#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/catalog_description.sh -- the "a
# doc/test catalog row carries a description" lint.
#
# The column is required. It is not redundant with the test name: this
# repo's @test names are long and already say WHAT is asserted, so a
# description that restates them adds nothing, while the descriptions that
# exist say why the case matters -- which one is load-bearing, what it is
# defending. A `-` loses that half. Two specs landing the same week, same
# generator and same review bar, came out opposite ways because nothing
# said which was correct, and that divergence is what this lint stops.
#
# The design decisions this spec pins:
#
#   - The guard is RATCHETED, not a wall. 1517 rows carried the
#     placeholder when the rule landed; failing all of them would hold
#     everyone hostage to a backfill nobody asked for, and a rushed
#     backfill produces filler that passes the lint and is worse than `-`.
#     So a baseline file records those rows and the lint fails only on a
#     placeholder that is NOT on it.
#
#   - The baseline is keyed by SPEC PATH plus TEST NAME, so renaming or
#     moving a test drops it out of the baseline and forces a description.
#     Touch it, describe it; leave it alone, leave it alone. That property
#     is the whole reason the baseline is a name list rather than a count,
#     so it gets its own case.
#
#   - The baseline may only SHRINK. Nothing in a checkout can tell whether
#     a line was there yesterday, so the lint does not pretend to: it
#     instead makes every change to the file impossible to make silently.
#     The file declares its own entry count, the count must match, and a
#     baselined row that is no longer a placeholder is refused as stale --
#     so describing a row forces the list and the count DOWN in the same
#     commit, and growing either one is a deliberate, reviewable edit of a
#     number that states how much debt is left.
#
#   - The baseline records what was ALREADY missing, and nothing else. An
#     entry over a row that IS described unenforces that description --
#     the row can go back to `-` with the lint green -- so it is refused,
#     as is the duplicated section that is how a described row acquires a
#     placeholder twin in the first place.
#
#   - The rule REACHES every generated section. A section that answers
#     with a summary instead of a row each is outside the rule, and that
#     is allowed -- but only as a DECLARED, reasoned exemption the lint
#     reports, never as a table shape the parser silently failed to
#     recognise. The reach a lint claims and the reach it has are two
#     different numbers unless something forces them together.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; the final cases drive the REAL
# tree. Shape mirrors changelog_entry_lint_spec.bats /
# home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/catalog_description.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}"
  mkdir -p "${SCRATCH}/$(dirname "${_CATALOG_DESC_BASELINE_FILE}")"
  REPO_ROOT="${SCRATCH}"
  CATALOG="${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/unit.md"
  BASELINE="${SCRATCH}/${_CATALOG_DESC_BASELINE_FILE}"
  # Most cases are about the rows, not the two sidecar files, so start from
  # an empty-but-well-formed pair and let the cases that care rewrite them.
  _write_baseline
  _write_exempt
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_catalog <spec-path> <row>... -- a scratch catalog with one
# generated section for <spec-path> and the given `| name | desc |` rows.
_write_catalog() {
  local _spec="${1}"
  shift
  {
    printf '# Unit Tests\n\n'
    printf '## Test Files\n\n'
    printf '### %s (%d)\n\n' "${_spec}" "$#"
    printf '| Test | Description |\n|------|-------------|\n'
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
  } > "${CATALOG}"
}

# _row <name> <desc> -- one rendered catalog row, the way
# sync-doc-counts.sh renders it.
_row() {
  printf '| `%s` | %s |' "${1}" "${2}"
}

# _write_baseline <entry>... -- a scratch baseline whose declared count
# matches the entries given. Entries are passed as `<spec>|<name>` and
# joined with the TAB the file actually uses, so the fixtures stay
# readable.
_write_baseline() {
  {
    printf '# scratch baseline\n'
    printf '# entries: %d\n' "$#"
    local _e
    for _e in "$@"; do
      printf '%s\t%s\n' "${_e%%|*}" "${_e#*|}"
    done
  } > "${BASELINE}"
}

