#!/usr/bin/env bats
#
# abi_gate_spec.bats -- unit tests for script/ci/abi-gate.sh, the gate that
# decides whether a dependency bump may auto-release.
#
# why: Unit tests for `script/ci/abi-gate.sh`, the shared gate a downstream
# repo asks before auto-releasing a merged dependency bump (#829). The
# question it answers is narrow on purpose -- is this old -> new pin change
# ABI-safe by the rule this dependency itself follows -- and every other
# question (which version to cut, whether to fan out) belongs to the caller.
#
# The fail-open direction here is declaring a breaking change safe, so
# "cannot determine" resolves to NOT releasing, always: an unparseable
# version, a missing declaration, an axis this cannot read, a downgrade, a
# pair the upstream never sanctioned. There is deliberately no default for
# the ABI axis -- which component of a version is that dependency's ABI is a
# fact about the dependency (librealsense's SONAME carries its minor, plenty
# of libraries only their major), and base guessing it is exactly the
# fail-open this gate exists to prevent.
#
# A refusal exits non-zero and prints NOTHING on stdout, so a caller
# appending stdout to GITHUB_OUTPUT gets no `decision` key -- both the
# `steps.x.outputs.decision == 'release'` wiring and the bare exit status
# read a refusal as "do not release".

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/abi-gate.sh"
  assert_spec_subject "${SCRIPT}" \
      "the dependency-bump ABI gate under test"
}

# _gate <old> <new> <axis> [compat] -- run the gate over one bump, with the
# environment release-worker's callers bind and nothing else.
_gate() {
  DEP_NAME="librealsense" \
  OLD_VERSION="${1}" NEW_VERSION="${2}" ABI_AXIS="${3}" \
  UPSTREAM_COMPAT="${4:-}" \
    run bash "${SCRIPT}"
}

# ── what the gate lets through ───────────────────────────────────────────────

# why: The case the whole mechanism exists for: a patch bump of a dependency
# whose ABI is its major.minor. Nothing about the interface moved, so the
# repo may cut a Z without a human (ADR-00000027 sec.1).
@test "abi-gate: a patch bump under a major.minor ABI is released" {
  _gate "2.56.1" "2.56.2" "major.minor"
  assert_success
  [[ "${lines[0]}" == "decision=release" ]]
}

# why: The same bump judged by a dependency whose ABI is only its major. The
# axis is the caller's declaration, so a minor move is safe here and is not
# safe above -- one rule, two answers, which is why the axis has no default.
@test "abi-gate: a minor bump under a major-only ABI is released" {
  _gate "1.4.0" "1.7.2" "major"
  assert_success
  [[ "${lines[0]}" == "decision=release" ]]
}

# why: GITHUB_OUTPUT is line-oriented, so the reason has to be one line or
# the key after it is lost. Also pins the shape a caller reads: exactly a
# decision and a reason.
@test "abi-gate: an approval prints exactly a decision and a one-line reason" {
  _gate "2.56.1" "2.56.2" "major.minor"
  assert_success
  [[ "${#lines[@]}" -eq 2 ]]
  [[ "${lines[1]}" == reason=* ]]
}

# ── what the gate stops ──────────────────────────────────────────────────────

# why: The bump this gate is for: the minor moved on a dependency whose
# SONAME carries the minor, so the ABI changed and a downstream rebuild is
# not a formality. Refused by name, with the axis in the message.
@test "abi-gate: refuses a minor bump under a major.minor ABI" {
  _gate "2.56.1" "2.57.0" "major.minor"
  assert_failure
  [[ "${output}" == *"major.minor"* ]]
}

# why: The unambiguous break, under any convention.
@test "abi-gate: refuses a major bump" {
  _gate "1.4.0" "2.0.0" "major"
  assert_failure
}

# why: The gate cannot know which component is a given dependency's ABI, and
# a default would be a guess that silently releases a break. Absent means
# refuse, and the message has to say what to declare.
@test "abi-gate: refuses when no ABI axis is declared, naming what to declare" {
  DEP_NAME="librealsense" OLD_VERSION="2.56.1" NEW_VERSION="2.56.2" \
    run bash "${SCRIPT}"
  assert_failure
  [[ "${output}" == *"ABI_AXIS"* ]]
}

# why: An axis the gate does not recognise is the #1012 shape -- an
# unrecognised input must not resolve to the permissive branch. It refuses
# instead of falling back to either known axis.
@test "abi-gate: refuses an ABI axis it does not recognise" {
  _gate "2.56.1" "2.56.2" "patch"
  assert_failure
}

