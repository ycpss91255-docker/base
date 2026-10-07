#!/usr/bin/env bash
# drivers/log_event_registry.sh - "every event id a shipped script EMITS is
# in the registry" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_log_event_registry.
#
# Contract: runs wherever test.sh dispatches it -- inside the ci
# (test-tools) container for `just test lint --log-event-registry`, or
# host-direct for `--log-event-registry-only`. References ${REPO_ROOT} (a
# global exported by test.sh).
# Follows drivers/test_name_backtick.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# ── NOT IN _LINT_TOOLS, AND THIS IS WHY ─────────────────────────────────────
#
# This lint gates nothing. `--lint` does not run it and no CI job does.
# It is dispatchable and nothing more:
#
#   ./script/test/test.sh --log-event-registry-only   (host-direct, 0.5s)
#   just test lint --log-event-registry               (in-container)
#
# It is NOT in _LINT_TOOLS because of its READER, not its rule. The rule is
# finished and it works: it found all four ids base#1220 was filed for,
# including one the issue did not name, and two of those were emitted
# through a forwarding wrapper that nothing else in this tree can see.
#
# The reader is the problem. Its first spelling was a regex over the raw
# line. It is now a hand-written shell word splitter -- all three quoting
# forms with their own context inside a substitution, command position
# carried rather than inferred, redirections resolved before the
# arguments, folds over continuations and open constructs, the expression
# grammars held inert, positional state tracked through shift / set /
# unset -- and getting there took FORTY-ONE CONSECUTIVE review rounds and
# roughly ninety reproduced defects.
#
# THE CURVE NEVER FLATTENED, and that is the finding. Round thirty-four
# came back clean, the lint was taken out of _LINT_TOOLS on the strength
# of the argument below, and the SEVEN rounds after that found sixteen
# more -- the last of them four, more than any round in the twenties. A
# clean round is not evidence of a finished reader; it is evidence about
# the shapes that round happened to try.
#
# TWENTY-FIVE of those were FALSE POSITIVES on valid shell: array
# initialisers single- and multi-line, `(( ))` / `for (( ))` headers and
# their nesting across lines, `function name { }` definitions and ones
# whose brace is on the next line, `time -p`, named-descriptor
# redirections `{fd}>`, a quoted `[[`, `case` used as an argument, brace
# expansions, unquoted globs and tildes, parameter-expansion replacement
# text, locale-translated quoting, assignment-shaped arguments to ordinary
# commands, assignment PREFIXES read as persistent aliases (with and
# without a redirection between), `set -e` and `set -e --` read alike,
# `unset` ignored, a service argument that expands, and a substitution
# judged without the positional state in force where it runs.
#
# IN THE TABLE, EVERY ONE OF THOSE WOULD HAVE BLOCKED A PR whose logging
# was entirely correct, and the author's only recourse would have been to
# read fourteen hundred lines of awk to tell a parser bug from a real
# finding. A gate that does that once gets muted. A muted gate is worse
# than no gate, because it still carries the claim that the question is
# being asked.
#
# The reverse direction is cheap by comparison. A missed id stays
# unregistered until someone runs the scan -- which is precisely the state
# base#1220 describes, and a manual run closes it. The two errors are not
# symmetric, so the gate is not armed.
#
# ONE MEASUREMENT IS THE WHOLE ARGUMENT, and it is kept here because it
# was nearly shipped. Folding the logical line while ANY parenthesis stood
# open looks like the clean general version of the array-initialiser rule.
# Against the real tree it folded init.sh 827 LINES INTO ONE, because a
# `(` in a heredoc body or a glob never closes, and the scan lost 16 real
# emit sites -- 432 ids down to 416 -- WHILE STILL PRINTING A CLEAN LINE.
# It was caught only because those counts were being watched by hand. In
# CI nobody watches them. Parentheses are now counted only inside a
# substitution, and the measurement stays so the next reader does not try
# the general version again.
#
# THE KNOWN IMPRECISE SET WAS base#1228, and its three are now FIXED: a
# substitution judged with the definition END state instead of the state
# where it runs, forwarding discovery reading past the function closing
# brace, and a command name split by quoting (`_log_""err`) lost in the
# raw-text candidate filter. Each has its case in the spec. The HALF of
# the third that is not fixed is a bound rather than a defect and is
# named in the reach list below: a WRAPPER name split by quoting stays
# out of reach, because a wrapper name has no invariant prefix for the
# raw-text filter to fall back on the way `_log_` is for the direct half.
#
# THREE FIXES ARE NOT A FINISHED READER. That set was the shapes the
# review rounds happened to try, and the curve never flattened -- so
# fixing a named set changes nothing about the condition below, which is
# the only thing that promotes this lint.
#
# PROMOTION HAS ONE CONDITION: a release cycle clean against a moving
# tree. NOT a clean review round -- round thirty-four was clean and seven
# more rounds found sixteen defects after it. Then add the name to
# _LINT_TOOLS and delete its entry from _UNTABLED_LINT_ENTRY_POINTS in
# test/bats/unit/ci_spec.bats -- base#1113's hygiene guard refuses a name
# that is in both, so the two moves cannot come apart. Do not promote it
# on the strength of this file reading finished. It read finished at round
# four, and at round thirty-four.
#
# ── The asymmetry this closes ───────────────────────────────────────────────
#
# _log_* is STRICT: lib/log.sh refuses a body that log-events.txt does not
# carry and prints `FATAL: unregistered log body "<id>"` in place of the
# message. So an unregistered id is not a missing label, it is the message
# the operator was supposed to read being replaced by the registry's own
# refusal, at exactly the moment something went wrong.
#
# The tree already asserted the OTHER direction, one site at a time: a
# driver's spec asserts that the id ITS driver dies with is registered
# (action_ref_agreement, spec_repo_root, and others say so by name). That
# is a per-site habit, not a population, so it answers "is this id
# registered?" and never "is every id registered?". base#1220 found four
# that nothing asked about -- conf_write_failed on two branches of
# setup_cmd.sh, ci_invalid_jobs_policy and ci_no_fragile_files in
# drivers/bats.sh, and no_such_file in lib/toml_bridge.sh. Three of them
# predate the habit; all four were reachable and fatal.
#
# ── Both sides are derived; there is no roster and no exemption list ────────
#
# A hand-written list of "the ids we know about" is the declared-population
# smell base#1089, base#1090 and base#1113 each spent a PR removing: it is
# correct the day it is written and wrong the day the next emit site lands,
# with the gate still green. Nothing here is enumerated:
#
#   - the FILES are every *.sh under the shipped roots below, walked.
#   - the REGISTRY is found by reading the tree: the one file in that
#     population that assigns `_LOG_EVENTS_FILE=`, resolved against its own
#     directory. The path is never spelled here, so moving lib/log.sh moves
#     this lint with it instead of emptying it.
#   - the REGISTERED ids are that file's non-comment, non-blank lines, read
#     the way _log_is_registered reads them (`grep -Fxq`, so a whole line).
#   - the EMITTED ids are the literal body argument of every `_log_*
#     <service> <body>` call site, plus the first argument of every call to
#     a FORWARDING WRAPPER.
#   - a FORWARDING WRAPPER is itself derived, not named: a function whose
#     definition passes its own first positional into the body slot of a
#     `_log_*` call. That is what script/test/test.sh's `_die` does, and
#     resolving it is what makes the thirty-odd lint drivers' `_die
#     ci_<something>` call sites visible to this scan at all -- two of
#     base#1220's four hid in exactly that shape.
#
# A NAME IS NOT GLOBAL. Two other files define their own `_die` -- one
# prints to stderr and never logs, the other logs a FIXED id and puts its
# argument in the display attribute -- so a file that defines a wrapper
# name itself, non-forwardingly, shadows it for its own call sites. Without
# that, `_die "not a duration: ${_d}"` in script/ci/reclaim.sh would be
# read as an event id and reported as unregistered, which is the kind of
# false finding that gets a lint muted.
#
# There is no exemption list, deliberately. base#1113 had to add a hygiene
# guard over one, because an exemption outlives the reason it was granted
# and then excuses the next arrival. The question this lint asks has a
# right answer in every case -- register the id -- so there is nothing an
# exemption would be for.
#
# ── Scope, and what it does NOT see ─────────────────────────────────────────
#
# The population is *.sh under dist/ and script/: the shipped wrapper and
# library tree that a consumer runs, and the repo's own CI and test
# scripts. Both emit through the same strict _log_*. test/bats/** is NOT
# scanned -- a spec writes deliberately unregistered ids as fixtures (the
# `unregistered body causes fatal exit` case in log_spec.bats is exactly
# that), so scanning it would report the lint's own evidence as a defect.
#
# Six shapes are out of the scan's reach, named rather than implied,
# with the direction each errs in:
#
#   1. A body that is not a literal -- `_log_err conf "${_ev}"` at a site
#      whose value this driver would have to run a shell to know. Only the
#      forwarding-wrapper hop above is resolved; anything further is not.
#   2. An id emitted from a *.bats file, a justfile recipe or a workflow
#      step rather than from a *.sh.
#   3. The OTHER direction: a registered id that nothing emits any more.
#      That is a different finding (dead registry entry, not a broken
#      message) with a different fix, and it is out of base#1220's bound.
#   4. A forwarding wrapper whose definition spans more than one line.
#      Only the definition LINE is read. The tree's one wrapper is a
#      one-liner, and reading a whole multi-line body instead is what
#      makes the rule unsafe rather than wider: over a long function
#      "some _log_* call, and some local assigned from ${1}" is a
#      coincidence, not a forwarding contract, and a wrongly declared
#      wrapper turns every ordinary call of that function into a reported
#      id -- the noise that gets a lint muted. The empty-wrapper refusal
#      below is what keeps this bound visible: if the one-liner shape ever
#      goes away, the lint says so instead of shrinking quietly.
#
#   5. A HEREDOC body. The reader knows shell words, not shell
#      redirection, so a line of heredoc text that happens to read like a
#      call is read as one. That OVER-reports, which is the refusing
#      direction -- and it is the direction worth naming, because a
#      finding that is not a defect is what gets a gate muted. The tree
#      holds no such line today; if one lands, the fix is to register
#      nothing and teach the reader the redirection, not to mute it.
#
#   6. A FORWARDING WRAPPER NAME split by quoting -- `_d""ie seed_ok`.
#      The raw-text candidate filter asks for the derived wrapper names
#      as they are spelled, and a quoted name matches none of them, so
#      the line is never tokenised and the id behind it is MISSED. The
#      direct half of that filter asks only for the `_log_` prefix,
#      which nothing can split without also splitting the prefix; a
#      wrapper name has no such invariant prefix to fall back on, and
#      asking the question from the tokenised command names instead
#      would tokenise every line in the tree. So this one is a bound and
#      not a defect, and it errs in the missing direction.
#
# ── Non-vacuity ─────────────────────────────────────────────────────────────
#
# SIX ways this could go green having checked nothing, each a _die with its
# own sentence: a walk that failed part way through, a walk that found no
# *.sh at all, a population with no `_LOG_EVENTS_FILE=` assignment (the
# registry's location is unknown, so nothing can be compared), more than
# one such assignment resolving to different files (ambiguous), a registry
# that carries no id, and a scan that read no `_log_*` call site anywhere.
#
# The last is the one that matters: 271 direct call sites exist today, so
# zero means the detector has gone blind -- a renamed helper, a changed
# argument order -- and a blind detector reports a clean tree.
#
# A seventh is the wrapper half, which is where two of the four hid: when
# the population defines no forwarding wrapper AT ALL, the `_die
# ci_<something>` family is out of reach and this lint silently shrinks to
# the direct call sites. That is refused too, by its own sentence.
#
# An EIGHTH is about the reader rather than the tree: a file whose last
# logical line never closed -- an unterminated quote, substitution or
# backtick -- was read only up to that point, and the rest of it is gone
# from the population. Nothing else notices, because the other files
# still satisfy all seven checks above and the clean line reads exactly
# as it would over a tree that genuinely had less in it. If the file is
# in fact well formed, that refusal is reporting a defect in THIS driver,
# and says so.

