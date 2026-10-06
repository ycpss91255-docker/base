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
#
# The literal dots are bracketed rather than backslash-escaped because this
# one constant is handed to BOTH engines -- bash's `[[ =~ ]]` here and awk's
# `~` in the folding pre-pass below -- and awk reads a backslash in a `-v`
# value as a string escape, warns, and drops it. `[.]` means the same thing
# to both, so there is one regex rather than two that have to agree.
readonly _DERIVED_FIGURES_INVOCATION_RE='^(just[[:space:]]+test|[.]/test[.]sh|[.]/script/test/test[.]sh)([[:space:]]+(.*))?$'

# The negation that turns a tool name from "this runs" into a statement about
# what does NOT run. One prefix, with the tool appended by the caller, so kcov
# and the linters are judged by the same rule rather than by two that have to
# agree.
#
# ASCII, and the same spelling in every locale: the translations write the tool
# list in Latin script already, so the negation travels with it and this driver
# needs no localized pattern.
#
# `.`, `;` and `,` end the clause the negation reaches. That bound is the whole
# point: without it "no kcov, ShellCheck + Hadolint run" would read as a denial
# of ShellCheck, and the allowance would become a way to wave the rule through
# by putting a negation anywhere in the line. An annotation whose second clause
# claims a tool is judged on that clause.
readonly _DERIVED_FIGURES_NEGATION_RE='(^|[^[:alnum:]])(no|without|skip|skips|skipped|skipping)[^.;,]{0,40}'

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

