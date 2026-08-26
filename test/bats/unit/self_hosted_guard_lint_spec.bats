#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/self_hosted_guard.sh -- the "a job
# that can land on a self-hosted runner must be guarded to same-repository
# events" lint.
#
# The org registers a self-hosted runner at ORG level, in the Default
# runner group, visibility `all`, `allows_public_repositories: true`, on a
# workstation shared with unrelated tenants. This repo is public. So a
# fork PR whose workflow reaches that machine is arbitrary code execution
# on hardware -- a different question from secrets, which fork PRs already
# cannot read.
#
# What is under test is NOT "does today's tree carry the condition" (a
# hand-applied `if:` on today's jobs decays at job N+1). It is the
# ELIGIBILITY RULE, which is what makes the requirement mechanical:
#
#   A job is self-hosted-eligible unless the lint can PROVE every label
#   its `runs-on` resolves to is a reserved GitHub-hosted label
#   (ubuntu-* / windows-* / macos-*, which GitHub will not let a
#   self-hosted runner claim). Unproven defaults to eligible.
#
# So the cases below are mostly "a NEW job spelled this way, with no
# guard, fails" -- the regression that a hand-maintained roster cannot
# catch. Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree; the last section drives the REAL tree to
# prove today's workflows pass, and pins the three jobs that are eligible
# today. Shape mirrors i18n_orphan_lint_spec.bats /
# early_close_reader_lint_spec.bats.

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
  source /source/script/test/drivers/self_hosted_guard.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/.github/workflows"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _workflow <name> <line>... -- create a workflow fixture.
_workflow() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/.github/workflows/${_name}"
}

# The canonical guard, as the block form a job would paste.
_guard_lines() {
  printf '%s\n' \
    "    if: >-" \
    "      github.event_name != 'pull_request' ||" \
    "      github.event.pull_request.head.repo.full_name == github.repository"
}

# ════════════════════════════════════════════════════════════════════
# The eligibility rule: a NEW job that can reach a self-hosted runner
# and carries no guard must FAIL
# ════════════════════════════════════════════════════════════════════

@test "self-hosted guard: FAILS on a new job with a literal self-hosted runs-on" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  heavy:' \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job heavy"* ]]
  [[ "${output}" == *"self-hosted"* ]]
}

@test "self-hosted guard: FAILS on a new job whose runs-on is a label array" {
  # The real registration shape: the org's runner carries
  # self-hosted,Linux,X64,gpu, and a job targets it by listing labels.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  gpu-build:' \
    '    runs-on: [self-hosted, gpu]' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job gpu-build"* ]]
  [[ "${output}" == *"'self-hosted'"* ]]
}

@test "self-hosted guard: FAILS on the block-sequence runs-on form" {
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  gpu-build:' \
    '    runs-on:' \
    '      - self-hosted' \
    '      - gpu' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job gpu-build"* ]]
}

@test "self-hosted guard: FAILS on a runner GROUP, which has no hosted reading" {
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  grouped:' \
    '    runs-on:' \
    '      group: workstations' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"runner group"* ]]
}

@test "self-hosted guard: FAILS when a literal matrix contributes a non-hosted label" {
  # The likeliest migration shape: an existing platform matrix gains one
  # self-hosted entry. The runs-on line does not change at all, so a
  # roster keyed on job names or on the runs-on text would miss it.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  build:' \
    '    strategy:' \
    '      matrix:' \
    '        include:' \
    '          - platform: linux/amd64' \
    '            runner: ubuntu-latest' \
    '          - platform: linux/arm64' \
    '            runner: self-hosted' \
    '    runs-on: ${{ matrix.runner }}' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job build"* ]]
  [[ "${output}" == *"'self-hosted'"* ]]
}

@test "self-hosted guard: FAILS when the matrix is computed at runtime (fromJSON)" {
  # Unprovable, therefore eligible. The label set comes from a script the
  # lint does not execute, so no static reading can rule out a
  # self-hosted label appearing there tomorrow.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  build:' \
    '    needs: compute-matrix' \
    '    strategy:' \
    '      matrix: ${{ fromJSON(needs.compute-matrix.outputs.matrix) }}' \
    '    runs-on: ${{ matrix.runner }}' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"computed at runtime"* ]]
}

@test "self-hosted guard: FAILS when runs-on is a caller-supplied input expression" {
  _workflow "wf.yaml" \
    'on:' \
    '  workflow_call:' \
    'jobs:' \
    '  build:' \
    '    runs-on: ${{ inputs.runner }}' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not knowable here"* ]]
}

@test "self-hosted guard: FAILS when runs-on reads a matrix key the job never declares" {
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  build:' \
    '    strategy:' \
    '      matrix:' \
    '        platform: [linux/amd64]' \
    '    runs-on: ${{ matrix.runner }}' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no literal value"* ]]
}

@test "self-hosted guard: FAILS on a job calling a REMOTE reusable workflow" {
  # The callee picks the machine and the callee is not in this tree, so
  # the caller has to carry the guard. A LOCAL call is exempt (next
  # section) because the callee's own jobs are checked in place.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  delegated:' \
    '    uses: other-org/other-repo/.github/workflows/build.yaml@v1'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"remote reusable workflow"* ]]
}

@test "self-hosted guard: FAILS on a bare hostname label" {
  # Neither self-hosted nor a reserved family: a runner registered under
  # its own hostname is the shape an ad-hoc migration reaches for first.
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  build:' \
    '    runs-on: C01013328' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"C01013328"* ]]
}

