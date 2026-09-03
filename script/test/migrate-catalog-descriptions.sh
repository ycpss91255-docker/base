#!/usr/bin/env bash
#
# migrate-catalog-descriptions.sh - ONE-SHOT: move the hand-written
# catalogue prose out of doc/test/*.md and into the spec files, as the
# `# why:` markers script/test/spec-markers.sh reads.
#
# THIS SCRIPT IS DELETED IN THE SAME PR THAT ADDS IT. It cannot stay in
# the tree: it reads descriptions OUT of the catalogue, which is exactly
# the direction the change exists to close. It is committed, run, and
# removed in three commits so a reviewer can read it and re-run it at the
# commit that adds it, and nothing dead survives.
#
# Usage:
#   migrate-catalog-descriptions.sh migrate <ABS root> <base-ref>
#   migrate-catalog-descriptions.sh prove   <ABS root> <base-ref>
#
# Both take the SOURCE MAP from <base-ref> rather than from the working
# tree, so the answer does not depend on how far the branch has already
# moved.
#
# THE SOURCE MAP is the EXISTING `_catalog_collect_descriptions` from
# `<base-ref>:script/test/sync-doc-counts.sh`. It already keys
# `(spec path, test name)` and already undoes the table's name escaping
# exactly as `_catalog_render_row` applied it. Reusing it means the
# migration reads a row the same way the generator wrote it, rather than a
# second parser that agrees on the day it was pasted.
#
# WHAT MOVES
#   * a row's description  -> a `# why:` block on the lines above its
#                             `@test`, `\|` unescaped back to `|` (the
#                             marker holds prose; markdown is the
#                             renderer's problem).
#   * a section's blurb    -> a `# why:` block appended to the spec's
#                             opening comment run. Nothing already in the
#                             header is discarded.
#   * a `| Category | Tests |` summary -> the same file-level block, as a
#                             list. The counts are dropped: they were
#                             derived, and every test in the section now
#                             carries its own row. The words are NOT
#                             dropped -- deleting an opt-out is not a
#                             licence to delete what somebody wrote under
#                             it.
#
# THE TWO CASES THAT MUST NOT BE GUESSED. Both are 0 on the tree this was
# written against, so refusing costs nothing and does not smuggle in a
# guess that would be unexpressible afterwards (the marker is positional,
# so it cannot represent "these two same-named tests share one sentence").
#
#   1. A spec with two identical `@test` names where the row is
#      described. A name-keyed map gives both the same prose. The CURRENT
#      generator does exactly that, so reproducing it would be
#      defensible -- and this is the last moment the ambiguity can be
#      stated at all.
#   2. A `### <path> (N)` heading appearing twice in one document. The
#      later section's rows overwrite the earlier's, so a duplicated
#      section silently halves the migration.
#
# A name appearing in two DIFFERENT specs is not one of these: the map is
# spec-scoped, so both survive independently, and `prove` confirms it.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_MIG_WIDTH=76

_mig_err() {
  {
    printf 'migrate-catalog-descriptions: %s\n' "$1"
  } >&2
}

# _mig_load_base <root> <ref> <workdir> -- materialise <ref>'s catalogue
# reader and <ref>'s doc/test into <workdir>, and source the reader.
# The spec trees are symlinked in so the reader's `[[ -f <root>/<spec> ]]`
# resolution answers about the real tree.
_mig_load_base() {
  local _root="$1" _ref="$2" _work="$3"
  mkdir -p "${_work}/base/doc/test"
  git -C "${_root}" show "${_ref}:script/test/sync-doc-counts.sh" \
    > "${_work}/collector.sh"
  local _name
  while IFS= read -r _name; do
    [[ -n "${_name}" ]] || continue
    git -C "${_root}" show "${_ref}:doc/test/${_name}" \
      > "${_work}/base/doc/test/${_name}"
  done < <(git -C "${_root}" ls-tree --name-only "${_ref}:doc/test" \
    | sed -n 's/\.md$/.md/p')
  ln -s "${_root}/test" "${_work}/base/test"
  [[ -d "${_root}/dist" ]] && ln -s "${_root}/dist" "${_work}/base/dist"
  # shellcheck source=/dev/null
  source "${_work}/collector.sh"
}

# _mig_unescape_pipe_into <outvar> <cell> -- `\|` back to `|`. The table
# escaping is the RENDERER's, so it must not survive into a marker.
_mig_unescape_pipe_into() {
  local -n _mig_unescape_out="$1"
  _mig_unescape_out="${2//\\|/|}"
}

