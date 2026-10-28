#!/usr/bin/env bats
#
# per_test_timeout_spec.bats -- every bats run the driver starts bounds each
# test, a test that outlives the bound fails BY NAME, and the outer layers
# (the CI kcov step, the local compose run) carry bounds of their own.
#
# why: Nothing in the repo set BATS_TEST_TIMEOUT, so one hung test was
# unbounded locally and, in CI, became a job-level cancellation that names
# no test (base#1413). The bound is a property of the DRIVER, not of a
# spec, so this spec runs the driver's real entries over a fixture tree and
# reads the value each fixture test actually saw -- in plain mode and under
# kcov, where tracing makes every test slower and the bound must be wider.
# A spec-text scan would pass a driver that sets the variable on one path
# and forgets another.
#
# The bound's knob is PER_TEST_TIMEOUT (seconds, plain mode); the driver
# derives the kcov bound from it. An INHERITED BATS_TEST_TIMEOUT is not
# the knob: a nested driver run (this spec, kcov_shard_concurrency_spec)
# inherits the outer run's value, which is the wrong mode's value.

bats_require_minimum_version 1.5.0

# _make_fixture <root>
#   A repo-shaped tree whose every spec records the BATS_TEST_TIMEOUT its
#   test saw: one line `<PROBE_TAG> <spec> <value>` appended to
#   ${PROBE_LOG}. One unit spec, one integration spec, and one unit spec
#   carrying the kcov-fragile guard so _run_bats_fragile selects it (the
#   guard falls through: COVERAGE is unset in every run below).
_make_fixture() {
  local _root="${1}" _name _dir
  mkdir -p "${_root}/test/bats/unit" "${_root}/test/bats/integration" \
           "${_root}/coverage"
  for _name in unit/probe_a_spec.bats integration/probe_b_spec.bats \
               unit/probe_fragile_spec.bats; do
    _dir="${_root}/test/bats/${_name}"
    # The test line is printed, not written in a here-doc, so no line of
    # THIS file starts with the test keyword except its own tests.
    {
      printf '@test "probe %s" {\n' "${_name##*/}"
      if [[ "${_name}" == *fragile* ]]; then
        # shellcheck disable=SC2016
        printf '%s\n' '  [ "${COVERAGE:-0}" = 1 ] && skip "kcov-fragile probe"'
      fi
      # shellcheck disable=SC2016
      printf '%s\n' '  printf "%s %s %s\n" "${PROBE_TAG}" "${BATS_TEST_FILENAME##*/}" "${BATS_TEST_TIMEOUT:-unset}" >> "${PROBE_LOG}"'
      printf '}\n'
    } > "${_dir}"
  done
}

# _make_sleeper <root>
#   A tree with one spec: a test that sleeps far past any bound this spec
#   sets, beside one that passes, so the report has a name to get right.
_make_sleeper() {
  local _root="${1}"
  mkdir -p "${_root}/test/bats/unit" "${_root}/test/bats/integration" \
           "${_root}/coverage"
  {
    printf '@test "fixture neighbour passes" {\n  :\n}\n'
    printf '@test "fixture sleeper outlives its timeout" {\n  sleep 40\n}\n'
  } > "${_root}/test/bats/unit/sleeper_spec.bats"
}

# _driver <root> <log> <tag> <entry...>
#   Run one driver entry against the fixture tree at <root>. `env -u`
#   keeps an OUTER bats' timeout and an outer kcov's instrumentation (when
#   this spec itself runs under `just test coverage`) out of the nested run;
#   the caller adds its own PER_TEST_TIMEOUT / BATS_TEST_TIMEOUT through
#   DRIVER_ENV.
_driver() {
  local _root="${1}" _log="${2}" _tag="${3}"
  shift 3
  env -u BASH_ENV -u BASH_XTRACEFD -u KCOV_BASH_XTRACEFD -u LD_PRELOAD \
    -u BATS_TEST_TIMEOUT -u PER_TEST_TIMEOUT -u COVERAGE \
    -u BATS_FILE -u BATS_FILTER -u SHARD_WEIGHTS_FILE \
    -u COVERAGE_LOCAL_WORKDIR \
    REPO_ROOT="${_root}" PROBE_LOG="${_log}" PROBE_TAG="${_tag}" \
    "${DRIVER_ENV[@]}" \
    bash -c '
      _die() { echo "DIE: $*"; exit 1; }
      source /source/script/test/drivers/bats.sh
      "$@"
    ' _ "$@"
}

