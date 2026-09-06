#!/usr/bin/env bats
#
# Unit tests for script/release/changelog_index.sh -- the --write half, which
# nothing drove, and the one claim of the print half that a diff cannot see.
#
# The PRINT half is otherwise exercised by changelog_layout_lint_spec.bats:
# the layout lint runs the generator and diffs its output against the block
# committed in doc/changelog/CHANGELOG.md. That diff pins the block against
# the generator and nothing else, so a row that says the wrong thing is
# rendered identically on both sides of it and agrees with itself forever --
# which is why the "in progress" marker is asserted here, against the state
# it is supposed to name, rather than there. Nothing ran --write, and --write
# is the half a human runs. It is what `just release changelog-index` calls,
# and it is the fix named in the layout lint's own die message and in the
# marker comment inside the index. So a --write that does not reproduce what
# print rendered is worse than a wrong index: it is a LOOP -- the lint
# refuses the file, the documented fix rewrites the same corruption, and the
# lint refuses it again with no way out but hand-editing a generated block.
#
# The two properties below are exactly that loop's two halves. What --write
# puts between the markers is what print renders (so the fix clears the
# lint), and the file it replaces keeps its own mode (so running the fix
# does not quietly make the changelog owner-only-readable; git does not
# track the bit, so nothing downstream would report it).
#
# Fixtures go into a scratch changelog directory so the spec is independent
# of the live tree.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  GEN=/source/script/release/changelog_index.sh
  assert_spec_subject "${GEN}" \
      "the changelog index generator this spec pins"

  SCRATCH="$(mktemp -d)"
  CL="${SCRATCH}/changelog"
  mkdir -p "${CL}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _series <name> <line>... -- write one series file.
_series() {
  local _name="${1}"
  shift
  printf '%s\n' "$@" > "${CL}/${_name}.md"
}

# _breaking_series -- one series whose BREAKING lead bullet QUOTES a
# backslash escape. That is not a contrived string: the index quotes an
# entry's lead bullet verbatim, and this repo's entries routinely name a
# `\n`, a `\r` or a `\t` when the change is about one (the errexit-bang
# entry in v0.43 names a `\r`).
_breaking_series() {
  _series v0.9 \
    '# base changelog -- v0.9' \
    '' \
    '## [v0.9.0] - 2026-04-03' \
    '' \
    '### BREAKING' \
    '- **the emitter now escapes a `\n` in a value** -- affects downstream repos.' \
    '' \
    '[v0.9.0]: https://example.invalid/compare/v0.8.0...v0.9.0'
}

# _live_and_stub -- the two states the "in progress" marker has to tell
# apart. v0.1 is the LIVE series: it carries `## [Unreleased]`, and it has a
# released version of its own, which is the ordinary shape of a series being
# written into. v0.3 is a stub someone has just cut and not yet written into.
_live_and_stub() {
  _series v0.1 \
    '# base changelog -- v0.1' \
    '' \
    '## [Unreleased]' \
    '' \
    '### Fixed' \
    '- the pending thing (#4, PR #5)' \
    '' \
    '## [v0.1.0] - 2026-04-01' \
    '' \
    '### Added' \
    '- the first thing (#1, PR #2)' \
    '' \
    '[Unreleased]: https://example.invalid/compare/v0.1.0...HEAD' \
    '[v0.1.0]: https://example.invalid/releases/tag/v0.1.0'
  _series v0.3 '# base changelog -- v0.3'
}

# _row <series> -- the rendered index row for one series, or the empty
# string. Not a `run` + assert_output: both cases below are about which of
# two rows carries a marker, and a partial match over the whole block cannot
# say which row it matched.
_row() {
  bash "${GEN}" "${CL}" | grep -F "**[${1}]" || true
}

# _index_with_markers -- an index carrying the generated block as PRINT
# renders it, which is the state a clean checkout is in.
_index_with_markers() {
  printf '# Changelog\n\n' > "${CL}/CHANGELOG.md"
  bash "${GEN}" "${CL}" >> "${CL}/CHANGELOG.md"
}

