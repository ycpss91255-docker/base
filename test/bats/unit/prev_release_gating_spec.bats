#!/usr/bin/env bats
#
# Unit tests for the released-tree fixture gate in script/test/test.sh.
#
# The fixture (.prev-release/, materialised host-side by
# script/test/prepare-prev-release.sh) is read by exactly ONE spec,
# test/bats/integration/prev_release_upgrade_spec.bats. Resolving it costs
# release tags, and on a shallow or tagless checkout a network fetch of
# them, so these tests pin WHO pays that cost: the dispatches that actually
# run that spec -- while keeping an unresolvable fixture FATAL for those,
# because a compatibility spec that quietly shrinks to zero cases is what
# the fixture exists to prevent.
#
# The unresolvable case is reproduced with a `git` mock that reports no
# tags and fails the fetch. That is exactly a `git clone --depth 1` with no
# tags on a machine that cannot reach the remote -- which is both the
# contributor case and what `actions/checkout` leaves behind in CI.
#
# Every dispatch here is driven through test.sh's REAL entry point (a
# subshell running the script, so its strict mode is armed) with `docker`
# mocked, so what the tests observe is whether a container was dispatched
# at all. It is driven through `_dispatch`, which clears the dispatch
# variables first: this suite RUNS inside a compose dispatch, which
# forwards every one of them into the container, so a child that inherited
# them would be running the harness's own mode rather than the flag under
# test.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  # Logs every docker invocation and succeeds: `docker image inspect`
  # reports the tooling image present (no build), and `docker compose run`
  # is the dispatch these tests are looking for.
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${DOCKER_LOG}"'"
    exit 0'
}

teardown() {
  cleanup_mock_dir
}

# A checkout with no release tags whose remote cannot be reached: `git tag
# --list` prints nothing and the fetch fails. Everything else git is asked
# succeeds silently, so nothing but the tag resolution is perturbed.
_mock_tagless_offline_git() {
  mock_cmd "git" '
    case " ${*} " in
      *" fetch "*) exit 1 ;;
    esac
    exit 0'
}

# Run test.sh with the flags under test and NOTHING inherited from the
# dispatch this suite is itself running under. `_run_via_compose` forwards
# all of these into the container, so BATS_FILE (say) is already set here
# and would out-rank the flag being exercised in the child -- in test.sh's
# dispatch and in the container's alike.
_dispatch() {
  _dispatch_with_blob "" "$@"
}

# _dispatch with SHARD_WEIGHTS_BLOB set to <blob>: the form a CI coverage
# shard runs in, where compute-shards' blob is ambient. Every other weights
# source is cleared too, because a coverage run of this suite has already
# decoded its own blob into SHARD_WEIGHTS_FILE (base#1433).
_dispatch_with_blob() {
  local _blob="${1}"
  shift
  run env \
    -u COVERAGE -u COVERAGE_SHARD -u COVERAGE_PATH \
    -u COVERAGE_LOCAL_JOBS -u COVERAGE_JOBS -u SHARD_WEIGHTS_FILE \
    -u BATS_ONLY -u BATS_UNIT_SHARD -u BATS_FRAGILE -u BATS_INTEGRATION \
    -u BATS_FILE -u BATS_FILTER \
    -u LINT_ONLY -u LINT_TOOL \
    SHARD_WEIGHTS_BLOB="${_blob}" \
    bash /source/script/test/test.sh "$@"
}

# The shard number, out of <total>, that the partition assigns the
# fixture-reading spec to. Asked of _shard_unit_files itself rather than
# assumed: its pool is test/bats/{unit,integration}/**, so an integration
# spec genuinely lands in one of the "unit" shards.
#
# [weights-file] is the weights the partition reads. Omitted, it is the
# checkout's test/bats/.shard-weights, which a --bats-unit-shard reads on
# both sides of the compose boundary. A coverage shard instead reads the
# blob the host forwards, so its callers pass the file that blob encodes,
# or an empty file for an empty blob (`@test` count).
_shard_carrying_prev_release() {
  local _total="${1}"
  local _wf="${2:-}"
  local _n
  for (( _n = 1; _n <= _total; _n++ )); do
    if SHARD_WEIGHTS_FILE="${_wf}" \
        bash -c "source /source/script/test/test.sh; _shard_unit_files '${_n}/${_total}'" \
        | grep -qxF /source/test/bats/integration/prev_release_upgrade_spec.bats; then
      printf '%s\n' "${_n}"
      return 0
    fi
  done
  return 1
}

