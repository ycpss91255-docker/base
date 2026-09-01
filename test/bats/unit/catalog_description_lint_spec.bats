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
#   - The guard is RATCHETED, not a wall. 714 rows carried the placeholder
#     when the rule landed, and the baseline has grown twice since --
#     deliberately, visibly, and recorded with its dates in the file's own
#     header; failing all of them would hold everyone hostage to a
#     backfill nobody asked for, and a rushed
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

# _bats_sections_in <doc> -- how many generated `### <spec> (N)` sections
# doc/test/<doc> carries, read off the document itself.
_bats_sections_in() {
  local _doc="${1}" _n
  _n="$(grep -cE '^#{3,6} [^ ]+\.bats \([0-9]+\)$' "/source/doc/test/${_doc}")" \
    || true
  [[ "${_n}" =~ ^[0-9]+$ ]] && (( _n > 0 )) \
    || { fail "doc/test/${_doc} carries no generated spec section: '${_n}'"; return 1; }
  printf '%s' "${_n}"
}

# _driver_header_text <file> -- the file's leading comment block as one
# line, comment markers stripped. Assertions over prose read this rather
# than the raw file: where a sentence wraps is a formatting choice, and a
# pin that a re-wrap can break is a pin people delete.
_driver_header_text() {
  awk 'NR > 1 && !/^#/ { exit } { sub(/^# ?/, ""); printf "%s ", $0 }' "${1}"
}

# _index_credit <doc> -- how many tests doc/test/TEST.md's index credits
# doc/test/<doc> with. The index is regenerated from the spec files and
# drift-gated, so it is the tree's own answer rather than this spec's
# arithmetic.
_index_credit() {
  local _doc="${1}" _n
  _n="$(sed -n "s/^| \[${_doc}\](${_doc}) |.*| \([0-9]\{1,\}\) |\$/\1/p" \
    /source/doc/test/TEST.md)"
  [[ "${_n}" =~ ^[0-9]+$ ]] \
    || { fail "doc/test/TEST.md credits no test count to ${_doc}: '${_n}'"; return 1; }
  printf '%s' "${_n}"
}

# The SHAPE of a finding line. Every report the driver prints leads with
# the repo-relative file it is about -- `<rel>: ...` or `<rel>:<line>: ...`
# -- and nothing else a run emits does: the banner it opens with
# (`--- Running ... ---`) and the clean line it ends with (`catalog
# description lint: clean (...)`) both put a space before their first
# colon, and the dispatcher's ERROR line leads with an ISO timestamp whose
# colons are each followed by a digit.
#
# Selecting that shape rather than SUBTRACTING today's known non-findings
# is what makes the floor below real. Subtracting only the ERROR line left
# the banner in, and the banner is unconditional: the population could
# never be empty, so the floor was dead code and a refutation could hold
# over a run that reported nothing at all. It also keeps the next line the
# driver learns to print from silently counting as a report.
_CATALOG_DESC_FINDING_RE='^[^[:space:]]+: '

