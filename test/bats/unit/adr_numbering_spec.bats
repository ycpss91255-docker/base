#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/adr_numbering.sh -- the ADR-numbering
# lint. The registry is the filesystem: ADR files live at
# doc/adr/NNNNNNNN-<slug>.md. The lint FAILS on a duplicate ADR number or a
# malformed filename, and WARNS (exit 0) on a numbering gap. The detection
# runs against a controlled temp REPO_ROOT so the spec is independent of the
# live tree's contents; a final case drives the REAL doc/adr/ to prove it
# passes today with the intentional 00000009 gap warned-not-failed.
#
# why: Unit tests for `script/test/drivers/adr_numbering.sh`
# (`_run_adr_numbering`, refs #808), the ADR-numbering lint. The registry is
# the filesystem (`doc/adr/NNNNNNNN-<slug>.md`): the lint FAILS on a
# duplicate ADR number or a malformed filename and WARNS (exit 0) on a
# numbering gap. Driven at the driver CLI over throwaway fixture `doc/adr/`
# trees, plus a real-tree guard that the live `doc/adr/` passes today with
# the intentional `00000009` gap warned.

# adr-refs: fixture 00000001 00000002 00000007
# Those three numbers name the throwaway registries these cases build
# under a temp root, never this tree's, so neither the lint nor
# `just adr renumber` reads them here. Every OTHER number in this file is
# this tree's -- the `# why:` block below citing
# doc/adr/00000008-coverage-sharded-pr-gate.md is a live pointer, and the
# generator publishes that marker verbatim as a doc/test/unit.md row. See
# script/adr/references.sh for why the declaration is about numbers and
# not about the file.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # issueref_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/adr_numbering.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/adr"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
  # `if`, not `&&`: SHIM_DIR is set by only two of the cases, and a bare
  # `[[ ... ]] && ...` as teardown's LAST statement would fail teardown
  # (and so the test) for every case that never shimmed anything.
  if [[ -n "${SHIM_DIR:-}" ]]; then
    rm -rf "${SHIM_DIR}"
  fi
}

# _touch_adr <NNNNNNNN-slug.md> -- create an empty ADR fixture file.
_touch_adr() {
  : > "${SCRATCH}/doc/adr/${1}"
}

# _shim_early_closing_reader -- populate ${SHIM_DIR} with a `head` that
# closes the pipe before reading and a `sort` that writes only after a
# delay, so a `... | sort | head` min/max computation loses the SIGPIPE
# race on EVERY run instead of a few percent of them. The real race is
# scheduler-dependent (sort writing while head has already left); these
# shims pin the losing interleaving so the regression is deterministic.
# A driver that computes min/max in-shell never execs either one.
_shim_early_closing_reader() {
  SHIM_DIR="$(mktemp -d)"
  cat > "${SHIM_DIR}/head" << 'EOF'
#!/bin/sh
# A reader that already has what it needs: leave at once, so the write
# end of the pipe has no reader left.
exit 0
EOF
  cat > "${SHIM_DIR}/sort" << 'EOF'
#!/bin/sh
# Drain stdin, sort for real, then write LATE -- the losing side of the
# race every time.
_data="$(/usr/bin/sort "$@")"
sleep 0.2
printf '%s\n' "${_data}"
EOF
  chmod +x "${SHIM_DIR}/head" "${SHIM_DIR}/sort"
}

