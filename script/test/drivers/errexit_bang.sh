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
# Scope: EVERY *.bats file in the repo, wherever it sits -- the files
# where a test body's return status is the verdict. The population is
# DERIVED at run time (one `find` over ${REPO_ROOT}), never listed: the
# repo has two live bats trees today (test/bats/ and the shipped
# dist/test/bats/smoke/, which `just test smoke` runs and the .base
# subtree vendors into every downstream repo), and a hand-listed roster
# would exempt the third one the day it is added -- which is the whole
# job of a guard named for a set.
#
# Ordinary *.sh under dist/ or script/ is NOT in scope and needs no
# exclusion to stay out: a `!` there is usually an `if` condition or a
# deliberate errexit escape, both correct, and only *.bats is collected.
#
# Two directories ARE pruned, and both are non-source: `.git` (VCS
# internals) and `.prev-release/` (gitignored copies of ALREADY-RELEASED
# trees that script/test/prepare-prev-release.sh materialises with `git
# archive`, so a finding there is unfixable history, not a defect on this
# branch). Nothing else is skipped.
#
# What is a violation: inside a `@test ... {` body, a STATEMENT whose
# first token is `!`, when EITHER
#   (a) the statement does not end on the body's last statement line, or
#   (b) the statement hands its verdict to a command that cannot fail --
#       a `;` with anything after it, or `|| true` / `|| :` -- ANYWHERE
#       in it, including on a `\` continuation line.
#
# (b) exists because (a) is judged by POSITION, and one statement can hold
# more than one command. `! cmd; other` returns `other`'s status
# unconditionally, and `! cmd || true` returns 0 in precisely the branch
# that matters -- the one where cmd SUCCEEDED and the assertion was
# supposed to fail. Both are the same discarded negation as a `!` on an
# earlier line, so both are reported wherever they sit rather than only
# when they land last.
#
# The WHOLE statement is read, not its opening physical line. A backslash
# moves a separator one line down and changes nothing about who owns the
# status, and the shape it produces escapes (a) as well: a statement
# continued onto the body's last line IS the last statement, which is
# where the position rule declines to fire. Judging the first line only
# left `! grep -q A \` / `"${_f}"; true` reported by nothing at all.
#
# Reading the whole statement means reading it to its END, wherever that
# falls. A continued statement ends on the first line that does not
# continue -- INCLUDING a blank or a comment line, which bash reads as
# the terminator once the backslash-newline is removed. Such a statement
# is judged there, on the last line that carried code, rather than being
# carried to the next real line (where it was silently discarded, and so
# escaped both rules).
#
# NOT every `||` is that hand-off, and the two named above are the only
# ones flagged. `! A || B` runs B exactly when A SUCCEEDED, so who owns
# the verdict is decided by B: `! A || return 1` and `! A || fail "..."`
# fail the test in that branch, correctly, and B's failure is not exempt
# from errexit either, so they fail it from a non-final position too --
# such a statement is out of BOTH rules. `true` and `:` are the only
# operands that cannot fail; they are the language's two always-zero
# builtins, a closed set fixed by bash rather than a roster of this tree,
# which is why listing them is not the listed-population defect this file
# otherwise refuses.
#
# That is a deliberate narrowing with a cost: `! A || echo x` is inert and
# goes unreported. This lint is named for statements that CANNOT fail
# their test, and flagging one that can would be a wider claim than the
# rule makes -- on a blocking gate the price of the wider claim is an
# allow region hand-written for a line that was never a violation.
#
# `&&` is out for the same reason. `! A && B` parses as `(! A) && B` and
# short-circuits to 1 whenever A succeeded, so as the body's last
# statement the failing case still reaches its return status. Earlier in
# the body it is inert like any other `!` statement, which is what (a)
# already says about it.
# errexit_bang_lint_spec pins both by RUNNING the shapes, not by asserting
# them here.
#
# The separator scan reads the statement's CODE, not its raw text:
# quoted spans are blanked and a trailing comment is dropped first, so
# `! grep -q 'a;b' f` and `! grep -q A f  # see also; below` are not read
# as two commands. The quote tracker is three states plus a backslash
# escape -- it is not a second bash parser and does not try to be one (no
# expansion, no nesting, no heredoc). An unbalanced quote blanks the rest
# of the line, which can only HIDE a separator: the safe direction, since
# the only other answer is an allow region written by hand.
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
# inside a test is not tracked. A fixture line beginning with `! ` inside
# one reads as a statement (a false alarm the allow region answers), and
# a `}` at column 0 inside one closes the body early, taking the REST of
# that body out of the rule's reach (a MISSED violation). The tree has
# neither today, and a heredoc tracker would be a second bash parser.
# The converse shape -- a heredoc that swallows the body's real closing
# brace -- is no longer silent: it leaves the body open at EOF, which the
# population check below reports.
#
# Population: every body opened must also CLOSE (a body still open at EOF
# is reported, never discarded -- the pending statements of an unclosed
# body are exactly the ones the rule is about), the find must SUCCEED
# (its status is captured, not thrown away by a pipeline) and must yield
# at least one spec, and every `@test`
# header found by a plain text scan must correspond to a body this parser
# actually opened. Without that cross-check a header whose `{` sits on the
# next line would make its whole body invisible and the lint would pass by
# not looking. Each scanned root is populated by construction -- a root
# exists in the roster only because a spec was found inside it -- and the
# clean line prints the file and root counts so a shrinking population is
# visible rather than silent.
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

