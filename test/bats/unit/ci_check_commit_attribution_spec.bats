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
