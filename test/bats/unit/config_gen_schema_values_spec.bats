#!/usr/bin/env bats
#
# config_gen_schema_values_spec.bats -- the shell half of "Validation
# matches schema.sh" (base#1442).
#
# why: The Go generator's schema.Validate and the shell's _schema_validate
# must accept and refuse the same values. Both read one shared table,
# dockerfile/config-gen/testdata/corpus/s6/s6_scalar_values.tsv; the Go
# half asserts what Validate answers, and this half asserts that every
# verdict in the table is what the shell answers on the bridge's text, so
# the table is the shell's word and not the Go package's.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  LIB=/source/dist/script/docker/lib
  TABLE=/source/dockerfile/config-gen/testdata/corpus/s6/s6_scalar_values.tsv
  TEXTS=/source/dockerfile/config-gen/testdata/corpus/s6/s6_scalar_texts.tsv
  export LC_ALL=C
  # shellcheck disable=SC1091
  source "${LIB}/schema.sh"
  # shellcheck disable=SC1091
  source "${LIB}/toml_bridge.sh"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# why: Each class=value row's literal goes through the bridge's --kv, the
# text the shell reads, and _schema_validate on that text must give the
# row's verdict: rc 0 for accept, non-zero for refuse. A
# `differs:wrong_type` row is one the generator refuses on purpose as a
# value outside its field's type (ADR-00000039) while the shell passes its
# text, so the shell must accept it: rc 0.
@test "s6_scalar_values: every class=value verdict is _schema_validate's on the bridge text" {
  local _class _section _key _lit _verdict _event _branch _kv _text _rc
  local _rows=0 _bad=()
  while IFS=$'\t' read -r _class _section _key _lit _verdict _event _branch; do
    [[ "${_class}" == \#* ]] && continue
    [[ "${_class}" == value ]] || { _bad+=("class ${_class}"); continue; }
    printf '[%s]\n%s = %s\n' "${_section}" "${_key}" "${_lit}" > "${TEMP_DIR}/in.toml"
    _kv="$(toml_bridge_parse "${TEMP_DIR}/in.toml" --kv)" \
      || { _bad+=("${_section}.${_key}=${_lit}: bridge failed"); continue; }
    _text="${_kv#*$'\t'*$'\t'}"
    _rc=0
    _schema_validate "${_section}" "${_key}" "${_text}" || _rc=$?
    if [[ "${_verdict}" == accept && "${_rc}" -ne 0 ]] \
      || [[ "${_verdict}" == differs:wrong_type && "${_rc}" -ne 0 ]] \
      || [[ "${_verdict}" == refuse && "${_rc}" -eq 0 ]]; then
      _bad+=("${_section}.${_key}=${_lit} (${_branch}): shell rc=${_rc}, table ${_verdict}")
    fi
    case "${_verdict}" in
      accept|refuse|differs:wrong_type) ;;
      *) _bad+=("${_section}.${_key}=${_lit}: verdict ${_verdict}") ;;
    esac
    _rows=$((_rows + 1))
  done < "${TABLE}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}

# why: Go's Scalar text for each TOML scalar kind (a local time, a local
# datetime, a fractional datetime among them) must be the text the shell
# reads from the bridge's --kv for the same literal; each row of the shared
# s6_scalar_texts.tsv names that text and the Go half asserts the same.
@test "s6_scalar_texts: every bridge-text column is the bridge's --kv text" {
  local _section _key _lit _kind _want _kv _text
  local _rows=0 _bad=()
  while IFS=$'\t' read -r _section _key _lit _kind _want; do
    [[ "${_section}" == \#* ]] && continue
    printf '[%s]\n%s = %s\n' "${_section}" "${_key}" "${_lit}" > "${TEMP_DIR}/in.toml"
    _kv="$(toml_bridge_parse "${TEMP_DIR}/in.toml" --kv)" \
      || { _bad+=("${_section}.${_key}=${_lit}: bridge failed"); continue; }
    _text="${_kv#*$'\t'*$'\t'}"
    [[ "${_text}" == "${_want}" ]] \
      || _bad+=("${_section}.${_key}=${_lit} (${_kind}): bridge text '${_text}', table '${_want}'")
    _rows=$((_rows + 1))
  done < "${TEXTS}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}
