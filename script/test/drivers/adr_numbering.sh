#!/usr/bin/env bash
# drivers/adr_numbering.sh - ADR-numbering per-tool driver for the
# self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_adr_numbering, the enforcer that keeps the ADR registry (the
# filesystem, doc/adr/NNNNNNNN-<slug>.md) duplicate-free and well-formed.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/issueref.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# The registry is the filesystem. ADR files live at
# doc/adr/NNNNNNNN-<slug>.md (8-digit zero-padded number + kebab slug).
# The lint reads doc/adr/*.md and:
#   - FAILS (non-zero) on a DUPLICATE ADR number (two files sharing
#     NNNNNNNN). This is the primary defect -- two PRs once authored the
#     same ADR number in parallel, caught only by manual inspection.
#   - FAILS (non-zero) on a MALFORMED ADR filename (not matching
#     ^[0-9]{8}-.+\.md$).
#   - WARNS (still exit 0) on a numbering GAP (a missing number in the
#     min..max run). A gap must NOT block CI -- an intentional gap exists
#     in the live tree. The gap is printed as an advisory line only.
#   - Exits 0 clean on a well-formed, duplicate-free set (gaps allowed).
# Fail-loud messages name exactly which file(s)/number(s) are wrong.

# ── ADR-numbering lint ───────────────────────────────────────────────────────

# Well-formed ADR basename: 8-digit zero-padded number, a dash, a non-empty
# slug, and the .md extension. Anything else is a malformed filename.
readonly _ADR_NAME_RE='^[0-9]{8}-.+\.md$'

_run_adr_numbering() {
  echo "--- Running ADR-numbering lint ---"
  local _adr_dir="${REPO_ROOT}/doc/adr"
  local _file _base _num
  local -a _malformed=()
  local -a _dups=()
  local -a _nums=()
  # number -> first basename that claimed it; a second claimant is a dup.
  local -A _seen=()

  local -a _files=()
  local _f
  shopt -s nullglob
  for _f in "${_adr_dir}"/*.md; do
    _files+=("${_f}")
  done
  shopt -u nullglob

  for _file in "${_files[@]}"; do
    _base="$(basename "${_file}")"
    if [[ ! "${_base}" =~ ${_ADR_NAME_RE} ]]; then
      _malformed+=("${_base}")
      continue
    fi
    _num="${_base:0:8}"
    if [[ -n "${_seen[${_num}]:-}" ]]; then
      _dups+=("${_num}: ${_seen[${_num}]} + ${_base}")
    else
      _seen["${_num}"]="${_base}"
      _nums+=("${_num}")
    fi
  done

  # Advisory: warn every missing number in the min..max run. A gap is
  # informational only -- it never contributes to the violation count.
  # Numbers are 8-digit zero-padded; 10#-prefix the arithmetic so a leading
  # zero is decimal, not octal.
  if [[ "${#_nums[@]}" -gt 0 ]]; then
    local _min _max _i _padded
    _min="$(printf '%s\n' "${_nums[@]}" | sort | head -n1)"
    _max="$(printf '%s\n' "${_nums[@]}" | sort | tail -n1)"
    for (( _i = 10#${_min}; _i <= 10#${_max}; _i++ )); do
      _padded="$(printf '%08d' "${_i}")"
      if [[ -z "${_seen[${_padded}]:-}" ]]; then
        printf 'ADR numbering: advisory: gap at %s (no doc/adr/%s-*.md)\n' \
          "${_padded}" "${_padded}"
      fi
    done
  fi

  # Failures: malformed filenames and duplicate numbers, each named.
  local _violations=0 _m _d
  for _m in "${_malformed[@]}"; do
    printf 'ADR numbering: malformed filename: doc/adr/%s (expected NNNNNNNN-<slug>.md)\n' \
      "${_m}"
    _violations=$(( _violations + 1 ))
  done
  for _d in "${_dups[@]}"; do
    printf 'ADR numbering: duplicate number %s\n' "${_d}"
    _violations=$(( _violations + 1 ))
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_adr_numbering \
      "${_violations} ADR-numbering defect(s) under doc/adr/: duplicate number(s) and/or malformed filename(s). Fix the named file(s)/number(s) (a numbering gap is advisory, not a failure)."
    return 1
  fi
  echo "ADR-numbering lint: clean"
}
