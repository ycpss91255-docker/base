#!/usr/bin/env bats
#
# coverage_local_spec.bats -- the in-job parallel kcov mode
# (`test.sh --coverage-local [--jobs N]`, base#726).
#
# why: ADR-00000008 shards kcov ACROSS a CI matrix, which is the only
# parallelism a GitHub-hosted plan offers: one runner, one concurrent job.
# On a single fat machine that matrix buys nothing, so the full-scope
# coverage run the release badge requires falls back to the serial path --
# tens of minutes pinning one core while the other thirty-one idle. kcov's
# bash engine parses one xtrace stream per traced process and is
# single-threaded, and `kcov` wrapping `bats --jobs` is unreliable for
# coverage ACCURACY, so the ONLY parallelism available is N independent
# kcov PROCESSES over disjoint slices, merged.
#
# What this spec pins is everything about that mode a merge could quietly
# lie about. The partition is the SHARED `_shard_unit_files` primitive
# (base#724) rather than a second partitioner, so the slices are the same
# exhaustive + disjoint set the CI matrix runs. A slice that produced no
# report at all must FAIL the run rather than merge to a smaller total that
# reads as a coverage regression -- "cannot tell" resolves to refusing. And
# the run covers the WHOLE suite, so it must stamp `scope=full`: a parallel
# run that stamped `partial` would be refused by
# `just release coverage-badge`, which is the entire point of building it.
#
# The mode is NOT wired into the PR gate. Production `self-test.yaml`
# stays on the GitHub-hosted matrix (one self-hosted runner is a SPOF and
# a contention point); the local mode's CI exposure is an opt-in
# `workflow_dispatch` workflow, whose shape the last section pins.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
}

teardown() {
  cleanup_mock_dir
}

# ════════════════════════════════════════════════════════════════════
# Fixtures
# ════════════════════════════════════════════════════════════════════

# _make_pool_root
#   Build a throwaway repo root carrying the two pools
#   `_COVERAGE_FULL_SUITE_POOLS` names, populated with specs of differing
#   `@test` counts (so the greedy-LPT weight has something to sort by).
#   Echoes the root.
_make_pool_root() {
  local _root="${BATS_TEST_TMPDIR}/pool"
  mkdir -p "${_root}/test/bats/unit/sub" "${_root}/test/bats/integration"
  local _n=1 _f
  for _f in "${_root}/test/bats/unit/alpha_spec.bats" \
            "${_root}/test/bats/unit/beta_spec.bats" \
            "${_root}/test/bats/unit/sub/gamma_spec.bats" \
            "${_root}/test/bats/integration/delta_spec.bats" \
            "${_root}/test/bats/integration/epsilon_spec.bats"; do
    : > "${_f}"
    local _i
    for (( _i = 0; _i < _n; _i++ )); do
      printf '@test "t%d" { true; }\n' "${_i}" >> "${_f}"
    done
    _n=$(( _n + 2 ))
  done
  printf '%s\n' "${_root}"
}

