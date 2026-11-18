#!/usr/bin/env bats
#
# Unit tests for dockerfile/apk-retry.sh -- the bounded-retry wrapper every
# `apk` call in Dockerfile.test-tools goes through (base#1422).
#
# The Alpine `main` index fetch failed twice with 403 / "Permission denied"
# after a 240 s stall, and nothing retried it. Only the kcov-builder stage
# had an ad-hoc loop. The seam is the wrapper's CLI (exit code + how often
# apk ran) and the Dockerfile text (no bare `apk add` / `apk update`). apk
# is a stub on PATH, so no network and no daemon are needed.

setup() {
  HELPER=/source/dockerfile/apk-retry.sh
  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  MOCK_DIR="${BATS_TEST_TMPDIR}/mock"
  mkdir -p "${MOCK_DIR}"
  COUNT="${BATS_TEST_TMPDIR}/count"
  : > "${COUNT}"
}

# _stub_apk <fail-count> -- an apk that fails its first <fail-count> runs
# and then succeeds, recording every run in ${COUNT}.
_stub_apk() {
  cat > "${MOCK_DIR}/apk" <<STUB
#!/bin/sh
echo run >> "${COUNT}"
n=\$(wc -l < "${COUNT}")
[ "\${n}" -gt "$1" ]
STUB
  chmod +x "${MOCK_DIR}/apk"
}

# why: base#1422 -- a transient index failure must be retried; before the
# wrapper the build died on the first 403.
@test "apk-retry: a transient apk failure is retried and then succeeds" {
  _stub_apk 2

  run env PATH="${MOCK_DIR}:${PATH}" APK_RETRY_SLEEP=0 sh "${HELPER}" add --no-cache git

  [ "${status}" -eq 0 ]
  [ "$(wc -l < "${COUNT}")" -eq 3 ]
}

# why: base#1422 -- a lasting failure must still fail, within a bound, and
# say so; an unbounded loop would hang the build instead of reporting it.
@test "apk-retry: a lasting apk failure exits non-zero after a bounded number of tries with a clear message" {
  _stub_apk 1000

  run env PATH="${MOCK_DIR}:${PATH}" APK_RETRY_SLEEP=0 sh "${HELPER}" add --no-cache git

  [ "${status}" -ne 0 ]
  [ "$(wc -l < "${COUNT}")" -le 10 ]
  [[ "${output}" == *"apk-retry: apk add failed after"* ]]
}

# why: base#1422 -- the first slice of the issue: every apk call in the
# Dockerfile goes through the wrapper. Comment lines are skipped because
# the file discusses `apk add` in prose more often than it runs it.
@test "Dockerfile.test-tools: no apk add or apk update bypasses apk-retry" {
  run grep -nE '^[^#]*(^|[^-[:alnum:]_/])apk[[:space:]]+(add|update)' "${DOCKERFILE}"

  [ "${status}" -eq 1 ] || fail "bare apk call(s): ${output}"
}

# why: base#1422 -- the wrapper has to reach the image: a Dockerfile that
# calls apk-retry without COPYing it fails every package stage.
@test "Dockerfile.test-tools: the alpine-apk base stage ships the apk-retry helper" {
  run grep -E '^COPY dockerfile/apk-retry\.sh /usr/local/bin/apk-retry' "${DOCKERFILE}"

  [ "${status}" -eq 0 ]
}
