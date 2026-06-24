#!/usr/bin/env bash
# test.sh - Run CI pipeline (ShellCheck + Bats [+ Kcov])
#
# Usage:
#   ./test.sh                   # Run ShellCheck + Bats (fast dev loop)
#   ./test.sh --ci              # Run inside CI container (called by compose)
#   ./test.sh --lint-only       # Run ShellCheck only (via docker compose)
#   ./test.sh --shellcheck-only # Run ShellCheck only, no compose, no bats deps
#                             # (used by self-test.yaml's dedicated shellcheck
#                             # job, #376; plain ubuntu-latest runner with
#                             # pre-installed shellcheck)
#   ./test.sh --bats-only       # Run Bats only inside compose (skip ShellCheck)
#                             # (used by self-test.yaml's bats jobs, #376/#377)
#   ./test.sh --bats-unit-shard N/T  # Run unit shard N of T (skip ShellCheck +
#                                  # integration). Used by the bats-unit
#                                  # matrix in self-test.yaml (#377)
#   ./test.sh --bats-integration     # Run integration tests only (skip
#                                  # ShellCheck + unit). Used by the
#                                  # bats-integration job in self-test.yaml
#                                  # (#377)
#   ./test.sh --coverage        # Run ShellCheck + Bats + Kcov coverage
#                             # (push-to-main only via self-test.yaml's
#                             # coverage job, #377)
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

# Disable the wrapper transcript for the whole self-test (#622): specs that
# run a wrapper main() would otherwise tee a log/ tree into the mounted
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
# test/<tool>/ folder; the dispatcher is untouched (#650, ADR-00000011).
# shellcheck source=script/test/drivers/shellcheck.sh
source "${SCRIPT_DIR}/drivers/shellcheck.sh"
# shellcheck source=script/test/drivers/bats.sh
source "${SCRIPT_DIR}/drivers/bats.sh"

# ── Help ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: ./test.sh [OPTIONS]

Run CI pipeline: ShellCheck + Bats [+ Kcov coverage].

