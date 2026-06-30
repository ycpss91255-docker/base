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

@test "_sync_doc_counts: rewrites the system per-type total from test/bats/system/ (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/system" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/system/x_spec.bats"
    printf "%s\n" "System specs under \`test/bats/system/\`: **99 tests**." > "${root}/doc/test/system.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/system.md"
  '
  assert_success
  assert_output --partial "**2 tests**"
  refute_output --partial "**99 tests**"
}

@test "_sync_doc_counts: tolerates an empty acceptance dir (count 0, no error) (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/acceptance" "${root}/doc/test"
    printf "%s\n" "Acceptance specs under \`test/bats/acceptance/\`: **7 tests**." > "${root}/doc/test/acceptance.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/acceptance.md"
  '
  assert_success
  assert_output --partial "**0 tests**"
  refute_output --partial "**7 tests**"
}

@test "_sync_test_md_index: fills the system + acceptance rows, retires behavioural (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/integration" \
             "${root}/test/bats/system" "${root}/test/bats/acceptance" \
             "${root}/dist/test/smoke" "${root}/doc/test"
    printf "@test \"u\" {\n:\n}\n" > "${root}/test/bats/unit/u_spec.bats"
    printf "@test \"i\" {\n:\n}\n" > "${root}/test/bats/integration/i_spec.bats"
    printf "@test \"s1\" {\n:\n}\n@test \"s2\" {\n:\n}\n@test \"s3\" {\n:\n}\n" > "${root}/test/bats/system/s_spec.bats"
    {
      echo "| Doc | Scope | Count |"
      echo "| [unit.md](unit.md) | unit | 0 |"
      echo "| [integration.md](integration.md) | integration | 0 |"
      echo "| [system.md](system.md) | system | 0 |"
      echo "| [acceptance.md](acceptance.md) | acceptance | 0 |"
      echo "| [smoke.md](smoke.md) | smoke | 0 |"
    } > "${root}/doc/test/TEST.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/TEST.md"
  '
  assert_success
  assert_output --partial "[system.md](system.md) | system | 3 "
  assert_output --partial "[acceptance.md](acceptance.md) | acceptance | 0 "
}
