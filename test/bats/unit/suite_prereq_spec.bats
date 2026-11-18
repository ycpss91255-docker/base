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
  run env HOST_UID=1000 HOST_GID=1000 "$@" FAKE_ROOT="${FAKE_ROOT}" bash -c '
    source /source/script/test/test.sh
    REPO_ROOT="${FAKE_ROOT}"
    _check_suite_prerequisites
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
