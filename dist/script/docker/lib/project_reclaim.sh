#!/usr/bin/env bash
#
# project_reclaim.sh - collect the compose artifacts THIS project left
# behind, and nothing else.
#
# The development host is shared. It carries a self-hosted runner tree for
# a sibling org, a GitLab runner container, ollama, buildx builder state
# and GPU workloads, and the worst outcome available here is deleting one
# of those. That is worse than leaving litter, so every removal below rests
# on a proof of ownership rather than on an artifact looking unused, and
# the default on anything the rules cannot place is to LEAVE IT ALONE.
#
# The proof. base's self-test names its compose project after the ABSOLUTE
# PATH of the checkout it runs in -- `base-<sha256(path)[0:12]>`, see
# _reclaim_project_for_path -- and compose stamps that name onto every
# artifact it creates as `com.docker.compose.project`. So an artifact
# carrying `base-<12hex>` where that hash matches NO path in the live
# worktree list belongs to a checkout that no longer exists. Nothing
# another tenant runs mints a name of that shape, which is what bounds the
# blast radius: this cannot reach a GitLab runner network, an ollama
# volume, or a buildx cache mount, because none of them carry a project
# label of this form.
#
# The daemon-wide `docker {network,image,builder} prune` in the sibling
# prune.sh is deliberately untouched by all of this. It remains the
# explicit bigger hammer for an operator who has judged the machine; this
# file is the collector that needs no such judgement to run, which is why
# it can be wired to fire by itself.
#
# WHAT IT DOES NOT COLLECT, and why each is deliberate.
#
#   - Containers. A container ATTACHED to a project is instead the reason
#     the whole project is spared: a container is the one artifact that can
#     still be running, still be holding a post-mortem, or still be a
#     concurrent run's. A stopped container therefore pins its project's
#     network here forever, which is a residue the daemon-wide prune exists
#     to clear.
#   - Images. The tooling image is content-hash tagged on purpose, so ONE
#     image is shared by every checkout whose Dockerfile.test-tools hashes
#     alike -- measured on the host: the tag the current tree resolves to
#     carries the project label of a DIFFERENT live worktree, the one that
#     happened to build it first. A project label on an image therefore
#     names its builder and not its users, and collecting on it would
#     delete an image live checkouts still resolve. Images are retired by
#     content instead, in _reclaim_tool_tags.
#   - Volumes. A volume holds state, and neither its age nor the
#     disappearance of the path that created it is evidence that the state
#     is disposable -- the same rule script/ci/reclaim.sh applies to its
#     own age-based layer. base's compose.yaml declares no named volumes,
#     so there is nothing here to leave behind today; the day it does, this
#     comment is the decision to revisit rather than a gap to discover.
#
# WHAT IT CANNOT PROVE, stated because a guard whose limits are implied
# gets believed past them. sha256 is one-way, so an artifact's hash cannot
# be turned back into a path and asked whether it exists; liveness can only
# be decided by MEMBERSHIP in a set of paths this process enumerated. Two
# kinds of live checkout are therefore outside that set:
#
#   - a throwaway copy of the tree (an agent mutation-testing a guard),
#     which is a real directory in nobody's worktree list;
#   - a separate CLONE of base elsewhere on the host, whose worktrees this
#     repo's git knows nothing about.
#
# Both are covered by the two guards that do not depend on enumeration: the
# checkout this invocation is running in is ALWAYS live (a copy collecting
# its own project mid-run is the one case enumeration would get wrong every
# time), and nothing created inside the grace window is a candidate at all.
# The grace window has to exceed the longest run that can be in flight; the
# longest phase this repo documents is the 8-12 minute kcov pass, so the
# 6h default clears it by roughly thirty times and still collects the same
# day's litter. Raising it only ever removes less.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_PROJECT_RECLAIM_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_PROJECT_RECLAIM_SOURCED=1

# log.sh carries _log_* / _dry_run_cmd and is idempotent via its own
# guard, so pulling it in directly keeps this file usable by a caller that
# sources it without the full _lib.sh (the specs do exactly that).
_project_reclaim_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_project_reclaim_dir}/log.sh"
unset _project_reclaim_dir

# The compose project name base's self-test mints, split into its two
# halves so the producer and the collector cannot drift apart.
readonly _RECLAIM_PROJECT_PREFIX='base'
readonly _RECLAIM_PROJECT_LABEL='com.docker.compose.project'

