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
# ── Why the COMPARISON scan stays ─────────────────────────────────────────
#
# Because the snapshot cannot subsume it. A comparison against the live tree
# leaves no trace: the spec reads, decides, and the checkout is byte-
# identical afterwards. There is nothing for an executed residue check to
# find, and the failure is not residue at all -- it is a verdict half of
# which someone else wrote. A static scan is the only shape that can see it
# before it costs a gate run, and unlike the write roster it has ONE shape
# to match (a live path as an operand of diff / cmp), which is why it did
# not need widening in three rounds.
#
# It is an over-approximation on purpose -- `diff /source/a /source/b`
# compares two live paths and is flagged as well -- and it is line-wise, so
# a comparison whose operand is an alias, or is pushed onto a continuation
# line, goes unseen. Being incomplete is acceptable HERE in a way it was not
# for the write scan: nothing else was standing behind that one.
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

  # A command POSITION: start of line, or after a separator that opens one.
  # Requiring it is what keeps a verb quoted inside somebody else's grep
  # pattern out of the scan -- four such lines matched before this was
  # added, and an invariant that cries wolf four times is one that gets
  # deleted.
  CMD_POS='(^|[;&|(){]|&&|\|\||\brun[[:space:]]+|\bthen[[:space:]]+|\bdo[[:space:]]+)[[:space:]]*'

  # An OPERAND position: the live path as the first or the second argument,
  # after any run of option flags. `cmp "${SCRATCH}/x" /source/x` settles
  # its verdict from the SECOND operand, so first-operand-only would miss
  # half of the shape.
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

@test "no spec settles an assertion by comparing against the live checkout (#965)" {
  # The defect this file was written for: a spec generated an artifact in
  # its own scratch dir and then diffed it against the live tree, so a
  # concurrent writer -- another job in this 32-way parallel suite, a
  # sibling checkout's gate, an editor -- supplied half the verdict.
  _assert_population
  _assert_clean_scan "${COMPARE_RE}"
}

@test "a scan of a tree that is not there answers 2, not 1 (#965)" {
  # What keeps the invariant above from passing vacuously. `grep -rnE`
  # over a missing path is the exact shape of a check that found no files,
  # and it is indistinguishable from a clean tree under `assert_failure`.
  # Pinning status 1 is only meaningful while 2 is reachable, so reach it.
  run grep -rnE "${COMPARE_RE}" "${SPEC_TREE}-does-not-exist/"
  assert_equal "${status}" 2
}

@test "the comparison scan sees the line it was written for, in both operand positions (#965)" {
  # The other way an invariant goes quietly blind: it holds because its
  # PATTERN misses the line, not because no such line exists.
  #
  # The first fixture is readme_sync_spec's old assertion, verbatim except
  # for the live path being a printf ARGUMENT rather than a literal -- a
  # literal would put a matching line into the tree the invariant above
  # scans, and it would fail on its own fixture.
  local _planted="${BATS_TEST_TMPDIR}/planted_cmp"
  mkdir -p "${_planted}"
  printf '  run diff -r %s/doc/readme "${SCRATCH}/doc/readme"\n' \
    "${LIVE_TREE}" > "${_planted}/historical.bats"
  printf '  run cmp "${SCRATCH}/x" %s/x\n' "${LIVE_TREE}" > "${_planted}/second_operand.bats"
  printf '  diff %s/README.md "${SCRATCH}/README.md"\n' \
    "${LIVE_TREE}" > "${_planted}/bare_diff.bats"

  local _spelling
  for _spelling in historical second_operand bare_diff; do
    run grep -nE "${COMPARE_RE}" "${_planted}/${_spelling}.bats"
    [[ "${status}" -eq 0 ]] || fail \
      "the comparison scan does not match the ${_spelling} spelling, so a spec letting the live tree settle its verdict that way would leave the invariant green"
  done
}
