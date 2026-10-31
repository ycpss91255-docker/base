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
# The resolve/ensure/build path, shared with the config generator
# (base#1466). It sources project_reclaim.sh, whose digest derivation the
# tag is taken with -- the SAME function the tooling tag and the image
# retention policy use, not a second hashing rule (base#1169).
# shellcheck source=dist/script/docker/lib/tool_image.sh
source "${_toml_bridge_dir}/tool_image.sh"

# The bridge's build inputs, relative to the subtree root. The build
# context is the Dockerfile's OWN directory, which is what makes the
# shipped copy buildable from a consumer at all: a context of the subtree
# root would make the COPY path depend on the subtree's name, which is the
# consumer's to choose.
_TOML_BRIDGE_DOCKERFILE_REL="dockerfile/Dockerfile.toml-bridge"
tool_image_define toml_bridge toml-bridge "${_toml_bridge_dir}" \
  "${_TOML_BRIDGE_DOCKERFILE_REL}" dockerfile TOML_BRIDGE_IMAGE \
  _TOML_BRIDGE_RESOLVED

# The image the containerised path last resolved, so the resolution -- and
# the build it may do -- happens once per shell. A global and not a
# printed value on purpose: a command substitution would run the whole
# resolution in a subshell, where the memo cannot survive, and the next
# read of the same file would build again.
_TOML_BRIDGE_RESOLVED=""

# _toml_bridge_tool_image_display <kind> <image> <path> <rc> <out> <lib>
#   The bridge's wording for each record tool_image.sh writes on its
#   behalf. A failed build names the builder's output, already folded onto
#   one line, and does not exit: the INI-to-TOML migration's commit gate
#   reads an unavailable bridge as a declined conversion (base#1137).
_toml_bridge_tool_image_display() {
  case "$1" in
    no_root)
      printf '%s' "cannot name the containerised TOML parser: no subtree root (a directory carrying .version and dist/) above ${6}, so the shipped ${_TOML_BRIDGE_DOCKERFILE_REL} cannot be found. The configuration format is TOML (ADR-00000037) and nothing reads it without the parser, so this stops here rather than reporting an empty configuration as a loaded one." ;;
    no_dockerfile)
      printf '%s' "cannot build the containerised TOML parser: ${3} is missing from the vendored subtree. Re-run the upgrade so the subtree is complete, or pin a parser image with TOML_BRIDGE_IMAGE. The configuration format is TOML (ADR-00000037) and nothing reads it without the parser." ;;
    no_context)
      printf '%s' "cannot build the containerised TOML parser: its build context ${3} is missing from the vendored subtree. Re-run the upgrade so the subtree is complete, or pin a parser image with TOML_BRIDGE_IMAGE." ;;
    unhashable)
      printf '%s' "cannot name the containerised TOML parser: a build input of ${3} could not be resolved or read (the refusal above names it). A digest taken over the rest would name an image it does not describe." ;;
    building)
      printf '%s' "building the containerised TOML parser ${2} from ${3} -- the configuration format is TOML (ADR-00000037) and nothing reads it until the parser exists. Once per revision of the bridge: a later run whose build inputs are identical resolves this same tag and skips the build." ;;
    build_failed)
      printf '%s' "the containerised TOML parser ${2} could not be built from ${3} (docker build exited ${4}), so the configuration cannot be read and this stops here rather than falling back to the template defaults. Builder said: ${5}. Fix the cause and re-run, or pin a parser image with TOML_BRIDGE_IMAGE." ;;
  esac
}

# The bridge's provisioning steps, each the shared helper's for the
# toml_bridge profile. _toml_bridge_resolve_image sets
# _TOML_BRIDGE_RESOLVED and prints nothing; TOML_BRIDGE_IMAGE, when
# non-empty, wins verbatim and is NOT provisioned.
_toml_bridge_subtree_root() { tool_image_subtree_root toml_bridge; }
_toml_bridge_dockerfile() { tool_image_dockerfile toml_bridge; }
_toml_bridge_derive_image() { tool_image_derive toml_bridge; }
_toml_bridge_ensure_image() { tool_image_ensure toml_bridge "${1:?"${FUNCNAME[0]}: missing image"}"; }
_toml_bridge_resolve_image() { tool_image_resolve toml_bridge; }

# _toml_bridge_use_native -- true when the bridge binary is installed
# locally and the caller has not forced Docker mode.
_toml_bridge_use_native() {
  [[ "${TOML_BRIDGE_FORCE_DOCKER:-}" != "1" ]] && command -v toml-bridge &>/dev/null
}

# toml_bridge_parse <toml-file> [--kv | --empty-arrays | --tables | --empty-families]
#   Parse a TOML file and emit JSON (or --kv TSV, or with --tables the
#   dotted path of every declared table, one per line, or with
#   --empty-families `section<TAB>key<TAB>path` -- the KV row an empty
#   array's first entry would take) on stdout.
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
  # `-e`, not `-f`: a directory in a layer's place is there, so it is
  # refused by name instead of counting as absent (base#1400). Any layer
  # that is there but is not a regular file is refused HERE, before the
  # bridge opens it: open(2) on a FIFO blocks until a writer arrives, so
  # handing one to the bridge hangs the caller instead of refusing
  # (base#1400).
  for _file in "$@"; do
    [[ -e "${_file}" ]] || continue
    if [[ ! -f "${_file}" ]]; then
      _log_err toml_bridge merge_layer_not_regular \
        "display=toml_bridge_merge: ${_file} is there but is not a regular file; refusing it as a configuration layer rather than opening it" \
        "path=${_file}"
      return 1
    fi
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