# The tooling image. Repository name and the Dockerfile whose CONTENT
# (never its path) the tag is derived from.
readonly _RECLAIM_TOOL_REPO='test-tools'
readonly _RECLAIM_TOOL_DOCKERFILE_REL='dockerfile/Dockerfile.test-tools'

# Defaults. Both are overridable; neither is a number a reader has to go
# find in a script to understand what the collector kept.
readonly _RECLAIM_DEFAULT_GRACE='6h'
readonly _RECLAIM_TOOL_KEEP_FLOOR=3

# ── the two derivations, each with exactly one producer ──────────────────

# _reclaim_project_for_path <path>
#
# Prints `base-<sha256(path)[0:12]>`; exits non-zero, printing nothing,
# when no usable digest can be produced.
#
# THE producer of the compose project name. script/test/test.sh's
# _compute_compose_project_name delegates here rather than hashing again:
# the collector's whole proof is that it computes the same name the
# producer did, and two implementations of one rule is how they come to
# disagree.
#
# Keyed to the PATH, not the commit: two worktrees are routinely branched
# from one commit, so a commit-keyed name would collide in exactly the
# concurrent case the name exists to separate. Hashing also satisfies
# compose's `[a-z0-9][a-z0-9_-]*` grammar by construction for ANY input
# path, which sanitising the path text cannot.
#
# A short digest -- sha256sum or cut missing from PATH -- would degrade to
# the bare prefix, a name EVERY checkout resolves. That is refused rather
# than returned, in both directions: the producer must not hand compose a
# colliding name, and the collector must not be handed a pattern that
# matches everything.
_reclaim_project_for_path() {
  local _root="${1:?_reclaim_project_for_path requires <path>}"
  local _hash
  _hash="$(printf '%s' "${_root}" | sha256sum 2>/dev/null | cut -d' ' -f1)" || _hash=""
  [[ "${_hash}" =~ ^[0-9a-f]{12} ]] || return 1
  printf '%s-%s\n' "${_RECLAIM_PROJECT_PREFIX}" "${_hash:0:12}"
}

# _reclaim_is_project_name <name>
#
# Whether <name> is a name THIS derivation could have produced. Everything
# else -- an empty label, `gitlab_runner`, a hand-set COMPOSE_PROJECT_NAME
# like `base-release`, a CI run key -- fails here and is thereby refused,
# because a collector that cannot say which rule minted a name has no
# proof of ownership to act on.
_reclaim_is_project_name() {
  [[ "${1-}" =~ ^base-[0-9a-f]{12}$ ]]
}

# _reclaim_tool_dockerfile_hash <dockerfile>
#
# Prints the full content digest of the tooling Dockerfile, or nothing at
# all when the file is absent. Redirected stdin, never `sha256sum <file>`,
# so the PATH never enters the digest: the same content in two checkouts
# must resolve to ONE tag, which is the property that makes the tag
# shareable and the reason images are not collected by project label.
_reclaim_tool_dockerfile_hash() {
  local _dockerfile="${1:?_reclaim_tool_dockerfile_hash requires <dockerfile>}"
  [[ -f "${_dockerfile}" ]] || return 0
  sha256sum < "${_dockerfile}" 2>/dev/null | cut -d' ' -f1
}

# _reclaim_tool_tag_for_path <repo_root>
#
# Prints `test-tools:<12hex>` for the checkout at <repo_root>; exits
# non-zero, printing nothing, when that checkout has no tooling Dockerfile
# or no usable digest. THE producer of the tooling tag, for the same
# reason as above -- script/test/test.sh's _resolve_test_tools_image
# delegates here.
_reclaim_tool_tag_for_path() {
  local _root="${1:?_reclaim_tool_tag_for_path requires <repo_root>}"
  local _hash
  _hash="$(_reclaim_tool_dockerfile_hash "${_root%/}/${_RECLAIM_TOOL_DOCKERFILE_REL}")"
  [[ "${_hash}" =~ ^[0-9a-f]{12} ]] || return 1
  printf '%s:%s\n' "${_RECLAIM_TOOL_REPO}" "${_hash:0:12}"
}

# _reclaim_is_tool_tag <ref>
#
# Whether <ref> is a tag THIS derivation mints. `test-tools:local`, a
# registry-qualified `ghcr.io/<org>/test-tools:v0.43.0`, and any other
# repository are all refused: they are published or caller-pinned tags
# that nothing here produced, so nothing here retires them.
_reclaim_is_tool_tag() {
  [[ "${1-}" =~ ^test-tools:[0-9a-f]{12}$ ]]
}

