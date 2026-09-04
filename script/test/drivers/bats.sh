#!/usr/bin/env bash
# drivers/bats.sh - Bats per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides the bats
# runners (unit / unit-shard / integration / bats-path / system),
# the shared _bats_args_with_label helper, and the kcov coverage runners
# (kcov wraps bats, so it lives with the bats driver): _run_coverage for
# the reported figure (full suite / shard) and _run_coverage_path for one
# named spec under instrumentation with no figure at all.
#
# Contract: runs INSIDE the ci / coverage container where test.sh invokes
# it. References ${REPO_ROOT} (a global exported by test.sh) for the spec
# tree. Function names + behaviour are byte-identical to the pre-split
# monolith so every call site in test.sh's main is unchanged.

# ── Bats tests ───────────────────────────────────────────────────────────────

_bats_args_with_label() {
  # Shared helper: populate the caller-supplied array name with the
  # `--jobs N` argument when GNU parallel is available, and set the
  # caller-supplied label var. Reused by every _run_*_tests function so
  # parallelism + fallback messaging stay in one place. Inputs:
  #   $1 = name of array var (e.g. _bats_args)
  #   $2 = name of label string var (e.g. _label)
  # All specs use per-test mktemp dirs (BATS_TEST_TMPDIR / TEMP_DIR) so
  # there's no shared filesystem state between tests — safe to run
  # concurrently. When parallel is missing (earlier alpine test-tools
  # images), fall back to serial bats — slower but correct.
  local -n _out_args="$1"
  local -n _out_label="$2"
  # --recursive so a directory target descends into per-lib sub-folders
  # (test/bats/unit/<lib>/<subunit>_spec.bats); foldered specs are
  # first-class shard units (ADR-00000015). Harmless when the target is a
  # file rather than a directory.
  _out_args=(--recursive)
  if command -v parallel >/dev/null 2>&1; then
    local _jobs
    _jobs="$(nproc 2>/dev/null || echo 4)"
    _out_args+=(--jobs "${_jobs}")
    _out_label="jobs=${_jobs}"
  else
    _out_label="serial; parallel not in PATH"
  fi
}

_run_unit_tests() {
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats Unit Tests (${_label}) ---"
  bats "${_bats_args[@]}" "${REPO_ROOT}/test/bats/unit/"
}

_run_integration_tests() {
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats Integration Tests (${_label}) ---"
  bats "${_bats_args[@]}" "${REPO_ROOT}/test/bats/integration/"
}

_run_tests() {
  # Wrapper retained for the full sequential dev-loop path (local
  # `just test`). Kept so refactors are localised; the CI matrix shard
  # jobs go through _run_unit_shard / _run_integration_tests directly.
  _run_unit_tests
  _run_integration_tests
}

_run_bats_path() {
  # Single-path / filtered inner loop. BATS_FILE (repo-root-relative
  # file or directory) and / or BATS_FILTER (bats -f regex) are set by the
  # outer `--bats-path` / `--filter` flags and plumbed in via
  # `_run_via_compose`. With a path, run just that spec / subtree; with only
  # a filter, apply -f across unit + integration. ShellCheck is skipped
  # (BATS_ONLY=1) and kcov is off so the loop stays fast.
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  [[ -n "${BATS_FILTER:-}" ]] && _bats_args+=(-f "${BATS_FILTER}")
  if [[ -n "${BATS_FILE:-}" ]]; then
    echo "--- Running Bats single path: ${BATS_FILE} (${_label}) ---"
    bats "${_bats_args[@]}" "${REPO_ROOT}/${BATS_FILE}"
  else
    echo "--- Running Bats filtered unit + integration: -f '${BATS_FILTER}' (${_label}) ---"
    bats "${_bats_args[@]}" "${REPO_ROOT}/test/bats/unit/" "${REPO_ROOT}/test/bats/integration/"
  fi
}

