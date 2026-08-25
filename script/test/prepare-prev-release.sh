#!/usr/bin/env bash
# prepare-prev-release.sh - materialise the last N released trees for the
# released-caller compatibility spec (test/bats/integration/prev_release_upgrade_spec.bats).
#
# WHY THIS EXISTS
#
# An upgrade is always driven by the CONSUMER'S OWN vendored copy of
# upgrade.sh -- a copy that shipped in an OLD release and can never be
# changed retroactively. So the only way to know that a file move in this
# tree is survivable is to run those old scripts against this tree. That
# needs the real released trees, and it needs them on the HOST: the suite
# runs in a container that bind-mounts the checkout, and in a git worktree
# `.git` is a FILE pointing outside the mount, so no in-container git
# command can reach the object store. The host always can.
#
# So this runs host-side (script/test/test.sh calls it before it dispatches
# to compose) and leaves a plain directory tree the spec consumes with no
# git and no network of its own.
#
# WHAT IT WRITES
#
#   .prev-release/tags.txt   newest-first list of the covered release tags
#   .prev-release/<tag>/     `git archive <tag>` extracted verbatim
#
# .prev-release/ is gitignored + dockerignored and sits at the repo root
# ON PURPOSE: every lint driver scans a fixed root list (dist/, script/,
# test/, dockerfile/), so an old release parked under any of those would be
# linted as if it were current source.
#
# NETWORK
#
# None in the steady state: the tags are read from the checkout's own
# object store. A shallow/tagless checkout (CI's default `actions/checkout`)
# has neither, so a missing tag is fetched once, per tag, per checkout, and
# then cached. Nothing here is a hand-written fixture -- what the spec runs
# is byte-for-byte what was released.

# Guarded so sourcing this file (the sourceable-scripts spec does) cannot
# turn strict mode on in the caller.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

# shellcheck source=dist/script/base/upstream.sh
source "${REPO_ROOT}/dist/script/base/upstream.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/dist/script/docker/lib/_lib.sh"

# Where the materialised trees land. Repo-root dotdir, see the header.
PREV_RELEASE_DIR="${REPO_ROOT}/.prev-release"
readonly PREV_RELEASE_DIR

# How many releases back the compatibility spec covers.
#
# Two, not one. "The previous release" alone would, on a tree whose newest
# tag is also the tree's own version, resolve to the tree under test and
# assert nothing. Two always spans a real version boundary, and it is also
# the honest support claim: a consumer upgrading today is on one of the last
# couple of releases. It is a window, not a path list -- widening it costs
# one integer, and the tags inside it are resolved from the repo every run,
# so it cannot decay the way a hardcoded tag does.
PREV_RELEASE_WINDOW="${PREV_RELEASE_WINDOW:-2}"
readonly PREV_RELEASE_WINDOW

_die() {
  _log_err ci ci_prev_release_unavailable "display=prepare-prev-release.sh: $*"
  exit 1
}

_note() {
  _log_info ci ci_prev_release_progress "display=prepare-prev-release.sh: $*"
}

# _stable_release_tags
#   Print the stable release tags newest-first. RC / pre-release tags are
#   excluded: they are not what a consumer is sitting on. `--sort=-v:refname`
#   orders `v0.42.0-rc4` ABOVE `v0.42.0`, which is the opposite of SemVer
#   precedence, so the pre-releases are dropped BEFORE the ordering is
#   trusted rather than after.
_stable_release_tags() {
  local _tag
  while IFS= read -r _tag; do
    [[ "${_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    printf '%s\n' "${_tag}"
  done < <(git -C "${REPO_ROOT}" tag --list 'v*' --sort=-v:refname)
}

# _fetch_release_tags
#   Pull the tag refs from upstream. Only called when the local object
#   store does not already carry enough of them -- i.e. on a fresh shallow
#   CI checkout, once.
_fetch_release_tags() {
  _note "fewer than ${PREV_RELEASE_WINDOW} release tags locally; fetching from ${BASE_UPSTREAM_REMOTE}"
  # --depth 1: the archived tree is all we want, never the history behind
  # it. Failure is not fatal here -- the caller re-counts and reports the
  # real problem (not enough tags) with the tags it actually has.
  git -C "${REPO_ROOT}" fetch --quiet --depth 1 --no-recurse-submodules \
    "${BASE_UPSTREAM_REMOTE}" \
    '+refs/tags/v*:refs/tags/v*' 2>/dev/null \
    || _note "tag fetch failed (offline?); continuing with local tags"
}

# _materialise <tag>
#   Extract <tag>'s tree into .prev-release/<tag>/. Idempotent: an already
#   extracted tag is left alone, so the steady-state local loop does no
#   work at all.
_materialise() {
  local _tag="${1:?BUG: _materialise expects a tag}"
  local _dest="${PREV_RELEASE_DIR}/${_tag}"

  if [[ -f "${_dest}/.version" ]]; then
    return 0
  fi

  rm -rf "${_dest}"
  mkdir -p "${_dest}"
  # Piped into tar rather than `git archive -o`: no intermediate archive to
  # clean up, and it works the same for a worktree checkout.
  git -C "${REPO_ROOT}" archive --format=tar "${_tag}" | tar -x -C "${_dest}"
  [[ -f "${_dest}/.version" ]] \
    || _die "extracted ${_tag} has no .version -- not a release tree"
  _note "materialised ${_tag}"
}

# _prune <keep...>
#   Drop cached trees that are no longer in the window, so the cache can
#   never serve a tag the resolver stopped naming.
_prune() {
  local -a _keep=("$@")
  local _entry _base _k _hit
  for _entry in "${PREV_RELEASE_DIR}"/*; do
    [[ -d "${_entry}" ]] || continue
    _base="$(basename "${_entry}")"
    _hit=0
    for _k in "${_keep[@]}"; do
      [[ "${_base}" == "${_k}" ]] && _hit=1
    done
    (( _hit == 1 )) || rm -rf "${_entry}"
  done
}

# _window_tags
#   The window's tags, newest first. Sliced in-shell rather than piped
#   through `head`: a reader that leaves after N lines strands the writer
#   with SIGPIPE, and `pipefail` promotes that 141 to the pipeline's status.
_window_tags() {
  local -a _all=()
  mapfile -t _all < <(_stable_release_tags)
  # printf with no operands after the format still prints one empty line,
  # which mapfile would read back as a one-element list of "".
  if (( ${#_all[@]} == 0 )); then
    return 0
  fi
  printf '%s\n' "${_all[@]:0:PREV_RELEASE_WINDOW}"
}

main() {
  local -a _tags=()
  mapfile -t _tags < <(_window_tags)

  if (( ${#_tags[@]} < PREV_RELEASE_WINDOW )); then
    _fetch_release_tags
    mapfile -t _tags < <(_window_tags)
  fi

  # Fail rather than silently covering less. A spec that quietly shrinks to
  # zero cases is the failure mode this whole file exists to prevent.
  if (( ${#_tags[@]} < PREV_RELEASE_WINDOW )); then
    _die "need ${PREV_RELEASE_WINDOW} stable release tags, found ${#_tags[@]}. Fetch them: git fetch --tags ${BASE_UPSTREAM_REMOTE}"
  fi

  mkdir -p "${PREV_RELEASE_DIR}"
  local _tag
  for _tag in "${_tags[@]}"; do
    _materialise "${_tag}"
  done
  _prune "${_tags[@]}"

  printf '%s\n' "${_tags[@]}" > "${PREV_RELEASE_DIR}/tags.txt"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