# _committed_block -- the text between the markers, read exactly the way
# script/test/drivers/changelog_layout.sh reads it.
_committed_block() {
  awk '
    index($0, "<!-- changelog-index: begin") == 1 { on = 1 }
    on { print }
    index($0, "<!-- changelog-index: end") == 1 { on = 0 }
  ' "${CL}/CHANGELOG.md"
}

# why: The property the generator/checker split rests on. If --write and print
# disagree, the layout lint refuses the file and the fix its own message
# names rewrites the same corruption -- a loop with no way out but
# hand-editing a generated block.
@test "changelog_index.sh --write: the block it writes is the block it prints (#926)" {
  # The property the whole generator/checker split rests on. If these two
  # disagree, `just release changelog-index` cannot clear the drift its own
  # error message tells the reader to clear with it.
  _breaking_series
  _index_with_markers

  local _printed
  _printed="$(bash "${GEN}" "${CL}")"
  # Non-vacuity: the rendering under comparison actually carries the row.
  [[ "${_printed}" == *'**[v0.9](v0.9.md)**'* ]] \
    || fail "the fixture rendered no v0.9 row: ${_printed}"

  run bash "${GEN}" --write "${CL}"
  [ "${status}" -eq 0 ]
  [ "$(_committed_block)" = "${_printed}" ]
}

# why: The concrete corruption behind the case above, asserted alone so a
# failure names the character that was eaten instead of dumping two
# blocks. awk expands escape sequences in a `-v` value, and this tree's
# entries routinely quote a `\n` or a `\r` when the change is about one.
@test "changelog_index.sh --write: a backslash escape in a quoted BREAKING entry is written verbatim (#926)" {
  # The concrete corruption behind the case above, asserted on its own so a
  # failure says which character was eaten rather than dumping two blocks.
  _breaking_series
  _index_with_markers

  run bash "${GEN}" --write "${CL}"
  [ "${status}" -eq 0 ]
  run grep -cF -- 'escapes a `\n` in a value' "${CL}/CHANGELOG.md"
  [ "${output}" = '1' ]
}

# why: The rewrite goes through mktemp, which creates 0600. Git does not track
# the bit, so the documented refresh would leave the changelog
# owner-only-readable in a state no gate reports and no later reader can
# explain.
@test "changelog_index.sh --write: the index keeps its own file mode (#926)" {
  # The rewrite goes through mktemp, which creates 0600. Carrying that mode
  # onto the index makes the changelog owner-only-readable in the working
  # tree, and git does not track the bit, so the next reader finds it and
  # nothing explains it.
  _breaking_series
  _index_with_markers
  chmod 644 "${CL}/CHANGELOG.md"

  run bash "${GEN}" --write "${CL}"
  [ "${status}" -eq 0 ]
  [ "$(stat -c %a "${CL}/CHANGELOG.md")" = '644' ]
}

# why: Non-vacuity for the three cases above, which all assert on what lands
# BETWEEN the markers: a --write that silently wrote nowhere when it could
# not find them would satisfy each of them and be caught by nothing else
# here.
@test "changelog_index.sh --write: an index with no markers is REFUSED, not appended to (#926)" {
  # Non-vacuity for the two cases above: they assert on what lands between
  # the markers, so a --write that silently wrote nowhere when it could not
  # find them would have to be caught here.
  _breaking_series
  printf '# Changelog\n\nno markers here\n' > "${CL}/CHANGELOG.md"

  run bash "${GEN}" --write "${CL}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'changelog-index markers'* ]] \
    || fail "the refusal did not say what was missing: ${output}"
  run grep -cF -- 'no markers here' "${CL}/CHANGELOG.md"
  [ "${output}" = '1' ]
}

