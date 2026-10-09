#!/usr/bin/env bats
#
# why: The guard over the one string in a spec file that bats EVALUATES.
# base#1200 measured what a live backtick in a name costs on this tree's two
# offenders: one run of a single 124-test spec emitted 125 copies of each
# of two shell errors, and printed both names with their backticked span
# replaced by the substitution's empty stdout, so the TAP output and the
# catalogue under doc/test/ disagreed about what the suite contains. The
# noise and the divergence are the measured cost; arbitrary command
# execution at collection time, with no test selected, is the mechanism.
#
# Unit tests for script/test/drivers/test_name_backtick.sh -- the "a
# `@test` name is a literal, not a command" lint.
#
# Two properties drive the case list, and both were measured on bats 1.13.0
# rather than assumed. FIRST, the author's quoting does not matter: bats's
# preprocessor strips the quotes the source wrote and its registration site
# supplies its own double quotes around the name before eval'ing it, so a
# single-quoted name is expanded exactly like a double-quoted one -- which
# is why the driver judges the whole @test line and parses no quoting, and
# why single-quoting is not a fix for this defect even though it reads like
# one.
#
# SECOND, a backslash-escaped backtick is a literal one: the catalogue
# generator unescapes it back to a plain backtick when it renders a row, so
# nothing is executed and this lint reports nothing. It is still not the fix
# base#1200 took, because `--filter` is matched against the name as the SOURCE
# writes it, so the backslashes stay in the one string the filter sees. The
# fix is to drop the backticks and write the code span in single quotes
# inside the name, which 178 of this tree's names already do.
#
# Detection runs against a controlled temp REPO_ROOT, never the live
# checkout: the tree is asserted by the `lint-static` group that runs this
# driver, which is where a whole-tree scan belongs (base#1075).

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
  source /source/script/test/drivers/test_name_backtick.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/test/bats/unit"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
# Every fixture line is passed as a single-quoted argument and written
# verbatim, so a backtick in one reaches the file as a backtick and this
# spec's own `@test` lines (which the shipped lint scans) stay clean.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_test_name_backtick: violations
# ════════════════════════════════════════════════════════════════════

# why: The exact shape base#1200 found twice. The report has to name the file,
# the line and the column, because the author is looking for a character
# inside a long sentence
@test "_run_test_name_backtick: FAILS on a live backtick in a name, naming file, line and column" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "acceptance drives `just template new` end-to-end" {' \
    '  assert_success' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats/unit/x_spec.bats:1:26"* ]]
}

# why: The load-bearing case for the rule's shape. bats supplies its own quotes
# around the name, so a single-quoted one is expanded too -- measured, a
# single-quoted name whose backticks held an echo registered with the echo's
# output in place of them. A lint that exempted single quotes would bless
# the one spelling that reads most like the fix
@test "_run_test_name_backtick: FAILS on a single-quoted name too, because bats expands it as well" {
  _write "test/bats/unit/x_spec.bats" \
    "@test 'no monolithic \`test:\` job remains' {" \
    '  assert_success' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:1"* ]]
}

# why: An even-length backslash run leaves the backtick live -- the run escapes
# itself, not the character after it -- and reading one character back
# instead of counting the run would call this clean
@test "_run_test_name_backtick: FAILS when an EVEN backslash run leaves the backtick live" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "a literal backslash then \\`date` here" {' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:1"* ]]
}

# why: Reporting the first offender and stopping makes the lint take as many
# runs to clear as the tree has names; base#1200's own tree had two, in one
# file
@test "_run_test_name_backtick: reports EVERY offending name, not the first" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "first `echo one` name" {' \
    '}' \
    '' \
    '@test "second `echo two` name" {' \
    '}'
  _write "test/bats/integration/y_spec.bats" \
    '@test "third `echo three` name" {' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:1"* ]]
  [[ "${output}" == *"x_spec.bats:4"* ]]
  [[ "${output}" == *"y_spec.bats:1"* ]]
  [[ "${output}" == *"3 finding(s)"* ]]
}

# why: The population is the whole tree and not test/bats/. The shipped smoke
# specs under dist/ are vendored into every downstream repo by the .base
# subtree, so a name executed there is executed in seventeen other
# checkouts, and a scan rooted at the base-own spec tree would never see it
@test "_run_test_name_backtick: scans the shipped smoke specs under dist/, not only test/bats/" {
  _write "dist/test/bats/smoke/z.bats" \
    '@test "smoke `echo hi` name" {' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/test/bats/smoke/z.bats:1"* ]]
}

