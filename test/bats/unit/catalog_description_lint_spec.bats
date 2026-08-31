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
  # TEST.md is the index: it is what says which catalogues doc/test/ is
  # supposed to have, so the scan cannot be bounded by whichever files
  # happen to exist. The fixture keeps it in step with the sections the
  # helpers write; a case that writes a document by hand says so itself.
  declare -gA INDEX=()
  _index_render
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
  _index_set 'unit.md' "$#"
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
  _index_add 'unit.md' "${2}"
}

# _index_render -- write the scratch TEST.md index from INDEX, one row per
# document, the way sync-doc-counts.sh renders the real one.
_index_render() {
  local _doc
  {
    printf '# TEST.md\n\n## Test Docs by Level / Type\n\n'
    printf '| Doc | Scope | Count |\n|-----|-------|-------|\n'
    if [[ "${#INDEX[@]}" -gt 0 ]]; then
      while IFS= read -r _doc; do
        printf '| [%s](%s) | scratch | %s |\n' \
          "${_doc}" "${_doc}" "${INDEX[${_doc}]}"
      done < <(printf '%s\n' "${!INDEX[@]}" | LC_ALL=C sort)
    fi
  } > "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/TEST.md"
}

# _non_answer_tokens -- the written-out non-answers the driver refuses,
# read out of _CATALOG_DESC_NON_ANSWERS_RE instead of retyped. The
# population the vocabulary case exercises is derived from the rule it is
# testing, which is what makes it cover a token added later.
_non_answer_tokens() {
  local _re="${_CATALOG_DESC_NON_ANSWERS_RE}"
  _re="${_re#^(}"
  _re="${_re%)$}"
  printf '%s\n' "${_re//|/$'\n'}"
}

# _index_set <doc> <tests> / _index_add <doc> <tests> -- keep the index in
# step with the sections a case writes.
_index_set() {
  INDEX["${1}"]="${2}"
  _index_render
}

_index_add() {
  INDEX["${1}"]=$(( ${INDEX["${1}"]:-0} + ${2} ))
  _index_render
}

# assert_finding <text> -- <text> appears in one of the lint's OWN finding
# lines, not merely somewhere in the run's output.
#
# Why not `assert_output --partial`. Every failing run ends with the
# dispatcher's catch-all _die message, which restates the whole rule and
# therefore carries the words 'reason', 'stale', 'entries', 'duplicate',
# 'described', 'malformed', 'TEST.md', 'doc/test' and both sidecar paths.
# A --partial over the whole output is satisfied by ANY failing run, so
# deleting a specific finding's printf left this spec green: the positive
# and the negative case produced output that satisfied the assertion
# equally. This drops the ERROR log line the driver dies with and asserts
# against what is left, so a report that is not emitted is a red test.
#
# A run whose only output is that summary FAILS here rather than being
# skipped: nothing found is not a pass.
assert_finding() {
  local _needle="${1}" _lines _rc=0
  _lines="$(printf '%s\n' "${output}" | grep -v '\] ERROR: ')" || _rc=$?
  (( _rc <= 1 )) \
    || fail "assert_finding: could not read the run output (grep exit ${_rc})"
  [[ -n "${_lines}" ]] \
    || fail "assert_finding: the run printed no finding line at all, only the dispatcher summary; wanted '${_needle}'"
  printf '%s\n' "${_lines}" | grep -qF -- "${_needle}" \
    || fail "$(printf 'assert_finding: no finding line contains %s\n--- findings ---\n%s' "'${_needle}'" "${_lines}")"
}

