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

# ── both historical smoke layouts, same workflow ─────────────────────────────

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

@test "archive manifest: a consumer with no doc/ and no .hadolint.yaml still archives (#914)" {
  _seed 'Dockerfile' '.base/dist/script/' 'script/' 'README.md'
  run _archive
  assert_success
  [ ! -e "${REPO}/${DEST}/doc" ]
  [ ! -e "${REPO}/${DEST}/.hadolint.yaml" ]
  assert_output --partial 'doc/'
  assert_output --partial '.hadolint.yaml'
}

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

@test "archive manifest: a tree with no Dockerfile fails, naming Dockerfile (#914)" {
  _seed '.base/dist/script/' 'script/' 'README.md' 'doc/'
  run _archive
  assert_failure
  assert_output --partial 'Dockerfile'
  refute_output --partial 'cannot stat'
}

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

@test "archive manifest: declares exactly two required entries (Dockerfile and .base/) (#914)" {
  # Pins the mandatory decision. Promoting a path to required makes a base
  # layout change able to break a downstream release again, so it must be a
  # deliberate, reviewed edit -- this test is the review trigger.
  run bash -c "grep -c '^required|' '${MANIFEST}'"
  assert_success
  assert_output "2"
  run bash "${ARCHIVE}" --list "${MANIFEST}"
  assert_success
  assert_output --partial 'Dockerfile'
  assert_output --partial '.base/'
}

@test "archive manifest: still declares every path the hardcoded cp list carried (#914)" {
  # The payload must not be pruned by accident while making it tolerant.
  for _path in 'Dockerfile' 'script/' '.hadolint.yaml' 'test/bats/smoke/' \
    'test/smoke/' '.base/' 'README.md' 'doc/'; do
    run grep -F "${_path}" "${MANIFEST}"
    assert_success
  done
}

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