# _mig_trim_into <outvar> <string>
_mig_trim_into() {
  local -n _mig_trim_out="$1"
  local _s="$2"
  _s="${_s#"${_s%%[![:space:]]*}"}"
  _s="${_s%"${_s##*[![:space:]]}"}"
  _mig_trim_out="${_s}"
}

# _mig_is_placeholder <desc> -- true when the row said nothing, so nothing
# is inserted. Matches the generator's own two spellings.
_mig_is_placeholder() {
  local _d="$1"
  _mig_trim_into _d "${_d}"
  [[ -z "${_d}" || "${_d}" == '-' ]]
}

# _mig_comment_block <prefix-first> <text> -- <text> as `# ` comment lines
# wrapped to _MIG_WIDTH columns INCLUDING the `# ` prefix, the first line
# opened with <prefix-first> (`# why: ` or `# `).
_mig_comment_block() {
  local _first="$1" _text="$2"
  local -a _words=()
  read -r -a _words <<< "${_text}"
  local _line="${_first}" _word _opened=0
  for _word in "${_words[@]}"; do
    if (( ! _opened )); then
      _line+="${_word}"
      _opened=1
    elif (( ${#_line} + 1 + ${#_word} <= _MIG_WIDTH )); then
      _line+=" ${_word}"
    else
      printf '%s\n' "${_line}"
      _line="# ${_word}"
    fi
  done
  (( _opened )) && printf '%s\n' "${_line}"
  return 0
}

# _mig_collect_sections <root> <basedoc-dir> <blurb-mapvar> -- the blurb
# (and the `| Category | Tests |` summary, folded in as a list) of every
# `### <path> (N)` section, keyed by spec path. Refuses a document that
# carries one spec's section twice.
#
# Paragraphs come back separated by a newline; a source line opening with
# `- ` starts its own paragraph, so a list survives as a list.
_mig_collect_sections() {
  local _root="$1" _docdir="$2"
  local -n _mig_blurbs="$3"
  local _doc _line _spec='' _rc=0
  local -A _seen=()
  local _para='' _acc='' _cat=0 _intable=0 _cell _rest
  for _doc in "${_docdir}"/*.md; do
    [[ -f "${_doc}" ]] || continue
    _seen=()
    _spec=''
    _acc=''
    _para=''
    _cat=0
    _intable=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      if [[ "${_line}" =~ ^#{1,6}[[:space:]] ]]; then
        _mig_flush_section _spec _acc _para _mig_blurbs
        _spec=''
        _cat=0
        _intable=0
        if [[ "${_line}" =~ ^#{3,6}[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]] \
          && [[ -f "${_root}/${BASH_REMATCH[1]}" ]]; then
          _spec="${BASH_REMATCH[1]}"
          if [[ -n "${_seen[${_spec}]:-}" ]]; then
            _mig_err "${_doc##*/} carries two sections for ${_spec} -- the later one's rows overwrite the earlier's, so the migration would silently halve. Delete the copy, heading and table together, then re-run."
            _rc=1
          fi
          _seen["${_spec}"]=1
        fi
        continue
      fi
      [[ -n "${_spec}" ]] || continue
      if [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*Description[[:space:]]*\| ]]; then
        _intable=1
        _cat=0
        continue
      fi
      if [[ "${_line}" =~ ^\|[[:space:]]*Category[[:space:]]*\| ]]; then
        _cat=1
        _intable=1
        _mig_append_para _acc _para 'Grouped by concern:'
        continue
      fi
      if [[ "${_line}" == '|'* ]]; then
        if (( _cat )) && [[ ! "${_line}" =~ ^\|[-:[:space:]|]+\|[[:space:]]*$ ]]; then
          _rest="${_line#|}"
          _cell="${_rest%%|*}"
          _mig_trim_into _cell "${_cell}"
          _mig_unescape_pipe_into _cell "${_cell}"
          [[ -n "${_cell}" ]] && _mig_append_para _acc _para "- ${_cell}"
        fi
        continue
      fi
      (( _intable )) && continue
      if [[ -z "${_line//[[:space:]]/}" ]]; then
        _mig_close_para _acc _para
        continue
      fi
      if [[ "${_line}" == '- '* || "${_line}" == '* '* ]]; then
        _mig_close_para _acc _para
      fi
      # Trimmed: a markdown list item's continuation lines are INDENTED,
      # and that indentation is layout, not content. Keeping it would put
      # runs of spaces inside the prose, which the marker writer collapses
      # anyway -- so the two sides of the proof would differ over
      # whitespace nobody typed.
      _mig_trim_into _line "${_line}"
      if [[ -n "${_para}" ]]; then
        _para+=" ${_line}"
      else
        _para="${_line}"
      fi
    done < "${_doc}"
    _mig_flush_section _spec _acc _para _mig_blurbs
  done
  return "${_rc}"
}

# _mig_close_para <acc-var> <para-var> -- end the paragraph under
# construction, appending it to the accumulator.
_mig_close_para() {
  local -n _mig_cp_acc="$1"
  local -n _mig_cp_para="$2"
  [[ -n "${_mig_cp_para}" ]] || return 0
  if [[ -n "${_mig_cp_acc}" ]]; then
    _mig_cp_acc+=$'\n'"${_mig_cp_para}"
  else
    _mig_cp_acc="${_mig_cp_para}"
  fi
  _mig_cp_para=''
}

# _mig_append_para <acc-var> <para-var> <text> -- close whatever is open
# and add <text> as a paragraph of its own.
_mig_append_para() {
  local -n _mig_ap_acc="$1"
  local -n _mig_ap_para="$2"
  _mig_close_para _mig_ap_acc _mig_ap_para
  _mig_ap_para="$3"
  _mig_close_para _mig_ap_acc _mig_ap_para
}

# _mig_flush_section <spec-var> <acc-var> <para-var> <mapvar>
_mig_flush_section() {
  local -n _mig_fs_spec="$1"
  local -n _mig_fs_acc="$2"
  local -n _mig_fs_para="$3"
  local -n _mig_fs_map="$4"
  _mig_close_para _mig_fs_acc _mig_fs_para
  if [[ -n "${_mig_fs_spec}" && -n "${_mig_fs_acc}" ]]; then
    _mig_fs_map["${_mig_fs_spec}"]="${_mig_fs_acc}"
  fi
  _mig_fs_acc=''
  _mig_fs_para=''
}

# _mig_run_has_marker <lines-arrayvar> <line> -- true when the contiguous
# comment run immediately above <line> already carries a `# why:`.
#
# The guard against a SECOND pass, and it is per SITE rather than per file
# on purpose. A whole-file refusal is the obvious spelling and it is wrong
# twice over: it aborts on a spec that legitimately already carries a
# marker somebody wrote by hand, and it says nothing about the sites this
# run is actually about. Per site, a first run that aborted part-way is
# simply resumable, and a doubled block -- which renders as a plausible
# sentence rather than as damage -- cannot be produced at all.
_mig_run_has_marker() {
  local -n _mig_rh_lines="$1"
  local _mig_rh_j=$(( $2 - 1 ))
  while (( _mig_rh_j >= 1 )) \
    && [[ "${_mig_rh_lines[_mig_rh_j-1]}" == '#'* ]]; do
    [[ "${_mig_rh_lines[_mig_rh_j-1]}" =~ ^#[[:space:]]*why: ]] && return 0
    _mig_rh_j=$(( _mig_rh_j - 1 ))
  done
  return 1
}

# _mig_rewrite_spec <root> <spec-rel> <descmap-var> <blurbmap-var> -- write
# the markers into one spec file. Refuses a spec that answers twice for one
# described name.
_mig_rewrite_spec() {
  local _root="$1" _rel="$2"
  local -n _mig_rw_desc="$3"
  local -n _mig_rw_blurb="$4"
  local _file="${_root}/${_rel}"
  local -a _lines=()
  mapfile -t _lines < "${_file}"
  local _n="${#_lines[@]}" _i _open_end=0
  for (( _i = 1; _i <= _n; _i++ )); do
    [[ "${_lines[_i-1]}" == '#'* ]] || break
    _open_end="${_i}"
  done

  # Refuse a described name that the spec carries twice.
  local -A _count=()
  local _name _key _d
  for (( _i = 1; _i <= _n; _i++ )); do
    [[ "${_lines[_i-1]}" =~ ^@test[[:space:]]+\"(.*)\"[[:space:]]*\{[[:space:]]*$ ]] \
      || continue
    _catalog_unescape_into _name "${BASH_REMATCH[1]}"
    _count["${_name}"]=$(( ${_count["${_name}"]:-0} + 1 ))
  done
  local _bad=0
  for _name in "${!_count[@]}"; do
    # `${...}` first: an unadorned associative subscript inside (( )) is
    # evaluated as ARITHMETIC, so a test name containing an identifier
    # would be dereferenced as a variable.
    (( ${_count["${_name}"]} > 1 )) || continue
    _key="$(_catalog_key "${_rel}" "${_name}")"
    _d="${_mig_rw_desc[${_key}]:-}"
    _mig_is_placeholder "${_d}" && continue
    _mig_err "${_rel} carries '${_name}' ${_count[${_name}]} times and the catalogue describes it once -- a name-keyed map would give both tests the same sentence. The marker is positional, so this is the last moment the ambiguity can be stated. Split the names, or describe them by hand, then re-run."
    _bad=1
  done
  (( _bad )) && return 1

  # A file-level block already present is this file's blurb; nothing is
  # appended over it.
  local _blurb="${_mig_rw_blurb[${_rel}]:-}"
  local _i2
  for (( _i2 = 1; _i2 <= _open_end; _i2++ )); do
    if [[ "${_lines[_i2-1]}" =~ ^#[[:space:]]*why: ]]; then
      _blurb=''
      break
    fi
  done

  local _tmp
  _tmp="$(mktemp "${_file}.XXXXXX")" || return 1
  local _para _first
  for (( _i = 1; _i <= _n; _i++ )); do
    if [[ "${_lines[_i-1]}" =~ ^@test[[:space:]]+\"(.*)\"[[:space:]]*\{[[:space:]]*$ ]]; then
      _catalog_unescape_into _name "${BASH_REMATCH[1]}"
      _key="$(_catalog_key "${_rel}" "${_name}")"
      _d="${_mig_rw_desc[${_key}]:-}"
      if ! _mig_is_placeholder "${_d}" \
        && ! _mig_run_has_marker _lines "${_i}"; then
        _mig_unescape_pipe_into _d "${_d}"
        _mig_comment_block '# why: ' "${_d}"
      fi
    fi
    printf '%s\n' "${_lines[_i-1]}"
    if (( _i == _open_end )) && [[ -n "${_blurb}" ]]; then
      printf '#\n'
      _first=1
      while IFS= read -r _para; do
        [[ -n "${_para}" ]] || continue
        if (( _first )); then
          _mig_comment_block '# why: ' "${_para}"
          _first=0
        else
          printf '#\n'
          _mig_comment_block '# ' "${_para}"
        fi
      done <<< "${_blurb}"
    fi
  done > "${_tmp}"
  mv "${_tmp}" "${_file}"
}

# _mig_spec_files <root> -- every spec file the catalogues cover.
_mig_spec_files() {
  local _root="$1" _glob _f
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _glob in 'test/bats/**/*_spec.bats' 'dist/test/bats/smoke/**/*.bats'; do
    for _f in "${_root}"/${_glob}; do
      [[ -f "${_f}" ]] && printf '%s\n' "${_f#"${_root}"/}"
    done
  done
  (( _globstar_was_set )) || shopt -u globstar
}

_mig_migrate() {
  local _root="$1" _ref="$2" _work="$3"
  local -A _desc=() _blurb=()
  local _doc
  for _doc in "${_work}"/base/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    _catalog_collect_descriptions "${_work}/base" "${_doc}" _desc || true
  done
  _mig_collect_sections "${_work}/base" "${_work}/base/doc/test" _blurb || return 1

  local _rel _rc=0 _n=0
  while IFS= read -r _rel; do
    _mig_rewrite_spec "${_root}" "${_rel}" _desc _blurb || _rc=1
    _n=$(( _n + 1 ))
  done < <(_mig_spec_files "${_root}")
  (( _rc == 0 )) || return 1
  printf 'migrated %s spec file(s): %s description(s), %s section blurb(s)\n' \
    "${_n}" "${#_desc[@]}" "${#_blurb[@]}"
}

# _mig_triples <root> <docdir> -- `<spec> TAB <name> TAB <desc>` for every
# DESCRIBED row the base collector finds in <docdir>, sorted. `\|` is
# unescaped on both sides of the comparison, and that normalisation is
# declared rather than hidden: the committed catalogue spells a literal
# pipe two ways (four rows escape it, one does not) and the new renderer
# spells it one way. A renderer bug still shows -- a dropped pipe, or a
# double escape, does not survive the same unescape on both sides.
_mig_triples() {
  local _root="$1" _docdir="$2"
  local -A _d=()
  local _doc _k _v
  for _doc in "${_docdir}"/*.md; do
    [[ -f "${_doc}" ]] || continue
    _catalog_collect_descriptions "${_root}" "${_doc}" _d || true
  done
  for _k in "${!_d[@]}"; do
    _v="${_d[${_k}]}"
    _mig_is_placeholder "${_v}" && continue
    _mig_unescape_pipe_into _v "${_v}"
    printf '%s\t%s\n' "${_k}" "${_v}"
  done | LC_ALL=C sort
}

# _mig_blurb_pairs <root> <docdir> -- `<spec> TAB <blurb>` with the
# paragraph newlines flattened to a space, sorted.
_mig_blurb_pairs() {
  local _root="$1" _docdir="$2"
  local -A _b=()
  local _k _v
  _mig_collect_sections "${_root}" "${_docdir}" _b || return 1
  for _k in "${!_b[@]}"; do
    _v="${_b[${_k}]//$'\n'/ }"
    _mig_unescape_pipe_into _v "${_v}"
    printf '%s\t%s\n' "${_k}" "${_v}"
  done | LC_ALL=C sort
}

_mig_prove() {
  local _root="$1" _work="$2"
  local _rows_a="${_work}/A.txt" _rows_b="${_work}/B.txt"
  local _blurb_a="${_work}/A-blurb.txt" _blurb_b="${_work}/B-blurb.txt"

  _mig_triples "${_work}/base" "${_work}/base/doc/test" > "${_rows_a}"
  _mig_triples "${_root}" "${_root}/doc/test" > "${_rows_b}"
  _mig_blurb_pairs "${_work}/base" "${_work}/base/doc/test" > "${_blurb_a}"
  _mig_blurb_pairs "${_root}" "${_root}/doc/test" > "${_blurb_b}"

  local _rc=0 _lost _gained
  printf 'A (described rows, committed catalogue at the base commit): %s\n' \
    "$(wc -l < "${_rows_a}")"
  printf 'B (described rows, catalogue regenerated from the specs):   %s\n' \
    "$(wc -l < "${_rows_b}")"
  _lost="$(LC_ALL=C comm -23 "${_rows_a}" "${_rows_b}" | wc -l)"
  _gained="$(LC_ALL=C comm -13 "${_rows_a}" "${_rows_b}" | wc -l)"
  printf 'in A but not in B (lost or altered): %s\n' "${_lost}"
  printf 'in B but not in A (invented):        %s\n' "${_gained}"
  if [[ "${_lost}" != '0' || "${_gained}" != '0' ]]; then
    LC_ALL=C comm -3 "${_rows_a}" "${_rows_b}" > "${_work}/rows.diff"
    sed -n '1,40p' "${_work}/rows.diff"
    _rc=1
  fi

  printf 'A (section blurbs, committed catalogue): %s\n' "$(wc -l < "${_blurb_a}")"
  printf 'B (section blurbs, regenerated):         %s\n' "$(wc -l < "${_blurb_b}")"
  _lost="$(LC_ALL=C comm -23 "${_blurb_a}" "${_blurb_b}" | wc -l)"
  _gained="$(LC_ALL=C comm -13 "${_blurb_a}" "${_blurb_b}" | wc -l)"
  printf 'blurbs in A but not in B: %s\n' "${_lost}"
  printf 'blurbs in B but not in A: %s\n' "${_gained}"
  if [[ "${_lost}" != '0' || "${_gained}" != '0' ]]; then
    LC_ALL=C comm -3 "${_blurb_a}" "${_blurb_b}" > "${_work}/blurbs.diff"
    sed -n '1,20p' "${_work}/blurbs.diff"
    _rc=1
  fi
  return "${_rc}"
}

main() {
  local _cmd="${1:-}" _root="${2:-}" _ref="${3:-}"
  if [[ -z "${_cmd}" || -z "${_root}" || -z "${_ref}" ]]; then
    _mig_err "usage: $0 {migrate|prove} <ABS root> <base-ref>"
    return 1
  fi
  if [[ "${_root}" != /* ]]; then
    _mig_err "scan root '${_root}' is relative -- pass an ABSOLUTE path."
    return 1
  fi
  local _work _rc=0
  _work="$(mktemp -d)" || return 1
  _mig_load_base "${_root}" "${_ref}" "${_work}"
  case "${_cmd}" in
    migrate) _mig_migrate "${_root}" "${_ref}" "${_work}" || _rc=1 ;;
    prove) _mig_prove "${_root}" "${_work}" || _rc=1 ;;
    *) _mig_err "unknown command '${_cmd}'"; _rc=1 ;;
  esac
  rm -rf "${_work}"
  return "${_rc}"
}

main "$@"