# Directory NAMES pruned from the walk. Both are non-source (see the
# header): VCS internals, and the gitignored released-tree archives. This
# is not a roster of what is scanned -- what is scanned is every *.bats
# the walk finds.
readonly _ERREXIT_BANG_PRUNE_DIRS=('.git' '.prev-release')

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
# The three separator tests, all applied to the statement's CODE (quoted
# spans blanked, trailing comment dropped) with its continuation lines
# joined on -- never to one physical line.
#
# A `;` with another command after it. A bare trailing `;` terminates the
# statement and is fine.
readonly _ERREXIT_BANG_SEQ_RE=';[[:space:]]*[^[:space:]]'
# An `||` whose right operand CANNOT fail: the only `||` shape that makes
# the statement inert. `true` and `:` are bash's two always-zero builtins.
readonly _ERREXIT_BANG_INERT_OR_RE='\|\|[[:space:]]*(true|:)([[:space:]]*;|[[:space:]]*$)'
# An `||` that belongs to the bang command itself -- no `;` closes the
# list before it. With any other right operand the verdict is that
# operand's and the statement leaves this rule entirely (see the header).
readonly _ERREXIT_BANG_LIVE_OR_RE='^[^;]*\|\|'

# Region markers for the explicit opt-out (see the header note).
readonly _ERREXIT_BANG_ALLOW_BEGIN='errexit-bang-lint: allow-begin'
readonly _ERREXIT_BANG_ALLOW_END='errexit-bang-lint: allow-end'