# ── the live set ─────────────────────────────────────────────────────────

# _reclaim_live_paths <repo_root> <outvar-array>
#
# Fills <outvar-array> with every checkout that must be treated as alive,
# and returns non-zero when it cannot enumerate them.
#
# The set is <repo_root> itself plus `git worktree list --porcelain`, whose
# first record IS the main checkout -- so the main checkout needs no
# separate lookup and cannot be forgotten. <repo_root> is included
# unconditionally and first, before git is consulted at all: a throwaway
# copy of the tree is a live path in nobody's list, and the one checkout an
# invocation can prove is in use is the one it is running in.
#
# THE FAILURE DIRECTION IS THE WHOLE POINT. git missing, git failing, a
# broken gitdir, an empty listing -- each returns non-zero, and every
# caller turns that into an abort. Read the other way ("no live worktrees
# came back, so every project is an orphan") the same condition deletes the
# entire host's worth of artifacts, which is precisely the fail-open this
# collector must never have.
_reclaim_live_paths() {
  local _root="${1:?_reclaim_live_paths requires <repo_root>}"
  local -n _rlp_out="${2:?_reclaim_live_paths requires <outvar>}"
  _rlp_out=("${_root}")

  command -v git >/dev/null 2>&1 || return 1
  local _listing
  _listing="$(git -C "${_root}" worktree list --porcelain 2>/dev/null)" || return 1
  [[ -n "${_listing}" ]] || return 1

  local _line _path _seen=0
  while IFS= read -r _line; do
    [[ "${_line}" == "worktree "* ]] || continue
    _path="${_line#worktree }"
    [[ -n "${_path}" ]] || continue
    _rlp_out+=("${_path}")
    _seen=1
  done <<< "${_listing}"
  (( _seen == 1 )) || return 1
  return 0
}

# _reclaim_live_projects <repo_root> <outvar-array>
#
# The live paths mapped through the SAME producer compose was named by. A
# path whose digest cannot be computed aborts the whole enumeration rather
# than being dropped: a live checkout silently missing from this set is a
# live project silently eligible for deletion.
_reclaim_live_projects() {
  local _root="${1:?_reclaim_live_projects requires <repo_root>}"
  local -n _rlj_out="${2:?_reclaim_live_projects requires <outvar>}"
  local -a _paths=()
  _reclaim_live_paths "${_root}" _paths || return 1
  _rlj_out=()
  local _p _name
  for _p in "${_paths[@]}"; do
    _name="$(_reclaim_project_for_path "${_p}")" || return 1
    _rlj_out+=("${_name}")
  done
  return 0
}

# ── the docker surface, one place ────────────────────────────────────────
#
# Four reads and one removal per kind, so the whole daemon interaction is
# auditable at a glance. Every one of them tolerates a failure by yielding
# nothing: an artifact that vanished between listing and inspection is a
# concurrent teardown racing ours, which is normal, and an empty read makes
# the caller collect LESS rather than more.

_reclaim_docker_networks() {
  docker network ls --filter "label=${_RECLAIM_PROJECT_LABEL}" \
    --format "{{.ID}}|{{.Name}}|{{.Label \"${_RECLAIM_PROJECT_LABEL}\"}}" 2>/dev/null || true
}

_reclaim_docker_container_projects() {
  docker ps -a --format "{{.Label \"${_RECLAIM_PROJECT_LABEL}\"}}" 2>/dev/null || true
}

_reclaim_docker_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true
}

# _reclaim_created_epoch <kind> <id> -- creation time as a unix timestamp,
# empty when it cannot be read.
#
# `{{json .Created}}`, never the bare `{{.Created}}`, and the two are not
# interchangeable. On an IMAGE the field is already an RFC3339 string and
# both spellings work; on a NETWORK it is a Go time value, which the bare
# template renders as `2026-09-03 11:07:45.1237 +0800 CST` -- a form
# `date -d` rejects outright. The JSON spelling marshals both to RFC3339,
# so one rule reads both kinds. The bug that cost this its first real run
# read every network's age as unreadable; it failed in the safe direction
# (the orphan was spared rather than collected) which is exactly why it
# could go unnoticed, and why the specs pin the quoted shape.
_reclaim_created_epoch() {
  local _kind="${1:?}" _id="${2:?}" _created=""
  _created="$(docker "${_kind}" inspect --format '{{json .Created}}' "${_id}" 2>/dev/null)" \
    || return 0
  _created="${_created%\"}"
  _created="${_created#\"}"
  [[ -n "${_created}" ]] || return 0
  date -d "${_created}" +%s 2>/dev/null || true
}

