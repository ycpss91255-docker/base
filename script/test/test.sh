#!/usr/bin/env bash
# test.sh - Run CI pipeline (ShellCheck + Bats [+ Kcov])
#
# Usage:
#   ./test.sh                   # Run ShellCheck + Hadolint + Bats (fast dev loop)
#   ./test.sh --ci              # Run inside CI container (called by compose)
#   ./test.sh --lint            # Run all linters (ShellCheck + Hadolint) via
#                             # docker compose (the ci/test-tools image bakes in
#                             # hadolint). Narrow with --shellcheck / --hadolint
#                             # (ADR-00000011 #3 min->max)
#   ./test.sh --lint --shellcheck  # Only ShellCheck, via compose
#   ./test.sh --lint --hadolint    # Only Hadolint, via compose
#   ./test.sh --shellcheck-only # Run ShellCheck only, no compose, no bats deps
#                             # (used by self-test.yaml's dedicated shellcheck
#                             # job,; plain ubuntu-latest runner with
#                             # pre-installed shellcheck)
#   ./test.sh --hadolint-only   # Run Hadolint only inside the ci container
#                             # (single source of truth for the self-test.yaml
#                             # hadolint job;  ADR-00000011)
#   ./test.sh --bats-only       # Run Bats only inside compose (skip ShellCheck)
#                             # (used by self-test.yaml's bats jobs,)
#   ./test.sh --bats-unit-shard N/T  # Run unit shard N of T (skip ShellCheck +
#                                  # integration). Coverage-matrix slice
#                                  # primitive (greedy weight-balanced)
#   ./test.sh --bats-fragile         # Run ONLY the kcov-fragile unit specs in
#                                  # plain mode (the tests the coverage matrix
#                                  # skips). Used by the bats-fragile job in
#                                  # self-test.yaml
#   ./test.sh --bats-integration     # Run integration tests only (skip
#                                  # ShellCheck + unit). Used by the
#                                  # bats-integration job in self-test.yaml
#                                  #
#   ./test.sh --coverage        # Run ShellCheck + Bats + Kcov coverage
#                             # (full suite; local `just test coverage`)
#   ./test.sh --coverage-shard N/T  # Run kcov over coverage shard N of T
#                                  # (skip ShellCheck). Used by the coverage
#                                  # matrix in self-test.yaml. Codecov
#                                  # merges the per-shard uploads.
#   ./test.sh -h, --help        # Show this help
#
# Kcov instrumentation wraps every bats command and slows the suite
# 2-5x, so the default no longer runs it. Run `--coverage` (or
# `just test coverage`) when you need the HTML report before
# releasing.

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

# Disable the wrapper transcript for the whole self-test: specs that
# run a wrapper main would otherwise tee a log/ tree into the mounted
# checkout (FILE_PATH/REPO_ROOT resolve to /source). The env override wins
# over setup.conf; transcript_spec clears it to exercise the conf logic.
export WRAPPER_TRANSCRIPT=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../downstream/script/docker/lib/_lib.sh"

# Per-tool drivers. test.sh is the dispatcher (arg parsing, mode dispatch,
# CI-container setup); the per-tool execution lives in sourced driver
# libraries under drivers/. Each driver uses _log_* / _die from _lib.sh
# (sourced above) and references the ${REPO_ROOT} global defined here, so
# source order is: _lib.sh -> drivers. Adding a tool = a driver + a
# test/<tool>/ folder; the dispatcher is untouched (ADR-00000011).
# shellcheck source=script/test/drivers/shellcheck.sh
source "${SCRIPT_DIR}/drivers/shellcheck.sh"
# shellcheck source=script/test/drivers/hadolint.sh
source "${SCRIPT_DIR}/drivers/hadolint.sh"
# shellcheck source=script/test/drivers/bats.sh
source "${SCRIPT_DIR}/drivers/bats.sh"
# shellcheck source=script/test/drivers/issueref.sh
source "${SCRIPT_DIR}/drivers/issueref.sh"

# ── Help ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: ./test.sh [OPTIONS]

Run CI pipeline: ShellCheck + Bats [+ Kcov coverage].