# _write_exempt <entry>... -- a scratch exemptions file whose declared
# count matches the entries given. Entries are passed as `<spec>|<reason>`
# and joined with the TAB the file actually uses.
_write_exempt() {
  {
    printf '# scratch exemptions\n'
    printf '# entries: %d\n' "$#"
    local _e
    for _e in "$@"; do
      printf '%s\t%s\n' "${_e%%|*}" "${_e#*|}"
    done
  } > "${SCRATCH}/${_CATALOG_DESC_EXEMPT_FILE}"
}

# _write_summary_section <spec> <tests> -- append a section that answers
# with a `| Category | Tests |` summary instead of a row each.
_write_summary_section() {
  {
    printf '\n### %s (%d)\n\n' "${1}" "${2}"
    printf '| Category | Tests |\n|----------|-------|\n'
    printf '| parsing | %d |\n' "${2}"
  } >> "${CATALOG}"
}

# ════════════════════════════════════════════════════════════════════
# The rule: a placeholder row fails
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: FAILS on a placeholder row that is not on the baseline (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
}

@test "_run_catalog_description: names the catalog file, the line, the spec and the test (#922)" {
  # A finding nobody can act on is a finding that gets muted. The line
  # number comes from the fixture via grep, not from arithmetic over the
  # driver's own scan, so the assertion cannot agree with a miscount.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  local _line
  _line="$(grep -n 'alpha does a thing' "${CATALOG}" | cut -d: -f1)"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_DOC_DIR}/unit.md:${_line}:"
  assert_output --partial 'test/bats/unit/alpha_spec.bats'
}

@test "_run_catalog_description: reports EVERY undescribed row, not just the first (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' '-')" \
    "$(_row 'beta does another thing' '-')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
  assert_output --partial 'beta does another thing'
}

@test "_run_catalog_description: an EMPTY description cell counts as a placeholder (#922)" {
  # `-` is what the generator writes; a hand-edited row can be blank, and
  # a blank cell is the same missing sentence wearing less ink.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
}

@test "_run_catalog_description: a description with no WORD in it is a placeholder (#922)" {
  # `-` is the placeholder the generator writes, but it is not the only
  # way to write silence, and the ratchet makes the alternatives
  # attractive: a cell one keystroke away from `-` is the cheapest way to
  # clear a red build. `.` and `--` are not judgement calls about whether
  # a sentence restates the test name -- they say nothing at all, which is
  # the one thing this rule exists to refuse.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' '.')" \
    "$(_row 'beta does another thing' '--')" \
    "$(_row 'gamma does a third thing' '...')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
  assert_output --partial 'beta does another thing'
  assert_output --partial 'gamma does a third thing'
  assert_output --partial '3 undescribed'
}

@test "_run_catalog_description: the written-out non-answers are placeholders too (#922)" {
  # The same silence spelled with letters. These are short enough to be
  # unambiguous: no honest description of why a case matters is "n/a".
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'n/a')" \
    "$(_row 'beta does another thing' 'TBD')" \
    "$(_row 'gamma does a third thing' 'TODO')"
  run _run_catalog_description
  assert_failure
  assert_output --partial '3 undescribed'
}

@test "_run_catalog_description: a SHORT honest description still passes (#922)" {
  # The other side of the same rule, and the reason it is drawn at "has a
  # word in it" rather than at a length: the real catalogues carry
  # descriptions like "GPU on" and "--dry-run", which say something a name
  # does not, and a guard whose false positives are the good rows teaches
  # people to write around it.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'the compose file gets the device request' 'GPU on')" \
    "$(_row 'the wrapper forwards the flag' '--dry-run')"
  run _run_catalog_description
  assert_success
  assert_output --partial '2 rows checked'
}

@test "_run_catalog_description: an exemption reason with no WORD in it is refused (#922)" {
  # The exemptions file is held to the same reading, for the same reason:
  # `.` in the reason column is the silence the file exists to break.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  _write_exempt 'test/bats/unit/beta_spec.bats|.'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'reason'
}