# _run_driver_strict -- run _run_adr_numbering the way the lint phase
# runs it: a fresh `set -euo pipefail` shell, ${SHIM_DIR} first on PATH.
# bats' own `run` clears errexit, which is exactly the setting that turns
# a 141 pipeline into a silent abort, so the production strictness has to
# be re-established in a child shell for the failure mode to show at all.
#
# The strict shell is a script FILE, never `bash -c '...'`. The coverage
# shard runs bash under kcov, which counts lines from xtrace with a PS4
# that expands ${BASH_SOURCE}; at the top level of a `bash -c` string that
# array is EMPTY, so the first command traced after `set -u` dies
# "BASH_SOURCE: unbound variable" before the driver is ever reached. That
# aborts the harness, not the driver, and it is why these cases passed
# plain and failed under coverage -- i.e. failed in the musl/coreutils
# container where the SIGPIPE defect is the one that actually reproduces.
# A script file populates BASH_SOURCE[0], so the same strict shell now
# survives instrumentation and the shims decide the outcome. The identical
# interaction is documented in sourceable_scripts_spec.bats.
_run_driver_strict() {
  local _runner="${SCRATCH}/run_driver_strict.sh"
  # Quoted heredoc: every expansion below belongs to the strict child, not
  # to this shell.
  cat > "${_runner}" << 'EOF'
set -euo pipefail
source /source/dist/script/docker/lib/_lib.sh
_die() { local _ev="${1}"; shift; printf "die %s: %s\n" "${_ev}" "$*"; exit 1; }
source /source/script/test/drivers/adr_numbering.sh
REPO_ROOT="${SCRATCH_ROOT}"
PATH="${SHIM_DIR}:${PATH}"
_run_adr_numbering
EOF
  run env SHIM_DIR="${SHIM_DIR}" SCRATCH_ROOT="${SCRATCH}" bash "${_runner}"
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: failures
# ════════════════════════════════════════════════════════════════════

# why: Duplicate number fails, both files named
@test "_run_adr_numbering: FAILS on a duplicate ADR number, naming both files (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000002-gamma.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000002"* ]]
  [[ "${output}" == *"00000002-beta.md"* ]]
  [[ "${output}" == *"00000002-gamma.md"* ]]
}

# why: Malformed filename fails, file named
@test "_run_adr_numbering: FAILS on a malformed filename, naming the file (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "notes.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.md"* ]]
}

# why: Non-8-digit prefix fails
@test "_run_adr_numbering: FAILS on a too-short (non-8-digit) number prefix (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "0001-short.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"0001-short.md"* ]]
}

# why: README.md index exempt from the naming contract
@test "_run_adr_numbering: EXEMPTS doc/adr/README.md (the index), not flagged malformed (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  : > "${SCRATCH}/doc/adr/README.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *"README.md"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: passes (gaps allowed)
# ════════════════════════════════════════════════════════════════════

# why: Gap warned, exit 0
@test "_run_adr_numbering: PASSES a clean set WITH a gap, warning the gap (exit 0) (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  # 00000003 intentionally missing -> advisory gap, not a failure.
  _touch_adr "00000004-delta.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"00000003"* ]]
  [[ "${output}" == *"clean"* ]]
}

# why: Contiguous set clean, no gap line
@test "_run_adr_numbering: PASSES a clean contiguous set with no gap warning (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000003-gamma.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *"gap"* ]]
}

