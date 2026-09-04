#!/usr/bin/env bats
#
# Unit tests for script/test/check_test_md_drift.sh (_check_test_md_drift).
#
# why: The read-only validating twin of `sync-doc-counts.sh`. It runs THAT
# generator against a throwaway copy and diffs, so "byte-identical to what
# is committed" is the whole gate and the validator cannot drift from the
# generator. Covers the in-sync / drifted verdicts -- including a deleted
# `# why:` block, which is the edit the catalogue is now the only place to
# notice -- and the unusable-scan-root guards that keep the gate from
# passing vacuously (relative root, missing root, no `doc/test/`, no
# specs).
#
# The in-sync fixtures are BUILT BY THE GENERATOR rather than typed out.
# Hand-writing what a generator emits is the habit this change exists to
# end, and a fixture that only happens to match today would make every case
# here fail on the next formatting change for a reason none of them is
# about.

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
    printf "%s\n" "# why: described" "@test \"a\" {" ":" "}" "@test \"b\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    _check_test_md_drift "${root}"
  '
  assert_success
}

@test "_check_test_md_drift: exits non-zero and names the drifted doc on a stale count (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    printf "%s\n" "@test \"a\" {" ":" "}" "@test \"b\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "unit.md"
}

# why: THE case this change adds to the gate. A description now lives in
# one place, so deleting it has to be visible somewhere -- and the
# catalogue is that somewhere: the row falls back to `-` while the
# committed one still carries prose, and the drift diff fires. Without
# this, the one edit that silently empties the catalogue would be the one
# edit nothing checks.
@test "_check_test_md_drift: FAILS when a '# why:' block is deleted from a spec" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: the sentence that is about to go" "@test \"a\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "the sentence that is about to go"
}

# why: The ceiling became a generated figure (base#1024), and a gate that
# compared only doc/test would report a tree in sync while the number in
# the driver was one the specs no longer justify -- which is the slack
# nobody closes, back again as a green run.
@test "_check_test_md_drift: FAILS when the committed ceiling is not what the tree measures" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=9" \
      > "${root}/script/test/drivers/catalog_description.sh"
    _sync_doc_counts "${root}"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=9" \
      > "${root}/script/test/drivers/catalog_description.sh"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial 'catalog_description.sh'
  assert_output --partial '_CATALOG_DESC_UNDESCRIBED_CEILING'
}

# why: The other side of the same gate. A tree the generator has just
# written must verify, or `just test sync-docs` would leave a red gate
# behind and the message telling people to run it would be a lie.
@test "_check_test_md_drift: a regenerated ceiling verifies in sync" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=9" \
      > "${root}/script/test/drivers/catalog_description.sh"
    _sync_doc_counts "${root}"
    _check_test_md_drift "${root}"
  '
  assert_success
}

@test "_check_test_md_drift: tolerates an empty acceptance level dir (count 0) (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/acceptance" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    printf "%s\n" "Acceptance specs under \`test/bats/acceptance/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/acceptance.md"
    _sync_doc_counts "${root}"
    _check_test_md_drift "${root}"
  '
  assert_success
}

# ── Scan-root robustness ────────────────────────────────────────────────────
#
# The comparison copies doc/test into a temp dir and symlinks the spec trees
# in from the scan root, so a relative root resolves against the TEMP dir on
# that hop: every spec glob misses and every count comes back 0 -- a
# confident wrong answer, not an error. The sibling sync-doc-counts.sh has no
# such hop and takes a relative root fine, which is what makes passing `.` to
# both the natural thing to do.

@test "_check_test_md_drift: a RELATIVE root gives the same verdict as the absolute one (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cd "${root}" || exit 2
    _check_test_md_drift .
  '
  assert_success
}

@test "_check_test_md_drift: a RELATIVE root still detects real drift (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    cd "${root}" || exit 2
    _check_test_md_drift .
  '
  assert_failure
  assert_output --partial "unit.md"
}

@test "_check_test_md_drift: FAILS on a nonexistent scan root, naming it (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    _check_test_md_drift "${BATS_TEST_TMPDIR}/nope"
  '
  assert_failure
  assert_output --partial "nope"
}

@test "_check_test_md_drift: FAILS on a scan root with no doc/test (no vacuous pass) (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "doc/test"
}

@test "_check_test_md_drift: FAILS on a spec-free scan root (no vacuous pass) (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "${BATS_TEST_TMPDIR}/r"
}

@test "_check_test_md_drift: counts a shipped smoke spec as spec files (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/dist/test/bats/smoke" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/dist/test/bats/smoke/s.bats"
    printf "%s\n" "Shared smoke specs that ship under \`dist/test/bats/smoke/\`: **0 tests**." \
      "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/smoke.md"
    _sync_doc_counts "${root}"
    _check_test_md_drift "${root}"
  '
  assert_success
}

# why: The rot this closes: the heading count was regenerated -- so the gate
# said in sync -- while the per-test table next to it stayed short, 36 rows
# against 43 tests. The region is generated wholesale now, so a hand-edited
# row IS drift, and the gate names it.
@test "_check_test_md_drift: FAILS when a row is deleted from the generated region (#859)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep -v "beta" "${root}/doc/test/unit.md" > "${root}/doc/test/unit.md.new"
    mv "${root}/doc/test/unit.md.new" "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "beta"
}
