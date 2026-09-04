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

# why: The gate's file set has to be the GENERATOR's answer and not a
# constant this file keeps beside it. The merge resolver was changed for
# exactly that reason -- a resolver carrying its own copy of "what is
# generated" refuses the one file whose conflicts it is best placed to
# settle -- and the gate names its single outside output twice instead.
# A further generated output is then covered on a merge and silently
# uncovered here, with pass as the default. The case swaps in a generator
# with a second output and asks the gate to notice it has gone stale.
@test "_check_test_md_drift: compares every file the generator claims, not one it names (#1024)" {
  local _runner="${BATS_TEST_TMPDIR}/second_output.sh"
  # Quoted heredoc: every expansion below belongs to the child, not here.
  cat > "${_runner}" << 'EOF'
set -uo pipefail
source /source/script/test/check_test_md_drift.sh

_SECOND_REL='script/test/drivers/second_figure.sh'

# A generator with one more output than the gate can name. Both halves
# are replaced together, because they are one fact: what it WRITES, and
# what it answers when asked which files those are.
eval "_orig_sync_doc_counts() $(declare -f _sync_doc_counts | tail -n +2)"
_sync_doc_counts() {
  _orig_sync_doc_counts "$@" || return 1
  mkdir -p "$(dirname -- "$1/${_SECOND_REL}")"
  printf 'readonly _SECOND=%s\n' \
    "$(grep -c '^@test' "$1/test/bats/unit/x_spec.bats")" \
    > "$1/${_SECOND_REL}"
}
_sync_doc_counts_outputs() {
  local _r="$1" _doc
  for _doc in "${_r}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] && printf '%s\n' "${_doc}"
  done
  [[ -f "${_r}/${_SECOND_REL}" ]] && printf '%s\n' "${_r}/${_SECOND_REL}"
  return 0
}

root="${ROOT}"
mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
printf '%s\n' '#!/usr/bin/env bats' '' '@test "a" {' ':' '}' \
  > "${root}/test/bats/unit/x_spec.bats"
printf '%s\n' 'Unit specs under `test/bats/unit/`: **0 tests**.' '' \
  '<!-- generated: catalogue sections -->' '<!-- /generated -->' \
  > "${root}/doc/test/unit.md"
_sync_doc_counts "${root}"
# The second output, and nothing else, is now what the specs no longer
# justify. doc/test is in sync, so only a gate that reads the whole
# output set can see it.
printf 'readonly _SECOND=99\n' > "${root}/${_SECOND_REL}"
_check_test_md_drift "${root}"
EOF
  run env ROOT="${BATS_TEST_TMPDIR}/r" bash "${_runner}"
  assert_failure
  assert_output --partial 'second_figure.sh'
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