# why: Gaps are advisory, not failures
@test "_run_adr_numbering: does NOT flag a gap as a duplicate or malformed (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000005-epsilon.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  # 00000002..00000004 are all advisory gaps; none is a failure.
  [[ "${output}" == *"00000002"* ]]
  [[ "${output}" == *"00000004"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: no early-closing-reader pipeline
#
# The min/max scan must not hand its exit status to a reader that stops
# reading. `sort` writing into a departed `head` dies of SIGPIPE (141),
# `pipefail` makes that the pipeline's status, and the bare assignment
# under `set -e` kills the whole lint phase with no message at all --
# which fails the local-CI stamp, not a test. These two cases pin the
# losing interleaving so the defect cannot come back intermittently.
# ════════════════════════════════════════════════════════════════════

# why: No pipeline status owned by a departing reader
@test "_run_adr_numbering: an early-closing reader cannot abort the min/max scan (#898)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000003-gamma.md"
  _shim_early_closing_reader
  _run_driver_strict
  # assert_success, not a bare `[ "${status}" -eq 0 ]`: the child shell is
  # where anything goes wrong here, and the bare test reports only its own
  # source line, so a real abort in there arrives with no message at all.
  assert_success
  [[ "${output}" == *"clean"* ]]
}

# why: In-shell range still bounds the gap scan
@test "_run_adr_numbering: min/max stay correct with sort/head unusable (#898)" {
  _touch_adr "00000002-beta.md"
  _touch_adr "00000005-epsilon.md"
  _shim_early_closing_reader
  _run_driver_strict
  assert_success
  # min=00000002, max=00000005 -> 3 and 4 are the advisory gaps, and
  # neither end of the run is itself reported as missing.
  [[ "${output}" == *"00000003"* ]]
  [[ "${output}" == *"00000004"* ]]
  [[ "${output}" != *"gap at 00000002"* ]]
  [[ "${output}" != *"gap at 00000005"* ]]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: the references into the registry (base#1021)
#
# A registry nothing points at is half a registry. The renumber that
# followed the 00000030 collision touched 14 files and was left
# incomplete in three of them -- the index row and two audit conclusions
# still named the old number -- and every gate stayed green, because a
# stale number in prose was read by nothing.
# ════════════════════════════════════════════════════════════════════

# _write <relpath> <line>... -- a fixture file somewhere in the scan root.
_write() {
  local _rel="$1"
  shift
  mkdir -p "${SCRATCH}/$(dirname -- "${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# _index <row>... -- doc/adr/README.md with the audit table header and the
# given rows. The header is what marks the document as the index; a
# README without one is not one.
_index() {
  {
    printf '%s\n' '# ADR index'
    printf '%s\n' '| ADR | Verdict | Serves | Note |'
    printf '%s\n' '|---|---|---|---|'
    printf '%s\n' "$@"
  } > "${SCRATCH}/doc/adr/README.md"
}

# why: The reference that outlives its record. A renumber frees the old
# number, so every `ADR-<old>` left behind names nothing -- and this is
# the only shape of missed reference a checkout can still recognise.
@test "_run_adr_numbering: FAILS on an ADR- reference to a number no record claims (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  _write 'CONTEXT.md' 'The rule is written down in ADR-00000007.'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000007"* ]]
  [[ "${output}" == *"CONTEXT.md"* ]]
}

# why: The shape that survives a collision repair. The number still
# resolves -- another record took it -- so nothing about the number is
# wrong; the SLUG beside it is what says the pointer no longer names what
# the author meant.
@test "_run_adr_numbering: FAILS on a doc/adr path whose number and slug name no file (#1021)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '| 00000002 -- beta | keep | mechanism | note |'
  # Assembled from a variable rather than typed out, and this is the same
  # hazard the case is about: a literal `doc/adr/NNNNNNNN-<slug>.md` in
  # THIS file is a reference in the real tree, where that slug names no
  # record -- so a fixture spelled the obvious way would fail the
  # real-tree case below.
  local _num='00000002'
  _write 'CONTEXT.md' "See doc/adr/${_num}-alpha.md for the argument."
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000002-alpha.md"* ]]
}

# why: The difference between a reference and a FIXTURE, DECLARED rather
# than guessed at -- and declared per NUMBER. Every reference form
# carrying a declared number is dropped, not the ones some heuristic
# recognised, which is what let a renumber rewrite half of one and leave
# the assertions naming the other record.
@test "_run_adr_numbering: a number a file declares its own is not scanned (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled from a variable, for the reason the mispaired case above
  # states: a literal dangling reference in THIS file is a dangling
  # reference in the real tree, which the real-tree case below reads.
  local _ghost='00000099'
  _write 'test/bats/unit/x_spec.bats' \
    "# adr-refs: fixture ${_ghost}" \
    "  : > \"\${SCRATCH}/doc/adr/${_ghost}-fixture.md\"" \
    "  printf 'ADR-${_ghost}'"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: The half a whole-FILE drop resolved to "pass". A spec that builds a
# throwaway registry still says things about THIS tree's -- a `# why:`
# block naming the record a case came from, a comment naming the record
# whose shape the check was written for -- and dropping the file whole
# made those pointers invisible here and unreachable by the verb, which is
# the stale-pointer-under-a-green-gate this check exists to prevent. The
# declaration names numbers; a number it does not name is this tree's.
@test "_run_adr_numbering: a number the declaration does not name is this tree's (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the cases above state.
  local _ghost='00000099' _own='00000098'
  _write 'test/bats/unit/x_spec.bats' \
    "# adr-refs: fixture ${_own}" \
    "  printf 'ADR-${_own}'" \
    "  # the record this case came from is ADR-${_ghost}"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ADR-${_ghost}"* ]]
  [[ "${output}" != *"ADR-${_own}"* ]]
}

