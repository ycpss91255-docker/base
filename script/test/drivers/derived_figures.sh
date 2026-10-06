#!/usr/bin/env bash
# drivers/derived_figures.sh - "a figure a document repeats must match the
# code that defines it" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers -- and the shipped lib's
# _validate_stage_name / SCHEMA_SECTIONS -- are available. Provides
# _run_derived_figures. Follows drivers/stale_setup_conf.sh /
# drivers/home_literal.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# Why: two figures had drifted, and each of them lived in more than one
# place, which is exactly what makes a hand fix the wrong answer -- the
# next edit re-opens the gap in whichever copy the editor did not have
# open.
#
#   1. The baseline stage blocklist. _validate_stage_name rejects
#      {sys, devel-base, devel, runtime-test} plus the legacy aliases
#      {base, test}, and deliberately lets `devel-test` through: it is
#      emitted as the `test` service so `[stage:devel-test]` has a runtime
#      control surface. Six documents said otherwise, listing a
#      five-element set with `devel-test` in it -- README.md, two of
#      stage.sh's own docstrings, three localized READMEs and four
#      setup_tui.sh message tables. A reader of any of them concludes the
#      `test` service does not exist.
#
#   2. The setup.conf section list. SCHEMA_SECTIONS is the single source
#      for "which sections exist, in what order"; README.md's overview
#      announced seven and listed eight, missing six real ones.
#
# What is derived, and how:
#
#   - The baseline renderings come from _validate_stage_name's own
#     `return 2` case arms, read back out of `declare -f` (the parsed,
#     canonical form -- immune to comment, indentation and line-wrapping
#     changes in the source file). Every extracted name is then probed
#     back THROUGH the predicate: if one does not return 2 the extraction
#     misread the function, and this lint fails loudly rather than pinning
#     prose to a set it invented.
#   - The section list is SCHEMA_SECTIONS verbatim, and the announced
#     count is just its length.
#
# Scope: the prose surfaces that a maintainer navigates by -- README.md,
# CONTEXT.md, the localized doc/readme/README.*.md, and dist/**/*.sh
# (shipped code comments AND the TUI message tables, which are user-facing
# strings). doc/adr/ and doc/changelog/ are deliberately NOT scanned: an
# ADR and a changelog entry are dated records of what was decided or
# shipped, and rewriting them to match today's code would destroy the
# record.
#
# What this lint does NOT try to be: a general "this English paragraph
# describes this function" mechanism. It pins two named, machine-derivable
# figures. A third figure is a third constant here, not a new framework.

# ── Derived-figure lint ──────────────────────────────────────────────────────

# The prose files that must exist. Each is required: a missing one would
# make the scan pass vacuously, which is how a lint quietly stops linting.
readonly _DERIVED_FIGURES_DOC_FILES=('README.md' 'CONTEXT.md')

# The localized READMEs, scanned through a glob (rather than a fixed list)
# so a fourth language is covered the day it is added.
readonly _DERIVED_FIGURES_DOC_DIR='doc/readme'
readonly _DERIVED_FIGURES_DOC_GLOB='README.*.md'

# The shipped runtime tree. Its *.sh files carry both the stage subsystem's
# own docstrings and the setup_tui.sh message tables a user reads at the
# menu, so a stale set here is not merely a comment.
readonly _DERIVED_FIGURES_CODE_ROOT='dist'

# The setup.conf overview, and the heading whose figure is pinned. The
# heading text is part of the contract: renaming it makes this lint fail
# loudly (naming the expected form) rather than silently stop checking.
readonly _DERIVED_FIGURES_README='README.md'
readonly _DERIVED_FIGURES_CONF_HEADING_RE='^### One conf, ([0-9]+) sections$'
readonly _DERIVED_FIGURES_CONF_HEADING='### One conf, <N> sections'

