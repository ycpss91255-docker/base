#!/usr/bin/env bash
# drivers/test_name_backtick.sh - "a `@test` name is a literal, not a
# command" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_test_name_backtick.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/errexit_bang.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main, population derived by one walk).
#
# ── What bats does with a name, measured ─────────────────────────────────
#
# bats does not treat a `@test` name as a string. Its registration site --
# bats 1.13.0, lib/bats-core/test_functions.bash:471, inside
# bats_test_function -- is
#
#   eval "printf -v test_description '%s' \"$2\""
#
# carrying the upstream comment "use eval to resolve variable references
# in test names". The name is RE-QUOTED in double quotes and eval'd, so an
# unescaped backtick in it is command substitution and bats RUNS it: at
# REGISTRATION, before any test has been selected, once per test the file
# registers, in every invocation that sources the file -- the plain run,
# each `--filter` probe, and each kcov coverage shard.
#
# base#1200 measured both halves on this tree's two offenders. One run of
# `test.sh --bats-path test/bats/unit/self_test_yaml_spec.bats` emitted 125
# copies of each of
#
#   error: justfile does not contain recipe `template`
#   /opt/bats/lib/bats-core/test_functions.bash: line 471: test:: command not found
#
# -- one per registration of a 124-test file -- and reported the names
# with the backticked span replaced by the substitution's empty stdout, so
# that `no monolithic `test:` job remains ...` was registered and printed
# as `no monolithic  job remains ...`, two spaces and nothing between
# them. That is not the name in the source, so the TAP output and the catalogue
# under doc/test/ disagree about what the suite contains. The noise and
# the divergence are today's cost; the hazard is that the mechanism is
# arbitrary command execution, and the next name to carry a backticked
# command gets it run by every bats invocation with no test selected.
#
# ── Why this models no quoting ──────────────────────────────────────────
#
# The author's quoting does not enter into it. bats's preprocessor strips
# the quotes the source wrote and the eval above supplies its own, so a
# SINGLE-quoted name is expanded exactly like a double-quoted one.
# Measured on bats 1.13.0, one file, four names:
#
#   @test "dq with `echo HI` inside"      -> ok 1 dq with HI inside
#   @test 'sq with `echo HI` inside'      -> ok 2 sq with HI inside
#   @test "dq with escaped \`tick\` ..."  -> ok 3 dq with escaped `tick` ...
#   @test "dq with $(echo SUB) inside"    -> ok 4 dq with SUB inside
#
# So the whole `@test` LINE is judged and no quoting is parsed: a rule
# that exempted single quotes would exempt a name bats still executes, and
# single-quoting is not a fix for this defect even though it reads like
# one.
#
# ── What a fix looks like, and why the backslash is not the first one ───
#
# TWO spellings leave nothing to execute, and they are not equivalent.
#
# DROP the backticks, and write the code span the way 178 of this tree's
# names already write one -- in single quotes inside the double-quoted
# name, 'just template new'. The name is then the same bytes in the
# source, in the TAP output and in the catalogue row.
#
# ESCAPE them. An escaped backtick is a literal one -- row 3 above -- and
# the catalogue generator collapses it back to a bare backtick when it
# renders a row (_spec_marker_unescape_into in
# script/test/spec-markers.sh, there "so a row can be pasted straight into
# --filter"). So bats registers the backticks and the catalogue prints
# them, and nothing runs. It is NOT a finding here, because there is
# nothing to find.
#
# base#1200 took the first, on a third measured fact: `--filter` is matched
# against the name as the SOURCE writes it, not against the name bats
# registers. bats-gather-tests takes its `description` straight from the
# preprocessed line and never eval's it, so an escaped source keeps its
# backslashes in the only string the filter sees -- `--filter` on the
# catalogue row stops matching, which is the property the unescaping above
# exists to provide. The tree's twenty-odd backslash-escaped `$` names are
# already in that state; two more is the wrong direction, and single
# quotes are what the tree reaches for anyway.
#
# ── Scope ───────────────────────────────────────────────────────────────
#
# EVERY *.bats file in the repo, wherever it sits. The population is
# DERIVED at run time by one `find` over ${REPO_ROOT}, never listed: the
# repo has two live bats trees today (test/bats/ and the shipped
# dist/test/bats/smoke/, which `just test smoke` runs and the .base subtree
# vendors into every downstream repo), and a hand-written roster would
# exempt the third one the day it is added. Two directories are pruned and
# both are non-source: `.git`, and `.prev-release/` (gitignored copies of
# ALREADY-RELEASED trees that script/test/prepare-prev-release.sh
# materialises with `git archive`, where a finding is unfixable history
# rather than a defect on this branch).
#
# `$(...)` and `${VAR}` in a name are the same mechanism and are NOT
# judged here. The direction that matters -- this driver never reports a
# name bats leaves alone -- is unaffected, and the tree's twenty-odd
# `\$(...)` / `\${...}` names are already escaped, so a rule over the bare
# forms would have nothing to find. base#1200's bound is the backtick; the
# escape-aware reader below is the half that would be reused.
#
# ── What is not modelled, and which way each errs ───────────────────────
#
# OVER-reports, which is the refusing direction. An indented `@test` inside
# a quoted heredoc is fixture TEXT, and it is reported. bats's preprocessor
# rewrites it -- it is a line filter with no heredoc model, so the fixture's
# own text is rewritten in place -- but the enclosing shell then reads that
# as heredoc content and registers nothing, so nothing is executed there.
# A scan over text cannot tell that line from a declaration, and the
# fixture is often written out and run by an inner bats, where the name IS
# registered. 21 such lines exist in this tree today and none carries a
# backtick.
#
# UNDER-reports. bats's second declaration form, BATS_TEST_PATTERN_COMMENT
# (`some_function() { # @test`), is not read: there the name is a FUNCTION
# name, which cannot hold a space, so a backticked command is not a shape
# it can carry. This tree uses the form zero times.
#
# ── Non-vacuity ─────────────────────────────────────────────────────────
#
# THREE ways this could go green having checked nothing, each a _die: a
# walk that failed part way through (a short list reads as "less to
# check"), a walk that found no *.bats at all (the specs moved), and a
# scan that read no `@test` line ANYWHERE (4848 exist today, so zero means
# the anchor has gone blind -- a renamed keyword, a changed convention --
# and a blind detector reports a clean tree).