# why: Where the grammar's residue points. A declaration this reader
# cannot parse -- no number list, the shape the whole-file drop used --
# exempts NOTHING and is itself a finding. The alternative is a marker
# that has quietly stopped protecting the fixtures it was written for
# while every gate stays green, which is the failure mode the declaration
# exists to remove.
@test "_run_adr_numbering: a declaration that names no number exempts nothing (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the cases above state.
  local _ghost='00000099'
  _write 'test/bats/unit/x_spec.bats' \
    '# adr-refs: fixture' \
    "  printf 'ADR-${_ghost}'"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ADR-${_ghost}"* ]]
  [[ "${output}" == *"x_spec.bats:1"* ]]
}

# why: The residue the per-number rule keeps, and the only site at which
# it bites. A declaration is per FILE, and a `# why:` marker is the one
# thing in a spec that LEAVES the file: the catalogue generator publishes
# it verbatim into doc/test, a document that declares nothing. A DECLARED
# number written there therefore arrives in the catalogue as this tree's
# reference, and the verb has no state to reach -- it rewrites the
# published row, the regeneration puts the number straight back from the
# marker it may not touch, and the run aborts half-way with the record
# already moved. The marker is the one thing a repair can edit, so the
# finding names it.
@test "_run_adr_numbering: FAILS on a declared number a test's marker publishes (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the cases above state.
  local _own='00000098'
  _write 'test/bats/unit/x_spec.bats' \
    '#!/usr/bin/env bats' \
    "# adr-refs: fixture ${_own}" '' \
    "# why: the convention ADR-${_own} records" \
    '@test "a described case" {' \
    '  true' \
    '}'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:5"* ]]
  [[ "${output}" == *"${_own}"* ]]
}

# why: The same shape at the file-level marker, which the generator
# publishes as the section BLURB rather than a row. One grammar, two
# sites, and a rule that read only the attached blocks would leave the
# other half of the published text unchecked.
@test "_run_adr_numbering: FAILS on a declared number the file blurb publishes (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the cases above state.
  local _own='00000098'
  _write 'test/bats/unit/x_spec.bats' \
    '#!/usr/bin/env bats' \
    "# adr-refs: fixture ${_own}" \
    "# why: this spec builds its own registry; ADR-${_own} is the record" \
    '# it takes its shape from.' '' \
    '@test "a case" {' \
    '  true' \
    '}'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats"* ]]
  [[ "${output}" == *"${_own}"* ]]
}

# why: The third published site, and the one ADR-00000034 records as
# having actually cost: a `@test` NAME carrying the number is a ROW in a
# generated catalogue, published whether the test carries a marker or not.
# A check that read only the prose would pass a spec whose names are the
# half that comes straight back after every regeneration.
@test "_run_adr_numbering: FAILS on a declared number a test name publishes (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the cases above state.
  local _own='00000098'
  _write 'test/bats/unit/x_spec.bats' \
    '#!/usr/bin/env bats' \
    "# adr-refs: fixture ${_own}" '' \
    "@test \"the placeholder and ADR-${_own} say one thing\" {" \
    '  true' \
    '}'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:4"* ]]
  [[ "${output}" == *"${_own}"* ]]
}

# why: The blind spot the guess created, and it was live. The rule was a
# two-character lookback: a `doc/adr/` path preceded by `}` was taken for
# somebody's fixture. coverage_badge_spec.bats writes
# `"${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"` as a pointer at
# this tree's OWN registry, so a renumber of that record would leave a
# stale pointer under a green lint -- and a rule whose default on the
# shape it does not recognise is "pass" is not a check.
@test "_run_adr_numbering: FAILS on a doc/adr path rooted in a shell expansion (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the case above states.
  local _ghost='00000099'
  _write 'test/bats/unit/x_spec.bats' \
    "  local _adr=\"\${REPO_ROOT}/doc/adr/${_ghost}-ghost.md\""
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${_ghost}-ghost.md"* ]]
}

