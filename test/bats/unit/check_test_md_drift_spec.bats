#!/usr/bin/env bats
#
# Unit tests for script/test/check_test_md_drift.sh (_check_test_md_drift) --
# the read-only validating twin of sync-doc-counts.sh. It re-derives the
# doc/test/*.md count figures from the specs (the same `grep -c '^@test'`
# source) and exits non-zero when the committed docs have drifted, so a PR
# that adds a @test without running `just test sync-docs` fails the gate
# instead of silently shipping stale counts.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  CHECK="/source/script/test/check_test_md_drift.sh"
}

@test "_check_test_md_drift: exits 0 on an in-sync tree (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_success
}

@test "_check_test_md_drift: exits non-zero and names the drifted doc on a stale count (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "unit.md"
}

@test "_check_test_md_drift: tolerates an empty acceptance level dir (count 0) (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/acceptance" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **1 tests**." "" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    printf "%s\n" "Acceptance specs under \`test/bats/acceptance/\`: **0 tests**." > "${root}/doc/test/acceptance.md"
    _check_test_md_drift "${root}"
  '
  assert_success
}