# ── @test name backtick lint ────────────────────────────────────────────────

# Non-source directories. See the Scope note above for why each is here;
# nothing else is skipped.
readonly _TNB_PRUNE_DIRS=('.git' '.prev-release')

# What looks like a test declaration, and what bats makes of one. BOTH are
# bats's own, copied from libexec/bats-core/bats-preprocess rather than
# written here, because the string this lint judges has to be the string
# bats eval's and nothing else.
#
# The anchor is BATS_TEST_PATTERN's opening, so a declaration INDENTED by
# spaces or tabs is in the population: bats accepts one and registers the
# test, backticks and all. An anchor pinned to column 0 skipped them while
# bats still ran them, and the non-empty-population check below could not
# notice, because a file's other tests satisfy it.
#
# _TNB_DESCRIPTION_RE is BATS_TEST_PATTERN itself with ONE change -- the
# leading blanks and `@test` are captured as group 1, so the length of that
# prefix gives the description's column offset in the line. Group 2 is
# bats's description group: everything BEFORE the final ` {`. The
# preprocessor then takes `body="${BASH_REMATCH[2]}"` -- everything after
# the brace -- as the body's first line, so a trailing comment there is
# body and never reaches the eval. Judging the whole line reported those as
# findings; 26 `@test` lines in this tree carry text after the brace.
#
# This population is NOT the catalogue's. script/test/spec-markers.sh
# anchors on `^@test` at column 0, as does the `grep -cE '^@test'` the
# per-spec counts use, so an indented declaration is a test bats runs and
# the catalogue cannot see. Zero exist today. That gap is a defect in the
# catalogue's reader rather than in this lint, and it is outside
# base#1200's bound; what matters here is that this lint judges every name
# bats registers, which is the superset.
readonly _TNB_TEST_ANCHOR_RE='^[[:blank:]]*@test[[:blank:]]'
readonly _TNB_DESCRIPTION_RE='^([[:blank:]]*@test[[:blank:]]+)(.*[^[:blank:]])[[:blank:]]+\{(.*)$'

# _tnb_collect <files_outvar>
#   Fill <files_outvar> with every *.bats in the repo, sorted, pruning the
#   non-source directories. find's status is CAPTURED (the walk writes to
#   a temp file rather than into a pipeline, whose status would belong to
#   `sort`), because a walk that died half way through would otherwise
#   hand the lint a short list and read as "there is less to check".
_tnb_collect() {
  local -n _tnbc_files="${1}"
  local -a _prune=()
  local _d
  for _d in "${_TNB_PRUNE_DIRS[@]}"; do
    [[ "${#_prune[@]}" -eq 0 ]] || _prune+=('-o')
    _prune+=('-name' "${_d}")
  done

  local _tmp _st=0
  _tmp="$(mktemp)" || return 1
  find "${REPO_ROOT}" \( "${_prune[@]}" \) -prune -o \
    -name '*.bats' -type f -print0 > "${_tmp}" || _st=$?
  if [[ "${_st}" -ne 0 ]]; then
    rm -f "${_tmp}"
    return "${_st}"
  fi

  local _file
  while IFS= read -r -d '' _file; do
    _tnbc_files+=("${_file}")
  done < <(sort -z < "${_tmp}")
  rm -f "${_tmp}"
}

