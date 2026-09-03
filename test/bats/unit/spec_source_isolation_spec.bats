#!/usr/bin/env bats
#
# One repo-wide invariant over test/bats/: a spec may READ the live
# checkout -- that is where its subject lives -- but it may not settle an
# assertion by COMPARING against it.
#
# Why the population is drawn that way. Two specs lost a race against their
# own suite and cost two or three full gate runs per landed branch. The
# obvious framing -- "audit every spec that touches /source" -- is not
# actionable: all but a handful of the specs reference /source -- 125 of the
# 129 spec files, measured 2026-08-31 -- because that is where the script
# under test, the tracked workflow being asserted on, and the real tree the
# "clean today" guards lint all live. A read of the subject is the point of
# a unit test, not a defect.
#
# That pair of figures is stated twice, here and in doc/test/unit.md, and
# nothing derives one from the other: the derived-figures lint pins two
# named constants read back out of the code that defines them, over the
# prose surfaces a maintainer navigates by (README.md, CONTEXT.md, the
# localized READMEs, dist/**/*.sh), and doc/test/ is not one of them. Both
# copies carry the date so a difference reads as drift rather than as a
# rounding; teaching the lint a third figure is a change to that lint, not
# to this file.
#
# What separates the defect from the population is OWNERSHIP of the answer.
# `diff -r /source/doc/readme "${SCRATCH}/doc/readme"` asked the generator a
# question and then let a tree the spec does not own supply half the answer;
# the suite runs 32-way parallel, often beside another checkout's gate, so
# anything writing there in the window flipped the verdict on correct code.
# Both sides of a comparison have to be bytes the spec captured itself.
#
# ── Why this file no longer scans for WRITES ──────────────────────────────
#
# It used to carry a second invariant: no spec writes into the live tree.
# That one was a roster. It enumerated the commands a write can be spelled
# with -- rm / mv / cp / ln / tee / dd / sed / a redirection -- and every
# review of it found another spelling it CLAIMED and could not see: a third
# operand of `mv` or `install`, `dd`'s `of=PATH` (which the operand rule
# could never match, so naming `dd` was a claim that could not fire),
# `rsync` in no pattern at all, a trailing comment defeating the cp / ln end
# anchor. It also fired on `install` READING out of the live tree. Three
# rounds, three widenings, another spelling each time.
#
# The property has an executed form with no roster: script/test/test.sh
# snapshots the checkout either side of the bats phase and fails naming any
# path that differs (`_residue_snapshot` / `_residue_check`, covered by
# test/bats/unit/residue_guard_spec.bats). Whatever wrote, however it was
# spelled -- through an alias, a subshell, a driver, a tool this repo has
# never heard of -- the bytes moved and the snapshot moved with them. It
# cannot false-positive on the suite's own setup either, which is what made
# the cp / ln half of the old rule delicate: reading the live tree leaves
# nothing behind. So the scan was deleted rather than widened a fourth
# time, and what replaced it is strictly wider on every spelling but one.
#
# That one: a spec that writes into the checkout and removes its own traces
# before the phase ends is invisible to the snapshot. The scan could not see
# it reliably either -- it missed six spellings outright -- so nothing was
# traded away, but it is the residual gap, and closing it means snapshotting
# per SPEC rather than per run.
#
# ── Why the COMPARISON scan stays, and exactly what it is worth ───────────
#
# Because the residue check cannot subsume it. A comparison against the live
# tree leaves no trace: the spec reads, decides, and the checkout is byte-
# identical afterwards. There is nothing for an executed snapshot to find,
# and the failure is not residue at all -- it is a verdict half of which
# somebody else wrote. A static scan is the only shape that can see that
# before it costs a gate run.
#
# WHAT IT IS NOT IS A CLOSED SET, and two rounds of this header said it was.
# The argument ran: the deleted write roster enumerated the commands that
# can write, which is every binary that exists, while this enumerates the
# places a shell can begin a command, which is the shell's finite grammar.
# The POSITION axis really is derivable that way and its positions are taken
# from the grammar -- but the scan has two more axes and both of them are
# rosters. It matches two command NAMES, and it matches the live path as the
# first or the second WORD after a run of flags -- which is NOT the same as
# the first or the second operand, and the difference is a spelling it
# misses. A review planted eighteen comparison spellings and sixteen went
# unseen: a checksum pair, a comparison driven through git, an equality test
# over two command substitutions, a live path that is the second operand of
# a comparison and its third word, because an option ahead of it took an
# argument of its own. None of those is exotic, and no derivation reaches
# them.
#
# So the claim is the narrow one the body can carry: an OVER-APPROXIMATION
# that catches the COMMON spellings at the moment the line is written, and
# names the line. Over- in the other direction too, on purpose -- two live
# paths compared against each other are flagged as well.
#
# WHAT ACTUALLY HOLDS THE LINE, since this does not. For the WRITE property
# there is an executed gate with no roster in it: script/test/test.sh
# snapshots the checkout either side of the bats phase and names any path
# that differs, whatever wrote it and however it was spelled. The comparison
# property has no such backstop -- that is the whole reason a scan is still
# here -- so what stands behind it is the discipline it is a reminder of:
# settle a verdict on bytes the spec captured itself. A spelling this scan
# misses costs what the defect it was written for cost: a verdict flipped by
# a concurrent writer, and a gate re-run until it went green.
#
# Which is why the disclosure may not be a word wider than the body. A
# reader who believes a scan is complete stops looking. What it misses is
# sampled instead, one per axis, in the case named "the comparison scan is
# an over-approximation, not a closed set" -- and those samples are examples
# drawn from an OPEN set, not the set.
#
# Why a spec and not a lint driver: test.sh's _LINT_TOOLS table is asserted
# by self_test_yaml_spec to have a CI job per entry, so a driver costs a
# workflow edit for a scan that the bats gate already runs everywhere. The
# sibling spec_subject_guard_spec.bats set that precedent.
#
# The invariant has the failure mode it is looking for, so it pins the scan
# as well as the result: the spec population may not fall below a floor, and
# grep's status must be exactly 1 (scanned, matched nothing) -- never 2
# (could not scan), which `assert_failure` would have accepted. A separate
# case proves a scan of nothing answers 2, and another proves each spelling
# the pattern claims to see is actually seen.
#
# why: One repo-wide invariant over `test/bats/`: a spec may READ the live
# checkout -- that is where its subject lives -- but may not settle an
# assertion by COMPARING against it. "Every spec that touches `/source`" is
# not the population: 125 of the 129 spec files reference it (measured
# 2026-08-31; the same figures are stated in the spec's own header, and a
# drift between them is drift, not a rounding). What separates the defect is
# who owns the answer, and by that measure a live path as a comparison
# operand had exactly one instance -- the `readme_sync` case that failed
# five gate runs.
#
# This file used to carry a second invariant, a scan for WRITES into the
# live tree, and it is gone. That one was a roster of the commands a write
# can be spelled with, and three consecutive reviews each found another
# spelling it CLAIMED and could not see (a third operand of `mv` or
# `install`, `dd`'s `of=PATH`, `rsync` in no pattern at all) plus one it
# flagged for merely READING. Its property now has an executed form with no
# roster and no false positives: `script/test/test.sh` snapshots the
# checkout either side of the bats phase and fails naming any path that
# differs -- see `residue_guard_spec.bats`. The one spelling the snapshot
# cannot see is a spec that writes and then removes its own traces, and the
# scan could not see that reliably either.
#
# The comparison scan stays because the snapshot cannot subsume it: a
# comparison against the live tree leaves NOTHING behind, so there is no
# residue to find. What it is NOT is a closed set, and two rounds of this
# file's header said it was. That argument -- the write roster enumerated
# the commands that can write, which is every binary that exists, while this
# enumerates the places a shell can begin a command, which is the shell's
# finite grammar -- holds for the POSITION axis alone. The scan has two more
# axes and both are rosters: it matches two command NAMES, and the live path
# as the first or second WORD after a run of flags -- not the first or
# second OPERAND, which is a spelling it misses. A review planted 18
# comparison spellings and 16 went unseen -- a checksum pair, a comparison
# driven through git, an equality test over two command substitutions, a
# live path that is the second operand of a comparison and its third word
# because an option ahead of it took an argument of its own. One derivable
# position is unscanned by choice as well: a backtick, because every line
# the one-character widening that sees it matched was this repo's own
# comment prose and no command at all (three of them when re-measured
# 2026-09-01).
#
# So the claim is the narrow one the body can carry: an over-approximation
# that catches the COMMON spellings at the moment the line is written, and
# names the line. Nothing executed stands behind it -- the residue guard
# holds the WRITE property with no roster at all, and the comparison
# property has no such backstop -- which is the reason not to overstate the
# scan rather than a reason to widen it. What it misses is sampled, one per
# axis, in a case of its own, so a later widening is a decision stated there
# and not a silent edit to a regex. Like its sibling
# `spec_subject_guard_spec.bats`, it pins the scan as well as the result: a
# population floor, `find` under `pipefail`, and grep status exactly 1
# (scanned, no match) rather than 2 (could not scan).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The live checkout, as every spec sees it inside the ci container. Held
  # in a variable rather than written into the pattern below so that no
  # line of THIS file -- which lives under the tree the scan reads -- can
  # match and fail the invariant on its own source.
  LIVE_TREE=/source

  # Where the scan looks, and the floor the population may not fall below.
  SPEC_TREE="${LIVE_TREE}/test/bats"
  SPEC_TREE_FLOOR=100

  # A command POSITION, derived from the shell grammar rather than listed by
  # taste. Requiring one is what keeps a verb quoted inside somebody else's
  # grep pattern out of the scan -- four such lines matched before this was
  # added, and an invariant that cries wolf four times is one that gets
  # deleted. Listing them by taste is what made the scan blind to six
  # spellings it named, so the set is now the grammar's:
  #
  #   - the start of a line;
  #   - after a separator or opener: `;` `&` `|` `&&` `||` `(` `{`;
  #   - after a reserved word that is FOLLOWED BY A COMMAND: `if` `elif`
  #     `while` `until` `then` `else` `do` `time`. The other reserved words
  #     either take a word rather than a command (`case` `for` `in`
  #     `select` `function`) or close a construct (`fi` `done` `esac` `}`);
  #   - after a negating `!`, which may follow any of the above;
  #   - after bats' own `run`, with any run of its flags.
  #
  # One position the grammar has and this set deliberately OMITS: a backtick
  # opens a command substitution exactly as `$(` does, and `$(` is matched
  # only because the class already carries `(`. Adding the backtick was
  # tried and measured before it was rejected -- one character, and every
  # line it then matched was this repo's own COMMENT prose, a comparison
  # quoted in markdown backticks, not one of them a command (three such
  # lines when re-measured 2026-09-01; the count moves whenever a comment
  # is reworded, what the lines ARE does not). The corpus decides: in spec
  # files that spelling is punctuation, so scanning it cries wolf, which is
  # the one failure mode CMD_POS exists to prevent. It is planted in the
  # blind-spot case instead.
  #
  # That is what makes this set CLOSED where the deleted write roster's was
  # open: the shell has a finite grammar, while the set of commands that can
  # write a file is every binary that exists.
  CMD_POS='(^|[;&|(){]|&&|\|\||\b(if|elif|while|until|then|else|do|time)[[:space:]]|\brun([[:space:]]+-[^[:space:]]+)*[[:space:]])[[:space:]]*(![[:space:]]*)?'

  # A position measured in WORDS, not in operands -- the variable name is
  # older than the measurement: the live path as the first or the second
  # word after any run of option flags. `cmp "${SCRATCH}/x" /source/x`
  # settles its verdict from the second of them, so first-word-only would
  # miss half of the shape; and an option that takes an argument of its own
  # spends one of the two, which is what the blind-spot case plants.
  OPERAND="([[:space:]]+-[^[:space:]]+)*([[:space:]]+[^[:space:]]+)?[[:space:]]+\"?${LIVE_TREE}"

  # A live path as an operand of a comparison: the shape that made a correct
  # generator fail five gate runs.
  COMPARE_RE="${CMD_POS}(diff|cmp)\\b${OPERAND}"
}

