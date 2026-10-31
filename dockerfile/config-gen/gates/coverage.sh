#!/usr/bin/env bash
#
# coverage.sh -- the coverage gate of the config generator's test stage
# (base#1462). Run from the module root inside the golang image:
#
#   bash gates/coverage.sh <corpus root record>
#
# The record is the one line the race RUN wrote,
# <module>/internal/testcorpus.root=<dir> (base#1468).
#
# Every package `go list ./...` names must reach >= 90.0% of its
# statements, measured from a profile of its own. Fail-closed: every way
# the measurement can go missing is a refusal, never a pass.
#
#   corpus_root_missing  the root record is missing or empty
#   list_failed          go list exited non-zero
#   no_packages          go list listed nothing
#   test_failed          the package's go test exited non-zero
#   profile_invalid      the profile is missing, is not `mode: atomic`,
#                        carries a malformed line, or a line from any other
#                        package
#   no_statements        zero statements in a package that has source files
#   below_floor          covered * 10 < statements * 9
#
# A refusal is one line on stderr,
#   config_gen_gate_coverage_failed reason=<reason> pkg=<import path>
# nothing on stdout, and exit 1. A pass is `gate=coverage ok` on stdout.
#
# It runs inside the golang image, where lib/log.sh does not exist, so the
# refusal is a plain line; script/test/config_gen_gates.sh re-emits the id
# as a registered event.
#
# Style: Google Shell Style Guide.

set -euo pipefail

# _CG_X -- the validated corpus root record main read; _measure forwards it.
_CG_X=''

# _refuse <reason> [pkg] -- the one refusal line, then exit 1.
_refuse() {
  printf 'config_gen_gate_coverage_failed reason=%s pkg=%s\n' "${1}" "${2:-}" >&2
  exit 1
}

# _measure <dir> <index> <import path> <gofiles> <cgofiles> -- run the
# package's tests into its own atomic profile and judge it.
_measure() {
  local dir="${1}" i="${2}" pkg="${3}" gofiles="${4}" cgofiles="${5}"
  local prof="${dir}/${i}.out" verdict
  go test -covermode=atomic -coverprofile="${prof}" "-ldflags=-X=${_CG_X}" \
    "${pkg}" >&2 \
    || _refuse test_failed "${pkg}"
  [[ -f "${prof}" ]] || _refuse profile_invalid "${pkg}"
  verdict="$(_judge "${prof}" "${pkg}" "$(( gofiles + cgofiles ))")" \
    || _refuse profile_invalid "${pkg}"
  [[ "${verdict}" == ok ]] || _refuse "${verdict}" "${pkg}"
}

# _judge <profile> <import path> <source files> -- print ok, no_statements
# or below_floor; exit 1 when the profile is not a valid profile of <pkg>.
# A block a profile repeats (one per test binary that ran it) counts once,
# at its highest count. The floor is an integer comparison, so no float
# rounding moves a package across it. An empty line carries no block and
# is skipped; every other line must be a block of <pkg>.
_judge() {
  awk -v pkg="${2}" -v files="${3}" '
    BEGIN {
      prefix = pkg "/"
      body = "^[^/]+\\.go:[0-9]+\\.[0-9]+,[0-9]+\\.[0-9]+ [0-9]+ [0-9]+$"
    }
    NR == 1 { if ($0 != "mode: atomic") bad = 1; next }
    $0 == "" { next }
    {
      if (substr($0, 1, length(prefix)) != prefix) { bad = 1; next }
      if (substr($0, length(prefix) + 1) !~ body) { bad = 1; next }
      key = $1
      if (!(key in n)) { n[key] = $2 + 0; c[key] = $3 + 0 }
      else if ($3 + 0 > c[key]) c[key] = $3 + 0
    }
    END {
      if (NR == 0 || bad) exit 1
      for (k in n) { stmts += n[k]; if (c[k] > 0) cov += n[k] }
      if (stmts == 0) { print (files == 0 ? "ok" : "no_statements"); exit 0 }
      print (cov * 10 >= stmts * 9 ? "ok" : "below_floor")
    }' "${1}"
}

main() {
  local listing dir pkg gofiles cgofiles i=0 x=''
  if [[ -f "${1:-}" ]]; then IFS= read -r x <"${1}" || true; fi
  [[ -n "${x}" ]] || _refuse corpus_root_missing
  _CG_X="${x}"
  listing="$(go list -f '{{.ImportPath}}{{"\t"}}{{len .GoFiles}}{{"\t"}}{{len .CgoFiles}}' ./...)" \
    || _refuse list_failed
  [[ -n "${listing}" ]] || _refuse no_packages
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${dir} now; it is local to main
  trap "rm -rf '${dir}'" EXIT
  while IFS=$'\t' read -r pkg gofiles cgofiles; do
    [[ -n "${pkg}" ]] || continue
    i=$(( i + 1 ))
    _measure "${dir}" "${i}" "${pkg}" "${gofiles}" "${cgofiles}"
  done <<<"${listing}"
  echo 'gate=coverage ok'
}

main "$@"
