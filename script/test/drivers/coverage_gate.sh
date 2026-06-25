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

# Parse one cobertura.xml's root <coverage> element and echo
# "<covered> <valid>". Echoes nothing (and the caller treats it as a
# parse failure) when either counter is absent. Pure text extraction so
# it needs no XML library in the test-tools image.
_coverage_gate_parse() {
  local _file="${1}"
  # kcov emits the counters as attributes on the root element, e.g.
  #   <coverage line-rate="0.529" lines-covered="529" lines-valid="1000" ...>
  # Grab the first occurrence of each (the root is the first element).
  local _covered _valid
  _covered="$(grep -o 'lines-covered="[0-9]*"' "${_file}" 2>/dev/null \
    | head -n1 | grep -o '[0-9]*')"
  _valid="$(grep -o 'lines-valid="[0-9]*"' "${_file}" 2>/dev/null \
    | head -n1 | grep -o '[0-9]*')"
  [[ -n "${_covered}" && -n "${_valid}" ]] || return 1
  printf '%s %s\n' "${_covered}" "${_valid}"
}

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

  local _sum_covered=0 _sum_valid=0 _file _parsed _c _v
  for _file in "$@"; do
    if [[ ! -f "${_file}" ]]; then
      echo "coverage_gate: report not found: ${_file}" >&2
      return 2
    fi
    if ! _parsed="$(_coverage_gate_parse "${_file}")"; then
      echo "coverage_gate: no line counters in: ${_file}" >&2
      return 2
    fi
    _c="${_parsed% *}"
    _v="${_parsed#* }"
    _sum_covered=$(( _sum_covered + _c ))
    _sum_valid=$(( _sum_valid + _v ))
  done

  if (( _sum_valid == 0 )); then
    echo "coverage_gate: total valid lines is zero (empty report set)" >&2
    return 2
  fi

  # Line-weighted total: SUM(covered)/SUM(valid), as a percentage.
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

# Standalone CLI: when executed directly (CI: `bash coverage_gate.sh
# coverage/*/cobertura.xml`), run the gate over the argument paths and
# propagate its exit code. When sourced, this guard is false so only the
# functions above are defined.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _coverage_gate_run "$@"
fi
