#!/usr/bin/env bash
# prepare-prev-release.sh - materialise every supported released tree for
# the released-caller compatibility spec (test/bats/integration/prev_release_upgrade_spec.bats).
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
# One `git ls-remote` per run: which releases the window owes is a fact
# about upstream, not about the tags this checkout happens to hold
# (base#1729). Each owed tag the checkout lacks is fetched once, per tag,
# per checkout, and then cached. Nothing here is a hand-written fixture -- what the spec runs
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

# The oldest release the compatibility spec covers (base#1055, base#1041).
#
# The window is every stable release from this floor up to, but not
# including, the tree under test -- not a count of the newest tags. A
# count drops the floor once enough releases follow it, and keeps
# pre-floor releases while the floor is not yet tagged. Excluding the
# tree's own version is what stops the window resolving to the tree under
# test and asserting nothing. Before any release past the floor exists the
# window is empty, and that is the rule's answer (base#1055: "binds
# nothing until v0.44.0").
# tool-pin: ignore -- this repo's own support floor, not a third-party
# version.
PREV_RELEASE_FLOOR="v0.43.0"
readonly PREV_RELEASE_FLOOR

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
#   store carries no stable release tag at all -- i.e. on a fresh shallow
#   CI checkout, once.
_fetch_release_tags() {
  _note "no stable release tags locally; fetching from ${BASE_UPSTREAM_REMOTE}"
  # --depth 1: the archived tree is all we want, never the history behind
  # it. Failure is not fatal here -- the caller re-checks and reports the
  # real problem (no stable release tags) with the tags it actually has.
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

# _triple <vX.Y.Z[-pre]>
#   Print "X Y Z". Releases are compared on this triple, never with
#   `sort -V` or a string compare: `sort -V` ranks v0.43.0 above
#   v0.43.0-rc5, the opposite of SemVer precedence.
_triple() {
  local _v="${1:?BUG: _triple expects a version}"
  [[ "${_v}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-.*)?$ ]] \
    || _die "BUG: '${_v}' is not a vX.Y.Z version"
  printf '%d %d %d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# _owed <tree>
#   Filter stable tags on stdin down to the ones the window owes a tree at
#   version <tree>: PREV_RELEASE_FLOOR <= tag < tree, in input order. A
#   pre-release tree vX.Y.Z-rcN sits below vX.Y.Z, so vX.Y.Z is excluded
#   with the tree's own tag.
_owed() {
  local _tree="${1:?BUG: _owed expects the tree version}"
  local -a _f _t _v
  read -r -a _f <<< "$(_triple "${PREV_RELEASE_FLOOR}")"
  read -r -a _t <<< "$(_triple "${_tree}")"
  # The floor is a 0.x rule; a 1.x tree needs its own.
  (( _t[0] == 0 )) || _die "BUG: tree ${_tree} is past 0.x; the ${PREV_RELEASE_FLOOR} floor does not cover it"
  local _tag
  while IFS= read -r _tag; do
    read -r -a _v <<< "$(_triple "${_tag}")"
    (( _v[0] == 0 )) || continue
    (( _v[1] > _f[1] || (_v[1] == _f[1] && _v[2] >= _f[2]) )) || continue
    (( _v[1] < _t[1] || (_v[1] == _t[1] && _v[2] < _t[2]) )) || continue
    printf '%s\n' "${_tag}"
  done
}

# _window_tags
#   The window's tags, newest first: every stable release the tree under
#   test owes (see PREV_RELEASE_FLOOR).
_window_tags() {
  local _tree
  _tree="$(tr -d '[:space:]' < "${REPO_ROOT}/.version")"
  _stable_release_tags | _owed "${_tree}"
}

# _upstream_stable_tags
#   Print the stable release tags upstream lists. The owed set is a fact
#   about upstream: tags an earlier fetch left in this checkout say nothing
#   about releases cut since (base#1729).
_upstream_stable_tags() {
  local _sha _ref _tag
  while IFS=$'\t' read -r _sha _ref; do
    _tag="${_ref#refs/tags/}"
    [[ "${_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    printf '%s\n' "${_tag}"
  done < <(git -C "${REPO_ROOT}" ls-remote --tags --refs \
    "${BASE_UPSTREAM_REMOTE}" 'v*' 2>/dev/null)
}

# _fetch_owed_tags
#   Fetch every tag upstream owes the tree under test that the local
#   object store does not hold yet, one explicit refspec per tag.
_fetch_owed_tags() {
  local _tree _tag
  _tree="$(tr -d '[:space:]' < "${REPO_ROOT}/.version")"
  local -a _local=() _missing=()
  mapfile -t _local < <(_stable_release_tags)
  while IFS= read -r _tag; do
    [[ " ${_local[*]} " == *" ${_tag} "* ]] \
      || _missing+=("refs/tags/${_tag}:refs/tags/${_tag}")
  done < <(_upstream_stable_tags | _owed "${_tree}")
  (( ${#_missing[@]} > 0 )) || return 0
  _note "fetching owed release tags from ${BASE_UPSTREAM_REMOTE}"
  git -C "${REPO_ROOT}" fetch --quiet --depth 1 --no-recurse-submodules \
    "${BASE_UPSTREAM_REMOTE}" "${_missing[@]}" 2>/dev/null \
    || _note "owed tag fetch failed (offline?); continuing with local tags"
}

main() {
  _fetch_owed_tags

  local -a _stable=()
  mapfile -t _stable < <(_stable_release_tags)

  if (( ${#_stable[@]} == 0 )); then
    _fetch_release_tags
    mapfile -t _stable < <(_stable_release_tags)
  fi

  # Fail rather than silently covering less. With no stable tag at all the
  # window below would be empty for want of tags, not because the rule
  # owes nothing -- the shape this whole file exists to prevent.
  if (( ${#_stable[@]} == 0 )); then
    _die "no stable release tags found. Fetch them: git fetch --tags ${BASE_UPSTREAM_REMOTE}"
  fi

  local -a _tags=()
  mapfile -t _tags < <(_window_tags)

  mkdir -p "${PREV_RELEASE_DIR}"
  local _tag
  for _tag in "${_tags[@]}"; do
    _materialise "${_tag}"
  done
  _prune "${_tags[@]}"

  # printf with no operands still prints one empty line, which the spec
  # would read back as a one-line window of "".
  if (( ${#_tags[@]} == 0 )); then
    : > "${PREV_RELEASE_DIR}/tags.txt"
    _note "no release owed below $(tr -d '[:space:]' < "${REPO_ROOT}/.version") since ${PREV_RELEASE_FLOOR} (base#1055)"
    return 0
  fi
  printf '%s\n' "${_tags[@]}" > "${PREV_RELEASE_DIR}/tags.txt"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
