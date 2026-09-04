#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/changelog_layout.sh -- the lint that
# keeps the split changelog addressable.
#
# The changelog is now one file per 0.Y series behind a generated index. A
# split is a set of claims that nothing checked before this file existed:
# that a version's section is in the file its version names, that the index
# lists the series that exist, that the compare link a section is read
# through is in the same file as the section, and that exactly one file
# carries `## [Unreleased]`. Every one of those breaks silently -- a section
# in the wrong file still renders, a missing index row reads exactly like a
# series that does not exist, and a dangling compare link is a 404 nobody
# clicks until they need it. The single-file changelog already lost its
# compare links once, around v0.6.8.
#
# The index is DERIVED (script/release/changelog_index.sh) and this lint
# re-derives it and diffs, the same generator/checker split
# script/test/sync-doc-counts.sh and the doc-counts gate use. That is the
# answer to "how is the roster kept honest": there is no roster to maintain,
# only a rendering to disagree with.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree; the last case drives the real one. Shape
# mirrors changelog_entry_lint_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  DRIVER=/source/script/test/drivers/changelog_layout.sh
  assert_spec_subject "${DRIVER}" \
      "the changelog layout lint this spec pins"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source "${DRIVER}"

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/changelog" "${SCRATCH}/script/release"
  # The driver re-derives the index by running the real generator, so the
  # scratch tree carries the real one.
  cp /source/script/release/changelog_index.sh "${SCRATCH}/script/release/"
  REPO_ROOT="${SCRATCH}"
  CL="${SCRATCH}/doc/changelog"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _series <name> <line>... -- one series file.
_series() {
  local _name="${1}"
  shift
  printf '%s\n' "$@" > "${CL}/${_name}.md"
}

# _clean_tree -- a two-series split that satisfies every rule, with the
# index regenerated to match. The starting point every case perturbs.
_clean_tree() {
  _series v0.2 \
    '# base changelog -- v0.2' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0'
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
    '[Unreleased]: https://example.invalid/compare/v0.2.0...HEAD' \
    '[v0.1.0]: https://example.invalid/releases/tag/v0.1.0'
  _reindex
}

# _reindex -- re-derive the index from whatever series files are on disk.
# A perturbation that changes a series' version count, its date span or
# which file holds [Unreleased] also changes the DERIVED index, so without
# this it trips the index-drift rule as well as the rule it is about, and
# that collateral is what lets a loose assertion pass on a driver whose rule
# has been deleted. So a case whose perturbation moves the index re-derives
# it here; a case that leaves every derived row alone has nothing to
# re-derive, and the drift case must not.
_reindex() {
  printf '# Changelog\n\n' > "${CL}/CHANGELOG.md"
  bash "${SCRATCH}/script/release/changelog_index.sh" "${CL}" \
    >> "${CL}/CHANGELOG.md"
}

# why: The negative control for the thirteen refusals below, all of which a
# lint that refused everything would also satisfy. The '2 series' assertion
# is what stops it passing over a tree it never walked.
@test "changelog layout: a split whose index matches its series files is clean" {
  _clean_tree
  run _run_changelog_layout
  [ "${status}" -eq 0 ]
  # Non-vacuity: the clean line says what it actually walked.
  assert_output --partial '2 series'
  # And that it walked the INDEX too, not only the series files.
  assert_output --partial 'CHANGELOG.md carries none of them'
}

# why: The regression this rule exists for, and the one every OTHER rule here
# is blind to: a merge with main re-adds the release history to the index
# wholesale, because git reads main's edits to a file the split emptied as
# lines to add back. Every rule above walks the series files only, so the
# copy is not misplaced, not duplicated and not dangling -- it is simply
# never looked at. It went green over 108 re-added sections twice.
@test "changelog layout: a released section left in the index is named" {
  _clean_tree
  # The index, correct in every derived respect, with a release section
  # re-added below the generated block -- exactly what the merge leaves.
  # The section is a COPY: v0.1.md still has the original, so the
  # placement, duplicate and compare-link rules all still hold over the
  # series files, and this rule is the only one that can fire.
  {
    printf '\n## [v0.1.0] - 2026-04-01\n\n### Added\n- the first thing (#1, PR #2)\n'
  } >> "${CL}/CHANGELOG.md"

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  # The rule's own sentence, and the tag it found -- not a bare count.
  assert_output --partial 'the index carries 1 release section(s) -- v0.1.0'
  # And it is the ONLY rule that fired.
  assert_output --partial '1 misplaced section'
}

# why: The live half of the same rule, and the only corner of the disease the
# gate ever saw: `## [Unreleased]` in the index. The entry lint objects to
# it because it globs `*.md`, so a fix aimed at the symptom deletes this
# block alone and leaves the released sections sitting in the index --
# which is what happened, twice. This rule refuses both halves at once.
@test "changelog layout: a live [Unreleased] in the index is named" {
  _clean_tree
  {
    printf '\n## [Unreleased]\n\n### Fixed\n- written into the index (#6, PR #7)\n'
  } >> "${CL}/CHANGELOG.md"

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'the index carries 1 release section(s) -- Unreleased'
  # The live-series rule counts SERIES files, so it still sees exactly one
  # and stays quiet: without this pass, an [Unreleased] in the index is
  # invisible to the layout lint entirely.
  assert_output --partial '1 misplaced section'
}

