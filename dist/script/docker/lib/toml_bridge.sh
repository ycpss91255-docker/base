#!/usr/bin/env bash
# toml_bridge.sh -- shim for the TOML parser (ADR-37).
#
# Provides toml_bridge_parse() and toml_bridge_merge() for TOML config
# processing.  Two dispatch paths, tried in order:
#
#   1. Native -- the `toml-bridge` binary is in PATH (the test-tools image
#      installs it).  Fastest, no Docker dependency at call time.
#   2. Containerised -- `docker run` of the bridge image, which this file
#      PROVISIONS when it is not there.  The host needs Docker only; no
#      Python, no pip (ADR-37 sec. Containerised parsing).
#
# Set TOML_BRIDGE_FORCE_DOCKER=1 to skip the native probe and always
# use the containerised path (useful for testing the Docker fallback).
#
# ── WHY THE IMAGE IS PROVISIONED HERE, AND NOT ASSUMED ──────────────────
#
# The containerised path used to run a fixed `toml-bridge:local`, and
# nothing in the production `init` path ever built it. Every shipped reader
# now goes through this shim, so on a clean host the configuration could
# not be read at all -- and the only places the image existed were a
# self-test workflow step and a developer who had read the Dockerfile's
# usage comment. The capability a release ships cannot depend on a step in
# the release's own CI.
#
# Two things make that fixable from here rather than from a registry: the
# build inputs ARE shipped. The subtree a consumer vendors is this repo's
# root, so `dockerfile/Dockerfile.toml-bridge` and the `toml_bridge.py` it
# COPYs arrive at `<subtree>/dockerfile/` on every consumer, beside the
# `Dockerfile.test-tools` the build wrappers already read from there.
#
# IDENTITY IS REVISION-SPECIFIC, never a floating tag. The tag is a digest
# over the bridge Dockerfile and every file it COPYs from its build
# context, which is the property base#1169 established for the tooling
# tag: the same content resolves to ONE name on two machines, so a cache
# hit is a cache hit and two checkouts at different revisions cannot
# displace each other's image mid-run. The derivation is
# _reclaim_tool_dockerfile_hash -- the SAME function the tooling tag and
# the image-retention policy use, not a second hashing rule of this
# file's own.
#
# BUILD AT FIRST USE is the accepted cost. It adds network and
# build-failure exposure to a configuration read, and a bridge-less host
# already failed during configuration loading -- so the exposure is not
# new, only the direction it fails in: a loud refusal costs a re-run,
# where the old behaviour cost the configuration, because an unreadable
# parser resolved to an empty handle and every value fell back to its
# template default with nothing said.
#
# TOML_BRIDGE_IMAGE still wins verbatim and is NOT provisioned. CI pins a
# published or in-run tag through it, and building over what a caller
# asked for is the same mistake _ensure_test_tools_image declines to make.

_toml_bridge_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_toml_bridge_dir}/log.sh"
# The content-digest derivation, shared with the tooling tag and the image
# retention policy rather than reimplemented (base#1169). Sourced after
# log.sh, which it emits its refusals through.
# shellcheck source=dist/script/docker/lib/project_reclaim.sh
source "${_toml_bridge_dir}/project_reclaim.sh"

# The bridge's build inputs, relative to the subtree root.
_TOML_BRIDGE_DOCKERFILE_REL="dockerfile/Dockerfile.toml-bridge"

# The image the containerised path last resolved, so the resolution -- and
# the build it may do -- happens once per shell. A global and not a
# printed value on purpose: a command substitution would run the whole
# resolution in a subshell, where the memo cannot survive, and the next
# read of the same file would build again.
_TOML_BRIDGE_RESOLVED=""

# _toml_bridge_subtree_root
#   The subtree root the shipped build inputs sit under: the directory
#   carrying the subtree markers `.version` + `dist/` above this lib.
#   The same walk init.sh and upgrade.sh do, and for the same reason --
#   the prefix is the consumer's to name, so nothing may spell `.base`.
#
#   Non-zero and silent when there is none: the caller turns that into
#   the refusal, where the image it was trying to name can be said too.
_toml_bridge_subtree_root() {
  local _dir="${_toml_bridge_dir}"
  while [[ "${_dir}" != "/" ]]; do
    if [[ -f "${_dir}/.version" && -d "${_dir}/dist" ]]; then
      printf '%s\n' "${_dir}"
      return 0
    fi
    _dir="$(cd -- "${_dir}/.." && pwd -P)" || return 1
  done
  return 1
}

