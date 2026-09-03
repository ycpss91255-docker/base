#!/usr/bin/env bash
#
# project_reclaim.sh - collect the compose artifacts a base checkout that
# no longer exists left behind, and nothing else.
#
# The development host is shared. It carries a self-hosted runner tree for
# a sibling org, a GitLab runner container, ollama, buildx builder state
# and GPU workloads, and the worst outcome available here is deleting one
# of those. That is worse than leaving litter, so every removal below rests
# on a proof of ownership rather than on an artifact looking unused, and
# the default on anything the rules cannot place is to LEAVE IT ALONE.
#
# THE PROOF IS RECORDED AT CREATION, NOT RECONSTRUCTED AT COLLECTION.
# base's compose.yaml stamps the ABSOLUTE PATH of the checkout that ran it
# onto the network compose creates, as the label `base.checkout.path`,
# beside the `com.docker.compose.project` label docker sets itself. The
# collector reads that path back OFF THE ARTIFACT and asks the filesystem
# one question: is anything still there? Nothing there means the checkout
# that minted this network is gone, and the network is its litter.
#
# WHY RECORDED AND NOT RECOMPUTED. The rule this replaced derived
# `base-<sha256(path)[0:12]>` for every worktree `git worktree list`
# reported, and treated every artifact outside that set as an orphan. That
# makes the answer depend on WHERE THE COLLECTOR RAN: the same sweep
# launched from a downstream consumer's checkout -- which is exactly where
# the shipped stop.sh runs it -- enumerates THAT repo's worktrees, finds
# base's live checkouts in none of them, and deletes the network of every
# live base project on the host. Measured, not argued: from a synthetic
# consumer the sweep named 12 victims including this worktree and the main
# checkout, and at the DEFAULT grace it issued `docker network rm` for the
# live main checkout's network (with a fake daemon on PATH, so nothing live
# was destroyed). The same rule also had to
# PARSE the enumeration, and `git worktree list --porcelain` does not
# escape a newline in a path, so a live worktree whose path contained one
# was read as a different, non-existent path and collected. Both defects
# are one defect: a collector that INFERS ownership from something it
# enumerates is correct only when the enumeration happens to be the right
# one, and nothing in it can notice when it is not. Reading the path off
# the artifact has no such precondition -- it is correct from any cwd, in
# any repository, with or without git, with or without worktrees.
#
# WHAT THAT COSTS, stated here rather than discovered later. An artifact
# with NO path label cannot be attributed to anything, so it is LEFT ALONE
# -- permanently, by this collector. That includes every network created
# before this change: the litter already on the host is NOT collected by
# this mechanism, and the daemon-wide `docker network prune` in the sibling
# prune.sh remains what clears it. That is the safe direction and not a gap
# to apologise for; the alternative is a rule for artifacts whose owner
# cannot be established, and that is the rule that deletes a GitLab
# runner's network.
#
# A PATH THAT STILL EXISTS SPARES THE ARTIFACT, whether or not it is still
# a checkout. An empty directory where a checkout used to be is
# indistinguishable from here from a checkout mid-clone, mid-`git worktree
# add`, or mid-`git checkout` of a large tree -- and the run that owns it
# may be about to fill it. So the test is existence, never checkout-ness:
# the cost of sparing is one network that a later `rm -rf` of the directory
# makes collectable, and the cost of collecting is a live run's network.
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
#     alike, and its project label names whichever invocation happened to
#     build it first. Measured on the host: the tag this tree resolves,
#     `test-tools:b866113e322c`, carries `com.docker.compose.project=
#     local-base-995` -- the project `just docker build` mints -- while
#     this tree's own compose project is `base-0107d2de5abf`, and 13 live
#     worktrees resolve that same tag. A project label on an image
#     therefore names its builder and not its users, and collecting on it
#     would delete an image live checkouts still resolve. Images are
#     retired by content instead, in _reclaim_tool_tags.
#   - Volumes. A volume holds state, and neither its age nor the
#     disappearance of the path that created it is evidence that the state
#     is disposable -- the same rule script/ci/reclaim.sh applies to its
#     own age-based layer. base's compose.yaml declares no named volumes,
#     so there is nothing here to leave behind today; the day it does, this
#     comment is the decision to revisit rather than a gap to discover.
#
# THE GRACE WINDOW, and what it is still for. With liveness read off the
# artifact, the checkout running right now spares its own network by
# existing -- no self-protection special case, and no dependence on the
# invocation knowing which checkout it is. The window covers the narrower
# case the path test cannot see: a directory that is momentarily absent
# because something is moving or re-creating it while its run is in flight.
# That is a window of seconds, so the 6h default is not a tuned number: it
# is a wide margin that still collects the same day's litter, and the
# reason it is 6h rather than 6m is that the cost of waiting is a network
# nobody sees while the cost of being early is a live run's network.
# Raising it only ever removes less.

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