# An empty weights file: what an empty SHARD_WEIGHTS_BLOB decodes to, and
# so the `@test`-count partition a coverage shard runs with no blob.
_empty_weights() {
  local _f="${BATS_TEST_TMPDIR}/empty.shard-weights"
  : > "${_f}"
  printf '%s\n' "${_f}"
}

# A weights file under which the 2-shard partition puts the fixture-reading
# spec in the OTHER shard from the `@test`-count partition (base#1433).
# Seconds dwarf every `@test` count, so the heaviest named spec takes shard
# 1 and the next takes shard 2: name the spec alone to put it in 1, or
# after a heavier spec to put it in 2.
_weights_moving_prev_release() {
  local _count_carrier="${1}"
  local _f="${BATS_TEST_TMPDIR}/moving.shard-weights"
  if [[ "${_count_carrier}" == "1" ]]; then
    printf '%s\n' \
      "2000000 test/bats/unit/ci_spec.bats" \
      "1000000 test/bats/integration/prev_release_upgrade_spec.bats" > "${_f}"
  else
    printf '%s\n' \
      "1000000 test/bats/integration/prev_release_upgrade_spec.bats" > "${_f}"
  fi
  printf '%s\n' "${_f}"
}

# ════════════════════════════════════════════════════════════════════
# Dispatches that run no spec reading the fixture must not pay for it
# ════════════════════════════════════════════════════════════════════

@test "prev-release gate: --bats-path over a unit spec dispatches with no release tags" {
  _mock_tagless_offline_git

  _dispatch --bats-path test/bats/unit/ci_spec.bats
  assert_success

  assert [ -f "${DOCKER_LOG}" ]
  run cat "${DOCKER_LOG}"
  assert_output --partial "BATS_FILE=test/bats/unit/ci_spec.bats"
}

@test "prev-release gate: --bats-fragile dispatches with no release tags" {
  _mock_tagless_offline_git

  _dispatch --bats-fragile
  assert_success

  assert [ -f "${DOCKER_LOG}" ]
  run cat "${DOCKER_LOG}"
  assert_output --partial "BATS_FRAGILE=1"
}

@test "prev-release gate: a shard that does not carry the spec dispatches with no release tags" {
  local _carrier
  _carrier="$(_shard_carrying_prev_release 2)"
  # Not an aside: with no carrier the sibling test below would assert a
  # failure that came from a malformed shard spec instead of the fixture.
  assert [ -n "${_carrier}" ]
  local _other=1
  if [[ "${_carrier}" == "1" ]]; then
    _other=2
  fi
  _mock_tagless_offline_git

  _dispatch --bats-unit-shard "${_other}/2"
  assert_success

  assert [ -f "${DOCKER_LOG}" ]
  run cat "${DOCKER_LOG}"
  assert_output --partial "BATS_UNIT_SHARD=${_other}/2"
}

@test "prev-release gate: --lint dispatches with no release tags" {
  _mock_tagless_offline_git

  _dispatch --lint --shellcheck
  assert_success

  assert [ -f "${DOCKER_LOG}" ]
  run cat "${DOCKER_LOG}"
  assert_output --partial "LINT_ONLY=1"
}

# ════════════════════════════════════════════════════════════════════
# Dispatches that DO run it still fail loudly, before any container
# ════════════════════════════════════════════════════════════════════

@test "prev-release gate: --bats-integration refuses to start when the tags cannot be resolved" {
  _mock_tagless_offline_git

  _dispatch --bats-integration
  assert_failure
  assert_output --partial "stable release tags"

  assert [ ! -f "${DOCKER_LOG}" ]
}

@test "prev-release gate: the shard that carries the spec refuses to start when the tags cannot be resolved" {
  local _carrier
  _carrier="$(_shard_carrying_prev_release 2 "$(_empty_weights)")"
  # An empty carrier would make the assertions below pass on a malformed
  # shard spec rather than on the fixture, so pin it first.
  assert [ -n "${_carrier}" ]
  _mock_tagless_offline_git

  _dispatch --coverage-shard "${_carrier}/2"
  assert_failure
  assert_output --partial "stable release tags"

  assert [ ! -f "${DOCKER_LOG}" ]
}

