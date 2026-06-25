#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/coverage_gate.sh -- the self-hosted,
# CI-agnostic coverage-floor gate (ADR-00000008). The gate MERGES the
# per-shard kcov cobertura reports into ONE project line-rate (summing
# covered/valid lines across shards, NOT averaging the per-shard rates)
# and exits non-zero when the merged rate is below COVERAGE_MIN. These
# tests drive it against controlled cobertura fixtures so they are
# independent of any live kcov run.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The gate script is standalone-runnable (CI invokes it directly with
  # the per-shard cobertura paths). Resolve it via the mounted /source
  # tree the test-tools container exposes.
  GATE=/source/script/test/drivers/coverage_gate.sh

  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# Write a minimal kcov-style cobertura.xml with the given covered/valid
# line counts at $1; kcov emits these on the root <coverage> element.
_make_cobertura() {
  local _path="${1}" _covered="${2}" _valid="${3}"
  local _rate="0.0"
  if [[ "${_valid}" != "0" ]]; then
    _rate="$(awk -v c="${_covered}" -v v="${_valid}" 'BEGIN{printf "%.4f", c/v}')"
  fi
  mkdir -p "$(dirname "${_path}")"
  cat > "${_path}" <<EOF
<?xml version="1.0" ?>
<coverage line-rate="${_rate}" lines-covered="${_covered}" lines-valid="${_valid}" branch-rate="0.0" version="1.9" timestamp="0">
  <sources><source>/source</source></sources>
  <packages></packages>
</coverage>
EOF
}

# ════════════════════════════════════════════════════════════════════
# Floor pass / fail
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: passes when merged rate >= COVERAGE_MIN" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 60 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]
}

@test "coverage_gate: passes at exactly the floor (boundary)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 50 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
}

@test "coverage_gate: fails when merged rate < COVERAGE_MIN" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 40 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"40.00"* ]]
  [[ "${output}" == *"50"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Multi-shard merge math: SUM covered/valid, do NOT average the rates
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: merges shards by summing covered/valid, not averaging" {
  # Shard A: 90/100 = 90%. Shard B: 10/100 = 10%. The average of the two
  # per-shard rates is 50%; the CORRECT line-weighted total is
  # (90+10)/(100+100) = 50%. With equal denominators these coincide, so
  # use UNEQUAL denominators to distinguish the two: A 90/100 (90%),
  # B 10/900 (~1.1%) -> sum = 100/1000 = 10.00%, average would be ~45.6%.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 90 100
  _make_cobertura "${SCRATCH}/b/cobertura.xml" 10 900
  run env COVERAGE_MIN=0 bash "${GATE}" \
    "${SCRATCH}/a/cobertura.xml" "${SCRATCH}/b/cobertura.xml"
  [ "${status}" -eq 0 ]
  # Line-weighted total is 10.00%, NOT the ~45.6% average of the rates.
  [[ "${output}" == *"10.00"* ]]
  [[ "${output}" != *"45.6"* ]]
}

@test "coverage_gate: four shards merge into one weighted total" {
  _make_cobertura "${SCRATCH}/s1/cobertura.xml" 25 100
  _make_cobertura "${SCRATCH}/s2/cobertura.xml" 25 100
  _make_cobertura "${SCRATCH}/s3/cobertura.xml" 25 100
  _make_cobertura "${SCRATCH}/s4/cobertura.xml" 25 100
  run env COVERAGE_MIN=20 bash "${GATE}" \
    "${SCRATCH}"/s*/cobertura.xml
  [ "${status}" -eq 0 ]
  # (25*4)/(100*4) = 25.00%
  [[ "${output}" == *"25.00"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Missing / empty / malformed report handling
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: errors when no report files are given" {
  run env COVERAGE_MIN=50 bash "${GATE}"
  [ "${status}" -ne 0 ]
}

@test "coverage_gate: errors when a named report file is missing" {
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/does-not-exist.xml"
  [ "${status}" -ne 0 ]
}

@test "coverage_gate: errors when total valid lines is zero (empty report)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 0 0
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
}

@test "coverage_gate: errors on a report missing the line counters" {
  mkdir -p "${SCRATCH}/a"
  printf '%s\n' '<coverage version="1.9"></coverage>' \
    > "${SCRATCH}/a/cobertura.xml"
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# COVERAGE_MIN default + visibility
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: default COVERAGE_MIN does not false-fail at ~52.9%" {
  # The current measured rate (~52.9%) must clear the built-in default
  # floor. Model it with a report just at that rate and assert pass with
  # NO COVERAGE_MIN override.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 529 1000
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
}

@test "coverage_gate: emits a GitHub step summary table when GITHUB_STEP_SUMMARY is set" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 60 100
  local _summary="${SCRATCH}/summary.md"
  run env COVERAGE_MIN=50 GITHUB_STEP_SUMMARY="${_summary}" \
    bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [ -f "${_summary}" ]
  run cat "${_summary}"
  [[ "${output}" == *"Coverage"* ]]
  [[ "${output}" == *"60.00"* ]]
}
