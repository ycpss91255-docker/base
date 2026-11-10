#!/usr/bin/env bash
# merge_group_trust.sh - Say whether every pull request in a merge group
# is from this repository.
#
# Usage: REPO=<owner/name> BASE_REF=refs/heads/<branch> HEAD_SHA=<oid> \
#          HEAD_REF=<group head ref> merge_group_trust.sh
#
# Prints `same_repo=true` or `same_repo=false` on stdout.
#
# A merge_group payload carries no pull_request object, so the self-hosted
# fork guard cannot ask who wrote the code. This script asks the API: it
# reads the merge queue of BASE_REF with one `gh api graphql` call, finds
# the entry whose head commit is HEAD_SHA, and takes the group as that
# entry plus every entry ahead of it. The group is trusted only when every
# pull request in it is same-repository, base#1587.
set -euo pipefail

: "${REPO:?REPO is not set}"
: "${BASE_REF:?BASE_REF is not set}"
: "${HEAD_SHA:?HEAD_SHA is not set}"
: "${HEAD_REF:?HEAD_REF is not set}"

retry="$(dirname "${BASH_SOURCE[0]:-$0}")/retry.sh"

owner="${REPO%%/*}"
name="${REPO#*/}"
branch="${BASE_REF#refs/heads/}"

# The $-names are GraphQL variables, filled by gh's -F flags below.
# shellcheck disable=SC2016
query='query($owner: String!, $name: String!, $branch: String!) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: $branch) {
      entries(first: 100) {
        nodes {
          position
          headCommit { oid }
          pullRequest {
            number
            isCrossRepository
            headRepository { nameWithOwner }
          }
        }
      }
    }
  }
}'

# A failed call leaves the group unproven: print false and exit 0, so
# classify stays green and the ci-rollup names the reason, base#1587.
if ! reply="$("${retry}" 3 5 -- gh api graphql \
  -f query="${query}" -F owner="${owner}" -F name="${name}" \
  -F branch="${branch}")"; then
  printf '::error::merge_group_trust: the merge queue query failed\n' >&2
  printf 'same_repo=false\n'
  exit 0
fi

# A null queue (the queue is off for BASE_REF) proves nothing: say why,
# then answer false, base#1587.
if [[ "$(jq -r '.data.repository.mergeQueue == null' <<<"${reply}")" == "true" ]]; then
  printf '::error::merge_group_trust: %s has no merge queue for %s\n' \
    "${REPO}" "${branch}" >&2
  printf 'same_repo=false\n'
  exit 0
fi

# An empty queue holds no entry for HEAD_SHA, so nothing about the group
# is proven: say why, then answer false, base#1587.
if [[ "$(jq -r '[.data.repository.mergeQueue.entries.nodes[]?] | length' <<<"${reply}")" == "0" ]]; then
  printf '::error::merge_group_trust: the %s merge queue for %s has no entries\n' \
    "${REPO}" "${branch}" >&2
  printf 'same_repo=false\n'
  exit 0
fi

# No entry has HEAD_SHA as its head commit, so this run's group is not in
# the queue and nothing about it is proven: say why, then answer false,
# base#1587.
if [[ "$(jq -r --arg sha "${HEAD_SHA}" \
  '[.data.repository.mergeQueue.entries.nodes[]? | select(.headCommit.oid == $sha)] | length' \
  <<<"${reply}")" == "0" ]]; then
  printf '::error::merge_group_trust: the %s merge queue for %s has no entry for %s\n' \
    "${REPO}" "${branch}" "${HEAD_SHA}" >&2
  printf 'same_repo=false\n'
  exit 0
fi

# The group head ref is .../pr-<N>-<sha>; N names the entry's pull request.
pr=""
if [[ "${HEAD_REF}" =~ /pr-([0-9]+)-[0-9a-f]+$ ]]; then
  pr="${BASH_REMATCH[1]}"
fi

same_repo="$(jq -r --arg sha "${HEAD_SHA}" --arg pr "${pr}" \
  --arg repo "${REPO}" '
  [.data.repository.mergeQueue.entries.nodes[]?] as $all
  | ([$all[] | select(.headCommit.oid == $sha)] | first) as $e
  | if $e == null or ($e.pullRequest.number | tostring) != $pr then false
    else
      [$all[] | select(.position <= $e.position)]
      | length > 0 and all(
          .pullRequest.isCrossRepository == false
          and .pullRequest.headRepository.nameWithOwner == $repo)
    end' <<<"${reply}")"

printf 'same_repo=%s\n' "${same_repo}"
