#!/usr/bin/env bats
#
# release_version_spec.bats -- unit tests for script/ci/release-version.sh,
# the release worker's version resolver.
#
# why: Unit tests for `script/ci/release-version.sh`, the resolver that
# decides WHICH version `release-worker.yaml` cuts and whether it is a
# prerelease (#829). The worker used to read both off `github.ref_name`,
# which only exists on a tag push; a downstream that wants to auto-release a
# merged dependency bump cannot push a tag with `GITHUB_TOKEN` and have the
# tag event fire (GitHub's recursion guard), so it calls the worker directly
# and the ref is a BRANCH. The resolver takes the caller's `version` input
# when there is one, falls back to the ref otherwise, and derives the
# prerelease flag from the version it resolved rather than from the ref --
# the same defect shape as #1012, where a decision about a version was read
# off a ref that did not carry one.
#
# Every unresolvable case REFUSES: an input the resolver cannot read becomes
# the name of a git tag and a published GitHub Release, so "cannot determine"
# must not fall through to the ref, to a default, or to any name that is
# already consumed (#1012's `else` arm resolved to `:latest`). A refusal
# prints nothing on stdout, so a caller appending stdout to `GITHUB_OUTPUT`
# ends up with no `version` key at all and every downstream `if:` on it is
# false.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/release-version.sh"
  assert_spec_subject "${SCRIPT}" \
      "the release-worker version resolver under test"
}

# _resolve <version-input> <ref-name> -- run the resolver with the two
# environment values release-worker.yaml binds, and nothing else.
_resolve() {
  RELEASE_VERSION_INPUT="${1}" GITHUB_REF_NAME="${2}" run bash "${SCRIPT}"
}

# ── the tag path, unchanged ──────────────────────────────────────────────────

# why: The pre-existing path: a tag push, no `version` input. The resolved
# version is the tag and the release is not a prerelease, so adding the input
# does not move what a tag-triggered release cuts today.
@test "release-version: no input resolves the pushed tag, not a prerelease" {
  _resolve "" "v1.2.3"
  assert_success
  assert_output 'version=v1.2.3
prerelease=false'
}

# why: A hyphen in the resolved version is what marks a prerelease, which is
# the test `release-worker.yaml` already applied to `github.ref_name`. On the
# tag path the answer must not change.
@test "release-version: no input marks an rc tag as a prerelease" {
  _resolve "" "v0.42.0-rc4"
  assert_success
  assert_output 'version=v0.42.0-rc4
prerelease=true'
}

# ── the direct-call path ─────────────────────────────────────────────────────

# why: The point of the input: called from a merged bump on the default
# branch, `github.ref_name` is `main`, which is not a version at all. The
# caller's version wins and the ref is never consulted.
@test "release-version: the version input wins over a branch ref" {
  _resolve "v2.0.1" "main"
  assert_success
  assert_output 'version=v2.0.1
prerelease=false'
}

# why: The #1012 shape, in the direction that matters here: a prerelease cut
# from a branch. If the flag were still read off the ref, `main` carries no
# hyphen and an RC would publish as a full release. It is derived from the
# resolved version instead.
@test "release-version: a prerelease input is a prerelease even from a branch ref" {
  _resolve "v2.0.0-rc1" "main"
  assert_success
  assert_output 'version=v2.0.0-rc1
prerelease=true'
}

# why: `version` is declared with an empty default, so "not supplied" reaches
# the resolver as an empty (or whitespace-only) string and must mean the tag
# path rather than a refusal.
@test "release-version: a whitespace-only input means not supplied" {
  _resolve "   " "v1.0.0"
  assert_success
  assert_output 'version=v1.0.0
prerelease=false'
}

# ── refusal: an unreadable version never becomes a tag ───────────────────────

# why: #1012's `else` arm resolved an unrecognised input to `:latest`, the
# most-consumed name in the registry. The inverse is the rule here: a version
# the resolver cannot read is refused by name, never resolved to anything.
@test "release-version: refuses an input that is not a version, naming it" {
  _resolve "latest" "main"
  assert_failure
  [[ "${output}" == *"latest"* ]]
}

# why: The resolved value becomes a git tag and downstream repos pin `vX.Y.Z`
# (ADR-00000002). A bare `1.2.3` is refused rather than silently prefixed:
# normalising would publish a tag the caller did not ask for.
@test "release-version: refuses a version missing the v prefix" {
  _resolve "1.2.3" "main"
  assert_failure
}

# why: A two-component version cannot be classified -- there is no patch
# component to say whether this is the Z the caller means -- so it is refused
# rather than completed with a zero.
@test "release-version: refuses a two-component version" {
  _resolve "v1.2" "main"
  assert_failure
}

# why: The resolved value is interpolated into a tag name and a release title.
# The shape check is what keeps caller-controlled text from carrying shell or
# ref metacharacters through, so a version with a command in it is refused.
@test "release-version: refuses a version carrying shell metacharacters" {
  _resolve 'v1.2.3; rm -rf /' "main"
  assert_failure
}

# why: The fallback is subject to the same rule as the input. A tag that is
# not a version reaches this worker whenever a repo pushes one (the caller's
# `call-release` fires on any tag), and releasing under a name nothing can
# pin is the failure being refused.
@test "release-version: refuses a ref that is not a version" {
  _resolve "" "some-branch"
  assert_failure
  [[ "${output}" == *"some-branch"* ]]
}

# why: Neither source supplied is the caller-contract error, and it must be
# named as such rather than producing an empty version.
@test "release-version: refuses when neither input nor ref is supplied" {
  _resolve "" ""
  assert_failure
}

# why: The fail-closed property the whole design rests on. The workflow
# appends this script's stdout to GITHUB_OUTPUT; a refusal that printed a
# partial `version=` line would leave a value for a later step to release
# under. A refusal writes to stderr only, so there is no output key and every
# `if:` reading it is false.
@test "release-version: a refusal prints nothing on stdout" {
  RELEASE_VERSION_INPUT="latest" GITHUB_REF_NAME="main" \
    run --separate-stderr bash "${SCRIPT}"
  assert_failure
  assert_output ""
  [[ -n "${stderr}" ]]
}
