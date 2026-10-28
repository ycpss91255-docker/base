#!/usr/bin/env bash
#
# pre_pr_mirror.sh -- run, on this machine, every job self-test.yaml's
# `ci-rollup` needs, in the mode CI runs it, for the diff a PR would carry.
#
# A pre-PR stamp is only worth what it ran. The mirror used to live outside
# this repo, run the bats suite plain while CI's primary unit gate is the
# kcov `coverage` matrix, and skip `system` and `acceptance` outright -- so
# a green stamp said nothing about the jobs most likely to go red (base#1409).
# It lives here now, next to the workflow it mirrors, and
# test/bats/unit/pre_pr_mirror_parity_spec.bats holds it to that workflow:
# every `ci-rollup` need is attested or excluded with a reason, only the
# jobs no local machine can reproduce may be excluded, and an attested job
# runs locally in the same mode (plain vs kcov) CI runs it.
#
# Usage:
#   ./script/ci/pre_pr_mirror.sh [--base <ref>]
#       Run the plan for the diff <ref>...HEAD (default origin/main), in
#       order, stopping at the first red command. Exit 0 only when every
#       planned command was green; 1 on a red command; 3 when a planned
#       command was printed as NOT RUN (an amd64 leg on a daemon that is not
#       amd64, see below) and nothing was red.
#   ./script/ci/pre_pr_mirror.sh --table
#       Print the attested / excluded table, one TAB-separated line per
#       required job:
#         attested<TAB><job><TAB><the local command run for it>
#         excluded<TAB><job>[/<leg>]<TAB><reason>
#   ./script/ci/pre_pr_mirror.sh --plan
#       Read changed paths (one per line) on stdin and print the commands
#       the mirror would run for that diff, one per line.
#   ./script/ci/pre_pr_mirror.sh --actionlint
#       Run actionlint as the workflow's actionlint job does: the same
#       image pin and the same `-ignore` suppressions, both read out of the
#       workflow so a bump there cannot leave this behind.
#   ./script/ci/pre_pr_mirror.sh --coverage-shards
#       Print the coverage matrix CI fans out over, one `<n>/<total>` per
#       line: compute-shards' own rule applied to the repo's CI_SHARDS
#       variable (the CI_SHARDS environment variable, when set, stands in
#       for it).
#   ./script/ci/pre_pr_mirror.sh --coverage-matrix
#       Run every shard of that matrix the way the coverage job runs one --
#       `./script/test/test.sh --coverage-shard <n>/<total>` with the
#       workflow's COVERAGE_JOBS -- and keep each shard's coverage/ tree as
#       coverage-shards/<n>/, the layout coverage-gate downloads the shard
#       artifacts into.
#
# What the plan runs, and why each gate is the one it is:
#
#   always            actionlint, and `just test` -- every linter of the
#                     _LINT_TOOLS table, then the whole bats suite plain.
#                     The lint jobs and bats-fragile / bats-integration run
#                     subsets of exactly that, plain, in CI. Run on every
#                     diff, because a superset costs a minute and a
#                     classification this mirror got wrong would cost a PR.
#   code changed      `--coverage-matrix` -- every shard of CI's coverage
#                     matrix, each run as the coverage job runs it: the same
#                     shard count, the same `--coverage-shard <n>/<total>`
#                     command and the same COVERAGE_JOBS kcov slices -- then
#                     coverage-gate's three steps over the shard trees: the
#                     floor (coverage_gate.sh --run-dirs, the command CI
#                     runs over its downloaded shard directories), the
#                     timings merge, and the shard-union check over the
#                     merged manifest. And `just test acceptance`, the amd64
#                     acceptance scaffold. "Code changed" is CI's own
#                     classify rule: any path outside doc/**, README.md,
#                     LICENSE and CONTEXT.md, and it is the `if:` CI puts on
#                     coverage, coverage-gate and acceptance. The whole
#                     matrix is planned even for a spec-only diff: it holds
#                     every shard a changed spec can land in, and the floor
#                     is a project rate no partial run can measure.
#
#                     It is the matrix, not `just test coverage`: the
#                     unsharded run is one serial kcov over the suite, and
#                     CI never runs that shape. A shard is a weighted slice
#                     of the suite dealt into COVERAGE_JOBS concurrent kcov
#                     slices (base#1410, base#1414), so a failure that only
#                     concurrent slices or a shard's membership produce
#                     passed the unsharded run and went red in CI.
#
#                     Weights: each shard partitions by the ambient
#                     SHARD_WEIGHTS_BLOB, as the coverage job does; unset,
#                     that is CI's cache-miss partition (by `@test` count).
#                     The blob a PR's run restores is whatever the newest
#                     main run cached when the PR's run starts, which no
#                     run before the push can read; export the blob of a
#                     given CI run to reproduce that run's partition.
#   system relevant   `just test system` -- the docker.sock image-lifecycle
#                     gate. Relevance is CI's own pathspec list, read from
#                     script/ci/system_paths.sh, so the two cannot disagree
#                     about which diff can change what it observes.
#
# The parity spec holds each gate to the job-level `if:` the workflow puts
# on the job, so a gate written here that runs a job on fewer diffs than CI
# does is red there.
#
# Architecture: `system` and the amd64 `acceptance` leg build and run
# images for the docker daemon's own architecture, and CI runs both on
# amd64 runners. On any other daemon -- or one whose architecture cannot
# be read -- the run prints those two as NOT RUN instead of running them
# for the wrong arch and calling the amd64 leg green (base#1409).
#
# Style: Google Shell Style Guide.