# _probe <tag> <entry...>
#   Run one entry over a fresh probe fixture and print the values its
#   tests saw, one per line, sorted and de-duplicated. Fails with the
#   driver's output when the run itself fails.
_probe() {
  local _tag="${1}"
  shift
  local _root="${BATS_TEST_TMPDIR}/${_tag}"
  _make_fixture "${_root}"
  local _rc=0
  _driver "${_root}" "${_root}/probe.log" "${_tag}" "$@" \
    > "${_root}/driver.out" 2>&1 || _rc=$?
  if (( _rc != 0 )) || [[ ! -s "${_root}/probe.log" ]]; then
    echo "driver entry '$*' exited ${_rc}; output:"
    cat "${_root}/driver.out"
    return 1
  fi
  awk '{ print $3 }' "${_root}/probe.log" | LC_ALL=C sort -u
}

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject /source/script/test/drivers/bats.sh \
    "the test driver whose bats runs this spec bounds"
  DRIVER_ENV=()
}

# _plain_entries / _kcov_entries
#   Every driver entry that starts bats, split by whether kcov wraps it.
#   Each line is the entry and its arguments.
_plain_entries() {
  printf '%s\n' \
    "_run_unit_tests" \
    "_run_integration_tests" \
    "_run_tests" \
    "_run_bats_path_file" \
    "_run_unit_shard 1/1" \
    "_run_bats_fragile"
}

_kcov_entries() {
  printf '%s\n' \
    "_run_coverage_path test/bats/unit" \
    "_run_coverage 1/1" \
    "_run_coverage_parallel 1"
}

# _entry_values <tag-prefix> <entry-line>
#   _probe for one roster line; `_run_bats_path_file` stands for
#   _run_bats_path with BATS_FILE naming the unit directory.
_entry_values() {
  local _tag="${1}" _line="${2}"
  local -a _argv
  read -r -a _argv <<< "${_line}"
  if [[ "${_argv[0]}" == "_run_bats_path_file" ]]; then
    DRIVER_ENV+=(BATS_FILE=test/bats/unit)
    _argv[0]=_run_bats_path
  fi
  _probe "${_tag}-${_argv[0]}" "${_argv[@]}"
}

