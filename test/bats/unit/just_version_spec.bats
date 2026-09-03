#!/usr/bin/env bats
#
# Unit tests for the ONE pinned version of the `just` runner.
#
# `just` is this project's only control surface -- every container
# operation is a recipe -- and it used to reach a developer through four
# independent provenance paths that shared no version at all:
#
#   the test-tools image        a bare `apk add ... just` (alpine's package)
#   CI's integration-e2e job    `extractions/setup-just` with no version input
#   init.sh --bootstrap-just    just.systems/install.sh with no --tag
#   the init.sh install hint    apt / brew / cargo, presented as equivalents
#
# Measured 2026-08-28 that spread was 37 minors wide, so a recipe could
# work on one path and fail on another -- indistinguishable, from the
# outside, from a broken recipe.
#
# The fix is ONE declaration that the other paths READ, not four values
# kept in agreement: `ARG JUST_VERSION` in dockerfile/Dockerfile.test-tools,
# exposed by dist/script/base/just-version.sh. This spec pins the
# declaration, the accessor and each reader's static shape; the
# behavioural half (the image really ships that version) is
# test/bats/integration/just_runner_version_spec.bats, and the guard that
# a NEW provenance path cannot land unpinned is
# script/test/drivers/just_provenance.sh.
#
# Why the declaration lives in the Dockerfile rather than in a data file
# of its own: script/test/test.sh derives the local test-tools tag from
# the sha256 of that Dockerfile ALONE, so a version declared anywhere
# else would be invisible to the tag and a bump would silently reuse the
# previous image.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  ACCESSOR=/source/dist/script/base/just-version.sh
  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _declared_pin -- read the declaration with an expression that is NOT the
# accessor's, so "the accessor agrees with the file" is a real comparison
# rather than the accessor agreeing with itself.
_declared_pin() {
  grep -E '^ARG[[:space:]]+JUST_VERSION=' "${DOCKERFILE}" \
    | cut -d= -f2 | tr -d '[:space:]'
}

# _seed_tree <version> -- a minimal base tree at ${SCRATCH}/<name>: the
# accessor at its shipped path plus a declaration to read.
_seed_tree() {
  local _root="${SCRATCH}/tree" _ver="${1}"
  mkdir -p "${_root}/dist/script/base" "${_root}/dockerfile"
  cp "${ACCESSOR}" "${_root}/dist/script/base/just-version.sh"
  printf 'ARG JUST_VERSION=%s\n' "${_ver}" \
    > "${_root}/dockerfile/Dockerfile.test-tools"
  printf '%s\n' "${_root}"
}

# ════════════════════════════════════════════════════════════════════
# The declaration
# ════════════════════════════════════════════════════════════════════