# refute_finding <text> -- the mirror: no finding line mentions <text>.
# The same population floor applies, so a run that reported nothing at all
# cannot satisfy it by silence.
refute_finding() {
  local _needle="${1}" _lines _rc=0
  _lines="$(printf '%s\n' "${output}" | grep -v '\] ERROR: ')" || _rc=$?
  (( _rc <= 1 )) \
    || fail "refute_finding: could not read the run output (grep exit ${_rc})"
  [[ -n "${_lines}" ]] \
    || fail "refute_finding: the run printed no finding line at all, so the refutation would hold vacuously; wanted findings that omit '${_needle}'"
  printf '%s\n' "${_lines}" | grep -qF -- "${_needle}" \
    && fail "$(printf 'refute_finding: a finding line contains %s\n--- findings ---\n%s' "'${_needle}'" "${_lines}")"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# The rule: a placeholder row fails
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: FAILS on a placeholder row that is not on the baseline (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  run _run_catalog_description
  assert_failure
  assert_finding 'alpha does a thing'
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
  assert_finding "${_CATALOG_DESC_DOC_DIR}/unit.md:${_line}:"
  assert_finding 'test/bats/unit/alpha_spec.bats'
}

@test "_run_catalog_description: reports EVERY undescribed row, not just the first (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' '-')" \
    "$(_row 'beta does another thing' '-')"
  run _run_catalog_description
  assert_failure
  assert_finding 'alpha does a thing'
  assert_finding 'beta does another thing'
}

@test "_run_catalog_description: an EMPTY description cell counts as a placeholder (#922)" {
  # `-` is what the generator writes; a hand-edited row can be blank, and
  # a blank cell is the same missing sentence wearing less ink.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '')"
  run _run_catalog_description
  assert_failure
  assert_finding 'alpha does a thing'
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
  assert_finding 'alpha does a thing'
  assert_finding 'beta does another thing'
  assert_finding 'gamma does a third thing'
  assert_output --partial '3 undescribed'
}

@test "_run_catalog_description: a one- or two-character cell has no WORD in it (#922)" {
  # Where the line actually IS. The case above feeds `.`, `--` and `...`,
  # cells with ZERO alphanumerics, which a rule of "at least one alnum"
  # would refuse just as happily -- so it says nothing about the three
  # the rule asks for. `x` and `ab` are the cells that separate a
  # three-character run from any run at all, and `a b` pins the run as
  # CONTIGUOUS. The short-honest-description case below is the other
  # side: "GPU on" has to keep passing, so the threshold cannot climb
  # either.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'x')" \
    "$(_row 'beta does another thing' 'ab')" \
    "$(_row 'gamma does a third thing' 'a b')"
  run _run_catalog_description
  assert_failure
  assert_finding 'alpha does a thing'
  assert_finding 'beta does another thing'
  assert_finding 'gamma does a third thing'
  assert_output --partial '3 undescribed'
}

