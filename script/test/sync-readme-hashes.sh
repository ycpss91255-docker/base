#!/usr/bin/env bash
#
# sync-readme-hashes.sh - stamp every localized README section with the hash
# of the English section it was translated against, so a later English-side
# edit is detectable per SECTION instead of being silently absorbed.
#
# The English author changes nothing. The translator never types a hash:
# after updating a translation they run this generator and it computes the
# current English hash and writes it. Same model as the sibling
# sync-doc-counts.sh (derived figures are generated, not hand-maintained);
# drivers/readme_sync.sh is the read-only validating twin, the way
# check_test_md_drift.sh is for the doc counts.
#
# Usage:
#   ./script/test/sync-readme-hashes.sh          # stamp REPO_ROOT
#   ./script/test/sync-readme-hashes.sh <root>   # stamp <root>
#
# Idempotent: stamping an already-stamped tree rewrites the same bytes.
#
# ── The marker ───────────────────────────────────────────────────────────────
#
# A translated section carries, on the line immediately above its heading:
#
#   <!-- sync: <section-id> <hash> -->
#   ## <translated heading>
#
# HTML comments do not render, so a reader sees nothing. A translator writes
# the id-only form `<!-- sync: <section-id> -->` once, by hand, and this
# generator fills in (and thereafter re-stamps) the hash.
#
# A section that deliberately has NO translation is declared instead, once,
# anywhere in the file:
#
#   <!-- sync-skip: <section-id> -- <why> -->
#
# The three localized READMEs are abridged by design -- they do not carry
# every English section -- so "no marker" cannot mean "fine": an omission has
# to be either translated or declared. The generator never invents that
# decision (it would silence exactly the drift the guard exists to catch); it
# reports the unclaimed sections and leaves the choice to a human.
#
# Both marker forms must start at column 0 on a line of their own.
#
# ── Section identity ─────────────────────────────────────────────────────────
#
# The heading text differs per language, so the identity cannot be the
# heading. `<section-id>` is the GitHub anchor slug of the ENGLISH heading:
# lowercased, every character outside [a-z0-9 _-] dropped, each remaining
# space turned into a hyphen, leading/trailing hyphens trimmed. That is the
# same string README.md's own table of contents links to, so the id is
# already a published, human-checkable name -- "field-deployment-just-docker
# -setup-deploy", not an opaque number. Renaming an English heading changes
# its id: the guard then reports the stale id as UNKNOWN and the new one as
# MISSING, which is the correct outcome (a heading rename is a
# translation-affecting change).
#
# ── What exactly is hashed ───────────────────────────────────────────────────
#
# For an English section, the hash input is, in order:
#
#   1. the section's heading line, verbatim, with trailing whitespace removed;
#   2. the section's body -- every line after the heading up to (not
#      including) the next ATX heading of ANY level -- each line with
#      trailing whitespace removed, with leading and trailing blank lines
#      dropped.
#
# Those lines are joined with LF and terminated with a single LF. The hash is
# the first 12 hex characters of the SHA-256 of that byte string.
#
# Deliberate consequences, stated rather than discovered later:
#   - a nested subsection is its own section; a parent's body stops at it, so
#     drift is reported at the sub-heading that actually changed;
#   - reflowing a paragraph or fixing a typo DOES change the hash (an English
#     edit marks the translations stale; the translator confirms and re-runs
#     this generator -- one command, an accepted cost);
#   - trailing whitespace and the blank lines that pad a section do NOT change
#     it, so a whitespace-only sweep does not mark three files stale;
#   - lines inside fenced code blocks (``` / ~~~) are never headings, so the
#     shell comments in the README's fenced examples do not invent sections.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# The English source, the translation directory and the translation glob, all
# repo-root-relative. The glob (rather than a fixed list) means a fourth
# language file is guarded the day it is added, with no edit here.
readonly _README_SYNC_SOURCE_REL='README.md'
readonly _README_SYNC_DIR_REL='doc/readme'
readonly _README_SYNC_GLOB='README.*.md'

# Hex characters of the SHA-256 kept in the marker. 12 is short enough to
# read in a diff and long enough that a collision is not a practical concern
# for a few dozen sections.
readonly _README_SYNC_HASH_LEN=12

# Marker grammar. Both anchor at column 0 and consume the whole line; the
# hash group is optional so a translator can write the id-only form and let
# the generator stamp it.
readonly _README_SYNC_MARKER_RE='^<!--[[:space:]]+sync:[[:space:]]+([A-Za-z0-9._-]+)([[:space:]]+([0-9a-f]+))?[[:space:]]*-->$'
readonly _README_SYNC_SKIP_RE='^<!--[[:space:]]+sync-skip:[[:space:]]+([A-Za-z0-9._-]+)([[:space:]]+--[[:space:]]+.*)?-->$'

