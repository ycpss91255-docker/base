#!/usr/bin/env bash
# drivers/bats.sh - Bats per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides the bats
# runners (unit / unit-shard / integration / bats-path / behavioural),
# the shared _bats_args_with_label helper, and the kcov coverage runner
# (kcov wraps bats, so it lives with the bats driver).
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
  _out_args=()
  if command -v parallel >/dev/null 2>&1; then
    local _jobs
    _jobs="$(nproc 2>/dev/null || echo 4)"
    _out_args=(--jobs "${_jobs}")
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

_shard_unit_files() {
  # Shared shard-partition primitive for the coverage matrix. Echoes the
  # newline-separated subset of test/bats/unit/*_spec.bats for shard <n>
  # of <total>, using greedy weight-balanced bin-packing by per-spec
  # `@test` count: specs are sorted heaviest-first and each is assigned to
  # the currently-lightest shard, so the slowest shard's @test load
  # approaches total/N instead of the round-robin floor (a single big
  # spec no longer pins one shard 2x above the others). Coverage is the
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
  local _files
  _files=$(
    for _f in "${REPO_ROOT}"/test/bats/unit/*_spec.bats; do
      [[ -e "${_f}" ]] || continue
      printf '%s %s\n' "$(grep -cE '^@test' "${_f}")" "${_f}"
    done \
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
    _die ci_empty_shard "No spec files matched shard ${_spec}. Empty test/bats/unit/ ?"
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

_run_coverage() {
  # Run kcov-instrumented bats and write an HTML/cobertura report to
  # ${REPO_ROOT}/coverage. With no argument, runs the FULL suite (unit +
  # integration) — the local `just test coverage` / release path. With a
  # `<n>/<total>` shard spec, runs kcov over ONLY this shard's
  # slice so the GHA `coverage` matrix mirrors the bats-unit matrix:
  #
  #   - unit specs: the SAME round-robin slice _run_unit_shard selects
  #     (via _shard_unit_files), so shard k covers the identical unit code
  #     the unit-test matrix exercises.
  #   - integration specs: run ONLY on the LAST shard (n == total) rather
  #     than every shard, so the 87 integration specs aren't kcov'd T
  #     times (wasted minutes + duplicated lines). The self-hosted
  #     coverage-gate merges the per-shard cobertura reports back into one
  #     line-weighted project figure, so where a slice runs doesn't matter
  #     to the merged total — only that every slice runs exactly once
  #     across the matrix.
  #
  # Each shard writes to ${REPO_ROOT}/coverage and the GHA job uploads it
  # as a CI artifact; coverage_gate.sh sums covered/valid lines across all
  # shards' cobertura.xml into one project rate (no external SaaS).
  local _shard_spec="${1:-}"

  local _excludes=(
    "${REPO_ROOT}/test/"
    "${REPO_ROOT}/script/test/"
    "${REPO_ROOT}/downstream/script/base/init.sh"
    "${REPO_ROOT}/downstream/script/base/upgrade.sh"
    "${REPO_ROOT}/downstream/config/shell/bashrc"
    "${REPO_ROOT}/downstream/config/shell/terminator/config"
    "${REPO_ROOT}/downstream/config/shell/tmux/tmux.conf"
    "${REPO_ROOT}/.github/"
  )
  local _exclude_path
  _exclude_path="$(IFS=,; printf '%s' "${_excludes[*]}")"

  local -a _targets=()
  if [[ -z "${_shard_spec}" ]]; then
    echo "--- Running Tests with Kcov Coverage (full suite) ---"
    _targets=("${REPO_ROOT}/test/bats/unit/" "${REPO_ROOT}/test/bats/integration/")
  else
    # _shard_unit_files _die's on a malformed / empty shard spec.
    local _files
    _files="$(_shard_unit_files "${_shard_spec}")"
    local _total="${_shard_spec#*/}"
    local _shard="${_shard_spec%/*}"
    echo "--- Running Tests with Kcov Coverage (shard ${_shard_spec}) ---"
    # Word-split intentional: one shard file per target entry.
    # shellcheck disable=SC2206
    _targets=(${_files})
    if (( _shard == _total )); then
      echo "  + integration suite (last shard)"
      _targets+=("${REPO_ROOT}/test/bats/integration/")
    fi
    # Word-split intentional: print one line per shard target.
    printf '  cov-shard:%s\n' "${_targets[@]}"
  fi

  kcov \
    --include-path="${REPO_ROOT}" \
    --exclude-path="${_exclude_path}" \
    "${REPO_ROOT}/coverage" \
    bats "${_targets[@]}"
}

# ── Behavioural runtime-test specs ────────────────────────────────────
#
# Opt-in path. Requires the ci-behavioural compose service (mounts host
# /var/run/docker.sock + sets MOUNT_DOCKER_SOCK=1). Drives
# `docker buildx build --target runtime-test` against synthesized
# fixtures so the runtime smoke gate is actually exercised end-to-end,
# not just static-grep asserted.

readonly _BEHAVIOURAL_BUILDER="template-behavioural"

_behavioural_setup() {
  [[ -S /var/run/docker.sock ]] \
    || _die ci_no_docker_socket "behavioural mode requires /var/run/docker.sock; run via 'just test-behavioural' (ci-behavioural service)."
  command -v docker >/dev/null 2>&1 \
    || _die ci_no_docker_cli "behavioural mode requires docker CLI in the test-tools image (test-tools < v0.23.2 lacks it)."

  # Dedicated buildx builder isolates the cache from the host's default
  # context, so prune at the end only touches our cache (not the user's
  # other docker work). `--use` switches active builder for this process.
  if ! docker buildx inspect "${_BEHAVIOURAL_BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${_BEHAVIOURAL_BUILDER}" --driver docker-container --bootstrap >/dev/null
  fi
  docker buildx use "${_BEHAVIOURAL_BUILDER}"
}

_behavioural_teardown() {
  # Prune only the dedicated builder's cache. Leaves the host's default
  # context untouched so the user's other docker workflows aren't
  # disturbed. `|| true` because builder may already be gone if
  # something earlier aborted partway through.
  docker buildx prune --builder "${_BEHAVIOURAL_BUILDER}" -af >/dev/null 2>&1 || true
}

_run_behavioural() {
  _behavioural_setup
  trap _behavioural_teardown EXIT

  local -a _bats_args=()
  local _jobs
  _jobs="$(nproc 2>/dev/null || echo 1)"
  if command -v parallel >/dev/null 2>&1; then
    _bats_args=(--jobs "${_jobs}")
  fi

  bats "${_bats_args[@]}" "${REPO_ROOT}/test/bats/behavioural/"
}
