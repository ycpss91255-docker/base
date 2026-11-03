#!/usr/bin/env bats
#
# config_gen_s7_verdicts_spec.bats -- the bridge half of the S7 verdict
# manifest (base#1443).
#
# why: Every corpus/s7 fixture's expected verdict lives in one shared
# table, dockerfile/config-gen/testdata/corpus/s7/s7_verdicts.tsv, as
# S6's layers live in s6_layers.tsv. The Go half (TestCheckS7Corpus) holds
# `config-gen check` on each fixture to the row's verdict, event,
# position and key. This half holds the same row to the bridge's own
# output, so the table is not the Go package's word: a refuse row's event
# and key are read off the bridge's refusal message, an accept or a
# differs:<exception> row is one the bridge's --kv accepts, and the
# apply column is what apply's per-layer checks (_layer_verdict) give
# the fixture. Line and column are counted from the fixture bytes, since
# the bridge reports no position.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB=/source/dist/script/docker/lib
  BRIDGE_PY=/source/dockerfile/toml_bridge.py
  CORPUS=/source/dockerfile/config-gen/testdata/corpus/s7
  TABLE="${CORPUS}/s7_verdicts.tsv"
  export LC_ALL=C
  # shellcheck disable=SC1091
  source "${LIB}/schema.sh"
  # shellcheck disable=SC1091
  source "${LIB}/toml_bridge.sh"
  # shellcheck disable=SC1091
  source "${LIB}/setup_cmd.sh"
  load "${BATS_TEST_DIRNAME}/config_gen_layer_helper"
}

# _bridge_event <message> -- print "<event> <key>" for the first line of
# a bridge --kv refusal, read by the phrase the bridge words each
# refusal with, or nothing when no phrase matches. The phrases are
# written here, apart from the Go side's events, so a row is held to
# what the bridge says.
_bridge_event() {
  local _m="${1%%$'\n'*}"
  _m="${_m#toml-bridge: }"
  local _entry='^entry ([0-9]+) of ([^ ]+) '
  if [[ "${_m}" =~ ${_entry}is\ .*,\ not\ a\ table ]]; then
    printf 'conf_entry_not_table %s[%s]\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  elif [[ "${_m}" =~ ${_entry}carries\ none\ of\ the\ fields ]]; then
    printf 'conf_entry_no_gating_field %s[%s]\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  elif [[ "${_m}" =~ ${_entry}carries\ ([^ ,]+),\ which\ its\ family\ does\ not\ read ]]; then
    printf 'conf_entry_unknown_field %s[%s].%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "${_m}" =~ ${_entry}gives\ ([^ ]+)\ an\ array\ or\ a\ table ]]; then
    printf 'conf_value_type_refused %s[%s].%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "${_m}" =~ ${_entry}carries\ ([^ ]+)\ without\ ([^ ,]+), ]]; then
    printf 'conf_entry_field_needs %s[%s].%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "${_m}" =~ ^([^ ]+)\ is\ carried\ two\ ways ]]; then
    printf 'conf_family_two_spellings %s\n' "${BASH_REMATCH[1]}"
  elif [[ "${_m}" =~ ^([^ ]+)\ is\ an\ array,\ and\ no\ numbered\ family ]]; then
    printf 'conf_unknown_key %s\n' "${BASH_REMATCH[1]}"
  fi
}

# why: Each row's verdict is the bridge's --kv status on the fixture: 1
# for refuse, 0 for accept and for a differs:<exception> row, which the
# generator refuses on purpose while the bridge reads it. A refuse row's
# event and key are the ones the bridge's refusal message names, and
# every row's apply column is _layer_verdict's verdict on the fixture, so
# a fixture the generator accepts and apply refuses is recorded as such
# (base#1443).
@test "s7_verdicts: every row's verdict, event and key are the bridge's, its apply column _layer_verdict's" {
  local _fixture _verdict _event _line _col _key _apply _extra _f _rc _err _got
  local _rows=0 _bad=()
  while IFS=$'\t' read -r _fixture _verdict _event _line _col _key _apply _extra; do
    [[ "${_fixture}" == \#* ]] && continue
    [[ -n "${_apply}" && -z "${_extra}" ]] || { _bad+=("${_fixture}: want 7 columns"); continue; }
    _f="${CORPUS}/${_fixture}"
    [[ -f "${_f}" ]] || { _bad+=("${_fixture}: no such fixture"); continue; }
    _rc=0
    _err="$(python3 "${BRIDGE_PY}" --kv < "${_f}" 2>&1 >/dev/null)" || _rc=$?
    case "${_verdict}" in
      refuse)
        [[ "${_rc}" -eq 1 ]] || _bad+=("${_fixture}: bridge rc=${_rc}, table refuse")
        _got="$(_bridge_event "${_err}")"
        [[ "${_got}" == "${_event} ${_key}" ]] \
          || _bad+=("${_fixture}: bridge says '${_got}' (${_err%%$'\n'*}), table '${_event} ${_key}'") ;;
      accept)
        [[ "${_rc}" -eq 0 ]] || _bad+=("${_fixture}: bridge rc=${_rc}, table accept: ${_err%%$'\n'*}")
        [[ "${_event}${_line}${_col}${_key}" == '----' ]] || _bad+=("${_fixture}: an accept row names a refusal") ;;
      differs:?*)
        [[ "${_rc}" -eq 0 ]] || _bad+=("${_fixture}: bridge rc=${_rc}, table ${_verdict}: ${_err%%$'\n'*}")
        [[ "${_event}" != - && "${_key}" != - ]] || _bad+=("${_fixture}: a differs row names no refusal") ;;
      *) _bad+=("${_fixture}: verdict ${_verdict}") ;;
    esac
    _got="$(_layer_verdict "${_f}")"
    [[ "${_got}" == "${_apply}" ]] || _bad+=("${_fixture}: _layer_verdict ${_got}, table apply ${_apply}")
    _rows=$((_rows + 1))
  done < "${TABLE}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}

# why: The table and the corpus are held to each other both ways: every
# corpus/s7/*.toml has exactly one row and every row names a fixture, so
# a fixture added without its verdict, or a row left behind by a removed
# fixture, fails here and in the Go half (base#1443).
@test "s7_verdicts: every corpus/s7 fixture has exactly one row and every row its fixture" {
  local _f _base _n
  local _bad=()
  [ -f "${TABLE}" ]
  for _f in "${CORPUS}"/*.toml; do
    _base="${_f##*/}"
    _n="$(awk -F'\t' -v f="${_base}" '$1 == f { n++ } END { print n + 0 }' "${TABLE}")"
    [[ "${_n}" -eq 1 ]] || _bad+=("${_base}: ${_n} rows")
  done
  while IFS=$'\t' read -r _base _; do
    [[ "${_base}" == \#* ]] && continue
    [[ -f "${CORPUS}/${_base}" ]] || _bad+=("${_base}: a row with no fixture")
  done < "${TABLE}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
}
