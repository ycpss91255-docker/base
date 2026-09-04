#!/usr/bin/env bats
#
# classify_testtools_spec.bats -- does the classifier know when the
# tooling image is stale?
#
# why: `testtools_changed` tells every image-consuming job whether to
# rebuild the tooling image from source instead of pulling the rolling
# `:main`. On a pull request it is computed from the diff; on every other
# event it was the literal `false`, including the one event that can
# answer it -- a push to main whose commit is what makes `:main` stale in
# the first place. So the merge that added a tool to the Dockerfile ran
# the whole post-merge suite inside the image from before it. The probe
# was supposed to compensate and was itself too narrow to notice; both
# halves are the same incident, and this is the half that can be
# answered from the diff.
#
# The cases drive the REAL classify step against a synthetic push, so
# each reads the output the step writes.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SELF_WF=/source/.github/workflows/self-test.yaml
  assert_spec_subject "${SELF_WF}" \
      "the workflow whose classifier this spec drives"
}

# _classify_event <event> <repo-relative-path> [--root]
#   Runs self-test's OWN classify step against a synthetic history whose
#   head commit changes <path> and nothing else, reported to the step as
#   <event>. With `--root` the history is ONE commit, so `HEAD^` does not
#   resolve and the diff cannot be taken at all. Prints the GITHUB_OUTPUT
#   the step wrote.
_classify_event() {
  local _e="${1:?BUG: _classify_event expects an event}"
  local _p="${2:?BUG: _classify_event expects a path}"
  local _root="${3:-}"
  local _d="${BATS_TEST_TMPDIR}/push"
  rm -rf "${_d}"
  mkdir -p "${_d}/$(dirname "${_p}")"
  ln -s /source/script "${_d}/script"
  printf 'a\n' > "${_d}/${_p}"
  git -C "${_d}" init -q -b main
  git -C "${_d}" config user.email ci@example.invalid
  git -C "${_d}" config user.name ci
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m base
  if [[ "${_root}" != "--root" ]]; then
    printf 'b\n' >> "${_d}/${_p}"
    git -C "${_d}" commit -q -a -m change
  fi
  yaml_step_run "${SELF_WF}" classify diff > "${_d}/step.sh"
  [ -s "${_d}/step.sh" ] || return 2
  : > "${_d}/out"
  (
    cd "${_d}" || return 2
    env EVENT_NAME="${_e}" BASE_REF= GITHUB_OUTPUT="${_d}/out" bash step.sh
  ) >/dev/null 2>&1
  cat "${_d}/out"
}

# _classify_push <repo-relative-path>
#   The push case of the above, which is the only event that can answer
#   `testtools_changed` from a diff.
_classify_push() {
  _classify_event push "${1:?BUG: _classify_push expects a path}"
}

# why: The reported case. A push to main that changes the test-tools
# Dockerfile is exactly the push for which the rolling tag is stale --
# the republish that would refresh it is racing this very run -- and it
# was the push that reported the image unchanged.
@test "classify: a push that changes the test-tools Dockerfile rebuilds it (#1010)" {
  run _classify_push dockerfile/Dockerfile.test-tools
  assert_success
  assert_line 'testtools_changed=true'
}

# why: The guard against answering true to every push, which would put a
# full multi-arch tooling build in front of every merge. A push that
# leaves the Dockerfile alone takes the pull path, where the probe is now
# the thing that catches a stale image.
@test "classify: a push that leaves it alone still pulls (#1010)" {
  run _classify_push doc/guide.md
  assert_success
  assert_line 'testtools_changed=false'
}

# why: A non-PR event still runs the full suite. The flag being
# computable now must not narrow what a push runs.
@test "classify: a push is still code-changed and system-relevant (#1010)" {
  run _classify_push doc/guide.md
  assert_success
  assert_line 'code_changed=true'
  assert_line 'system_relevant=true'
}

# why: The fail-safe direction the step's own comment promises and did not
# take. `workflow_dispatch` has no previous commit to diff against, so the
# classifier cannot know whether the rolling tag corresponds to this ref --
# and it answered `false`, which is the side that USES an image it could
# not check. The path here is deliberately not the Dockerfile, so a `true`
# can only come from the default and never from a diff.
@test "classify: an event that cannot be diffed still rebuilds (#1010)" {
  run _classify_event workflow_dispatch doc/guide.md
  assert_success
  assert_line 'testtools_changed=true'
}

# why: The other half of the same promise, and the half that already held:
# a push whose `HEAD^` does not resolve is a diff that cannot be taken, not
# an answer of "unchanged". Pinned because the fix above rewrites the
# branch that decides it, and a rewrite that inverted this one would look
# green against the dispatch case alone.
@test "classify: a push with no parent to diff still rebuilds (#1010)" {
  run _classify_event push doc/guide.md --root
  assert_success
  assert_line 'testtools_changed=true'
}
