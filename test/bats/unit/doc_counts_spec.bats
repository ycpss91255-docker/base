#!/usr/bin/env bats
#
# Unit tests for script/test/sync-doc-counts.sh (_sync_doc_counts).
#
# why: Unit coverage for the generator that derives ALL of doc/test/*.md
# from the specs: the count figures (`grep -c '^@test'`) and the catalogue
# sections, whose blurbs and per-test descriptions are read out of the spec
# files' own `# why:` markers. `check_test_md_drift.sh` stays the
# validating safety net and runs this same generator, so a case here is a
# case for the gate too.
#
# The first half covers the count figures, which were generated first and
# for the same reason: they were hand-edited every PR and went stale
# silently. The second half covers the generated catalogue REGION, and
# every case in it is a property the previous design could not have --
# a rename carrying its prose, a deleted row restored byte-for-byte, a
# description with a pipe in it that the author did not have to escape.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  GEN="/source/script/test/sync-doc-counts.sh"
}

# why: per-spec heading recompute
@test "_sync_doc_counts: rewrites a stale ### heading to the real @test count (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **99 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "### test/bats/unit/x_spec.bats (3)"
}

# why: Heading DEPTH is uniform now, and that is a decision with a cost.
# Depth used to be whatever the document had, which is why eight sections
# sat at `####` -- an editorial grouping under a prose heading, not path
# nesting, so nothing in a checkout could derive it. A generator that
# emitted both depths would have to be told which, by a person, per
# section. One depth is derivable; the grouping prose moved to the
# hand-written preamble, where it enumerates nothing.
@test "_sync_doc_counts: every section heading is emitted at one derivable depth" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit/compose_emit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/compose_emit/y_spec.bats"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep "^#" "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "### test/bats/unit/compose_emit/y_spec.bats (1)"
  assert_output --partial "### test/bats/unit/x_spec.bats (1)"
  refute_output --partial "#### "
}

# why: per-type total from grep-over-files
@test "_sync_doc_counts: rewrites the per-type total to the sum of the headings (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **99 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**3 tests**"
  refute_output --partial "**99 tests**"
}

# why: re-run no-op
@test "_sync_doc_counts: is idempotent on an already-synced tree (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/unit.md"
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
    printf "%s\n" "System specs under \`test/bats/system/\`: **99 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/system.md"
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
    printf "%s\n" "Acceptance specs under \`test/bats/acceptance/\`: **7 tests**." "" "<!-- generated: catalogue sections -->" "<!-- /generated -->" > "${root}/doc/test/acceptance.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/acceptance.md"
  '
  assert_success
  assert_output --partial "**0 tests**"
  refute_output --partial "**7 tests**"
}

# ── No aggregate suite figure is committed ───────────────────────────────────
#
# The figures above are per-DOCUMENT: one catalogue's own count, generated
# into the catalogue it describes. The ones below were AGGREGATES over the
# whole suite, and they lived in the two documents every branch touches --
# TEST.md's grand total, the "in the N figure" prose, the "System (N) and
# smoke (N)" pair, the index table's Count column, and unit.md's per-type
# total. ADR-00000028 sec. 1 removes them: an aggregate over a moving tree
# names nothing it measured, so it is wrong between every commit and its
# resync, and it was the whole merge surface of doc/test/.
#
# Nothing in the generator forbids writing one back -- a sed that finds no
# pattern is a silent no-op, and re-adding the line would put it back under
# maintenance. This is the guard that fails instead.

# The shapes an aggregate figure took. `\*\*[0-9]+\*\*` is the bare grand
# total; the rest are the four prose and table sites verbatim.
_AGGREGATE_FIGURE_RE='\*\*[0-9]+ tests?\*\*|\*\*[0-9]+\*\*|\| Count \||in the [0-9]+ figure|System \([0-9]+\) and smoke \([0-9]+\)'

# _aggregate_figure_hits <doc> -- `<line>: <text>` for every authored line of
# <doc> carrying an aggregate figure. Scanning STOPS at the generated fence:
# past it the document is the catalogue, whose per-spec headings and rows are
# derived on every run and are not this rule's business.
_aggregate_figure_hits() {
  awk '/<!-- generated: catalogue sections -->/ { exit } { print FNR ": " $0 }' "$1" \
    | grep -E "${_AGGREGATE_FIGURE_RE}" || true
}

