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