# _derived_coverage_skips_lint <out_var> -- 1 when a coverage dispatch does NOT
# run the lint phase, 0 when it does. Read off the guard around the full
# pipeline's `_run_all_lint_tools` call: `COVERAGE` named in that condition is
# what makes the phase skipped under coverage, so a documented coverage run
# that claims the linters ran is naming checks nothing performed. Returns
# non-zero when no call site is found at all -- the question is then
# unanswerable and the lint must refuse rather than assume.
_derived_coverage_skips_lint() {
  local -n _skip_out="$1"
  _skip_out=0
  local -a _conds=()
  mapfile -t _conds < <(awk '
    /^[[:space:]]*if \[\[/   { cond = $0 }
    /_run_all_lint_tools/     { if (cond != "") print cond }
  ' "${REPO_ROOT}/${_DERIVED_FIGURES_RUNNER}")
  [[ "${#_conds[@]}" -gt 0 ]] || return 1
  local _c
  for _c in "${_conds[@]}"; do
    [[ "${_c}" == *COVERAGE* ]] && _skip_out=1
  done
  return 0
}

# _derived_is_coverage_entry <token> -- does this argument name one of the
# instrumented entries? Leading dashes are stripped, so the subcommand
# (`coverage`, `coverage-local`, `coverage-path`) and the flag spelling of the
# same thing (`--coverage`, `--coverage-shard`) are one question.
_derived_is_coverage_entry() {
  local _tok="${1#--}"
  _tok="${_tok#-}"
  [[ "${_tok}" == 'coverage' || "${_tok}" == coverage-* ]]
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

# _derived_default_recipe <subcmds_var> <out_var> -- the recipe a BARE
# invocation runs. `just` dispatches a bare invocation to the recipe named
# `default` when the file defines one, and otherwise to the FIRST recipe in the
# file. So `just test <that name>` and bare `just test` are one dispatch, and an
# example that spells the name out has to be judged as the default run -- read
# as a narrowing subcommand it would exempt the default run from the rule about
# the default run. Derived from the recipe list, never the literal word.
_derived_default_recipe() {
  local -n _subs_in="$1"
  local -n _recipe_out="$2"
  _recipe_out=''
  [[ "${#_subs_in[@]}" -gt 0 ]] || return 1
  local _s
  for _s in "${_subs_in[@]}"; do
    if [[ "${_s}" == 'default' ]]; then
      _recipe_out='default'
      return 0
    fi
  done
  _recipe_out="${_subs_in[0]}"
  return 0
}

# _derived_tool_claimed <annotation> <tool> -- does this annotation claim that
# tool RUNS? It has to name it, and the mention must not be negated. An
# annotation that spells out which checks a dispatch skips is the most useful
# one a reader can get, so a denial is never read as a claim.
_derived_tool_claimed() {
  local _annot="${1,,}" _tool="${2,,}"
  [[ "${_annot}" == *"${_tool}"* ]] || return 1
  [[ "${_annot}" =~ ${_DERIVED_FIGURES_NEGATION_RE}${_tool} ]] && return 1
  return 0
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

# _derived_fold_annotations <file> -- emit `<line-number><TAB><text>`, one
# record per LOGICAL line, with a wrapped comment folded into one.
#
# A recipe doc comment wraps, and the claim is spread over the wrap:
# justfile.test's own default-recipe comment names the tool set on its first
# line and says "no kcov" on its second. Reading a file a physical line at a
# time inspects neither half properly -- the continuation is not an invocation,
# so it is skipped, and the opening line carries only as much of the claim as
# fit on it.
#
# Folding rules, in the order they are applied:
#
#   - a bare `#` line DETACHES. It is the paragraph separator this repo
#     already treats that way (the `# why:` markers the catalogue reads use
#     the same rule), so the paragraph below an example is not read as part
#     of that example's claim.
#   - a comment line whose body itself opens an invocation STARTS a new
#     annotation, so a block of worked examples stays a block of separate
#     claims rather than collapsing into the first one.
#   - any other comment line CONTINUES the one above it.
#   - a non-comment line is its own logical line: there the annotation is the
#     trailing `#` comment, which cannot wrap.
#
# The record keeps the line number the annotation OPENS on, which is where a
# reader fixes it.
_derived_fold_annotations() {
  awk -v inv="${_DERIVED_FIGURES_INVOCATION_RE}" '
    function flush() {
      if (open) { printf "%d\t#%s\n", start, buf; open = 0; buf = "" }
    }
    /^[[:space:]]*#[[:space:]]*$/ { flush(); next }
    /^[[:space:]]*#/ {
      body = $0
      # ALL leading whitespace goes, not one space: a worked example in a
      # header block is indented under its `#`, and an invocation that does
      # not reach the start of the body opens no annotation -- which would
      # fold every example in the block into the prose line above it and
      # leave the whole block unjudged.
      sub(/^[[:space:]]*#[[:space:]]*/, "", body)
      if (!open || body ~ inv) {
        flush()
        start = FNR
        buf = " " body
        open = 1
      } else {
        buf = buf " " body
      }
      next
    }
    { flush(); printf "%d\t%s\n", FNR, $0 }
    END { flush() }
  ' "${1}"
}

# _derived_scan_cmd_annotations <file> <rel> <coverage> <subcmds_var>
#                              <lint_tools_var> <coverage_skips_lint>
#
# Report every documented invocation whose annotation disagrees with the
# code. Prints one violation per hit and returns the count.
_derived_scan_cmd_annotations() {
  local _file="$1" _rel="$2" _coverage="$3"
  local -n _subcmds_in="$4"
  local -n _lint_tools_in="$5"
  local _coverage_skips_lint="$6"

  local _default_recipe=''
  if ! _derived_default_recipe _subcmds_in _default_recipe; then
    printf '%s: no recipe names were read, so which recipe a bare invocation runs is unknown\n' \
      "${_rel}"
    return 1
  fi

  local _has_shellcheck=0 _has_hadolint=0 _tool
  for _tool in "${_lint_tools_in[@]}"; do
    [[ "${_tool}" == 'shellcheck' ]] && _has_shellcheck=1
    [[ "${_tool}" == 'hadolint' ]] && _has_hadolint=1
  done

  local _violations=0 _lineno='' _line _args _annot _claims_kcov
  local -a _toks=()
  while IFS=$'\t' read -r _lineno _line; do
    _derived_cmd_annotation "${_line}" _args _annot || continue
    read -r -a _toks <<< "${_args}"

    # A CLAIM that coverage is measured: the word, not negated. Read the
    # same way whichever way the flag points -- an annotation that denies
    # kcov contradicts a dispatch that measures it just as plainly as one
    # that asserts kcov contradicts a dispatch that does not.
    _claims_kcov=0
    _derived_tool_claimed "${_annot}" 'kcov' && _claims_kcov=1

    # Does this example describe the DEFAULT run? No arguments does. So
    # does an argument that is neither a flag nor one of justfile.test's own
    # recipe names: `just test <that>` dispatches nowhere, so the example is
    # still talking about the bare run -- and a bogus token cannot be used
    # to step out from under the rule.
    local _is_default=1 _subcmd
    if [[ "${#_toks[@]}" -eq 1 && "${_toks[0]}" == "${_default_recipe}" ]]; then
      _is_default=1
    elif [[ "${#_toks[@]}" -gt 0 ]]; then
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
        if (( _claims_kcov )); then
          printf '%s:%s: the default self-test is documented as measuring coverage, but every _run_via_compose ci call passes coverage %s -- kcov is reachable only through the --coverage entries\n' \
            "${_rel}" "${_lineno}" "${_coverage}"
          _violations=$(( _violations + 1 ))
        fi
      elif (( ! _claims_kcov )); then
        printf '%s:%s: the default self-test measures coverage (_run_via_compose ci passes %s) and this annotation does not say so\n' \
          "${_rel}" "${_lineno}" "${_coverage}"
        _violations=$(( _violations + 1 ))
      fi
      continue
    fi

    # An instrumented entry. The coverage dispatch sets COVERAGE=1, which is
    # exactly the flag the full pipeline's lint-phase guard excludes, so an
    # annotation that names a linter there tells a reader ShellCheck and
    # Hadolint passed when neither ran.
    if (( _coverage_skips_lint )) && _derived_is_coverage_entry "${_toks[0]}" \
      && (( _has_shellcheck || _has_hadolint )); then
      # Per tool, and a NEGATED mention is not a claim: an annotation that
      # spells out which checks coverage skips is the most useful one a
      # reader can get, and must not be refused for containing the name.
      local _claimed=''
      for _tool in shellcheck hadolint; do
        _derived_tool_claimed "${_annot}" "${_tool}" && _claimed+=" ${_tool}"
      done
      if [[ -n "${_claimed}" ]]; then
        printf '%s:%s: a coverage run sets COVERAGE=1, which is the flag the lint phase guard excludes, so no linter runs -- this annotation names%s as running. Say the lint phase is skipped, or negate the name ("no shellcheck")\n' \
          "${_rel}" "${_lineno}" "${_claimed}"
        _violations=$(( _violations + 1 ))
      fi
      continue
    fi

    # The bare lint phase: `lint` and nothing narrowing it. It runs the
    # whole _LINT_TOOLS table, so an annotation that names one of the two
    # binary linters and not the other describes a narrowed run.
    if [[ "${#_toks[@]}" -eq 1 && "${_toks[0]}" == 'lint' ]] \
      && (( _has_shellcheck && _has_hadolint )); then
      # SYMMETRIC. Both binaries run, so naming either one alone describes a
      # narrowed phase; catching one spelling and not the other enforces the
      # invariant in one direction and invites the other.
      local _sc_claimed=0 _hd_claimed=0
      _derived_tool_claimed "${_annot}" 'shellcheck' && _sc_claimed=1
      _derived_tool_claimed "${_annot}" 'hadolint' && _hd_claimed=1
      if (( _sc_claimed != _hd_claimed )); then
        local _named='hadolint'
        (( _sc_claimed )) && _named='shellcheck'
        printf '%s:%s: the bare lint phase runs all %s entries of _LINT_TOOLS, shellcheck and hadolint among them, but this annotation names %s alone\n' \
          "${_rel}" "${_lineno}" "${#_lint_tools_in[@]}" "${_named}"
        _violations=$(( _violations + 1 ))
      fi
    fi
  done < <(_derived_fold_annotations "${_file}")

  return "${_violations}"
}

# ── Figure 4: the drift-detection key set ───────────────────────────────────
#
# The fourth figure is a SET again: which `.env.generated` values
# `_check_setup_drift` reads back and compares. It reads five
# (`SETUP_CONF_HASH`, `SETUP_DOCKERFILE_HASH`, `SETUP_GUI_DETECTED`,
# `GPU_ENABLED`, `USER_UID`); the README's "Drift detection" section named
# three, one of which -- `SETUP_TIMESTAMP` -- is written and never compared
# by anything, and omitted the Dockerfile stage list, which is the one
# trigger a maintainer adding a `FROM ... AS <stage>` would come looking for.
# All three translations carried the same three names.
#
# Two rules, both derived:
#
#   - COMPLETENESS. Every key the function reads back has to be named in the
#     section. Derived from the read-back patterns in lib/drift.sh.
#   - SOUNDNESS. A `SETUP_*` key that setup.sh WRITES but drift never reads
#     back must not appear in the section at all. `SETUP_*` is the
#     drift-metadata namespace env_emit.sh writes, so the candidate set is
#     derived too, and an inert key named in a section about comparison is
#     read as compared.
#
# And one rule on the section next door. "When setup.sh runs" listed four
# triggers and opened with "setup.sh runs only when explicitly triggered",
# while the wrappers run `setup.sh check-drift` on every build and launch and
# re-run `setup.sh apply` when it fails -- so the list was missing the
# trigger that fires without anybody typing anything. The subcommand NAME is
# read out of the wrapper rather than written here, and the rule goes inert
# if the wrapper ever stops drift-checking, because the claim would then be
# true.

# The code that defines figure 4, and the two README sections that repeat it.
# A section is addressed by its English heading and by the `sync:` id the
# localized files carry above the translated heading -- the same id
# sync-readme-hashes.sh stamps -- so one lookup serves all four locales.
readonly _DERIVED_FIGURES_DRIFT_LIB='dist/script/docker/lib/drift.sh'
readonly _DERIVED_FIGURES_ENV_EMIT_LIB='dist/script/docker/lib/env_emit.sh'
readonly _DERIVED_FIGURES_WRAPPER_LIB='dist/script/docker/lib/wrapper.sh'
readonly _DERIVED_FIGURES_DRIFT_HEADING='### Drift detection'
readonly _DERIVED_FIGURES_DRIFT_ID='drift-detection'
readonly _DERIVED_FIGURES_RUNS_HEADING='### When setup.sh runs'
readonly _DERIVED_FIGURES_RUNS_ID='when-setupsh-runs'

# _derived_drift_keys -- the `.env.generated` keys _check_setup_drift reads
# back, one per line. Read off its own `'^KEY=\K...'` extraction patterns:
# that is where the set is decided, so a key added to the comparison appears
# here without anybody editing this driver.
_derived_drift_keys() {
  grep -oE "'\\^[A-Z][A-Z0-9_]*=" "${REPO_ROOT}/${_DERIVED_FIGURES_DRIFT_LIB}" \
    | tr -d "'^=" | sort -u
}

# _derived_setup_metadata_keys -- the `SETUP_*` keys env_emit.sh writes into
# `.env.generated`, one per line. The drift-metadata namespace: the candidate
# set for the soundness rule.
_derived_setup_metadata_keys() {
  grep -oE '^SETUP_[A-Z0-9_]*=' "${REPO_ROOT}/${_DERIVED_FIGURES_ENV_EMIT_LIB}" \
    | tr -d '=' | sort -u
}

# _derived_wrapper_drift_subcommand <out_var> -- the setup.sh subcommand the
# wrappers run on every build / launch to decide whether to regenerate.
# Empty when the wrappers no longer drift-check at all, which makes the
# trigger-list rule inert rather than wrong. Returns non-zero when more than
# one such subcommand exists, because then the name to document is ambiguous.
_derived_wrapper_drift_subcommand() {
  local -n _sub_out="$1"
  _sub_out=''
  local -a _subs=()
  mapfile -t _subs < <(
    grep -oE '[a-z]+-drift' "${REPO_ROOT}/${_DERIVED_FIGURES_WRAPPER_LIB}" \
      2>/dev/null | sort -u
  )
  [[ "${#_subs[@]}" -le 1 ]] || return 1
  [[ "${#_subs[@]}" -eq 1 ]] && _sub_out="${_subs[0]}"
  return 0
}

# _derived_section <file> <heading> <sync-id> <out_var> -- the body of one
# README section, one line per element.
#
# A localized README carries `<!-- sync: <id> ... -->` above its translated
# heading, so the id addresses the section in every language; the English
# original carries no markers, so there the heading itself does. Which of the
# two a file is, is read off the file (does it carry any marker at all),
# never off its name. The body ends at the next marker, or at the next
# markdown heading when there are none.
_derived_section() {
  local _file="$1" _heading="$2" _id="$3"
  local -n _body_out="$4"
  _body_out=()

  local _localized=0
  grep -qE '^<!-- sync: ' "${_file}" && _localized=1

  local -a _lines=()
  mapfile -t _lines < "${_file}"

  local _i _start=-1
  for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
    if (( _localized )); then
      [[ "${_lines[_i]}" == "<!-- sync: ${_id} "* ]] || continue
    else
      [[ "${_lines[_i]}" == "${_heading}" ]] || continue
    fi
    _start="${_i}"
    break
  done
  (( _start >= 0 )) || return 1

  for (( _i = _start + 1; _i < ${#_lines[@]}; _i++ )); do
    if (( _localized )); then
      [[ "${_lines[_i]}" == '<!-- sync: '* ]] && break
    else
      [[ "${_lines[_i]}" =~ ^#{1,6}[[:space:]] ]] && break
    fi
    _body_out+=( "${_lines[_i]}" )
  done
  return 0
}

# _derived_check_drift_keys <file> <rel> <drift_keys_var> <inert_keys_var>
#                          <drift_subcommand>
#
# Hold one locale's two sections to figure 4. Prints each violation and
# returns the count; a missing section is a violation too, named as one,
# because a renamed heading would otherwise silence the whole rule.
_derived_check_drift_keys() {
  local _file="$1" _rel="$2"
  local -n _keys_in="$3"
  local -n _inert_in="$4"
  local _drift_sub="$5"

  local _violations=0
  local -a _body=()
  local _text='' _line _key

  if ! _derived_section "${_file}" "${_DERIVED_FIGURES_DRIFT_HEADING}" \
      "${_DERIVED_FIGURES_DRIFT_ID}" _body; then
    printf "%s: no '%s' section (sync id '%s') -- the drift key set has nowhere to be pinned. Restore the section (the keys are %s) or move the pin in drivers/derived_figures.sh.\\n" \
      "${_rel}" "${_DERIVED_FIGURES_DRIFT_HEADING}" \
      "${_DERIVED_FIGURES_DRIFT_ID}" "$(_derived_join_comma "${_keys_in[@]}")"
    return 1
  fi

  _text=''
  for _line in "${_body[@]}"; do
    _text+="${_line} "
  done

  for _key in "${_keys_in[@]}"; do
    if [[ "${_text}" != *"${_key}"* ]]; then
      printf '%s: the drift section does not name %s, which _check_setup_drift reads back and compares (it compares %s)\n' \
        "${_rel}" "${_key}" "$(_derived_join_comma "${_keys_in[@]}")"
      _violations=$(( _violations + 1 ))
    fi
  done

  for _key in "${_inert_in[@]}"; do
    if [[ "${_text}" == *"${_key}"* ]]; then
      printf '%s: the drift section names %s, which setup.sh writes and nothing compares -- in a section about comparison it reads as compared\n' \
        "${_rel}" "${_key}"
      _violations=$(( _violations + 1 ))
    fi
  done

  # The trigger list next door. Inert when the wrappers no longer
  # drift-check, because the claim would then be true.
  [[ -n "${_drift_sub}" ]] || return "${_violations}"

  _body=()
  if ! _derived_section "${_file}" "${_DERIVED_FIGURES_RUNS_HEADING}" \
      "${_DERIVED_FIGURES_RUNS_ID}" _body; then
    printf "%s: no '%s' section (sync id '%s') -- the trigger list has nowhere to be pinned. Restore the section or move the pin in drivers/derived_figures.sh.\\n" \
      "${_rel}" "${_DERIVED_FIGURES_RUNS_HEADING}" \
      "${_DERIVED_FIGURES_RUNS_ID}"
    return $(( _violations + 1 ))
  fi

  _text=''
  for _line in "${_body[@]}"; do
    _text+="${_line} "
  done
  if [[ "${_text}" != *"${_drift_sub}"* ]]; then
    printf '%s: the trigger list does not name %s, which the wrappers run on every build and launch and regenerate on -- a trigger that fires without anybody typing anything\n' \
      "${_rel}" "${_drift_sub}"
    _violations=$(( _violations + 1 ))
  fi

  return "${_violations}"
}

# ── Figure 5: the command a shipped message tells a consumer to type ────────
#
# The fifth figure is a VOCABULARY: which `just` invocations the layering a
# consumer gets actually dispatches. Four `next:` hints -- printed at the
# exact moment a user has finished changing configuration and is asking how
# to apply it -- named `just build`, and the shipped entry justfile registers
# every action as a NAMESPACE (ADR-00000011, zero special case), so there is
# no top-level `build` recipe to reach. The instruction answered itself with
# `error: justfile does not contain recipe 'build'`, which reads as a broken
# install rather than a stale string, and it shipped to every downstream.
#
# Two reasons a remembered list would not have caught it. The four hints were
# pinned verbatim by four assertions, so the suite was green BECAUSE the
# string was wrong; and the same class had already been fixed twice by hand
# (base#1111's generated monitor workflow, base#1121's `just upgrade`), which
# is what a drift with no gate looks like.
#
# What is derived, and how:
#
#   - the NAMESPACES from the entry justfile's own `mod` / `mod?` lines, and
#     the recipes of each from the module file that line names. A namespace
#     added tomorrow is understood the day it lands.
#   - the TOP-LEVEL recipes from the entry's own recipe lines, which today is
#     `default` alone. That is the whole of the one-word vocabulary, and it is
#     read rather than asserted, so flattening the layering lifts the rule
#     instead of breaking it.
#   - the consumer's repo root from the entry's own location: the entry is
#     symlinked in as <repo>/script/justfile, so its mod paths resolve
#     against the directory ABOVE its own. Here that is dist/, derived, not
#     spelled.
#
# An `import`ed registry contributes nothing on purpose. script/local/
# justfile.local is repo-owned -- seeded with comments only by init.sh and
# never clobbered -- so what it defines is unknowable from base's tree, and a
# shipped message must not tell a user to run a recipe only their own repo
# might have.
#
# Scope, and the residual limits, stated rather than papered over:
#
#   - only dist/**/*.sh. That is the tree that ships, and the entry justfile
#     it ships beside it is the layering being derived; base's own root
#     justfile is a different one (it carries the `test` namespace), so
#     README.md and CONTEXT.md are deliberately not judged by this figure.
#   - only a SINGLE-QUOTED literal, and only on a line that is not a comment.
#     That pairing is what separates an instruction from prose about one: a
#     single-quoted command inside a message string is this tree's spelling
#     for "type this" (`'just --list'`, `'./stop.sh'`), while a comment is
#     maintainer prose -- the entry justfile's own docstring says there is no
#     top-level `just build`, and a rule that judged comments would fail on
#     the file that documents the hazard. A command spelled some other way
#     (backticked inside running prose, bare inside a usage heredoc) is NOT
#     detected; every one of the four live defects is single-quoted.
#   - retired ROOT WRAPPER paths (`./setup.sh`, `./stop.sh`) are a separate
#     question with a separate population -- the names init.sh deletes on
#     sight -- and they are not derived here.
readonly _DERIVED_FIGURES_ENTRY_JUSTFILE='dist/script/justfile'

# A single-quoted `just` invocation inside a message string.
readonly _DERIVED_FIGURES_JUST_LITERAL_RE="'(just([[:space:]]+[^']*)?)'"

# A token standing in for whatever the reader substitutes, rather than naming
# a recipe. `just <verb> [args...]` is a shape, not an invocation, and
# `{{args}}` / `${_ver}` are expanded before anybody reads them.
readonly _DERIVED_FIGURES_PLACEHOLDER_RE='[<>{}$%*[]'

# _derived_justfile_recipes <file> -- the recipe names a justfile defines,
# one per line, aliases included.
#
# A recipe line is at column 0, opens with the name, may carry parameters
# and dependencies, and reaches a colon. `set x := y` is a SETTING and
# `alias h := help` is an alias, so a `:=` line is never read as a recipe --
# the alias is picked up by its own rule instead, because `just docker h` is
# as dispatchable as `just docker help`. `mod` / `import` lines define no
# recipe of their own and are read by the caller.
_derived_justfile_recipes() {
  awk '
    /:=/ {
      if ($1 == "alias") { print $2 }
      next
    }
    /^(mod|mod\?|import|import\?)[[:space:]]/ { next }
    /^[a-z_][a-zA-Z0-9_-]*([[:space:]][^:]*)?:/ {
      name = $1
      sub(/:.*$/, "", name)
      if (name != "") { print name }
    }
  ' "$1"
}

# _derived_entry_modules <file> -- one `<namespace> <module-path>` line per
# `mod` / `mod?` line of the entry justfile. The path is repo-root-relative
# in the consumer, which is how the caller resolves it.
_derived_entry_modules() {
  awk "
    /^(mod|mod\?)[[:space:]]/ {
      path = \$0
      if (sub(/^[^']*'/, \"\", path) && sub(/'.*\$/, \"\", path)) {
        print \$2, path
      } else {
        print \$2
      }
    }
  " "$1"
}

# _derived_consumer_just_commands <out_var> -- every invocation prefix the
# consumer's layering dispatches, one per element: each top-level recipe of
# the entry, each namespace on its own (which lists it), and each
# `<namespace> <recipe>` pair. Returns non-zero when the entry is missing or
# names a module file that is not there, because a command set derived from
# half a layering would report the shipped tree rather than the gap.
_derived_consumer_just_commands() {
  local -n _cmds_out="$1"
  _cmds_out=()

  local _entry="${REPO_ROOT}/${_DERIVED_FIGURES_ENTRY_JUSTFILE}"
  [[ -f "${_entry}" ]] || return 1

  # The consumer repo root the mod paths resolve against: the entry is
  # symlinked in as <repo>/script/justfile, so it is the directory above the
  # entry's own.
  local _consumer_root
  _consumer_root="$(dirname "$(dirname "${_entry}")")"

  local _recipe
  while IFS= read -r _recipe; do
    [[ -n "${_recipe}" ]] && _cmds_out+=( "${_recipe}" )
  done < <(_derived_justfile_recipes "${_entry}")

  local _ns _path _module
  while read -r _ns _path; do
    [[ -n "${_ns}" ]] || continue
    [[ -n "${_path}" ]] || return 2
    _module="${_consumer_root}/${_path}"
    [[ -f "${_module}" ]] || return 2
    _cmds_out+=( "${_ns}" )
    while IFS= read -r _recipe; do
      [[ -n "${_recipe}" ]] && _cmds_out+=( "${_ns} ${_recipe}" )
    done < <(_derived_justfile_recipes "${_module}")
  done < <(_derived_entry_modules "${_entry}")

  [[ "${#_cmds_out[@]}" -gt 0 ]] || return 3
  return 0
}

# Every helper below takes the command array by NAME and binds it to a
# nameref of its own distinct spelling. One shared spelling would be a
# CIRCULAR name reference the moment a helper passed the array on to a
# sibling: bash resolves `local -n x="x"` to nothing, silently, so the
# namespace lookup answered "not a namespace" for every token and the
# correct namespaced spelling was reported as the violation.
#
# _derived_is_known_command <candidate> <commands_var>
_derived_is_known_command() {
  local _cand="$1"
  local -n _dkc_cmds="$2"
  local _known
  for _known in "${_dkc_cmds[@]}"; do
    [[ "${_known}" == "${_cand}" ]] && return 0
  done
  return 1
}

# _derived_is_namespace <token> <commands_var> -- does this token open a
# two-word invocation? True when some derived command is "<token> <recipe>".
_derived_is_namespace() {
  local _tok="$1"
  local -n _dins_cmds="$2"
  local _known
  for _known in "${_dins_cmds[@]}"; do
    [[ "${_known}" == "${_tok} "* ]] && return 0
  done
  return 1
}

# _derived_namespaced_spellings <verb> <commands_var> -- every
# `<namespace> <verb>` the layering does dispatch, comma-joined. The repair
# for the live defect is exactly this, so the message hands it over rather
# than leaving the reader to read two justfiles.
_derived_namespaced_spellings() {
  local _verb="$1"
  local -n _dns_cmds="$2"
  local -a _hits=()
  local _known
  for _known in "${_dns_cmds[@]}"; do
    [[ "${_known}" == *" ${_verb}" ]] && _hits+=( "just ${_known}" )
  done
  [[ "${#_hits[@]}" -gt 0 ]] && _derived_join_comma "${_hits[@]}"
}

# _derived_just_candidate <invocation> <commands_var_name> <out_var> -- the
# invocation prefix to judge, or empty when there is nothing to judge.
#
# Bare `just` runs the default recipe. A leading dash is one of the runner's
# own options, not a recipe. A placeholder is a shape. Otherwise the first
# token is the candidate, widened to two words when it is a namespace and a
# real second token follows -- so `just docker build test` is judged as
# `docker build` and its trailing arguments are not read as recipe names.
_derived_just_candidate() {
  local _cmds_name="$2"
  local -n _djc_out="$3"
  _djc_out=''

  local -a _tok=()
  read -r -a _tok <<< "$1"
  local _first="${_tok[1]:-}" _second="${_tok[2]:-}"
  [[ -n "${_first}" ]] || return 0
  [[ "${_first}" == -* ]] && return 0
  [[ "${_first}" =~ ${_DERIVED_FIGURES_PLACEHOLDER_RE} ]] && return 0

  _djc_out="${_first}"
  if _derived_is_namespace "${_first}" "${_cmds_name}" \
    && [[ -n "${_second}" && "${_second}" != -* ]] \
    && [[ ! "${_second}" =~ ${_DERIVED_FIGURES_PLACEHOLDER_RE} ]]; then
    _djc_out="${_first} ${_second}"
  fi
  return 0
}

# _derived_scan_just_literals <file> <rel> <commands_var_name>
#
# Report every single-quoted `just` invocation in <file> that the consumer's
# layering does not dispatch. Prints one violation per hit and returns the
# count.
_derived_scan_just_literals() {
  local _file="$1" _rel="$2" _cmds_name="$3"
  local _violations=0

  local _lineno=0 _line _rest _match _invocation _cand _repair
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    [[ "${_line}" =~ ^[[:space:]]*# ]] && continue
    _rest="${_line}"
    while [[ "${_rest}" =~ ${_DERIVED_FIGURES_JUST_LITERAL_RE} ]]; do
      _match="${BASH_REMATCH[0]}"
      _invocation="${BASH_REMATCH[1]}"
      _rest="${_rest#*"${_match}"}"

      _cand=''
      _derived_just_candidate "${_invocation}" "${_cmds_name}" _cand
      [[ -n "${_cand}" ]] || continue
      _derived_is_known_command "${_cand}" "${_cmds_name}" && continue

      _repair="$(_derived_namespaced_spellings "${_cand}" "${_cmds_name}")"
      if [[ -n "${_repair}" ]]; then
        _repair=" -- the layering dispatches ${_repair}"
      else
        _repair=''
      fi
      printf "%s:%s: tells the user to run '%s', and the consumer's layering has no '%s'%s\n" \
        "${_rel}" "${_lineno}" "${_invocation}" "${_cand}" "${_repair}"
      _violations=$(( _violations + 1 ))
    done
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

  # Figure 4's sections live in the READMEs only -- CONTEXT.md is the
  # architecture note and carries neither. The English original plus every
  # localized file, each required: a locale that drops a section is a
  # reported violation, not a silent pass. Collected INSIDE the nullglob
  # region with the other surfaces, so a tree with no translations yet
  # yields no surface rather than the unexpanded glob.
  local -a _doc_surfaces=( "${REPO_ROOT}/${_DERIVED_FIGURES_README}" )

  local _nullglob_was_set=0
  shopt -q nullglob && _nullglob_was_set=1
  shopt -s nullglob
  local _localized
  for _localized in \
    "${REPO_ROOT}/${_DERIVED_FIGURES_DOC_DIR}"/${_DERIVED_FIGURES_DOC_GLOB}; do
    _files+=( "${_localized}" )
    _doc_surfaces+=( "${_localized}" )
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
  # Figure 5 judges the SHIPPED tree alone: its entry justfile is the
  # layering being derived, while base's own root justfile carries a `test`
  # namespace no consumer gets. Collected here so one find serves both.
  local -a _shipped_surfaces=()
  local _file
  while IFS= read -r -d '' _file; do
    _files+=( "${_file}" )
    _shipped_surfaces+=( "${_file}" )
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

  local _coverage_skips_lint=''
  if ! _derived_coverage_skips_lint _coverage_skips_lint; then
    _die ci_derived_figures \
      "found no _run_all_lint_tools call under an if in ${_DERIVED_FIGURES_RUNNER} -- whether a coverage run reaches the lint phase is then unanswerable, and prose about it cannot be judged."
    return 1
  fi

  for _file in "${_cmd_surfaces[@]}"; do
    _hits=0
    _derived_scan_cmd_annotations \
      "${_file}" "${_file#"${REPO_ROOT}"/}" "${_coverage}" _subcmds \
      _lint_tools "${_coverage_skips_lint}" || _hits=$?
    _violations=$(( _violations + _hits ))
  done

  # Figure 4. The key sets come out of the shipped libs; each refuses loudly
  # when the lib it reads is not there, because an empty set would make the
  # completeness rule pass over every locale at once.
  local -a _drift_keys=() _meta_keys=() _inert_keys=()
  mapfile -t _drift_keys < <(_derived_drift_keys)
  if [[ "${#_drift_keys[@]}" -eq 0 ]]; then
    _die ci_derived_figures \
      "read no read-back keys out of ${_DERIVED_FIGURES_DRIFT_LIB} -- what drift detection compares is then unknown, and the prose that lists it would pass unchecked."
    return 1
  fi
  mapfile -t _meta_keys < <(_derived_setup_metadata_keys)
  if [[ "${#_meta_keys[@]}" -eq 0 ]]; then
    _die ci_derived_figures \
      "read no SETUP_* keys out of ${_DERIVED_FIGURES_ENV_EMIT_LIB} -- the drift metadata namespace is then unknown."
    return 1
  fi
  local _meta _drift_key _is_compared
  for _meta in "${_meta_keys[@]}"; do
    _is_compared=0
    for _drift_key in "${_drift_keys[@]}"; do
      [[ "${_meta}" == "${_drift_key}" ]] && _is_compared=1 && break
    done
    (( _is_compared )) || _inert_keys+=( "${_meta}" )
  done

  local _drift_sub=''
  if ! _derived_wrapper_drift_subcommand _drift_sub; then
    _die ci_derived_figures \
      "${_DERIVED_FIGURES_WRAPPER_LIB} names more than one *-drift subcommand -- which one the trigger list must document is then ambiguous."
    return 1
  fi

  for _file in "${_doc_surfaces[@]}"; do
    _hits=0
    _derived_check_drift_keys \
      "${_file}" "${_file#"${REPO_ROOT}"/}" _drift_keys _inert_keys \
      "${_drift_sub}" || _hits=$?
    _violations=$(( _violations + _hits ))
  done

  # Figure 5. The command vocabulary refuses loudly rather than reporting
  # every instruction in the shipped tree: an empty or half-read layering
  # makes each correct hint look wrong, which buries the one missing file
  # under its own consequences.
  local -a _just_cmds=()
  local _cmds_rc=0
  _derived_consumer_just_commands _just_cmds || _cmds_rc=$?
  case "${_cmds_rc}" in
    0) ;;
    1)
      _die ci_derived_figures \
        "'${_DERIVED_FIGURES_ENTRY_JUSTFILE}' not found under ${REPO_ROOT} -- which 'just' commands a consumer has cannot be derived, and a lint that cannot derive them must not pass. Point it at the shipped entry justfile."
      return 1
      ;;
    2)
      _die ci_derived_figures \
        "a 'mod' line in ${_DERIVED_FIGURES_ENTRY_JUSTFILE} names a module file that is not there (or names none) -- the command vocabulary would be missing that whole namespace, and every correct instruction naming it would be reported."
      return 1
      ;;
    *)
      _die ci_derived_figures \
        "read no recipes and no namespaces out of ${_DERIVED_FIGURES_ENTRY_JUSTFILE} -- every documented 'just' command would then be a violation."
      return 1
      ;;
  esac

  for _file in "${_shipped_surfaces[@]}"; do
    _hits=0
    _derived_scan_just_literals \
      "${_file}" "${_file#"${REPO_ROOT}"/}" _just_cmds || _hits=$?
    _violations=$(( _violations + _hits ))
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_derived_figures \
      "${_violations} document figure(s) disagree with the code that defines them. The baseline stage blocklist is whatever _validate_stage_name returns 2 for -- currently $(_derived_join_comma "${_renderings[@]}") -- and 'devel-test' is NOT in it (it is emitted as the 'test' service). The setup.conf section list and its count are SCHEMA_SECTIONS. What a bare 'just test' measures is the coverage argument of _run_via_compose ci, and what a bare 'just test lint' runs is the whole _LINT_TOOLS table. The drift key set is whatever _check_setup_drift reads back. The 'just' commands a consumer has are the entry justfile's own recipes plus one per '<namespace> <recipe>' pair its mod lines reach. Fix the prose, not the predicate."
    return 1
  fi
  echo "derived-figure lint: clean"
}
