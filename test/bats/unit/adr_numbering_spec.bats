#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/adr_numbering.sh -- the ADR-numbering
# lint. The registry is the filesystem: ADR files live at
# doc/adr/NNNNNNNN-<slug>.md. The lint FAILS on a duplicate ADR number or a
# malformed filename, and WARNS (exit 0) on a numbering gap. The detection
# runs against a controlled temp REPO_ROOT so the spec is independent of the
# live tree's contents; a final case drives the REAL doc/adr/ to prove it
# passes today with the intentional 00000009 gap warned-not-failed.

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
}

# _touch_adr <NNNNNNNN-slug.md> -- create an empty ADR fixture file.
_touch_adr() {
  : > "${SCRATCH}/doc/adr/${1}"
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: failures
# ════════════════════════════════════════════════════════════════════

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

@test "_run_adr_numbering: FAILS on a malformed filename, naming the file (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "notes.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.md"* ]]
}

@test "_run_adr_numbering: FAILS on a too-short (non-8-digit) number prefix (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "0001-short.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"0001-short.md"* ]]
}

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

@test "_run_adr_numbering: PASSES a clean contiguous set with no gap warning (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000003-gamma.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *"gap"* ]]
}

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
# _run_adr_numbering: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_numbering: the REAL doc/adr/ passes today (00000009 gap warned) (#808)" {
  REPO_ROOT="/source"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"00000009"* ]]
  [[ "${output}" == *"clean"* ]]
}
