#!/usr/bin/env bats
#
# suite_prereq_spec.bats - a bare in-container run of the suite names what
# it is missing instead of failing tests that read as unrelated.
#
# The host-side `just test` supplies the prev-release fixture and the host
# ids before it starts a container. A bare container run (a bare docker
# run of the test-tools image, a hosted or self-hosted job that skips the
# host step) supplies neither, and the person running it saw sixteen
# previous-release tests and four compose tests fail with nothing naming
# the cause (base#1423).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  FAKE_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "${FAKE_ROOT}"
}

# _prereq_run <env assignments...>: run the in-container prerequisite check
# against FAKE_ROOT, with HOST_UID / HOST_GID present unless the caller
# overrides them, and the plain-bats dispatch (no BATS_FILE / shard).
_prereq_run() {
  # The selectors are cleared: this spec is itself run under one (a
  # BATS_FILE naming it), and the check replays the ambient dispatch.
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u COVERAGE -u COVERAGE_PATH -u COVERAGE_SHARD -u LINT_ONLY \
      HOST_UID=1000 HOST_GID=1000 "$@" FAKE_ROOT="${FAKE_ROOT}" bash -c '
    source /source/script/test/test.sh
    _check_suite_prerequisites "${FAKE_ROOT}"
  '
}

# why: a bare container run of the whole suite reaches the 16 previous-
# release tests with no .prev-release/tags.txt (that file is produced on
# the host by prepare-prev-release.sh). The run has to stop at once and
# name the file, not fail those tests one by one.
@test "prereq: a missing .prev-release/tags.txt is refused by name (base#1423)" {
  _prereq_run
  assert_failure
  assert_output --partial ".prev-release/tags.txt"
}

# _seed_tags: the prev-release fixture the host step would have produced.
_seed_tags() {
  mkdir -p "${FAKE_ROOT}/.prev-release"
  printf 'v0.42.0\n' > "${FAKE_ROOT}/.prev-release/tags.txt"
}

# why: with the fixture and both host ids present the check is silent and
# succeeds, so a refusal is never the price of a correctly supplied run.
@test "prereq: everything supplied passes (base#1423)" {
  _seed_tags
  _prereq_run
  assert_success
  assert_output ""
}

# why: prepare-prev-release.sh writes tags.txt empty on purpose when no
# stable release falls inside the window (base#1055), and the prev-release
# spec only needs the file to exist. An empty file means "no release owed",
# not "fixture missing", so it must not be refused.
@test "prereq: an empty .prev-release/tags.txt (no release owed) passes (base#1423)" {
  mkdir -p "${FAKE_ROOT}/.prev-release"
  : > "${FAKE_ROOT}/.prev-release/tags.txt"
  _prereq_run
  assert_success
  refute_output --partial "ci_missing_prerequisite"
  refute_output --partial "tags.txt"
}

# why: the four compose tests need HOST_UID and HOST_GID (compose
# interpolates them with a required-variable form). A bare container has
# neither, and the check must say so by variable name rather than let the
# compose tests fail one by one.
@test "prereq: missing HOST_UID and HOST_GID are each named (base#1423)" {
  _seed_tags
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u COVERAGE -u COVERAGE_PATH -u COVERAGE_SHARD -u LINT_ONLY \
      -u HOST_UID -u HOST_GID FAKE_ROOT="${FAKE_ROOT}" bash -c '
    source /source/script/test/test.sh
    _check_suite_prerequisites "${FAKE_ROOT}"
  '
  assert_failure
  assert_output --partial "HOST_UID"
  assert_output --partial "HOST_GID"
}

# _one_id_missing <unset-var> <system>: the check with the fixture seeded,
# one host id removed and the other supplied.
_one_id_missing() {
  _seed_tags
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u COVERAGE -u COVERAGE_PATH -u COVERAGE_SHARD -u LINT_ONLY \
      HOST_UID=1000 HOST_GID=1000 DROP="${1}" \
      FAKE_ROOT="${FAKE_ROOT}" SYSTEM="${2}" bash -c '
    unset "${DROP}"
    source /source/script/test/test.sh
    _check_suite_prerequisites "${FAKE_ROOT}" "${SYSTEM}"
  '
}

# why: each id is its own requirement. Unsetting both together would let a
# check that only looks at HOST_UID (and names both) pass, while a run
# missing only HOST_GID got through; each is removed on its own here, with
# the other supplied, on both the plain and the system dispatch.
@test "prereq: HOST_UID alone missing is refused by that name (base#1423)" {
  local _sys
  for _sys in 0 1; do
    _one_id_missing HOST_UID "${_sys}"
    assert_failure
    assert_output --partial "HOST_UID"
    refute_output --partial "HOST_GID"
  done
}

@test "prereq: HOST_GID alone missing is refused by that name (base#1423)" {
  local _sys
  for _sys in 0 1; do
    _one_id_missing HOST_GID "${_sys}"
    assert_failure
    assert_output --partial "HOST_GID"
    refute_output --partial "HOST_UID"
  done
}

