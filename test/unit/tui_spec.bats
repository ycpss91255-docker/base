#!/usr/bin/env bats
#
# tui_spec.bats — pure-logic unit tests for the TUI support libraries.
# Focuses on validators, INI round-trip, and mount-string parsing. No
# interactive dialog/whiptail calls are exercised here (see
# tui_backend_spec.bats and tui_flow.bats for those).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/_tui_conf.sh

  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _validate_mount
# ════════════════════════════════════════════════════════════════════

@test "_validate_mount accepts simple host:container" {
  _validate_mount "/data:/data"
}

@test "_validate_mount accepts host:container:ro" {
  _validate_mount "/etc/machine-id:/etc/machine-id:ro"
}

@test "_validate_mount accepts host:container:rw" {
  _validate_mount "/cache:/cache:rw"
}

@test "_validate_mount accepts paths with env var expansion" {
  _validate_mount '${HOME}/.ssh:/root/.ssh:ro'
}

@test "_validate_mount rejects empty string" {
  run _validate_mount ""
  [ "${status}" -ne 0 ]
}

@test "_validate_mount rejects missing colon" {
  run _validate_mount "/data"
  [ "${status}" -ne 0 ]
}

@test "_validate_mount rejects invalid mode" {
  run _validate_mount "/data:/data:xx"
  [ "${status}" -ne 0 ]
}

