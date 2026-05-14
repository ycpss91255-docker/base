#!/usr/bin/env bats
#
# Tests for [logging] / [logging.<svc>] support in generate_compose_yaml
# and the supporting _collect_logging / _parse_logging_svc_sections
# parsers in script/docker/setup.sh. Closes #310.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  CONF_FILE="${TEMP_DIR}/setup.conf"
}

teardown() {
  unset SETUP_CONF
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: logging block emission
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml omits logging: block when both inputs empty (back-compat)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "" ""
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits logging: block on devel from global [logging]" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s\n%s' \
    "driver=json-file" "max_size=10m" "max_file=3" "compress=true"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'driver: json-file' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "10m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-file: "3"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'compress: "true"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits logging on test service" {
  local _extras=()
  local _global="driver=local"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # The test service block sits after devel; assert the logging line
  # appears at least twice (once for devel, once for test).
  run grep -c -E '^    logging:$' "${COMPOSE_OUT}"
  assert_success
  [[ "${output}" -ge 2 ]]
}

@test "generate_compose_yaml driver-only [logging] omits options: block" {
  local _extras=()
  local _global="driver=syslog"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F 'driver: syslog' "${COMPOSE_OUT}"
  assert_success
  run grep -E '^      options:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml partial options emits only set keys" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -E '^      options:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "50m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-file' "${COMPOSE_OUT}"
  assert_failure
  run grep -F 'compress' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml per-svc [logging.<svc>] overrides global key on that svc" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s' "driver=json-file" "max_size=10m" "max_file=3"
  local _per_svc="test:max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # Both 10m (devel/global) and 50m (test override) should appear.
  run grep -F 'max-size: "10m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "50m"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml per-svc [logging.<svc>] inherits keys absent in override" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s' "driver=json-file" "max_size=10m" "max_file=3"
  local _per_svc="test:max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # The `test` service's logging block must still emit max-file (inherited).
  # Slice from the second `logging:` line onward and assert max-file appears.
  run awk '/^    logging:$/ { c++ } c >= 2 { print }' "${COMPOSE_OUT}"
  assert_success
  echo "${output}" | grep -F 'max-file: "3"'
}

# ════════════════════════════════════════════════════════════════════
# _parse_logging_svc_sections
# ════════════════════════════════════════════════════════════════════

@test "_parse_logging_svc_sections enumerates services in file order" {
  cat > "${CONF_FILE}" <<'CONF'
[logging]
driver = json-file

[logging.runtime]
max_size = 50m

[logging.devel]
compress = false
CONF
  local -a _svcs=()
  _parse_logging_svc_sections "${CONF_FILE}" _svcs
  [[ "${#_svcs[@]}" -eq 2 ]]
  [[ "${_svcs[0]}" == "runtime" ]]
  [[ "${_svcs[1]}" == "devel" ]]
}

@test "_parse_logging_svc_sections ignores plain [logging] section" {
  cat > "${CONF_FILE}" <<'CONF'
[logging]
driver = json-file
CONF
  local -a _svcs=()
  _parse_logging_svc_sections "${CONF_FILE}" _svcs
  [[ "${#_svcs[@]}" -eq 0 ]]
}

@test "_parse_logging_svc_sections returns empty when file does not exist" {
  local -a _svcs=()
  _parse_logging_svc_sections "/no/such/file" _svcs
  [[ "${#_svcs[@]}" -eq 0 ]]
}

# ════════════════════════════════════════════════════════════════════
# _collect_logging
# ════════════════════════════════════════════════════════════════════

@test "_collect_logging reads global [logging] from per-repo setup.conf" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[logging]
driver = local
max_size = 20m
CONF
  local _g="" _p=""
  _collect_logging "${TEMP_DIR}" _g _p
  [[ "${_g}" == *"driver=local"* ]]
  [[ "${_g}" == *"max_size=20m"* ]]
  [[ -z "${_p}" ]]
}

@test "_collect_logging reads per-service [logging.<svc>] sections" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[logging]
driver = json-file

[logging.runtime]
max_size = 100m
compress = false
CONF
  local _g="" _p=""
  _collect_logging "${TEMP_DIR}" _g _p
  [[ "${_p}" == *"runtime:max_size=100m"* ]]
  [[ "${_p}" == *"runtime:compress=false"* ]]
}

@test "_collect_logging returns empty when no [logging] sections anywhere" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[image]
rule_1 = @basename
CONF
  local _g="" _p=""
  # Force template fallback to also miss (point _SETUP_SCRIPT_DIR at a
  # path whose ../../config/docker/setup.conf does not exist).
  local _save="${_SETUP_SCRIPT_DIR:-}"
  _SETUP_SCRIPT_DIR="${TEMP_DIR}/nonexistent/docker"
  _collect_logging "${TEMP_DIR}" _g _p
  _SETUP_SCRIPT_DIR="${_save}"
  [[ -z "${_g}" ]]
  [[ -z "${_p}" ]]
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: [logging] local_path bind mount + LOG_FILE_PATH (#328)
# ════════════════════════════════════════════════════════════════════

@test "local_path on global emits volumes mount + LOG_FILE_PATH env for devel (#328)" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "local_path=./logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # Volume mount on devel: <resolved>:/var/log/myrepo
  run grep -F ":/var/log/myrepo" "${COMPOSE_OUT}"
  assert_success
  # LOG_FILE_PATH env on devel
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/devel.log" "${COMPOSE_OUT}"
  assert_success
}

