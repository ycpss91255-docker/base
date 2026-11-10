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
#
# Every case that proves nothing (failed call, no queue, no entry, a
# mismatched entry, a null head repository) prints `same_repo=false`, an
# `::error::` line naming why, and exits 0: a red classify would hide the
# reason, so classify stays green and the ci-rollup fails the run instead.
set -euo pipefail

: "${REPO:?REPO is not set}"
: "${BASE_REF:?BASE_REF is not set}"
: "${HEAD_SHA:?HEAD_SHA is not set}"
: "${HEAD_REF:?HEAD_REF is not set}"

retry="$(dirname "${BASH_SOURCE[0]:-$0}")/retry.sh"

owner="${REPO%%/*}"
name="${REPO#*/}"
branch="${BASE_REF#refs/heads/}"

# untrusted <reason>: name why the group is unproven, answer false, and
# exit 0, base#1587.
untrusted() {
  printf '::error::merge_group_trust: %s\n' "$1" >&2
  printf 'same_repo=false\n'
  exit 0
}

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

if ! reply="$("${retry}" 3 5 -- gh api graphql \
  -f query="${query}" -F owner="${owner}" -F name="${name}" \
  -F branch="${branch}")"; then
  untrusted "the merge queue query failed"
fi

# A null queue means the queue is off for BASE_REF.
if [[ "$(jq -r '.data.repository.mergeQueue == null' <<<"${reply}")" == "true" ]]; then
  untrusted "${REPO} has no merge queue for ${branch}"
fi

nodes="$(jq -c '[.data.repository.mergeQueue.entries.nodes[]?]' <<<"${reply}")"
if [[ "$(jq -r 'length' <<<"${nodes}")" == "0" ]]; then
  untrusted "the ${REPO} merge queue for ${branch} has no entries"
fi

# The entry whose head commit is HEAD_SHA is this run's group head.
entry="$(jq -c --arg sha "${HEAD_SHA}" \
  'map(select(.headCommit.oid == $sha)) | first // empty' <<<"${nodes}")"
if [[ -z "${entry}" ]]; then
  untrusted "the ${REPO} merge queue for ${branch} has no entry for ${HEAD_SHA}"
fi

# The group head ref is .../pr-<N>-<sha>; N must be the entry's pull
# request, or the group is not proven to be that entry.
pr=""
if [[ "${HEAD_REF}" =~ /pr-([0-9]+)-[0-9a-f]+$ ]]; then
  pr="${BASH_REMATCH[1]}"
fi
entry_pr="$(jq -r '.pullRequest.number // "" | tostring' <<<"${entry}")"
if [[ "${entry_pr}" != "${pr}" ]]; then
  untrusted "the entry for ${HEAD_SHA} is pull request ${entry_pr:-none}, but ${HEAD_REF} names pr-${pr:-none}"
fi

# The group: the entry plus every entry ahead of it in the queue.
group="$(jq -c --argjson e "${entry}" \
  'map(select(.position <= $e.position))' <<<"${nodes}")"

# A null head repository (deleted) does not prove who wrote the code.
null_head="$(jq -r \
  'map(select(.pullRequest.headRepository == null) | .pullRequest.number | tostring) | join(" ")' \
  <<<"${group}")"
if [[ -n "${null_head}" ]]; then
  untrusted "pull request ${null_head} in the group has no head repository"
fi

same_repo="$(jq -r --arg repo "${REPO}" '
  length > 0 and all(
    .pullRequest.isCrossRepository == false
    and .pullRequest.headRepository.nameWithOwner == $repo)' <<<"${group}")"

printf 'same_repo=%s\n' "${same_repo}"
