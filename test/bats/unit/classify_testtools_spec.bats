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

# _classify_pr <repo-relative-path>
#   The pull-request arm of the same step, which is the arm every PR's
#   image jobs read. The base ref is planted as `refs/remotes/origin/main`
#   because that is the name the step resolves; its own `git fetch` has no
#   remote to reach and is already tolerated by the step's `|| true`.
_classify_pr() {
  local _p="${1:?BUG: _classify_pr expects a path}"
  local _d="${BATS_TEST_TMPDIR}/pr"
  rm -rf "${_d}"
  mkdir -p "${_d}/$(dirname "${_p}")" "${_d}/doc"
  ln -s /source/script "${_d}/script"
  printf 'seed\n' > "${_d}/doc/seed.md"
  printf 'a\n' > "${_d}/${_p}"
  git -C "${_d}" init -q -b main
  git -C "${_d}" config user.email ci@example.invalid
  git -C "${_d}" config user.name ci
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m base
  git -C "${_d}" update-ref refs/remotes/origin/main HEAD
  printf 'b\n' >> "${_d}/${_p}"
  git -C "${_d}" commit -q -a -m change
  yaml_step_run "${SELF_WF}" classify diff > "${_d}/step.sh"
  [ -s "${_d}/step.sh" ] || return 2
  : > "${_d}/out"
  (
    cd "${_d}" || return 2
    env EVENT_NAME=pull_request BASE_REF=main GITHUB_OUTPUT="${_d}/out" \
        bash step.sh
  ) >/dev/null 2>&1
  cat "${_d}/out"
}

# _context_copy_paths
#   Every build-context path the tooling Dockerfile COPYs, read off the
#   DOCKERFILE through the shared reader rather than through the signal
#   under test: a population computed by the subject would certify the
#   subject against itself.
#
#   Filtered to paths that exist in this checkout, because each one is
#   driven by committing a change to it. The shapes the reader cannot
#   resolve -- a glob, a variable, a line continuation -- are the
#   derivation's own business and are asserted where it lives, in
#   testtools_paths_spec.bats.
_context_copy_paths() {
  local _p
  dockerfile_context_copy_srcs /source/dockerfile/Dockerfile.test-tools \
    | while IFS= read -r _p; do
        [[ -n "${_p}" && -e "/source/${_p}" ]] && printf '%s\n' "${_p}"
      done
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

# ── the inputs that are not the Dockerfile ────────────────────────────

# why: The defect this spec was extended for. The signal named one path,
# and the tooling image has more inputs than that: a plain build-context
# COPY bakes a file of the checkout into the image, so editing that file
# alone leaves a `:main` that no longer describes the tree while the
# classifier reports the image unchanged. The population is read off the
# Dockerfile, so the next COPY anyone adds brings its own case with it
# instead of waiting for someone to remember this list.
@test "classify: a push that changes a file the Dockerfile COPYs rebuilds it (#1171)" {
  local _p _missed=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    run _classify_push "${_p}"
    assert_success
    grep -qx 'testtools_changed=true' <<< "${output}" \
      || _missed="${_missed}${_p}"$'\n'
  done < <(_context_copy_paths)
  [[ -z "${_missed}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context, and a push that changes one reports the image unchanged:"$'\n'"${_missed}"
}

# why: The same miss on the arm every pull request takes, which is the
# expensive one: the PR arm's `false` sends `obtain_test_tools.sh` down its
# layer-2 path, so the whole suite runs inside the rolling `:main` -- an
# image built before the edit, and one nothing on the PR path refreshes.
@test "classify: a PR that changes a file the Dockerfile COPYs rebuilds it (#1171)" {
  local _p _missed=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    run _classify_pr "${_p}"
    assert_success
    grep -qx 'testtools_changed=true' <<< "${output}" \
      || _missed="${_missed}${_p}"$'\n'
  done < <(_context_copy_paths)
  [[ -z "${_missed}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context, and a PR that changes one runs inside the stale rolling tag:"$'\n'"${_missed}"
}

# why: The guard that keeps the two cases above from being bought by
# answering `true` to everything. "Anything changed" would rebuild the
# tooling image on every pull request and throw away the pull path the
# rolling tag exists for.
@test "classify: a PR that changes nothing the image reads still pulls (#1171)" {
  run _classify_pr doc/guide.md
  assert_success
  assert_line 'testtools_changed=false'
}

# why: The Dockerfile's own case on the PR arm, pinned alongside the two
# above so a rewrite that reaches for the derivation cannot drop the one
# input the signal already had.
@test "classify: a PR that changes the test-tools Dockerfile rebuilds it (#1171)" {
  run _classify_pr dockerfile/Dockerfile.test-tools
  assert_success
  assert_line 'testtools_changed=true'
}