# _tnb_live_backtick_col <line>
#   Print the 1-based column of the first backtick in <line> that a
#   backslash does not escape, and return 0; return 1 when the line
#   carries none.
#
#   A backtick is escaped when the backslash run immediately before it has
#   ODD length, which is what bash does inside the double quotes bats
#   supplies: `\\\`` is a literal backslash followed by a live backtick,
#   and this counts the run rather than looking one character back so that
#   case is read the way bash reads it.
_tnb_live_backtick_col() {
  local _line="${1}" _bs=0 _i _ch
  # Spelled as an ANSI-C quote, the same way spec-markers.sh writes it:
  # a lone backslash inside '...' reads to ShellCheck as a mis-escaped
  # single quote (SC1003).
  local _backslash=$'\\'
  local _len="${#_line}"
  for (( _i = 0; _i < _len; _i++ )); do
    _ch="${_line:_i:1}"
    if [[ "${_ch}" == "${_backslash}" ]]; then
      _bs=$(( _bs + 1 ))
      continue
    fi
    if [[ "${_ch}" == '`' && $(( _bs % 2 )) -eq 0 ]]; then
      printf '%d\n' "$(( _i + 1 ))"
      return 0
    fi
    _bs=0
  done
  return 1
}

# _tnb_scan_file <path> <rel> <rows_outvar> <names_outvar>
#   Append one row per offending `@test` line in <path>, and add the number
#   of names READ to <names_outvar>. One row per line and not per backtick:
#   the author fixes the name, not a character, and the column names where
#   to start looking.
#
#   A line the anchor matches but bats's own pattern cannot read is a row
#   too, with its own sentence. It is a line this lint cannot judge, and an
#   unreadable line is a failure rather than a skip -- the same rule the
#   failed walk follows: skipping it would take the name out of the rule's
#   reach with the gate green.
_tnb_scan_file() {
  local _path="${1}" _rel="${2}"
  local -n _tnbs_rows="${3}"
  local -n _tnbs_names="${4}"
  local _line _col _desc _prefix _lineno=0

  # `|| [[ -n ... ]]`: a final line with no trailing newline is still a
  # line, and a spec file is exactly the kind of file an editor leaves
  # that way.
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    [[ "${_line}" =~ ${_TNB_TEST_ANCHOR_RE} ]] || continue
    if [[ ! "${_line}" =~ ${_TNB_DESCRIPTION_RE} ]]; then
      _tnbs_rows+=("${_rel}:${_lineno}: a '@test' line bats's own pattern cannot read -- ${_line}")
      continue
    fi
    _prefix="${BASH_REMATCH[1]}"
    _desc="${BASH_REMATCH[2]}"
    _tnbs_names=$(( _tnbs_names + 1 ))
    if _col="$(_tnb_live_backtick_col "${_desc}")"; then
      _tnbs_rows+=("${_rel}:${_lineno}:$(( ${#_prefix} + _col )): ${_line}")
    fi
  done < "${_path}"
}

_run_test_name_backtick() {
  echo "--- Running @test name backtick lint ---"

  local -a _files=()
  local _find_st=0
  _tnb_collect _files || _find_st=$?
  if [[ "${_find_st}" -ne 0 ]]; then
    _die ci_test_name_backtick \
      "the walk for *.bats under ${REPO_ROOT} failed (exit ${_find_st}) -- a scan that could not finish is not a scan that found nothing."
    return 1
  fi
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_test_name_backtick \
      "no *.bats anywhere under ${REPO_ROOT} (pruning ${_TNB_PRUNE_DIRS[*]}) -- a scan with no population is not a pass. This lint derives its population from the tree; an empty one means the specs moved, not that they are clean."
    return 1
  fi

  local -a _rows=()
  local _names=0 _file _rel
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _tnb_scan_file "${_file}" "${_rel}" _rows _names
  done

  if [[ "${_names}" -eq 0 && "${#_rows[@]}" -eq 0 ]]; then
    _die ci_test_name_backtick \
      "no '@test' line in any of the ${#_files[@]} *.bats file(s) under ${REPO_ROOT} -- the anchor read nothing, so every name would be clean vacuously. Either the specs declare their tests some other way now, or this lint's anchor has gone blind."
    return 1
  fi

  if [[ "${#_rows[@]}" -gt 0 ]]; then
    printf '%s\n' "${_rows[@]}"
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_test_name_backtick \
      "${#_rows[@]} finding(s) across the ${#_files[@]} *.bats file(s) in this repo: a '@test' name carrying an unescaped backtick, or a '@test' line bats's own pattern cannot read. bats eval's a test name when it REGISTERS the test (lib/bats-core/test_functions.bash, \"use eval to resolve variable references in test names\"), so a live backtick there is command substitution that runs once per registration -- with no test selected, in every run and in every coverage shard -- and the name bats then reports is the substitution's OUTPUT, not the name in the source, which puts the TAP output and doc/test/ out of agreement. Changing the SHELL quoting is not the fix: bats supplies its own quotes, so a single-quoted name is expanded too. Drop the backticks and write the span the way 178 names here already do, in single quotes inside the name -- 'just template new' -- which leaves the name identical in the source, in the TAP output and in the catalogue row. A backslash-escaped backtick is inert too and this lint does not report it, but --filter is matched against the name as the SOURCE writes it, so the backslashes stay in the one string the filter sees and the catalogue row stops being pasteable into it."
    return 1
  fi
  echo "@test name backtick lint: clean (${_names} test name(s) across ${#_files[@]} spec file(s))"
}
