#!/usr/bin/env bash
# drivers/coverage_gate.sh - self-hosted, CI-agnostic coverage-floor gate.
#
# DUAL MODE: this file is both a sourced driver (test.sh sources it after
# _lib.sh, so _log_* / _die are available, exposing _run_coverage_gate)
# AND a standalone CLI (CI and `just test coverage-gate` invoke
# `bash coverage_gate.sh --verdict <manifest> <cobertura>...` directly).
# The standalone path re-implements the minimum logging it needs so it
# has no dependency on the test.sh sourcing context.
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
# shard, and the project total is the per-line UNION across them -- a line
# is covered if ANY shard executed it, and `valid` is the count of DISTINCT
# source lines. See _coverage_gate_run for the two halves that make that
# invariant hold (the union itself, and the path-alias canonicalisation).
#
# It is neither of the two readings that look right and are not. Not the
# average of the per-shard line-rate attributes: shards have different
# denominators (each shard instruments only the slice of the time-balanced
# partition it was handed -- unit and integration specs are ONE pool,
# spread by recorded runtime, so two slices practically never cover the
# same number of lines), so averaging would weight a small shard equally
# with a large one. And not SUM(covered) / SUM(valid) of the root counters,
# which is what this gate did until base#730: every shard runs with
# --include-path=<repo> so every report carries the WHOLE tree, and adding
# the denominators counts shared source once per shard -- the rate then
# drifts DOWN as the shard count rises (52.9% at 4 shards, 42% at 8, same
# suite) and the fix was not a bigger margin but the union above.
#
# THRESHOLD: COVERAGE_MIN (percent, env-overridable). The default is set
# just below the current measured rate so it does not false-fail today;
# it is meant to RATCHET UP as coverage improves (the v2 regression-vs-
# main-baseline gate is a documented follow-up, not built here).

# Default floor (percent). BASIS: the last CI run on main measured the
# merged project rate at 84.72% (5907/6972 lines), so an 80 floor leaves
# 4.72 points of margin -- enough that ordinary churn in a single PR does
# not trip the gate, tight enough that a real regression is visible. The
# floor was re-based from 50 to 80 once the alias double-counting was
# fixed and the rate meant what it said: before that fix the same suite
# read ~51%, understating the project by roughly 33 points, and a 50
# floor against an 85% reality left ~35 points of dead slack. Raise it as
# coverage climbs. Overridable via the COVERAGE_MIN env var.
: "${COVERAGE_MIN:=80}"

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
# project rate by per-line UNION and returns non-zero when it is below
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
  # -- shard-count-invariant.
  #
  # PATH-ALIAS CANONICALISATION (the second half of that invariant): the
  # union key must NOT be the raw kcov `filename`, because kcov reports the
  # SAME source file under several prefix-truncated aliases in the same
  # report set -- e.g. lib/_lib.sh, docker/lib/_lib.sh,
  # script/docker/lib/_lib.sh and dist/script/docker/lib/_lib.sh are all one
  # file. Each alias is a distinct key prefix, so each contributed its own
  # full copy of the file's lines to `valid` while only the aliases that
  # recorded hits contributed to `cov`: the denominator was inflated and,
  # because which alias appears depends on which shard ran the file, adding
  # ONE spec reshuffled the shards and moved the reported rate.
  #
  # The aliases are pure prefix truncations of one another, so a
  # longest-path-SUFFIX-wins normalisation is exact and needs no filesystem
  # access: the canonical name of a filename is the LONGEST filename in the
  # report set of which it is a path suffix (matched on "/" component
  # boundaries, so lib/_lib.sh is a suffix of docker/lib/_lib.sh but
  # ib/_lib.sh is not). Basename-only keying would be WRONG: distinct files
  # legitimately share a basename (dist/script/docker/lib/deploy.sh and the
  # generated field launcher deploy.sh) and merging them would overstate
  # coverage. Observations are collected keyed on the raw filename in one
  # pass, then re-keyed on the canonical name at END, since the canonical
  # map is only knowable once every filename has been seen.
  local _parsed _sum_covered _sum_valid _alias_collapsed
  _parsed="$(awk '
    # 1 when short is a path suffix of long on a "/" component boundary
    # (a strict suffix: identical names are not aliases of each other).
    function is_path_suffix(short, long,   d) {
      d = length(long) - length(short)
      if (d < 1) return 0
      return (substr(long, d + 1) == short && substr(long, d, 1) == "/")
    }
    match($0, /<class [^>]*filename="[^"]*"/) {
      s = substr($0, RSTART, RLENGTH); sub(/.*filename="/, "", s); sub(/".*/, "", s)
      cur = s
      if (!(cur in seen)) { seen[cur] = 1; names[++n_names] = cur }
      next
    }
    match($0, /<line number="[0-9]+" hits="[0-9]+"/) {
      ln = substr($0, RSTART, RLENGTH)
      n = ln; sub(/.*number="/, "", n); sub(/".*/, "", n)
      h = ln; sub(/.*hits="/, "", h); sub(/".*/, "", h)
      k = cur SUBSEP n; valid[k] = 1; if (h + 0 > 0) cov[k] = 1
    }
    END {
      collapsed = 0
      for (i = 1; i <= n_names; i++) {
        best = names[i]
        for (j = 1; j <= n_names; j++) {
          if (is_path_suffix(names[i], names[j]) && length(names[j]) > length(best)) {
            best = names[j]
          }
        }
        canon[names[i]] = best
        if (best != names[i]) collapsed++
      }
      for (k in valid) { split(k, p, SUBSEP); u_valid[canon[p[1]] ":" p[2]] = 1 }
      for (k in cov)   { split(k, p, SUBSEP); u_cov[canon[p[1]] ":" p[2]] = 1 }
      c = 0; v = 0
      for (k in u_valid) v++
      for (k in u_cov) c++
      printf "%d %d %d", c, v, collapsed
    }
  ' "$@")"
  read -r _sum_covered _sum_valid _alias_collapsed <<< "${_parsed}"

  if (( _sum_valid == 0 )); then
    echo "coverage_gate: total valid lines is zero (no <line> data in report set)" >&2
    return 2
  fi

  # Always reported, including the 0 case, so a future change in how kcov
  # reports paths shows up as a moved number instead of failing silently.
  echo "coverage_gate: collapsed ${_alias_collapsed} kcov path alias(es)" \
       "into their canonical filenames" >&2

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
#   Merge the per-shard `<seconds> <spec path>` timings files (one per
#   coverage shard, produced by _junit_to_timings; repo-relative paths since
#   base#1410) into one weights file at <out_file>, the SHARD_WEIGHTS_FILE
#   the next run restores. A spec runs in exactly one shard, so normally one
#   entry per path; the MAX is kept as a defensive dedup. Non-existent
#   inputs are skipped (a shard may have produced no file); no inputs yields
#   an empty weights file. Output is sorted by path so the cached weights
#   are deterministic.
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

