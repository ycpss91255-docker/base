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
#       planned command was green.
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
#
# What the plan runs, and why each gate is the one it is:
#
#   always            actionlint, and `just test` -- every linter of the
#                     _LINT_TOOLS table, then the whole bats suite plain.
#                     The lint jobs and bats-fragile / bats-integration run
#                     subsets of exactly that, plain, in CI. Run on every
#                     diff, because a superset costs a minute and a
#                     classification this mirror got wrong would cost a PR.
#   code changed      `just test coverage` -- the FULL kcov suite -- then the
#                     coverage floor and the shard-union check over its
#                     report, which is what `coverage` and `coverage-gate`
#                     run in CI. "Code changed" is CI's own classify rule:
#                     any path outside doc/**, README.md, LICENSE and
#                     CONTEXT.md. The full suite is planned even for a
#                     spec-only diff: it holds every shard a changed spec
#                     can land in (the greedy partition depends on a
#                     weights file a fresh checkout does not have, so
#                     naming "the" shard locally would be a guess), and the
#                     floor is a project rate no partial run can measure.
#   system relevant   `just test system` and `just test acceptance` -- the
#                     docker.sock image-lifecycle gate and the amd64
#                     acceptance scaffold. Relevance is CI's own pathspec
#                     list, read from script/ci/system_paths.sh, so the two
#                     cannot disagree about which diff can change what they
#                     observe.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_MIRROR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _MIRROR_DIR
_MIRROR_ROOT="$(cd -- "${_MIRROR_DIR}/../.." && pwd -P)"
readonly _MIRROR_ROOT
readonly _MIRROR_WORKFLOW="${_MIRROR_ROOT}/.github/workflows/self-test.yaml"

# The local commands, spelled once: the table and the plan both print them,
# and the parity spec reads the table's spelling to derive each one's mode.
readonly _CMD_ACTIONLINT='./script/ci/pre_pr_mirror.sh --actionlint'
readonly _CMD_TEST='just test'
readonly _CMD_COVERAGE='just test coverage'
readonly _CMD_FLOOR='bash ./script/test/drivers/coverage_gate.sh coverage/cobertura.xml'
readonly _CMD_UNION='./script/test/test.sh --coverage-union-check coverage/timings.tsv'
readonly _CMD_SYSTEM='just test system'
readonly _CMD_ACCEPTANCE='just test acceptance'

# _table -- what this mirror attests and what it leaves to CI, and why.
#
# Membership of `attested` is a claim about what the plan RUNS; adding a
# job there without changing the plan is the one way to make the stamp lie
# again. `excluded` is the honest way to narrow the claim, and only what no
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
    "attested${t}coverage-gate${t}${_CMD_COVERAGE} && ${_CMD_FLOOR} && ${_CMD_UNION}" \
    "attested${t}system${t}${_CMD_SYSTEM}" \
    "attested${t}acceptance${t}${_CMD_ACCEPTANCE}" \
    "excluded${t}acceptance/arm64${t}the native arm64 runner leg; a local run measures the host's own arch, and there is no local arm64 runner to stand in for it" \
    "excluded${t}classify${t}CI's own path classifier computing the other jobs' if: gates; the plan applies the same two rules itself, and there is no repo-content verdict to reproduce" \
    "excluded${t}compute-shards${t}emits the partition the coverage matrix fans out over; the mirror runs that suite unsharded, so there is no partition to compute" \
    "excluded${t}worker-selftest${t}invokes base's reusable build-worker.yaml, which only a GitHub Actions runner can call"
}

# _system_pathspecs -- CI's system_relevant pathspecs, one per line. Empty
# on a failed read, which _plan treats as relevant (CI fails open the same
# way: "cannot tell" must not mean "skip the job").
_system_pathspecs() {
  bash "${_MIRROR_ROOT}/script/ci/system_paths.sh" 2>/dev/null || true
}

# _matches_pathspec <path> <pathspec> -- a git pathspec of the two shapes
# system_paths.sh emits: `<dir>/**` (anything under <dir>) or a literal
# path. `**` becomes `*`, which in a [[ ]] pattern already spans `/`.
_matches_pathspec() {
  local path="$1" spec="$2"
  # shellcheck disable=SC2053 # the right-hand side IS the glob
  [[ "${path}" == ${spec//\*\*/*} ]]
}

# _is_code <path> -- CI's classify rule for code_changed: anything outside
# the documentation pathspecs.
_is_code() {
  case "$1" in
    doc/*|README.md|LICENSE|CONTEXT.md) return 1 ;;
    *) return 0 ;;
  esac
}

# _plan -- read changed paths on stdin, print the commands to run.
_plan() {
  local path spec code=0 system=0 specs
  specs="$(_system_pathspecs)"
  [[ -n "${specs}" ]] || system=1
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    _is_code "${path}" && code=1
    (( system )) && continue
    while IFS= read -r spec; do
      [[ -n "${spec}" ]] || continue
      if _matches_pathspec "${path}" "${spec}"; then
        system=1
        break
      fi
    done <<< "${specs}"
  done

  printf '%s\n' "${_CMD_ACTIONLINT}" "${_CMD_TEST}"
  if (( code )); then
    printf '%s\n' "${_CMD_COVERAGE}" "${_CMD_FLOOR}" "${_CMD_UNION}"
  fi
  if (( system )); then
    printf '%s\n' "${_CMD_SYSTEM}" "${_CMD_ACCEPTANCE}"
  fi
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

# _run <base> -- plan the diff <base>...HEAD and run it, first red stops.
_run() {
  local base="$1" diff cmd
  diff="$(git -C "${_MIRROR_ROOT}" diff --name-only "${base}...HEAD")" || {
    printf 'pre_pr_mirror: cannot diff %s...HEAD in %s\n' "${base}" "${_MIRROR_ROOT}" >&2
    return 2
  }
  while IFS= read -r cmd; do
    printf '\n==> pre-PR mirror: %s\n' "${cmd}"
    if ! (cd "${_MIRROR_ROOT}" && bash -c "${cmd}"); then
      printf 'pre_pr_mirror: RED at: %s\n' "${cmd}" >&2
      return 1
    fi
  done < <(printf '%s\n' "${diff}" | _plan)
  printf '\npre_pr_mirror: every planned command was green for %s...HEAD\n' "${base}"
}

main() {
  case "${1:-}" in
    --table) _table ;;
    --plan) _plan ;;
    --actionlint) _actionlint ;;
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
