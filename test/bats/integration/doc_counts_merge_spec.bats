#!/usr/bin/env bats
#
# doc_counts_merge_spec.bats -- integration coverage for
# script/test/resolve-doc-counts.sh against a REAL git merge conflict.
#
# why: The unit spec drives the resolver's functions over hand-written
# marker fixtures. This one reproduces what actually happens: two branches
# each added tests, both bumped the same generated total in
# doc/test/unit.md, and the merge conflicts on it -- the conflict shape
# every branch refresh in the base review batch produced, resolved by hand
# six times in one of them.
#
# One command has to leave a merged, regenerated, staged, gate-clean tree
# behind. The catalogue prose is the half that used to need rescuing, and
# it is the half this case now proves needs nothing: both branches
# authored their descriptions in the SPEC files, so both collapses
# regenerate the same rows from the same merged spec tree and there is
# nothing left for a collapse to drop.
#
# What can still be refused is a disagreement OUTSIDE the generated
# region, where the document is hand-written and regeneration justifies
# nothing. The second case drives that, and asserts nothing is staged.

bats_require_minimum_version 1.5.0

RESOLVE="/source/script/test/resolve-doc-counts.sh"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}/test/bats/unit" "${REPO}/doc/test"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email tester@example.invalid
  git -C "${REPO}" config user.name tester
  _seed
}

# _spec <name> <test-name>:<description>... -- (re)write a spec file
# carrying the named tests, each with its `# why:` marker above it. An
# empty description after the colon leaves the test undescribed.
_spec() {
  local _name="${1}"
  shift
  local _t _testname _desc
  : > "${REPO}/test/bats/unit/${_name}.bats"
  for _t in "$@"; do
    _testname="${_t%%:*}"
    _desc="${_t#*:}"
    [[ -n "${_desc}" ]] \
      && printf '# why: %s\n' "${_desc}" >> "${REPO}/test/bats/unit/${_name}.bats"
    printf '@test "%s" {\n:\n}\n' "${_testname}" \
      >> "${REPO}/test/bats/unit/${_name}.bats"
  done
}

# _doc <total> <lead-prose> -- rewrite unit.md's hand-written half. The
# generated region is left empty on purpose: the resolver regenerates it,
# and a fixture that pre-typed what a generator emits would be the habit
# this whole change removes. Only the total line and the lead prose are
# hand-written, which is where the two branches collide.
_doc() {
  local _total="${1}" _lead="${2:-Spacer prose, hand written and identical on both sides.}"
  {
    printf 'Unit specs under `test/bats/unit/`: **%s tests**.\n' "${_total}"
    printf '\n%s\n' "${_lead}"
    printf '\n<!-- generated: catalogue sections -->\n<!-- /generated -->\n'
  } > "${REPO}/doc/test/unit.md"
}

# _seed -- the common ancestor both branches start from.
_seed() {
  _spec a_spec 'alpha:the original'
  _spec b_spec 'bravo:the other original'
  _doc 2
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm base
}

# _commit_all <message> -- stage everything and commit.
_commit_all() {
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm "${1}"
}

# why: The whole toil, end to end. The load-bearing assertion is that BOTH
# branches' descriptions survive: a mechanical collapse keeps one side's
# document, and under the old design that dropped whichever description the
# other side had written. Here neither side's document holds a description
# at all, so there is nothing to drop.
@test "resolve-doc-counts: resolves a real two-branch counter conflict end to end (#857)" {
  git -C "${REPO}" checkout -q -b feature
  _spec a_spec 'alpha:the original' 'beta:added on the branch' 'charlie:'
  _doc 4
  _commit_all feature

  git -C "${REPO}" checkout -q main
  _spec b_spec 'bravo:the other original' 'delta:added on main'
  _doc 3
  _commit_all main

  run git -C "${REPO}" merge --no-edit feature
  assert_failure
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_output --partial 'doc/test/unit.md'

  run bash "${RESOLVE}" "${REPO}"
  assert_success

  run cat "${REPO}/doc/test/unit.md"
  assert_success
  refute_output --partial '<<<<<<<'
  refute_output --partial '>>>>>>>'
  assert_line '| `alpha` | the original |'
  assert_line '| `beta` | added on the branch |'
  assert_line '| `charlie` | - |'
  assert_line '| `bravo` | the other original |'
  assert_line '| `delta` | added on main |'
  # The totals are regenerated from the MERGED spec tree, not inherited
  # from whichever side the collapse kept (3 + 2 = 5, a number neither
  # side wrote).
  assert_output --partial '**5 tests**'
  assert_output --partial '### test/bats/unit/a_spec.bats (3)'
  assert_output --partial '### test/bats/unit/b_spec.bats (2)'

  # Resolved means resolved: nothing left unmerged, so the merge can be
  # committed without a second manual `git add`.
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_success
  assert_output ''

  run bash /source/script/test/check_test_md_drift.sh "${REPO}"
  assert_success
}

# why: The refusal that survives. Inside the fence there is nothing left to
# disagree about, but the preamble is still hand-written, and adopting one
# side of a sentence regeneration cannot justify is exactly the trap the
# hand-typed recipe carried. Nothing is staged, so a half-resolved tree
# cannot be committed by accident.
@test "resolve-doc-counts: REFUSES a merge whose sides differ OUTSIDE the generated region, staging nothing (#857)" {
  git -C "${REPO}" checkout -q -b feature
  _spec a_spec 'alpha:the original' 'beta:added on the branch'
  _doc 3 'Covers the old behaviour, hand written.'
  _commit_all feature

  git -C "${REPO}" checkout -q main
  _spec a_spec 'alpha:the original' 'beta:added on the branch'
  _doc 3 'Covers the new behaviour, hand written.'
  _commit_all main

  run git -C "${REPO}" merge --no-edit feature
  assert_failure

  run bash "${RESOLVE}" "${REPO}"
  assert_failure
  assert_output --partial 'hand written'

  # Refused means untouched as far as git is concerned: still unmerged, so
  # nobody can commit a half-resolved tree by accident.
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_output --partial 'doc/test/unit.md'
}