# _errexit_bang_code_part <line>
#   Print the CODE of one physical line: every character inside a quote
#   replaced by a space, and a trailing comment dropped. The separator
#   tests run on this, so that a `;` the shell would read as an argument
#   or as prose is not read here as a second command.
#
#   Three states (unquoted / single / double) plus a backslash escape
#   outside single quotes, and nothing else -- expansions, nesting and
#   heredocs are not modelled, exactly as the header says. A `#` ends the
#   line only when it starts a word (preceded by whitespace or nothing),
#   which is when the shell starts a comment. Blanking rather than
#   deleting keeps the column count, so a reported line still lines up
#   with the file.
_errexit_bang_code_part() {
  local _s="${1}" _out='' _i _ch _q='' _prev=' '
  for (( _i = 0; _i < ${#_s}; _i++ )); do
    _ch="${_s:_i:1}"
    if [[ "${_q}" != "'" && "${_ch}" == $'\\' ]]; then
      # An escaped character is data, and a trailing backslash is the
      # continuation marker. Neither is a separator.
      _out+='  '
      _i=$(( _i + 1 ))
      _prev=' '
      continue
    fi
    if [[ -n "${_q}" ]]; then
      [[ "${_ch}" == "${_q}" ]] && _q=''
      _out+=' '
      _prev=' '
      continue
    fi
    case "${_ch}" in
      "'"|'"')
        _q="${_ch}"
        _out+=' '
        _prev=' '
        continue
        ;;
      '#')
        [[ "${_prev}" == ' ' || "${_prev}" == $'\t' ]] && break
        ;;
    esac
    _out+="${_ch}"
    _prev="${_ch}"
  done
  printf '%s' "${_out}"
}

# _errexit_bang_scan_file <abs_path> <rel_path> <rows_outvar> <headers_outvar>
#   Append one `<rel>:<line>: <text>` row per violation to <rows_outvar>
#   and add this file's `@test` header count to <headers_outvar>. Called
#   directly, never through a command substitution: both outputs are
#   namerefs, and a subshell would drop the count.
#
# One pass, this state: whether we are inside a body, whether the previous
# physical line continues onto this one, the `!` statement currently being
# READ (its start line, its end line so far, its opening text for the
# report and its joined code for the separator test), the pending `!`
# statements of the current body (start line, END line, text) and the line
# number of the body's last statement. A statement is judged for (b) when
# it ENDS -- a separator can still arrive on a continuation line -- and a
# pending statement is judged for (a) only when the body closes, since
# "is this the last statement" is not knowable before then.
_errexit_bang_scan_file() {
  local _abs="${1}" _rel="${2}"
  local -n _ebsf_rows="${3}"
  local -n _ebsf_headers="${4}"

  local _line _lineno=0 _in_body=0 _prev_cont=0 _cont=0 _body_open=0 _is_stmt=1
  local _last_stmt=0 _in_allow=0 _begin_line=0
  local _bang_start=0 _bang_end=0 _bang_text='' _bang_code=''
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
        _body_open="${_lineno}"
        _last_stmt=0
        _bang_start=0
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

    # Blank and comment lines are not statements: they open none and join
    # none, and neither continues onto the next line (a trailing backslash
    # inside a comment is comment text). But a `!` statement the line
    # above left open ENDS on one of them -- bash removes the
    # backslash-newline, so a blank line contributes its own newline as
    # the terminator and a comment line becomes a comment trailing the
    # command -- so this does not `continue` past the judging block below.
    # Skipping it there was the drop: the statement would be zeroed by the
    # next real line, having been judged by NEITHER rule.
    _is_stmt=1
    if [[ -z "${_line//[[:space:]]/}" ]] || [[ "${_line}" =~ ^[[:space:]]*# ]]; then
      _is_stmt=0
      _cont=0
    fi

    # A statement line. A continuation belongs to the statement that
    # started above it: it moves that statement's END (and the body's
    # last-statement mark) and JOINS its text, without starting a new one.
    # A blank / comment line moves neither: the statement it closes ended
    # on the last line that carried code, which is the line the position
    # rule must compare against the body's last statement.
    if [[ "${_is_stmt}" -eq 1 ]]; then
      _last_stmt="${_lineno}"
      if [[ "${_prev_cont}" -eq 1 ]]; then
        if [[ "${_bang_start}" -gt 0 ]]; then
          _bang_end="${_lineno}"
          _bang_code+=" $(_errexit_bang_code_part "${_line}")"
        fi
      else
        _bang_start=0
        if [[ "${_in_allow}" -eq 0 && "${_line}" =~ ${_ERREXIT_BANG_STMT_RE} ]]; then
          _bang_start="${_lineno}"
          _bang_end="${_lineno}"
          _bang_text="${_line}"
          _bang_code="$(_errexit_bang_code_part "${_line}")"
        fi
      fi
    fi

    # The statement ENDS on the first of its lines that does not continue,
    # and only there is the separator test complete: a `;` or `||` one
    # line further along masks the negation exactly as one on the opening
    # line does.
    if [[ "${_bang_start}" -gt 0 && "${_cont}" -eq 0 ]]; then
      # Order matters: an `|| true` is judged before the generic `||`
      # escape, so the one hand-off that IS inert is still reported.
      if [[ "${_bang_code}" =~ ${_ERREXIT_BANG_INERT_OR_RE} ]]; then
        # Inert in EVERY position, so it is judged here rather than
        # queued: waiting for the body to close would report it only when
        # it happened not to be last, which is the hole this closes. It
        # is deliberately not ALSO queued -- one statement, one row.
        _ebsf_rows+=("${_rel}:${_bang_start}: ${_bang_text}  -- the '!' hands its status to an operand that cannot fail ('|| true' / '|| :')")
      elif [[ "${_bang_code}" =~ ${_ERREXIT_BANG_LIVE_OR_RE} ]]; then
        # `! A || B` with a B that can fail. The verdict is B's, and B's
        # failure is not exempt from errexit, so this statement can fail
        # its test from any position: out of both rules, not merely out
        # of this one. See the header.
        :
      elif [[ "${_bang_code}" =~ ${_ERREXIT_BANG_SEQ_RE} ]]; then
        _ebsf_rows+=("${_rel}:${_bang_start}: ${_bang_text}  -- the '!' hands its status to another command in this statement (';')")
      else
        _pending_line+=("${_bang_start}")
        _pending_end+=("${_bang_end}")
        _pending_text+=("${_bang_text}")
      fi
      _bang_start=0
    fi
  done < "${_abs}"

  if [[ "${_in_allow}" -eq 1 ]]; then
    _ebsf_rows+=("${_rel}:${_begin_line}: unterminated allow-begin (no closing allow-end)")
  fi
  # A body still open at EOF was never judged: "is this the last
  # statement" is answered by the closing `}`, so every pending `!` in it
  # was discarded. That is a file this parser cannot read, and an
  # unreadable file is a failure, not a skip -- the same rule the grep
  # statuses below follow.
  if [[ "${_in_body}" -eq 1 ]]; then
    _ebsf_rows+=("${_rel}:${_body_open}: unclosed test body (no '}' in the first column before EOF) -- its statements were never judged; put the closing brace at column 0")
  fi
}

# _errexit_bang_collect <files_outvar>
#   Fill <files_outvar> with every *.bats in the repo, sorted, pruning the
#   non-source directories. find's status is CAPTURED (the walk writes to a
#   temp file rather than into a pipeline, whose status belongs to `sort`),
#   because a walk that died half way through would otherwise hand the lint
#   a short list and read as "there is less to check".
_errexit_bang_collect() {
  local -n _ebc_files="${1}"
  local -a _prune=()
  local _d
  for _d in "${_ERREXIT_BANG_PRUNE_DIRS[@]}"; do
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
    _ebc_files+=("${_file}")
  done < <(sort -z < "${_tmp}")
  rm -f "${_tmp}"
}

_run_errexit_bang() {
  echo "--- Running non-final bang-statement lint ---"

  local -a _files=()
  local _find_st=0
  _errexit_bang_collect _files || _find_st=$?
  if [[ "${_find_st}" -ne 0 ]]; then
    _die ci_errexit_bang \
      "the walk for *.bats under ${REPO_ROOT} failed (exit ${_find_st}) -- a scan that could not finish is not a scan that found nothing."
    return 1
  fi

  local _file
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_errexit_bang \
      "no *.bats anywhere under ${REPO_ROOT} (pruning ${_ERREXIT_BANG_PRUNE_DIRS[*]}) -- a scan with no population is not a pass. This lint derives its population from the tree; an empty one means the specs moved, not that they are clean."
    return 1
  fi

  # The roots are derived FROM the files, so each is populated by
  # construction; they are collected only to report what was covered.
  local -a _roots=()
  local _rel_dir _root _seen
  for _file in "${_files[@]}"; do
    _rel_dir="${_file#"${REPO_ROOT}"/}"
    _rel_dir="${_rel_dir%%/*}"
    _seen=0
    for _root in ${_roots[@]+"${_roots[@]}"}; do
      [[ "${_root}" == "${_rel_dir}" ]] && _seen=1 && break
    done
    [[ "${_seen}" -eq 1 ]] || _roots+=("${_rel_dir}")
  done

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
      "${_headers} '@test' header(s) across ${#_files[@]} spec file(s) but only ${_bodies} body/bodies the parser could open. A header whose '{' is not the last character of its line hides its whole body from this lint. Put the opening brace at the end of the '@test' line."
    return 1
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_errexit_bang \
      "${_violations} non-final / masked '!' statement(s), unclosed body/bodies or unbalanced allow marker(s) across the ${#_files[@]} *.bats file(s) in this repo. bash exempts a '!' pipeline from errexit, so such a line is an assertion ONLY as the last COMMAND of a test body's last statement -- anywhere else, and after a ';' or an '|| true' / '|| :' anywhere in that statement, the command runs, the negation is computed and the answer is discarded, and the test passes whatever the code did. Assert it with an explicit 'if <cmd>; then <message>; return 1; fi', with 'refute'/'refute_output', or move it to the end of the body. A line that genuinely cannot be written that way opts out by bracketing it with '# ${_ERREXIT_BANG_ALLOW_BEGIN} -- <why>' / '# ${_ERREXIT_BANG_ALLOW_END}'."
    return 1
  fi
  echo "non-final bang-statement lint: clean (${#_files[@]} spec file(s) under ${_roots[*]}, ${_headers} test bodies)"
}
