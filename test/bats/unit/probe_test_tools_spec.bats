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
#
# The default series arm answers with the pin the checkout carries, so a
# test that is about a TOOL says nothing about alpine and still describes
# an image that matches its checkout. A test about the series overrides it
# with an arm of its own, which is why the caller's arms come first.
_fake_run() {
  printf '
_probe_run() {
  local _cmd="${2}"
  case "${_cmd}" in
    %s
    *alpine-release*) printf "%%s.0\\n" "$(_probe_pinned_series %s)" ;;
    *) return 0 ;;
  esac
}' "${1}" "${DOCKERFILE}"
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

# ── reading the series pin ──────────────────────────────────────────────────
#
# The tool pins are not the only thing in this Dockerfile a pulled image can
# disagree with. Every stage is built `FROM alpine:${ALPINE_VERSION}`, and
# that pin decides which bash the image ships -- which is what decides
# whether kcov reads this suite's coverage correctly at all (see
# dockerfile/Dockerfile.test-tools' measured table, and
# kcov_bash_instrumentation_spec). An image on another series is as wrong an
# image as one carrying another shellcheck, and the version probe was blind
# to it.

@test "probe: reads the alpine series pin out of the real Dockerfile (#946)" {
  run bash -c "$(_src); _probe_pinned_series '${DOCKERFILE}'"
  assert_success
  # Shaped, not literal, for the reason above the tool readers.
  [[ "${output}" =~ ^[0-9]+\.[0-9]+$ ]] || fail "unshaped series: ${output}"
}

@test "probe: a Dockerfile with no ALPINE_VERSION FAILS rather than returning nothing (#946)" {
  local _f="${TEMP_DIR}/no-series"
  printf 'FROM alpine\n' > "${_f}"
  run bash -c "$(_src); _probe_pinned_series '${_f}'"
  assert_failure
}

@test "probe: two ALPINE_VERSION pins are refused, not silently the first (#946)" {
  # Two pins is the state where an expectation cannot be formed: whichever
  # one the reader picked, half the stages would be built on the other.
  local _f="${TEMP_DIR}/two-series"
  printf 'ARG ALPINE_VERSION=3.22\nARG ALPINE_VERSION=3.24\n' > "${_f}"
  run bash -c "$(_src); _probe_pinned_series '${_f}'"
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

@test "probe: an image built on ANOTHER alpine series is refused and both named (#946)" {
  local _series
  _series="$(bash -c "$(_src); _probe_pinned_series '${DOCKERFILE}'")"
  run bash -c "$(_src)
$(_fake_run "*alpine-release*) echo '3.19.4' ;;")
_probe_image img '${DOCKERFILE}'"
  assert_failure 1
  assert_output --partial '3.19.4'
  assert_output --partial "${_series}"
}

@test "probe: an image that reports no alpine series is refused, not read as agreement (#946)" {
  run bash -c "$(_src)
$(_fake_run "*alpine-release*) return 1 ;;")
_probe_image img '${DOCKERFILE}'"
  assert_failure 1
  assert_output --partial 'alpine'
}

@test "probe: a series pin the probe cannot read is a hard refusal (#946)" {
  # Same rule as an unreadable tool pin: "cannot tell" is not "matches".
  # The tool pins are kept intact so the refusal can only be the series.
  local _f="${TEMP_DIR}/no-series-pin"
  grep -v '^ARG ALPINE_VERSION=' "${DOCKERFILE}" > "${_f}"
  run bash -c "$(_src)
$(_fake_run "")
_probe_image img '${_f}'"
  assert_failure 2
  assert_output --partial 'ALPINE_VERSION'
}

@test "probe: a longer series is not satisfied by a prefix of it (#946)" {
  # 3.2 must not be accepted as agreement with a 3.24 image, and a pin of
  # 3.2 must not accept 3.22 either: the comparison is on the whole series
  # field, not a string prefix.
  local _f="${TEMP_DIR}/short-series"
  sed 's|^ARG ALPINE_VERSION=.*|ARG ALPINE_VERSION=3.2|' "${DOCKERFILE}" > "${_f}"
  run bash -c "$(_src)
$(_fake_run "*alpine-release*) echo '3.22.5' ;;")
_probe_image img '${_f}'"
  assert_failure 1
}

# ── the entry point ─────────────────────────────────────────────────────────

@test "probe: main refuses an invocation that names no image (#947)" {
  run bash "${PROBE}"
  assert_failure
  assert_output --partial 'usage'
}

# ── the whole script, over a fake docker ────────────────────────────────────
#
# Everything above overrides `_probe_run`, which is what makes the decision
# logic testable without a daemon -- and it also means the one function in
# this file that actually touches docker was never entered by anything, and
# neither was main's delegation to the verdict. A typo in that `docker run`
# line would have shipped: the probe's own failure path is "rebuild from
# source", so a probe that cannot run at all still leaves CI green, just
# slower and no longer checking anything.
#
# So these two drive the script as a PROGRAM -- `bash script/ci/...` -- with
# a `docker` shim first on PATH, the idiom prune_sh_spec / run_sh_spec /
# wrapper_lib_spec already use. The shim answers as the real image would,
# and the versions it reports are READ from the Dockerfile like everywhere
# else in this file, so a pin bump still touches one place.

# _fake_docker <bin_dir> <shellcheck-version> <hadolint-version> <alpine-release>
#   A `docker` that answers the three questions _probe_run asks -- presence
#   (`command -v <tool>`), tool version, and which alpine the image was
#   built on -- for the readings given. It reads the LAST argument, which
#   is the `sh -c` command string, so it also fails the test if _probe_run
#   ever stops passing one.
_fake_docker() {
  local _dir="${1:?BUG: _fake_docker expects a bin dir}"
  local _sc="${2:?BUG: _fake_docker expects a shellcheck version}"
  local _hd="${3:?BUG: _fake_docker expects a hadolint version}"
  local _al="${4:?BUG: _fake_docker expects an alpine release}"
  mkdir -p "${_dir}"
  cat > "${_dir}/docker" <<EOS
#!/usr/bin/env bash
_cmd="\${*: -1}"
case "\${_cmd}" in
  'command -v '*)        exit 0 ;;
  'shellcheck --version') echo 'ShellCheck - shell script analysis tool'
                          echo 'version: ${_sc}' ;;
  'hadolint --version')   echo 'Haskell Dockerfile Linter ${_hd}' ;;
  'cat /etc/alpine-release') echo '${_al}' ;;
  *) echo "fake docker: unexpected command: \${_cmd}" >&2; exit 127 ;;
