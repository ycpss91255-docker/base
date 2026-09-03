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
  printf '# Changelog\n\n' > "${CL}/CHANGELOG.md"
  bash "${SCRATCH}/script/release/changelog_index.sh" "${CL}" \
    >> "${CL}/CHANGELOG.md"
}

@test "changelog layout: a split whose index matches its series files is clean" {
  _clean_tree
  run _run_changelog_layout
  [ "${status}" -eq 0 ]
  # Non-vacuity: the clean line says what it actually walked.
  assert_output --partial '2 series'
}

@test "changelog layout: a section in the wrong series file is named" {
  _clean_tree
  # v0.2.0's section moved into the v0.1 file: it still renders, and the
  # index still lists both series, so nothing else notices.
  _series v0.1 \
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

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'v0.2.0'
  assert_output --partial 'v0.1.md'
}

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

@test "changelog layout: [Unreleased] in two files is refused" {
  # Two places to write the next entry is two places a merge can keep, and
  # the entry lint measures whichever one it finds first.
  _clean_tree
  _series v0.2 \
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

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'Unreleased'
}

@test "changelog layout: no [Unreleased] anywhere is refused, not passed" {
  _clean_tree
  _series v0.1 \
    '## [v0.1.0] - 2026-04-01' \
    '' \
    '### Added' \
    '- the first thing (#1, PR #2)' \
    '' \
    '[v0.1.0]: https://example.invalid/releases/tag/v0.1.0'

  run _run_changelog_layout
  [ "${status}" -ne 0 ]
  assert_output --partial 'Unreleased'
}

@test "changelog layout: a changelog directory with no series files DIES" {
  # The vacuous pass this repo keeps having to fix: with nothing to walk,
  # every rule above holds and the lint reports clean over zero files.
  printf '# Changelog\n' > "${CL}/CHANGELOG.md"
  run _run_changelog_layout
  [ "${status}" -ne 0 ]
}

@test "changelog layout: the live changelog tree is clean" {
  REPO_ROOT=/source
  run _run_changelog_layout
  [ "${status}" -eq 0 ]
  assert_output --partial 'series'
}