# _assert_population -- the spec tree is really there and really populated.
# A scan of an empty or missing tree reports "no matches" exactly like a
# clean one, so the invariant below establishes the denominator first.
_assert_population() {
  # pipefail so a find that cannot read the tree fails HERE, with find's
  # own message, instead of reaching the comparison below as the count 0
  # plus a stderr line and failing as "integer expression expected".
  run bash -c "set -o pipefail; find ${SPEC_TREE} -type f -name '*.bats' | wc -l | tr -d ' '"
  assert_success
  assert [ "${output}" -ge "${SPEC_TREE_FLOOR}" ]
}

# _assert_clean_scan <regex> -- the scan RAN and matched nothing. grep
# answers 1 for "scanned, no match" and 2 for "could not scan"; only the
# first is the invariant holding.
_assert_clean_scan() {
  run grep -rnE "${1:?BUG: _assert_clean_scan expects a regex}" "${SPEC_TREE}/"
  assert_equal "${status}" 1
  assert_output ""
}

# why: The defect this file was written for: a concurrent writer supplied
# half the verdict
@test "no spec settles an assertion by comparing against the live checkout (#965)" {
  # The defect this file was written for: a spec generated an artifact in
  # its own scratch dir and then diffed it against the live tree, so a
  # concurrent writer -- another job in this 32-way parallel suite, a
  # sibling checkout's gate, an editor -- supplied half the verdict.
  _assert_population
  _assert_clean_scan "${COMPARE_RE}"
}

