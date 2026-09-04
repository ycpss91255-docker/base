#!/usr/bin/env bats
#
# Unit tests for script/adr/renumber.sh -- moving one ADR record to
# another number and rewriting every reference to it.
#
# why: Nothing allocates an ADR number, so parallel branches collide by
# construction (base#1021: three took 00000030 on one day, each right by
# the only rule there is). The collision reaches a red check; the REPAIR
# was what cost -- 14 files, three of them left incomplete and green. The
# cases here are about the property that makes the repair trustworthy: the
# reference set is DERIVED, the classes are told apart rather than sed'ed
# over, and a state the tool cannot resolve without guessing is refused
# whole rather than half-applied.
#
# The fixture roots are not git checkouts. That is deliberate: it exercises
# the same code path a checkout takes apart from the rename verb, and it
# keeps the cases about references rather than about git.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  RENUMBER="/source/script/adr/renumber.sh"
  ROOT="${BATS_TEST_TMPDIR}/r"
  mkdir -p "${ROOT}/doc/adr" "${ROOT}/doc/test" "${ROOT}/test/bats/unit"
  printf '%s\n' '# The record' > "${ROOT}/doc/adr/00000030-entry-point.md"
  printf '%s\n' '# Another' > "${ROOT}/doc/adr/00000029-early-return.md"
  printf '%s\n' \
    'Unit specs under `test/bats/unit/`: **0 tests**.' '' \
    '<!-- generated: catalogue sections -->' '<!-- /generated -->' \
    > "${ROOT}/doc/test/unit.md"
}

# _index <row>... -- the ADR index, whose bare 8-digit runs are all ADR
# numbers and are therefore rewritten.
_index() {
  {
    printf '%s\n' '# ADR index'
    printf '%s\n' '| ADR | Verdict | Serves | Note |'
    printf '%s\n' '|---|---|---|---|'
    printf '%s\n' "$@"
  } > "${ROOT}/doc/adr/README.md"
}

# _file <relpath> <line>... -- any other file in the tree.
_file() {
  local _rel="$1"
  shift
  mkdir -p "${ROOT}/$(dirname -- "${_rel}")"
  printf '%s\n' "$@" > "${ROOT}/${_rel}"
}

