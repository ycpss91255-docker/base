#!/bin/sh
# apt-retry.sh - Run `apt-get update && <cmd...>` up to <attempts> times.
#
# Usage: apt-retry.sh <attempts> <first-delay-s> -- <cmd...>
#
# The template Dockerfile wraps each apt update + install layer in this
# helper, so one failed fetch from a skewed mirror does not fail the image
# build: each attempt refreshes the index before the install, base#1602.
set -eu

attempts="$1"
delay="$2"
shift 3

i=1
while :; do
  rc=0
  { apt-get update && "$@"; } || rc=$?
  if [ "${rc}" -eq 0 ]; then
    exit 0
  fi
  printf 'apt-retry: attempt %d/%d failed (exit %d)\n' "${i}" "${attempts}" "${rc}" >&2
  if [ "${i}" -ge "${attempts}" ]; then
    exit "${rc}"
  fi
  sleep "${delay}"
  delay=$((delay * 2))
  i=$((i + 1))
done
