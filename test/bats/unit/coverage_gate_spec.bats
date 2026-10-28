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
#
# why: Unit tests for `script/test/drivers/coverage_gate.sh` (#710) -- the
# self-hosted, CI-agnostic coverage-floor gate that replaces the removed
# Codecov merge+status path. The gate MERGES the per-shard kcov cobertura
# reports into ONE line-weighted project rate (summing covered/valid lines
# across shards, NOT averaging the per-shard rates) and exits non-zero when
# the merged rate is below `COVERAGE_MIN`. Driven against controlled
# cobertura fixtures so the spec is independent of any live kcov run. Since
# #853 the union key is CANONICALISED first: kcov reports one source file
# under several prefix-truncated aliases, and each alias used to add its own
# full copy of the file's lines to the denominator.

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

# Write a kcov-style cobertura report at $1 from one or more class specs,
# each given as `<filename>:<valid>:<lo>:<hi>`: a <class> with <valid>
# per-line <line> elements of which lines lo..hi carry hits="1" (lo=0 =>
# none covered). Unlike _make_cobertura this emits SEVERAL classes per
# report, which is what kcov does and what the path-alias cases need. The
# root lines-covered / lines-valid counters are deliberately omitted: the
# gate merges by per-line union and never reads them.
_make_multi_cobertura() {
  local _path="${1}"
  shift
  mkdir -p "$(dirname "${_path}")"
  {
    echo '<?xml version="1.0" ?>'
    echo '<coverage version="1.9" timestamp="0">'
    echo '  <packages><package name="p"><classes>'
    local _spec _fn _valid _lo _hi _i
    for _spec in "$@"; do
      IFS=: read -r _fn _valid _lo _hi <<< "${_spec}"
      echo "  <class name=\"c\" filename=\"${_fn}\"><lines>"
      for (( _i = 1; _i <= _valid; _i++ )); do
        if (( _lo > 0 && _i >= _lo && _i <= _hi )); then
          echo "    <line number=\"${_i}\" hits=\"1\"/>"
        else
          echo "    <line number=\"${_i}\" hits=\"0\"/>"
        fi
      done
      echo '  </lines></class>'
    done
    echo '  </classes></package></packages>'
    echo '</coverage>'
  } > "${_path}"
}

# ════════════════════════════════════════════════════════════════════
# Floor pass / fail
# ════════════════════════════════════════════════════════════════════

# why: Floor pass
@test "coverage_gate: passes when merged rate >= COVERAGE_MIN" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 60 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]
}

# why: Boundary (==) pass
@test "coverage_gate: passes at exactly the floor (boundary)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 50 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
}

# why: Floor fail (non-zero exit)
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

# why: 4-shard merge total
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
# kcov path aliases: one source file is reported under several
# prefix-truncated filenames, so the union key must be canonicalised
# (longest observed path-suffix match) before it is counted
# ════════════════════════════════════════════════════════════════════

# why: Alias-inflated denominator (the bug)
@test "coverage_gate: prefix path aliases of one file are counted once (#853)" {
  # kcov emits the SAME source file under several prefix truncations. Each
  # alias is a different union key, so each contributes its own full copy of
  # the file's lines to the denominator while only the alias that recorded
  # hits contributes to the numerator. One 100-line file, 50 lines covered
  # under the fully-qualified alias -> 50/100 = 50.00%, NOT 50/400 = 12.50%.
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:100:1:50" \
    "script/docker/lib/_lib.sh:100:0:0" \
    "docker/lib/_lib.sh:100:0:0" \
    "lib/_lib.sh:100:0:0"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"50.00"* ]]
  [[ "${output}" != *"12.50"* ]]
}

# why: Basename-only keying is wrong (the trap)
@test "coverage_gate: different files sharing a basename stay separate (#853)" {
  # The trap that rules basename-only keying out: distinct files legitimately
  # share a basename (a shipped lib deploy.sh and the generated field
  # launcher). Neither name is a path suffix of the other, so they must keep
  # separate keys: 80/200 = 40.00%, NOT the merged 80/100 = 80.00%.
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/deploy.sh:100:1:80" \
    "deploy/robot-field-1.0.0/deploy.sh:100:0:0"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"40.00"* ]]
  [[ "${output}" != *"80.00"* ]]
}

