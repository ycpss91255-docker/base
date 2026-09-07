#!/usr/bin/env bash
# toml_bridge.sh -- shim for the TOML parser (ADR-37).
#
# Provides toml_bridge_parse() and toml_bridge_merge() for TOML config
# processing.  Two dispatch paths, tried in order:
#
#   1. Native -- the `toml-bridge` binary is in PATH (installed in the
#      test-tools image via COPY --from=toml-bridge-src).  Fastest, no
#      Docker dependency at call time.
#   2. Containerised -- `docker run toml-bridge:local`.  The host needs
#      Docker only; no Python, no pip (ADR-37 sec. Containerised parsing).
#
# Set TOML_BRIDGE_FORCE_DOCKER=1 to skip the native probe and always
# use the containerised path (useful for testing the Docker fallback).

_toml_bridge_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_toml_bridge_dir}/log.sh"

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

  local _image="${TOML_BRIDGE_IMAGE:-toml-bridge:local}"
  docker run --rm -i "${_image}" "$@" < "${_file}"
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
  local _file
  local -a _layers=()
  for _file in "$@"; do
    [[ -f "${_file}" ]] || continue
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
  local _image="${TOML_BRIDGE_IMAGE:-toml-bridge:local}"
  local -a _docker_args=("run" "--rm")
  local -a _bridge_args=("--merge")
  [[ -n "${_kv_flag}" ]] && _bridge_args+=("--kv")

  for _file in "${_layers[@]}"; do
    _docker_args+=("-v" "${_file}:${_file}:ro")
    _bridge_args+=("${_file}")
  done

  docker "${_docker_args[@]}" "${_image}" "${_bridge_args[@]}"
}