# _finding_lines -- the lint's OWN finding lines from ${output}, one per
# line, on stdout. grep exit 1 is a legitimately EMPTY population and is
# handed back as an empty string with status 0; any other non-zero status
# means the output could not be read, and is returned rather than being
# rounded down to "no match".
_finding_lines() {
  local _out _rc=0
  _out="$(printf '%s\n' "${output}" | grep -E "${_CATALOG_DESC_FINDING_RE}")" \
    || _rc=$?
  (( _rc <= 1 )) || return "${_rc}"
  printf '%s' "${_out}"
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
# equally. This asserts against the finding lines alone, so a report that
# is not emitted is a red test.
#
# A run that emitted no finding line FAILS here rather than being skipped:
# nothing found is not a pass.
#
# Every branch RETURNS after `fail`. bats disables errexit inside `run`,
# so a bare `fail` there prints its message and lets the function fall
# through to its own exit status -- which is how the floor above could
# report the right diagnosis and still be read as a pass.
assert_finding() {
  local _needle="${1}" _lines _rc=0
  _lines="$(_finding_lines)" || _rc=$?
  (( _rc == 0 )) \
    || { fail "assert_finding: could not read the run output (grep exit ${_rc})"; return 1; }
  [[ -n "${_lines}" ]] \
    || { fail "assert_finding: the run printed no finding line at all, only its banner and the dispatcher summary; wanted '${_needle}'"; return 1; }
  printf '%s\n' "${_lines}" | grep -qF -- "${_needle}" \
    || { fail "$(printf 'assert_finding: no finding line contains %s\n--- findings ---\n%s' "'${_needle}'" "${_lines}")"; return 1; }
  return 0
}

# refute_finding <text> -- the mirror: no finding line mentions <text>.
# The same population floor applies, so a run that reported nothing at all
# cannot satisfy it by silence.
refute_finding() {
  local _needle="${1}" _lines _rc=0
  _lines="$(_finding_lines)" || _rc=$?
  (( _rc == 0 )) \
    || { fail "refute_finding: could not read the run output (grep exit ${_rc})"; return 1; }
  [[ -n "${_lines}" ]] \
    || { fail "refute_finding: the run printed no finding line at all, so the refutation would hold vacuously; wanted findings that omit '${_needle}'"; return 1; }
  printf '%s\n' "${_lines}" | grep -qF -- "${_needle}" \
    && { fail "$(printf 'refute_finding: a finding line contains %s\n--- findings ---\n%s' "'${_needle}'" "${_lines}")"; return 1; }
  return 0
}

# ════════════════════════════════════════════════════════════════════
# The helpers' own floor
# ════════════════════════════════════════════════════════════════════
#
# The two cases below are the reason the helpers exist. Every other case
# in this file leans on them to tell "the lint reported X" apart from
# "the run mentioned X somewhere", and a helper that counts a line the
# driver prints on EVERY run -- pass or fail -- cannot do that: its
# population is never empty, so the floor it advertises is unreachable
# and a refutation holds by silence.

@test "assert_finding: the lines every run prints are not findings (#922)" {
  # A clean run emits exactly two lines, the banner it opens with and the
  # summary it ends with, and neither is a report about a row. If either
  # counts, a needle drawn from it passes over a run that found nothing.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'The load-bearing case: nothing else holds without it')"
  run _run_catalog_description
  assert_success
  # ${output} is only overwritten once the call returns, so the helper
  # under test still reads the clean run above. The probes restore it
  # between attempts because the first one leaves its own failure message
  # -- which quotes the findings dump -- in ${output}.
  local _clean="${output}"
  run assert_finding 'Running catalog description lint'
  assert_failure
  assert_output --partial 'no finding line at all'
  output="${_clean}"
  run assert_finding 'rows checked'
  assert_failure
  assert_output --partial 'no finding line at all'
}

@test "refute_finding: a run that reported NOTHING cannot satisfy it (#922)" {
  # The mirror, and the one that matters: a refutation is the assertion
  # that silently becomes true when the subject stops being scanned at
  # all. Nothing found is a failure here, never a pass.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'The load-bearing case: nothing else holds without it')"
  run _run_catalog_description
  assert_success
  run refute_finding 'alpha does a thing'
  assert_failure
  assert_output --partial 'no finding line at all'
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
  # somebody remembers this case. Four of the seven were unexercised under
  # the hand-written fixture this replaces: it fed `n/a`, `TBD` and
  # `TODO`, leaving `na`, `nil`, `none` and `unknown`. Cutting the list to
  # `n/a|tbd|todo` left the spec green while `nil`, `none` and `unknown`
  # went back to passing -- `na` stays caught by the word rule either way.
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
  # Three figures in that header are LIVE -- how many rows the baseline
  # parks, how many sections are declared outside the per-test rule, and
  # what deleting one catalogue would take out of the rule, which the
  # header names doc/test/system.md to make concrete. Each is declared by
  # a file this lint already holds exact, so they are read from there
  # rather than retyped here, and a header that falls behind any of them
  # is red. Every other figure in the header is a measurement of a past
  # tree and carries its date: no checkout can re-measure those, and
  # pinning a figure that moves with every added test would buy
  # drift-detection with a treadmill. The case below holds the header to
  # exactly that division.
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
  local _header
  _header="$(_driver_header_text "${_driver}")"
  [[ -n "${_header}" ]] \
    || { fail "the driver header is empty -- nothing was read to check"; return 1; }
  printf '%s\n' "${_header}" \
    | grep -qF "The baseline parks ${_baseline_n} rows" \
    || fail "the driver header does not say the baseline parks ${_baseline_n} rows"
  printf '%s\n' "${_header}" \
    | grep -qF "${_exempt_n} sections declared outside the per-test rule" \
    || fail "the driver header does not say ${_exempt_n} sections are declared out"
  # The illustration the reach paragraph turns on. Both halves come from
  # the tree: the sections from the document itself, the tests from the
  # index row that credits it -- the same index the driver reads, so a
  # catalogue that grows a section or a test moves this figure the day it
  # lands rather than the day somebody remembers the header.
  local _system_sections _system_tests
  _system_sections="$(_bats_sections_in 'system.md')"
  _system_tests="$(_index_credit 'system.md')"
  printf '%s\n' "${_header}" \
    | grep -qF "its ${_system_sections} sections and the ${_system_tests} tests" \
    || fail "the driver header does not say doc/test/system.md accounts for ${_system_sections} sections and ${_system_tests} tests"
}

@test "_run_catalog_description: every figure in the driver header is dated or pinned (#922)" {
  # The header states the rule the case above enforces figure by figure:
  # a figure is either LIVE and read back from the file that declares it,
  # or a measurement of a past tree carrying the date it was taken. What
  # nothing checked was the rule itself, and three figures had quietly
  # left it -- an undated "40% of rows" that was 41% when written and 59%
  # by the time it was read, an undated "1500-line file", and an undated
  # "12 tests" against a document that holds 13.
  #
  # So the header is READ rather than reviewed. Every paragraph of it is
  # scanned, every figure it states is collected -- at any width, a lone
  # digit included -- and a figure is a finding unless its paragraph
  # carries an ISO date or the figure is one of the live values derived
  # below. Deriving the paragraphs from the file means a paragraph added
  # tomorrow is scanned the day it lands.
  local _driver='/source/script/test/drivers/catalog_description.sh'
  local -a _pinned=()
  _pinned+=("$(sed -n 's/^# entries: \([0-9]\{1,\}\)$/\1/p' \
    "/source/${_CATALOG_DESC_BASELINE_FILE}")")
  _pinned+=("$(sed -n 's/^# entries: \([0-9]\{1,\}\)$/\1/p' \
    "/source/${_CATALOG_DESC_EXEMPT_FILE}")")
  _pinned+=("$(_bats_sections_in 'system.md')")
  _pinned+=("$(_index_credit 'system.md')")
  # The enumerator exemption is BOUNDED, and the bound is the whole
  # point of it. An unbounded strip -- any run of digits at the head of
  # any header line, followed by ". " -- silently swallows a figure that
  # merely landed at the head of a re-wrapped line, which is exactly how
  # a sentence-final "... numbered\n# 9999. That figure ..." gets past a
  # guard whose name promises every figure. So the strip demands what
  # this header's list items actually look like: at least two columns of
  # indentation, then a one- or two-digit enumerator, then ". ". Nothing
  # is ever dropped from column zero, where prose lives.
  local _para_awk='
    NR > 1 && !/^#/ { exit }
    /^#$/ { if (_p != "") { print _p }; _p = ""; next }
    { sub(/^# ?/, ""); sub(/^[ ][ ]+[0-9][0-9]?\. /, ""); _p = _p " " $0 }
    END { if (_p != "") { print _p } }'
  # Both halves of that bound, probed on the SAME awk program the scan
  # runs, so a bound that widens back out fails here rather than going
  # quiet: the indented enumerator is dropped, the sentence-final figure
  # at column zero survives.
  local _probe
  _probe="$(printf '%s\n' '#!/usr/bin/env bash' '# the sweep reached' \
    '# 9999. that is sentence-final' '#' '#   1. an enumerated item' \
    | awk "${_para_awk}")"
  [[ "${_probe}" == $' the sweep reached 9999. that is sentence-final\n an enumerated item' ]] \
    || { fail "$(printf 'the header paragraph builder no longer bounds the enumerator exemption; it produced:\n%s\n' "${_probe}")"; return 1; }
  local -a _paras=()
  mapfile -t _paras < <(awk "${_para_awk}" "${_driver}")
  (( ${#_paras[@]} > 0 )) \
    || { fail "the driver header has no paragraphs -- the scan read nothing"; return 1; }
  # A figure is ANY run of digits, or a percentage. Width is the wrong
  # exemption: it made every one-digit measurement invisible, so a
  # sentence stating "the scan reached 9 catalogues" passed undated and
  # unpinned. The one thing that is genuinely not a figure -- the "1."
  # / "2." enumerator of this header's ordered lists -- is exempted by
  # the bounded POSITION rule above, which leaves a digit anywhere
  # inside a sentence collected.
  #
  # "41%" is collected as one figure and not as a bare "41". The
  # alternation ORDER buys nothing either way: ERE matching is
  # leftmost-longest, so '[0-9]+%|[0-9]+' and '[0-9]+|[0-9]+%' behave
  # identically, and a reader who reorders them breaks nothing. What is
  # worth pinning is the outcome, not the ordering, so the probe below
  # asserts it instead of a comment claiming it.
  local _fig_re='[0-9]+%|[0-9]+'
  # The width the scan promises, probed rather than assumed: this is the
  # exact sentence the narrower pattern let through.
  [[ "$(printf '%s\n' 'the scan reached 9 catalogues' \
    | grep -oE "${_fig_re}")" == '9' ]] \
    || { fail "the figure pattern '${_fig_re}' does not collect a one-digit measurement"; return 1; }
  [[ "$(printf '%s\n' 'it parked 41% of rows' \
    | grep -oE "${_fig_re}")" == '41%' ]] \
    || { fail "the figure pattern '${_fig_re}' splits a percentage into a bare number"; return 1; }
  local _para _figs _fig _p _ok _raw _status _with_figures=0
  local -a _bad=() _seen=()
  for _para in "${_paras[@]}"; do
    # grep's status is pinned: 0 found, 1 none in THIS paragraph (normal,
    # the population floor below is what refuses an empty scan), and
    # anything else is the scan erroring rather than finding nothing.
    _raw="$(printf '%s\n' "${_para}" | grep -oE "${_fig_re}")" \
      && _status=0 || _status=$?
    (( _status <= 1 )) \
      || { fail "the figure scan errored (grep exit ${_status}) on: ${_para:0:80}"; return 1; }
    [[ -n "${_raw}" ]] || continue
    _figs="$(printf '%s\n' "${_raw}" | LC_ALL=C sort -u | tr '\n' ' ')"
    _with_figures=$(( _with_figures + 1 ))
    for _fig in ${_figs}; do
      _seen+=("${_fig}")
    done
    # A dated paragraph is a measurement of a tree this checkout does not
    # have, and every figure in it is that measurement.
    [[ "${_para}" =~ 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]] && continue
    for _fig in ${_figs}; do
      _ok=0
      for _p in "${_pinned[@]}"; do
        [[ "${_fig}" == "${_p}" ]] && _ok=1
      done
      (( _ok )) \
        || _bad+=("${_fig} -- in: ${_para:0:120}")
    done
  done
  # The population floor. The scan must have found figures at all, and it
  # must have found the live baseline count -- which sits in the ratchet
  # paragraph near the top -- so a scan that silently read an empty or
  # truncated header is a failure here rather than a clean sweep.
  (( _with_figures > 0 )) \
    || { fail "no paragraph in the driver header states a figure -- the scan found nothing to check"; return 1; }
  [[ " ${_seen[*]} " == *" ${_pinned[0]} "* ]] \
    || { fail "the scan never saw the live baseline figure ${_pinned[0]}; it is not reading the header it claims to (${_with_figures} paragraph(s) with figures)"; return 1; }
  # And it must have seen the reach paragraph's section count, which is a
  # short figure: the scan that missed one-digit measurements collected
  # every other figure in the header and still looked healthy here.
  [[ " ${_seen[*]} " == *" ${_pinned[2]} "* ]] \
    || { fail "the scan never saw the live section figure ${_pinned[2]} the reach paragraph states; a figure of that width is escaping it"; return 1; }
  (( ${#_bad[@]} == 0 )) \
    || { fail "$(printf 'figures in the driver header that are neither dated nor pinned:\n%s\n' "$(printf '  %s\n' "${_bad[@]}")")"; return 1; }
}

@test "_run_catalog_description: the driver's own comment lines wrap at 80 columns (#922)" {
  # Narrow on purpose. This case is about THIS driver's prose and says so
  # in its name; it makes no claim about any other file. Within that file
  # the population is derived rather than listed -- every comment line
  # the file holds, header and body alike, read off the file itself -- so
  # a comment added or re-wrapped tomorrow is measured the day it lands.
  #
  # Comments only. A CODE line over the limit here is a single-string
  # failure message, and breaking one would either change the text or
  # make it ungreppable; that is a different argument and this case does
  # not take it. Prose has no such excuse: it re-wraps for free, and a
  # 100-column paragraph in a file that wraps at about 72 everywhere else
  # is what an edit that never reflowed leaves behind. Nothing else in
  # the gate measures comment width, so a re-wrap that misses a line is
  # otherwise found only by a reader who happens to look.
  local _driver='/source/script/test/drivers/catalog_description.sh'
  local _scanned _stripped _over _status
  _scanned="$(grep -cE '^[[:space:]]*#' "${_driver}")" && _status=0 || _status=$?
  (( _status == 0 )) \
    || { fail "reading the comment lines of ${_driver} failed (grep exit ${_status}) -- the scan found no file to measure"; return 1; }
  (( _scanned > 100 )) \
    || { fail "only ${_scanned} comment line(s) read from ${_driver}; it is not the file this case claims to measure"; return 1; }
  # The measure is CHARACTERS, and it is pinned to be characters rather
  # than left to the image. awk's length() counts characters only when
  # the awk that answers `awk` and the runner's locale are both
  # UTF-8-aware, and this image installs busybox awk, mawk and gawk side
  # by side (dockerfile/Dockerfile.test-tools) -- so which of them
  # answers, and under which locale, is an image detail this case must
  # not silently depend on. Under a byte-counting awk the five
  # box-drawing section rules in this driver (U+2500, three bytes each)
  # measure 109-198 "columns" while being about 74 wide, and five
  # correctly wrapped lines turn red.
  #
  # So the stream is forced to C -- where every one of those awks counts
  # bytes, deterministically -- and every UTF-8 continuation byte is
  # deleted first. One byte per character, for any awk, in any locale.
  local _probe
  _probe="$(printf '%s\n' '──────────' \
    | LC_ALL=C tr -d '\200-\277' | LC_ALL=C awk '{ print length($0) }')"
  [[ "${_probe}" == '10' ]] \
    || { fail "the width measure reports ${_probe} for a 10-character rule of U+2500; it is measuring bytes, not columns"; return 1; }
  # Deleting continuation bytes cannot add or remove a newline, so the
  # measured stream must still hold exactly the comment lines counted
  # above; if it does not, the normalisation ate the population.
  _stripped="$(LC_ALL=C tr -d '\200-\277' < "${_driver}" \
    | grep -cE '^[[:space:]]*#')"
  (( _stripped == _scanned )) \
    || { fail "normalising ${_driver} to one byte per character left ${_stripped} comment line(s) of ${_scanned}; the measured stream is not the file"; return 1; }
  _over="$(LC_ALL=C tr -d '\200-\277' < "${_driver}" \
    | LC_ALL=C awk 'length($0) > 80 && /^[[:space:]]*#/ { print NR "\t" length($0) }')"
  if [[ -n "${_over}" ]]; then
    local _report='' _n _w
    while IFS=$'\t' read -r _n _w; do
      _report+="  ${_n} (${_w} cols): $(sed -n "${_n}p" "${_driver}")"$'\n'
    done <<< "${_over}"
    fail "$(printf 'comment lines over 80 columns (%d scanned):\n%s' "${_scanned}" "${_report}")"
  fi
}

@test "_run_catalog_description: the header's reason for keying on the spec path still holds (#922)" {
  # The header rejects keying the baseline by test NAME because names in
  # this tree already collide across specs, so one baseline line would
  # excuse a row nobody looked at. That is a claim about the tree, not
  # about a past one: if the collisions ever go away the justification
  # has to be restated rather than left standing. Counted, not listed --
  # the pairs come from the spec files themselves.
  local _names _dupes
  _names="$(grep -rhE '^@test "' /source/test/bats --include='*.bats' | wc -l)"
  (( _names > 0 )) \
    || { fail "no @test lines found under test/bats -- the scan read nothing"; return 1; }
  _dupes="$(grep -rE '^@test "' /source/test/bats --include='*.bats' \
    | sed -E 's/^([^:]+):@test "(.*)" *\{ *$/\2\t\1/' \
    | LC_ALL=C sort -u | cut -f1 | LC_ALL=C uniq -d)"
  [[ -n "${_dupes}" ]] \
    || { fail "no test name lives in two specs at once (${_names} tests scanned), so the driver header's reason for keying the baseline by spec path plus name no longer holds -- restate it"; return 1; }
}

@test "_run_catalog_description: the rows the changelog-entry lint added are described, not baselined (#922)" {
  # The rows that prompted the rule. They landed the same week, so the
  # author's intent was still recoverable, which is why they were written
  # rather than parked -- and pinning that here stops a later sweep from
  # quietly moving them onto the baseline.
  run grep -c '(#917)' "/source/${_CATALOG_DESC_BASELINE_FILE}"
  assert_output '0'
}
