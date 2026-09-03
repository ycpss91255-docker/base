#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/adr_structure.sh -- the ADR-structure
# lint. adr_numbering.sh guards what an ADR file is CALLED; this guards what
# it CONTAINS: a `> Serves:` back-pointer, the four required sections
# (Context / Decision / Consequences / Alternatives), and a Status that is
# exactly one of the three contract values.
#
# Every check has a failing fixture here -- a check nobody has watched fail
# is a check nobody knows works. The detection runs against a controlled temp
# REPO_ROOT so the spec does not move when the live tree does; a final case
# drives the REAL doc/adr/ to prove it passes today.
#
# The zero-ADR case is a REFUSAL, not a pass. A lint that examined nothing
# and printed "clean" cannot tell an empty tree from a scan that has stopped
# matching, and the second is the failure mode that costs the most, because
# its output is indistinguishable from success (PRD design principle P3).

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # adr_numbering_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/adr_structure.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/adr"
  REPO_ROOT="${SCRATCH}"
  _SERVES="> Serves: PRD invariant 2 (never fail silently)."
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _adr <basename> <serves-line> <status-value> [section-heading...]
#   Write an ADR fixture. An empty <serves-line> or <status-value> omits that
#   line entirely; no section headings means the four required ones. Every
#   failing fixture below differs from a passing one in exactly one respect,
#   so a case that goes red names the check that caught it.
_adr() {
  local _name="${1}" _serves="${2}" _status="${3}"
  shift 3
  local -a _sections=("$@")
  if [[ "${#_sections[@]}" -eq 0 ]]; then
    _sections=("## Context" "## Decision" "## Consequences" "## Alternatives")
  fi
  {
    echo "# A title"
    echo
    if [[ -n "${_serves}" ]]; then echo "${_serves}"; echo; fi
    echo "- **Date:** 2026-09-03"
    if [[ -n "${_status}" ]]; then echo "- **Status:** ${_status}"; fi
    echo
    local _s
    for _s in "${_sections[@]}"; do
      echo "${_s}"
      echo
      echo "Body."
      echo
    done
  } > "${SCRATCH}/doc/adr/${_name}"
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_structure: the back-pointer
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_structure: FAILS on a missing '> Serves:' back-pointer, naming the file (#994)" {
  _adr "00000001-alpha.md" "" "Accepted"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000001-alpha.md"* ]]
  [[ "${output}" == *"Serves"* ]]
}

@test "_run_adr_structure: a '> Serves:' that is not at line start does NOT count (#994)" {
  _adr "00000001-alpha.md" "Nothing here. > Serves: smuggled in mid-line." "Accepted"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Serves"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_structure: the required sections
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_structure: FAILS on a missing '## Context' (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted" \
    "## Decision" "## Consequences" "## Alternatives"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Context"* ]]
  [[ "${output}" == *"00000001-alpha.md"* ]]
}

@test "_run_adr_structure: FAILS on a missing '## Decision' (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted" \
    "## Context" "## Consequences" "## Alternatives"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Decision"* ]]
}

@test "_run_adr_structure: FAILS on a missing '## Consequences' (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted" \
    "## Context" "## Decision" "## Alternatives"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Consequences"* ]]
}

@test "_run_adr_structure: FAILS on a missing '## Alternatives' -- required, not advisory (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted" \
    "## Context" "## Decision" "## Consequences"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Alternatives"* ]]
}

@test "_run_adr_structure: ACCEPTS the house heading variants with trailing text (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted" \
    "## Context" "## Decision (pending -- this ADR is Proposed)" \
    "## Consequences / trade-offs" "## Alternatives considered"
  run _run_adr_structure
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_adr_structure: a heading inside a fenced code block does NOT satisfy the check (#994)" {
  {
    echo "# A title"
    echo
    echo "${_SERVES}"
    echo
    echo "- **Status:** Accepted"
    echo
    echo "## Context"
    echo
    echo '```markdown'
    echo "## Decision"
    echo "## Consequences"
    echo "## Alternatives"
    echo '```'
  } > "${SCRATCH}/doc/adr/00000001-alpha.md"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Decision"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_structure: the three-value Status contract
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_structure: FAILS on free text after Accepted (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted (amended 2026-06-12)"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Status"* ]]
  [[ "${output}" == *"amended"* ]]
}

@test "_run_adr_structure: FAILS on free text after Rejected (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Rejected (spike disproved the premise)"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Status"* ]]
}

@test "_run_adr_structure: FAILS on a Status line that is absent entirely (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" ""
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Status"* ]]
}

@test "_run_adr_structure: FAILS on 'Proposed', which is not one of the three values (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Proposed"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Status"* ]]
}

@test "_run_adr_structure: FAILS on a supersession pointing at a non-8-digit number (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Superseded by ADR-12"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Status"* ]]
}

@test "_run_adr_structure: FAILS on a supersession carrying a trailing date (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Superseded by ADR-00000012 (2026-06-23)"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Status"* ]]
}

@test "_run_adr_structure: ACCEPTS all three contract values (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted"
  _adr "00000002-beta.md" "${_SERVES}" "Rejected"
  _adr "00000003-gamma.md" "${_SERVES}" "Superseded by ADR-00000001"
  run _run_adr_structure
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_structure: the exemption, and reporting
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_structure: EXEMPTS doc/adr/README.md (the index) (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted"
  printf '# ADR index\n\nNo Serves, no Status, no sections.\n' \
    > "${SCRATCH}/doc/adr/README.md"
  run _run_adr_structure
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *"README.md"* ]]
}

@test "_run_adr_structure: names EVERY offending file, not just the first (#994)" {
  _adr "00000001-alpha.md" "" "Accepted"
  _adr "00000002-beta.md" "${_SERVES}" "Proposed"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000001-alpha.md"* ]]
  [[ "${output}" == *"00000002-beta.md"* ]]
}

@test "_run_adr_structure: reports how many ADRs it examined (#994)" {
  _adr "00000001-alpha.md" "${_SERVES}" "Accepted"
  _adr "00000002-beta.md" "${_SERVES}" "Accepted"
  run _run_adr_structure
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 ADR(s) examined"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_structure: an empty population is a REFUSAL, never a pass
#
# The lint that finds nothing has two possible reasons and must not
# conflate them. These cases are the difference between "the tree is
# clean" and "the scan stopped matching".
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_structure: REFUSES when doc/adr/ holds no ADR at all (#994)" {
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"clean"* ]]
  [[ "${output}" == *"0 ADR"* ]]
}

@test "_run_adr_structure: REFUSES when doc/adr/ holds ONLY the exempt README (#994)" {
  printf '# ADR index\n' > "${SCRATCH}/doc/adr/README.md"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"clean"* ]]
  [[ "${output}" == *"0 ADR"* ]]
}

@test "_run_adr_structure: REFUSES when doc/adr/ does not exist (#994)" {
  rm -rf "${SCRATCH}/doc/adr"
  run _run_adr_structure
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_structure: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_structure: the REAL doc/adr/ passes today (#994)" {
  REPO_ROOT="/source"
  run _run_adr_structure
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
