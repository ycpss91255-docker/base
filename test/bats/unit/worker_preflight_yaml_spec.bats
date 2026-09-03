#!/usr/bin/env bats
#
# worker_preflight_yaml_spec.bats -- structural assertions that the
# reusable workers wire in the caller-contract preflight.
#
# The preflight LOGIC is unit-tested in ci_preflight_spec.bats and
# integration-tested in ci_preflight_contract_spec.bats. These tests lock
# the thin GHA wiring: a preflight job that (a) runs before the real work
# gates on it, (b) fetches the validator + manifest from base at the SAME
# ref as the worker (github.job_workflow_sha, so the validator can never
# drift from the worker it guards), and (c) calls preflight.sh with the
# per-worker manifest and the real inputs exported into the env vars the
# manifest names.
#
# why: Structural assertions that `build-worker.yaml` and
# `release-worker.yaml` wire in the caller-contract preflight: a `preflight`
# job that the real build / release job gates on (its `needs:` list includes
# it), fetching the validator + manifest from base at the worker's own ref
# (`github.job_workflow_sha`, so the validator can never drift from the
# worker it guards), then calling `preflight.sh` with the per-worker
# manifest and the real inputs exported into the env vars the manifest names
# (plus a GHCR-login probe feeding the packages-permission check on the
# build side). #801 adds the build side's `cache_backend` export into the
# manifest guard env and a REAL packages: write probe (a GHCR blob-upload
# scope check, not a bare login) for the registry backend.

bats_require_minimum_version 1.5.0

BUILD_WF="/source/.github/workflows/build-worker.yaml"
RELEASE_WF="/source/.github/workflows/release-worker.yaml"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject "${BUILD_WF}" \
      "the reusable build worker this spec pins"
  assert_spec_subject "${RELEASE_WF}" \
      "the reusable release worker this spec pins"
}

# ── build-worker.yaml ─────────────────────────────────────────────────

@test "build-worker.yaml: declares a preflight job (#800)" {
  run code_grep -E '^  preflight:$' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: build job gates on preflight (#800)" {
  # The heavy build must not start unless preflight passed. Assert the
  # build job's needs: list includes preflight.
  run code_grep -E '^    needs: \[.*preflight.*\]$' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight fetches the validator at the worker's own ref (job_workflow_sha, no drift) (#800)" {
  run code_grep -F 'ref: ${{ github.job_workflow_sha }}' "${BUILD_WF}"
  assert_success
  run code_grep -F 'repository: ycpss91255-docker/base' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight runs preflight.sh with the build manifest (#800)" {
  run code_grep -F 'script/ci/preflight.sh' "${BUILD_WF}"
  assert_success
  run code_grep -F 'script/ci/preflight/build.manifest' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight exports image_name into the manifest env var (#800)" {
  run code_grep -F 'PREFLIGHT_INPUT_IMAGE_NAME: ${{ inputs.image_name }}' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight probes GHCR login for the packages permission (#800)" {
  # A login probe feeds PREFLIGHT_PERM_PACKAGES; paves the way for the
  # registry-cache backend's packages: write.
  run code_grep -F 'PREFLIGHT_PERM_PACKAGES:' "${BUILD_WF}"
  assert_success
  run code_grep -F 'docker login ghcr.io' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight exports cache_backend into the manifest guard env (#801)" {
  # The build manifest's packages: write requirement is conditional on
  # cache_backend == registry; the preflight must feed the real input into
  # the guard env var the manifest names.
  run code_grep -F 'PREFLIGHT_CACHE_BACKEND: ${{ inputs.cache_backend }}' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight verifies a REAL packages:write, not just login, for the registry backend (#801)" {
  # A read-only token can still `docker login`, so login alone is not
  # proof of packages: write. The probe opens a GHCR blob upload against
  # the repo's buildcache namespace (202 == write granted) and only runs
  # the write check when cache_backend == registry.
  run code_grep -F '/buildcache/blobs/uploads/' "${BUILD_WF}"
  assert_success
  run code_grep -F 'CACHE_BACKEND: ${{ inputs.cache_backend }}' "${BUILD_WF}"
  assert_success
}

# ── release-worker.yaml ───────────────────────────────────────────────

@test "release-worker.yaml: declares a preflight job (#800)" {
  run code_grep -E '^  preflight:$' "${RELEASE_WF}"
  assert_success
}

@test "release-worker.yaml: release job gates on preflight (#800)" {
  run code_grep -E '^    needs: \[.*preflight.*\]$' "${RELEASE_WF}"
  assert_success
}

@test "release-worker.yaml: preflight runs preflight.sh with the release manifest (#800)" {
  run code_grep -F 'script/ci/preflight/release.manifest' "${RELEASE_WF}"
  assert_success
}

@test "release-worker.yaml: preflight exports archive_name_prefix into the manifest env var (#800)" {
  run code_grep -F 'PREFLIGHT_INPUT_ARCHIVE_NAME_PREFIX: ${{ inputs.archive_name_prefix }}' "${RELEASE_WF}"
  assert_success
}
