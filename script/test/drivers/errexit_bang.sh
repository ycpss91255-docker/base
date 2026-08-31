#!/usr/bin/env bash
# drivers/errexit_bang.sh - "a `!` statement that is not last cannot fail
# its test" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_errexit_bang.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/early_close_reader.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main, region-delimited opt-out).
#
# Why: bash does not exit on a command whose failure is part of a `!`
# expression. A bats test body is a function run under errexit whose
# RETURN STATUS is the verdict, so `! <cmd>` is an assertion in exactly
# one position -- the body's last statement, where its status becomes the
# body's. Anywhere else the command runs, the negation is computed, and
# the answer is thrown away. The line LOOKS like an assertion, reviews
# like one, and cannot fail.
#
# That is worse than a missing test: the case name claims a property the
# body does not check, so the gap is invisible to the next reader.
# base#956 found two live instances (compose_watchdog_spec's
# WATCHDOG_INTERVAL half, inert while the WATCHDOG_NOTIFY line below it
# did the work; tui_flow_spec's cleared-override check) and both were
# found by auditing the whole tree by hand -- for the second time in one
# review round. The rule is mechanical, so it stops being an audit.
#
# Scope: *.bats under test/bats/ -- the tree where a test body's return
# status is the verdict. NOT dist/ or script/: a `!` in ordinary shell is
# usually an `if` condition or a deliberate errexit escape, both of which
# are correct.
#
# What is a violation: inside a `@test ... {` body, a STATEMENT whose
# first token is `!`, when the statement does not end on the body's last
# statement line.
#
# What is NOT:
#   - the body's last statement (across a `\` continuation, and with any
#     number of trailing comment / blank lines after it).
#   - a line that CONTINUES the previous one. `find ... \` + `! -name x`
#     is a find predicate, not a statement, and the tree has one.
#   - a `!` outside any test body (a file-scope helper function): errexit
#     there is the caller's problem and this rule says nothing about it.
#   - a comment. Prose about the shape must not violate it.
#
# Known limitation, stated rather than papered over: a heredoc body
# inside a test is not tracked, so a fixture line beginning with `! `
# inside one would be read as a statement. The tree has no such line
# today, and a heredoc tracker would be a second bash parser; the allow
# region below is the answer if one ever appears.
#
# Population: the scan root must exist and must yield at least one spec,
# and every `@test` header found by a plain text scan must correspond to
# a body this parser actually opened. Without that cross-check a header
# whose `{` sits on the next line would make its whole body invisible and
# the lint would pass by not looking.
#
# Allowlist: an explicit, region-delimited opt-out rather than a per-file
# exclusion, so a NEW inert assertion elsewhere in an allowlisted file is
# still caught. Bracket the line with
#   # errexit-bang-lint: allow-begin -- <why>
#   ...
#   # errexit-bang-lint: allow-end
# There is no live region today. Unbalanced markers (an unterminated
# begin, an unmatched end) fail the lint -- a silently swallowed region
# would re-open exactly the hole this closes.

# ── Non-final `!` statement lint ─────────────────────────────────────────────

# The scanned tree, repo-root-relative. It must exist and must hold
# specs: a missing or empty root would make the scan pass vacuously.
readonly _ERREXIT_BANG_SCAN_ROOT='test/bats'

# The test-body opener. The `{` must close the line -- a header that does
# not match is not skipped quietly, it is counted and reported by the
# population cross-check below.
readonly _ERREXIT_BANG_TEST_OPEN_RE='^@test[[:space:]].*\{[[:space:]]*$'
# Any test header at all, for that cross-check.
readonly _ERREXIT_BANG_TEST_ANY_RE='^@test[[:space:]]'
# The body closer: a `}` in the first column, which is how every bats
# body in this tree ends.
readonly _ERREXIT_BANG_TEST_CLOSE_RE='^\}[[:space:]]*$'

