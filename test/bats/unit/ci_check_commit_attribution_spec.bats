#!/usr/bin/env bats
#
# Unit tests for script/ci/check_commit_attribution.sh -- the CI check that
# fails a pull request or merge_group run when a commit in its range carries
# AI attribution, base#1989.
#
# Each spec builds a throwaway repository in BATS_TEST_TMPDIR, makes a base
# commit and the commits under test, and runs the script from inside it with
# EVENT_NAME, BASE_SHA and HEAD_SHA set the way the workflow sets them. The
# result is read from the exit code and the `::error::commit <sha>` lines.
#
# The marker strings are built from parts at runtime (_cab, _model, _addr) so
# the repository's own attribution guards do not fire on this file.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  CHECK="/source/script/ci/check_commit_attribution.sh"

  REPO="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${REPO}"
  git -C "${REPO}" config user.email t@example.com
  git -C "${REPO}" config user.name t
  git -C "${REPO}" commit -q --allow-empty -m "base"
  BASE="$(git -C "${REPO}" rev-parse HEAD)"
}

# Marker parts, joined at runtime.
_cab() { printf '%s-%s-%s' "Co" "Authored" "By"; }
_model() { printf '%s%s' "Cla" "ude"; }
_addr() { printf '%s@%s.%s' "noreply" "anthropic" "com"; }

# _commit <message>: an empty commit in REPO with that message.
_commit() {
  git -C "${REPO}" commit -q --allow-empty -m "$1"
}

# _run_pr: run the check over BASE..HEAD as a pull_request event.
_run_pr() {
  cd "${REPO}" || return 1
  export EVENT_NAME=pull_request
  export BASE_SHA="${BASE}"
  HEAD_SHA="$(git rev-parse HEAD)"
  export HEAD_SHA
  run bash "${CHECK}"
}

# why: The trailer the agent tooling adds by default is the case the check
# exists for. A check that always passed would pass every clean-commit spec,
# so this one pins exit 1 and the offending sha in the output (base#1989).
@test "check_commit_attribution.sh: a co-author trailer naming the model fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s: %s X <%s>' "$(_cab)" "$(_model)" "$(_addr)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}"
}

# why: The address is attribution under any trailer key, not only the
# co-author one. A check that ran the marker list alone would pass a
# `Reviewed-by:` trailer carrying it, so this pins exit 1 and the sha for a
# trailer the marker list does not name (base#1989).
@test "check_commit_attribution.sh: a non-co-author trailer with the noreply address fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\nReviewed-by: Bot <%s>' "$(_addr)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}"
}

# why: Git accepts a space before a trailer's colon and prints the trailer in
# canonical `key: value` form. A check that ran the marker list over the raw
# body alone would pass `<key> : <model> <other address>`, which names the
# model and carries no noreply address, so this pins exit 1 and the sha
# (base#1989).
@test "check_commit_attribution.sh: a co-author trailer with a space before the colon naming the model fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s : %s <x@example.com>' "$(_cab)" "$(_model)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}"
}

# why: The address as the author identity is attribution even when the
# message is clean. A check that read the message alone would pass a commit
# authored as the noreply address, so this pins exit 1 and the sha for a
# clean message with that author email (base#1989).
@test "check_commit_attribution.sh: an author email equal to the noreply address fails and names the sha (base#1989)" {
  GIT_AUTHOR_EMAIL="$(_addr)" git -C "${REPO}" commit -q --allow-empty -m "feat: x"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}"
}

# why: The address as the committer identity is attribution too, and a
# commit can carry it there with a clean message and a human author. A check
# that read the author email for both identities would pass such a commit,
# so this pins exit 1 and the sha when only the committer email is the
# noreply address (base#1989).
@test "check_commit_attribution.sh: a committer email equal to the noreply address fails and names the sha (base#1989)" {
  GIT_COMMITTER_EMAIL="$(_addr)" git -C "${REPO}" commit -q --allow-empty -m "feat: x"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}"
}

# why: The workflow also runs on push and on release tags, where there is no
# pull request range to walk. A check that demanded BASE_SHA and HEAD_SHA on
# every event would fail those runs, so this pins exit 0 and the no-range
# notice for a push event with neither sha set (base#1989).
@test "check_commit_attribution.sh: a push event has no range to check and passes with a notice (base#1989)" {
  cd "${REPO}" || return 1
  unset BASE_SHA HEAD_SHA
  export EVENT_NAME=push

  run bash "${CHECK}"
  assert_equal "${status}" 0
  assert_output --partial "no range"
}
