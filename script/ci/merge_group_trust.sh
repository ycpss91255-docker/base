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

reply="$("${retry}" 3 5 -- gh api graphql \
  -f query="${query}" -F owner="${owner}" -F name="${name}" \
  -F branch="${branch}")"

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
