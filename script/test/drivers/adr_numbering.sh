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
# doc/adr/README.md (the ADR index / PRD audit) is the one conventional
# non-ADR file in the registry dir and is exempt from the naming contract.
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

# ── The pointers into the registry (base#1021) ──────────────────────────
#
# A registry nothing points at is half a registry, and the half this lint
# used to read was the filesystem alone. What that missed: nothing
# allocates an ADR number, so three branches took 00000030 on one day,
# each of them right by the only rule there is. The duplicate reached this
# lint. The REPAIR did not: renumbering one of them touched 14 files, and
# three of the sites were left naming the old number -- the index row, and
# two of the audit conclusions -- with every gate green, because a stale
# number in prose is read by nothing.
#
# Three checks, and what each catches:
#
#   dangling    `ADR-NNNNNNNN` naming a number no record claims. What a
#               renumber leaves behind once the old number is free.
#   mispaired   a `doc/adr/NNNNNNNN-<slug>.md` path that names no file.
#               The number may still resolve -- another record took it --
#               and the slug beside it is what says the pointer no longer
#               names what its author meant.
#   index       doc/adr/README.md's audit table: exactly one row per
#               record, no row without a record. The site the hand
#               renumber actually missed, twice.
#
# WHAT IS NOT CHECKED, said out loud because the gap is the interesting
# part. A prose `ADR-NNNNNNNN` whose number EXISTS but names a different
# record than its author meant is indistinguishable, in a checkout, from a
# correct one: the number resolves, and only the author knew which record
# they had in mind. That is precisely what a missed reference looks like
# after a collision is repaired by renumbering one of two claimants -- and
# it is an argument for renumbering ON THE BRANCH, where the number has
# one claimant and the rewrite is mechanical (script/adr/renumber.sh), not
# for a lint that guesses.
#
# Non-canonical spellings (`ADR-3`, `ADR-0011`, both live in this tree)
# are not references for this purpose. Eight digits is the filename
# contract; widening the pattern to shapes the registry never uses would
# trade precision for guesswork.
#
# The index checks run only where doc/adr/README.md carries the audit
# table's HEADER. A README without one is not an index, which is the
# fixture case and also the honest reading -- and the residue is stated
# rather than hidden: deleting the table disables the check. That is a
# whole document's spine going missing in a diff, where a single missed
# row is invisible, and the invisible one is what this is for.

# ── ADR-numbering lint ───────────────────────────────────────────────────────

# Which files can carry a reference. Shared with script/adr/renumber.sh,
# the verb that rewrites them, because a lint whose population is wider
# than the verb's fails on files no documented command can repair -- see
# that file's header for the two the disagreement actually produced.
_ADR_NUMBERING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=script/adr/references.sh
source "${_ADR_NUMBERING_DIR}/../../adr/references.sh"

# Well-formed ADR basename: 8-digit zero-padded number, a dash, a non-empty
# slug, and the .md extension. Anything else is a malformed filename.
readonly _ADR_NAME_RE='^[0-9]{8}-.+\.md$'

# The reference vocabulary. The token form is the common one; the path
# form is the one that carries a slug.
readonly _ADR_TOKEN_SCAN_RE='ADR-[0-9]{8}'
# Up to two leading characters are captured so a path built on a shell
# EXPANSION can be told apart from one rooted in this tree: leftmost-match
# makes `"${SCRATCH}/doc/adr/..."` come back as `}/doc/adr/...`, and a
# path whose root is a variable is a registry some test builds, not this
# one. Without that distinction every lint spec's throwaway fixture would
# be a finding here. TWO characters and not one because the brace is
# separated from the path by its slash.
#
# The residue: an expansion written without braces (`"$SCRATCH/doc/..."`)
# is not recognised and would be read as a reference. This tree's style
# requires the braces, so the shape has no instances -- and widening the
# lookback until it did would start swallowing real references.
readonly _ADR_PATH_SCAN_RE='.{0,2}doc/adr/[0-9]{8}-[A-Za-z0-9._-]+\.md'
# The audit table: its header marks the document as the index, and a row
# opens with the number of the record it is about.
readonly _ADR_INDEX_HEADER_RE='^\| ADR \| Verdict \|'
readonly _ADR_INDEX_ROW_RE='^\| ([0-9]{8}) '

