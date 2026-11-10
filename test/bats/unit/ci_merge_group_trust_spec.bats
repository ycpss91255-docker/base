#!/usr/bin/env bats
#
# Unit tests for script/ci/merge_group_trust.sh -- the resolver a
# merge_group run uses to prove that every pull request in its group is
# from this repository before a self-hosted runner builds it, base#1587.
#
# A merge_group payload carries no pull_request object, so the fork
# question is answered from the API instead: the repository's merge queue
# entries, read with one `gh api graphql` call. `gh` is stubbed via
# mock_cmd and answers with ${MOCK_REPLY}. The fixture JSON uses the field
# names that a GraphQL introspection of MergeQueueEntry and PullRequest
# printed (position, headCommit.oid, pullRequest.number,
# isCrossRepository, headRepository.nameWithOwner). When the caller passes
# `--jq <expr>` the stub applies it, as real gh does.
#
# why: The self-hosted fork guard fails closed on merge_group, and a site
# opens only on this resolver's answer. These specs pin that the answer is
# true only when every pull request in the group is proven same-repository,
# base#1587.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir

  TRUST="/source/script/ci/merge_group_trust.sh"

  export REPO="ycpss91255-docker/base"
  export BASE_REF="refs/heads/main"
  unset GITHUB_OUTPUT

  mock_cmd "gh" '
case "$1:$2" in
  api:graphql)
    _jq=""
    while (( $# > 0 )); do
      if [[ "$1" == "--jq" || "$1" == "-q" ]]; then _jq="$2"; shift; fi
      shift
    done
    if [[ -n "${_jq}" ]]; then
      printf "%s\n" "${MOCK_REPLY}" | jq -r "${_jq}"
    else
      printf "%s\n" "${MOCK_REPLY}"
    fi
    ;;
  *) printf "unexpected gh %s\n" "$*" >&2; exit 9 ;;
esac
'
}

teardown() { cleanup_mock_dir; }

# _entry <position> <oid> <pr-number> <isCrossRepository> <nameWithOwner>
_entry() {
  printf '{"position":%s,"headCommit":{"oid":"%s"},"pullRequest":{"number":%s,"isCrossRepository":%s,"headRepository":{"nameWithOwner":"%s"}}}' \
    "$1" "$2" "$3" "$4" "$5"
}

# _queue <entry-json>...: a mergeQueue(branch:"main") reply holding them.
_queue() {
  local _nodes
  _nodes="$(IFS=,; printf '%s' "$*")"
  printf '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[%s]}}}}}' "${_nodes}"
}

@test "merge_group_trust.sh: a group of three same-repository pull requests is trusted (base#1587)" {
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 false ycpss91255-docker/base)" \
    "$(_entry 3 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run bash "${TRUST}"
  assert_success
  assert_line "same_repo=true"
}

@test "merge_group_trust.sh: a failed gh call leaves the group untrusted and exits 0 (base#1587)" {
  # gh fails on every attempt; retry.sh's back-off sleep is stubbed so
  # the spec does not wait. Exit 0 with same_repo=false keeps classify
  # green, so the ci-rollup can name the reason (fail closed).
  mock_cmd "gh" 'printf "gh: HTTP 502\n" >&2; exit 1'
  mock_cmd "sleep" 'exit 0'
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
}
