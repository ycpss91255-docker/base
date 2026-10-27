#!/usr/bin/env bash
# check-views.sh -- base#1395 slice 1: is every --batch view byte-identical to
# the single-view call it replaces? SPIKE ONLY.
#
# usage: check-views.sh <native|docker> <layer>...
#
# Prefetches the chain through the spike's --batch path, then for every
# cached view runs the live single-view call (cache emptied, batching off)
# and compares stdout bytes, stderr bytes and exit status. Prints one line
# per view and a final `views=N mismatches=M`. Exit 1 on any mismatch.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BASE="$(cd -- "${HERE}/../../.." && pwd -P)"
ENGINE="${1:?native|docker}"; shift
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

case "${ENGINE}" in
  native) unset TOML_BRIDGE_FORCE_DOCKER
          command -v toml-bridge > /dev/null || { echo "no toml-bridge on PATH" >&2; exit 2; } ;;
  docker) export TOML_BRIDGE_FORCE_DOCKER=1 ;;
  *) echo "engine is native or docker" >&2; exit 2 ;;
esac

# shellcheck source=/dev/null
source "${BASE}/dist/script/docker/lib/toml_bridge.sh"

TOML_BRIDGE_BATCH=1 toml_bridge_prefetch "$@"
(( ${#_TB_BATCH_RC[@]} > 0 )) || { echo "prefetch cached nothing" >&2; exit 2; }

_n=0 _bad=0
for _key in "${!_TB_BATCH_RC[@]}"; do
  (( _n++ )) || true
  _tb_batch_emit "${_key}" > "${TMP}/c.out" 2> "${TMP}/c.err"; _crc=$?
  IFS=$'\x1f' read -r -a _parts <<< "${_key}"
  _view="${_parts[0]}"; _files=("${_parts[@]:1}")
  (
    unset TOML_BRIDGE_BATCH
    _TB_BATCH_RC=() _TB_BATCH_OUT=() _TB_BATCH_ERR=() _TB_BATCH_FSIG=()
    if [[ "${_view}" == merge-kv ]]; then
      toml_bridge_merge --kv "${_files[@]}"
    else
      toml_bridge_parse "${_files[0]}" "--${_view}"
    fi
  ) > "${TMP}/l.out" 2> "${TMP}/l.err"; _lrc=$?
  _st=ok
  cmp -s "${TMP}/c.out" "${TMP}/l.out" || _st=STDOUT-DIFFERS
  cmp -s "${TMP}/c.err" "${TMP}/l.err" || _st="${_st}+STDERR-DIFFERS"
  [[ "${_crc}" == "${_lrc}" ]] || _st="${_st}+RC-${_crc}-vs-${_lrc}"
  [[ "${_st}" == ok ]] || (( _bad++ )) || true
  printf '%s\t%s\t%s\trc=%s\tbytes=%s\n' "${_st}" "${_view}" \
    "$(printf '%s ' "${_files[@]##*/}")" "${_lrc}" "$(wc -c < "${TMP}/l.out")"
done
printf 'engine=%s views=%d mismatches=%d\n' "${ENGINE}" "${_n}" "${_bad}"
(( _bad == 0 ))