# A brace-set literal: an opening brace, a lowercase-initial token, then
# only the characters a comma-separated identifier list can contain. The
# restricted class is what keeps a match from spanning unrelated prose
# once the file has been flattened to one line, and what makes `${_var}`
# (leading underscore) and `${VAR}` (uppercase) non-matches.
readonly _DERIVED_FIGURES_SET_RE='\{[a-z][a-z0-9_,. -]*\}'

# A single stage name.
readonly _DERIVED_FIGURES_NAME_RE='^[a-z][a-z0-9_-]*$'

# _derived_join_comma <token>... -- "a, b, c".
_derived_join_comma() {
  local _joined=''
  printf -v _joined '%s, ' "$@"
  printf '%s' "${_joined%, }"
}

# _derived_baseline_arms -- emit one line per baseline case arm of
# _validate_stage_name, tokens space-separated, in source order.
#
# Reads `declare -f`, i.e. bash's own re-rendering of the parsed function,
# so the arms arrive one-per-line in a fixed shape no matter how the source
# file wraps or comments them. An arm counts when its body is exactly
# `return 2` -- the baseline-collision verdict. The reserved-tag arms
# (`return 3`) and the format check are not baseline and are skipped.
_derived_baseline_arms() {
  local -a _lines=()
  mapfile -t _lines < <(declare -f _validate_stage_name 2>/dev/null)
  if [[ "${#_lines[@]}" -eq 0 ]]; then
    return 1
  fi

  local _i _pat _body
  local -a _toks=()
  for (( _i = 0; _i + 1 < ${#_lines[@]}; _i++ )); do
    [[ "${_lines[_i]}" =~ ^[[:space:]]*([a-z][a-z0-9|_\ -]*)\)$ ]] || continue
    _pat="${BASH_REMATCH[1]//|/ }"
    _body="${_lines[_i+1]}"
    _body="${_body#"${_body%%[![:space:]]*}"}"
    _body="${_body%"${_body##*[![:space:]]}"}"
    [[ "${_body}" == 'return 2' ]] || continue
    read -r -a _toks <<< "${_pat}"
    printf '%s\n' "${_toks[*]}"
  done
}

# _derived_baseline_names -- every baseline stage name, one per line.
_derived_baseline_names() {
  local _arm _name
  while read -r -a _arm; do
    for _name in "${_arm[@]}"; do
      printf '%s\n' "${_name}"
    done
  done < <(_derived_baseline_arms)
}

# _derived_baseline_renderings -- the canonical `{a, b, c}` rendering of
# each baseline arm, one per line. This is the ONLY spelling documents may
# use; a set that names a baseline stage and is not one of these is the
# drift this lint exists to catch.
_derived_baseline_renderings() {
  local -a _arm=()
  while read -r -a _arm; do
    printf '{%s}\n' "$(_derived_join_comma "${_arm[@]}")"
  done < <(_derived_baseline_arms)
}

# _derived_flatten <file> <flat_var> <offsets_var> -- render <file> as one
# line, and record where each source line starts inside it.
#
# All three live drift shapes wrap the set: README.md breaks it across two
# markdown lines, stage.sh's docstring breaks it across two `#` comment
# lines, and setup_tui.sh breaks it with an escaped `\n` inside a $'...'
# message. A line-at-a-time matcher would have reported none of them, so
# the file is joined into a single string first, with the leading comment
# marker dropped so the continuation's `#` does not land inside the set.
# Markdown code ticks and tabs become spaces for the same reason (the set
# is written inside backticks in every README).
#
# <offsets_var> receives "<start-offset>:<line-number>" entries, so a match
# found at a flattened offset can still be reported at its source line.
_derived_flatten() {
  local _file="$1"
  local -n _flat_out="$2"
  local -n _offsets_out="$3"
  _flat_out=''
  _offsets_out=()

  local _line _seg
  local _lineno=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    _seg="${_line//\`/ }"
    _seg="${_seg//'\n'/ }"
    _seg="${_seg//$'\t'/ }"
    if [[ "${_seg}" =~ ^[[:space:]]*#[[:space:]]?(.*)$ ]]; then
      _seg="${BASH_REMATCH[1]}"
    fi
    _offsets_out+=( "${#_flat_out}:${_lineno}" )
    _flat_out+="${_seg} "
  done < "${_file}"
}

# _derived_lineno_at <offset> <offsets_var> -- the source line a flattened
# offset came from.
_derived_lineno_at() {
  local _offset="$1"
  local -n _offsets_in="$2"
  local _entry _start _lineno='1'
  for _entry in "${_offsets_in[@]}"; do
    _start="${_entry%%:*}"
    (( _start > _offset )) && break
    _lineno="${_entry#*:}"
  done
  printf '%s' "${_lineno}"
}

# _derived_scan_baseline_sets <file> <rel> <renderings_var> <names_var>
#
# Report every brace-set literal in <file> that names a baseline stage and
# is not one of the canonical renderings. Prints one violation per hit and
# returns the count.
_derived_scan_baseline_sets() {
  local _file="$1" _rel="$2"
  local -n _renderings_in="$3"
  local -n _names_in="$4"

  local _flat=''
  local -a _offsets=()
  _derived_flatten "${_file}" _flat _offsets

  local _violations=0
  local _rest="${_flat}" _consumed=0
  local _match _prefix _offset _inner _tok _canonical _rendering
  local _names_hit _shape_ok _is_canonical
  local -a _toks=()
  while [[ "${_rest}" =~ ${_DERIVED_FIGURES_SET_RE} ]]; do
    _match="${BASH_REMATCH[0]}"
    _prefix="${_rest%%"${_match}"*}"
    _offset=$(( _consumed + ${#_prefix} ))
    _consumed=$(( _offset + ${#_match} ))
    _rest="${_rest:${#_prefix} + ${#_match}}"

    # A brace group glued to a path separator is a shell brace EXPANSION,
    # not a prose set -- `test/bats/smoke/{shared,devel-test,runtime-test}/`
    # is a real directory layout, and rewriting it to the baseline set
    # would be nonsense. Prose always delimits the set with whitespace, a
    # code tick or a bracket.
    if [[ "${_prefix: -1}" == '/' || "${_rest:0:1}" == '/' ]]; then
      continue
    fi

    # Split on commas and trim. A token that is not a bare stage name
    # (an embedded dot, an empty slot) means this is not a stage set at
    # all -- a `${dir}/name` expansion, a brace expansion, prose.
    _inner="${_match#\{}"
    _inner="${_inner%\}}"
    _toks=()
    _shape_ok=1
    local _old_ifs="${IFS}"
    IFS=','
    for _tok in ${_inner}; do
      _tok="${_tok#"${_tok%%[![:space:]]*}"}"
      _tok="${_tok%"${_tok##*[![:space:]]}"}"
      if [[ ! "${_tok}" =~ ${_DERIVED_FIGURES_NAME_RE} ]]; then
        _shape_ok=0
        break
      fi
      _toks+=( "${_tok}" )
    done
    IFS="${_old_ifs}"
    (( _shape_ok )) || continue
    [[ "${#_toks[@]}" -gt 0 ]] || continue

    # Only sets that talk about the baseline are this lint's business.
    _names_hit=0
    for _tok in "${_toks[@]}"; do
      for _canonical in "${_names_in[@]}"; do
        if [[ "${_tok}" == "${_canonical}" ]]; then
          _names_hit=1
          break 2
        fi
      done
    done
    (( _names_hit )) || continue

    # Compare as a SET rendering, not byte-for-byte: spacing is the
    # author's business, membership and order are the code's.
    _rendering="{$(_derived_join_comma "${_toks[@]}")}"
    _is_canonical=0
    for _canonical in "${_renderings_in[@]}"; do
      if [[ "${_rendering}" == "${_canonical}" ]]; then
        _is_canonical=1
        break
      fi
    done
    (( _is_canonical )) && continue

    printf '%s:%s: baseline stage set %s -- expected %s\n' \
      "${_rel}" "$(_derived_lineno_at "${_offset}" _offsets)" \
      "${_rendering}" \
      "$(_derived_join_comma "${_renderings_in[@]}")"
    _violations=$(( _violations + 1 ))
  done

  return "${_violations}"
}

# _derived_check_conf_sections -- pin README.md's setup.conf overview to
# SCHEMA_SECTIONS: the announced count must be the list's length, and the
# `[section]` lines under the heading must be the sections themselves, in
# template order. Prints each violation; returns the count.
_derived_check_conf_sections() {
  local _readme="${REPO_ROOT}/${_DERIVED_FIGURES_README}"
  local -a _lines=()
  mapfile -t _lines < "${_readme}"

  local _i _count='' _heading_idx=-1
  for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
    if [[ "${_lines[_i]}" =~ ${_DERIVED_FIGURES_CONF_HEADING_RE} ]]; then
      _count="${BASH_REMATCH[1]}"
      _heading_idx="${_i}"
      break
    fi
  done

  local _expected_list
  _expected_list="$(_derived_join_comma "${SCHEMA_SECTIONS[@]}")"

  if (( _heading_idx < 0 )); then
    printf "%s: no '%s' heading -- the setup.conf section figure has nowhere to be pinned. Restore the heading (the count is %s) or move the pin in drivers/derived_figures.sh.\\n" \
      "${_DERIVED_FIGURES_README}" "${_DERIVED_FIGURES_CONF_HEADING}" \
      "${#SCHEMA_SECTIONS[@]}"
    return 1
  fi

  local _violations=0
  if [[ "${_count}" != "${#SCHEMA_SECTIONS[@]}" ]]; then
    printf '%s:%s: setup.conf section count is %s, SCHEMA_SECTIONS declares %s\n' \
      "${_DERIVED_FIGURES_README}" "$(( _heading_idx + 1 ))" \
      "${_count}" "${#SCHEMA_SECTIONS[@]}"
    _violations=$(( _violations + 1 ))
  fi

  local -a _found=()
  for (( _i = _heading_idx + 1; _i < ${#_lines[@]}; _i++ )); do
    [[ "${_lines[_i]}" =~ ^#{1,6}[[:space:]] ]] && break
    [[ "${_lines[_i]}" =~ ^\[([a-z_]+)\] ]] && _found+=( "${BASH_REMATCH[1]}" )
  done

  if [[ "${_found[*]}" != "${SCHEMA_SECTIONS[*]}" ]]; then
    printf '%s:%s: setup.conf sections listed as [%s], SCHEMA_SECTIONS declares [%s]\n' \
      "${_DERIVED_FIGURES_README}" "$(( _heading_idx + 1 ))" \
      "$(_derived_join_comma "${_found[@]}")" "${_expected_list}"
    _violations=$(( _violations + 1 ))
  fi

  return "${_violations}"
}

# ── Figure 3: what the DEFAULT self-test runs ────────────────────────────────
#
# The third figure is a FLAG, not a list: whether a bare `just test` measures
# coverage. It is decided in exactly one place -- the coverage argument every
# `_run_via_compose ci` call passes -- and it is repeated on every surface a
# person reaches for before running anything: the README quick-start, the
# "Running Template Tests" block, the three translations of both, the
# dispatcher's own `--help` examples and the recipe doc comments `just --list`
# renders.
#
# Eight of those said "ShellCheck + Bats + Kcov". The compose path provably
# cannot reach kcov: every `_run_via_compose ci` call passes coverage 0, the
# in-container `ci` branch skips kcov for speed, and kcov is reachable only
# through the explicit `--coverage*` entries. The cost is a wasted CI round
# trip for whoever believed the default was the full gate, and a wrong first
# impression on the repo's most-read page.
#
# The claim and the subcommand vocabulary are both DERIVED, so a migration
# lifts the rule instead of breaking it:
#
#   - the flag from the coverage argument of `_run_via_compose ci`. If those
#     calls ever disagree with each other the figure is ambiguous and the
#     lint refuses rather than guessing;
#   - which words after `just test` are a SUBCOMMAND (and so describe
#     something other than the default) from justfile.test's own recipe
#     names, never a list kept here;
#   - whether `shellcheck` and `hadolint` both run in the lint phase from
#     the `_LINT_TOOLS` table, which is what makes "ShellCheck only" a
#     false description of a bare `just test lint`.
#
# What is NOT gated, deliberately: the `mod? test` doc comment in the root
# justfile. `just --list` renders it as the NAMESPACE's label, not as the
# default recipe's description, and its parenthesis already names `coverage`
# as a subcommand -- so it is prose about a namespace rather than an
# annotation on an invocation, and the two shapes below do not reach it.

# The dispatcher that decides the figure, and the recipe file whose doc
# comments `just --list` renders. Both are scanned and both are required.
readonly _DERIVED_FIGURES_RUNNER='script/test/test.sh'
readonly _DERIVED_FIGURES_CMD_FILES=(
  'script/test/test.sh'
  'script/test/justfile.test'
)

# The invocations of the self-test that a documented example opens with.
# Anchored at the start of the command region, so a mention inside running
# prose (`bare 'just test' already runs bats in parallel`) is not read as an
# annotated example.
readonly _DERIVED_FIGURES_INVOCATION_RE='^(just[[:space:]]+test|\./test\.sh|\./script/test/test\.sh)([[:space:]]+(.*))?$'

# An annotation that explicitly says coverage is NOT measured. ASCII, and
# the same spelling in every locale: the translations write the tool list in
# Latin script already, so the negation travels with it and this driver
# needs no localized pattern.
readonly _DERIVED_FIGURES_NO_KCOV_RE='(^|[^[:alnum:]])(no|without)[[:space:]]+kcov'

# _derived_default_coverage <out_var> -- 1 when the compose dispatch measures
# coverage, 0 when it does not. Read off the coverage argument of every
# `_run_via_compose ci` call: that parameter IS the figure, and the `ci`
# service is the only thing a bare invocation reaches. Returns non-zero when
# the calls disagree, because a figure that cannot be derived must refuse
# rather than pick a side.
_derived_default_coverage() {
  local -n _cov_out="$1"
  _cov_out=''
  local -a _flags=()
  mapfile -t _flags < <(
    grep -oE '_run_via_compose[[:space:]]+ci[[:space:]]+[0-9]+' \
      "${REPO_ROOT}/${_DERIVED_FIGURES_RUNNER}" 2>/dev/null \
      | awk '{ print $NF }' | sort -u
  )
  [[ "${#_flags[@]}" -eq 1 ]] || return 1
  _cov_out="${_flags[0]}"
  return 0
}

# _derived_test_subcommands -- the recipe names `just test <name>` dispatches
# to, one per line, read out of justfile.test. A recipe line is a column-0
# name, optional parameters, then a colon ending the line; the name is the
# first word. Derived so a new recipe is understood the day it lands.
_derived_test_subcommands() {
  awk '
    /^[a-z][a-z0-9-]*([[:space:]][^:]*)?:$/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' "${REPO_ROOT}/script/test/justfile.test"
}

# _derived_lint_tools -- the entries of test.sh's _LINT_TOOLS table, one per
# line. PARSED, never sourced: the table is a literal in a file this driver
# only reads, and sourcing the dispatcher would drag in its whole lib chain.
_derived_lint_tools() {
  awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${REPO_ROOT}/${_DERIVED_FIGURES_RUNNER}"
}

# _derived_cmd_annotation <line> <args_var> <annot_var> -- recognise a
# DOCUMENTED invocation of the self-test and split it into the arguments it
# passes and the annotation that describes them.
#
# Two shapes, which are the two this repo documents a command with:
#
#   just test        # Full CI via docker compose
#   # just test -> run the whole self-test
#
# A comment line is unwrapped first, then whichever of `#` / `->` comes
# first opens the annotation. Returns non-zero when the line is neither.
_derived_cmd_annotation() {
  local _line="$1"
  local -n _args_out="$2"
  local -n _annot_out="$3"
  _args_out=''
  _annot_out=''

  local _body="${_line}"
  if [[ "${_body}" =~ ^[[:space:]]*#[[:space:]]*(.*)$ ]]; then
    _body="${BASH_REMATCH[1]}"
  else
    _body="${_body#"${_body%%[![:space:]]*}"}"
  fi

  [[ "${_body}" =~ ${_DERIVED_FIGURES_INVOCATION_RE} ]] || return 1
  local _rest="${BASH_REMATCH[3]}"

  # Whichever separator appears first opens the annotation. A `#` inside a
  # markdown fence and a `->` in a recipe doc comment are the same thing
  # here: everything left of it is what the example RUNS, everything right
  # of it is what the example CLAIMS.
  local _hash_at=-1 _arrow_at=-1 _head
  if [[ "${_rest}" == *'#'* ]]; then
    _head="${_rest%%'#'*}"
    _hash_at="${#_head}"
  fi
  if [[ "${_rest}" == *'->'* ]]; then
    _head="${_rest%%'->'*}"
    _arrow_at="${#_head}"
  fi

  local _sep=''
  if (( _hash_at >= 0 )) && { (( _arrow_at < 0 )) || (( _hash_at < _arrow_at )); }; then
    _sep='#'
  elif (( _arrow_at >= 0 )); then
    _sep='->'
  else
    return 1
  fi

  _annot_out="${_rest#*"${_sep}"}"
  _args_out="${_rest%%"${_sep}"*}"
  return 0
}

# _derived_scan_cmd_annotations <file> <rel> <coverage> <subcmds_var>
#                              <lint_tools_var>
#
# Report every documented invocation whose annotation disagrees with the
# code. Prints one violation per hit and returns the count.
_derived_scan_cmd_annotations() {
  local _file="$1" _rel="$2" _coverage="$3"
  local -n _subcmds_in="$4"
  local -n _lint_tools_in="$5"

  local _has_shellcheck=0 _has_hadolint=0 _tool
  for _tool in "${_lint_tools_in[@]}"; do
    [[ "${_tool}" == 'shellcheck' ]] && _has_shellcheck=1
    [[ "${_tool}" == 'hadolint' ]] && _has_hadolint=1
  done

  local _violations=0 _lineno=0 _line _args _annot _names_kcov
  local -a _toks=()
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    _derived_cmd_annotation "${_line}" _args _annot || continue
    read -r -a _toks <<< "${_args}"

    _names_kcov=0
    [[ "${_annot}" =~ [Kk][Cc][Oo][Vv] ]] && _names_kcov=1

    # Does this example describe the DEFAULT run? No arguments does. So
    # does an argument that is neither a flag nor one of justfile.test's own
    # recipe names: `just test <that>` dispatches nowhere, so the example is
    # still talking about the bare run -- and a bogus token cannot be used
    # to step out from under the rule.
    local _is_default=1 _subcmd
    if [[ "${#_toks[@]}" -gt 0 ]]; then
      if [[ "${_toks[0]}" == -* ]]; then
        _is_default=0
      else
        for _subcmd in "${_subcmds_in[@]}"; do
          if [[ "${_toks[0]}" == "${_subcmd}" ]]; then
            _is_default=0
            break
          fi
        done
      fi
    fi

    if (( _is_default )); then
      if [[ "${_coverage}" == '0' ]]; then
        if (( _names_kcov )) \
          && [[ ! "${_annot,,}" =~ ${_DERIVED_FIGURES_NO_KCOV_RE} ]]; then
          printf '%s:%s: the default self-test is documented as measuring coverage, but every _run_via_compose ci call passes coverage %s -- kcov is reachable only through the --coverage entries\n' \
            "${_rel}" "${_lineno}" "${_coverage}"
          _violations=$(( _violations + 1 ))
        fi
      elif (( ! _names_kcov )); then
        printf '%s:%s: the default self-test measures coverage (_run_via_compose ci passes %s) and this annotation does not say so\n' \
          "${_rel}" "${_lineno}" "${_coverage}"
        _violations=$(( _violations + 1 ))
      fi
      continue
    fi

    # The bare lint phase: `lint` and nothing narrowing it. It runs the
    # whole _LINT_TOOLS table, so an annotation that names one of the two
    # binary linters and not the other describes a narrowed run.
    if [[ "${#_toks[@]}" -eq 1 && "${_toks[0]}" == 'lint' ]] \
      && (( _has_shellcheck && _has_hadolint )); then
      if [[ "${_annot,,}" == *shellcheck* && "${_annot,,}" != *hadolint* ]]; then
        printf '%s:%s: the bare lint phase runs all %s entries of _LINT_TOOLS, shellcheck and hadolint among them, but this annotation names shellcheck alone\n' \
          "${_rel}" "${_lineno}" "${#_lint_tools_in[@]}"
        _violations=$(( _violations + 1 ))
      fi
    fi
  done < "${_file}"

  return "${_violations}"
}

_run_derived_figures() {
  echo "--- Running derived-figure lint ---"

  if ! declare -F _validate_stage_name >/dev/null \
    || [[ ! -v SCHEMA_SECTIONS ]]; then
    _die ci_derived_figures \
      "the shipped lib is not loaded (_validate_stage_name / SCHEMA_SECTIONS missing) -- the figures cannot be derived, and a lint that cannot derive them must not pass."
    return 1
  fi

  local -a _renderings=() _names=()
  mapfile -t _renderings < <(_derived_baseline_renderings)
  mapfile -t _names < <(_derived_baseline_names)
  if [[ "${#_renderings[@]}" -eq 0 || "${#_names[@]}" -eq 0 ]]; then
    _die ci_derived_figures \
      "read no baseline case arms out of _validate_stage_name -- the extraction is broken, so the canonical set is unknown."
    return 1
  fi

  # Probe every extracted name back through the predicate. The extractor
  # reads case arms; this is what proves it read them right, and it is the
  # difference between pinning prose to the code and pinning it to a
  # parser's guess.
  local _name _rc
  for _name in "${_names[@]}"; do
    _rc=0
    _validate_stage_name "${_name}" || _rc=$?
    if [[ "${_rc}" -ne 2 ]]; then
      _die ci_derived_figures \
        "extracted baseline name '${_name}' does not collide with the baseline (_validate_stage_name returned ${_rc}, expected 2) -- the case-arm extraction misread the function."
      return 1
    fi
  done

  # Assemble the scan surface, failing loudly on anything missing.
  local -a _files=()
  local _rel _abs
  for _rel in "${_DERIVED_FIGURES_DOC_FILES[@]}"; do
    _abs="${REPO_ROOT}/${_rel}"
    if [[ ! -f "${_abs}" ]]; then
      _die ci_derived_figures \
        "'${_rel}' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the prose that repeats the figures."
      return 1
    fi
    _files+=( "${_abs}" )
  done

  local _nullglob_was_set=0
  shopt -q nullglob && _nullglob_was_set=1
  shopt -s nullglob
  local _localized
  for _localized in \
    "${REPO_ROOT}/${_DERIVED_FIGURES_DOC_DIR}"/${_DERIVED_FIGURES_DOC_GLOB}; do
    _files+=( "${_localized}" )
  done
  [[ "${_nullglob_was_set}" -eq 1 ]] || shopt -u nullglob

  # The prose surfaces, before the shipped tree is appended: figure 3 is
  # about documented COMMANDS, which live in the prose and in the two files
  # that document the runner, not in the container runtime.
  local -a _cmd_surfaces=( "${_files[@]}" )
  for _rel in "${_DERIVED_FIGURES_CMD_FILES[@]}"; do
    _abs="${REPO_ROOT}/${_rel}"
    if [[ ! -f "${_abs}" ]]; then
      _die ci_derived_figures \
        "'${_rel}' not found under ${REPO_ROOT} -- the documented-command figure would pass vacuously. Point it at the dispatcher and the recipe file that document the default run."
      return 1
    fi
    _cmd_surfaces+=( "${_abs}" )
  done

  local _code_root="${REPO_ROOT}/${_DERIVED_FIGURES_CODE_ROOT}"
  if [[ ! -d "${_code_root}" ]]; then
    _die ci_derived_figures \
      "scan root '${_DERIVED_FIGURES_CODE_ROOT}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the shipped runtime tree."
    return 1
  fi
  local _file
  while IFS= read -r -d '' _file; do
    _files+=( "${_file}" )
  done < <(find "${_code_root}" -name '*.sh' -type f -print0 2>/dev/null \
    | sort -z)

  local _violations=0 _hits
  for _file in "${_files[@]}"; do
    _hits=0
    _derived_scan_baseline_sets \
      "${_file}" "${_file#"${REPO_ROOT}"/}" _renderings _names || _hits=$?
    _violations=$(( _violations + _hits ))
  done

  _hits=0
  _derived_check_conf_sections || _hits=$?
  _violations=$(( _violations + _hits ))

  # Figure 3. Derive the flag, the subcommand vocabulary and the lint table
  # first; each of them refuses loudly rather than letting the scan run on a
  # guess.
  local _coverage=''
  if ! _derived_default_coverage _coverage; then
    _die ci_derived_figures \
      "the _run_via_compose ci calls in ${_DERIVED_FIGURES_RUNNER} do not agree on one coverage argument -- what a bare 'just test' measures is then undefined, and prose cannot be held to it."
    return 1
  fi

  local -a _subcmds=() _lint_tools=()
  mapfile -t _subcmds < <(_derived_test_subcommands)
  if [[ "${#_subcmds[@]}" -eq 0 ]]; then
    _die ci_derived_figures \
      "read no recipe names out of script/test/justfile.test -- every documented 'just test <recipe>' would be judged as the default run."
    return 1
  fi
  mapfile -t _lint_tools < <(_derived_lint_tools)
  if [[ "${#_lint_tools[@]}" -eq 0 ]]; then
    _die ci_derived_figures \
      "read no entries out of the _LINT_TOOLS table in ${_DERIVED_FIGURES_RUNNER} -- what the bare lint phase runs is then unknown."
    return 1
  fi

  for _file in "${_cmd_surfaces[@]}"; do
    _hits=0
    _derived_scan_cmd_annotations \
      "${_file}" "${_file#"${REPO_ROOT}"/}" "${_coverage}" _subcmds \
      _lint_tools || _hits=$?
    _violations=$(( _violations + _hits ))
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_derived_figures \
      "${_violations} document figure(s) disagree with the code that defines them. The baseline stage blocklist is whatever _validate_stage_name returns 2 for -- currently $(_derived_join_comma "${_renderings[@]}") -- and 'devel-test' is NOT in it (it is emitted as the 'test' service). The setup.conf section list and its count are SCHEMA_SECTIONS. What a bare 'just test' measures is the coverage argument of _run_via_compose ci, and what a bare 'just test lint' runs is the whole _LINT_TOOLS table. Fix the prose, not the predicate."
    return 1
  fi
  echo "derived-figure lint: clean"
}
