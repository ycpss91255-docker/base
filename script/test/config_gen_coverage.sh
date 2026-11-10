#!/usr/bin/env bash
#
# config_gen_coverage.sh -- the coverage gate of the config generator's
# test stage (base#1462). config_gen_steps/01-admit.sh installs it as
# coverage.sh in the mutation context, so it lives outside the module the
# mutation gate maps (base#1467); the coverage RUN runs it from the module
# root inside the golang image:
#
#   bash /mutation/coverage.sh --measure <file> <corpus root record> \
#     [--profile <merged profile>]
#
# The record is the one line the race RUN wrote,
# <module>/internal/testcorpus.root=<dir> (base#1468).
#
# Every package `go list ./...` names is tested into a profile of its own,
# and one line per package, `<import path>\t<statements>\t<covered>`, is
# written to <file> (a package with no statements is `<pkg>\t0\t0`).
# With --profile, no go test runs: the one merged atomic profile the race
# RUN wrote is split per listed package, a block going to the package whose
# import path equals its file's directory, and each part is counted the
# same way; a package with no block (no statements) is `<pkg>\t0\t0`, as
# its own profile would give (base#1547).
# The gate judges no floor: cmd/cg-gates ratchet reads <file> and judges each
# package against coverage-floors.d and floors.base (base#1465).
# Fail-closed: every way the measurement can go missing is a refusal,
# never a count.
#
#   usage                --measure <file> was not given
#   corpus_root_missing  the root record is missing or empty
#   list_failed          go list exited non-zero
#   no_packages          go list listed nothing
#   test_failed          the package's go test exited non-zero
#   profile_invalid      the profile is missing, is not `mode: atomic`,
#                        carries a malformed line, or a line from any other
#                        package; a merged profile carries a second mode
#                        line or a block of a directory go list does not
#                        name
#
# A refusal is one line on stderr,
#   config_gen_gate_coverage_failed reason=<reason> pkg=<import path>
# nothing on stdout, and exit 1. A measurement writes <file>, prints
# nothing and exits 0.
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

# _measure <dir> <index> <import path> -- run the package's tests into its
# own atomic profile and append `<pkg>\t<stmts>\t<covered>` to
# <dir>/measured.
_measure() {
  local dir="${1}" i="${2}" pkg="${3}" prof="${1}/${2}.out" counts
  go test -covermode=atomic -coverprofile="${prof}" "-ldflags=-X=${_CG_X}" \
    "${pkg}" >&2 \
    || _refuse test_failed "${pkg}"
  [[ -f "${prof}" ]] || _refuse profile_invalid "${pkg}"
  counts="$(_count "${prof}" "${pkg}")" || _refuse profile_invalid "${pkg}"
  printf '%s\t%s\n' "${pkg}" "${counts}" >> "${dir}/measured"
}

# _block_dirs <merged profile> -- the directory of each block's file, one
# per line, sorted and unique: the import paths the profile holds blocks
# of.
_block_dirs() {
  awk 'NR > 1 && $0 != "" { d = $0; sub(/:.*/, "", d); sub(/\/[^\/]*$/, "", d); print d }' \
    "${1}" | LC_ALL=C sort -u
}

# _split <dir> <index> <import path> <merged profile> -- write the merged
# profile's header and the blocks whose file's directory is exactly <pkg>
# to <dir>/<index>.out, then count it as _measure does. A package with no
# block is a package with no statements (a test-only package, or types
# alone): go test writes only the header for it, so _measure counts it
# 0 0, and so does this (base#1547).
_split() {
  local dir="${1}" i="${2}" pkg="${3}" prof="${1}/${2}.out" counts
  awk -v pkg="${pkg}" '
    NR == 1 { print; next }
    {
      d = $0
      sub(/:.*/, "", d)
      sub(/\/[^\/]*$/, "", d)
      if (d == pkg) print
    }' "${4}" > "${prof}"
  counts="$(_count "${prof}" "${pkg}")" || _refuse profile_invalid "${pkg}"
  printf '%s\t%s\n' "${pkg}" "${counts}" >> "${dir}/measured"
}

# _count <profile> <import path> -- print `<stmts>\t<covered>`; exit 1 when
# the profile is not a valid profile of <pkg>.
# A block a profile repeats (one per test binary that ran it) counts once,
# at its highest count. An empty line carries no block and is skipped;
# every other line must be a block of <pkg>.
_count() {
  awk -v pkg="${2}" '
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
      printf "%d\t%d\n", stmts, cov
    }' "${1}"
}

main() {
  local listing dir pkg out="" x='' i=0 merged=''
  if [[ "${1:-}" != --measure || -z "${2:-}" ]]; then
    _refuse usage
  fi
  out="${2}"
  shift 2
  if [[ -f "${1:-}" ]]; then IFS= read -r x <"${1}" || true; fi
  [[ -n "${x}" ]] || _refuse corpus_root_missing
  _CG_X="${x}"
  if [[ "${2:-}" == --profile ]]; then
    [[ -f "${3:-}" ]] || _refuse profile_invalid
    # One `mode: atomic` header and no other mode line (base#1547): _split
    # keeps only line 1 as the header, so a second one would be dropped.
    awk 'NR == 1 && $0 == "mode: atomic" { next } /^mode:/ { bad = 1 }
      END { exit (NR == 0 || bad) }' "${3}" || _refuse profile_invalid
    merged="${3}"
  fi
  listing="$(go list -f '{{.ImportPath}}' ./...)" || _refuse list_failed
  [[ -n "${listing}" ]] || _refuse no_packages
  # A block of a directory go list does not name is from another tree,
  # the merged counterpart of the line from another package _count
  # refuses in a package's own profile (base#1547).
  if [[ -n "${merged}" ]]; then
    pkg="$(LC_ALL=C comm -23 <(_block_dirs "${merged}") <(cut -f1 <<<"${listing}" | LC_ALL=C sort -u))"
    [[ -z "${pkg}" ]] || _refuse profile_invalid "${pkg%%$'\n'*}"
  fi
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${dir} now; it is local to main
  trap "rm -rf '${dir}'" EXIT
  : > "${dir}/measured"
  while IFS=$'\t' read -r pkg _; do
    [[ -n "${pkg}" ]] || continue
    i=$(( i + 1 ))
    if [[ -n "${merged}" ]]; then
      _split "${dir}" "${i}" "${pkg}" "${merged}"
    else
      _measure "${dir}" "${i}" "${pkg}"
    fi
  done <<<"${listing}"
  cp "${dir}/measured" "${out}"
}

main "$@"
