#!/usr/bin/env bats
#
# tool_pin_agreement_spec.bats -- the versions this image actually ships
# are the ones the Dockerfile names: the two linters it pins by release
# URL, and the alpine series every stage is built on.
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
# The third pin is the alpine SERIES, and it was the one nothing measured.
# `ARG ALPINE_VERSION` decides which bash the image ships, and bash is what
# decides whether kcov can read this suite's coverage at all -- 5.3's
# ANSI-C xtrace quoting makes it report lines that ran as never run. The
# Dockerfile records the bash-per-series table it was measured from, and
# until these tests that table was a claim in a comment: nothing compared
# it, or the series itself, with the image the suite was running inside.
# alpine_eol_spec reads the same file, but only ever the file.
#
# The series assertion is exact. The bash one is on the 5.x SERIES rather
# than the point release, because the series is the load-bearing half --
# 5.2 against 5.3 is what moves the coverage number -- while a point
# release moves inside a stable alpine branch without anything being wrong.
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

# _pinned_series <file>
#   The value of `ARG ALPINE_VERSION=`. Prints nothing and fails when the
#   ARG is absent or declared more than once -- with two pins there is no
#   single series for the image to agree with, which is a defect rather
#   than a reason to pass.
_pinned_series() {
  local _file="${1:?BUG: _pinned_series expects a file}"
  local -a _hits=()
  local _line
  while IFS= read -r _line; do
    _hits+=("${_line#ARG ALPINE_VERSION=}")
  done < <(grep -E '^ARG ALPINE_VERSION=' "${_file}")
  [[ "${#_hits[@]}" -eq 1 ]] || return 1
  printf '%s\n' "${_hits[0]}"
}

# _table_bash <file> <series>
#   The bash version the Dockerfile's measured table records for a series,
#   from a `<series> -> bash <version>` row. Prints nothing and fails when
#   the series has no row: a pin the table does not cover is a table that
#   stopped being a measurement.
_table_bash() {
  local _file="${1:?BUG: _table_bash expects a file}"
  local _series="${2:?BUG: _table_bash expects a series}"
  local _re="${_series//./\\.}"
  local _row
  _row="$(grep -oE "(^|[^0-9.])${_re} -> bash [0-9]+\.[0-9]+(\.[0-9]+)?" \
    "${_file}" | head -n1)"
  [[ -n "${_row}" ]] || return 1
  printf '%s\n' "${_row##* }"
}

# why: Exit 0 says a binary exists; this says it is the one the pin asked
# for
@test "tool pins: the shipped shellcheck is the version the Dockerfile pins" {
  local _pinned _actual
  _pinned="$(_pinned_version "${DOCKERFILE}" shellcheck)"
  _actual="$(shellcheck --version)"
  _reports_version "${_actual}" "${_pinned}" || fail \
    "the Dockerfile pins shellcheck v${_pinned} but the image reports: ${_actual}. Either the image predates the pin (rebuild: the content-hash tag changes with the Dockerfile, so a stale tag is a stale image) or the pin was edited without one. Until they agree, every lint result in this image is being attributed to a rule set it did not run."
}

# why: The drift that let a 2022 rule set stay behind a green gate, now
# asserted every run
@test "tool pins: the shipped hadolint is the version the Dockerfile pins" {
  local _pinned _actual
  _pinned="$(_pinned_version "${DOCKERFILE}" hadolint)"
  _actual="$(hadolint --version)"
  _reports_version "${_actual}" "${_pinned}" || fail \
    "the Dockerfile pins hadolint v${_pinned} but the image reports: ${_actual}. Either the image predates the pin (rebuild) or the pin was edited without one. This is the exact drift that let a 2022 rule set stay behind a green gate."
}

# why: A reader returning nothing would reduce both checks to empty-vs-empty
# agreement
@test "tool pins reader: a Dockerfile with no pinned URL FAILS rather than returning nothing" {
  local _f="${BATS_TEST_TMPDIR}/no-pin"
  printf 'FROM alpine\nRUN apk add shellcheck\n' > "${_f}"
  run _pinned_version "${_f}" shellcheck
  assert_failure
}

