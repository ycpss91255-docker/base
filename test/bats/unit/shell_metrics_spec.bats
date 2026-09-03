#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/shell_metrics.sh -- the ONE shell
# reader behind the three implementation-standard metric lints (nesting
# depth, function length, positional parameters; base#994 phase 2).
#
# The reader is the subject, not the three thresholds: a threshold is one
# comparison over a record the reader produced, and every way this can be
# wrong is a way the READER can be wrong. So most of this file is fixtures
# for shapes that broke the ad-hoc counter base#994 measured the tree with --
# a keyword used as an argument, a `$( )` the quote scanner did not
# recurse into, a `$'...'` holding an escaped quote -- plus the shapes
# those three suggest (heredoc bodies, case patterns, comments, nested and
# one-line function definitions, CRLF).
#
# Every fixture tree is a REAL git repository built in a scratch dir: the
# population is derived from the index, so a spec that did not create one
# would be testing a different collector than the live tree uses.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the reader runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/shell_metrics.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" config user.email "spec@example.invalid"
  git -C "${SCRATCH}" config user.name "spec"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a fixture file and track it.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
  git -C "${SCRATCH}" add -- "${_rel}"
}

# _field <name> <field> -- one measured field of one function record.
# Fields: file name start end depth length params variadic.
_field() {
  _shell_metrics_load
  _shell_metrics_field "${1}" "${2}"
}

# ════════════════════════════════════════════════════════════════════
# The population is derived from the index, and an empty one is refused
# ════════════════════════════════════════════════════════════════════

@test "population: a tracked .sh file is read (#994)" {
  _write "a.sh" 'f() {' '  echo hi' '}'
  run _field f length
  assert_success
  assert_output "1"
}

@test "population: a tracked EXTENSIONLESS file whose first two bytes are '#!' is read (#994)" {
  _write "bin/runme" '#!/usr/bin/env bash' 'g() {' '  echo hi' '}'
  run _field g length
  assert_success
  assert_output "1"
}

@test "population: a tracked extensionless file WITHOUT a shebang is not read (#994)" {
  _write "notes" 'g() {' '  echo hi' '}'
  _write "a.sh" 'f() {' '  echo hi' '}'
  run _field g length
  assert_failure
}

@test "population: a tracked SYMLINK ending .sh is not read (#994)" {
  _write "real.sh" 'f() {' '  echo hi' '}'
  ln -s real.sh "${SCRATCH}/link.sh"
  git -C "${SCRATCH}" add -- link.sh
  _shell_metrics_load
  run _shell_metrics_files
  assert_success
  assert_line "real.sh"
  refute_line "link.sh"
}

@test "population: an UNTRACKED .sh file is not read (#994)" {
  _write "a.sh" 'f() {' '  echo hi' '}'
  printf '%s\n' 'h() {' '  echo hi' '}' > "${SCRATCH}/loose.sh"
  _shell_metrics_load
  run _shell_metrics_files
  assert_success
  refute_line "loose.sh"
}

@test "population: an EMPTY population is refused, never reported clean (#994)" {
  run _shell_metrics_load
  assert_failure
  assert_output --partial "no shell file"
}

# ════════════════════════════════════════════════════════════════════
# The three parser bugs the ad-hoc counter had. Each is a fixture, and
# each fixture is here because the bug was found by a fixture rather
# than by reading the code.
# ════════════════════════════════════════════════════════════════════

@test "parser: a shell KEYWORD USED AS AN ARGUMENT closes nothing (#994)" {
  # `echo done fi esac` ended three constructs in the ad-hoc counter, so
  # every function AFTER it in the file was measured against a corrupt
  # stack. The keywords are only keywords in command position.
  _write "a.sh" \
    'first() {' \
    '  if true; then' \
    '    echo done fi esac' \
    '  fi' \
    '}' \
    'second() {' \
    '  if true; then' \
    '    if true; then' \
    '      if true; then' \
    '        if true; then' \
    '          echo deep' \
    '        fi' \
    '      fi' \
    '    fi' \
    '  fi' \
    '}'
  run _field first depth
  assert_output "1"
  run _field second depth
  assert_output "4"
}

