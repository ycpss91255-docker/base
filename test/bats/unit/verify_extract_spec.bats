#!/usr/bin/env bats
#
# Unit tests for dockerfile/verify-extract.sh -- the "verify the sha256 of
# a downloaded archive, THEN extract it" helper the lint-tools stage of
# Dockerfile.test-tools uses for the shellcheck release asset (base#1648).
#
# The seam is the helper's CLI: exit code + what lands in the destination
# directory. The archive is a tiny local fixture, so no network and no
# daemon are needed. The "good" hash is computed by the spec with the host
# `sha256sum` before the helper runs; the "bad" hash is a worked literal.

setup() {
  HELPER=/source/dockerfile/verify-extract.sh
  FIX="${BATS_TEST_TMPDIR}/fix"
  DEST="${BATS_TEST_TMPDIR}/dest"
  mkdir -p "${FIX}/payload" "${DEST}"
  printf 'payload-literal\n' > "${FIX}/payload/hello.txt"
  tar -czf "${FIX}/a.tar.gz" -C "${FIX}/payload" hello.txt
}

@test "verify-extract: a wrong sha256 exits non-zero and extracts nothing" {
  local _bad
  _bad="0000000000000000000000000000000000000000000000000000000000000000"

  run sh "${HELPER}" "${FIX}/a.tar.gz" "${_bad}" "${DEST}"

  # Exactly 1 is the helper's "checksum mismatch" code; a missing helper
  # (127) or a usage error (2) must not satisfy this case.
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${DEST}")" ]
}