@test "self-hosted guard: names the exact condition to paste in the failure message" {
  # A guard nobody can act on gets bypassed. The message must carry the
  # expression verbatim, not a pointer to documentation.
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  build:' \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"github.event_name != 'pull_request'"* ]]
  [[ "${output}" == *"github.event.pull_request.head.repo.full_name == github.repository"* ]]
}

# ════════════════════════════════════════════════════════════════════
# The eligibility rule: what must NOT be flagged
# ════════════════════════════════════════════════════════════════════

@test "self-hosted guard: PASSES a literal GitHub-hosted runs-on with no guard" {
  # The rule must not demand the condition of hosted-only jobs: guarding
  # them would skip them for fork PRs, which is how a required check goes
  # vacuously green.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" == *"0 self-hosted-eligible"* ]]
}

@test "self-hosted guard: PASSES the arm + amd hosted families and a windows/macos runner" {
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  a:' \
    '    runs-on: ubuntu-24.04-arm' \
    '    steps:' \
    '      - run: make' \
    '  b:' \
    '    runs-on: windows-latest' \
    '    steps:' \
    '      - run: make' \
    '  c:' \
    '    runs-on: macos-14' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"3 job(s)"* ]]
  [[ "${output}" == *"0 self-hosted-eligible"* ]]
}

@test "self-hosted guard: PASSES a literal matrix that resolves entirely to hosted labels" {
  # The self-test acceptance job's real shape. Resolving the matrix is
  # what keeps this job out of the eligible set, and therefore keeps it
  # running for fork PRs.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  acceptance:' \
    '    strategy:' \
    '      matrix:' \
    '        include:' \
    '          - platform: linux/amd64' \
    '            runner: ubuntu-latest' \
    '          - platform: linux/arm64' \
    '            runner: ubuntu-24.04-arm' \
    '    runs-on: ${{ matrix.runner }}' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"0 self-hosted-eligible"* ]]
}

@test "self-hosted guard: PASSES a LOCAL reusable-workflow call" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  worker-selftest:' \
    '    uses: ./.github/workflows/build-worker.yaml' \
    '    with:' \
    '      image_name: fixture'
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
}

@test "self-hosted guard: PASSES an eligible job that carries the guard alone" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  heavy:' \
    "$(_guard_lines)" \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 self-hosted-eligible, all guarded"* ]]
}

@test "self-hosted guard: PASSES an eligible job that ANDs the guard with its own gate" {
  # The build-worker shape. A job keeps its code_changed gate and
  # parenthesises the guard beside it; the check is on the normalised
  # text, so the wrapped block scalar still matches.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  heavy:' \
    '    needs: [path-filter]' \
    '    if: >-' \
    "      needs.path-filter.outputs.code_changed == 'true' &&" \
    "      (github.event_name != 'pull_request' ||" \
    '      github.event.pull_request.head.repo.full_name == github.repository)' \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 self-hosted-eligible, all guarded"* ]]
}

@test "self-hosted guard: FAILS an eligible job whose if: is a near-miss reword" {
  # `github.repository_owner` is the trap: it passes for every fork
  # inside the same org, which is not the property being asserted. Only
  # the canonical expression counts.
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  heavy:' \
    '    if: github.repository_owner == ${{ github.event.pull_request.head.repo.owner.login }}' \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"job heavy"* ]]
}

@test "self-hosted guard: an unrelated job-level if: does not satisfy the guard" {
  _workflow "wf.yaml" \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  heavy:' \
    "    if: needs.classify.outputs.code_changed == 'true'" \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity: the lint must not pass by scanning nothing
# ════════════════════════════════════════════════════════════════════

@test "self-hosted guard: FAILS when the workflow directory is missing" {
  rm -rf "${SCRATCH}/.github"
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"vacuously"* ]]
}

@test "self-hosted guard: FAILS when the workflow directory holds no workflow" {
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"vacuously"* ]]
}

@test "self-hosted guard: FAILS when the workflows parse to zero jobs" {
  # A reader regression would otherwise report zero violations forever,
  # in silence -- the same failure mode the guard exists to prevent, one
  # level up.
  _workflow "wf.yaml" \
    'on:' \
    '  push:' \
    'permissions:' \
    '  contents: read'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no job at all"* ]]
}

@test "self-hosted guard: scans every workflow in the directory, not a named list" {
  # A workflow added tomorrow is covered without editing the driver.
  _workflow "clean.yaml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  lint:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: make'
  _workflow "later.yml" \
    'on:' \
    '  push:' \
    'jobs:' \
    '  heavy:' \
    '    runs-on: self-hosted' \
    '    steps:' \
    '      - run: make'
  run _run_self_hosted_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"later.yml"* ]]
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "self-hosted guard: the real repo tree has every eligible job guarded" {
  REPO_ROOT="/source"
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "self-hosted guard: the real tree's eligible set is the three runtime-matrix worker jobs" {
  # Pins the CURRENT answer, so a change to the eligible set is a
  # deliberate edit here rather than a silent drift. All three take their
  # runner label from a `fromJSON` matrix; every other job in the tree
  # resolves statically to a reserved hosted label.
  REPO_ROOT="/source"
  run _run_self_hosted_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"3 self-hosted-eligible, all guarded"* ]]
}