# why: Shard-membership invariance
@test "coverage_gate: rate is unchanged when the suite is resharded under other aliases (#853)" {
  # The invariant the union already claimed but aliasing broke: which alias a
  # file appears under depends on which shard executed it, and shard
  # membership is recomputed from the spec-file list -- so adding one spec
  # reshuffles the shards and moved the reported rate. The SAME suite (one
  # 100-line file, lines 1-60 covered) split two ways must report the same
  # rate: 60/100 = 60.00%.
  _make_multi_cobertura "${SCRATCH}/two/s1/cobertura.xml" \
    "script/docker/lib/_lib.sh:100:1:30"
  _make_multi_cobertura "${SCRATCH}/two/s2/cobertura.xml" \
    "lib/_lib.sh:100:31:60"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}"/two/s*/cobertura.xml
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]

  _make_multi_cobertura "${SCRATCH}/four/s1/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:100:1:15"
  _make_multi_cobertura "${SCRATCH}/four/s2/cobertura.xml" \
    "script/docker/lib/_lib.sh:100:16:30"
  _make_multi_cobertura "${SCRATCH}/four/s3/cobertura.xml" \
    "docker/lib/_lib.sh:100:31:45"
  _make_multi_cobertura "${SCRATCH}/four/s4/cobertura.xml" \
    "lib/_lib.sh:100:46:60"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}"/four/s*/cobertura.xml
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]
}

# why: Alias-collapse diagnostic
@test "coverage_gate: reports the collapsed-alias count as a diagnostic (#853)" {
  # A regression in kcov's path reporting must be visible, not silent: the
  # gate states how many observed filenames collapsed into a canonical one.
  # Four aliases of one file plus one unaliased file -> 3 collapsed.
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:10:1:5" \
    "script/docker/lib/_lib.sh:10:0:0" \
    "docker/lib/_lib.sh:10:0:0" \
    "lib/_lib.sh:10:0:0" \
    "dist/script/docker/lib/deploy.sh:10:1:5"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"collapsed 3"* ]]
}

# why: Diagnostic reports 0, not silence
@test "coverage_gate: reports zero collapsed aliases when nothing is aliased (#853)" {
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:10:1:5" \
    "dist/script/docker/lib/deploy.sh:10:1:5"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"collapsed 0"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Missing / empty / malformed report handling
# ════════════════════════════════════════════════════════════════════

# why: No-args error
@test "coverage_gate: errors when no report files are given" {
  run env COVERAGE_MIN=50 bash "${GATE}"
  [ "${status}" -ne 0 ]
}

# why: Missing-file error
@test "coverage_gate: errors when a named report file is missing" {
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/does-not-exist.xml"
  [ "${status}" -ne 0 ]
}

# why: Empty-report error
@test "coverage_gate: errors when total valid lines is zero (empty report)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 0 0
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
}

# why: Malformed-report error
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

# why: Built-in default does not false-fail
@test "coverage_gate: default COVERAGE_MIN does not false-fail at the measured 84.72%" {
  # The rate CI measures on main (84.72%, 5907/6972 lines) must clear the
  # built-in default floor. Model it with a report at that rate and assert
  # pass with NO COVERAGE_MIN override.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 5907 6972
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"84.72"* ]]
}

# why: Floor value pinned from below
@test "coverage_gate: default COVERAGE_MIN is 80 -- a report exactly at 80 passes" {
  # Pin the floor VALUE from below: 80.00% is the lowest rate the built-in
  # default accepts. Asserted with NO override so the constant itself is
  # under test, and the reported floor is read back out of the verdict
  # line so a silent re-base cannot pass unnoticed.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 8000 10000
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"floor 80% -> PASS"* ]]
}

# why: Floor value pinned from above
@test "coverage_gate: default COVERAGE_MIN is 80 -- a report just under 80 fails" {
  # Pin the same value from above: 79.99% must FAIL on the built-in
  # default. Together with the boundary-pass case this fixes the floor at
  # exactly 80, so lowering it back silently breaks a test.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 7999 10000
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"floor 80% -> FAIL"* ]]
}

# why: GitHub visibility (no SaaS)
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