# why: A vX.Y.Z section renders identically wherever it sits, so nothing but a
# lint notices it in the wrong file. The fixture MOVES rather than copies
# the section precisely so the duplicate-section rule cannot satisfy this
# assertion with the placement rule deleted.
@test "changelog layout: a section in the wrong series file is named" {
  _clean_tree
  # v0.2.0's section MOVED into the v0.1 file -- carried over whole, links
  # included, and gone from v0.2.md rather than duplicated into it. A copy
  # would trip the duplicate-section rule too, and then the assertions below
  # would be satisfied with the placement rule deleted.
  _series v0.1 \
    '# base changelog -- v0.1' \
    '' \
    '## [Unreleased]' \
    '' \
    '### Fixed' \
    '- the pending thing (#4, PR #5)' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '[Unreleased]: https://example.invalid/compare/v0.2.0...HEAD' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0'
  _series v0.2 '# base changelog -- v0.2'
  _reindex

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  # The placement rule's own sentence, not a substring the duplicate-section
  # message and the index-drift diff also print.
  assert_output --partial 'v0.2.0 belongs in doc/changelog/v0.2.md'
  # And it is the ONLY rule that fired: a second violation here would mean
  # the fixture is testing something other than placement.
  assert_output --partial '1 misplaced section'
}

# why: What `merge=union` leaves behind: union keeps both sides and conflicts
# on nothing, so two branches promoting the same section land it twice
# with nothing to review. Both copies sit in the file the version names,
# so this is the only rule that can catch it.
@test "changelog layout: a version section that appears TWICE is named" {
  _clean_tree
  # What a union merge leaves behind. `doc/changelog/*.md merge=union` keeps
  # both sides of every overlapping hunk and conflicts on nothing, so two
  # branches that both promote the same section land it twice in one file --
  # with nothing to review. Both copies are in the file the version names,
  # so the placement rule has nothing to say about either and this is the
  # only rule that can fire.
  _series v0.2 \
    '# base changelog -- v0.2' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing, kept twice (#2, PR #3)' \
    '' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0'
  _reindex

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  # The duplicate rule's own sentence, naming the file the first copy is in.
  assert_output --partial 'duplicate section -- v0.2.0 already has a section in doc/changelog/v0.2.md'
  # And nothing else fired: a second violation would mean the fixture is
  # testing something other than duplication.
  assert_output --partial '1 misplaced section'
}

# why: The other half of what `merge=union` leaves behind, and the quiet one.
# Both compare-link definitions are in the file the version names, so the
# section/definition agreement rule beside this one is satisfied by
# either, and CommonMark resolves every reference to the FIRST -- so a
# stale or wrong URL wins with nothing rendering differently.
@test "changelog layout: a compare link DEFINED TWICE in one file is named" {
  _clean_tree
  # The definition block is where a union merge overlaps most reliably: it
  # is the foot of every series file and every branch appends to it. Both
  # copies name the same tag in the file that tag belongs to, so the
  # agreement rule and the placement rule both hold; only this one can fire.
  _series v0.2 \
    '# base changelog -- v0.2' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0' \
    '[v0.2.0]: https://example.invalid/compare/WRONG...v0.2.0'

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  # The rule's own sentence, naming the line the winning definition is on --
  # the one a reader has to go and read to see which URL is live.
  assert_output --partial 'duplicate compare-link definition -- [v0.2.0] is already defined at line 8'
  # And nothing else fired.
  assert_output --partial '1 misplaced section'
}

# why: A heading belonging to no series has no file the placement rule could
# say it belongs in, so it would be filed wherever it was found and pass.
# Without this rule the layout check is silent on exactly the headings the
# roster does not govern.
@test "changelog layout: a section heading that is not a version is named" {
  _clean_tree
  # `## [Yanked]` renders like any other section and belongs to no series,
  # so there is no file the placement rule could say it belongs in -- it
  # would be filed under whichever file it happened to be found in, which
  # is a pass. A heading in the section position that is not a version is
  # its own finding.
  _series v0.2 \
    '# base changelog -- v0.2' \
    '' \
    '## [Yanked] - 2026-04-02' \
    '' \
    '### Removed' \
    '- pulled after release (#9, PR #10)' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '[Yanked]: https://example.invalid/compare/v0.1.0...v0.2.0' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0'
  _reindex

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'section heading is not a version -- Yanked'
  assert_output --partial '1 misplaced section'
}

# why: The case above is unreachable unless this returns 0. The lint phase runs
# drivers under errexit and the caller reads the answer through a command
# substitution, so a non-zero status ends the driver on an assignment and
# the finding is never printed. bats turns errexit off for a `run`, so no
# other case here can see it.
@test "changelog layout: _cll_series_of answers for a non-version tag instead of FAILING" {
  # The rule above is only reachable if this answers with a status of 0.
  # The lint phase runs every driver under `set -e` with an ERR trap
  # (script/test/test.sh's _run_lint_tool), and the caller takes the answer
  # through a plain `_want="$(_cll_series_of ...)"` -- a command
  # substitution whose non-zero status ends the driver at that line. The
  # finding above would then never be printed: the run would stop with
  # ci_lint_driver_failed naming an assignment, which reads as a broken
  # lint rather than as a changelog that needs fixing.
  #
  # bats runs a `run` command with errexit OFF, so the case above cannot
  # see this on its own -- which is exactly why it is asserted here, on the
  # status, rather than left to be inferred.
  run _cll_series_of 'Yanked'
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run _cll_series_of 'v0.2.0'
  [ "${status}" -eq 0 ]
  [ "${output}" = 'v0.2' ]
}

# why: Markdown link definitions are file-scoped, so the split's mechanical
# risk is a definition that stayed behind while its section moved. A
# section whose link is simply absent is that defect at its simplest, and
# it renders as plain text nobody reads as broken.
@test "changelog layout: a version section with no compare link is named" {
  _clean_tree
  _series v0.2 \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)'

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'v0.2.0'
}

