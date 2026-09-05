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

# adr-refs: fixture 99990029 99990030 99990032
# Those three numbers name the throwaway registry a case builds under
# ${ROOT}, never this tree's. Declaring them is what stops the verb from
# renumbering the fixtures out from under the assertions that guard it,
# in every reference class at once -- including the bare numbers these
# cases pass to it as ARGUMENTS. Any OTHER number here is this tree's.
#
# They are in the 9999NNNN band because a declaration may not name a
# number a RECORD claims: the two readings of such a pointer -- this
# file's fixture, and this tree's record -- are both true and nothing
# tells them apart, so the declaration would exempt a live pointer as
# quietly as a fixture one. Numbered here, forgetting the declaration is
# LOUD: the reference dangles and the lint names it. These cases read as
# the 00000030 collision the record describes; the digits are a fixture's.
# See script/adr/references.sh.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  RENUMBER="/source/script/adr/renumber.sh"
  ROOT="${BATS_TEST_TMPDIR}/r"
  mkdir -p "${ROOT}/doc/adr" "${ROOT}/doc/test" "${ROOT}/test/bats/unit"
  printf '%s\n' '# The record' > "${ROOT}/doc/adr/99990030-entry-point.md"
  printf '%s\n' '# Another' > "${ROOT}/doc/adr/99990029-early-return.md"
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
  _file 'CONTEXT.md' 'The entry point is base'"'"'s (ADR-99990030).'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  [[ -f "${ROOT}/doc/adr/99990032-entry-point.md" ]]
  [[ ! -e "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
}

# why: The path form carries the slug, which is what makes it the one
# reference class that stays unambiguous even where the number does not --
# and the class a rewrite of `ADR-<n>` alone would leave behind.
@test "adr renumber: rewrites a doc/adr path reference, slug and all (#1021)" {
  # Assembled from variables, and the reason is this case's own subject: a
  # literal `doc/adr/NNNNNNNN-<slug>.md` in THIS file is a reference in the
  # real tree, where `entry-point` names no record -- so the fixture
  # spelled the obvious way would fail the ADR-reference lint.
  local _from='99990030' _to='99990032'
  _file 'test/bats/unit/init_spec.bats' \
    "  local _adr=/source/doc/adr/${_from}-entry-point.md"
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
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
  _index '| 99990029 -- early return | keep | P1 | note |' \
    '| 99990030 -- the entry point | keep | inv 6 | note |'
  _file 'test/bats/unit/lint_spec.bats' '  _touch_adr "99990030-fixture.md"'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/doc/adr/README.md"
  assert_output --partial '| 99990032 -- the entry point |'
  refute_output --partial '| 99990030 --'
  run cat "${ROOT}/test/bats/unit/lint_spec.bats"
  assert_output --partial '"99990030-fixture.md"'
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
    '@test "the placeholder and ADR-99990030 name the convention identically" {' \
    '}'
  _file 'doc/test/unit.md' \
    'Unit specs under `test/bats/unit/`: **99 tests**.' '' \
    '<!-- generated: catalogue sections -->' \
    '### test/bats/unit/init_spec.bats (99)' \
    '| `the placeholder and ADR-99990030 name the convention identically` | stale |' \
    '<!-- /generated -->'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/test/bats/unit/init_spec.bats"
  assert_output --partial 'ADR-99990032 name the convention'
  run cat "${ROOT}/doc/test/unit.md"
  assert_output --partial 'ADR-99990032 name the convention'
  refute_output --partial 'ADR-99990030'
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
    'The acceptance bringup is base'"'"'s orchestrator (ADR-99990030), which' \
    'this paragraph says by hand -- no generator wrote it.' '' \
    '<!-- generated: catalogue sections -->' '<!-- /generated -->'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/doc/test/unit.md"
  assert_output --partial 'orchestrator (ADR-99990032)'
  refute_output --partial 'ADR-99990030'
  # Still regenerated: the hand-written half being rewritten must not cost
  # the rebuild of the half that is derived.
  assert_output --partial '### test/bats/unit/init_spec.bats (1)'
  refute_output --partial '**99 tests**'
}

# why: The tool corrupting its own spec. A spec that builds a throwaway
# registry numbers it where no record claims, and every form of every
# other number it writes is left alone -- the `ADR-<n>` and `adr/<n>-`
# forms AND the bare numbers it passes to this tool as ARGUMENTS, which a
# heuristic once told apart per class: the first two moved, the third did
# not, and the spec's setup and its command named different records with
# the survivor self-check and the lint both green. Only the number this
# run was GIVEN is a target, in any class.
@test "adr renumber: rewrites the number it was given and no other (#1021)" {
  local _own='00000098' _other='00000099'
  _file 'test/bats/unit/lint_spec.bats' \
    "# adr-refs: fixture ${_own}" \
    "  : > \"\${T}/doc/adr/${_own}-fixture.md\"" \
    "  run bash \"\${RENUMBER}\" ${_own} ${_other} \"\${T}\"" \
    "  # the fixture record is ADR-${_own} throughout" \
    '  # and this tree'"'"'s record is ADR-99990030'
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/test/bats/unit/lint_spec.bats"
  assert_output --partial "doc/adr/${_own}-fixture.md"
  assert_output --partial "ADR-${_own}"
  assert_output --partial "${_own} ${_other}"
  # The pointer at the record that DID move, in the same file, moved.
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
}

# why: The other end of the same refusal. Moving a record ONTO a number
# some file declares its own leaves the tree in the state the refusal
# above exists to keep out of it -- a declaration naming a number a record
# claims -- and the run that produced it reported success. The lint fails
# the tree afterwards, which is a red gate produced BY the documented
# command; refused before the rename, nothing is written at all.
@test "adr renumber: REFUSES a target number a file declares its own fixture (#1021)" {
  _file 'test/bats/unit/lint_spec.bats' \
    '#!/usr/bin/env bats' \
    '# adr-refs: fixture 99990032' \
    '  : > "${T}/doc/adr/99990032-fixture.md"'
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_failure
  assert_output --partial 'test/bats/unit/lint_spec.bats'
  [[ -f "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  [[ ! -e "${ROOT}/doc/adr/99990032-entry-point.md" ]]
}

# why: The half of that rule the verb can lose on its own. A declaration
# exempts the NUMBERS it names, not the file that carries one: both of this
# tree's declaring specs also point at real records, so a whole-file drop
# leaves a live pointer unswept -- and where that pointer is a `# why:`
# block, the generator publishes it as a catalogue row, the rewrite fixes
# the row, the regeneration puts the old number straight back, and the run
# ends on a survivor with the record already moved. Asserted here on the
# VERB because nothing else runs it: the lint reads the same declaration
# through the same reader, and its half is asserted in
# adr_numbering_spec.bats, so without this case the verb could go back to
# a whole-file exemption with every spec green.
@test "adr renumber: a declaration exempts its numbers, not its file (#1021)" {
  _file 'test/bats/unit/lint_spec.bats' \
    '#!/usr/bin/env bats' \
    '# adr-refs: fixture 99990029' \
    '  : > "${T}/doc/adr/99990029-early-return.md"' \
    '  # the fixture registry is ADR-99990029' '' \
    '# why: the convention ADR-99990030 records' \
    '@test "a described case" {' \
    '  true' \
    '}'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/test/bats/unit/lint_spec.bats"
  # Its own registry's number: untouched, in both classes.
  assert_output --partial 'doc/adr/99990029-early-return.md'
  assert_output --partial 'ADR-99990029'
  # This tree's pointer, in the same file: swept like any other.
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
  # And the row the generator publishes from that marker moved with it,
  # which is the step a whole-file exemption cannot reach.
  run cat "${ROOT}/doc/test/unit.md"
  assert_output --partial 'the convention ADR-99990032 records'
}

# why: The whole-file drop's other half, and the state it left behind. A
# spec that builds a throwaway registry still carries pointers at THIS
# tree's -- a `# why:` block naming the record a case came from, which the
# generator then publishes verbatim as a catalogue row. Dropped whole, the
# marker was never rewritten, so the rewrite pass fixed the catalogue and
# the regeneration immediately put the old number back: the verb aborted
# on a survivor no message could attribute, with the record already moved
# and 25 files rewritten. A declaration exempts the numbers it NAMES, and
# one that names none exempts nothing.
@test "adr renumber: a declaration that names no number hides no reference (#1021)" {
  _file 'test/bats/unit/lint_spec.bats' \
    '#!/usr/bin/env bats' \
    '# adr-refs: fixture' '' \
    '# why: the convention ADR-99990030 records' \
    '@test "a described case" {' \
    '  true' \
    '}'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/test/bats/unit/lint_spec.bats"
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
  # The catalogue row is REGENERATED from that marker, so the rewrite
  # holding and the regeneration agreeing are the same assertion.
  run cat "${ROOT}/doc/test/unit.md"
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
}

# why: The one state in which this verb cannot tell a reference from a
# fixture: a number a file DECLARES its own that a record also claims.
# Both readings are true at once and nothing in the tree says which any
# one pointer is, so the sweep skips that whole file and reports a
# complete repair -- with a live pointer to the moved record still in it,
# and the lint reading the same declaration and agreeing. Refused before
# the first write, and named, the way two claimants on one number are: the
# repair derivable here is to renumber the FIXTURE, which is what the lint
# asks for too. It is also why the survivor path below no longer has a
# captive-marker branch -- that state is refused, not diagnosed after the
# record has moved.
@test "adr renumber: REFUSES a number a file declares its own fixture (#1021)" {
  _file 'test/bats/unit/lint_spec.bats' \
    '#!/usr/bin/env bats' \
    '# adr-refs: fixture 99990030' '' \
    '# why: the convention ADR-99990030 records' \
    '@test "a described case" {' \
    '  true' \
    '}'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_failure
  # The file whose declaration covers the number, which is the repair site.
  assert_output --partial 'test/bats/unit/lint_spec.bats'
  # And nothing was written: the record is still where it was.
  [[ -f "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  [[ ! -e "${ROOT}/doc/adr/99990032-entry-point.md" ]]
}

# why: The population, and the property that keeps this verb and the ADR
# lint from disagreeing about what a reference is -- they read one. A
# tree the checkout declares derived is not swept: a materialised old
# release and a wrapper transcript are records of what WAS said, so
# rewriting one falsifies it, and a finding the verb cannot reach is a
# red gate with no repair path through the verb.
@test "adr renumber: leaves a tree the checkout declares derived alone (#1021)" {
  _file '.gitignore' 'log/'
  _file 'log/test/2026-09-04-abcdef12.log' 'the transcript said ADR-99990030'
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-99990032'
  run cat "${ROOT}/log/test/2026-09-04-abcdef12.log"
  assert_output --partial 'ADR-99990030'
}

# why: The verb's half of the population the lint reads. A file that is in
# the working tree and not yet in the index is not derived -- nothing
# declares it so -- and the walk tier, which is the tier `just test` takes
# from inside the container, cannot tell it from a tracked one anyway. So
# the verb has to sweep it here, where git CAN answer, or the local gate
# reddens on a finding no documented command repairs.
@test "adr renumber: sweeps an untracked file in a checkout (#1021)" {
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  _file 'scratch.md' 'A note citing ADR-99990030.'
  git -C "${ROOT}" init -q
  git -C "${ROOT}" add doc CONTEXT.md
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  run cat "${ROOT}/scratch.md"
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
}

# why: What `sed -i` does to a symlink, which is replace it with a regular
# copy of its target and report success. A symlink has no content of its
# own, so there is nothing here to rewrite: the bytes belong to the target,
# and the target is swept like any other file. base survived this only by
# an ordering accident -- all eight of its wrapper links sort after their
# `dist/` targets in `git ls-files`, so the pattern no longer matched by
# the time the link was reached. This case pins the opposite order.
@test "adr renumber: a tracked symlink is not replaced by a copy of its target (#1021)" {
  _file 'zz/target.md' 'The rule is ADR-99990030.'
  ln -s zz/target.md "${ROOT}/a-link.md"
  # A checkout, because this is the tier `just adr renumber` runs on and
  # the one whose population carries symlinks at all. `a-link.md` sorts
  # BEFORE `zz/target.md`, so the link is reached while the old number is
  # still there.
  git -C "${ROOT}" init -q
  git -C "${ROOT}" add -A
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  [[ -L "${ROOT}/a-link.md" ]]
  run cat "${ROOT}/zz/target.md"
  assert_output --partial 'ADR-99990032'
  refute_output --partial 'ADR-99990030'
}

# why: The other half of not writing through a link: a reference reachable
# only through one is a reference this verb cannot repair, because the file
# holding the bytes is a tree the checkout declares derived and rewriting
# it would falsify a record of what was said. Refused and named, rather
# than reported as a complete sweep -- the lint reads the same link and
# would fail on it, so a silent pass here is the disagreement the shared
# population exists to prevent.
@test "adr renumber: REFUSES a reference reachable only through a symlink (#1021)" {
  _file '.gitignore' 'ignored/'
  _file 'ignored/target.md' 'The rule is ADR-99990030.'
  ln -s ignored/target.md "${ROOT}/link.md"
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_failure
  assert_output --partial 'link.md'
}

# why: The verb's half of "a population of nothing is not an answer". The
# lint refuses a scan root whose population is empty; this verb read the
# same reader and, handed no files, renamed the record, swept nothing and
# reported a complete sweep -- the one report it must never make wrongly,
# since its whole claim is that the reference set is derived. A root with
# a doc/adr/ in it has at least the record itself to read, so no files at
# all is a reader that has stopped matching, not a tree with no
# references.
@test "adr renumber: REFUSES a root whose population is empty, changing nothing (#1021)" {
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  # One line that covers the whole tree.
  _file '.gitignore' '*'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_failure
  assert_output --partial 'no file'
  [[ -f "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-99990030'
}

# why: A target somebody else already claims is the collision again, one
# move later. Refusing BEFORE the first write is what keeps a refusal from
# leaving a half-renumbered tree somebody has to unpick by hand.
@test "adr renumber: REFUSES a target number a record already claims, changing nothing (#1021)" {
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  run bash "${RENUMBER}" 99990030 99990029 "${ROOT}"
  assert_failure
  assert_output --partial '99990029'
  [[ -f "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-99990030'
}

# why: The state a collision merge actually lands in, and the one the tool
# must not guess its way through: with two records on one number, a prose
# `ADR-` token naming it names whichever the author had in mind and
# nothing in the tree records which. The refusal names both and points at
# the resolution that IS derivable -- renumber on the branch, where the
# number has one claimant. Spelled with the token rather than the number,
# because this block is published verbatim as a doc/test row and this file
# declares that number its own: written out, the row would be a reference
# the verb rewrites and the regeneration restores.
@test "adr renumber: REFUSES a number two records claim, naming both (#1021)" {
  printf '%s\n' '# The other one' > "${ROOT}/doc/adr/99990030-config-layout.md"
  _file 'CONTEXT.md' 'ADR-99990030 is ambiguous now.'
  run bash "${RENUMBER}" 99990030-entry-point.md 32 "${ROOT}"
  assert_failure
  assert_output --partial '99990030-entry-point.md'
  assert_output --partial '99990030-config-layout.md'
  [[ -f "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  [[ -f "${ROOT}/doc/adr/99990030-config-layout.md" ]]
}

# why: The record this verb exists for is the one a branch authored this
# morning, and `git add` is not part of authoring an ADR. `git mv` refuses
# a path it does not track, so the git tier renamed nothing, ignored the
# refusal and reported a renumber -- leaving the record at its old number
# with every reference in the tree rewritten to the new one, and the
# survivor check unable to see it because the survivor check greps for the
# number the sweep has just removed everywhere.
@test "adr renumber: moves a record git does not track yet (#1021)" {
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  git -C "${ROOT}" init -q
  # Everything BUT the record, which is the state a freshly written ADR is
  # in: authored, referenced, not yet staged.
  git -C "${ROOT}" add CONTEXT.md doc/test
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  [[ -f "${ROOT}/doc/adr/99990032-entry-point.md" ]]
  [[ ! -e "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-99990032'
}

# why: A rename that did not happen is not a renumber. `_renumber_move`
# ran `git mv` and returned 0 whatever it said, so any failure -- a
# concurrent `index.lock`, a permission, a repository state -- came back
# as "N reference file(s) rewritten" and exit 0, with the record still at
# its old number and every pointer at the tree moved to the new one. The
# header promises the opposite ("a refusal leaves nothing half-renumbered")
# and the rename is now the FIRST write, so there is nothing to unpick.
@test "adr renumber: REFUSES when the rename fails, changing nothing (#1021)" {
  _file 'CONTEXT.md' 'ADR-99990030 is the record.'
  git -C "${ROOT}" init -q
  git -C "${ROOT}" add -A
  # An index git cannot take. Not a contrivance: it is what a second git
  # process in the same checkout leaves behind, and the point is that the
  # tool's answer does not depend on which failure it was.
  : > "${ROOT}/.git/index.lock"
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_failure
  assert_output --partial '99990030-entry-point.md'
  [[ -f "${ROOT}/doc/adr/99990030-entry-point.md" ]]
  run cat "${ROOT}/CONTEXT.md"
  assert_output --partial 'ADR-99990030'
  refute_output --partial 'ADR-99990032'
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
  local _from='99990030'
  _file 'CONTEXT.md' "ADR-${_from} and doc/adr/${_from}-entry-point.md."
  _file 'doc/changelog/CHANGELOG.md' '- something (ADR-99990030)'
  run bash "${RENUMBER}" 99990030 99990032 "${ROOT}"
  assert_success
  assert_output --partial 'CONTEXT.md'
  assert_output --partial 'doc/changelog/CHANGELOG.md'
  run grep -rn '99990030' "${ROOT}"
  assert_failure
}
