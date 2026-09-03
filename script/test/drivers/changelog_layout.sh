#!/usr/bin/env bash
# drivers/changelog_layout.sh - "the split changelog is still addressable"
# per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_changelog_layout.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/changelog_entry.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# WHY. doc/changelog/ is one file per 0.Y series behind an index. The single
# file it replaces was 669 KiB and 108 released version sections; nobody
# opened it, so it did not matter what was in it. Splitting it makes it
# readable and, at the same time, turns four things that used to be true by
# construction into claims a commit can break with nothing to notice:
#
#   - A version's section lives in the file its version names. Nothing about
#     a section in the wrong file renders differently; it is simply not
#     where the reader mid-upgrade looks.
#   - The index lists the series that exist. A missing row reads exactly
#     like a series that does not exist, which is the worst possible failure
#     mode for an index -- silence that looks like an answer.
#   - A section's compare link is in the same file as the section. Markdown
#     link definitions are file-scoped, so `[v0.12.4]` in v0.12.md resolves
#     to nothing if its definition stayed behind in the index. The
#     single-file changelog already went stale here once, around v0.6.8.
#   - Exactly one file carries `## [Unreleased]`. Two is two places to write
#     the next entry and two places a merge can keep; zero means the entry
#     lint has nothing to measure and every future entry goes unchecked.
#
# THE INDEX IS DERIVED, NOT CURATED. That is the answer to "what keeps the
# roster honest", and it is why this lint is not itself a second list to
# maintain: script/release/changelog_index.sh renders the block from the
# series files, and this driver runs the SAME generator and diffs its output
# against what is committed. There is no roster here to fall out of date --
# only a rendering to disagree with. Same generator/checker split as
# script/test/sync-doc-counts.sh and the doc-counts drift gate, and the same
# fix: run the generator (`just release changelog-index`).
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not read entry text, category
# headings or entry length -- drivers/changelog_entry.sh owns those, scoped
# to [Unreleased]. This one is about WHERE things are, which is the property
# the split created and the only one that needs a second pair of eyes.
#
# Fenced code blocks are structurally inert, as everywhere else in this
# repo's markdown scanning: inside ``` / ~~~ a `## [` is an example of a
# heading, and the convention note shows exactly that.

# ── Changelog layout lint ────────────────────────────────────────────────────

# The changelog tree and the two files in it that are not series files.
readonly _CHANGELOG_LAYOUT_DIR='doc/changelog'
readonly _CHANGELOG_LAYOUT_INDEX='CHANGELOG.md'
readonly _CHANGELOG_LAYOUT_GENERATOR='script/release/changelog_index.sh'

# The heading that marks the series currently being written.
readonly _CHANGELOG_LAYOUT_UNRELEASED='## [Unreleased]'