@test "just version: declared exactly once, as a semver ARG in the tooling Dockerfile (#948)" {
  run grep -cE '^ARG[[:space:]]+JUST_VERSION=' "${DOCKERFILE}"
  assert_success
  assert_output "1"
  [[ "$(_declared_pin)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "declared pin '$(_declared_pin)' is not a bare semver"
}

@test "just version: the tooling image fetches the pinned release, never a bare apk add (#948)" {
  # The alpine package is whatever the alpine series carries (1.37.0 on
  # 3.21, 1.48.1 on 3.24) -- bumping alpine does not fix it. The pinned
  # upstream release is the same shape shellcheck / hadolint already use.
  run grep -F 'casey/just/releases/download/${JUST_VERSION}' "${DOCKERFILE}"
  assert_success
  run grep -E '^COPY --from=just-runner ' "${DOCKERFILE}"
  assert_success
  # No apk line anywhere in the file may install `just` as a package.
  run grep -nE 'apk add .*\bjust\b' "${DOCKERFILE}"
  assert_failure
  [ "${status}" -eq 1 ] || fail "grep errored (${status}), it did not merely fail to match"
}

# ════════════════════════════════════════════════════════════════════
# The accessor
# ════════════════════════════════════════════════════════════════════

@test "just-version.sh: prints the declared pin (#948)" {
  run "${ACCESSOR}"
  assert_success
  assert_output "$(_declared_pin)"
}

@test "just-version.sh: reads its own tree, not the caller's cwd (#948)" {
  local _root
  _root="$(_seed_tree 9.9.9)"
  cd /tmp
  run "${_root}/dist/script/base/just-version.sh"
  assert_success
  assert_output "9.9.9"
}

# Each of the three failure cases names the message it expects, not merely
# a non-zero status. `run <path>` on a script that is absent or unreadable
# also exits non-zero (127), so a status-only assertion is satisfied by
# "the accessor is gone" -- the one state these tests cannot be allowed to
# read as a pass, since they exist to prove the accessor rejects a bad
# declaration.

@test "just-version.sh: fails loud when the declaration file is gone (#948)" {
  local _root
  _root="$(_seed_tree 9.9.9)"
  rm -f "${_root}/dockerfile/Dockerfile.test-tools"
  run "${_root}/dist/script/base/just-version.sh"
  assert_failure
  assert_output --partial "declaration not found"
  assert_output --partial "Dockerfile.test-tools"
}

@test "just-version.sh: fails loud when the declaration is duplicated (#948)" {
  local _root
  _root="$(_seed_tree 9.9.9)"
  printf 'ARG JUST_VERSION=8.8.8\n' \
    >> "${_root}/dockerfile/Dockerfile.test-tools"
  run "${_root}/dist/script/base/just-version.sh"
  assert_failure
  assert_output --partial "declarations in"
  assert_output --partial "there must be exactly one"
}

@test "just-version.sh: fails loud when the declaration is empty (#948)" {
  local _root
  _root="$(_seed_tree 9.9.9)"
  printf 'ARG JUST_VERSION=\n' \
    > "${_root}/dockerfile/Dockerfile.test-tools"
  run "${_root}/dist/script/base/just-version.sh"
  assert_failure
  assert_output --partial "is not a bare semver"
}

# ════════════════════════════════════════════════════════════════════
# The readers
# ════════════════════════════════════════════════════════════════════

# The two reader assertions below are scoped to the JOB that installs the
# runner, via yaml_job_lines, rather than grepping the whole workflow.
# Whole-file evidence is not evidence about a step: self-test.yaml names
# the accessor on six code lines (the acceptance job's resolve step plus
# the five :main probes added for the version check), so a file-wide grep
# for it stays green while the acceptance step goes back to restating the
# literal -- the exact defect this spec exists to prevent, and the state it
# was in until now.
#
# Job scope also subsumes the comment hazard the previous form was
# converted for: yaml_job_lines strips comment-only lines, so
# release-test-tools.yaml's prose "read via dist/script/base/just-version.sh"
# (the file's ONLY other mention of the accessor) cannot vouch for the
# smoke check that sits under it.

@test "self-test.yaml: setup-just is pinned from the accessor, not left to install latest (#948)" {
  local _wf=/source/.github/workflows/self-test.yaml
  local _body _pin_id
  _body="$(yaml_job_lines "${_wf}" acceptance)"
  [ -n "${_body}" ] \
    || fail "derived an empty 'acceptance' job from ${_wf} -- the job reader is broken, so this test checked nothing"
  # The resolve step runs the accessor into a step output ...
  [[ "${_body}" == *'dist/script/base/just-version.sh'* ]] \
    || fail "the acceptance job installs just but never reads the declaration through dist/script/base/just-version.sh"
  # ... and setup-just consumes THAT step's output. yaml_step_id_for names
  # the step the job's first accessor call sits in -- derived from the
  # workflow, so renaming the step moves this assertion with it -- and the
  # input is then required to read that id. The assertion therefore says
  # "the input comes from the step that read the declaration", not the
  # weaker "some step output reaches the input".
  #
  # When the shape is not the one it recognises -- the accessor call is in
  # a step with no id, or the job stopped calling the accessor at all --
  # the helper answers with an empty id and the guard below fails. An
  # unattributable match never becomes a step name here.
  _pin_id="$(yaml_step_id_for "${_wf}" acceptance \
    'dist/script/base/just-version[.]sh')"
  [ -n "${_pin_id}" ] \
    || fail "the accessor call sits in a step with no 'id:', so no other step can consume what it resolved"
  [[ "${_body}" == *"just-version: \${{ steps.${_pin_id}.outputs."* ]] \
    || fail "setup-just's just-version input does not read step '${_pin_id}' -- what it installs is not the declared pin"
}

@test "release-test-tools.yaml: the just smoke check asserts the version, not exit 0 (#948)" {
  local _wf=/source/.github/workflows/release-test-tools.yaml
  local _body
  _body="$(yaml_job_lines "${_wf}" merge)"
  [ -n "${_body}" ] \
    || fail "derived an empty 'merge' job from ${_wf} -- the job reader is broken, so this test checked nothing"
  [[ "${_body}" == *'dist/script/base/just-version.sh'* ]] \
    || fail "the merge job smoke-checks the published image but never reads the declared pin"
  # Reading both versions is not comparing them: the compare is what
  # turns "the binary is there" into "the binary is the pinned one".
  [[ "${_body}" == *'!= "just ${just_pin}"'* ]] \
    || fail "the merge job reads the pin and the image's version but never compares them"
  # A bare `docker run ... just --version` with nothing comparing its
  # output is the check that caught removal and never staleness.
  run grep -nE 'docker run --rm "\$\{image\}" just --version$' "${_wf}"
  assert_failure
  [ "${status}" -eq 1 ] || fail "grep errored (${status}), it did not merely fail to match"
}
