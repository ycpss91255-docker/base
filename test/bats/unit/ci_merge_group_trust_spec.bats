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
# false when the call or the queue proves nothing, false when a pull request
# at or ahead of the HEAD_SHA entry is cross-repository or names another
# head repository, and true when the only fork sits behind that entry,
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

# why: The only case that opens a self-hosted runner on a queue run. A
# resolver that always answered false would pass every other spec here and
# skip `build` on every merge_group run, so the queue could never go green
# (base#1587).
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

# why: An API outage proves nothing about the group, so it must not read
# as trusted; and a non-zero exit would turn classify red and hide the
# reason the rollup is meant to print (base#1587).
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

# why: One transient API 5xx must not mark the group untrusted: the
# rollup would then fail every queue run on a blip. The call goes through
# retry.sh, so a gh that fails once and then answers still proves the
# group same-repository; a bare `gh api graphql` call fails this spec
# (base#1587).
@test "merge_group_trust.sh: a gh call that fails once and then answers is retried and trusted (base#1587)" {
  MOCK_REPLY="$(_queue \
    "$(_entry 1 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
  : > "${GH_CALLS}"
  mock_cmd "gh" '
printf "x\n" >> "${GH_CALLS}"
if (( $(wc -l < "${GH_CALLS}") == 1 )); then
  printf "gh: HTTP 502\n" >&2
  exit 1
fi
printf "%s\n" "${MOCK_REPLY}"
'
  mock_cmd "sleep" 'exit 0'
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=true"
  [[ "$(wc -l < "${GH_CALLS}")" -eq 2 ]]
}

# why: A merge_group run while the queue is off (or turned off mid-run)
# has no entries to prove anything with; treating null as "no forks" would
# open the runner on an unproven group (base#1587).
@test "merge_group_trust.sh: a null merge queue leaves the group untrusted and names why (base#1587)" {
  # `repository.mergeQueue(branch:"main")` returned null in a live
  # GraphQL query while the queue was off. Nothing is proven, so the
  # answer is false, and an `::error::` line says why: classify stays
  # green (exit 0), so this line is the only place the reason shows.
  export MOCK_REPLY='{"data":{"repository":{"mergeQueue":null}}}'
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
  [[ "${stderr}" == *"::error::merge_group_trust:"* ]]
}

# why: The queue exists, so the null-queue case does not cover it; a
# resolver that read "no cross-repository entry found" as trust would
# answer true here with nothing proven (base#1587).
@test "merge_group_trust.sh: an empty merge queue leaves the group untrusted and names why (base#1587)" {
  # The queue exists but lists no entries, so no entry holds HEAD_SHA and
  # nothing about the group is proven. The answer is false, and an
  # `::error::` line says why, since classify stays green (exit 0).
  export MOCK_REPLY='{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}}}}}'
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
  [[ "${stderr}" == *"::error::merge_group_trust:"* ]]
}

# why: Other groups in the queue being same-repository says nothing about
# this run's commit; trusting them would let a run whose own group is not
# listed borrow their answer (base#1587).
@test "merge_group_trust.sh: a queue with no entry for HEAD_SHA leaves the group untrusted and names why (base#1587)" {
  # The queue holds same-repository entries, but none has HEAD_SHA as its
  # head commit, so this run's group is not among them and nothing about
  # it is proven. The answer is false, and an `::error::` line says why,
  # since classify stays green (exit 0).
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
  [[ "${stderr}" == *"::error::merge_group_trust:"* ]]
}

# why: The commit and the group ref must name the same entry, or the
# group whose code is running is not proven to be the one that was
# checked (base#1587).
@test "merge_group_trust.sh: an entry whose pull request is not HEAD_REF's pr-<N> leaves the group untrusted and names why (base#1587)" {
  # The entry with HEAD_SHA as its head commit belongs to PR 103, but the
  # group head ref names pr-999. The two disagree, so this run's group is
  # not proven to be that entry. The answer is false, and an `::error::`
  # line says why, since classify stays green (exit 0).
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 false ycpss91255-docker/base)" \
    "$(_entry 3 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-999-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
  [[ "${stderr}" == *"::error::merge_group_trust:"* ]]
}

# why: A deleted head repository leaves isCrossRepository false as the
# only signal; a resolver that read that field alone would answer true for
# code whose author is no longer provable (base#1587).
@test "merge_group_trust.sh: an entry whose head repository is null leaves the group untrusted and names why (base#1587)" {
  # PullRequest.headRepository is null when the head repository was
  # deleted, so who wrote the code is not proven even though
  # isCrossRepository says false. Entry 2, ahead of the HEAD_SHA entry,
  # has it null. The answer is false, and an `::error::` line says why,
  # since classify stays green (exit 0).
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    '{"position":2,"headCommit":{"oid":"2222222222222222222222222222222222222222"},"pullRequest":{"number":102,"isCrossRepository":false,"headRepository":null}}' \
    "$(_entry 3 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
  [[ "${stderr}" == *"::error::merge_group_trust:"* ]]
}

# why: The load-bearing case: a group builds the code of every pull
# request ahead of its head, so a fork there runs on the self-hosted
# runner unless the resolver checks the whole group, not only the head
# entry or HEAD_REF's pull request (base#1587).
@test "merge_group_trust.sh: a cross-repository pull request ahead of the HEAD_SHA entry leaves the group untrusted (base#1587)" {
  # Entry 2 is in the group (ahead of entry 3) and comes from a fork, so
  # the group holds fork-authored code. The answer is false.
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 true someone/base)" \
    "$(_entry 3 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
}

# why: The group head is the pull request the run is named after; a
# resolver that checked only the entries ahead of it would let a fork at
# the head through (base#1587).
@test "merge_group_trust.sh: a cross-repository pull request as the HEAD_SHA entry leaves the group untrusted (base#1587)" {
  # The group head itself, entry 3, comes from a fork. The answer is false.
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 false ycpss91255-docker/base)" \
    "$(_entry 3 3333333333333333333333333333333333333333 103 true someone/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
}

# why: Pins the position filter from the other side: checking the whole
# queue would make one parked fork block every same-repository group ahead
# of it, and the queue would stall (base#1587).
@test "merge_group_trust.sh: a cross-repository pull request behind the HEAD_SHA entry does not block the group (base#1587)" {
  # Entry 4 comes from a fork but sits behind entry 3, so it is not in
  # this run's group (a group holds the entry and those ahead of it). A
  # fork parked in the queue must not block same-repository groups ahead
  # of it. The answer is true.
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 false ycpss91255-docker/base)" \
    "$(_entry 3 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)" \
    "$(_entry 4 4444444444444444444444444444444444444444 104 true someone/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=true"
}

# why: isCrossRepository alone is one field; the resolver also requires
# nameWithOwner to be REPO, and this is the only case where the two
# disagree, so dropping the second check is caught here (base#1587).
@test "merge_group_trust.sh: a head repository named for another repository leaves the group untrusted (base#1587)" {
  # Entry 2 says isCrossRepository false but its head repository is not
  # REPO, so the two fields disagree and same-repository is not proven.
  # The answer is false.
  MOCK_REPLY="$(_queue \
    "$(_entry 1 1111111111111111111111111111111111111111 101 false ycpss91255-docker/base)" \
    "$(_entry 2 2222222222222222222222222222222222222222 102 false someone/base)" \
    "$(_entry 3 3333333333333333333333333333333333333333 103 false ycpss91255-docker/base)")"
  export MOCK_REPLY
  export HEAD_SHA="3333333333333333333333333333333333333333"
  export HEAD_REF="refs/heads/gh-readonly-queue/main/pr-103-a61b898dd898e4c4bf5c5cf00b3ef76076d0a1d3"

  run --separate-stderr bash "${TRUST}"
  assert_success
  assert_output "same_repo=false"
}