# _install_kcov_mocks <log> [fail_slice]
#   Stand in for kcov + bats. The kcov mock records its whole argv, writes
#   the cobertura report a real run leaves in its output directory, and
#   executes the wrapped command; `--merge` is recorded and writes the
#   merged report. The bats mock writes the junit report `_junit_to_timings`
#   reads back, one <testsuite> per spec file it was handed.
#
#   MOCK_NO_REPORT names an output directory the kcov mock must leave
#   EMPTY -- a crashed kcov that still exits 0, the case the run has to
#   refuse. MOCK_FAIL_ARG names a spec whose slice exits non-zero.
#   MOCK_MERGE_FAIL makes `kcov --merge` itself fail, every slice report
#   present -- the one refusal that is about neither the specs nor a lost
#   slice.
_install_kcov_mocks() {
  local _log="${1}"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    if [ "${1}" = "--merge" ]; then
      # MOCK_MERGE_FAIL: kcov merged nothing and said so. The slice
      # reports all exist, so the run has to fail on the merge itself.
      if [ -n "${MOCK_MERGE_FAIL:-}" ]; then
        exit 3
      fi
      shift
      _out="${1}"; shift
      mkdir -p "${_out}/kcov-merged"
      printf "<coverage/>\n" > "${_out}/kcov-merged/cobertura.xml"
      exit 0
    fi
    _out=""
    while [ $# -gt 0 ]; do
      case "${1}" in
        -*) shift ;;
        *)  _out="${1}"; shift; break ;;
      esac
    done
    if [ -n "${MOCK_NO_REPORT:-}" ] && [ "${_out}" = "${MOCK_NO_REPORT}" ]; then
      mkdir -p "${_out}"
      exit 0
    fi
    mkdir -p "${_out}/kcov-merged"
    printf "<coverage/>\n" > "${_out}/kcov-merged/cobertura.xml"
    "$@"'
  mock_cmd "bats" '
    _out=""
    _rc=0
    _files=""
    while [ $# -gt 0 ]; do
      case "${1}" in
        --output) _out="${2}"; shift 2 ;;
        # A value-taking flag whose value is NOT a spec path. Left as a
        # bare `-*` it would consume only the flag and the formatter name
        # would be read as a sixth spec, which is how this fixture first
        # made a whole-suite manifest look partial.
        --report-formatter) shift 2 ;;
        -*)       shift ;;
        *)        _files="${_files} ${1}"
                  if [ -n "${MOCK_FAIL_ARG:-}" ]; then
                    case "${1}" in *"${MOCK_FAIL_ARG}") _rc=1 ;; esac
                  fi
                  shift ;;
      esac
    done
    if [ -n "${_out}" ]; then
      mkdir -p "${_out}"
      {
        printf "<testsuites>\n"
        for _f in ${_files}; do
          printf "  <testsuite name=\"%s\" time=\"2.0\"/>\n" "${_f}"
        done
        printf "</testsuites>\n"
      } > "${_out}/report.xml"
    fi
    exit "${_rc}"'
}

# _driver_prelude <root>
#   Echo the shell program that sources ONLY the bats driver against a
#   throwaway repo root. test.sh pins REPO_ROOT `readonly` at the real
#   checkout, and this runner writes into ${REPO_ROOT}/coverage -- the
#   mounted checkout, whose reports a concurrent `just test coverage` is
#   reading. Sourcing the driver alone is what keeps the fixture a fixture.
_driver_prelude() {
  printf '%s\n' \
    "REPO_ROOT='${1}'" \
    '_die() { printf "DIE %s\n" "$*" >&2; exit 1; }' \
    '_log_warn() { printf "WARN %s\n" "$*" >&2; }' \
    'source /source/script/test/drivers/bats.sh'
}

# ════════════════════════════════════════════════════════════════════
# The host-side flags
#
# `--coverage-local` is a THIRD kcov mode beside `--coverage` (serial,
# whole suite) and `--coverage-shard` (one slice of the CI matrix), and it
# has to be told apart from both: it produces a whole-suite figure like the
# first and runs a partition like the second. Combining it with either is
# a request for two different runs, so it is refused rather than silently
# resolved -- the same rule `--coverage-path` already carries.
# ════════════════════════════════════════════════════════════════════

# why: `--jobs` alone reads as "run the suite with N parallel jobs", which
# is what bare `just test` already does. Accepting it there would make a
# typo for `--coverage-local --jobs N` a silent no-op run of the wrong
# mode.
@test "main: --jobs without --coverage-local is refused" {
  run bash -c '
    source /source/script/test/test.sh
    main --jobs 4
  '
  assert_failure
  assert_output --partial "--jobs"
  assert_output --partial "--coverage-local"
}

# why: the load-bearing conflict. `--coverage-shard` narrows the run to ONE
# slice, `--coverage-local` runs every slice; a run that took both would
# write a partition's reports while the operator believed they had the
# whole suite -- exactly the certificate defect ADR-00000008's #952
# amendment closed.
@test "main: --coverage-local with --coverage-shard is refused" {
  run bash -c '
    source /source/script/test/test.sh
    main --coverage-local --coverage-shard 1/4
  '
  assert_failure
  assert_output --partial "--coverage-local"
  # Not the parser shrugging at a flag it does not know: the refusal has to
  # be the one that names the conflict.
  refute_output --partial "Unknown option"
}

# why: `--coverage-path` reports NO figure at all and writes nothing into
# coverage/, so pairing it with a mode whose whole output is a merged
# report is two answers to one question.
@test "main: --coverage-local with --coverage-path is refused" {
  run bash -c '
    source /source/script/test/test.sh
    main --coverage-local --coverage-path test/bats/unit/ci_spec.bats
  '
  assert_failure
  assert_output --partial "--coverage-local"
  refute_output --partial "Unknown option"
}

