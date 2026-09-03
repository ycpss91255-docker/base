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
#   (b) the statement hands its verdict away -- a `;` with anything after
#       it, an async `&` (trailing or not), or `|| true` / `|| :` --
#       ANYWHERE in it, including on a continuation line.
#
# (b) exists because (a) is judged by POSITION, and one statement can hold
# more than one command. `! cmd; other` returns `other`'s status
# unconditionally, `! cmd &` returns the fork's -- 0, whatever cmd did --
# and `! cmd || true` returns 0 in precisely the branch that matters --
# the one where cmd SUCCEEDED and the assertion was supposed to fail.
# All three are the same discarded negation as a `!` on an earlier line,
# so all three are reported wherever they sit rather than only when they
# land last.
#
# The WHOLE statement is read, not its opening physical line. A backslash
# moves a separator one line down and changes nothing about who owns the
# status, and the shape it produces escapes (a) as well: a statement
# continued onto the body's last line IS the last statement, which is
# where the position rule declines to fire. Judging the first line only
# left `! grep -q A \` / `"${_f}"; true` reported by nothing at all.
#
# Reading the whole statement means reading it to its END, wherever that
# falls -- and whether the NEXT physical line belongs to it is answered
# by the folded text, with exactly one thing read off the raw line: a
# completely BLANK line ends a backslash continuation, because bash
# removes the backslash-newline and the blank line's own newline is then
# the terminator. A line that merely OPENS with `#` does NOT end one, and
# that is the whole difference from the predicate this replaced, because
# the backslash-newline is a SPLICE and not a join:
# `! grep -q A\` followed by `#b f; true` is the one word `A#b` and a
# live `; true` behind it, while `! grep -q A \` followed by the same
# `#b f; true` -- one blank further left -- really is a comment. Reading
# the second line on its own gets one of the two wrong whichever answer
# it picks, which is why it is not asked. The statement is judged where
# it ends, on the last line that carried code, rather than being carried
# to the next real line (where it was silently discarded, and so escaped
# both rules).
#
# NOT every `||` is that hand-off, and the two named above are the only
# ones flagged. `! A || B` runs B exactly when A SUCCEEDED, so who owns
# the verdict is decided by B: `! A || return 1` and `! A || fail "..."`
# fail the test in that branch, correctly, and an ORDINARY B's failure is
# not exempt from errexit either, so they fail it from a non-final
# position too -- such a statement is out of BOTH rules.
#
# One B breaks that, and it is the one the exemption used to cover: a B
# that is itself `!`-inverted. bash suppresses errexit for a command
# whose return value is inverted with `!`, and the operand after the
# final `||` is a command like any other -- so `! A || ! B` aborts
# nothing, and away from the body's last statement it is exactly the
# inert assertion this lint is named for:
#   set -e; f(){ ! true || ! true; echo REACHED; }; f  -> REACHED, 0
#   set -e; f(){ ! true || false;  echo REACHED; }; f  -> aborts,  1
# The exemption is therefore DECLINED as soon as any operand in the list
# opens with `!`, and the statement falls through to the position and `;`
# rules like every other one. As the body's LAST statement it still
# passes, because there its own status is the verdict (B succeeding
# returns 1) -- position, not the exemption, is what makes that case
# clean. Declining it for the whole class rather than only where the list
# is provably inert is deliberate: `! A || ! B || return 1` DOES fail
# from a non-final position, and telling it apart from `! A || ! B` needs
# the chain EVALUATED rather than read, so it is reported too. That
# over-report costs one allow region, which is the refusing direction
# this file takes wherever the text stops answering the question.
# errexit_bang_lint_spec pins both halves by RUNNING them.
#
# `true` and `:` are the only SIMPLE COMMANDS that cannot fail; they are
# the language's two always-zero builtins, a closed set fixed by bash
# rather than a roster of this tree, which is why listing them is not the
# listed-population defect this file otherwise refuses.
#
# They are not, however, every always-zero OPERAND: a group is one too,
# and `! A || { true; }` / `! A || ( true )` are as inert as `|| true`
# while taking the live-`||` exemption. Both go unreported, and that is a
# disclosed narrowing rather than a claim: the closed-set argument covers
# builtins, not groups, and it does not extend. A `( ... )` operand is
# blanked by the paren rule below, so this scan cannot see what is in it
# at all; and "can this group fail" has no lexical answer in general
# (`|| ( exit 1 )` fails, `|| { true; }` does not), so matching the one
# spelling that happens to be writable as a regex would be a guard
# narrower than its own name -- the defect this whole file exists to
# stop. Fixing it needs a different question than a scan can ask.
#
# The same narrowing has a second cost: `! A || echo x` is inert and goes
# unreported. This lint is named for statements that CANNOT fail their
# test, and flagging one that can would be a wider claim than the rule
# makes -- on a blocking gate the price of the wider claim is an allow
# region hand-written for a line that was never a violation.
#
# `&&` is out for the same reason. `! A && B` parses as `(! A) && B` and
# short-circuits to 1 whenever A succeeded, so as the body's last
# statement the failing case still reaches its return status. Earlier in
# the body it is inert like any other `!` statement, which is what (a)
# already says about it.
#
# A single `&` is the opposite case and IS reported. It is not a list
# operator but the async one: `! A &` forks, and the list's status is 0
# whatever A did, so the statement cannot fail its test even as the
# body's last -- the one position rule (a) declines to judge. `! A & B`
# discards the negation just as unconditionally and returns B's status,
# which is the `;` case spelled differently. The neighbouring spellings
# that merely contain the character -- `&&`, `|&`, `>&` / `<&`, `&>` --
# are excluded by the operator they belong to, not by a roster.
# errexit_bang_lint_spec pins both by RUNNING the shapes, not by asserting
# them here.
#
# The separator scan reads the statement's CODE, not its raw text:
# quoted spans are blanked, an unquoted `( ... )` is blanked with them,
# and a comment is dropped first -- one that opens after a blank or after
# a word-ending metacharacter, which is where the shell opens one -- so
# `! grep -q 'a;b' f`, `! grep -q $(foo; bar) f`,
# `! grep -q A f  # see also; below` and `! ovr_get k;# a note` are not
# read as two commands. Both rules ask about the statement's OWN
# top-level list: a separator inside a subshell or a command substitution
# is an argument's, and reading it as the statement's exempted an inert
# `! grep -q $(foo || bar) f` from both rules while reporting a
# `$(foo; bar)` that was never a violation. The tracker is three quote
# states, a backslash escape, one paren depth and four list/pipe
# operators -- it is not a second bash parser and does not try to be one
# (no expansion, no heredoc, no compound command).
#
# That scan runs on the LOGICAL line, never on a physical one, and that
# is the structure rather than a tuning of the predicate. Whether a `#`
# opens a comment is not answerable from one line: a `$(` opened on one
# line and closed on the next left the continuation scanned at depth 0,
# where a blank-preceded `#` read as a comment and everything behind it
# was discarded --
#
#     ! grep -q A $(echo \
#       x #y) f; true
#
# lost `#y) f; true`, so the `; true` reached NEITHER rule. Three rounds
# of patching a per-line predicate each moved that drop one shape further
# out, because the state a physical line needs is the state the previous
# line ended in. So the lines are FOLDED first and the scan decides once,
# on the whole statement -- the shape
# dist/script/docker/lib/dockerfile_migrate.sh already uses for multi-line
# COPY statements (`_dfm_join_copy_statements`, `_dfm_smoke_copy_present`).
#
# A logical line continues while the folded text is INCOMPLETE, and this
# scan models three forms of that. A line-continuation backslash. A
# quote or a `(` still open at the end of the text -- which is what
# carries the paren depth and the quote state across the fold instead of
# resetting them, and what reads a `$( ... )` spanning lines with no
# backslash at all as the one statement it is. And a list or pipe
# operator with no right operand yet (`|`, `||`, `&&`, `|&`), which bash
# reads on for with no backslash either: without it,
#
#     ! grep -q A f ||
#       true
#
# read as two statements, the first took the live-`||` exemption meant
# for `! A || return 1`, the lone `true` was judged by no rule, and the
# `|| true` this lint names in its own message went unreported -- while
# the same split over `&&` or `|` ended the `!` a line early and had the
# position rule report a statement that WAS the body's last.
#
# The three differ in how they treat the lines they read through. A
# backslash SPLICES: the two physical lines become one character
# sequence with nothing between them, so a word broken across the join
# stays one word. The other two are separated by a real newline, which
# is a blank, and both read straight past blank and comment lines the
# way bash does.
#
# Bash has more incompleteness than these three -- an `if`/`while`/`for`/
# `case` block, a `{` list, a heredoc awaiting its terminator. None is
# modelled. Each is in the WHAT IS NOT MODELLED list below with the
# direction it errs in; the list is the limit of this scan, stated, not
# a promise that there is no other.
#
# Where the scan meets a construct it does not recognise it AIMS at the
# REFUSING direction, because a dropped statement is invisible and a
# false positive is not. Two answers spell that out. They are answers
# about two specific constructs, not a property this scan has in
# general: the list below names where the aim does not hold.
#
# A `)` that closes a `(` opened outside this statement -- a heredoc
# body, a `case` pattern -- does not end a word. The text stays CODE and
# is read on rather than truncated on a guess, so no separator behind it
# is discarded.
#
# A statement still UNFINISHED when the fold reaches the body's `}` --
# an open quote or `(`, or an operator that never got its right operand
# -- is the scan saying it lost track. It is reported when it can have
# cost something: when the span this lint judges is a `!` one (its code
# was read only as far as the scan got), or when a line that OPENS a `!`
# statement was folded into it while a quote or `(` was open (that line
# is then judged by no rule). It is NOT reported otherwise, and that is
# a claim rather than a shrug: the only lines this lint judges are the
# ones opening with `!`, so a fold that swallowed none of them hid no
# violation. What stays unreadable is a heredoc body or a multi-line
# string -- constructs this scan never modelled -- and they no longer
# fail a gate they have no bearing on. A `!` line inside a heredoc still
# reads as a statement, the false alarm the allow region answers -- and
# BOTH of those rows are gated on the allow region, like every row that
# judges a `!` line, because a finding the documented opt-out cannot
# silence is a blocking gate nobody can get past. (The two rows that are
# NOT so gated report the file itself, not a statement in it: a body
# left open at EOF, and an unbalanced allow marker. Silencing either
# with the mechanism they are about would close the hole they exist to
# keep open.)
#
# WHICH SPAN the rules are asked about is a second question, and getting
# it wrong is the same defect one level down: reading a property of a
# statement off text that is not the statement. A logical line is judged
# for the `!` statement inside it, which is the whole of it when the line
# OPENS with `!` and a TAIL of it when an operator fold pulled a `!` line
# in. `echo a ||` over `! grep -q A f; true` is one logical line and the
# `;` really does throw the negation away -- but the `||` in front of the
# `!` is the echo's, not the `!`'s hand-off, so asking the rules about
# the whole line would take the live-`||` exemption and say nothing.
# The span starts at the `!`, and the row names the line it starts on.
#
# An operator fold is therefore NOT part of the swallow row, and does not
# need to be: it takes no `!` line out of reach. Where the logical line
# already opens with `!`, the line folded in is that same statement's
# text -- `! A ||` over `! B` is one `||` list with one verdict, so it is
# judged ONCE, from the line the first `!` opens on. A second row on the
# second `!` would be a false positive; a clean verdict on the list is
# not, and used to be what came out: the list is a live assertion only as
# the body's last statement, and one statement earlier the `!` on B
# exempts it from errexit and it cannot fail. That is the position rule's
# case, which it now reaches. Where the logical line does NOT open with
# `!`, the folded-in `!` opens the judged span and is put through the
# rules exactly as it would have been on a line of its own, position rule
# included: `echo a && ! grep -q A f` as the body's LAST statement is
# still the body's verdict and stays clean.
#
# WHAT IS NOT MODELLED, and which way each one is wrong. This list is
# the honest half of the paragraph above: the scan is three quote
# states, one paren depth, a backslash and four operators, so anything
# else is read with the wrong rule. Each entry says which direction that
# lands in, because "refusing" is a claim about a specific construct and
# not a property the scan has in general.
#
#   - ANSI-C quoting, `$'...'`. The `$` is an ordinary character here
#     and the `'` opens a plain single-quoted span, so an escaped quote
#     inside it (`$'a\'b'`) leaves the scan with a quote it never sees
#     closed. OVER-reports: the statement is reported as still
#     UNFINISHED where the body closes -- verified, that is the row it
#     prints. Refusing direction; costs one allow region.
#   - Backtick command substitution. No depth is opened for it, so its
#     text is read as this statement's own -- a `;` or an `||` inside
#     backticks is taken for the statement's separator. OVER-reports,
#     and did so before this scan existed too. Refusing direction.
#   - Heredocs, as the limitation note below already says. Its body is
#     read as code, so a fixture line opening with `!` reads as a
#     statement -- and it still does when the line above it ends in
#     `|`, `||`, `&&` or `|&`, because the fold that pulls it in opens
#     the judged span on it. OVER-reports, the usual heredoc false
#     alarm, answered by one allow region. Refusing direction. The MISS
#     heredocs carry is the other shape in that note: a `}` at column 0
#     inside one closes the body early.
#   - Compound commands -- `if`, `while`, `for`, `case`, a `{ ... }`
#     list. A block's STATUS is its last command's, but the scan reads
#     each line inside one as its own statement and counts the closing
#     `fi` / `done` / `esac` / `}` as the body's last. A `!` that ends
#     such a block, where the block ends the test body, is therefore
#     reported although it IS the verdict. OVER-reports; refusing
#     direction; costs one allow region. base#991 tracks it.
#   - CRLF line endings. `IFS= read -r` keeps the `\r`, so a trailing
#     backslash escapes the CARRIAGE RETURN rather than the newline and
#     the continuation is never seen. Mostly that over-reports (the
#     statement is judged short and the position rule fires on the
#     wrong line), but the splice above is lost with it, so
#     `! grep -q A\` + `#b f; true` written with CRLF is a silent MISS.
#     Every *.bats in this tree is LF; base#990 tracks it.
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
# one reads as a statement (a false alarm the allow region answers,
# whether or not the line above it ends in a list or pipe operator), and
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
# The three separator tests, all applied to the statement's CODE (quoted
# spans blanked, trailing comment dropped) with its continuation lines
# joined on -- never to one physical line.
#
# A `;` with another command after it. A bare trailing `;` terminates the
# statement and is fine.
readonly _ERREXIT_BANG_SEQ_RE=';[[:space:]]*[^[:space:]]'
# The ASYNC operator. A lone `&` forks: trailing, the list's status is 0
# whatever the command did; with a command after it, the status is that
# command's, unconditionally -- the same discard as a `;`. The four
# neighbouring spellings that are NOT it are excluded by their adjacent
# character rather than by a roster: `&&` (a list operator), `|&` (part
# of the pipe operator), `>&` / `<&` and `&>` (parts of a redirection
# operator). An unquoted `&` inside `[[ ... ]]` needs no exemption --
# bash rejects it as a syntax error, so no statement this lint judges
# can hold one, the same argument that keeps `<` and `>` out of the
# comment-start set.
readonly _ERREXIT_BANG_ASYNC_RE='(^|[^&<>|])&([^&>]|$)'
# An `||` whose right operand CANNOT fail. `true` and `:` are bash's two
# always-zero builtins -- a closed set, which is why matching them by name
# is not the listed-population defect this file otherwise refuses. It is
# not every inert shape: an always-zero GROUP (`|| { true; }`,
# `|| ( true )`) is inert too and goes unreported, for the reason the
# header gives.
readonly _ERREXIT_BANG_INERT_OR_RE='\|\|[[:space:]]*(true|:)([[:space:]]*;|[[:space:]]*$)'
# An `||` that belongs to the bang command itself -- no `;` closes the
# list before it. With any other right operand the verdict is that
# operand's and the statement leaves this rule entirely (see the header).
readonly _ERREXIT_BANG_LIVE_OR_RE='^[^;]*\|\|'
# A list or pipe operator whose RIGHT OPERAND opens with `!`. bash exempts
# a command whose return value is inverted with `!` from errexit, so such
# an operand cannot abort the body -- which is the one thing the exemption
# above assumes its operand does. The four operators are the same set the
# fold reads on across (`|`, `||`, `&&`, `|&`), and the trailing space is
# the one `_ERREXIT_BANG_STMT_RE` uses: `!=` and `!(` are not this.
readonly _ERREXIT_BANG_BANG_OPERAND_RE='(\|\||&&|\|&|\|)[[:space:]]*![[:space:]]'