# ════════════════════════════════════════════════════════════════════
# --merge-timings: aggregate per-shard runtime files into one weights file
#
# Each coverage shard uploads a `<seconds> <basename>` timings file
# (from _junit_to_timings). The coverage-gate job already downloads every
# shard artifact, so it also merges the timings into one weights file that
# the NEXT run restores as SHARD_WEIGHTS_FILE. A spec runs in exactly one
# shard, so normally one entry per basename; the merge keeps the MAX as a
# defensive dedup and tolerates a shard that produced no file.
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate --merge-timings: merges per-shard timings keeping max seconds per basename (#733)" {
  printf '%s\n' "10 foo_spec.bats" "3 bar_spec.bats" > "${SCRATCH}/a.tsv"
  printf '%s\n' "5 baz_spec.bats" "7 foo_spec.bats" > "${SCRATCH}/b.tsv"
  run bash "${GATE}" --merge-timings "${SCRATCH}/w.tsv" \
    "${SCRATCH}/a.tsv" "${SCRATCH}/b.tsv" "${SCRATCH}/missing.tsv"
  [ "${status}" -eq 0 ]
  run cat "${SCRATCH}/w.tsv"
  assert_line "10 foo_spec.bats"
  assert_line "3 bar_spec.bats"
  assert_line "5 baz_spec.bats"
}

@test "coverage_gate --merge-timings: no input files yields an empty weights file (#733)" {
  run bash "${GATE}" --merge-timings "${SCRATCH}/w.tsv" "${SCRATCH}/none.tsv"
  [ "${status}" -eq 0 ]
  [ -f "${SCRATCH}/w.tsv" ]
  run cat "${SCRATCH}/w.tsv"
  [ -z "${output}" ]
}

# ════════════════════════════════════════════════════════════════════
# --verdict: the ONE coverage verdict every environment runs (base#1411)
#
# A coverage run decides something only through its verdict, and the
# verdict is two checks, not one: the floor over the reports AND the
# run-manifest union check (a spec that ran nowhere cannot lower a ratio,
# so the floor alone cannot see it). `--verdict <manifest> <report>...`
# runs both, so local, GitHub-hosted and self-hosted reach the same
# verdict through the same entry point instead of three step lists.
# ════════════════════════════════════════════════════════════════════

# Write, at $1, a run manifest naming every spec in the live inventory --
# what a whole-suite coverage run leaves in its timings file. With $2 set,
# the first spec of the inventory is left out and its basename printed.
_verdict_manifest() {
  local _out="${1}" _drop="${2:-}"
  run bash -c '
    source /source/script/test/test.sh
    _inv="$(_coverage_spec_inventory "${REPO_ROOT}")"
    if [[ -n "${2}" ]]; then
      sed -n "1p" <<< "${_inv}"
      _inv="$(sed "1d" <<< "${_inv}")"
    fi
    sed "s/^/1 /" <<< "${_inv}" > "${1}"
  ' _ "${_out}" "${_drop}"
  assert_success
}

# why: the pass direction -- a whole manifest and a rate at the floor is
# a green verdict, and the output carries BOTH halves' evidence.
@test "coverage_gate --verdict: passes when the rate clears the floor and every spec ran (base#1411)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 60 100
  _verdict_manifest "${SCRATCH}/whole.tsv"

  run env COVERAGE_MIN=50 bash "${GATE}" --verdict \
    "${SCRATCH}/whole.tsv" "${SCRATCH}/a/cobertura.xml"
  assert_success
  assert_output --partial "60.00"
  assert_output --partial "exhaustive"
}

# why: the half the floor cannot see. The rate is well above the floor,
# so only the union check can turn this red, and it must name the spec.
@test "coverage_gate --verdict: fails, naming the spec, when a spec ran nowhere though the rate passes (base#1411)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 90 100
  _verdict_manifest "${SCRATCH}/short.tsv" drop
  local _dropped="${output}"
  [ -n "${_dropped}" ]

  run env COVERAGE_MIN=50 bash "${GATE}" --verdict \
    "${SCRATCH}/short.tsv" "${SCRATCH}/a/cobertura.xml"
  assert_failure
  assert_output --partial "90.00"
  assert_output --partial "${_dropped}"
}