# why: 0.11.0 must not be satisfied by 0.11.01 or by 10.11.0
@test "tool pins reader: a version is matched whole, not as a prefix of a longer one" {
  _reports_version 'version: 0.11.0' '0.11.0'
  ! _reports_version 'version: 0.11.01' '0.11.0'
  ! _reports_version 'version: 10.11.0' '0.11.0'
}

# why: An unescaped regex dot would let 0x11x0 pass as 0.11.0
@test "tool pins reader: the dots in a version are literal, not any-character" {
  ! _reports_version 'version: 0x11x0' '0.11.0'
}

# why: The base every stage is built on, compared with the image the suite
# is actually running in
@test "tool pins: the alpine this image runs on is the series the Dockerfile pins" {
  local _series _release
  _series="$(_pinned_series "${DOCKERFILE}")"
  _release="$(cat /etc/alpine-release)"
  case "${_release}" in
    "${_series}" | "${_series}".*) ;;
    *) fail "the Dockerfile pins alpine ${_series} but this image reports ${_release}. Every stage is built FROM alpine:\${ALPINE_VERSION}, so the image the suite is running in does not correspond to the checkout it is testing -- rebuild it (the content-hash tag moves with the Dockerfile, so a stale tag is a stale image)." ;;
  esac
}

# why: The bash-per-series table the series was chosen on, asserted rather
# than left as a comment
@test "tool pins: the bash this image ships is the series the pin's table records" {
  local _series _expected _actual
  _series="$(_pinned_series "${DOCKERFILE}")"
  _expected="$(_table_bash "${DOCKERFILE}" "${_series}")" || fail \
    "the Dockerfile's bash-per-series table has no row for the series it pins (${_series}). The table is what the series was CHOSEN on -- it is the record that this series keeps bash on the side of the 5.3 boundary kcov can read -- so a pin it does not cover is a choice nothing supports."
  # Read out of the binary the image ships, not out of ${BASH_VERSION}:
  # the claim under test is about what was installed, and the reading
  # should come from the same place a person would check it.
  _actual="$(bash --version)"
  local _want="${_expected%.*}" _got
  _got="$(printf '%s\n' "${_actual}" | sed -n 's/.*version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)"
  [[ "${_got}" == "${_want}" ]] || fail \
    "the Dockerfile records bash ${_expected} for alpine ${_series} but this image ships ${_actual}. Either the image is not built on the pinned series, or the measured table is no longer a measurement -- and the table is what says whether kcov reads this suite's coverage or silently under-reports it."
}

# why: A pin the table has no row for is a choice nothing supports
@test "tool pins reader: a series the table does not cover FAILS rather than returning nothing" {
  local _f="${BATS_TEST_TMPDIR}/no-row"
  printf '# 3.21 -> bash 5.2.37\nARG ALPINE_VERSION=3.99\n' > "${_f}"
  run _table_bash "${_f}" 3.99
  assert_failure
}

# why: A row for 3.2 must not answer for 3.22, nor one for 13.22
@test "tool pins reader: a table row is matched whole, not as a prefix of a longer series" {
  # A row for 3.2 must not answer for 3.22, and a row for 13.22 must not
  # answer for 3.22 either.
  local _f="${BATS_TEST_TMPDIR}/prefix-row"
  printf '#     3.2 -> bash 5.1.16     13.22 -> bash 5.9.9\n' > "${_f}"
  run _table_bash "${_f}" 3.22
  assert_failure
}

# why: With two pins there is no single series for the image to agree with
@test "tool pins reader: an ALPINE_VERSION declared twice FAILS rather than picking one" {
  local _f="${BATS_TEST_TMPDIR}/two-pins"
  printf 'ARG ALPINE_VERSION=3.22\nARG ALPINE_VERSION=3.24\n' > "${_f}"
  run _pinned_series "${_f}"
  assert_failure
}
