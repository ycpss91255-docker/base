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
# row's verdict: rc 0 for accept, non-zero for refuse.
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
      || [[ "${_verdict}" == refuse && "${_rc}" -eq 0 ]]; then
      _bad+=("${_section}.${_key}=${_lit} (${_branch}): shell rc=${_rc}, table ${_verdict}")
    fi
    _rows=$((_rows + 1))
  done < "${TABLE}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}