@test "_run_catalog_description: PASSES a described row (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'The load-bearing case: nothing else holds without it')"
  run _run_catalog_description
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The ratchet: today's placeholders are excused, and only those
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: PASSES a placeholder row that IS on the baseline (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_success
}

@test "_run_catalog_description: renaming a baselined test forces a description (#922)" {
  # The property the whole design turns on, and the reason the baseline is
  # a name list rather than a count: touch a test and you own its
  # description; leave it alone and the debt stays parked.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing, renamed' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing, renamed'
}

@test "_run_catalog_description: MOVING a baselined test to another spec forces a description (#922)" {
  # The baseline is scoped by spec path as well as name -- three test
  # names in this tree already live in two specs at once, so a name-only
  # key would excuse a row nobody ever looked at.
  _write_catalog 'test/bats/unit/beta_spec.bats' "$(_row 'alpha does a thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'beta_spec.bats'
}

# ════════════════════════════════════════════════════════════════════
# The baseline may only shrink
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: FAILS on a baseline entry whose row is now DESCRIBED (#922)" {
  # This is what drives the ratchet down. Without it a described row keeps
  # its excuse forever, the file never shrinks, and the count stops
  # meaning anything.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'The load-bearing case')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'stale'
}

@test "_run_catalog_description: FAILS on a baseline entry whose row is GONE (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'beta does another thing' 'Why beta matters')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'stale'
}

@test "_run_catalog_description: FAILS when the declared entry count is too LOW (#922)" {
  # Growing the list is the move the ratchet exists to stop, and the
  # declared count is what makes it impossible to make quietly: an added
  # line is a failing lint until someone also raises a number that states
  # how much debt is left.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  {
    printf '# entries: 0\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries'
}

@test "_run_catalog_description: FAILS when the declared entry count is too HIGH (#922)" {
  # The other direction: a count left behind by a deletion is a count
  # nobody is reading, and it silently buys room to grow later.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  {
    printf '# entries: 9\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries'
}

@test "_run_catalog_description: DIES when the baseline declares no count at all (#922)" {
  # Dropping the directive would turn the shrink-only lock off silently,
  # which is exactly the edit it exists to make loud.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n' > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries:'
}

