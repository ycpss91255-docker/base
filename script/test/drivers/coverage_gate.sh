#!/usr/bin/env bash
# drivers/coverage_gate.sh - self-hosted, CI-agnostic coverage-floor gate.
#
# DUAL MODE: this file is both a sourced driver (test.sh sources it after
# _lib.sh, so _log_* / _die are available, exposing _run_coverage_gate)
# AND a standalone CLI (CI invokes `bash coverage_gate.sh <cobertura>...`
# directly with the per-shard report paths). The standalone path
# re-implements the minimum logging it needs so it has no dependency on
# the test.sh sourcing context.
#
# WHY (ADR-00000008, self-hosted amendment): the repo is moving to the
# company GitLab where Codecov is unavailable and uploading coverage to
# an external SaaS is data leakage. This replaces the Codecov merge+gate
# with a local one that reads kcov's cobertura.xml output and exits
# non-zero when the MERGED project line-rate is below a configurable
# floor. It is deliberately CI-agnostic: it reads files and sets an exit
# code, so it behaves identically under GitHub Actions and GitLab CI.
#
# MERGE MATH (the load-bearing detail): kcov writes one cobertura.xml per
# shard whose root <coverage> element carries lines-covered / lines-valid.
# The project total is SUM(covered) / SUM(valid) across all shards -- a
# LINE-WEIGHTED merge. It is NOT the average of the per-shard line-rate
# attributes: shards have different denominators (the integration suite
# runs on the last shard only), so averaging the rates would weight a
# small shard equally with a large one and report a wrong total.
#
# THRESHOLD: COVERAGE_MIN (percent, env-overridable). The default is set
# just below the current measured rate so it does not false-fail today;
# it is meant to RATCHET UP as coverage improves (the v2 regression-vs-
# main-baseline gate is a documented follow-up, not built here).

# Default floor (percent). Set just under the current measured project
# rate (~52.9 at adoption) so it passes today; raise it as coverage
# climbs. Overridable via the COVERAGE_MIN env var.
: "${COVERAGE_MIN:=50}"

# Append the coverage summary table to $GITHUB_STEP_SUMMARY when set
# (GitHub Actions built-in, no SaaS). A no-op elsewhere (e.g. GitLab,
# where the MR widget is fed by the job `coverage:` regex instead). Args:
#   $1 = merged rate (e.g. 52.90)  $2 = covered  $3 = valid
#   $4 = floor  $5 = verdict string (PASS / FAIL)
_coverage_gate_step_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## Coverage gate"
    echo ""
    echo "| Metric | Value |"
    echo "| --- | --- |"
    echo "| Line rate | ${1}% |"
    echo "| Covered lines | ${2} |"
    echo "| Valid lines | ${3} |"
    echo "| Floor (COVERAGE_MIN) | ${4}% |"
    echo "| Verdict | ${5} |"
  } >> "${GITHUB_STEP_SUMMARY}"
}