# _toml_bridge_dockerfile
#   The shipped bridge Dockerfile, or non-zero when the subtree root
#   cannot be found.
_toml_bridge_dockerfile() {
  local _root
  _root="$(_toml_bridge_subtree_root)" || return 1
  printf '%s/%s\n' "${_root}" "${_TOML_BRIDGE_DOCKERFILE_REL}"
}

# _toml_bridge_derive_image
#   `toml-bridge:<12 hex>` over the bridge Dockerfile and every file it
#   COPYs from its build context. Twelve digits for the reason the tooling
#   tag takes twelve: the tag has to stay readable in `docker images`, and
#   the collision surface is the handful of checkouts on one host.
#
#   Every way of not getting an answer is a refusal, never a fallback to a
#   bare literal. A literal resolves to whatever a sibling checkout last
#   built under that name, which is the collision the derivation exists to
#   remove, and here it would also hand a configuration read a parser from
#   another revision.
_toml_bridge_derive_image() {
  local _dockerfile _hash=""
  if ! _dockerfile="$(_toml_bridge_dockerfile)"; then
    _log_err toml_bridge toml_bridge_unprovisionable \
      "display=cannot name the containerised TOML parser: no subtree root (a directory carrying .version and dist/) above ${_toml_bridge_dir}, so the shipped ${_TOML_BRIDGE_DOCKERFILE_REL} cannot be found. The configuration format is TOML (ADR-00000037) and nothing reads it without the parser, so this stops here rather than reporting an empty configuration as a loaded one." \
      "lib=${_toml_bridge_dir}"
    return 1
  fi
  if [[ ! -f "${_dockerfile}" ]]; then
    _log_err toml_bridge toml_bridge_unprovisionable \
      "display=cannot build the containerised TOML parser: ${_dockerfile} is missing from the vendored subtree. Re-run the upgrade so the subtree is complete, or pin a parser image with TOML_BRIDGE_IMAGE. The configuration format is TOML (ADR-00000037) and nothing reads it without the parser." \
      "path=${_dockerfile}"
    return 1
  fi
  if ! _hash="$(_reclaim_tool_dockerfile_hash "${_dockerfile}")" \
    || [[ -z "${_hash}" ]]; then
    _log_err toml_bridge toml_bridge_unprovisionable \
      "display=cannot name the containerised TOML parser: a build input of ${_dockerfile} could not be resolved or read (the refusal above names it). A digest taken over the rest would name an image it does not describe." \
      "path=${_dockerfile}"
    return 1
  fi
  printf 'toml-bridge:%s\n' "${_hash:0:12}"
}

# _toml_bridge_ensure_image <image>
#   Make <image> exist. Present is the whole answer -- the tag is keyed to
#   its inputs, so a tag that is there was built from these inputs and a
#   rebuild would be a cache hit under a different name for the same thing.
#
#   The build context is the Dockerfile's OWN directory, which is what
#   makes the shipped copy buildable from a consumer at all: a context of
#   the subtree root would make the COPY path depend on the subtree's name,
#   which is the consumer's to choose.
#
#   A failed build is reported with the builder's own output folded onto
#   one line -- it reaches the log as an attribute value, and the text sink
#   renders a body on one line -- and answers non-zero. It does not exit:
#   the INI-to-TOML migration's commit gate reads an unavailable bridge as
#   a declined conversion (base#1137), and a hard exit here would turn
#   that containment into a crash.
_toml_bridge_ensure_image() {
  local _image="${1:?"${FUNCNAME[0]}: missing image"}"
  docker image inspect "${_image}" > /dev/null 2>&1 && return 0

  local _dockerfile _context _out="" _rc=0
  _dockerfile="$(_toml_bridge_dockerfile)" || return 1
  _context="${_dockerfile%/*}"

  _log_info toml_bridge toml_bridge_building \
    "display=building the containerised TOML parser ${_image} from ${_dockerfile} -- the configuration format is TOML (ADR-00000037) and nothing reads it until the parser exists. Once per revision of the bridge: a later run whose build inputs are identical resolves this same tag and skips the build." \
    "image=${_image}" \
    "path=${_dockerfile}"

  _out="$(docker build -t "${_image}" -f "${_dockerfile}" "${_context}" 2>&1)" \
    || _rc=$?
  (( _rc == 0 )) && return 0

  _log_err toml_bridge toml_bridge_build_failed \
    "display=the containerised TOML parser ${_image} could not be built from ${_dockerfile} (docker build exited ${_rc}), so the configuration cannot be read and this stops here rather than falling back to the template defaults. Builder said: ${_out//$'\n'/ }. Fix the cause and re-run, or pin a parser image with TOML_BRIDGE_IMAGE." \
    "image=${_image}" \
    "path=${_dockerfile}" \
    "status=${_rc}"
  return 1
}

