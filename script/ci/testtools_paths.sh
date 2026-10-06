#!/usr/bin/env bash
#
# testtools_paths.sh -- which paths can change what the TOOLING IMAGE
# contains.
#
# Two CI decisions rest on that question. `testtools_changed` in
# self-test.yaml's classify job decides whether the image jobs rebuild from
# source or pull the rolling `ghcr.io/.../test-tools:main`, and
# release-test-tools.yaml decides whether a push to main republishes that
# rolling tag. Both used to answer it with one quoted literal,
# `dockerfile/Dockerfile.test-tools`, on the premise that the Dockerfile is
# the image's only input -- every tool it installs is pinned by a literal
# inside its own text.
#
# The premise stopped holding when a stage arrived that COPYs a file
# straight out of the build context. That file's CONTENT is baked into the
# image while the Dockerfile does not move, so a commit touching it alone
# left both decisions answering "unchanged": the PR ran its whole suite
# inside an image built before the edit, and the merge that followed did
# not refresh the tag it had fallen back to. The same premise broke the
# LOCAL content-hash tag, which is where the rule below comes from.
#
# So the answer is DERIVED, never listed. The set is the Dockerfile itself
# plus every path it COPYs from the build context, read off the
# Dockerfile's own COPY lines by the derivation in
# dist/script/docker/lib/project_reclaim.sh -- the same code that decides
# which files the local tag hashes. One rule, one implementation, for the
# reason the local fix gives: two implementations of one question is how
# they come to disagree, and a list is an implementation that is correct on
# the day it is written and wrong the next time someone adds a COPY. A
# second entry added here by hand would be the same defect one indirection
# further away.
#
# Output: one git pathspec per line on stdout, suitable for
# `git diff -- "${paths[@]}"`. A COPY of a directory prints the directory,
# which as a pathspec selects everything under it.
#
# Exit: 0 and the list; non-zero and NOTHING on stdout when the set cannot
# be established -- an absent Dockerfile, or a COPY line the derivation
# refuses to guess at (a glob, a variable, ADD, ONBUILD; it says which
# line). Both consumers must read a non-zero as "assume it changed": a
# needless rebuild costs minutes, and the alternative is a suite reporting
# a verdict about code that is not in the image it ran in.
#
# Usage: testtools_paths.sh [repo-root]
#
#   The argument exists so a spec can point this at a synthetic tree whose
#   Dockerfile has two context COPYs, or none, or an unparseable one. CI
#   passes nothing and gets the checkout this file lives in -- which is the
#   tree both workflows are classifying, since GitHub runs every step from
#   the workspace root.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_TESTTOOLS_PATHS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" \
  && pwd -P)"

# The derivation, and with it the Dockerfile's own repo-relative path
# (_RECLAIM_TOOL_DOCKERFILE_REL). Both are taken from the library rather
# than re-spelled here for the reason in the header: a second spelling of
# the path is a second thing to keep in agreement.
# shellcheck source=dist/script/docker/lib/project_reclaim.sh
source "${_TESTTOOLS_PATHS_DIR}/../../dist/script/docker/lib/project_reclaim.sh"

main() {
  local _root="${1:-}"
  if [[ -z "${_root}" ]]; then
    _root="$(cd -- "${_TESTTOOLS_PATHS_DIR}/../.." && pwd -P)"
  fi
  local _dockerfile="${_root%/}/${_RECLAIM_TOOL_DOCKERFILE_REL}"
  # Absent is a refusal here, where the local tag derivation treats it as a
  # fact about the tree. The difference is what the caller does with the
  # answer: an empty pathspec list passed to `git diff` compares the WHOLE
  # diff, so "there is no tooling Dockerfile" would read as "everything is
  # an input of it". Saying so and letting the consumer fail open is the
  # only direction that is wrong in the cheap way.
  if [[ ! -f "${_dockerfile}" ]]; then
    printf 'testtools_paths: no tooling Dockerfile at %s, so the paths that can change the tooling image cannot be derived\n' \
      "${_dockerfile}" >&2
    return 1
  fi
  local _srcs
  # The refusal the derivation prints names the line or the path; it is
  # left on stderr as it stands, and nothing is written to stdout, so a
  # consumer reading only stdout cannot mistake a partial list for the set.
  _srcs="$(_reclaim_tool_context_sources "${_dockerfile}")" || return 1
  printf '%s\n' "${_RECLAIM_TOOL_DOCKERFILE_REL}"
  [[ -z "${_srcs}" ]] || printf '%s\n' "${_srcs}"
}

main "$@"
