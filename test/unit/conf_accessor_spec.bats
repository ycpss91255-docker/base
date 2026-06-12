#!/usr/bin/env bats
#
# Unit tests for the conf.sh opaque accessor interface (#564).
#
# The accessor verbs (_conf_load / _conf_get / _conf_list / _conf_sections)
# hide conf.sh's internal parallel-array + namespacing representation: callers
# load a handle once and query it by (section, key) without touching arrays.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/script/docker/lib/conf.sh
  FIX="$(mktemp)"
  cat > "${FIX}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 2

[network]
net = host
EOF
}

teardown() {
  rm -f "${FIX}"
}

@test "_conf_get returns a value by section and key" {
  _conf_load "${FIX}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "auto"
}

@test "_conf_sections lists section names in first-appearance order" {
  _conf_load "${FIX}" H
  run _conf_sections H
  assert_success
  assert_line --index 0 "deploy"
  assert_line --index 1 "network"
}

@test "_conf_list lists a section's keys in file order" {
  _conf_load "${FIX}" H
  run _conf_list H deploy
  assert_success
  assert_line --index 0 "gpu_runtime"
  assert_line --index 1 "gpu_count"
}

@test "_conf_load_merged: repo section replaces template section wholesale" {
  local _tpl _repo
  _tpl="$(mktemp)"; _repo="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 0

[build]
arg_1 = FROM_TEMPLATE
EOF
  cat > "${_repo}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  _conf_load_merged "${_tpl}" "${_repo}" M
  run _conf_get M deploy gpu_runtime
  assert_success
  assert_output "nvidia"
  run _conf_get M deploy gpu_count missing
  assert_output "missing"
  run _conf_get M build arg_1
  assert_output "FROM_TEMPLATE"
  rm -f "${_tpl}" "${_repo}"
}

@test "_conf_list_sorted returns prefix_N values in numeric order, skipping empties" {
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_2 = b
mount_10 = c
mount_1 = a
mount_3 =
EOF
  _conf_load "${_f}" H
  local -a out=()
  _conf_list_sorted H volumes mount_ out
  assert_equal "${#out[@]}" 3
  assert_equal "${out[0]}" a
  assert_equal "${out[1]}" b
  assert_equal "${out[2]}" c
  rm -f "${_f}"
}
