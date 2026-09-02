#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/errexit_bang.sh -- the "a `!`
# statement that is not last cannot fail its test" lint.
#
# bash exempts a pipeline prefixed with `!` from errexit (POSIX: the
# shell does not exit when the failing command is part of a `!`
# expression). Inside a bats test body -- a function run under `set -e`
# whose RETURN STATUS is the verdict -- that has one consequence: a
# `! <cmd>` line is an assertion only when it is the body's LAST
# statement, where its status becomes the body's. Anywhere else it is
# decoration: the command runs, the negation is computed, and the result
# is thrown away. The test goes on to pass.
#
# This tree has now paid for that twice in one review round
# (compose_watchdog_spec's WATCHDOG_INTERVAL half, and the inverted greps
# in dockerfile_migrate_spec / upgrade_spec before it), each time found by
# hand. The rule is mechanical, so it is a lint.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# tree to prove it passes today. Shape mirrors
# early_close_reader_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/errexit_bang.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/test/bats/unit"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_errexit_bang: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: FAILS on a non-final bang statement, naming file and line (#956)" {
  # The compose_watchdog shape: two absence assertions, only the last of
  # which can fail.
  _write "test/bats/unit/x_spec.bats" \
    '@test "two absence checks" {' \
    '  ! grep -qF A "${_f}"' \
    '  ! grep -qF B "${_f}"' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats/unit/x_spec.bats:2"* ]]
  [[ "${output}" != *"x_spec.bats:3"* ]]
}

@test "_run_errexit_bang: FAILS on a bang statement buried mid-body (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "buried" {' \
    '  ! ovr_get some.key' \
    '  is_removed some.key' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a bang statement nested in a block (#956)" {
  # Still exempt, and still not the body's status.
  _write "test/bats/unit/x_spec.bats" \
    '@test "nested" {' \
    '  if [[ -n "${_x}" ]]; then' \
    '    ! grep -q A "${_f}"' \
    '  fi' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:3"* ]]
}

