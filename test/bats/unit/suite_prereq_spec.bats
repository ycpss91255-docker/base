#!/usr/bin/env bats
#
# suite_prereq_spec.bats - a bare in-container run of the suite names what
# it is missing instead of failing tests that read as unrelated.
#
# The host-side `just test` supplies the prev-release fixture and the host
# ids before it starts a container. A bare container run (a bare docker
# run of the test-tools image, a hosted or self-hosted job that skips the
# host step) supplies neither, and the person running it saw sixteen
# previous-release tests and four compose tests fail one by one, well into
# the run, instead of one refusal before it (base#1423).

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

# why: `--bats-path` resolves its target as ${REPO_ROOT}/<path>, so every
# spelling that names the same file or directory runs the same specs.
# Whether the fixture is demanded has to follow the path bats will open,
# not its spelling: `./test/bats/integration/prev_release_upgrade_spec.bats`
# used to skip the fixture (and the host preparation) while bats ran it.
@test "prereq: every spelling of a path selecting the prev-release spec demands the fixture (base#1423)" {
  local _p
  for _p in \
      ./test/bats/integration/prev_release_upgrade_spec.bats \
      test/bats/integration/./prev_release_upgrade_spec.bats \
      test//bats/integration/prev_release_upgrade_spec.bats \
      test/bats/unit/../integration/prev_release_upgrade_spec.bats \
      ./test/bats/integration/ \
      ./test \
      ./; do
    _prereq_run BATS_FILE="${_p}"
    assert_failure
    assert_output --partial ".prev-release/tags.txt"
  done
}

# why: the normalisation must not widen the selection either: a path
# outside the integration directory still runs without the fixture.
@test "prereq: a path not selecting the prev-release spec needs no fixture (base#1423)" {
  local _p
  for _p in ./test/bats/unit/ test/bats/integration/../unit \
      ./test/bats/integration/apk_mirror_spec.bats; do
    _prereq_run BATS_FILE="${_p}"
    assert_success
    assert_output ""
  done
}

