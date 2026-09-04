#!/usr/bin/env bash
#
# obtain_test_tools.sh -- get this run the tooling image it runs inside.
#
# Six jobs of self-test.yaml need `test-tools`, and there are three ways to
# have it. The PR changed the Dockerfile, so the rolling `:main` is stale
# for it by definition and the image is built from source. Or `:main`
# corresponds to this checkout and is pulled, re-tagged under the run's own
# name, and used -- the hot path, and the reason a PR that touches nothing
# related does not pay for a multi-arch build. Or it does not correspond,
# or cannot be pulled at all, and the image is built from source again.
#
# The decision is here rather than in the jobs because it USED to be in the
# jobs: a block of shell pasted into each of them, and a paste is something
# a person has to remember to do. Five copies probed the pulled image; the
# sixth -- `acceptance`, which scaffolds a downstream repo and runs
# `just docker build test` against a lint stage that is
# `FROM ${TEST_TOOLS_IMAGE}` -- pulled and exited 0. It is precisely the
# job the mitigation was written for, and it is the one that did not get
# it, because no single copy looked wrong.
#
# The refusal side is always the source build. That is the strict
# direction: a rebuild costs minutes, and running the suite inside an image
# that does not correspond to its own checkout costs a review -- a lint
# gate on an older rule set does not fail, it under-reports.
#
# Usage:
#   ./script/ci/obtain_test_tools.sh <image-tag> [options]
#
#     --platform <p>            platform to pull (default: the host's)
#     --local-build inline      build here when the verdict is "from
#                               source"
#     --local-build delegate    leave that build to the caller's own step
#                               (the default)
#
#   `delegate` is for the jobs whose build runs through
#   docker/build-push-action, so the GHA layer cache applies; they gate
#   that step on the `build_local` output written here. `inline` is for the
#   jobs that set up buildx with `driver: docker` -- their later
#   `docker compose build` resolves `FROM ${TEST_TOOLS_IMAGE}` against the
#   host daemon, which the container driver's isolated store cannot serve,
#   and that driver has no GHA cache to lose.
#
# Env:
#   TESTTOOLS_CHANGED   `true` when THIS PR changes the test-tools
#                       Dockerfile. Computed by the classify job, which has
#                       the full-depth checkout the three-dot diff needs;
#                       computing it in these jobs (fetch-depth: 1)
#                       misfired and rebuilt on every PR.
#   CI_RUN_KEY          the run identity stamped as the ownership label, so
#                       a sweep can tell whose image this is.
#   GITHUB_OUTPUT       where `build_local=true|false` is written, when set.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -uo pipefail
fi

_OBTAIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# The rolling tag, and the file a from-source build reads. Written once
# here rather than in each caller: a second spelling of either is a second
# thing to keep in agreement.
_OBTAIN_ROLLING_TAG="ghcr.io/ycpss91255-docker/test-tools:main"

# _obtain_dockerfile
#   The checkout's test-tools Dockerfile, resolved from THIS script's own
#   location, for the same reason the probe resolves its own: CI invokes
#   this with an image tag alone.
_obtain_dockerfile() {
  local _root
  _root="$(cd -- "${_OBTAIN_DIR}/../.." && pwd -P)" || return 1
  printf '%s\n' "${_root}/dockerfile/Dockerfile.test-tools"
}

# ── the four seams through which this script touches docker ──────────────
#
# Each is one command, so the decision above them is drivable from a unit
# spec with no daemon.

# _obtain_pull <platform>
#   Pull the rolling tag for <platform>. Its noise is dropped: a registry
#   that cannot be reached is an ordinary branch here, not an error the
#   reader has to triage.
_obtain_pull() {
  local _platform="${1:-}"
  if [[ -n "${_platform}" ]]; then
    docker pull --platform "${_platform}" "${_OBTAIN_ROLLING_TAG}" 2>/dev/null
    return
  fi
  docker pull "${_OBTAIN_ROLLING_TAG}" 2>/dev/null
}

# _obtain_retag <source> <target> <run-key>
#   Re-tag under the run-scoped name AND stamp the ownership label in one
#   metadata-only layer. `docker tag` cannot add a label, and an image the
#   run pulled is still an image the run has to clean up.
_obtain_retag() {
  local _source="${1}" _target="${2}" _key="${3}"
  printf 'FROM %s\nLABEL base.ci.run=%s\n' "${_source}" "${_key}" \
    | docker build -q -t "${_target}" - >/dev/null
}

# _obtain_probe <image>
#   Does <image> correspond to this checkout? The verdict, and the reason
#   on stderr when it does not.
_obtain_probe() {
  bash "${_OBTAIN_DIR}/probe_test_tools.sh" "${1}"
}

# _obtain_build <image> <run-key>
#   The from-source build, labelled so the sweep can attribute it.
_obtain_build() {
  local _image="${1}" _key="${2}" _file
  _file="$(_obtain_dockerfile)" || return 1
  docker build --label "base.ci.run=${_key}" -t "${_image}" -f "${_file}" .
}

# _obtain_decide <image> [platform]
#   The verdict, and the only place the three ways are weighed. Writes
#   `build_local=true|false` to GITHUB_OUTPUT when that is set, and leaves
#   the same answer in `_OBTAIN_BUILD_LOCAL` for `main`.
#
#   The verdict is a VALUE and not an exit status. A status would have to
#   read "0 means build", which inverts the usual reading of success at the
#   one call site that decides whether to spend five minutes -- and a
#   caller that got it backwards would rebuild on every hot path and still
#   look green.
_obtain_decide() {
  local _image="${1:?BUG: _obtain_decide expects an image}"
  local _platform="${2:-}"
  local _key="${CI_RUN_KEY:-unattributed}"
  local _local=true

  if [[ "${TESTTOOLS_CHANGED:-false}" != "true" ]]; then
    if _obtain_pull "${_platform}"; then
      _obtain_retag "${_OBTAIN_ROLLING_TAG}" "${_image}" "${_key}"
      if _obtain_probe "${_image}"; then
        _local=false
      else
        echo "::warning::the pulled test-tools:main does not match this" \
             "checkout (reason above); rebuilding from source"
      fi
    fi
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'build_local=%s\n' "${_local}" >> "${GITHUB_OUTPUT}"
  fi
  _OBTAIN_BUILD_LOCAL="${_local}"
}

main() {
  local _image="" _platform="" _mode="delegate"
  while [[ "$#" -gt 0 ]]; do
    case "${1}" in
      --platform)
        _platform="${2:-}"
        shift 2 || return 2
        ;;
      --local-build)
        _mode="${2:-}"
        shift 2 || return 2
        ;;
      -*)
        printf 'obtain: unknown option %s\n' "${1}" >&2
        return 2
        ;;
      *)
        _image="${1}"
        shift
        ;;
    esac
  done

  if [[ -z "${_image}" ]]; then
    printf 'usage: obtain_test_tools.sh <image-tag> [--platform <p>] [--local-build inline|delegate]\n' >&2
    return 2
  fi
  case "${_mode}" in
    inline | delegate) ;;
    *)
      printf 'obtain: --local-build takes inline or delegate, not %s\n' \
        "${_mode}" >&2
      return 2
      ;;
  esac

  _OBTAIN_BUILD_LOCAL=true
  _obtain_decide "${_image}" "${_platform}"

  # The verdict is "from source". Whether that build happens here is the
  # caller's shape, not this script's opinion.
  if [[ "${_OBTAIN_BUILD_LOCAL}" == "true" && "${_mode}" == "inline" ]]; then
    _obtain_build "${_image}" "${CI_RUN_KEY:-unattributed}" || return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
