#!/usr/bin/env bats
#
# toml_config_wiring_spec.bats -- verify conf.sh / setup_conf.sh / env_emit.sh
# wire TOML config files (setup.toml, .env.toml, setup.local.toml,
# .env.local.toml) instead of their legacy INI counterparts.
#
# D1: setup.toml as the primary config source.
# D2: .env.toml + .env.local.toml wiring.
#
# Pure path + file tests -- no docker interaction needed.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  TEMP_DIR="$(mktemp -d)"
  export _SETUP_SCRIPT_DIR="${TEMP_DIR}/dist/script/docker/setup"
  mkdir -p "${_SETUP_SCRIPT_DIR}"
  # The template dist root is three levels above _SETUP_SCRIPT_DIR.
  DIST_ROOT="${TEMP_DIR}/dist"
  mkdir -p "${DIST_ROOT}"

  BASE_PATH="${TEMP_DIR}/repo"
  mkdir -p "${BASE_PATH}"

  # Source libs under test.
  # shellcheck source=dist/script/docker/lib/setup_conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/setup_conf.sh
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# D1: _setup_conf_layers emits TOML paths
# ════════════════════════════════════════════════════════════════════

# why: The layer chain must resolve to setup.toml paths; a stale .setup.conf path silently bypasses the TOML parser.
@test "_setup_conf_layers returns setup.toml layer chain" {
  local -a layers=()
  _setup_conf_layers "${BASE_PATH}" layers

  # Template layer: <dist>/setup.toml
  assert_equal "${layers[0]}" "${DIST_ROOT}/setup.toml"
  # Repo layer: <base>/setup.toml
  assert_equal "${layers[1]}" "${BASE_PATH}/setup.toml"
  # Local layer: <base>/setup.local.toml
  assert_equal "${layers[2]}" "${BASE_PATH}/setup.local.toml"
}

# why: An explicit template_dist override must land in the layer chain, not silently fall back to the default.
@test "_setup_conf_layers with explicit template_dist uses that dir's setup.toml" {
  local _alt_dist="${TEMP_DIR}/alt_dist"
  mkdir -p "${_alt_dist}"

  local -a layers=()
  _setup_conf_layers "${BASE_PATH}" layers "${_alt_dist}"

  assert_equal "${layers[0]}" "${_alt_dist}/setup.toml"
  assert_equal "${layers[1]}" "${BASE_PATH}/setup.toml"
  assert_equal "${layers[2]}" "${BASE_PATH}/setup.local.toml"
}

# why: A missing template dir must shrink the chain rather than inject a nonexistent path that breaks conf loading.
@test "_setup_conf_layers omits template when no _SETUP_SCRIPT_DIR and no explicit dist" {
  unset _SETUP_SCRIPT_DIR

  local -a layers=()
  _setup_conf_layers "${BASE_PATH}" layers

  # Only repo + local layers, no template.
  assert_equal "${#layers[@]}" 2
  assert_equal "${layers[0]}" "${BASE_PATH}/setup.toml"
  assert_equal "${layers[1]}" "${BASE_PATH}/setup.local.toml"
}

# ════════════════════════════════════════════════════════════════════
# D1: _setup_conf_local_path returns setup.local.toml
# ════════════════════════════════════════════════════════════════════

# why: The per-worktree override must resolve to setup.local.toml; a stale .setup.conf.local path loses operator overrides.
@test "_setup_conf_local_path returns setup.local.toml" {
  run _setup_conf_local_path "${BASE_PATH}"
  assert_success
  assert_output "${BASE_PATH}/setup.local.toml"
}

# ════════════════════════════════════════════════════════════════════
# D2: _scaffold_env_local creates .env.local.toml
# ════════════════════════════════════════════════════════════════════

# why: The TOML scaffold must be created on first run; without it operators have no guidance for the override format.
@test "_scaffold_env_local creates .env.local.toml when absent" {
  # Source env_emit.sh (it needs _setup_msg which we stub).
  _setup_msg() { echo "stub"; }
  export -f _setup_msg
  # shellcheck source=dist/script/docker/lib/env_emit.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/env_emit.sh

  local _target="${BASE_PATH}/.env.local.toml"
  [[ ! -e "${_target}" ]]

  _scaffold_env_local "${_target}"
  [[ -f "${_target}" ]]

  # The scaffold should contain TOML guidance.
  run grep -i 'toml' "${_target}"
  assert_success
}

# why: Idempotency -- re-running setup must not destroy operator-authored overrides.
@test "_scaffold_env_local does not overwrite existing .env.local.toml" {
  _setup_msg() { echo "stub"; }
  export -f _setup_msg
  # shellcheck source=dist/script/docker/lib/env_emit.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/env_emit.sh

  local _target="${BASE_PATH}/.env.local.toml"
  echo "MY_SECRET=42" > "${_target}"

  _scaffold_env_local "${_target}"
  run cat "${_target}"
  assert_output "MY_SECRET=42"
}

# ════════════════════════════════════════════════════════════════════
# D2: gitignore includes TOML local overrides
# ════════════════════════════════════════════════════════════════════

# why: A missing gitignore entry lets the per-worktree TOML override get committed, leaking local config into the repo.
@test "canonical gitignore entries include setup.local.toml" {
  # shellcheck source=dist/script/docker/lib/gitignore.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh

  run _canonical_gitignore_entries
  assert_success
  assert_line "setup.local.toml"
}

# why: Without this entry the service env override file gets committed, leaking secrets or per-machine tuning.
@test "canonical gitignore entries include .env.local.toml" {
  # shellcheck source=dist/script/docker/lib/gitignore.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh

  run _canonical_gitignore_entries
  assert_success
  assert_line ".env.local.toml"
}

# ════════════════════════════════════════════════════════════════════
# D1: _is_self_managed_repo checks setup.toml
# ════════════════════════════════════════════════════════════════════

# why: A repo with setup.toml is template-managed; misclassifying it skips the conf layer chain entirely.
@test "_is_self_managed_repo is false when setup.toml exists" {
  # shellcheck source=dist/script/docker/lib/compose.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/compose.sh 2>/dev/null || true

  local _repo="${TEMP_DIR}/consumer_repo"
  mkdir -p "${_repo}/.base"
  touch "${_repo}/setup.toml"

  run _is_self_managed_repo "${_repo}"
  assert_failure
}

# why: The complement of the previous test; a bare directory with no template markers must be classified as self-managed.
@test "_is_self_managed_repo is true when neither .base nor setup.toml exist" {
  source /source/dist/script/docker/lib/compose.sh 2>/dev/null || true

  local _repo="${TEMP_DIR}/self_managed"
  mkdir -p "${_repo}"

  run _is_self_managed_repo "${_repo}"
  assert_success
}