Options:
  --ci                    Run directly inside CI container (called by
                          compose); honors $COVERAGE=1 to include kcov,
                          $COVERAGE_SHARD to kcov one shard of the matrix,
                          $BATS_ONLY=1 to skip the ShellCheck phase,
                          $BATS_UNIT_SHARD to run only one matrix shard,
                          $BATS_FRAGILE=1 to run only the kcov-fragile specs,
                          $BATS_INTEGRATION=1 to run integration only
  --lint                  All linters (ShellCheck + Hadolint) via docker
                          compose; the ci/test-tools image bakes in hadolint.
                          Narrow with --shellcheck / --hadolint (#650)
  --shellcheck            With --lint: run only ShellCheck (still via compose)
  --hadolint              With --lint: run only Hadolint (still via compose)
  --issueref              With --lint: run only the issue-ref comment lint
                          (no transient #NNN in code comments; ADR-00000013)
  --shellcheck-only       ShellCheck only, directly, no compose; relies on
                          shellcheck already being in PATH (e.g. plain
                          ubuntu-latest GHA runner). Used by
                          self-test.yaml's dedicated shellcheck job (#376)
  --hadolint-only         Hadolint only, directly inside the ci container
                          (hadolint baked into the test-tools image). Single
                          source of truth for self-test.yaml's hadolint job
                          (#650)
  --bats-only             Bats only inside compose (skip ShellCheck) (#376)
  --bats-unit-shard N/T   Run unit shard N of T (skip ShellCheck +
                          integration). Greedy weight-balanced partition;
                          the coverage matrix slice primitive (#377, #677)
  --bats-fragile          Run ONLY the kcov-fragile unit specs in plain mode
                          (skip ShellCheck + integration). These are the
                          tests the coverage matrix skips; the bats-fragile
                          job in self-test.yaml runs them so no unit test
                          goes unrun (#677)
  --bats-integration      Run integration tests only (skip ShellCheck +
                          unit). Used by the bats-integration job in
                          self-test.yaml (#377)
  --bats-path PATH        Run a single spec FILE or DIRECTORY (repo-root-
                          relative, e.g. test/bats/unit/ci_spec.bats) via the ci
                          container. Skips ShellCheck + kcov for a fast TDD
                          inner loop. test/bats/behavioural/ is rejected (needs
                          the ci-behavioural service); cannot combine with
                          --coverage (#523)
  --filter REGEX          Pass a bats -f name filter (within-file single-test
                          selection); usable with or without --bats-path.
                          Without a path it filters unit + integration (#523)
  --coverage              Run tests with Kcov coverage (slow; CI / release
                          check). Full suite (unit + integration). Local
                          `just test coverage`.
  --coverage-shard N/T    Run kcov over coverage shard N of T (skip
                          ShellCheck). Mirrors --bats-unit-shard's
                          round-robin slice; integration runs on the last
                          shard. Used by the coverage matrix in
                          self-test.yaml (#615). Codecov merges the
                          per-shard uploads into one project figure.
  -h, --help              Show this help

Default (no flag): ShellCheck + Hadolint + bats via docker compose, no
kcov. Kcov wraps every bats command and slows the suite 2-5x, so the
dev-loop default skips it.

Examples:
  ./test.sh                       # Fast: ShellCheck + Hadolint + Bats (no kcov)
  just test      # Same as above
  ./test.sh --coverage            # Full: ShellCheck + Hadolint + Bats + Kcov
  just test coverage  # Same as above
  just test lint      # All linters (ShellCheck + Hadolint)
  just test lint --shellcheck     # ShellCheck only
  just test lint --hadolint       # Hadolint only
  ./test.sh --shellcheck-only     # Direct shellcheck, no compose
  ./test.sh --hadolint-only       # Hadolint only (inside ci container)
  ./test.sh --bats-only           # Compose-bats only, skip ShellCheck
  ./test.sh --bats-unit-shard 1/2 # Compose-bats unit shard 1 of 2
  ./test.sh --bats-fragile        # Compose-bats kcov-fragile specs (plain)
  ./test.sh --bats-integration    # Compose-bats integration only
  ./test.sh --bats-path test/bats/unit/ci_spec.bats          # one spec, fast
  ./test.sh --bats-path test/bats/unit/                       # one directory
  ./test.sh --bats-path test/bats/unit/ci_spec.bats --filter 'shard'  # + name filter
  ./test.sh --filter 'cap_add'    # filter across unit + integration
EOF
  exit 0
}

# ── CI container setup ───────────────────────────────────────────────────────

_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }

# ── Fix coverage permissions ─────────────────────────────────────────────────

_fix_permissions() {
  local uid="${HOST_UID:-}"
  local gid="${HOST_GID:-}"
  if [[ -n "${uid}" && -n "${gid}" && -d "${REPO_ROOT}/coverage" ]]; then
    chown -R "${uid}:${gid}" "${REPO_ROOT}/coverage"
  fi
}

# ── Docker compose wrapper ───────────────────────────────────────────────────

_run_via_compose() {
  # Service is the first arg so the caller picks the runner image:
  #   `ci`       — alpine test-tools (bats/shellcheck/hadolint baked in,
  #                no apt-install on each run; fast dev loop)
  #   `coverage` — the SAME alpine test-tools image as `ci`, with kcov
  #                source-built in. No apt-install, no APT_MIRROR_DEBIAN;
  #                the only difference is COVERAGE=1.
  #
  # BATS_ONLY is forwarded so the inner `--ci` dispatch can skip
  # _run_shellcheck when the dedicated GHA shellcheck job is
  # covering it in parallel. Default 0 keeps the local `just test`
  # path unchanged (full shellcheck + bats).
  #
  # BATS_UNIT_SHARD / BATS_FRAGILE / BATS_INTEGRATION route the
  # coverage-slice / bats-fragile / bats-integration GHA jobs to the right
  # subset inside the container; empty / 0 keep the local `just test` path
  # unchanged (full unit + integration).
  #
  # LINT_ONLY / LINT_TOOL route `just test lint [--shellcheck |
  # --hadolint]` to the lint phase only (skip bats) inside the container:
  # LINT_ONLY=1 runs the linters and returns; LINT_TOOL narrows to one
  # ('shellcheck' | 'hadolint'), empty = all. hadolint has no host binary,
  # so even shellcheck-via-lint runs in-container for behaviour parity.
  local _service="${1:-ci}"
  local _coverage="${2:-0}"
  docker compose -f "${REPO_ROOT}/compose.yaml" run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e COVERAGE="${_coverage}" \
    -e COVERAGE_SHARD="${COVERAGE_SHARD:-}" \
    -e BATS_ONLY="${BATS_ONLY:-0}" \
    -e BATS_UNIT_SHARD="${BATS_UNIT_SHARD:-}" \
    -e BATS_FRAGILE="${BATS_FRAGILE:-0}" \
    -e BATS_INTEGRATION="${BATS_INTEGRATION:-0}" \
    -e BATS_FILE="${BATS_FILE:-}" \
    -e BATS_FILTER="${BATS_FILTER:-}" \
    -e LINT_ONLY="${LINT_ONLY:-0}" \
    -e LINT_TOOL="${LINT_TOOL:-}" \
    "${_service}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode="compose"
  local behavioural=0
  local bats_only=0
  local shellcheck_only=0
  local hadolint_only=0
  local lint=0
  local lint_tool=""
  local bats_unit_shard=""
  local bats_fragile=0
  local bats_integration=0
  local bats_path=""
  local bats_filter=""
  local coverage_shard=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage ;;
      --ci) mode="ci"; shift ;;
      --lint) lint=1; shift ;;
      --shellcheck) lint_tool="shellcheck"; shift ;;
      --hadolint) lint_tool="hadolint"; shift ;;
      --issueref) lint_tool="issueref"; shift ;;
      --shellcheck-only) shellcheck_only=1; shift ;;
      --hadolint-only) hadolint_only=1; shift ;;
      --bats-only) bats_only=1; shift ;;
      --bats-unit-shard) bats_unit_shard="${2:?--bats-unit-shard expects <n>/<total>}"; shift 2 ;;
      --bats-fragile) bats_fragile=1; shift ;;
      --bats-integration) bats_integration=1; shift ;;
      --bats-path) bats_path="${2:?--bats-path expects <path>}"; shift 2 ;;
      --filter) bats_filter="${2:?--filter expects <regex>}"; shift 2 ;;
      --coverage) mode="coverage"; shift ;;
      --coverage-shard) mode="coverage"; coverage_shard="${2:?--coverage-shard expects <n>/<total>}"; shift 2 ;;
      --behavioural) behavioural=1; shift ;;
      *) _die ci_unknown_option "Unknown option: $1" ;;
    esac
  done

  # --shellcheck / --hadolint are narrowing flags for --lint; reject them
  # standalone so a typo (`./test.sh --hadolint`, meaning --hadolint-only)
  # fails loudly instead of silently no-op'ing.
  if [[ -n "${lint_tool}" && "${lint}" != "1" ]]; then
    _die ci_lint_tool_without_lint \
      "--${lint_tool} narrows --lint; use './test.sh --lint --${lint_tool}' or '--${lint_tool}-only'."
  fi

  # --shellcheck-only short-circuits before any mode dispatch. It runs
  # the lint phase directly on the host (no compose, no apt-install).
  # Caller is responsible for having the linter binary in PATH — the
  # dedicated self-test.yaml shellcheck job uses plain
  # ubuntu-latest, which ships it pre-installed.
  if [[ "${shellcheck_only}" == "1" ]]; then
    _run_shellcheck
    return 0
  fi

  # --hadolint-only short-circuits and runs the linter directly here (no
  # compose), so hadolint must already be in PATH. It is the in-container
  # primitive: callers run it from INSIDE the ci/test-tools image (which
  # bakes hadolint in) -- the self-test.yaml hadolint job invokes it via
  # `_run_via_compose ci`. _run_hadolint _die's with a clear message if the
  # binary is missing (e.g. invoked on a bare host).
  if [[ "${hadolint_only}" == "1" ]]; then
    _run_hadolint
    return 0
  fi

  # `--lint` runs the linters through the ci/test-tools container (it bakes
  # in hadolint, absent on the host). LINT_ONLY=1 tells the in-container
  # `--ci` path to run only the lint phase; LINT_TOOL narrows to one linter
  # (empty = all). Even `--lint --shellcheck` runs in-container so its
  # behaviour matches bare `just test lint`; the dedicated GHA shellcheck
  # job uses the host-only `--shellcheck-only` path instead.
  if [[ "${lint}" == "1" ]]; then
    LINT_ONLY=1 LINT_TOOL="${lint_tool}" _run_via_compose ci 0
    return 0
  fi

  # Single-path / filtered inner loop. `--bats-path <file|dir>` and / or
  # `--filter <regex>` run a named subset via the `ci` container, skipping
  # ShellCheck (BATS_ONLY=1) and kcov so the TDD inner loop stays fast.
  # Validation runs on the host before dispatch; the in-container `--ci`
  # branch (BATS_FILE / BATS_FILTER) actually invokes bats.
  if [[ -n "${bats_path}" || -n "${bats_filter}" ]]; then
    if [[ "${mode}" == "coverage" ]]; then
      _die ci_bats_path_coverage \
        "--bats-path / --filter cannot combine with --coverage (single-path is the fast no-kcov loop; use --coverage alone for kcov)."
    fi
    if [[ -n "${bats_path}" ]]; then
      if [[ "${bats_path}" == test/bats/behavioural || "${bats_path}" == test/bats/behavioural/* ]]; then
        _die ci_bats_path_behavioural \
          "test/bats/behavioural/ needs the ci-behavioural service + docker.sock; run 'just test behavioural' (host test.sh cannot launch it)."
      fi
      [[ -e "${REPO_ROOT}/${bats_path}" ]] \
        || _die ci_bats_path_not_found \
          "No such spec file or directory: ${bats_path} (path is repo-root-relative, resolved as \${REPO_ROOT}/${bats_path})."
    fi
    BATS_ONLY=1 BATS_FILE="${bats_path}" BATS_FILTER="${bats_filter}" \
      _run_via_compose ci 0
    return 0
  fi

  case "${mode}" in
    ci)
      # Running inside container. Default path skips kcov for speed
      # (the dev loop is far more frequent than the coverage check).
      # Pass COVERAGE=1 via the outer `--coverage` flag to include it.
      # `--behavioural` swaps the bats invocation to drive
      # `docker buildx build` against runtime-test fixtures.
      # BATS_ONLY=1 (set by `--bats-only` outer flag, plumbed via
      # `_run_via_compose`) skips the ShellCheck phase — the dedicated
      # self-test.yaml shellcheck job covers it in parallel.
      # BATS_UNIT_SHARD / BATS_INTEGRATION route this dispatch
      # to a matrix-shard / integration-only subset; the dedicated GHA
      # bats-unit / bats-integration jobs set these via the outer
      # `--bats-unit-shard` / `--bats-integration` flags so the
      # in-container path matches the local dev path.
      if [[ "${behavioural}" == "1" ]]; then
        _run_behavioural
        _fix_permissions
        return 0
      fi
      # LINT_ONLY: `just test lint [--shellcheck | --hadolint]`
      # routes here with LINT_ONLY=1; run the requested linter(s) and skip
      # bats entirely. LINT_TOOL empty = all linters (shellcheck +
      # hadolint), matching bare `just test lint`. The test-tools image
      # already ships every tool (bats / shellcheck / hadolint / kcov), so
      # nothing is installed at runtime on any path.
      if [[ "${LINT_ONLY:-0}" == "1" ]]; then
        case "${LINT_TOOL:-}" in
          shellcheck) _run_shellcheck ;;
          hadolint)   _run_hadolint ;;
          issueref)   _run_issueref ;;
          "")         _run_shellcheck; _run_hadolint; _run_issueref ;;
          *)          _die ci_unknown_lint_tool "Unknown LINT_TOOL '${LINT_TOOL}' (expected shellcheck | hadolint | issueref | empty)." ;;
        esac
        return 0
      fi
      # Full `just test` lint phase: shellcheck THEN hadolint, so a
      # Dockerfile regression fails `just test` locally the same way it
      # fails the CI hadolint job (local==CI). BATS_ONLY=1 (dedicated
      # GHA shellcheck/hadolint jobs cover lint in parallel) skips both.
      # COVERAGE=1 also skips lint: lint is a separate concern measured by
      # the dedicated lint jobs, not the coverage matrix — running it once
      # per coverage shard would be wasted work (the coverage shards now
      # share the test-tools image, which DOES ship both linters, so this
      # is a deliberate skip, not a missing-binary workaround).
      if [[ "${BATS_ONLY:-0}" != "1" && "${COVERAGE:-0}" != "1" ]]; then
        _run_shellcheck
        _run_hadolint
        _run_issueref
      fi
      if [[ "${COVERAGE:-0}" == "1" ]]; then
        # COVERAGE_SHARD narrows kcov to one matrix slice; empty =
        # full suite (local `just test coverage` / release path).
        _run_coverage "${COVERAGE_SHARD:-}"
        _fix_permissions
        echo "Coverage report: ${REPO_ROOT}/coverage/index.html"
      elif [[ -n "${BATS_FILE:-}" || -n "${BATS_FILTER:-}" ]]; then
        _run_bats_path
      elif [[ -n "${BATS_UNIT_SHARD:-}" ]]; then
        _run_unit_shard "${BATS_UNIT_SHARD}"
      elif [[ "${BATS_FRAGILE:-0}" == "1" ]]; then
        _run_bats_fragile
      elif [[ "${BATS_INTEGRATION:-0}" == "1" ]]; then
        _run_integration_tests
      else
        _run_tests
      fi
      ;;
    coverage)
      # Kcov via the kcov/kcov-based `coverage` service. Bare --coverage
      # runs the full suite; --coverage-shard N/T (coverage_shard set)
      # plumbs COVERAGE_SHARD into the container so _run_coverage kcov's
      # only this matrix slice. The self-test.yaml coverage matrix sets
      # the latter; local `just test coverage` uses the former.
      if [[ -n "${coverage_shard}" ]]; then
        COVERAGE_SHARD="${coverage_shard}" _run_via_compose coverage 1
      else
        _run_via_compose coverage 1
      fi
      ;;
    compose)
      # Default: fast CI (shellcheck + bats, no kcov) via the alpine
      # test-tools-based `ci` service. Flag-driven plumbing of the
      # relevant env vars selects the inner branch:
      #   --bats-only          -> BATS_ONLY=1 (skip _run_shellcheck)
      #   --bats-unit-shard X  -> BATS_ONLY=1 + BATS_UNIT_SHARD=X
      #   --bats-integration   -> BATS_ONLY=1 + BATS_INTEGRATION=1
      # Local `just test` (no flags) keeps the full pipeline.
      if [[ -n "${bats_unit_shard}" ]]; then
        BATS_ONLY=1 BATS_UNIT_SHARD="${bats_unit_shard}" _run_via_compose ci 0
      elif [[ "${bats_fragile}" == "1" ]]; then
        BATS_ONLY=1 BATS_FRAGILE=1 _run_via_compose ci 0
      elif [[ "${bats_integration}" == "1" ]]; then
        BATS_ONLY=1 BATS_INTEGRATION=1 _run_via_compose ci 0
      elif [[ "${bats_only}" == "1" ]]; then
        BATS_ONLY=1 _run_via_compose ci 0
      else
        _run_via_compose ci 0
      fi
      ;;
  esac
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