# why: a person fixing a bare run should not have to rerun once per missing
# item; every gap is reported in the one refusal.
@test "prereq: every missing item is reported in a single refusal (base#1423)" {
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u COVERAGE -u COVERAGE_PATH -u COVERAGE_SHARD -u LINT_ONLY \
      -u HOST_UID -u HOST_GID FAKE_ROOT="${FAKE_ROOT}" bash -c '
    source /source/script/test/test.sh
    _check_suite_prerequisites "${FAKE_ROOT}"
  '
  assert_failure
  assert_output --partial ".prev-release/tags.txt"
  assert_output --partial "HOST_UID"
  assert_output --partial "HOST_GID"
}

# why: `just test system` and the System Test CI job run ci-system without
# the prev-release step, so the system dispatch never reads tags.txt. It
# must not be refused for it (HOST_UID / HOST_GID stay required).
@test "prereq: the system dispatch needs no .prev-release/tags.txt (base#1423)" {
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u COVERAGE -u COVERAGE_PATH -u COVERAGE_SHARD -u LINT_ONLY \
      HOST_UID=1000 HOST_GID=1000 FAKE_ROOT="${FAKE_ROOT}" bash -c '
    source /source/script/test/test.sh
    _check_suite_prerequisites "${FAKE_ROOT}" 1
  '
  assert_success
  assert_output ""
}

# why: the check is only worth anything if the in-container dispatch runs
# it before any phase. The cases above call the function directly, so an
# entry point that stopped calling it would still pass them all; this one
# drives `main --ci` itself, a bare container run of the whole suite with
# neither host id and no fixture, and every phase stubbed to a marker.
@test "prereq: a bare main --ci refuses by name before any phase runs (base#1423)" {
  local _log="${BATS_TEST_TMPDIR}/phases.log"
  # The selectors are cleared so this is the plain whole-suite dispatch,
  # not the one this spec itself is running under.
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u BATS_INTEGRATION -u BATS_ONLY -u COVERAGE -u COVERAGE_PATH \
      -u COVERAGE_SHARD -u COVERAGE_LOCAL_JOBS -u LINT_ONLY -u LINT_TOOL \
      -u LINT_GROUP -u HOST_UID -u HOST_GID \
      FAKE_ROOT="${FAKE_ROOT}" PHASE_LOG="${_log}" bash -c '
    source /source/script/test/test.sh
    # REPO_ROOT is readonly and is the real checkout, which may or may not
    # carry a .prev-release; the real check is kept and only pointed at the
    # empty scratch tree, so the call from main is what is under test.
    eval "$(declare -f _check_suite_prerequisites \
      | sed "1s/_check_suite_prerequisites/_real_check_suite_prerequisites/")"
    _check_suite_prerequisites() { _real_check_suite_prerequisites "${FAKE_ROOT}" "${2:-0}"; }
    _run_all_lint_tools() { echo lint >> "${PHASE_LOG}"; }
    _run_tests()          { echo bats >> "${PHASE_LOG}"; }
    _run_coverage()       { echo coverage >> "${PHASE_LOG}"; }
    _run_system()         { echo system >> "${PHASE_LOG}"; }
    _fix_permissions()    { :; }
    main --ci
  '
  assert_failure
  assert_output --partial ".prev-release/tags.txt"
  assert_output --partial "HOST_UID"
  assert_output --partial "HOST_GID"
  assert [ ! -e "${_log}" ]
}

# why: the system exemption has to hold at the entry point, not only in
# the helper. A main that passed 0 instead of its --system flag would pass
# the helper-level case above while refusing every `just test system` run
# for a fixture that run never reads. Driven with both ids, no fixture.
@test "prereq: main --ci --system with no fixture reaches the system phase (base#1423)" {
  local _log="${BATS_TEST_TMPDIR}/phases.log"
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u BATS_INTEGRATION -u BATS_ONLY -u COVERAGE -u COVERAGE_PATH \
      -u COVERAGE_SHARD -u COVERAGE_LOCAL_JOBS -u LINT_ONLY -u LINT_TOOL \
      -u LINT_GROUP HOST_UID=1000 HOST_GID=1000 \
      FAKE_ROOT="${FAKE_ROOT}" PHASE_LOG="${_log}" bash -c '
    source /source/script/test/test.sh
    eval "$(declare -f _check_suite_prerequisites \
      | sed "1s/_check_suite_prerequisites/_real_check_suite_prerequisites/")"
    _check_suite_prerequisites() { _real_check_suite_prerequisites "${FAKE_ROOT}" "${2:-0}"; }
    _run_all_lint_tools() { echo lint >> "${PHASE_LOG}"; }
    _run_tests()          { echo bats >> "${PHASE_LOG}"; }
    _run_coverage()       { echo coverage >> "${PHASE_LOG}"; }
    _run_system()         { echo system >> "${PHASE_LOG}"; }
    _fix_permissions()    { :; }
    main --ci --system
  '
  assert_success
  refute_output --partial "ci_missing_prerequisite"
  run cat "${_log}"
  assert_output "system"
}

# why: the system exemption covers the fixture only; the host ids are
# still demanded.
@test "prereq: the system dispatch still requires HOST_UID and HOST_GID (base#1423)" {
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u COVERAGE -u COVERAGE_PATH -u COVERAGE_SHARD -u LINT_ONLY \
      -u HOST_UID -u HOST_GID FAKE_ROOT="${FAKE_ROOT}" bash -c '
    source /source/script/test/test.sh
    _check_suite_prerequisites "${FAKE_ROOT}" 1
  '
  assert_failure
  assert_output --partial "HOST_UID"
  refute_output --partial "tags.txt"
}
