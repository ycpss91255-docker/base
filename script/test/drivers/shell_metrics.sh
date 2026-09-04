#!/usr/bin/env bash
# drivers/shell_metrics.sh - ONE shell reader, three implementation-standard
# metric lints: nesting depth, function length, positional parameters
# (base#994 phase 2).
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_nesting_depth, _run_function_length, _run_positional_params (the
# three gates) and _run_shell_metrics (all three in one report, which is
# what `just test metrics` runs).
#
# Contract: runs on the HOST, over a real git checkout. References
# ${REPO_ROOT} (a global exported by test.sh). Follows
# drivers/errexit_bang.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# ── Why one file and not three ───────────────────────────────────────────────
#
# ADR-00000011 sec.5 gives each lint tool its own driver, and three lints
# here have one driver between them. The reason is the rule they share:
# all three are thresholds over the SAME record -- file, function name,
# start line, end line, depth, length, highest positional parameter -- and
# that record comes from one pass of one reader. Three drivers would mean
# either three readers (three answers to "where does a function begin and
# end", which is the drift PRD design principle P4 exists to stop) or one
# reader living in one of them and imported by the other two, which is the
# same file with a worse name. The three `_run_*` entry points below are
# the many entry points P4 asks for; the reader is the one owner.
#
# ── Why this exists at all, and what it is NOT ───────────────────────────────
#
# base#994 measured the tree with an ad-hoc counter and got 44 functions at
# depth >= 4, 151 over 50 lines, 7 over 5 parameters. Those figures set
# the target of phase 3, so a wrong measurement is worse than no
# measurement: it sends the next round of work at code that was never
# defective and leaves the code that is. Three bugs in that counter were
# each found by a FIXTURE rather than by reading it, and each is a case in
# test/bats/unit/shell_metrics_spec.bats:
#
#   1. A shell KEYWORD USED AS AN ARGUMENT closed a block that was still
#      open -- `echo done fi esac` ended three constructs, and every
#      function after it in that file was measured against a corrupt
#      stack. Here `done` / `fi` / `esac` are keywords only in COMMAND
#      POSITION, which is the property bash itself uses.
#   2. DOUBLE-QUOTE SCANNING THAT DID NOT RECURSE INTO `$( )` lost quote
#      state at the command substitution and read an embedded awk program
#      as shell, inventing a depth of 9. It reported
#      `script/test/drivers/coverage_gate.sh::_coverage_gate_run` at depth
#      11 and `self_hosted_guard.sh::flush_if` at depth 10; both figures
#      were artifacts of this and neither function is nested that deep.
#      Here a `$( )` opens a nested command context with its own quote
#      state, its own word buffer and its own command position, so the
#      `'...'` around the awk program is seen and the awk program is never
#      read as shell.
#   3. `$'...'` WITH A BACKSLASH-ESCAPED QUOTE -- the single-quote scanner
#      had no `$'...'` case, so `$'it\'s'` was read as an ordinary
#      single-quoted span that the escaped quote failed to close, and
#      every function below it was silently lost from the count. The tree
#      has live instances (`dist/script/docker/lib/log.sh`,
#      `script/test/sync-doc-counts.sh`).
#
# This is a READER, not a shell. It does no expansion, runs nothing, and
# knows nothing about aliases, `eval` or `source`. It reads far enough to
# answer three questions about static text, and where the text stops
# answering them it REFUSES: a file whose quotes, heredocs or constructs
# do not balance at EOF is a FINDING that fails the lint, and that file's
# records are dropped rather than reported. A metric lint that quietly
# skips a file it could not parse reports a clean tree it never measured.
#
# ── What this reader reports, against what the epic planned for ─────────────
#
# base#994's table is the ad-hoc counter's. This reader disagrees with two
# thirds of it, and the disagreement is the point of building it:
#
#   metric      | epic (ad-hoc) | this reader | why they differ
#   ------------|---------------|-------------|--------------------------------
#   depth > 3   | 44            | 26          | the three bugs above, plus the
#               | (7 at 5,      | (19 at 4,   | case-arm rule below
#               |  1 at 6)      |  7 at 5,    |
#               |               |  0 at 6)    |
#   length > 50 | 151           | 69          | body CODE lines, not the
#               |               |             | brace-to-brace span (106
#               |               |             | functions have a span over 50)
#   params > 5  | 7             | 7           | same count, and the same worst
#               |               |             | case -- compose_emit.sh::
#               |               |             | generate_compose_yaml at 31,
#               |               |             | the figure the epic names.
#               |               |             | The ad-hoc counter's SEVEN
#               |               |             | were never listed, so this is
#               |               |             | agreement on the two figures
#               |               |             | it did publish, not on a set
#
# The parameter column agreeing exactly -- same count, same worst case, same
# function -- is the corroboration that matters, because it is the metric
# neither the parser bugs nor the counting rules move. The depth extreme was
# hand-checked: setup_tui.sh::_edit_section_image reaches 5 at its `for _x`
# (while > for > if > if > for) and nothing in the tree reaches 6. The length
# extreme was hand-checked the same way: setup_cmd.sh::_setup_apply is 315
# body code lines out of a 526-line span, which is what a `grep -vc` of blank
# and comment-only lines over that range independently returns.
#
# Phase 3 works from THESE numbers, and phase 3's slices will therefore be
# smaller than the epic sized them. That is a correction, not a discount: the
# 44 included functions at fictitious depths 11 and 10, and the 151 counted
# this repo's rationale comments as length.
#
# ── The population, and why it is derived ────────────────────────────────────
#
# Every TRACKED file that ends `.sh`, plus every TRACKED extensionless file
# whose first two bytes are `#!`, minus symlinks. Derived from `git
# ls-files`, never listed (PRD design principle P2): the tree has 89 such
# files today across `dist/`, `script/`, `template/` and `dockerfile/`,
# and a roster would be short from the first file added anywhere else.
#
# THIS FILE is one of the 89, and four of its own functions are in the
# report it prints: `_sm_scan_line` at depth 4 and 279 body code lines,
# `_sm_flush_word` at 98, `_sm_read_dollar` at depth 4 and 82,
# `_sm_scan_file` at 65. There is no exemption for it and none is wanted:
# a reader outside its own population is a rule with one case in it, and
# phase 3 owns these four the way it owns the rest.
#
# Tracked, rather than everything `find` turns up, because the untracked
# tree is not ours: `.prev-release/` holds `git archive` copies of
# ALREADY-RELEASED trees (a finding there is unfixable history), and
# `coverage/`, build output and a developer's scratch script are not code
# this repo ships. Symlinks are excluded because they are the SAME file
# read twice -- `script/build.sh` and the six siblings beside it are
# symlinks into `dist/script/docker/wrapper/`, and counting a function
# twice would inflate every figure phase 3 works from.
#
# An extensionless file needs the `#!` because the extensionless tracked
# set is mostly data (`LICENSE`, `Dockerfile`); the shebang is the file
# saying it is a program. It is read from the file's first two BYTES, not
# guessed from the path. There are no such files today, which is exactly
# why the branch is derived rather than assumed away -- the spec covers it
# with a fixture.
#
# A file with a non-`.sh` extension is out of the population even with a
# shebang (`*.bats`, `*.bash`). Bats bodies are not functions in the sense
# these thresholds are about, and `errexit_bang.sh` is the lint that reads
# them.
#
# An EMPTY population is refused, never reported clean (P3). So is a `git`
# that fails: a scan that could not enumerate its own inputs found
# nothing, which is not the same as there being nothing to find.
#
# Because the population comes from the git index, this lint runs
# HOST-DIRECT (`test.sh --nesting-depth-only` and its siblings, or
# `just test metrics`) and is deliberately absent from the in-container
# `--lint` phase: a `git worktree` checkout's `.git` is a FILE pointing at
# a path outside the container's bind mount, so `git ls-files` inside the
# `ci` service fails for exactly the checkouts this repo develops in. The
# lint would refuse rather than pass vacuously, which is correct and
# useless. The CI join is the host-direct primitive, which is what the
# `lint-static` matrix already uses for every pure-bash lint.
#
# ── NOT in the default gate, and what still blocks that ─────────────────────
#
# These three names are deliberately NOT in test.sh's `_LINT_TOOLS`.
# Measured 2026-09-03 (base#994 phase 3, before its first flattening slice):
# 108 violations across 93 files and 803 functions -- 23 over nesting
# depth, 77 over function length, 8 over positional parameters. Phase 2
# reported 102 on a smaller tree; the movement is the tree's, not the
# reader's.
#
# The blocker is no longer "the tree is not clean" -- the adoption
# ceilings below let a lint gate a tree that is still being flattened, and
# they are why the tree does not have to be clean first. What is left is
# structural, and it belongs to phase 4: `_LINT_TOOLS` is run INSIDE the
# ci container, and this lint's population comes from the git index, which
# a `git worktree` checkout cannot serve from inside the bind mount (its
# `.git` is a file pointing at a path outside it). Joining the lint phase
# therefore means giving the phase a host-direct leg, not adding three
# strings to a table. Until then the entry points are `just test metrics`
# and `test.sh --<metric>-only`, which is what CI's lint-static matrix
# already uses for every pure-bash lint.
#
# ── The counting rules ───────────────────────────────────────────────────────
#
# These are DECISIONS, not facts. Each is stated with its reason, because
# a threshold whose measurement nobody can restate is a number people
# argue with instead of a rule they follow.
#
# NESTING DEPTH is the number of enclosing CONTROL constructs, counted
# from the function body as 0. `if` / `for` / `while` / `until` /
# `select` / `case` each add one level; so does a function defined inside
# another function.
#
#   A `case` ARM adds NOTHING, and the `case` itself is the one level.
#   The alternative -- arm as a second level -- penalises `case` against
#   the `if`/`elif` chain it replaces: `if a; then X; elif b; then Y; fi`
#   puts X at depth 1, and the equivalent `case` would put it at 2. A
#   twelve-arm dispatcher is the FLATTEST shape a twelve-way branch has,
#   and a metric that scores it worse than the chain would push the next
#   round of work toward the worse shape. An arm is a branch, like `elif`,
#   and a reader carries one branch context through either.
#
#   A brace GROUP (`{ ...; }`) and a SUBSHELL (`( ... )`) add nothing
#   either. Depth measures the conditions and iterations a reader has to
#   hold; a grouping introduces neither. Both exist for a redirection
#   (`{ ...; } > file`) or to bind an `||`, and the construct written
#   INSIDE one still counts for itself.
#
#   A NESTED FUNCTION DEFINITION does add a level to the enclosing
#   function, and gets a record of its own measured from its own baseline.
#   Its body is a block the outer function's reader must still get past.
#
#   A command substitution is a nested command CONTEXT, and what is
#   written in it counts at the depth where it is written -- `if x; then
#   y=$(for i in a; do ...; done); fi` really is two constructs deep for a
#   reader. What it is NOT is a place where the enclosing function's
#   blocks can be closed: bug 2 above is what happens when the two are
#   confused. That line is a fixture in the spec, not only a sentence
#   here: it was written as the rule's worked example before it could be
#   MEASURED, and the reader dropped the whole file over the `done)`
#   until the `)` handler was made to flush its word before reading the
#   construct stack.
#
#   An ARRAY LITERAL -- a `(` written against a word that ends in `=`,
#   which is `w=( ... )`, `w+=( ... )` and `declare -A m=( [k]=v )` -- is
#   a WORD LIST, not a command context, so nothing written in one counts
#   and nothing written in one can close anything: `w=( if fi )` is a
#   two-element list of the strings "if" and "fi". A `$( )` written as an
#   element is still a command substitution and still counts by the rule
#   above. Reading the literal as a subshell instead put the first
#   element of each of its physical lines in command position, where a
#   keyword pushed a construct -- and while an unbalanced set was a loud
#   finding, a balanced `if` / `fi` pair silently INFLATED the enclosing
#   function's depth. That was the one shape found where this reader
#   produced a wrong NUMBER rather than a finding.
#
# FUNCTION LENGTH is the count of body lines that carry CODE: blank lines,
# comment-only lines and heredoc BODY lines do not count, and neither does
# the header line (`f() {`) nor the line carrying the closing `}` unless
# it also carries body code (which is how a one-line function measures 1).
#
#   Not the brace-to-brace span, and the reason is what a span metric
#   would make the next person do. This repo writes long rationale
#   comments INSIDE functions on purpose -- it is the house style and it
#   is why a reader can follow `errexit_bang.sh` at all -- so a span
#   metric would report the explanation as the defect, and the cheapest
#   way to a green gate would be to delete it. The threshold exists to
#   bound how much BEHAVIOUR one name hides, and a comment is not
#   behaviour. A heredoc body is excluded by the same argument and not a
#   second one: it is literal data, not statements.
#
#   The disagreement this has to survive: a span can be gamed by joining
#   code onto fewer physical lines. It can, and the result is a long line
#   that shellcheck and a reviewer both see; deleting the explanation is
#   the gaming that is INVISIBLE, so the rule closes the invisible door
#   and leaves the visible one. A 200-line heredoc is likewise not made
#   short by this rule, it is judged on its code -- if the heredoc is the
#   problem, that is a different finding than "this function is too long".
#
#   An INNER function's lines DO count toward the outer function's length,
#   as well as toward its own. Excluding them would make "wrap the middle
#   of it in a nested function" a way to shrink a long function for free.
#
# POSITIONAL PARAMETERS is the highest index the function can read:
# max over every `$N` / `${N}` / `${N:-...}` / `${!N}` of that index, plus
# the positions any `shift` before it has already consumed.
#
#   The HIGHEST index, not the count of distinct ones. A function that
#   reads `$1` and `$7` takes seven parameters whether or not it names the
#   five in between; the caller still has to pass them. Counting distinct
#   names would report 2 and let a function with a hole in it hide.
#
#   An unbraced `$N` takes ONE digit, because that is what bash does:
#   `$12` is `${1}2`. A function taking 31 parameters has to write
#   `${31}`, and reading `$31` as index 31 would invent parameters that do
#   not exist.
#
#   `shift` RAISES it. After `shift 2`, the function's `$1` is its third
#   parameter, and a rule that ignored that would report the widest
#   argument-shuffling functions as narrow. The offset accumulates in
#   source order, which is an upper bound where the shift is conditional
#   -- the fail-closed direction, and the direction a threshold wants.
#
#   `$@` / `$*` do NOT raise it, and neither does `$#`. A forwarded
#   argument list is a variadic TAIL, not a fixed parameter: `f "${@}"` is
#   one conceptual argument list however long it is, and counting it as
#   unbounded would make every forwarding wrapper a violation whose only
#   fix is to stop forwarding -- the metric attacking the one shape that
#   was already right.
#
#   That leaves a DISCLOSED BLIND SPOT rather than a silent one: a
#   function that reads everything through `$@` and `shift` inside a loop
#   has no fixed arity for this metric to bound, and the `while [[ $# -gt
#   0 ]]; do ... shift; done` argument parser is exactly that shape. Such
#   a function is marked VARIADIC -- by `$@` / `$*`, by a `shift` with a
#   non-literal count, or by a `shift` inside a loop -- and the count of
#   variadic functions is printed as an advisory on every run, clean or
#   not. It is not an exemption: a variadic function that ALSO names
#   `${7}` is still reported at 7. It is the metric saying which functions
#   it could not bound, which is the difference between a blind spot and a
#   pass.
#
#   The non-literal count is recognised in every spelling it is written
#   in -- `shift $n`, `shift "$n"`, `shift "${n}"`, `shift $(( k ))`. The
#   two QUOTED spellings resolved as a bare `shift` (one position) until
#   the pending count was decided on whether a word was opened rather
#   than on whether it left characters in the buffer, because a
#   fully-quoted word is read entirely by the double-quote scanner and
#   leaves the buffer empty. That direction was UNDER-counting -- a wide
#   argument-shuffling function measured narrow -- which is the one
#   direction a threshold must never err in.

# ── What this reader does NOT model, and which way each errs ─────────────────
#
# Listed with its DIRECTION, because a limitation whose direction is
# unknown is a figure nobody can act on. Every one of these errs toward a
# FINDING -- the file named and dropped -- and none of them can produce a
# measured number that is wrong. The two that are reachable by writing
# ordinary bash are pinned by cases in the spec, so they cannot quietly
# change shape into the other kind.
#
#   - An arithmetic LEFT SHIFT: `$(( 1 << 2 ))` and `(( x <<= 2 ))`. This
#     reader collapses `((` into two nested parens and does not tell
#     arithmetic from a subshell, so the `<<` reads as a heredoc operator
#     and takes `2` for a delimiter. That delimiter never appears, the
#     file ends inside the heredoc, and it is reported unmeasured. The
#     tree has no instance.
#   - A function body that is not `{ ... }` -- `f() ( ... )`, legal bash.
#     The header is reported as one that never opened a body. The tree has
#     no instance.
#   - A legacy BACKTICK command substitution. Reported by name rather than
#     parsed: `$( )` is the form this repo writes, and a second
#     substitution grammar for a shape nothing here uses would be more
#     reader to be wrong in. The tree has none outside comments, quoted
#     spans and heredoc bodies, where they are data.
#   - A `${...}` parameter expansion spanning a line break. The skip that
#     keeps `${x#*)}`'s `)` out of the construct stack reads one line.
#   - `eval`, `source` and aliases, as with every static reader. A
#     function defined inside an `eval` string is not a record here, and
#     no line of it is counted toward anything.

# ── Thresholds ───────────────────────────────────────────────────────────────

# The three implementation standards (base#994). They are constants here and
# not a config surface: a threshold a caller can lower is a threshold.
#
# WHERE EACH NUMBER COMES FROM is not written here. It is PRD invariant 11,
# amended by base#994 phase 3 to cover a magnitude: each value is the lowest one
# that fails no correct function, and the measured distribution that answers
# that question for each metric is in the amendment. A copy of the argument
# beside the constants would be a second place to keep it true
# (ADR-00000028).
readonly _SM_MAX_DEPTH=3
readonly _SM_MAX_LENGTH=50
readonly _SM_MAX_PARAMS=5

# ── The adoption ceilings ────────────────────────────────────────────────────
#
# A THRESHOLD says what the standard is. A CEILING says how much of the
# tree has not been brought to it yet. They are different numbers with
# different rules, and conflating them is how a quality bar becomes a
# record of the worst code in the tree: the threshold above never moves
# to make the tree pass -- that is the whole of ADR-00000029 -- and the
# ceiling below may only ever go DOWN.
#
# Phase 2 measured the tree and left the lints ungated. Phase 3 measured
# it again on arrival -- the figures the ceilings below start from, and
# the same measurement the header quotes above: 108 functions over the
# three thresholds (23 depth, 77 length, 8 parameters, on 803 functions
# across 93 files). Phase 2's own count was 102 on a smaller tree, and
# the difference between them is the tree's movement rather than a
# change of rule; the ceilings are set from the phase-3 figure because
# that is the tree they gate.
#
# Phase 3 is the flattening, and it does not fit in one reviewable PR: a
# single change rewriting 108 functions across the shipped `dist/` tree
# and the test drivers is one nobody can review, which is the shape
# ADR-00000014 rule 3 already refuses for the same reason. So the
# population is closed in slices, and between slices the lint has to be
# able to say something other than "still red".
#
# THIS IS NOT THE BASELINE ADR-00000029 REJECTED, and the difference is
# argued rather than asserted (see that ADR's amendment for base#994). The
# rejected alternative was a hand-kept ROSTER: one entry per violating
# site, which has to be regenerated when a file moves, drifts silently
# against the tree (P2), cannot tell "fixed" from "no longer matches",
# and states the gate as "the standard holds except in these 108 places".
# A ceiling is one integer. It names no site, so it cannot excuse a
# particular function and cannot be individually stale; it cannot be
# wrong about which functions exist, because the count is recomputed from
# the tree on every run; and it has no entries to decay. The person
# ratifies a number the tree computed. It is the same instrument, and the
# same argument, as the transition ceiling in drivers/catalog_description.sh
# (base#999).
#
# THE COST, stated rather than papered over. Slack = ceiling - count. It
# starts at 0 for all three and grows by one each time a function is
# flattened without lowering the ceiling, and within that slack a NEW
# violation can land green. That is a real weakening against a per-site
# baseline, which would have caught it. What bounds it: every run prints
# the census -- count, limit, ceiling, slack -- clean or not, so the slack
# is a visible figure rather than an invisible category, and closing it is
# a one-line PR. Raising a ceiling is one reviewable line, and the policy
# is that it may only go down; that is NOT mechanically enforceable
# without history, and this driver does not pretend otherwise.
#
# Considered and rejected:
#   - per-file ceilings: 93 numbers instead of 3, no decision carried by
#     the split, each acquiring its own slack. That is the roster again
#     with a coarser key.
#   - a ceiling on the WORST value (deepest, longest, widest) instead of
#     the count: it would let 77 functions at 51 lines each land while
#     reporting the tree improved, because the extreme is one function's
#     property and adoption is a population's.
#   - exact equality (fail when count != ceiling): the stronger ratchet,
#     rejected on this repo's own evidence -- five self-declared totals
#     every branch edits caused 61 conflicts in 65 merges
#     (ADR-00000028). Every flattening PR and every new-function PR would
#     edit the same three lines. A ceiling is edited only by a branch
#     that ADDS a violation, which is precisely the branch a reviewer
#     should be looking at.
readonly _SM_DEPTH_CEILING=23
readonly _SM_LENGTH_CEILING=77
readonly _SM_PARAMS_CEILING=5

# ── Reader state ─────────────────────────────────────────────────────────────
#
# The scanner's state is file-scope rather than `local`, and deliberately:
# the character loop hands work to a dozen small helpers (word flush,
# push, pop, parameter note), and threading twenty variables through each
# call by nameref would be a worse file than this one. `_sm_reset_file`
# is the single initialiser, called once per file, so nothing survives
# from the previous file.

# Results, keyed by record index. Parallel arrays rather than one packed
# string per record: a function name and a path are arbitrary text, and a
# delimiter chosen for them is a bug waiting for the first file that
# contains it.
_SM_R_FILE=()
_SM_R_NAME=()
_SM_R_START=()
_SM_R_END=()
_SM_R_DEPTH=()
_SM_R_LEN=()
_SM_R_PARAM=()
_SM_R_VAR=()

_SM_FILES=()
_SM_FINDINGS=()

# Whether the tree has been read, and how many times it actually was.
# The three lints each call _shell_metrics_load and exactly one pass
# happens; the spec asserts the counter to keep that true.
_SHELL_METRICS_LOADED=0
_SHELL_METRICS_PASSES=0

# Per-file scanner state (see _sm_reset_file).
_sm_rel=""
_sm_line=""
_sm_lineno=0
_sm_i=0
_sm_n=0
_sm_q=""
_sm_prev=""
_sm_word=""
_sm_wplain=1
_sm_wopen=0
_sm_cmdpos=1
_sm_intest=0
_sm_cont=0
_sm_bad=0
_sm_hd=""
_sm_hdq=0
_sm_hds=0
_sm_pendfn=""
_sm_pendfn_line=0
_sm_expectname=0
_sm_shiftpend=0
_sm_patstart=0
_sm_count=0
_sm_allflagged=0
_sm_first_code=-1
_sm_wstart=0
_sm_kind=()
_sm_cmode=()
_sm_hd_pend=()
_sm_hdq_pend=()
_sm_hds_pend=()
_sm_sv_word=()
_sm_sv_wplain=()
_sm_sv_wopen=()
_sm_sv_cmdpos=()
_sm_sv_intest=()
_sm_sv_q=()
_sm_fn_name=()
_sm_fn_start=()
_sm_fn_base=()
_sm_fn_dep=()
_sm_fn_len=()
_sm_fn_par=()
_sm_fn_sh=()
_sm_fn_var=()
_sm_fn_flag=()
_sm_fn_sidx=()

_sm_reset_file() {
  _sm_rel="${1}"
  _sm_line=""
  _sm_lineno=0
  _sm_i=0
  _sm_n=0
  _sm_q=""
  _sm_prev=""
  _sm_word=""
  _sm_wplain=1
  _sm_wopen=0
  _sm_cmdpos=1
  _sm_intest=0
  _sm_cont=0
  _sm_bad=0
  _sm_hd=""
  _sm_hdq=0
  _sm_hds=0
  _sm_pendfn=""
  _sm_pendfn_line=0
  _sm_expectname=0
  _sm_shiftpend=0
  _sm_patstart=0
  _sm_count=0
  _sm_allflagged=0
  _sm_first_code=-1
  _sm_wstart=0
  _sm_kind=()
  _sm_cmode=()
  _sm_hd_pend=()
  _sm_hdq_pend=()
  _sm_hds_pend=()
  _sm_sv_word=()
  _sm_sv_wplain=()
  _sm_sv_wopen=()
  _sm_sv_cmdpos=()
  _sm_sv_intest=()
  _sm_sv_q=()
  _sm_fn_name=()
  _sm_fn_start=()
  _sm_fn_base=()
  _sm_fn_dep=()
  _sm_fn_len=()
  _sm_fn_par=()
  _sm_fn_sh=()
  _sm_fn_var=()
  _sm_fn_flag=()
  _sm_fn_sidx=()
}

# _sm_finding <message> -- record a place the reader could not answer for,
# and mark the file unmeasured. Never a silent skip.
_sm_finding() {
  _SM_FINDINGS+=("${_sm_rel}:${_sm_lineno}: ${1}")
  _sm_bad=1
}

# ── The construct stack ──────────────────────────────────────────────────────
#
# Kinds: IF LOOP CASE FUNC (counting) / BRACE SUBSHELL CMDSUB ARRAY
# PATPAREN (structural only). `_sm_count` is the number of counting
# entries, which is the absolute depth; a function's depth is that minus
# the count at its own opening brace.

_sm_push() {
  local _k="${1}" _f _rel
  _sm_kind+=("${_k}")
  _sm_cmode+=(0)
  case "${_k}" in
    IF|LOOP|CASE|FUNC)
      _sm_count=$(( _sm_count + 1 ))
      for (( _f = 0; _f < ${#_sm_fn_name[@]}; _f++ )); do
        _rel=$(( _sm_count - _sm_fn_base[_f] ))
        if (( _rel > _sm_fn_dep[_f] )); then
          _sm_fn_dep[_f]="${_rel}"
        fi
      done
      ;;
  esac
}

# _sm_pop <expected-kind> <spelling> -- close the innermost construct.
# A mismatch is a finding: the stack this reader keeps is the only thing
# telling it where a function ends, so a wrong pop corrupts every record
# after it in the file.
_sm_pop() {
  local _want="${1}" _spell="${2}" _idx _top
  _idx=$(( ${#_sm_kind[@]} - 1 ))
  if (( _idx < 0 )); then
    _sm_finding "'${_spell}' closes a construct that was never opened"
    return 1
  fi
  _top="${_sm_kind[_idx]}"
  if [[ "${_top}" != "${_want}" ]]; then
    _sm_finding "'${_spell}' closes a ${_want}, but the innermost open construct is a ${_top}"
    return 1
  fi
  unset '_sm_kind[_idx]' '_sm_cmode[_idx]'
  case "${_want}" in
    IF|LOOP|CASE|FUNC) _sm_count=$(( _sm_count - 1 )) ;;
  esac
  return 0
}

# ── Function frames ──────────────────────────────────────────────────────────

_sm_open_fn() {
  local _name="${1}" _start="${2}"
  _sm_push FUNC
  _sm_fn_name+=("${_name}")
  _sm_fn_start+=("${_start}")
  _sm_fn_base+=("${_sm_count}")
  _sm_fn_dep+=(0)
  _sm_fn_len+=(0)
  _sm_fn_par+=(0)
  _sm_fn_sh+=(0)
  _sm_fn_var+=(0)
  _sm_fn_flag+=(0)
  _sm_fn_sidx+=($(( ${#_sm_kind[@]} - 1 )))
  # The new frame has seen no code on this line yet.
  _sm_allflagged=0
}

_sm_close_fn() {
  local _k=$(( ${#_sm_fn_name[@]} - 1 ))
  (( _k < 0 )) && return 0
  # A closing brace that shares its line with body code (the one-line
  # function, `f() { echo hi; }`) still owes that line to the body; a `}`
  # alone on its line does not, which is what "excluding the closing
  # brace" means. The two are told apart by WHERE the line's first code
  # character sat: in front of this `}` word, or at it.
  if [[ "${_sm_fn_flag[_k]}" -eq 1 ]] && (( _sm_first_code < _sm_wstart )); then
    _sm_fn_len[_k]=$(( _sm_fn_len[_k] + 1 ))
  fi
  _SM_R_FILE+=("${_sm_rel}")
  _SM_R_NAME+=("${_sm_fn_name[_k]}")
  _SM_R_START+=("${_sm_fn_start[_k]}")
  _SM_R_END+=("${_sm_lineno}")
  _SM_R_DEPTH+=("${_sm_fn_dep[_k]}")
  _SM_R_LEN+=("${_sm_fn_len[_k]}")
  _SM_R_PARAM+=("${_sm_fn_par[_k]}")
  _SM_R_VAR+=("${_sm_fn_var[_k]}")
  unset '_sm_fn_name[_k]' '_sm_fn_start[_k]' '_sm_fn_base[_k]' \
        '_sm_fn_dep[_k]' '_sm_fn_len[_k]' '_sm_fn_par[_k]' \
        '_sm_fn_sh[_k]' '_sm_fn_var[_k]' '_sm_fn_flag[_k]' \
        '_sm_fn_sidx[_k]'
  _sm_allflagged=0
}

# _sm_note_param <index> -- the INNERMOST open function reads that
# positional parameter; a nested function's `$1` is its own, never the
# enclosing one's.
_sm_note_param() {
  local _k=$(( ${#_sm_fn_name[@]} - 1 )) _cand
  (( _k < 0 )) && return 0
  _cand=$(( _sm_fn_sh[_k] + ${1} ))
  if (( _cand > _sm_fn_par[_k] )); then
    _sm_fn_par[_k]="${_cand}"
  fi
}

_sm_note_variadic() {
  local _k=$(( ${#_sm_fn_name[@]} - 1 ))
  (( _k < 0 )) && return 0
  _sm_fn_var[_k]=1
}

# _sm_note_code -- a code character was consumed; every open function owes
# this physical line to its body. Guarded by `_sm_allflagged` so the
# common case costs one comparison per character rather than a loop.
_sm_note_code() {
  local _f
  (( _sm_first_code < 0 )) && _sm_first_code="${_sm_i}"
  (( _sm_allflagged == 1 )) && return 0
  for (( _f = 0; _f < ${#_sm_fn_name[@]}; _f++ )); do
    _sm_fn_flag[_f]=1
  done
  _sm_allflagged=1
}

# ── Words and keywords ───────────────────────────────────────────────────────

# _sm_shift_resolve <literal-or-empty> -- close out a pending `shift`.
# An empty argument is the bare `shift` (one position); a literal integer
# is that many; anything else is a count this reader cannot bound, which
# makes the function variadic rather than mis-measured.
_sm_shift_resolve() {
  local _arg="${1}" _mode="${_sm_shiftpend}" _k=$(( ${#_sm_fn_name[@]} - 1 ))
  _sm_shiftpend=0
  (( _k < 0 )) && return 0
  # Mode 2: the `shift` is inside a loop, so how many positions it
  # consumes has no static answer. The function is already marked
  # variadic; the offset deliberately stops accumulating, because adding
  # one per textual `shift` would report an argument PARSER as taking
  # fifty-six parameters -- a number about the loop's source text rather
  # than about the function's arity.
  (( _mode == 2 )) && return 0
  if [[ -z "${_arg}" ]]; then
    _sm_fn_sh[_k]=$(( _sm_fn_sh[_k] + 1 ))
  elif [[ "${_arg}" =~ ^[0-9]+$ ]]; then
    _sm_fn_sh[_k]=$(( _sm_fn_sh[_k] + _arg ))
  else
    _sm_fn_var[_k]=1
  fi
}

# _sm_shift_in_loop -- is the `shift` just read inside a loop within the
# innermost function? A loop makes the consumed count unbounded, which is
# the one shape the running offset cannot describe.
_sm_shift_in_loop() {
  local _k=$(( ${#_sm_fn_name[@]} - 1 )) _s _idx
  (( _k < 0 )) && return 1
  _s="${_sm_fn_sidx[_k]}"
  for _idx in "${!_sm_kind[@]}"; do
    (( _idx <= _s )) && continue
    [[ "${_sm_kind[_idx]}" == "LOOP" ]] && return 0
  done
  return 1
}

# _sm_flush_word -- end the word under construction and act on it. This is
# where a token becomes a keyword, a function name, a `shift` or a case
# pattern, and it is the ONLY place that decides any of those.
_sm_flush_word() {
  local _w="${_sm_word}" _plain="${_sm_wplain}" _open="${_sm_wopen}"
  _sm_word=""
  _sm_wplain=1
  _sm_wopen=0

  # A pending `shift` takes this word as its count. Decided on whether a
  # word was OPENED, not on whether it left characters in the buffer:
  # `shift "$n"` and `shift "${n}"` are read entirely by the
  # double-quote scanner, which appends nothing, so an empty-word return
  # here would let the pending shift survive to `_sm_separator` and
  # resolve as a BARE `shift` -- one position, and a function that
  # reshuffles an unbounded argument list measured as narrow. That is the
  # UNDER-counting direction, which is the direction a threshold must not
  # err in. A shift with no word after it at all still resolves as bare,
  # because nothing opened a word.
  if (( _sm_shiftpend != 0 )) && (( _open == 1 )); then
    if [[ "${_plain}" -eq 1 ]]; then
      _sm_shift_resolve "${_w}"
    else
      _sm_shift_resolve "?"
    fi
    return 0
  fi

  [[ -z "${_w}" ]] && return 0

  # `function <name>` -- the name is a word, not a keyword.
  if (( _sm_expectname == 1 )); then
    _sm_expectname=0
    _sm_pendfn="${_w}"
    _sm_pendfn_line="${_sm_lineno}"
    _sm_cmdpos=1
    return 0
  fi

  # Inside `[[ ... ]]` every word is an operand; only `]]` is syntax.
  if (( _sm_intest == 1 )); then
    [[ "${_w}" == "]]" && "${_plain}" -eq 1 ]] && _sm_intest=0
    return 0
  fi

  # `in` opens the pattern list of the `case` just read. It is recognised
  # by that pending CASE and NOT by command position: the word in front of
  # it is the case's subject, so the reader is never in command position
  # when it arrives. In `for x in ...` the innermost construct is the
  # LOOP, which is why the same word is an ordinary one there.
  if [[ "${_w}" == "in" && "${_plain}" -eq 1 ]]; then
    local _cidx=$(( ${#_sm_kind[@]} - 1 ))
    if (( _cidx >= 0 )) && [[ "${_sm_kind[_cidx]}" == "CASE" ]] \
       && [[ "${_sm_cmode[_cidx]}" -eq 0 ]]; then
      _sm_cmode[_cidx]=1
      _sm_patstart=1
      _sm_cmdpos=0
      return 0
    fi
  fi

  # A case PATTERN. `esac` is the one word read as syntax here (an empty
  # `case x in esac`, and every arm boundary lands back in this state).
  if _sm_in_pattern; then
    if [[ "${_w}" == "esac" && "${_plain}" -eq 1 ]]; then
      _sm_pop CASE 'esac' || return 0
      _sm_cmdpos=0
    fi
    _sm_patstart=0
    return 0
  fi

  if (( _sm_cmdpos == 1 && _plain == 1 )); then
    case "${_w}" in
      'if')     _sm_push IF;   _sm_cmdpos=1; return 0 ;;
      'elif')   _sm_cmdpos=1; return 0 ;;
      'then'|'else'|'do') _sm_cmdpos=1; return 0 ;;
      'fi')     _sm_pop IF 'fi'   || true; _sm_cmdpos=0; return 0 ;;
      'done')   _sm_pop LOOP 'done' || true; _sm_cmdpos=0; return 0 ;;
      'esac')   _sm_pop CASE 'esac' || true; _sm_cmdpos=0; return 0 ;;
      'while'|'until') _sm_push LOOP; _sm_cmdpos=1; return 0 ;;
      'for'|'select')  _sm_push LOOP; _sm_cmdpos=0; return 0 ;;
      'case')   _sm_push CASE; _sm_cmdpos=0; return 0 ;;
      '!'|'time'|'coproc') _sm_cmdpos=1; return 0 ;;
      'function') _sm_expectname=1; return 0 ;;
      '[[')   _sm_intest=1; _sm_cmdpos=0; return 0 ;;
      '{')
        if [[ -n "${_sm_pendfn}" ]]; then
          _sm_open_fn "${_sm_pendfn}" "${_sm_pendfn_line}"
          _sm_pendfn=""
        else
          _sm_push BRACE
        fi
        _sm_cmdpos=1
        return 0
        ;;
      '}')
        local _ti=$(( ${#_sm_kind[@]} - 1 )) _t=""
        (( _ti >= 0 )) && _t="${_sm_kind[_ti]}"
        if [[ "${_t}" == "FUNC" ]]; then
          _sm_close_fn
          _sm_pop FUNC '}' || true
        else
          _sm_pop BRACE '}' || true
        fi
        _sm_cmdpos=0
        return 0
        ;;
      'shift')
        if _sm_shift_in_loop; then
          _sm_note_variadic
          _sm_shiftpend=2
        else
          _sm_shiftpend=1
        fi
        _sm_cmdpos=0
        return 0
        ;;
    esac
    # A word in command position that is not a keyword. If a function
    # header was waiting for its body, this is not one.
    if [[ -n "${_sm_pendfn}" ]]; then
      _sm_finding "function '${_sm_pendfn}' (line ${_sm_pendfn_line}) has a body this reader does not read; only a '{ ... }' body is supported"
      _sm_pendfn=""
    fi
    _sm_cmdpos=0
    return 0
  fi

  _sm_cmdpos=0
  return 0
}

# _sm_in_pattern -- is the reader between `case ... in` (or a `;;`) and
# the `)` that opens an arm body?
_sm_in_pattern() {
  local _idx=$(( ${#_sm_kind[@]} - 1 ))
  (( _idx < 0 )) && return 1
  [[ "${_sm_kind[_idx]}" == "CASE" && "${_sm_cmode[_idx]}" -eq 1 ]]
}

# _sm_separator -- a `;`, `&`, `|`, `)` or end of line ended a command.
# A bare `shift` that never got an argument consumed one position.
_sm_separator() {
  (( _sm_shiftpend != 0 )) && _sm_shift_resolve ""
  return 0
}

# ── Nested command contexts ──────────────────────────────────────────────────
#
# `$( )` and `( )` open a command context of their own: its own quote
# state, its own word, its own command position. Saving and restoring them
# is bug 2's fix -- a `"` inside a command substitution inside a
# double-quoted string is a FRESH quote, and a scanner that does not model
# that reads the rest of the file inverted.

_sm_enter_paren() {
  local _kind="${1}"
  _sm_push "${_kind}"
  _sm_sv_word+=("${_sm_word}")
  _sm_sv_wplain+=("${_sm_wplain}")
  _sm_sv_wopen+=("${_sm_wopen}")
  _sm_sv_cmdpos+=("${_sm_cmdpos}")
  _sm_sv_intest+=("${_sm_intest}")
  _sm_sv_q+=("${_sm_q}")
  _sm_word=""
  _sm_wplain=1
  _sm_wopen=0
  # An ARRAY literal is a word list, so its contents are never in
  # command position; `$( )` and `( )` are command contexts and are.
  if [[ "${_kind}" == "ARRAY" ]]; then
    _sm_cmdpos=0
  else
    _sm_cmdpos=1
  fi
  _sm_intest=0
  _sm_q=""
}

# _sm_in_array -- is the reader inside an array literal `w=( ... )`?
# What is written there is DATA: `w=( if fi )` is a two-element list of
# the strings "if" and "fi", not a construct. A `$( )` written as an
# element opens a command context of its own and sits above this one, so
# this asks about the INNERMOST construct only.
#
# It is asked in exactly ONE place -- the start-of-line reset in
# `_sm_scan_line`; `_sm_enter_paren` above reads the kind it was handed
# instead. Command POSITION is the single mechanism, and those two are
# its two halves: a reader that is never in command position inside a
# literal cannot read an element as a keyword and cannot read one as a
# function header either. A second guard at the keyword table would be
# unfalsifiable, because every way to reach it (`w=( a; b )`,
# `w=( a|b )`, `w=( f() )`) is a bash SYNTAX ERROR and so cannot be
# written as a fixture.
_sm_in_array() {
  local _idx=$(( ${#_sm_kind[@]} - 1 ))
  (( _idx < 0 )) && return 1
  [[ "${_sm_kind[_idx]}" == "ARRAY" ]]
}

_sm_leave_paren() {
  local _k=$(( ${#_sm_sv_word[@]} - 1 ))
  (( _k < 0 )) && return 0
  _sm_word="${_sm_sv_word[_k]}"
  _sm_wplain="${_sm_sv_wplain[_k]}"
  # The surrounding word continues past the `)`.
  _sm_wopen=1
  _sm_cmdpos="${_sm_sv_cmdpos[_k]}"
  _sm_intest="${_sm_sv_intest[_k]}"
  _sm_q="${_sm_sv_q[_k]}"
  unset '_sm_sv_word[_k]' '_sm_sv_wplain[_k]' '_sm_sv_wopen[_k]' \
        '_sm_sv_cmdpos[_k]' '_sm_sv_intest[_k]' '_sm_sv_q[_k]'
}

# ── Parameter references ─────────────────────────────────────────────────────

# _sm_read_dollar -- the reader is at a `$`. Note any positional
# parameter it introduces and leave `_sm_i` past what was consumed.
# Called from unquoted text and from inside a double-quoted span, which
# are the two places bash expands one.
_sm_read_dollar() {
  local _nx="${_sm_line:_sm_i+1:1}" _j _ch _depth _digits
  case "${_nx}" in
    '(')
      _sm_i=$(( _sm_i + 2 ))
      _sm_enter_paren CMDSUB
      return 0
      ;;
    '{')
      _sm_i=$(( _sm_i + 2 ))
      _j="${_sm_i}"
      # `${!N}` reads through the Nth parameter, so it reads it.
      [[ "${_sm_line:_j:1}" == '!' ]] && _j=$(( _j + 1 ))
      _ch="${_sm_line:_j:1}"
      if [[ "${_ch}" == '@' || "${_ch}" == '*' ]]; then
        _sm_note_variadic
      elif [[ "${_ch}" =~ ^[0-9]$ ]]; then
        _digits=""
        while [[ "${_sm_line:_j:1}" =~ ^[0-9]$ ]]; do
          _digits+="${_sm_line:_j:1}"
          _j=$(( _j + 1 ))
        done
        [[ "${_digits}" != "0" ]] && _sm_note_param "$(( 10#${_digits} ))"
      fi
      # Skip to the matching `}`. A parameter expansion can hold a `)`
      # (`${x#*)}`) or a quote, and reading either as this statement's
      # would corrupt the stack.
      _depth=1
      while (( _sm_i < _sm_n )); do
        _ch="${_sm_line:_sm_i:1}"
        case "${_ch}" in
          \\) _sm_i=$(( _sm_i + 1 )) ;;
          "'") _sm_i=$(( _sm_i + 1 ))
               while (( _sm_i < _sm_n )) && [[ "${_sm_line:_sm_i:1}" != "'" ]]; do
                 _sm_i=$(( _sm_i + 1 ))
               done
               ;;
          '"') _sm_i=$(( _sm_i + 1 ))
               while (( _sm_i < _sm_n )) && [[ "${_sm_line:_sm_i:1}" != '"' ]]; do
                 [[ "${_sm_line:_sm_i:1}" == "\\" ]] && _sm_i=$(( _sm_i + 1 ))
                 _sm_i=$(( _sm_i + 1 ))
               done
               ;;
          '{') _depth=$(( _depth + 1 )) ;;
          '}') _depth=$(( _depth - 1 ))
               if (( _depth == 0 )); then
                 _sm_i=$(( _sm_i + 1 ))
                 return 0
               fi
               ;;
        esac
        _sm_i=$(( _sm_i + 1 ))
      done
      _sm_finding "a '\${...}' parameter expansion is not closed on its own line; this reader does not follow one across a line break"
      return 0
      ;;
    [0-9])
      # Unbraced takes ONE digit: bash reads `$12` as `${1}2`.
      [[ "${_nx}" != "0" ]] && _sm_note_param "${_nx}"
      _sm_i=$(( _sm_i + 2 ))
      return 0
      ;;
    '@'|'*')
      _sm_note_variadic
      _sm_i=$(( _sm_i + 2 ))
      return 0
      ;;
    "'")
      if [[ -z "${_sm_q}" ]]; then
        # ANSI-C quoting. Inside a double-quoted span this is a literal
        # `$` followed by a quote character, which is why it is gated.
        _sm_q="A"
        _sm_i=$(( _sm_i + 2 ))
        return 0
      fi
      _sm_i=$(( _sm_i + 1 ))
      return 0
      ;;
    '"')
      if [[ -z "${_sm_q}" ]]; then
        _sm_q="D"
        _sm_i=$(( _sm_i + 2 ))
        return 0
      fi
      _sm_i=$(( _sm_i + 1 ))
      return 0
      ;;
  esac
  _sm_i=$(( _sm_i + 1 ))
  return 0
}

# _sm_scan_params_raw <text> -- positional parameters in text this reader
# treats as data but bash still expands: the body of a heredoc whose
# delimiter is unquoted. Counted, because they really are read.
_sm_scan_params_raw() {
  local _t="${1}"
  local _rest="${_t}"
  while [[ "${_rest}" =~ \$\{?\!?([0-9]+) ]]; do
    _sm_note_param "$(( 10#${BASH_REMATCH[1]} ))"
    _rest="${_rest#*"${BASH_REMATCH[0]}"}"
  done
  if [[ "${_t}" =~ \$\{?[@*] ]]; then
    _sm_note_variadic
  fi
}

# ── Heredocs ─────────────────────────────────────────────────────────────────

# _sm_read_heredoc_op -- the reader is at `<<`. Queue the delimiter; the
# body starts on the next physical line. `<<<` is a here-string and opens
# nothing.
_sm_read_heredoc_op() {
  local _j _strip=0 _quoted=0 _delim="" _ch
  if [[ "${_sm_line:_sm_i+2:1}" == '<' ]]; then
    _sm_i=$(( _sm_i + 3 ))
    return 0
  fi
  _j=$(( _sm_i + 2 ))
  if [[ "${_sm_line:_j:1}" == '-' ]]; then
    _strip=1
    _j=$(( _j + 1 ))
  fi
  while [[ "${_sm_line:_j:1}" == ' ' || "${_sm_line:_j:1}" == $'\t' ]]; do
    _j=$(( _j + 1 ))
  done
  while (( _j < _sm_n )); do
    _ch="${_sm_line:_j:1}"
    case "${_ch}" in
      "'"|'"')
        _quoted=1
        _j=$(( _j + 1 ))
        while (( _j < _sm_n )) && [[ "${_sm_line:_j:1}" != "${_ch}" ]]; do
          _delim+="${_sm_line:_j:1}"
          _j=$(( _j + 1 ))
        done
        _j=$(( _j + 1 ))
        ;;
      \\)
        _quoted=1
        _j=$(( _j + 1 ))
        _delim+="${_sm_line:_j:1}"
        _j=$(( _j + 1 ))
        ;;
      ' '|$'\t'|';'|'&'|'|'|'<'|'>'|'(' |')')
        break
        ;;
      *)
        _delim+="${_ch}"
        _j=$(( _j + 1 ))
        ;;
    esac
  done
  if [[ -z "${_delim}" ]]; then
    _sm_finding "a heredoc operator with no delimiter"
    _sm_i="${_j}"
    return 0
  fi
  _sm_hd_pend+=("${_delim}")
  _sm_hdq_pend+=("${_quoted}")
  _sm_hds_pend+=("${_strip}")
  _sm_i="${_j}"
  return 0
}

# ── The character loop ───────────────────────────────────────────────────────

# _sm_scan_line -- read one physical line, carrying every piece of state
# from the line before it. Quotes, heredocs, `\` continuations and open
# constructs all span lines, so nothing here is decided per line except
# where a comment may start.
_sm_scan_line() {
  local _c _nx
  _sm_n="${#_sm_line}"
  _sm_i=0
  _sm_first_code=-1

  # A new physical line starts a new command -- unless the reader is
  # mid-continuation, mid-quote, mid case-pattern, or inside an ARRAY
  # literal, whose every line carries elements rather than commands.
  # Resetting inside one is what let `w=(` / newline / `if` read the
  # first element of each line as a keyword: an unbalanced set was a loud
  # finding, but a balanced `if` / `fi` pair silently INFLATED the
  # function's depth, which is the one way this reader was found to
  # produce a wrong number with nothing printed.
  if (( _sm_cont == 0 )) && [[ -z "${_sm_q}" ]]; then
    if ! _sm_in_pattern && ! _sm_in_array; then
      _sm_cmdpos=1
    fi
  fi
  _sm_cont=0

  while (( _sm_i < _sm_n )); do
    _c="${_sm_line:_sm_i:1}"

    # ── inside a quoted span ────────────────────────────────────────────
    if [[ "${_sm_q}" == "S" ]]; then
      (( _sm_allflagged == 1 )) || _sm_note_code
      [[ "${_c}" == "'" ]] && _sm_q=""
      _sm_i=$(( _sm_i + 1 ))
      continue
    fi
    if [[ "${_sm_q}" == "A" ]]; then
      (( _sm_allflagged == 1 )) || _sm_note_code
      if [[ "${_c}" == "\\" ]]; then
        _sm_i=$(( _sm_i + 2 ))
        continue
      fi
      [[ "${_c}" == "'" ]] && _sm_q=""
      _sm_i=$(( _sm_i + 1 ))
      continue
    fi
    if [[ "${_sm_q}" == "D" ]]; then
      (( _sm_allflagged == 1 )) || _sm_note_code
      case "${_c}" in
        \\)
          if (( _sm_i + 1 >= _sm_n )); then
            _sm_cont=1
            _sm_i=$(( _sm_i + 1 ))
          else
            _sm_i=$(( _sm_i + 2 ))
          fi
          continue
          ;;
        '"') _sm_q=""; _sm_i=$(( _sm_i + 1 )); continue ;;
        '$') _sm_read_dollar; continue ;;
        '`')
          _sm_finding "a legacy backtick command substitution; this reader reads only \$( ... )"
          _sm_i=$(( _sm_i + 1 ))
          continue
          ;;
        *) _sm_i=$(( _sm_i + 1 )); continue ;;
      esac
    fi

    # ── unquoted ────────────────────────────────────────────────────────
    #
    # Blanks and a comment are decided FIRST, before the line is credited
    # with code: a comment-only line is not a body line, and crediting it
    # would make `length` the brace-to-brace span this file's header
    # explicitly declines to measure.
    case "${_c}" in
      ' '|$'\t')
        _sm_flush_word
        _sm_i=$(( _sm_i + 1 ))
        continue
        ;;
      '#')
        if (( _sm_wopen == 0 )); then
          # A comment runs to end of line. It is not code and never
          # closes anything -- `# ... fi` is prose.
          _sm_i="${_sm_n}"
          continue
        fi
        ;;
    esac
    (( _sm_allflagged == 1 )) || _sm_note_code

    case "${_c}" in
      \\)
        if (( _sm_i + 1 >= _sm_n )); then
          _sm_cont=1
          _sm_i=$(( _sm_i + 1 ))
        else
          _sm_word+="${_sm_line:_sm_i+1:1}"
          _sm_wplain=0
          (( _sm_wopen == 1 )) || _sm_wstart="${_sm_i}"
          _sm_wopen=1
          _sm_i=$(( _sm_i + 2 ))
        fi
        _sm_prev=$'\\'
        continue
        ;;
      "'")
        _sm_q="S"
        _sm_wplain=0
        (( _sm_wopen == 1 )) || _sm_wstart="${_sm_i}"
        _sm_wopen=1
        _sm_i=$(( _sm_i + 1 ))
        _sm_prev="'"
        continue
        ;;
      '"')
        _sm_q="D"
        _sm_wplain=0
        (( _sm_wopen == 1 )) || _sm_wstart="${_sm_i}"
        _sm_wopen=1
        _sm_i=$(( _sm_i + 1 ))
        _sm_prev='"'
        continue
        ;;
      '`')
        _sm_finding "a legacy backtick command substitution; this reader reads only \$( ... )"
        _sm_i=$(( _sm_i + 1 ))
        continue
        ;;
      '#')
        # Reached only mid-word, where a `#` is data (`B#note`).
        _sm_word+='#'
        _sm_i=$(( _sm_i + 1 ))
        _sm_prev='#'
        continue
        ;;
      '$')
        _sm_wplain=0
        (( _sm_wopen == 1 )) || _sm_wstart="${_sm_i}"
        _sm_wopen=1
        _sm_read_dollar
        _sm_prev='$'
        continue
        ;;
      ';')
        _sm_flush_word
        _sm_separator
        _nx="${_sm_line:_sm_i+1:1}"
        if [[ "${_nx}" == ';' || "${_nx}" == '&' ]]; then
          # `;;`, `;&`, `;;&` -- an arm boundary, back to pattern state.
          if [[ "${_nx}" == ';' ]]; then
            _sm_i=$(( _sm_i + 2 ))
            [[ "${_sm_line:_sm_i:1}" == '&' ]] && _sm_i=$(( _sm_i + 1 ))
          else
            _sm_i=$(( _sm_i + 2 ))
          fi
          local _idx=$(( ${#_sm_kind[@]} - 1 ))
          if (( _idx >= 0 )) && [[ "${_sm_kind[_idx]}" == "CASE" ]]; then
            _sm_cmode[_idx]=1
            _sm_patstart=1
          fi
          _sm_cmdpos=0
          _sm_prev=';'
          continue
        fi
        _sm_i=$(( _sm_i + 1 ))
        _sm_cmdpos=1
        _sm_prev=';'
        continue
        ;;
      '&')
        _nx="${_sm_line:_sm_i+1:1}"
        if [[ "${_nx}" == '&' ]]; then
          _sm_flush_word
          _sm_separator
          _sm_i=$(( _sm_i + 2 ))
          _sm_cmdpos=1
        elif [[ "${_nx}" == '>' || "${_sm_prev}" == '>' || "${_sm_prev}" == '<' ]]; then
          # `&>`, `>&`, `<&` are redirections, not the async operator.
          _sm_flush_word
          _sm_i=$(( _sm_i + 1 ))
        else
          _sm_flush_word
          _sm_separator
          _sm_i=$(( _sm_i + 1 ))
          _sm_cmdpos=1
        fi
        _sm_prev='&'
        continue
        ;;
      '|')
        _sm_flush_word
        if _sm_in_pattern; then
          # Alternation inside a case pattern, not a pipe.
          _sm_i=$(( _sm_i + 1 ))
          _sm_patstart=1
          _sm_prev='|'
          continue
        fi
        _sm_separator
        _nx="${_sm_line:_sm_i+1:1}"
        if [[ "${_nx}" == '|' || "${_nx}" == '&' ]]; then
          _sm_i=$(( _sm_i + 2 ))
        else
          _sm_i=$(( _sm_i + 1 ))
        fi
        _sm_cmdpos=1
        _sm_prev='|'
        continue
        ;;
      '<')
        if [[ "${_sm_line:_sm_i+1:1}" == '<' ]]; then
          _sm_flush_word
          _sm_read_heredoc_op
          _sm_prev='<'
          continue
        fi
        _sm_flush_word
        _sm_i=$(( _sm_i + 1 ))
        _sm_prev='<'
        continue
        ;;
      '>')
        _sm_flush_word
        _sm_i=$(( _sm_i + 1 ))
        [[ "${_sm_line:_sm_i:1}" == '>' ]] && _sm_i=$(( _sm_i + 1 ))
        _sm_prev='>'
        continue
        ;;
      '(')
        if (( _sm_intest == 1 )); then
          # Grouping inside `[[ ... ]]`; balanced by the `)` below.
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev='('
          continue
        fi
        if _sm_in_pattern && (( _sm_patstart == 1 && _sm_wopen == 0 )); then
          # The optional `(` of `(a|b)`; the pattern's own `)` closes it.
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev='('
          continue
        fi
        if _sm_in_pattern; then
          # An extglob group inside a pattern -- `*(a|b)` -- whose `)` is
          # its own, not the pattern's.
          _sm_push PATPAREN
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev='('
          continue
        fi
        # A `(` against a word that ends in `=` opens an ARRAY literal
        # (`w=(`, `w+=(`, `declare -A m=(`), not a subshell. It is the
        # same `=` that keeps `_seen=()` from being read as a function
        # definition below; a subshell never has one, because a word and
        # a `(` with nothing between them is an assignment or a header.
        if (( _sm_wopen == 1 )) && [[ "${_sm_word}" == *= ]]; then
          _sm_flush_word
          _sm_enter_paren ARRAY
        else
          _sm_flush_word
          _sm_enter_paren SUBSHELL
        fi
        _sm_i=$(( _sm_i + 1 ))
        _sm_prev='('
        continue
        ;;
      ')')
        # Inside `[[ ... ]]` a paren is grouping and the stack knows
        # nothing about it, so that is decided before anything else.
        if (( _sm_intest == 1 )); then
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev=')'
          continue
        fi
        local _ti=$(( ${#_sm_kind[@]} - 1 )) _t=""
        (( _ti >= 0 )) && _t="${_sm_kind[_ti]}"
        # An extglob group inside a case pattern is closed by its own
        # `)` and carries no word to flush: the pattern text around it
        # is one word that continues past this character.
        if [[ "${_t}" == "PATPAREN" ]]; then
          _sm_pop PATPAREN ')' || true
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev=')'
          continue
        fi
        # THE WORD IS FLUSHED BEFORE THE STACK TOP IS READ, and the top
        # re-read after. A keyword that closes a construct opened inside
        # this substitution sits immediately against the paren --
        # `$(for i in a; do ...; done)`, the header's own worked example
        # for the command-substitution rule -- and reading the top first
        # reads the LOOP the keyword is about to close rather than the
        # CMDSUB the paren closes. That made the paren close nothing and
        # took the rest of the file's construct balance with it, so the
        # stated rule could not be measured at all. One space before the
        # `)` always worked, which is what makes this an ordering defect
        # and not a limit on what the reader models.
        _sm_flush_word
        _ti=$(( ${#_sm_kind[@]} - 1 ))
        _t=""
        (( _ti >= 0 )) && _t="${_sm_kind[_ti]}"
        if [[ "${_t}" == "CMDSUB" || "${_t}" == "SUBSHELL" || "${_t}" == "ARRAY" ]]; then
          _sm_separator
          _sm_pop "${_t}" ')' || true
          _sm_leave_paren
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev=')'
          continue
        fi
        if _sm_in_pattern; then
          local _idx=$(( ${#_sm_kind[@]} - 1 ))
          _sm_cmode[_idx]=2
          _sm_cmdpos=1
          _sm_i=$(( _sm_i + 1 ))
          _sm_prev=')'
          continue
        fi
        _sm_separator
        _sm_finding "a ')' that closes nothing this reader opened"
        _sm_i=$(( _sm_i + 1 ))
        _sm_prev=')'
        continue
        ;;
    esac

    # An ordinary word character. A `(` immediately after a word in
    # command position is a function definition -- `f()`, `f ()`,
    # `function f ()` -- unless the word cannot be a function NAME, which
    # is what keeps `_seen=()` an array assignment.
    _sm_word+="${_c}"
    (( _sm_wopen == 1 )) || _sm_wstart="${_sm_i}"
    _sm_wopen=1
    _sm_prev="${_c}"
    _sm_i=$(( _sm_i + 1 ))
    if (( _sm_cmdpos == 1 )) && ! _sm_in_pattern && (( _sm_intest == 0 )); then
      _sm_maybe_function_header
    fi
  done

  _sm_flush_word
  _sm_separator
  return 0
}

# _sm_maybe_function_header -- called after each word character consumed
# in command position. Looks ahead for the `()` that makes the word a
# function name, consuming it when found.
_sm_maybe_function_header() {
  local _j="${_sm_i}"
  # Only when the word ENDS here: `f(` has the `(` next, `f ()` a blank.
  while [[ "${_sm_line:_j:1}" == ' ' || "${_sm_line:_j:1}" == $'\t' ]]; do
    _j=$(( _j + 1 ))
  done
  [[ "${_sm_line:_j:1}" == '(' ]] || return 0
  _j=$(( _j + 1 ))
  while [[ "${_sm_line:_j:1}" == ' ' || "${_sm_line:_j:1}" == $'\t' ]]; do
    _j=$(( _j + 1 ))
  done
  [[ "${_sm_line:_j:1}" == ')' ]] || return 0
  # A function name is a plain word with no assignment in it. `_seen=()`
  # and `_files+=()` are array assignments, and reading either as a
  # definition would invent a function and lose the file's brace balance.
  [[ "${_sm_wplain}" -eq 1 ]] || return 0
  [[ "${_sm_word}" == *=* ]] && return 0
  [[ "${_sm_word}" == *'!'* ]] && return 0
  # A header still waiting for its body when a second one arrives means
  # the first one never got a `{`. Reported rather than overwritten: a
  # silent overwrite is how a mis-read header (an array assignment taken
  # for a definition, say) disappears without the file ever failing.
  if [[ -n "${_sm_pendfn}" ]]; then
    _sm_finding "function '${_sm_pendfn}' (line ${_sm_pendfn_line}) never opened a body"
  fi
  _sm_pendfn="${_sm_word}"
  _sm_pendfn_line="${_sm_lineno}"
  _sm_expectname=0
  _sm_word=""
  _sm_wplain=1
  _sm_wopen=0
  _sm_i=$(( _j + 1 ))
  _sm_cmdpos=1
  return 0
}

# ── One file ─────────────────────────────────────────────────────────────────

_sm_scan_file() {
  local _abs="${1}" _rel="${2}"
  local _mark="${#_SM_R_FILE[@]}"
  local _findmark="${#_SM_FINDINGS[@]}"
  local _raw _cmp _f _k

  _sm_reset_file "${_rel}"

  if [[ ! -r "${_abs}" ]]; then
    _sm_finding "in the git index but not readable here, so it was NOT measured"
    return 0
  fi

  while IFS= read -r _raw || [[ -n "${_raw}" ]]; do
    _sm_lineno=$(( _sm_lineno + 1 ))
    # CRLF: the carriage return is line terminator, not code. Left in, it
    # would end every heredoc delimiter comparison in the wrong place and
    # append itself to the last word of every line.
    _sm_line="${_raw%$'\r'}"

    if [[ -n "${_sm_hd}" ]]; then
      _cmp="${_sm_line}"
      if (( _sm_hds == 1 )); then
        _cmp="${_cmp#"${_cmp%%[!$'\t']*}"}"
      fi
      if [[ "${_cmp}" == "${_sm_hd}" ]]; then
        _sm_hd=""
        _sm_hdq=0
        _sm_hds=0
        _sm_open_pending_heredoc
      elif (( _sm_hdq == 0 )); then
        # An unquoted delimiter means the body is expanded, so a `${3}`
        # in it really is read.
        _sm_scan_params_raw "${_sm_line}"
      fi
      continue
    fi

    _sm_scan_line
    _sm_open_pending_heredoc

    # Every open function owes this line to its body if code was seen on
    # it while the function was open.
    for (( _f = 0; _f < ${#_sm_fn_name[@]}; _f++ )); do
      if [[ "${_sm_fn_flag[_f]}" -eq 1 ]]; then
        _sm_fn_len[_f]=$(( _sm_fn_len[_f] + 1 ))
        _sm_fn_flag[_f]=0
      fi
    done
    _sm_allflagged=0
  done < "${_abs}"

  # ── end of file: what is still open is what could not be read ────────
  if [[ -n "${_sm_q}" ]]; then
    _sm_finding "the file ends inside an unterminated quote"
  fi
  if [[ -n "${_sm_hd}" ]]; then
    _sm_finding "the file ends inside a heredoc whose delimiter '${_sm_hd}' never appeared"
  fi
  if [[ -n "${_sm_pendfn}" ]]; then
    _sm_finding "function '${_sm_pendfn}' (line ${_sm_pendfn_line}) never opened a body"
  fi
  if (( ${#_sm_kind[@]} > 0 )); then
    local -a _open=()
    for _k in "${!_sm_kind[@]}"; do
      _open+=("${_sm_kind[_k]}")
    done
    _sm_finding "the file ends with ${#_open[@]} construct(s) still open (${_open[*]})"
  fi

  if (( _sm_bad == 1 )); then
    # A file the reader could not finish is a file it did not measure.
    # Its records are dropped rather than reported: a wrong number is
    # worse than a missing one, because phase 3 works from these.
    _SM_R_FILE=("${_SM_R_FILE[@]:0:_mark}")
    _SM_R_NAME=("${_SM_R_NAME[@]:0:_mark}")
    _SM_R_START=("${_SM_R_START[@]:0:_mark}")
    _SM_R_END=("${_SM_R_END[@]:0:_mark}")
    _SM_R_DEPTH=("${_SM_R_DEPTH[@]:0:_mark}")
    _SM_R_LEN=("${_SM_R_LEN[@]:0:_mark}")
    _SM_R_PARAM=("${_SM_R_PARAM[@]:0:_mark}")
    _SM_R_VAR=("${_SM_R_VAR[@]:0:_mark}")
    _SM_FINDINGS+=("${_rel}: could not be parsed, so it was NOT measured (see the $(( ${#_SM_FINDINGS[@]} - _findmark )) line(s) above)")
  fi
  return 0
}

_sm_open_pending_heredoc() {
  [[ -n "${_sm_hd}" ]] && return 0
  (( ${#_sm_hd_pend[@]} == 0 )) && return 0
  _sm_hd="${_sm_hd_pend[0]}"
  _sm_hdq="${_sm_hdq_pend[0]}"
  _sm_hds="${_sm_hds_pend[0]}"
  _sm_hd_pend=("${_sm_hd_pend[@]:1}")
  _sm_hdq_pend=("${_sm_hdq_pend[@]:1}")
  _sm_hds_pend=("${_sm_hds_pend[@]:1}")
  return 0
}

# ── Population ───────────────────────────────────────────────────────────────

# _shell_metrics_collect <array-name> -- the derived population. Returns
# non-zero if git could not answer; an empty answer is the caller's to
# refuse.
_shell_metrics_collect() {
  local -n _smc_out="${1}"
  local _tmp _st=0 _meta _path _base
  _tmp="$(mktemp)" || return 1
  git -C "${REPO_ROOT}" ls-files -s -z > "${_tmp}" 2>/dev/null || _st=$?
  if (( _st != 0 )); then
    rm -f "${_tmp}"
    return "${_st}"
  fi
  while IFS= read -r -d '' _meta; do
    # `<mode> <sha> <stage>\t<path>`
    _path="${_meta#*$'\t'}"
    _meta="${_meta%%$'\t'*}"
    # A symlink is the same file read twice; `dist/` is where it lives.
    [[ "${_meta}" == 120000\ * ]] && continue
    _base="${_path##*/}"
    if [[ "${_path}" == *.sh ]]; then
      _smc_out+=("${_path}")
      continue
    fi
    [[ "${_base}" == *.* ]] && continue
    if [[ ! -r "${REPO_ROOT}/${_path}" ]]; then
      # Whether this tracked file is a program is a question about its
      # first two bytes, and they could not be read. Skipping it would
      # decide the question by not asking it.
      _SM_FINDINGS+=("${_path}: tracked and extensionless, but unreadable, so this reader cannot tell whether it is a program")
      continue
    fi
    [[ "$(head -c 2 -- "${REPO_ROOT}/${_path}" 2>/dev/null)" == '#!' ]] \
      && _smc_out+=("${_path}")
  done < "${_tmp}"
  rm -f "${_tmp}"
  return 0
}

# ── The one pass ─────────────────────────────────────────────────────────────

# _shell_metrics_load -- read the tree once and memoise. The three lints
# each call this and exactly one pass happens, which is what makes them
# three outputs of one reader rather than three scanners.
_shell_metrics_load() {
  (( _SHELL_METRICS_LOADED == 1 )) && return 0

  local -a _files=()
  local _st=0
  _shell_metrics_collect _files || _st=$?
  if (( _st != 0 )); then
    _die ci_shell_metrics \
      "could not enumerate the tracked files under ${REPO_ROOT} (git exit ${_st}). These lints derive their population from the git index and run host-direct; a scan that could not list its own inputs found nothing, which is not the same as there being nothing to find."
    return 1
  fi
  if (( ${#_files[@]} == 0 )); then
    _die ci_shell_metrics \
      "no shell file in the population under ${REPO_ROOT}: no tracked '*.sh' and no tracked extensionless file starting '#!' (symlinks excluded). An empty population is refused, not reported clean -- it means the tree moved, not that it is measured."
    return 1
  fi

  _SM_FILES=("${_files[@]}")
  _SM_R_FILE=(); _SM_R_NAME=(); _SM_R_START=(); _SM_R_END=()
  _SM_R_DEPTH=(); _SM_R_LEN=(); _SM_R_PARAM=(); _SM_R_VAR=()
  _SM_FINDINGS=()

  local _rel
  for _rel in "${_files[@]}"; do
    _sm_scan_file "${REPO_ROOT}/${_rel}" "${_rel}"
  done
  _SHELL_METRICS_PASSES=$(( _SHELL_METRICS_PASSES + 1 ))

  if (( ${#_SM_FINDINGS[@]} > 0 )); then
    local _f
    for _f in "${_SM_FINDINGS[@]}"; do
      printf 'shell metrics: %s\n' "${_f}"
    done
    _die ci_shell_metrics \
      "${#_SM_FINDINGS[@]} finding(s): the reader could not parse the file(s) named above, so they were NOT measured. A metric lint that silently skips a file it cannot read reports a clean tree it never looked at. Fix the shape, or extend the reader in script/test/drivers/shell_metrics.sh (and add the fixture first)."
    return 1
  fi

  _SHELL_METRICS_LOADED=1
  return 0
}

# ── Record accessors (the spec's window on the reader) ───────────────────────

_shell_metrics_files() {
  local _f
  for _f in "${_SM_FILES[@]}"; do
    printf '%s\n' "${_f}"
  done
}

_shell_metrics_names() {
  local _i
  for (( _i = 0; _i < ${#_SM_R_NAME[@]}; _i++ )); do
    printf '%s\n' "${_SM_R_NAME[_i]}"
  done
}

# _shell_metrics_field <function-name> <field> -- one measured field of
# one record. Fields: file name start end depth length params variadic.
_shell_metrics_field() {
  local _name="${1}" _field="${2}" _i
  for (( _i = 0; _i < ${#_SM_R_NAME[@]}; _i++ )); do
    [[ "${_SM_R_NAME[_i]}" == "${_name}" ]] || continue
    case "${_field}" in
      file)     printf '%s\n' "${_SM_R_FILE[_i]}" ;;
      name)     printf '%s\n' "${_SM_R_NAME[_i]}" ;;
      start)    printf '%s\n' "${_SM_R_START[_i]}" ;;
      end)      printf '%s\n' "${_SM_R_END[_i]}" ;;
      depth)    printf '%s\n' "${_SM_R_DEPTH[_i]}" ;;
      length)   printf '%s\n' "${_SM_R_LEN[_i]}" ;;
      params)   printf '%s\n' "${_SM_R_PARAM[_i]}" ;;
      variadic) printf '%s\n' "${_SM_R_VAR[_i]}" ;;
      *) return 2 ;;
    esac
    return 0
  done
  return 1
}

# ── The three thresholds ─────────────────────────────────────────────────────

# _shell_metrics_violations <metric> <limit> <rows-array> -- the ONE
# threshold implementation. Every lint below is this call with different
# arguments, which is what keeps them from disagreeing about what a
# violation is.
_shell_metrics_violations() {
  local _metric="${1}" _limit="${2}"
  local -n _smv_rows="${3}"
  local _i _val
  for (( _i = 0; _i < ${#_SM_R_NAME[@]}; _i++ )); do
    case "${_metric}" in
      depth)  _val="${_SM_R_DEPTH[_i]}" ;;
      length) _val="${_SM_R_LEN[_i]}" ;;
      params) _val="${_SM_R_PARAM[_i]}" ;;
      *) return 2 ;;
    esac
    (( _val > _limit )) || continue
    _smv_rows+=("${_SM_R_FILE[_i]}:${_SM_R_START[_i]}: ${_SM_R_NAME[_i]} -- ${_metric} ${_val} (limit ${_limit})")
  done
  return 0
}

_sm_variadic_count() {
  local _i _n=0
  for (( _i = 0; _i < ${#_SM_R_VAR[@]}; _i++ )); do
    [[ "${_SM_R_VAR[_i]}" -eq 1 ]] && _n=$(( _n + 1 ))
  done
  printf '%s' "${_n}"
}

# _sm_metric_facts <metric> -- the threshold, the adoption ceiling, the
# human label and the die event of one metric, tab separated in that
# order. The ONE place a metric name is matched to the constants that
# bound it (P4): the three gates and the combined report all read it, so
# a fourth caller cannot invent a fourth pairing.
_sm_metric_facts() {
  case "${1}" in
    depth)
      printf '%s\t%s\t%s\t%s' "${_SM_MAX_DEPTH}" "${_SM_DEPTH_CEILING}" \
        'nesting depth' 'ci_nesting_depth' ;;
    length)
      printf '%s\t%s\t%s\t%s' "${_SM_MAX_LENGTH}" "${_SM_LENGTH_CEILING}" \
        'function length' 'ci_function_length' ;;
    params)
      printf '%s\t%s\t%s\t%s' "${_SM_MAX_PARAMS}" "${_SM_PARAMS_CEILING}" \
        'positional parameters' 'ci_positional_params' ;;
    *) return 2 ;;
  esac
}

# _sm_census <label> <count> <limit> <ceiling> -- the one line every run
# prints, clean or not. Slack is the room a new violation could land in
# green (see the ceiling header); a cost nobody can see is one nobody
# closes, so it is printed rather than computed on request.
_sm_census() {
  local _label="${1}" _count="${2}" _limit="${3}" _ceiling="${4}"
  if (( _count == 0 )); then
    printf '%s lint: clean (%s function(s) in %s shell file(s), limit %s, ceiling %s, slack %s)\n' \
      "${_label}" "${#_SM_R_NAME[@]}" "${#_SM_FILES[@]}" "${_limit}" \
      "${_ceiling}" "${_ceiling}"
    return 0
  fi
  printf '%s lint: %s function(s) over the limit of %s (%s function(s) in %s shell file(s), ceiling %s, slack %s)\n' \
    "${_label}" "${_count}" "${_limit}" "${#_SM_R_NAME[@]}" \
    "${#_SM_FILES[@]}" "${_ceiling}" "$(( _ceiling - _count ))"
}

# _sm_gate <metric> <remedy> -- the shared body of the three lints. Every
# function past the THRESHOLD is printed, sorted, whatever the verdict --
# those rows are the worklist phase 3 works from, and a report that
# appeared only on failure would leave the slices with nothing to read.
# The VERDICT is the adoption CEILING.
_sm_gate() {
  local _metric="${1}" _remedy="${2}"
  local _facts _limit _ceiling _label _event
  if ! _facts="$(_sm_metric_facts "${_metric}")"; then
    _die ci_shell_metrics "unknown metric '${_metric}'"
    return 1
  fi
  IFS=$'\t' read -r _limit _ceiling _label _event <<<"${_facts}"

  local -a _rows=()
  _shell_metrics_violations "${_metric}" "${_limit}" _rows
  local _row
  for _row in ${_rows[@]+"${_rows[@]}"}; do
    printf '%s lint: %s\n' "${_label}" "${_row}"
  done
  _sm_census "${_label}" "${#_rows[@]}" "${_limit}" "${_ceiling}"

  if (( ${#_rows[@]} > _ceiling )); then
    _die "${_event}" \
      "${#_rows[@]} function(s) over the ${_label} limit of ${_limit}, against an adoption ceiling of ${_ceiling} (across ${#_SM_FILES[@]} shell file(s) / ${#_SM_R_NAME[@]} function(s)). The ceiling is the population #994 phase 3 has not flattened yet and it may only ever go DOWN: if this change added a function past the limit, split it rather than raising the number. ${_remedy}"
    return 1
  fi
  return 0
}

_run_nesting_depth() {
  echo "--- Running nesting depth lint ---"
  _shell_metrics_load || return 1
  _sm_gate depth \
    "Depth is what happens when the guard clause at the top was not written (PRD design principle P1, ADR-00000029): validate, reject, return, and the body that is left is one level shallower. A 'case' arm and a brace group add no level here, so a reported depth is real nesting."
}

_run_function_length() {
  echo "--- Running function length lint ---"
  _shell_metrics_load || return 1
  _sm_gate length \
    "Length here counts BODY CODE lines only -- blank lines, comment lines and heredoc bodies are already excluded -- so a reported figure is that many statements under one name. Split it at the seam its guard clauses already suggest."
}

_run_positional_params() {
  echo "--- Running positional parameter lint ---"
  _shell_metrics_load || return 1
  local _var
  _var="$(_sm_variadic_count)"
  printf 'positional parameters: advisory: %s function(s) are variadic ("$@" / "$*", or a shift this reader cannot bound); their arity is not bounded by this metric\n' \
    "${_var}"
  _sm_gate params \
    "The figure is the highest index the function can reach, shift offsets included. Past five, pass a record instead of a position: an options struct, an associative array, or a smaller function."
}

# _run_shell_metrics -- all three, in one report, without stopping at the
# first. This is what `just test metrics` runs and what phase 3 works
# from: a report that stopped at the first metric would hide two thirds of
# the tree's state behind whichever lint happened to run first.
#
# It judges by the same three ceilings the individual gates do, and fails
# when ANY metric is past its own. Judging the sum against a sum would let
# a slice that flattened ten long functions pay for a new one at depth 5.
_run_shell_metrics() {
  echo "--- Running shell implementation-standard metrics (nesting depth, function length, positional parameters) ---"
  _shell_metrics_load || return 1

  local _metric _facts _limit _ceiling _label _row
  local _total=0 _over=0
  local -a _rows=()
  for _metric in depth length params; do
    _facts="$(_sm_metric_facts "${_metric}")"
    IFS=$'\t' read -r _limit _ceiling _label _ <<<"${_facts}"
    _rows=()
    _shell_metrics_violations "${_metric}" "${_limit}" _rows
    printf '\n== %s > %s (ceiling %s) ==\n' "${_label}" "${_limit}" "${_ceiling}"
    for _row in ${_rows[@]+"${_rows[@]}"}; do printf '%s\n' "${_row}"; done
    _sm_census "${_label}" "${#_rows[@]}" "${_limit}" "${_ceiling}"
    _total=$(( _total + ${#_rows[@]} ))
    (( ${#_rows[@]} > _ceiling )) && _over=$(( _over + 1 ))
  done

  printf '\n%s shell file(s), %s function(s), %s variadic; %s function(s) over an implementation standard, %s metric(s) past their adoption ceiling\n' \
    "${#_SM_FILES[@]}" "${#_SM_R_NAME[@]}" "$(_sm_variadic_count)" \
    "${_total}" "${_over}"

  if (( _over > 0 )); then
    _die ci_shell_metrics \
      "${_over} metric(s) past their adoption ceiling, ${_total} violation(s) in total across ${#_SM_FILES[@]} shell file(s). The ceilings are the population #994 phase 3 has not flattened yet and they may only ever go DOWN."
    return 1
  fi
  if (( _total > 0 )); then
    printf 'shell implementation-standard metrics: %s violation(s), all within the adoption ceilings (#994 phase 3 is still flattening them)\n' \
      "${_total}"
    return 0
  fi
  echo "shell implementation-standard metrics: clean"
  return 0
}
