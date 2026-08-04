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
#   ./test.sh --<tool>-only     # Run ONE lint of the phase on the host, no
#                             # compose: --shellcheck-only / --issueref-only
#                             # / --adr-numbering-only /
#                             # --stale-setup-conf-only / --readme-sync-only
#                             # / --doc-counts-only. These are what the
#                             # self-test.yaml lint jobs call -- no CI job
#                             # runs the lint phase itself
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
source "${SCRIPT_DIR}/../../dist/script/docker/lib/_lib.sh"

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
# shellcheck source=script/test/drivers/adr_numbering.sh
source "${SCRIPT_DIR}/drivers/adr_numbering.sh"
# shellcheck source=script/test/drivers/stale_setup_conf.sh
source "${SCRIPT_DIR}/drivers/stale_setup_conf.sh"
# shellcheck source=script/test/drivers/readme_sync.sh
source "${SCRIPT_DIR}/drivers/readme_sync.sh"
# shellcheck source=script/test/drivers/doc_counts.sh
source "${SCRIPT_DIR}/drivers/doc_counts.sh"

# ── The lint phase's tool table ──────────────────────────────────────────────

# Every tool the lint phase runs, in phase order. THE list: three callers
# used to repeat it -- the full phase, the in-container LINT_TOOL
# narrowing, and the host-direct primitives -- so a newly added lint could
# be wired into one and silently missed by the others. They all dispatch
# through _run_lint_tool / _run_all_lint_tools below now.
#
# It is also the CI-coverage manifest: self_test_yaml_spec asserts that
# every entry here is named by a job in .github/workflows/self-test.yaml
# (a host-direct `--<tool>-only` primitive, the in-container hadolint job,
# or a `lint-static` matrix entry). Add a lint to this table without
# giving it a CI job and that guard fails -- which is what stops the next
# lint from landing local-only, the way these four did.
readonly _LINT_TOOLS=(
  shellcheck
  hadolint
  issueref
  adr-numbering
  stale-setup-conf
  readme-sync
  doc-counts
)

# Every tool but hadolint is runnable host-direct (`--<tool>-only`): the
# drivers are pure bash over the checkout, and shellcheck's binary ships
# on ubuntu-latest. hadolint's binary exists only in the alpine
# test-tools image, so its CI job runs the driver inside that image
# (`--lint --hadolint`) instead of host-direct.

# Run one lint tool by name. The single dispatch point; unknown names die
# loudly rather than no-op'ing, so a typo in a CI job or a stale
# LINT_TOOL export cannot silently skip a gate.
_run_lint_tool() {
  case "${1:-}" in
    shellcheck)       _run_shellcheck ;;
    hadolint)         _run_hadolint ;;
    issueref)         _run_issueref ;;
    adr-numbering)    _run_adr_numbering ;;
    stale-setup-conf) _run_stale_setup_conf ;;
    readme-sync)      _run_readme_sync ;;
    doc-counts)       _run_doc_counts ;;
    *) _die ci_unknown_lint_tool \
         "Unknown LINT_TOOL '${1:-}' (expected $(printf '%s | ' "${_LINT_TOOLS[@]}")empty)." ;;
  esac
}

