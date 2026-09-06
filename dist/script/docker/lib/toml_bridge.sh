#!/usr/bin/env bash
# toml_bridge.sh -- host-side shim for the containerised TOML parser.
#
# Provides toml_bridge_parse() which feeds a TOML file to the toml-bridge
# container (docker run) and emits JSON on stdout. The host needs Docker
# only; no Python, no pip (ADR-37 sec. Containerised parsing).

_toml_bridge_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_toml_bridge_dir}/log.sh"

# toml_bridge_parse <toml-file>
#   Parse a TOML file and output JSON on stdout.
#   Returns non-zero if the file does not exist or parsing fails.
toml_bridge_parse() {
  local _file="${1:?toml_bridge_parse expects a TOML file path}"
  local _image="${TOML_BRIDGE_IMAGE:-toml-bridge:local}"

  if [[ ! -f "${_file}" ]]; then
    _log_err toml_bridge no_such_file \
      "toml_bridge_parse: no such file: ${_file}"
    return 1
  fi

  docker run --rm -i "${_image}" < "${_file}"
}