@test "prev-release gate: under kcov the shard out-ranks a leftover BATS_FILE" {
  local _carrier
  _carrier="$(_shard_carrying_prev_release 2 "$(_empty_weights)")"
  assert [ -n "${_carrier}" ]
  _mock_tagless_offline_git

  # The in-container kcov branch reads COVERAGE_SHARD and ignores BATS_FILE,
  # so a BATS_FILE left in the environment must not talk the host out of the
  # fixture either -- that is how the shard would run the spec with nothing
  # for it to read.
  run env \
    -u COVERAGE -u COVERAGE_PATH \
    -u COVERAGE_LOCAL_JOBS -u COVERAGE_JOBS -u SHARD_WEIGHTS_FILE \
    -u BATS_ONLY -u BATS_UNIT_SHARD -u BATS_FRAGILE -u BATS_INTEGRATION \
    -u BATS_FILTER -u LINT_ONLY -u LINT_TOOL \
    BATS_FILE=test/bats/unit/ci_spec.bats SHARD_WEIGHTS_BLOB="" \
    bash /source/script/test/test.sh --coverage-shard "${_carrier}/2"
  assert_failure
  assert_output --partial "stable release tags"

  assert [ ! -f "${DOCKER_LOG}" ]
}

@test "prev-release gate: --bats-path over the spec itself refuses to start when the tags cannot be resolved" {
  _mock_tagless_offline_git

  _dispatch \
    --bats-path test/bats/integration/prev_release_upgrade_spec.bats
  assert_failure
  assert_output --partial "stable release tags"

  assert [ ! -f "${DOCKER_LOG}" ]
}

# ════════════════════════════════════════════════════════════════════
# A coverage shard asks with the weights its container partitions by
# ════════════════════════════════════════════════════════════════════
#
# The container decodes the forwarded SHARD_WEIGHTS_BLOB and partitions by
# it, so the host's question "does this shard run the spec?" has to be
# asked of that same partition. Each test pins that the blob really moves
# the spec before relying on it.

# Sets _count_carrier, _blob_carrier and _weights for the tests below.
_setup_moving_weights() {
  _count_carrier="$(_shard_carrying_prev_release 2 "$(_empty_weights)")"
  assert [ -n "${_count_carrier}" ]
  _weights="$(_weights_moving_prev_release "${_count_carrier}")"
  _blob_carrier="$(_shard_carrying_prev_release 2 "${_weights}")"
  assert [ -n "${_blob_carrier}" ]
  assert [ "${_blob_carrier}" != "${_count_carrier}" ]
}

# why: the CI failure itself (base#1433): the shard compute-shards' blob
# hands the spec ran it with no .prev-release/ and failed every case. A
# gate that reads the checkout's weights passes every other test here.
@test "prev-release gate: the shard a CI weights blob gives the spec refuses to start when the tags cannot be resolved" {
  local _count_carrier _blob_carrier _weights
  _setup_moving_weights
  _mock_tagless_offline_git

  _dispatch_with_blob "$(base64 -w0 < "${_weights}")" \
    --coverage-shard "${_blob_carrier}/2"
  assert_failure
  assert_output --partial "stable release tags"

  assert [ ! -f "${DOCKER_LOG}" ]
}

# why: a local `--coverage-shard N/T --shard-weights` must reproduce CI's
# shard N/T fixture decision too, or the local repro of a CI shard
# diverges exactly where the CI form was fixed.
@test "prev-release gate: the shard a --shard-weights file gives the spec refuses to start when the tags cannot be resolved" {
  local _count_carrier _blob_carrier _weights
  _setup_moving_weights
  _mock_tagless_offline_git

  _dispatch --coverage-shard "${_blob_carrier}/2" --shard-weights "${_weights}"
  assert_failure
  assert_output --partial "stable release tags"

  assert [ ! -f "${DOCKER_LOG}" ]
}

# why: the converse pin. Without it a gate that always answers yes for a
# coverage shard would pass the two refusal tests above while every shard
# again pays a tag fetch for a spec it does not run.
@test "prev-release gate: a shard a CI weights blob takes the spec away from dispatches with no release tags" {
  local _count_carrier _blob_carrier _weights
  _setup_moving_weights
  _mock_tagless_offline_git

  _dispatch_with_blob "$(base64 -w0 < "${_weights}")" \
    --coverage-shard "${_count_carrier}/2"

  assert [ -f "${DOCKER_LOG}" ]
  run cat "${DOCKER_LOG}"
  assert_output --partial "COVERAGE_SHARD=${_count_carrier}/2"
}

# why: the converse pin for the local form; a gate that ignored
# --shard-weights and used the `@test` count would refuse here.
@test "prev-release gate: a shard a --shard-weights file takes the spec away from dispatches with no release tags" {
  local _count_carrier _blob_carrier _weights
  _setup_moving_weights
  _mock_tagless_offline_git

  _dispatch --coverage-shard "${_count_carrier}/2" --shard-weights "${_weights}"

  assert [ -f "${DOCKER_LOG}" ]
  run cat "${DOCKER_LOG}"
  assert_output --partial "COVERAGE_SHARD=${_count_carrier}/2"
}
