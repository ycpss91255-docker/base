#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/tool_provenance.sh -- the "a CI job
# may not run a tool this repo pins unless it obtains the pin" lint.
#
# base#1080: the `shellcheck` job ran whatever `ubuntu-latest` shipped
# pre-installed. The pin machinery could not see it -- pin-coverage checks
# that every version the tree NAMES is declared, and that job named none --
# so the local gate and a required check disagreed about the same commit,
# in both directions, with GitHub's image release schedule deciding which.
#
# What is under test is NOT "does today's shellcheck job install the pin"
# (a hand-applied step decays at job N+1, and a hand-written list of jobs
# allowed to use runner tools goes stale in silence -- the failure this
# repo keeps repeating). It is the RULE, whose two populations are both
# computed:
#
#   the TOOLS   every pin on script/ci/test-tools-pins.sh's roster whose
#               own probe invokes it by name. A pin added to
#               dockerfile/Dockerfile.test-tools joins the scan with this
#               file untouched; ALPINE_VERSION and the bats helper
#               libraries fall out because their probes name `cat` and
#               `git`, not themselves.
#   the JOBS    every job of every workflow under .github/workflows/.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree; the last section drives the REAL tree.
# Shape mirrors self_hosted_guard_lint_spec.bats / just_provenance_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/tool_provenance.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/.github/workflows" \
           "${SCRATCH}/script/ci" \
           "${SCRATCH}/script/test/drivers"
  REPO_ROOT="${SCRATCH}"

  # A roster stub in the accessor's own output shape: <ARG>\t<pin>\t<probe>.
  # Two invocable pins and two that are not, so the derivation of "which
  # roster entries are commands" is exercised rather than assumed.
  cat > "${SCRATCH}/script/ci/test-tools-pins.sh" <<'ROSTER'
#!/usr/bin/env bash
printf 'SHELLCHECK_VERSION\tv0.11.0\tshellcheck --version\n'
printf 'HADOLINT_VERSION\tv2.15.1\thadolint --version\n'
printf 'ALPINE_VERSION\t3.22\tcat /etc/alpine-release\n'
printf 'BATS_SUPPORT_VERSION\tv0.3.0\tgit -C /usr/lib/bats/bats-support describe --tags\n'
ROSTER
  chmod +x "${SCRATCH}/script/ci/test-tools-pins.sh"

  # A test.sh stub answering only what the driver asks it: the members of
  # a lint group. `1/1` is the whole partition, which is how the driver
  # resolves a `--lint-group` whose index is a workflow expression.
  cat > "${SCRATCH}/script/test/test.sh" <<'TESTSH'
#!/usr/bin/env bash
[[ "${1:-}" == "--lint-group-members" ]] || exit 2
printf 'pure-lint\n'
TESTSH
  chmod +x "${SCRATCH}/script/test/test.sh"

  # Two driver fixtures: one that invokes a pinned tool, one pure bash.
  printf '%s\n' '#!/usr/bin/env bash' 'shellcheck -x "${1}"' \
    > "${SCRATCH}/script/test/drivers/needs_binary.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'grep -q x "${1}"' \
    > "${SCRATCH}/script/test/drivers/pure_lint.sh"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _workflow <name> <line>... -- create a workflow fixture.
_workflow() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/.github/workflows/${_name}"
}

# ════════════════════════════════════════════════════════════════════
# A job that runs a pinned tool it does not obtain must FAIL
# ════════════════════════════════════════════════════════════════════

# why: The direct shape. A job invoking a pinned binary on a bare runner
# is running whatever the runner image happens to carry that week, which
# is the divergence base#1080 measured.
@test "tool provenance: FAILS on a job invoking a pinned tool directly" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: shellcheck -x init.sh'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job lint"* ]]
  [[ "${output}" == *"shellcheck"* ]]
}

# why: base#1080 itself. The job's shell says `--shellcheck-only`, not
# `shellcheck`, so a scan for command words alone reads it as clean. The
# demand is resolved through the driver the selector names.
@test "tool provenance: FAILS on a host-direct test.sh selector whose driver needs a pinned binary" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/test/test.sh --needs-binary-only'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job lint"* ]]
  [[ "${output}" == *"shellcheck"* ]]
  # And the finding names WHERE the demand came from. Without it a reader
  # is sent looking for the word `shellcheck` in a job whose shell says
  # `--needs-binary-only`.
  [[ "${output}" == *"needs_binary.sh"* ]]
}

# why: A backslash continuation is ONE command, and this repo's workflows
# wrap: the install step base#1080 added wraps its own `curl`. Read line by
# line, the selector and the `test.sh` that carries it land on different
# lines, and the demand the flag names disappears -- the same silent green
# as reading no selector at all.
@test "tool provenance: FAILS on a host-direct selector split across a line continuation" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: |' \
    '          ./script/test/test.sh \' \
    '            --needs-binary-only'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job lint"* ]]
  [[ "${output}" == *"shellcheck"* ]]
  [[ "${output}" == *"needs_binary.sh"* ]]
}

# why: A selector naming a driver that does not exist cannot be resolved,
# and an unresolvable demand must not read as no demand -- that is the
# silent green this lint exists to refuse.
@test "tool provenance: REFUSES a host-direct selector whose driver file is absent" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/test/test.sh --no-such-lint-only'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no_such_lint.sh"* ]]
}

