#!/usr/bin/env bats
#
# Unit tests for script/test/sync-doc-counts.sh (_sync_doc_counts) -- the
# generator that derives the test-count figures in doc/test/*.md from the
# specs themselves (grep -c '^@test'), so the counts stop being hand-edited
# every PR. The check_test_md_drift.sh hook remains the validating safety net.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  GEN="/source/script/test/sync-doc-counts.sh"
}

@test "_sync_doc_counts: rewrites a stale ### heading to the real @test count (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **99 tests**." "" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "### test/bats/unit/x_spec.bats (3)"
}

@test "_sync_doc_counts: rewrites the per-type total to the sum of the headings (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **99 tests**." "" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**3 tests**"
  refute_output --partial "**99 tests**"
}

@test "_sync_doc_counts: is idempotent on an already-synced tree (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    a=$(cat "${root}/doc/test/unit.md")
    _sync_doc_counts "${root}"
    b=$(cat "${root}/doc/test/unit.md")
    [[ "${a}" == "${b}" ]] && echo IDEMPOTENT
  '
  assert_success
  assert_output --partial "IDEMPOTENT"
}
