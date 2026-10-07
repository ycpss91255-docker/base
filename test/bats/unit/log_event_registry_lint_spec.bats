#!/usr/bin/env bats
#
# why: The guard over the direction the registry check never covered.
# lib/log.sh is STRICT -- it refuses a body log-events.txt does not carry
# and prints 'FATAL: unregistered log body' INSTEAD of the message -- so an
# unregistered id is not a missing label but the diagnostic being replaced
# by the registry's own complaint, at the moment something had already gone
# wrong. The tree asserted only the other direction, one site at a time: a
# driver's spec says the id ITS driver dies with is registered. That is a
# per-site habit and not a population, so four unregistered ids accumulated
# unseen (base#1220).
#
# Unit tests for script/test/drivers/log_event_registry.sh -- the "every
# event id a shipped script EMITS is registered" lint.
#
# Two properties drive the case list. FIRST, the emitted set is not just
# the direct '_log_<level> <service> <body>' sites: two of base#1220's four
# were emitted as the first argument of script/test/test.sh's one-line
# _die, which hands that argument to _log_err's body slot. A scan without
# that hop sees thirty-odd lint drivers emit nothing at all, so the
# forwarding wrapper is derived from the tree and the case list pins both
# the hop and its shadowing rule.
#
# SECOND, nothing here is a roster: the registry's own path is read out of
# the _LOG_EVENTS_FILE assignment in the scanned tree, and a resolution
# that points at no file is not a candidate. That existence rule is not a
# convenience -- this driver spells '_LOG_EVENTS_FILE=' in the pattern it
# matches with and is itself in the population, so the naive rule resolved
# to two registries on its first run.
#
# Detection runs against a controlled temp REPO_ROOT, never the live
# checkout: the tree is asserted by the 'lint-static' group that runs this
# driver, which is where a whole-tree scan belongs (base#1075).
#
# THIRD, the reader is a word splitter and not a regex over the raw line,
# and four cases were the reason to begin with. Two are MISSES -- a body wrapped onto a
# continuation line, and a body an operator terminates without a space --
# and two are FALSE FINDINGS: a call spelled out in a trailing comment,
# and a wrapper name inside a message. The false findings are the half
# that decides whether the gate survives, because an author told to
# register an id no shell will ever log is an author who mutes the lint,
# and this driver spells several such calls in its own header while
# sitting in the population it scans.
#
# The case list grew from there, one reproduced shape at a time, and what
# it adds up to is a small shell word splitter: quoting of all three
# kinds and its own context inside a substitution, redirections and their
# operands, command position carried rather than guessed, folds over
# continuations, open quotes, open substitutions and array initialisers.
# Nothing here is a general shell parser and it does not claim to be --
# where the reader cannot resolve a body it DECLINES, and where it cannot
# finish reading a file it REFUSES rather than reporting what it managed.


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
  source /source/script/test/drivers/log_event_registry.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
# Every line is written verbatim, so a '${1}' in one reaches the file
# unexpanded and the fixture reads the way the shipped source does.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# _seed <registered-id>... -- lay down the minimum tree every non-vacuity
# check wants: a library that says where the registry is, the registry
# itself carrying <registered-id>..., one direct call site, and one
# forwarding wrapper with one call site. Cases then add the file under
# test on top, so a failure names the shape the case is about rather than
# one of the seven refusals.
_seed() {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "# registry" "$@" "seed_ok" \
    > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  _write "dist/script/docker/wrapper/seed.sh" \
    '_log_info seed seed_ok "display=hello"'
  _write "script/test/seed_die.sh" \
    '_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }' \
    '_die seed_ok "boom"'
}

# ════════════════════════════════════════════════════════════════════
# _run_log_event_registry: violations
# ════════════════════════════════════════════════════════════════════

# why: The plain shape base#1220 found in setup_cmd.sh and toml_bridge.sh. The
# report has to name the file, the line and the id, because the author is
# looking for one argument among hundreds of call sites
@test "_run_log_event_registry: FAILS on a direct _log_ body the registry does not carry" {
  _seed
  _write "dist/script/docker/lib/setup_cmd.sh" \
    '  _log_err setup conf_write_failed "display=could not write"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/setup_cmd.sh:1: conf_write_failed"* ]]
}

# why: The load-bearing case. Two of base#1220's four were emitted as the first
# argument of test.sh's _die, not at a _log_ call site at all, so a scan
# that read only the direct sites would have reported the lint drivers
# clean while thirty-odd of them die with ids nothing checks
@test "_run_log_event_registry: FAILS on an id emitted through a forwarding wrapper" {
  _seed
  _write "script/test/drivers/bats.sh" \
    '    *) _die ci_invalid_jobs_policy \' \
    '         "BUG: unreadable jobs policy." ;;'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/test/drivers/bats.sh:1: ci_invalid_jobs_policy"* ]]
}

# why: Reporting the first offender and stopping makes the lint take as many
# runs to clear as the tree has emit sites; base#1220's own tree had
# thirteen sites over five ids, in four files
@test "_run_log_event_registry: reports EVERY offending site, not the first" {
  _seed
  _write "dist/script/docker/lib/a.sh" \
    '_log_err conf alpha_missing "display=a"' \
    '_log_warn conf beta_missing "display=b"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/a.sh:1: alpha_missing"* ]]
  [[ "${output}" == *"dist/script/docker/lib/a.sh:2: beta_missing"* ]]
}

# why: A body is a literal whether bash reads it through double quotes, single
# quotes or none, and lib/log.sh compares what the shell hands it -- so
# `_log_err ci 'missing' ...` is exactly as fatal as the double-quoted
# spelling. The first unquoting rule stripped only the double quote, which
# left the single-quoted token starting with a character no id starts
# with, so the shape was DISCARDED rather than reported and a tree holding
# it read clean. A reader of that clean line cannot tell a quoting style
# the scan does not see from a tree that has none of it
@test "_run_log_event_registry: FAILS on a single-quoted body the registry does not carry" {
  _seed
  _write "dist/script/docker/lib/q.sh" \
    "_log_err conf squote_missing \"display=a\"" \
    "_log_err conf 'squote_literal' \"display=b\""
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/q.sh:2: squote_literal"* ]]
}

