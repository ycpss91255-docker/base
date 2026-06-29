#!/usr/bin/env bats
#
# Unit tests for check-base-version.sh — the per-repo base version
# monitor shipped via the subtree. Two surfaces:
#
#   * `compare <local> <remote>` — pure semver comparison, no network.
#     Exit 0 when <remote> is strictly newer (this repo is behind).
#   * `run` — full flow: resolve the local .base/.version, query base's
#     releases/latest, dedupe open tracking issues, file one when behind.
#
# `gh` is stubbed via mock_cmd so `run` never touches the network. The
# stub dispatches on "$1:$2" and reads its fixtures from MOCK_* env vars
# so each test can vary latest-release / existing-issues without
# rewriting the stub body.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir

  SCRIPT="/source/dist/script/base/check-base-version.sh"

  # Deterministic local version via env override (the real script walks
  # up to .base/.version; tests pin it to a temp file instead).
  VERSION_FILE="${BATS_TEST_TMPDIR}/.version"
  export BASE_VERSION_FILE="${VERSION_FILE}"
  export MONITOR_LABEL="base-upgrade"

  # `gh issue create` invocations land here for assertion.
  export MOCK_CALLS="${BATS_TEST_TMPDIR}/gh-calls"
  : > "${MOCK_CALLS}"
}

teardown() { cleanup_mock_dir; }

# Stub `gh`: `api` echoes ${MOCK_LATEST}; `issue list` echoes
# ${MOCK_EXISTING} (newline-separated open-issue titles); `issue create`
# records its argv to ${MOCK_CALLS}. Single-quoted body so the env refs
# expand at stub runtime, not at mock_cmd authoring time.
_stub_gh() {
  mock_cmd "gh" '
case "$1:$2" in
  api:*)        printf "%s\n" "${MOCK_LATEST}" ;;
  issue:list)   printf "%s" "${MOCK_EXISTING:-}" ;;
  issue:create) printf "create %s\n" "$*" >> "${MOCK_CALLS}"; printf "https://x/issues/1\n" ;;
  *)            printf "unexpected gh %s\n" "$*" >&2; exit 9 ;;
esac
'
}

# ════════════════════════════════════════════════════════════════════
# compare — pure semver, numeric per-field (not lexical)
# ════════════════════════════════════════════════════════════════════

@test "compare: newer minor is behind (v0.41.0 < v0.42.0)" {
  run bash "${SCRIPT}" compare v0.41.0 v0.42.0
  assert_success
}

@test "compare: equal versions are not behind" {
  run bash "${SCRIPT}" compare v0.41.0 v0.41.0
  assert_failure
}

@test "compare: older remote is not behind" {
  run bash "${SCRIPT}" compare v0.42.0 v0.41.0
  assert_failure
}

@test "compare: newer patch is behind" {
  run bash "${SCRIPT}" compare v0.41.0 v0.41.1
  assert_success
}

@test "compare: numeric not lexical (v0.9.7 < v0.10.0)" {
  run bash "${SCRIPT}" compare v0.9.7 v0.10.0
  assert_success
}

@test "compare: newer major is behind (v0.41.0 < v1.0.0)" {
  run bash "${SCRIPT}" compare v0.41.0 v1.0.0
  assert_success
}

@test "compare: tolerates a missing leading v" {
  run bash "${SCRIPT}" compare 0.41.0 0.42.0
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# run — end-to-end with stubbed gh
# ════════════════════════════════════════════════════════════════════

@test "run: behind -> opens a tracking issue naming the target version" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  assert_output --partial "v0.42.0"

  run cat "${MOCK_CALLS}"
  assert_output --partial "create"
  assert_output --partial "v0.42.0"
}

@test "run: opened issue carries the base-upgrade label" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  run cat "${MOCK_CALLS}"
  assert_output --partial "base-upgrade"
}

@test "run: up to date -> no issue created" {
  echo "v0.42.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  [ ! -s "${MOCK_CALLS}" ]
}

@test "run: existing open issue for the target -> skip (dedup)" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" \
         MOCK_EXISTING="chore: .base behind base — upgrade v0.41.0 -> v0.42.0"
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  [ ! -s "${MOCK_CALLS}" ]
}

@test "run: empty latest from API -> fails without creating an issue" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_failure
  [ ! -s "${MOCK_CALLS}" ]
}