@test "_run_catalog_description: FAILS on an unsorted baseline (#922)" {
  # A 1500-line file is only reviewable while its diff is one line per
  # change; unsorted, an insertion can hide anywhere.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'zulu' '-')" "$(_row 'alpha' '-')"
  {
    printf '# entries: 2\n'
    printf 'test/bats/unit/alpha_spec.bats\tzulu\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'sorted'
}

@test "_run_catalog_description: FAILS on a duplicated baseline entry (#922)" {
  # Two lines, one excused row: the count then overstates the debt and a
  # later deletion of one copy looks like progress.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha' '-')"
  {
    printf '# entries: 2\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'duplicate'
}

@test "_run_catalog_description: FAILS on a baseline line with no TAB separator (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha' '-')"
  {
    printf '# entries: 1\n'
    printf 'test/bats/unit/alpha_spec.bats alpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'malformed'
}

@test "_run_catalog_description: 256 findings in a sidecar file are not read as zero (#922)" {
  # The load-list findings used to come back as the function's EXIT
  # STATUS, and an exit status is 8 bits. The 256th finding wrapped to 0,
  # the caller's `|| _violations=$(( _violations + $? ))` never fired, and
  # the lint printed 256 findings and then called itself clean -- the
  # exact defect class this whole driver is written against, a guard whose
  # own report contradicts its verdict. The baseline holds four figures of
  # entries, so a re-sort under another locale or a bulk regeneration
  # reaches 256 without anything exotic happening.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '# scratch baseline\n'
    # Malformed lines are not entries, so the declared count stays 0 and
    # the 256 findings are exactly the 256 malformed lines.
    printf '# entries: 0\n'
    local _i
    for (( _i = 0; _i < 256; _i++ )); do
      printf 'no-tab-separator-%03d\n' "${_i}"
    done
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  refute_output --partial 'catalog description lint: clean'
  assert_output --partial '256 undescribed'
}

@test "_run_catalog_description: a baseline entry may NOT excuse a row that is also described (#922)" {
  # The ratchet from the other side. The baseline records what was already
  # missing; the moment one of its keys also names a DESCRIBED row, that
  # description stops being enforced -- somebody can replace it with `-`
  # and the lint stays green, which is the opposite of forward-only. Two
  # rows under one name is the only way a key can be both, and it is not
  # hypothetical: a duplicated section put 17 described rows of the real
  # catalogue into exactly this state, and nothing said so.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' '-')" \
    "$(_row 'alpha does a thing' 'The load-bearing case')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'described'
  assert_output --partial 'alpha does a thing'
}

@test "_run_catalog_description: FAILS when one spec carries TWO generated sections (#922)" {
  # How the row above came to exist. A section moved into its thematic
  # group left its heading behind; `just test sync-docs` filled the empty
  # copy with a row per test, all of them placeholders, and parking those
  # on the baseline unenforced the descriptions in the other copy. The
  # SECTION is the unit of the rule, so a spec gets exactly one -- two
  # answers for one spec is a defect in the document, not a layout choice.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '\n### test/bats/unit/alpha_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `alpha does a thing` | - |\n'
  } >> "${CATALOG}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'duplicate section'
  assert_output --partial 'test/bats/unit/alpha_spec.bats'
}

@test "_run_catalog_description: the SECOND copy of a section is not scanned as rows (#922)" {
  # One finding per defect. The duplicate's rows are not also reported as
  # undescribed, and they are not counted: a copied table would otherwise
  # inflate the reach figures by exactly its own length (the real one
  # inflated both the rows-checked and the still-on-the-baseline counts by
  # 17) and bury the one line that says what is actually wrong.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '\n### test/bats/unit/alpha_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `beta only exists in the copy` | - |\n'
  } >> "${CATALOG}"
  run _run_catalog_description
  assert_failure
  refute_output --partial 'beta only exists in the copy'
}

# ════════════════════════════════════════════════════════════════════
# What is and is not a catalog row
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: a summary table is not a per-test catalog (#922)" {
  # A section may summarise with a `| Category | Tests |` table instead of
  # a row each. Reading those cells as test names would invent findings
  # for rows that were never claimed to be tests -- so a DECLARED summary
  # contributes no rows, and the row count proves it.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  _write_exempt 'test/bats/unit/beta_spec.bats|grouped by concern; 40 rows would be noise'
  run _run_catalog_description
  assert_success
  assert_output --partial '1 rows checked'
}

# ════════════════════════════════════════════════════════════════════
# Reach: every generated section is governed or declared exempt
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: FAILS on a section with no per-test table that nobody declared (#922)" {
  # The hole the rule had: a section the parser did not recognise as a
  # catalogue was outside the rule by TABLE SHAPE, silently and with no
  # reason recorded, so 45% of the suite could sit outside a REQUIRED
  # field and the green line said nothing. Being outside the rule is now
  # something somebody has to write down.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  run _run_catalog_description
  assert_failure
  assert_output --partial 'test/bats/unit/beta_spec.bats'
  assert_output --partial "${_CATALOG_DESC_EXEMPT_FILE}"
}

@test "_run_catalog_description: a section with NO table at all must be declared too (#922)" {
  # Prose-only was the other 25 sections and 820 tests. The rule is about
  # the section, not about which table shape it happens to carry, so
  # answering with no table at all is not a way around it.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  printf '\n### test/bats/unit/beta_spec.bats (12)\n\nCovers the beta paths.\n' \
    >> "${CATALOG}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'test/bats/unit/beta_spec.bats'
}

