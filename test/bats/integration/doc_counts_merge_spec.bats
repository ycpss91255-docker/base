#!/usr/bin/env bats
#
# doc_counts_merge_spec.bats -- integration coverage for
# script/test/resolve-doc-counts.sh against a REAL git merge conflict.
#
# The unit spec drives the resolver's functions over hand-written marker
# fixtures. This one proves the thing it actually exists for: two branches
# that each added a spec file and its doc section, merged, conflicting in
# doc/test/unit.md exactly as every branch refresh in the base review batch
# did. One command has to leave a merged, regenerated, staged, gate-clean
# tree behind.

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
}

# _spec <name> <test-name>... -- write a spec file carrying the named tests.
_spec() {
  local _name="${1}"; shift
  local _t
  : > "${REPO}/test/bats/unit/${_name}.bats"
  for _t in "$@"; do
    printf '@test "%s" {\n:\n}\n' "${_t}" >> "${REPO}/test/bats/unit/${_name}.bats"
  done
}

# _section <name> <count> <row>... -- append a doc section for a spec file.
_section() {
  local _name="${1}" _count="${2}"; shift 2
  {
    printf '\n### test/bats/unit/%s.bats (%s)\n\n' "${_name}" "${_count}"
    printf '| Test | Description |\n|------|-------------|\n'
    printf '%s\n' "$@"
  } >> "${REPO}/doc/test/unit.md"
}

@test "resolve-doc-counts: resolves a real two-branch merge conflict end to end (#857)" {
  _spec base_spec alpha
  printf 'Unit specs under `test/bats/unit/`: **1 tests**.\n' \
    > "${REPO}/doc/test/unit.md"
  _section base_spec 1 '| `alpha` | the original |'
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm base

  git -C "${REPO}" checkout -q -b feature
  _spec feature_spec beta
  _section feature_spec 1 '| `beta` | added on the branch |'
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm feature

  git -C "${REPO}" checkout -q main
  _spec main_spec gamma delta
  _section main_spec 2 '| `gamma` | added on main |' '| `delta` | - |'
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm main

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
  # Every side's tests are catalogued, and the prose each side wrote survives.
  assert_line '| `alpha` | the original |'
  assert_line '| `beta` | added on the branch |'
  assert_line '| `gamma` | added on main |'
  assert_line '| `delta` | - |'
  # The derived figures are regenerated from the merged spec tree, not
  # inherited from whichever side the collapse happened to keep.
  assert_output --partial '**4 tests**'
  assert_output --partial '### test/bats/unit/feature_spec.bats (1)'
  assert_output --partial '### test/bats/unit/main_spec.bats (2)'

  # Resolved means resolved: nothing left unmerged, so the merge can be
  # committed without a second manual `git add`.
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_success
  assert_output ''

  run bash /source/script/test/check_test_md_drift.sh "${REPO}"
  assert_success
}
