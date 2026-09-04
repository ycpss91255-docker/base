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

@test "_sync_test_md_index: fills the system + acceptance rows, retires behavioural (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/integration" \
             "${root}/test/bats/system" "${root}/test/bats/acceptance" \
             "${root}/dist/test/bats/smoke/shared" "${root}/doc/test"
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

@test "_sync_test_md_index: regenerates the blockquote prose System/smoke pair (#843)" {
  # Regression: only the table rows and per-level headers were regenerated,
  # so TEST.md's hand-written "System (N) and smoke (N)" prose drifted and
  # ended up contradicting the table sitting right below it.
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/system" "${root}/dist/test/bats/smoke" \
             "${root}/doc/test"
    printf "@test \"s1\" {\n:\n}\n@test \"s2\" {\n:\n}\n" > "${root}/test/bats/system/s_spec.bats"
    printf "@test \"k\" {\n:\n}\n" > "${root}/dist/test/bats/smoke/k.bats"
    printf "%s\n" "> System (99) and smoke (98) tests are tracked here too." \
      > "${root}/doc/test/TEST.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/TEST.md"
  '
  assert_success
  assert_output --partial "System (2) and smoke (1) tests"
  refute_output --partial "System (99)"
}



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

# ════════════════════════════════════════════════════════════════════
# The undescribed ceiling (base#1024)
#
# The ceiling is the third derived figure, and it arrived as a hand-kept
# one: a `readonly` in drivers/catalog_description.sh that every branch
# describing a test had a correct reason to lower, so every branch edited
# the same line and every merge conflicted on it -- with the merged tree's
# right value NEITHER side's, because descriptions compose. It is now
# written by this generator, in the run that writes the catalogue.
#
# The ratchet is the whole point and these cases exist to keep it: a
# generator that writes whatever it measures turns a bound into a mirror,
# and a lint that mirrors bounds nothing. So the value moves DOWN only.
# ════════════════════════════════════════════════════════════════════

# why: The ordinary direction. A branch that describes tests should not
# also have to compute and hand-edit a number about the tree it just
# changed -- that hand-edit is the conflict this removes.
@test "_sync_doc_counts: lowers the undescribed ceiling to what the tree measures" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" "}" "@test \"b\" {" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=9" \
      > "${root}/script/test/drivers/catalog_description.sh"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep _CATALOG_DESC_UNDESCRIBED_CEILING "${root}/script/test/drivers/catalog_description.sh"
  '
  assert_success
  assert_output 'readonly _CATALOG_DESC_UNDESCRIBED_CEILING=2'
}

# why: The load-bearing case. A generator that wrote whatever it measured
# would turn the ratchet into a mirror and the lint would stop bounding
# anything -- so a tree with MORE undescribed tests than the record leaves
# the record alone, and the breach reaches the lint.
@test "_sync_doc_counts: REFUSES to raise the ceiling for a tree that breached it" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" "}" "@test \"b\" {" "}" \
      "@test \"c\" {" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=1" \
      > "${root}/script/test/drivers/catalog_description.sh"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep _CATALOG_DESC_UNDESCRIBED_CEILING "${root}/script/test/drivers/catalog_description.sh"
  '
  assert_success
  assert_output 'readonly _CATALOG_DESC_UNDESCRIBED_CEILING=1'
}

# why: The refusal proven where it matters -- through the lint, not just
# by reading the number back. A regeneration must not be a way to launder
# a breach into a green run, which is exactly what "the generator owns the
# ceiling" would mean if it wrote what it measured.
@test "_sync_doc_counts: a regenerated tree that breached the ceiling still FAILS the lint" {
  run bash -c '
    set -uo pipefail
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    cp /source/script/test/*.sh "${root}/script/test/"
    sed -E "s/^readonly _CATALOG_DESC_UNDESCRIBED_CEILING=[0-9]+$/readonly _CATALOG_DESC_UNDESCRIBED_CEILING=1/" \
      /source/script/test/drivers/catalog_description.sh \
      > "${root}/script/test/drivers/catalog_description.sh"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" "}" "@test \"b\" {" "}" \
      "@test \"c\" {" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    source "${root}/script/test/sync-doc-counts.sh"
    _sync_doc_counts "${root}"
    source /source/dist/script/docker/lib/_lib.sh
    _die() { local _ev="${1}"; shift; printf "die %s: %s\n" "${_ev}" "$*"; return 1; }
    source "${root}/script/test/drivers/catalog_description.sh"
    REPO_ROOT="${root}"
    _run_catalog_description
  '
  assert_failure
  assert_output --partial 'undescribed=3'
  assert_output --partial 'ceiling=1'
}

# why: Idempotence for the third figure. The drift gate is "regenerating
# reproduces what is committed", so a second run that moved this number
# would make every branch red for a reason no diff explains.
@test "_sync_doc_counts: a second run leaves an already-lowered ceiling alone" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=4" \
      > "${root}/script/test/drivers/catalog_description.sh"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cp "${root}/script/test/drivers/catalog_description.sh" "${BATS_TEST_TMPDIR}/first"
    _sync_doc_counts "${root}"
    diff "${BATS_TEST_TMPDIR}/first" "${root}/script/test/drivers/catalog_description.sh" \
      && echo IDEMPOTENT
  '
  assert_success
  assert_output --partial 'IDEMPOTENT'
}

# why: The number is a bound, so a value the reader cannot find is not a
# missing figure to fill in with a guess -- guessing high is a fail-open
# that silently unbounds the lint. A conflicted or hand-mangled record
# stops the generator instead.
@test "_sync_doc_counts: FAILS naming the file when the ceiling cannot be read" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test" "${root}/script/test/drivers"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "<<<<<<< HEAD" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=7" \
      "=======" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=8" ">>>>>>> other" \
      > "${root}/script/test/drivers/catalog_description.sh"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial 'catalog_description.sh'
  assert_output --partial '_CATALOG_DESC_UNDESCRIBED_CEILING'
}

# why: The generator runs against scratch trees that hold doc/test and the
# spec trees and nothing else -- the drift gate's copy and the resolver's
# two collapses. A root with no driver in it is those callers, not a
# broken checkout, so it is a skip and not a failure.
@test "_sync_doc_counts: a root with no driver in it syncs the documents and skips the ceiling" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "#!/usr/bin/env bats" "" "@test \"a\" {" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "<!-- generated: catalogue sections -->" "<!-- /generated -->" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep -c "x_spec.bats (1)" "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output '1'
}

# why: What the resolver and the drift gate have to agree with the
# generator about is the OUTPUT SET, and a hand-kept second copy of it is
# the same defect one level up. The ceiling file is an output now, so it
# has to be in the answer.
@test "_sync_doc_counts_outputs: names every file the generator writes, ceiling included" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test" "${root}/script/test/drivers"
    : > "${root}/doc/test/unit.md"
    : > "${root}/doc/test/TEST.md"
    printf "%s\n" "readonly _CATALOG_DESC_UNDESCRIBED_CEILING=1" \
      > "${root}/script/test/drivers/catalog_description.sh"
    _sync_doc_counts_outputs "${root}" | sed "s|^${root}/||"
  '
  assert_success
  assert_line 'doc/test/TEST.md'
  assert_line 'doc/test/unit.md'
  assert_line 'script/test/drivers/catalog_description.sh'
}