# _reclaim_duration_seconds <duration> -- `6h` -> 21600; non-zero on
# anything else, which callers turn into an abort rather than a default.
_reclaim_duration_seconds() {
  local _d="${1-}"
  [[ "${_d}" =~ ^([0-9]+)([smhd])$ ]] || return 1
  local _n="${BASH_REMATCH[1]}" _u="${BASH_REMATCH[2]}"
  case "${_u}" in
    s) printf '%s' "${_n}" ;;
    m) printf '%s' "$(( _n * 60 ))" ;;
    h) printf '%s' "$(( _n * 3600 ))" ;;
    d) printf '%s' "$(( _n * 86400 ))" ;;
  esac
}

# _reclaim_in_list <needle> <haystack...>
_reclaim_in_list() {
  local _needle="${1}"; shift
  local _item
  for _item in "$@"; do
    [[ "${_item}" == "${_needle}" ]] && return 0
  done
  return 1
}

# ── the collector ────────────────────────────────────────────────────────

# _reclaim_orphan_projects <repo_root> [grace]
#
# Removes the network of every compose project that is provably dead:
# labelled `base-<12hex>`, matching no live checkout, carrying no
# container, and older than the grace window. Returns non-zero only when it
# refused to act at all (an unreadable worktree list, an unparseable grace)
# -- a network that could not be removed is reported and does not fail the
# sweep, since the next sweep collects it.
#
# EVERY INPUT IT CANNOT PLACE IS LEFT ALONE. An artifact with no project
# label, a label that is not `base-`-prefixed, a `base-` label whose suffix
# is not 12 hex digits, an artifact whose creation time cannot be read, a
# hash that cannot be computed, a worktree list that could not be read --
# none of them is a candidate. There is no branch below in which failing to
# recognise something leads to removing it, and there must never be one:
# the fail-open direction here is deleting an artifact whose owner cannot
# be established, and on a host shared with other tenants that is the worst
# outcome available.
_reclaim_orphan_projects() {
  local _root="${1:?_reclaim_orphan_projects requires <repo_root>}"
  local _grace="${2:-${BASE_RECLAIM_GRACE:-${_RECLAIM_DEFAULT_GRACE}}}"

  local -a _live=()
  if ! _reclaim_live_projects "${_root}" _live; then
    _log_err reclaim reclaim_worktrees_unreadable \
      "display=cannot enumerate the live worktrees of ${_root}; removing nothing (an unreadable list is not evidence that every project is dead)." \
      "root=${_root}"
    return 1
  fi

  local _grace_s
  if ! _grace_s="$(_reclaim_duration_seconds "${_grace}")"; then
    _log_err reclaim reclaim_bad_grace \
      "display=not a duration: ${_grace} (expected <N>s / <N>m / <N>h / <N>d); removing nothing." \
      "grace=${_grace}"
    return 1
  fi

  local -a _attached=()
  local _p
  while IFS= read -r _p; do
    if [[ -n "${_p}" ]]; then
      _attached+=("${_p}")
    fi
  done < <(_reclaim_docker_container_projects)

  local _now _cutoff
  _now="$(date +%s)"
  _cutoff=$(( _now - _grace_s ))

  # Two refusal counters, not one. "I do not recognise this label" and "I
  # could not read this artifact's age" are both refusals to delete, but
  # they say different things about the machine: the first is another
  # tenant's artifact and is expected every run, the second is an artifact
  # that vanished between the listing and the inspection -- a concurrent
  # run's teardown racing ours, which is normal, but is also the shape a
  # daemon problem would take. Reported as one number they cannot be told
  # apart.
  local _scanned=0 _kept_live=0 _kept_attached=0 _kept_young=0
  local _refused_label=0 _refused_age=0
  local -a _victims=()
  local _id _name _project _created
  while IFS='|' read -r _id _name _project; do
    [[ -n "${_id}" ]] || continue
    _scanned=$(( _scanned + 1 ))
    # Unrecognised name shape: no label, another tenant's project, a
    # hand-set project name. Not ours to reason about.
    if ! _reclaim_is_project_name "${_project}"; then
      _refused_label=$(( _refused_label + 1 ))
      continue
    fi
    if _reclaim_in_list "${_project}" "${_live[@]}"; then
      _kept_live=$(( _kept_live + 1 ))
      continue
    fi
    if _reclaim_in_list "${_project}" "${_attached[@]+"${_attached[@]}"}"; then
      _kept_attached=$(( _kept_attached + 1 ))
      continue
    fi
    _created="$(_reclaim_created_epoch network "${_id}")"
    # An unreadable creation time is not a young artifact and not an old
    # one; it is one more thing that cannot be placed.
    if [[ -z "${_created}" ]]; then
      _refused_age=$(( _refused_age + 1 ))
      continue
    fi
    if (( _created >= _cutoff )); then
      _kept_young=$(( _kept_young + 1 ))
      continue
    fi
    _victims+=("${_id}")
  done < <(_reclaim_docker_networks)

  _log_info reclaim reclaim_scan \
    "display=scoped reclaim: ${_scanned} labelled network(s); keeping ${_kept_live} live, ${_kept_attached} with a container attached, ${_kept_young} inside the ${_grace} grace window; left alone ${_refused_label} not mine and ${_refused_age} whose age could not be read." \
    "scanned=${_scanned}" "live=${_kept_live}" "attached=${_kept_attached}" \
    "young=${_kept_young}" "not_mine=${_refused_label}" "age_unreadable=${_refused_age}"

  if (( ${#_victims[@]} == 0 )); then
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == true ]]; then
    _log_info reclaim reclaim_orphan_dry_run \
      "display=would remove ${#_victims[@]} orphaned network(s): ${_victims[*]}" \
      "count=${#_victims[@]}"
    return 0
  fi

  _log_info reclaim reclaim_orphan_removed \
    "display=removing ${#_victims[@]} orphaned network(s) whose checkout no longer exists." \
    "count=${#_victims[@]}"
  local _v
  for _v in "${_victims[@]}"; do
    docker network rm "${_v}" >/dev/null 2>&1 || _log_warn reclaim reclaim_network_rm_failed \
      "display=could not remove network ${_v}; leaving it for the next sweep." "network=${_v}"
  done
  return 0
}

# ── tooling-tag retention ────────────────────────────────────────────────

# _reclaim_tool_tags_default_keep <repo_root>
#
# Prints N, the size of the recency window _reclaim_tool_tags keeps on top
# of the tags live checkouts resolve to.
#
# DERIVED, not chosen. Content-hash tagging guarantees unbounded growth, so
# something has to bound it, and the number that bounds it honestly is how
# many DISTINCT tooling images the checkouts on this host currently need --
# one per distinct Dockerfile.test-tools across the live worktrees. That is
# a measurement of the machine, not a constant, and it grows when the work
# on the machine grows.
#
# The floor of 3 covers the case the measurement cannot see: a single
# checkout resolves one tag, and a developer who switches to a branch and
# back would then pay a full tooling-image rebuild for the round trip. Three
# lets a branch, the branch before it and the trunk coexist.
#
# BASE_TOOL_TAGS_KEEP overrides both, so the number is never something a
# reader has to go dig out of a script.
_reclaim_tool_tags_default_keep() {
  local _root="${1:?_reclaim_tool_tags_default_keep requires <repo_root>}"
  if [[ -n "${BASE_TOOL_TAGS_KEEP:-}" ]]; then
    printf '%s\n' "${BASE_TOOL_TAGS_KEEP}"
    return 0
  fi
  local -a _paths=()
  if ! _reclaim_live_paths "${_root}" _paths; then
    printf '%s\n' "${_RECLAIM_TOOL_KEEP_FLOOR}"
    return 0
  fi
  local -a _tags=()
  local _p _tag
  for _p in "${_paths[@]}"; do
    _tag="$(_reclaim_tool_tag_for_path "${_p}")" || continue
    _reclaim_in_list "${_tag}" "${_tags[@]+"${_tags[@]}"}" || _tags+=("${_tag}")
  done
  if (( ${#_tags[@]} > _RECLAIM_TOOL_KEEP_FLOOR )); then
    printf '%s\n' "${#_tags[@]}"
  else
    printf '%s\n' "${_RECLAIM_TOOL_KEEP_FLOOR}"
  fi
}

# _reclaim_tool_tags <repo_root> [keep]
#
# Retires local `test-tools:<12hex>` images down to a bounded set: the tag
# the current tree resolves to, every tag a LIVE checkout resolves to, and
# the <keep> most recently created besides. Everything else is content the
# machine can rebuild and no checkout on it asks for.
#
# Keeping the live-resolved tags is the same ownership standard as the
# project rule -- a live checkout needing an image is a proof, where "it
# looks unused" is not -- and it is why deleting one of these is never
# merely a slow rebuild for somebody. The recency window on top of it is
# the hedge for the tag whose checkout has moved on but which a branch
# switch would ask for again in a minute.
#
# ANYTHING ELSE IS LEFT ALONE, by name: an image in another repository, a
# registry-qualified tag, `test-tools:local`, a tag whose suffix is not 12
# hex digits, and an image whose creation time cannot be read. An
# unreadable worktree list aborts before a single removal, for the same
# reason it does in the project rule.
_reclaim_tool_tags() {
  local _root="${1:?_reclaim_tool_tags requires <repo_root>}"

  local -a _paths=()
  if ! _reclaim_live_paths "${_root}" _paths; then
    _log_err reclaim reclaim_worktrees_unreadable \
      "display=cannot enumerate the live worktrees of ${_root}; retiring no tooling tags." \
      "root=${_root}"
    return 1
  fi

  local _keep="${2-}"
  if [[ -z "${_keep}" ]]; then
    _keep="$(_reclaim_tool_tags_default_keep "${_root}")"
  fi
  if [[ ! "${_keep}" =~ ^[0-9]+$ ]]; then
    _log_err reclaim reclaim_bad_keep \
      "display=not a count: ${_keep}; retiring no tooling tags." "keep=${_keep}"
    return 1
  fi

  # The tags no rebuild should ever be paid for: this tree's, and every
  # live checkout's.
  local -a _pinned=()
  local _p _tag
  for _p in "${_paths[@]}"; do
    _tag="$(_reclaim_tool_tag_for_path "${_p}")" || continue
    _reclaim_in_list "${_tag}" "${_pinned[@]+"${_pinned[@]}"}" || _pinned+=("${_tag}")
  done

  # Candidates, newest first. An image whose creation time cannot be read
  # is dropped from the ordering entirely rather than sorted as if it were
  # ancient -- unknown age must not become a reason to delete.
  local -a _ordered=()
  local _ref _created
  while IFS=$'\t' read -r _created _ref; do
    if [[ -n "${_ref}" ]]; then
      _ordered+=("${_ref}")
    fi
  done < <(
    while IFS= read -r _ref; do
      [[ -n "${_ref}" ]] || continue
      _reclaim_is_tool_tag "${_ref}" || continue
      _created="$(_reclaim_created_epoch image "${_ref}")"
      [[ -n "${_created}" ]] || continue
      printf '%s\t%s\n' "${_created}" "${_ref}"
    done < <(_reclaim_docker_images) | sort -rn
  )

  local -a _victims=()
  local _i=0 _pinned_present=0
  for _ref in "${_ordered[@]+"${_ordered[@]}"}"; do
    if _reclaim_in_list "${_ref}" "${_pinned[@]+"${_pinned[@]}"}"; then
      _pinned_present=$(( _pinned_present + 1 ))
      continue
    fi
    if (( _i < _keep )); then
      _i=$(( _i + 1 ))
      continue
    fi
    _victims+=("${_ref}")
  done

  # `present`, not the size of the pinned SET: the live checkouts resolve
  # more tags than the host has ever built, and reporting the set size
  # against a smaller image count reads as an arithmetic error.
  _log_info reclaim reclaim_tool_tags_scan \
    "display=tooling tags: ${#_ordered[@]} derived tag(s) present; keeping ${_pinned_present} a live checkout resolves plus the ${_keep} most recent; retiring ${#_victims[@]}." \
    "derived=${#_ordered[@]}" "pinned_present=${_pinned_present}" \
    "pinned_resolvable=${#_pinned[@]}" "keep=${_keep}" "retiring=${#_victims[@]}"

  if (( ${#_victims[@]} == 0 )); then
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == true ]]; then
    _log_info reclaim reclaim_tool_tags_dry_run \
      "display=would retire ${#_victims[@]} tooling tag(s): ${_victims[*]}" \
      "count=${#_victims[@]}"
    return 0
  fi

  _log_info reclaim reclaim_tool_tag_retired \
    "display=retiring ${#_victims[@]} tooling tag(s) no live checkout resolves." \
    "count=${#_victims[@]}"
  local _v
  for _v in "${_victims[@]}"; do
    docker rmi "${_v}" >/dev/null 2>&1 || _log_warn reclaim reclaim_tool_tag_rm_failed \
      "display=could not retire ${_v} (in use, or already gone); leaving it." "image=${_v}"
  done
  return 0
}