# why: bats's preprocessor accepts leading blanks before '@test' and registers
# the test, backticks and all -- measured, an indented name whose backticks
# held an echo registered as the echo's output. An anchor pinned to column 0
# would skip it while bats still ran it, and the non-empty-population check
# would not notice because the file's other tests satisfy it
@test "_run_test_name_backtick: FAILS on an INDENTED name, which bats registers too" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "a clean name" {' \
    '}' \
    '  @test "indented `echo IND` name" {' \
    '  }'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:3"* ]]
}

# why: The over-report this lint accepts, pinned so it cannot change shape
# unnoticed. An indented '@test' inside a quoted heredoc is fixture TEXT: the
# preprocessor rewrites it (it is a line filter with no heredoc model) but the
# enclosing shell never registers it, so nothing is executed there. It is
# reported anyway, because a scan over text cannot tell that line from a
# declaration -- and the fixture is often written out and run by an inner
# bats, where the name IS registered. Over-reporting is the refusing
# direction; 21 such lines exist in this tree today and none carries a
# backtick
@test "_run_test_name_backtick: reports an indented name inside a heredoc, the accepted over-report" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "a clean name" {' \
    '  cat <<SPEC' \
    '  @test "fixture `echo HI` name" {' \
    '  }' \
    'SPEC' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:3"* ]]
}

# why: A '@test' line bats's own pattern cannot read is a line this lint cannot
# judge, and an unreadable line is a failure rather than a skip -- the same
# rule the walk failure below follows. Silently skipping it would take the
# name out of the rule's reach with the gate green
@test "_run_test_name_backtick: FAILS on a '@test' line bats's own pattern cannot read" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "no opening brace on this line"' \
    '{' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:1"* ]]
  [[ "${output}" == *"cannot read"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_test_name_backtick: must-keep (no false positives)
# ════════════════════════════════════════════════════════════════════

# why: The boundary of the rule. An escaped backtick is a literal one, so there
# is nothing to execute and nothing to report; a lint that flagged it would
# be refusing a name bats leaves alone, and would read as licence to widen
# until it refused every backtick
@test "_run_test_name_backtick: PASSES a backslash-escaped backtick, which bats leaves alone" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "acceptance drives \`just template new\` end-to-end" {' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: Only the NAME is eval'd at registration. A backtick in a body is ordinary
# shell the test author meant to run, and a lint that flagged it would be
# unsatisfiable in half the specs here
@test "_run_test_name_backtick: PASSES a backtick that is not on a '@test' line" {
  _write "test/bats/unit/x_spec.bats" \
    '# a comment mentioning `just template new`' \
    '@test "a clean name" {' \
    '  local _now' \
    '  _now="`date`"' \
    '  assert_success' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -eq 0 ]
}

# why: Everything after the opening brace is the BODY, not the name: bats takes
# its description from the text BEFORE the brace and makes the rest the body's
# first line, so a backtick in a trailing comment is never eval'd at
# registration -- measured, such a name registers clean. 26 '@test' lines here
# carry text after the brace, so judging the whole line would fail the gate on
# names bats leaves alone
@test "_run_test_name_backtick: PASSES a backtick in a comment AFTER the opening brace" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "a clean name" { # see `just template new`' \
    '  assert_success' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -eq 0 ]
}

# why: The clean line is the audit trail: it says how many names were read and
# over how many files, so a reader of a green CI log can tell a scan that
# checked the tree from one that checked nothing
@test "_run_test_name_backtick: a clean tree passes and the counts print" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "a clean name" {' \
    '}' \
    '' \
    '@test "another clean name" {' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 test name(s) across 1 spec file(s)"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_test_name_backtick: non-vacuity
# ════════════════════════════════════════════════════════════════════

# why: A walk that died part way through hands the lint a short list, which
# reads exactly like a tree with less in it. The three dies below are the
# only ways this lint can report clean having read nothing, and each
# asserts the sentence only ITS die prints
@test "_run_test_name_backtick: DIES when the walk for spec files fails" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "a clean name" {' \
    '}'
  find() { return 3; }
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a scan that could not finish is not a scan that found nothing"* ]]
}

# why: An empty population is the shape that goes green by construction: the
# specs moved, the lint reads nothing and reports a clean tree
@test "_run_test_name_backtick: DIES when the tree holds no spec file at all" {
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a scan with no population is not a pass"* ]]
}

# why: The blind-detector case, and the one that matters most: 4848 '@test'
# lines exist today, so zero means the anchor stopped matching -- a renamed
# keyword, a changed convention -- and a blind detector reports every name
# clean
@test "_run_test_name_backtick: DIES when the spec files carry no '@test' line" {
  _write "test/bats/unit/x_spec.bats" \
    'setup() {' \
    '  load helper' \
    '}'
  run _run_test_name_backtick
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"the anchor read nothing"* ]]
}