# _toml_bridge_resolve_image
#   Set _TOML_BRIDGE_RESOLVED to the image the containerised path runs,
#   provisioning it when it is this checkout's derived tag and is not
#   there yet. Answers non-zero, having said why, when it cannot.
_toml_bridge_resolve_image() {
  if [[ -n "${TOML_BRIDGE_IMAGE:-}" ]]; then
    _TOML_BRIDGE_RESOLVED="${TOML_BRIDGE_IMAGE}"
    return 0
  fi
  [[ -n "${_TOML_BRIDGE_RESOLVED}" ]] && return 0
  local _image
  _image="$(_toml_bridge_derive_image)" || return 1
  _toml_bridge_ensure_image "${_image}" || return 1
  _TOML_BRIDGE_RESOLVED="${_image}"
  return 0
}

# _toml_bridge_use_native -- true when the bridge binary is installed
# locally and the caller has not forced Docker mode.
_toml_bridge_use_native() {
  [[ "${TOML_BRIDGE_FORCE_DOCKER:-}" != "1" ]] && command -v toml-bridge &>/dev/null
}

# toml_bridge_parse <toml-file> [--kv]
#   Parse a TOML file and emit JSON (or --kv TSV) on stdout.
#   Returns non-zero if the file does not exist or parsing fails.
toml_bridge_parse() {
  local _file="${1:?toml_bridge_parse expects a TOML file path}"
  shift

  if [[ ! -f "${_file}" ]]; then
    _log_err toml_bridge no_such_file \
      "toml_bridge_parse: no such file: ${_file}"
    return 1
  fi

  if _toml_bridge_use_native; then
    toml-bridge "$@" < "${_file}"
    return
  fi

  _toml_bridge_resolve_image || return 1
  docker run --rm -i "${_TOML_BRIDGE_RESOLVED}" "$@" < "${_file}"
}

# toml_bridge_merge [--kv] <toml-file>...
#   Merge multiple TOML files with type-aware semantics (table key-level
#   merge, array-of-tables replace).
#   Files are given in INCREASING precedence (baseline first, override last).
#   Default: merged JSON on stdout.  --kv: section\tkey\tvalue TSV lines.
#   A layer that does not exist contributes nothing; naming no layer at all
#   is refused.  Returns non-zero if merging fails.
toml_bridge_merge() {
  local _kv_flag=""
  if [[ "${1:-}" == "--kv" ]]; then
    _kv_flag="--kv"
    shift
  fi
  (( $# > 0 )) || {
    _log_err toml_bridge merge_no_files \
      "toml_bridge_merge: no files given"
    return 1
  }

  # An absent layer contributes nothing rather than failing the merge: the
  # caller passes the whole chain unconditionally, which is the rule
  # _conf_load_layers states on this side of the call and the bridge's own
  # _merge_toml implements on the other. A layer that IS there and cannot
  # be read still fails, inside the bridge, naming the file. Naming no
  # layer at all is a different mistake and is refused above.
  #
  # A layer that IS there is collected by its ABSOLUTE path, because the
  # docker path below mounts each file at its own name and `docker run -v`
  # refuses a destination that is not absolute. The chain carries relative
  # paths whenever the caller passed a relative --base-path, so without
  # this the containerised merge fails on a file sitting right there -- and
  # only on the hosts that have no bridge binary, which are the hosts the
  # docker path exists for.
  local _file _dir
  local -a _layers=()
  for _file in "$@"; do
    [[ -f "${_file}" ]] || continue
    if [[ "${_file}" != /* ]]; then
      _dir="$(cd -- "$(dirname -- "${_file}")" && pwd -P)" || return 1
      _file="${_dir}/$(basename -- "${_file}")"
    fi
    _layers+=("${_file}")
  done
  (( ${#_layers[@]} > 0 )) || return 0

  # Native path: call the bridge binary directly.
  if _toml_bridge_use_native; then
    local -a _args=("--merge")
    [[ -n "${_kv_flag}" ]] && _args+=("--kv")
    _args+=("${_layers[@]}")
    toml-bridge "${_args[@]}"
    return
  fi

  # Docker path: mount each file and run the containerised bridge.
  _toml_bridge_resolve_image || return 1
  local -a _docker_args=("run" "--rm")
  local -a _bridge_args=("--merge")
  [[ -n "${_kv_flag}" ]] && _bridge_args+=("--kv")

  for _file in "${_layers[@]}"; do
    _docker_args+=("-v" "${_file}:${_file}:ro")
    _bridge_args+=("${_file}")
  done

  docker "${_docker_args[@]}" "${_TOML_BRIDGE_RESOLVED}" "${_bridge_args[@]}"
}