# why: doc/changelog/CHANGELOG.md tells the reader that a new entry goes into
# "the row below marked *in progress*", so the marker is a navigation
# instruction and its only evidence is `## [Unreleased]`. _ci_row returned on
# a zero version count before consulting the flag it was passed, so a stub
# cut for a series nobody has written into yet -- which is the state a series
# file is in for exactly as long as it takes to write the first entry, when
# the index is what a writer consults -- claimed the marker.
@test "changelog_index.sh: an empty series is not the row marked in progress (#926)" {
  _live_and_stub
  local _stub
  _stub="$(_row v0.3)"
  [[ -n "${_stub}" ]] || fail "the fixture rendered no v0.3 row"
  [[ "${_stub}" != *'in progress'* ]] \
    || fail "an empty stub claims the live-series marker: ${_stub}"
}

# why: The other half of the same marker, and the half that leaves the reader
# with no row to follow at all: a live series that has already cut a version
# rendered its date span and "(plus [Unreleased])", so nothing in the block
# said "in progress" -- the words the index's own prose sends the reader to
# look for. One property, both directions: the row marked in progress is the
# series carrying [Unreleased], whatever it has released.
@test "changelog_index.sh: the series carrying [Unreleased] is the row marked in progress (#926)" {
  _live_and_stub
  local _live
  _live="$(_row v0.1)"
  [[ -n "${_live}" ]] || fail "the fixture rendered no v0.1 row"
  [[ "${_live}" == *'in progress'* ]] \
    || fail "the live series is not marked in progress: ${_live}"
}

# why: The third way into the marker, and the one that reaches it without any
# series file being unusual: a released heading carrying no ISO date leaves
# the row with no span to print, and the fallback for THAT was 'in progress'
# too. The layout lint reads a heading for its tag and never for its date,
# so a section written `## [v0.9.0]` is a shape the tree admits. A row is
# marked in progress because it carries [Unreleased], never because
# something about it could not be read.
@test "changelog_index.sh: a released section with no date does not borrow the marker (#926)" {
  _live_and_stub
  _series v0.9 \
    '# base changelog -- v0.9' \
    '' \
    '## [v0.9.0]' \
    '' \
    '### Added' \
    '- the undated thing (#6, PR #7)' \
    '' \
    '[v0.9.0]: https://example.invalid/compare/v0.8.0...v0.9.0'
  local _undated
  _undated="$(_row v0.9)"
  [[ "${_undated}" == *'1 version'* ]] \
    || fail "the fixture rendered no v0.9 version count: ${_undated}"
  [[ "${_undated}" != *'in progress'* ]] \
    || fail "an undated section claims the live-series marker: ${_undated}"
}

# ════════════════════════════════════════════════════════════════════
# The print half's shape rules
#
# Four branches of the renderer that no fixture used to reach: the quote
# budget, the fence, an entry's continuation lines, and a series spanning
# more than one day. They were executed only because the layout lint ran
# the generator over the LIVE doc/changelog/ -- 43 series files, which
# between them happen to contain every one of these shapes -- and executed
# is not asserted: that run diffs the block against a committed copy of
# itself, so a renderer that truncated at the wrong place, or counted a
# fenced example as a version, agreed with itself and passed.
#
# base#1075 removed the real-tree case (331s of a coverage shard for the
# errexit-bang one of its kind, and the lint job makes the same
# assertion), and these four are what its coverage was worth, turned into
# fixtures that state the rule instead of running it.
# ════════════════════════════════════════════════════════════════════