Options:
  --ci                    Run directly inside CI container (called by
                          compose); honors $COVERAGE=1 to include kcov,
                          $BATS_ONLY=1 to skip the ShellCheck phase,
                          $BATS_UNIT_SHARD to run only one matrix shard,
                          $BATS_INTEGRATION=1 to run integration only
  --lint-only             ShellCheck only (via docker compose)
  --shellcheck-only       ShellCheck only, directly, no compose; relies on
                          shellcheck already being in PATH (e.g. plain
                          ubuntu-latest GHA runner). Used by
                          self-test.yaml's dedicated shellcheck job (#376)
  --bats-only             Bats only inside compose (skip ShellCheck) (#376)
  --bats-unit-shard N/T   Run unit shard N of T (skip ShellCheck +
                          integration). Used by the bats-unit matrix in
                          self-test.yaml (#377)
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
                          check). Used by self-test.yaml's coverage job
                          (push-to-main only, #377)
  -h, --help              Show this help

Default (no flag): ShellCheck + bats via docker compose, no kcov.
Kcov wraps every bats command and slows the suite 2-5x, so the
dev-loop default skips it.

Examples:
  ./test.sh                       # Fast: ShellCheck + Bats (no kcov)
  just test      # Same as above
  ./test.sh --coverage            # Full: ShellCheck + Bats + Kcov
  just test coverage  # Same as above
  just test lint      # ShellCheck only
  ./test.sh --shellcheck-only     # Direct shellcheck, no compose
  ./test.sh --bats-only           # Compose-bats only, skip ShellCheck
  ./test.sh --bats-unit-shard 1/2 # Compose-bats unit shard 1 of 2
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

_install_deps() {
  command -v bats >/dev/null 2>&1 && return 0

  # Rewrite sources.list to use APT_MIRROR_DEBIAN before apt-get update.
  # Default deb.debian.org is unreachable on some networks (regional outage,
  # ISP routing, captive portals) while the configured mirror responds. The
  # env var is plumbed through by compose.yaml; only rewrite when it actually
  # differs from the default so unaffected networks keep using the upstream.
  local _mirror="${APT_MIRROR_DEBIAN:-deb.debian.org}"
  if [[ "${_mirror}" != "deb.debian.org" ]]; then
    [[ -f /etc/apt/sources.list ]] \
      && sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list
    if compgen -G '/etc/apt/sources.list.d/*.list' >/dev/null; then
      sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list.d/*.list
    fi
    if compgen -G '/etc/apt/sources.list.d/*.sources' >/dev/null; then
      sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list.d/*.sources
    fi
  fi

  apt-get update -qq \
    || _die ci_apt_update_failed "apt-get update failed. Check network / apt mirror reachability."

  # The kcov/coverage image is debian-based and ships none of the bats
  # toolchain, so install it here; `parallel` shards the bats run. The
  # downstream-justfile integration test (`just upgrade-check`)
  # self-skips when `just` is absent -- it runs against the test-tools
  # image (which bundles just), not this kcov image -- so no make/just
  # runner is needed in this debian environment.
  apt-get install -y --no-install-recommends \
      bats bats-support bats-assert \
      shellcheck git ca-certificates \
      parallel \
    || _die ci_apt_install_failed "apt-get install failed for bats/shellcheck deps."

  # bats-mock is distro-packaged on newer distros but missing on bookworm,
  # so we always pin to upstream v1.2.5 for reproducibility.
  git clone --depth 1 -b v1.2.5 \
      https://github.com/jasonkarns/bats-mock /usr/lib/bats/bats-mock \
    || _die ci_bats_mock_clone_failed "git clone bats-mock failed. Check network / GitHub access."
}

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
  #   `coverage` — kcov/kcov (debian; needs apt-install via _install_deps,
  #                opt-in APT_MIRROR_DEBIAN rewrite for unreachable mirrors)
  #
  # BATS_ONLY is forwarded so the inner `--ci` dispatch can skip
  # _run_shellcheck when the dedicated GHA shellcheck job (#376) is
  # covering it in parallel. Default 0 keeps the local `just test`
  # path unchanged (full shellcheck + bats).
  #
  # BATS_UNIT_SHARD / BATS_INTEGRATION (#377) route the matrix
  # bats-unit + bats-integration GHA jobs to the right subset inside
  # the container; empty / 0 keep the local `just test` path
  # unchanged (full unit + integration).
  local _service="${1:-ci}"
  local _coverage="${2:-0}"
  docker compose -f "${REPO_ROOT}/compose.yaml" run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e COVERAGE="${_coverage}" \
    -e BATS_ONLY="${BATS_ONLY:-0}" \
    -e BATS_UNIT_SHARD="${BATS_UNIT_SHARD:-}" \
    -e BATS_INTEGRATION="${BATS_INTEGRATION:-0}" \
    -e BATS_FILE="${BATS_FILE:-}" \
    -e BATS_FILTER="${BATS_FILTER:-}" \
    "${_service}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode="compose"
  local behavioural=0
  local bats_only=0
  local shellcheck_only=0
  local bats_unit_shard=""
  local bats_integration=0
  local bats_path=""
  local bats_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage ;;
      --ci) mode="ci"; shift ;;
      --lint-only) mode="lint"; shift ;;
      --shellcheck-only) shellcheck_only=1; shift ;;
      --bats-only) bats_only=1; shift ;;
      --bats-unit-shard) bats_unit_shard="${2:?--bats-unit-shard expects <n>/<total>}"; shift 2 ;;
      --bats-integration) bats_integration=1; shift ;;
      --bats-path) bats_path="${2:?--bats-path expects <path>}"; shift 2 ;;
      --filter) bats_filter="${2:?--filter expects <regex>}"; shift 2 ;;
      --coverage) mode="coverage"; shift ;;
      --behavioural) behavioural=1; shift ;;
      *) _die ci_unknown_option "Unknown option: $1" ;;
    esac
  done

  # --shellcheck-only short-circuits before any mode dispatch. It runs
  # the lint phase directly on the host (no compose, no apt-install).
  # Caller is responsible for having the linter binary in PATH — the
  # dedicated self-test.yaml shellcheck job (#376) uses plain
  # ubuntu-latest, which ships it pre-installed.
  if [[ "${shellcheck_only}" == "1" ]]; then
    _run_shellcheck
    return 0
  fi

  # Single-path / filtered inner loop (#523). `--bats-path <file|dir>` and / or
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
      # `docker buildx build` against runtime-test fixtures (#249).
      # BATS_ONLY=1 (set by `--bats-only` outer flag, plumbed via
      # `_run_via_compose`) skips the ShellCheck phase — the dedicated
      # self-test.yaml shellcheck job covers it in parallel (#376).
      # BATS_UNIT_SHARD / BATS_INTEGRATION (#377) route this dispatch
      # to a matrix-shard / integration-only subset; the dedicated GHA
      # bats-unit / bats-integration jobs set these via the outer
      # `--bats-unit-shard` / `--bats-integration` flags so the
      # in-container path matches the local dev path.
      if [[ "${behavioural}" == "1" ]]; then
        _install_deps
        _run_behavioural
        _fix_permissions
        return 0
      fi
      _install_deps
      if [[ "${BATS_ONLY:-0}" != "1" ]]; then
        _run_shellcheck
      fi
      if [[ "${COVERAGE:-0}" == "1" ]]; then
        _run_coverage
        _fix_permissions
        echo "Coverage report: ${REPO_ROOT}/coverage/index.html"
      elif [[ -n "${BATS_FILE:-}" || -n "${BATS_FILTER:-}" ]]; then
        _run_bats_path
      elif [[ -n "${BATS_UNIT_SHARD:-}" ]]; then
        _run_unit_shard "${BATS_UNIT_SHARD}"
      elif [[ "${BATS_INTEGRATION:-0}" == "1" ]]; then
        _run_integration_tests
      else
        _run_tests
      fi
      ;;
    lint)
      # ShellCheck only — requires shellcheck installed locally
      _run_shellcheck
      ;;
    coverage)
      # Full CI + kcov via the kcov/kcov-based `coverage` service.
      _run_via_compose coverage 1
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
