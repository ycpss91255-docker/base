#!/usr/bin/env bats
#
# schema_coverage_spec.bats — registry drift guards for lib/schema.sh
# (#562, schema epic #559 phase 3).
#
# Phase 1 (#560) added the validator registry; phase 2 (#561) added the
# ordered SCHEMA_SECTIONS + accessors. These tests assert the registry
# stays internally consistent and in sync with the setup.conf template,
# so schema drift fails CI instead of surfacing as a runtime surprise:
#   - every validator name resolves to a defined function,
#   - SCHEMA_SECTIONS matches the template section headers in file order,
#   - every SCHEMA_EMPTY key is a registered validator key,
#   - every registered key is reachable via SCHEMA_SECTIONS.
#
# The i18n / kind / default coverage from the original #562 scope needs a
# registry i18n-index column that the epic deferred (a future follow-up);
# it is tracked separately and not asserted here.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/lib/schema.sh
}

@test "every SCHEMA_VALIDATOR validator name resolves to a defined function (#562)" {
  local _canon _fn _missing=""
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    _fn="${SCHEMA_VALIDATOR[${_canon}]}"
    declare -F "${_fn}" >/dev/null 2>&1 || _missing+=" ${_canon}=>${_fn}"
  done
  [ -z "${_missing}" ] || { echo "validators not defined:${_missing}"; false; }
}

@test "SCHEMA_SECTIONS matches the setup.conf template headers in file order (#562)" {
  # Registry / template drift guard: the ordered SCHEMA_SECTIONS list must
  # equal the [section] headers in the shipped template, in file order. A
  # section added to the template but not the registry (or vice versa)
  # fails here.
  local _tpl="/source/downstream/config/docker/setup.conf"
  local -a _hdrs=()
  local _line
  while IFS= read -r _line; do
    _hdrs+=("${_line}")
  done < <(grep -oE '^\[[a-z_]+\]' "${_tpl}" | tr -d '[]')
  [ "${SCHEMA_SECTIONS[*]}" = "${_hdrs[*]}" ]
}

@test "every SCHEMA_EMPTY key is a registered SCHEMA_VALIDATOR key (#562)" {
  # The empty-value policy table may only reference keys that actually
  # have a validator -- an orphan SCHEMA_EMPTY entry is dead config.
  local _k _missing=""
  for _k in "${!SCHEMA_EMPTY[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] || _missing+=" ${_k}"
  done
  [ -z "${_missing}" ] || { echo "orphan SCHEMA_EMPTY keys:${_missing}"; false; }
}

@test "every registered key is reachable via SCHEMA_SECTIONS (#562)" {
  # No validator key may be stranded under a section missing from
  # SCHEMA_SECTIONS: the count of keys reachable by walking
  # SCHEMA_SECTIONS + _schema_section_keys must equal the registry size.
  local _seen=0 _sec
  for _sec in "${SCHEMA_SECTIONS[@]}"; do
    local -a _k=()
    _schema_section_keys "${_sec}" _k
    _seen=$(( _seen + ${#_k[@]} ))
  done
  [ "${_seen}" -eq "${#SCHEMA_VALIDATOR[@]}" ]
}
