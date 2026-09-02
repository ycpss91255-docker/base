#!/usr/bin/env bats
#
# probe_test_tools_spec.bats -- unit tests for the CI-side probe that
# decides whether a pulled `test-tools:main` may be used as-is.
#
# CI does not rebuild the tooling image for a PR that leaves
# dockerfile/Dockerfile.test-tools alone. It pulls the rolling `:main` tag
# instead, and `:main` is only republished by a push to main that touches
# that Dockerfile. So between the moment a tool pin changes and the moment
# that republish finishes -- and indefinitely if it fails -- every other
# PR's suite runs inside an image whose linters are NOT the ones its own
# checkout pins.
#
# The guard that existed asked `command -v <tool>` and nothing else:
# PRESENCE, never version. That answers the kcov race it was written for
# and is blind to a pin bump, which is the louder failure of the two -- a
# lint job that passes under the rule set the repo just moved off is a
# green check reporting on the wrong thing, and there is no error anywhere
# to notice.
#
# So the probe compares. The expectations are READ from the checkout's
# Dockerfile, never restated: this file names no version either, so a bump
# touches the Dockerfile and leaves both the probe and these tests alone.
#
# A tool whose version is pinned by literal release URL is named in
# PINNED_TOOLS, and an unreadable pin for one of those is a HARD failure
# rather than a skip: an empty expectation compared against an empty
# reading agrees with itself, which is exactly the shape of pass this
# whole mechanism exists to refuse.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  PROBE=/source/script/ci/probe_test_tools.sh
  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${PROBE}" \
    "the CI-side test-tools probe this spec drives"
  assert_spec_subject "${DOCKERFILE}" \
    "the Dockerfile the probe reads its expectations from"
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _src -- source the probe so a test drives the REAL function bodies.
_src() {
  printf 'source %s' "${PROBE}"
}

# _fake_image <spec> -- a `_probe_run` stand-in, so the probe's decision
# logic is exercised without a docker daemon. <spec> is a newline-free
# case body: `<pattern>) <action> ;;` arms matching the command string.
_fake_run() {
  printf '
_probe_run() {
  local _cmd="${2}"
  case "${_cmd}" in
    %s
    *) return 0 ;;
  esac
}' "${1}"
}

# ── reading the pin ─────────────────────────────────────────────────────────

@test "probe: reads the shellcheck pin out of the real Dockerfile (#947)" {
  run bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' shellcheck"
  assert_success
  # Shaped, not literal: naming the version here would be the second place
  # to bump, which is the defect this whole file is about.
  [[ "${output}" =~ ^[0-9]+\.[0-9]+ ]] || fail "unshaped pin: ${output}"
}

@test "probe: reads the hadolint pin out of the real Dockerfile (#947)" {
  run bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' hadolint"
  assert_success
  [[ "${output}" =~ ^[0-9]+\.[0-9]+ ]] || fail "unshaped pin: ${output}"
}

@test "probe: a Dockerfile with no pinned URL FAILS rather than returning nothing (#947)" {
  local _f="${TEMP_DIR}/no-pin"
  printf 'FROM alpine\nRUN apk add shellcheck\n' > "${_f}"
  run bash -c "$(_src); _probe_pinned_version '${_f}' shellcheck"
  assert_failure
}

# ── comparing a reported version ────────────────────────────────────────────

@test "probe: a version is matched whole, not as a prefix of a longer one (#947)" {
  run bash -c "$(_src); _probe_reports_version 'version: 0.11.0' '0.11.0'"
  assert_success
  run bash -c "$(_src); _probe_reports_version 'version: 0.11.01' '0.11.0'"
  assert_failure
  run bash -c "$(_src); _probe_reports_version 'version: 10.11.0' '0.11.0'"
  assert_failure
}

@test "probe: the dots in a version are literal, not any-character (#947)" {
  run bash -c "$(_src); _probe_reports_version 'version: 0x11x0' '0.11.0'"
  assert_failure
}

# ── the decision ────────────────────────────────────────────────────────────

@test "probe: an image carrying every tool at the pinned version is accepted (#947)" {
  local _sc _hd
  _sc="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' shellcheck")"
  _hd="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' hadolint")"
  run bash -c "$(_src)
$(_fake_run "*'shellcheck --version'*) echo 'version: ${_sc}' ;; *'hadolint --version'*) echo 'Haskell Dockerfile Linter ${_hd}' ;;")
_probe_image img '${DOCKERFILE}'"
  assert_success
}

@test "probe: a MISSING tool is refused and named (#947)" {
  run bash -c "$(_src)
$(_fake_run "*'command -v kcov'*) return 1 ;;")
_probe_image img '${DOCKERFILE}'"
  assert_failure
  assert_output --partial 'kcov'
}

@test "probe: a tool at the WRONG version is refused and both versions are named (#947)" {
  local _sc
  _sc="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' shellcheck")"
  run bash -c "$(_src)
$(_fake_run "*'shellcheck --version'*) echo 'version: 0.1.0' ;;")
_probe_image img '${DOCKERFILE}'"
  assert_failure
  assert_output --partial 'shellcheck'
  assert_output --partial '0.1.0'
  assert_output --partial "${_sc}"
}

@test "probe: a present-but-silent tool is refused, not read as agreement (#947)" {
  # `<tool> --version` printing nothing must not compare equal to a pin.
  # shellcheck is given its real version so the refusal below can only be
  # about hadolint.
  local _sc
  _sc="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' shellcheck")"
  run bash -c "$(_src)
$(_fake_run "*'shellcheck --version'*) echo 'version: ${_sc}' ;; *'hadolint --version'*) return 0 ;;")
_probe_image img '${DOCKERFILE}'"
  assert_failure
  assert_output --partial 'hadolint'
}

@test "probe: an unreadable pin for a PINNED tool is a hard refusal (#947)" {
  # The state a moved release URL or a renamed file produces. Comparing an
  # empty expectation against an empty reading agrees with itself.
  local _f="${TEMP_DIR}/no-pin"
  printf 'FROM alpine\n' > "${_f}"
  # Every tool is PRESENT, so the only thing left to refuse is the missing
  # expectation itself.
  run bash -c "$(_src)
$(_fake_run "")
_probe_image img '${_f}'"
  assert_failure
  assert_output --partial 'pin'
}

@test "probe: an empty REQUIRED_TOOLS is refused rather than passing vacuously (#947)" {
  run bash -c "$(_src); REQUIRED_TOOLS='' _probe_image img '${DOCKERFILE}'"
  assert_failure
}

@test "probe: a PINNED tool absent from REQUIRED_TOOLS is refused as a contradiction (#947)" {
  # PINNED_TOOLS names tools whose VERSION matters; REQUIRED_TOOLS names
  # the tools the run executes. A pinned tool the probe never looks at is
  # a list that has drifted, not a narrower probe.
  run bash -c "$(_src); REQUIRED_TOOLS='kcov bats' _probe_image img '${DOCKERFILE}'"
  assert_failure
  assert_output --partial 'REQUIRED_TOOLS'
}

# ── the entry point ─────────────────────────────────────────────────────────

@test "probe: main refuses an invocation that names no image (#947)" {
  run bash "${PROBE}"
  assert_failure
  assert_output --partial 'usage'
}

@test "probe: the Dockerfile defaults to this checkout's, not the caller's cwd (#947)" {
  # CI invokes it with the image alone from the repo root; the default must
  # resolve off the script's own location so a cwd change cannot silently
  # turn the comparison into an unreadable-pin refusal.
  run bash -c "$(_src); _probe_default_dockerfile"
  assert_success
  assert_output "${DOCKERFILE}"
}