# why: a job count that is not a positive integer would reach
# `_shard_unit_files` as a malformed total, whose message names a shard
# spec the operator never typed. Refuse it where it was typed.
@test "main: --coverage-local rejects a non-numeric --jobs" {
  run bash -c '
    source /source/script/test/test.sh
    main --coverage-local --jobs seven
  '
  assert_failure
  assert_output --partial "seven"
}

# why: zero jobs is the boundary the partitioner cannot answer -- a
# partition of the suite into no slices covers nothing, and a run that
# covered nothing must not be reported as one that covered everything.
@test "main: --coverage-local rejects --jobs 0" {
  run bash -c '
    source /source/script/test/test.sh
    main --coverage-local --jobs 0
  '
  assert_failure
  assert_output --partial "0"
  refute_output --partial "Unknown option"
}

# why: `010` passes `^[0-9]+$` and is then READ IN TWO BASES. The launch
# loop counts with bash arithmetic, where a leading zero is octal (8); the
# partitioner hands the same string to awk as `-v t=`, where it is decimal
# (10). So `--jobs 010` launches 8 slices of a 10-way partition, two bins'
# specs are never run and never instrumented, and none of the three
# documented refusals fires -- a whole-suite certificate over a
# measurement with a hole in it. Refused where it was typed rather than
# resolved to one base: either resolution leaves the operator's `010`
# meaning a number they did not write.
@test "main: --coverage-local rejects a --jobs written with a leading zero" {
  run bash -c '
    source /source/script/test/test.sh
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { :; }
    # The dispatch is stubbed so the assertion is about the value never
    # LEAVING the host, not about what a container did with it.
    _run_via_compose() { printf "DISPATCHED jobs=%s\n" "${COVERAGE_LOCAL_JOBS}"; }
    main --coverage-local --jobs 010
  '
  assert_failure
  assert_output --partial "010"
  refute_output --partial "DISPATCHED"
  refute_output --partial "Unknown option"
}

# why: the dispatch is what makes the mode real, and the two selectors it
# CLEARS matter as much as the one it sets: `_run_via_compose` forwards
# COVERAGE_SHARD / COVERAGE_PATH from the AMBIENT environment, so this
# suite's own specs -- which run inside a coverage shard -- would otherwise
# hand a whole-suite mode a partition value.
@test "main: --coverage-local dispatches to the coverage service with the job count pinned" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'
  mock_cmd "nproc" 'echo 6'

  run bash -c '
    source /source/script/test/test.sh
    # The provenance pair is STUBBED: it reads and writes
    # ${REPO_ROOT}/coverage, which here is the mounted checkout.
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { :; }
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --coverage-local
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
  assert_output --partial "COVERAGE_LOCAL_JOBS=6"
  assert_output --partial "COVERAGE_SHARD="
  refute_output --partial "COVERAGE_SHARD=1"
}

# why: the default is `nproc` and the flag has to beat it, or `--jobs`
# would be decoration on a machine whose core count the operator is
# deliberately not using (a shared workstation, a cgroup-limited shell).
@test "main: --coverage-local --jobs N overrides the nproc default" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'
  mock_cmd "nproc" 'echo 32'

  run bash -c '
    source /source/script/test/test.sh
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { :; }
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --coverage-local --jobs 3
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "COVERAGE_LOCAL_JOBS=3"
  refute_output --partial "COVERAGE_LOCAL_JOBS=32"
}

# ════════════════════════════════════════════════════════════════════
# The in-container dispatch
# ════════════════════════════════════════════════════════════════════

# why: the branch order is the contract. COVERAGE_PATH is read FIRST
# because it is the one kcov mode that writes nothing into coverage/;
# letting a stale COVERAGE_LOCAL_JOBS out-rank it would turn a
# one-spec instrumentation loop into a whole-suite run against the
# checkout.
@test "main --ci: COVERAGE_PATH out-ranks COVERAGE_LOCAL_JOBS" {
  run bash -c '
    source /source/script/test/test.sh
    _run_coverage_path() { printf "PATH_RUNNER %s\n" "$1"; }
    _run_coverage_parallel() { printf "PARALLEL_RUNNER %s\n" "$1"; }
    _fix_permissions() { :; }
    COVERAGE=1 COVERAGE_PATH=test/bats/unit/ci_spec.bats \
      COVERAGE_LOCAL_JOBS=4 COVERAGE_SHARD= BATS_ONLY=1 main --ci
  '
  assert_success
  assert_output --partial "PATH_RUNNER test/bats/unit/ci_spec.bats"
  refute_output --partial "PARALLEL_RUNNER"
}

