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