# why: TEST.md is the index and carried four of the five aggregate lines, so
# it is where a reintroduced total would land first. The guard reads the
# COMMITTED document rather than a fixture: the fixture cases above prove
# what the generator writes, and this one proves what the repo ships.
@test "doc/test/TEST.md commits no aggregate suite figure (#978)" {
  run _aggregate_figure_hits /source/doc/test/TEST.md
  assert_success
  assert_output ''
}

# why: unit.md's total is the fifth line, and the load-bearing one: it is the
# figure every branch that adds a unit test had to edit. Only the authored
# preamble is scanned -- the generated region below the fence is derived from
# the specs on every run.
@test "doc/test/unit.md commits no aggregate suite figure (#978)" {
  run _aggregate_figure_hits /source/doc/test/unit.md
  assert_success
  assert_output ''
}

# why: Removing the lines is only half of it. The generator's TEST.md pass
# was the mechanism that made them maintainable, and every one of its rewrites
# is a `sed` that silently does nothing when its pattern is absent -- so left
# in place it would sit there looking retired while standing ready to adopt
# any figure typed back in, which is how the count became a maintained thing
# the first time. This is the case that says the generator no longer owns
# TEST.md: a document carrying every shape at once comes back unchanged.
@test "_sync_doc_counts: does not maintain an aggregate figure in TEST.md (#978)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/system" \
             "${root}/dist/test/bats/smoke" "${root}/doc/test"
    printf "@test \"u\" {\n:\n}\n" > "${root}/test/bats/unit/u_spec.bats"
    printf "@test \"s\" {\n:\n}\n" > "${root}/test/bats/system/s_spec.bats"
    printf "@test \"k\" {\n:\n}\n" > "${root}/dist/test/bats/smoke/k.bats"
    printf "%s\n" \
      "Template self-tests: **99 tests** total (98 unit + 1 integration)." \
      "> System (97) and smoke (96) tests are tracked here too but are" \
      "> **not** in the 99 figure." \
      "| Doc | Scope | Count |" \
      "| [unit.md](unit.md) | unit | 95 |" \
      "| [system.md](system.md) | system | 94 |" \
      "Self-test grand total (unit + integration): **99**." \
      > "${root}/doc/test/TEST.md"
    cp "${root}/doc/test/TEST.md" "${root}/before"
    _sync_doc_counts "${root}"
    diff -u "${root}/before" "${root}/doc/test/TEST.md"
  '
  assert_success
  assert_output ''
}

# The two `_sync_test_md_index` cases that stood here -- the index table's
# Count column and the "System (N) and smoke (N)" blockquote pair -- went
# with the function. Both asserted that a figure in TEST.md was kept true;
# ADR-00000028 sec. 1 is that it is not kept at all. The case above replaces
# them: it asserts TEST.md comes back unchanged.

# ── The generated catalogue region ───────────────────────────────────────────
#
# Fixtures build the spec files with printf, never a heredoc: a literal
# `@test ...` at column 0 anywhere in this file -- heredoc body included --
# is picked up by bats' own preprocessor as a test definition of THIS file.
#
# `_fixture_doc` writes a catalogue with the generated fence in it, because
# a document without one is refused (see the last case) rather than
# silently generated into nothing.

# _fixture_doc <path> <preamble-line>... -- a catalogue whose hand-written
# half is the given lines and whose generated half is an empty fenced
# region.
_fixture_doc() {
  local _path="$1"
  shift
  {
    printf '%s\n' "$@"
    printf '\n<!-- generated: catalogue sections -->\n<!-- /generated -->\n'
  } > "${_path}"
}

# why: The ordinary case end to end: a description authored above a test in
# the spec file arrives in the rendered row. Everything else here is a
# deviation from this one.
@test "_sync_doc_counts: a '# why:' block above a test becomes that row's description" {
  _fixture_doc "${BATS_TEST_TMPDIR}/unit.md" "# Unit"
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: the load-bearing case" "@test \"a\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    cp "${BATS_TEST_TMPDIR}/unit.md" "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial '| `a` | the load-bearing case |'
}

