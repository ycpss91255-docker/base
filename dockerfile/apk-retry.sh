#!/bin/sh
# apk-retry.sh -- run `apk <args>` with a bounded retry and backoff.
#
# Usage: apk-retry <apk-args...>      e.g. apk-retry add --no-cache git
#
# The Alpine index fetch fails intermittently (403 / "Permission denied"
# after a long stall, base#1422) and a bare `apk add` fails the whole
# build on the first miss. This retries up to APK_RETRY_ATTEMPTS times
# (default 4), sleeping APK_RETRY_SLEEP seconds (default 10) times the
# attempt number between tries, then exits 1 with a message naming the
# command, so a lasting failure is bounded and not mistaken for a
# packaging mistake. POSIX sh: the stages are alpine/busybox.

if [ "$#" -lt 1 ]; then
  echo "usage: apk-retry <apk-args...>" >&2
  exit 2
fi

_max=${APK_RETRY_ATTEMPTS:-4}
_base=${APK_RETRY_SLEEP:-10}
_try=1
while :; do
  if apk "$@"; then
    exit 0
  fi
  if [ "${_try}" -ge "${_max}" ]; then
    echo "apk-retry: apk $* failed after ${_try} attempts; the package index or mirror is unreachable or refusing the request" >&2
    exit 1
  fi
  _wait=$((_base * _try))
  echo "apk-retry: apk $1 failed (attempt ${_try} of ${_max}); retrying in ${_wait} s" >&2
  sleep "${_wait}"
  _try=$((_try + 1))
done
