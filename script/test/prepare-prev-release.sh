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
# is byte-for-byte what was released. With upstream unreachable the run
# fails: no rule built from local tags or the tree's version is the owed
# set, so there is no offline window that can be proven complete.

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

# _triple_lt <a-array-name> <b-array-name>
#   Succeed when triple a sorts strictly below triple b, comparing X, then
#   Y, then Z. The one ordering every window decision uses.
_triple_lt() {
  local -n _tl_a="${1:?BUG: _triple_lt expects an array name}"
  local -n _tl_b="${2:?BUG: _triple_lt expects an array name}"
  local _tl_i
  for _tl_i in 0 1 2; do
    (( _tl_a[_tl_i] == _tl_b[_tl_i] )) && continue
    return "$(( _tl_a[_tl_i] < _tl_b[_tl_i] ? 0 : 1 ))"
  done
  return 1
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

# _owed_from <in-array-name> <out-array-name>
#   Set <out-array-name> to the tags of <in-array-name> the window owes the
#   tree under test: PREV_RELEASE_FLOOR <= tag < tree on the (X Y Z)
#   triple, newest first. A pre-release tree vX.Y.Z-rcN sits below vX.Y.Z,
#   so vX.Y.Z is excluded with the tree's own tag. The major takes part in
#   the compare, so a v1.x tag never sits below a 0.x tree. Needs _load_versions to
#   have run. Arrays go in and out by nameref, so this never runs inside a
#   `$(...)`, `<(...)` or pipeline: nothing on the path to tags.txt may
#   decide anything in a subshell whose exit the run never sees.
_owed_from() {
  local -n _of_in="${1:?BUG: _owed_from expects an input array name}"
  local -n _of_out="${2:?BUG: _owed_from expects an output array name}"
  local _of_tag _of_i _of_j _of_swap
  local -a _of_v=() _of_w=()
  _of_out=()
  for _of_tag in "${_of_in[@]}"; do
    _parse_version "${_of_tag}" _of_v || continue
    _triple_lt _of_v _FLOOR && continue
    _triple_lt _of_v _TREE || continue
    _of_out+=("${_of_tag}")
  done
  # Newest first by triple. Insertion sort: the owed set is a handful of
  # tags, and the order must not lean on `sort -V` (see _parse_version).
  for (( _of_i = 1; _of_i < ${#_of_out[@]}; _of_i++ )); do
    for (( _of_j = _of_i; _of_j > 0; _of_j-- )); do
      _parse_version "${_of_out[_of_j-1]}" _of_v
      _parse_version "${_of_out[_of_j]}" _of_w
      _triple_lt _of_v _of_w || break
      _of_swap="${_of_out[_of_j-1]}"
      _of_out[_of_j-1]="${_of_out[_of_j]}"
      _of_out[_of_j]="${_of_swap}"
    done
  done
}

# _upstream_stable_tags <out-array-name>
#   Set <out-array-name> to the stable release tags upstream lists. The
#   owed set is a fact about upstream: tags this checkout happens to hold
#   say nothing about releases cut since, nor whether a local tag was ever
#   released (base#1729). Returns 1 when upstream cannot be listed; the
#   caller refuses in its own shell.
_upstream_stable_tags() {
  local -n _us_out="${1:?BUG: _upstream_stable_tags expects an array name}"
  local _us_listing _us_sha _us_ref _us_tag
  _us_out=()
  _us_listing="$(git -C "${REPO_ROOT}" ls-remote --tags --refs \
    "${BASE_UPSTREAM_REMOTE}" 'v*' 2>/dev/null)" || return 1
  while IFS=$'\t' read -r _us_sha _us_ref; do
    _us_tag="${_us_ref#refs/tags/}"
    _is_stable_tag "${_us_tag}" || continue
    _us_out+=("${_us_tag}")
  done <<< "${_us_listing}"
}

# _has_local_tag <tag>
#   Succeed when the local object store holds <tag> as a commit.
_has_local_tag() {
  git -C "${REPO_ROOT}" rev-parse --verify -q \
    "refs/tags/${1:?BUG: _has_local_tag expects a tag}^{commit}" >/dev/null 2>&1
}

main() {
  _load_versions

  # Every refusal below runs here, in main's own shell: a _die inside a
  # `$(...)` or pipeline would end only that subshell, and the run would go
  # on to write a window that covers less than the rule owes.
  local -a _upstream=() _tags=() _refspecs=() _still=()
  _upstream_stable_tags _upstream \
    || _die "cannot list upstream release tags (${BASE_UPSTREAM_REMOTE}); the window cannot be proven complete"
  # An upstream that answers with no stable release is a wrong remote or a
  # broken listing, not one that owes nothing.
  (( ${#_upstream[@]} > 0 )) \
    || _die "upstream lists no stable release tags (${BASE_UPSTREAM_REMOTE})"

  _owed_from _upstream _tags

  local _tag
  for _tag in "${_tags[@]}"; do
    _has_local_tag "${_tag}" || _refspecs+=("refs/tags/${_tag}:refs/tags/${_tag}")
  done
  if (( ${#_refspecs[@]} > 0 )); then
    _note "fetching owed release tags from ${BASE_UPSTREAM_REMOTE}"
    # --depth 1: the archived tree is all we want, never the history
    # behind it. A failed fetch is reported by the check below, by tag.
    git -C "${REPO_ROOT}" fetch --quiet --depth 1 --no-recurse-submodules \
      "${BASE_UPSTREAM_REMOTE}" "${_refspecs[@]}" 2>/dev/null \
      || _note "owed tag fetch failed"
  fi
  for _tag in "${_tags[@]}"; do
    _has_local_tag "${_tag}" || _still+=("${_tag}")
  done
  (( ${#_still[@]} == 0 )) \
    || _die "owed release tags missing after fetch: ${_still[*]}"

  mkdir -p "${PREV_RELEASE_DIR}"
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
