#!/usr/bin/env bats
#
# Unit tests for the checksum half of script/test/drivers/pin_coverage.sh
# (base#1675): a github-release pin declared in
# dockerfile/Dockerfile.test-tools must carry a checksum entry. Fixture
# helpers mirror pin_coverage_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  SCRIPT_DIR=/source/script/test
  # shellcheck disable=SC1091
  source /source/script/test/drivers/pin_coverage.sh

  SCRATCH="$(mktemp -d)"
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/dockerfile" "${SCRATCH}/dist/dockerfile" \
           "${SCRATCH}/.github/workflows"
  printf 'FROM scratch\n' > "${SCRATCH}/dist/dockerfile/Dockerfile"
  printf 'name: x\non:\n  push:\n' > "${SCRATCH}/.github/workflows/x.yaml"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

_lint() {
  git -C "${SCRATCH}" add -A
  run _run_pin_coverage
}

_dockerfile() {
  printf '%s\n' "$@" > "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

_one_good_pin() {
  printf '%s\n' \
    '# tool-pin: seed github-release owner/seed' \
    'ARG SEED_VERSION=1.0.0' \
    >> "${SCRATCH}/dist/dockerfile/Dockerfile"
}

# why: A github-release pin in test-tools with no checksum ARG is an
# unverified download; the lint must name the pin and the expected ARG
@test "_run_pin_coverage: FAILS on a test-tools github-release pin with no checksum ARG" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0'
  _lint
  assert_failure
  assert_output --partial 'foo'
  assert_output --partial 'FOO_SHA256_AMD64'
}

# why: The pending allowlist is transitional; once a listed pin has its
# checksum the entry must be deleted, so the lint fails on a stale entry
@test "_run_pin_coverage: FAILS when a pending-allowlisted pin already has a checksum" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: just github-release casey/just' \
    'ARG JUST_VERSION=1.0.0' \
    'ARG JUST_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000' \
    'ARG JUST_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111'
  _lint
  assert_failure
  assert_output --partial 'stale'
}

# why: Both per-arch ARGs are required; a pin with only one arch checked
# leaves the other arch's download unverified
@test "_run_pin_coverage: FAILS on a pin with only the AMD64 checksum ARG" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0' \
    'ARG FOO_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000'
  _lint
  assert_failure
  assert_output --partial 'FOO_SHA256_ARM64'
}

# why: The same rule from the other side, so an either-arch match fails
@test "_run_pin_coverage: FAILS on a pin with only the ARM64 checksum ARG" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0' \
    'ARG FOO_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111'
  _lint
  assert_failure
  assert_output --partial 'FOO_SHA256_AMD64'
}

# why: The pending allowlist is what keeps main green while the sibling
# issues land their checksums; a listed pin with none must pass
@test "_run_pin_coverage: PASSES a pending-allowlisted pin that has no checksum ARG" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: kcov github-release SimonKagstrom/kcov' \
    'ARG KCOV_VERSION=1.0.0' \
    '# tool-pin: just github-release casey/just' \
    'ARG JUST_VERSION=1.0.0' \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=1.0.0' \
    '# tool-pin: bats-support github-release bats-core/bats-support' \
    'ARG BATS_SUPPORT_VERSION=1.0.0' \
    '# tool-pin: bats-assert github-release bats-core/bats-assert' \
    'ARG BATS_ASSERT_VERSION=1.0.0'
  _lint
  assert_success
  assert_output --partial 'clean'
}
