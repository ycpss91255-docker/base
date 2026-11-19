#!/usr/bin/env bash
# check_commit_attribution.sh - Fail when a commit in the pull request range
# carries AI attribution, base#1989.
#
# Usage: BASE_SHA=<oid> HEAD_SHA=<oid> check_commit_attribution.sh
#
# Walks `git rev-list BASE_SHA..HEAD_SHA` and matches each commit's message
# against the marker list of the local attribution hook and the model
# vendor's noreply address. The list is copied here because the hook lives
# outside the repository and CI cannot read it.
# Prints `::error::commit <sha>: <marker>` for each hit and exits 1 when any
# commit hits.
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is not set}"
: "${HEAD_SHA:?HEAD_SHA is not set}"

# The hook's marker list, built from parts so the repository's own
# attribution guards do not fire on this file, base#1989.
model="Cla""ude"
markers="Generated with (\\[)?${model} Code|Co-Authored-By:[[:space:]]*${model}"
# The model vendor's noreply address, matched as a fixed string anywhere in
# the message so a trailer under any key carrying it fails, base#1989.
addr="noreply@""anthropic.com"

hits=0
count=0
while IFS= read -r sha; do
  count=$((count + 1))
  # The body plus git's own unfolded trailers: git prints a trailer written
  # with a space before the colon in canonical `key: value` form, so the
  # marker list sees it too, base#1989.
  msg="$(git log -1 --format='%B%n%(trailers:unfold)' "${sha}")"
  if grep -qiE "${markers}" <<<"${msg}"; then
    printf '::error::commit %s: attribution marker in message\n' "${sha}"
    hits=$((hits + 1))
  fi
  if grep -qiF "${addr}" <<<"${msg}"; then
    printf '::error::commit %s: noreply address in message\n' "${sha}"
    hits=$((hits + 1))
  fi
  # The address as the author identity is attribution even when the message
  # is clean, base#1989.
  if grep -qixF "${addr}" <<<"$(git log -1 --format='%ae' "${sha}")"; then
    printf '::error::commit %s: noreply address as author email\n' "${sha}"
    hits=$((hits + 1))
  fi
done < <(git rev-list "${BASE_SHA}..${HEAD_SHA}")

if [[ "${hits}" -gt 0 ]]; then
  exit 1
fi
printf 'no AI attribution in %d commit(s)\n' "${count}"
