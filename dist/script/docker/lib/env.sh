#!/usr/bin/env bash
#
# env.sh - .env file loader.
#
# Provides _load_env which sources a .env file under allexport so every
# assignment becomes an exported variable visible to `docker compose`.
#
# Split out from _lib.sh in

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_ENV_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_ENV_SOURCED=1

# _load_env sources the given .env file with allexport so every assignment
# becomes an exported variable visible to docker compose.
#
# Args:
#   $1: absolute path to .env file
_load_env() {
  local env_file="${1:?_load_env requires an env file path}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${env_file}"
  set +o allexport
}

# _env_file_value <env_file> <key> <outvar>
#
# The LAST `<key>=<value>` assignment in a generated env file, empty when
# the file or the key is absent.
#
# Deliberately not `source`: this answers a question ABOUT the file (what
# does it currently record?) rather than importing it. Sourcing would
# answer with whatever the caller's environment already exports when the
# key is absent, which is the opposite of what a "what is recorded here"
# question means -- and it would import a whole file's worth of exports to
# read one key.
_env_file_value() {
  local _file="${1:?_env_file_value requires a file}"
  local _key="${2:?_env_file_value requires a key}"
  local -n _efv_out="${3:?_env_file_value requires an outvar}"
  _efv_out=""
  [[ -f "${_file}" ]] || return 0
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ "${_line}" == "${_key}="* ]] && _efv_out="${_line#*=}"
  done < "${_file}"
  return 0
}