# why: The half that goes wrong quietly -- the section moved and the definition
# did not, so the link resolves to nothing in the file the reader has
# open. The single-file changelog already lost its compare links this way
# once, around v0.6.8.
@test "changelog layout: a compare link whose section is elsewhere is named" {
  # The half of the split that goes wrong quietly: the section moved and
  # the link did not, so the link resolves to nothing in the file a reader
  # is looking at.
  _clean_tree
  _series v0.2 \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0' \
    '[v0.1.0]: https://example.invalid/releases/tag/v0.1.0'

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'v0.1.0'
}

# why: A missing index row reads exactly like a series that does not exist,
# which is why the block is derived rather than written. This is the case
# that makes the derivation load-bearing: a new series file nobody
# re-indexed is the ordinary way it goes stale.
@test "changelog layout: an index that has drifted from the series files is refused" {
  _clean_tree
  # A new series lands and nobody refreshes the index -- the failure the
  # generated block exists to make impossible to leave in place.
  _series v0.3 \
    '## [v0.3.0] - 2026-04-05' \
    '' \
    '### Added' \
    '- the third thing (#6, PR #7)' \
    '' \
    '[v0.3.0]: https://example.invalid/compare/v0.2.0...v0.3.0'

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'v0.3'
}

# why: Two live series is two places to write the next entry and two places a
# merge can keep, with the entry lint measuring whichever it reaches
# first. The assertion names the rule's own count rather than the word
# Unreleased, which the drift diff prints too.
@test "changelog layout: [Unreleased] in two files is refused" {
  # Two places to write the next entry is two places a merge can keep, and
  # the entry lint measures whichever one it finds first.
  _clean_tree
  _series v0.2 \
    '# base changelog -- v0.2' \
    '' \
    '## [Unreleased]' \
    '' \
    '### Added' \
    '- written into the wrong file (#8, PR #9)' \
    '' \
    '## [v0.2.0] - 2026-04-02' \
    '' \
    '### Added' \
    '- the second thing (#2, PR #3)' \
    '' \
    '[Unreleased]: https://example.invalid/compare/v0.2.0...HEAD' \
    '[v0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0'
  _reindex

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  # The live-series rule's own count, not the word 'Unreleased' -- which the
  # index-drift diff prints too, in the row that gains '(plus [Unreleased])'.
  assert_output --partial "'## [Unreleased]' appears in 2 series files"
  assert_output --partial '1 misplaced section'
}

# why: The same rule in the direction that fails open: with no live series
# every placement rule holds and the tree reports clean, while there is
# nowhere left to write the next entry.
@test "changelog layout: no [Unreleased] anywhere is refused, not passed" {
  _clean_tree
  _series v0.1 \
    '# base changelog -- v0.1' \
    '' \
    '## [v0.1.0] - 2026-04-01' \
    '' \
    '### Added' \
    '- the first thing (#1, PR #2)' \
    '' \
    '[v0.1.0]: https://example.invalid/releases/tag/v0.1.0'
  _reindex

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial "'## [Unreleased]' appears in 0 series files"
  assert_output --partial '1 misplaced section'
}

# why: The vacuous pass this repo keeps paying for. With nothing to walk, every
# rule above holds and the lint prints a green line that means the scan
# found nothing, not that nothing is wrong.
@test "changelog layout: a changelog directory with no series files DIES" {
  # The vacuous pass this repo keeps having to fix: with nothing to walk,
  # every rule above holds and the lint reports clean over zero files.
  printf '# Changelog\n' > "${CL}/CHANGELOG.md"
  run _run_changelog_layout
  [ "${status}" -ne 0 ]
}

# why: Every other case drives a scratch fixture, so this is the only one that
# says the rules hold for the 43 series files that actually ship -- which
# is what makes the split's own landing a gated change rather than a
# claim.
@test "changelog layout: the live changelog tree is clean" {
  REPO_ROOT=/source
  run _run_changelog_layout
  [ "${status}" -eq 0 ]
  assert_output --partial 'series'
}