# why: a filter with no path (`--bats-filter` alone) runs bats over unit +
# integration and leaves the regex to bats, so the check cannot tell
# whether the regex selects a prev-release test. It demands the fixture
# whatever the regex, even one that matches no test at all. With a path
# given as well, the path alone decides. The docs state this rule, and
# this case pins it so a user can predict which filtered runs refuse.
@test "prereq: a filter with no path demands the fixture whatever its regex (base#1423)" {
  _prereq_run BATS_FILTER='^no test is titled this$'
  assert_failure
  assert_output --partial ".prev-release/tags.txt"
  _prereq_run BATS_FILE=./test/bats/unit/ BATS_FILTER='prev_release'
  assert_success
  assert_output ""
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

# why: the mirror case, and the one a HOST_UID-only check lets through:
# a run that set HOST_UID but not HOST_GID must still be refused.
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

# _isolated_checkout: a scratch checkout at FAKE_ROOT holding a copy of
# what sourcing test.sh needs. test.sh derives REPO_ROOT from its own
# location, so sourcing the copy resolves the root the way a real run does
# -- no stand-in for the check, and nothing in the mounted checkout (which
# may or may not carry a .prev-release) is read.
_isolated_checkout() {
  mkdir -p "${FAKE_ROOT}/script" "${FAKE_ROOT}/dist/script/docker"
  cp -r /source/script/test "${FAKE_ROOT}/script/"
  cp -r /source/dist/script/docker/lib "${FAKE_ROOT}/dist/script/docker/"
}

# _main_ci [VAR=value ...] -- [main args ...]: the in-container entry
# point, `main --ci <args>`, of the isolated checkout, with both host ids
# and every selector cleared (the assignments put back what a case
# supplies) and every phase runner replaced by a marker in PHASE_LOG.
# _check_suite_prerequisites is NOT replaced: its call from main, with
# the arguments main gives it, is what is under test.
_main_ci() {
  local -a _env=()
  while (( $# )) && [[ "$1" != "--" ]]; do
    _env+=("$1")
    shift
  done
  (( $# )) && shift
  _isolated_checkout
  PHASE_LOG="${BATS_TEST_TMPDIR}/phases.log"
  run env -u BATS_FILE -u BATS_FILTER -u BATS_UNIT_SHARD -u BATS_FRAGILE \
      -u BATS_INTEGRATION -u BATS_ONLY -u COVERAGE -u COVERAGE_PATH \
      -u COVERAGE_SHARD -u COVERAGE_LOCAL_JOBS -u SHARD_WEIGHTS_BLOB \
      -u LINT_ONLY -u LINT_TOOL -u LINT_GROUP -u HOST_UID -u HOST_GID \
      "${_env[@]}" ROOT="${FAKE_ROOT}" PHASE_LOG="${PHASE_LOG}" bash -c '
    source "${ROOT}/script/test/test.sh"
    if [[ "${REPO_ROOT}" != "$(cd -- "${ROOT}" && pwd -P)" ]]; then
      echo "REPO_ROOT=${REPO_ROOT} is not the isolated checkout"
      exit 99
    fi
    for _f in _run_all_lint_tools _run_lint_group _run_lint_tool \
        _run_tests _run_bats_path _run_unit_shard _run_bats_fragile \
        _run_integration_tests _run_coverage _run_coverage_parallel \
        _run_coverage_path _run_system _decode_shard_weights_blob; do
      eval "${_f}() { echo ${_f} >> \"\${PHASE_LOG}\"; }"
    done
    _fix_permissions() { :; }
    main --ci "$@"
  ' _ "$@"
}

# _seed_isolated_tags: the prev-release fixture, in the isolated checkout.
_seed_isolated_tags() {
  mkdir -p "${FAKE_ROOT}/.prev-release"
  printf 'v0.42.0\n' > "${FAKE_ROOT}/.prev-release/tags.txt"
}

# why: the check is only worth anything if the in-container dispatch runs
# it before any phase, against the checkout it is running in. The cases
# above call the function directly, so an entry point that stopped calling
# it, or called it on the wrong root, would still pass them all; this one
# drives `main --ci` of an isolated checkout, a bare container run of the
# whole suite with neither host id and no fixture.
@test "prereq: a bare main --ci refuses by name before any phase runs (base#1423)" {
  _main_ci --
  assert_failure
  assert_output --partial "ci_missing_prerequisite"
  assert_output --partial ".prev-release/tags.txt"
  assert_output --partial "HOST_UID"
  assert_output --partial "HOST_GID"
  assert [ ! -e "${PHASE_LOG}" ]
}

# why: the root main checks is the checkout it runs in. With the fixture
# and both ids supplied there, the whole-suite dispatch reaches its phase:
# a main that inspected any other root would be refused here.
@test "prereq: main --ci with everything supplied in its checkout runs the suite (base#1423)" {
  _seed_isolated_tags
  _main_ci HOST_UID=1000 HOST_GID=1000 --
  assert_success
  refute_output --partial "ci_missing_prerequisite"
  run cat "${PHASE_LOG}"
  assert_output --partial "_run_tests"
}

# why: the system exemption has to hold at the entry point, not only in
# the helper. A main that passed 0 instead of its --system flag would pass
# the helper-level case above while refusing every `just test system` run
# for a fixture that run never reads. Driven with both ids, no fixture.
@test "prereq: main --ci --system with no fixture reaches the system phase (base#1423)" {
  _main_ci HOST_UID=1000 HOST_GID=1000 -- --system
  assert_success
  refute_output --partial "ci_missing_prerequisite"
  run cat "${PHASE_LOG}"
  assert_output "_run_system"
}

# why: the exemption is for the fixture only. A main that skipped the
# check altogether for --system would pass the case above; with one id
# missing, the system dispatch must still be refused by that id's name
# before its phase runs. Each id is removed on its own.
@test "prereq: main --ci --system with a host id missing is refused before the system phase (base#1423)" {
  local _keep _drop
  for _drop in HOST_UID HOST_GID; do
    if [[ "${_drop}" == "HOST_UID" ]]; then _keep=HOST_GID; else _keep=HOST_UID; fi
    rm -f "${BATS_TEST_TMPDIR}/phases.log"
    _main_ci "${_keep}=1000" -- --system
    assert_failure
    assert_output --partial "ci_missing_prerequisite"
    assert_output --partial "${_drop}"
    assert [ ! -e "${PHASE_LOG}" ]
  done
}

# why: the coverage dispatches leave main through their own branches
# (COVERAGE_PATH, COVERAGE_LOCAL_JOBS, a shard, the serial run), and the
# coverage routing specs stand in for the check, so a main that skipped it
# on any one of those routes would pass them. Each route is driven here
# with HOST_GID missing and must be refused by that name before its
# runner starts.
@test "prereq: every coverage route of main --ci refuses a missing host id before its runner (base#1423)" {
  local _route
  _seed_isolated_tags
  for _route in "" COVERAGE_LOCAL_JOBS=4 COVERAGE_SHARD=1/3 \
      COVERAGE_PATH=test/bats/unit/ci_spec.bats; do
    rm -f "${BATS_TEST_TMPDIR}/phases.log"
    _main_ci HOST_UID=1000 COVERAGE=1 BATS_ONLY=1 ${_route} --
    assert_failure
    assert_output --partial "ci_missing_prerequisite"
    assert_output --partial "HOST_GID"
    assert [ ! -e "${PHASE_LOG}" ]
  done
}

# why: the fixture half on the coverage routes that run the prev-release
# spec: the whole-suite coverage run and a COVERAGE_PATH naming that spec
# are refused for tags.txt before their runner starts.
@test "prereq: a coverage route running the prev-release spec refuses a missing fixture (base#1423)" {
  local _route
  for _route in "" \
      COVERAGE_PATH=test/bats/integration/prev_release_upgrade_spec.bats; do
    rm -f "${BATS_TEST_TMPDIR}/phases.log"
    _main_ci HOST_UID=1000 HOST_GID=1000 COVERAGE=1 BATS_ONLY=1 ${_route} --
    assert_failure
    assert_output --partial ".prev-release/tags.txt"
    assert [ ! -e "${PHASE_LOG}" ]
  done
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