# ════════════════════════════════════════════════════════════════════
# A job that obtains the pin PASSES
# ════════════════════════════════════════════════════════════════════

# why: The fix shape. The job reads the version from the one declaration
# and installs it, so the binary it runs is the binary the gate runs.
@test "tool provenance: PASSES a job that installs the tool from the declaration" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: |' \
    '          v="$(./script/ci/test-tools-pins.sh roster)"' \
    '          echo "SHELLCHECK_VERSION ${v}"' \
    '      - run: shellcheck -x init.sh'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# why: The other legitimate provenance: the tool comes from the image
# whose every version this repo pins, so no per-tool evidence is needed.
@test "tool provenance: PASSES a job that obtains the pinned test-tools image" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/ci/obtain_test_tools.sh img --platform linux/amd64' \
    '      - run: shellcheck -x init.sh'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# why: A pure-bash driver demands nothing, and a lint that reported one
# anyway would push every lint job into obtaining an image it does not
# need -- the cost the split-out jobs exist to avoid.
@test "tool provenance: PASSES a host-direct selector whose driver is pure bash" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/test/test.sh --pure-lint-only'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# why: `--lint-group N/T` takes its index from a matrix expression, so the
# demand is the UNION over the whole partition -- resolved by asking
# test.sh for the members of the single-group partition rather than by a
# list of which driver lands in which group.
@test "tool provenance: resolves --lint-group through test.sh, not through a group list" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint-static:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/test/test.sh --lint-group "${LINT_GROUP}"'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# What is NOT a demand
# ════════════════════════════════════════════════════════════════════

# why: A comment installs and runs nothing, and the prose of this repo --
# this driver's own header included -- names every tool it reasons about.
@test "tool provenance: a tool named in a comment is not an invocation" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      # shellcheck is what this job used to run' \
    '      - run: echo hi'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# why: ci-rollup echoes the name of the job whose result it reports, and a
# path under coverage/ carries `kcov` in it. Neither runs anything, and a
# lint that read them as invocations would be answered by muting it --
# which is how a guard stops being read.
@test "tool provenance: a tool name in an argument or a path is not an invocation" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  rollup:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: |' \
    '          echo "shellcheck: ${SHELLCHECK_RESULT}"' \
    '          report=coverage/kcov-merged/cobertura.xml' \
    '          test -f "${report}"'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# why: The same fold, in the direction that costs a lint its readers.
# Unfolded, the second physical line of a continued command reads as a
# command of its own, so a wrapped ARGUMENT that happens to spell a pinned
# tool reports a demand nothing makes -- and a lint answered by muting it
# stops being read.
@test "tool provenance: a wrapped argument is not an invocation" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  probe:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: |' \
    '          echo "the linter here is" \' \
    '            hadolint'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# why: A job `name:` is a label in the checks list, not a command. The
# bats jobs are named after the harness they run, so reading names as
# demands would report every one of them.
@test "tool provenance: a tool named in a step name is not an invocation" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  probe:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - name: Run Bats kcov-fragile specs' \
    '        run: echo hi'
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity: a reader regression must not read as agreement
# ════════════════════════════════════════════════════════════════════

# why: An empty workflow directory scans nothing and would report every
# job compliant, which is the failure mode of every guard this repo has
# had to repair.
@test "tool provenance: REFUSES a workflow tree with no job at all" {
  _workflow "wf.yaml" 'on:' '  push:'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"vacuous"* ]]
}

# why: A job key is a job key whether or not the line ends in a comment,
# and this tree's workflows are comment-dense. Read as ordinary text, such
# a key does not merely drop its job: the steps under it are accumulated
# into the PREVIOUS job, so an unobtained tool is scored against provenance
# that belongs to a different job and passes.
@test "tool provenance: FAILS on a job whose key line carries a trailing comment" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  good:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/ci/obtain_test_tools.sh img' \
    '  bad:  # the one that borrows the job above it' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: shellcheck -x init.sh'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job bad"* ]]
}

# why: The whole-tree floor only fires when NO file yielded a job, so one
# file the reader cannot see is skipped in silence beside nine it can --
# and the clean line still reports the file in its workflow count. Every
# workflow declares `jobs:` (GitHub requires it), so a file that yielded
# none is a reader that stopped reading, not a workflow without work.
@test "tool provenance: REFUSES a workflow file it could read no job out of" {
  _workflow "a.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  good:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: ./script/ci/obtain_test_tools.sh img'
  _workflow "z.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:  # the key the reader cannot see' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: shellcheck -x init.sh'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"z.yaml"* ]]
  [[ "${output}" == *"vacuous"* ]]
}

# why: The roster is the population of tools. If the accessor stops
# answering, the scan has nothing to look for and passes having looked at
# nothing.
@test "tool provenance: REFUSES an empty roster" {
  printf '#!/usr/bin/env bash\n' > "${SCRATCH}/script/ci/test-tools-pins.sh"
  chmod +x "${SCRATCH}/script/ci/test-tools-pins.sh"
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: shellcheck -x init.sh'
  run _run_tool_provenance
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# The live tree
# ════════════════════════════════════════════════════════════════════

# why: The rule above is worth nothing if the repo it guards does not
# satisfy it. This is also the assertion that fails the day a new job
# reaches for a runner-provided pinned tool.
@test "tool provenance: the live workflow tree is clean" {
  REPO_ROOT=/source
  run _run_tool_provenance
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