# why: A wrapper call is a command, and a command sits wherever bash allows one
# -- after `then`, after `do`, after `&&`. The wrapper scan walked the line
# token pair by token pair and, on a pair whose first half was NOT a
# wrapper, skipped past BOTH halves; `then _die` therefore consumed the
# `_die` that followed it and the id after that was never looked at. The
# shipped tree hides the bug because its wrapper calls open their own
# lines, so only a fixture can hold the rule still: a non-wrapper match now
# advances past its own name alone, leaving the next token free to be read
# as the command it is
@test "_run_log_event_registry: FAILS on a wrapper call that is not the first word of its line" {
  _seed
  _write "dist/script/docker/lib/inline.sh" \
    'if true; then _die inline_missing "boom"; fi'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/inline.sh:1: inline_missing"* ]]
}

# why: bash reads a backslash-newline as nothing at all, so a call wrapped over
# two physical lines is one command and its body is as fatal as any other.
# A per-physical-line scan sees `_log_err conf \` -- service `\`, no body --
# and the real id on the line below with no call in front of it, so the
# site is skipped and the lint says clean. A reader cannot tell that from
# a tree with no such site, which is the vacuity this driver refuses
# everywhere else
@test "_run_log_event_registry: FAILS on a body on a continuation line" {
  _seed
  _write "dist/script/docker/lib/cont.sh" \
    '_log_err conf \' \
    '  continued_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/cont.sh:1: continued_missing"* ]]
}

# why: An argument ends where the shell says it does, and `;` `&&` `|` `)` end
# one without a space. Splitting the line on whitespace alone made
# `missing;` the body, which is not id-shaped, so the site was DISCARDED
# rather than reported -- a miss produced by the scan being coarser than
# the language it reads, and the shape every one-line `then ... ; fi`
# guard in this tree is written in
@test "_run_log_event_registry: FAILS on a body a shell operator terminates" {
  _seed
  _write "dist/script/docker/lib/op.sh" \
    '_log_err conf semi_missing; true' \
    '(_die amp_missing "boom") &'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/op.sh:1: semi_missing"* ]]
  [[ "${output}" == *"dist/script/docker/lib/op.sh:2: amp_missing"* ]]
}

