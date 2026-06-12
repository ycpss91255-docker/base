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

# ════════════════════════════════════════════════════════════════════
# _schema_validate — per-service logging section normalisation
# ([logging.<svc>] shares the [logging] key validators) + empty=allow
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate routes logging.driver to _validate_log_driver (accept)" {
  run _schema_validate logging driver "json-file"
  [ "${status}" -eq 0 ]
}

@test "_schema_validate routes logging.driver to _validate_log_driver (reject)" {
  run _schema_validate logging driver "bad driver!"
  [ "${status}" -ne 0 ]
}

@test "_schema_validate allows empty logging.driver (empty policy = allow)" {
  run _schema_validate logging driver ""
  [ "${status}" -eq 0 ]
}

@test "_schema_validate normalises logging.<svc> to the logging key set (reject)" {
  run _schema_validate logging.test driver "bad driver!"
  [ "${status}" -ne 0 ]
}

@test "_schema_validate normalises logging.<svc> to the logging key set (accept)" {
  run _schema_validate logging.devel driver "journald"
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — full registry coverage (parity with the validators
# that setup.sh AND the TUI wire). Table-driven: each row is
# "<section>|<key>|<value>|<expect: ok|fail>". This is the union: keys
# the TUI validated but setup.sh historically accepted (target_arch /
# build_network / gpu_runtime / runtime alias / network.name /
# devices.device_ / security.cap_add_ / cap_drop_) are now rejected by
# BOTH paths — the divergence #560 closes.
# ════════════════════════════════════════════════════════════════════

# Helper: assert _schema_validate verdict for one row.
_assert_schema() {
  local _section="$1" _key="$2" _value="$3" _expect="$4"
  if _schema_validate "${_section}" "${_key}" "${_value}"; then
    [[ "${_expect}" == "ok" ]] \
      || { echo "expected FAIL but ACCEPTED: ${_section}.${_key} = '${_value}'"; return 1; }
  else
    [[ "${_expect}" == "fail" ]] \
      || { echo "expected ACCEPT but REJECTED: ${_section}.${_key} = '${_value}'"; return 1; }
  fi
}

@test "_schema_validate accepts every registered key's valid sample" {
  _assert_schema resources shm_size "2gb" ok
  _assert_schema lifecycle restart "unless-stopped" ok
  _assert_schema build target_arch "arm64" ok
  _assert_schema build build_network "host" ok
  _assert_schema deploy gpu_runtime "nvidia" ok
  _assert_schema deploy runtime "auto" ok
  _assert_schema network name "my_net" ok
  _assert_schema logging max_size "10m" ok
  _assert_schema logging max_file "3" ok
  _assert_schema logging compress "true" ok
  _assert_schema logging local_path "/var/log/app" ok
  _assert_schema volumes mount_1 "/data:/data:ro" ok
  _assert_schema devices device_1 "/dev/snd:/dev/snd" ok
  _assert_schema devices cgroup_rule_1 "c 81:* rmw" ok
  _assert_schema environment env_1 "FOO=bar" ok
  _assert_schema additional_contexts context_1 "repo=.." ok
  _assert_schema security cap_add_1 "SYS_ADMIN" ok
  _assert_schema security cap_drop_1 "NET_RAW" ok
}

@test "_schema_validate rejects every registered key's invalid sample" {
  _assert_schema resources shm_size "huge" fail
  _assert_schema lifecycle restart "sometimes" fail
  _assert_schema build target_arch "sparc" fail
  _assert_schema build build_network "carrier-pigeon" fail
  _assert_schema deploy gpu_runtime "podman" fail
  _assert_schema deploy runtime "podman" fail
  _assert_schema network name "-bad" fail
  _assert_schema logging max_size "10petabytes" fail
  _assert_schema logging max_file "0" fail
  _assert_schema logging compress "maybe" fail
  _assert_schema logging local_path $'has\nnewline' fail
  _assert_schema volumes mount_1 "noslash" fail
  _assert_schema devices device_1 "noslash" fail
  _assert_schema devices cgroup_rule_1 "bogus" fail
  _assert_schema environment env_1 "1BAD=x" fail
  _assert_schema additional_contexts context_1 "noequals" fail
  _assert_schema security cap_add_1 "lowercase" fail
  _assert_schema security cap_drop_1 "has space" fail
}

@test "_schema_validate allows empty (clear) for every list + clearable scalar key" {
  _assert_schema resources shm_size "" ok
  _assert_schema lifecycle restart "" ok
  _assert_schema build target_arch "" ok
  _assert_schema network name "" ok
  _assert_schema volumes mount_1 "" ok
  _assert_schema devices device_1 "" ok
  _assert_schema environment env_1 "" ok
  _assert_schema security cap_add_1 "" ok
}

@test "_schema_validate accepts free-form (unregistered) keys" {
  _assert_schema tmpfs tmpfs_1 "/run:size=64m" ok
  _assert_schema security security_opt_1 "anything goes" ok
  _assert_schema image rule_1 "whatever" ok
}