# why: without this the flag is inert -- the container would fall through
# to the serial `_run_coverage`, and the mode would be a rename of the run
# it was built to replace.
@test "main --ci: COVERAGE_LOCAL_JOBS routes to the parallel runner, not the serial one" {
  run bash -c '
    source /source/script/test/test.sh
    _run_coverage() { printf "SERIAL_RUNNER %s\n" "${1:-}"; }
    _run_coverage_parallel() { printf "PARALLEL_RUNNER %s\n" "$1"; }
    _fix_permissions() { :; }
    COVERAGE=1 COVERAGE_LOCAL_JOBS=4 COVERAGE_PATH= COVERAGE_SHARD= \
      BATS_ONLY=1 main --ci
  '
  assert_success
  assert_output --partial "PARALLEL_RUNNER 4"
  refute_output --partial "SERIAL_RUNNER"
}

# why: found by RUNNING the mode, not by reading it. `just test
# coverage-local` on the real tree turned ci_spec's "main --ci with
# COVERAGE=1 skips the lint phase" red, and the reason is the whole
# selector family, not this one member: the in-container dispatch reads
# COVERAGE_SHARD / COVERAGE_PATH / COVERAGE_LOCAL_JOBS out of the
# ENVIRONMENT, and a spec that drives that entry inherits whatever the
# container was started with. That spec pinned two of the three and stubbed
# `_run_coverage`; under `--coverage-local` the inherited
# COVERAGE_LOCAL_JOBS routed past the stub into the real parallel runner,
# so a unit test launched 32 nested kcov processes and failed.
# The rule is therefore not "clear COVERAGE_LOCAL_JOBS" -- that is this
# defect, not its class. It is: a block that drives the in-container
# coverage entry PINS EVERY selector the dispatch forwards, set or
# emptied, so the branch under test is the branch taken whichever run the
# suite is inside. The roster is read off `_run_via_compose`'s own
# forwarding lines rather than listed here, so a fourth selector arrives
# with this demand already made of every fixture.
@test "specs driving the in-container coverage entry pin every forwarded selector (#726)" {
  # The roster, derived. These are the names the coverage service is
  # started with, which is exactly the set a spec can inherit.
  run bash -c "grep -oE -- '-e COVERAGE_[A-Z_]+=' /source/script/test/test.sh \
    | grep -oE 'COVERAGE_[A-Z_]+' | sort -u | tr '\n' ' '"
  assert_success
  local _roster="${output}"
  # Three today; the assertion is that there is a roster at all, not how
  # long it is.
  assert [ -n "${_roster}" ]

  local _script="${BATS_TEST_TMPDIR}/pin.awk"
  cat > "${_script}" << 'AWK'
    # The in-container entry is one command: the COVERAGE=1 assignment and
    # the `main --ci` call on ONE logical line. That shape reaches the
    # dispatch's coverage branch without the word `_run_coverage` or
    # `--coverage` appearing in the block at all, which is why a
    # name-based reading misses it.
    #
    # The pattern is ASSEMBLED from pieces rather than written out,
    # because a detector spelled in full matches its own block: this file
    # carries the scanner and would be reported as a spec that drives a
    # coverage run and pins nothing.
    BEGIN {
      n = split(sel, s, " ")
      entry = "COVERAGE" "=1[^\n]*main --" "ci"
    }
    /^@test / { blk = $0; body = ""; cont = ""; inblk = 1; next }
    inblk {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # Prose about a selector is not a pin, and prose about the entry is
      # not a drive.
      if (line ~ /^#/) next
      # Continuations are joined, so an invocation wrapped across lines is
      # still one command to this reader -- the form both of this file's
      # own dispatch cases are written in.
      if (cont != "") { line = cont " " line; cont = "" }
      if (line ~ /\\$/) { sub(/\\$/, "", line); cont = line; next }
      body = body "\n" line
      if ($0 == "}") {
        inblk = 0
        if (body !~ entry) next
        # A block that hands the entry's SHAPE to a scanner is describing
        # it, not running it -- ci_spec's own "no spec drives a coverage
        # run against the mounted checkout" carries the same command as a
        # regex, and pinning selectors inside a pattern would change what
        # that guard matches. `awk -f` over the spec tree is the mark of a
        # reader; a driver sources test.sh and calls main.
        if (body ~ /awk -f/) next
        total++
        for (i = 1; i <= n; i++) {
          if (s[i] == "") continue
          if (body !~ (s[i] "=")) {
            print FILENAME ": " blk " -- does not pin " s[i]
          }
        }
      }
    }
    END { print "TOTAL=" total }
AWK

  run awk -v sel="${_roster}" -f "${_script}" \
    /source/test/bats/unit/*.bats /source/test/bats/integration/*.bats
  assert_success
  # Non-vacuous: the scan actually found the blocks it is judging. A
  # detector that matched nothing would report every tree compliant.
  #
  # What this guard measured when it was written, so that the next person
  # to change the detector can tell a real movement from a bug in it: over
  # the tree it landed on, TOTAL=4 driving blocks, and before the four
  # fixtures were completed it printed 6 offending lines across all 4 of
  # them. (Five blocks match the entry's shape; the fifth is this file's
  # own scanner-carrying case, which the `awk -f` exemption above takes
  # out. b1b8b0ea's message reported the un-exempted 5/5 -- the figures
  # from a mid-work version of the detector, not from the one it committed;
  # that message cannot be reworded, as history rewriting is denied
  # org-wide, so the correct figures are recorded here beside the code they
  # describe.)
  assert_line --partial "TOTAL="
  refute_line --partial "TOTAL=0"
  refute_output --partial "does not pin"
}

# ════════════════════════════════════════════════════════════════════
# The runner
# ════════════════════════════════════════════════════════════════════

# why: the whole claim of the mode. N kcov PROCESSES, each over one slice
# of the SHARED partition -- so the union of the slices is the suite and no
# spec is instrumented twice. A second partitioner would be a second
# roster; a partition that dropped a spec would report a coverage
# regression nobody caused.
@test "_run_coverage_parallel: launches one kcov per slice over an exhaustive, disjoint partition" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel 3"
  assert_success

  # One instrumented run per slice, plus the merge.
  run bash -c "grep -c -- '--include-path' '${_log}'"
  assert_output "3"

  # The union of the spec files handed to kcov is the pool, once each.
  run bash -c "
    tr ' ' '\n' < '${_log}' \
      | grep -- '_spec\.bats\$' | sort"
  assert_success
  assert_line --index 0 "${_root}/test/bats/integration/delta_spec.bats"
  assert_line --index 1 "${_root}/test/bats/integration/epsilon_spec.bats"
  assert_line --index 2 "${_root}/test/bats/unit/alpha_spec.bats"
  assert_line --index 3 "${_root}/test/bats/unit/beta_spec.bats"
  assert_line --index 4 "${_root}/test/bats/unit/sub/gamma_spec.bats"
  assert [ "${#lines[@]}" -eq 5 ]
}

# why: the merge is what turns N partial reports into the project figure,
# and it must name EVERY slice. A merge over a subset is the silent-loss
# case: it produces a valid report carrying a smaller line set, which reads
# as a regression rather than as the bug it is.
@test "_run_coverage_parallel: merges every slice's report into the repo coverage tree" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel 3"
  assert_success

  run bash -c "grep -- '--merge' '${_log}'"
  assert_success
  assert_output --partial "${_root}/coverage"
  # Three slice directories, all of them.
  run bash -c "grep -- '--merge' '${_log}' | tr ' ' '\n' | grep -c 'part-'"
  assert_output "3"

  assert [ -f "${_root}/coverage/kcov-merged/cobertura.xml" ]
}

# why: "cannot tell" resolves to refusing. A kcov that dies after its
# tests pass leaves an EMPTY output directory and a zero status, and
# merging the survivors would publish a smaller line set under a
# whole-suite certificate. The refusal is what makes a lost slice
# distinguishable from a coverage drop.
@test "_run_coverage_parallel: a slice that produced no report fails the run instead of merging" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  local _work="${BATS_TEST_TMPDIR}/work"
  run bash -c "$(_driver_prelude "${_root}")
export COVERAGE_LOCAL_WORKDIR='${_work}'
export MOCK_NO_REPORT='${_work}/part-2'
_run_coverage_parallel 3"
  assert_failure
  assert_output --partial "slice 2"

  run bash -c "grep -c -- '--merge' '${_log}' || true"
  assert_output "0"
}

# why: a refusal is only as useful as the next thing it tells you to look
# at, and this mode's scratch root is a `mktemp -d` INSIDE the ephemeral
# `docker compose run --rm` container the shipped entry starts. A path
# under it does not exist on the machine the operator is reading the
# message on, and COVERAGE_LOCAL_WORKDIR -- the only way to move it -- is
# not forwarded into that container, so they cannot make it exist either.
# What they DO have is every slice's output, replayed above the refusal by
# `_coverage_parallel_collect`; that is what both refusals must name.
@test "_run_coverage_parallel: the lost-slice refusal names output the operator has (#726)" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  local _work="${BATS_TEST_TMPDIR}/refusal-work"
  run bash -c "$(_driver_prelude "${_root}")
export COVERAGE_LOCAL_WORKDIR='${_work}'
export MOCK_NO_REPORT='${_work}/part-2'
_run_coverage_parallel 3"
  assert_failure
  assert_output --partial "slice 2 of 3"
  # The scratch root is container-local. Naming any path under it sends the
  # reader to `ls` something that is not there.
  refute_output --partial "${_work}/log-2"
  refute_output --partial "${_work}/part-2"
  # And the replay is named, because it is where the evidence actually is.
  assert_output --partial "replayed above"

  # Naming the replay is half of it. A refusal that QUOTES a header for the
  # reader to search for has to quote one the run actually printed --
  # otherwise the instruction is precise, followable, and wrong, which is
  # worse than "look above": the operator greps, finds nothing, and
  # concludes the replay is missing rather than that the message is. So the
  # quoted literal is lifted back out of the message and required to appear
  # in the same output -- on some OTHER line, because the message quoting it
  # would otherwise satisfy the search by itself.
  local _all="${output}" _quoted _elsewhere
  _quoted="$(sed -n "s/.*under '\([^']*\)'.*/\1/p" <<< "${_all}" | head -n 1)"
  assert [ -n "${_quoted}" ]
  _elsewhere="$(grep -vF -- "under '" <<< "${_all}" || true)"
  run grep -qF -- "${_quoted}" <<< "${_elsewhere}"
  assert_success
}

# why: the sibling refusal, and the same rule. A merge that fails leaves
# the same unreachable scratch root, and "the per-slice reports are under
# <container temp dir>" is the same instruction the reader cannot follow.
@test "_run_coverage_parallel: a failed merge names output the operator has (#726)" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  local _work="${BATS_TEST_TMPDIR}/merge-work"
  run bash -c "$(_driver_prelude "${_root}")
export COVERAGE_LOCAL_WORKDIR='${_work}'
export MOCK_MERGE_FAIL=1
_run_coverage_parallel 2"
  assert_failure
  # The status is the one fact only the merge knows, so it stays.
  assert_output --partial "status 3"
  refute_output --partial "${_work}"
  assert_output --partial "replayed above"
}