# The two labels the collector reads off a network.
#
# _RECLAIM_CHECKOUT_LABEL is the provenance base's compose.yaml records and
# this file is the only reader of; it is what makes an artifact
# attributable. `base.ci.run`, the ownership stamp script/ci/reclaim.sh
# already uses on the artifacts CI builds, is the naming this follows.
#
# _RECLAIM_PROJECT_LABEL is docker's own, and is used for exactly one
# thing here: asking whether a container is attached to the same project.
readonly _RECLAIM_CHECKOUT_LABEL='base.checkout.path'
readonly _RECLAIM_PROJECT_LABEL='com.docker.compose.project'

# The compose project name base's self-test mints.
readonly _RECLAIM_PROJECT_PREFIX='base'

# The tooling image. Repository name and the Dockerfile whose CONTENT
# (never its path) the tag is derived from.
readonly _RECLAIM_TOOL_REPO='test-tools'
readonly _RECLAIM_TOOL_DOCKERFILE_REL='dockerfile/Dockerfile.test-tools'

# Defaults. Both are overridable; neither is a number a reader has to go
# find in a script to understand what the collector kept.
readonly _RECLAIM_DEFAULT_GRACE='6h'
readonly _RECLAIM_TOOL_KEEP_FLOOR=3

# The last line of a network's fact read (see _reclaim_network_facts). A
# terminator and not a field count, because the field that may contain a
# newline is deliberately last and must be read to its end.
readonly _RECLAIM_FACTS_END='--- end of network facts ---'

# ── the derivations base's self-test mints artifacts by ─────────────────

# _reclaim_project_for_path <path>
#
# Prints `base-<sha256(path)[0:12]>`; exits non-zero, printing nothing,
# when no usable digest can be produced.
#
# THE producer of the compose project name -- script/test/test.sh's
# _compute_compose_project_name delegates here rather than hashing again,
# so the rule has one implementation. Note what it is NOT: the collector
# below does not recompute this name for anything, and no removal depends
# on it. Its whole job is to keep two checkouts' compose projects apart.
#
# Keyed to the PATH, not the commit: two worktrees are routinely branched
# from one commit, so a commit-keyed name would collide in exactly the
# concurrent case the name exists to separate. Hashing also satisfies
# compose's `[a-z0-9][a-z0-9_-]*` grammar by construction for ANY input
# path, which sanitising the path text cannot.
#
# A short digest -- sha256sum or cut missing from PATH -- would degrade to
# the bare prefix, a name EVERY checkout resolves. That is refused rather
# than returned: the producer must not hand compose a colliding name.
_reclaim_project_for_path() {
  local _root="${1:?_reclaim_project_for_path requires <path>}"
  local _hash
  _hash="$(printf '%s' "${_root}" | sha256sum 2>/dev/null | cut -d' ' -f1)" || _hash=""
  [[ "${_hash}" =~ ^[0-9a-f]{12} ]] || return 1
  printf '%s-%s\n' "${_RECLAIM_PROJECT_PREFIX}" "${_hash:0:12}"
}

