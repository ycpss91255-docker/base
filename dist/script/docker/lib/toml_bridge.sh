#!/usr/bin/env bash
# toml_bridge.sh -- host-side shim for the containerised TOML parser.
#
# Provides toml_bridge_parse() which feeds a TOML file to the toml-bridge
# container (docker run) and emits JSON on stdout. The host needs Docker
# only; no Python, no pip (ADR-37 sec. Containerised parsing).

_toml_bridge_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_toml_bridge_dir}/log.sh"

# toml_bridge_parse <toml-file> [--kv]
#   Parse a TOML file via the containerised bridge.
#   Default: JSON on stdout.  --kv: section\tkey\tvalue TSV lines.
#   Returns non-zero if the file does not exist or parsing fails.
toml_bridge_parse() {
  local _file="${1:?toml_bridge_parse expects a TOML file path}"
  shift
  local _image="${TOML_BRIDGE_IMAGE:-toml-bridge:local}"

  if [[ ! -f "${_file}" ]]; then
    _log_err toml_bridge no_such_file \
      "toml_bridge_parse: no such file: ${_file}"
    return 1
  fi

  docker run --rm -i "${_image}" "$@" < "${_file}"
}

# toml_bridge_merge [--kv] <toml-file>...
#   Type-aware merge of multiple TOML layers (lowest precedence first).
#   Scalar keys within a [table] get key-level merge; [[array of tables]]
#   get array replace. Missing files are silently skipped.
#   Default: JSON on stdout.  --kv: section\tkey\tvalue TSV lines.
#   Returns non-zero if parsing or merging fails.
toml_bridge_merge() {
  local _kv=""
  if [[ "${1:-}" == "--kv" ]]; then
    _kv="--kv"
    shift
  fi

  local _image="${TOML_BRIDGE_IMAGE:-toml-bridge:local}"
  local -a _mount_args=() _container_paths=()
  local _f _abs

  for _f in "$@"; do
    [[ -f "${_f}" ]] || continue
    _abs="$(cd -- "$(dirname -- "${_f}")" && pwd -P)/$(basename -- "${_f}")"
    _mount_args+=(-v "${_abs}:${_abs}:ro")
    _container_paths+=("${_abs}")
  done

  if (( ${#_container_paths[@]} == 0 )); then
    return 0
  fi

  docker run --rm "${_mount_args[@]}" "${_image}" \
    --merge ${_kv} "${_container_paths[@]}"
}
