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

@test "build manifest: a registry-cache caller is told the backend is unreachable, not to grant more (#957)" {
  # cache_backend: registry selected, image_name supplied, but the GHCR
  # write probe reported missing. This message is the ONLY text a failing
  # caller actually reads, and until #957 it told them to add `packages:
  # write` to call-docker-build (the #801 wording). That grant cannot
  # reach the worker's `build` job, which declares its own read-only
  # `permissions:` block -- a called job gets the block it declares, and a
  # caller's grant does not widen it -- so following the old hint produced
  # this same failure again. The hint must name the real fix (drop the
  # registry backend) and must not hand the caller a grant snippet.
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_CACHE_BACKEND=registry \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
  assert_output --partial 'cache_backend: registry is not usable'
  # Neither the hint nor the requirement description -- both are printed
  # on failure -- may spell the grant out: that IS the false promise.
  refute_output --partial 'packages: write'
}

@test "build manifest: the default gha caller without packages permission still passes (#801 backward compat)" {
  # cache_backend defaults to gha -> the buildx cache lives in GHA cache
  # and the test-tools image is pulled anonymously, so no packages
  # permission is required. An existing caller that never granted
  # `packages: write` must not start failing.
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_CACHE_BACKEND=gha \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_success
}

@test "build manifest: a registry-cache caller with packages granted passes (#801)" {
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_CACHE_BACKEND=registry \
  PREFLIGHT_PERM_PACKAGES=granted \
    run bash "${PREFLIGHT}" "${BUILD_MANIFEST}"
  assert_success
}

@test "build manifest --list: self-describes both requirements, packages as registry-conditional (#801)" {
  run bash "${PREFLIGHT}" --list "${BUILD_MANIFEST}"
  assert_success
  assert_output --partial 'image_name'
  assert_output --partial 'packages'
  assert_output --partial 'when PREFLIGHT_CACHE_BACKEND=registry'
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