# why: the floor half still decides -- a whole manifest does not rescue
# a rate under COVERAGE_MIN.
@test "coverage_gate --verdict: fails on a rate under the floor even when every spec ran (base#1411)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 40 100
  _verdict_manifest "${SCRATCH}/whole.tsv"

  run env COVERAGE_MIN=50 bash "${GATE}" --verdict \
    "${SCRATCH}/whole.tsv" "${SCRATCH}/a/cobertura.xml"
  assert_failure
  assert_output --partial "floor 50% -> FAIL"
}
# why: both halves always run. With the rate under the floor AND a spec
# missing from the manifest, the output must carry the floor's FAIL and
# the union check's naming of the spec -- a wrapper that skips the union
# check once the floor has failed hides the missing spec until the rate
# is fixed and the next run turns red again.
@test "coverage_gate --verdict: reports both halves when the floor and the union check both fail (base#1411)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 40 100
  _verdict_manifest "${SCRATCH}/short.tsv" drop
  local _dropped="${output}"
  [ -n "${_dropped}" ]

  run env COVERAGE_MIN=50 bash "${GATE}" --verdict \
    "${SCRATCH}/short.tsv" "${SCRATCH}/a/cobertura.xml"
  assert_failure
  assert_output --partial "floor 50% -> FAIL"
  assert_output --partial "${_dropped}"
}

# ════════════════════════════════════════════════════════════════════
# Parity: local, GitHub-hosted and self-hosted run the SAME verdict
# (base#1411). Each place that decides on a coverage run invokes the
# verdict exactly once, with the same invocation, over inputs bound to
# what that run produced, and under the driver's own COVERAGE_MIN -- so a
# flag, a floor, an input or a check changed in one of them and not the
# others fails here instead of drifting.
# ════════════════════════════════════════════════════════════════════

# Print the code lines of $1 (or stdin with "-"): comment and blank lines
# dropped, leading space trimmed, backslash continuations joined so one
# command reads as one line.
_code_lines() {
  sed -e '/^[[:space:]]*#/d' -e 's/^[[:space:]]*//' -e '/^$/d' "${1}" \
    | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta'
}

# Print every coverage_gate.sh invocation in the code lines of $1, one per
# line, as the script name plus the word that follows it (or the bare
# name when nothing follows). Per invocation, not per line: two commands
# chained on one line are two invocations.
_gate_invocations() {
  _code_lines "${1}" \
    | grep -oE 'coverage_gate\.sh([[:space:]]+[^[:space:];&|)]+)?' || true
}

# Print the code lines of $1 that invoke the verdict.
_verdict_lines() {
  _code_lines "${1}" | grep -E 'coverage_gate\.sh[[:space:]]+--verdict'
}