# _spec_weight <spec_path>
#   Echo the partition weight for a spec: its recorded runtime in whole
#   seconds from SHARD_WEIGHTS_FILE (lines `<seconds> <basename>`, populated
#   automatically from prior CI runs) when present, else a fallback of the
#   spec's `@test` count -- so a new spec with no recorded time still gets a
#   proportional weight until CI records its real runtime. Keeping the
#   fallback in the SAME function lets _shard_unit_files stay weight-source
#   agnostic (greedy LPT regardless of whether the unit is seconds or count).
_spec_weight() {
  local _spec="${1:?BUG: _spec_weight expects a spec path}"
  local _base
  _base="$(basename -- "${_spec}")"
  # Weight source: SHARD_WEIGHTS_FILE when set (tests), else the canonical
  # in-repo path the CI cache restores to. The container mounts the repo at
  # ${REPO_ROOT}, so dropping the restored weights there means the in-
  # container coverage run reads them with no -e plumbing; a missing file
  # (first run / evicted cache / local run) drops to the @test-count fallback.
  local _wf="${SHARD_WEIGHTS_FILE:-${REPO_ROOT:-}/test/bats/.shard-weights}"
  if [[ -n "${_wf}" && -f "${_wf}" ]]; then
    local _secs
    _secs="$(awk -v b="${_base}" '$2 == b { print $1; f=1; exit } END { exit !f }' \
      "${_wf}" 2>/dev/null)" \
      && { printf '%s\n' "${_secs}"; return 0; }
  fi
  local _c
  _c="$(grep -cE '^@test' "${_spec}" 2>/dev/null || true)"
  printf '%s\n' "${_c:-0}"
}

