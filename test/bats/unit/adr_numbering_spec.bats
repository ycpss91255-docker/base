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

# why: The tier CI takes, where git can answer. An untracked scratch file
# is not a reference this repo keeps true and the verb never rewrites
# one, so the lint must not fail on it either -- the same disagreement as
# the case above, arriving through the other branch of the population.
@test "_run_adr_numbering: an untracked file in a checkout is not a reference (#1021)" {
  _touch_adr "00000001-alpha.md"
  _index '| 00000001 -- alpha | keep | mechanism | note |'
  # Assembled, for the reason the case above states.
  local _ghost='00000099'
  _write 'CONTEXT.md' 'ADR-00000001 resolves.'
  _write 'scratch.md' "A scratch note citing ADR-${_ghost}."
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" add doc CONTEXT.md
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
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