# why: The whole point of moving the prose to the spec. A rename used to
# lose the description -- the catalogue documented that loss as a rule --
# because the row was keyed on the name. The description now moves with
# the lines above the test, so this is the case the previous design could
# not satisfy at all.
@test "_sync_doc_counts: renaming a test carries its description to the new name" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: prose that must follow" "@test \"old name\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    printf "%s\n" "# why: prose that must follow" "@test \"new name\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial '| `new name` | prose that must follow |'
  refute_output --partial 'old name'
}

# why: The other direction of "the spec is the source": a row deleted from
# the committed catalogue is not a decision, it is damage, and the next run
# has to put it back exactly. Under the old design the description went
# with it and nothing could restore that half.
@test "_sync_doc_counts: a row deleted from the catalogue is restored byte-for-byte" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: a sentence nobody can retype" "@test \"a\" {" ":" "}" \
      "" "@test \"b\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cp "${root}/doc/test/unit.md" "${BATS_TEST_TMPDIR}/before.md"
    grep -v "a sentence nobody can retype" "${BATS_TEST_TMPDIR}/before.md" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    if cmp -s "${BATS_TEST_TMPDIR}/before.md" "${root}/doc/test/unit.md"; then
      echo RESTORED_IDENTICAL
    else
      diff "${BATS_TEST_TMPDIR}/before.md" "${root}/doc/test/unit.md"
    fi
  '
  assert_success
  assert_output --partial 'RESTORED_IDENTICAL'
}

# why: Deleting the marker is the one edit that SHOULD change the
# catalogue, and it must change it visibly: the row falls back to the
# placeholder rather than keeping prose the tree no longer holds.
@test "_sync_doc_counts: deleting a '# why:' block turns its row back into the placeholder" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: about to be deleted" "@test \"a\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial '| `a` | - |'
  refute_output --partial 'about to be deleted'
}

# why: The load-bearing escaping case, and the one the migration had to get
# right: five committed descriptions carry a literal pipe. The author types
# it raw in the marker -- markdown is the RENDERER's problem -- so an
# unescaped one here would split the row into three cells and silently move
# every description one column left.
@test "_sync_doc_counts: a pipe in a DESCRIPTION is escaped, so the row keeps two cells" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "# why: a || b is the operator this defends" "@test \"a\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep "^| .a." "${root}/doc/test/unit.md"
  '
  assert_success
  # The pipes are escaped, so the row still has exactly two cells: the
  # renderer owns the markdown, and the author typed `||` raw.
  assert_output '| `a` | a \|\| b is the operator this defends |'
}

# why: A `|` in a test NAME has always been escaped; the case stays because
# name and description are escaped by the same renderer now and a change to
# one is a change to the other.
@test "_sync_doc_counts: a pipe in a test NAME is escaped so the table stays well formed" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"a | b\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial '| `a \| b` | - |'
}

# why: The file-level block is a different site with the same grammar, and
# it is what replaced the hand-written paragraph under each heading -- the
# half a merge used to be able to drop while keeping the heading.
@test "_sync_doc_counts: the file-level '# why:' block renders as the section blurb" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "#!/usr/bin/env bats" "# why: what this whole file defends" \
      "" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial '### test/bats/unit/x_spec.bats (1)'
  assert_output --partial 'what this whole file defends'
}

# why: Sections are derived from the glob, not from what the document
# already mentions. A spec that never got a heading used to be invisible to
# every gate -- the same rot one level up from a missing row.
@test "_sync_doc_counts: every spec the glob matches gets a section, in glob order" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"z\" {" ":" "}" > "${root}/test/bats/unit/b_spec.bats"
    printf "%s\n" "@test \"y\" {" ":" "}" > "${root}/test/bats/unit/a_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep "^### " "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line --index 0 '### test/bats/unit/a_spec.bats (1)'
  assert_line --index 1 '### test/bats/unit/b_spec.bats (1)'
}