# why: The site the hand renumber actually missed. The index row is the
# one place every record is named exactly once, so a record with no row is
# a record the index has lost track of.
@test "_run_adr_numbering: FAILS when the index has no row for a record (#1021)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000002"* ]]
  [[ "${output}" == *"README.md"* ]]
}

# why: The same failure in its other direction, and the exact state the
# 00000030 renumber left behind: the record moved and its row did not, so
# the index names a number that is nobody's.
@test "_run_adr_numbering: FAILS when the index carries a row for no record (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '| 00000009 -- ghost | keep | mechanism | note |'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000009"* ]]
}

# why: Two rows on one number is what a collision looks like in the index,
# and taking the first would make the check agree with whichever row was
# written first rather than with the tree.
@test "_run_adr_numbering: FAILS when two index rows carry the same number (#1021)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '| 00000001 -- alpha again | keep | mechanism | note |' \
    '| 00000002 -- beta | keep | mechanism | note |'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000001"* ]]
}

# why: Two of the three sites the 00000030 hand repair actually left stale
# were audit-conclusion bullets, not table rows -- and the row check reads
# only `^| NNNNNNNN `, so a recurrence in exactly those two lines stayed
# green. `just adr renumber` disagrees: it rewrites a BARE number ANYWHERE
# in this document, on the stated ground that its 8-digit runs are all ADR
# numbers, its rows opening with one AND its audit conclusions enumerating
# them. Half a document guarded is the same defect one line down.
@test "_run_adr_numbering: FAILS on a bare number outside a row that no record claims (#1021)" {
  _touch_adr "00000001-alpha.md"
  # Assembled, for the reason the mispaired case above states.
  local _ghost='00000099'
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '' '## Audit conclusion' '' \
    "- ${_ghost} -> invariant 6. Postdates the audit; listed for index" \
    '  completeness.'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${_ghost}"* ]]
}

# why: The other spelling the live document actually uses for the same
# conclusion, emphasised rather than bare-leading. One reading of "a bare
# 8-digit run", not a list of the shapes somebody happened to write.
@test "_run_adr_numbering: FAILS on an emphasised bare number no record claims (#1021)" {
  _touch_adr "00000001-alpha.md"
  # Assembled, for the reason the mispaired case above states.
  local _ghost='00000099'
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '' '## Audit conclusion' '' \
    "- **${_ghost}** postdates the audit and is listed for index" \
    '  completeness.'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${_ghost}"* ]]
}

# why: The same rule inside a row, where the note cell carries the numbers
# a verdict points at (`keep (amended by 00000023)`). The row check reads
# the number the row OPENS with and nothing else, so a stale cross-
# reference three columns along is the audit-conclusion gap again.
@test "_run_adr_numbering: FAILS on a bare number in a row's note cell (#1021)" {
  _touch_adr "00000001-alpha.md"
  # Assembled, for the reason the mispaired case above states.
  local _ghost='00000099'
  _index "| 00000001 -- alpha | keep (amended by ${_ghost}) | mechanism | note |"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${_ghost}"* ]]
}

