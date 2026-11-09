#!/usr/bin/env bash
# retry.sh - Run a command up to <attempts> times until it succeeds.
#
# Usage: retry.sh <attempts> <first-delay-s> -- <cmd...>
#
# The one bounded-retry helper CI wraps around a network fetch (the
# actionlint image pull, the just install), so a single upstream 5xx does
# not fail the job, base#1562.
set -euo pipefail

attempts="$1"
shift 3

i=1
while :; do
  rc=0
  "$@" || rc=$?
  if (( rc == 0 )); then
    exit 0
  fi
  printf 'retry: attempt %d/%d failed (exit %d)\n' "${i}" "${attempts}" "${rc}" >&2
  if (( i >= attempts )); then
    exit "${rc}"
  fi
  i=$(( i + 1 ))
done