# The gate proper. Merges the given per-shard cobertura reports into one
# line-weighted project rate and returns non-zero when it is below
# COVERAGE_MIN. Args: one or more cobertura.xml paths. Emits the merged
# rate to stdout; diagnostics to stderr. Self-contained (no _die / _log_*
# dependency) so the standalone CLI and the sourced driver share it.
_coverage_gate_run() {
  if (( $# == 0 )); then
    echo "coverage_gate: no cobertura report files given" >&2
    return 2
  fi

  local _file
  for _file in "$@"; do
    if [[ ! -f "${_file}" ]]; then
      echo "coverage_gate: report not found: ${_file}" >&2
      return 2
    fi
  done

  # Per-line UNION across all shard reports (NOT SUM of root counters).
  # Each shard's kcov runs with --include-path=<repo>, so every shard's
  # cobertura reports the WHOLE tree and a source file exercised by specs in
  # multiple shards appears in MULTIPLE reports. Summing root counters
  # double-counts that shared source, so the rate drifts DOWN as the shard
  # count grows (4 shards ~52.9%, 8 shards 42% on the SAME suite). A line is
  # covered if ANY shard executed it (hits>0); valid = distinct source lines
  # (key = <class filename> + <line number>) -- shard-count-invariant.
  local _parsed _sum_covered _sum_valid
  _parsed="$(awk '
    match($0, /<class [^>]*filename="[^"]*"/) {
      s = substr($0, RSTART, RLENGTH); sub(/.*filename="/, "", s); sub(/".*/, "", s)
      cur = s; next
    }
    match($0, /<line number="[0-9]+" hits="[0-9]+"/) {
      ln = substr($0, RSTART, RLENGTH)
      n = ln; sub(/.*number="/, "", n); sub(/".*/, "", n)
      h = ln; sub(/.*hits="/, "", h); sub(/".*/, "", h)
      k = cur ":" n; valid[k] = 1; if (h + 0 > 0) cov[k] = 1
    }
    END { c = 0; v = 0; for (k in valid) v++; for (k in cov) c++; printf "%d %d", c, v }
  ' "$@")"
  _sum_covered="${_parsed% *}"
  _sum_valid="${_parsed#* }"

  if (( _sum_valid == 0 )); then
    echo "coverage_gate: total valid lines is zero (no <line> data in report set)" >&2
    return 2
  fi

  # Union project rate covered/valid, as a percentage.
  local _rate
  _rate="$(awk -v c="${_sum_covered}" -v v="${_sum_valid}" \
    'BEGIN{printf "%.2f", (c/v)*100}')"

  # Compare against the floor in awk (floating-point safe). pass=1 when
  # rate >= floor.
  local _pass
  _pass="$(awk -v r="${_rate}" -v m="${COVERAGE_MIN}" \
    'BEGIN{print (r+0 >= m+0) ? 1 : 0}')"

  local _verdict
  if (( _pass == 1 )); then
    _verdict="PASS"
  else
    _verdict="FAIL"
  fi

  echo "coverage_gate: merged line rate ${_rate}% " \
       "(${_sum_covered}/${_sum_valid} lines)," \
       "floor ${COVERAGE_MIN}% -> ${_verdict}"
  _coverage_gate_step_summary \
    "${_rate}" "${_sum_covered}" "${_sum_valid}" \
    "${COVERAGE_MIN}" "${_verdict}"

  (( _pass == 1 )) || return 1
  return 0
}

# Sourced-driver entry point. Mirrors the other drivers' _run_<tool>
# naming so test.sh / a coverage aggregation step can call it with the
# shard report paths. Delegates to the shared implementation.
_run_coverage_gate() {
  _coverage_gate_run "$@"
}

# _merge_timings <out_file> <in_file>...
#   Merge the per-shard `<seconds> <basename>` timings files (one per
#   coverage shard, produced by _junit_to_timings) into one weights file at
#   <out_file>, the SHARD_WEIGHTS_FILE the next run restores. A spec runs in
#   exactly one shard, so normally one entry per basename; the MAX is kept
#   as a defensive dedup. Non-existent inputs are skipped (a shard may have
#   produced no file); no inputs yields an empty weights file. Output is
#   sorted by basename so the cached weights are deterministic.
_merge_timings() {
  local _out="${1:?BUG: _merge_timings expects <out_file> <in_file>...}"
  shift
  local -a _ins=()
  local _f
  for _f in "$@"; do
    [[ -f "${_f}" ]] && _ins+=("${_f}")
  done
  if (( ${#_ins[@]} == 0 )); then
    : > "${_out}"
    return 0
  fi
  awk '
    ($2 != "") { v = $1 + 0; if (v > max[$2]) max[$2] = v }
    END { for (k in max) print max[k], k }
  ' "${_ins[@]}" | sort -k2,2 > "${_out}"
}

# Standalone CLI: when executed directly (CI: `bash coverage_gate.sh
# coverage/*/cobertura.xml`), run the gate over the argument paths and
# propagate its exit code. The `--merge-timings <out> <in>...` subcommand
# aggregates per-shard timings instead (the coverage-gate job calls it after
# downloading the shard artifacts). When sourced, this guard is false so
# only the functions above are defined.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  if [[ "${1:-}" == "--merge-timings" ]]; then
    shift
    _merge_timings "$@"
  else
    _coverage_gate_run "$@"
  fi
fi
