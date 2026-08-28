#!/usr/bin/env bash
# runtime_stages.sh -- runtime-stage resolver for the reusable Docker build
# worker (build-worker.yaml).
#
# Answers one question: should this build run the `runtime-test` / `runtime`
# targets? The Dockerfile is the only artifact that KNOWS -- it either
# declares those stages or it does not -- so the worker reads it here rather
# than trusting the caller's `build_runtime` input to agree. The two used to
# be independent declarations of one fact with nothing checking them: the
# shipped template Dockerfile keeps its builder / runtime / runtime-test
# blocks commented out while the worker input defaults to true, so a repo
# created from the template asked buildx for a target that did not exist
# ("target stage \"runtime-test\" could not be found") on its first push,
# and every downstream fixed its own copy by hand.
#
# With the Dockerfile as the single reader, uncommenting the runtime blocks
# is the whole action needed to get a runtime build, and no edit anywhere
# else can contradict it. `build_runtime` survives as an opt-OUT for the repo
# that ships the stages but deliberately does not want them built in CI; it
# can no longer assert that a stage exists.
#
# A Dockerfile declaring exactly one half of the pair is drift, not a
# configuration: `runtime` without `runtime-test` silently loses the
# install-check, `runtime-test` without `runtime` cannot build at all. Both
# fail here, naming the Dockerfile and the missing stage, instead of
# surfacing as an opaque buildx target error.
#
# Pushed down out of build-worker.yaml so the logic is host-testable under
# `just test` (System-level logic -> Unit level, ADR-00000018); the workflow
# keeps only the thin GITHUB_OUTPUT plumbing around this script's stdout.
#
# Input : DOCKERFILE env var (path to the caller's Dockerfile, required)
#         BUILD_RUNTIME env var ("true" / "false" / empty; empty means true)
# Output: "true" or "false" on stdout -- whether to build the runtime pair.
# Exit  : 0 on a resolved answer; 1 on a missing / unreadable Dockerfile, an
#         unparseable BUILD_RUNTIME, or a half-declared runtime pair (message
#         on stderr). The logic is CI-host-agnostic: only build-worker.yaml
#         binds the env + stdout to GitHub.

set -euo pipefail

# _declares_stage <dockerfile> <stage>
#
# True when the Dockerfile declares `FROM <image> AS <stage>` at the start of
# a line, with any `--platform=` style flags in between. Dockerfile keywords
# are case-insensitive, so the match is too; a leading `#` is not, which is
# exactly what keeps the shipped commented-out blocks from counting as
# declared. Same `FROM ... AS` shape the worker's extra-stages loop and
# setup.sh's stage parser recognise.
_declares_stage() {
  local _dockerfile="${1}" _stage="${2}"
  grep -qiE "^FROM[[:space:]]+.*[[:space:]]+AS[[:space:]]+${_stage}[[:space:]]*(#.*)?$" \
    "${_dockerfile}"
}

main() {
  local dockerfile="${DOCKERFILE:-}"
  local requested="${BUILD_RUNTIME:-true}"

  if [[ -z "${dockerfile}" ]]; then
    printf 'runtime_stages: DOCKERFILE is empty -- nothing to read the runtime stages from\n' >&2
    return 1
  fi
  if [[ ! -f "${dockerfile}" ]]; then
    printf 'runtime_stages: no Dockerfile at %s\n' "${dockerfile}" >&2
    return 1
  fi

  case "${requested}" in
    true | false) ;;
    *)
      printf "runtime_stages: build_runtime must be true or false, got '%s'\n" \
        "${requested}" >&2
      return 1
      ;;
  esac

  local has_runtime=false has_runtime_test=false
  _declares_stage "${dockerfile}" "runtime" && has_runtime=true
  _declares_stage "${dockerfile}" "runtime-test" && has_runtime_test=true

  if [[ "${has_runtime}" != "${has_runtime_test}" ]]; then
    local present="runtime" missing="runtime-test"
    if [[ "${has_runtime_test}" == "true" ]]; then
      present="runtime-test"
      missing="runtime"
    fi
    printf 'runtime_stages: %s declares stage %s but not %s -- a runtime split needs both (uncomment the %s block, or comment %s out)\n' \
      "${dockerfile}" "${present}" "${missing}" "${missing}" "${present}" >&2
    return 1
  fi

  if [[ "${has_runtime}" == "false" ]]; then
    printf 'runtime_stages: %s declares no runtime / runtime-test stage -- skipping the runtime build steps\n' \
      "${dockerfile}" >&2
    printf 'false\n'
    return 0
  fi

  if [[ "${requested}" == "false" ]]; then
    printf 'runtime_stages: %s declares a runtime split, but the caller passed build_runtime: false -- skipping the runtime build steps\n' \
      "${dockerfile}" >&2
    printf 'false\n'
    return 0
  fi

  printf 'true\n'
}

main "$@"