set -euo pipefail

_MIRROR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _MIRROR_DIR
_MIRROR_ROOT="$(cd -- "${_MIRROR_DIR}/../.." && pwd -P)"
readonly _MIRROR_ROOT
readonly _MIRROR_WORKFLOW="${_MIRROR_ROOT}/.github/workflows/self-test.yaml"

# The local commands, spelled once: the table and the plan both print them.
# The parity spec derives each one's mode from what it runs (a `just test`
# recipe is read as its body in justfile.test), and requires every planned
# command to be what _run executes.
readonly _CMD_ACTIONLINT='./script/ci/pre_pr_mirror.sh --actionlint'
readonly _CMD_TEST='just test'
readonly _CMD_COVERAGE='./script/ci/pre_pr_mirror.sh --coverage-matrix'
readonly _CMD_FLOOR='bash ./script/test/drivers/coverage_gate.sh --run-dirs coverage-shards/*/'
readonly _CMD_MERGE='bash ./script/test/drivers/coverage_gate.sh --merge-timings coverage-shards/timings.tsv coverage-shards/*/timings.tsv'
readonly _CMD_UNION='./script/test/test.sh --coverage-union-check coverage-shards/timings.tsv'

# Where --coverage-matrix keeps each shard's coverage/ tree, as
# coverage-gate's download step lays the shard artifacts out.
readonly _SHARDS_DIR='coverage-shards'
readonly _CMD_SYSTEM='just test system'
readonly _CMD_ACCEPTANCE='just test acceptance'

# The planned commands that measure the daemon's own architecture, for jobs
# CI runs on amd64 runners only (base#1409).
readonly -a _AMD64_CMDS=("${_CMD_SYSTEM}" "${_CMD_ACCEPTANCE}")