# Region markers for the explicit opt-out (see the header note).
readonly _ERREXIT_BANG_ALLOW_BEGIN='errexit-bang-lint: allow-begin'
readonly _ERREXIT_BANG_ALLOW_END='errexit-bang-lint: allow-end'

# _errexit_bang_code_scan <text> <code_outvar> <cont_outvar>
#   Scan ONE LOGICAL LINE -- a statement with every continuation line
#   already folded into it -- from its first character, and answer the
#   two questions the caller has about it.
#
#   <code_outvar> gets the statement's CODE: every character inside a
#   quote replaced by a space, everything inside an unquoted `( ... )`
#   replaced with it, and a trailing comment dropped. The separator tests
#   run on this, so that a `;` the shell would read as an argument or as
#   prose is not read here as a second command.
#
#   <cont_outvar> gets how the text ENDS, which is what decides whether
#   the next physical line is part of this same statement:
#     0  complete -- the statement ends here.
#     1  a line-continuation backslash: the last character is a `\` with
#        nothing left for it to escape but the newline.
#     2  a quote or a `(` is still open. bash reads straight on in both
#        cases, so this scan does too, and this is the value that carries
#        the paren depth and the quote state ACROSS the fold instead of
#        resetting them at every line -- the whole point of folding.
#   The caller appends the next physical line and calls again from the
#   top: the state is rebuilt from the whole buffer rather than resumed,
#   so there is no half-scanned state to hand over and get wrong.
#
#   Three quote states (unquoted / single / double) plus a backslash
#   escape outside single quotes, and nothing else -- expansions and
#   heredocs are not modelled, exactly as the header says. A `#` ends the
#   text only where it starts a WORD, which is where the shell starts a
#   comment; `;# note` is a terminator and prose, not a second command.
#   In mid-word it is data and the scan goes on.
#
#   `_word_end` carries that single bit, and every construct below
#   answers for itself rather than being matched against a list of
#   characters. A word ends at the start of the text, after a blank, and
#   after `;`, `&` or `|`. It does NOT end at a closing quote, at a
#   consumed backslash escape or after any ordinary character: `'a'#b`,
#   `"a"#b` and `a\ #b` are one argument apiece and the `#` in them is
#   data. Reading such a `#` as a comment dropped the rest of the text
#   and hid a real separator -- a MISSED violation, the one direction
#   this lint refuses. That is also why the flag DEFAULTS to 0: a
#   construct this scan does not recognise leaves the word open, and an
#   open word means the text is read on rather than discarded on a guess.
#   Over-reporting costs a hand-written allow region; under-reporting is
#   the defect. `<` and `>` end a word as well and are deliberately left
#   out: a comment there eats the redirect's target, so the line is a
#   SYNTAX ERROR and never a statement this lint judges (the spec runs
#   that one too). Blanking rather than deleting keeps the column count.
#
#   `)` is not one case but two, and reading it as one was a drop. The
#   `)` that closes a SUBSHELL ends a word -- `(echo A)# note` really is
#   a comment, and so is `(( x & 1 ))#b`. The `)` that closes an
#   EXPANSION does not: `$( )`, `$(( ))`, `<( )` and `>( )` leave the
#   surrounding word open, `printf '[%s]\n' $(echo A)#b` prints the one
#   argument `[A#b]`, and taking that `#` for a comment blanked the
#   `; true` behind it. Which one a `)` is depends on the `(` it closes,
#   so the `(` at depth 0 reads the character in front of it and records
#   the answer in `_paren_ends_word`; its `)` reads it back. Folding is
#   what makes that answer available: the `(` and its `)` are in the same
#   text now even when they sit on different lines, which is exactly the
#   case a per-line scan could not answer.
#
#   A `)` at depth 0 is the leftover case, and it is now genuinely
#   unrecognised rather than merely unread: the `(` it closes was opened
#   OUTSIDE this statement -- a heredoc body, a `case` pattern -- neither
#   of which this scan models. There is no answer to read back, and
#   unknown resolves to the open word, per the default above.
#
#   One nesting IS tracked: an unquoted `( ... )`. Everything inside it is
#   blanked, because a separator there belongs to a SUBSHELL or a command
#   substitution -- an argument to this statement -- and not to the
#   statement's own top-level list. `! grep -q $(foo || bar) f` hands its
#   verdict to nobody, and `! grep -q $(foo; bar) f` starts no second
#   command; reading either separator as this statement's dropped the
#   first out of both rules and reported the second as a violation it is
#   not. Blanking is also why a `#` INSIDE a substitution is not modelled
#   as the comment bash makes of it: its text is blanked with the rest of
#   the substitution and the `)` still closes the depth, so
#   `$(echo x #y) f; true` is reported for the `; true` behind it rather
#   than read as the unterminated substitution bash rejects. Reporting a
#   line bash will not even parse is the refusing direction.
_errexit_bang_code_scan() {
  local _s="${1}"
  local -n _ebcs_code="${2}"
  local -n _ebcs_cont="${3}"
  local _out='' _i _ch _q='' _prev=' ' _depth=0 _trail=0
  # A SHADOW of the code, built alongside it, where every span the code
  # blanks contributes the placeholder `x` instead of a space. The
  # trailing-operator test below is read off THIS, never off `_out`: the
  # code blanks a `( ... )` to spaces, so `! A || ( true )` ends in a
  # bare `||` there and would read as a statement still waiting for its
  # operand -- turning the disclosed `|| ( true )` narrowing into a false
  # positive. `x` remembers that an operand was in fact written.
  local _sig=''
  # Would a `#` HERE open a comment? A logical line opens a word, so this
  # starts set; every branch below answers for itself. Anything
  # unrecognised leaves it 0 -- "no comment here" -- which keeps the rest
  # of the text as code.
  local _word_end=1
  # Whether the `)` that closes the `(` currently open at depth 0 ends a
  # word. Recorded when that `(` is read, the only point at which the
  # character in front of it is visible.
  local _paren_ends_word=0
  for (( _i = 0; _i < ${#_s}; _i++ )); do
    _ch="${_s:_i:1}"
    # Only a backslash that reaches the END of the text continues the
    # line, so any character read after one clears the flag again.
    _trail=0
    if [[ "${_q}" != "'" && "${_ch}" == $'\\' ]]; then
      # An escaped character is data, and neither it nor the backslash
      # ENDS a word: `a\ #b` is the one argument `a #b` and the `#` is
      # data. A backslash with nothing left to escape escapes the
      # NEWLINE: the statement continues onto the next physical line, and
      # the caller folds it in.
      _out+=' '
      _sig+='x'
      if (( _i + 1 < ${#_s} )); then
        _out+=' '
        _sig+='x'
        _i=$(( _i + 1 ))
      else
        _trail=1
      fi
      _prev=$'\\'
      _word_end=0
      continue
    fi
    if [[ -n "${_q}" ]]; then
      # A quote that CLOSES does not end the word either (`'a'#b` is the
      # one argument `a#b`). Inside the span nothing is read as syntax: a
      # `#` there reaches this branch, not the comment case below.
      if [[ "${_ch}" == "${_q}" ]]; then
        _q=''
      fi
      _out+=' '
      _sig+='x'
      _prev="${_ch}"
      _word_end=0
      continue
    fi
    case "${_ch}" in
      "'"|'"')
        _q="${_ch}"
        _out+=' '
        _sig+='x'
        _prev="${_ch}"
        _word_end=0
        continue
        ;;
      '(')
        # Which `(` this is decides whether its `)` ends a word (see the
        # doc above). `$(`, `$((`, `<(` and `>(` open an EXPANSION, whose
        # close leaves the surrounding word open; a bare `(` opens a
        # subshell -- or, doubled, an arithmetic command -- whose close
        # ends one. Only the outermost is recorded, because the comment
        # test runs at depth 0 alone.
        if [[ "${_depth}" -eq 0 ]]; then
          case "${_prev}" in
            '$'|'<'|'>') _paren_ends_word=0 ;;
            *)           _paren_ends_word=1 ;;
          esac
        fi
        _depth=$(( _depth + 1 ))
        _out+=' '
        _sig+='x'
        _prev='('
        _word_end=1
        continue
        ;;
      ')')
        if [[ "${_depth}" -gt 0 ]]; then
          _depth=$(( _depth - 1 ))
          # Back at top level this `)` is whatever its `(` said it was.
          if [[ "${_depth}" -eq 0 ]]; then
            _word_end="${_paren_ends_word}"
          else
            _word_end=0
          fi
        else
          # A `)` closing a `(` this statement never opened -- a heredoc
          # body, a `case` pattern. What it closes is unknown, and
          # unknown is not a word end: the text is read on rather than
          # truncated on a guess.
          _word_end=0
        fi
        _out+=' '
        _sig+='x'
        _prev=')'
        continue
        ;;
      '#')
        # A comment starts where the `#` starts a WORD. In mid-word it is
        # data (`echo B#note` prints `B#note`, and so do `'a'#b`, `a\ #b`
        # and `$(echo a)#b`), which is why this is not an unconditional
        # break.
        if [[ "${_depth}" -eq 0 && "${_word_end}" -eq 1 ]]; then
          break
        fi
        ;;
    esac
    if [[ "${_depth}" -gt 0 ]]; then
      # Inside `( ... )`: an argument's own text, never this statement's
      # separator.
      _out+=' '
      _sig+='x'
      _prev=' '
      _word_end=0
      continue
    fi
    _out+="${_ch}"
    _sig+="${_ch}"
    _prev="${_ch}"
    # The word-ending characters a statement can continue past. `)` is not
    # among them: it answered for itself above, and everything else -- an
    # ordinary character -- continues the word.
    case "${_ch}" in
      ' '|$'\t'|';'|'&'|'|') _word_end=1 ;;
      *)                     _word_end=0 ;;
    esac
  done
  _ebcs_code="${_out}"
  # The last run of non-blank text in the SHADOW, for the operator test
  # below. Reading it there rather than off the raw line is what keeps a
  # `|` inside a quote, inside a `( ... )` or behind a `#` from being
  # mistaken for the statement's own unfinished operator; reading it
  # there rather than off `_out` is what keeps a blanked operand from
  # LOOKING like a missing one.
  local _tail=''
  [[ "${_sig}" =~ ([^[:space:]]+)[[:space:]]*$ ]] && _tail="${BASH_REMATCH[1]}"
  # An open quote or `(` outranks the other two: all three continue the
  # statement, and the caller distinguishes them only to know whether a
  # blank or comment line can end it.
  if [[ -n "${_q}" || "${_depth}" -gt 0 ]]; then
    _ebcs_cont=2
  elif [[ "${_trail}" -eq 1 ]]; then
    _ebcs_cont=1
  elif [[ "${_tail}" == *'|' || "${_tail}" == *'&&' || "${_tail}" == *'|&' ]]; then
    # A list or pipe operator with no right operand yet. `|`, `||`, `&&`
    # and `|&` all need one, and bash reads on -- across blank and
    # comment lines -- until it has it. A lone trailing `&` is NOT one of
    # them: it is the async operator and it TERMINATES the list, which is
    # why the test looks at the last two characters rather than at the
    # character class.
    _ebcs_cont=3
  else
    _ebcs_cont=0
  fi
}