# A statement whose first token is `!`. The trailing space matters:
# `!=` and `!(` are not this.
readonly _ERREXIT_BANG_STMT_RE='^[[:space:]]*![[:space:]]'
# A line continued onto the next one.
readonly _ERREXIT_BANG_CONT_RE='\\[[:space:]]*$'

# Region markers for the explicit opt-out (see the header note).
readonly _ERREXIT_BANG_ALLOW_BEGIN='errexit-bang-lint: allow-begin'
readonly _ERREXIT_BANG_ALLOW_END='errexit-bang-lint: allow-end'

# _errexit_bang_scan_file <abs_path> <rel_path> <rows_outvar> <headers_outvar>
#   Append one `<rel>:<line>: <text>` row per violation to <rows_outvar>
#   and add this file's `@test` header count to <headers_outvar>. Called
#   directly, never through a command substitution: both outputs are
#   namerefs, and a subshell would drop the count.
#
# One pass, this state: whether we are inside a body, whether the previous
# physical line continues onto this one, the pending `!` statements of the
# current body (start line, END line, text) and the line number of the
# body's last statement. A pending statement is judged only when the body
# closes -- "is this the last statement" is not knowable before then.
_errexit_bang_scan_file() {
  local _abs="${1}" _rel="${2}"
  local -n _ebsf_rows="${3}"
  local -n _ebsf_headers="${4}"

  local _line _lineno=0 _in_body=0 _prev_cont=0 _cont=0
  local _last_stmt=0 _in_allow=0 _begin_line=0 _bang_open=-1
  local -a _pending_line=() _pending_end=() _pending_text=()
  local _i

  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    _prev_cont="${_cont}"
    _cont=0
    [[ "${_line}" =~ ${_ERREXIT_BANG_CONT_RE} ]] && _cont=1

    if [[ "${_line}" == *"${_ERREXIT_BANG_ALLOW_BEGIN}"* ]]; then
      _in_allow=1
      _begin_line="${_lineno}"
      continue
    fi
    if [[ "${_line}" == *"${_ERREXIT_BANG_ALLOW_END}"* ]]; then
      if [[ "${_in_allow}" -eq 0 ]]; then
        _ebsf_rows+=("${_rel}:${_lineno}: unmatched allow-end (no open allow-begin)")
      fi
      _in_allow=0
      continue
    fi

    if [[ "${_line}" =~ ${_ERREXIT_BANG_TEST_ANY_RE} ]]; then
      _ebsf_headers=$(( _ebsf_headers + 1 ))
    fi

    if [[ "${_in_body}" -eq 0 ]]; then
      if [[ "${_line}" =~ ${_ERREXIT_BANG_TEST_OPEN_RE} ]]; then
        _in_body=1
        _last_stmt=0
        _bang_open=-1
        _pending_line=()
        _pending_end=()
        _pending_text=()
      fi
      continue
    fi

    if [[ "${_line}" =~ ${_ERREXIT_BANG_TEST_CLOSE_RE} ]]; then
      # The body is closed: every pending `!` whose statement did not END
      # on the body's last statement line was exempt from errexit and
      # could not have failed the test.
      for (( _i = 0; _i < ${#_pending_line[@]}; _i++ )); do
        if [[ "${_pending_end[_i]}" != "${_last_stmt}" ]]; then
          _ebsf_rows+=("${_rel}:${_pending_line[_i]}: ${_pending_text[_i]}")
        fi
      done
      _in_body=0
      continue
    fi

    # Blank and comment lines are not statements.
    [[ -z "${_line//[[:space:]]/}" ]] && continue
    [[ "${_line}" =~ ^[[:space:]]*# ]] && continue

    # A statement line. A continuation belongs to the statement that
    # started above it: it moves that statement's END (and the body's
    # last-statement mark) without starting a new one.
    _last_stmt="${_lineno}"
    if [[ "${_prev_cont}" -eq 1 ]]; then
      if [[ "${_bang_open}" -ge 0 ]]; then
        _pending_end[_bang_open]="${_lineno}"
        [[ "${_cont}" -eq 1 ]] || _bang_open=-1
      fi
      continue
    fi

    _bang_open=-1
    [[ "${_in_allow}" -eq 1 ]] && continue

    if [[ "${_line}" =~ ${_ERREXIT_BANG_STMT_RE} ]]; then
      _pending_line+=("${_lineno}")
      _pending_end+=("${_lineno}")
      _pending_text+=("${_line}")
      [[ "${_cont}" -eq 1 ]] && _bang_open=$(( ${#_pending_line[@]} - 1 ))
    fi
  done < "${_abs}"

  if [[ "${_in_allow}" -eq 1 ]]; then
    _ebsf_rows+=("${_rel}:${_begin_line}: unterminated allow-begin (no closing allow-end)")
  fi
}

_run_errexit_bang() {
  echo "--- Running non-final bang-statement lint ---"
  local _abs_root="${REPO_ROOT}/${_ERREXIT_BANG_SCAN_ROOT}"
  if [[ ! -d "${_abs_root}" ]]; then
    _die ci_errexit_bang \
      "scan root '${_ERREXIT_BANG_SCAN_ROOT}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the bats tree, where a test body's return status is the verdict."
    return 1
  fi

  local -a _files=()
  local _file
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_abs_root}" -name '*.bats' -type f -print0 2>/dev/null \
    | sort -z)

  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_errexit_bang \
      "no *.bats under ${_ERREXIT_BANG_SCAN_ROOT}/ -- a scan with no population is not a pass."
    return 1
  fi

  local _headers=0 _bodies=0 _rel _row _cnt _cst
  local -a _rows=()
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _errexit_bang_scan_file "${_file}" "${_rel}" _rows _headers
  done
  for _row in ${_rows[@]+"${_rows[@]}"}; do
    printf '%s\n' "${_row}"
  done
  local _violations="${#_rows[@]}"

  # Population cross-check: every `@test` header the plain text scan
  # counted must be a body the parser opened. A header the opener regex
  # does not match takes its whole body out of the rule's reach, and a
  # lint that passes by not looking is the defect this one is about.
  # grep's status is pinned to 0/1 for the same reason -- a 2 here would
  # otherwise read as "this file has no bodies".
  for _file in "${_files[@]}"; do
    _cst=0
    _cnt="$(grep -cE "${_ERREXIT_BANG_TEST_OPEN_RE}" "${_file}")" || _cst=$?
    if [[ "${_cst}" -gt 1 ]]; then
      _die ci_errexit_bang \
        "could not scan ${_file#"${REPO_ROOT}"/} for test headers (grep exit ${_cst}). A file the lint cannot read is not a file with nothing in it."
      return 1
    fi
    _bodies=$(( _bodies + _cnt ))
  done
  if [[ "${_headers}" -ne "${_bodies}" ]]; then
    _die ci_errexit_bang \
      "${_headers} '@test' header(s) under ${_ERREXIT_BANG_SCAN_ROOT}/ but only ${_bodies} body/bodies the parser could open. A header whose '{' is not the last character of its line hides its whole body from this lint. Put the opening brace at the end of the '@test' line."
    return 1
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_errexit_bang \
      "${_violations} non-final '!' statement(s) / unbalanced allow marker(s) under ${_ERREXIT_BANG_SCAN_ROOT}/. bash exempts a '!' pipeline from errexit, so such a line is an assertion ONLY as a test body's last statement -- anywhere else the command runs, the negation is computed and the answer is discarded, and the test passes whatever the code did. Assert it with an explicit 'if <cmd>; then <message>; return 1; fi', with 'refute'/'refute_output', or move it to the end of the body. A line that genuinely cannot be written that way opts out by bracketing it with '# ${_ERREXIT_BANG_ALLOW_BEGIN} -- <why>' / '# ${_ERREXIT_BANG_ALLOW_END}'."
    return 1
  fi
  echo "non-final bang-statement lint: clean"
}
