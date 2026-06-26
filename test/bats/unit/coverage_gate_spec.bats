#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/coverage_gate.sh -- the self-hosted,
# CI-agnostic coverage-floor gate (ADR-00000008). The gate MERGES the
# per-shard kcov cobertura reports into ONE project line-rate by per-line
# UNION (a line is covered if ANY shard ran it; valid = distinct source
# lines), NOT a SUM of root counters (which double-counts source shared
# across shards and drifts with the shard count -- see the merge bug fix)
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

# Write a minimal kcov-style cobertura.xml at $1 with <covered> of <valid>
# per-line <line> elements (the gate merges by per-line UNION). The
# class filename defaults to a UNIQUE name per fixture dir, so distinct
# fixtures are DISJOINT source -> their union equals the old sum (the
# pre-union assertions stay valid). Pass $4 to force a SHARED filename so two
# shards overlap on the same source (exercises the union dedupe).
#   $1 path  $2 covered  $3 valid  [$4 filename]
_make_cobertura() {
  local _path="${1}" _covered="${2}" _valid="${3}"
  local _fn="${4:-$(basename "$(dirname "${_path}")").sh}"
  mkdir -p "$(dirname "${_path}")"
  {
    echo '<?xml version="1.0" ?>'
    echo "<coverage lines-covered=\"${_covered}\" lines-valid=\"${_valid}\" version=\"1.9\" timestamp=\"0\">"
    echo '  <packages><package name="p"><classes>'
    echo "  <class name=\"c\" filename=\"${_fn}\"><lines>"
    local _i
    for (( _i = 1; _i <= _valid; _i++ )); do
      if (( _i <= _covered )); then
        echo "    <line number=\"${_i}\" hits=\"1\"/>"
      else
        echo "    <line number=\"${_i}\" hits=\"0\"/>"
      fi
    done
    echo '  </lines></class>'
    echo '  </classes></package></packages>'
    echo '</coverage>'
  } > "${_path}"
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
# Multi-shard merge math: per-line UNION, do NOT average; do NOT double-count
# shared source across shards
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: merges DISJOINT shards by union (= sum), not averaging" {
  # Distinct fixtures -> distinct class filenames -> disjoint source, so the
  # union equals the line-weighted sum. A 90/100 (90%), B 10/900 (~1.1%) ->
  # union = 100/1000 = 10.00%; the average of the rates would be ~45.6%.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 90 100
  _make_cobertura "${SCRATCH}/b/cobertura.xml" 10 900
  run env COVERAGE_MIN=0 bash "${GATE}" \
    "${SCRATCH}/a/cobertura.xml" "${SCRATCH}/b/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"10.00"* ]]
  [[ "${output}" != *"45.6"* ]]
}

@test "coverage_gate: SHARED source across shards is unioned, not double-counted (#730)" {
  # The real bug dynamic sharding exposed: every shard's kcov reports the WHOLE tree, so a
  # source file run by specs in multiple shards appears in EACH shard's report.
  # Two shards over the SAME file (filename "shared.sh", 100 lines): shard A
  # covers lines 1-30, shard B covers lines 31-60. UNION = 60/100 = 60.00%.
  # The old SUM math double-counted valid: (30+30)/(100+100) = 30.00% (wrong).
  mkdir -p "${SCRATCH}/a" "${SCRATCH}/b"
  {
    echo '<coverage lines-covered="30" lines-valid="100" version="1.9">'
    echo '<packages><package><classes><class name="c" filename="shared.sh"><lines>'
    for i in $(seq 1 100); do
      if (( i <= 30 )); then echo "<line number=\"${i}\" hits=\"1\"/>"
      else echo "<line number=\"${i}\" hits=\"0\"/>"; fi
    done
    echo '</lines></class></classes></package></packages></coverage>'
  } > "${SCRATCH}/a/cobertura.xml"
  {
    echo '<coverage lines-covered="30" lines-valid="100" version="1.9">'
    echo '<packages><package><classes><class name="c" filename="shared.sh"><lines>'
    for i in $(seq 1 100); do
      if (( i >= 31 && i <= 60 )); then echo "<line number=\"${i}\" hits=\"1\"/>"
      else echo "<line number=\"${i}\" hits=\"0\"/>"; fi
    done
    echo '</lines></class></classes></package></packages></coverage>'
  } > "${SCRATCH}/b/cobertura.xml"
  run env COVERAGE_MIN=0 bash "${GATE}" \
    "${SCRATCH}/a/cobertura.xml" "${SCRATCH}/b/cobertura.xml"
  [ "${status}" -eq 0 ]
  # union 60/100 = 60.00%, NOT the double-counted sum 30.00%
  [[ "${output}" == *"60.00"* ]]
  [[ "${output}" != *"30.00"* ]]
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
