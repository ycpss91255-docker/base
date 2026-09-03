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

# _load_env_optional sources the given env file when it is there, and does
# nothing at all when it is not.
#
# The distinction it draws is between a file that is MISSING and a file
# that is BROKEN. `.env.generated` is a configured consumer's
# interpolation cache: a self-managed checkout (base itself -- no
# `.setup.conf`, no `.base/` subtree, a hand-authored compose.yaml) never
# writes one and never will, so its absence is that checkout's normal
# state and not an error to report. A file that EXISTS and fails to source
# still aborts the caller, exactly as _load_env does.
#
# One rule, not five. Every wrapper faces the same question, and the
# wrappers that answered it inline are the reason three of them answered
# it differently: build.sh and prune.sh guarded the source, stop / run /
# exec did not, so `just docker build` in a base checkout minted a project
# that `just docker stop` could not end.
_load_env_optional() {
  local _env_file="${1:?_load_env_optional requires an env file path}"
  [[ -f "${_env_file}" ]] || return 0
  _load_env "${_env_file}"
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