@test "parser: double-quote scanning RECURSES into command substitution (#994)" {
  # The bug: a `"` scanner that did not enter `$( )` lost quote state at
  # the command substitution and read the awk program inside it as shell,
  # inventing a depth of 9. coverage_gate.sh::_coverage_gate_run reported
  # depth 11 and self_hosted_guard.sh::flush_if depth 10 that way; both
  # figures were artifacts of this.
  _write "a.sh" \
    'embedded() {' \
    '  local _out' \
    '  _out="$(awk '"'"'' \
    '    function flush_if() {' \
    '      if (a) { if (b) { if (c) { if (d) { print "x" } } } }' \
    '    }' \
    '    { for (i = 0; i < 3; i++) { while (j) { print } } }' \
    '  '"'"' "${_f}")"' \
    '  echo "${_out}"' \
    '}'
  run _field embedded depth
  assert_success
  assert_output "0"
}

@test "parser: a dollar-single-quote holding an escaped quote does not swallow the file (#994)" {
  # The single-quote scanner had no `$'...'` case, so the `'` that opened
  # it was read as a plain single quote, the escaped `\'` closed nothing,
  # and every function after this line vanished from the count.
  _write "a.sh" \
    'quoter() {' \
    "  local _q=\$'it\\'s'" \
    '  echo "${_q}"' \
    '}' \
    'after() {' \
    '  if true; then' \
    '    if true; then' \
    '      echo x' \
    '    fi' \
    '  fi' \
    '}'
  run _field after depth
  assert_success
  assert_output "2"
}

# ════════════════════════════════════════════════════════════════════
# The shapes those three suggest
# ════════════════════════════════════════════════════════════════════

@test "parser: a heredoc body containing 'if' and 'done' is data, not syntax (#994)" {
  _write "a.sh" \
    'doc() {' \
    '  cat <<EOF' \
    'if you are reading this' \
    '  done' \
    '  fi' \
    'EOF' \
    '  echo after' \
    '}' \
    'after() {' \
    '  if true; then' \
    '    echo x' \
    '  fi' \
    '}'
  run _field doc depth
  assert_output "0"
  run _field after depth
  assert_output "1"
}

@test "parser: a heredoc body does not count toward function length (#994)" {
  _write "a.sh" \
    'doc() {' \
    '  cat <<EOF' \
    'one' \
    'two' \
    'three' \
    'EOF' \
    '}'
  run _field doc length
  assert_output "1"
}

@test "parser: a case pattern containing ')' does not end the pattern early (#994)" {
  _write "a.sh" \
    'patterned() {' \
    '  case "${1}" in' \
    "    'a)b') echo one ;;" \
    '    *\)*) echo two ;;' \
    '    *) echo three ;;' \
    '  esac' \
    '}' \
    'after() {' \
    '  echo x' \
    '}'
  run _field patterned depth
  assert_success
  assert_output "1"
  run _field after length
  assert_output "1"
}

@test "parser: a double-semicolon inside a string does not end a case arm (#994)" {
  _write "a.sh" \
    'stringy() {' \
    '  case "${1}" in' \
    '    a)' \
    '      echo "one;; two"' \
    '      if true; then echo x; fi' \
    '      ;;' \
    '  esac' \
    '}'
  run _field stringy depth
  assert_success
  assert_output "2"
}

@test "parser: a comment containing 'fi' closes nothing (#994)" {
  _write "a.sh" \
    'commented() {' \
    '  if true; then' \
    '    # the fi below is real, this one is not: fi done esac' \
    '    echo x' \
    '  fi' \
    '}'
  run _field commented depth
  assert_success
  assert_output "1"
}