# why: A version the gate cannot parse cannot be compared, and an
# uncomparable pair is the definition of "cannot determine". Named in the
# message so the reader sees which side was unreadable.
@test "abi-gate: refuses an unparseable new version, naming it" {
  _gate "2.56.1" "latest" "major.minor"
  assert_failure
  [[ "${output}" == *"latest"* ]]
}

# why: The same rule on the other side. An old pin recorded as a commit sha
# says nothing about the interface it carried.
@test "abi-gate: refuses an unparseable old version" {
  _gate "e1b2c3d" "2.56.2" "major.minor"
  assert_failure
}

# why: A suffixed upstream version is a prerelease or a vendor build, not a
# released interface. It is refused rather than compared on its numbers.
@test "abi-gate: refuses a version carrying a suffix" {
  _gate "2.56.1" "2.56.2-rc1" "major.minor"
  assert_failure
}

# why: Nothing changed, so there is nothing to release. Silence here would
# cut a release whose changelog says a dependency moved when it did not.
@test "abi-gate: refuses when the version did not change" {
  _gate "2.56.1" "2.56.1" "major.minor"
  assert_failure
}

# why: A downgrade is never a routine bump -- it is a revert or a mistake,
# and either way it is a person's call. The component test alone would call
# 2.56.2 -> 2.56.1 a safe patch move.
@test "abi-gate: refuses a downgrade the axis test would call safe" {
  _gate "2.56.2" "2.56.1" "major.minor"
  assert_failure
}

# why: Under 0.x a major carries no compatibility promise, so `major` is not
# a meaningful axis for such a pin. Refused with the fix rather than
# silently re-read as major.minor: a declaration nobody corrected would keep
# meaning something other than what it says.
@test "abi-gate: refuses a 0.x pair declared with a major-only ABI" {
  _gate "0.4.1" "0.5.0" "major"
  assert_failure
  [[ "${output}" == *"major.minor"* ]]
}

# why: The same 0.x dependency declared correctly still auto-releases its
# patch bumps -- the rule above is about the declaration, not a blanket ban
# on 0.x.
@test "abi-gate: a 0.x patch bump under a major.minor ABI is released" {
  _gate "0.4.1" "0.4.2" "major.minor"
  assert_success
  [[ "${lines[0]}" == "decision=release" ]]
}

# ── the upstream's declared compatibility ────────────────────────────────────

# why: A wrapper declares the dependency version it was tested against, and
# a pair upstream never shipped together is not made safe by each half being
# ABI-clean on its own. When the caller supplies that declaration, the new
# pin has to agree with it on the ABI axis. The bump here is one the axis
# test alone would release -- 2.56.1 -> 2.56.4 leaves the major.minor
# untouched -- so only the declaration (2.55.0) can be refusing it. A pair
# the axis check already stops would hold with this rule deleted, and pin
# nothing.
@test "abi-gate: refuses a bump only the upstream compat declaration stops" {
  _gate "2.56.1" "2.56.4" "major.minor" "2.55.0"
  assert_failure
  [[ "${output}" == *"2.55.0"* ]]
}

# why: The sanctioned pair passes -- the declaration is a constraint, not a
# second reason to refuse everything.
@test "abi-gate: releases a bump the upstream compat declaration sanctions" {
  _gate "2.56.1" "2.56.4" "major.minor" "2.56.0"
  assert_success
  [[ "${lines[0]}" == "decision=release" ]]
}

# why: A declaration the gate cannot parse is not a satisfied constraint. It
# is refused rather than dropped, which is what an ignored unreadable input
# amounts to.
@test "abi-gate: refuses an unparseable upstream compat declaration" {
  _gate "2.56.1" "2.56.4" "major.minor" "unknown"
  assert_failure
}

# ── the refusal leaves nothing behind to release under ───────────────────────

# why: The fail-closed property the wiring rests on. A refusal that printed a
# partial decision would leave an output key for a later job to gate on. It
# writes to stderr only, so there is no `decision` key at all, and the
# dependency is named there for whoever reads the log.
@test "abi-gate: a refusal prints nothing on stdout and names the dependency" {
  DEP_NAME="librealsense" OLD_VERSION="2.56.1" NEW_VERSION="2.57.0" \
  ABI_AXIS="major.minor" \
    run --separate-stderr bash "${SCRIPT}"
  assert_failure
  assert_output ""
  [[ "${stderr}" == *"librealsense"* ]]
}