# ── The emitted-id registry lint ────────────────────────────────────────────

# The shipped roots. dist/ is what a consumer gets; script/ is what this
# repo runs in CI. Both load lib/log.sh and both emit through it.
readonly _LER_ROOTS=('dist' 'script')

# The assignment that says where the registry lives. lib/log.sh writes
# `readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"`; this reads
# the basename out of it and resolves it against the assigning file's own
# directory, so the registry's path is a fact about the tree rather than a
# literal in this driver.
readonly _LER_REGISTRY_ASSIGN_RE='_LOG_EVENTS_FILE=.*/([A-Za-z0-9_.-]+)"'

# The scan program, in two phases over the same population.
#
# PHASE=def prints one record per function definition: whether it FORWARDS
# its first positional into a `_log_*` body slot, the file, and the name.
# PHASE=emit prints one record per literal event id, and a trailing count
# of the call sites READ (direct and through a wrapper), which is what the
# blind-detector checks below read.
#
# A FILE-SCOPE constant and not a heredoc inside the function, the shape
# drivers/spec_repo_root.sh already uses for _SPEC_REPO_ROOT_AWK: the
# reader is one program either way, and a function carrying it is one
# function over the implementation-standard length.
#
# Written for POSIX awk: the ci image carries busybox awk, mawk and gawk,
# and the issueref lint is the standing reminder that a program here runs
# under more than one of them.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _LER_AWK='
# ── The reader ──────────────────────────────────────────────────────────────
#
# TOKENS, not a regex over the raw line. The first spelling matched
# `_log_<level> <service> <body>` and a wrapper name followed by a word
# anywhere in the text, and split what it found on whitespace. Four shapes
# broke that, two in each direction, and all four are pinned as cases:
#
#   - a body wrapped onto a continuation line was never seen, because the
#     backslash was read as the body and the real id had no call in front
#     of it. bash reads backslash-newline as nothing, so the lines are
#     FOLDED here before anything looks at them.
#   - a body an operator terminates -- `_log_err conf id; true` -- was
#     DISCARDED, because `id;` is not id-shaped. An argument ends where
#     the shell says it does.
#   - a call spelled out in a TRAILING comment was reported. Only a whole
#     line comment was skipped, and this driver is in the population it
#     scans.
#   - a wrapper name inside a STRING -- help text naming `_die` -- was
#     read as a call, and the next word reported as an event id.
#
# The last two are the direction that matters most: a finding that is not
# a defect is what gets a gate muted. Narrowing the pattern a fourth time
# is the move base#1090 refused; what the shapes have in common is that
# they are facts about SHELL WORDS, so the reader is a word splitter.
#
# It is a small one, and deliberately: enough of the grammar to say where
# a word starts and ends, which quotes make one word out of several, and
# where a command position is. It does not expand anything, and a
# substitution inside double quotes stays part of its word -- which is
# what makes a non-literal body fall out on its own rather than by a rule.
#
# Written for POSIX awk: the ci image carries busybox awk, mawk and gawk,
# and the issueref lint is the standing reminder that a program here runs
# under more than one of them. The whole program is ONE shell
# single-quoted string, so no apostrophe appears anywhere in it, comments
# included -- the single quote character is built with sprintf where the
# tokeniser needs it.
# Can this body be compared against the registry at all? lib/log.sh
# compares the body to the registry line for line and imposes no shape on
# it, so a hyphen where an underscore belongs is refused at runtime like
# any other unregistered id -- and is exactly the typo this lint should
# catch. The only thing the scan cannot resolve is a body carrying an
# EXPANSION, so that is the only thing it declines.
# A dollar sign is not an expansion when the shell never treats it as
# one: a single-quoted `missing$` and a double-quoted `missing\$` are
# fully known literals, and after the quoting is removed the two are
# indistinguishable from a real one. So the tokeniser RECORDS whether an
# expansion occurred, while that can still be seen, and this reads the
# record rather than the text.
# The record separator is a tab, and a body can CONTAIN one: an
# ANSI-C quoted backslash-t decodes to one. Written verbatim the record
# splits, and the reader then takes
# a different word as the body. Encoded on the way out, decoded for the
# membership test, and shown encoded in the report so a finding stays
# one readable line.
# Does a dollar sign at <i> start an EXPANSION? Only when what follows
# introduces one. A trailing dollar -- `"missing$"`, or the unquoted
# spelling -- is kept literally by bash, so marking every dollar as an
# expansion declines a body that is both fully known and unregistered.
function _expands(line, i,   c) {
  if (i >= length(line)) return 0
  c = substr(line, i + 1, 1)
  if (c ~ /^[A-Za-z0-9_{(@*?#!$-]$/) return 1
  return 0
}
# A recorded substitution span is <token index> SPANSEP <text>. These read
# the two halves back. SPANSEP is built with sprintf and found with index
# rather than matched, so no escape has to be trusted inside a regular
# expression -- the three awks this runs under do not agree on what an
# octal escape means in one.
function _span_idx(s,   j) {
  j = index(s, SPANSEP)
  return (j > 0) ? substr(s, 1, j - 1) + 0 : 0
}
function _span_txt(s,   j) {
  j = index(s, SPANSEP)
  return (j > 0) ? substr(s, j + 1) : s
}
function _enc(t) {
  gsub(/%/, "%25", t)
  gsub(/\t/, "%09", t)
  gsub(/\n/, "%0A", t)
  return t
}
# A descriptor PREFIX: a number, or the bash named form `{name}`, which
# allocates a descriptor and puts its number in that variable. Only the
# numeric spelling was recognised, so the brace word took the command
# position and hid the logger behind it.
function _is_fd(t) { return (t ~ /^[0-9]+$/ || t ~ /^[{][A-Za-z_][A-Za-z0-9_]*[}]$/) }
# A redirection operator, and the descriptor-duplication half of one.
function _is_redir(t) { return (t ~ /^(<|>|<<|>>|<>|>[|])$/) }
# The ARGUMENTS of the command at index <ci>, by token index, in order.
# bash removes a redirection BEFORE it hands a command its positionals,
# so `_log_err 2>/dev/null conf id` passes id in the body slot exactly as
# the unredirected spelling does. A real separator ends the command.
function _args(kind, text, qs, adj, n, ci, out,   j, m, skip) {
  m = 0; j = ci + 1; skip = 0
  while (j <= n) {
    if (kind[j] == "O") {
      if (_is_redir(text[j])) {
        if (j < n && kind[j + 1] == "O" && text[j + 1] == "&") j++
        skip = 1; j++
        continue
      }
      if (text[j] == "&" && j < n && kind[j + 1] == "O" && text[j + 1] ~ /^(>|>>)$/) {
        j += 2; skip = 1
        continue
      }
      break
    }
    if (skip) { skip = 0; j++; continue }
    if (_is_fd(text[j]) && !qs[j] && j < n && kind[j + 1] == "O" && adj[j + 1] \
        && _is_redir(text[j + 1])) { j++; continue }
    m++; out[m] = j
    j++
  }
  return m
}
# Does <text>, the whole of a one-line function definition, hand its own
# first positional to a _log_* body slot? Either directly ("${1}") or
# through a name the same definition assigns "${1}" to, which is how
# test.sh spells it (`local _ev="${1}"; ... _log_err ci "${_ev}"`).
# <sh0> and <al> carry the positional state and the alias set INTO a
# recursive call, because a substitution has to be judged with the state
# in effect where it RUNS: a fresh context forgot a `shift` in front of it
# and read the `$1` inside as the caller first argument again. Both are
# empty at the top level, which is what a definition starts with.
function _forwards(text, sh0, al,   n, i, k, m, sn, d, ad, K, T, Q, EX, AJ, A, SUB, SI, ST, SJ, ALC, kk, cmd, cond, skip, subs, assignctx, shifted, tok, nm) {
  shifted = sh0
  n = _tokenize(text, K, T, Q, EX, AJ)
  # Captured immediately: the recursion below calls _tokenize again.
  subs = _TOK_SUBS
  # Each span arrives carrying the index of the token it sits in, and is
  # judged THERE in the walk below. Judging them all afterwards with the
  # definition end state was wrong in both directions: a wrapper that
  # logs its first argument inside a substitution and shifts afterwards
  # read as non-forwarding, so every call of it went unchecked; and a
  # name assigned the first positional AFTER a substitution was in the
  # alias set when the span was judged, so a fixed-body function read as
  # a wrapper and every ordinary call of it was reported.
  sn = split(subs, SUB, "\034")
  for (k = 1; k <= sn; k++) { SI[k] = _span_idx(SUB[k]); ST[k] = _span_txt(SUB[k]) }
  # ONE walk, in order. The alias set -- names this definition assigns
  # its own first positional to -- is updated as the commands go past,
  # so each `_log_*` call is judged against only the assignments in
  # FRONT of it. Collecting the set over the whole definition first gets
  # both orders wrong: a body that logs its alias and then overwrites it
  # does forward, and one that logs a fixed id before assigning does
  # not.
  cmd = 1
  for (i = 1; i <= n; i++) {
    # A substitution RUNS where it sits, so a definition whose logger
    # call is inside one forwards just as surely -- and it is judged with
    # the positional state and alias set as they stand HERE, which is the
    # state the shell will be in when it runs.
    for (k = 1; k <= sn; k++) {
      if (ST[k] == "" || SI[k] != i) continue
      SJ[k] = 1
      # A COPY of the alias set. The recursion assigns into the array it
      # is handed, and a name a substitution sets is not a name the
      # definition around it goes on holding.
      split("", ALC)
      for (kk in al) ALC[kk] = al[kk]
      if (_forwards(ST[k], shifted, ALC)) return 1
    }
    # THE SAME GRAMMAR THE EMIT SCAN USES, because the two have to agree.
    # An array initialiser stores words, an expression runs no command and
    # a redirection operand is a filename, so none of them is a logger
    # call -- and a walk that reset the command position at every operator
    # read all three as one, declaring a function that logs nothing a
    # wrapper and turning its every ordinary call into a reported id.
    if (d == 0 && K[i] == "O" && T[i] == "(" && i > 1 && K[i - 1] == "W" \
        && T[i - 1] ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=$/) {
      d = 1
      cmd = 0
      continue
    }
    if (d > 0) {
      if (K[i] == "O" && T[i] == "(") d++
      else if (K[i] == "O" && T[i] == ")") d--
      continue
    }
    if (!cond && cmd && K[i] == "W" && !Q[i] && T[i] == "[[") { cond = 1; cmd = 0; continue }
    if (!cond && K[i] == "O" && T[i] == "((") { cond = 2; ad = 0; cmd = 0; continue }
    if (cond == 1) {
      if (K[i] == "W" && !Q[i] && T[i] == "]]") cond = 0
      continue
    }
    # ARITHMETIC NESTS, and the inner closing pair must not end the
    # expression: after it did, the `&&` behind it opened a command
    # position inside what is still arithmetic, and the operator after a
    # variable sharing a wrapper name became an event id.
    if (cond == 2) {
      if (K[i] == "O" && T[i] == "((") ad++
      else if (K[i] == "O" && T[i] == "))") {
        if (ad > 0) ad--
        else cond = 0
      }
      continue
    }
    if (K[i] == "O" && _is_redir(T[i])) {
      if (i < n && K[i + 1] == "O" && T[i + 1] == "&") i++
      skip = 1
      continue
    }
    if (K[i] == "O" && T[i] == "&" && i < n && K[i + 1] == "O" && T[i + 1] ~ /^(>|>>)$/) {
      i++; skip = 1
      continue
    }
    if (K[i] == "O") { cmd = 1; assignctx = 0; continue }
    if (skip) { skip = 0; continue }
    if (_is_fd(T[i]) && !Q[i] && i < n && K[i + 1] == "O" && AJ[i + 1] \
        && _is_redir(T[i + 1])) continue
    # Any word of assignment shape counts, at a command position or not:
    # `local ev="${1}"` is an ARGUMENT of `local`, not a prefix. The
    # tokeniser has removed the quoting, so it arrives as `ev=${1}`
    # however it was written -- and EX is what says the `${1}` was a
    # real expansion rather than five single-quoted characters, which
    # would be a fixed id and no forward at all.
    # An assignment counts at a command POSITION, where it is a prefix,
    # or as an ARGUMENT of a builtin that assigns -- `local` and its
    # family. An assignment-SHAPED argument to an ordinary command
    # assigns nothing: `printf "%s" ev="$1"` prints a value, it does not
    # make `ev` the first argument, and tracking every such word declared
    # a function a wrapper on the strength of text handed to printf.
    if ((cmd || assignctx) \
        && T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && (Q[i] == 0 || index(T[i], "=") < Q[i])) {
      # A PREFIX is skipped entirely -- not recorded, and not deleted
      # either, because it does not change the variable the shell is
      # holding. Recording one declared a function a wrapper on the
      # strength of a value it never holds.
      if (cmd && !assignctx && !_assign_persists(K, T, Q, AJ, n, i)) continue
      nm = T[i]; sub(/=.*$/, "", nm)
      # `!shifted`: a name assigned `${1}` AFTER a shift holds the
      # second argument, so recording it as an alias of the first makes
      # the lint check the wrong argument of every call -- reporting
      # ordinary message text and missing the real id beside it. One
      # captured BEFORE the shift still forwards.
      if (!shifted && EX[i] && T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=[$][{]?1[}]?$/) al[nm] = 1
      else delete al[nm]
    }
    if (!cmd) continue
    if (_opens_another(T, Q, i)) continue
    if (!Q[i] && T[i] ~ /^(local|declare|typeset|export|readonly)$/) {
      assignctx = 1
      cmd = 0
      continue
    }
    # `shift` and `set --` move the POSITIONALS, so a `$1` logged after
    # one is not the caller first argument. The flag is on the
    # positionals and not on the definition, which is what keeps the
    # tree own `_die` working: it captures `${1}` into a local BEFORE
    # shifting, and an alias taken before the shift still forwards.
    if (!Q[i] && T[i] == "shift") { shifted = 1; cmd = 0; continue }
    # `unset` REMOVES a name, so a body logging it afterwards is empty --
    # which log.sh does not check at all. Leaving the name in the set
    # declared the function a wrapper and reported every call argument.
    if (!Q[i] && T[i] == "unset") {
      m = _args(K, T, Q, AJ, n, i, A)
      for (k = 1; k <= m; k++) delete al[T[A[k]]]
      cmd = 0
      continue
    }
    # `set -e` changes shell OPTIONS and leaves the positionals alone.
    # Only `set --`, or a `set` whose first argument is not an option,
    # replaces them -- treating every `set` as a change declined a real
    # wrapper and took all its call sites out of the population.
    if (!Q[i] && T[i] == "set") {
      # EVERY argument, not just the first. `set` takes options and THEN
      # positionals, so `set -e -- seed_ok` both sets an option and
      # replaces them: reading `-e` alone answered the wrong question.
      # `--` is the explicit spelling and matches an option test (a dash
      # followed by a dash); `-o` and `+o` consume the name after them,
      # so `set -o pipefail` changes no positional.
      m = _args(K, T, Q, AJ, n, i, A)
      for (k = 1; k <= m; k++) {
        if (T[A[k]] == "--") { shifted = 1; break }
        if (T[A[k]] == "-o" || T[A[k]] == "+o") { k++; continue }
        if (T[A[k]] !~ /^[-+]./) { shifted = 1; break }
      }
      cmd = 0
      continue
    }
    if (T[i] ~ /^_log_(debug|info|warn|err|fatal)$/ && _args(K, T, Q, AJ, n, i, A) >= 2) {
      # The same guard the emit scan uses: a service argument that expands
      # UNQUOTED moves the body out of its slot, so `_log_err {ci,id}
      # "$1"` does not forward -- the brace expansion puts id there.
      if (EX[A[1]] && Q[A[1]] == 0) { cmd = 0; continue }
      if (!EX[A[2]]) { cmd = 0; continue }
      tok = T[A[2]]
      if (!shifted && (tok == "${1}" || tok == "$1")) return 1
      if (match(tok, /^[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/)) {
        nm = tok; gsub(/[$={}]/, "", nm)
        if (nm in al) return 1
      }
    }
    cmd = 0
  }
  # A span whose token the walk never reached -- an index past the tokens
  # it saw, which is the shape a record with no index at all also takes.
  # Judged with the end state, which is where every span used to be
  # judged, so a span the walk cannot place is still read rather than
  # dropped.
  for (k = 1; k <= sn; k++) {
    if (ST[k] != "" && !SJ[k] && _forwards(ST[k], shifted, al)) return 1
  }
  return 0
}
# _tokenize(<folded line>, kind[], text[]) -> count
#   Split one logical line into shell-ish tokens. kind[i] is "W" for a
#   word and "O" for an operator; text[i] is the word with one level of
#   quoting removed, so a quoted run is ONE word and a name inside a
#   message is part of that word rather than a command.
#
#   A bare `#` at a word boundary ends the line, which is what the shell
#   does and what makes a trailing comment inert here.
function _tokenize(line, kind, text, qs, ex, adj,   n, i, c, e, cur, raw, has, j, L, sq, qst, hasex, gap, wgap, ao) {
  n = 0; cur = ""; has = 0; qst = 0; hasex = 0; gap = 1; wgap = 1; L = length(line); i = 1; sq = sprintf("%c", 39)
  _TOK_SUBS = ""
  while (i <= L) {
    # The token a substitution found from here BELONGS to. The word being
    # accumulated is flushed as token n + 1, so a span is recorded with
    # the position of the command whose argument carries it, and
    # _forwards can judge it where it RUNS instead of with the end state
    # of the whole definition. Set at the top of the OUTER loop, which is
    # the iteration a quoted word opens on, so a span found by the
    # double-quote reader carries the index of that word and not of the
    # one before it.
    _TOK_CUR = n + 1
    c = substr(line, i, 1)
    # Adjacency: a token that STARTS where the one before it ended. The
    # descriptor prefix of a redirection is the only thing that needs
    # it, and it needs it absolutely -- `2>` is one redirection because
    # the two characters touch, while `_log_err conf 123 > /dev/null`
    # passes 123 in the BODY slot.
    if (!has) wgap = gap
    if (c == " " || c == "\t") {
      if (has) { n++; kind[n] = "W"; text[n] = cur; qs[n] = qst; ex[n] = hasex; adj[n] = (wgap ? 0 : 1); cur = ""; has = 0; qst = 0; hasex = 0 }
      gap = 1
      i++
      continue
    }
    # A comment ends at the NEXT NEWLINE, and a logical line holds
    # several of them: a substitution written over several lines is one
    # logical line. Ending the whole read here would discard every
    # command after a comment inside one.
    if (c == "#" && !has) {
      j = index(substr(line, i), "\n")
      if (j == 0) break
      i = i + j - 1
      continue
    }
    # An ANSI-C quoted run -- dollar, apostrophe, text, apostrophe --
    # where a backslash escapes the next character, an apostrophe
    # included. Copied with the escapes resolved; what matters
    # here is that it ENDS where the shell says it does.
    if (c == "$" && substr(line, i + 1, 1) == sq) {
      if (!qst) qst = length(cur) + 1
      i += 2
      while (i <= L) {
        c = substr(line, i, 1)
        if (c == "\\" && i < L) {
          e = substr(line, i + 1, 1)
          if (e == "\\" || e == sq || e == "\"" || e == "?") cur = cur e
          else if (e == "n") cur = cur "\n"
          else if (e == "t") cur = cur "\t"
          else if (e == "r") cur = cur "\r"
          # `\x6f` is the letter o, and dropping the backslash is not
          # decoding it -- that yields a word no shell ever emits and a
          # finding that is not a defect. Anything this does not decode
          # makes the body UNRESOLVED, which is the one thing the scan
          # declines and says so about.
          else hasex = 1
          i += 2
          continue
        }
        if (c == sq) { i++; break }
        cur = cur c; i++
      }
      has = 1
      continue
    }
    if (c == sq) {
      if (!qst) qst = length(cur) + 1
      j = index(substr(line, i + 1), sq)
      if (j == 0) { cur = cur substr(line, i + 1); has = 1; break }
      cur = cur substr(line, i + 1, j - 1); has = 1; i = i + j + 1
      continue
    }
    if (c == "\"") {
      if (!qst) qst = length(cur) + 1
      i++
      while (i <= L) {
        c = substr(line, i, 1)
        # Inside double quotes bash escapes only `$`, a backtick, `"`,
        # `\\` and a newline. A backslash in front of ANYTHING ELSE is
        # kept, and removing it normalises a body into one the registry
        # carries -- so a call that is fatal at runtime reads as
        # registered, which is the one direction a registry gate must
        # never get wrong.
        if (c == "\\" && i < L) {
          e = substr(line, i + 1, 1)
          if (e == "$" || e == "`" || e == "\"" || e == "\\") cur = cur e
          else cur = cur c e
          i += 2
          continue
        }
        if (c == "$" && substr(line, i + 1, 1) == "{") {
          j = _brace_end(line, i + 1)
          if (j > 0) {
            _harvest(substr(line, i + 2, j - i - 2), 1)
            hasex = 1
            cur = cur substr(line, i, j - i + 1)
            i = j + 1
            continue
          }
        }
        # A command substitution RUNS what is inside it, and double quotes
        # do not stop that. Its span is kept VERBATIM, inner quotes
        # included, so _scan can descend into it; dissolving the quotes
        # here would leave a fragment no reader could make sense of.
        if (c == "$" && substr(line, i + 1, 1) == "(") {
          j = _subst_end(line, i + 1)
          if (j > 0) {
            # Arithmetic again; see the unquoted branch below.
            if (substr(line, i + 2, 1) == "(") _harvest(substr(line, i + 2, j - i - 2), 1)
            else _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(line, i + 2, j - i - 2) "\034"
            hasex = 1
            cur = cur substr(line, i, j - i + 1)
            i = j + 1
            continue
          }
        }
        if (c == "`") {
          j = _btick_end(line, i)
          if (j > 0) {
            _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(line, i + 1, j - i - 1) "\034"
            hasex = 1
            cur = cur substr(line, i, j - i + 1)
            i = j + 1
            continue
          }
        }
        if (c == "\"") { i++; break }
        if (c == "$" && _expands(line, i)) hasex = 1
        cur = cur c; i++
      }
      has = 1
      continue
    }
    # A BACKSLASH QUOTES the character after it, so `\time` is the
    # external command and not the shell keyword. Recorded like any other
    # quoting: without it the word read as the keyword, kept the command
    # position open, and made the name behind it a call.
    if (c == "\\" && i < L) {
      if (!qst) qst = length(cur) + 1
      cur = cur substr(line, i + 1, 1); has = 1; i += 2
      continue
    }
    # `$"..."` is LOCALE-TRANSLATED quoting: what the shell passes
    # depends on the message catalogue in force, so the body is knowable
    # only under a known locale. Read as a double-quoted run and marked
    # UNRESOLVED, which is the honest answer when the answer depends on
    # the environment -- keeping the dollar instead reported a body no
    # shell ever logs. UNQUOTED only: INSIDE double quotes a `$` before
    # the closing quote is a literal dollar, which its own case pins.
    if (c == "$" && substr(line, i + 1, 1) == "\"") {
      if (!qst) qst = length(cur) + 1
      hasex = 1
      i += 2
      # The VALUE is unknowable, which is why the body carrying one is
      # declined -- but a substitution written inside still RUNS, exactly
      # as inside ordinary double quotes, so the raw run is harvested.
      raw = ""
      while (i <= L) {
        c = substr(line, i, 1)
        if (c == "\\" && i < L) {
          raw = raw substr(line, i, 2)
          cur = cur substr(line, i + 1, 1); i += 2
          continue
        }
        if (c == "\"") { i++; break }
        raw = raw c
        cur = cur c; i++
      }
      _harvest(raw, 1)
      has = 1
      continue
    }
    # A PARAMETER EXPANSION carries its replacement text, and that text
    # is not shell to run -- in `${x:-; _die id}` the semicolon and the
    # name are characters inside one expansion. Taken whole, with the
    # substitutions that DO execute inside it harvested.
    if (c == "$" && substr(line, i + 1, 1) == "{") {
      j = _brace_end(line, i + 1)
      if (j > 0) {
        _harvest(substr(line, i + 2, j - i - 2), 0)
        hasex = 1
        cur = cur substr(line, i, j - i + 1)
        has = 1
        i = j + 1
        continue
      }
    }
    # An unquoted BRACE EXPANSION is resolved by the shell before the
    # logger sees it: `{a,b}` becomes two arguments. Checking the braced
    # text against the registry would report a body no shell ever logs,
    # so it is DECLINED like any other expansion. A group command is told
    # apart by its whitespace -- `{ cmd; }` has some, an expansion none.
    if (c == "{") {
      j = _brace_end(line, i)
      if (j > 0 && substr(line, i, j - i + 1) !~ /[[:space:]]/ \
          && substr(line, i + 1, j - i - 1) ~ /,|\.\./) {
        hasex = 1
        cur = cur substr(line, i, j - i + 1)
        has = 1
        i = j + 1
        continue
      }
    }
    # An UNQUOTED substitution belongs to the word it sits in, and its
    # closing parenthesis is not a command separator -- exposing it as
    # one puts the next argument of an ordinary command at a command
    # position. Taken whole and recorded, exactly as the double-quoted
    # spelling is, so the call INSIDE it is still found.
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      j = _subst_end(line, i + 1)
      if (j > 0) {
        # `$((...))` is ARITHMETIC: it reads variables and runs no
        # command, so its expression is not scanned as shell -- a
        # variable sharing a name with a wrapper would otherwise make
        # the operator after it an event id. It is still an expansion,
        # so a body carrying one is declined. Told apart by the two
        # parentheses being adjacent, which is how it is written; a
        # space between them is the subshell instead.
        if (substr(line, i + 2, 1) == "(") _harvest(substr(line, i + 2, j - i - 2), 0)
        else _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(line, i + 2, j - i - 2) "\034"
        hasex = 1
        cur = cur substr(line, i, j - i + 1)
        has = 1
        i = j + 1
        continue
      }
    }
    if (c == "`") {
      j = _btick_end(line, i)
      if (j > 0) {
        _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(line, i + 1, j - i - 1) "\034"
        hasex = 1
        cur = cur substr(line, i, j - i + 1)
        has = 1
        i = j + 1
        continue
      }
    }
    # `<(...)` and `>(...)` are PROCESS substitutions: a command runs
    # where a filename is expected. Read as a plain redirection the
    # command inside becomes the operand and is skipped whole, which is
    # a miss in the one construct whose point is that it is not a file.
    if ((c == "<" || c == ">") && substr(line, i + 1, 1) == "(") {
      j = _subst_end(line, i + 1)
      if (j > 0) {
        _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(line, i + 2, j - i - 2) "\034"
        hasex = 1
        cur = cur substr(line, i, j - i + 1)
        has = 1
        i = j + 1
        continue
      }
    }
    if (index(";&|()<>\n", c) > 0) {
      ao = (gap ? 0 : 1)
      if (has) {
        n++; kind[n] = "W"; text[n] = cur; qs[n] = qst; ex[n] = hasex; adj[n] = (wgap ? 0 : 1)
        cur = ""; has = 0; qst = 0; hasex = 0
        ao = 1
      }
      n++; kind[n] = "O"; qs[n] = 0; ex[n] = 0; adj[n] = ao
      # `>|` is ONE operator -- the noclobber override -- and splitting
      # it leaves a bare pipe, which ends the command and takes the body
      # after it out of reach.
      if (c == ">" && substr(line, i + 1, 1) == "|") { text[n] = ">|"; i += 2 }
      else if (substr(line, i + 1, 1) == c) { text[n] = c c; i += 2 }
      else { text[n] = c; i++ }
      gap = 0
      continue
    }
    if (c == "$" && _expands(line, i)) hasex = 1
    # An unquoted `*`, `?` or `[` is a PATHNAME pattern: what the command
    # receives depends on what is on disk, so the body is not knowable
    # from the source. Declined like the brace expansion above; quoting
    # or escaping is what stops the expansion, and both reach `cur` by a
    # path that never gets here.
    if (c == "*" || c == "?" || c == "[") hasex = 1
    # A leading unquoted `~` is TILDE expansion: the shell replaces it
    # with a home directory, so the body is a fact about the machine and
    # not about the source. Only at the START of a word, which is where
    # bash expands it.
    if (c == "~" && !has) hasex = 1
    cur = cur c; has = 1; i++
  }
  if (has) { n++; kind[n] = "W"; text[n] = cur; qs[n] = qst; ex[n] = hasex; adj[n] = (wgap ? 0 : 1) }
  return n
}
# Does word i STAY at a command position rather than being the command
# itself -- a keyword that opens another command, or an assignment prefix
# in front of one?
#
# UNQUOTED only. A keyword is a keyword because the shell reads it as one,
# and a quoted `then` is an ordinary word: `printf "%s" "then" _log_err
# conf x` runs no logger. The tokeniser has already removed the quotes by
# the time this is asked, which is why it also records whether the word
# OPENED with one.
# Does the assignment at <i> PERSIST past its command? A standalone
# assignment does; a PREFIX -- `ev="$1" true` -- changes only the
# environment of the command it sits in front of and leaves the shell own
# variable alone, so it is an alias for nothing after it. Told apart by
# whether a command word follows in the same simple command.
function _assign_persists(kind, text, qs, adj, n, i,   j, skip) {
  skip = 0
  for (j = i + 1; j <= n; j++) {
    if (kind[j] == "O") {
      # A REDIRECTION sits between a prefix and the command it belongs
      # to, so stopping at the first operator read `ev=x >/dev/null cmd`
      # as a standalone assignment. Consumed the way the argument walk
      # consumes it; any other operator really does end the command.
      if (_is_redir(text[j])) {
        if (j < n && kind[j + 1] == "O" && text[j + 1] == "&") j++
        skip = 1
        continue
      }
      if (text[j] == "&" && j < n && kind[j + 1] == "O" && text[j + 1] ~ /^(>|>>)$/) {
        j += 2; skip = 1
        continue
      }
      return 1
    }
    if (skip) { skip = 0; continue }
    if (_is_fd(text[j]) && !qs[j] && j < n && kind[j + 1] == "O" && adj[j + 1] \
        && _is_redir(text[j + 1])) continue
    if (text[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && (qs[j] == 0 || index(text[j], "=") < qs[j])) continue
    return 0
  }
  return 1
}
function _opens_another(text, qs, i) {
  # A KEYWORD has to be wholly unquoted -- `then""` is the word, not the
  # keyword -- and `command`, `builtin` and `exec` are deliberately NOT
  # in the set: they BYPASS shell functions, which is what they are for,
  # so none of them can invoke `_log_err` or a wrapper. Reading them as
  # transparent openers made the name behind one a call and reported an
  # id no shell ever logs.
  if (!qs[i] && text[i] ~ /^(if|while|until|then|do|else|elif|\{|\}|!|time|eval)$/) return 1
  # `time` keeps the command position open and `-p` is its own flag, not
  # the command, so the flag has to be read the same way the keyword is.
  if (!qs[i] && text[i] == "-p" && i > 1 && !qs[i - 1] && text[i - 1] == "time") return 1
  # An ASSIGNMENT PREFIX needs only its NAME unquoted: `VAR="x" cmd` is
  # one, `"VAR=x" cmd` is not. qs says where the first quote fell, so
  # the test is whether the `=` came before it.
  if (text[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return 0
  return (qs[i] == 0 || index(text[i], "=") < qs[i])
}
# One folded line: count the emit sites it holds and print the literal
# ids among them. <ln> is the FIRST physical line of the fold, which is
# the line a reader of the report opens.
function _scan(line, ln,   n, i, m, d, ad, K, T, Q, EX, AJ, A, SUB, cmd, cond, skip, subs, k) {
  n = _tokenize(line, K, T, Q, EX, AJ)
  # Captured IMMEDIATELY: _tokenize publishes the substitution list in a
  # global, and the recursion below calls _tokenize again.
  subs = _TOK_SUBS
  # The command position is CARRIED, not inferred from the token behind:
  # it starts true, every operator restores it, a keyword or an assignment
  # prefix keeps it, and the first ordinary word consumes it. Looking back
  # one token could not tell `VAR=x _log_err ...` (a call) from an
  # argument, nor a quoted `then` from the keyword.
  cmd = 1
  d = _ARR_DEPTH
  cond = _COND
  # The nesting depth is carried with the state it belongs to. Carrying
  # one without the other is worse than carrying neither: it looks like
  # the multi-line case is handled, and a nested expression spread over
  # two lines has its INNER closing pair end the expression.
  ad = _ADEPTH
  for (i = 1; i <= n; i++) {
    # Inside `[[ ... ]]` the operators are the CONDITIONAL grammar: `&&`
    # there joins two tests and opens no command position. Reading it as
    # one makes the word after it a command, so an ordinary string
    # comparison naming a wrapper reports its right-hand side as an
    # event id. A substitution inside the expression still runs, and the
    # descent below still reads it.
    # UNQUOTED, and at a command position. A quoted `[[` is an argument,
    # and taking it for the opener puts this state on and leaves it on,
    # suppressing every call for the rest of the file while the clean
    # line reads normally -- the state that fixes a false finding must
    # not be able to create a silent miss.
    # `[[ ... ]]` is the conditional grammar and `(( ... ))` the
    # arithmetic one. Neither contains commands: `&&` there joins two
    # tests, and a variable sharing a name with a wrapper would make the
    # operator after it an event id. Both carry across lines, because an
    # expression spread over several is still one expression.
    if (!cond && cmd && K[i] == "W" && !Q[i] && T[i] == "[[") { cond = 1; cmd = 0; continue }
    # No `cmd` condition on `((`: `for (( ... ))` puts a keyword in front
    # of the same arithmetic grammar, and the keyword consumes the
    # position. A standalone `((` operator token only ever means
    # arithmetic -- a substitution is captured into a word, not exposed
    # as this token.
    if (!cond && K[i] == "O" && T[i] == "((") { cond = 2; ad = 0; cmd = 0; continue }
    if (cond == 1) {
      if (K[i] == "W" && !Q[i] && T[i] == "]]") cond = 0
      continue
    }
    # ARITHMETIC NESTS, and the inner closing pair must not end the
    # expression: after it did, the `&&` behind it opened a command
    # position inside what is still arithmetic, and the operator after a
    # variable sharing a wrapper name became an event id.
    if (cond == 2) {
      if (K[i] == "O" && T[i] == "((") ad++
      else if (K[i] == "O" && T[i] == "))") {
        if (ad > 0) ad--
        else cond = 0
      }
      continue
    }
    # `function name { ... }` puts the NAME where a command would stand,
    # so a wrapper defining itself that way reads as a call of itself
    # and the brace after it as an event id. The prologue is consumed.
    if (cmd && K[i] == "W" && !Q[i] && T[i] == "function") {
      if (i < n && K[i + 1] == "W") i++
      continue
    }
    # A REDIRECTION is not a separator and its operand is a FILENAME.
    # Consuming the whole thing leaves the command position where it was:
    # otherwise `>/dev/null _log_err ...` lets the filename take the
    # position and the logger behind it is never read, while `> _die x`
    # makes a filename look like a wrapper call. `2>&1` is ONE such
    # redirection written in three tokens, and the `&` in the middle is
    # not the `&` that backgrounds a command.
    if (K[i] == "O" && _is_redir(T[i])) {
      if (i < n && K[i + 1] == "O" && T[i + 1] == "&") i++
      skip = 1
      continue
    }
    if (K[i] == "O" && T[i] == "&" && i < n && K[i + 1] == "O" && T[i + 1] ~ /^(>|>>)$/) {
      i++; skip = 1
      continue
    }
    # `name=( ... )` STORES words and runs nothing, so its contents are
    # not commands. It is told from a subshell by the assignment in front
    # of the parenthesis, which the tokeniser leaves as its own word
    # because `(` is an operator.
    if (d == 0 && K[i] == "O" && T[i] == "(" && i > 1 && K[i - 1] == "W" \
        && T[i - 1] ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=$/) {
      d = 1
      cmd = 0
      continue
    }
    # Inside one, and NOT by folding the file: an initialiser spread over
    # several lines is still one initialiser, so the depth is carried from
    # line to line. Counting parentheses only INSIDE an initialiser is
    # what keeps that safe -- a `(` anywhere else, in a heredoc body or a
    # glob, would otherwise swallow the rest of the file.
    if (d > 0) {
      if (K[i] == "O" && T[i] == "(") d++
      else if (K[i] == "O" && T[i] == ")") d--
      continue
    }
    if (K[i] == "O") { cmd = 1; continue }
    if (skip) { skip = 0; continue }
    # An fd prefix belongs to the redirection behind it, not to the
    # command position: `2>/dev/null` is one redirection.
    if (_is_fd(T[i]) && !Q[i] && i < n && K[i + 1] == "O" && AJ[i + 1] \
        && _is_redir(T[i + 1])) continue
    if (!cmd) continue
    if (_opens_another(T, Q, i)) continue
    if (T[i] ~ /^_log_(debug|info|warn|err|fatal)$/) {
      m = _args(K, T, Q, AJ, n, i, A)
      if (m >= 2) {
        direct++
        # The argument BEFORE the body matters too: one that expands into
        # more than one word moves the body out of its slot. `_log_err
        # {conf,x} <word>` emits `x`, so reading <word> would report an id
        # the shell never logs AND say nothing about the one it does.
        #
        # UNQUOTED only. A QUOTED expansion is exactly one word -- the
        # tree writes its service as `"${_svc}"` and declining those cost
        # nine real emit sites when this was first spelled without the
        # quoting test. The residual is a word that merely BEGINS
        # unquoted, like `$svc"x"`, which this reads as protected; that is
        # a stated limit, and it errs toward checking rather than
        # declining.
        if (!(EX[A[1]] && Q[A[1]] == 0) && !EX[A[2]]) \
          printf "ID" US "%s" US "%s" US "%d\n", _enc(T[A[2]]), FILENAME, ln
      }
    } else if ((T[i] in fwd) && !((FILENAME "|" T[i]) in shadow)) {
      m = _args(K, T, Q, AJ, n, i, A)
      if (m >= 1) {
        wrapped++
        if (!EX[A[1]]) printf "ID" US "%s" US "%s" US "%d\n", _enc(T[A[1]]), FILENAME, ln
      }
    }
    cmd = 0
  }
  # Descend into every command substitution that RUNS. An unquoted one
  # was split on its parentheses above and is already read; this is the
  # double-quoted kind the tokeniser kept whole.
  #
  # The list comes from the tokeniser, which recorded each span WHILE THE
  # QUOTING WAS STILL KNOWN. Searching the finished token for `$(` cannot
  # do it: by then the quotes are gone, so a substitution written inside
  # single quotes, or escaped inside double ones -- both of them the
  # documented way to SHOW one without running it, and both of them in
  # shipped help text -- read exactly like the real thing.
  _ARR_DEPTH = d
  _COND = cond
  _ADEPTH = ad
  k = split(subs, SUB, "\034")
  for (i = 1; i <= k; i++) {
    # The emit descent reads every span wherever it sits, so the token
    # index _forwards judges spans at is not wanted here and comes off.
    SUB[i] = _span_txt(SUB[i])
    if (SUB[i] != "") {
      # The recursion runs its own walk, so the carried depth is put back
      # afterwards: a substitution inside an initialiser does not end it.
      d = _ARR_DEPTH; cond = _COND; ad = _ADEPTH
      _ARR_DEPTH = 0; _COND = 0; _ADEPTH = 0
      _scan(SUB[i], ln)
      _ARR_DEPTH = d; _COND = cond; _ADEPTH = ad
    }
  }
}
# _btick_end(<text>, <index of the opening backtick>) -> index of its
#   match, or 0. Backticks are the older spelling of a command
#   substitution and run the same command; inside one a backslash escapes
#   the next character.
# _harvest(<text>) -- record every command substitution <text> carries,
#   without reading <text> itself as commands. Arithmetic reads
#   variables and runs nothing -- except that a substitution written
#   inside it DOES run, so declining the whole expansion to keep its
#   identifiers inert would throw the nested call away with it.
# <dq> says the text came from inside DOUBLE quotes, where a single quote
# is an ordinary character and does NOT stop a substitution running. The
# context has to travel with the text, or an apostrophe-wrapped span
# inside a double-quoted expansion reads as quoted and its call is lost.
function _harvest(t, dq,   L, i, c, sq, j) {
  L = length(t); sq = sprintf("%c", 39); i = 1
  while (i <= L) {
    c = substr(t, i, 1)
    if (!dq && c == sq) {
      j = index(substr(t, i + 1), sq)
      if (j == 0) break
      i = i + j + 1
      continue
    }
    if (c == "\\" && i < L) { i += 2; continue }
    if (c == "$" && substr(t, i + 1, 1) == "(") {
      j = _subst_end(t, i + 1)
      if (j > 0) {
        if (substr(t, i + 2, 1) == "(") _harvest(substr(t, i + 2, j - i - 2), dq)
        else _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(t, i + 2, j - i - 2) "\034"
        i = j + 1
        continue
      }
    }
    if (c == "`") {
      j = _btick_end(t, i)
      if (j > 0) {
        _TOK_SUBS = _TOK_SUBS _TOK_CUR SPANSEP substr(t, i + 1, j - i - 1) "\034"
        i = j + 1
        continue
      }
    }
    i++
  }
}
# _brace_end(<text>, <index of the opening brace>) -> index of its match,
#   or 0. Counts nesting and skips quoted runs, so a parameter expansion
#   can be taken whole: its replacement text is CHARACTERS, not shell to
#   run, and exposing a separator inside one puts the word after it at a
#   command position.
function _brace_end(t, i,   L, d, c, sq, st) {
  L = length(t); sq = sprintf("%c", 39); d = 0; st = 0
  while (i <= L) {
    c = substr(t, i, 1)
    if (st == 1) { if (c == sq) st = 0; i++; continue }
    if (st == 2) {
      if (c == "\\" && i < L) { i += 2; continue }
      if (c == "\"") st = 0
      i++
      continue
    }
    if (c == sq) { st = 1; i++; continue }
    if (c == "\"") { st = 2; i++; continue }
    if (c == "{") { d++; i++; continue }
    if (c == "}") { d--; if (d == 0) return i; i++; continue }
    i++
  }
  return 0
}
function _btick_end(text, i,   L, c) {
  L = length(text); i++
  while (i <= L) {
    c = substr(text, i, 1)
    if (c == "\\" && i < L) { i += 2; continue }
    if (c == "`") return i
    i++
  }
  return 0
}
# _subst_end(<text>, <index of the opening parenthesis>) -> index of its
#   match, or 0. Counts nesting and skips quoted runs, so the span of a
#   command substitution can be taken whole.
# Is the <len>-character run at <i> a whole WORD, not part of a longer
# one? `case` and `esac` have to be recognised to tell a case PATTERN
# terminator from a parenthesis that closes something, and `lowercase)`
# must not be read as one of them.
function _is_word_at(t, i, len,   b, a) {
  b = (i == 1) ? "" : substr(t, i - 1, 1)
  a = substr(t, i + len, 1)
  if (b ~ /[A-Za-z0-9_.\/-]/) return 0
  if (a ~ /[A-Za-z0-9_.\/-]/) return 0
  return 1
}
# Could a COMMAND start at <i>? Looking back over whitespace to the
# start of the text, a separator, or a keyword that opens one. `case` is
# a keyword only here: as an ARGUMENT it is four letters, and opening a
# case frame for one left a frame nothing closes, so the substitution
# around it never closed either.
function _cmd_pos_at(t, i,   j, c) {
  j = i - 1
  while (j >= 1) {
    c = substr(t, j, 1)
    if (c == " " || c == "\t") { j--; continue }
    break
  }
  if (j < 1) return 1
  c = substr(t, j, 1)
  if (index(";&|()<>{}!\n", c) > 0) return 1
  if (j >= 4 && substr(t, j - 3, 4) == "then" && _is_word_at(t, j - 3, 4)) return 1
  if (j >= 4 && substr(t, j - 3, 4) == "else" && _is_word_at(t, j - 3, 4)) return 1
  if (j >= 2 && substr(t, j - 1, 2) == "do" && _is_word_at(t, j - 1, 2)) return 1
  if (j >= 2 && substr(t, j - 1, 2) == "in" && _is_word_at(t, j - 1, 2)) return 1
  return 0
}
function _subst_end(text, i,   L, d, c, k, sq, st, cs) {
  L = length(text); sq = sprintf("%c", 39); d = 0; st = 0
  while (i <= L) {
    c = substr(text, i, 1)
    if (st == 3) {
      if (c == "\\" && i < L) { i += 2; continue }
      if (c == sq) st = 0
      i++
      continue
    }
    if (st == 1) { if (c == sq) st = 0; i++; continue }
    if (st == 2) {
      if (c == "\\" && i < L) { i += 2; continue }
      # Quoting RESTARTS inside a substitution, so a nested one opened
      # while this one is quoted gets its own span and its own quote
      # state. Sharing one state across the boundary let the first
      # literal `)` in a display string look like the end of the whole
      # thing.
      if (c == "$" && substr(text, i + 1, 1) == "(") {
        k = _subst_end(text, i + 1)
        if (k > 0) { i = k + 1; continue }
      }
      if (c == "\"") st = 0
      i++
      continue
    }
    if (c == "$" && substr(text, i + 1, 1) == sq) { st = 3; i += 2; continue }
    if (c == sq) { st = 1; i++; continue }
    if (c == "\"") { st = 2; i++; continue }
    # A parenthesis inside a COMMENT closes nothing, and an escaped one
    # is a character. Counting either ends the span early, and every
    # command after it falls back into the word around it and vanishes.
    if (c == "#" && d > 0 && (i == 1 || substr(text, i - 1, 1) ~ /[[:space:]]/)) {
      k = index(substr(text, i), "\n")
      if (k == 0) return 0
      i = i + k
      continue
    }
    if (c == "\\" && i < L) { i += 2; continue }
    # A `case` PATTERN ends with a `)` that closes nothing. Counted per
    # depth, so a `case` in one substitution does not excuse a
    # parenthesis in another.
    if (substr(text, i, 4) == "case" && _is_word_at(text, i, 4) && _cmd_pos_at(text, i)) { cs[d]++; i += 4; continue }
    if (substr(text, i, 4) == "esac" && _is_word_at(text, i, 4) && _cmd_pos_at(text, i)) {
      if (cs[d] > 0) cs[d]--
      i += 4
      continue
    }
    if (c == "(") { d++; i++; continue }
    if (c == ")") {
      if (cs[d] > 0) { i++; continue }
      d--
      if (d == 0) return i
      i++
      continue
    }
    i++
  }
  return 0
}
# _lex_state(<physical line>, <state in>) -> <state out>
#   The fold needs two facts the tokeniser cannot give it, because the
#   tokeniser runs on a line that is already complete: whether a quote is
#   still open at the newline (0 none, 1 single, 2 double), and whether
#   the line ends in a continuation backslash. The second is published in
#   _LEX_CONT rather than returned, awk having one return value.
#
#   A COMMENT ends the line for both purposes. bash does not continue a
#   comment over a backslash, so a trailing one there continues nothing
#   and folding on it would glue the next line of CODE onto a line the
#   tokeniser discards whole.
function _top_st(ctx) { return substr(ctx, length(ctx), 1) + 0 }
function _top_kind(ctx) { return substr(ctx, length(ctx) - 1, 1) }
function _set_st(ctx, v) { return substr(ctx, 1, length(ctx) - 1) v }
function _push(ctx, kind) { return ctx kind "0" }
function _pop(ctx) { return (length(ctx) > 2) ? substr(ctx, 1, length(ctx) - 2) : ctx }
# Is the logical line still unfinished? A quote still open, or a frame
# that a closing character is owed: a substitution, a backtick, a group.
# A `case` frame does NOT count -- it is open from `case` to `esac`,
# which is a block and not a line continuation, and folding over it
# would swallow the whole statement.
# Are we inside a substitution or a backtick? Only there is a plain `(`
# worth counting. Outside one it is ignored, because a `(` in a heredoc
# body or a glob never closes -- a `case` frame must not make it count
# either, and the shipped usage heredocs that live in `case` arms are
# exactly where that showed.
function _in_subst(ctx,   i, L, kk) {
  L = length(ctx)
  for (i = 1; i < L; i += 2) {
    kk = substr(ctx, i, 1)
    if (kk == "P" || kk == "B") return 1
  }
  return 0
}
# Is the top frame inside a quote? Definition discovery asks, because a
# `name() { ... }` written inside a multi-line STRING is not a
# definition -- and taken for a non-forwarding one it SHADOWS the wrapper
# for the whole file, which turns the rule that prevents false findings
# into one that manufactures silent misses.
function _in_quote(ctx) { return (_top_st(ctx) != 0) }
function _fold_open(ctx,   i, L, kk) {
  if (_top_st(ctx) != 0) return 1
  L = length(ctx)
  for (i = 1; i < L; i += 2) {
    kk = substr(ctx, i, 1)
    if (kk == "P" || kk == "B" || kk == "G") return 1
  }
  return 0
}
# _lex_state(<physical line>, <context in>) -> <context out>
#   Where the fold stands at the newline. The context is a STACK of
#   frames, two characters each: a kind -- T the top level, P a `$(`,
#   `<(` or `>(` substitution, G a plain group inside one, B a backtick
#   -- and the quote state inside that frame (0 none, 1 single, 2
#   double, 3 the ANSI-C form). The logical line is complete when the
#   context is back to T0.
#
#   A STACK, because QUOTING INSIDE A SUBSTITUTION IS ITS OWN. One
#   shared state cannot say that: a double quote inside a substitution
#   single-quoted argument would close the quote OUTSIDE it, the fold
#   would never close, and every line after it would sit in a buffer
#   that the next file discards -- the rest of a file leaving the
#   population with nothing said about it.
#
#   A plain `(` is pushed only INSIDE a substitution. At the top level
#   it is ignored, because a `(` in a heredoc body or a glob never
#   closes: counting those was measured against the real tree earlier in
#   this branch and folded init.sh 827 lines into one.
#
#   _LEX_CONT is published beside the return: the line ended in a
#   continuation backslash, which joins with nothing between the halves.
function _lex_state(line, ctx,   i, L, c, sq, pv, st, k) {
  if (ctx == "") ctx = "T0"
  L = length(line); sq = sprintf("%c", 39); i = 1; _LEX_CONT = 0
  while (i <= L) {
    st = _top_st(ctx); k = _top_kind(ctx)
    c = substr(line, i, 1)
    if (st == 3) {
      if (c == "\\" && i < L) { i += 2; continue }
      if (c == sq) ctx = _set_st(ctx, 0)
      i++
      continue
    }
    if (st == 1) { if (c == sq) ctx = _set_st(ctx, 0); i++; continue }
    if (st == 2) {
      if (c == "\\" && i < L) { i += 2; continue }
      if (c == "\\") { _LEX_CONT = 1; break }
      if (c == "$" && substr(line, i + 1, 1) == "(") { ctx = _push(ctx, "P"); i += 2; continue }
      if (c == "`") { ctx = _push(ctx, "B"); i++; continue }
      if (c == "\"") ctx = _set_st(ctx, 0)
      i++
      continue
    }
    if (c == "#") {
      pv = (i == 1) ? " " : substr(line, i - 1, 1)
      if (pv == " " || pv == "\t" || index(";&|()<>", pv) > 0) break
      i++
      continue
    }
    if (c == "$" && substr(line, i + 1, 1) == sq) { ctx = _set_st(ctx, 3); i += 2; continue }
    if (c == "`") {
      if (k == "B") ctx = _pop(ctx)
      else ctx = _push(ctx, "B")
      i++
      continue
    }
    if (c == sq) { ctx = _set_st(ctx, 1); i++; continue }
    if (c == "\"") { ctx = _set_st(ctx, 2); i++; continue }
    if (c == "\\") {
      if (i == L) { _LEX_CONT = 1; break }
      i += 2
      continue
    }
    if ((c == "$" || c == "<" || c == ">") && substr(line, i + 1, 1) == "(") {
      ctx = _push(ctx, "P"); i += 2
      continue
    }
    # `case` opens a frame of its own, so a PATTERN terminator -- a `)`
    # that closes nothing -- cannot pop the substitution around it,
    # while a `$( ... )` written inside an arm still closes normally
    # because it pushes its own frame on top.
    if (substr(line, i, 4) == "case" && _is_word_at(line, i, 4) && _cmd_pos_at(line, i)) { ctx = _push(ctx, "C"); i += 4; continue }
    if (substr(line, i, 4) == "esac" && _is_word_at(line, i, 4) && _cmd_pos_at(line, i)) {
      if (k == "C") ctx = _pop(ctx)
      i += 4
      continue
    }
    if (c == "(") { if (_in_subst(ctx)) ctx = _push(ctx, "G"); i++; continue }
    if (c == ")") { if (k == "P" || k == "G") ctx = _pop(ctx); i++; continue }
    i++
  }
  return ctx
}
# Worth tokenising? Tokenising is per character, and all but a few
# thousand of the tree lines can hold no call at all. The names are the
# derived wrapper set, so this filter widens with it rather than being a
# second place a name is written down.
function _candidate(line) {
  # The PREFIX alone, and not the level name behind it. QUOTING splits a
  # command name that the tokeniser rejoins once the quotes come off, so
  # a call written `_log_""err ci missing` matched no spelling of
  # `_log_<level>` in the raw text and was never tokenised -- its
  # unregistered body left the population, which is a MISS and the one
  # direction this filter can produce. Nothing splits `_log_` without
  # also splitting the prefix, so this is as narrow as the raw text lets
  # the question be asked. It costs runtime and nothing else: the filter
  # exists only for speed.
  if (line ~ /_log_/) return 1
  # An array initialiser OPENS on a line that may hold no call at all,
  # and the depth it starts has to be carried to the lines that do.
  if (line ~ /=\(/) return 1
  # A conditional OPENS on a line that may hold no call at all, and the
  # state it starts has to reach the lines that do.
  if (line ~ /\[\[|\]\]|\(\(|\)\)/) return 1
  return (fwdre != "" && line ~ fwdre)
}
BEGIN {
  # The ID / SEEN records are separated by a UNIT SEPARATOR, not a tab.
  # A tab is IFS whitespace, so the reading shell collapses a run of
  # them and drops an empty field -- which is exactly the empty-body
  # case, and a body can carry a tab of its own as well.
  US = sprintf("%c", 31)
  # The separator between a substitution span and the token index it was
  # found in. A GROUP separator, so it is distinct from the record
  # separator the span list itself uses.
  SPANSEP = sprintf("%c", 29)
  n = split(FWDS, a, "\n")
  for (i = 1; i <= n; i++) if (a[i] != "") {
    fwd[a[i]] = 1
    fwdre = (fwdre == "" ? a[i] : fwdre "|" a[i])
  }
  if (fwdre != "") fwdre = "(^|[^A-Za-z0-9_])(" fwdre ")([^A-Za-z0-9_]|$)"
  n = split(SHADOWS, b, "\n")
  for (i = 1; i <= n; i++) if (b[i] != "") shadow[b[i]] = 1
}
PHASE == "def" {
  if (FNR == 1) dctx = "T0"
  dinq = _in_quote(dctx)
  dctx = _lex_state($0, dctx)
  if (dinq) next
  # Two spellings, and the second has no parentheses in it at all. A
  # wrapper written `function name { ... }` was never discovered, so its
  # call sites went unchecked -- and silently, because another wrapper
  # exists and the empty-wrapper refusal therefore does not fire. The
  # same omission would stop such a definition SHADOWING a name, which
  # is the half that prevents false findings.
  if ($0 ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/) {
    match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)
    nm = substr($0, RSTART, RLENGTH)
    sub(/[[:space:]]*\(\)$/, "", nm)
  } else if ($0 ~ /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\{/) {
    nm = $0
    sub(/^[[:space:]]*function[[:space:]]+/, "", nm)
    sub(/[[:space:]]*\{.*$/, "", nm)
  } else if ($0 ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*$/) {
    # The opening brace on the NEXT line. Recorded as PLAIN without
    # reading a body, which is the refusing direction and agrees with the
    # stated limit that a multi-line definition is not read for
    # forwarding: what matters here is that the NAME exists, so the
    # definition can SHADOW. Without it a file defining its own `_die`
    # this way had every call of it read as another file forwarding
    # wrapper, and its ordinary arguments reported as event ids.
    match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)
    nm = substr($0, RSTART, RLENGTH)
    sub(/[[:space:]]*\(\)$/, "", nm)
    printf "%s\t%s\t%s\n", "PLAIN", FILENAME, nm
    next
  } else if ($0 ~ /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) {
    nm = $0
    sub(/^[[:space:]]*function[[:space:]]+/, "", nm)
    sub(/[[:space:]]*$/, "", nm)
    printf "%s\t%s\t%s\n", "PLAIN", FILENAME, nm
    next
  } else {
    next
  }
  # The BODY, not the whole line: what is in front of the opening brace
  # is the definition prologue, and in the `function name {` spelling the
  # name sits where a command would, which would consume the command
  # position the body needs.
  body = $0
  sub(/^[^{]*\{/, "", body)
  # And it ENDS at its matching closing brace. Stripping the prologue
  # alone left whatever followed the function on the same line inside the
  # text read as its body, so `w() { printf "%s" "$1"; }; _log_err ci
  # "$1"` declared a fixed-body function a forwarding wrapper -- and a
  # wrongly declared wrapper reports every ordinary call of that
  # function, not one site, which is the worst false finding this scan
  # has. _brace_end counts quote-aware and wants the opening brace, so it
  # is asked about the body with that brace put back in front, so every
  # index it returns is one higher than the same character in the body,
  # and the closing brace itself is not part of the body.
  bend = _brace_end("{" body, 1)
  # Zero means the brace never closed on this line. That is the
  # multi-line definition the reach list already declines, and the body
  # is left as it stands rather than truncated to nothing.
  if (bend > 0) body = substr(body, 1, bend - 2)
  printf "%s\t%s\t%s\n", (_forwards(body) ? "FWD" : "PLAIN"), FILENAME, nm
  next
}
PHASE == "emit" {
  if (FNR == 1) {
    # A buffer still open where a file ended is the REST OF THAT FILE
    # leaving the population, and it goes unnoticed: the other files
    # satisfy every non-vacuity check and the clean line reads normally.
    # Reported, and refused by the caller.
    if (buf != "") printf "OPEN" US "%s" US "%d\n", prevfile, startln
    buf = ""; startln = 0; ctx = "T0"; _ARR_DEPTH = 0; _COND = 0; _ADEPTH = 0
  }
  prevfile = FILENAME
  if (buf == "") startln = FNR
  ctx = _lex_state($0, ctx)
  # A quote still open at the newline holds ONE word across the lines, so
  # the fold continues until it closes. Help text spanning several lines
  # is the ordinary way a shipped script spells its usage, and an inner
  # line of it reads exactly like a call.
  if (_fold_open(ctx)) {
    if (_LEX_CONT) { buf = buf substr($0, 1, length($0) - 1) }
    # A NEWLINE, not a space. Inside a quoted message the newline stays
    # part of the one word either way, but a substitution written over
    # several lines holds several COMMANDS, and a space between them
    # makes the second one an argument of the first.
    else { buf = buf $0 "\n" }
    next
  }
  # A trailing backslash OUTSIDE a comment continues the line, and the
  # halves are joined with NOTHING between them, which is what bash does:
  # a word may be split across the fold and still be one word. A space
  # would turn `split_` + `missing` into two words and hand the body slot
  # a truncated id. Inside a comment there is nothing to continue -- bash
  # ends the comment at the newline -- and folding there would glue the
  # next line of CODE onto a line the tokeniser then discards whole.
  if (_LEX_CONT) { buf = buf substr($0, 1, length($0) - 1); next }
  line = buf $0
  buf = ""
  # Inside an initialiser every line is scanned, call or not: that is
  # where its closing parenthesis is.
  if (_ARR_DEPTH > 0 || _COND > 0 || _candidate(line)) _scan(line, startln)
  next
}
END {
  if (PHASE == "emit") {
    if (buf != "") printf "OPEN" US "%s" US "%d\n", prevfile, startln
    printf "SEEN" US "%d" US "%d\n", direct + 0, wrapped + 0
  }
}
'

# The scanned files, filled by _ler_collect and read by its caller.
# Meaningless before it has run. A GLOBAL rather than stdout for the
# reason drivers/spec_repo_root.sh states at length: a _die inside a
# process substitution refuses a subshell nobody is listening to.
_LER_FILES=()

# _ler_collect
#   Fill _LER_FILES with every *.sh under the shipped roots, sorted.
#   find's status is CAPTURED (the walk writes to a temp file rather than
#   into a pipeline, whose status would belong to `sort`), because a walk
#   that died half way through would otherwise hand the lint a short list
#   and read as "there is less to check". A root that does not exist is
#   skipped rather than fatal; the empty-population check is what refuses
#   a tree where none of them does.
_ler_collect() {
  _LER_FILES=()
  local -a _dirs=()
  local _root
  for _root in "${_LER_ROOTS[@]}"; do
    if [[ -d "${REPO_ROOT}/${_root}" ]]; then
      _dirs+=("${REPO_ROOT}/${_root}")
    fi
  done
  # Spelled as an `if` and not `[[ ... ]] && return 0`, here and below: a
  # false `[[ ]]` is the compound's status, and under the errexit the lint
  # phase runs its drivers with, a trailing `&&` that did not fire is a
  # function returning 1 -- which this caller reads as a FAILED WALK.
  if [[ "${#_dirs[@]}" -eq 0 ]]; then
    return 0
  fi

  local _tmp _st=0
  _tmp="$(mktemp)" || return 1
  find "${_dirs[@]}" -name '*.sh' -type f -print0 > "${_tmp}" || _st=$?
  if [[ "${_st}" -ne 0 ]]; then
    rm -f "${_tmp}"
    return "${_st}"
  fi

  local _file
  while IFS= read -r -d '' _file; do
    _LER_FILES+=("${_file}")
  done < <(sort -z < "${_tmp}")
  rm -f "${_tmp}"
}

# _ler_registry_path <outvar>
#   Resolve the registry file from the population: a scanned file that
#   assigns `_LOG_EVENTS_FILE=<dir>/<name>` names a registry at <name>
#   next to itself. Each distinct resolution THAT EXISTS goes into
#   <outvar>, so the caller can refuse zero and refuse two.
#
#   EXISTENCE IS PART OF THE RULE, not a convenience. The naive rule --
#   every file carrying the assignment names the registry -- resolved to
#   two files the first time it ran, because THIS DRIVER spells
#   `_LOG_EVENTS_FILE=` in the pattern it matches with and is itself in
#   the population. Narrowing the pattern until it stopped seeing itself
#   is the move base#1090 refused twice before changing the rule instead:
#   a registry is a file that is there, so a resolution pointing at
#   nothing is not a candidate. Self-exclusion by name would have been the
#   roster this driver exists to avoid.
_ler_registry_path() {
  local -n _lerrp_out="${1}"
  _lerrp_out=()
  local _file _line _dir _cand
  for _file in "${_LER_FILES[@]}"; do
    while IFS= read -r _line; do
      [[ "${_line}" =~ ${_LER_REGISTRY_ASSIGN_RE} ]] || continue
      _dir="$(dirname -- "${_file}")"
      _cand="${_dir}/${BASH_REMATCH[1]}"
      if [[ -f "${_cand}" ]]; then
        _lerrp_out+=("${_cand}")
      fi
    done < <(grep -h '_LOG_EVENTS_FILE=' "${_file}" 2>/dev/null || true)
  done
  if [[ "${#_lerrp_out[@]}" -gt 1 ]]; then
    mapfile -t _lerrp_out < <(printf '%s\n' "${_lerrp_out[@]}" | sort -u)
  fi
}

_run_log_event_registry() {
  echo "--- Running log event registry lint ---"

  local _find_st=0
  _ler_collect || _find_st=$?
  if [[ "${_find_st}" -ne 0 ]]; then
    _die ci_log_event_registry \
      "the walk for *.sh under ${REPO_ROOT} failed (exit ${_find_st}) -- a scan that could not finish is not a scan that found nothing."
    return 1
  fi
  if [[ "${#_LER_FILES[@]}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "no *.sh under ${_LER_ROOTS[*]} in ${REPO_ROOT} -- a scan with no population is not a pass. This lint derives its population from the tree; an empty one means the shipped scripts moved, not that they emit nothing."
    return 1
  fi

  local -a _registries=()
  _ler_registry_path _registries
  if [[ "${#_registries[@]}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "no file among the ${#_LER_FILES[@]} scanned assigns _LOG_EVENTS_FILE to a path that exists -- the registry's location is read from the tree rather than written down here, so without that assignment there is nothing to compare the emitted ids against and every id would pass."
    return 1
  fi
  if [[ "${#_registries[@]}" -gt 1 ]]; then
    _die ci_log_event_registry \
      "${#_registries[@]} different registry files are implied by _LOG_EVENTS_FILE assignments (${_registries[*]}) -- this lint compares against ONE registry, and picking either would make the other's ids look unregistered."
    return 1
  fi
  local _registry="${_registries[0]}"

  # The allowed set, read the way _log_is_registered reads it: a whole
  # non-comment, non-blank line. Kept as an ASSOCIATIVE ARRAY and not
  # re-grepped per emit site -- the membership test runs once per call
  # site, and `printf '%s\n' "${_registered[@]}" | grep -Fxq` is the
  # early-closing-reader shape this repo has a lint for. That spelling
  # was written here first and the lint caught it: `-q` exits on the
  # match, printf takes SIGPIPE, pipefail promotes the 141 over grep's
  # 0, and a SUCCESSFUL lookup reads as "not registered". Host-direct,
  # with no pipefail, it reported a clean tree; inside the lint phase
  # the same scan reported 29 registered ids as findings.
  # No -f guard: the resolution above only yields a file that exists, so
  # one here would be a branch nothing can take.
  local -a _registered=()
  mapfile -t _registered < <(
    grep -vE '^[[:space:]]*(#|$)' "${_registry}" 2>/dev/null | sort -u
  )
  if [[ "${#_registered[@]}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "the registry ${_registry#"${REPO_ROOT}"/} carries no event id -- an empty registry makes every emitted id unregistered at runtime, so reading it as the allowed set would be reading nothing."
    return 1
  fi
  local -A _registered_set=()
  local _rid
  for _rid in "${_registered[@]}"; do
    _registered_set["${_rid}"]=1
  done

  # Pass one: which function names forward their first positional into a
  # _log_* body slot, and which files define one of those names WITHOUT
  # forwarding (so their own call sites of it mean something else).
  local _defs
  _defs="$(awk -v PHASE=def -v FWDS= -v SHADOWS= "${_LER_AWK}" \
             "${_LER_FILES[@]}")"

  local _fwds _shadows
  _fwds="$(printf '%s\n' "${_defs}" | awk -F'\t' '$1=="FWD"{print $3}' | sort -u)"
  _shadows="$(printf '%s\n' "${_defs}" \
    | awk -F'\t' -v W="${_fwds}" '
        BEGIN { n = split(W, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
        $1 == "PLAIN" && ($3 in w) { print $2 "|" $3 }
      ' | sort -u)"

  # Pass two: the emitted ids, with the call-site counts that say whether
  # the detector read anything at all.
  local _emit
  _emit="$(awk -v PHASE=emit -v FWDS="${_fwds}" -v SHADOWS="${_shadows}" \
             "${_LER_AWK}" "${_LER_FILES[@]}")"

  local _us=$'\037'
  local _seen_line _direct=0 _wrapped=0
  _seen_line="$(printf '%s\n' "${_emit}" \
    | awk -v FS="${_us}" '$1=="SEEN"{print $2" "$3}')"
  read -r _direct _wrapped <<<"${_seen_line:-0 0}"
  if [[ "${_direct:-0}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "no '_log_<level> <service> <body>' call site in any of the ${#_LER_FILES[@]} scanned file(s) -- the detector read nothing, so every id would be registered vacuously. The scan, not the tree, is what to look at: a renamed helper or a changed argument order blinds it exactly this way."
    return 1
  fi

  # The wrapper half, checked AFTER the direct count and not before it: a
  # forwarding definition spells a _log_* call on its own line, so a tree
  # with a wrapper always has at least one direct site and this refusal
  # placed first would make the blind-detector one above unreachable.
  if [[ -z "${_fwds}" ]]; then
    _die ci_log_event_registry \
      "no function in the ${#_LER_FILES[@]} scanned file(s) forwards its first argument into a _log_* body slot -- that shape (script/test/test.sh's _die) is how the lint drivers name their events, and two of base#1220's four unregistered ids were emitted through it. With none found, this lint silently shrinks to the direct call sites."
    return 1
  fi

  # An EIGHTH refusal. A file whose last logical line never closed was
  # read only up to that point, and the rest of it is gone from the
  # population with nothing saying so -- the other files still satisfy
  # every check above, so the clean line reads exactly as it would over
  # a tree that genuinely had less in it.
  local _open
  _open="$(printf '%s\n' "${_emit}" \
    | awk -v FS="${_us}" '$1=="OPEN"{print $2":"$3}' | sort -u | paste -sd' ' -)"
  if [[ -n "${_open}" ]]; then
    _die ci_log_event_registry \
      "${_open} ends with a logical line still open -- an unterminated quote, substitution or backtick. Everything after it was never read, and a scan that stopped part way through a file reports the same clean line as one that read all of it. Close the construct, or if it IS closed, the reader disagrees with the shell about where: that is a defect in this driver, not in the file."
    return 1
  fi

  local -a _rows=()
  local _kind _id _plain _loc _lineno _ids_total=0
  while IFS="${_us}" read -r _kind _id _loc _lineno; do
    [[ "${_kind}" == "ID" ]] || continue
    _ids_total=$(( _ids_total + 1 ))
    # Decoded for the lookup, in the reverse order of the encoding so a
    # literal `%25` in a body cannot be read as an escape.
    _plain="${_id//%09/$'\t'}"
    _plain="${_plain//%0A/$'\n'}"
    _plain="${_plain//%25/%}"
    # An EMPTY body is counted as a site read and NOT checked, because
    # lib/log.sh does not check one: _log_dispatch guards its registry
    # test with a nonempty-body condition, so such a call prints its
    # diagnostic and returns zero. What this lint reports is a body
    # that REPLACES the message, and an empty one does not.
    [[ -n "${_plain}" ]] || continue
    if [[ -z "${_registered_set[${_plain}]:-}" ]]; then
      _rows+=("${_loc#"${REPO_ROOT}"/}:${_lineno}: ${_id}")
    fi
  done < <(printf '%s\n' "${_emit}")

  if [[ "${#_rows[@]}" -gt 0 ]]; then
    printf '%s\n' "${_rows[@]}" | sort -u
    local _distinct
    _distinct="$(printf '%s\n' "${_rows[@]}" | awk '{print $NF}' | sort -u \
                 | paste -sd' ' -)"
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_log_event_registry \
      "${#_rows[@]} emit site(s) name an id the registry does not carry: ${_distinct}. lib/log.sh is STRICT -- it refuses an unregistered body and prints 'FATAL: unregistered log body' INSTEAD of the message, so each of these replaces the diagnostic a user was meant to read with the registry's own complaint, at the moment something had already gone wrong. Add the id to ${_registry#"${REPO_ROOT}"/}, under the section for the file that emits it."
    return 1
  fi

  echo "log event registry lint: clean (${_ids_total} emit site(s)," \
       "${_direct} direct + ${_wrapped} through a wrapper, across" \
       "${#_LER_FILES[@]} *.sh file(s); ${#_registered[@]} id(s) registered)"
}