# _coverage_gate_run_dirs <dir>... -- the gate over ONE report per kcov run
# directory. kcov writes a run's report under <dir>/<command>.<hash>/
# cobertura.xml, and a merged one under <dir>/kcov-merged/cobertura.xml
# once more than one command reported into <dir>; neither layout puts a
# cobertura.xml at <dir> itself. So: the merged report when there is one,
# else the first cobertura.xml under <dir> -- never both, which would count
# the run twice. A directory holding no report contributes nothing; no
# report anywhere is a refusal. The coverage verdict below reads reports by
# this one rule, whichever environment hands it the run directories.
_coverage_gate_run_dirs() {
  local _dir _first
  local -a _reports=()
  for _dir in "$@"; do
    _dir="${_dir%/}"
    if [[ -f "${_dir}/kcov-merged/cobertura.xml" ]]; then
      _reports+=("${_dir}/kcov-merged/cobertura.xml")
      continue
    fi
    _first="$(find "${_dir}" -type f -name cobertura.xml 2>/dev/null \
      | LC_ALL=C sort | sed -n 1p)"
    [[ -n "${_first}" ]] && _reports+=("${_first}")
  done
  if (( ${#_reports[@]} == 0 )); then
    echo "coverage_gate: no cobertura.xml found under: $*" >&2
    return 1
  fi
  printf 'coverage report: %s\n' "${_reports[@]}"
  _coverage_gate_run "${_reports[@]}"
}

# _coverage_verdict <manifest> <run-dir>... -- THE coverage verdict, the
# one every environment that decides on a coverage run reaches (base#1411):
# the GitHub-hosted coverage-gate job, the self-hosted coverage-local
# workflow, `just test coverage-gate` and the pre-PR mirror's coverage-gate
# leg all call `--verdict` the same way, so a check added here reaches all
# of them at once.
#
# It is two checks, and both always run so one red run reports both:
#   1. the floor: _coverage_gate_run_dirs over <run-dir>... against
#      COVERAGE_MIN -- one report per run directory, by the rule above;
#   2. the union: `test.sh --coverage-union-check <manifest>`, which names
#      every spec the run manifest lacks. The floor cannot see such a spec
#      -- it contributes no lines to either side of the ratio.
# The union half is test.sh's own check run as a process, not a copy of
# it: test.sh sources this file, so sourcing test.sh from here would be
# circular. Returns non-zero when either half fails (2 on a usage error).
_coverage_verdict() {
  if (( $# < 2 )); then
    echo "coverage_gate: --verdict expects <manifest> <run-dir>..." >&2
    return 2
  fi
  local _manifest="${1}"
  shift
  local _test_sh _floor_rc=0 _union_rc=0
  _test_sh="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)/test.sh"
  _coverage_gate_run_dirs "$@" || _floor_rc=$?
  bash "${_test_sh}" --coverage-union-check "${_manifest}" || _union_rc=$?
  if (( _floor_rc != 0 )); then
    return "${_floor_rc}"
  fi
  return "${_union_rc}"
}

# Standalone CLI: when executed directly, `--verdict <manifest>
# <run-dir>...` runs the whole coverage verdict (see _coverage_verdict);
# this is the form every workflow, recipe and the pre-PR mirror use.
# `--run-dirs <dir>...` runs the floor alone over one report per run
# directory, and bare report paths run the floor alone over those reports.
# `--merge-timings <out> <in>...` aggregates per-shard timings (the
# coverage-gate job and the pre-PR mirror call it ahead of the verdict to
# build the run manifest). When sourced, this guard is false so only the
# functions above are defined.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  case "${1:-}" in
    --merge-timings) shift; _merge_timings "$@" ;;
    --verdict) shift; _coverage_verdict "$@" ;;
    --run-dirs) shift; _coverage_gate_run_dirs "$@" ;;
    *) _coverage_gate_run "$@" ;;
  esac
fi
