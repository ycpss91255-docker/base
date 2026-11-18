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
# test and asserting nothing. Until v0.43.0 is tagged the window is empty,
# and that is the rule's answer; it holds v0.43.0 itself as soon as that
# tag exists below the tree.
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

# _is_stable_tag <tag>
#   Succeed for a stable release tag vX.Y.Z; RC / pre-release tags fail.
_is_stable_tag() {
  [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
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
    _is_stable_tag "${_tag}" || continue
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

# _parse_version <vX.Y.Z[-pre]> <array-name>
#   Set <array-name> to (X Y Z) and succeed, or fail on anything that is
#   not vX.Y.Z[-pre]. Releases are compared on this triple, never with
#   `sort -V` or a string compare: `sort -V` ranks v0.43.0 above
#   v0.43.0-rc5, the opposite of SemVer precedence. It writes through a
#   nameref and never prints, so a caller can parse in its own shell and
#   act on the failure there, not in a `$(...)` subshell it cannot leave.
_parse_version() {
  local _pv_in="${1:?BUG: _parse_version expects a version}"
  local -n _pv_out="${2:?BUG: _parse_version expects an array name}"
  [[ "${_pv_in}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-.*)?$ ]] || return 1
  _pv_out=("$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))")
}

# The parsed floor and tree under test, set once by _load_versions in
# main's own shell before any pipeline runs.
_FLOOR=()
_TREE=()
_TREE_VERSION=""

# _load_versions
#   Read the tree version from .version and parse it and the floor. A tree
#   that is not vX.Y.Z, or one past 0.x (the floor is a 0.x rule), is fatal
#   HERE: main calls this directly, so _die ends the run before a window is
#   resolved, rather than inside a pipeline whose exit the run never sees.
_load_versions() {
  _TREE_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/.version")"
  _parse_version "${PREV_RELEASE_FLOOR}" _FLOOR \
    || _die "BUG: floor '${PREV_RELEASE_FLOOR}' is not a vX.Y.Z version"
  _parse_version "${_TREE_VERSION}" _TREE \
    || _die "BUG: '${_TREE_VERSION}' is not a vX.Y.Z version"
  (( _TREE[0] == 0 )) \
    || _die "BUG: tree ${_TREE_VERSION} is past 0.x; the ${PREV_RELEASE_FLOOR} floor does not cover it"
}

# _owed
#   Filter stable tags on stdin down to the ones the window owes the tree
#   under test: PREV_RELEASE_FLOOR <= tag < tree, in input order. A
#   pre-release tree vX.Y.Z-rcN sits below vX.Y.Z, so vX.Y.Z is excluded
#   with the tree's own tag. Needs _load_versions to have run; it has no
#   refusal of its own, since it runs inside pipelines.
_owed() {
  local _tag
  local -a _v=()
  while IFS= read -r _tag; do
    _parse_version "${_tag}" _v || continue
    (( _v[0] == 0 )) || continue
    (( _v[1] > _FLOOR[1] || (_v[1] == _FLOOR[1] && _v[2] >= _FLOOR[2]) )) || continue
    (( _v[1] < _TREE[1] || (_v[1] == _TREE[1] && _v[2] < _TREE[2]) )) || continue
    printf '%s\n' "${_tag}"
  done
}

# _has_tag <tag> <tag...>
#   Succeed when <tag> is one of the remaining arguments.
_has_tag() {
  local _want="${1:?BUG: _has_tag expects a tag}" _t
  shift
  for _t in "$@"; do
    [[ "${_t}" == "${_want}" ]] && return 0
  done
  return 1
}

# _window_tags
#   The window's tags, newest first: every stable release the tree under
#   test owes (see PREV_RELEASE_FLOOR).
_window_tags() {
  _stable_release_tags | _owed
}

# _upstream_stable_tags
#   Print the stable release tags upstream lists. The owed set is a fact
#   about upstream: tags an earlier fetch left in this checkout say nothing
#   about releases cut since (base#1729).
#   Returns 1 when upstream cannot be listed, so an unreachable upstream
#   is never read as "nothing owed".
_upstream_stable_tags() {
  local _listing _sha _ref _tag
  _listing="$(git -C "${REPO_ROOT}" ls-remote --tags --refs \
    "${BASE_UPSTREAM_REMOTE}" 'v*' 2>/dev/null)" || return 1
  while IFS=$'\t' read -r _sha _ref; do
    _tag="${_ref#refs/tags/}"
    _is_stable_tag "${_tag}" || continue
    printf '%s\n' "${_tag}"
  done <<< "${_listing}"
}

# _check_offline_minimum
#   With upstream unreachable the owed set cannot be read, so the window is
#   DEGRADED to the local tags. It must still hold the minimum the tree
#   alone implies: v0.m.0 for every floor minor <= m < tree minor. Each one
#   missing is fatal and named.
_check_offline_minimum() {
  local -a _local=() _missing=()
  local _m _tag
  _note "upstream ${BASE_UPSTREAM_REMOTE} unreachable; window degraded to local tags"
  mapfile -t _local < <(_stable_release_tags)
  for (( _m = _FLOOR[1]; _m < _TREE[1]; _m++ )); do
    _tag="v0.${_m}.0"
    _has_tag "${_tag}" "${_local[@]}" || _missing+=("${_tag}")
  done
  (( ${#_missing[@]} == 0 )) \
    || _die "degraded (upstream unreachable): window lacks ${_missing[*]}"
}

# _fetch_owed_tags
#   Fetch every tag upstream owes the tree under test that the local
#   object store does not hold yet, one explicit refspec per tag. An owed
#   tag still missing afterwards is fatal: the window would silently cover
#   less than the rule owes.
_fetch_owed_tags() {
  local _tag
  local -a _local=() _owed_tags=() _missing=() _still=()
  local _upstream
  if ! _upstream="$(_upstream_stable_tags)"; then
    _check_offline_minimum
    return 0
  fi
  # An upstream that answers with no stable release is a wrong remote or a
  # broken listing, not one that owes nothing: reading it as empty would
  # hand the window back to the local tags.
  [[ -n "${_upstream}" ]] \
    || _die "upstream lists no stable release tags (${BASE_UPSTREAM_REMOTE})"
  mapfile -t _local < <(_stable_release_tags)
  mapfile -t _owed_tags < <(printf '%s\n' "${_upstream}" | _owed)
  for _tag in "${_owed_tags[@]}"; do
    _has_tag "${_tag}" "${_local[@]}" \
      || _missing+=("refs/tags/${_tag}:refs/tags/${_tag}")
  done
  (( ${#_missing[@]} > 0 )) || return 0
  _note "fetching owed release tags from ${BASE_UPSTREAM_REMOTE}"
  git -C "${REPO_ROOT}" fetch --quiet --depth 1 --no-recurse-submodules \
    "${BASE_UPSTREAM_REMOTE}" "${_missing[@]}" 2>/dev/null \
    || _note "owed tag fetch failed (offline?)"
  mapfile -t _local < <(_stable_release_tags)
  for _tag in "${_owed_tags[@]}"; do
    _has_tag "${_tag}" "${_local[@]}" || _still+=("${_tag}")
  done
  (( ${#_still[@]} == 0 )) \
    || _die "owed release tags missing after fetch: ${_still[*]}"
}

main() {
  _load_versions
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
    _note "no release owed below ${_TREE_VERSION} since ${PREV_RELEASE_FLOOR} (base#1055)"
    return 0
  fi
  printf '%s\n' "${_tags[@]}" > "${PREV_RELEASE_DIR}/tags.txt"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
