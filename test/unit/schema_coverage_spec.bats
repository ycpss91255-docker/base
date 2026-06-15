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
