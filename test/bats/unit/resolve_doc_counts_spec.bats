#!/usr/bin/env bats
#
# Unit tests for script/test/resolve-doc-counts.sh (_resolve_doc_counts) --
# the one command that resolves a doc/test/*.md merge conflict: collapse the
# markers, regenerate the derived figures authoritatively, verify.
#
# The recipe it replaces was retyped by hand six times in a single review
# batch (an awk one-liner plus two scripts) and had to be pasted verbatim into
# every dispatched agent prompt. It was also hazardous: a mechanical collapse
# adopts whichever side it keeps, INCLUDING for content the generator does not
# derive, so a stale figure or a lost sentence rides through silently.
#
# The cases below therefore split into two halves: the toil half (markers go,
# figures come back right) and the safety half (anything the collapse cannot
# justify by regeneration is refused loudly, never adopted quietly).
#
# why: Unit coverage for `script/test/resolve-doc-counts.sh` -- the one
# command that resolves a `doc/test/*.md` merge conflict. Two halves: the
# toil (markers go, figures come back regenerated from the merged spec tree)
# and the safety (a relative root, a surviving marker, an unhappy drift
# gate, and any disagreement regeneration cannot settle are all refused
# loudly rather than resolved to whichever side the collapse happened to
# keep).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  RESOLVE="/source/script/test/resolve-doc-counts.sh"
}

# ── Root guards ──────────────────────────────────────────────────────────────

@test "_resolve_doc_counts: FAILS on a RELATIVE root, naming it (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    cd "${root}"
    _resolve_doc_counts .
  '
  assert_failure
  assert_output --partial "relative"
}

@test "_resolve_doc_counts: FAILS on a nonexistent root, naming it (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    _resolve_doc_counts "${BATS_TEST_TMPDIR}/nope"
  '
  assert_failure
  assert_output --partial "nope"
}

# ── The toil ─────────────────────────────────────────────────────────────────

# why: The conflict this tool did not cover, and the reason base#1024
# exists: two branches that each described tests each lowered the ceiling,
# so the merge conflicts on that line and the right answer is NEITHER
# side's -- the descriptions compose, so the merged tree measures lower
# than both. Recomputing is the only resolution, which is exactly what
# this tool already does for the documents.
@test "_resolve_doc_counts: resolves a ceiling conflict by recomputing, not by taking a side" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"alpha\" {" ":" "}" \
      "@test \"beta\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=5" \
      "=======" \
      "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=4" \
      ">>>>>>> origin/main" \
      > "${root}/script/test/drivers/catalog_description.sh"
    _resolve_doc_counts "${root}"
    cat "${root}/script/test/drivers/catalog_description.sh"
  '
  assert_success
  assert_output --partial 'readonly _CATALOG_DESC_UNDESCRIBED_CEILING=2'
  refute_output --partial '<<<<<<<'
  refute_output --partial '======='
}

@test "_resolve_doc_counts: collapses a counter-only conflict and regenerates (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      "@test \"gamma\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **1 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **2 tests**." \
      ">>>>>>> origin/main" \
      "" \
      "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**3 tests**"
  refute_output --partial "<<<<<<<"
  refute_output --partial ">>>>>>>"
  refute_output --partial "======="
}

@test "_resolve_doc_counts: drops the diff3 base section too (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **9 tests**." \
      "||||||| merged common ancestors" \
      "Unit specs under \`test/bats/unit/\`: **7 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **8 tests**." \
      ">>>>>>> origin/main" \
      "" \
      "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**1 tests**"
  refute_output --partial "|||||||"
  refute_output --partial "merged common ancestors"
}

# why: What used to need reconciling, and no longer can. Each side's
# collapse used to carry hand-written descriptions the generator could not
# re-derive, so a mechanical collapse dropped a sentence nothing would put
# back and this script had to merge them row by row. Descriptions are
# authored in the specs now, so both collapses regenerate the SAME rows
# from the SAME merged spec tree -- whichever side a conflicted counter
# line came from. This case pins that the prose survives a conflict
# without any reconciliation code left to do it.
@test "_resolve_doc_counts: catalogue prose survives a conflict because both sides regenerate it (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: ours describes alpha" "@test \"alpha\" {" ":" "}" \
      "# why: theirs describes beta" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **1 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **9 tests**." \
      ">>>>>>> origin/main" \
      "" \
      "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `alpha` | ours describes alpha |'
  assert_line '| `beta` | theirs describes beta |'
  refute_output --partial "<<<<<<<"
}

@test "_resolve_doc_counts: an unconflicted tree is verified, not rewritten (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    before=$(cat "${root}/doc/test/unit.md")
    _resolve_doc_counts "${root}"
    after=$(cat "${root}/doc/test/unit.md")
    [[ "${before}" == "${after}" ]] && echo UNCHANGED
  '
  assert_success
  assert_output --partial "no conflicted"
  assert_output --partial "UNCHANGED"
}

# ── The trap ─────────────────────────────────────────────────────────────────

@test "_resolve_doc_counts: FAILS when the sides differ in prose the generator does not derive (#857)" {
  # The exact trap the manual recipe carried: the collapse adopts whichever
  # side it kept for a hand-maintained sentence sitting next to the generated
  # figures, and nothing downstream notices.
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Covers the old behaviour, hand written." \
      "=======" \
      "Covers the new behaviour, hand written." \
      ">>>>>>> origin/main" \
      "" \
      "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial "hand written"
}

# why: The same trap, in the file that is only ONE LINE generated. The
# ceiling lives in a 400-line hand-written driver (base#1024), so adopting
# a side there adopts an argument somebody wrote, not a figure -- the
# doc/test half of this refusal has a case and this half had none, which
# left the guard free to be deleted invisibly. The two sides here disagree
# about a comment AND about the ceiling: the ceiling alone would resolve
# by recomputation, so only the comment can make it refuse.
@test "_resolve_doc_counts: FAILS when the sides of a generated file outside doc/test differ in prose (#1024)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" \
      "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **1 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "# the argument for the ceiling, as ours wrote it" \
      "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=5" \
      "=======" \
      "# the argument for the ceiling, as theirs rewrote it" \
      "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=4" \
      ">>>>>>> origin/main" \
      > "${root}/script/test/drivers/catalog_description.sh"
    _resolve_doc_counts "${root}"
    _rc=$?
    printf "AFTER %s\n" "$(cat "${root}/script/test/drivers/catalog_description.sh")"
    exit "${_rc}"
  '
  assert_failure
  assert_output --partial 'script/test/drivers/catalog_description.sh'
  assert_output --partial 'Resolve it by hand'
  # Refused means UNTOUCHED: the markers are still there for the person
  # the message just handed the file to.
  assert_output --partial '<<<<<<< HEAD'
}

@test "_resolve_doc_counts: FAILS when the drift gate is unhappy afterwards (#857)" {
  # A scan root the gate refuses (no spec files: every count would compare 0
  # against 0) must surface as a failure, not as a resolved-looking tree.
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **1 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **2 tests**." \
      ">>>>>>> origin/main" \
      "" \
      "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial "no spec files"
}

@test "_resolve_assert_no_markers: FAILS naming the file and line of a survivor (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test"
    printf "%s\n" "fine" "<<<<<<< HEAD" "also fine" \
      > "${root}/doc/test/unit.md"
    _resolve_assert_no_markers "${root}"
  '
  assert_failure
  assert_output --partial "unit.md:2"
}