# why: The quote is a budget, and a budget nothing tests is a number. An entry
# longer than it must come back SHORTER, ellipsed, and cut between words --
# a quote that stops mid-word reads as a typo rather than as a truncation.
@test "changelog_index.sh: a BREAKING entry over the quote budget is truncated on a word boundary (#926)" {
  local _long
  _long="$(printf 'wordy %.0s' $(seq 1 40))"
  _series v0.4 \
    '# base changelog -- v0.4' \
    '' \
    '## [v0.4.0] - 2026-04-04' \
    '' \
    '### BREAKING' \
    "- **the long thing** -- ${_long}" \
    '' \
    '[v0.4.0]: https://example.invalid/releases/tag/v0.4.0'
  local _quote
  _quote="$(bash "${GEN}" "${CL}" | grep -F 'the long thing' || true)"
  [[ -n "${_quote}" ]] || fail "the fixture rendered no BREAKING one-liner"
  [[ "${_quote}" == *'...' ]] \
    || fail "an over-budget quote was not ellipsed: ${_quote}"
  [[ "${_quote}" != *'wordy'?* || "${_quote}" == *'wordy...' ]] \
    || fail "the quote was cut mid-word: ${_quote}"
  # Shorter than what it quotes, or the budget did nothing.
  [[ "${#_quote}" -lt "${#_long}" ]] \
    || fail "the quote is no shorter than the entry: ${_quote}"
}

# why: A '## [' inside a fenced example is an example of a heading. Counting it
# inflates a series' version count, and nothing in the rendered row shows
# where the extra number came from -- the reader is simply told a series
# holds one more release than it does.
@test "changelog_index.sh: a '## [' inside a fenced block is not a version (#926)" {
  _series v0.5 \
    '# base changelog -- v0.5' \
    '' \
    '## [v0.5.0] - 2026-04-05' \
    '' \
    '### Added' \
    '- the real thing (#1, PR #2)' \
    '' \
    'An example of a heading:' \
    '' \
    '```markdown' \
    '## [v9.9.9] - 2099-01-01' \
    '```' \
    '' \
    '[v0.5.0]: https://example.invalid/releases/tag/v0.5.0'
  local _r
  _r="$(_row v0.5)"
  [[ "${_r}" == *'1 version'* ]] \
    || fail "the fenced example was counted as a version: ${_r}"
  [[ "${_r}" != *'2099'* ]] \
    || fail "the fenced example's date reached the span: ${_r}"
}

# why: The quote is taken over the ENTRY, not the lead LINE. Quoting the line
# ends the sentence wherever the author's wrapping happened to fall, which
# reads as a claim that stops mid-thought rather than as a shortened quote --
# and every entry in this repo's changelog is wrapped.
@test "changelog_index.sh: a BREAKING entry's continuation lines are part of what it quotes (#926)" {
  _series v0.6 \
    '# base changelog -- v0.6' \
    '' \
    '## [v0.6.0] - 2026-04-06' \
    '' \
    '### BREAKING' \
    '- **the wrapped thing** -- the first half of the sentence' \
    '  and the second half, on its own line.' \
    '' \
    '[v0.6.0]: https://example.invalid/releases/tag/v0.6.0'
  local _quote
  _quote="$(bash "${GEN}" "${CL}" | grep -F 'the wrapped thing' || true)"
  [[ -n "${_quote}" ]] || fail "the fixture rendered no BREAKING one-liner"
  [[ "${_quote}" == *'and the second half'* ]] \
    || fail "the continuation line was dropped from the quote: ${_quote}"
}

# why: A series holding more than one release spans dates, and a row that
# printed one of them would be answering "when was this cut" with the wrong
# date half the time. The one-date case is already the fixture everywhere
# else here, so only the span is unasserted.
@test "changelog_index.sh: a series holding two dated releases renders the span (#926)" {
  _series v0.7 \
    '# base changelog -- v0.7' \
    '' \
    '## [v0.7.1] - 2026-05-09' \
    '' \
    '### Fixed' \
    '- the later thing (#3, PR #4)' \
    '' \
    '## [v0.7.0] - 2026-04-07' \
    '' \
    '### Added' \
    '- the earlier thing (#1, PR #2)' \
    '' \
    '[v0.7.0]: https://example.invalid/releases/tag/v0.7.0'
  local _r
  _r="$(_row v0.7)"
  [[ "${_r}" == *'2026-04-07 .. 2026-05-09'* ]] \
    || fail "a two-date series did not render its span oldest-first: ${_r}"
  [[ "${_r}" == *'2 versions'* ]] \
    || fail "the fixture rendered the wrong version count: ${_r}"
}
