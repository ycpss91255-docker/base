#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/issueref.sh -- the "no transient
# issue refs in code comments" lint (ADR-00000013). The detection runs
# against a controlled temp REPO_ROOT so the spec is independent of the
# live tree's contents.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/downstream/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/issueref.sh

  # A scratch repo root the driver will scan. Mirror the in-scope roots so
  # the driver's find walk has somewhere to look.
  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/downstream/script" "${SCRATCH}/script" "${SCRATCH}/test"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# ════════════════════════════════════════════════════════════════════
# _run_issueref: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_issueref: flags a bare #NNN in a leading comment" {
  printf '%s\n' '# rationale for the gate #440' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#440'* ]]
}

@test "_run_issueref: flags a bare #NNN in a trailing comment" {
  printf '%s\n' 'echo hi   # auto-build gate #216' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#216'* ]]
}

@test "_run_issueref: flags the (#NNN) paren form in a comment" {
  printf '%s\n' '# the EXIT-trap cleanup (#429)' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'(#429)'* ]]
}

@test "_run_issueref: flags refs in .bats helper comments (not @test names)" {
  cat > "${SCRATCH}/test/sample.bats" <<'EOF'
#!/usr/bin/env bats
# helper comment with a stale ref #319
@test "behaviour stays named with (#388)" {
  true
}
EOF
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#319'* ]]
  # The @test line's (#388) must NOT be reported.
  [[ "${output}" != *'#388'* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_issueref: must-keep (no false positives)
# ════════════════════════════════════════════════════════════════════

@test "_run_issueref: passes clean on a tree with no comment refs" {
  printf '%s\n' '# describes what the gate does, no number' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'clean'* ]]
}

@test "_run_issueref: does NOT flag a #NNN inside a string literal" {
  printf '%s\n' 'echo "patched (#567 m7)"   # plain comment, no ref' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag ADR-0000xxxx references" {
  printf '%s\n' '# layered consumer entry (ADR-00000011)' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag DL/SC directive codes or version tags" {
  printf '%s\n' '# hadolint DL3007 / shellcheck SC1090, since v0.41.0' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag word-prefixed cross-repo refs" {
  printf '%s\n' '# layered COPY chain (template#254), see harness#53' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag single-digit or 5+-digit numbers" {
  printf '%s\n' '# step #1 of the loop; PID #12345 placeholder' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT treat a \${#arr[@]} expansion as a comment" {
  printf '%s\n' 'len=${#arr[@]}; echo "${len} items"' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}
