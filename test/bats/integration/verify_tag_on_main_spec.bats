#!/usr/bin/env bats
#
# verify_tag_on_main_spec.bats -- tests for script/ci/verify-tag-on-main.sh,
# the release worker's on-main guard.
#
# why: Tests for `script/ci/verify-tag-on-main.sh`, the guard the release
# worker runs before cutting a Release. The org's tag rulesets (base#1124)
# admit any commit that passed CI, including one that went green inside a PR
# that was never merged, because a tag ruleset can only ask whether the
# target commit passed its checks -- not whether it is on main. This guard
# asserts the one thing the ruleset cannot: the commit under release is an
# ancestor of the remote's main (base#1143). It is deliberately ONE rule for
# both of the worker's entry paths -- a pushed tag and the direct
# auto-release call whose commit is main's own tip -- so these drive a real
# git graph: a historical main commit and the tip pass, a commit on an
# unmerged branch is refused, and every unreadable case (no GITHUB_SHA, an
# unfetched main ref) fails CLOSED with a message rather than passing, since
# failing to know where main is is not evidence the commit is on it. The
# refusal writes to stderr only, so a caller cannot mistake it for a pass.
#
# Level: integration -- the subject's whole job is a `git merge-base
# --is-ancestor` query, so the fixtures are real repositories rather than
# stubs.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  SCRIPT="/source/script/ci/verify-tag-on-main.sh"
  assert_spec_subject "${SCRIPT}" \
      "the release-worker on-main guard under test"

  # A repo with main = A -> C, and an unmerged feature commit B off A.
  REPO="$(mktemp -d)"
  git init -q -b main "${REPO}"
  git -C "${REPO}" config user.email test@example.com
  git -C "${REPO}" config user.name test
  git -C "${REPO}" commit -q --allow-empty -m A
  ON_MAIN="$(git -C "${REPO}" rev-parse HEAD)"
  git -C "${REPO}" checkout -q -b feature
  git -C "${REPO}" commit -q --allow-empty -m B
  OFF_MAIN="$(git -C "${REPO}" rev-parse HEAD)"
  git -C "${REPO}" checkout -q main
  git -C "${REPO}" commit -q --allow-empty -m C
  MAIN_TIP="$(git -C "${REPO}" rev-parse HEAD)"
}

teardown() {
  [[ -n "${REPO:-}" ]] && rm -rf "${REPO}"
}

# _verify <sha> -- run the guard in the fixture, testing ancestry against the
# fixture's local `main` (no remote, which is exactly what makes the git
# query host-testable).
_verify() {
  cd "${REPO}"
  GITHUB_SHA="${1}" VTM_MAIN_REF="main" run bash "${SCRIPT}"
}

# ── on main: admitted ────────────────────────────────────────────────────────

# why: A historical main commit (not the tip) is on main and must pass -- the
# guard tests reachability, not equality with the tip, so releasing an older
# main commit is admitted.
@test "verify-tag-on-main: a commit on main is admitted" {
  _verify "${ON_MAIN}"
  assert_success
  assert_output ""
}

# why: The direct auto-release path (release-version.sh's `version` input)
# runs on a push to main, so GITHUB_SHA is main's tip. The single rule admits
# it with no special case -- this pins that the tip passes.
@test "verify-tag-on-main: main's own tip is admitted (the auto-release path)" {
  _verify "${MAIN_TIP}"
  assert_success
  assert_output ""
}

# ── off main: refused ────────────────────────────────────────────────────────

# why: The whole point. A commit on a branch that was never merged is exactly
# what the tag ruleset admits (it passed CI) and what this refuses, naming the
# commit so the failure says which tag to delete.
@test "verify-tag-on-main: a commit that is not on main is refused, naming it" {
  _verify "${OFF_MAIN}"
  assert_failure
  [[ "${output}" == *"${OFF_MAIN}"* ]]
  [[ "${output}" == *"not an ancestor"* ]]
}

# ── unreadable cases fail closed ─────────────────────────────────────────────

# why: No commit to check is a caller-contract error, not a pass. The release
# job always has GITHUB_SHA; its absence means this was wired wrong, and
# guessing "on main" would defeat the guard.
@test "verify-tag-on-main: an unset GITHUB_SHA is refused" {
  cd "${REPO}"
  GITHUB_SHA="" VTM_MAIN_REF="main" run bash "${SCRIPT}"
  assert_failure
  [[ "${output}" == *"GITHUB_SHA"* ]]
}

# why: The fail-closed property. If main was never fetched the ref does not
# resolve, and "not an ancestor of nothing" must NOT read as off-main -- it is
# refused by name so a missing fetch step fails loudly rather than quietly
# blocking every release or, worse, passing one it never checked.
@test "verify-tag-on-main: an unresolvable main ref is refused, not treated as off-main" {
  cd "${REPO}"
  GITHUB_SHA="${MAIN_TIP}" VTM_MAIN_REF="origin/main" run bash "${SCRIPT}"
  assert_failure
  [[ "${output}" == *"origin/main"* ]]
}

# why: The release step must never mistake a refusal for a pass. A refusal
# writes to stderr and prints nothing on stdout, so no wiring that keys off
# this step's stdout can misread it.
@test "verify-tag-on-main: a refusal prints nothing on stdout" {
  cd "${REPO}"
  GITHUB_SHA="${OFF_MAIN}" VTM_MAIN_REF="main" \
    run --separate-stderr bash "${SCRIPT}"
  assert_failure
  assert_output ""
  [[ -n "${stderr}" ]]
}
