#!/usr/bin/env bats
#
# config_gen_coverage_spec.bats -- script/test/config_gen_coverage.sh,
# the coverage gate the config-gen test stage runs (base#1462).
#
# why: The gate measures per-package profiles and writes, per package,
# `<import path>\t<statements>\t<covered>` for the floor ratchet
# (cmd/cg-gates ratchet, base#1465), which judges every floor. Every way
# the measurement can go missing -- go list failing or listing nothing, a
# test failing, a profile absent, carrying the wrong mode, a malformed line
# or a line from another package -- must be a refusal, because each one
# otherwise reads as a count. The counts are integers, so no float rounding
# moves a package across a floor.
#
# The script runs inside the golang image, which has no lib/log.sh, so its
# refusal is one exact stderr line rather than a JSON event; the runner
# re-emits the id as an event (config_gen_gates_spec.bats). A stub `go` on
# PATH answers `go list` and `go test` from canned files here.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  GATE="/source/script/test/config_gen_coverage.sh"
  S="${BATS_TEST_TMPDIR}"
  mkdir -p "${S}/bin" "${S}/prof" "${S}/mod"
  : > "${S}/list"
  printf '0\n' > "${S}/list.rc"
  _stub_go
}

# _stub_go -- `go list ...` prints ${S}/list and exits ${S}/list.rc.
# When ${S}/pkgs exists (rows `<pkg>\t<gofiles>\t<testgofiles>\t<xtestgofiles>`,
# written by _tested_pkg), `go list -f <template> ...` instead renders the
# template once per row, filling {{.ImportPath}}, {{len .GoFiles}},
# {{len .TestGoFiles}} and {{len .XTestGoFiles}}; any other action makes
# the stub exit 3, so a template it cannot answer never reads as a listing.
# `go test ... -coverprofile=<f> ... <pkg>` copies ${S}/prof/<key> to <f>
# when it exists (<key> is <pkg> with / as _) and exits ${S}/prof/<key>.rc,
# 0 when there is none. Every call is logged to ${S}/go.calls.
_stub_go() {
  cat > "${S}/bin/go" <<EOF
#!$(command -v bash)
printf '%s\n' "\$*" >> "${S}/go.calls"
case "\${1:-}" in
  list)
    if [[ -f "${S}/pkgs" && "\${2:-}" == -f ]]; then
      while IFS=\$'\t' read -r p g t x; do
        line="\${3}"
        line="\${line//'{{.ImportPath}}'/\${p}}"
        line="\${line//'{{len .GoFiles}}'/\${g}}"
        line="\${line//'{{len .TestGoFiles}}'/\${t}}"
        line="\${line//'{{len .XTestGoFiles}}'/\${x}}"
        if [[ "\${line}" == *'{{'* ]]; then
          printf 'go stub: unsupported list template: %s\n' "\${3}" >&2
          exit 3
        fi
        printf '%s\n' "\${line}"
      done < "${S}/pkgs"
      exit "\$(cat "${S}/list.rc")"
    fi
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

# _tested_pkg <import-path> <gofiles> <testgofiles> <xtestgofiles> -- add a
# package, with its test file counts, to the listing a `go list -f`
# template is rendered from.
_tested_pkg() {
  printf '%s\t%s\t%s\t%s\n' "${1}" "${2}" "${3}" "${4}" >> "${S}/pkgs"
}

# _profile <import-path> <line>... -- the package's canned profile: a
# `mode: atomic` header, then each <line>.
_profile() {
  local _key="${1//\//_}"
  shift
  { printf 'mode: atomic\n'; printf '%s\n' "$@"; } > "${S}/prof/${_key}"
}

