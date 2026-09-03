#!/usr/bin/env bats
#
# Shared build-time smoke: the "does it even come up" baseline that runs
# inside EVERY Dockerfile `-test` stage (devel-test and runtime-test),
# so it must only assert things present in every real stage under test.
# It therefore avoids /lint (populated only in devel-test) and touches
# just the universal surface: both halves of the installed entrypoint +
# bash on PATH.
#
# Both halves, because the entry point is two files (ADR-00000030): the
# base-owned orchestrator at /usr/local/lib/base/entrypoint.sh is what the
# Dockerfile names as ENTRYPOINT, and it SOURCES the repo-owned bringup at
# /entrypoint.sh. Asserting only the bringup left the file the image
# actually starts -- and the runtime-dir COPY that installs it -- pinned by
# nothing, so dropping it produced a container that would not start and a
# green build.
#
# Loaded together with the shared test_helper.bash (both live under
# smoke/shared/ and are COPYed into /smoke_test/ by each `-test` stage).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "the base entrypoint orchestrator is installed and executable" {
  assert_file_exists /usr/local/lib/base/entrypoint.sh
  assert [ -x /usr/local/lib/base/entrypoint.sh ]
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}
