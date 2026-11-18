#!/bin/sh
# verify-extract.sh -- verify the sha256 of a downloaded archive, then extract.
#
# Usage: verify-extract.sh <archive> <sha256> <dest-dir>
#
# Exit codes: 0 verified and extracted, 1 checksum mismatch (nothing
# extracted), 2 usage error or empty/malformed sha256 (fail closed).
# POSIX sh: the lint-tools stage is alpine/busybox (base#1648).

if [ "$#" -ne 3 ]; then
  echo "usage: verify-extract.sh <archive> <sha256> <dest-dir>" >&2
  exit 2
fi

_archive=$1
_sha=$2
_dest=$3

case "${_sha}" in
  *[!0-9a-fA-F]*|"")
    echo "verify-extract: sha256 must be 64 hex characters" >&2
    exit 2
    ;;
esac
if [ "${#_sha}" -ne 64 ]; then
  echo "verify-extract: sha256 must be 64 hex characters" >&2
  exit 2
fi

if ! printf '%s  %s\n' "${_sha}" "${_archive}" | sha256sum -c - >/dev/null 2>&1; then
  echo "verify-extract: sha256 mismatch for ${_archive}" >&2
  exit 1
fi

tar -xf "${_archive}" -C "${_dest}"