# why: the release path is the reason this mode exists.
# `just release coverage-badge` publishes only `scope=full`, and the scope
# is DERIVED from coverage/timings.tsv -- so a parallel run whose manifest
# named the last slice's specs alone would be refused exactly like a shard,
# and the serial run it replaces would still be on the critical path.
@test "_run_coverage_parallel: the merged run manifest names every spec, so the scope stamps full" {
  local _root
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${BATS_TEST_TMPDIR}/kcov.log"

  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel 3
bash -c 'source /source/script/test/test.sh
_measured_coverage_scope \"${_root}\"'"
  assert_success
  assert_output --partial "full"
  refute_output --partial "partial"
}

# why: a red spec must stay red. The slices run concurrently, so a failing
# one is a status that has to survive `wait` and the merge -- swallowing it
# would make the fastest coverage mode the one that cannot fail.
@test "_run_coverage_parallel: a failing slice fails the run" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  run bash -c "$(_driver_prelude "${_root}")
export MOCK_FAIL_ARG=alpha_spec.bats
_run_coverage_parallel 3"
  assert_failure

  # And it is the SPECS' verdict, not a runner that fell over: every slice
  # still reported, so the report was still merged. A red run that also
  # threw its report away would send the operator back to the serial path
  # to find out what broke.
  run bash -c "grep -c -- '--merge' '${_log}'"
  assert_output "1"
}

