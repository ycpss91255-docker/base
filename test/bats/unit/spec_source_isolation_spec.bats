#!/usr/bin/env bats
#
# Repo-wide invariants over test/bats/: a spec may READ the live checkout
# (that is where its subject lives), but it may not WRITE there, and it may
# not settle an assertion by COMPARING against it.
#
# Why the population is drawn that way. Two specs lost a race against their
# own suite and cost two or three full gate runs per landed branch.
# The obvious framing -- "audit every spec that touches /source" -- is not
# actionable: all but a handful of the specs reference /source -- 124 of the
# 128 spec files when this was written -- because that is where the script
# under test, the tracked workflow being asserted on, and the real tree the
# "clean today" guards lint all live. A read of the subject is the point of
# a unit test, not a defect.
#
# What separates the defect from the population is OWNERSHIP of the answer.
# `diff -r /source/doc/readme "${SCRATCH}/doc/readme"` asked the generator a
# question and then let a tree the spec does not own supply half the answer;
# the suite runs 32-way parallel, often beside another checkout's gate, so
# anything writing there in the window flipped the verdict on correct code.
# That shape -- a live path as a comparison operand -- had exactly one
# instance, the one that failed. A write into the live tree had none, and
# that is worth keeping: it is the shape that would make every OTHER spec's
# read racy, so the invariant is cheap now and expensive to recover later.
#
# Why a spec and not a lint driver: test.sh's _LINT_TOOLS table is asserted
# by self_test_yaml_spec to have a CI job per entry, so a driver costs a
# workflow edit for a scan that the bats gate already runs everywhere. The
# sibling spec_subject_guard_spec.bats set that precedent.
#
# Both invariants have the failure mode they are looking for, so each pins
# the scan as well as the result: the spec population may not fall below a
# floor, and grep's status must be exactly 1 (scanned, matched nothing) --
# never 2 (could not scan), which `assert_failure` would have accepted. A
# separate case proves a scan of nothing answers 2, and another proves each
# spelling the patterns claim to see is actually seen.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The live checkout, as every spec sees it inside the ci container. Held
  # in a variable rather than written into the patterns below so that no
  # line of THIS file -- which lives under the tree the scans read -- can
  # match a scan and fail the invariant on its own source.
  LIVE_TREE=/source

  # Where the scans look, and the floor the population may not fall below.
  SPEC_TREE="${LIVE_TREE}/test/bats"
  SPEC_TREE_FLOOR=100

  # A command POSITION: start of line, or after a separator that opens one.
  # Requiring it is what keeps a verb quoted inside somebody else's grep
  # pattern (`grep -E 'sed -i.*main_yaml' /source/...`) out of the scan --
  # four such lines matched before this was added, and an invariant that
  # cries wolf four times is an invariant that gets deleted.
  CMD_POS='(^|[;&|(){]|&&|\|\||\brun[[:space:]]+|\bthen[[:space:]]+|\bdo[[:space:]]+)[[:space:]]*'

  # An OPERAND position: the live path as the first or the second argument,
  # after any run of option flags. `mv "${SCRATCH}/x" /source/x` writes the
  # live tree from its SECOND operand, so first-operand-only would miss the
  # spelling that matters most.
  OPERAND="([[:space:]]+-[^[:space:]]+)*([[:space:]]+[^[:space:]]+)?[[:space:]]+\"?${LIVE_TREE}"

  # Commands whose named operands it MUTATES. cp and ln are absent on
  # purpose: `ln -s /source/dist/script/... "${SANDBOX}/build.sh"` is how
  # most of this suite gets its subject under test, and there the live path
  # is the source, not the destination.
  WRITE_CMD_RE="${CMD_POS}(rm|rmdir|mv|mkdir|touch|truncate|chmod|chown|install|tee|dd|sed)\\b${OPERAND}"

  # Output redirection into the live tree. No command position needed -- the
  # redirection operator IS the write.
  WRITE_REDIR_RE=">>?[[:space:]]*\"?${LIVE_TREE}"

  # A live path as an operand of a comparison: the shape that made a correct
  # generator fail five gate runs.
  COMPARE_RE="${CMD_POS}(diff|cmp)\\b${OPERAND}"
}

