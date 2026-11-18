#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/moving_tag.sh -- the "nothing internal
# consumes a moving test-tools tag" lint (base#1647).
#
# The release workflow publishes test-tools as :<ver> always, :latest for a
# non-prerelease tag and :main from main. :latest and :main are conveniences
# for humans and bootstrap; an internal build that resolves the tooling image
# by one of them gets whatever was pushed last, which is how base#1122
# happened. The lint refuses such a reference in base's own workflows,
# Dockerfiles, compose, justfile and scripts outside a per-line allow-list.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents. Shape mirrors
# arch_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/moving_tag.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_moving_tag: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_moving_tag: FAILS on a workflow that pulls test-tools:latest, naming file and line (base#1647)" {
  _write ".github/workflows/x.yaml" \
    'jobs:' \
    '  image: ghcr.io/ycpss91255-docker/test-tools:latest'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".github/workflows/x.yaml:2"* ]]
}