@test "parser: a comment-only line does not count toward length (#994)" {
  _write "a.sh" \
    'commented() {' \
    '  # one' \
    '  # two' \
    '' \
    '  echo x' \
    '}'
  run _field commented length
  assert_output "1"
}

@test "parser: a function defined INSIDE a function yields two records (#994)" {
  _write "a.sh" \
    'outer() {' \
    '  inner() {' \
    '    echo in' \
    '  }' \
    '  inner' \
    '}'
  run _field inner length
  assert_output "1"
  # The outer owes all four of its body lines -- the inner's header, its
  # one statement, its closing brace and the call below it. An inner
  # function's lines count toward the outer as well as toward its own, so
  # that wrapping the middle of a long function in a nested one is not a
  # way to shrink it for free.
  run _field outer length
  assert_output "4"
}

@test "parser: an inner function definition adds a level to the OUTER depth (#994)" {
  _write "a.sh" \
    'outer() {' \
    '  inner() {' \
    '    if true; then' \
    '      echo in' \
    '    fi' \
    '  }' \
    '}'
  run _field inner depth
  assert_output "1"
  run _field outer depth
  assert_output "2"
}

@test "parser: 'function name {' with no parens is a function definition (#994)" {
  _write "a.sh" \
    'function kwform {' \
    '  if true; then' \
    '    echo x' \
    '  fi' \
    '}'
  run _field kwform depth
  assert_success
  assert_output "1"
}

@test "parser: 'function name() {' is a function definition (#994)" {
  _write "a.sh" \
    'function bothform() {' \
    '  echo x' \
    '}'
  run _field bothform length
  assert_success
  assert_output "1"
}

@test "parser: a one-line function body is measured as one line (#994)" {
  _write "a.sh" 'oneline() { echo hi; }'
  run _field oneline length
  assert_success
  assert_output "1"
}

@test "parser: an array assignment is not read as a function definition (#994)" {
  _write "a.sh" \
    '_seen=()' \
    'real() {' \
    '  echo x' \
    '}'
  _shell_metrics_load
  run _shell_metrics_names
  assert_success
  assert_line "real"
  refute_line "_seen"
}

@test "parser: CRLF line endings are read like LF (#994)" {
  printf 'crlf() {\r\n  if true; then\r\n    echo x\r\n  fi\r\n}\r\n' \
    > "${SCRATCH}/a.sh"
  git -C "${SCRATCH}" add -- a.sh
  run _field crlf depth
  assert_success
  assert_output "1"
}

# ════════════════════════════════════════════════════════════════════
# The counting rules. Each of these is a DECISION; the driver header
# states it and its reason, and these cases pin it.
# ════════════════════════════════════════════════════════════════════

@test "counting: a case arm adds NO level, so case matches the if/elif chain it replaces (#994)" {
  _write "a.sh" \
    'viacase() {' \
    '  case "${1}" in' \
    '    a) echo one ;;' \
    '    b) echo two ;;' \
    '  esac' \
    '}' \
    'viaif() {' \
    '  if [[ "${1}" == a ]]; then' \
    '    echo one' \
    '  elif [[ "${1}" == b ]]; then' \
    '    echo two' \
    '  fi' \
    '}'
  run _field viacase depth
  assert_output "1"
  run _field viaif depth
  assert_output "1"
}

@test "counting: a brace group and a subshell add no level; the construct inside them does (#994)" {
  _write "a.sh" \
    'grouped() {' \
    '  { echo a; } > /dev/null' \
    '  ( echo b )' \
    '  if true; then' \
    '    echo c' \
    '  fi' \
    '}'
  run _field grouped depth
  assert_success
  assert_output "1"
}

@test "counting: length is body CODE lines, excluding the header and closing brace (#994)" {
  _write "a.sh" \
    'measured() {' \
    '  echo one' \
    '  echo two' \
    '}'
  run _field measured length
  assert_output "2"
}