# why: Pinning status 1 only means something while "could not scan" is
# reachable
@test "a scan of a tree that is not there answers 2, not 1 (#965)" {
  # What keeps the invariant above from passing vacuously. `grep -rnE`
  # over a missing path is the exact shape of a check that found no files,
  # and it is indistinguishable from a clean tree under `assert_failure`.
  # Pinning status 1 is only meaningful while 2 is reachable, so reach it.
  run grep -rnE "${COMPARE_RE}" "${SPEC_TREE}-does-not-exist/"
  assert_equal "${status}" 2
}

# why: The positions come from the grammar, which makes that axis narrow
# rather than complete
@test "the comparison scan sees a live operand in each command position it names (#965)" {
  # The other way an invariant goes quietly blind: it holds because its
  # PATTERN misses the line, not because no such line exists. A review
  # planted six spellings this scan NAMED and could not see -- `if`,
  # `elif`, `while`, `until`, a leading `!`, and `run` with a flag -- while
  # the header disclosed two. A wide claim with a narrow body is the defect
  # this repo keeps producing, so the positions are now derived and every
  # one of them is planted here.
  #
  # The positions are taken from the shell grammar rather than from taste:
  # a command can begin at the start of a line, after a separator or opener
  # (`;` `&` `|` `&&` `||` `(` `{`), after one of the reserved words that is
  # followed by a command (`if` `elif` `while` `until` `then` `else` `do`
  # `time`), after a negating `!`, or after bats' own `run` and its flags.
  # Reserved words that are followed by a WORD rather than a command
  # (`case`, `for`, `in`, `select`, `function`) cannot open one, and the
  # rest close a construct.
  #
  # That derivation makes the POSITION axis narrower than the scan's other
  # two -- it is not what makes the scan complete, and the scan is not. One
  # derivable position is unscanned by choice (a backtick, rejected with its
  # measurement where CMD_POS is defined), and the command and operand axes
  # are rosters. This case pins the positions the scan NAMES; the ones it
  # does not are sampled in the case below.
  #
  # Every fixture keeps the live path as a printf ARGUMENT, never a
  # literal: a literal would put a matching line into the tree the
  # invariant above scans and it would fail on its own fixture.
  local _planted="${BATS_TEST_TMPDIR}/planted_cmp"
  mkdir -p "${_planted}"
  # name|printf-format, so one loop covers the whole set. A quoted heredoc,
  # so ${SCRATCH} reaches the fixture as text; the live path arrives as the
  # printf argument.
  local _spelling _fmt
  while IFS='|' read -r _spelling _fmt; do
    [[ -n "${_spelling}" ]] || continue
    # shellcheck disable=SC2059
    printf "${_fmt}\n" "${LIVE_TREE}" > "${_planted}/${_spelling}.bats"
    run grep -nE "${COMPARE_RE}" "${_planted}/${_spelling}.bats"
    [[ "${status}" -eq 0 ]] || fail \
      "the comparison scan does not match the ${_spelling} spelling, so a spec letting the live tree settle its verdict that way would leave the invariant green while the race it names is wide open"
  done <<'SPELLINGS'
historical|  run diff -r %s/doc/readme "${SCRATCH}/doc/readme"
second_operand|  run cmp "${SCRATCH}/x" %s/x
bare_diff|  diff %s/README.md "${SCRATCH}/README.md"
subshell|  _out="$(diff %s/README.md "${SCRATCH}/README.md")"
if_condition|  if diff -r %s/doc/readme "${SCRATCH}/doc/readme"; then :; fi
elif_condition|  elif cmp -s %s/x "${SCRATCH}/x"; then :
while_negated|  while ! diff -q %s/a "${SCRATCH}/a"; do :; done
until_condition|  until cmp %s/a "${SCRATCH}/a"; do :; done
bang_leading|  ! diff %s/a "${SCRATCH}/a"
run_with_status_flag|  run -0 diff -r %s/doc "${SCRATCH}/doc"
run_with_long_flag|  run --separate-stderr diff %s/a "${SCRATCH}/a"
then_clause|  if true; then diff %s/a "${SCRATCH}/a"; fi
else_clause|  if false; then :; else diff %s/a "${SCRATCH}/a"; fi
do_clause|  for _i in 1; do cmp %s/a "${SCRATCH}/a"; done
after_and|  true && diff %s/a "${SCRATCH}/a"
after_or|  false || cmp %s/a "${SCRATCH}/a"
semicolon|  :; diff %s/a "${SCRATCH}/a"
time_keyword|  time diff %s/a "${SCRATCH}/a"
SPELLINGS
}