# why: The boundary, and it is load-bearing rather than a concession. The
# index deliberately names a number no record claims -- "`00000009` is an
# intentional gap ... do not invent a `00000009`", twice, in free prose --
# and running the bare check over the whole document reddens the live tree
# on exactly those two lines. That is the one place this lint and the verb
# cannot share a rule: the verb rewrites the number it is MOVING, which has
# a record by construction, and this asks which numbers have none.
@test "_run_adr_numbering: reads a bare number in prose as prose, not a row (#1021)" {
  _touch_adr "00000001-alpha.md"
  # Assembled, for the reason the mispaired case above states.
  local _gap='00000009'
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '' '## Anomalies (resolved)' '' \
    "- **\`${_gap}\` is an intentional gap.** There is no ADR-9 and none" \
    "  will be back-filled. Do not invent a \`${_gap}\`."
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: The passing shape, so the three failures above are read as a
# contract rather than as a lint that dislikes index tables.
@test "_run_adr_numbering: PASSES when every record has one row and every reference resolves (#1021)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |' \
    '| 00000002 -- beta | keep | mechanism | note |'
  # Assembled, for the reason the mispaired case above states.
  local _num='00000001'
  _write 'CONTEXT.md' "ADR-00000002 and doc/adr/${_num}-alpha.md both resolve."
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: the population (base#1021)
#
# The verb and the lint have to agree about which files can carry a
# reference. They did not: `just adr renumber` swept the files the
# checkout keeps true and reported a complete sweep, and this lint then
# read the whole filesystem -- so a materialised old release under
# .prev-release/ or a wrapper transcript under log/ turned a finished
# repair into a red gate with no repair path through the verb.
# ════════════════════════════════════════════════════════════════════

# why: The tier the local run actually takes -- a checkout whose git the
# reader cannot query (a worktree inside the test container). What the
# tree DECLARES derived is still not source: an old release and a
# transcript are records of what was said once, and the verb cannot reach
# either, so a finding in one is a red gate with no way to clear it.
@test "_run_adr_numbering: a tree the checkout declares derived carries no reference (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled from a variable, for the reason the mispaired case above
  # states: a literal dangling `ADR-NNNNNNNN` in THIS file is a dangling
  # reference in the real tree, which the real-tree case below reads.
  local _ghost='00000099'
  _write '.gitignore' '.prev-release/' 'log/'
  _write '.prev-release/v0.1.0/CONTEXT.md' "The old release cited ADR-${_ghost}."
  _write 'log/test/2026-09-04-abcdef12.log' "a transcript naming ADR-${_ghost}"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: A symlink is a file this repo keeps true. `git ls-files` lists the
# eight wrapper links at the root, so the git tier reads them; the walk
# printed only `-type f` and did not, which made the two tiers' populations
# differ by eight files -- and a lint and a verb that read one population
# is the whole point of the shared reader. The reference here is reachable
# ONLY through the link, so nothing but the link can report it.
@test "_run_adr_numbering: a symlink is read as the file it points at (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled from a variable, for the reason the mispaired case above
  # states: a literal dangling `ADR-NNNNNNNN` in THIS file is a dangling
  # reference in the real tree, which the real-tree case below reads.
  local _ghost='00000099'
  _write '.gitignore' 'ignored/'
  _write 'ignored/target.md' "A pointer at ADR-${_ghost}."
  ln -s ../ignored/target.md "${SCRATCH}/doc/link.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/link.md"* ]]
}

# why: The tree's own declaration, read the way the tree actually writes
# it. git needs no trailing slash, and this repo's root .gitignore uses
# none for `.claude` or `CLAUDE.md`. A pattern the reader does not
# recognise is a path this lint scans and the verb never sweeps -- a
# finding with no repair path through the documented command, which is the
# whole reason the two read one population. The residue is unchanged: only
# the root file, and only patterns with no wildcard and no negation.
@test "_run_adr_numbering: an ignored path written without a trailing slash is not read (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled from a variable, for the reason the mispaired case above
  # states: a literal dangling `ADR-NNNNNNNN` in THIS file is a dangling
  # reference in the real tree, which the real-tree case below reads.
  local _ghost='00000099'
  _write '.gitignore' '.claude' 'NOTES.md' '/vendor'
  _write '.claude/note.md' "A session note citing ADR-${_ghost}."
  _write 'NOTES.md' "A scratch note citing ADR-${_ghost}."
  _write 'vendor/old/CONTEXT.md' "A vendored tree citing ADR-${_ghost}."
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: The two tiers have to name ONE population, and only one of them can
# ask git. `just test` reads this checkout from inside the container, where
# a worktree's `.git` is a file naming a gitdir that was never mounted, so
# the WALK is the tier the local gate takes -- and a walk cannot tell a
# tracked file from an untracked one. Dropping the untracked ones where git
# DOES answer therefore made the host verb sweep less than the container
# lint reads: a scratch file citing a dangling number reddens the local
# gate and `just adr renumber` never touches it, which is the red-with-no-
# repair-path the shared population exists to prevent. Not yet tracked is
# not derived.
@test "_run_adr_numbering: an untracked file in a checkout is read like any other (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the case above states.
  local _ghost='00000099'
  _write 'CONTEXT.md' 'ADR-00000001 resolves.'
  _write 'scratch.md' "A scratch note citing ADR-${_ghost}."
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" add doc CONTEXT.md
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"scratch.md"* ]]
}

