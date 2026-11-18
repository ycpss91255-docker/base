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

# why: base#1648 -- the acceptance criterion. Before the helper the install
# path was `curl | tar -x` with no comparison at all; a wrong hash has to
# refuse AND leave the destination empty, which rules out verify-after-extract.
@test "verify-extract: a wrong sha256 exits non-zero and extracts nothing" {
  local _bad
  _bad="0000000000000000000000000000000000000000000000000000000000000000"

  run sh "${HELPER}" "${FIX}/a.tar.gz" "${_bad}" "${DEST}"

  # Exactly 1 is the helper's "checksum mismatch" code; a missing helper
  # (127) or a usage error (2) must not satisfy this case.
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${DEST}")" ]
}

# why: base#1648 -- the other half of the gate. A helper that always exits 1
# passes the wrong-hash case, so the build would never install shellcheck.
# The expected hash comes from the host sha256sum, not from the helper.
@test "verify-extract: the correct sha256 exits 0 and extracts the payload" {
  local _good
  _good="$(sha256sum "${FIX}/a.tar.gz")"
  _good="${_good%% *}"

  run sh "${HELPER}" "${FIX}/a.tar.gz" "${_good}" "${DEST}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${DEST}/hello.txt")" = "payload-literal" ]
}

# why: base#1648 -- an ARG blanked by --build-arg (or never pinned) must
# fail closed with the usage code 2, not pass vacuously and not extract.
@test "verify-extract: an empty sha256 exits 2 and extracts nothing" {
  run sh "${HELPER}" "${FIX}/a.tar.gz" "" "${DEST}"

  [ "${status}" -eq 2 ]
  [ -z "$(ls -A "${DEST}")" ]
}

# why: base#1648 -- a truncated 63-character hash is malformed, not a
# mismatch; it must be refused as exit 2 before any comparison or extract.
@test "verify-extract: a 63-character sha256 exits 2 and extracts nothing" {
  local _short
  _short="000000000000000000000000000000000000000000000000000000000000000"

  run sh "${HELPER}" "${FIX}/a.tar.gz" "${_short}" "${DEST}"

  [ "${status}" -eq 2 ]
  [ -z "$(ls -A "${DEST}")" ]
}