@test "_validate_mount rejects too many colons" {
  run _validate_mount "/a:/b:/c:/d"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_shm_size
# ════════════════════════════════════════════════════════════════════

@test "_validate_shm_size accepts sizes with units (2gb, 512mb, 1024k, 8g, 100b)" {
  _validate_shm_size "2gb"
  _validate_shm_size "512mb"
  _validate_shm_size "1024k"
  _validate_shm_size "8g"
  _validate_shm_size "100b"
}

@test "_validate_shm_size accepts uppercase units (2GB, 512MB)" {
  _validate_shm_size "2GB"
  _validate_shm_size "512MB"
  _validate_shm_size "8G"
}

@test "_validate_shm_size rejects missing unit" {
  run _validate_shm_size "2"
  [ "${status}" -ne 0 ]
}

@test "_validate_shm_size rejects non-numeric / bad unit / empty" {
  run _validate_shm_size "abc"
  [ "${status}" -ne 0 ]
  run _validate_shm_size "2xy"
  [ "${status}" -ne 0 ]
  run _validate_shm_size "2 gb"
  [ "${status}" -ne 0 ]
  run _validate_shm_size ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_port_mapping
# ════════════════════════════════════════════════════════════════════

@test "_validate_port_mapping accepts host:container" {
  _validate_port_mapping "8080:80"
  _validate_port_mapping "5000:5000"
  _validate_port_mapping "65535:1"
}

@test "_validate_port_mapping accepts optional /tcp or /udp" {
  _validate_port_mapping "8080:80/tcp"
  _validate_port_mapping "5000:5000/udp"
}

@test "_validate_port_mapping rejects bad formats" {
  run _validate_port_mapping "8080"
  [ "${status}" -ne 0 ]
  run _validate_port_mapping "a:b"
  [ "${status}" -ne 0 ]
  run _validate_port_mapping "8080:80/sctp"
  [ "${status}" -ne 0 ]
  run _validate_port_mapping ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_env_kv
# ════════════════════════════════════════════════════════════════════

@test "_validate_env_kv accepts KEY=VALUE and KEY= (empty value)" {
  _validate_env_kv "ROS_DOMAIN_ID=7"
  _validate_env_kv "DEBUG="
  _validate_env_kv "FOO_BAR=quoted value"
  _validate_env_kv "_UNDERSCORE=ok"
  _validate_env_kv "lower=case_ok"
}

@test "_validate_env_kv rejects missing = or bad key start" {
  run _validate_env_kv "NO_EQUALS"
  [ "${status}" -ne 0 ]
  run _validate_env_kv "123BAD=val"
  [ "${status}" -ne 0 ]
  run _validate_env_kv "=value"
  [ "${status}" -ne 0 ]
  run _validate_env_kv ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_network_name
# ════════════════════════════════════════════════════════════════════

@test "_validate_network_name accepts docker-compatible names" {
  _validate_network_name "my_bridge"
  _validate_network_name "bridge-1"
  _validate_network_name "prod.env"
  _validate_network_name "a"
}

@test "_validate_network_name rejects invalid leading chars / spaces" {
  run _validate_network_name "bad name"
  [ "${status}" -ne 0 ]
  run _validate_network_name "-starts-with-dash"
  [ "${status}" -ne 0 ]
  run _validate_network_name ".leading-dot"
  [ "${status}" -ne 0 ]
  run _validate_network_name "with/slash"
  [ "${status}" -ne 0 ]
  run _validate_network_name ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_capability
# ════════════════════════════════════════════════════════════════════

@test "_validate_capability accepts ALL_CAPS names" {
  _validate_capability "SYS_ADMIN"
  _validate_capability "NET_ADMIN"
  _validate_capability "ALL"
  _validate_capability "MKNOD"
}

@test "_validate_capability rejects lowercase / mixed case" {
  run _validate_capability "sys_admin"
  [ "${status}" -ne 0 ]
  run _validate_capability "Sys_Admin"
  [ "${status}" -ne 0 ]
}

@test "_validate_capability rejects digits / empty" {
  run _validate_capability "SYS_ADMIN1"
  [ "${status}" -ne 0 ]
  run _validate_capability ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_gpu_count
# ════════════════════════════════════════════════════════════════════

@test "_validate_gpu_count accepts 'all'" {
  _validate_gpu_count "all"
}

@test "_validate_gpu_count accepts positive integer" {
  _validate_gpu_count "1"
  _validate_gpu_count "4"
}

@test "_validate_gpu_count rejects zero" {
  run _validate_gpu_count "0"
  [ "${status}" -ne 0 ]
}

@test "_validate_gpu_count rejects negative" {
  run _validate_gpu_count "-1"
  [ "${status}" -ne 0 ]
}

@test "_validate_gpu_count rejects non-numeric" {
  run _validate_gpu_count "abc"
  [ "${status}" -ne 0 ]
}

@test "_validate_gpu_count rejects empty" {
  run _validate_gpu_count ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_enum
# ════════════════════════════════════════════════════════════════════

@test "_validate_enum accepts matching option" {
  _validate_enum "host" "host" "bridge" "none"
}

@test "_validate_enum rejects non-matching value" {
  run _validate_enum "overlay" "host" "bridge" "none"
  [ "${status}" -ne 0 ]
}

@test "_validate_enum rejects empty value" {
  run _validate_enum "" "a" "b"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _mount_host_path
# ════════════════════════════════════════════════════════════════════

@test "_mount_host_path extracts plain host path" {
  local _host=""
  _mount_host_path "/data:/data" _host
  assert_equal "${_host}" "/data"
}

@test "_mount_host_path extracts host path with mode" {
  local _host=""
  _mount_host_path "/data:/data:ro" _host
  assert_equal "${_host}" "/data"
}

@test "_mount_host_path extracts host path with env var" {
  local _host=""
  _mount_host_path '${WS_PATH}:/home/${USER_NAME}/work' _host
  assert_equal "${_host}" '${WS_PATH}'
}

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf_full + _write_setup_conf (INI round-trip)
# ════════════════════════════════════════════════════════════════════

@test "_load_setup_conf_full reads all sections preserving order" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rules = @default:foo

[build]
apt_mirror_ubuntu = tw.example.com
apt_mirror_debian = debian.example.com

[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
EOF
  local -a _sections=() _keys=() _values=()
  _load_setup_conf_full "${TEMP_DIR}/setup.conf" _sections _keys _values

  assert_equal "${_sections[0]}" "image"
  assert_equal "${_sections[1]}" "build"
  assert_equal "${_sections[2]}" "volumes"
}

@test "_load_setup_conf_full reads key/value pairs" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = auto
gpu_count = 2
EOF
  local -a _sections=() _keys=() _values=()
  _load_setup_conf_full "${TEMP_DIR}/setup.conf" _sections _keys _values

  # Entries are section-scoped key=value; format is
  #   _keys[i]="<section>.<key>", _values[i]="<value>"
  local _found_mode=""
  local i
  for (( i=0; i<${#_keys[@]}; i++ )); do
    if [[ "${_keys[i]}" == "deploy.gpu_mode" ]]; then
      _found_mode="${_values[i]}"
    fi
  done
  assert_equal "${_found_mode}" "auto"
}

@test "_write_setup_conf preserves template comments and section order" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
# Top comment
# Another line

[image]
# describe rules
rules = @default:orig

[build]
apt_mirror_ubuntu =
EOF
  local -a _sections=(image build) _keys=(image.rules build.apt_mirror_ubuntu) \
    _values=("@default:newval" "tw.archive.example.com")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  [ "${status}" -eq 0 ]
  # Preserves top comment
  [[ "${output}" == *"# Top comment"* ]]
  # Preserves section comment
  [[ "${output}" == *"# describe rules"* ]]
  # Substituted values
  [[ "${output}" == *"rules = @default:newval"* ]]
  [[ "${output}" == *"apt_mirror_ubuntu = tw.archive.example.com"* ]]
}

@test "_write_setup_conf keeps template value when key not in overrides" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[network]
mode = host
ipc = host
privileged = true
EOF
  local -a _sections=(network) _keys=(network.mode) _values=(bridge)
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  [[ "${output}" == *"mode = bridge"* ]]
  [[ "${output}" == *"ipc = host"* ]]          # untouched
  [[ "${output}" == *"privileged = true"* ]]   # untouched
}

@test "_write_setup_conf round-trips via _load_setup_conf_full" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[image]
rules = @default:orig

[deploy]
gpu_mode = auto
gpu_count = all
gpu_capabilities = gpu
EOF
  local -a _sections=(image deploy) \
    _keys=(image.rules deploy.gpu_mode deploy.gpu_count) \
    _values=("prefix:docker_, @default:foo" "force" "2")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  local -a _sect2=() _keys2=() _vals2=()
  _load_setup_conf_full "${TEMP_DIR}/out.conf" _sect2 _keys2 _vals2

  local _mode=""
  local i
  for (( i=0; i<${#_keys2[@]}; i++ )); do
    [[ "${_keys2[i]}" == "deploy.gpu_mode" ]] && _mode="${_vals2[i]}"
  done
  assert_equal "${_mode}" "force"
}

# ════════════════════════════════════════════════════════════════════
# _upsert_conf_value — in-place edit of a single key (for setup.sh writeback)
# ════════════════════════════════════════════════════════════════════

@test "_upsert_conf_value updates existing key value" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /dev:/dev
EOF
  _upsert_conf_value "${TEMP_DIR}/setup.conf" "volumes" "mount_1" \
    '/host:/home/${USER_NAME}/work'

  run grep '^mount_1' "${TEMP_DIR}/setup.conf"
  [[ "${output}" == "mount_1 = /host:/home/\${USER_NAME}/work" ]]
}

@test "_write_setup_conf removed_keys drops matching lines" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
mount_3 = /c:/c
EOF
  local -a _sections=(volumes) _keys=() _values=()
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values "volumes.mount_2"

  run cat "${TEMP_DIR}/out.conf"
  [[ "${output}" == *"mount_1 = /a:/a"* ]]
  [[ "${output}" != *"mount_2"* ]]
  [[ "${output}" == *"mount_3 = /c:/c"* ]]
}

@test "_write_setup_conf appends unknown override keys to their section" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[image]
rule_1 = prefix:docker_

[network]
mode = host
EOF
  local -a _sections=(image) \
    _keys=(image.rule_1 image.rule_2) \
    _values=("prefix:docker_" "@default:fallback")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  # Added rule_2 should appear under [image]
  [[ "${output}" == *"rule_2 = @default:fallback"* ]]
  # [network] section must remain
  [[ "${output}" == *"mode = host"* ]]
}

@test "_upsert_conf_value leaves other sections untouched" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rules = @default:foo

[volumes]
mount_1 =
EOF
  _upsert_conf_value "${TEMP_DIR}/setup.conf" "volumes" "mount_1" "/a:/b"

  run grep '^rules' "${TEMP_DIR}/setup.conf"
  [[ "${output}" == "rules = @default:foo" ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_list_section — regression tests for B5 (volumes mount_1)
# ════════════════════════════════════════════════════════════════════
#
# Bug: when setup.conf has `mount_1 =` (empty value, e.g. template
# default), `_edit_list_section` correctly hid it from the menu because
# `_cur_v` is empty, but still counted `1` in `_nums` for the `_max`
# calculation — so `add` created `mount_2`, leapfrogging the empty
# slot and leaving a hidden hole. Fix: when counting `_nums`, treat
# keys whose value is empty as free slots so `add` reuses them.

# Shared helper: source tui.sh once, stub interactive wrappers.
_b5_setup_tui() {
  export _LANG="en"
  # shellcheck disable=SC1091
  source /source/script/docker/tui.sh
  _tui_init_lang

  # Reset session state between tests
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()

  # Capture channel for stubbed interactions
  _B5_MENU_ARGS_FILE="${TEMP_DIR}/menu_args.log"
  : > "${_B5_MENU_ARGS_FILE}"
}

@test "_edit_list_section shows mount_1 when value is non-empty" {
  _b5_setup_tui
  _TUI_CURRENT[volumes.mount_1]="/foo:/bar"

  # Stub _tui_menu: record args + return "back" to exit the loop.
  _tui_menu() {
    printf '%s\n' "$@" > "${_B5_MENU_ARGS_FILE}"
    printf 'back'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  run cat "${_B5_MENU_ARGS_FILE}"
  # The menu tag/label stream must include mount_1 with its value.
  assert_output --partial "mount_1"
  assert_output --partial "/foo:/bar"
}

@test "_edit_list_section add reuses empty mount_1 slot instead of leapfrogging" {
  _b5_setup_tui
  # mount_1 cleared (empty value) + mount_2 populated.
  _TUI_CURRENT[volumes.mount_1]=""
  _TUI_CURRENT[volumes.mount_2]="/x:/y"

  # _tui_menu: first call returns "add", second returns "back".
  _b5_menu_calls=0
  _tui_menu() {
    (( _b5_menu_calls++ )) || true
    if (( _b5_menu_calls == 1 )); then
      printf 'add'
      return 0
    fi
    printf 'back'
    return 0
  }

  # _tui_inputbox supplies a new mount value.
  _tui_inputbox() {
    printf '/new:/new'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  # Expect the new mount to land in mount_1 (the empty slot), not mount_3.
  run _override_get "volumes.mount_1" ""
  assert_output "/new:/new"
  run _override_get "volumes.mount_3" ""
  assert_output ""
}

@test "_edit_list_section add uses max+1 when no empty slots exist" {
  _b5_setup_tui
  _TUI_CURRENT[volumes.mount_1]="/a:/a"
  _TUI_CURRENT[volumes.mount_2]="/b:/b"

  _b5_menu_calls=0
  _tui_menu() {
    (( _b5_menu_calls++ )) || true
    if (( _b5_menu_calls == 1 )); then
      printf 'add'
      return 0
    fi
    printf 'back'
    return 0
  }
  _tui_inputbox() {
    printf '/c:/c'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  run _override_get "volumes.mount_3" ""
  assert_output "/c:/c"
}

@test "_edit_list_section skips empty value from menu display" {
  _b5_setup_tui
  _TUI_CURRENT[volumes.mount_1]=""
  _TUI_CURRENT[volumes.mount_2]="/x:/y"

  _tui_menu() {
    printf '%s\n' "$@" > "${_B5_MENU_ARGS_FILE}"
    printf 'back'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  run cat "${_B5_MENU_ARGS_FILE}"
  # Empty mount_1 must not appear as an entry row.
  refute_output --partial $'mount_1\n'
  # mount_2 must still appear.
  assert_output --partial "mount_2"
  assert_output --partial "/x:/y"
}