# _one_value <values>
#   Print the single positive integer a run's tests all saw, or print what
#   they saw instead and return 1. It returns rather than calling `fail`:
#   it runs inside `$(...) || fail`, where errexit is off, so a `fail` in
#   here would not stop it from printing the value anyway.
_one_value() {
  local _values="${1}" _what="${2}"
  if [[ "${_values}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "${_values}"
    return 0
  fi
  printf '%s\n' "${_what}: its tests saw BATS_TEST_TIMEOUT '$(printf '%s' "${_values}" | tr '\n' ' ')', expected one positive integer for every test (base#1413)."
  return 1
}

# why: The bound has to hold on EVERY path that starts bats, not on the
# one a reader happened to check: a plain path left unbounded is the
# local hang the issue names. Every plain entry's tests see the same
# positive integer, with nothing in the caller's environment setting it.
@test "per-test timeout: every plain-mode driver entry runs its tests under one positive BATS_TEST_TIMEOUT" {
  local _line _values _v _first=""
  while IFS= read -r _line; do
    DRIVER_ENV=()
    _values="$(_entry_values plain "${_line}")" || fail "${_values}"
    _v="$(_one_value "${_values}" "plain entry '${_line}'")" || fail "${_v}"
    [[ -n "${_first}" ]] || _first="${_v}"
    [[ "${_v}" == "${_first}" ]] || \
      fail "plain entry '${_line}' bounds a test at ${_v} s, another plain entry at ${_first} s; the bound has one home (base#1413)."
  done < <(_plain_entries)
}

# why: kcov traces every line, so a test is slower under it and a bound
# sized for plain mode would fail a healthy test. Every kcov entry's tests
# see one positive integer, wider than the plain bound.
@test "per-test timeout: every kcov driver entry runs its tests under one BATS_TEST_TIMEOUT wider than plain mode's" {
  command -v kcov >/dev/null || \
    fail "no kcov in this image -- the coverage instrument whose bound this test reads is missing."
  local _plain _line _values _v _first=""
  _plain="$(_entry_values plain "_run_unit_tests")" || fail "${_plain}"
  _plain="$(_one_value "${_plain}" "plain entry _run_unit_tests")" || fail "${_plain}"
  while IFS= read -r _line; do
    DRIVER_ENV=()
    _values="$(_entry_values kcov "${_line}")" || fail "${_values}"
    _v="$(_one_value "${_values}" "kcov entry '${_line}'")" || fail "${_v}"
    [[ -n "${_first}" ]] || _first="${_v}"
    [[ "${_v}" == "${_first}" ]] || \
      fail "kcov entry '${_line}' bounds a test at ${_v} s, another kcov entry at ${_first} s (base#1413)."
    (( _v > _plain )) || \
      fail "kcov entry '${_line}' bounds a test at ${_v} s, no wider than plain mode's ${_plain} s (base#1413)."
  done < <(_kcov_entries)
}

# why: A nested driver run inherits the OUTER bats' BATS_TEST_TIMEOUT, and
# an outer plain run's value is the wrong one for a nested kcov run. The
# driver sets the bound from its own knob, PER_TEST_TIMEOUT, in both modes.
@test "per-test timeout: PER_TEST_TIMEOUT sets the plain bound and an inherited BATS_TEST_TIMEOUT does not" {
  local _values _default
  _default="$(_entry_values plain "_run_unit_tests")" || fail "${_default}"
  _default="$(_one_value "${_default}" "plain entry _run_unit_tests")" || fail "${_default}"

  DRIVER_ENV=(BATS_TEST_TIMEOUT=7777)
  _values="$(_probe inherited _run_unit_tests)" || fail "${_values}"
  [[ "${_values}" == "${_default}" ]] || \
    fail "with BATS_TEST_TIMEOUT=7777 inherited, the plain run's tests saw '${_values}', not the driver's ${_default} (base#1413)."

  DRIVER_ENV=(PER_TEST_TIMEOUT=5)
  _values="$(_probe knob _run_unit_tests)" || fail "${_values}"
  [[ "${_values}" == "5" ]] || \
    fail "with PER_TEST_TIMEOUT=5, the plain run's tests saw '${_values}', expected 5 (base#1413)."
}

# _sleeper <tag> <entry...>
#   Run one entry over the sleeper fixture with PER_TEST_TIMEOUT=2 and
#   leave its status in SLEEPER_RC, its output in SLEEPER_OUT and its
#   wall time in SLEEPER_SECONDS.
_sleeper() {
  local _tag="${1}"
  shift
  local _root="${BATS_TEST_TMPDIR}/${_tag}"
  _make_sleeper "${_root}"
  DRIVER_ENV=(PER_TEST_TIMEOUT=2)
  local _start="${SECONDS}"
  SLEEPER_RC=0
  _driver "${_root}" "${_root}/probe.log" "${_tag}" "$@" \
    > "${_root}/driver.out" 2>&1 || SLEEPER_RC=$?
  SLEEPER_SECONDS=$(( SECONDS - _start ))
  SLEEPER_OUT="$(cat "${_root}/driver.out")"
}

# _assert_sleeper_named <mode>
#   The run failed, inside the bound rather than after the 40 s sleep, and
#   its report names the sleeping test as the failure and the neighbour as
#   a pass.
_assert_sleeper_named() {
  local _mode="${1}"
  (( SLEEPER_RC != 0 )) || \
    fail "${_mode}: a test that sleeps 40 s under PER_TEST_TIMEOUT=2 passed after ${SLEEPER_SECONDS} s -- no per-test bound applied (base#1413). Output:
${SLEEPER_OUT}"
  (( SLEEPER_SECONDS < 30 )) || \
    fail "${_mode}: the run took ${SLEEPER_SECONDS} s; a test was allowed to sleep its full 40 s (base#1413)."
  run printf '%s\n' "${SLEEPER_OUT}"
  assert_line --regexp '^not ok [0-9]+ fixture sleeper outlives its timeout'
  assert_line --regexp '^ok [0-9]+ fixture neighbour passes'
}

# why: The point of the bound is the REPORT: a hang must end as a failure
# that names the test, where today it ends as a job cancellation that
# names nothing (base#1413).
@test "per-test timeout: a plain-mode test that outlives the bound fails and is reported by name" {
  DRIVER_ENV=()
  _sleeper sleep-plain _run_unit_tests
  _assert_sleeper_named "plain _run_unit_tests"
}

@test "per-test timeout: a kcov-mode test that outlives the bound fails and is reported by name" {
  command -v kcov >/dev/null || \
    fail "no kcov in this image -- the coverage instrument whose bound this test reads is missing."
  _sleeper sleep-kcov _run_coverage_path test/bats/unit/sleeper_spec.bats
  _assert_sleeper_named "kcov _run_coverage_path"
}

# ── the outer bounds ──────────────────────────────────────────────────────

# _step_timeout <workflow> <job> <step-name-regex>
#   The step-level timeout-minutes of the one step in <job> whose name
#   matches, or `null`.
_step_timeout() {
  _yaml_eval "${1}" ".jobs.\"${2}\".steps[] | select(.name | test(\"${3}\")) | .\"timeout-minutes\""
}

# why: The job bound is the last resort, and when it fires GitHub cancels
# the job and names no step. A step bound below it turns a hang the
# per-test bound missed (a stuck kcov merge, a wedged container) into a
# failed STEP, with the step's log intact, before the job is cancelled.
@test "per-test timeout: each CI kcov step carries a timeout-minutes below its job's bound" {
  local _wf _job _re _step _jobt _bad=""
  while IFS='|' read -r _wf _job _re; do
    assert_spec_subject "/source/.github/workflows/${_wf}" "the workflow running a kcov step"
    _step="$(_step_timeout "/source/.github/workflows/${_wf}" "${_job}" "${_re}")" || fail "${_step}"
    _jobt="$(_yaml_eval "/source/.github/workflows/${_wf}" ".jobs.\"${_job}\".\"timeout-minutes\"")" || fail "${_jobt}"
    [[ "${_jobt}" =~ ^[1-9][0-9]*$ ]] || \
      fail "${_wf} job ${_job}: job timeout-minutes is '${_jobt}', expected a positive integer."
    if ! [[ "${_step}" =~ ^[1-9][0-9]*$ ]]; then
      _bad+="${_wf} job ${_job}: the kcov step /${_re}/ has timeout-minutes '${_step}', expected a positive integer below the job's ${_jobt} (base#1413)."$'\n'
    elif (( _step >= _jobt )); then
      _bad+="${_wf} job ${_job}: the kcov step's ${_step} min is not below the job's ${_jobt} min, so the job is cancelled first and names no step (base#1413)."$'\n'
    fi
  done <<'ROSTER'
self-test.yaml|coverage|^Run kcov coverage shard
coverage-local.yaml|coverage-local|^Run the full suite as parallel kcov processes
ROSTER
  [[ -z "${_bad}" ]] || fail "${_bad}"
}

# why: Locally there is no job bound at all: `just test` and `just test
# coverage` run the suite in `docker compose run --rm`, and a hang there
# blocks the terminal forever. The compose run goes through `timeout`, in
# both the ci and the coverage dispatch.
@test "per-test timeout: the local compose run of the suite is wrapped in timeout, ci and coverage" {
  create_mock_dir
  local _cmd _path
  for _cmd in grep date cat printf sha256sum cut; do
    _path="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_path}" "${MOCK_DIR}/${_cmd}"
  done
  local _log="${BATS_TEST_TMPDIR}/calls.log"
  mock_cmd "docker" '
    printf "docker %s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'
  # A transparent timeout: log the bound, then run the command it wraps.
  mock_cmd "timeout" '
    printf "timeout %s\n" "$*" >> "'"${_log}"'"
    while (( $# > 0 )); do
      case "$1" in
        -k|-s) shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    shift
    exec "$@"'

  local _service _cov
  for _service in "ci 0" "coverage 1"; do
    : > "${_log}"
    read -r _service _cov <<< "${_service}"
    run bash -c '
      source /source/script/test/test.sh
      export PATH="'"${MOCK_DIR}"'"
      _run_via_compose '"${_service} ${_cov}"'
    '
    assert_success
    run cat "${_log}"
    # The compose run happened, and it happened under timeout.
    assert_line --regexp "^docker compose .* run --rm .* ${_service}\$"
    assert_line --regexp "^timeout (.* )?[1-9][0-9]*[smhd]? docker compose .* run --rm .* ${_service}\$"
  done
  cleanup_mock_dir
}