# why: The other half of the same rule, and the half that keeps it from
# collapsing into "grep everything". Untracked is read; DECLARED DERIVED is
# still not, and in the git tier it is git's own exclude machinery that
# says so rather than this file's reader. A materialised old release and a
# wrapper transcript are records of what WAS said, so a verb that rewrote
# them would falsify them -- the reason the population is pruned at all.
@test "_run_adr_numbering: an untracked but ignored path is still not read (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the case above states.
  local _ghost='00000099'
  _write '.gitignore' 'log/'
  _write 'CONTEXT.md' 'ADR-00000001 resolves.'
  _write 'log/test/2026-09-04-abcdef12.log' "the transcript said ADR-${_ghost}"
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" add doc CONTEXT.md .gitignore
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: An empty answer from the probe is not the answer that the tree is
# empty. `git rev-parse` succeeds anywhere INSIDE a checkout, so a scan
# root that is a subdirectory the checkout declares derived -- a
# materialised release under .prev-release/, a vendored tree -- answers the
# probe and then lists nothing: nothing under it is tracked, and git's own
# excludes drop it from `--others`. Taking that for the population turns
# every file in the tree into no files at all, and a lint over no files is
# clean over anything, silently. Falling back to the walk is how "cannot
# tell" refuses instead of passing, and the verb reads the same population,
# so a sweep cannot go quiet here either.
@test "_run_adr_numbering: a root git answers for but lists nothing is not an empty tree (#1021)" {
  # Assembled, for the reason the case above states.
  local _ghost='00000099'
  # The scan root is a subdirectory of a checkout that declares it derived,
  # which is the one state where the probe succeeds and the listing is
  # empty. The outer tree is the checkout; the inner one is what is linted.
  local _inner="${SCRATCH}/vendor"
  mkdir -p "${_inner}/doc/adr"
  : > "${_inner}/doc/adr/00000001-alpha.md"
  printf '%s\n' \
    '# ADR index' \
    '| ADR | Verdict | Serves | Note |' \
    '|---|---|---|---|' \
    '| 00000001 -- alpha | keep | mechanism | note |' \
    > "${_inner}/doc/adr/README.md"
  printf 'A pointer at ADR-%s.\n' "${_ghost}" > "${_inner}/CONTEXT.md"
  _write '.gitignore' 'vendor/'
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" add .gitignore
  REPO_ROOT="${_inner}"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CONTEXT.md"* ]]
  [[ "${output}" == *"${_ghost}"* ]]
}

# why: The trailing-slash defect's remaining siblings. A pattern with a
# wildcard and no separator is what git matches against a basename at any
# depth, which is exactly what `find -name` matches: read it, and the tier
# that cannot ask git stops keeping a file git drops. The residue this
# leaves is not the same shape as the one it removes -- see the two cases
# below.
@test "_run_adr_numbering: a wildcard the tree writes without a separator is read (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled from a variable, for the reason the mispaired case above
  # states: a literal dangling reference in THIS file is a dangling
  # reference in the real tree, which the real-tree case below reads.
  local _ghost='00000099'
  _write '.gitignore' 'build*'
  _write 'build.log' "a build log naming ADR-${_ghost}"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: What a reader that cannot apply a declaration must do instead of