@test "counting: positional parameters are the HIGHEST index reached, not the count of distinct ones (#994)" {
  _write "a.sh" \
    'holey() {' \
    '  echo "${1}" "${7}"' \
    '}'
  run _field holey params
  assert_output "7"
}

@test "counting: an unbraced positional takes ONE digit, the way bash reads it (#994)" {
  _write "a.sh" \
    'unbraced() {' \
    '  echo "$12"' \
    '}'
  run _field unbraced params
  assert_output "1"
}

@test "counting: a forwarded argument list does not raise the count but marks the function variadic (#994)" {
  _write "a.sh" \
    'forwarder() {' \
    '  local _one="${1}"' \
    '  printf "%s\\n" "$@"' \
    '}'
  run _field forwarder variadic
  assert_output "1"
  run _field forwarder params
  assert_output "1"
}

@test "counting: a 'shift' raises the index a later positional reaches (#994)" {
  _write "a.sh" \
    'shifter() {' \
    '  local _a="${1}"' \
    '  shift 2' \
    '  local _b="${1}"' \
    '  echo "${_a}${_b}"' \
    '}'
  run _field shifter params
  assert_output "3"
}

@test "counting: a 'shift' inside a loop is unbounded, so the function is variadic (#994)" {
  _write "a.sh" \
    'argparse() {' \
    '  while [[ $# -gt 0 ]]; do' \
    '    shift' \
    '  done' \
    '}'
  run _field argparse variadic
  assert_output "1"
}

@test "counting: a nested function has its OWN positional parameters (#994)" {
  _write "a.sh" \
    'outer() {' \
    '  echo "${2}"' \
    '  inner() {' \
    '    echo "${9}"' \
    '  }' \
    '}'
  run _field outer params
  assert_output "2"
  run _field inner params
  assert_output "9"
}

# ════════════════════════════════════════════════════════════════════
# A file the reader cannot parse is a FINDING, never a silent skip
# ════════════════════════════════════════════════════════════════════

@test "refusal: an unbalanced construct is reported, and the file's records are dropped (#994)" {
  _write "a.sh" \
    'broken() {' \
    '  if true; then' \
    '    echo x' \
    '}'
  run _shell_metrics_load
  assert_failure
  assert_output --partial "a.sh"
  assert_output --partial "could not be parsed"
}

@test "refusal: an unterminated quote is reported (#994)" {
  _write "a.sh" \
    'broken() {' \
    '  echo "never closed' \
    '}'
  run _shell_metrics_load
  assert_failure
  assert_output --partial "a.sh"
}

@test "refusal: a legacy backtick substitution is reported rather than guessed at (#994)" {
  _write "a.sh" \
    'legacy() {' \
    '  local _x' \
    '  _x=`echo hi`' \
    '  echo "${_x}"' \
    '}'
  run _shell_metrics_load
  assert_failure
  assert_output --partial "backtick"
}

# ════════════════════════════════════════════════════════════════════
# Disclosed limitations, pinned so they cannot change into the other
# kind of wrong. The driver header lists what the reader does not model
# and asserts that each errs toward a FINDING; these two are the ones
# reachable by writing ordinary bash, so they are RUN rather than
# claimed.
# ════════════════════════════════════════════════════════════════════

@test "limitation: a function body that is not a brace group is a finding, not a record (base#994)" {
  # `f() ( ... )` is legal bash and this reader does not read it. What is
  # pinned is the direction: the file is named and dropped, never
  # silently skipped and never measured on a guess.
  _write "a.sh" \
    'f() (' \
    '  echo hi' \
    ')'
  run _shell_metrics_load
  assert_failure
  assert_output --partial "only a '{ ... }' body is supported"
}