# why: The record itself, and the reference class that carries most of
# them. If the tool did only this it would already be the whole 14-file
# sweep for most files -- the interesting part is what it does NOT do to
# the other classes.
@test "adr renumber: moves the record and rewrites ADR- references (#1021)" {
  _file 'CONTEXT.md' 'The entry point is base'"'"'s (ADR-00000030).'
  run bash "${RENUMBER}" 00000030 00000032 "${ROOT}"
  assert_success
  [[ -f "${ROOT}/doc/adr/00000032-entry-point.md" ]]
  [[ ! -e "${ROOT}/doc/adr/00000030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-00000032'
  refute_output --partial 'ADR-00000030'
}

# why: The path form carries the slug, which is what makes it the one
# reference class that stays unambiguous even where the number does not --
# and the class a rewrite of `ADR-<n>` alone would leave behind.
@test "adr renumber: rewrites a doc/adr path reference, slug and all (#1021)" {
  # Assembled from variables, and the reason is this case's own subject: a
  # literal `doc/adr/NNNNNNNN-<slug>.md` in THIS file is a reference in the
  # real tree, where `entry-point` names no record -- so the fixture
  # spelled the obvious way would fail the ADR-reference lint.
  local _from='00000030' _to='00000032'
  _file 'test/bats/unit/init_spec.bats' \
    "  local _adr=/source/doc/adr/${_from}-entry-point.md"
  run bash "${RENUMBER}" 30 32 "${ROOT}"
  assert_success
  run cat "${ROOT}/test/bats/unit/init_spec.bats"
  assert_output --partial "/source/doc/adr/${_to}-entry-point.md"
}

# why: The index writes its numbers bare, and everywhere else a bare
# 8-digit run is not a reference at all. Rewriting bare numbers tree-wide
# is how a renumber would corrupt the fixture registries the lint specs
# build, so the class is scoped to the one document whose 8-digit runs are
# all ADR numbers.
@test "adr renumber: rewrites the bare number in the index and nowhere else (#1021)" {
  _index '| 00000029 -- early return | keep | P1 | note |' \
    '| 00000030 -- the entry point | keep | inv 6 | note |'
  _file 'test/bats/unit/lint_spec.bats' '  _touch_adr "00000030-fixture.md"'
  run bash "${RENUMBER}" 30 32 "${ROOT}"
  assert_success
  run cat "${ROOT}/doc/adr/README.md"
  assert_output --partial '| 00000032 -- the entry point |'
  refute_output --partial '| 00000030 --'
  run cat "${ROOT}/test/bats/unit/lint_spec.bats"
  assert_output --partial '"00000030-fixture.md"'
}

# why: The site a blind sed gets wrong. One of the 14 was a `@test` NAME
# carrying the number, and a test name is a ROW in a generated catalogue:
# rewriting the row directly puts a hand edit into a generated file, which
# the next regeneration reverts. The spec is a source and is rewritten;
# the catalogue is rebuilt from it. The stale count proves the rebuild
# happened rather than a substitution that only looked like one.
@test "adr renumber: regenerates the catalogue instead of editing it (#1021)" {
  _file 'test/bats/unit/init_spec.bats' \
    '#!/usr/bin/env bats' '' \
    '# why: the seeded text and the record use one vocabulary' \
    '@test "the placeholder and ADR-00000030 name the convention identically" {' \
    '}'
  _file 'doc/test/unit.md' \
    'Unit specs under `test/bats/unit/`: **99 tests**.' '' \
    '<!-- generated: catalogue sections -->' \
    '### test/bats/unit/init_spec.bats (99)' \
    '| `the placeholder and ADR-00000030 name the convention identically` | stale |' \
    '<!-- /generated -->'
  run bash "${RENUMBER}" 30 32 "${ROOT}"
  assert_success
  run cat "${ROOT}/test/bats/unit/init_spec.bats"
  assert_output --partial 'ADR-00000032 name the convention'
  run cat "${ROOT}/doc/test/unit.md"
  assert_output --partial 'ADR-00000032 name the convention'
  refute_output --partial 'ADR-00000030'
  # Regenerated, not substituted: the count and the description come back
  # from the spec, so the stale ones are gone.
  assert_output --partial '### test/bats/unit/init_spec.bats (1)'
  assert_output --partial 'the seeded text and the record use one vocabulary'
  refute_output --partial '**99 tests**'
}

# why: A generated document is only PARTLY generated -- its preamble is
# hand-written prose outside the fence, and the generator does not own a
# word of it. Skipping the file because the generator writes part of it
# left a reference standing there, found by running the tool over a copy
# of the real tree. Both halves are covered: the prose is rewritten, and
# the fenced half is rebuilt afterwards from the specs.
@test "adr renumber: rewrites the hand-written half of a generated document (#1021)" {
  _file 'test/bats/unit/init_spec.bats' \
    '#!/usr/bin/env bats' '' \
    '# why: a described case' \
    '@test "a" {' \
    '}'
  _file 'doc/test/unit.md' \
    'Unit specs under `test/bats/unit/`: **99 tests**.' '' \
    'The acceptance bringup is base'"'"'s orchestrator (ADR-00000030), which' \
    'this paragraph says by hand -- no generator wrote it.' '' \
    '<!-- generated: catalogue sections -->' '<!-- /generated -->'
  run bash "${RENUMBER}" 30 32 "${ROOT}"
  assert_success
  run cat "${ROOT}/doc/test/unit.md"
  assert_output --partial 'orchestrator (ADR-00000032)'
  refute_output --partial 'ADR-00000030'
  # Still regenerated: the hand-written half being rewritten must not cost
  # the rebuild of the half that is derived.
  assert_output --partial '### test/bats/unit/init_spec.bats (1)'
  refute_output --partial '**99 tests**'
}

# why: The population, and the property that keeps this verb and the ADR
# lint from disagreeing about what a reference is -- they read one. A
# tree the checkout declares derived is not swept: a materialised old
# release and a wrapper transcript are records of what WAS said, so
# rewriting one falsifies it, and a finding the verb cannot reach is a
# red gate with no repair path through the verb.
@test "adr renumber: leaves a tree the checkout declares derived alone (#1021)" {
  _file '.gitignore' 'log/'
  _file 'log/test/2026-09-04-abcdef12.log' 'the transcript said ADR-00000030'
  _file 'CONTEXT.md' 'ADR-00000030 is the record.'
  run bash "${RENUMBER}" 30 32 "${ROOT}"
  assert_success
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-00000032'
  run cat "${ROOT}/log/test/2026-09-04-abcdef12.log"
  assert_output --partial 'ADR-00000030'
}

# why: A target somebody else already claims is the collision again, one
# move later. Refusing BEFORE the first write is what keeps a refusal from
# leaving a half-renumbered tree somebody has to unpick by hand.
@test "adr renumber: REFUSES a target number a record already claims, changing nothing (#1021)" {
  _file 'CONTEXT.md' 'ADR-00000030 is the record.'
  run bash "${RENUMBER}" 30 29 "${ROOT}"
  assert_failure
  assert_output --partial '00000029'
  [[ -f "${ROOT}/doc/adr/00000030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-00000030'
}

# why: The state a collision merge actually lands in, and the one the tool
# must not guess its way through: with two records on one number, a prose
# ADR-00000030 names whichever the author had in mind and nothing in the
# tree records which. The refusal names both and points at the resolution
# that IS derivable -- renumber on the branch, where the number has one
# claimant.
@test "adr renumber: REFUSES a number two records claim, naming both (#1021)" {
  printf '%s\n' '# The other one' > "${ROOT}/doc/adr/00000030-config-layout.md"
  _file 'CONTEXT.md' 'ADR-00000030 is ambiguous now.'
  run bash "${RENUMBER}" 00000030-entry-point.md 32 "${ROOT}"
  assert_failure
  assert_output --partial '00000030-entry-point.md'
  assert_output --partial '00000030-config-layout.md'
  [[ -f "${ROOT}/doc/adr/00000030-entry-point.md" ]]
  [[ -f "${ROOT}/doc/adr/00000030-config-layout.md" ]]
}

# why: A record that is not there is a typo, and a tool that renamed
# nothing and reported success would leave the operator believing a sweep
# had happened.
@test "adr renumber: REFUSES a record no file matches, naming what it looked for (#1021)" {
  run bash "${RENUMBER}" 77 78 "${ROOT}"
  assert_failure
  assert_output --partial '00000077'
}

# why: The self-check, and the reason the tool can be trusted with a
# 14-file sweep: it re-reads the tree afterwards and fails if any
# reference to the old number survived. A class nobody thought of shows up
# as a failure here rather than as a green run with a stale pointer.
@test "adr renumber: reports the files it rewrote and leaves no reference behind (#1021)" {
  # Assembled, for the reason the path case above states.
  local _from='00000030'
  _file 'CONTEXT.md' "ADR-${_from} and doc/adr/${_from}-entry-point.md."
  _file 'doc/changelog/CHANGELOG.md' '- something (ADR-00000030)'
  run bash "${RENUMBER}" 30 32 "${ROOT}"
  assert_success
  assert_output --partial 'CONTEXT.md'
  assert_output --partial 'doc/changelog/CHANGELOG.md'
  run grep -rn '00000030' "${ROOT}"
  assert_failure
}