# _assert_population -- the spec tree is really there and really populated.
# A scan of an empty or missing tree reports "no matches" exactly like a
# clean one, so every invariant below establishes the denominator first.
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

@test "no spec writes into the live checkout it does not own (#965)" {
  # Every spec here reads the live tree -- that is where its subject is --
  # and every one of those reads is only safe while nothing writes there.
  # One writer would make the whole population racy at once.
  _assert_population
  _assert_clean_scan "${WRITE_CMD_RE}"
  _assert_clean_scan "${WRITE_REDIR_RE}"
}

@test "no spec settles an assertion by comparing against the live checkout (#965)" {
  # The defect this file was written for: a spec generated an artifact in
  # its own scratch dir and then diffed it against the live tree, so a
  # concurrent writer -- another job in this 32-way parallel suite, a
  # sibling checkout's gate, an editor -- supplied half the verdict. Both
  # sides of a comparison have to be bytes the spec captured itself.
  _assert_population
  _assert_clean_scan "${COMPARE_RE}"
}

@test "a scan of a tree that is not there answers 2, not 1 (#965)" {
  # What keeps the two invariants above from passing vacuously. `grep -rnE`
  # over a missing path is the exact shape of a check that found no files,
  # and it is indistinguishable from a clean tree under `assert_failure`.
  # Pinning status 1 is only meaningful while 2 is reachable, so reach it.
  run grep -rnE "${COMPARE_RE}" "${SPEC_TREE}-does-not-exist/"
  assert_equal "${status}" 2
}

@test "the write scan sees every spelling of a write it claims to (#965)" {
  # The other way an invariant goes quietly blind: it holds because its
  # PATTERN misses the write, not because no write exists.
  #
  # Each fixture is written with the live path as a printf ARGUMENT, never
  # as a literal in this file: a literal would put a matching line into the
  # tree the invariants above scan, and they would fail on their own
  # fixtures.
  local _planted="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "${_planted}"
  printf '  rm -rf %s/doc/readme\n'      "${LIVE_TREE}" > "${_planted}/rm_first.bats"
  printf '  mv "${SCRATCH}/x" %s/x\n'    "${LIVE_TREE}" > "${_planted}/mv_second.bats"
  printf '  sed -i s/a/b/ %s/x\n'        "${LIVE_TREE}" > "${_planted}/sed_inplace.bats"
  printf '  touch %s/x\n'                "${LIVE_TREE}" > "${_planted}/touch.bats"
  printf '  ( cd x && rm %s/y )\n'       "${LIVE_TREE}" > "${_planted}/rm_after_sep.bats"

  local _spelling
  for _spelling in rm_first mv_second sed_inplace touch rm_after_sep; do
    run grep -nE "${WRITE_CMD_RE}" "${_planted}/${_spelling}.bats"
    [[ "${status}" -eq 0 ]] || fail \
      "the write scan does not match the ${_spelling} spelling, so a spec writing the live tree that way would leave the invariant green"
  done

  printf '  printf x > %s/x\n'   "${LIVE_TREE}" > "${_planted}/redirect.bats"
  printf '  printf x >> "%s/x"\n' "${LIVE_TREE}" > "${_planted}/append.bats"
  for _spelling in redirect append; do
    run grep -nE "${WRITE_REDIR_RE}" "${_planted}/${_spelling}.bats"
    [[ "${status}" -eq 0 ]] || fail \
      "the redirection scan does not match the ${_spelling} spelling, so a spec writing the live tree that way would leave the invariant green"
  done
}

@test "the comparison scan sees the line it was written for, in both operand positions (#965)" {
  # The first fixture is readme_sync_spec's old assertion, verbatim except
  # for the live path being a printf argument. A guard that cannot match the
  # defect that produced it is decoration.
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