@test "_run_errexit_bang: FAILS on the FIRST line of a continued bang statement that is not last (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "continued" {' \
    '  ! grep -q A \' \
    '      "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a bang statement followed by another command via ';' (#956)" {
  # The rule is "not the last statement", but the parser judges by LINE:
  # a `!` that is not the last COMMAND on the body's last line was exempt.
  # `! cmd; other` runs the negation and then throws it away exactly as a
  # `!` on an earlier line does -- the list's status is `other`'s -- so it
  # is the same inert assertion, one semicolon further along.
  _write "test/bats/unit/x_spec.bats" \
    '@test "two commands, one line" {' \
    '  ! test -e /definitely/not/here; true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a bang statement whose '||' hands off the verdict (#956)" {
  # `! A || B` returns 0 whenever A failed, and B's status whenever A
  # SUCCEEDED -- so a `|| true` swallows precisely the case the assertion
  # exists to catch. Same verdict as the semicolon.
  _write "test/bats/unit/x_spec.bats" \
    '@test "negation handed to the right operand" {' \
    '  ! test -e /definitely/not/here || true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "bash: a backgrounded '!' returns 0 whatever the command did (#956)" {
  # Why `&` is a hand-off, pinned by running it. `! A &` is an ASYNC
  # list: the shell forks, does not wait, and the list's status is 0 --
  # not the negation's. So the failing direction (A SUCCEEDED, the
  # negation is 1, the body must fail) never reaches the body's status,
  # and it does not reach it from the LAST statement either, which is
  # where `!` is otherwise an assertion.
  run bash -c 'set -e; body() { ! true & }; body'
  [ "${status}" -eq 0 ]
  run bash -c 'set -e; body() { ! true; }; body'
  [ "${status}" -eq 1 ]
  # And with something after it the `&` is a separator like `;`: the
  # list's status is the LAST command's, unconditionally.
  run bash -c 'set -e; body() { ! true & true; }; body'
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: FAILS on a bang statement handed to the background (#956)" {
  # The inert assertion this lint is named for, in the one position the
  # position rule declines to judge: the body's LAST statement. Its
  # status is the fork's, always 0, so the test passes whatever the
  # command did.
  _write "test/bats/unit/x_spec.bats" \
    '@test "backgrounded" {' \
    '  ! grep -q A "${_f}" &' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS when a '&' hands the statement to the next command (#956)" {
  # The other half of the same character: `! A & B` discards the negation
  # unconditionally and returns B's status, which is what a `;` does and
  # why a `;` is reported.
  _write "test/bats/unit/x_spec.bats" \
    '@test "backgrounded, then another command" {' \
    '  ! grep -q A "${_f}" & wait' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on such a line even when the body continues past it (#956)" {
  # The masked shape is inert in EVERY position, so it is reported where
  # it stands rather than only when it lands on the last line -- and it is
  # reported once, not twice.
  _write "test/bats/unit/x_spec.bats" \
    '@test "masked and buried" {' \
    '  ! test -e /definitely/not/here; true' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "$(printf '%s\n' "${output}" | grep -c 'x_spec.bats:2')" -eq 1 ]]
}

@test "bash: a separator on the CONTINUATION line discards the negation too (#956)" {
  # Why the two cases below are violations, pinned by running the shape
  # rather than by asserting it in prose. In both, `! true` stands for the
  # assertion's failing direction -- the grep FOUND what the test says is
  # absent -- and in both the body still returns 0. A backslash moves the
  # separator one physical line down; it changes nothing about who owns
  # the statement's status.
  run bash -c $'set -e\nbody() {\n  ! true \\\n    ; true\n}\nbody'
  [ "${status}" -eq 0 ]
  run bash -c $'set -e\nbody() {\n  ! true \\\n    || true\n}\nbody'
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: FAILS when the ';' sits on a continuation line (#956)" {
  # The mask test reads the whole STATEMENT, not its first physical line.
  # Judging only the opening line let this shape through exactly where it
  # hurts: the statement is also the body's LAST, so the position rule has
  # nothing to say about it either and NOTHING reported it.
  _write "test/bats/unit/x_spec.bats" \
    '@test "masked on the continuation line" {' \
    '  ! grep -q A \' \
    '      "${_f}"; true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS when the '|| true' sits on a continuation line (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "handed off on the continuation line" {' \
    '  ! grep -q A \' \
    '      "${_f}" || true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS when a BLANK line ends a continued bang statement (#956)" {
  # bash removes the backslash-newline, so what ends the statement is the
  # BLANK line's own newline: `! grep -q A` is one statement and
  # `assert_success` is the next, which leaves the bang non-final and
  # inert. The parser has to judge the statement the blank line closed;
  # dropping it there exempts the statement from BOTH rules at once --
  # rule (b) never runs and rule (a) never receives it -- and nothing
  # reports a violation the lint exists for.
  _write "test/bats/unit/x_spec.bats" \
    '@test "closed by a blank line" {' \
    '  ! grep -q A \' \
    '' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS when a COMMENT line ends a continued bang statement (#956)" {
  # The blank line's sibling, and the same drop: the join puts the comment
  # after the bang command (`! grep -q A   # a note`), the statement ends
  # there, and `assert_success` below it is the body's last statement.
  _write "test/bats/unit/x_spec.bats" \
    '@test "closed by a comment line" {' \
    '  ! grep -q A \' \
    '  # a note' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: PASSES when the blank line that ends a continued bang ends the BODY too (#956)" {
  # The other direction of the same judgement: the statement closed by a
  # blank line is still the body's LAST statement, so judging it there
  # must not move its end line onto the blank -- that would make a clean
  # body fail the position rule against itself.
  _write "test/bats/unit/x_spec.bats" \
    '@test "final bang, closed by a blank line" {' \
    '  ! grep -q A \' \
    '' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _run_errexit_bang: what is NOT a violation
# ════════════════════════════════════════════════════════════════════

@test "bash: '! A && B' as the last statement still fails its test (#956)" {
  # Why the '&&' arm of the same shape is NOT a violation, pinned by
  # running it rather than by asserting it in prose. `! A && B` is
  # `(! A) && B`: when A SUCCEEDS -- the case the assertion must catch --
  # the negation is 1, `&&` short-circuits, and 1 is the body's status.
  # The verdict is never handed to B in that direction, so the assertion
  # cannot be masked and the lint has nothing to say about it. A `;` is
  # flagged because it hands the verdict over unconditionally, and an
  # `|| true` / `|| :` because it hands it to an operand that cannot
  # fail; any other `||` is out for the same reason `&&` is.
  run bash -c 'set -e; body() { ! true && true; }; body'
  [ "${status}" -eq 1 ]
  run bash -c 'set -e; body() { ! false && true; }; body'
  [ "${status}" -eq 0 ]
}

@test "bash: '! A || return 1' DOES fail its test in the failing direction (#956)" {
  # Why not every '||' is a hand-off. `! A || B` runs B exactly when A
  # SUCCEEDED -- the case the assertion exists to catch -- so whether the
  # assertion survives is decided by B, not by the `||`. With `return 1`
  # (or a bats `fail`) the body fails, correctly. Only an operand that
  # CANNOT fail makes the statement inert.
  run bash -c 'set -e; body() { ! true || return 1; }; body'
  [ "${status}" -eq 1 ]
  run bash -c 'set -e; body() { ! false || return 1; }; body'
  [ "${status}" -eq 0 ]
  # ... and it fails from a non-final position too: B's failure is NOT
  # exempt from errexit, so this shape is out of the rule in every
  # position, not only the last.
  run bash -c 'set -e; body() { ! true || return 1; true; }; body'
  [ "${status}" -eq 1 ]
}

@test "_run_errexit_bang: PASSES on '|| return 1' / '|| fail', which CAN fail the test (#956)" {
  # The lint is named for statements that CANNOT fail their test. These
  # can, so flagging them would be a wider claim than the rule makes --
  # and on a blocking gate the cost is an allow region hand-written for a
  # line that was never a violation.
  _write "test/bats/unit/x_spec.bats" \
    '@test "or return" {' \
    '  ! grep -q A "${_f}" || return 1' \
    '  true' \
    '}'
  _write "test/bats/unit/y_spec.bats" \
    '@test "or fail" {' \
    '  ! grep -q A "${_f}" || fail "A is present"' \
    '  true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: still FAILS on '|| true' / '|| :', the operands that cannot fail (#956)" {
  # The narrowing above is a narrowing, not a retreat: the two always-zero
  # builtins are still a hand-off, wherever the statement sits.
  _write "test/bats/unit/x_spec.bats" \
    '@test "or true" {' \
    '  ! grep -q A "${_f}" || true' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
  _write "test/bats/unit/x_spec.bats" \
    '@test "or colon" {' \
    '  ! grep -q A "${_f}" || :' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: PASSES on a ';' that sits in a trailing comment (#956)" {
  # The separator scan reads the statement's CODE. A ';' after the '#'
  # is prose, and the shell never sees a second command there.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a note with a semicolon" {' \
    '  ! grep -q A "${_f}"  # see also; the note below' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: PASSES on a ';' inside a quoted argument (#956)" {
  # Same reason, one quote further along: `a;b` is one argument to grep,
  # not a statement separator. This was a disclosed limitation of the
  # textual scan and is the sibling of the trailing comment above -- both
  # are text the shell does not read as a separator.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a quoted semicolon" {' \
    "  ! grep -q 'a;b' \"\${_f}\"" \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
  _write "test/bats/unit/x_spec.bats" \
    '@test "a quoted or" {' \
    '  ! grep -q "a || true" "${_f}"' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: FAILS on an '||' that belongs to a command substitution (#956)" {
  # `$( ... )` is an ARGUMENT, not this statement's top-level list. The
  # `||` inside it decides nothing about who owns the verdict, so the
  # exemption for `! A || B` -- earned by B being the operand whose
  # failure the test still sees -- does not reach it, and the bang is as
  # inert as any other non-final one. A flat text match over the whole
  # statement read it as a hand-off and dropped the statement out of BOTH
  # rules.
  _write "test/bats/unit/x_spec.bats" \
    '@test "an or inside a substitution" {' \
    '  ! grep -q $(foo || bar) "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: PASSES on a ';' that belongs to a command substitution (#956)" {
  # The same flat match, spelled with the other separator: a `;` inside
  # `$( ... )` separates two commands INSIDE the argument, not this
  # statement from a second one. The negation is still the body's status,
  # so reporting it is a false positive on a blocking gate.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a semicolon inside a substitution" {' \
    '  ! grep -q $(foo; bar) "${_f}"' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "bash: '#' opens a comment only where a WORD opens (#956)" {
  # The lexical rule the code scan implements, pinned by RUNNING it
  # rather than asserting it in prose: a `#` begins a comment when it
  # begins a WORD, and a word begins after a blank OR after one of the
  # metacharacters that end one -- `;`, `&`, `|`, `(` and the `)` that
  # closes a SUBSHELL. It is data only in the middle of a word
  # (`echo B#note` prints `B#note`). `)` is the context-dependent one and
  # gets its own case below: the `)` of a `$( ... )` ends the expansion,
  # not the word.
  run bash -c $'echo A;# note\necho B'
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "A" ]
  [ "${lines[1]}" = "B" ]
  run bash -c $'(echo A)# note\necho B'
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "A" ]
  [ "${lines[1]}" = "B" ]
  # The `&` spelling needs the EXACT line set, not a substring match:
  # were `# note` an ordinary word it would run as a command, `run`
  # merges its "command not found" into `output`, and the trailing
  # `echo B` would still exit 0 -- so a status check plus two substring
  # checks pass either way. `wait` makes the order deterministic.
  run bash -c $'echo A &# note\nwait\necho B'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "A" ]
  [ "${lines[1]}" = "B" ]
  # The `|` spelling proves itself the other way round: the comment eats
  # the pipeline's right-hand side, so bash reports a SYNTAX error. Were
  # `#note` an ordinary word, it would run as a command and the failure
  # would be a not-found at run time instead.
  run bash -c 'echo A|# note'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"syntax error"* ]]
  # And the middle-of-a-word case, which is why the scan cannot simply
  # break on every '#'.
  run bash -c 'echo B#note'
  [ "${status}" -eq 0 ]
  [ "${output}" = "B#note" ]
  # `<` and `>` end a word too, and a comment there eats the redirect's
  # target: the line does not parse at all, so it cannot be a statement
  # this lint has anything to say about. That is why the scan's set stops
  # at the five metacharacters above rather than claiming all of them.
  run bash -c 'echo A >#f'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"syntax error"* ]]
  # The other half of the same rule, and the half the scan got wrong: a
  # CLOSING QUOTE does not end a word, and neither does a backslash
  # escape. Both continue the word they sit in, so a `#` right after one
  # is data and the line goes on.
  run bash -c 'printf "[%s]\n" '"'"'a'"'"'#b'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[a#b]" ]
  run bash -c 'printf "[%s]\n" "a"#b'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[a#b]" ]
  run bash -c 'printf "[%s]\n" a\ #b'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[a #b]" ]
}

@test "bash: a ')' ends a word only when it closes a SUBSHELL (#956)" {
  # The half of the word rule that is context dependent, and the half the
  # scan read as one thing. A `)` that closes a SUBSHELL ends a word, so
  # a `#` behind it opens a comment. A `)` that closes a command
  # substitution, an arithmetic expansion or a process substitution does
  # NOT: it ends the expansion, the word goes on around it, and the `#`
  # behind it is data.
  run bash -c $'(echo A)# note\necho B'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "A" ]
  [ "${lines[1]}" = "B" ]
  run bash -c 'printf "[%s]\n" $(echo A)#b'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[A#b]" ]
  run bash -c 'printf "[%s]\n" $((1 + 1))#b'
  [ "${status}" -eq 0 ]
  [ "${output}" = "[2#b]" ]
  # A process substitution proves itself the other way round: the word is
  # the `/dev/fd` path with `#b` glued on, so the open FAILS -- were the
  # `)` a word end the comment would have eaten the argument and `cat`
  # would have read standard input instead.
  run bash -c 'cat <(echo A)#b'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"#b"* ]]
  # The arithmetic COMMAND is the other bare-paren spelling, and its `))`
  # does end a word: the `echo B` behind the comment never runs.
  run bash -c 'x=3; (( x & 1 ))#b; echo B'
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "_run_errexit_bang: PASSES on a bare trailing ';' followed by a comment (#956)" {
  # `;#` is a terminator and then a comment: the `;` ended the word, so
  # bash starts a comment at the `#` and there is no second command for
  # the negation to be handed to. Reading it as one is a false positive,
  # and on a blocking gate the price of a false positive is an allow
  # region hand-written for a line that was never a violation.
  _write "test/bats/unit/x_spec.bats" \
    '@test "terminated, then a note" {' \
    '  ! ovr_get some.key;# the override was never written' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: PASSES on a comment that opens right after a ')' (#956)" {
  # The same rule one metacharacter along: the `#` after the `)` that
  # closed the SUBSHELL starts a comment, so the `;` in the prose after
  # it is not this statement's separator either. Only that `)` -- the two
  # cases below run the ones that close an expansion instead.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a subshell, then a note" {' \
    '  ! (ovr_get some.key)# see also; the note below' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: FAILS on a ';' behind a '#' that follows a substitution's ')' (#956)" {
  # The `)` of a `$( ... )` closes the expansion, not the word -- the
  # bash case above runs `printf '[%s]\n' $(echo A)#b` and gets the
  # single argument `[A#b]`. So this `#` is data, the `; true` behind it
  # is this statement's own separator, and the negation is handed away.
  # Reading every `)` as a word end truncated the line at the `#` and hid
  # the separator: a MISSED violation, the one direction this lint
  # refuses -- and one the flat scan this comment rule replaced caught.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a substitution, then data" {' \
    '  ! grep -q A $(echo z)#b f; true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a ';' behind a STRAY ')' and a '#' (#956)" {
  # The unrecognised half of the same character. The scan reads one
  # PHYSICAL line at a time, so the `)` closing a `$(` that opened on the
  # line above arrives with nothing known about what it closes. Unknown
  # must resolve to "not a word end": the rest of the line stays code and
  # the `; true` is still read. The other answer discards the rest of the
  # line on a guess -- the drop this lint refuses.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a substitution across a continuation, then data" {' \
    '  ! grep -q A $(printf x \' \
    '    y)#b f; true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a ';' behind a '#' that follows a closing quote (#956)" {
  # A closing quote does not end a WORD -- the bash case above runs
  # `printf '[%s]\n' 'a'#b` and gets the single argument `[a#b]`. So the
  # `#` here is data, the `;` behind it is this statement's own
  # separator, and the negation is handed to `true`. Reading the quote as
  # a word end truncated the line at the `#` and hid the separator: a
  # MISSED violation, the direction this lint exists to refuse.
  _write "test/bats/unit/x_spec.bats" \
    '@test "a quoted word, then data" {' \
    "  ! grep -q 'a'#b f; true" \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
  _write "test/bats/unit/x_spec.bats" \
    '@test "a quoted word, then data" {' \
    '  ! grep -q "a"#b f; true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a ';' behind a '#' that follows an escape (#956)" {
  # The same word rule, the other spelling that continues a word: a
  # backslash escape. `a\ #b` is the one argument `a #b`, so this `#` is
  # data too and the `; true` behind it is real.
  _write "test/bats/unit/x_spec.bats" \
    '@test "an escaped blank, then data" {' \
    '  ! grep -q a\ #b f; true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: PASSES on a bang statement with a bare trailing ';' (#956)" {
  # A semicolon that terminates the statement rather than starting a
  # second one leaves the negation as the body's status.
  _write "test/bats/unit/x_spec.bats" \
    '@test "terminated, not continued" {' \
    '  ! ovr_get some.key;' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}


@test "_run_errexit_bang: PASSES on the '&' spellings that background nothing (#956)" {
  # `&` is only a hand-off when it is the async operator. `&&` is a list
  # operator the header already exempts by name, and `2>&1`, `&>` and
  # `|&` are parts of a redirection or a pipe operator -- in none of them
  # does the statement stop being the negation's. An unquoted `&` inside
  # `[[ ... ]]` needs no exemption: bash rejects it as a syntax error, so
  # it is never a statement this lint judges.
  _write "test/bats/unit/x_spec.bats" \
    '@test "and-and" {' \
    '  ! grep -q A "${_f}" && true' \
    '}'
  _write "test/bats/unit/y_spec.bats" \
    '@test "stderr redirected" {' \
    '  ! grep -q A "${_f}" 2>&1' \
    '}'
  _write "test/bats/unit/z_spec.bats" \
    '@test "both streams redirected" {' \
    '  ! grep -q A "${_f}" &>/dev/null' \
    '}'
  _write "test/bats/unit/w_spec.bats" \
    '@test "piped with stderr" {' \
    '  ! grep -q A "${_f}" |& grep -q B' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
  run bash -c '[[ a&b == a ]]'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"syntax error"* ]]
}

@test "_run_errexit_bang: PASSES when the bang statement is the body's last (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "final bang" {' \
    '  assert_success' \
    '  ! ovr_get some.key' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: PASSES when only comments and blanks follow the bang (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "trailing prose" {' \
    '  ! ovr_get some.key' \
    '  # the override was never written' \
    '' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: PASSES when the bang statement ends the body across a continuation (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "final continued bang" {' \
    '  ! grep -q A \' \
    '      "${_f}"' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: does not flag a bang that continues the previous line (#956)" {
  # `find ... \` / `! -name x` -- a find predicate, not a statement.
  _write "test/bats/unit/x_spec.bats" \
    '_libs() {' \
    '  find "${SRC}/lib" -name "*.sh" \' \
    '    ! -name "help.sh" | sort' \
    '}' \
    '@test "uses it" {' \
    '  _libs' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: does not flag a bang outside any test body (#956)" {
  # File-scope helpers are not bats bodies; errexit there is the caller's
  # problem and this rule says nothing about it.
  _write "test/bats/unit/x_spec.bats" \
    '_helper() {' \
    '  ! grep -q A "${_f}"' \
    '  return 0' \
    '}' \
    '@test "t" {' \
    '  _helper' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: does not flag a commented-out bang (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "prose about the shape" {' \
    '  # ! grep -q A "${_f}" would be inert here' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# Population: a scan that found nothing is not a pass
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: FAILS when the repo holds no *.bats at all (#956)" {
  rm -rf "${SCRATCH}/test/bats"
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no *.bats"* ]]
}

@test "_run_errexit_bang: FAILS when the spec directories are all empty (#956)" {
  # The directories exist, the specs do not. Same verdict: the population
  # is the FILES, and a walk that found none is not a clean tree.
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no *.bats"* ]]
}

@test "_run_errexit_bang: does NOT scan the released-tree archives (#956)" {
  # .prev-release/ is gitignored and materialised by `git archive <tag>`:
  # already-shipped history this branch cannot fix. It is one of the two
  # pruned names, and the prune is what keeps a released tree from failing
  # today's gate.
  _write "test/bats/unit/x_spec.bats" \
    '@test "clean" {' \
    '  true' \
    '}'
  _write ".prev-release/v0.9.5/test/bats/unit/old_spec.bats" \
    '@test "shipped inert assertion" {' \
    '  ! grep -q A "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: the clean line names every root it derived (#956)" {
  # The population is reported, not assumed: a tree that quietly stops
  # being scanned shows up as a missing root in this line.
  _write "test/bats/unit/x_spec.bats" \
    '@test "clean" {' \
    '  true' \
    '}'
  _write "dist/test/bats/smoke/shared/entrypoint.bats" \
    '@test "also clean" {' \
    '  true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 spec file(s)"* ]]
  [[ "${output}" == *"dist"* ]]
  [[ "${output}" == *"test"* ]]
}

@test "_run_errexit_bang: FAILS on a body the parser opened and never closed (#956)" {
  # Pending `!` statements are judged only when a `}` in the first column
  # arrives. A body that never produces one -- an indented closing brace, a
  # `}` eaten by an untracked heredoc, a truncated file -- reaches the end
  # of the read loop still open, and its pending statements are discarded
  # in silence. The header cross-check cannot see it: the header WAS
  # opened, so both counts agree. An unparseable file must be a failure,
  # never a quiet skip.
  _write "test/bats/unit/x_spec.bats" \
    '@test "the closing brace is indented" {' \
    '  ! test -e /definitely/not/here' \
    '  true' \
    '  }'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:1"* ]]
  [[ "${output}" == *"unclosed"* ]]
}

@test "_run_errexit_bang: FAILS when a test header the parser never opened exists (#956)" {
  # The population cross-check: every `@test` line in the tree must
  # correspond to a body the parser actually walked. A header whose brace
  # sits on the next line would otherwise make its whole body invisible
  # to the rule, and the lint would pass by not looking.
  _write "test/bats/unit/x_spec.bats" \
    '@test "brace on the next line"' \
    '{' \
    '  ! grep -q A "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"@test"* ]]
}

@test "_run_errexit_bang: FAILS on a violation in a bats tree outside test/bats (#956)" {
  # dist/test/bats/smoke/ is a SECOND live bats tree: `just test smoke`
  # runs it and the .base subtree ships it into every downstream repo. A
  # test body's return status is the verdict there exactly as it is under
  # test/bats, so a hand-listed scan root exempts it while the rule -- and
  # this lint's own name -- claim every bats body. The population is
  # DERIVED from the tree, not listed here.
  _write "test/bats/unit/x_spec.bats" \
    '@test "clean" {' \
    '  true' \
    '}'
  _write "dist/test/bats/smoke/shared/entrypoint.bats" \
    '@test "the entrypoint is installed" {' \
    '  ! test -e /entrypoint.sh' \
    '  true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/test/bats/smoke/shared/entrypoint.bats:2"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Allow region
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: an allow region suppresses the finding (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "opted out" {' \
    '  # errexit-bang-lint: allow-begin -- reason' \
    '  ! grep -q A "${_f}"' \
    '  # errexit-bang-lint: allow-end' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: an unterminated allow region fails (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "opted out and never back in" {' \
    '  # errexit-bang-lint: allow-begin -- reason' \
    '  ! grep -q A "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_errexit_bang: an unmatched allow-end fails (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "closed a region it never opened" {' \
    '  # errexit-bang-lint: allow-end' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: the real bats tree is clean (#956)" {
  REPO_ROOT=/source
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}