# why: The over-reporting half, and the one that decides whether this lint
# survives. A `#` after code opens a comment exactly as one at column 0
# does, so prose that spells a call out to explain it emits nothing --
# and this driver, whose own header spells several, is in the population
# it scans. Only WHOLE-line comments were excluded, so a trailing one was
# read as code and the author was told to register an id no shell will
# ever log. A finding that is not a defect is what gets a gate muted
@test "_run_log_event_registry: PASSES a _log_ call in a trailing comment" {
  _seed
  _write "dist/script/docker/lib/trail.sh" \
    'true # _log_err conf trailing_prose "display=boom"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: The other over-report. A wrapper name inside a STRING is a word in a
# message, not a command -- `printf "use _die <id> for failures"` is help
# text -- and the scan read the token after it as an event id. The fix is
# the same one tokenising gives the case above: a quote that opens a word
# makes the whole quoted run ONE argument, so a name buried inside it is
# never at a command position and never consulted
@test "_run_log_event_registry: PASSES a wrapper name inside a quoted string" {
  _seed
  _write "dist/script/docker/lib/prose.sh" \
    'printf "%s\n" "use _die quoted_prose for failures"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: The command-position rule was applied to the wrapper half and not to the
# direct half, so `printf "%s\n" _log_err conf not_an_event` -- the logger
# name as an ARGUMENT, three words of text -- was read as a call and its
# third word reported. Being at a command position is what makes a word a
# call, and that is true of `_log_err` for exactly the reason it is true
# of `_die`; one rule applied to one half is a rule that disagrees with
# itself
@test "_run_log_event_registry: PASSES a logger name used as an argument" {
  _seed
  _write "dist/script/docker/lib/arg.sh" \
    'printf "%s\n" _log_err conf not_an_event'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `if`, `while` and `until` open a command exactly as `then` and `do` do,
# and a wrapper that dies inside a condition emits its id like any other
# call. They were missing from the keyword set, so `if _die id; then`
# recorded no wrapper call at all and the id went unchecked -- the miss
# shape, in the half where two of base#1220's four were hiding
@test "_run_log_event_registry: FAILS on a wrapper call opening a condition" {
  _seed
  _write "dist/script/docker/lib/cond.sh" \
    'if _die cond_missing "boom"; then :; fi' \
    'until _die until_missing "boom"; do :; done'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/cond.sh:1: cond_missing"* ]]
  [[ "${output}" == *"dist/script/docker/lib/cond.sh:2: until_missing"* ]]
}

# why: bash removes a backslash-newline and joins what sits on either side with
# NOTHING between them, so a word may be split across the fold and still
# be one word. The fold put a space there, which turns `split_` + `missing`
# into two words and hands the body slot a truncated id -- a scan that can
# both miss an unregistered id and report a registered one as missing,
# which is the worst of the two directions at once
@test "_run_log_event_registry: FAILS on a body split across a continuation" {
  _seed
  _write "dist/script/docker/lib/split.sh" \
    '_log_err conf split_\' \
    'missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/split.sh:1: split_missing"* ]]
}

# why: A keyword is a keyword only when the shell reads it as one, and a QUOTED
# `then` is an ordinary word. Deciding command position by looking back at
# the previous token and matching its TEXT lost that distinction, because
# the tokeniser has already removed the quotes -- so `printf "then"
# _log_err conf x` reported x. Position is now carried forward as the
# walk goes, and a word that opened with a quote can never be a keyword
@test "_run_log_event_registry: PASSES a quoted keyword in front of a logger name" {
  _seed
  _write "dist/script/docker/lib/kw.sh" \
    'printf "%s\n" "then" _log_err conf ordinary_text'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `VAR=value cmd ...` runs cmd, and the assignment in front of it does not
# stop being a command position. Reading only the previous token saw a
# word that was not a keyword and concluded the logger was an argument,
# so the call was skipped entirely -- an emit site the scan reports
# nothing about while the shell runs it
@test "_run_log_event_registry: FAILS on a call behind an assignment prefix" {
  _seed
  _write "dist/script/docker/lib/pfx.sh" \
    'LOG_FORMAT=text _log_err conf assign_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/pfx.sh:1: assign_missing"* ]]
}

# why: The wrapper-detection half read its definition line by splitting on
# whitespace, which is the coarseness the emit half had already stopped
# using. A one-line wrapper closing with `; }` left the semicolon attached
# to the body slot, so the definition read as NON-forwarding and every one
# of its call sites went unchecked -- silently, because the seed wrapper
# still exists and the empty-wrapper refusal therefore does not fire. Both
# halves read the tree the same way now
@test "_run_log_event_registry: FAILS on an id through a wrapper whose definition ends in '; }'" {
  _seed
  _write "dist/script/docker/lib/abort.sh" \
    '_abort() { _log_err ci "$1"; }' \
    '_abort abort_missing "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/abort.sh:2: abort_missing"* ]]
}

# why: A quote that opens on one line and closes on another holds ONE word
# across both, and help text spanning several lines is the ordinary way a
# shipped script spells its usage. Tokenising each physical line on its
# own lost the open quote at the line end, so an inner line reading like a
# call was read as one and its next word reported. The quote state is
# carried across the fold now -- the over-reporting direction again, which
# is the one that gets a gate muted
@test "_run_log_event_registry: PASSES a wrapper name inside a multi-line quoted string" {
  _seed
  _write "dist/script/docker/lib/ml.sh" \
    "printf '%s\\n' 'Usage:" \
    "  _die ml_prose on failure" \
    "done'"
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: bash does not continue a COMMENT over a backslash -- the comment ends at
# the newline and the next line is code. Folding on any trailing backslash
# glued the real call onto the comment, and the fold then began with a
# `#`, so the whole logical line was discarded and the emit site vanished.
# A miss produced by the fold itself, which is the one place a reader has
# no way to notice: the counts simply come out one lower
@test "_run_log_event_registry: FAILS on a call under a comment that ends in a backslash" {
  _seed
  _write "dist/script/docker/lib/cmt.sh" \
    '# an example: _log_err conf something \' \
    '_log_err conf after_comment_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/cmt.sh:2: after_comment_missing"* ]]
}

# why: Inside DOUBLE quotes bash removes a backslash-newline too, so a body may
# be split across one and still be a single literal id. The fold joined
# with a space there and kept the backslash, because the zero-character
# join was only reached when no quote was open -- so the body slot got a
# word no id matches and the site fell out silently. Two folding rules for
# one shell rule is one rule too many
@test "_run_log_event_registry: FAILS on a quoted body split across a continuation" {
  _seed
  _write "dist/script/docker/lib/qsplit.sh" \
    '_log_err conf "qsplit_\' \
    'missing" "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/qsplit.sh:1: qsplit_missing"* ]]
}

# why: A REDIRECTION is not a command separator, and its operand is a filename
# rather than a command. Treating `<` and `>` like `;` broke it both ways
# at once: a leading `>/dev/null` let the FILENAME take the command
# position so the logger behind it was never read, and a `> _die` made a
# filename look like a wrapper call and reported the next word. The
# operator and its operand are consumed together now, leaving the position
# where they found it
@test "_run_log_event_registry: reads a call behind a redirection and ignores a redirection target" {
  _seed
  _write "dist/script/docker/lib/redir.sh" \
    '>/dev/null _log_err conf redir_missing "display=boom"' \
    'printf "%s\n" > _die not_an_event'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/redir.sh:1: redir_missing"* ]]
  [[ "${output}" != *"not_an_event"* ]]
}

# why: A command substitution RUNS what is inside it, quoted or not. Unquoted
# the tokeniser already split on the parentheses and read the call; inside
# double quotes the whole substitution was absorbed into one word, so
# `x="$(_log_err conf id)"` emitted a literal id nothing checked. The body
# here is not the unresolvable kind this driver declines -- it is written
# out in the source -- so the scan descends into the substitution instead,
# while ordinary quoted message text stays one inert word
@test "_run_log_event_registry: FAILS on a body inside a quoted command substitution" {
  _seed
  _write "dist/script/docker/lib/subst.sh" \
    'result="$(_log_err conf subst_missing "display=boom")"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/subst.sh:1: subst_missing"* ]]
}

# why: What makes a substitution a substitution is the context it is written
# in. Inside SINGLE quotes it is four characters of text, and a backslash
# in front of it inside double quotes is the documented way to show one
# without running it -- both are how a shipped script spells its own help.
# Finding the span by searching the finished token could not tell either
# from the real thing, because the tokeniser had already removed the
# quoting that decides it. Eligibility is recorded while the quoting is
# still known, and nothing is re-derived from the text afterwards
@test "_run_log_event_registry: PASSES a substitution that is quoted into inertness" {
  _seed
  _write "dist/script/docker/lib/inert.sh" \
    "printf '%s' '\$(_log_err conf single_quoted_prose)'" \
    "printf '%s' \"\\\$(_log_err conf escaped_prose)\""
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `$'...'` is a THIRD quoting form, and the one place a backslash escapes
# an apostrophe. Reading it as an ordinary single-quoted run closed the
# string at the escaped apostrophe and let the real closing one OPEN a
# quote that never ends -- so every line after it in the file was folded
# into one word and every call in them disappeared. One such string in a
# file silently empties the rest of it, which is the worst miss this scan
# can have: the counts just come out lower and nothing says why
@test "_run_log_event_registry: FAILS on a call after an ANSI-C quoted string" {
  _seed
  _write "dist/script/docker/lib/ansi.sh" \
    "printf '%s' \$'it\\'s'" \
    '_log_err conf hidden_missing "display=test"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/ansi.sh:2: hidden_missing"* ]]
}

# why: `2>&1` is one redirection written in three tokens, and the `&` in the
# middle is not the `&` that backgrounds a command. Resetting the command
# position on it made the word after an ordinary output redirection look
# like a command, so `printf "%s" 2>&1 _die x` reported x. Descriptor
# duplication is consumed whole now, position untouched
@test "_run_log_event_registry: PASSES a word after a descriptor-duplicating redirection" {
  _seed
  _write "dist/script/docker/lib/dup.sh" \
    'printf "%s" 2>&1 _die not_an_event'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: bash removes a redirection BEFORE it hands a command its positional
# arguments, so `_log_err 2>/dev/null conf id` passes id in the body slot
# exactly as the unredirected spelling does. Reading the body as the
# token two along required the words to be adjacent, so the redirection
# pushed the body out of the slot and the site was counted but never
# checked. The arguments are resolved after the redirections now, for
# wrapper calls as well
@test "_run_log_event_registry: FAILS on a body behind a redirection in the argument list" {
  _seed
  _write "dist/script/docker/lib/redirarg.sh" \
    '_log_err 2>/dev/null conf redir_arg_missing "display=boom"' \
    '_die >/dev/null wrapper_arg_missing "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/redirarg.sh:1: redir_arg_missing"* ]]
  [[ "${output}" == *"dist/script/docker/lib/redirarg.sh:2: wrapper_arg_missing"* ]]
}

# why: A file descriptor prefix is part of the redirection it touches, and
# `2>` is one token because the two characters are ADJACENT. A number
# separated from the operator by a space is an ordinary argument -- so
# `_log_err conf 123 > /dev/null` passes 123 in the body slot -- and
# discarding it as a descriptor dropped a fully known unregistered body.
# The second line keeps the real prefix working, so the fix cannot be a
# retreat from reading them
@test "_run_log_event_registry: FAILS on a numeric body a space separates from a redirection" {
  _seed
  _write "dist/script/docker/lib/fd.sh" \
    '_log_err conf 123 > /dev/null' \
    '2>/dev/null _log_err conf adjacent_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/fd.sh:1: 123"* ]]
  [[ "${output}" == *"dist/script/docker/lib/fd.sh:2: adjacent_missing"* ]]
}

# why: lib/log.sh compares the body against the registry line for line and
# imposes no shape on it, so a body with a hyphen in it is refused at
# runtime like any other unregistered one -- and a hyphen where an
# underscore belongs is exactly the typo this lint should catch. Requiring
# the identifier shape before checking membership threw those away
# silently: the site was COUNTED, so the clean line said it had been read,
# and nothing had been asked about it. What the scan cannot resolve is a
# body carrying an expansion, and that is now the only thing it declines
@test "_run_log_event_registry: FAILS on a literal body that is not identifier-shaped" {
  _seed
  _write "dist/script/docker/lib/hyph.sh" \
    '_log_err conf missing-event "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/hyph.sh:1: missing-event"* ]]
}

# why: A newline is a command SEPARATOR, and a substitution written over
# several lines holds several commands. Folding it with a space between
# the lines merged them, so the second logger became an argument of the
# first and its body was never read -- a miss the clean line cannot show,
# because the first command was counted and looked fine
@test "_run_log_event_registry: FAILS on the second command of a multi-line substitution" {
  _seed seed_ok
  _write "dist/script/docker/lib/mlsub.sh" \
    'result="$(_log_info conf seed_ok' \
    '_log_err conf multiline_missing "display=boom")"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/mlsub.sh:1: multiline_missing"* ]]
}

# why: `name=( ... )` STORES words; it runs nothing. Treating every opening
# parenthesis as a command boundary made the first word inside an array
# initialiser a command and the next one its event id, so an ordinary
# array of arguments was reported. An initialiser is recognised by the
# assignment in front of its parenthesis and skipped to its match
@test "_run_log_event_registry: PASSES words stored in an array initialiser" {
  _seed
  _write "dist/script/docker/lib/arr.sh" \
    'args=(_log_err conf not_an_event)' \
    'more+=(_die also_not_an_event)'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `$'...'` decodes escapes, and dropping the backslash is not decoding
# them: `$'\x6f'` is the letter o, so stripping gave the word `x6f` and
# the lint reported an id no shell ever emits. The simple escapes are
# decoded; anything else -- `\x`, `\u`, an octal -- makes the body
# UNRESOLVED, which is the one thing this scan declines and says so about.
# Declining is the honest answer here: comparing a wrongly decoded literal
# against the registry reports a defect that is not one
@test "_run_log_event_registry: PASSES a body whose ANSI-C escape it cannot decode" {
  _seed
  _write "dist/script/docker/lib/esc.sh" \
    "_log_info conf \$'seed_\\x6fk' \"display=boom\""
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: An initialiser spread over several lines is still one initialiser. The
# fold closed the logical line at the first newline, so the skip lost its
# nesting and the next line was scanned as a command -- the array shape
# the case above pins, in the spelling every long argument list in this
# tree actually uses. A logical line is not complete while a parenthesis
# is open
@test "_run_log_event_registry: PASSES words stored in a multi-line array initialiser" {
  _seed
  _write "dist/script/docker/lib/marr.sh" \
    'args=(' \
    '  _log_err conf not_an_event' \
    ')'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: An unquoted substitution belongs to the WORD it sits in, and its closing
# parenthesis is not a command separator. Exposing it as one put the next
# argument of an ordinary command at a command position, so `printf "%s"
# $(printf text) _log_err conf x` reported x. The span is taken whole and
# scanned on its own now -- the same path the quoted spelling takes, which
# is what keeps the call INSIDE one findable while the word around it
# stays an argument
@test "_run_log_event_registry: reads inside an unquoted substitution without losing the word around it" {
  _seed
  _write "dist/script/docker/lib/usub.sh" \
    'result=$(_log_err conf unquoted_subst_missing "display=boom")' \
    'printf "%s" $(printf text) _log_err conf not_an_event'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/usub.sh:1: unquoted_subst_missing"* ]]
  [[ "${output}" != *"not_an_event"* ]]
}

# why: `<(...)` is a PROCESS substitution: it runs a command and hands the
# reader a path to its output. Reading the `<` as a plain redirection
# made the command inside it the filename operand, so it was skipped
# whole and its id never checked -- a miss, in the one construct whose
# whole point is that a command runs where a filename is expected
@test "_run_log_event_registry: FAILS on a body inside a process substitution" {
  _seed
  _write "dist/script/docker/lib/psub.sh" \
    'cat <(_log_err conf process_missing "display=boom")'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/psub.sh:1: process_missing"* ]]
}

# why: Quoting RESTARTS inside a substitution, so a double quote within one is
# not the close of the quote outside it. The span finder shared one quote
# state across the boundary, so an inner substitution opened while the
# outer one was quoted did not count as nesting -- and the first literal
# `)` in a display string then looked like the end of the whole thing,
# truncating the command before its body was ever read
@test "_run_log_event_registry: FAILS on a body in a nested quoted substitution" {
  _seed
  _write "dist/script/docker/lib/nest.sh" \
    'out="$(printf "%s" "$(_log_err conf nested_missing "display=oops)")")"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/nest.sh:1: nested_missing"* ]]
}

# why: A `case` PATTERN ends with a `)` that closes nothing, and inside a
# substitution that parenthesis looked like the substitution ending --
# so the arm after it, and everything else in the substitution, was
# never read. `case` arms are where a script decides what went wrong, so
# they are where its _log_ calls live
@test "_run_log_event_registry: FAILS on a body in a case arm inside a substitution" {
  _seed
  _write "dist/script/docker/lib/caseq.sh" \
    'printf "%s" "$(case x in x) _log_err conf case_arm_missing ;; esac)"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/caseq.sh:1: case_arm_missing"* ]]
}

# why: `case` is a keyword only where a command can stand. As an ARGUMENT it is
# the four letters, and opening a case frame for it left a frame nothing
# closes -- so the substitution around it never closed either and the
# eighth refusal fired on a valid file. The construct that keeps a
# pattern terminator from closing a substitution must not be able to stop
# one closing at all
@test "_run_log_event_registry: PASSES the word case used as an argument" {
  _seed
  _write "dist/script/docker/lib/casearg.sh" \
    'x=$(printf "%s" case)' \
    '_log_err conf seed_ok "display=ok"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: An alias is only the first argument until something else is assigned to
# it. A body that takes `${1}` into a local and then OVERWRITES it logs a
# fixed id and forwards nothing, so declaring it a wrapper turned every
# ordinary call of the function into a reported id. The alias set is
# built in order and a reassignment removes the name: where the reader
# cannot be sure, it declines the wrapper rather than inventing call
# sites for it
@test "_run_log_event_registry: PASSES a function that overwrites its positional alias" {
  _seed seed_ok
  _write "dist/script/docker/lib/reassign.sh" \
    'fixed() { local _ev="${1}"; _ev=seed_ok; _log_err ci "${_ev}"; }' \
    'fixed ordinary_message'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: A comment ends at the NEXT NEWLINE, and a logical line now holds several
# of them -- a substitution written over several lines is one logical
# line. Ending the whole read at the first `#` therefore discarded every
# command after a comment inside one, not just the rest of that line
@test "_run_log_event_registry: FAILS on a call after a comment inside a substitution" {
  _seed
  _write "dist/script/docker/lib/csub.sh" \
    'value="$(printf hello # an aside' \
    '_log_err conf after_comment_in_subst "display=boom")"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/csub.sh:1: after_comment_in_subst"* ]]
}

# why: Backticks are the older spelling of a command substitution and they run
# the same command. Only the `$( )` form was descended into, so the
# backtick one emitted a literal id nothing checked. Inside SINGLE quotes
# a backtick is text, which the second line pins: the span is only taken
# where the shell would run it
@test "_run_log_event_registry: FAILS on a body inside a backtick substitution" {
  _seed
  _write "dist/script/docker/lib/btick.sh" \
    'value=`_log_err conf backtick_missing "display=boom"`' \
    "printf '%s' '\`_log_err conf backtick_prose\`'"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/btick.sh:1: backtick_missing"* ]]
  [[ "${output}" != *"backtick_prose"* ]]
}

# why: An UNQUOTED substitution spread over several lines is one substitution,
# and the fold knew only about quotes. Each line finished on its own, so
# the closing parenthesis arrived as a bare operator and restored the
# command position -- making the next argument of an ordinary command
# look like a command. Substitution nesting is carried across the fold
# now, and only that nesting: counting EVERY parenthesis was tried
# against the real tree and folded whole files, a glob or a heredoc body
# holding one that never closes
@test "_run_log_event_registry: PASSES an argument after a multi-line unquoted substitution" {
  _seed
  _write "dist/script/docker/lib/mlusub.sh" \
    'printf "%s" $(' \
    '  printf text' \
    ') _log_err conf not_an_event'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: A parenthesis inside a COMMENT closes nothing. The span finder counted
# it, so a substitution holding a commented `)` ended early and every
# command after it fell back into the quoted word around it and vanished
# -- the id is gone from the population and the clean line still counts
# the call before it, so nothing looks wrong
@test "_run_log_event_registry: FAILS past a commented parenthesis inside a substitution" {
  _seed seed_ok
  _write "dist/script/docker/lib/cparen.sh" \
    'value="$(_log_err conf seed_ok # )' \
    '_log_err conf comment_paren_missing "display=boom"' \
    ')"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/cparen.sh:1: comment_paren_missing"* ]]
}

# why: Inside double quotes bash escapes only five characters, and a backslash
# in front of anything else is KEPT. Removing it everywhere normalised a
# body into one the registry carries, so a call that is fatal at runtime
# read as registered -- the one direction a registry gate must never get
# wrong, because it reports the tree clean on the exact call it exists to
# catch
@test "_run_log_event_registry: FAILS on a body whose backslash bash would keep" {
  _seed seed_ok
  _write "dist/script/docker/lib/bslash.sh" \
    '_log_err conf "seed\_ok" "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'bslash.sh:1: seed\_ok'* ]]
}

# why: `function name { ... }` is a function definition with no parentheses in
# it, and the definition pattern required them. A wrapper written that
# way was never discovered, so its call sites went unchecked -- and
# silently, because another wrapper exists and the empty-wrapper refusal
# therefore does not fire. The same omission would stop such a definition
# SHADOWING a name, which is the half that prevents false findings
@test "_run_log_event_registry: FAILS on an id through a parenthesis-free function definition" {
  _seed
  _write "dist/script/docker/lib/fkw.sh" \
    'function fail { _log_err ci "$1"; exit 1; }' \
    'fail func_kw_missing "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/fkw.sh:2: func_kw_missing"* ]]
}

# why: The same spelling read from the other side. `function name {` puts the
# NAME where a command would stand, so a wrapper defining itself that way
# had its own definition read as a call of itself and the brace after it
# reported as an event id -- while the logger inside the definition went
# unread. The case above only exercises a failing invocation and cannot
# see this; the prologue is consumed before the body is scanned
@test "_run_log_event_registry: PASSES the definition line of a parenthesis-free wrapper" {
  _seed
  _write "dist/script/docker/lib/fkw2.sh" \
    'function warn { _log_err ci "$1"; exit 1; }' \
    'warn seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `(( ... ))` is the arithmetic COMMAND form, and its contents are an
# expression: it reads variables and runs nothing. Every opening
# parenthesis restored the command position, so a variable sharing a
# name with a wrapper made the operator after it an event id. The
# expansion form `$((...))` was already handled; this is the half that
# was not, and it is carried across lines like the conditional
@test "_run_log_event_registry: PASSES an arithmetic command naming a wrapper" {
  _seed
  _write "dist/script/docker/lib/arith2.sh" \
    '(( _die == 1 )) || true' \
    '(( _die == 2 &&' \
    '   _die == 3 )) || true'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: A backtick substitution can span lines like any other, and the fold
# tracked quotes and `$(` but not backticks -- so each physical line
# reached the span finder incomplete, no span was found, and the call
# inside left the population
@test "_run_log_event_registry: FAILS on a body in a multi-line backtick substitution" {
  _seed
  _write "dist/script/docker/lib/btml.sh" \
    'value=`_log_err conf btick_ml_missing "display=boom"' \
    '`'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/btml.sh:1: btick_ml_missing"* ]]
}

# why: The lint mirrors lib/log.sh, and log.sh does not check an EMPTY body:
# _log_dispatch guards its registry test with `[[ -n "${body}" ]]`, so
# such a call prints its diagnostic and returns zero. This case was
# asserted the other way round first, on the reasoning that an empty
# body is fully known and therefore checkable -- which is true, and
# beside the point: the gate exists because an unregistered body
# REPLACES the message, and this one does not. Reading the runtime is
# what settles it, and base#1220 bounds this work against changing it
@test "_run_log_event_registry: PASSES an empty body, as the logger does" {
  _seed
  _write "dist/script/docker/lib/empty.sh" \
    '_log_err conf "" "display=oops"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `command`, `builtin` and `exec` BYPASS shell functions -- that is what
# they are for -- so none of them can invoke `_log_err`, which is one.
# Reading them as transparent openers made the name behind them a
# logger call and reported an id no shell ever logs
@test "_run_log_event_registry: PASSES a logger name behind a function-bypassing prefix" {
  _seed
  _write "dist/script/docker/lib/bypass.sh" \
    'command _log_err conf not_a_function_call' \
    'builtin _log_err conf also_not_one'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: Quoting that starts PART WAY THROUGH a word still quotes the word.
# `12""` is the argument `12`, not a file descriptor, so bash passes it
# in the body slot and log.sh refuses it -- but the record said quoted
# only when a word OPENED with a quote, so the descriptor rule took it
# and threw a fatal call away. What is recorded now is where the first
# quote fell, which the assignment-prefix rule needs too: the name in
# front of the `=` must be unquoted, the value need not be
@test "_run_log_event_registry: FAILS on a numeric body quoted part way through" {
  _seed
  _write "dist/script/docker/lib/pq.sh" \
    '_log_err conf 12"">/dev/null' \
    'LOG_FORMAT="text" _log_err conf prefix_still_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/pq.sh:1: 12"* ]]
  [[ "${output}" == *"dist/script/docker/lib/pq.sh:2: prefix_still_missing"* ]]
}

# why: The scan hands its findings to the shell as tab-separated records, and a
# body can CONTAIN a tab -- `$'\tseed_ok'` decodes to one. Written
# verbatim it split the record, so the reader took the registered
# `seed_ok` as the body and called the tree clean on a call log.sh
# refuses. The id is encoded on the way out and decoded for the
# membership test; the report shows the encoded form so a finding stays
# one readable line
@test "_run_log_event_registry: FAILS on a literal body carrying a tab" {
  _seed seed_ok
  _write "dist/script/docker/lib/tab.sh" \
    "_log_err conf \$'\\tseed_ok' \"display=boom\""
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/tab.sh:1: %09seed_ok"* ]]
}

# why: QUOTING INSIDE A SUBSTITUTION IS ITS OWN. The fold kept one quote state
# across the boundary, so a double quote inside a its own
# single-quoted argument closed the quote OUTSIDE it -- and the fold then
# never closed, so every line after it stayed in a buffer that is thrown
# away at the next file. The rest of the file leaves the population with
# nothing said about it, which is the silent shrink this driver refuses
# everywhere else
@test "_run_log_event_registry: FAILS after a substitution holding a quote of its own" {
  _seed
  _write "dist/script/docker/lib/subq.sh" \
    "value=\"\$(printf '%s' '\"')\"" \
    '_log_err conf after_subst_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/subq.sh:2: after_subst_missing"* ]]
}

# why: And when the fold does not close, the lint must SAY SO. A buffer still
# open at the end of a file is the rest of that file leaving the
# population, and the run before this one proved it goes unnoticed: the
# other files satisfy every non-vacuity check and the clean line reads
# normally. A reader cannot tell a tree with less in it from a scan that
# stopped reading, so this is refused rather than counted
@test "_run_log_event_registry: DIES when a file ends with a logical line still open" {
  _seed
  _write "dist/script/docker/lib/open.sh" \
    '_log_err conf seed_ok "display=boom"' \
    'value="never closed'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/open.sh"* ]]
  [[ "${output}" == *"ends with a logical line still open"* ]]
}

# why: A dollar sign is not an expansion when the shell never treats it as one.
# `'"'"'missing$'"'"'` and `"missing\$"` are fully known literals, and the test
# for an unresolved body ran on the text AFTER the quoting was removed,
# where the two are indistinguishable -- so both were dropped. Whether an
# expansion actually occurred is recorded while it can still be seen
@test "_run_log_event_registry: FAILS on a literal body ending in a dollar sign" {
  _seed
  _write "dist/script/docker/lib/dollar.sh" \
    "_log_err conf 'quoted_dollar\$' \"display=boom\"" \
    '_log_err conf "escaped_dollar\$" "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'dollar.sh:1: quoted_dollar$'* ]]
  [[ "${output}" == *'dollar.sh:2: escaped_dollar$'* ]]
}

# why: A dollar sign only starts an expansion when what follows it introduces
# one. Marking EVERY one as an expansion declined a trailing dollar --
# `"missing$"`, and the unquoted spelling -- which bash keeps literally
# and log.sh then refuses. The wrong direction twice over: the body is
# fully known AND unregistered, and the lint said nothing
@test "_run_log_event_registry: FAILS on a literal body whose dollar starts nothing" {
  _seed
  _write "dist/script/docker/lib/trail.sh" \
    '_log_err conf "trailing_dollar$" "display=boom"' \
    '_log_err conf bare_dollar$ "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'trail.sh:1: trailing_dollar$'* ]]
  [[ "${output}" == *'trail.sh:2: bare_dollar$'* ]]
}

# why: Inside `[[ ... ]]` the operators are the CONDITIONAL grammar, not the
# command grammar: `&&` there joins two tests and opens no command
# position. Treating it as one made the word after it a command, so an
# ordinary string comparison naming a wrapper reported its right-hand
# side as an event id. A substitution inside the expression still runs,
# and is still descended into
@test "_run_log_event_registry: PASSES a wrapper name compared inside a conditional" {
  _seed
  _write "dist/script/docker/lib/cond2.sh" \
    '[[ foo == foo && _die == not_an_event ]] || true'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: A conditional spread over several lines is still one conditional, and
# the state saying so was local to a line. Worse, the line that OPENS it
# may hold no name the candidate filter looks for, so the opening `[[`
# was not even read. The state is carried from line to line, and a line
# inside a conditional is scanned whether or not it looks interesting
@test "_run_log_event_registry: PASSES a wrapper name compared inside a multi-line conditional" {
  _seed
  _write "dist/script/docker/lib/cond3.sh" \
    '[[ foo == foo &&' \
    '   _die == not_an_event ]] || true'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: A SINGLE-QUOTED `${1}` is the five characters, not the first argument,
# so a function whose body logs it emits one FIXED id and forwards
# nothing. Comparing the unquoted text alone could not tell that from the
# real thing, so the function was declared a wrapper and every ordinary
# call of it had its first argument reported. A wrongly declared wrapper
# is the noise that gets a lint muted -- the shadowing rule exists for
# exactly this -- so forwarding now requires a REAL positional expansion,
# for the alias as well as for the body slot
@test "_run_log_event_registry: PASSES a function whose body only looks like a forward" {
  _seed '${1}'
  _write "dist/script/docker/lib/fixed.sh" \
    "fixed() { _log_err ci '\${1}'; }" \
    'fixed ordinary_message'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: `[[` opens a conditional only where the shell reads it as one: unquoted,
# at a command position. A QUOTED one is an argument, and treating it as
# the opener put the conditional state on and left it on -- suppressing
# every call for the rest of the file, with the clean line reading
# normally. The state that fixes a false finding must not be able to
# create a silent miss
@test "_run_log_event_registry: FAILS after a quoted conditional delimiter" {
  _seed
  _write "dist/script/docker/lib/qbrack.sh" \
    "printf '%s' '[['" \
    '_log_err conf after_literal_bracket "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/qbrack.sh:2: after_literal_bracket"* ]]
}

# why: `$((...))` is ARITHMETIC: it reads variables and runs no command. The
# substitution branch took it for `$( ... )` and scanned its expression
# as shell, so a variable sharing a name with a wrapper made the operator
# after it an event id. Arithmetic is an expansion like any other -- the
# body carrying it is declined -- but nothing inside it is a call
@test "_run_log_event_registry: PASSES an arithmetic expansion naming a wrapper" {
  _seed
  _write "dist/script/docker/lib/arith.sh" \
    'n=$((_die + 1))' \
    'printf "%s" "$((_die + 2))"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: Arithmetic reads variables and runs nothing -- except that a command
# SUBSTITUTION written inside it does run. Declining the whole expansion
# to keep its identifiers inert threw the nested call away with it, so a
# literal unregistered body inside one went unseen. The identifiers stay
# inert; the substitutions in among them are harvested and scanned
@test "_run_log_event_registry: FAILS on a body in a substitution inside arithmetic" {
  _seed
  _write "dist/script/docker/lib/arith3.sh" \
    'n=$(( $(_log_err conf arith_subst_missing "display=boom") + 1 ))'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/arith3.sh:1: arith_subst_missing"* ]]
}

# why: `>|` is ONE redirection operator -- the noclobber override -- and
# splitting it left a bare pipe, which ends the command. The body after
# it was never looked at, so a literal unregistered id passed. A pipe
# that is half of a redirection is not a pipeline
@test "_run_log_event_registry: FAILS on a body behind a noclobber redirection" {
  _seed
  _write "dist/script/docker/lib/noclob.sh" \
    '_log_err >| /tmp/log conf noclobber_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/noclob.sh:1: noclobber_missing"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_log_event_registry: what it leaves alone
# ════════════════════════════════════════════════════════════════════

# why: The boundary of the rule and the whole of the fix base#1220 took: an id
# the registry carries is a message the operator actually reads, so there
# is nothing to report
@test "_run_log_event_registry: PASSES an id the registry carries" {
  _seed conf_write_failed
  _write "dist/script/docker/lib/setup_cmd.sh" \
    '  _log_err setup conf_write_failed "display=could not write"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: A name is not global. script/ci/reclaim.sh defines its own _die that
# prints to stderr and never logs, so 'not a duration: 5x' is a MESSAGE,
# not an event id. Without the shadowing rule every such argument would be
# reported unregistered, which is the false finding that gets a lint muted
@test "_run_log_event_registry: PASSES a same-named function a file defines without forwarding" {
  _seed
  _write "script/ci/reclaim.sh" \
    '_die() { printf "[reclaim] ERROR: %s\n" "$*" >&2; exit 2; }' \
    '_die not_a_duration "bad input"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: The stated blind spot, pinned so it cannot change shape unnoticed. A
# body this driver would have to run a shell to know is not resolved:
# exactly one hop -- the forwarding wrapper -- is, and anything further is
# out of reach rather than quietly guessed at
@test "_run_log_event_registry: PASSES a body that is not a literal" {
  _seed
  _write "dist/script/docker/lib/b.sh" \
    '_log_err conf "${_ev}" "display=indirect"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: Half the prose in these drivers spells a _log_ call out to explain one,
# and this driver's own header names four unregistered ids verbatim. A scan
# that read commented-out code would report its own documentation
@test "_run_log_event_registry: PASSES a _log_ call inside a whole-line comment" {
  _seed
  _write "dist/script/docker/lib/c.sh" \
    '# _log_err setup conf_write_failed "display=what the old code did"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: The registry's path is read out of the tree's own _LOG_EVENTS_FILE
# assignment rather than written down in the driver, so moving or renaming
# the registry moves this lint with it instead of emptying it. A literal
# path here would keep agreeing with itself after lib/log.sh stopped
@test "_run_log_event_registry: reads the registry the tree names, not a path of its own" {
  _write "dist/script/docker/lib/elsewhere/logging.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/events.list"'
  printf '%s\n' "seed_ok" "renamed_ok" \
    > "${SCRATCH}/dist/script/docker/lib/elsewhere/events.list"
  _write "dist/script/docker/wrapper/seed.sh" \
    '_log_info seed renamed_ok "display=hello"'
  _write "script/test/seed_die.sh" \
    '_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }' \
    '_die seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dist/script/docker/lib/elsewhere/events.list"* ]] \
    || [[ "${output}" == *"2 id(s) registered"* ]]
}

# why: The lint phase runs its drivers under `set -o pipefail`, and the first
# spelling of the membership test was `printf '%s\n' "${registered[@]}" |
# grep -Fxq`. grep -q exits on the match, printf takes SIGPIPE, pipefail
# promotes that 141 over grep's 0, and a SUCCESSFUL lookup reads as "not
# registered" -- host-direct, with no pipefail, the same scan called the tree
# clean while the lint phase reported 29 registered ids as findings. The ids
# here are seeded so a match lands before the last line, which is what makes
# the early close happen at all
@test "_run_log_event_registry: a registered id stays registered under pipefail" {
  _seed early_hit middle_hit late_hit
  _write "dist/script/docker/lib/d.sh" \
    '_log_err conf early_hit "display=a"' \
    '_log_warn conf middle_hit "display=b"'
  set -o pipefail
  run _run_log_event_registry
  set +o pipefail
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: The clean line is the audit trail: it says how many emit sites were read,
# how many came through a wrapper and how many ids the registry carries, so
# a reader of a green CI log can tell a scan that checked the tree from one
# that checked nothing
@test "_run_log_event_registry: a clean tree passes and the counts print" {
  _seed
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
  [[ "${output}" == *"through a wrapper"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_log_event_registry: the refusals
#
# Seven ways this lint could report a clean tree having checked nothing.
# Each case asserts the sentence only ITS refusal prints: several of them
# end in the same words, so a case that asserted the shared phrase would
# pass with the guard it names deleted.
# ════════════════════════════════════════════════════════════════════

# why: A walk that died part way through hands the lint a short list, which
# reads exactly like a tree with less in it. Captured rather than piped,
# because a status read through `| sort` belongs to sort
@test "_run_log_event_registry: DIES when the walk for *.sh fails" {
  _seed
  mktemp() { return 1; }
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not finish"* ]]
}

# why: An empty population is the shape that goes green by construction: the
# shipped scripts moved, the lint reads nothing and reports that every id
# is registered
@test "_run_log_event_registry: DIES when the tree holds no *.sh at all" {
  mkdir -p "${SCRATCH}/dist" "${SCRATCH}/script"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a scan with no population is not a pass"* ]]
}

# why: Without the assignment the registry's location is unknown, and an
# unknown allowed set accepts everything. It is also the existence half of
# the rule: this driver spells the assignment in its own matching pattern,
# so a resolution that points at no file has to be no candidate
@test "_run_log_event_registry: DIES when nothing names a registry that exists" {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  _write "script/test/seed_die.sh" \
    '_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }' \
    '_die seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"to a path that exists"* ]]
}

# why: Two registries is not two allowed sets to union: picking either would
# make the other's ids look unregistered, so the lint would report findings
# that are not defects and hide the ones that are
@test "_run_log_event_registry: DIES when two different registries are implied" {
  _seed
  _write "script/test/other_log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "seed_ok" > "${SCRATCH}/script/test/log-events.txt"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"different registry files are implied"* ]]
}

# why: An empty registry makes EVERY emitted id unregistered at runtime, so
# reading it as the allowed set is reading nothing. A comment-only file is
# the shape that matters: the header is still there, so the file looks
# populated to anything that only checks its size
@test "_run_log_event_registry: DIES when the registry carries no id" {
  _seed
  printf '%s\n' "# log-events.txt" "#" \
    > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"carries no event id"* ]]
}

# why: The blind-detector case, and the one that matters most: 271 direct call
# sites exist today, so zero means the detector stopped matching -- a
# renamed helper, a changed argument order -- and a blind detector reports
# every id registered
@test "_run_log_event_registry: DIES when no _log_ call site is read anywhere" {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "seed_ok" > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  _write "script/test/plain.sh" \
    '_emit() { local _ev="${1}"; shift; _report ci "${_ev}"; }' \
    '_emit seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"the detector read nothing"* ]]
}

# why: The wrapper half is where two of base#1220's four hid, and it is the
# half that can vanish silently: with no forwarding wrapper found the scan
# shrinks to the direct call sites and the thirty-odd lint drivers' events
# leave the population without anything saying so
@test "_run_log_event_registry: DIES when nothing forwards its first argument into a body slot" {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "seed_ok" > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  _write "dist/script/docker/wrapper/seed.sh" \
    '_log_info seed seed_ok "display=hello"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"forwards its first argument"* ]]
}