esac
EOS
  chmod +x "${_dir}/docker"
}

@test "probe: end to end, an image reporting the pinned versions is accepted (#947)" {
  local _sc _hd _al
  _sc="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' shellcheck")"
  _hd="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' hadolint")"
  _al="$(bash -c "$(_src); _probe_pinned_series '${DOCKERFILE}'")"
  _fake_docker "${TEMP_DIR}/bin" "${_sc}" "${_hd}" "${_al}.0"
  # No dockerfile argument: this is CI's own invocation shape, so the
  # default-resolution branch of main runs here too.
  PATH="${TEMP_DIR}/bin:${PATH}" run bash "${PROBE}" some-image:tag
  assert_success
  assert_output --partial 'every required tool'
}

@test "probe: end to end, an image reporting a STALE version is refused (#947)" {
  # The failure this whole file exists for: the tool is present, so a
  # presence check passes, and the lint gate would run the previous rule
  # set behind a green check.
  local _sc _hd _al
  _sc="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' shellcheck")"
  _hd="$(bash -c "$(_src); _probe_pinned_version '${DOCKERFILE}' hadolint")"
  _al="$(bash -c "$(_src); _probe_pinned_series '${DOCKERFILE}'")"
  _fake_docker "${TEMP_DIR}/bin" '0.1.0' "${_hd}" "${_al}.0"
  PATH="${TEMP_DIR}/bin:${PATH}" run bash "${PROBE}" some-image:tag "${DOCKERFILE}"
  assert_failure 1
  assert_output --partial 'shellcheck'
  assert_output --partial '0.1.0'
  assert_output --partial "${_sc}"
}

@test "probe: the Dockerfile defaults to this checkout's, not the caller's cwd (#947)" {
  # CI invokes it with the image alone from the repo root; the default must
  # resolve off the script's own location so a cwd change cannot silently
  # turn the comparison into an unreadable-pin refusal.
  run bash -c "$(_src); _probe_default_dockerfile"
  assert_success
  assert_output "${DOCKERFILE}"
}
