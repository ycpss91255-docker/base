#!/usr/bin/env bats
#
# release_archive_contract_spec.bats -- integration coverage for the REAL
# payload manifest the reusable release worker ships:
#   script/ci/release/archive.manifest   (release-worker.yaml)
#
# These drive script/ci/release-archive.sh against the ACTUAL declared
# payload (not synthetic fixtures) over SYNTHESISED consumer trees, so the
# question the two production incidents asked -- "what happens to a real
# consumer whose tree lacks one standard path?" -- is answered in CI instead
# of at someone's tag push.
#
# WHY THE TREES ARE SYNTHESISED. base's own checkout cannot stand in for a
# consumer: base is the template SOURCE, so it has no `.base/` subtree, and
# its smoke templates live under `dist/test/bats/smoke/`, not
# `test/bats/smoke/`. A test that drove `/source` would therefore assert
# nothing about a satisfied payload -- and, more to the point, could never
# express the case that matters here, a tree deliberately MISSING a path.
# Both prior instances shipped with a green suite for exactly that reason.
#
# Each fixture below is a consumer shape observed in the wild:
#   - new layout   -- what init.sh scaffolds today (`test/bats/smoke/`)
#   - old layout   -- repos scaffolded before the smoke tree moved
#                     (`test/smoke/`)
#   - no smoke     -- the v0.42.0 casualty shape: every other standard path
#                     present, no smoke tree at all
#   - docs-less    -- a consumer with neither `doc/` nor `.hadolint.yaml`
#   - broken       -- missing a MANDATORY path; must fail, naming it
#
# why: Drives `script/ci/release-archive.sh` against the REAL shipped
# payload manifest (`script/ci/release/archive.manifest`) over synthesised
# consumer trees. base's own checkout cannot stand in for a consumer -- it
# has no `.base/` subtree (it is the template source) and its smoke
# templates live under `dist/` -- and, more to the point, a real tree cannot
# express the case that matters: a repo deliberately MISSING a standard
# path. That vacuity is why the same defect shipped twice.

bats_require_minimum_version 1.5.0

ARCHIVE="/source/script/ci/release-archive.sh"
MANIFEST="/source/script/ci/release/archive.manifest"

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TMP_DIR="$(mktemp -d)"
  REPO="${TMP_DIR}/repo"
  DEST="out"
  mkdir -p "${REPO}"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# _seed <path>... -- materialise paths in the fixture consumer tree.
_seed() {
  local _p
  for _p in "$@"; do
    case "${_p}" in
      */)
        mkdir -p "${REPO}/${_p}"
        printf 'content of %s\n' "${_p}" > "${REPO}/${_p}payload.txt"
        ;;
      *)
        mkdir -p "$(dirname "${REPO}/${_p}")"
        printf 'content of %s\n' "${_p}" > "${REPO}/${_p}"
        ;;
    esac
  done
}

# The paths every fixture shares: the two mandatory ones plus the optional
# payload a fully-populated consumer carries.
_seed_common() {
  _seed 'Dockerfile' '.base/dist/script/' 'script/' '.hadolint.yaml' \
    'README.md' 'doc/'
}

_archive() {
  cd "${REPO}" || return 1
  bash "${ARCHIVE}" "${MANIFEST}" "${DEST}"
}

# _manifest_paths <manifest> [<kind>] -- print every DECLARED candidate path,
# one per line, optionally only those of entries of <kind>.
#
# Reads the assembler's own `--list` view of the parsed entries rather than
# the file. The manifest is prose as much as payload -- a header explaining
# the required set, a description column per entry -- and both name payload
# paths in plain English, so anything that searches the raw text answers
# "declared" for entries that were deleted. Only the paths column can satisfy
# this, and only as a whole candidate token.
_manifest_paths() {
  local _manifest="$1" _kind="${2-}" _line _current=""
  while IFS= read -r _line; do
    if [[ "${_line}" =~ ^[[:space:]]+\[([a-z]+)\][[:space:]] ]]; then
      _current="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "${_line}" =~ ^[[:space:]]+paths:[[:space:]](.*)$ ]] || continue
    [[ -z "${_kind}" || "${_current}" == "${_kind}" ]] || continue
    # Deliberate word splitting: <paths> is a space-separated candidate list.
    # shellcheck disable=SC2086
    printf '%s\n' ${BASH_REMATCH[1]}
  done < <(bash "${ARCHIVE}" --list "${_manifest}")
}

