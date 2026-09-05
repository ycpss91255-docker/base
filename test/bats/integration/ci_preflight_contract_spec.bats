#!/usr/bin/env bats
#
# ci_preflight_contract_spec.bats -- integration coverage for the real
# caller-contract manifests the reusable workers ship:
#   script/ci/preflight/build.manifest    (build-worker.yaml)
#   script/ci/preflight/release.manifest  (release-worker.yaml)
#
# These drive preflight.sh against the ACTUAL declared requirement lists
# (not synthetic fixtures) with a deliberately-incomplete fake caller
# environment, proving the worker fails early -- within seconds, before any
# build compute -- with a plain-language message telling the caller exactly
# what to add to main.yaml. This is the contract test the acceptance
# criteria call for.
#
# why: Drives `script/ci/preflight.sh` against the ACTUAL shipped
# requirement manifests (`script/ci/preflight/build.manifest` +
# `release.manifest`) with a deliberately-incomplete fake caller
# environment. A complete caller passes; a caller that forgot `image_name`
# (build) or `archive_name_prefix` (release) fails early with the
# plain-language `main.yaml` fix. The build contract declares NO permission
# requirement (#980): the one it used to carry demanded `packages: write`
# for the `registry` buildx cache backend, which no job of the worker
# declares and no caller could supply, so it failed every caller that
# followed its instructions. The backend and the requirement were removed
# together, and a caller that grants nothing beyond `contents: read` passes.
# `--list` self-describes the remaining contract.

bats_require_minimum_version 1.5.0

PREFLIGHT="/source/script/ci/preflight.sh"
BUILD_MANIFEST="/source/script/ci/preflight/build.manifest"
RELEASE_MANIFEST="/source/script/ci/preflight/release.manifest"

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
}

# ── build-worker caller contract ──────────────────────────────────────

@test "build manifest: a complete caller passes preflight" {
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_success
}

@test "build manifest: a caller that forgot image_name fails early, naming the fix" {
  # Simulate a downstream main.yaml that calls build-worker.yaml but omits
  # `with: { image_name: ... }`.
  PREFLIGHT_INPUT_IMAGE_NAME="" \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_failure
  assert_output --partial 'image_name'
  assert_output --partial 'main.yaml'
  assert_output --partial 'with:'
}

# why: The caller that grants nothing. Every job of build-worker.yaml
# declares `contents: read` and pushes nothing, so a caller holding no
# other scope is a COMPLETE caller -- and the build contract must say so.
# It did not: it demanded `packages: write` for a cache backend no job
# could reach, so the one caller shape that is entirely correct failed the
# gate written to help it (#980).
@test "build manifest: a caller granting no write scope is complete (#980)" {
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_success
}

@test "build manifest --list: self-describes the contract, and demands no permission (#980)" {
  run bash "${PREFLIGHT}" --list "${BUILD_MANIFEST}"
  assert_success
  assert_output --partial 'image_name'
  refute_output --partial 'packages'
}

# ── release-worker caller contract ────────────────────────────────────

@test "release manifest: a complete caller passes preflight" {
  PREFLIGHT_INPUT_ARCHIVE_NAME_PREFIX=ros_noetic \
    run bash "${PREFLIGHT}" "${RELEASE_MANIFEST}"
  assert_success
}

@test "release manifest: a caller that forgot archive_name_prefix fails early, naming the fix" {
  PREFLIGHT_INPUT_ARCHIVE_NAME_PREFIX="" \
    run bash "${PREFLIGHT}" "${RELEASE_MANIFEST}"
  assert_failure
  assert_output --partial 'archive_name_prefix'
  assert_output --partial 'main.yaml'
}
