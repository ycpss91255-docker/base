#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf (per-repo replace / template fallback)
# ════════════════════════════════════════════════════════════════════
@test "_load_setup_conf honors SETUP_CONF env var override" {
  local _override="${TEMP_DIR}/override.conf"
  cat > "${_override}" <<'EOF'
[gpu]
mode = off
count = 0
EOF
  local -a _k=() _v=()
  SETUP_CONF="${_override}" _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_v[0]}" "off"
}

@test "_load_setup_conf uses per-repo setup.conf when section present" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf falls back to template when section absent per-repo" {
  # Per-repo setup.conf has [gpu] but NOT [gui]
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  # Template default has [gui] mode = auto
  assert_equal "${_v[0]}" "auto"
}

@test "_load_setup_conf replace strategy: per-repo section fully replaces template section" {
  # Template [gpu] has mode+count+capabilities; per-repo only sets mode=off
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = off
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  # Replace strategy: only "mode" — no count, no capabilities inherited
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "mode"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_value / _get_conf_list_sorted
# ════════════════════════════════════════════════════════════════════
@test "_get_conf_value returns value for present key" {
  local -a _k=("mode" "count") _v=("auto" "all")
  local _out
  _get_conf_value _k _v "mode" "DEFAULT" _out
  assert_equal "${_out}" "auto"
}

@test "_get_conf_value returns default for absent key" {
  local -a _k=("mode") _v=("auto")
  local _out
  _get_conf_value _k _v "missing" "DEFAULT" _out
  assert_equal "${_out}" "DEFAULT"
}

@test "_get_conf_list_sorted returns values sorted by numeric suffix" {
  local -a _k=("mount_3" "mount_1" "mount_10" "mount_2")
  local -a _v=("/three:/three" "/one:/one" "/ten:/ten" "/two:/two")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "4"
  assert_equal "${_out[0]}" "/one:/one"
  assert_equal "${_out[1]}" "/two:/two"
  assert_equal "${_out[2]}" "/three:/three"
  assert_equal "${_out[3]}" "/ten:/ten"
}

@test "_get_conf_list_sorted skips non-matching keys" {
  local -a _k=("mount_1" "mode" "mount_2")
  local -a _v=("/a:/a" "auto" "/b:/b")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "2"
  assert_equal "${_out[0]}" "/a:/a"
  assert_equal "${_out[1]}" "/b:/b"
}

# ════════════════════════════════════════════════════════════════════
# _rule_basename
# ════════════════════════════════════════════════════════════════════
@test "_rule_basename returns last non-empty path component" {
  result="$(_rule_basename "/home/user/my_project")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename skips trailing slashes" {
  result="$(_rule_basename "/home/user/my_project/")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename handles single-component path" {
  result="$(_rule_basename "justname")"
  assert_equal "${result}" "justname"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_list_sorted skips empty values
# ════════════════════════════════════════════════════════════════════
@test "_get_conf_list_sorted skips entries with empty value" {
  local -a _k=("mount_1" "mount_2" "mount_3") _v=("" "/b:/b" "")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "1"
  assert_equal "${_out[0]}" "/b:/b"
}