# quietly widening its population: SAY SO. A negation and a pattern whose
# wildcard sits beside a separator are the two forms whose meaning `find`
# does not reproduce -- git's `*` stops at a `/` and find's does not, and
# nothing in a prune expression re-includes. Skipped silently they put
# files in this lint's population that `just adr renumber` never sweeps,
# which is the red-gate-with-no-repair-path the shared reader exists to
# close; reported, the tree is told which line to spell differently.
@test "_run_adr_numbering: a declaration this reader cannot apply is reported (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  _write '.gitignore' 'vendor/*.md' '!keep.md'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"vendor/*.md"* ]]
  [[ "${output}" == *'!keep.md'* ]]
}

# why: The same report for the declaration this reader never opens at all.
# Only the root file is read, so a nested one is a rule the walk cannot
# apply and git can -- the population splits on it exactly as it split on
# a trailing slash, and the finding is what keeps the split from being
# discovered by a red gate no documented command can clear.
@test "_run_adr_numbering: a nested .gitignore is reported, not ignored (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  _write '.gitignore' 'log/'
  _write 'pkg/.gitignore' 'skip.md'
  _write 'pkg/keep.md' 'ADR-00000001 resolves.'
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pkg/.gitignore"* ]]
}

# why: The same report for the two declarations that are not a
# `.gitignore` at all. `--exclude-standard` is three files, not one: the
# root `.gitignore`, `.git/info/exclude`, and whatever `core.excludesFile`
# names. The git tier applies all three; this reader opens only the first,
# so a path excluded by either of the other two is read here and never
# swept by `just adr renumber` -- the same split as the nested file, by
# the same mechanism, and silent until it reddens a local gate no
# documented command can clear.
@test "_run_adr_numbering: a .git/info/exclude the walk cannot apply is reported (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  mkdir -p "${SCRATCH}/.git/info"
  printf '%s\n' '# comments declare nothing' 'scratch/' \
    > "${SCRATCH}/.git/info/exclude"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"info/exclude"* ]]
}

# why: The per-user half of the same pair, and the one whose effect
# depends on whose machine the walk runs on -- which is exactly why it is
# reported rather than applied: a lint that read the operator's global
# ignore file would answer differently in the container and on the host,
# and neither answer would be visible in the tree.
@test "_run_adr_numbering: a core.excludesFile the walk cannot apply is reported (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  mkdir -p "${SCRATCH}/home"
  printf '%s\n' 'scratch/' > "${SCRATCH}/home/ignore"
  printf '%s\n' '[core]' "  excludesFile = ${SCRATCH}/home/ignore" \
    > "${SCRATCH}/home/.gitconfig"
  HOME="${SCRATCH}/home" run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"home/ignore"* ]]
}

# why: The boundary that keeps the pair above from being noise. A
# declaration with no rules in it declares nothing, and reporting a
# `.git/info/exclude` that carries only git's own seeded comments would be
# a finding on every checkout with no repair to make.
@test "_run_adr_numbering: an exclude file carrying no rule is not reported (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  mkdir -p "${SCRATCH}/.git/info"
  printf '%s\n' '# git seeds this file with comments and nothing else' '' \
    > "${SCRATCH}/.git/info/exclude"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: And the report is about the WALK, not about the tree. Where git
# answers, git applies every one of these forms itself -- that is the tier
# whose exclusion the walk is only ever approximating -- so reporting them
# there would fail a checkout for a declaration nothing in it gets wrong.
@test "_run_adr_numbering: a checkout reports no unreadable declaration (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the case above states.
  local _ghost='00000099'
  _write '.gitignore' 'vendor/*.md' '!keep.md' 'pkg/'
  _write 'CONTEXT.md' 'ADR-00000001 resolves.'
  _write 'vendor/old.md' "a vendored tree naming ADR-${_ghost}"
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" add doc CONTEXT.md .gitignore
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *".gitignore"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: real tree guard
# ════════════════════════════════════════════════════════════════════

# why: Live tree clean, 00000009 gap warned
@test "_run_adr_numbering: the REAL doc/adr/ passes today (00000009 gap warned) (#808)" {
  REPO_ROOT="/source"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"00000009"* ]]
  [[ "${output}" == *"clean"* ]]
}
