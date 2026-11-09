#!/usr/bin/env bash
# retry.sh - Run a command up to <attempts> times until it succeeds.
#
# Usage: retry.sh <attempts> <first-delay-s> -- <cmd...>
#
# The one bounded-retry helper CI wraps around a network fetch (the
# actionlint image pull, the just install), so a single upstream 5xx does
# not fail the job, base#1562.
set -euo pipefail

usage() {
  printf 'retry.sh: usage: retry.sh <attempts> <first-delay-s> -- <cmd...>\n' >&2
  exit 2
}

# A malformed call is refused before the command runs, base#1562.
(( $# >= 4 )) || usage
[[ "$1" =~ ^[0-9]+$ ]] || usage
(( 10#$1 >= 1 )) || usage
[[ "$2" =~ ^[0-9]+$ ]] || usage
[[ "$3" == "--" ]] || usage

attempts=$(( 10#$1 ))
delay=$(( 10#$2 ))
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
  sleep "${delay}"
  delay=$(( delay * 2 ))
  i=$(( i + 1 ))
done
