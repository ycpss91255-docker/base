#!/usr/bin/env bash
#
# resolve-doc-counts.sh - resolve a doc/test/*.md merge conflict in ONE
# command: collapse the conflict markers, regenerate the derived figures
# authoritatively, verify, stage.
#
# Usage:
#   ./script/test/resolve-doc-counts.sh            # repo root via git
#   ./script/test/resolve-doc-counts.sh <ABS root> # explicit, ABSOLUTE
#
# Exit status: 0 = resolved (or nothing to resolve, and the tree verifies);
# 1 = refused, with the reason on stderr. Nothing is staged on a refusal.
#
# Why this exists
# ---------------
# Every merge of main into a queued branch conflicts on doc/test/TEST.md and
# doc/test/unit.md, because both sides bumped the same generated counters. The
# resolution never needs judgement -- collapse to either side, then regenerate
# -- yet it was retyped by hand six times in a single review batch and pasted
# verbatim into every dispatched agent prompt, awk one-liner included.
#
# Why it is not just the awk one-liner
# ------------------------------------
# A mechanical collapse adopts whichever side it keeps, INCLUDING for content
# the generator does not derive. That already bit this repo: the "System (N)
# and smoke (N)" prose in TEST.md was hand-maintained, and a collapse silently
# carried the stale side through three times before the generator learned to
# regenerate it.
#
# So this script never trusts one side. It regenerates BOTH collapses and
# then compares them. Any remaining difference is, by construction, content
# the generator does not own -- and it is refused with the diff rather than
# picked. That check is what keeps this script honest as the generator grows:
# it does not carry a list of "figures that are generated" to fall out of
# date, it simply refuses to adopt anything regeneration cannot justify.
#
# What USED to need more than that was the per-test description: the row
# names were generated and the descriptions were hand-written prose the
# generator preserved but could not re-derive, so a collapse could drop a
# sentence nothing would put back, and this script had to reconcile the two
# sides row by row. Descriptions are now authored in the spec files and
# rendered from there, so both sides of a merge regenerate them from the same
# merged spec tree and there is nothing left to reconcile. The reconciliation
# is deleted rather than kept "in case": code that reads prose out of the
# catalogue is exactly the direction the catalogue no longer flows.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_RESOLVE_DOC_COUNTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# The read-only twin sources the generator, so this one source gives both
# _sync_doc_counts (regenerate) and _check_test_md_drift (verify), plus the
# catalog-row primitives -- no third copy of the parsing rules.
# shellcheck source=script/test/check_test_md_drift.sh
source "${_RESOLVE_DOC_COUNTS_DIR}/check_test_md_drift.sh"

# Conflict-marker line shapes, as git writes them: the two-way pair, the
# diff3 base section, and the separator.
_RESOLVE_MARKER_RE='^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)([[:space:]]|$)'
_RESOLVE_SEP_RE='^=======$'

# _resolve_err <message> -- diagnostic to stderr. Block-redirected rather than
# a bare `printf ... >&2`: this is a standalone, log.sh-free CI tool (same
# rationale class as check_test_md_drift.sh) and the bare-stderr lint scans
# script/test/.
_resolve_err() {
  {
    printf 'resolve-doc-counts: %s\n' "$1"
  } >&2
}

