#!/usr/bin/env bash
# check_commit_attribution.sh - Fail when a commit in the pull request range
# carries AI attribution, base#1989.
#
# Usage: EVENT_NAME=<event> BASE_SHA=<oid> HEAD_SHA=<oid> check_commit_attribution.sh
#
# Walks `git rev-list BASE_SHA..HEAD_SHA` and matches each commit's message
# against the marker list of the local attribution hook, the addresses in
# its trailers against the model vendor's noreply address, and its author
# and committer emails against that address. The list is copied here
# because the hook lives outside the repository and CI cannot read it.
# Prints `::error::commit <sha>: <marker>` for each hit and exits 1 when any
# commit hits.
set -euo pipefail

# Only a pull request or a merge group has a range to walk; push and tag runs
# pass with a notice instead of failing on the missing shas, base#1989.
case "${EVENT_NAME:-}" in
  pull_request | merge_group) ;;
  *)
    printf '::notice::no range to check for event %s\n' "${EVENT_NAME:-unset}"
    exit 0
    ;;
esac

: "${BASE_SHA:?BASE_SHA is not set}"
: "${HEAD_SHA:?HEAD_SHA is not set}"

# A sha that does not resolve would leave the walk empty and pass silently,
# so both ends must name a commit before the walk, base#1989.
for end in BASE_SHA HEAD_SHA; do
  if ! git rev-parse --quiet --verify "${!end}^{commit}" >/dev/null; then
    printf '::error::%s %s does not resolve to a commit\n' "${end}" "${!end}"
    exit 1
  fi
done

# The hook's marker list, one pattern per alternative so each hit names the
# marker it found, built from parts so the repository's own attribution
# guards do not fire on this file, base#1989.
model="Cla""ude"
footer="Generated with (\\[)?${model} Code"
coauthor="Co-Authored-By:[[:space:]]*${model}"
# The model vendor's noreply address. A trailer under any key that uses it
# fails; prose that names it, or an address that only contains it, does
# not, base#1989.
addr="noreply@""anthropic.com"
# One email-shaped token: the run around an @ up to white space, an angle
# bracket, a comma, a semicolon, a colon, a quote or a parenthesis, so the
# address is read whole wherever a trailer value puts it, base#1989.
sep='<>[:space:],;:"()'
email_token="[^${sep}]+@[^${sep}]+"

hits=0
count=0
# _hit <sha> <marker>: report one hit and count it.
_hit() {
  printf '::error::commit %s: %s\n' "$1" "$2"
  hits=$((hits + 1))
}

while IFS= read -r sha; do
  count=$((count + 1))
  # The body plus git's own unfolded trailers: git prints a trailer written
  # with a space before the colon in canonical `key: value` form, so the
  # marker list sees it too, base#1989.
  msg="$(git log -1 --format='%B%n%(trailers:unfold)' "${sha}")"
  if grep -qiE "${footer}" <<<"${msg}"; then
    _hit "${sha}" "generated-with footer in message"
  fi
  if grep -qiE "${coauthor}" <<<"${msg}"; then
    _hit "${sha}" "co-author trailer naming the model in message"
  fi
  # Each address in the trailer lines git parses out of the message, so a
  # prose line inside the trailer block is left out, compared whole and
  # without regard to case, base#1989.
  trailers="$(git log -1 --format='%(trailers:only)' "${sha}")"
  emails="$(grep -oE "${email_token}" <<<"${trailers}" || true)"
  if grep -qixF "${addr}" <<<"${emails}"; then
    _hit "${sha}" "noreply address in message"
  fi
  # The address as the author identity is attribution even when the message
  # is clean, base#1989.
  if grep -qixF "${addr}" <<<"$(git log -1 --format='%ae' "${sha}")"; then
    _hit "${sha}" "noreply address as author email"
  fi
  # The committer identity is read on its own: a commit can keep a human
  # author while the address commits it, base#1989.
  if grep -qixF "${addr}" <<<"$(git log -1 --format='%ce' "${sha}")"; then
    _hit "${sha}" "noreply address as committer email"
  fi
done < <(git rev-list "${BASE_SHA}..${HEAD_SHA}")

if [[ "${hits}" -gt 0 ]]; then
  exit 1
fi
printf 'no AI attribution in %d commit(s)\n' "${count}"