# why: Section order is sorted explicitly under LC_ALL=C, not left to
# pathname expansion, and this pair is the one that caught it: bash sorts a
# glob by the AMBIENT collation, and under en_US the underscore is ignored
# at the primary level, so `logrotate_spec.bats` sorts BEFORE
# `log_spec.bats` while under C it sorts after. The generator runs in a
# musl container and on a glibc host, so the same untouched tree
# regenerated in the two places produced two byte sequences and the drift
# gate fired on a checkout nobody had edited. What this case can and cannot
# do: it pins the C order, which is the
# answer both runtimes must give. It cannot itself reproduce the
# disagreement, because musl collates by byte and the suite runs in the
# alpine test-tools image -- the discriminating run is the host one.
@test "_sync_doc_counts: section order is the C collation, not the ambient locale's" {
  run bash -c '
    export LC_ALL=en_US.UTF-8
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/log_spec.bats"
    printf "@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/logrotate_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep "^### " "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line --index 0 '### test/bats/unit/log_spec.bats (1)'
  assert_line --index 1 '### test/bats/unit/logrotate_spec.bats (1)'
}

# why: Rows read the way the spec reads, so reordering a spec produces the
# matching doc diff instead of an unrelated scatter -- and the deliberate
# grouping of related cases survives into the catalogue.
@test "_sync_doc_counts: rows follow spec file order, not alphabetical order" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"zebra\" {" ":" "}" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep "^| .z\|^| .a" "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line --index 0 '| `zebra` | - |'
  assert_line --index 1 '| `alpha` | - |'
}

# why: Everything outside the fence is the author's, and the generator must
# not touch it -- that boundary is what lets the preamble hold prose no
# generator can write without becoming a merge surface again.
@test "_sync_doc_counts: text outside the fence is left exactly as written" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "hand-written above" "" \
      "<!-- generated: catalogue sections -->" "### stale garbage (99)" \
      "<!-- /generated -->" "" "hand-written below" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial 'hand-written above'
  assert_output --partial 'hand-written below'
  refute_output --partial 'stale garbage'
}

# why: A catalogue that lost its fence must be an ERROR. Generating nothing
# into a document with no region is how a level silently stops being
# covered while the drift gate keeps reporting "in sync" -- the exact
# failure this whole mechanism exists to remove, one layer up.
@test "_sync_doc_counts: FAILS naming the document when the generated fence is missing" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "no fence here" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial 'carries no'
  assert_output --partial 'unit.md'
}

# why: "Regenerating from scratch reproduces what is committed" is the gate
# check_test_md_drift.sh applies to the real tree, so a second run that
# moved a byte would make every branch red for a reason no diff explains.
@test "_sync_doc_counts: a second run over a generated catalogue changes nothing" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "#!/usr/bin/env bats" "# why: a blurb that wraps because it is long enough to need two lines of prose" \
      "" "# why: described" "@test \"a\" {" ":" "}" "" "@test \"b\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "# Unit" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cp "${root}/doc/test/unit.md" "${BATS_TEST_TMPDIR}/first.md"
    _sync_doc_counts "${root}"
    diff "${BATS_TEST_TMPDIR}/first.md" "${root}/doc/test/unit.md" && echo IDEMPOTENT
  '
  assert_success
  assert_output --partial 'IDEMPOTENT'
}

# why: A shipped smoke spec is the one level whose glob leaves test/ for
# dist/, and it was the case that caught the doc-to-glob map going stale
# before. It stays because the map is still hand-written.
@test "_sync_doc_counts: a shipped smoke spec lands in smoke.md" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/dist/test/bats/smoke/shared" "${root}/doc/test"
    printf "%s\n" "@test \"k\" {" ":" "}" \
      > "${root}/dist/test/bats/smoke/shared/k.bats"
    printf "%s\n" "# Smoke" "" "<!-- generated: catalogue sections -->" \
      "<!-- /generated -->" > "${root}/doc/test/smoke.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/smoke.md"
  '
  assert_success
  assert_output --partial '### dist/test/bats/smoke/shared/k.bats (1)'
}