# _manifest_declares <manifest> <path> -- succeed when <manifest> declares
# <path> as a candidate of some payload entry.
_manifest_declares() {
  local _manifest="$1" _want="$2" _candidate
  while IFS= read -r _candidate; do
    if [[ "${_candidate}" == "${_want}" ]]; then
      return 0
    fi
  done < <(_manifest_paths "${_manifest}")
  return 1
}

# ── both historical smoke layouts, same workflow ─────────────────────────────

# why: Full payload, `test/bats/smoke/` layout: every declared path lands
@test "archive manifest: a current-layout consumer (test/bats/smoke/) archives its whole payload (#914)" {
  _seed_common
  _seed 'test/bats/smoke/shared/'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/Dockerfile" ]
  [ -d "${REPO}/${DEST}/.base" ]
  [ -d "${REPO}/${DEST}/script" ]
  [ -f "${REPO}/${DEST}/.hadolint.yaml" ]
  [ -f "${REPO}/${DEST}/README.md" ]
  [ -d "${REPO}/${DEST}/doc" ]
  [ -f "${REPO}/${DEST}/test/bats/smoke/shared/payload.txt" ]
}

# why: `test/smoke/` layout archives with no restructuring (the v0.42.0
# casualty)
@test "archive manifest: a previous-layout consumer (test/smoke/) archives without restructuring (#914)" {
  # The v0.42.0 instance: the operand list moved to `test/bats/smoke/`, so a
  # consumer still on `test/smoke/` could not cut a release. Both layouts
  # are declared candidates of one entry, so neither consumer has to move a
  # directory to be releasable.
  _seed_common
  _seed 'test/smoke/'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/test/smoke/payload.txt" ]
}

# why: No smoke tree at all still cuts a release; the absence is reported
@test "archive manifest: neither smoke layout present still cuts a release (#914)" {
  # The exact shape that failed v0.42.0 downstream: everything else in
  # place, no smoke tree at all. Absence is reported, not fatal.
  _seed_common
  run _archive
  assert_success
  assert_output --partial 'smoke'
  [ -f "${REPO}/${DEST}/Dockerfile" ]
}

# ── optional gaps degrade the archive, they do not fail the release ──────────

# why: Missing docs + lint config degrade the archive, they do not fail it
@test "archive manifest: a consumer with no doc/ and no .hadolint.yaml still archives (#914)" {
  _seed 'Dockerfile' '.base/dist/script/' 'script/' 'README.md'
  run _archive
  assert_success
  [ ! -e "${REPO}/${DEST}/doc" ]
  [ ! -e "${REPO}/${DEST}/.hadolint.yaml" ]
  assert_output --partial 'doc/'
  assert_output --partial '.hadolint.yaml'
}

# why: Missing wrapper tree degrades the archive, it does not fail it
@test "archive manifest: a consumer with no script/ wrappers still archives (#914)" {
  # The first instance's mirror image: `script/` is the wrapper tree, whose
  # contents are duplicated out of `.base/` anyway, so its absence is a
  # degraded archive rather than a broken one.
  _seed 'Dockerfile' '.base/dist/script/' 'README.md' 'doc/'
  run _archive
  assert_success
  assert_output --partial 'script/'
}

# ── the mandatory half is genuinely mandatory ────────────────────────────────

