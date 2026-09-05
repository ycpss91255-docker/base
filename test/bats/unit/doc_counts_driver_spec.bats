#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/doc_counts.sh (_run_doc_counts) -- the
# dispatcher entry point for the generated-figure drift gate.
#
# why: The driver is a thin wrapper around `_check_test_md_drift`, and the
# one thing it owns is the message a red branch reads. That message is not
# decoration: it is the whole repair instruction, and the gate's file set
# outgrew it -- the generator writes the undescribed ceiling into its own
# lint's driver as well as the `doc/test` catalogues, so a message naming
# `doc/test/*.md` sends the reader to a file that is not the one that
# drifted. The case here drives a ceiling-only drift and reads the
# message, not the diff.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  DRIVER="/source/script/test/drivers/doc_counts.sh"
}

# why: A drift the message used to describe wrongly. Only the ceiling is
# out of sync -- every `doc/test` document matches the tree -- so a message
# that names `doc/test/*.md` and tells the reader not to hand-edit a count
# or a catalogue row names neither the file that drifted nor the edit that
# would repair it. The set is the generator's own answer
# (`_sync_doc_counts_outputs`), so the next generated figure arrives in the
# message with it. Read from the stubbed `_die` alone: the unified diff on
# stderr already names the file, and asserting over both would pass on the
# diff.
@test "_run_doc_counts: the drift message names the files the generator writes (#1024)" {
  run bash -c '
    _die() { printf "DIE %s: %s\n" "$1" "$2"; return 1; }
    source "'"${DRIVER}"'"
    REPO_ROOT="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/doc/test" \
      "${REPO_ROOT}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" ":" "}" \
      > "${REPO_ROOT}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." "" \
      "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${REPO_ROOT}/doc/test/unit.md"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=9" \
      > "${REPO_ROOT}/script/test/drivers/catalog_description.sh"
    _sync_doc_counts "${REPO_ROOT}"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=9" \
      > "${REPO_ROOT}/script/test/drivers/catalog_description.sh"
    _run_doc_counts 2>/dev/null
  '
  assert_failure
  assert_output --partial 'DIE ci_doc_counts'
  assert_output --partial 'script/test/drivers/catalog_description.sh'
  assert_output --partial 'doc/test/unit.md'
  assert_output --partial 'just test sync-docs'
}
