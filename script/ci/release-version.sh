#!/usr/bin/env bash
# release-version.sh -- version resolver for the reusable release worker
# (release-worker.yaml).
#
# Answers two questions the worker used to read straight off
# `github.ref_name`: WHICH version this release cuts, and whether it is a
# prerelease.
#
# `github.ref_name` only carries a version when the run was started by a tag
# push. A downstream repo that wants to auto-release a merged dependency bump
# cannot start one: an event created with the default GITHUB_TOKEN does not
# trigger a new workflow run, so a bot-pushed tag reaches nothing. Such a repo
# calls the worker directly instead, and on that path the ref is a BRANCH.
# Hence the `version` input, and hence this resolver: the caller's version when
# there is one, the ref when there is not, and the prerelease flag derived from
# whichever of the two was resolved.
#
# EVERY UNREADABLE CASE REFUSES. The resolved value becomes the name of a git
# tag and of a published GitHub Release, so there is no safe fallback for a
# version this cannot read -- not the ref, not a default, and least of all a
# name something already consumes. A refusal writes to stderr and prints
# NOTHING on stdout, so a caller appending stdout to GITHUB_OUTPUT is left with
# no `version` key and every `if:` that reads one is false.
#
# Input : RELEASE_VERSION_INPUT  the caller's `version` input ("" when unset)
#         GITHUB_REF_NAME        the ref the run started on
# Output: `version=<vX.Y.Z[-suffix]>` and `prerelease=<true|false>` on stdout,
#         one per line, ready to append to GITHUB_OUTPUT.
# Exit  : 0 on success; 1 when neither source is set or the resolved value is
#         not a version (with a message on stderr naming it). The logic is
#         CI-host-agnostic: only release-worker.yaml binds the env and stdout
#         to GitHub.

set -euo pipefail

# The one shape a release version may have here: `vX.Y.Z`, optionally with a
# prerelease suffix. Three components because the classification the cadence
# rests on (ADR-00000027) is stated per component; the `v` prefix because that
# is the tag downstream repos pin (ADR-00000002), and normalising a bare
# `1.2.3` into one would publish a tag the caller never asked for.
readonly VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# _trim <string> -- strip leading and trailing whitespace, nothing else.
# `version` is declared with an empty default, so "not supplied" can arrive as
# a run of spaces from a caller's expression; interior text is left alone so a
# malformed value is refused as written rather than repaired into something
# that passes.
_trim() {
  local value="${1}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

main() {
  local input ref version source_label
  input="$(_trim "${RELEASE_VERSION_INPUT:-}")"
  ref="$(_trim "${GITHUB_REF_NAME:-}")"

  if [[ -n "${input}" ]]; then
    version="${input}"
    source_label="the version input"
  elif [[ -n "${ref}" ]]; then
    version="${ref}"
    source_label="github.ref_name"
  else
    printf 'release-version: neither the version input nor github.ref_name is set -- there is nothing to release. Call this worker from a tag push, or pass the version input as vX.Y.Z.\n' >&2
    return 1
  fi

  if [[ ! "${version}" =~ ${VERSION_RE} ]]; then
    printf "release-version: %s is '%s', which is not a release version. Expected vX.Y.Z, optionally with a prerelease suffix (vX.Y.Z-rcN). Refusing rather than guessing: this value would become the tag and the release name.\n" \
      "${source_label}" "${version}" >&2
    return 1
  fi

  local prerelease=false
  if [[ "${version}" == *-* ]]; then
    prerelease=true
  fi

  printf 'version=%s\n' "${version}"
  printf 'prerelease=%s\n' "${prerelease}"
}

main "$@"