# _table -- what this mirror attests and what it leaves to CI, and why.
#
# Membership of `attested` is a claim about what the plan RUNS, on every
# diff CI runs the job for; the parity spec checks the plan against each
# job's `if:` gate and the run against the plan. `excluded` is the honest way to narrow the claim, and only what no
# local machine can reproduce belongs in it.
_table() {
  local t=$'\t'
  printf '%s\n' \
    "attested${t}actionlint${t}${_CMD_ACTIONLINT}" \
    "attested${t}shellcheck${t}${_CMD_TEST}" \
    "attested${t}doc-counts${t}${_CMD_TEST}" \
    "attested${t}lint-static${t}${_CMD_TEST}" \
    "attested${t}hadolint${t}${_CMD_TEST}" \
    "attested${t}bats-fragile${t}${_CMD_TEST}" \
    "attested${t}bats-integration${t}${_CMD_TEST}" \
    "attested${t}coverage${t}${_CMD_COVERAGE}" \
    "attested${t}coverage-gate${t}${_CMD_FLOOR} && ${_CMD_MERGE} && ${_CMD_UNION}" \
    "attested${t}system${t}${_CMD_SYSTEM}" \
    "attested${t}acceptance${t}${_CMD_ACCEPTANCE}" \
    "excluded${t}acceptance/arm64${t}the native arm64 runner leg; a local run measures the host's own arch, and there is no local arm64 runner to stand in for it" \
    "excluded${t}classify${t}CI's own path classifier computing the other jobs' if: gates; the plan applies the same two rules itself, and there is no repo-content verdict to reproduce" \
    "excluded${t}compute-shards${t}CI plumbing: it publishes the shard list and the cached weights blob; --coverage-shards applies its shard-count rule to the same CI_SHARDS, and the cache it restores is CI state no run before the push can read" \
    "excluded${t}worker-selftest${t}invokes base's reusable build-worker.yaml, which only a GitHub Actions runner can call"
}

# CI's code_changed pathspecs, as classify passes them to `git diff`:
# everything outside the documentation allow-list.
readonly -a _CODE_PATHSPECS=(':!doc/**' ':!README.md' ':!LICENSE' ':!CONTEXT.md')

# _system_pathspecs -- CI's system_relevant pathspecs, one per line. Empty
# on a failed read, which _gates treats as relevant (CI fails open the same
# way: "cannot tell" must not mean "skip the job").
_system_pathspecs() {
  bash "${_MIRROR_ROOT}/script/ci/system_paths.sh" 2>/dev/null || true
}