# why: the runner is reachable from the container's environment as well as
# from the flag (`COVERAGE_LOCAL_JOBS` is forwarded), so the validation
# cannot live only in the host-side parser -- an inherited junk value would
# otherwise reach `_shard_unit_files` as a malformed total.
@test "_run_coverage_parallel: rejects a job count that is not a positive integer" {
  local _root
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${BATS_TEST_TMPDIR}/kcov.log"

  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel 0"
  assert_failure
  assert_output --partial "DIE"

  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel two"
  assert_failure
  assert_output --partial "two"
}

# why: the same divergence one layer in, at the layer that actually
# partitions. This runner is reachable from the ENVIRONMENT as well as
# from the flag, so a leading zero the host parser never saw still gets
# here -- and here the two readings sit three lines apart: the launch loop
# counts `010` as octal 8 while `_shard_unit_files` passes it to awk as
# the decimal total 10. The refusal has to be here too, and it has to fire
# before anything is launched: 8 kcov processes over a 10-way partition
# produce reports that merge cleanly and certify a suite they never ran.
@test "_run_coverage_parallel: rejects a job count written with a leading zero" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel 010"
  assert_failure
  assert_output --partial "010"
  assert [ ! -f "${_log}" ]

  # By the refusal that names the INPUT. `010` also happens to trip the
  # empty-slice refusal on a five-spec pool -- 8 slices asked of a 10-bin
  # partition leave bins 6..10 empty -- and a run that dies there has been
  # told to use fewer jobs, which is the wrong repair for a number that
  # was read twice. On a pool of ten or more it would not die at all.
  assert_output --partial "ci_invalid_coverage_jobs"
  refute_output --partial "matched no spec files"
  refute_output --partial "fewer --jobs"
}

