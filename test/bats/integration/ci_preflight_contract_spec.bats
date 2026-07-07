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
  PREFLIGHT_PERM_PACKAGES=granted \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_success
}

@test "build manifest: a caller that forgot image_name fails early, naming the fix" {
  # Simulate a downstream main.yaml that calls build-worker.yaml but omits
  # `with: { image_name: ... }`. GHCR probe granted so only the input gap
  # is exercised.
  PREFLIGHT_INPUT_IMAGE_NAME="" \
  PREFLIGHT_PERM_PACKAGES=granted \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_failure
  assert_output --partial 'image_name'
  assert_output --partial 'main.yaml'
  assert_output --partial 'with:'
}

@test "build manifest: a caller missing packages permission fails with the permissions fix (#801 pave-the-way)" {
  # image_name supplied, but the GHCR/packages probe reported missing --
  # the future registry-cache backend needs `packages: write`. The caller
  # is told to grant it instead of 403-ing deep in a 20-min build.
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
  assert_output --partial 'permissions:'
}

@test "build manifest --list: self-describes both requirements" {
  run bash "${PREFLIGHT}" --list "${BUILD_MANIFEST}"
  assert_success
  assert_output --partial 'image_name'
  assert_output --partial 'packages'
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
