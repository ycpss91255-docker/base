#!/usr/bin/env bats
#
# config_gen_coverage_spec.bats -- dockerfile/config-gen/gates/coverage.sh,
# the coverage gate the config-gen test stage runs (base#1462).
#
# why: The gate reads per-package profiles and passes a package at >= 90.0%
# of its statements. Every way that measurement can go missing -- go list
# failing or listing nothing, a test failing, a profile absent, carrying the
# wrong mode, a malformed line or a line from another package, a package
# with source files and no statements -- must be a refusal, because each one
# otherwise reads as "covered". The floor is an integer comparison so no
# float rounding moves a package across it.
#
# The script runs inside the golang image, which has no lib/log.sh, so its
# refusal is one exact stderr line rather than a JSON event; the runner
# re-emits the id as an event (config_gen_gates_spec.bats). A stub `go` on
# PATH answers `go list` and `go test` from canned files here.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  GATE="/source/dockerfile/config-gen/gates/coverage.sh"
  S="${BATS_TEST_TMPDIR}"
  mkdir -p "${S}/bin" "${S}/prof" "${S}/mod"
  : > "${S}/list"
  printf '0\n' > "${S}/list.rc"
  _stub_go
}

# _stub_go -- `go list ...` prints ${S}/list and exits ${S}/list.rc.
# `go test ... -coverprofile=<f> ... <pkg>` copies ${S}/prof/<key> to <f>
# when it exists (<key> is <pkg> with / as _) and exits ${S}/prof/<key>.rc,
# 0 when there is none. Every call is logged to ${S}/go.calls.
_stub_go() {
  cat > "${S}/bin/go" <<EOF
#!$(command -v bash)
printf '%s\n' "\$*" >> "${S}/go.calls"
case "\${1:-}" in
  list)
    cat "${S}/list"
    exit "\$(cat "${S}/list.rc")" ;;
  test)
    out=""
    for a in "\$@"; do [[ "\${a}" == -coverprofile=* ]] && out="\${a#-coverprofile=}"; done
    pkg="\${*: -1}"
    key="\${pkg//\//_}"
    [[ -n "\${out}" && -f "${S}/prof/\${key}" ]] && cp "${S}/prof/\${key}" "\${out}"
    exit "\$(cat "${S}/prof/\${key}.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
  chmod +x "${S}/bin/go"
}

# _pkg <import-path> <gofiles> [cgofiles] -- add a package to the listing.
_pkg() {
  printf '%s\t%s\t%s\n' "${1}" "${2}" "${3:-0}" >> "${S}/list"
}

# _profile <import-path> <line>... -- the package's canned profile: a
# `mode: atomic` header, then each <line>.
_profile() {
  local _key="${1//\//_}"
  shift
  { printf 'mode: atomic\n'; printf '%s\n' "$@"; } > "${S}/prof/${_key}"
}

_run_gate() {
  assert_spec_subject "${GATE}" "the config-gen coverage gate (base#1462)"
  run --separate-stderr env PATH="${S}/bin:${PATH}" bash -c "cd '${S}/mod' && bash '${GATE}'"
}

# _refused <reason> <pkg> -- the exact refusal: rc 1, empty stdout, and one
# stderr line naming the reason and the package.
_refused() {
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  assert_equal "${stderr}" "config_gen_gate_coverage_failed reason=${1} pkg=${2}"
}

# _passed -- rc 0, `gate=coverage ok` alone on stdout, nothing on stderr.
_passed() {
  assert_equal "${status}" 0
  assert_equal "${output}" "gate=coverage ok"
  assert_equal "${stderr}" ""
}

# why: A list that failed is not a list of zero packages; reading it as one
# passes a module nobody measured.
@test "coverage.sh: a failing go list is refused with reason list_failed (base#1462)" {
  _pkg m/a 1
  printf '1\n' > "${S}/list.rc"
  _run_gate
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  [[ "${stderr}" =~ ^config_gen_gate_coverage_failed\ reason=list_failed(\ pkg=[^$'\n']*)?$ ]] \
    || fail "want one list_failed line on stderr, got: ${stderr}"
}