# why: the second refusal, and the one an operator reaches by accident --
# `nproc` on a big machine can exceed the spec count of a small tree, and
# then the tail slices match nothing. An empty slice is not a slice that
# ran nothing; it is a partition that never covered the tree, and merging
# what the non-empty slices produced would publish a fraction of the suite
# under a whole-suite certificate. It is checked BEFORE the first fork,
# because `_shard_unit_files` refuses by `_die` and a `_die` inside a
# background job exits the CHILD -- the parent would wait for a slice that
# never ran and then merge N-1 reports.
@test "_run_coverage_parallel: refuses more slices than the suite has specs" {
  local _root _log="${BATS_TEST_TMPDIR}/kcov.log"
  _root="$(_make_pool_root)"
  _install_kcov_mocks "${_log}"

  # The pool holds five spec files.
  run bash -c "$(_driver_prelude "${_root}")
_run_coverage_parallel 9"
  assert_failure
  assert_output --partial "matched no spec files"
  assert_output --partial "fewer --jobs"

  # And nothing was launched: no kcov ran, so there is no partial report
  # set for a later merge to find.
  assert [ ! -f "${_log}" ]
}

# ════════════════════════════════════════════════════════════════════
# The opt-in validation workflow
#
# Production `self-test.yaml` stays on the GitHub-hosted matrix: one
# self-hosted runner is a single point of failure and a contention point,
# so the local mode is deliberately NOT in the PR gate. Its CI exposure is
# a manually-triggered workflow.
# ════════════════════════════════════════════════════════════════════