# _cll_series_of <tag> -- the series file basename a tag's section belongs
# in. A pure function of the tag: at 0.x the minor is the breaking axis, so
# the 0.Y series is the unit, and the filename is derived rather than
# mapped. A mapping would be one more roster to keep honest.
#
# TOTAL, deliberately: it answers with an empty string for a tag it cannot
# parse rather than with a non-zero status. The caller reads it through
# `_want="$(_cll_series_of ...)"`, and the lint phase runs every driver
# under `set -e` with an ERR trap, so a failing status there ends the
# driver at that assignment -- the "not a version" finding below would
# never be printed, and the run would stop with ci_lint_driver_failed
# naming an assignment, which reads as a broken lint rather than as a
# changelog that needs fixing.
_cll_series_of() {
  if [[ "${1}" =~ ^(v[0-9]+\.[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# _cll_scan <file> -- print one record per structural line of the file,
# outside fenced blocks:
#
#   H<TAB><line-number><TAB><tag>    a `## [<tag>]` section heading
#   L<TAB><line-number><TAB><tag>    a `[<tag>]: <url>` link definition
#
# One walk, both facts, so the fence state is resolved once and the two
# checks below cannot disagree about what the file's structure is.
_cll_scan() {
  local _file="${1}" _fence='' _i _line
  local -a _lines=()
  mapfile -t _lines < "${_file}"
  for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
    _line="${_lines[_i]}"
    if [[ "${_line}" =~ ^[[:space:]]*(\`\`\`+|~~~+) ]]; then
      if [[ -z "${_fence}" ]]; then
        _fence="${BASH_REMATCH[1]:0:1}"
      elif [[ "${BASH_REMATCH[1]:0:1}" == "${_fence}" ]]; then
        _fence=''
      fi
      continue
    fi
    [[ -n "${_fence}" ]] && continue
    if [[ "${_line}" =~ ^##\ \[([^]]+)\] ]]; then
      printf 'H\t%d\t%s\n' "$(( _i + 1 ))" "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${_line}" =~ ^\[([^]]+)\]:[[:space:]] ]]; then
      printf 'L\t%d\t%s\n' "$(( _i + 1 ))" "${BASH_REMATCH[1]}"
    fi
  done
}

_run_changelog_layout() {
  echo "--- Running changelog layout lint (split / index / compare links) ---"
  local _dir="${REPO_ROOT}/${_CHANGELOG_LAYOUT_DIR}"
  local _index="${_dir}/${_CHANGELOG_LAYOUT_INDEX}"
  local _generator="${REPO_ROOT}/${_CHANGELOG_LAYOUT_GENERATOR}"

  if [[ ! -d "${_dir}" ]]; then
    _die ci_changelog_layout \
      "no '${_CHANGELOG_LAYOUT_DIR}' under ${REPO_ROOT} -- the lint would pass vacuously."
    return 1
  fi
  if [[ ! -f "${_index}" ]]; then
    _die ci_changelog_layout \
      "no '${_CHANGELOG_LAYOUT_DIR}/${_CHANGELOG_LAYOUT_INDEX}' -- the index is the canonical path every existing link points at."
    return 1
  fi
  if [[ ! -f "${_generator}" ]]; then
    _die ci_changelog_layout \
      "no '${_CHANGELOG_LAYOUT_GENERATOR}' -- the index is DERIVED, and without the generator there is nothing to compare it against."
    return 1
  fi

  # The series files, by derived name. A file under doc/changelog/ that is
  # not vX.Y.md is not a series file (CHANGELOG.md, CONVENTIONS.md), and is
  # left alone rather than guessed at.
  local -a _series=()
  local _file _name
  for _file in "${_dir}"/v*.md; do
    [[ -f "${_file}" ]] || continue
    _name="$(basename "${_file}" .md)"
    [[ "${_name}" =~ ^v[0-9]+\.[0-9]+$ ]] || continue
    _series+=("${_name}")
  done
  if [[ "${#_series[@]}" -eq 0 ]]; then
    _die ci_changelog_layout \
      "no vX.Y.md series file under '${_CHANGELOG_LAYOUT_DIR}' -- every rule below holds over an empty set, so the lint would report clean having walked nothing."
    return 1
  fi

  local _violations=0 _sections=0 _links=0 _unreleased_files=''
  local _rel _kind _lineno _tag _want
  local -A _section_file=()
  local -A _heads=() _defs=() _head_line=() _def_line=()

  # Pass 1: placement, [Unreleased] uniqueness, and per-file link agreement.
  for _name in "${_series[@]}"; do
    _file="${_dir}/${_name}.md"
    _rel="${_CHANGELOG_LAYOUT_DIR}/${_name}.md"
    _heads=()
    _defs=()
    _head_line=()
    _def_line=()
    while IFS=$'\t' read -r _kind _lineno _tag; do
      case "${_kind}" in
        H)
          if [[ "${_tag}" == 'Unreleased' ]]; then
            _unreleased_files+="${_rel} "
            _heads["${_tag}"]=1
            _head_line["${_tag}"]="${_lineno}"
            continue
          fi
          _sections=$(( _sections + 1 ))
          _heads["${_tag}"]=1
          _head_line["${_tag}"]="${_lineno}"
          if [[ -n "${_section_file["${_tag}"]:-}" ]]; then
            printf '%s:%s: duplicate section -- %s already has a section in %s\n' \
              "${_rel}" "${_lineno}" "${_tag}" "${_section_file["${_tag}"]}"
            _violations=$(( _violations + 1 ))
            continue
          fi
          _section_file["${_tag}"]="${_rel}"
          _want="$(_cll_series_of "${_tag}")"
          if [[ -z "${_want}" ]]; then
            printf '%s:%s: section heading is not a version -- %s\n' \
              "${_rel}" "${_lineno}" "${_tag}"
            _violations=$(( _violations + 1 ))
          elif [[ "${_want}" != "${_name}" ]]; then
            printf '%s:%s: %s belongs in %s/%s.md, not in %s.md -- a section in the wrong file still renders, it is just not where a reader mid-upgrade looks\n' \
              "${_rel}" "${_lineno}" "${_tag}" \
              "${_CHANGELOG_LAYOUT_DIR}" "${_want}" "${_name}"
            _violations=$(( _violations + 1 ))
          fi
          ;;
        L)
          _links=$(( _links + 1 ))
          _defs["${_tag}"]=1
          _def_line["${_tag}"]="${_lineno}"
          ;;
      esac
    done < <(_cll_scan "${_file}")

    # Markdown link definitions are FILE-scoped, so the two sets have to
    # agree within one file or the reference goes nowhere.
    for _tag in "${!_heads[@]}"; do
      [[ -n "${_defs["${_tag}"]:-}" ]] && continue
      printf '%s:%s: [%s] has a section here and no compare-link definition in this file -- markdown link definitions are file-scoped, so the reference resolves to nothing\n' \
        "${_rel}" "${_head_line["${_tag}"]}" "${_tag}"
      _violations=$(( _violations + 1 ))
    done
    for _tag in "${!_defs[@]}"; do
      [[ -n "${_heads["${_tag}"]:-}" ]] && continue
      printf '%s:%s: [%s] has a compare-link definition here and no section in this file -- the section moved and the link did not\n' \
        "${_rel}" "${_def_line["${_tag}"]}" "${_tag}"
      _violations=$(( _violations + 1 ))
    done
  done

  # Pass 2: exactly one live series. Zero is the state in which every future
  # entry goes unmeasured; two is two places a merge can keep.
  local _unreleased_count=0
  # shellcheck disable=SC2086  # the accumulator is a space-separated list.
  set -- ${_unreleased_files}
  _unreleased_count="$#"
  if [[ "${_unreleased_count}" -ne 1 ]]; then
    printf "%s: '%s' appears in %d series files (%s) -- exactly one file is the live series\n" \
      "${_CHANGELOG_LAYOUT_DIR}" "${_CHANGELOG_LAYOUT_UNRELEASED}" \
      "${_unreleased_count}" "${_unreleased_files:-none}"
    _violations=$(( _violations + 1 ))
  fi

  # Pass 3: index drift. The generator is the definition of the block; the
  # committed text is a copy, and a copy is a thing that can be wrong.
  local _rendered _committed
  if ! _rendered="$(bash "${_generator}" "${_dir}" 2>&1)"; then
    printf '%s: the index generator refused: %s\n' \
      "${_CHANGELOG_LAYOUT_GENERATOR}" "${_rendered}"
    _violations=$(( _violations + 1 ))
  else
    _committed="$(_cll_committed_block "${_index}")"
    if [[ "${_committed}" != "${_rendered}" ]]; then
      printf '%s/%s: the generated index block has drifted from the series files. Diff (committed vs derived):\n' \
        "${_CHANGELOG_LAYOUT_DIR}" "${_CHANGELOG_LAYOUT_INDEX}"
      diff <(printf '%s\n' "${_committed}") <(printf '%s\n' "${_rendered}") \
        | sed 's/^/    /'
      _violations=$(( _violations + 1 ))
    fi
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    _die ci_changelog_layout \
      "${_violations} misplaced section / dangling compare link / index drift / live-series problem under '${_CHANGELOG_LAYOUT_DIR}'. The changelog is one file per 0.Y series behind an index: a section for vX.Y.Z lives in vX.Y.md, its compare-link definition lives in the SAME file (markdown link definitions are file-scoped), exactly one series file carries '${_CHANGELOG_LAYOUT_UNRELEASED}', and the index block between the changelog-index markers is DERIVED -- refresh it with 'just release changelog-index' rather than editing it, because an index nothing re-derives goes stale on the first series nobody remembers to add and a missing row reads exactly like a series that does not exist."
    return 1
  fi

  echo "changelog layout lint: clean (${#_series[@]} series, ${_sections} version sections each in the file its version names, ${_links} compare links resolved in-file, index re-derived and identical)"
}

# _cll_committed_block <index-file> -- the text between the changelog-index
# markers, inclusive, exactly as committed. Read with awk on a literal
# comparison: the markers carry backticks and brackets, and a regex address
# for them is a second place the marker text has to be got exactly right.
_cll_committed_block() {
  awk '
    index($0, "<!-- changelog-index: begin") == 1 { on = 1 }
    on { print }
    index($0, "<!-- changelog-index: end") == 1 { on = 0 }
  ' "${1}"
}
