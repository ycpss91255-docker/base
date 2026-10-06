#!/usr/bin/env bash
#
# testtools_image.sh -- WHICH tooling image a worker build consumes.
#
# `ghcr.io/ycpss91255-docker/test-tools:<tag>` is a build-arg of every
# downstream Dockerfile: its test stage is declared
# `FROM ${TEST_TOOLS_IMAGE}`, so this reference decides which shellcheck,
# which hadolint and which bats a downstream repo's CI lints and tests
# with. The workers that pass it -- build-worker.yaml, publish-worker.yaml
# -- learn it from here and from nowhere else.
#
# ── Why the question needs a home ────────────────────────────────────────
#
# It had two answers, and they were never the same one.
#
#   this repo's `.version`        the base release a caller pinned
#                                 `uses: ...@vX.Y.Z` to, and the tag
#                                 release-test-tools.yaml publishes the
#                                 tooling image under
#   a `test_tools_version` input  defaulting to `latest`, which is a
#                                 ROLLING tag naming whatever release
#                                 published last
#
# A downstream repo pins the worker to an immutable base tag and then
# built its lint stage from `:latest`, so the tooling half of the pin was
# not pinned at all: the same downstream commit linted against different
# binaries on different days, and during an RC window it linted against
# whatever the last finished release had left there. Only one caller in
# the org ever set the input, which is the shape of a knob that exists so
# the default can be wrong quietly.
#
# Keeping both and reconciling them at release time -- a literal in the
# worker that a bump step rewrites -- is the same two-sources defect one
# indirection further away, and the reconciliation is the step nobody
# notices was skipped. So there is ONE source: `.version`, in the base
# checkout the worker already takes at its OWN ref
# (`github.job_workflow_sha`) for the cache-scope, runtime-stage and
# stage-name resolvers. The tag the image is published under and the tag
# the worker consumes are then the same string read from the same file,
# and no step has to keep them in step.
#
# ── Why it refuses rather than guesses ───────────────────────────────────
#
# The fallback that suggests itself for an unreadable `.version` is
# `latest`, which is exactly the rolling tag this exists to stop
# consuming -- so an unreadable version would route the build to the one
# reference the fix removed, silently, and the lint pass would report a
# verdict about tools nobody chose. Nothing is printed on stdout in that
# case: a caller capturing stdout gets an empty image reference and fails
# where it is used, rather than a well-formed answer that is wrong.
#
# WHETHER THE CONTENT IS A RELEASE VERSION IS NOT RE-ANSWERED HERE.
# `script/ci/release-version.sh` owns the shape a release version may
# have -- `vX.Y.Z` with an optional prerelease suffix, the `v` included
# because that is the tag downstream repos pin (ADR-00000002) -- and
# refuses anything else rather than normalising it. That is the same
# question with the same stakes (its answer becomes a published tag), so
# it is ASKED, and the version this prints is the one IT echoed back. A
# regex of our own here would be a third spelling of a rule that already
# has two readers, which is how the first two came to disagree.
#
# Usage: testtools_image.sh [base-root]
#
#   The argument exists so a spec can point this at a synthetic tree whose
#   `.version` is absent, empty or not a version. CI passes nothing and
#   gets the checkout this file lives in -- which is the base source at
#   the worker's own ref, since the worker checks that out and runs this
#   copy of the script from inside it.
#
# Output: `ghcr.io/ycpss91255-docker/test-tools:<version>` on stdout.
#         The FULL reference, not the tag alone, so the registry path has
#         one spelling too: a workflow that assembled
#         `<literal>:${{ steps.x.outputs.tag }}` would be a second place
#         the package can be renamed and missed.
#
# Exit  : 0 and the reference; non-zero and NOTHING on stdout when the
#         version cannot be established.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_TESTTOOLS_IMAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" \
  && pwd -P)"

# The published package. One spelling in the tree for the reference the
# workers consume; release-test-tools.yaml names the same package as the
# PUBLISHER, which resolves its tags from the pushed ref and not from a
# version file, so it is a different question and keeps its own.
readonly _TESTTOOLS_IMAGE_REPO='ghcr.io/ycpss91255-docker/test-tools'

# The owner of "is this string a release version, and which one".
readonly _TESTTOOLS_IMAGE_VERSION_OWNER='release-version.sh'

main() {
  local _root="${1:-}"
  if [[ -z "${_root}" ]]; then
    _root="$(cd -- "${_TESTTOOLS_IMAGE_DIR}/../.." && pwd -P)"
  fi
  local _file="${_root%/}/.version"
  # Unreadable is refused by the same test as absent, deliberately: a
  # reader whose redirection fails yields no content rather than an error,
  # and an empty version would reach the resolver below as "nothing was
  # supplied" -- a message about a release that does not mention this file
  # at all.
  if [[ ! -f "${_file}" || ! -r "${_file}" ]]; then
    printf 'testtools_image: no readable version file at %s, so which tooling image this build consumes cannot be derived. It is the base checkout the worker takes at its own ref; a worker reaching this has checked out something that is not a base release.\n' \
      "${_file}" >&2
    return 1
  fi
  local _raw
  _raw="$(tr -d '[:space:]' < "${_file}")"
  if [[ -z "${_raw}" ]]; then
    printf 'testtools_image: %s is empty, so there is no version to consume the tooling image at. Refusing rather than falling back to the rolling latest tag, which is the reference a pinned worker must never build from.\n' \
      "${_file}" >&2
    return 1
  fi
  local _resolved
  # The resolver's own refusal names the value and why it is not a
  # version; it is left on stderr as it stands rather than rephrased, and
  # this adds only where the value came from, which the resolver cannot
  # know.
  if ! _resolved="$(RELEASE_VERSION_INPUT="${_raw}" GITHUB_REF_NAME='' \
      bash "${_TESTTOOLS_IMAGE_DIR}/${_TESTTOOLS_IMAGE_VERSION_OWNER}")"; then
    printf 'testtools_image: the value above came from %s. The tooling image is published under the release tag, so a version that could not become a tag names no image to build from.\n' \
      "${_file}" >&2
    return 1
  fi
  local _version
  _version="$(printf '%s\n' "${_resolved}" | sed -n 's/^version=//p')"
  if [[ -z "${_version}" ]]; then
    printf 'testtools_image: %s answered without a version= line for %s. Refusing rather than consuming an untagged reference.\n' \
      "${_TESTTOOLS_IMAGE_VERSION_OWNER}" "${_raw}" >&2
    return 1
  fi
  printf '%s:%s\n' "${_TESTTOOLS_IMAGE_REPO}" "${_version}"
}

main "$@"