# _reclaim_is_compose_project_name <name>
#
# Whether <name> is well-formed as a compose project name at all. This is
# NOT an ownership claim -- ownership is the path label and nothing else.
# It is the well-formedness check that makes the fact read below
# unambiguous: the project field is parsed as one line, and compose's own
# grammar is what guarantees it cannot contain the newline that would make
# that parse wrong.
_reclaim_is_compose_project_name() {
  [[ "${1-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
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
# or no usable digest. THE producer of the tooling tag -- test.sh's
# _resolve_test_tools_image delegates here -- and, unlike the project name,
# it IS consumed below: the retention rule keeps every tag a checkout that
# still exists resolves to, which means computing exactly what the producer
# computed.
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

# ── the docker surface, one place ────────────────────────────────────────
#
# Every read below reports its own failure instead of yielding an empty
# result, and every caller turns a failure into an abort. The distinction
# is load-bearing in both directions: read as "no networks came back", a
# failed listing collects nothing (harmless), while a failed CONTAINER
# listing would say no container is attached to anything and a failed
# checkout-label listing would say no checkout is live -- each of which
# turns a broken daemon connection into a reason to delete.

# _reclaim_docker_network_ids -- the ids of every network carrying our
# provenance label. Ids only: they are hex, so this listing is the one
# read that cannot be corrupted by the content of a label.
_reclaim_docker_network_ids() {
  docker network ls --filter "label=${_RECLAIM_CHECKOUT_LABEL}" \
    --format '{{.ID}}' 2>/dev/null
}

# _reclaim_docker_container_projects -- the compose project of every
# container, running or stopped.
_reclaim_docker_container_projects() {
  docker ps -a --format "{{.Label \"${_RECLAIM_PROJECT_LABEL}\"}}" 2>/dev/null
}

_reclaim_docker_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null
}

# _reclaim_network_facts <id>
#
# Prints the three facts a removal decision needs, one per line, then a
# terminator line:
#
#   1  creation time, `{{json .Created}}` -- an RFC3339 string in quotes
#   2  the compose project label
#   3  the checkout path label, WHICH MAY ITSELF CONTAIN NEWLINES
#   4  _RECLAIM_FACTS_END
#
# The order is the point. A path is the one field whose content this script
# does not control, and `docker network ls --format` would emit it inline
# in a per-network line: a path containing a newline then reads back as a
# DIFFERENT, shorter path, which very plausibly does not exist -- the exact
# shape that got a live worktree's network removed under the rule this
# replaced. Read per id, with the free-form field last and a terminator
# after it, every byte of the path survives and no field can be confused
# for another.
#
# `{{json .Created}}` and not the bare `{{.Created}}`, and the two are not
# interchangeable. On an IMAGE the field is already an RFC3339 string and
# both spellings work; on a NETWORK it is a Go time value, which the bare
# template renders as `2026-09-03 11:07:45.1237 +0800 CST` -- a form
# `date -d` rejects outright. The JSON spelling marshals both to RFC3339,
# so one rule reads both kinds. The bug that cost this its first real run
# read every network's age as unreadable; it failed in the safe direction
# (the orphan was spared rather than collected) which is exactly why it
# could go unnoticed, and why the specs pin the quoted shape.
_reclaim_network_facts() {
  local _id="${1:?_reclaim_network_facts requires <id>}"
  docker network inspect --format \
    "{{json .Created}}{{\"\\n\"}}{{index .Labels \"${_RECLAIM_PROJECT_LABEL}\"}}{{\"\\n\"}}{{index .Labels \"${_RECLAIM_CHECKOUT_LABEL}\"}}{{\"\\n${_RECLAIM_FACTS_END}\"}}" \
    "${_id}" 2>/dev/null
}

# _reclaim_parse_facts <blob> <created-var> <project-var> <path-var>
#
# Splits what _reclaim_network_facts printed. Returns non-zero -- filling
# nothing -- when the terminator is absent (a truncated read, an inspect
# that failed, an artifact that vanished mid-sweep) or when the project
# field is not a well-formed compose project name, which is what
# guarantees the split found the real field boundaries.
_reclaim_parse_facts() {
  local _blob="${1-}"
  local -n _rpf_created="${2:?_reclaim_parse_facts requires <created-var>}"
  local -n _rpf_project="${3:?_reclaim_parse_facts requires <project-var>}"
  local -n _rpf_path="${4:?_reclaim_parse_facts requires <path-var>}"
  # Every local here is __rpf_-prefixed. A local whose NAME matches the
  # variable a caller asked to be filled captures the nameref: the
  # assignment then lands on this function's local and the caller sees an
  # empty field. The callers pass _created / _project / _path, which is
  # exactly the collision the prefix keeps out of reach.
  local __rpf_tail=$'\n'"${_RECLAIM_FACTS_END}"
  [[ "${_blob}" == *"${__rpf_tail}" ]] || return 1
  local __rpf_body="${_blob%"${__rpf_tail}"}"
  [[ "${__rpf_body}" == *$'\n'*$'\n'* ]] || return 1
  local __rpf_created="${__rpf_body%%$'\n'*}"
  local __rpf_rest="${__rpf_body#*$'\n'}"
  local __rpf_project="${__rpf_rest%%$'\n'*}"
  local __rpf_path="${__rpf_rest#*$'\n'}"
  _reclaim_is_compose_project_name "${__rpf_project}" || return 1
  __rpf_created="${__rpf_created%\"}"
  _rpf_created="${__rpf_created#\"}"
  _rpf_project="${__rpf_project}"
  _rpf_path="${__rpf_path}"
  return 0
}

# _reclaim_epoch <rfc3339> -- a unix timestamp, empty when unreadable.
_reclaim_epoch() {
  local _created="${1-}"
  [[ -n "${_created}" ]] || return 0
  date -d "${_created}" +%s 2>/dev/null || true
}

# _reclaim_created_epoch <kind> <ref> -- an IMAGE's creation time as a unix
# timestamp, empty when it cannot be read. Networks go through
# _reclaim_network_facts instead, which reads their age in the same round
# trip as their labels.
_reclaim_created_epoch() {
  local _kind="${1:?}" _id="${2:?}" _created=""
  _created="$(docker "${_kind}" inspect --format '{{json .Created}}' "${_id}" 2>/dev/null)" \
    || return 0
  _created="${_created%\"}"
  _created="${_created#\"}"
  _reclaim_epoch "${_created}"
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

# _reclaim_orphan_projects [grace]
#
# Removes the network of every compose project that is provably dead:
# carrying a checkout-path label, nothing at that path, no container on the
# same project, and older than the grace window. Returns non-zero only when
# it refused to act at all (a docker read that failed, an unparseable
# grace) -- a network that could not be removed is reported and does not
# fail the sweep, since the next sweep collects it.
#
# IT TAKES NO ROOT, and that is the fix rather than an economy. The rule it
# replaced took the caller's repo root, enumerated that repository's
# worktrees and deleted everything outside them, so the same call meant
# different things in different checkouts and meant something destructive
# in a downstream consumer. This one asks the artifact who made it, so
# there is no cwd, no repository and no git for the answer to depend on.
#
# EVERY INPUT IT CANNOT PLACE IS LEFT ALONE. No path label; a label that is
# not an absolute path; facts that could not be read or parsed; a project
# label that is not well-formed; an unreadable creation time -- none of
# them is a candidate. There is no branch below in which failing to
# recognise something leads to removing it: the single fact that can
# produce a removal is a path label that WAS read and whose path is not
# there, and everything else in the function only ever subtracts from that.
# The fail-open direction here is deleting an artifact whose owner cannot
# be established, and on a host shared with other tenants that is the worst
# outcome available.
_reclaim_orphan_projects() {
  local _grace="${1:-${BASE_RECLAIM_GRACE:-${_RECLAIM_DEFAULT_GRACE}}}"

  local _grace_s
  if ! _grace_s="$(_reclaim_duration_seconds "${_grace}")"; then
    _log_err reclaim reclaim_bad_grace \
      "display=not a duration: ${_grace} (expected <N>s / <N>m / <N>h / <N>d); removing nothing." \
      "grace=${_grace}"
    return 1
  fi

  local _ids
  if ! _ids="$(_reclaim_docker_network_ids)"; then
    _log_err reclaim reclaim_artifacts_unreadable \
      "display=cannot list the networks carrying a ${_RECLAIM_CHECKOUT_LABEL} label; removing nothing (a failed listing is not evidence that nothing is labelled)."
    return 1
  fi

  # Read BEFORE the scan, and aborted on rather than defaulted to empty: an
  # empty attached-set read as success says no container is attached to
  # anything, which turns a broken daemon connection into a reason to
  # delete a running project's network.
  local _containers
  if ! _containers="$(_reclaim_docker_container_projects)"; then
    _log_err reclaim reclaim_containers_unreadable \
      "display=cannot list containers; removing nothing (an unreadable container list cannot say that no container is attached)."
    return 1
  fi
  local -a _attached=()
  local _p
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] && _attached+=("${_p}")
  done <<< "${_containers}"

  local _now _cutoff
  _now="$(date +%s)"
  _cutoff=$(( _now - _grace_s ))

  # Three refusal counters, not one. "I could not read this artifact" and
  # "this artifact does not say who made it" and "I could not read its age"
  # are all refusals to delete, but they say different things about the
  # machine: the first and third are an artifact that vanished between the
  # listing and the inspection -- a concurrent teardown racing ours, which
  # is normal, but also the shape a daemon problem takes -- and the second
  # is the pre-existing litter this mechanism deliberately never collects.
  # Reported as one number they cannot be told apart.
  local _scanned=0 _kept_live=0 _kept_attached=0 _kept_young=0
  local _refused_unattributable=0 _refused_age=0
  local -a _victims=()
  local _id _facts _created _project _path _epoch
  while IFS= read -r _id; do
    [[ -n "${_id}" ]] || continue
    _scanned=$(( _scanned + 1 ))
    _facts="$(_reclaim_network_facts "${_id}")" || _facts=""
    _created=""; _project=""; _path=""
    if ! _reclaim_parse_facts "${_facts}" _created _project _path; then
      _refused_unattributable=$(( _refused_unattributable + 1 ))
      continue
    fi
    # The provenance, and the only thing that can make an artifact a
    # candidate. A relative path, or an empty label, names nothing this can
    # test, so it attributes nothing.
    if [[ "${_path}" != /* ]]; then
      _refused_unattributable=$(( _refused_unattributable + 1 ))
      continue
    fi
    if [[ -e "${_path}" ]]; then
      _kept_live=$(( _kept_live + 1 ))
      continue
    fi
    if _reclaim_in_list "${_project}" "${_attached[@]+"${_attached[@]}"}"; then
      _kept_attached=$(( _kept_attached + 1 ))
      continue
    fi
    _epoch="$(_reclaim_epoch "${_created}")"
    # An unreadable creation time is not a young artifact and not an old
    # one; it is one more thing that cannot be placed.
    if [[ -z "${_epoch}" ]]; then
      _refused_age=$(( _refused_age + 1 ))
      continue
    fi
    if (( _epoch >= _cutoff )); then
      _kept_young=$(( _kept_young + 1 ))
      continue
    fi
    _victims+=("${_id}")
  done <<< "${_ids}"

  _log_info reclaim reclaim_scan \
    "display=scoped reclaim: ${_scanned} labelled network(s); keeping ${_kept_live} whose checkout still exists, ${_kept_attached} with a container attached, ${_kept_young} inside the ${_grace} grace window; left alone ${_refused_unattributable} that record no readable checkout path and ${_refused_age} whose age could not be read." \
    "scanned=${_scanned}" "live=${_kept_live}" "attached=${_kept_attached}" \
    "young=${_kept_young}" "unattributable=${_refused_unattributable}" \
    "age_unreadable=${_refused_age}"

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

# _reclaim_live_checkouts <outvar-array>
#
# Every checkout path recorded on a labelled network that STILL EXISTS.
# Returns non-zero when the artifacts cannot be listed, which every caller
# turns into an abort: read as "no live checkouts", the same condition
# retires every tooling image on the host.
#
# This is the same evidence the project rule acts on, used the other way
# round -- the paths that are there rather than the ones that are not --
# so the two rules cannot come to disagree about which checkouts are alive.
# It enumerates ARTIFACTS, never worktrees: a checkout that has run the
# suite has a network naming it, wherever it lives and whatever repository
# the sweep was launched from.
_reclaim_live_checkouts() {
  local -n _rlc_out="${1:?_reclaim_live_checkouts requires <outvar>}"
  _rlc_out=()
  local _ids
  _ids="$(_reclaim_docker_network_ids)" || return 1
  local _id _facts _created _project _path
  while IFS= read -r _id; do
    [[ -n "${_id}" ]] || continue
    _facts="$(_reclaim_network_facts "${_id}")" || continue
    _created=""; _project=""; _path=""
    _reclaim_parse_facts "${_facts}" _created _project _path || continue
    [[ "${_path}" == /* ]] || continue
    [[ -e "${_path}" ]] || continue
    _reclaim_in_list "${_path}" "${_rlc_out[@]+"${_rlc_out[@]}"}" || _rlc_out+=("${_path}")
  done <<< "${_ids}"
  return 0
}

# _reclaim_pinned_tool_tags <repo_root> <outvar-array>
#
# The tags no rebuild should ever be paid for: the one <repo_root> resolves
# to, plus the one every live checkout resolves to. A live checkout needing
# an image is a proof of use, where "it looks unused" is not.
_reclaim_pinned_tool_tags() {
  local _root="${1:?_reclaim_pinned_tool_tags requires <repo_root>}"
  local -n _rptt_out="${2:?_reclaim_pinned_tool_tags requires <outvar>}"
  _rptt_out=()
  local -a _paths=()
  _reclaim_live_checkouts _paths || return 1
  # The invoking tree first and unconditionally. It is the one checkout an
  # invocation can prove is in use without asking anything, and on a first
  # run it has no network yet to be found by.
  _paths=("${_root}" "${_paths[@]+"${_paths[@]}"}")
  local _p _tag
  for _p in "${_paths[@]}"; do
    _tag="$(_reclaim_tool_tag_for_path "${_p}")" || continue
    _reclaim_in_list "${_tag}" "${_rptt_out[@]+"${_rptt_out[@]}"}" || _rptt_out+=("${_tag}")
  done
  return 0
}

# _reclaim_keep_window <pinned-count>
#
# Prints N, the size of the recency window _reclaim_tool_tags keeps ON TOP
# of the tags live checkouts resolve.
#
# DERIVED, not chosen. Content-hash tagging guarantees unbounded growth, so
# something has to bound it, and the number that bounds it honestly is how
# many DISTINCT tooling images the checkouts on this host currently need.
# That is a measurement of the machine, not a constant, and it grows when
# the work on the machine grows.
#
# The floor of 3 covers the case the measurement cannot see: a single
# checkout resolves one tag, and a developer who switches to a branch and
# back would then pay a full tooling-image rebuild for the round trip.
# Three lets a branch, the branch before it and the trunk coexist.
#
# BASE_TOOL_TAGS_KEEP overrides both, so the number is never something a
# reader has to go dig out of a script.
_reclaim_keep_window() {
  local _pinned="${1:-0}"
  if [[ -n "${BASE_TOOL_TAGS_KEEP:-}" ]]; then
    printf '%s\n' "${BASE_TOOL_TAGS_KEEP}"
    return 0
  fi
  [[ "${_pinned}" =~ ^[0-9]+$ ]] || _pinned=0
  if (( _pinned > _RECLAIM_TOOL_KEEP_FLOOR )); then
    printf '%s\n' "${_pinned}"
  else
    printf '%s\n' "${_RECLAIM_TOOL_KEEP_FLOOR}"
  fi
}

# _reclaim_tool_tags <repo_root> [keep]
#
# Retires local `test-tools:<12hex>` images down to a bounded set: every
# tag a live checkout resolves (this tree's included) and the <keep> most
# recently created besides. Everything else is content the machine can
# rebuild and no checkout on it asks for.
#
# The recency window on top of the pinned set is the hedge for the tag
# whose checkout has moved on but which a branch switch would ask for again
# in a minute.
#
# THIS ONE IS NEVER AUTOMATIC, and the reason is the difference between the
# two halves of `--reclaim`. The project rule acts on a proof carried by
# the artifact: this network says which checkout made it, and that checkout
# is gone. No such proof exists for an image. The tooling tag is
# content-hash shared ON PURPOSE, so an artifact can name the checkout that
# BUILT a tag but never the checkouts that use it, and the pinned set below
# is therefore a measurement of what this collector can currently see --
# every checkout that has run the suite since the label existed -- rather
# than evidence that nothing else wants the rest. Two things were measured
# on the shared host rather than argued: wired into the end of `just test`,
# the first automatic run retired one tooling image nobody had asked it to;
# and with the recency window taken out of the way
# (`--tool-tags --keep 0 --dry-run`) the retention names
# `test-tools:d717a7bbd9bc` a victim -- the tag the live worktree
# base-946 resolves, which is not pinned only because that checkout has not
# run under this label yet. The window is what happens to cover that gap
# today; it is a hedge, not a proof, and it covers less as tags accumulate.
# The cost is a rebuild rather than data, which is exactly the point: a
# removal resting on a measurement is a cost imposed on someone else, so it
# stays behind an explicit `just docker prune --tool-tags` / `--reclaim`,
# beside --volumes and --worktree-orphans, and out of anything that runs
# unasked.
#
# ANYTHING ELSE IS LEFT ALONE, by name: an image in another repository, a
# registry-qualified tag, `test-tools:local`, a tag whose suffix is not 12
# hex digits, and an image whose creation time cannot be read. A docker
# read that FAILED aborts before a single removal, for the same reason it
# does in the project rule.
_reclaim_tool_tags() {
  local _root="${1:?_reclaim_tool_tags requires <repo_root>}"

  local -a _pinned=()
  if ! _reclaim_pinned_tool_tags "${_root}" _pinned; then
    _log_err reclaim reclaim_artifacts_unreadable \
      "display=cannot list the networks that record which checkouts are live; retiring no tooling tags."
    return 1
  fi

  local _keep="${2-}"
  if [[ -z "${_keep}" ]]; then
    _keep="$(_reclaim_keep_window "${#_pinned[@]}")"
  fi
  if [[ ! "${_keep}" =~ ^[0-9]+$ ]]; then
    _log_err reclaim reclaim_bad_keep \
      "display=not a count: ${_keep}; retiring no tooling tags." "keep=${_keep}"
    return 1
  fi

  local _images
  if ! _images="$(_reclaim_docker_images)"; then
    _log_err reclaim reclaim_artifacts_unreadable \
      "display=cannot list images; retiring no tooling tags."
    return 1
  fi

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
    done <<< "${_images}" | sort -rn
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
