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

# why: base#1672 -- hadolint is a raw binary, not an archive, so the
# lint-tools stage needs a verify-only form. The correct hash must exit 0 and
# leave the file byte-identical; the expected hash comes from the host
# sha256sum, not from the helper. A mode that extracts (tar on a non-archive
# fails) or always exits 1 cannot pass this.
@test "verify-extract --verify-only: the correct sha256 exits 0 and leaves the file untouched" {
  local _raw _good
  _raw="${FIX}/raw-bin"
  printf 'raw-binary-literal\n' > "${_raw}"
  _good="$(sha256sum "${_raw}")"
  _good="${_good%% *}"

  run sh "${HELPER}" --verify-only "${_raw}" "${_good}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${_raw}")" = "raw-binary-literal" ]
}

# why: base#1672 -- a verify-only mode that always exits 0 would install a
# tampered hadolint. A worked-literal wrong hash must exit exactly 1 and
# name the mismatch, so a usage error (2) cannot satisfy it.
@test "verify-extract --verify-only: a wrong sha256 exits 1 with the mismatch message" {
  local _raw _bad
  _raw="${FIX}/raw-bin"
  printf 'raw-binary-literal\n' > "${_raw}"
  _bad="0000000000000000000000000000000000000000000000000000000000000000"

  run sh "${HELPER}" --verify-only "${_raw}" "${_bad}"

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"sha256 mismatch"* ]]
}

# why: base#1672 -- an ARG blanked by --build-arg must fail closed in the
# verify-only mode too (exit 2), not skip the 64-hex check.
@test "verify-extract --verify-only: an empty sha256 exits 2" {
  local _raw
  _raw="${FIX}/raw-bin"
  printf 'raw-binary-literal\n' > "${_raw}"

  run sh "${HELPER}" --verify-only "${_raw}" ""

  [ "${status}" -eq 2 ]
}

# why: base#1672 -- a truncated 63-character hash is malformed, not a
# mismatch: exit 2 before any comparison, in verify-only mode as well.
@test "verify-extract --verify-only: a 63-character sha256 exits 2" {
  local _raw _short
  _raw="${FIX}/raw-bin"
  printf 'raw-binary-literal\n' > "${_raw}"
  _short="000000000000000000000000000000000000000000000000000000000000000"

  run sh "${HELPER}" --verify-only "${_raw}" "${_short}"

  [ "${status}" -eq 2 ]
}

# why: base#1672 review -- --verify-only with the wrong argument count must
# take the usage branch (exit 2), not be read as the 3-arg archive form.
@test "verify-extract --verify-only: a missing sha256 argument exits 2" {
  run sh "${HELPER}" --verify-only "${FIX}/a.tar.gz"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"usage"* ]]
}