# Print the body of recipe $2 in justfile $1 (header line excluded).
_recipe_body() {
  awk -v r="${2}" '
    $0 ~ "^" r "( |:)" { inb = 1; next }
    inb && /^[^[:space:]#]/ { exit }
    inb { print }
  ' "${1}"
}

# Print the body of every `run: |` block in $1 that matches ERE $2.
_run_blocks_matching() {
  awk -v ere="${2}" '
    function flush() { if (buf ~ ere) printf "%s", buf; buf = ""; inb = 0 }
    inb {
      if (match($0, /[^[:space:]]/) && RSTART - 1 <= ind) { flush() }
      else { buf = buf $0 "\n"; next }
    }
    /^[[:space:]]*run:[[:space:]]*\|/ {
      match($0, /[^[:space:]]/); ind = RSTART - 1; inb = 1; buf = ""; next
    }
    END { if (inb) flush() }
  ' "${1}"
}

# Print the value of every `<name>=` assignment in the code lines of $1.
_assignments_of() {
  _code_lines "${1}" | sed -n "s/^${2}=//p"
}

# Write the three verdict contexts under $SCRATCH: hosted.yaml (the
# coverage-gate job), selfhosted.sh (coverage-local.yaml's verdict step)
# and recipe.sh (the `just test coverage-gate` body).
_verdict_contexts() {
  yaml_job_text /source/.github/workflows/self-test.yaml coverage-gate \
    > "${SCRATCH}/hosted.yaml"
  _run_blocks_matching /source/.github/workflows/coverage-local.yaml \
    'coverage_gate[.]sh[[:space:]]+--verdict' > "${SCRATCH}/selfhosted.sh"
  _recipe_body /source/script/test/justfile.test coverage-gate \
    > "${SCRATCH}/recipe.sh"
}

@test "coverage verdict parity: hosted, self-hosted and the local recipe run one identical verdict line (base#1411)" {
  local _hosted _selfhosted _local _ctx
  _verdict_contexts
  _hosted="$(_verdict_lines "${SCRATCH}/hosted.yaml")"
  _selfhosted="$(_verdict_lines "${SCRATCH}/selfhosted.sh")"
  _local="$(_verdict_lines "${SCRATCH}/recipe.sh")"

  [ -n "${_hosted}" ] || fail "self-test.yaml coverage-gate runs no coverage_gate.sh --verdict"
  [ -n "${_selfhosted}" ] || fail "coverage-local.yaml runs no coverage_gate.sh --verdict"
  [ -n "${_local}" ] || fail "no 'just test coverage-gate' recipe running coverage_gate.sh --verdict"
  # Counted per invocation, so a second verdict chained onto the line
  # counts as the second one it is.
  for _ctx in hosted.yaml selfhosted.sh recipe.sh; do
    [ "$(_gate_invocations "${SCRATCH}/${_ctx}" | grep -cE -- '--verdict$')" -eq 1 ] \
      || fail "${_ctx} does not run the verdict exactly once: $(_gate_invocations "${SCRATCH}/${_ctx}")"
  done
  [ "${_hosted}" == "${_selfhosted}" ] \
    || fail "hosted [${_hosted}] and self-hosted [${_selfhosted}] verdicts differ"
  [ "${_hosted}" == "${_local}" ] \
    || fail "hosted [${_hosted}] and local [${_local}] verdicts differ"
}

# why: one entry point means no second, partial verdict beside it. A bare
# floor-only gate call or a free-standing union check is the three-step-
# lists shape this issue removes. Read per INVOCATION, not per line: a
# floor-only call chained onto a permitted line must still be seen.
@test "coverage verdict parity: no context runs the floor or the union check outside the verdict (base#1411)" {
  local _ctx _bad
  _verdict_contexts
  for _ctx in hosted.yaml selfhosted.sh recipe.sh; do
    _bad="$(_gate_invocations "${SCRATCH}/${_ctx}" \
      | grep -vxE 'coverage_gate\.sh[[:space:]]+--(verdict|merge-timings)' || true)"
    [ -z "${_bad}" ] || fail "${_ctx} runs coverage_gate.sh outside the verdict: ${_bad}"
    run grep -E -- '--coverage-union-check' <(_code_lines "${SCRATCH}/${_ctx}")
    assert_failure
  done
  # The self-hosted workflow file as a whole, not only its verdict step.
  _bad="$(_gate_invocations /source/.github/workflows/coverage-local.yaml \
    | grep -vxE 'coverage_gate\.sh[[:space:]]+--verdict' || true)"
  [ -z "${_bad}" ] || fail "coverage-local.yaml runs coverage_gate.sh outside the verdict: ${_bad}"
  run grep -E -- '--coverage-union-check' <(_code_lines /source/.github/workflows/coverage-local.yaml)
  assert_failure
}

# why: an identical invocation over different inputs is a different
# verdict. Local and self-hosted both judge a run of this checkout from
# its coverage/ tree, so their whole verdict scripts must be the same
# text -- a manifest or report bound to anything else in one of them
# (a stale, complete manifest left by an older run) fails here.
@test "coverage verdict parity: the local recipe and the self-hosted step bind the same inputs (base#1411)" {
  _verdict_contexts
  [ -s "${SCRATCH}/selfhosted.sh" ] || fail "coverage-local.yaml has no run block with the verdict"
  diff <(_code_lines "${SCRATCH}/selfhosted.sh") <(_code_lines "${SCRATCH}/recipe.sh") \
    || fail "the self-hosted verdict step and 'just test coverage-gate' differ (diff above)"
}

# why: the manifest each verdict reads must be the one ITS run wrote. A
# local or self-hosted coverage run writes test.sh's run manifest; the
# hosted matrix's manifest is the file the --merge-timings step writes
# from the shards' timings. Bound to anything else, the union check
# judges some other run.
@test "coverage verdict parity: each verdict reads the manifest its own run wrote (base#1411)" {
  local _run_manifest _merged
  _verdict_contexts
  run bash -c 'source /source/script/test/test.sh; printf "%s" "${_COVERAGE_RUN_MANIFEST_REL}"'
  assert_success
  _run_manifest="${output}"
  [ -n "${_run_manifest}" ]

  run _assignments_of "${SCRATCH}/recipe.sh" manifest
  [ "${output}" == "${_run_manifest}" ] \
    || fail "the recipe binds manifest to [${output}], not the run manifest [${_run_manifest}]"
  run _assignments_of "${SCRATCH}/selfhosted.sh" manifest
  [ "${output}" == "${_run_manifest}" ] \
    || fail "self-hosted binds manifest to [${output}], not the run manifest [${_run_manifest}]"

  _merged="$(_code_lines "${SCRATCH}/hosted.yaml" \
    | sed -nE 's/.*coverage_gate\.sh[[:space:]]+--merge-timings[[:space:]]+([^[:space:]]+).*/\1/p')"
  [ -n "${_merged}" ] || fail "the hosted coverage-gate job merges no timings"
  run _assignments_of "${SCRATCH}/hosted.yaml" manifest
  [ "${output}" == "${_merged}" ] \
    || fail "hosted binds manifest to [${output}], not the merged timings [${_merged}]"
}

# why: the hosted reports are an input too, and the text checks above
# cannot see how its loop fills them. Run the hosted verdict step itself
# over a laid-out set of downloaded shards, with the driver stubbed to
# print its arguments: it must hand the verdict the manifest and exactly
# ONE report from EVERY shard -- the kcov-merged one where it exists, else
# the first one found. A loop that keeps only the last shard, or one that
# passes a shard twice, judges a different run than the one the manifest
# names.
@test "coverage verdict parity: the hosted verdict receives exactly one report from every downloaded shard (base#1411)" {
  local _work="${SCRATCH}/hosted-run" _s
  _verdict_contexts
  _run_blocks_matching "${SCRATCH}/hosted.yaml" \
    'coverage_gate[.]sh[[:space:]]+--verdict' > "${SCRATCH}/hosted-verdict.sh"
  [ -s "${SCRATCH}/hosted-verdict.sh" ] || fail "the hosted coverage-gate job has no run block with the verdict"

  mkdir -p "${_work}/script/test/drivers"
  printf '#!/usr/bin/env bash\nprintf "ARG %%s\\n" "$@"\n' \
    > "${_work}/script/test/drivers/coverage_gate.sh"
  # shard-0: a merged report beside a per-run one -> the merged one.
  # shard-1: per-run reports only -> exactly one of them.
  # shard-2: a merged report only.
  for _s in coverage-shard-0/kcov-merged coverage-shard-0/run-a \
            coverage-shard-1/run-a coverage-shard-1/run-b \
            coverage-shard-2/kcov-merged; do
    mkdir -p "${_work}/coverage-shards/${_s}"
    : > "${_work}/coverage-shards/${_s}/cobertura.xml"
  done

  run bash -c 'cd "$1" && bash "$2"' _ "${_work}" "${SCRATCH}/hosted-verdict.sh"
  assert_success
  assert_line 'ARG --verdict'
  assert_line 'ARG test/bats/.shard-weights'
  [ "$(grep -c '^ARG .*cobertura\.xml$' <<<"${output}")" -eq 3 ] \
    || fail "the hosted verdict does not receive exactly three reports: ${output}"
  assert_line 'ARG ./coverage-shards/coverage-shard-0/kcov-merged/cobertura.xml'
  [ "$(grep -c '^ARG \./coverage-shards/coverage-shard-1/run-[ab]/cobertura\.xml$' <<<"${output}")" -eq 1 ] \
    || fail "the hosted verdict does not receive exactly one shard-1 report: ${output}"
  assert_line 'ARG ./coverage-shards/coverage-shard-2/kcov-merged/cobertura.xml'
}

# why: the floor is an input too. The driver owns COVERAGE_MIN's default
# (80); a value set in one context and not the others -- a step `env:`, an
# inline assignment, a justfile `export` -- moves that context's floor
# while every invocation line stays identical.
@test "coverage verdict parity: no context overrides the driver's COVERAGE_MIN (base#1411)" {
  local _f
  for _f in /source/.github/workflows/self-test.yaml \
            /source/.github/workflows/coverage-local.yaml \
            /source/script/test/justfile.test \
            /source/justfile; do
    run grep -n 'COVERAGE_MIN' <(_code_lines "${_f}")
    assert_failure
  done
}