@test "local_path empty omits mount + env (back-compat) (#328)" {
  local _extras=()
  local _global="driver=json-file"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F "LOG_FILE_PATH" "${COMPOSE_OUT}"
  assert_failure
  run grep -F "/var/log/myrepo" "${COMPOSE_OUT}"
  assert_failure
}

@test "local_path on per-svc [logging.<svc>] emits LOG_FILE_PATH for that svc only (#328)" {
  local _extras=()
  local _global="driver=json-file"
  # Per-svc test gets its own local_path but devel inherits empty global.
  local _per_svc="test:local_path=./test-logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # test service: LOG_FILE_PATH=/var/log/myrepo/test.log
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/test.log" "${COMPOSE_OUT}"
  assert_success
  # devel service has no LOG_FILE_PATH (global didn't set local_path)
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/devel.log" "${COMPOSE_OUT}"
  assert_failure
}

@test "local_path absolute path is passed through verbatim (#328)" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "local_path=/srv/logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F "/srv/logs:/var/log/myrepo" "${COMPOSE_OUT}"
  assert_success
}

@test "local_path is NOT emitted as a logging.options key (driver-only options) (#328)" {
  local _extras=()
  # local_path with no other [logging] keys should not produce an
  # `options:` block — local_path is not a docker logging option.
  local _global="local_path=./logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # Volume + env still emitted.
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/devel.log" "${COMPOSE_OUT}"
  assert_success
  # But no docker `logging:` mapping (no driver / no options).
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_failure
  run grep -F "local_path" "${COMPOSE_OUT}"
  assert_failure
}

@test "local_path on test service emits standalone volumes block + env (#328)" {
  local _extras=()
  local _global="driver=json-file"
  local _per_svc="test:local_path=./test-logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # test stanza has its own volumes + environment.
  run awk '/^  test:/ { c=1 } c { print }' "${COMPOSE_OUT}"
  assert_success
  echo "${output}" | grep -F "LOG_FILE_PATH=/var/log/myrepo/test.log"
  echo "${output}" | grep -F ":/var/log/myrepo"
}

# ════════════════════════════════════════════════════════════════════
# _logging_svc_local_path_mount helper (#328)
# ════════════════════════════════════════════════════════════════════
#
# `_logging_svc_local_path_mount` lives inside generate_compose_yaml as
# a nested function — exercise it indirectly via the compose-emit
# tests above (the resolved host:container string lands in
# compose.yaml). Direct unit isolation would require exporting the
# helper, which we avoid to keep the scope encapsulation; instead,
# these end-to-end assertions cover the same resolution branches
# (relative / absolute / per-svc / empty fall-through).

# ════════════════════════════════════════════════════════════════════
# _sync_logging_local_paths_gitignore (#328)
# ════════════════════════════════════════════════════════════════════

@test "_sync_logging_local_paths_gitignore appends relative local_path to .gitignore (#328)" {
  local _gitignore="${TEMP_DIR}/.gitignore"
  : > "${_gitignore}"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "local_path=./logs/" ""
  run grep -xF "/logs/" "${_gitignore}"
  assert_success
  run grep -xF "# managed by template: [logging] local_path (do not remove)" "${_gitignore}"
  assert_success
}

@test "_sync_logging_local_paths_gitignore skips absolute paths (#328)" {
  local _gitignore="${TEMP_DIR}/.gitignore"
  : > "${_gitignore}"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "local_path=/srv/logs/" ""
  run grep -F "/srv/logs" "${_gitignore}"
  assert_failure
}

@test "_sync_logging_local_paths_gitignore skips ~ paths (#328)" {
  local _gitignore="${TEMP_DIR}/.gitignore"
  : > "${_gitignore}"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "local_path=~/logs/" ""
  run grep -F "~/logs" "${_gitignore}"
  assert_failure
}

@test "_sync_logging_local_paths_gitignore is idempotent (#328)" {
  local _gitignore="${TEMP_DIR}/.gitignore"
  : > "${_gitignore}"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "local_path=./logs/" ""
  local _first
  _first="$(cat "${_gitignore}")"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "local_path=./logs/" ""
  [[ "$(cat "${_gitignore}")" == "${_first}" ]]
}

@test "_sync_logging_local_paths_gitignore collects from both global + per-svc (#328)" {
  local _gitignore="${TEMP_DIR}/.gitignore"
  : > "${_gitignore}"
  local _per_svc=""
  printf -v _per_svc '%s\n%s' "devel:local_path=./devel-logs/" "test:local_path=./test-logs/"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "local_path=./global-logs/" "${_per_svc}"
  run grep -xF "/global-logs/" "${_gitignore}"
  assert_success
  run grep -xF "/devel-logs/" "${_gitignore}"
  assert_success
  run grep -xF "/test-logs/" "${_gitignore}"
  assert_success
}

@test "_sync_logging_local_paths_gitignore is no-op when no local_path keys (#328)" {
  local _gitignore="${TEMP_DIR}/.gitignore"
  : > "${_gitignore}"
  _sync_logging_local_paths_gitignore "${TEMP_DIR}" "driver=json-file" ""
  # File should be unchanged (still empty).
  [[ ! -s "${_gitignore}" ]]
}