# _errexit_bang_scan_file <abs_path> <rel_path> <rows_outvar> <headers_outvar>
#   Append one `<rel>:<line>: <text>` row per violation to <rows_outvar>
#   and add this file's `@test` header count to <headers_outvar>. Called
#   directly, never through a command substitution: both outputs are
#   namerefs, and a subshell would drop the count.
#
# One pass over the PHYSICAL lines that folds them into LOGICAL ones.
# The state is: whether we are inside a body, the logical line currently
# being read (its folded text, the physical line it opened on, the line
# it has reached, its opening text for the report, its code, how that
# code ENDS and whether it is a `!` statement this lint judges), the
# pending `!` statements of the current body (start line, END line, text)
# and the line number of the body's last statement.
#
# EVERY line inside a body is folded, not only a `!` one. Which physical
# line the next statement starts on is exactly the question the fold
# answers, and folding only the lines already known to be `!` statements
# would need the answer before it had it -- two scanners again, which is
# the defect this shape replaces.
#
# A statement is judged when it ENDS -- a separator can still arrive on a
# continuation line -- and a pending statement is judged for (a) only
# when the body closes, since "is this the last statement" is not
# knowable before then.
_errexit_bang_scan_file() {
  local _abs="${1}" _rel="${2}"
  local -n _ebsf_rows="${3}"
  local -n _ebsf_headers="${4}"

  local _line _lineno=0 _in_body=0 _body_open=0 _last_stmt=0
  local _in_allow=0 _begin_line=0 _close=0 _is_stmt=0 _is_blank=0
  local _judge=0 _fold=0
  # The logical line in progress; an empty `_lbuf` means there is none.
  local _lbuf='' _ltext='' _lcode='' _lstart=0 _lend=0 _lcont=0 _lbang=0
  # The SPAN the rules are asked about: the `!` statement inside the
  # logical line above. It is the whole of it when the line opens with
  # `!`, and a TAIL of it when an operator fold pulled a `!` line in --
  # asking the rules about the whole line there would read a `||` that
  # belongs to the line ABOVE the `!` as the `!`'s own hand-off, and
  # would name the wrong line in the row.
  local _lbbuf='' _lbtext='' _lbcode='' _lbstart=0 _lbcont=0
  # Set, with the line number, when a line that OPENS a `!` statement was
  # folded in because the scan had an unterminated quote or `(` -- the
  # one way the fold can take a statement this lint judges out of its
  # reach. An operator fold (3) does not set it: there the folded line
  # is the operator's right operand and bash reads it as part of this
  # statement too, so it is out of reach correctly.
  local _lswallow=0 _lswallow_line=0 _why=0
  local -a _pending_line=() _pending_end=() _pending_text=()
  local _i

  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))

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
        _lbuf=''
        _pending_line=()
        _pending_end=()
        _pending_text=()
      fi
      continue
    fi

    _close=0
    [[ "${_line}" =~ ${_ERREXIT_BANG_TEST_CLOSE_RE} ]] && _close=1
    # Two questions about the raw line, and neither of them is "does this
    # line start with a `#`". A BLANK line opens no statement and, alone
    # among the three kinds of continuation, ends a backslash one: bash
    # removes the backslash-newline, and the blank line's own newline is
    # then the terminator. A line that merely LOOKS like a comment is not
    # asked about here at all -- whether its `#` opens a comment is a
    # question about the spliced text, which only the code scan can
    # answer, and asking it here is the per-physical-line predicate this
    # driver exists to be rid of. `_is_stmt` is used for one thing only:
    # whether this line can OPEN a logical line, where there is no text
    # in front of the `#` and the answer really is local.
    _is_blank=0
    [[ -z "${_line//[[:space:]]/}" ]] && _is_blank=1
    _is_stmt=1
    if [[ "${_is_blank}" -eq 1 ]] || [[ "${_line}" =~ ^[[:space:]]*# ]]; then
      _is_stmt=0
    fi

    # Does this physical line belong to the logical line above it? An
    # open quote or `(` (2) and an unfinished operator (3) read straight
    # through blank and comment lines, exactly as bash does. A backslash
    # (1) is ended by a blank line and by nothing else -- a comment-
    # looking line is spliced in and then judged by the scan, because
    # `A\` + `#b` is the single word `A#b` and the `#` in it is data.
    _fold=0
    if [[ "${_close}" -eq 0 && -n "${_lbuf}" ]]; then
      case "${_lcont}" in
        2|3) _fold=1 ;;
        1)   [[ "${_is_blank}" -eq 0 ]] && _fold=1 ;;
        *)   ;;
      esac
    fi

    _judge=0
    if [[ -n "${_lbuf}" ]]; then
      if [[ "${_fold}" -eq 1 ]]; then
        # This physical line belongs to the statement above it. Fold it
        # in and re-decide on the WHOLE text: the quote state and the
        # paren depth are rebuilt from the first character, which is what
        # a per-line scan could not do.
        #
        # WHY it is folded decides what the fold owes. A backslash (1)
        # and an unfinished operator (3) are bash's own continuations and
        # the line is genuinely part of this statement (`find ... \` +
        # `! -name x` is a find predicate, and `! A ||` + `! B` is one
        # `||` list, neither of them a second assertion). An unterminated
        # quote or `(` (2) is instead the scan admitting it lost track,
        # and a line that would OPEN a `!` statement disappearing into
        # one is the only way this fold can hide something the rule
        # judges. Remember it and report it below.
        _why="${_lcont}"
        if [[ "${_why}" -eq 2 && "${_in_allow}" -eq 0 \
              && "${_line}" =~ ${_ERREXIT_BANG_STMT_RE} ]]; then
          # Gated on the allow region for the same reason every other row
          # is: a line the operator has already bracketed by hand is a
          # line they have judged, and the row below tells them to
          # bracket exactly this one. A finding its own documented
          # opt-out cannot silence is a blocking gate nobody can get
          # past.
          _lswallow=1
          _lswallow_line="${_lineno}"
        fi
        # A `!` line pulled in by an operator fold (3) belongs to this
        # logical line AND opens a statement this lint judges. Whether
        # the logical line is a `!` one used to be read off the line it
        # opened on alone, so a `!` folded in below a non-`!` line was
        # judged by no rule at all. The judged span starts here instead.
        # Only an operator fold: a backslash (1) continues the COMMAND
        # above it (`find ... \` + `! -name x` is a find predicate, not
        # an assertion), and a quote or `(` (2) is the scan admitting it
        # lost track, which is the swallow row above. Gated on the allow
        # region like every row that judges a `!` line.
        if [[ "${_why}" -eq 3 && "${_lbang}" -eq 0 && "${_in_allow}" -eq 0 \
              && "${_line}" =~ ${_ERREXIT_BANG_STMT_RE} ]]; then
          _lbang=1
          _lbstart="${_lineno}"
          _lbtext="${_line}"
          _lbbuf="${_line}"
        elif [[ "${_lbang}" -eq 1 ]]; then
          # The span is already open: this line extends it, spliced the
          # same way `_lbuf` is just below.
          if [[ "${_why}" -eq 1 ]]; then
            _lbbuf="${_lbbuf%\\}${_line}"
          else
            _lbbuf+=" ${_line}"
          fi
        fi
        if [[ "${_why}" -eq 1 ]]; then
          # A backslash-newline is REMOVED: the two physical lines become
          # one character sequence with nothing inserted between them, so
          # the splice is written that way. Joining them with a space
          # instead would end the word the backslash was glued to and
          # turn a following `#` from data into a comment. The other two
          # continuations really are separated by a newline, which is a
          # blank, so a space stands in for it there.
          _lbuf="${_lbuf%\\}${_line}"
        else
          _lbuf+=" ${_line}"
        fi
        _lend="${_lineno}"
        _last_stmt="${_lineno}"
        _errexit_bang_code_scan "${_lbuf}" _lcode _lcont
        # The span is scanned on its own: the rules below read its code,
        # not the logical line's.
        [[ "${_lbang}" -eq 1 ]] \
          && _errexit_bang_code_scan "${_lbbuf}" _lbcode _lbcont
        [[ "${_lcont}" -eq 0 ]] && _judge=1
      else
        # The statement ends WITHOUT consuming this line: a blank or a
        # comment line closed its backslash continuation, or the body's
        # `}` arrived while it was still open.
        _judge=1
      fi
    elif [[ "${_close}" -eq 0 && "${_is_stmt}" -eq 1 ]]; then
      _lbuf="${_line}"
      _ltext="${_line}"
      _lstart="${_lineno}"
      _lend="${_lineno}"
      _last_stmt="${_lineno}"
      _lbang=0
      _lswallow=0
      _lbbuf=''
      if [[ "${_in_allow}" -eq 0 && "${_line}" =~ ${_ERREXIT_BANG_STMT_RE} ]]; then
        _lbang=1
        _lbstart="${_lineno}"
        _lbtext="${_line}"
        _lbbuf="${_line}"
      fi
      _errexit_bang_code_scan "${_lbuf}" _lcode _lcont
      [[ "${_lbang}" -eq 1 ]] \
        && _errexit_bang_code_scan "${_lbbuf}" _lbcode _lbcont
      [[ "${_lcont}" -eq 0 ]] && _judge=1
    fi

    if [[ "${_judge}" -eq 1 ]]; then
      if [[ "${_lswallow}" -eq 1 ]]; then
        # The fold took a `!` line with it while the scan had no idea
        # where the statement ended. That line is judged by nothing, and
        # a statement judged by nothing is exactly what this lint exists
        # to stop -- so it is reported, and the price of being wrong is
        # one hand-written allow region.
        _ebsf_rows+=("${_rel}:${_lstart}: ${_ltext}  -- an unterminated quote or '(' folded line ${_lswallow_line}, which opens with '!', into this statement, so that line was judged by no rule (bracket line ${_lswallow_line} with the allow markers if that is deliberate)")
      elif [[ ( "${_lbcont}" -eq 2 || "${_lbcont}" -eq 3 ) && "${_lbang}" -eq 1 ]]; then
        # A `!` statement still unfinished where the body closed: a
        # quote or `(` that never closed, or an operator that never got
        # its right operand. Its code is whatever the scan could read,
        # which is not the statement -- so it is reported rather than
        # judged on a partial reading.
        _ebsf_rows+=("${_rel}:${_lbstart}: ${_lbtext}  -- this '!' statement is still unfinished where the body closes (an unterminated quote, '(' or list operator), so the scan cannot tell where it ends")
      elif [[ "${_lcont}" -eq 2 || "${_lcont}" -eq 3 ]]; then
        # Unreadable, but provably harmless to THIS rule: no line the
        # scan reads as OPENING a `!` statement went into it. A `!`
        # behind a backslash continues the command above it and is not
        # one; a `!` inside an allow region is one the operator has
        # already judged; the other two folds set a flag above and are
        # reported there. Stated in the header rather than reported, so
        # that a heredoc body or a multi-line string does not fail a gate
        # it has no bearing on.
        :
      elif [[ "${_lbang}" -eq 1 ]]; then
        # Order matters. The async operator is judged FIRST: a `&`
        # anywhere at top level discards the negation whatever else the
        # statement holds, so no `||` arm below it can speak for the
        # statement. Then an `|| true` is judged before the generic `||`
        # escape, so the one hand-off that IS inert is still reported.
        if [[ "${_lbcode}" =~ ${_ERREXIT_BANG_ASYNC_RE} ]]; then
          _ebsf_rows+=("${_rel}:${_lbstart}: ${_lbtext}  -- the '!' is handed to a background fork, whose status is 0 whatever the command did ('&')")
        elif [[ "${_lbcode}" =~ ${_ERREXIT_BANG_INERT_OR_RE} ]]; then
          # Inert in EVERY position, so it is judged here rather than
          # queued: waiting for the body to close would report it only
          # when it happened not to be last, which is the hole this
          # closes. It is deliberately not ALSO queued -- one statement,
          # one row.
          _ebsf_rows+=("${_rel}:${_lbstart}: ${_lbtext}  -- the '!' hands its status to an operand that cannot fail ('|| true' / '|| :')")
        elif [[ "${_lbcode}" =~ ${_ERREXIT_BANG_LIVE_OR_RE} \
             && ! "${_lbcode}" =~ ${_ERREXIT_BANG_BANG_OPERAND_RE} ]]; then
          # `! A || B` with an ORDINARY B that can fail. The verdict is
          # B's, and an ordinary B's failure is not exempt from errexit,
          # so this statement can fail its test from any position: out of
          # both rules, not merely out of this one.
          #
          # The second test is what keeps that true. An operand opening
          # with `!` IS exempt from errexit, so a list holding one aborts
          # nothing and is inert everywhere but the body's last statement
          # -- the position rule's case, reached by declining the
          # exemption here rather than by widening it. See the header for
          # why the whole class is declined, including the chains that
          # can still fail.
          :
        elif [[ "${_lbcode}" =~ ${_ERREXIT_BANG_SEQ_RE} ]]; then
          _ebsf_rows+=("${_rel}:${_lbstart}: ${_lbtext}  -- the '!' hands its status to another command in this statement (';')")
        else
          _pending_line+=("${_lbstart}")
          _pending_end+=("${_lend}")
          _pending_text+=("${_lbtext}")
        fi
      fi
      _lbuf=''
    fi

    if [[ "${_close}" -eq 1 ]]; then
      # The body is closed: every pending `!` whose statement did not END
      # on the body's last statement line was exempt from errexit and
      # could not have failed the test.
      for (( _i = 0; _i < ${#_pending_line[@]}; _i++ )); do
        if [[ "${_pending_end[_i]}" != "${_last_stmt}" ]]; then
          _ebsf_rows+=("${_rel}:${_pending_line[_i]}: ${_pending_text[_i]}")
        fi
      done
      _in_body=0
      _lbuf=''
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
      "${_violations} non-final / masked '!' statement(s), unclosed body/bodies or unbalanced allow marker(s) across the ${#_files[@]} *.bats file(s) in this repo. bash exempts a '!' pipeline from errexit, so such a line is an assertion ONLY as the last COMMAND of a test body's last statement -- anywhere else, and after a ';' or an '|| true' / '|| :' anywhere in that statement, or with an async '&' anywhere in it, the command runs, the negation is computed and the answer is discarded, and the test passes whatever the code did. Assert it with an explicit 'if <cmd>; then <message>; return 1; fi', with 'refute'/'refute_output', or move it to the end of the body. A line that genuinely cannot be written that way opts out by bracketing it with '# ${_ERREXIT_BANG_ALLOW_BEGIN} -- <why>' / '# ${_ERREXIT_BANG_ALLOW_END}'."
    return 1
  fi
  echo "non-final bang-statement lint: clean (${#_files[@]} spec file(s) under ${_roots[*]}, ${_headers} test bodies)"
}
