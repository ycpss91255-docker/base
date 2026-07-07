#!/usr/bin/env bats
#
# ci_preflight_spec.bats -- unit tests for script/ci/preflight.sh, the
# caller-contract validator the reusable build/release workers run before
# doing any real work.
#
# The validator is a pure shell engine: it reads a declared requirement
# manifest (the explicit list of what a caller must provide) and checks
# each entry against an environment variable the worker populates from the
# real inputs / permission probes. Any missing item -> a plain-language,
# early, non-zero failure that names exactly what to add to main.yaml.
#
# Pushing the logic here (host-testable under `just test`) keeps the GHA
# wiring in build-worker.yaml / release-worker.yaml thin: the workflow only
# exports the env and calls this script.

bats_require_minimum_version 1.5.0

PREFLIGHT="/source/script/ci/preflight.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  MANIFEST="$(mktemp)"
}

teardown() {
  rm -f "${MANIFEST}"
}

@test "preflight: passes when a required input is present" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name to your build-worker.yaml call
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: fails when a required input is empty, naming the input" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add `image_name:` under the `with:` block in your main.yaml
EOF
  PREFLIGHT_INPUT_IMAGE_NAME="" run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  # Names the missing requirement and quotes the fix hint verbatim.
  assert_output --partial 'image_name'
  assert_output --partial 'with:'
  assert_output --partial 'main.yaml'
}

@test "preflight: passes when a permission probe reports granted" {
  cat > "${MANIFEST}" <<'EOF'
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:` in your main.yaml
EOF
  PREFLIGHT_PERM_PACKAGES=granted run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: fails when a permission probe reports missing" {
  cat > "${MANIFEST}" <<'EOF'
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:` in your main.yaml
EOF
  PREFLIGHT_PERM_PACKAGES=missing run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
  assert_output --partial 'permissions:'
}

@test "preflight: an unset permission probe env fails (never silently green)" {
  cat > "${MANIFEST}" <<'EOF'
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:` in your main.yaml
EOF
  run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
}

@test "preflight: reports every unmet requirement in one pass" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add `image_name:` under `with:`
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:`
EOF
  run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  # Both gaps surface together, not fail-on-first.
  assert_output --partial 'image_name'
  assert_output --partial 'packages'
}

@test "preflight --list: prints the requirement list and exits 0 (self-describing)" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant packages
EOF
  run bash "${PREFLIGHT}" --list "${MANIFEST}"
  assert_success
  assert_output --partial 'image_name'
  assert_output --partial 'packages'
  assert_output --partial 'the container image name'
}

@test "preflight: comment and blank lines in the manifest are ignored" {
  cat > "${MANIFEST}" <<'EOF'
# this is a comment

input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ai_agent run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: missing manifest file is a usage error (exit 2)" {
  run bash "${PREFLIGHT}" /no/such/manifest
  assert_failure
  assert_equal "${status}" 2
}