@test "limitation: an arithmetic left shift is misread as a heredoc, and errs toward a finding (base#994)" {
  # `((` is collapsed into two nested parens, so arithmetic is not told
  # apart from a subshell and a `<<` inside one reads as a heredoc
  # operator. The delimiter it invents never appears, so the file ends
  # inside the heredoc and is reported unmeasured -- which is the whole
  # claim: this limitation cannot produce a wrong NUMBER.
  _write "a.sh" \
    'g() {' \
    '  local _x=$(( 1 << 2 ))' \
    '  echo "${_x}"' \
    '}'
  run _shell_metrics_load
  assert_failure
  assert_output --partial "heredoc"
}

# ════════════════════════════════════════════════════════════════════
# The three lints. Each is a threshold over the record above, and each
# has a case proving it can FAIL.
# ════════════════════════════════════════════════════════════════════

@test "_run_nesting_depth: FAILS at depth 4, naming file and function (#994)" {
  _write "a.sh" \
    'deep() {' \
    '  if true; then' \
    '    if true; then' \
    '      if true; then' \
    '        if true; then' \
    '          echo x' \
    '        fi' \
    '      fi' \
    '    fi' \
    '  fi' \
    '}'
  run _run_nesting_depth
  assert_failure
  assert_output --partial "a.sh"
  assert_output --partial "deep"
  assert_output --partial "4"
}

@test "_run_nesting_depth: passes at depth 3 (#994)" {
  _write "a.sh" \
    'ok() {' \
    '  if true; then' \
    '    if true; then' \
    '      if true; then' \
    '        echo x' \
    '      fi' \
    '    fi' \
    '  fi' \
    '}'
  run _run_nesting_depth
  assert_success
  assert_output --partial "clean"
}

@test "_run_function_length: FAILS at 51 body code lines (#994)" {
  {
    echo 'long() {'
    for _i in $(seq 1 51); do echo "  echo ${_i}"; done
    echo '}'
  } > "${SCRATCH}/a.sh"
  git -C "${SCRATCH}" add -- a.sh
  run _run_function_length
  assert_failure
  assert_output --partial "long"
  assert_output --partial "51"
}

@test "_run_function_length: passes at exactly 50 body code lines (#994)" {
  {
    echo 'atlimit() {'
    for _i in $(seq 1 50); do echo "  echo ${_i}"; done
    echo '}'
  } > "${SCRATCH}/a.sh"
  git -C "${SCRATCH}" add -- a.sh
  run _run_function_length
  assert_success
  assert_output --partial "clean"
}

@test "_run_positional_params: FAILS at 6 positional parameters (#994)" {
  _write "a.sh" \
    'wide() {' \
    '  echo "${1}${2}${3}${4}${5}${6}"' \
    '}'
  run _run_positional_params
  assert_failure
  assert_output --partial "wide"
  assert_output --partial "6"
}

@test "_run_positional_params: passes at exactly 5 (#994)" {
  _write "a.sh" \
    'atlimit() {' \
    '  echo "${1}${2}${3}${4}${5}"' \
    '}'
  run _run_positional_params
  assert_success
  assert_output --partial "clean"
}

@test "the three lints share ONE reader pass (#994)" {
  _write "a.sh" 'f() {' '  echo x' '}'
  _shell_metrics_load
  local _first="${_SHELL_METRICS_PASSES}"
  _shell_metrics_load
  _shell_metrics_load
  [ "${_SHELL_METRICS_PASSES}" -eq "${_first}" ]
  [ "${_first}" -eq 1 ]
}

@test "_run_shell_metrics: reports all three metrics in one run (#994)" {
  _write "a.sh" \
    'deep() {' \
    '  if true; then' \
    '    if true; then' \
    '      if true; then' \
    '        if true; then' \
    '          echo "${9}"' \
    '        fi' \
    '      fi' \
    '    fi' \
    '  fi' \
    '}'
  run _run_shell_metrics
  assert_failure
  assert_output --partial "nesting depth"
  assert_output --partial "function length"
  assert_output --partial "positional parameters"
  assert_output --partial "deep"
}