# why: A sample of what it misses, one per axis: the command name, the word
# position, line-wise literal matching, and the position omitted by choice
@test "the comparison scan is an over-approximation, not a closed set (#965)" {
  # The disclosure, made executable -- and the disclosure is that this scan
  # is NOT a closed set. An earlier version of this case claimed the
  # opposite in its own title ("and they are all of them") over a list of
  # three; a review then planted eighteen comparison spellings and sixteen
  # went unseen. A wide claim with a narrow body is the defect this repo
  # keeps producing, and a test that asserts completeness it does not have
  # is the worst place to produce it.
  #
  # So what is planted here is a SAMPLE, one per axis, of an open set:
  #
  #   - the COMMAND axis. The scan knows two names. A comparison driven
  #     through git, or settled by comparing two checksums, or written as an
  #     equality test over two command substitutions, is a comparison the
  #     scan has no name for. That axis is a roster exactly like the write
  #     roster this file deleted -- the difference being that the write
  #     property has an executed gate behind it and this one does not.
  #   - the WORD-POSITION axis, which the name OPERAND overstates. The
  #     scan matches the live path as the first or the second WORD after a
  #     run of flags, and an option that takes an argument of its own
  #     spends one of those words: in the sample planted below the live
  #     path IS the second operand of the comparison, and the scan misses
  #     it because it is the third word.
  #   - LINE-WISE and LITERAL, which is inherent rather than a roster: a
  #     comparison split across a continuation line, a command name arriving
  #     through a variable or an alias, a live path built out of a variable.
  #   - one derivable command POSITION left unscanned by choice, a backtick,
  #     because every line the widening that sees it matched was this
  #     repo's own comment prose and no command at all (three of them when
  #     re-measured 2026-09-01).
  #
  # Widening the pattern to catch one of these is starting a roster, which
  # this file has refused twice; this case is where that decision gets made
  # out loud rather than by editing a regex.
  local _planted="${BATS_TEST_TMPDIR}/planted_blind"
  mkdir -p "${_planted}"
  local _spelling _fmt
  while IFS='|' read -r _spelling _fmt; do
    [[ -n "${_spelling}" ]] || continue
    # shellcheck disable=SC2059
    printf "${_fmt}\n" "${LIVE_TREE}" > "${_planted}/${_spelling}.bats"
    run grep -nE "${COMPARE_RE}" "${_planted}/${_spelling}.bats"
    [[ "${status}" -eq 1 ]] || fail \
      "the ${_spelling} spelling IS matched, so this file's account of what the scan sees is out of date; the samples here are what keeps the header from claiming more than the pattern does, and widening the pattern is a decision to state, not a silent edit"
  done <<'BLIND'
command_in_a_variable|  _cmp=diff; "${_cmp}" %s/a "${SCRATCH}/a"
path_in_a_variable|  _live=%s; diff "${_live}/a" "${SCRATCH}/a"
backtick_substitution|  _out=`diff %s/a "${SCRATCH}/a"`
comparison_through_git|  run git diff --no-index %s/doc "${SCRATCH}/doc"
checksum_pair|  run md5sum %s/a "${SCRATCH}/a"
equality_test|  [[ "$(cat %s/README.md)" == "$(cat "${SCRATCH}/README.md")" ]]
past_the_second_word|  run diff --exclude foo "${SCRATCH}/doc" %s/doc
BLIND
  # The continuation line, which cannot be written as one line by
  # definition: the operand is on the NEXT line, so a line-wise scan
  # cannot see it whatever its command positions are.
  printf '  diff -r \\\n    %s/doc "${SCRATCH}/doc"\n' "${LIVE_TREE}" \
    > "${_planted}/continuation_line.bats"
  run grep -nE "${COMPARE_RE}" "${_planted}/continuation_line.bats"
  [[ "${status}" -eq 1 ]] || fail \
    "the continuation-line spelling IS matched, so the header understates what this scan sees"
}