@test "_run_catalog_description: converting a per-test table to a summary is not a silent opt-out (#922)" {
  # The exemption is reachable as an escape hatch on a section that is
  # already covered: replace 32 described rows with a three-line summary
  # and they leave the rule. That edit now fails until somebody declares
  # the section and says why, which is a line a reviewer sees.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 32
  run _run_catalog_description
  assert_failure
  local _first="${output}"
  _write_exempt 'test/bats/unit/beta_spec.bats|deliberately summarised, see the section prose'
  run _run_catalog_description
  assert_success
  [[ "${_first}" != "${output}" ]]
}

@test "_run_catalog_description: FAILS a declared exemption that gives no reason (#922)" {
  # An exemption without a reason is the same silence in a file, one
  # indirection further away. The placeholder the rule refuses in a row is
  # refused here for the same reason.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  _write_exempt 'test/bats/unit/beta_spec.bats|-'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'reason'
}

@test "_run_catalog_description: FAILS a stale exemption whose section now has a per-test table (#922)" {
  # The same ratchet the baseline gets: giving a summarised section real
  # rows forces its exemption line out in the same commit, so the file
  # cannot quietly keep excuses for sections that no longer need them.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_exempt 'test/bats/unit/alpha_spec.bats|summarised'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'stale'
}

@test "_run_catalog_description: FAILS a stale exemption whose section is GONE (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_exempt 'test/bats/unit/gone_spec.bats|summarised'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'stale'
}

@test "_run_catalog_description: FAILS when the exemptions file miscounts its own entries (#922)" {
  # Growing the exempt set is the move that shrinks the rule's reach, so
  # it costs the same declared number the baseline costs.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  {
    printf '# entries: 0\n'
    printf 'test/bats/unit/beta_spec.bats\tsummarised\n'
  } > "${SCRATCH}/${_CATALOG_DESC_EXEMPT_FILE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries'
}

@test "_run_catalog_description: DIES when the exemptions file is missing (#922)" {
  # Same standard as the baseline: the file missing changes what the lint
  # MEANS -- every section outside the rule would fail at once -- and that
  # should say so rather than arrive as a wall of findings.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  rm -f "${SCRATCH}/${_CATALOG_DESC_EXEMPT_FILE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_EXEMPT_FILE}"
  # The path alone does not distinguish this from the ordinary violation
  # message, which names the file too -- so the DIE's own sentence is what
  # is asserted: this is the file missing, not a section failing.
  assert_output --partial 'a record of decisions somebody made, not a cache'
}

@test "_run_catalog_description: the clean line says how much of the suite sits OUTSIDE the rule (#922)" {
  # The half the old report never had. A green line over 1736 rows said
  # nothing about the 1426 tests the rule did not reach, and a reach
  # nobody can see is a reach nobody defends.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  _write_exempt 'test/bats/unit/beta_spec.bats|grouped by concern'
  run _run_catalog_description
  assert_success
  assert_output --partial '1 section(s)'
  assert_output --partial '40 test(s)'
}

@test "_run_catalog_description: a name containing a PIPE is matched against the baseline unescaped (#922)" {
  # The row renders the name with the table escaping the generator applies
  # (`\|`); the baseline records the name as bats reports it. The two only
  # ever meet if the lint undoes that escaping exactly as the generator
  # applied it, which is why the splitter is the generator's own function
  # and not a second copy of it.
  _write_catalog 'test/bats/unit/alpha_spec.bats' '| `alpha a \| b` | - |'
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha a | b'
  run _run_catalog_description
  assert_success
}

@test "_run_catalog_description: a name containing a BACKTICK is matched against the baseline (#922)" {
  # The other half of the same escaping contract: a name with a backtick is
  # rendered in a double-backtick span so the span still closes where it
  # should, and the fence is not part of the name.
  _write_catalog 'test/bats/unit/alpha_spec.bats' '| ``alpha `x` beta`` | - |'
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha `x` beta'
  run _run_catalog_description
  assert_success
}