# Run the whole lint phase, in table order.
_run_all_lint_tools() {
  local _tool
  for _tool in "${_LINT_TOOLS[@]}"; do
    _run_lint_tool "${_tool}"
  done
}

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
  --adr-numbering         With --lint: run only the ADR-numbering lint
                          (doc/adr/ duplicate-free + well-formed; gaps
                          warned, not failed)
  --stale-setup-conf      With --lint: run only the stale setup.conf path
                          lint (no legacy config/docker/setup.conf in
                          dist/**/*.sh; the override lives at the repo-root
                          .setup.conf dotfile)
  --readme-sync           With --lint: run only the localized README sync
                          lint (each doc/readme/README.*.md section records
                          the hash of the README.md section it was
                          translated against; re-stamp with
                          'just test sync-readme')
  --doc-counts            With --lint: run only the doc/test count drift
                          gate (doc/test/*.md figures are generated from
                          the specs; regenerate with 'just test sync-docs').
                          Same gate as 'just test sync-docs-check' and as
                          the advisory harness PostToolUse hook -- one rule,
                          three entry points, this one being the blocking
                          one
  --<tool>-only           Run ONE lint from the phase directly on this
                          host: no compose, no test-tools image. These are
                          the CI join for the lint phase -- no CI job runs
                          the phase itself (the lint jobs narrow to one
                          tool, and every bats / coverage job sets
                          BATS_ONLY=1 / COVERAGE=1, which skip it), so
                          self-test.yaml calls one of these per job /
                          matrix entry, running the same driver the local
                          phase runs. Available:
                            --shellcheck-only        (needs shellcheck in
                                                     PATH; ubuntu-latest
                                                     ships it)
                            --issueref-only          pure bash
                            --adr-numbering-only     pure bash
                            --stale-setup-conf-only  pure bash
                            --readme-sync-only       pure bash
                            --doc-counts-only        pure bash + diff
                          (no --hadolint-only equivalent: hadolint exists
                          only in the test-tools image; see below)
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
                          inner loop. test/bats/system/ is rejected (needs
                          the ci-system service); cannot combine with
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
  just test lint --readme-sync    # Localized README sync lint only
  just test lint --doc-counts     # doc/test count drift gate only
  ./test.sh --shellcheck-only     # Direct shellcheck, no compose
  ./test.sh --doc-counts-only     # Direct doc/test count drift gate, no compose
  ./test.sh --readme-sync-only    # Direct localized README sync lint, no compose
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
  local system=0
  local bats_only=0
  local hadolint_only=0
  local lint=0
  local lint_tool=""
  # The `--<tool>-only` host-direct primitives all set this one variable:
  # they are the same operation (run ONE lint driver on this host, no
  # compose) parameterised by tool, so they share one short-circuit rather
  # than one boolean each.
  local host_lint=""
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
      --adr-numbering) lint_tool="adr-numbering"; shift ;;
      --stale-setup-conf) lint_tool="stale-setup-conf"; shift ;;
      --readme-sync) lint_tool="readme-sync"; shift ;;
      --doc-counts) lint_tool="doc-counts"; shift ;;
      --shellcheck-only) host_lint="shellcheck"; shift ;;
      --issueref-only) host_lint="issueref"; shift ;;
      --adr-numbering-only) host_lint="adr-numbering"; shift ;;
      --stale-setup-conf-only) host_lint="stale-setup-conf"; shift ;;
      --readme-sync-only) host_lint="readme-sync"; shift ;;
      --doc-counts-only) host_lint="doc-counts"; shift ;;
      --hadolint-only) hadolint_only=1; shift ;;
      --bats-only) bats_only=1; shift ;;
      --bats-unit-shard) bats_unit_shard="${2:?--bats-unit-shard expects <n>/<total>}"; shift 2 ;;
      --bats-fragile) bats_fragile=1; shift ;;
      --bats-integration) bats_integration=1; shift ;;
      --bats-path) bats_path="${2:?--bats-path expects <path>}"; shift 2 ;;
      --filter) bats_filter="${2:?--filter expects <regex>}"; shift 2 ;;
      --coverage) mode="coverage"; shift ;;
      --coverage-shard) mode="coverage"; coverage_shard="${2:?--coverage-shard expects <n>/<total>}"; shift 2 ;;
      --system) system=1; shift ;;
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

  # The host-direct lint primitives (`--shellcheck-only`,
  # `--issueref-only`, `--adr-numbering-only`,
  # `--stale-setup-conf-only`, `--readme-sync-only`,
  # `--doc-counts-only`) short-circuit before any mode dispatch and run
  # ONE driver right here: no compose, no test-tools image, no
  # apt-install. This is the CI join for the lint phase -- a plain
  # ubuntu-latest runner calls one of these per lint-static matrix entry,
  # running the SAME driver the local phase runs, so the local gate and
  # the CI gate cannot drift apart. Every tool but shellcheck is pure
  # bash over the checkout; shellcheck relies on the binary ubuntu-latest
  # ships pre-installed. hadolint is deliberately absent: its binary
  # exists only in the test-tools image, so its CI job uses
  # `--lint --hadolint` inside that image instead.
  if [[ -n "${host_lint}" ]]; then
    _run_lint_tool "${host_lint}"
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
      if [[ "${bats_path}" == test/bats/system || "${bats_path}" == test/bats/system/* ]]; then
        _die ci_bats_path_system \
          "test/bats/system/ needs the ci-system service + docker.sock; run 'just test system' (host test.sh cannot launch it)."
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
      # `--system` swaps the bats invocation to drive
      # `docker buildx build` against runtime-test fixtures.
      # BATS_ONLY=1 (set by `--bats-only` outer flag, plumbed via
      # `_run_via_compose`) skips the ShellCheck phase — the dedicated
      # self-test.yaml shellcheck job covers it in parallel.
      # BATS_UNIT_SHARD / BATS_INTEGRATION route this dispatch
      # to a matrix-shard / integration-only subset; the dedicated GHA
      # bats-unit / bats-integration jobs set these via the outer
      # `--bats-unit-shard` / `--bats-integration` flags so the
      # in-container path matches the local dev path.
      if [[ "${system}" == "1" ]]; then
        _run_system
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
        if [[ -z "${LINT_TOOL:-}" ]]; then
          _run_all_lint_tools
        else
          _run_lint_tool "${LINT_TOOL}"
        fi
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
        # Every tool in _LINT_TOOLS, in table order. Membership of that
        # table is what puts a lint in the local gate; it does NOT put it
        # in CI, because no CI job runs this phase (the lint jobs narrow
        # to one tool, and every bats / coverage job sets BATS_ONLY=1 /
        # COVERAGE=1, which land in the branch this guard excludes). The
        # CI join is a job in self-test.yaml calling the tool's
        # host-direct primitive; the completeness guard in
        # self_test_yaml_spec is what makes that mandatory rather than
        # remembered.
        _run_all_lint_tools
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
