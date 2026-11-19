#!/bin/sh
# verify-extract.sh -- verify the sha256 of a downloaded archive, then extract.
#
# Usage: verify-extract.sh <archive> <sha256> <dest-dir>
#        verify-extract.sh --verify-only <file> <sha256>
#
# --verify-only checks a raw binary (no archive, no extraction), base#1672.
#
# Exit codes: 0 verified and extracted, 1 checksum mismatch (nothing
# extracted), 2 usage error or empty/malformed sha256 (fail closed).
# POSIX sh: the lint-tools stage is alpine/busybox (base#1648).

if [ "$#" -eq 3 ] && [ "$1" = "--verify-only" ]; then
  # verify-only form: check a raw (non-archive) file, no extraction.
  _verify_only=1
  _archive=$2
  _sha=$3
elif [ "$#" -eq 3 ]; then
  _verify_only=0
  _archive=$1
  _sha=$2
  _dest=$3
else
  echo "usage: verify-extract.sh <archive> <sha256> <dest-dir>" >&2
  echo "       verify-extract.sh --verify-only <file> <sha256>" >&2
  exit 2
fi

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

if [ "${_verify_only}" -eq 1 ]; then
  exit 0
fi

tar -xf "${_archive}" -C "${_dest}"