@test "coverage.sh: an empty package list is refused with reason no_packages (base#1462)" {
  _run_gate
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  [[ "${stderr}" =~ ^config_gen_gate_coverage_failed\ reason=no_packages(\ pkg=[^$'\n']*)?$ ]] \
    || fail "want one no_packages line on stderr, got: ${stderr}"
}

@test "coverage.sh: a failing package test is refused with reason test_failed (base#1462)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1'
  printf '1\n' > "${S}/prof/m_a.rc"
  _run_gate
  _refused test_failed m/a
}

# why: The profile is the measurement; a test run that wrote none, or wrote
# one in another mode, has measured nothing this gate can read.
@test "coverage.sh: a missing profile is refused with reason profile_invalid (base#1462)" {
  _pkg m/a 1
  _run_gate
  _refused profile_invalid m/a
}

@test "coverage.sh: a profile not in atomic mode is refused with reason profile_invalid (base#1462)" {
  _pkg m/a 1
  printf 'mode: set\nm/a/a.go:1.1,2.2 10 1\n' > "${S}/prof/m_a"
  _run_gate
  _refused profile_invalid m/a
}

@test "coverage.sh: a malformed profile line is refused with reason profile_invalid (base#1462)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1' 'm/a/a.go:3.1,4.2 x 1'
  _run_gate
  _refused profile_invalid m/a
}

# why: A line attributed to another package, or to a subpackage, would add
# that package's statements to this one's ratio.
@test "coverage.sh: a profile line from another package is refused with reason profile_invalid (base#1462)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1' 'm/b/b.go:1.1,2.2 10 1'
  _run_gate
  _refused profile_invalid m/a
  : > "${S}/list"
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1' 'm/a/sub/s.go:1.1,2.2 10 1'
  _run_gate
  _refused profile_invalid m/a
}

# why: The issue's `[no statements]` rule: a package with source files and
# zero statements was not measured, while a package with no source files
# (tests or types moved elsewhere) has nothing to measure.
@test "coverage.sh: zero statements with source files is refused with reason no_statements (base#1462)" {
  _pkg m/a 1
  _profile m/a
  _run_gate
  _refused no_statements m/a
  : > "${S}/list"
  _pkg m/a 0 1
  _run_gate
  _refused no_statements m/a
}

@test "coverage.sh: zero statements with no source files passes (base#1462)" {
  _pkg m/a 0 0
  _profile m/a
  _run_gate
  _passed
}

# why: >= 90.0 exactly, as an integer comparison: 899/1000 is below and
# 900/1000 is not, and a red package is named even after a green one.
@test "coverage.sh: 899 of 1000 statements is refused with reason below_floor, 900 passes (base#1462)" {
  _pkg m/ok 1
  _profile m/ok 'm/ok/o.go:1.1,2.2 10 1'
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 899 1' 'm/a/a.go:3.1,4.2 101 0'
  _run_gate
  _refused below_floor m/a
  _profile m/a 'm/a/a.go:1.1,2.2 900 1' 'm/a/a.go:3.1,4.2 100 0'
  _run_gate
  _passed
}

# why: atomic profiles repeat a block once per test binary that ran it;
# summing the repeats would count its statements twice, and keeping the
# first repeat would keep a zero count another repeat covered.
@test "coverage.sh: a repeated block counts once, at its highest count (base#1462)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 900 0' 'm/a/a.go:3.1,4.2 100 0' 'm/a/a.go:1.1,2.2 900 3'
  _run_gate
  _passed
}

# why: One profile per package is what makes the attribution check possible;
# a single ./... profile cannot say which package a line came from.
@test "coverage.sh: runs one atomic-mode go test per listed package (base#1462)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1'
  _pkg m/b 1
  _profile m/b 'm/b/b.go:1.1,2.2 10 1'
  _run_gate
  _passed
  run grep -c '^test ' "${S}/go.calls"
  assert_output 2
  run grep '^test ' "${S}/go.calls"
  assert_line --regexp '^test .*-covermode=atomic .*m/a$'
  assert_line --regexp '^test .*-covermode=atomic .*m/b$'
}