# _gates <repo> <diff-arg>... -- the CI gates the diff fires, one per line
# (`code`, `system`), each decided by the `git diff --quiet ... --
# <pathspecs>` classify itself runs, with the same pathspecs. Git matches
# the pathspecs against the real names, so nothing here reads a printed
# file name: an earlier version matched `git diff --name-only` text, and
# that text dropped a move's source under rename detection and quoted a
# non-ASCII name under core.quotePath, each one a diff CI gates in and
# the mirror skipped (base#1409). A failing diff fires the gate, as the
# `if git diff` form does in CI.
_gates() {
  local repo="$1" spec
  shift
  local -a specs=()
  while IFS= read -r spec; do
    [[ -n "${spec}" ]] && specs+=("${spec}")
  done < <(_system_pathspecs)
  git -C "${repo}" diff --quiet "$@" -- "${_CODE_PATHSPECS[@]}" || echo code
  if (( ${#specs[@]} == 0 )) \
      || ! git -C "${repo}" diff --quiet "$@" -- "${specs[@]}"; then
    echo system
  fi
}

# _commands <gates> -- the commands to run for the gates _gates printed.
_commands() {
  local gates="$1" code=0 system=0
  grep -qx code <<<"${gates}" && code=1
  grep -qx system <<<"${gates}" && system=1
  printf '%s\n' "${_CMD_ACTIONLINT}" "${_CMD_TEST}"
  if (( code )); then
    printf '%s\n' "${_CMD_COVERAGE}" "${_CMD_FLOOR}" "${_CMD_MERGE}" "${_CMD_UNION}"
  fi
  if (( system )); then
    printf '%s\n' "${_CMD_SYSTEM}"
  fi
  if (( code )); then
    printf '%s\n' "${_CMD_ACCEPTANCE}"
  fi
}

# _plan -- read changed paths on stdin, print the commands to run. The
# paths are staged as empty files into a throwaway repo and classified by
# the same _gates the run uses, against the empty tree, so --plan and a
# real run cannot disagree on which gate a path fires (base#1409).
_plan() {
  local tmp blob empty path gates
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${tmp} now; it is local to _plan
  trap "rm -rf '${tmp}'" EXIT
  git init -q "${tmp}"
  blob="$(git -C "${tmp}" hash-object -w --stdin </dev/null)"
  empty="$(git -C "${tmp}" hash-object -t tree /dev/null)"
  while IFS= read -r path; do
    [[ -n "${path}" ]] && printf '100644 %s\t%s\0' "${blob}" "${path}"
  done | git -C "${tmp}" update-index -z --index-info
  gates="$(_gates "${tmp}" --cached "${empty}")"
  _commands "${gates}"
}

# _actionlint -- the actionlint job, image pin and suppressions read from
# the workflow. No pin found is a refusal: an un-pinned local actionlint is
# a different rule set, and a green from it would attest nothing.
_actionlint() {
  local img
  img="$(grep -m1 -oE 'rhysd/actionlint:[A-Za-z0-9._-]+' "${_MIRROR_WORKFLOW}")" || true
  img="${img%%$'\n'*}"
  if [[ -z "${img}" ]]; then
    printf 'pre_pr_mirror: no rhysd/actionlint:<tag> pin in %s; refusing to run an unpinned actionlint\n' \
      "${_MIRROR_WORKFLOW}" >&2
    return 1
  fi
  local -a args=()
  [[ -t 1 ]] && args+=(-color)
  local pat
  while IFS= read -r pat; do
    [[ -n "${pat}" ]] && args+=(-ignore "${pat}")
  done < <(sed -n "s/.*-ignore[[:space:]]*'\\([^']*\\)'.*/\\1/p" "${_MIRROR_WORKFLOW}")
  docker run --rm -v "${_MIRROR_ROOT}:/repo:ro" -w /repo "${img}" "${args[@]}"
}

# _ci_shards_raw -- the CI_SHARDS value the coverage matrix is computed
# from: the environment's CI_SHARDS when it is set (even empty, which is
# CI's "variable unset"), else the repo's Actions variable. A variable that
# cannot be read is a refusal, not compute-shards' default of 8: guessing
# the count would run a different matrix and call it CI's.
_ci_shards_raw() {
  if [[ -v CI_SHARDS ]]; then
    printf '%s\n' "${CI_SHARDS}"
    return 0
  fi
  if ! (cd "${_MIRROR_ROOT}" && gh variable get CI_SHARDS) 2>/dev/null; then
    printf 'pre_pr_mirror: cannot read the CI_SHARDS Actions variable with gh; set CI_SHARDS=<n> (empty: unset) to say which matrix CI runs\n' >&2
    return 1
  fi
}

# _coverage_shards -- the coverage matrix, one `<n>/<total>` per line.
# The count rule is compute-shards' `gen` step, line for line; the parity
# spec runs both over the same inputs.
_coverage_shards() {
  local raw n
  raw="$(_ci_shards_raw)" || return 1
  n="${raw:-8}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=8
  (( n < 1 )) && n=1
  (( n > 12 )) && n=12
  seq 1 "${n}" | sed "s|.*|&/${n}|"
}

# _coverage_jobs -- the COVERAGE_JOBS the coverage job sets on its shard
# step, read from the workflow. None found is a refusal: the slice count
# is part of what a shard is (base#1410).
_coverage_jobs() {
  local jobs
  jobs="$(grep -m1 -oE '^[[:space:]]+COVERAGE_JOBS:[[:space:]]*[0-9]+' "${_MIRROR_WORKFLOW}")" || true
  jobs="${jobs##*[^0-9]}"
  if [[ -z "${jobs}" ]]; then
    printf 'pre_pr_mirror: no COVERAGE_JOBS: <n> in %s; refusing to guess the shard slice count\n' \
      "${_MIRROR_WORKFLOW}" >&2
    return 1
  fi
  echo "${jobs}"
}

# _coverage_matrix -- run every shard as the coverage job does, keeping
# each shard's coverage/ tree as coverage-shards/<n>/. The first red
# shard stops the run: its report is incomplete, and the floor after it
# would read a matrix with a hole.
_coverage_matrix() {
  local jobs shard
  local -a shards=()
  jobs="$(_coverage_jobs)" || return 1
  mapfile -t shards < <(_coverage_shards)
  (( ${#shards[@]} > 0 )) || return 1
  cd "${_MIRROR_ROOT}"
  rm -rf "${_SHARDS_DIR}"
  mkdir -p "${_SHARDS_DIR}"
  for shard in "${shards[@]}"; do
    printf '\n==> pre-PR mirror: coverage shard %s (COVERAGE_JOBS=%s)\n' "${shard}" "${jobs}"
    COVERAGE_JOBS="${jobs}" ./script/test/test.sh --coverage-shard "${shard}" || return 1
    cp -R coverage "${_SHARDS_DIR}/${shard%%/*}"
  done
}

# _daemon_arch -- the docker daemon's architecture as `docker info`
# reports it (x86_64, aarch64, ...), or `unknown` when it cannot be read.
_daemon_arch() {
  local arch
  arch="$(docker info --format '{{.Architecture}}' 2>/dev/null)" || arch=""
  echo "${arch:-unknown}"
}

# _needs_amd64 <cmd> -- true when <cmd> is one of _AMD64_CMDS.
_needs_amd64() {
  local c
  for c in "${_AMD64_CMDS[@]}"; do
    [[ "$1" == "${c}" ]] && return 0
  done
  return 1
}

# _run <base> -- plan the diff <base>...HEAD and run it, first red stops.
# The range is checked first, so a base that does not resolve is an error
# rather than the fail-open "every gate fires" a failing diff gives.
_run() {
  local base="$1" gates cmd arch="" not_run=0
  if ! git -C "${_MIRROR_ROOT}" merge-base "${base}" HEAD >/dev/null 2>&1; then
    printf 'pre_pr_mirror: cannot diff %s...HEAD in %s\n' "${base}" "${_MIRROR_ROOT}" >&2
    return 2
  fi
  gates="$(_gates "${_MIRROR_ROOT}" "${base}...HEAD")"
  # The plan is read in full before anything runs. Fed to the loop on
  # stdin, it was also every planned command's stdin, and `just test`
  # drained it: the run stopped after two commands and still reported
  # every planned command green (base#1409).
  local -a plan=()
  mapfile -t plan < <(_commands "${gates}")
  for cmd in "${plan[@]}"; do
    if _needs_amd64 "${cmd}"; then
      [[ -n "${arch}" ]] || arch="$(_daemon_arch)"
      if [[ "${arch}" != x86_64 && "${arch}" != amd64 ]]; then
        printf '\npre_pr_mirror: NOT RUN: %s (CI runs it on an amd64 runner; the docker daemon here is %s)\n' \
          "${cmd}" "${arch}" >&2
        not_run=$(( not_run + 1 ))
        continue
      fi
    fi
    printf '\n==> pre-PR mirror: %s\n' "${cmd}"
    if ! (cd "${_MIRROR_ROOT}" && bash -c "${cmd}"); then
      printf 'pre_pr_mirror: RED at: %s\n' "${cmd}" >&2
      return 1
    fi
  done
  if (( not_run )); then
    printf '\npre_pr_mirror: NOT GREEN for %s...HEAD: %d planned command(s) not run, see NOT RUN above\n' \
      "${base}" "${not_run}" >&2
    return 3
  fi
  printf '\npre_pr_mirror: every planned command was green for %s...HEAD\n' "${base}"
}

main() {
  case "${1:-}" in
    --table) _table ;;
    --plan) _plan ;;
    --actionlint) _actionlint ;;
    --coverage-shards) _coverage_shards ;;
    --coverage-matrix) _coverage_matrix ;;
    --base) _run "${2:?--base expects a ref}" ;;
    '') _run origin/main ;;
    -h|--help) sed -n '2,/^# Style/p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//' ;;
    *)
      printf 'pre_pr_mirror: unknown argument: %s (see --help)\n' "$1" >&2
      return 2
      ;;
  esac
}

main "$@"