# An ATX heading outside a fenced block: 1-6 hashes, a space, a non-empty
# title. Used for both the English index and the "a marker sits above a
# heading" check.
readonly _README_SYNC_HEADING_RE='^(#{1,6})[[:space:]]+(.*[^[:space:]])[[:space:]]*$'
readonly _README_SYNC_FENCE_RE='^[[:space:]]*(```|~~~)'

# _readme_sync_err <message>... -- diagnostic to stderr. Block-redirected
# rather than a bare `printf ... >&2` because this is a standalone,
# log.sh-free CI tool inside lint_bare_stderr.sh's scan scope (same rationale
# class as check_test_md_drift.sh).
_readme_sync_err() {
  {
    printf 'sync-readme-hashes: %s\n' "$@"
  } >&2
}

# _readme_slug <heading-text> -- the GitHub anchor slug of an English heading.
_readme_slug() {
  local _slug="${1,,}"
  _slug="${_slug//[^a-z0-9 _-]/}"
  _slug="${_slug// /-}"
  while [[ "${_slug}" == -* ]]; do _slug="${_slug#-}"; done
  while [[ "${_slug}" == *- ]]; do _slug="${_slug%-}"; done
  printf '%s\n' "${_slug}"
}

# _readme_index <file> -- emit "<slug><TAB><hash>" for every section of an
# English-side markdown file, in document order. Duplicate slugs are emitted
# as-is; detecting the ambiguity is the caller's job (the generator has
# nothing useful to do about it, the lint reports it).
_readme_index() {
  local _file="$1"
  local -a _lines=()
  mapfile -t _lines < "${_file}"

  # extglob for the `%%+([[:space:]])` right-trim (no subshell per line);
  # saved/restored so sourcing this lib never leaks the option to a caller,
  # the same idiom sync-doc-counts.sh uses for globstar.
  local _extglob_was_set=0
  shopt -q extglob && _extglob_was_set=1
  shopt -s extglob

  local _n="${#_lines[@]}"
  local -a _hidx=() _hslug=()
  local _i _fence=0
  for (( _i = 0; _i < _n; _i++ )); do
    if [[ "${_lines[_i]}" =~ ${_README_SYNC_FENCE_RE} ]]; then
      _fence=$(( 1 - _fence ))
      continue
    fi
    [[ "${_fence}" -eq 1 ]] && continue
    if [[ "${_lines[_i]}" =~ ${_README_SYNC_HEADING_RE} ]]; then
      _hidx+=( "${_i}" )
      _hslug+=( "$(_readme_slug "${BASH_REMATCH[2]}")" )
    fi
  done

  local _j _k _end _head _hash
  local -a _body=()
  for (( _j = 0; _j < ${#_hidx[@]}; _j++ )); do
    if (( _j + 1 < ${#_hidx[@]} )); then
      _end=$(( ${_hidx[_j+1]} - 1 ))
    else
      _end=$(( _n - 1 ))
    fi
    _head="${_lines[${_hidx[_j]}]%%+([[:space:]])}"
    _body=()
    for (( _k = ${_hidx[_j]} + 1; _k <= _end; _k++ )); do
      _body+=( "${_lines[_k]%%+([[:space:]])}" )
    done
    while [[ "${#_body[@]}" -gt 0 && -z "${_body[0]}" ]]; do
      _body=( "${_body[@]:1}" )
    done
    while [[ "${#_body[@]}" -gt 0 && -z "${_body[-1]}" ]]; do
      unset '_body[-1]'
    done
    _hash="$(printf '%s\n' "${_head}" "${_body[@]}" \
      | sha256sum | cut -c "1-${_README_SYNC_HASH_LEN}")"
    printf '%s\t%s\n' "${_hslug[_j]}" "${_hash}"
  done

  [[ "${_extglob_was_set}" -eq 1 ]] || shopt -u extglob
}

# _readme_file_markers <file> -- emit one TAB-separated record per marker
# found in a translation, in document order:
#
#   <lineno><TAB>sync|skip<TAB><id><TAB><hash-or-dash><TAB>yes|no
#
# The last field answers "is this marker immediately above a heading" and is
# always `-` for a skip declaration (which deliberately has no section to sit
# above).
_readme_file_markers() {
  local _file="$1"
  local -a _lines=()
  mapfile -t _lines < "${_file}"

  local _extglob_was_set=0
  shopt -q extglob && _extglob_was_set=1
  shopt -s extglob

  local _n="${#_lines[@]}"
  local _i _j _probe _id _hash _follow
  for (( _i = 0; _i < _n; _i++ )); do
    _probe="${_lines[_i]%%+([[:space:]])}"
    if [[ "${_probe}" =~ ${_README_SYNC_SKIP_RE} ]]; then
      printf '%s\tskip\t%s\t-\t-\n' "$(( _i + 1 ))" "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${_probe}" =~ ${_README_SYNC_MARKER_RE} ]]; then
      _id="${BASH_REMATCH[1]}"
      _hash="${BASH_REMATCH[3]:-}"
      [[ -n "${_hash}" ]] || _hash='-'
      _follow='no'
      for (( _j = _i + 1; _j < _n; _j++ )); do
        [[ -z "${_lines[_j]%%+([[:space:]])}" ]] && continue
        if [[ "${_lines[_j]}" =~ ${_README_SYNC_HEADING_RE} ]]; then
          _follow='yes'
        fi
        break
      done
      printf '%s\tsync\t%s\t%s\t%s\n' \
        "$(( _i + 1 ))" "${_id}" "${_hash}" "${_follow}"
    fi
  done

  [[ "${_extglob_was_set}" -eq 1 ]] || shopt -u extglob
}

# _readme_translation_files <root> -- emit the localized README paths under
# <root>, sorted. Empty output means none were found; the caller decides
# whether that is an error (for the lint it is: a vacuous pass).
_readme_translation_files() {
  local _root="$1" _file
  local _nullglob_was_set=0
  shopt -q nullglob && _nullglob_was_set=1
  shopt -s nullglob
  local -a _files=()
  for _file in "${_root}/${_README_SYNC_DIR_REL}"/${_README_SYNC_GLOB}; do
    _files+=( "${_file}" )
  done
  [[ "${_nullglob_was_set}" -eq 1 ]] || shopt -u nullglob
  [[ "${#_files[@]}" -eq 0 ]] || printf '%s\n' "${_files[@]}" | sort
}

# _sync_readme_hashes [root] -- stamp every recognized marker in every
# localized README under <root> with its English section's current hash.
#
# A marker whose id is not an English section is left EXACTLY as it is: the
# generator cannot know whether the id is a typo or an English heading that
# was renamed, and quietly dropping or rewriting it would destroy the
# evidence. The lint names it instead.
_sync_readme_hashes() {
  local _root="${1:-${REPO_ROOT:-.}}"
  local _src="${_root}/${_README_SYNC_SOURCE_REL}"

  if [[ ! -f "${_src}" ]]; then
    _readme_sync_err \
      "no ${_README_SYNC_SOURCE_REL} under ${_root} -- nothing to hash against."
    return 1
  fi

  local -A _en=()
  local -a _en_order=()
  local _slug _hash
  while IFS=$'\t' read -r _slug _hash; do
    [[ -n "${_en[${_slug}]+x}" ]] || _en_order+=( "${_slug}" )
    _en["${_slug}"]="${_hash}"
  done < <(_readme_index "${_src}")

  local -a _files=()
  mapfile -t _files < <(_readme_translation_files "${_root}")
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _readme_sync_err \
      "no ${_README_SYNC_DIR_REL}/${_README_SYNC_GLOB} under ${_root} -- nothing to stamp."
    return 1
  fi

  local _extglob_was_set=0
  shopt -q extglob && _extglob_was_set=1
  shopt -s extglob

  local _file _rel _tmp _line _probe _id _stamped=0
  for _file in "${_files[@]}"; do
    _rel="${_file#"${_root}"/}"
    _tmp="$(mktemp "${_file}.XXXXXX")" || return 1
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _probe="${_line%%+([[:space:]])}"
      if [[ "${_probe}" =~ ${_README_SYNC_MARKER_RE} ]]; then
        _id="${BASH_REMATCH[1]}"
        if [[ -n "${_en[${_id}]+x}" ]]; then
          printf '<!-- sync: %s %s -->\n' "${_id}" "${_en[${_id}]}"
          _stamped=$(( _stamped + 1 ))
          continue
        fi
      fi
      printf '%s\n' "${_line}"
    done < "${_file}" > "${_tmp}"
    mv "${_tmp}" "${_file}"

    # Advisory: which English sections this translation still accounts for
    # neither way. Never auto-declared -- see the header note.
    local -A _claimed=()
    local _lineno _kind _rhash _follow
    while IFS=$'\t' read -r _lineno _kind _id _rhash _follow; do
      _claimed["${_id}"]=1
    done < <(_readme_file_markers "${_file}")
    for _slug in "${_en_order[@]}"; do
      [[ -n "${_claimed[${_slug}]+x}" ]] && continue
      printf "%s: no marker for English section '%s' -- translate it and add '<!-- sync: %s -->' above the translated heading, or declare '<!-- sync-skip: %s -- <why> -->'\\n" \
        "${_rel}" "${_slug}" "${_slug}" "${_slug}"
    done
  done

  [[ "${_extglob_was_set}" -eq 1 ]] || shopt -u extglob

  printf 'stamped %s marker(s) across %s file(s) under %s\n' \
    "${_stamped}" "${#_files[@]}" "${_root}/${_README_SYNC_DIR_REL}"
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  _sync_readme_hashes "${_root}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
