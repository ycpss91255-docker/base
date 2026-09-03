#!/usr/bin/env bash
# stage_names.sh -- Dockerfile stage-roster reader for the reusable Docker
# build worker (build-worker.yaml).
#
# Answers one question for every worker step that needs it: which build
# stages does this Dockerfile declare? Two steps ask. The extra_stages loop
# asks whether a `<stage>-test` companion exists before it builds one, and
# runtime_stages.sh asks whether the runtime / runtime-test pair is
# declared.
#
# It answers by CALLING the tree's one FROM-line matcher --
# dist/script/docker/lib/stage.sh's _dockerfile_stage_from_line -- rather
# than restating it. That matcher already owns the question for the compose
# emitter, the Dockerfile drift hash, the [environment] ENV bake and the
# config COPY bake, and its header says any change to what counts as a
# stage line belongs there and nowhere else. The worker disagreed
# with it twice over: the extra_stages loop allowed ONE token between FROM
# and AS, so the cross-build `FROM --platform=$BUILDPLATFORM debian AS
# x-test` form declared nothing to it and the stage's smoke test was
# silently not built, while runtime_stages.sh carried a third, looser
# regex -- each with a comment beside it claiming the two agreed.
# Two readers of one fact and a sentence asserting they match is the shape
# that produced both defects; there is one reader now, and the agreement is
# a verdict in stage_spec.bats's FROM-line corpus rather than a claim.
#
# The roster is UNFILTERED, unlike _parse_dockerfile_stages' projection of
# the same matcher: that one drops the baseline set {sys, devel-base,
# devel, runtime-test} on its way to compose services, and those are
# exactly the names the worker asks about.
#
# Pushed down out of build-worker.yaml for the reason its sibling resolvers
# were (System-level logic -> Unit level, ADR-00000018): the workflow keeps
# the plumbing, the logic is host-testable under `just test`.
#
# Input : DOCKERFILE env var (path to the caller's Dockerfile, required)
# Output: one declared stage name per line, in file order, on stdout.
# Exit  : 0 on a Dockerfile that was read -- including one that declares no
#         stages, which is an empty roster and not an error; 1 on an unset
#         or unreadable DOCKERFILE, message on stderr. A Dockerfile the
#         worker cannot read is not "no stages": it is "we do not know",
#         and answering an empty roster there is how a build step skips its
#         work and reports success. The logic is CI-host-agnostic; only
#         build-worker.yaml binds the env + stdout to GitHub.

set -euo pipefail

_stage_names_dir="$(dirname -- "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=dist/script/docker/lib/stage.sh
source "${_stage_names_dir}/../../../dist/script/docker/lib/stage.sh"

main() {
  local dockerfile="${DOCKERFILE:-}"

  if [[ -z "${dockerfile}" ]]; then
    printf 'stage_names: DOCKERFILE is empty -- nothing to read the stages from\n' >&2
    return 1
  fi
  if [[ ! -f "${dockerfile}" ]]; then
    printf 'stage_names: no Dockerfile at %s\n' "${dockerfile}" >&2
    return 1
  fi

  # Read the file directly (no grep | sed pipe) for the reason
  # _parse_dockerfile_stages does: under pipefail an empty match set turns
  # into exit 1, and a Dockerfile with no stage lines is a legitimate
  # answer here, not a failure.
  #
  # `|| [[ -n "${_line}" ]]` because `read` returns false on a final line
  # that no newline terminates -- it assigns the line and THEN reports the
  # EOF it hit. Without the continuation the loop drops that line, so a
  # Dockerfile written without a trailing newline loses its last stage:
  # the extra-stages loop stops seeing a `<stage>-test` companion and
  # builds no smoke test for it, and runtime_stages.sh reads a complete
  # runtime pair as a half-declared one and fails the build naming a stage
  # the file declares. The grep this reader replaced had no such blind
  # spot, and _generate_runtime_dockerfile -- reading the same files
  # through the same matcher -- already carries the continuation.
  local _line _stage
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _dockerfile_stage_from_line "${_line}" _stage || continue
    printf '%s\n' "${_stage}"
  done < "${dockerfile}"
}

main "$@"