# _adr_scan <root> <regexp> -- `<relpath>:<line>:<match>` for every match
# under <root>, one per line.
#
# The population is `_adr_ref_files` and not a recursive grep: the verb
# that repairs these findings sweeps exactly that set, and a lint that
# read more would fail on files the verb cannot reach.
_adr_scan() {
  local _root="$1" _re="$2" _rel
  local -a _files=()
  while IFS= read -r _rel; do
    _files+=( "${_rel}" )
  done < <(_adr_ref_files "${_root}")
  (( ${#_files[@]} > 0 )) || return 0
  (
    cd -- "${_root}" || exit 0
    grep -HnIo -E -e "${_re}" -- "${_files[@]}" 2>/dev/null || true
  )
}

# _adr_ref_findings <root> <claimed-number>... -- one line per reference
# that names no record: a dangling `ADR-NNNNNNNN`, or a `doc/adr/` path
# whose number and slug are not a file.
#
# `<relpath>:<line>:<match>` is split on the LAST colon, which is exact
# rather than approximate: neither reference form can contain one.
_adr_ref_findings() {
  local _root="$1"
  shift
  local -A _known=()
  local _n
  for _n in "$@"; do
    _known["${_n}"]=1
  done
  local _hit _loc _match _num _path
  while IFS= read -r _hit; do
    _match="${_hit##*:}"
    _loc="${_hit%:*}"
    _num="${_match#ADR-}"
    [[ -z "${_known[${_num}]:-}" ]] || continue
    printf 'ADR numbering: %s: reference to ADR-%s, which no record claims (there is no doc/adr/%s-*.md).\n' \
      "${_loc}" "${_num}" "${_num}"
  done < <(_adr_scan "${_root}" "${_ADR_TOKEN_SCAN_RE}")
  while IFS= read -r _hit; do
    _match="${_hit##*:}"
    _loc="${_hit%:*}"
    # A path whose root is a shell expansion is a registry some test
    # builds, not this one -- see the header. The brace can only be in the
    # captured lookback: a record's path cannot contain one.
    [[ "${_match}" != *'}'* ]] || continue
    _path="doc/adr/${_match#*doc/adr/}"
    [[ ! -f "${_root}/${_path}" ]] || continue
    printf 'ADR numbering: %s: reference to %s, which is not a record in this tree (renumbered, renamed, or a typo).\n' \
      "${_loc}" "${_path}"
  done < <(_adr_scan "${_root}" "${_ADR_PATH_SCAN_RE}")
}

# _adr_index_findings <root> <claimed-number>... -- one line per
# disagreement between doc/adr/README.md's audit table and the records.
#
# Runs only where the table's header is there to read: a README without
# one is not an index. Row order is not checked -- the table is sorted by
# hand and a renumber does not make it wrong, only unsorted.
_adr_index_findings() {
  local _root="$1"
  shift
  local _readme="${_root}/doc/adr/README.md"
  [[ -f "${_readme}" ]] || return 0
  grep -qE -e "${_ADR_INDEX_HEADER_RE}" "${_readme}" || return 0

  local -A _rows=()
  local _line _num
  while IFS= read -r _line; do
    [[ "${_line}" =~ ${_ADR_INDEX_ROW_RE} ]] || continue
    _num="${BASH_REMATCH[1]}"
    if [[ -n "${_rows[${_num}]:-}" ]]; then
      printf 'ADR numbering: doc/adr/README.md: %s opens more than one index row; a record has exactly one.\n' \
        "${_num}"
      continue
    fi
    _rows["${_num}"]=1
  done < "${_readme}"

  local -A _known=()
  for _num in "$@"; do
    _known["${_num}"]=1
    [[ -z "${_rows[${_num}]:-}" ]] || continue
    printf 'ADR numbering: doc/adr/README.md carries no index row for %s; every record is named there exactly once.\n' \
      "${_num}"
  done
  # Sorted: an associative array's key order is a hash order, and a
  # findings list that reorders between runs is a diff nobody can read.
  local -a _row_nums=()
  mapfile -t _row_nums < <(printf '%s\n' "${!_rows[@]}" | LC_ALL=C sort)
  for _num in "${_row_nums[@]+"${_row_nums[@]}"}"; do
    [[ -z "${_known[${_num}]:-}" ]] || continue
    printf 'ADR numbering: doc/adr/README.md: index row for %s, which no record claims.\n' \
      "${_num}"
  done
}

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
    # README.md is the ADR index / PRD audit (doc/adr/README.md), not an
    # ADR record. It is the conventional non-ADR file in the registry dir,
    # so it is deliberately exempt from the NNNNNNNN-<slug>.md contract.
    if [[ "${_base}" == "README.md" ]]; then
      continue
    fi
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
  #
  # The min/max scan is in-shell on purpose. It used to be
  # `printf '%s\n' "${_nums[@]}" | sort | head -n1`: `head` closes the
  # pipe the moment it has its line, so a `sort` that has not written yet
  # takes SIGPIPE and dies 141, `pipefail` promotes that to the pipeline's
  # status, and the bare assignment under `set -e` killed the entire lint
  # phase with no message -- failing the local-CI stamp rather than any
  # test. Nothing below can be killed by a reader that stopped reading,
  # because there is no reader: no pipe, no subprocess, no exit status
  # that depends on how two processes were scheduled.
  if [[ "${#_nums[@]}" -gt 0 ]]; then
    local _min _max _i _padded _n
    _min="${_nums[0]}"
    _max="${_nums[0]}"
    for _n in "${_nums[@]}"; do
      if (( 10#${_n} < 10#${_min} )); then _min="${_n}"; fi
      if (( 10#${_n} > 10#${_max} )); then _max="${_n}"; fi
    done
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

  # The pointers. Run after the registry itself has been read, because
  # every one of these questions is asked against the set of numbers the
  # filesystem actually claims.
  local -a _ref_findings=()
  local _finding
  mapfile -t _ref_findings < <(
    _adr_ref_findings "${REPO_ROOT}" "${_nums[@]+"${_nums[@]}"}"
    _adr_index_findings "${REPO_ROOT}" "${_nums[@]+"${_nums[@]}"}"
  )
  for _finding in "${_ref_findings[@]+"${_ref_findings[@]}"}"; do
    printf '%s\n' "${_finding}"
    _violations=$(( _violations + 1 ))
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_adr_numbering \
      "${_violations} ADR-numbering defect(s): duplicate number(s), malformed filename(s), and/or references that name no record. Fix the named file(s)/number(s) (a numbering gap is advisory, not a failure). To move a record and every reference to it in one step, use 'just adr renumber <record> <number>' rather than a hand sweep -- a reference missed by hand is a reference no gate reads."
    return 1
  fi
  echo "ADR-numbering lint: clean"
}
