#!/usr/bin/env bats
#
# schema_spec.bats — unit tests for the setup.conf validation registry
# (lib/schema.sh, #560, epic #559).
#
# `_schema_validate <section> <key> <value>` is the single validation
# gate routed through by BOTH setup.sh (set/add) and the TUI. The
# registry maps a canonical (section,key) to the validator that lives in
# _tui_conf.sh; the dispatcher normalises per-service logging sections
# and numbered list keys before lookup.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/lib/schema.sh
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — list keys (numbered suffix normalised to prefix)
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate routes network.port_N to _validate_port_mapping (accept)" {
  run _schema_validate network port_1 "8080:80"
  [ "${status}" -eq 0 ]
}

@test "_schema_validate routes network.port_N to _validate_port_mapping (reject)" {
  run _schema_validate network port_1 "not-a-port"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — scalar keys (exact match) + empty-value policy
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate routes deploy.gpu_count to _validate_gpu_count (accept)" {
  run _schema_validate deploy gpu_count "all"
  [ "${status}" -eq 0 ]
}

@test "_schema_validate routes deploy.gpu_count to _validate_gpu_count (reject)" {
  run _schema_validate deploy gpu_count "-1"
  [ "${status}" -ne 0 ]
}

@test "_schema_validate rejects empty deploy.gpu_count (empty policy = validate)" {
  run _schema_validate deploy gpu_count ""
  [ "${status}" -ne 0 ]
}