# _junit_to_timings <junit_xml>
#   Emit `<seconds> <basename>` (one line per <testsuite>) from a bats
#   junit report, so a coverage shard can record the real kcov-mode
#   runtime of each spec FILE in the form _spec_weight reads back. bats
#   `--report-formatter junit` writes one <testsuite name=<spec> time=<sec>>
#   per file; we round the seconds to the nearest whole, floored at 1 so a
#   sub-second spec still carries a non-zero greedy-LPT weight. Attribute
#   order-independent. The <testsuites> root (plural) is skipped. A missing
#   file is a no-op (return 0) so first-run / no-report paths degrade to the
#   @test-count fallback in _spec_weight.
_junit_to_timings() {
  local _xml="${1:?BUG: _junit_to_timings expects a junit xml path}"
  [[ -f "${_xml}" ]] || return 0
  awk '
    /<testsuite[ >]/ {
      name = ""; t = ""
      if (match($0, /name="[^"]*"/)) { name = substr($0, RSTART + 6, RLENGTH - 7) }
      if (match($0, /time="[^"]*"/)) { t = substr($0, RSTART + 6, RLENGTH - 7) }
      if (name == "") next
      n = split(name, p, "/"); base = p[n]
      s = int(t + 0.5); if (s < 1) s = 1
      print s, base
    }
  ' "${_xml}"
}

# The pools a coverage run covers, repo-root-relative and in the order the
# run walks them. ONE roster, read by three places that must agree:
#
#   - _run_coverage's full-suite targets (the directories handed to kcov's
#     `bats --recursive`),
#   - _shard_unit_files' partition pool (the same specs, sliced), and
#   - _coverage_spec_inventory in test.sh, the list the release
#     certificate's scope is derived against.
#
# Typed out three times, a pool could join the run without joining the
# inventory, and every release would then be refused with `partial n/n
# specs` -- a message that contradicts itself and points at nothing.
readonly _COVERAGE_FULL_SUITE_POOLS=(test/bats/unit test/bats/integration)

# The file shape those pools are enumerated by. It is what bats EXECUTES
# under a directory target (`bats --recursive` runs every *.bats), not the
# *_spec.bats naming convention: a manifest names what ran, so an
# inventory keyed on the convention would be a subset of it the day a file
# is named otherwise.
readonly _COVERAGE_SPEC_GLOB='*.bats'

_shard_unit_files() {
  # Shared shard-partition primitive for the coverage matrix. Echoes the
  # newline-separated subset of test/bats/unit/*_spec.bats for shard <n>
  # of <total>, using greedy weight-balanced bin-packing by per-spec
  # _spec_weight -- recorded RUNTIME IN SECONDS where a weights file is
  # present, the `@test` count only as its fallback. Specs are sorted
  # heaviest-first and each is assigned to the currently-lightest shard,
  # so the slowest shard's load approaches max(heaviest spec, total/N) --
  # the floor no partition can beat, since a spec cannot be split --
  # instead of the round-robin ceiling (a single big spec no longer pins
  # one shard 2x above the others). The guard on that property is
  # ci_spec's balance probe, which measures through the same _spec_weight
  # so it follows whichever weight source is in force. Coverage is the
  # only consumer (the bats-unit matrix was replaced by a single fragile
  # job), but the slice is still partitioned so the kcov work spreads
  # evenly across the matrix. _die's on a malformed spec or an empty
  # match. Inputs:
  #   $1 = shard spec `<n>/<total>` (1<=n<=total)
  local _spec="${1:?BUG: _shard_unit_files expects <n>/<total>}"
  if [[ "${_spec}" != */* ]]; then
    _die ci_invalid_shard "Invalid shard spec '${_spec}'. Expected <n>/<total> (e.g. 1/2)."
  fi
  local _shard="${_spec%/*}"
  local _total="${_spec#*/}"
  if ! [[ "${_shard}" =~ ^[0-9]+$ && "${_total}" =~ ^[0-9]+$ ]] \
       || (( _shard < 1 || _shard > _total )); then
    _die ci_invalid_shard "Invalid shard spec '${_spec}'. Need 1<=n<=total."
  fi
  # Greedy longest-processing-time bin-packing. awk reads `<count> <path>`
  # lines (heaviest first), maintains a running load per shard, assigns
  # each spec to the lightest shard, and prints only the files landing in
  # the requested shard. The `sort -k1` secondary on the path keeps the
  # partition deterministic across runs (ties broken by name).
  # find, so the walk descends into per-lib sub-folders
  # (test/bats/unit/<lib>/<subunit>_spec.bats, ADR-00000015) exactly as
  # `bats --recursive` does; each foldered spec is still its own
  # kcov/shard unit. A missing pool is not fatal here -- the empty-match
  # check below reports it once, with the shard that asked.
  local _files _pool _f
  _files=$(
    while IFS= read -r _f; do
      printf '%s %s\n' "$(_spec_weight "${_f}")" "${_f}"
    done < <(
      for _pool in "${_COVERAGE_FULL_SUITE_POOLS[@]}"; do
        find "${REPO_ROOT}/${_pool}" -type f \
          -name "${_COVERAGE_SPEC_GLOB}" 2>/dev/null
      done
    ) \
      | sort -k1,1nr -k2,2 \
      | awk -v want="${_shard}" -v t="${_total}" '
          BEGIN { for (i = 1; i <= t; i++) load[i] = 0 }
          {
            # pick the lightest shard (ties -> lowest index for stability)
            min = 1
            for (i = 2; i <= t; i++) if (load[i] < load[min]) min = i
            load[min] += $1
            if (min == want) print $2
          }'
  )
  if [[ -z "${_files}" ]]; then
    _die ci_empty_shard "No spec files matched shard ${_spec}. Empty test/bats/{unit,integration}/ ?"
  fi
  printf '%s\n' "${_files}"
}

_run_unit_shard() {
  # Run a deterministic subset of test/bats/unit/*_spec.bats for one shard.
  # Spec accepts `<n>/<total>` where 1<=n<=total. Partition is the
  # greedy weight-balanced bin-packing in _shard_unit_files, so the slice
  # matches the coverage matrix's shard <n>. Retained as a plain-mode
  # convenience (`test.sh --bats-unit-shard N/T`) for running a coverage
  # slice locally without kcov; the CI unit gate is the kcov coverage
  # matrix (+ the plain bats-fragile job for the kcov-skipped delta).
  local _spec="${1:?BUG: _run_unit_shard expects <n>/<total>}"
  local _files
  _files="$(_shard_unit_files "${_spec}")"
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats Unit Shard ${_spec} (${_label}) ---"
  # Word-split intentional: print one line per shard file.
  # shellcheck disable=SC2086
  printf '  shard:%s\n' ${_files}
  # Word-split intentional: bats accepts multiple file args.
  # shellcheck disable=SC2086
  bats "${_bats_args[@]}" ${_files}
}

# ── kcov-fragile unit specs ────────────────────────────────────────────

readonly _FRAGILE_GUARD_RE='^[[:space:]]*\[ "\$\{COVERAGE:-0\}" = 1 \] &&[[:space:]]*skip'

_fragile_unit_files() {
  # Echo the newline-separated set of test/bats/unit/*_spec.bats files that
  # contain at least one kcov-fragile test — those guarded at the start of
  # a test body by `[ "${COVERAGE:-0}" = 1 ] && skip ...`. The coverage
  # matrix SKIPS these tests (they perturb the kcov ptrace wrapper), so the
  # plain bats-fragile job runs exactly this set with COVERAGE unset to
  # preserve the delta. Computed at runtime by grepping for the skip guard
  # so it self-maintains: a NEW fragile-skip in a 10th file is picked up
  # automatically (a spec asserts the set). The regex is line-anchored on
  # leading whitespace + the literal bracket so a COMMENT that merely
  # mentions the guard (e.g. this driver's own spec) is NOT matched.
  # _die's on an empty match (the guard pattern changed or the fragile
  # tests were all removed — both want a human).
  local _files
  _files=$(grep -rlE "${_FRAGILE_GUARD_RE}" "${REPO_ROOT}/test/bats/unit" | sort)
  if [[ -z "${_files}" ]]; then
    _die ci_no_fragile_files \
      "No kcov-fragile spec files matched the skip guard in test/bats/unit/. Did the guard pattern change?"
  fi
  printf '%s\n' "${_files}"
}

_run_bats_fragile() {
  # Run ONLY the kcov-fragile unit specs in PLAIN mode (COVERAGE unset),
  # for the GHA bats-fragile job. These are the exact tests the coverage
  # matrix skips, so running them here preserves full unit coverage with
  # zero double-run: non-fragile tests run under kcov (coverage matrix),
  # fragile tests run plain here. Selection is runtime-computed
  # (_fragile_unit_files) so the set self-maintains.
  local _files
  _files="$(_fragile_unit_files)"
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats kcov-fragile Unit Specs (plain; ${_label}) ---"
  # Word-split intentional: print one line per fragile file.
  # shellcheck disable=SC2086
  printf '  fragile:%s\n' ${_files}
  # Word-split intentional: bats accepts multiple file args. COVERAGE is
  # NOT set, so the [ "${COVERAGE:-0}" = 1 ] && skip guards fall through
  # and the fragile tests actually run.
  # shellcheck disable=SC2086
  bats "${_bats_args[@]}" ${_files}
}

# ── Kcov coverage ────────────────────────────────────────────────────────────

# _coverage_exclude_path
#   Echo the comma-joined --exclude-path argument every kcov run in this
#   driver passes. Shared by the shard / full-suite runner (which reports a
#   figure) and the single-spec runner (which reports none): what kcov
#   instruments has to be the SAME in both, or a failure seen on a shard
#   would not be reproducible through the single-spec entry -- which is the
#   only reason that entry exists.
#
#   The set is what a coverage FIGURE must not count: the specs themselves,
#   the harness that runs them, the two base-management scripts that never
#   execute inside the container, and the dotfiles / workflow YAML that are
#   not shell at all.
_coverage_exclude_path() {
  local _excludes=(
    "${REPO_ROOT}/test/"
    "${REPO_ROOT}/script/test/"
    "${REPO_ROOT}/dist/script/base/init.sh"
    "${REPO_ROOT}/dist/script/base/upgrade.sh"
    "${REPO_ROOT}/dist/config/shell/bashrc"
    "${REPO_ROOT}/dist/config/shell/terminator/config"
    "${REPO_ROOT}/dist/config/shell/tmux/tmux.conf"
    "${REPO_ROOT}/.github/"
  )
  local IFS=,
  printf '%s' "${_excludes[*]}"
}

# _run_coverage_path <path>
#   Run ONE spec file (or directory) under kcov instrumentation. The
#   inner loop for the kcov-only failure class: a spec that is red under
#   kcov and green without it. Before this existed the only instrumented
#   entries were the whole suite and a whole shard -- 8 to 12 minutes per
#   red-green iteration -- so the diagnosis was done with a hand-rolled
#   `docker run` + kcov instead, the one step of that work that could not
#   go through `just`.
#
#   IT REPORTS NO COVERAGE FIGURE, and that is the design, not a gap. The
#   kcov report goes to a throwaway directory created here and removed on
#   the way out, so no path through this function can write
#   ${REPO_ROOT}/coverage: not cobertura.xml, which the coverage-gate
#   merges into the project rate, and not timings.tsv, which becomes the
#   NEXT partition's weights. One spec's lines over the whole tree's
#   denominator is not a project rate, and one spec's runtime is not a
#   partition input; a mode that wrote either would be able to feed the
#   gate a number that means nothing. What it produces is the RUN --
#   bats' pass/fail output and kcov's exit status.
#
#   Target selection is the caller's path, verbatim. It never consults
#   _shard_unit_files, so the greedy-LPT partition and the recorded
#   weights file (restored from cache on CI, absent locally, so the two
#   partitions genuinely differ) cannot change what runs. `just test
#   coverage <n>/<total>` locally does NOT run the same specs CI's shard
#   <n> runs; this does.
#
#   BATS_FILTER, when set, narrows further to matching test names (bats
#   -f), so one @test can be put under kcov rather than one file.
_run_coverage_path() {
  local _path="${1:?BUG: _run_coverage_path expects a repo-root-relative spec path}"
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  [[ -n "${BATS_FILTER:-}" ]] && _bats_args+=(-f "${BATS_FILTER}")

  # Container-local scratch, never the mounted checkout. Removed below
  # whether the spec passed or failed.
  local _report_dir
  _report_dir="$(mktemp -d)"
  echo "--- Running one spec under kcov: ${_path} (${_label}) ---"
  echo "    instrumentation only -- no coverage figure is produced and" \
       "nothing is written to ${REPO_ROOT}/coverage"
  local _rc=0
  kcov \
    --include-path="${REPO_ROOT}" \
    --exclude-path="$(_coverage_exclude_path)" \
    "${_report_dir}" \
    bats "${_bats_args[@]}" "${REPO_ROOT}/${_path}" \
    || _rc=$?
  rm -rf "${_report_dir}"
  return "${_rc}"
}

_run_coverage() {
  # Run kcov-instrumented bats and write an HTML/cobertura report to
  # ${REPO_ROOT}/coverage. With no argument, runs the FULL suite (unit +
  # integration) — the local `just test coverage` / release path. With a
  # `<n>/<total>` shard spec, runs kcov over ONLY this shard's
  # slice, so the GHA `coverage` matrix spreads the kcov work evenly:
  #
  #   - the slice is the greedy-LPT partition _shard_unit_files computes,
  #     the same one _run_unit_shard selects, so shard k here instruments
  #     exactly the code shard k runs.
  #   - unit and integration specs are ONE pool, spread by runtime like any
  #     other spec. Integration is NOT appended whole to the last shard:
  #     that rule made the last shard the sole bottleneck and is superseded
  #     (ADR-00000008 amendment). Every spec still runs exactly once across
  #     the matrix, and the coverage-gate merges the per-shard cobertura
  #     reports back into one line-weighted project figure, so WHERE a slice
  #     runs does not matter to the merged total -- only that it runs once.
  #
  # Each shard writes to ${REPO_ROOT}/coverage and the GHA job uploads it
  # as a CI artifact; coverage_gate.sh sums covered/valid lines across all
  # shards' cobertura.xml into one project rate (no external SaaS).
  local _shard_spec="${1:-}"

  # Shared with _run_coverage_path: both runners must instrument the same
  # tree, or a failure seen here would not reproduce there.
  local _exclude_path
  _exclude_path="$(_coverage_exclude_path)"

  local -a _targets=()
  local _pool
  if [[ -z "${_shard_spec}" ]]; then
    echo "--- Running Tests with Kcov Coverage (full suite) ---"
    # The pools, from the one roster the inventory reads too -- so what
    # the certificate is measured against is what the run walked.
    for _pool in "${_COVERAGE_FULL_SUITE_POOLS[@]}"; do
      _targets+=("${REPO_ROOT}/${_pool}/")
    done
  else
    # _shard_unit_files _die's on a malformed / empty shard spec. Its pool
    # now spans unit + integration specs (time-balanced), so a shard slice
    # already carries whatever integration specs it was assigned -- no
    # last-shard special case (the old all-integration-on-last-shard rule is
    # superseded; every spec still runs exactly once across the matrix, just
    # spread by runtime).
    local _files
    _files="$(_shard_unit_files "${_shard_spec}")"
    echo "--- Running Tests with Kcov Coverage (shard ${_shard_spec}) ---"
    # Word-split intentional: one shard file per target entry.
    # shellcheck disable=SC2206
    _targets=(${_files})
    # Word-split intentional: print one line per shard target.
    printf '  cov-shard:%s\n' "${_targets[@]}"
  fi

  # Capture each spec FILE's real kcov-mode runtime via bats' junit report
  # (one <testsuite time=...> per file) and convert it to coverage/timings.tsv
  # (`<seconds> <basename>`). The coverage-gate job merges every shard's
  # timings into the SHARD_WEIGHTS_FILE the NEXT run restores, so the
  # partition self-balances by real time (greedy LPT, ADR-00000008). The
  # junit report goes to a temp dir (only timings.tsv needs uploading); kcov's
  # exit code (the actual test result) is preserved so a failing shard fails.
  local _junit_dir
  _junit_dir="$(mktemp -d)"
  local _rc=0
  kcov \
    --include-path="${REPO_ROOT}" \
    --exclude-path="${_exclude_path}" \
    "${REPO_ROOT}/coverage" \
    bats --recursive --report-formatter junit --output "${_junit_dir}" "${_targets[@]}" \
    || _rc=$?
  _junit_to_timings "${_junit_dir}/report.xml" \
    > "${REPO_ROOT}/coverage/timings.tsv" 2>/dev/null || true
  rm -rf "${_junit_dir}"
  return "${_rc}"
}

# ── In-job parallel kcov (local mode) ────────────────────────────────────────
#
# ADR-00000008 shards kcov ACROSS a CI matrix, which is the only parallelism
# a GitHub-hosted plan sells: one runner runs one job, so the way to use
# eight machines is eight jobs. On ONE fat machine that mechanism buys
# nothing -- a self-hosted runner takes the matrix one entry at a time --
# and the run that matters most is the one the matrix cannot help with
# anyway: `just release coverage-badge` publishes only a `scope=full`
# measurement, so every release pays for a whole-suite coverage run, and
# that run was serial.
#
# Serial is not a kcov floor. kcov's bash engine parses one xtrace stream
# per traced process and is single-threaded, and `kcov` wrapping
# `bats --jobs` is unreliable for coverage ACCURACY -- which is exactly why
# ADR-00000008 left the coverage path serial while the normal path is not.
# What that argument does NOT forbid is N INDEPENDENT kcov processes, each
# wrapping a serial bats over its own slice, merged afterwards. Each process
# traces its own children and writes its own database; nothing is shared but
# the merge.
#
# The slices come from `_shard_unit_files`, the SAME greedy-LPT primitive the
# CI matrix partitions with (base#724). A second partitioner would be a
# second roster, and the failure mode of two rosters is a spec that belongs
# to neither: an exhaustive, disjoint partition is the whole reason the
# merged total may be read as the project's.

# _coverage_parallel_workdir
#   Echo the scratch root the slices write into. COVERAGE_LOCAL_WORKDIR
#   names it explicitly -- a spec that has to point at one slice's output
#   directory, and an operator keeping the per-slice logs after a red run;
#   otherwise a fresh container-local temp dir, removed on the way out.
_coverage_parallel_workdir() {
  if [[ -n "${COVERAGE_LOCAL_WORKDIR:-}" ]]; then
    mkdir -p "${COVERAGE_LOCAL_WORKDIR}"
    printf '%s\n' "${COVERAGE_LOCAL_WORKDIR}"
    return 0
  fi
  mktemp -d
}

# _run_coverage_parallel <jobs>
#   Run the WHOLE suite under kcov as <jobs> concurrent processes over the
#   time-balanced partition, then merge their reports into
#   ${REPO_ROOT}/coverage -- the same tree the serial run writes, carrying
#   the same `kcov-merged/cobertura.xml` the coverage-gate and the release
#   badge generator already read. Returns the worst slice's status, so a red
#   spec is still red.
#
#   THREE REFUSALS, and each is a way the merge could otherwise lie:
#
#   1. A job count that is not a positive integer. It would reach
#      `_shard_unit_files` as a malformed total, whose message names a shard
#      spec nobody typed.
#   2. A slice that matched no spec files (jobs > specs). An empty slice is
#      not a slice that ran nothing; it is a partition that never covered
#      the tree.
#   3. A slice that produced NO REPORT -- a kcov that died after its tests
#      passed, leaving an empty output directory and a zero status. Merging
#      the survivors would publish a smaller line set under a whole-suite
#      certificate, which reads as a coverage regression rather than as the
#      lost slice it is. "Cannot tell" resolves to refusing.
_run_coverage_parallel() {
  local _jobs="${1:?BUG: _run_coverage_parallel expects <jobs>}"
  if ! [[ "${_jobs}" =~ ^[0-9]+$ ]] || (( _jobs < 1 )); then
    _die ci_invalid_coverage_jobs \
      "Invalid coverage job count '${_jobs}'. Expected a positive integer (default: nproc)."
  fi

  # Shared with the serial runner and the single-spec runner: all three must
  # instrument the same tree, or a figure produced here would not be
  # comparable with the one the matrix produces.
  local _exclude_path
  _exclude_path="$(_coverage_exclude_path)"

  # The partition is computed BEFORE the first fork, and that ordering is
  # load-bearing: `_shard_unit_files` refuses an empty match by `_die`, and a
  # `_die` inside a background job exits the CHILD -- the parent would go on
  # to wait for a slice that never ran and then merge N-1 reports.
  local -a _slices=()
  local _i _slice _srun_rc
  for (( _i = 1; _i <= _jobs; _i++ )); do
    _srun_rc=0
    _slice="$(_shard_unit_files "${_i}/${_jobs}")" || _srun_rc=$?
    if (( _srun_rc != 0 )) || [[ -z "${_slice}" ]]; then
      _die ci_coverage_parallel_empty_slice \
        "coverage slice ${_i} of ${_jobs} matched no spec files. ${_jobs} is more slices than the suite has specs; run with fewer --jobs."
    fi
    _slices+=("${_slice}")
  done

  local _work
  _work="$(_coverage_parallel_workdir)"
  echo "--- Running Tests with Kcov Coverage (local, ${_jobs} parallel kcov processes) ---"

  local -a _pids=()
  for (( _i = 1; _i <= _jobs; _i++ )); do
    mkdir -p "${_work}/junit-${_i}"
    # Word-split intentional: one bats target per slice file. Each slice's
    # bats is SERIAL (no --jobs): `kcov` over `bats --jobs` is the
    # combination ADR-00000008 found unreliable for accuracy, and this mode
    # exists to get the cores WITHOUT it.
    # shellcheck disable=SC2086
    kcov \
      --include-path="${REPO_ROOT}" \
      --exclude-path="${_exclude_path}" \
      "${_work}/part-${_i}" \
      bats --recursive --report-formatter junit \
        --output "${_work}/junit-${_i}" ${_slices[_i - 1]} \
      > "${_work}/log-${_i}" 2>&1 &
    _pids+=("$!")
  done

  # Each slice's output is replayed WHOLE and in order after its wait, not
  # streamed: N concurrent bats writing one terminal interleaves into
  # something no one can read a failure out of, which would send the
  # operator back to the serial run to find out what broke.
  local _rc=0 _prc
  for (( _i = 1; _i <= _jobs; _i++ )); do
    _prc=0
    wait "${_pids[_i - 1]}" || _prc=$?
    echo "--- coverage slice ${_i}/${_jobs} (exit ${_prc}) ---"
    cat "${_work}/log-${_i}" 2>/dev/null || true
    (( _prc == 0 )) || _rc="${_prc}"
  done

  # Refusal 3. Captured rather than piped into a `-q` reader: a reader that
  # leaves at its first match strands `find` with SIGPIPE, and the whole
  # point here is to tell "no report" apart from "reader gave up".
  local _found
  for (( _i = 1; _i <= _jobs; _i++ )); do
    _found="$(find "${_work}/part-${_i}" -type f -name cobertura.xml 2>/dev/null)"
    [[ -n "${_found}" ]] && continue
    _die ci_coverage_slice_no_report \
      "coverage slice ${_i} of ${_jobs} produced no report under ${_work}/part-${_i}; merging the rest would publish a smaller line set as the project total. Its log is ${_work}/log-${_i}."
  done

  # kcov's own merge, over every slice. A line covered by ANY slice is
  # covered: the union is the only correct reading, and it is what the
  # coverage-gate independently computes over the per-shard reports of the
  # CI path (base#730).
  local -a _parts=()
  for (( _i = 1; _i <= _jobs; _i++ )); do
    _parts+=("${_work}/part-${_i}")
  done
  mkdir -p "${REPO_ROOT}/coverage"
  local _mrc=0
  kcov --merge "${REPO_ROOT}/coverage" "${_parts[@]}" || _mrc=$?
  if (( _mrc != 0 )); then
    _die ci_coverage_merge_failed \
      "kcov --merge over ${_jobs} slice report(s) failed (status ${_mrc}); the per-slice reports are under ${_work}."
  fi

  # The run manifest, merged from every slice's junit report. It is what
  # `_measured_coverage_scope` compares against the spec inventory, so a
  # manifest carrying one slice's specs would stamp `partial` and
  # `just release coverage-badge` would refuse the run -- which is the whole
  # reason this mode exists.
  {
    for (( _i = 1; _i <= _jobs; _i++ )); do
      _junit_to_timings "${_work}/junit-${_i}/report.xml"
    done
  } | LC_ALL=C sort -k2,2 > "${REPO_ROOT}/coverage/timings.tsv" 2>/dev/null || true

  [[ -n "${COVERAGE_LOCAL_WORKDIR:-}" ]] || rm -rf "${_work}"
  return "${_rc}"
}

# ── System runtime-test specs ────────────────────────────────────
#
# Opt-in path. Requires the ci-system compose service (mounts host
# /var/run/docker.sock + sets MOUNT_DOCKER_SOCK=1). Drives
# `docker buildx build --target runtime-test` against synthesized
# fixtures so the runtime smoke gate is actually exercised end-to-end,
# not just static-grep asserted.

readonly _SYSTEM_BUILDER="template-system"

_system_setup() {
  # Socket path is overridable via SYSTEM_DOCKER_SOCK (default the real
  # daemon socket) so the guard is exercisable against a per-test path
  # instead of the single process-global /var/run/docker.sock -- the two
  # prerequisite-guard tests otherwise race on that shared literal under
  # parallel bats jobs. Production leaves it unset, so behaviour is unchanged.
  local _sock="${SYSTEM_DOCKER_SOCK:-/var/run/docker.sock}"
  [[ -S "${_sock}" ]] \
    || _die ci_no_docker_socket "system mode requires ${_sock}; run via 'just test system' (ci-system service)."
  command -v docker >/dev/null 2>&1 \
    || _die ci_no_docker_cli "system mode requires docker CLI in the test-tools image (test-tools < v0.23.2 lacks it)."

  # Dedicated buildx builder isolates the cache from the host's default
  # context, so prune at the end only touches our cache (not the user's
  # other docker work). `--use` switches active builder for this process.
  if ! docker buildx inspect "${_SYSTEM_BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${_SYSTEM_BUILDER}" --driver docker-container --bootstrap >/dev/null
  fi
  docker buildx use "${_SYSTEM_BUILDER}"
}

_system_teardown() {
  # Prune only the dedicated builder's cache. Leaves the host's default
  # context untouched so the user's other docker workflows aren't
  # disturbed. `|| true` because builder may already be gone if
  # something earlier aborted partway through.
  docker buildx prune --builder "${_SYSTEM_BUILDER}" -af >/dev/null 2>&1 || true
}

_run_system() {
  _system_setup
  trap _system_teardown EXIT

  local -a _bats_args=()
  local _jobs
  _jobs="$(nproc 2>/dev/null || echo 1)"
  if command -v parallel >/dev/null 2>&1; then
    _bats_args=(--jobs "${_jobs}")
  fi

  bats "${_bats_args[@]}" "${REPO_ROOT}/test/bats/system/"
}