# _resolve_doc_counts_root <root> -- print <root> unchanged after checking it
# is absolute and exists; fail naming it otherwise.
#
# A relative root is REFUSED rather than resolved. The reconciliation below
# copies doc/test into two temp dirs and symlinks the spec trees in from
# <root>: a relative target is recorded relative to the TEMP dir, every spec
# glob then misses, every count comes back 0 -- and 0 == 0 on both sides
# reconciles perfectly. The failure mode of guessing here is a confidently
# resolved, entirely wrong tree, so the caller is told to be explicit.
_resolve_doc_counts_root() {
  local _root="${1:-}"
  if [[ "${_root}" != /* ]]; then
    _resolve_err "scan root '${_root}' is relative -- pass an ABSOLUTE path. The spec trees are symlinked into a temp dir here, so a relative root resolves against that temp dir and every count silently becomes 0."
    return 1
  fi
  if [[ ! -d "${_root}" ]]; then
    _resolve_err "scan root '${_root}' does not exist or is not a directory."
    return 1
  fi
  printf '%s\n' "${_root}"
}

# _resolve_conflicted_docs <root> -- the GENERATED files that still carry
# conflict markers, one per line.
#
# The file set is the generator's own answer (`_sync_doc_counts_outputs`)
# and not a `doc/test/*.md` glob written down here. That glob was right
# until the generator grew a fourth output outside doc/test -- the
# description lint's ceiling, base#1024 -- and a resolver carrying its own
# copy of "what is generated" would have gone on refusing the one file
# whose conflicts it was best placed to settle.
_resolve_conflicted_docs() {
  local _root="$1" _doc
  while IFS= read -r _doc; do
    [[ -f "${_doc}" ]] || continue
    if grep -qE -e "${_RESOLVE_MARKER_RE}" -e "${_RESOLVE_SEP_RE}" "${_doc}"; then
      printf '%s\n' "${_doc}"
    fi
  done < <(_sync_doc_counts_outputs "${_root}")
}

# _resolve_assert_no_markers <root> -- fail, naming file and line, if any
# generated file still carries a conflict marker. Post-condition check: the
# collapse is meant to be total, and a survivor means it was not.
_resolve_assert_no_markers() {
  local _root="$1" _doc _hits _rel _hit _rc=0
  while IFS= read -r _doc; do
    [[ -f "${_doc}" ]] || continue
    _hits="$(grep -nE -e "${_RESOLVE_MARKER_RE}" -e "${_RESOLVE_SEP_RE}" \
      "${_doc}" || true)"
    [[ -n "${_hits}" ]] || continue
    _rel="${_doc#"${_root}"/}"
    while IFS= read -r _hit; do
      _resolve_err "conflict marker survived at ${_rel}:${_hit%%:*}"
    done <<< "${_hits}"
    _rc=1
  done < <(_sync_doc_counts_outputs "${_root}")
  return "${_rc}"
}

# _resolve_collapse <file> <ours|theirs> -- <file> with the conflict regions
# reduced to the named side, on stdout. The diff3 base section is dropped
# whichever side is kept.
_resolve_collapse() {
  local _file="$1" _side="$2"
  awk -v side="${_side}" '
    /^<<<<<<<([ \t]|$)/ { state = 1; next }
    /^\|\|\|\|\|\|\|([ \t]|$)/ { state = 2; next }
    /^=======$/ { state = 3; next }
    /^>>>>>>>([ \t]|$)/ { state = 0; next }
    {
      if (state == 0 \
          || (state == 1 && side == "ours") \
          || (state == 3 && side == "theirs")) {
        print
      }
    }
  ' "${_file}"
}

# _resolve_build_side <root> <dest> <side> <conflicted>... -- a scratch tree
# holding every generated file with the conflicted ones collapsed to <side>,
# and the spec trees symlinked in so the generator's globs resolve.
#
# Every output is copied at its ROOT-RELATIVE path rather than into one flat
# directory: the set is no longer doc/test-shaped, and a file placed
# anywhere but where the generator expects it is a file the regeneration
# below silently declines to write.
_resolve_build_side() {
  local _root="$1" _dest="$2" _side="$3"
  shift 3
  mkdir -p "${_dest}/doc"
  cp -R "${_root}/doc/test" "${_dest}/doc/test"
  ln -s "${_root}/test" "${_dest}/test"
  [[ -d "${_root}/dist" ]] && ln -s "${_root}/dist" "${_dest}/dist"
  local _out _rel
  while IFS= read -r _out; do
    case "${_out}" in
      "${_root}/doc/test/"*) continue ;;
    esac
    _rel="${_out#"${_root}"/}"
    mkdir -p "${_dest}/$(dirname -- "${_rel}")"
    cp -- "${_out}" "${_dest}/${_rel}"
  done < <(_sync_doc_counts_outputs "${_root}")
  local _doc
  for _doc in "$@"; do
    _rel="${_doc#"${_root}"/}"
    mkdir -p "${_dest}/$(dirname -- "${_rel}")"
    _resolve_collapse "${_doc}" "${_side}" > "${_dest}/${_rel}"
  done
  return 0
}

# _resolve_doc_counts [root] -- the whole flow. See the file header for the
# reconciliation contract.
_resolve_doc_counts() {
  local _root
  _root="$(_resolve_doc_counts_root "${1:-}")" || return 1

  if [[ ! -d "${_root}/doc/test" ]]; then
    _resolve_err "no doc/test/ under scan root ${_root} -- nothing to resolve."
    return 1
  fi

  local -a _conflicted=()
  mapfile -t _conflicted < <(_resolve_conflicted_docs "${_root}")

  if (( ${#_conflicted[@]} == 0 )); then
    printf 'resolve-doc-counts: no conflicted generated file under %s -- verifying the tree anyway.\n' \
      "${_root}"
    _check_test_md_drift "${_root}" || return 1
    printf 'resolve-doc-counts: doc/test counts are in sync under %s\n' \
      "${_root}/doc/test"
    return 0
  fi

  local _doc
  for _doc in "${_conflicted[@]}"; do
    printf 'resolve-doc-counts: conflicted %s\n' "${_doc#"${_root}"/}"
  done

  local _ours _theirs _rc=0
  _ours="$(mktemp -d)" || return 1
  if ! _theirs="$(mktemp -d)"; then
    rm -rf "${_ours}"
    return 1
  fi

  _resolve_reconcile "${_root}" "${_ours}" "${_theirs}" "${_conflicted[@]}" \
    || _rc=1
  rm -rf "${_ours}" "${_theirs}"
  (( _rc == 0 )) || return 1

  _resolve_assert_no_markers "${_root}" || return 1

  if ! _check_test_md_drift "${_root}"; then
    _resolve_err "the drift gate is unhappy after regeneration -- the tree was rewritten but NOTHING was staged. Fix the reported drift, then re-run."
    return 1
  fi

  _resolve_stage "${_root}" "${_conflicted[@]}" || return 1
  printf 'resolve-doc-counts: resolved %s generated file(s) under %s\n' \
    "${#_conflicted[@]}" "${_root}"
}

# _resolve_reconcile <root> <ours-dir> <theirs-dir> <conflicted>... -- build
# both collapses, regenerate both, reconcile, and write the result back into
# <root>/doc/test. Split out of _resolve_doc_counts so the scratch dirs get
# cleaned up on every exit path.
_resolve_reconcile() {
  local _root="$1" _ours="$2" _theirs="$3"
  shift 3
  local -a _conflicted=( "$@" )

  _resolve_build_side "${_root}" "${_ours}" ours "${_conflicted[@]}" || return 1
  _resolve_build_side "${_root}" "${_theirs}" theirs "${_conflicted[@]}" \
    || return 1
  _sync_doc_counts "${_ours}" >/dev/null || return 1
  _sync_doc_counts "${_theirs}" >/dev/null || return 1

  local _out _rel _diff _extra
  if ! _diff="$(diff -ru "${_ours}/doc/test" "${_theirs}/doc/test" 2>/dev/null)"; then
    {
      printf 'resolve-doc-counts: the two sides do not agree on content the generator does not derive, so no collapse can be justified by regeneration. Resolve these by hand:\n'
      printf '%s\n' "${_diff}"
    } >&2
    return 1
  fi
  # The outputs outside doc/test, compared one by one. `diff -ru` over the
  # scratch ROOTS is not an option: the spec trees are symlinked in, so it
  # would walk the whole suite twice to prove two symlinks point at one
  # directory.
  while IFS= read -r _out; do
    case "${_out}" in
      "${_root}/doc/test/"*) continue ;;
    esac
    _rel="${_out#"${_root}"/}"
    if ! _extra="$(diff -u "${_ours}/${_rel}" "${_theirs}/${_rel}" 2>/dev/null)"; then
      {
        printf 'resolve-doc-counts: the two sides of %s do not agree on content the generator does not derive, so no collapse can be justified by regeneration. Resolve it by hand:\n' \
          "${_rel}"
        printf '%s\n' "${_extra}"
      } >&2
      return 1
    fi
  done < <(_sync_doc_counts_outputs "${_root}")

  while IFS= read -r _out; do
    _rel="${_out#"${_root}"/}"
    cp -- "${_theirs}/${_rel}" "${_root}/${_rel}"
  done < <(_sync_doc_counts_outputs "${_root}")
}

# _resolve_stage <root> <file>... -- mark the resolved files merged, so the
# merge can be committed without a second manual `git add`. A non-git root
# (a fixture tree) is simply left alone.
_resolve_stage() {
  local _root="$1"
  shift
  git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local _doc
  for _doc in "$@"; do
    git -C "${_root}" add -- "${_doc}" || return 1
  done
}

main() {
  local _root="${1:-}"
  if [[ -z "${_root}" ]]; then
    _root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  fi
  _resolve_doc_counts "${_root}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