@test "_run_catalog_description: a PIPE inside a description does not truncate it (#922)" {
  # Splitting from the right instead of at the first unescaped `|` would
  # cut this description in half and, for a short enough one, leave an
  # empty cell -- a finding invented by the reader.
  #
  # `assert_success` alone does not pin that: a described row is the one
  # case the lint says nothing about, so ANY reading that leaves two
  # non-empty cells passes, including one that puts half the description
  # in the name. So the reading itself is asserted, through the same
  # shared splitter the driver calls -- break the split and this goes red
  # on the name, not just on a count.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    '| `alpha` | Guards the `a | b` split |'
  run _run_catalog_description
  assert_success
  local _name='' _desc=''
  _catalog_cell_split_into _name _desc '| `alpha` | Guards the `a | b` split |'
  [[ "${_name}" == 'alpha' ]] \
    || fail "the name cell ended at the wrong pipe: ${_name}"
  [[ "${_desc}" == 'Guards the `a | b` split' ]] \
    || fail "the description was truncated: ${_desc}"
}

@test "_run_catalog_description: a table under no spec section is not scanned (#922)" {
  # TEST.md's own index tables are `| Lint | ... |` shaped and belong to
  # no spec; only a table under a generated `### <path> (N)` heading is a
  # catalog.
  {
    printf '# Test index\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `not a catalog row` | - |\n'
  } > "${CATALOG}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'no catalog rows'
}

@test "_run_catalog_description: scans EVERY catalog in the directory, not just one (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '# Integration Tests\n\n'
    printf '### test/bats/integration/gamma_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `gamma does a thing` | - |\n'
  } > "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/integration.md"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'gamma does a thing'
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: DIES when the catalog directory is missing (#922)" {
  rm -rf "${SCRATCH:?}/${_CATALOG_DESC_DOC_DIR}"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_DOC_DIR}"
}

@test "_run_catalog_description: DIES when the baseline file is missing (#922)" {
  # A missing baseline would fail every predating row at once rather than
  # pass vacuously, but it is still the file's shape changing under the
  # lint, and it should say so instead of burying it in 1517 findings.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  rm -f "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_BASELINE_FILE}"
  # Same standard as the exemptions case: the ordinary violation message
  # names this file as well, so the assertion is on the DIE's own words.
  assert_output --partial 'a record of what was already there, not a cache'
}

@test "_run_catalog_description: the clean line says how many rows it checked and excused (#922)" {
  # A green line standing for zero inspected rows is the vacuous pass this
  # repo keeps having to fix, so the count that was actually measured is
  # printed next to the count the baseline took off the table.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')" \
    "$(_row 'beta does another thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|beta does another thing'
  run _run_catalog_description
  assert_success
  assert_output --partial '2 rows checked'
  assert_output --partial '1 still on the baseline'
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: the real doc/test catalogs are clean (#922)" {
  REPO_ROOT=/source
  run _run_catalog_description
  assert_success
}

@test "_run_catalog_description: every spec has exactly ONE section in the real catalogues (#922)" {
  # Read straight off the documents rather than through the driver, so a
  # regression in the driver's own duplicate check cannot take this pin
  # down with it. doc/test/unit.md carried a second, empty copy of one
  # heading for a day; the generator filled it and the baseline swallowed
  # the result.
  local _dupes
  _dupes="$(grep -hE '^#{3,6} [^ ]+\.bats \([0-9]+\)$' /source/doc/test/*.md \
    | sed -E 's/ \([0-9]+\)$//' | LC_ALL=C sort | uniq -d)"
  [[ -z "${_dupes}" ]] || fail "two sections for one spec: ${_dupes}"
}

@test "_run_catalog_description: the rows the changelog-entry lint added are described, not baselined (#922)" {
  # The rows that prompted the rule. They landed the same week, so the
  # author's intent was still recoverable, which is why they were written
  # rather than parked -- and pinning that here stops a later sweep from
  # quietly moving them onto the baseline.
  run grep -c '(#917)' "/source/${_CATALOG_DESC_BASELINE_FILE}"
  assert_output '0'
}