# why: Mandatory gap fails naming `Dockerfile`, never `cp: cannot stat`
@test "archive manifest: a tree with no Dockerfile fails, naming Dockerfile (#914)" {
  _seed '.base/dist/script/' 'script/' 'README.md' 'doc/'
  run _archive
  assert_failure
  assert_output --partial 'Dockerfile'
  refute_output --partial 'cannot stat'
}

# why: Mandatory gap fails naming `.base/`, never `cp: cannot stat`
@test "archive manifest: a tree with no .base/ subtree fails, naming .base/ (#914)" {
  # An archive without the vendored toolchain is not a release: every entry
  # point it ships resolves into `.base/`. Shipping it silently would move
  # the discovery from tag time to the consumer who unpacks it.
  _seed 'Dockerfile' 'script/' 'README.md' 'doc/'
  run _archive
  assert_failure
  assert_output --partial '.base/'
  refute_output --partial 'cannot stat'
}

# ── the declared payload itself ──────────────────────────────────────────────

# why: Pins the mandatory set so widening it is a deliberate, reviewed edit
@test "archive manifest: declares exactly two required entries (Dockerfile and .base/) (#914)" {
  # Pins the mandatory decision. Promoting a path to required makes a base
  # layout change able to break a downstream release again, so it must be a
  # deliberate, reviewed edit -- this test is the review trigger.
  #
  # Asserted as the exact required PATH SET, not as two substrings of the
  # listing: `Dockerfile` also appears in the hadolint entry's description
  # and `.base/` in the wrappers entry's, so a substring reading of the same
  # output would survive promoting or demoting either one.
  run bash -c "grep -c '^required|' '${MANIFEST}'"
  assert_success
  assert_output "2"
  run _manifest_paths "${MANIFEST}" required
  assert_success
  assert_output "$(printf 'Dockerfile\n.base/')"
}

# why: No payload path was silently pruned while making the list tolerant
@test "archive manifest: still declares every path the hardcoded cp list carried (#914)" {
  # The payload must not be pruned by accident while making it tolerant.
  local _path
  for _path in 'Dockerfile' 'script/' '.hadolint.yaml' 'test/bats/smoke/' \
    'test/smoke/' '.base/' 'README.md' 'doc/'; do
    run _manifest_declares "${MANIFEST}" "${_path}"
    assert_success
  done
}

# why: The payload guard cannot be satisfied by the prose that explains the
# entry
@test "archive manifest: a payload entry deleted behind its own comment is no longer declared (#914)" {
  # The guard above is only worth its name if deleting a payload line makes it
  # go red. The manifest's header prose names `Dockerfile`, `.base/` and
  # `script/`'s wrappers in plain English, so any reader that searches the
  # WHOLE FILE keeps answering "declared" for a payload that no longer
  # declares anything -- the assertion is then satisfied by the comment that
  # explains the entry rather than by the entry.
  local _pruned="${TMP_DIR}/pruned.manifest"
  grep -v '^optional|wrappers|' "${MANIFEST}" > "${_pruned}"

  # The prose survives the deletion. This is the trap, pinned.
  run grep -F 'script/' "${_pruned}"
  assert_success

  run _manifest_declares "${_pruned}" 'script/'
  assert_failure
}

# why: The #558 instance: no removed root wrapper is declared as a payload
# path
@test "archive manifest: names no wrapper that init.sh no longer creates at the repo root (#914)" {
  # The first instance: the operand list still named `build.sh` / `run.sh` /
  # `exec.sh` / `stop.sh` / `setup_tui.sh` at the root after they moved into
  # `script/`. They are carried by the `script/` entry now; re-adding a root
  # name as its own entry goes red here.
  run grep -nE '\|(build|run|exec|stop|setup_tui)\.sh( |\|)' "${MANIFEST}"
  if [ "${status}" -eq 0 ]; then
    echo "removed root wrapper declared as a payload path:"
    echo "${output}"
    return 1
  fi
}
