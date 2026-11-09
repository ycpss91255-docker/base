#!/usr/bin/env bash
#
# config_gen_layer_helper.bash -- the one copy of _layer_verdict the
# config-gen shell-half specs share (base#1442, base#1443).
#
# The caller sources dist/script/docker/lib/schema.sh, toml_bridge.sh and
# setup_cmd.sh first.

# _layer_verdict <file> -- print accept or refuse: the verdict the bridge
# and apply's per-layer checks give one layer. The bridge's --kv refusing
# it (a parse failure, a transport refusal) is refuse; so is a --tables
# table or a --kv row's section that _setup_known_section does not know, a
# key _setup_known_key does not know, or a value _schema_validate refuses.
# A [stage:*] table is skipped as _setup_conf_check_known skips it.
_layer_verdict() {
  local _file="${1}" _kv _tables _sect _key _val
  _kv="$(toml_bridge_parse "${_file}" --kv 2>/dev/null)" || { echo refuse; return 0; }
  _tables="$(toml_bridge_parse "${_file}" --tables 2>/dev/null)" || { echo refuse; return 0; }
  while IFS= read -r _sect; do
    [[ -z "${_sect}" || "${_sect}" == stage:* ]] && continue
    _setup_known_section "${_sect}" || { echo refuse; return 0; }
  done <<< "${_tables}"
  while IFS=$'\t' read -r _sect _key _val; do
    [[ -z "${_sect}${_key}" || "${_sect}" == stage:* ]] && continue
    _setup_known_section "${_sect}" || { echo refuse; return 0; }
    _setup_known_key "${_sect}" "${_key}" || { echo refuse; return 0; }
    _schema_validate "${_sect}" "${_key}" "${_val}" || { echo refuse; return 0; }
  done <<< "${_kv}"
  echo accept
}
