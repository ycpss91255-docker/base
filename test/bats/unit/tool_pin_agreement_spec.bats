#!/usr/bin/env bats
#
# tool_pin_agreement_spec.bats -- the shellcheck and hadolint the image
# actually ships are the versions the Dockerfile pins.
#
# The two lint gates every PR here must pass are pinned by literal release
# URL in dockerfile/Dockerfile.test-tools. Nothing compared the pin with the
# binary. The publish workflow ran `shellcheck --version` / `hadolint
# --version` and asserted exit 0, which answers "is there a binary", never
# "is it the one we asked for" -- and a hadolint pin sat three and a half
# years stale behind that green check.
#
# The publish workflow now compares. This spec compares in the OTHER place,
# and the other place is the one that matters more often: `just test` and
# every CI lint job run inside this image, on every pull request, whereas
# the publish smoke stage runs only when a tag or a Dockerfile change
# triggers a republish. A pinned URL edited without a rebuild, a cached
# layer that outlived the edit, a hand-pushed image -- each of those reaches
# a developer's gate long before it reaches a publish, and each is a state
# where the lint result is being attributed to the wrong rule set.
#
# Both tools report a bare number while the pin is a tag, so the comparison
# strips the leading v and bounds the number on both sides -- 0.11.0 must
# not be satisfied by 0.11.01 or by any longer digit run that contains it.
#
# These two tests can only pass in an image that matches the checkout, and
# CI does not rebuild the image for every PR -- it pulls the rolling
# `test-tools:main`. That is why self-test.yaml's Obtain step compares the
# pulled image's tool VERSIONS with this same Dockerfile before accepting
# it (script/ci/probe_test_tools.sh) and rebuilds from source when they
# disagree. So a pin bump does not leave unrelated PRs failing here until
# `:main` is republished: the mismatch is self-corrected one layer down,
# where it can be, rather than skipped here, where skipping would retire
# the check on exactly the runs it was written for.
#
# The pin is READ from the Dockerfile, never restated here: this file names
# no version, so a bump touches the Dockerfile and leaves the spec alone.
# The reader's failure path is exercised on a fixture rather than assumed,
# because a reader that silently returns nothing would turn this whole file
# into a comparison of two empty strings -- the exact shape of pass this
# spec exists to refuse.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${DOCKERFILE}" \
    "the test-tools Dockerfile whose lint-tool pins this spec checks"
}

# _pinned_version <file> <tool>
#   The version in the tool's pinned release URL, leading v stripped.
#   Prints nothing and fails when no such URL is present -- an unreadable
#   pin is a defect, not an absent constraint.
_pinned_version() {
  local _file="${1:?BUG: _pinned_version expects a file}"
  local _tool="${2:?BUG: _pinned_version expects a tool}"
  local _v
  _v="$(sed -n "s|.*${_tool}/releases/download/v\([0-9][0-9.]*\)/.*|\1|p" \
    "${_file}" | head -n1)"
  [[ -n "${_v}" ]] || return 1
  printf '%s\n' "${_v}"
}

# _reports_version <text> <version>
#   Does the tool's own --version output carry exactly this version? Dots
#   are escaped and the number is bounded on both sides.
_reports_version() {
  local _text="${1?BUG: _reports_version expects the tool output}"
  local _version="${2:?BUG: _reports_version expects a version}"
  local _re="${_version//./\\.}"
  [[ "${_text}" =~ (^|[^0-9.])${_re}([^0-9.]|$) ]]
}

@test "tool pins: the shipped shellcheck is the version the Dockerfile pins" {
  local _pinned _actual
  _pinned="$(_pinned_version "${DOCKERFILE}" shellcheck)"
  _actual="$(shellcheck --version)"
  _reports_version "${_actual}" "${_pinned}" || fail \
    "the Dockerfile pins shellcheck v${_pinned} but the image reports: ${_actual}. Either the image predates the pin (rebuild: the content-hash tag changes with the Dockerfile, so a stale tag is a stale image) or the pin was edited without one. Until they agree, every lint result in this image is being attributed to a rule set it did not run."
}

@test "tool pins: the shipped hadolint is the version the Dockerfile pins" {
  local _pinned _actual
  _pinned="$(_pinned_version "${DOCKERFILE}" hadolint)"
  _actual="$(hadolint --version)"
  _reports_version "${_actual}" "${_pinned}" || fail \
    "the Dockerfile pins hadolint v${_pinned} but the image reports: ${_actual}. Either the image predates the pin (rebuild) or the pin was edited without one. This is the exact drift that let a 2022 rule set stay behind a green gate."
}

@test "tool pins reader: a Dockerfile with no pinned URL FAILS rather than returning nothing" {
  local _f="${BATS_TEST_TMPDIR}/no-pin"
  printf 'FROM alpine\nRUN apk add shellcheck\n' > "${_f}"
  run _pinned_version "${_f}" shellcheck
  assert_failure
}

@test "tool pins reader: a version is matched whole, not as a prefix of a longer one" {
  _reports_version 'version: 0.11.0' '0.11.0'
  ! _reports_version 'version: 0.11.01' '0.11.0'
  ! _reports_version 'version: 10.11.0' '0.11.0'
}

@test "tool pins reader: the dots in a version are literal, not any-character" {
  ! _reports_version 'version: 0x11x0' '0.11.0'
}