# why: the scope limit, asserted rather than promised. A trigger other
# than `workflow_dispatch` would put a single shared workstation on the
# path of an automatic run -- which is the SPOF this mode was scoped away
# from. Read as a SET rather than as refusals of the two names anyone
# thought of: `push`, `repository_dispatch` and `workflow_call` are
# automatic triggers too, and nothing else in the tree would catch one --
# `self_hosted_guard.sh` reads a job's `if:`, never a workflow's `on:`.
@test "coverage-local workflow: is manually triggered only" {
  local _wf=/source/.github/workflows/coverage-local.yaml
  assert [ -f "${_wf}" ]

  # The EVENT keys of the `on:` block: the keys at the indentation of the
  # first one, so a filter (`branches:`, `types:`, `tags:`) nested under an
  # event is not read as an event of its own. The inline forms (`on: push`,
  # `on: [push]`) yield no keys, so they fail this as an empty set rather
  # than passing unread.
  run awk '
    /^on:/ { o = 1; next }
    /^[^[:space:]#]/ { o = 0 }
    o && $0 ~ /^[[:space:]]+[a-z_]+:/ {
      match($0, /^[[:space:]]+/)
      ind = RLENGTH
      k = $0
      sub(/^[[:space:]]+/, "", k)
      sub(/:.*$/, "", k)
      if (first == 0) { first = ind }
      if (ind == first) { print k }
    }
  ' "${_wf}"
  assert_success
  assert_output "workflow_dispatch"
}

# why: the concurrency group's stated property is one run at a time on the
# MACHINE -- two of these would each start nproc kcov processes on the same
# host and measure each other's contention rather than the mode. A group
# keyed on `github.ref` does not have that property: the normal way this
# gets used is a dispatch on the branch under test beside one on `main`,
# which is two refs, two groups, and one runner. Nothing about the machine
# is in the ref, so the group must not interpolate anything at all --
# `github.ref`, an input, or a matrix leg would each split it the same way.
@test "coverage-local workflow: one run at a time on the machine, not per ref (#726)" {
  local _wf=/source/.github/workflows/coverage-local.yaml
  assert [ -f "${_wf}" ]

  # The `concurrency:` block's own lines, comments dropped: the paragraph
  # above it states the property in prose and would answer for the key.
  run bash -c "
    sed '/^[[:space:]]*#/d' '${_wf}' \
      | awk '/^concurrency:/ { c = 1; next } /^[^[:space:]]/ { c = 0 } c'"
  assert_success
  assert_output --partial "group: coverage-local"
  refute_output --partial '${{'
  # A cancelled run is a half-finished kcov tree on a shared machine, so
  # queueing is the behaviour, not cancelling.
  assert_output --partial "cancel-in-progress: false"
}

# why: the runner is the point -- an in-job parallel mode measured on a
# hosted two-core runner would prove nothing about the fat machine it was
# written for. And a job that can land on the org's self-hosted runner is
# arbitrary code execution on a shared workstation unless it carries the
# fork guard, which is what `self-hosted-guard` enforces for every job in
# this tree. Read off the CODE, comments dropped: this file's header spends a
# paragraph on why one self-hosted runner is not a PR gate, so the words
# "self-hosted" are in it whatever the job runs on -- a whole-file read
# answers the question with the prose that explains the answer. That is the
# rule the sibling `self-test.yaml` case already applies to `runs-on:`.
@test "coverage-local workflow: runs on the self-hosted GPU runner behind the fork guard" {
  local _wf=/source/.github/workflows/coverage-local.yaml
  assert [ -f "${_wf}" ]

  run bash -c "sed '/^[[:space:]]*#/d' '${_wf}'"
  assert_success
  assert_output --partial "runs-on: [self-hosted, gpu]"
  assert_output --partial "github.event_name != 'pull_request'"
  assert_output --partial "github.event.pull_request.head.repo.full_name == github.repository"
}

# why: the workflow has to drive the MODE, through the same entry an
# operator uses. A validation job that called `--coverage` would be a
# second, slower way of running what CI already runs and would never
# exercise the merge this issue is about. Read as the SET of modes the
# workflow invokes, off the code, because two things would otherwise pass
# a broken file: the header comment names
# `test.sh --coverage-local` twice, so a whole-file `--partial` stays green
# after the run step is switched back to the serial mode; and there are TWO
# invocations (with and without `--jobs`), so a `--partial` over either one
# is satisfied by the other. A set has neither hole -- and the `--jobs`
# branch matters most, because `--jobs` on the serial mode is an invocation
# the entry refuses outright.
@test "coverage-local workflow: drives test.sh --coverage-local" {
  local _wf=/source/.github/workflows/coverage-local.yaml
  assert [ -f "${_wf}" ]

  run bash -c "
    sed '/^[[:space:]]*#/d' '${_wf}' \
      | grep -oE 'test\.sh --[a-z-]+' \
      | LC_ALL=C sort -u"
  assert_success
  assert_output "test.sh --coverage-local"
}

# why: production must be untouched. The acceptance criterion is explicit
# that the PR gate keeps the hosted matrix, and the cheapest way for that
# to rot is a job quietly added to self-test.yaml on the way past.
@test "self-test.yaml: the PR gate is unchanged -- no self-hosted runner, no local mode" {
  # `runs-on:` values, not the file's prose: the coverage-gate job's own
  # comment calls the floor gate "self-hosted" (meaning "not Codecov"), and
  # a whole-file grep would read that sentence as a runner.
  run bash -c "
    grep -E '^[[:space:]]*runs-on:' /source/.github/workflows/self-test.yaml \
      | sort -u"
  assert_success
  refute_output --partial "self-hosted"

  run bash -c "sed '/^[[:space:]]*#/d' /source/.github/workflows/self-test.yaml"
  assert_success
  refute_output --partial "--coverage-local"
}