# _run_gate_with [arg...] -- run the gate from ${S}/mod with exactly the
# given arguments.
_run_gate_with() {
  assert_spec_subject "${GATE}" "the config-gen coverage gate (base#1462)"
  local _args=""
  (( $# == 0 )) || _args="$(printf " '%s'" "$@")"
  run --separate-stderr env PATH="${S}/bin:${PATH}" bash -c "cd '${S}/mod' && bash '${GATE}'${_args}"
}

# _run_gate -- run the gate with --measure ${S}/measured and a valid corpus
# root record (base#1468).
_run_gate() {
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with --measure "${S}/measured" "${S}/corpus-root"
}

# _refused <reason> <pkg> -- the exact refusal: rc 1, empty stdout, and one
# stderr line naming the reason and the package.
_refused() {
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  assert_equal "${stderr}" "config_gen_gate_coverage_failed reason=${1} pkg=${2}"
}

# _passed [<line>...] -- rc 0, nothing on stdout or stderr, and when lines
# are given, ${S}/measured holding exactly them.
_passed() {
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  (( $# == 0 )) || assert_equal "$(od -An -c "${S}/measured" | tr -s ' ')" \
    "$(printf '%s\n' "$@" | od -An -c | tr -s ' ')"
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

# why: Judging a package with source files and zero statements is the
# ratchet's (its `none` rule, base#1465); the gate's job is the count, and
# a refusal here would leave such a package unjudgeable. The listing and
# profile are what golang:1.27.2-trixie gave for a package holding only
# declarations: GoFiles 1 and a profile of exactly `mode: atomic`.
@test "coverage.sh: zero statements with or without source files is measured as 0 0 (base#1465)" {
  _pkg m/a 1
  _profile m/a
  _pkg m/b 0 1
  _profile m/b
  _pkg m/c 0 0
  _profile m/c
  _run_gate
  _passed "m/a"$'\t'"0"$'\t'"0" "m/b"$'\t'"0"$'\t'"0" "m/c"$'\t'"0"$'\t'"0"
}

# why: The counts are what the ratchet compares in integer tenths: 899 of
# 1000 and 900 of 1000 must reach it as exactly those numbers, with no
# floor judged here (base#1465).
@test "coverage.sh: 899 and 900 of 1000 statements are measured exactly, with no floor judged (base#1465)" {
  _pkg m/ok 1
  _profile m/ok 'm/ok/o.go:1.1,2.2 10 1'
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 899 1' 'm/a/a.go:3.1,4.2 101 0'
  _run_gate
  _passed "m/ok"$'\t'"10"$'\t'"10" "m/a"$'\t'"1000"$'\t'"899"
  _profile m/a 'm/a/a.go:1.1,2.2 900 1' 'm/a/a.go:3.1,4.2 100 0'
  _run_gate
  _passed "m/ok"$'\t'"10"$'\t'"10" "m/a"$'\t'"1000"$'\t'"900"
}

# why: Without --measure the gate would have nowhere to write the counts,
# and no floor to judge; it refuses rather than passing on nothing
# (base#1465).
@test "coverage.sh: a run without --measure <file> is refused with reason usage before go runs (base#1465)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1'
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with "${S}/corpus-root"
  _refused usage ""
  _run_gate_with --measure
  _refused usage ""
  [[ ! -e "${S}/go.calls" ]] || fail "go ran before the guard: $(cat "${S}/go.calls")"
}

# why: atomic profiles repeat a block once per test binary that ran it;
# summing the repeats would count its statements twice, and keeping the
# first repeat would keep a zero count another repeat covered.
@test "coverage.sh: a repeated block counts once, at its highest count (base#1462)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 900 0' 'm/a/a.go:3.1,4.2 100 0' 'm/a/a.go:1.1,2.2 900 3'
  _run_gate
  _passed "m/a"$'\t'"1000"$'\t'"900"
}

# why: The race RUN's one go test writes a single merged atomic profile
# (base#1547), so the coverage RUN must not run go test again: --profile
# splits that profile per listed package and counts each as today. A block
# belongs to the package whose import path equals its file's directory, so
# m/a/sub is counted on its own and never folded into m/a, and a block the
# profile repeats counts once, at its highest count. The expected lines are
# worked by hand from the literal profile: m/a holds 2+1 statements, 2 of
# them covered (its first block's repeat carries count 1); m/a/sub 5, none
# covered; m/b 4, all covered.
@test "coverage.sh: --profile splits one merged profile per package, nested dirs apart, and runs no go test (base#1547)" {
  _pkg m/a 1
  _pkg m/a/sub 1
  _pkg m/b 1
  printf '%s\n' 'mode: atomic' \
    'm/a/a.go:1.1,2.2 2 0' \
    'm/a/a.go:3.1,4.2 1 0' \
    'm/a/sub/s.go:1.1,2.2 5 0' \
    'm/a/a.go:1.1,2.2 2 1' \
    'm/b/b.go:1.1,2.2 4 7' > "${S}/all.out"
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with --measure "${S}/measured" "${S}/corpus-root" --profile "${S}/all.out"
  _passed "m/a"$'\t'"3"$'\t'"2" "m/a/sub"$'\t'"5"$'\t'"0" "m/b"$'\t'"4"$'\t'"4"
  if grep -q '^test ' "${S}/go.calls"; then
    fail "--profile still ran go test: $(grep '^test ' "${S}/go.calls")"
  fi
}

# why: A merged profile holds exactly one `mode: atomic` header (base#1547).
# A second mode line means two profiles were concatenated, or the file is
# not what the race RUN wrote; splitting it would silently drop that line
# and count the rest. It is refused as profile_invalid, before any count is
# written and without go test.
@test "coverage.sh: --profile refuses a merged profile with a second mode line as profile_invalid (base#1547)" {
  _pkg m/a 1
  printf '%s\n' 'mode: atomic' \
    'm/a/a.go:1.1,2.2 2 1' \
    'mode: atomic' \
    'm/a/a.go:3.1,4.2 1 1' > "${S}/all.out"
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with --measure "${S}/measured" "${S}/corpus-root" --profile "${S}/all.out"
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  [[ "${stderr}" =~ ^config_gen_gate_coverage_failed\ reason=profile_invalid(\ pkg=[^$'\n']*)?$ ]] \
    || fail "want one profile_invalid line on stderr, got: ${stderr}"
  [[ ! -e "${S}/measured" ]] || fail "a refused profile still wrote counts: $(cat "${S}/measured")"
  if grep -q '^test ' "${S}/go.calls" 2>/dev/null; then
    fail "--profile still ran go test: $(grep '^test ' "${S}/go.calls")"
  fi
}

# why: A package with no statements has no block in any profile: go test
# writes only the `mode:` header for it, which today's per-package
# _measure counts as `<pkg>\t0\t0` (base#1547). The planted
# internal/zzglob holds only zzglob_test.go, and a package of types or
# constants alone is the same, so a merged profile with no block for such
# a package is what a complete profile looks like. --profile must count
# both as 0 0, the line _measure gives them, and not refuse them: a
# refusal keyed on test files failed the redpath's sens-per-golden case,
# which passes on origin/main (base#1547 review round 1 finding 1).
@test "coverage.sh: --profile counts a test-only package and a package with no statements as 0 0, as _measure does (base#1547)" {
  _tested_pkg m/a 1 1 0
  _tested_pkg m/zz 0 1 0
  _tested_pkg m/types 1 1 0
  printf '%s\n' 'mode: atomic' \
    'm/a/a.go:1.1,2.2 2 1' > "${S}/all.out"
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with --measure "${S}/measured" "${S}/corpus-root" --profile "${S}/all.out"
  _passed "m/a"$'\t'"2"$'\t'"2" "m/zz"$'\t'"0"$'\t'"0" "m/types"$'\t'"0"$'\t'"0"
  if grep -q '^test ' "${S}/go.calls" 2>/dev/null; then
    fail "--profile still ran go test: $(grep '^test ' "${S}/go.calls")"
  fi
}

# why: Today each package's own profile is refused when it carries a line
# from any other package (_count, base#1462): such a profile is not the
# package's. The merged profile's counterpart is a block whose file's
# directory is no package `go list ./...` names here: the profile was
# written for another tree, so its counts are not this module's (base#1547).
# Splitting would drop that block silently and count the rest. It is
# refused as profile_invalid naming the stray directory, before any count
# is written and without go test.
@test "coverage.sh: --profile refuses a block of a package go list does not name as profile_invalid (base#1547)" {
  _tested_pkg m/a 1 1 0
  printf '%s\n' 'mode: atomic' \
    'm/a/a.go:1.1,2.2 2 1' \
    'm/gone/g.go:1.1,2.2 3 1' > "${S}/all.out"
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with --measure "${S}/measured" "${S}/corpus-root" --profile "${S}/all.out"
  _refused profile_invalid m/gone
  [[ ! -e "${S}/measured" ]] || fail "a refused profile still wrote counts: $(cat "${S}/measured")"
  if grep -q '^test ' "${S}/go.calls" 2>/dev/null; then
    fail "--profile still ran go test: $(grep '^test ' "${S}/go.calls")"
  fi
}

# why: The stray-directory check keeps only the first stray directory it
# names (base#1547). Cutting that list with `| head -n 1` under pipefail
# lets head exit after one line while comm is still writing: comm dies of
# SIGPIPE, the substitution's status is 141, and errexit ends the gate with
# 141 and no refusal line, so a profile from another tree reads as a crash,
# not as profile_invalid. Enough stray directories to outrun one pipe
# buffer (64 KiB) must still be refused, naming the first in C order.
@test "coverage.sh: --profile refuses more stray directories than one pipe buffer holds as profile_invalid naming the first (base#1547)" {
  _tested_pkg m/a 1 1 0
  {
    printf '%s\n' 'mode: atomic' 'm/a/a.go:1.1,2.2 2 1'
    awk 'BEGIN { for (i = 0; i < 20000; i++) printf "m/stray%05d/g.go:1.1,2.2 1 1\n", i }'
  } > "${S}/all.out"
  printf 'm/internal/testcorpus.root=/r/testdata\n' > "${S}/corpus-root"
  _run_gate_with --measure "${S}/measured" "${S}/corpus-root" --profile "${S}/all.out"
  _refused profile_invalid m/stray00000
  [[ ! -e "${S}/measured" ]] || fail "a refused profile still wrote counts: $(cat "${S}/measured")"
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

# why: The race RUN writes the corpus root record and the coverage RUN must
# hand that root to every go test, or testcorpus.Glob fails with an empty
# root and the gate reads it as a package's test_failed. A record that never
# arrived is refused before go runs, under its own reason, so it cannot pass
# and cannot look like a later test failure (base#1468). Without the guard
# this listing reads reason=test_failed pkg=m/a.
@test "coverage.sh: a missing corpus root record is refused with reason corpus_root_missing before go runs (base#1468)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1'
  printf '1\n' > "${S}/prof/m_a.rc"
  _run_gate_with --measure "${S}/measured" "${S}/no-such-record"
  _refused corpus_root_missing ""
  [[ ! -e "${S}/go.calls" ]] || fail "go ran before the guard: $(cat "${S}/go.calls")"
}

# why: A record that exists but is empty, a record holding only a blank
# line, and no argument at all deliver no root either. Each must stop at the
# same guard as a missing file, before go runs; a check that only asks
# whether the file exists passes the first two, and under set -u an unset
# variable exits without the refusal line (base#1468). Without the guard
# this listing reads reason=test_failed pkg=m/a.
@test "coverage.sh: an empty record, a blank-line record and no argument are refused with reason corpus_root_missing before go runs (base#1468)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1'
  printf '1\n' > "${S}/prof/m_a.rc"
  : > "${S}/empty-record"
  printf '\n' > "${S}/blank-record"
  local _case
  for _case in empty blank none; do
    rm -f "${S}/go.calls"
    case "${_case}" in
      empty) _run_gate_with --measure "${S}/measured" "${S}/empty-record" ;;
      blank) _run_gate_with --measure "${S}/measured" "${S}/blank-record" ;;
      none) _run_gate_with --measure "${S}/measured" ;;
    esac
    _refused corpus_root_missing ""
    [[ ! -e "${S}/go.calls" ]] || fail "${_case}: go ran before the guard: $(cat "${S}/go.calls")"
  done
}

# why: Validating the record and then dropping it leaves every go test with
# an empty testcorpus root, which reads as test_failed in the real image. The
# validated root has to reach each package's go test as one -ldflags -X
# token (base#1468). The expected token is the record line verbatim.
@test "coverage.sh: every go test receives the corpus root record as -ldflags=-X (base#1468)" {
  _pkg m/a 1
  _profile m/a 'm/a/a.go:1.1,2.2 10 1'
  _pkg m/b 1
  _profile m/b 'm/b/b.go:1.1,2.2 10 1'
  _run_gate
  _passed
  run grep -c '^test ' "${S}/go.calls"
  assert_output 2
  run grep -c '^test \(.* \)\?-ldflags=-X=m/internal/testcorpus\.root=/r/testdata .*' "${S}/go.calls"
  assert_output 2
}