@test "_run_catalog_description: EVERY written-out non-answer is refused (#922)" {
  # The same silence spelled with letters. The rows are DERIVED from
  # _CATALOG_DESC_NON_ANSWERS_RE rather than retyped, so a token added
  # tomorrow is exercised the day it is added rather than the day
  # somebody remembers this case -- three of the seven were unexercised
  # under the hand-written fixture this replaces, and cutting the list to
  # `n/a|tbd|todo` left the spec green while `nil`, `none` and `unknown`
  # went back to passing.
  local -a _tokens=()
  mapfile -t _tokens < <(_non_answer_tokens)
  # Deriving the fixture from the rule means SHRINKING the rule would
  # shrink the fixture with it and stay green, so the vocabulary itself
  # is compared first. It is written out because it is a decision about
  # English, not a set the tree can be asked for: growing it is a
  # deliberate edit of this line, and a token deleted or retyped is red
  # here rather than silently untested.
  assert_equal \
    "$(printf '%s\n' "${_tokens[@]}" | LC_ALL=C sort | tr '\n' ' ')" \
    'n/a na nil none tbd todo unknown '
  local -a _rows=()
  local _i
  for (( _i = 0; _i < ${#_tokens[@]}; _i++ )); do
    _rows+=("$(_row "case ${_i} matters" "${_tokens[_i]}")")
  done
  _write_catalog 'test/bats/unit/alpha_spec.bats' "${_rows[@]}"
  run _run_catalog_description
  assert_failure
  # Each row by name, not just the tally: a count alone is satisfied by
  # the right NUMBER of the wrong rows.
  for (( _i = 0; _i < ${#_tokens[@]}; _i++ )); do
    assert_finding "case ${_i} matters"
  done
  assert_output --partial "${#_tokens[@]} undescribed"
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
  assert_finding 'no reason given for the exemption'
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
  assert_finding 'alpha does a thing, renamed'
}

@test "_run_catalog_description: MOVING a baselined test to another spec forces a description (#922)" {
  # The baseline is scoped by spec path as well as name -- three test
  # names in this tree already live in two specs at once, so a name-only
  # key would excuse a row nobody ever looked at.
  _write_catalog 'test/bats/unit/beta_spec.bats' "$(_row 'alpha does a thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_finding 'beta_spec.bats'
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
  assert_finding 'stale entry, no longer an undescribed row'
}

@test "_run_catalog_description: FAILS on a baseline entry whose row is GONE (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'beta does another thing' 'Why beta matters')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_finding 'stale entry, no longer an undescribed row'
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
  assert_finding 'declares "# entries:'
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
  assert_finding 'declares "# entries:'
}

@test "_run_catalog_description: DIES when the baseline declares no count at all (#922)" {
  # Dropping the directive would turn the shrink-only lock off silently,
  # which is exactly the edit it exists to make loud.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n' > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_finding 'no "# entries: <n>" directive'
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
  assert_finding 'not sorted (LC_ALL=C)'
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
  assert_finding 'duplicate entry'
}

@test "_run_catalog_description: FAILS on a baseline line with no TAB separator (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha' '-')"
  {
    printf '# entries: 1\n'
    printf 'test/bats/unit/alpha_spec.bats alpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_finding 'malformed entry'
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
  assert_finding 'excuses a row that is DESCRIBED'
  assert_finding 'alpha does a thing'
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
  assert_finding 'duplicate section -- already opened at'
  assert_finding 'test/bats/unit/alpha_spec.bats'
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
  assert_finding 'no per-test catalogue and no declared exemption'
  assert_finding "test/bats/unit/beta_spec.bats"
}

@test "_run_catalog_description: a section with NO table at all must be declared too (#922)" {
  # Prose-only was the other 25 sections and 820 tests. The rule is about
  # the section, not about which table shape it happens to carry, so
  # answering with no table at all is not a way around it.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  printf '\n### test/bats/unit/beta_spec.bats (12)\n\nCovers the beta paths.\n' \
    >> "${CATALOG}"
  _index_add 'unit.md' 12
  run _run_catalog_description
  assert_failure
  assert_finding 'no per-test catalogue and no declared exemption'
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
  assert_finding 'no reason given for the exemption'
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
  assert_finding 'stale entry, no longer a section outside the per-test rule'
}

@test "_run_catalog_description: FAILS a stale exemption whose section is GONE (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_exempt 'test/bats/unit/gone_spec.bats|summarised'
  run _run_catalog_description
  assert_failure
  assert_finding 'stale entry, no longer a section outside the per-test rule'
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
  assert_finding 'declares "# entries:'
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

@test "_run_catalog_description: a FENCED example is not structure (#922)" {
  # This branch has just made doc/test/TEST.md the home of the convention,
  # which is exactly the document that wants a worked example of a
  # catalogue section -- and a lint that cannot be illustrated where it is
  # documented is a lint people paraphrase instead. Inside a ``` block
  # nothing is structure, the way the sibling changelog-entry lint already
  # reads its own file.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '\n## How this catalogue is maintained\n\n'
    printf '```markdown\n'
    printf '### test/bats/unit/example_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `an example row` | - |\n'
    printf '```\n'
  } >> "${CATALOG}"
  run _run_catalog_description
  assert_success
  refute_output --partial 'example_spec.bats'
}

@test "_run_catalog_description: a fenced heading does not close the section it sits in (#922)" {
  # The inverse, which is the direction that would be a HOLE rather than a
  # false positive: if a fenced `###` line closed the real section, the
  # rows after it would belong to no spec, and rows under no section are
  # not scanned at all. The row below is alpha's and has to be reported as
  # alpha's.
  {
    printf '# Unit Tests\n\n'
    printf '### test/bats/unit/alpha_spec.bats (1)\n\n'
    printf 'An example of the shape this section takes:\n\n'
    printf '~~~markdown\n'
    printf '### test/bats/unit/not_a_real_spec.bats (1)\n'
    printf '~~~\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `alpha does a thing` | - |\n'
  } > "${CATALOG}"
  _index_set 'unit.md' 1
  run _run_catalog_description
  assert_failure
  assert_finding 'test/bats/unit/alpha_spec.bats: no description'
  refute_output --partial 'not_a_real_spec.bats'
}

@test "_run_catalog_description: a fenced example does not take the REST of its table out of the rule (#922)" {
  # The hole this closes: the fence cleared _in_table and nothing put it
  # back, so every row AFTER the closing fence belonged to no table and
  # was never scanned. A three-line example dropped into a catalogue took
  # the remainder of that section's rows out of a REQUIRED field with both
  # gates green and nothing in the diff saying so -- the same silent
  # opt-out the "Reach" section exists to refuse, one level down. A fence
  # INTERRUPTS the table; it does not end it.
  {
    printf '# Unit Tests\n\n'
    printf '### test/bats/unit/alpha_spec.bats (2)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `alpha does a thing` | Why alpha matters |\n'
    printf '```markdown\n'
    printf '| `an example row` | - |\n'
    printf '```\n'
    printf '| `beta does another thing` | - |\n'
  } > "${CATALOG}"
  _index_set 'unit.md' 2
  run _run_catalog_description
  assert_failure
  assert_finding 'beta does another thing'
  # And the fenced row is still an example, not a row: resuming the table
  # must not also start scanning what the fence held.
  refute_finding 'an example row'
}

@test "_run_catalog_description: a backtick fence is not closed by a tilde one (#922)" {
  # CommonMark: a fence closes on at least as many of the SAME character.
  # The driver header states that as its contract, and the check is one
  # `[[ ]]` away from being dropped -- at which point the `~~~` line below
  # ends the block early and the row it holds becomes a finding invented
  # by the reader. The section documents its own format, so the example
  # deliberately shows the other fence character.
  {
    printf '# Unit Tests\n\n'
    printf '### test/bats/unit/alpha_spec.bats (2)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `alpha does a thing` | Why alpha matters |\n'
    printf '```markdown\n'
    printf '~~~\n'
    printf '| `an example row` | - |\n'
    printf '```\n'
    printf '| `beta does another thing` | - |\n'
  } > "${CATALOG}"
  _index_set 'unit.md' 2
  run _run_catalog_description
  assert_failure
  # The table resumes at the ``` that really closes it, so beta is still
  # reached -- which is what makes the refutation below mean something:
  # the scan did not simply stop.
  assert_finding 'beta does another thing'
  refute_finding 'an example row'
}

@test "_run_catalog_description: a longer fence is not closed by a shorter one (#922)" {
  # The other half of the same CommonMark rule: a four-backtick fence
  # needs four to close, which is exactly how a markdown example that
  # itself contains a fence is written. Drop the length check and the
  # inner ``` closes the outer one.
  {
    printf '# Unit Tests\n\n'
    printf '### test/bats/unit/alpha_spec.bats (2)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `alpha does a thing` | Why alpha matters |\n'
    printf '````markdown\n'
    printf '```\n'
    printf '| `an example row` | - |\n'
    printf '```\n'
    printf '````\n'
    printf '| `beta does another thing` | - |\n'
  } > "${CATALOG}"
  _index_set 'unit.md' 2
  run _run_catalog_description
  assert_failure
  assert_finding 'beta does another thing'
  refute_finding 'an example row'
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
  _index_set 'unit.md' 0
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
  _index_set 'integration.md' 1
  run _run_catalog_description
  assert_failure
  assert_finding 'gamma does a thing'
}

# ════════════════════════════════════════════════════════════════════
# Reach: the set of catalogues is declared, not discovered
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: a catalogue the index declares but that is GONE is a finding (#922)" {
  # The scan is a `find` over doc/test/, so a catalogue that is not there
  # is a catalogue that is not checked: deleting doc/test/system.md took
  # 12 tests out of the rule with both this lint and the doc-counts drift
  # gate green, and the clean line said nothing because it reported no
  # denominator. TEST.md is that denominator -- it is regenerated from the
  # spec tree and drift-gated, so it still names the document after the
  # document is gone.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _index_set 'system.md' 12
  run _run_catalog_description
  assert_failure
  assert_finding "declares 'system.md' (12 test(s)), which is not a catalogue under"
}

@test "_run_catalog_description: a catalogue the index does NOT name is a finding (#922)" {
  # The other direction, which is how the first one would be worked
  # around: delete the document and its index row together. The index and
  # the directory have to agree both ways or neither statement means
  # anything.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '# Integration Tests\n\n'
    printf '### test/bats/integration/gamma_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `gamma does a thing` | Why gamma matters |\n'
  } > "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/integration.md"
  run _run_catalog_description
  assert_failure
  assert_finding 'integration.md: not named by'
}

@test "_run_catalog_description: a catalogue must declare the tests the index credits it with (#922)" {
  # Deleting a whole SECTION is the narrow version of deleting the file,
  # and the same number catches it: the sections a document carries have
  # to add up to what the index says the document holds.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _index_set 'unit.md' 13
  run _run_catalog_description
  assert_failure
  assert_finding 'unit.md: its sections declare 1 test(s)'
  assert_finding 'the index credits it with 13'
}

@test "_run_catalog_description: the clean line states the reach the index declares (#922)" {
  # A reach figure the lint computes from what it happened to find is
  # circular. This one is measured against a number nothing in this driver
  # produces.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  _write_summary_section 'test/bats/unit/beta_spec.bats' 40
  _write_exempt 'test/bats/unit/beta_spec.bats|grouped by concern; 40 rows would be noise'
  run _run_catalog_description
  assert_success
  assert_output --partial '41 test(s)'
}

@test "_run_catalog_description: DIES when the index declares no catalogue at all (#922)" {
  # An empty index is a denominator of zero, and every one of the checks
  # above passes vacuously against it.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  INDEX=()
  _index_render
  run _run_catalog_description
  assert_failure
  assert_output --partial 'declares no catalogue'
}

@test "_run_catalog_description: DIES when the index file is missing (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  rm -f "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/TEST.md"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'a deleted catalogue is a catalogue with no rows to report'
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: DIES when the catalog directory is missing (#922)" {
  rm -rf "${SCRATCH:?}/${_CATALOG_DESC_DOC_DIR}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'Point it at the generated test catalogues'
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

@test "_run_catalog_description: the live figures in the driver header are the ones the files declare (#922)" {
  # This driver's subject is a document silently disagreeing with the
  # code, and its own header had been doing exactly that: "747 of 1711
  # when the rule was first written" against a measured 714 of 1736, and
  # a sentence carrying one quantity at two different times.
  #
  # Two figures in that header are LIVE -- how many rows the baseline
  # parks, and how many sections are declared outside the per-test rule.
  # Both are declared by a sidecar file this lint already holds exact, so
  # they are read from there rather than retyped here, and a header that
  # falls behind either one is red. Every other figure in the header is a
  # measurement of a past tree and carries its date: no checkout can
  # re-measure those, and pinning a figure that moves with every added
  # test would buy drift-detection with a treadmill.
  local _baseline_n _exempt_n
  _baseline_n="$(sed -n 's/^# entries: \([0-9]\{1,\}\)$/\1/p' \
    "/source/${_CATALOG_DESC_BASELINE_FILE}")"
  _exempt_n="$(sed -n 's/^# entries: \([0-9]\{1,\}\)$/\1/p' \
    "/source/${_CATALOG_DESC_EXEMPT_FILE}")"
  [[ "${_baseline_n}" =~ ^[0-9]+$ ]] \
    || fail "the baseline declares no single '# entries: <n>': ${_baseline_n}"
  [[ "${_exempt_n}" =~ ^[0-9]+$ ]] \
    || fail "the exemptions file declares no single '# entries: <n>': ${_exempt_n}"
  local _driver='/source/script/test/drivers/catalog_description.sh'
  grep -qF "The baseline parks ${_baseline_n} rows" "${_driver}" \
    || fail "the driver header does not say the baseline parks ${_baseline_n} rows"
  grep -qF "the ${_exempt_n} sections the exemptions file declares" "${_driver}" \
    || fail "the driver header does not say ${_exempt_n} sections are declared out"
}

@test "_run_catalog_description: the rows the changelog-entry lint added are described, not baselined (#922)" {
  # The rows that prompted the rule. They landed the same week, so the
  # author's intent was still recoverable, which is why they were written
  # rather than parked -- and pinning that here stops a later sweep from
  # quietly moving them onto the baseline.
  run grep -c '(#917)' "/source/${_CATALOG_DESC_BASELINE_FILE}"
  assert_output '0'
}
