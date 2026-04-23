#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source setup.sh functions only (main is guarded)
  # shellcheck disable=SC1091
  source /source/script/docker/setup.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# detect_user_info
# ════════════════════════════════════════════════════════════════════

@test "detect_user_info uses USER env when set" {
  local _user _group _uid _gid
  USER="mockuser" detect_user_info _user _group _uid _gid
  assert_equal "${_user}" "mockuser"
}

@test "detect_user_info falls back to id -un when USER unset" {
  local _user _group _uid _gid
  mock_cmd "id" '
case "$1" in
  -un) echo "fallbackuser" ;;
  -u)  echo "1001" ;;
  -gn) echo "fallbackgroup" ;;
  -g)  echo "1001" ;;
esac'
  unset USER
  detect_user_info _user _group _uid _gid
  assert_equal "${_user}" "fallbackuser"
}

@test "detect_user_info sets group uid gid correctly" {
  local _user _group _uid _gid
  mock_cmd "id" '
case "$1" in
  -un) echo "testuser" ;;
  -u)  echo "1234" ;;
  -gn) echo "testgroup" ;;
  -g)  echo "5678" ;;
esac'
  USER="testuser" detect_user_info _user _group _uid _gid
  assert_equal "${_group}" "testgroup"
  assert_equal "${_uid}" "1234"
  assert_equal "${_gid}" "5678"
}

# ════════════════════════════════════════════════════════════════════
# detect_hardware
# ════════════════════════════════════════════════════════════════════

@test "detect_hardware returns uname -m output" {
  local _hw
  mock_cmd "uname" 'echo "aarch64"'
  detect_hardware _hw
  assert_equal "${_hw}" "aarch64"
}

# ════════════════════════════════════════════════════════════════════
# detect_docker_hub_user
# ════════════════════════════════════════════════════════════════════

@test "detect_docker_hub_user uses docker info username when logged in" {
  local _result
  mock_cmd "docker" 'echo " Username: dockerhubuser"'
  detect_docker_hub_user _result
  assert_equal "${_result}" "dockerhubuser"
}

@test "detect_docker_hub_user falls back to USER when docker returns empty" {
  local _result
  mock_cmd "docker" 'echo "no username line here"'
  USER="localuser" detect_docker_hub_user _result
  assert_equal "${_result}" "localuser"
}

@test "detect_docker_hub_user falls back to id -un when USER also unset" {
  local _result
  mock_cmd "docker" 'echo "no username line here"'
  mock_cmd "id" '
case "$1" in
  -un) echo "iduser" ;;
esac'
  unset USER
  detect_docker_hub_user _result
  assert_equal "${_result}" "iduser"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu
# ════════════════════════════════════════════════════════════════════

@test "detect_gpu returns true when nvidia-container-toolkit is installed" {
  local _result
  mock_cmd "dpkg-query" 'echo "ii"'
  detect_gpu _result
  assert_equal "${_result}" "true"
}

@test "detect_gpu returns false when nvidia-container-toolkit is not installed" {
  local _result
  mock_cmd "dpkg-query" 'echo "un"'
  detect_gpu _result
  assert_equal "${_result}" "false"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu_count
# ════════════════════════════════════════════════════════════════════

@test "detect_gpu_count returns count of GPUs from nvidia-smi -L output" {
  mock_cmd "nvidia-smi" '
if [[ "$1" == "-L" ]]; then
  echo "GPU 0: NVIDIA A100 (UUID: ...)"
  echo "GPU 1: NVIDIA A100 (UUID: ...)"
  echo "GPU 2: NVIDIA A100 (UUID: ...)"
fi'
  local _n=0
  detect_gpu_count _n
  assert_equal "${_n}" "3"
}

@test "detect_gpu_count returns 0 when nvidia-smi is missing" {
  # Point PATH at MOCK_DIR only (no nvidia-smi stub installed) so the
  # command -v check fails.
  local _saved_path="${PATH}"
  PATH="${MOCK_DIR}"
  local _n=99
  detect_gpu_count _n
  PATH="${_saved_path}"
  assert_equal "${_n}" "0"
}

@test "detect_gpu_count returns 0 when nvidia-smi fails (driver broken)" {
  mock_cmd "nvidia-smi" 'exit 9'
  local _n=99
  detect_gpu_count _n
  assert_equal "${_n}" "0"
}

@test "template setup.conf ships [devices] device_1 = /dev:/dev by default" {
  # Dev-friendly default: new repos get full /dev tree bound without
  # needing to run TUI. Template source-of-truth.
  run grep -E '^device_1 = /dev:/dev$' /source/setup.conf
  assert_success
}

@test "template setup.conf [deploy] enables ALL GPU capabilities by default" {
  # Dev-friendly: reserve every GPU capability so new repos get
  # compute + utility + graphics out of the box (no need to tick boxes
  # in TUI). Users narrow it down via ./setup_tui.sh deploy if they want
  # a minimal reservation.
  run grep -E '^gpu_capabilities = gpu compute utility graphics$' /source/setup.conf
  assert_success
}

@test "[security] cap_add_* fallback: repo setup.conf with no cap_add_* uses template defaults" {
  # Simulate a repo override that keeps privileged=false but wiped all
  # cap_add_* entries. Expected behaviour: setup.sh falls back to the
  # template's baseline (SYS_ADMIN / NET_ADMIN / MKNOD) so the container
  # does not silently drop to Docker's stripped-down default capability
  # set.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- NET_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- MKNOD' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[security] security_opt_* fallback: missing security_opt_* uses template defaults" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- seccomp:unconfined' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[security] cap_add_* explicit override: user-provided list is honored (no template fallback)" {
  # User set cap_add_1=ALL explicitly: compose should use THAT, not the
  # template's SYS_ADMIN/NET_ADMIN/MKNOD.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = ALL
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- ALL' "${TEMP_DIR}/compose.yaml"
  assert_success
  # Template's SYS_ADMIN/NET_ADMIN/MKNOD should NOT appear.
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "detect_gpu_count nameref survives caller-local named '_line' (regression)" {
  # Regression: previously detect_gpu_count used `local _line` internally,
  # which shadowed a caller-local also named `_line`; the nameref outvar
  # then silently wrote to the function-local `_line`, never reaching the
  # caller. The fix uses `__dgc_`-prefixed locals.
  mock_cmd "nvidia-smi" '
if [[ "$1" == "-L" ]]; then
  echo "GPU 0: A"
  echo "GPU 1: B"
fi'
  local _line=99
  detect_gpu_count _line
  assert_equal "${_line}" "2"
}

# ════════════════════════════════════════════════════════════════════
# detect_gui
# ════════════════════════════════════════════════════════════════════

@test "detect_gui returns true when DISPLAY is set" {
  local _result
  DISPLAY=":0" WAYLAND_DISPLAY="" detect_gui _result
  assert_equal "${_result}" "true"
}

@test "detect_gui returns true when WAYLAND_DISPLAY is set" {
  local _result
  DISPLAY="" WAYLAND_DISPLAY="wayland-0" detect_gui _result
  assert_equal "${_result}" "true"
}

@test "detect_gui returns false when both DISPLAY and WAYLAND_DISPLAY unset" {
  local _result
  DISPLAY="" WAYLAND_DISPLAY="" detect_gui _result
  assert_equal "${_result}" "false"
}

# ════════════════════════════════════════════════════════════════════
# _parse_ini_section
# ════════════════════════════════════════════════════════════════════

@test "_parse_ini_section reads keys and values for one section" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
count = all
capabilities = gpu
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gpu" _k _v
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "auto"
  assert_equal "${_k[1]}" "count"
  assert_equal "${_v[1]}" "all"
}

@test "_parse_ini_section isolates sections (entries from other sections ignored)" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto

[gui]
mode = off
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "off"
}

@test "_parse_ini_section skips comment and empty lines" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
# top comment
[network]
# inside comment
mode = host

ipc = host

# trailing
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "network" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_k[1]}" "ipc"
}

@test "_parse_ini_section trims whitespace around key and value" {
  local _conf="${TEMP_DIR}/setup.conf"
  printf '[gpu]\n  mode  =  force  \n' > "${_conf}"
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gpu" _k _v
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "force"
}

@test "_parse_ini_section returns empty arrays for missing file" {
  local -a _k=() _v=()
  _parse_ini_section "${TEMP_DIR}/missing.conf" "gpu" _k _v
  assert_equal "${#_k[@]}" "0"
  assert_equal "${#_v[@]}" "0"
}

@test "_parse_ini_section returns empty arrays for absent section" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "0"
}

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
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf falls back to template when section absent per-repo" {
  # Per-repo file has [gpu] but NOT [gui]
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
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
# _resolve_gpu / _resolve_gui
# ════════════════════════════════════════════════════════════════════

@test "_resolve_gpu auto + detected=true => enabled" {
  local _out
  _resolve_gpu "auto" "true" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gpu auto + detected=false => disabled" {
  local _out
  _resolve_gpu "auto" "false" _out
  assert_equal "${_out}" "false"
}

@test "_resolve_gpu force => enabled regardless of detection" {
  local _out
  _resolve_gpu "force" "false" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gpu off => disabled regardless of detection" {
  local _out
  _resolve_gpu "off" "true" _out
  assert_equal "${_out}" "false"
}

@test "_resolve_gui auto + detected=true => enabled" {
  local _out
  _resolve_gui "auto" "true" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gui force => enabled regardless" {
  local _out
  _resolve_gui "force" "false" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gui off => disabled regardless" {
  local _out
  _resolve_gui "off" "true" _out
  assert_equal "${_out}" "false"
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name (now reads [image] rules from setup.conf)
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name uses template default rules (prefix:docker_ → strip)" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/docker_myapp"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name uses template default rules (suffix:_ws → strip)" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/projects/myapp_ws"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name template default falls through to @basename for generic paths" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/plainproject"
  assert_equal "${_result}" "plainproject"
}

@test "detect_image_name honors per-repo setup.conf [image] rules" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:foo_
rule_2 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/foo_bar"
  assert_equal "${_result}" "bar"
}

@test "detect_image_name rules apply in order (first match wins)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:docker_
rule_2 = suffix:_ws
rule_3 = @default:unused
EOF
  unset SETUP_CONF
  local _result
  # path has docker_ prefix AND _ws somewhere — prefix wins
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/myapp_ws/src/docker_nav"
  assert_equal "${_result}" "nav"
}

@test "detect_image_name @default:<value> used when no rule matches" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:nonexistent_
rule_2 = @default:myfallback
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plain"
  assert_equal "${_result}" "myfallback"
}

@test "detect_image_name lowercases the result" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/docker_MyApp"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name returns unknown when no rule matches and no @default" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:nonexistent_
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plain"
  assert_equal "${_result}" "unknown"
}

# ════════════════════════════════════════════════════════════════════
# detect_ws_path
# ════════════════════════════════════════════════════════════════════

@test "detect_ws_path strategy 1: docker_* finds sibling *_ws" {
  local _ws_parent="${TEMP_DIR}/projects"
  mkdir -p "${_ws_parent}/docker_myapp" "${_ws_parent}/myapp_ws"
  local _result
  detect_ws_path _result "${_ws_parent}/docker_myapp"
  assert_equal "${_result}" "${_ws_parent}/myapp_ws"
}

@test "detect_ws_path strategy 1: docker_* without sibling falls through" {
  local _parent="${TEMP_DIR}/projects"
  mkdir -p "${_parent}/docker_myapp"
  local _result
  detect_ws_path _result "${_parent}/docker_myapp"
  assert_equal "${_result}" "${_parent}"
}

@test "detect_ws_path strategy 2: finds _ws component in path" {
  local _ws="${TEMP_DIR}/myapp_ws"
  mkdir -p "${_ws}/src"
  local _result
  detect_ws_path _result "${_ws}/src"
  assert_equal "${_result}" "${_ws}"
}

@test "detect_ws_path strategy 3: falls back to parent directory" {
  local _plain="${TEMP_DIR}/plain/project"
  mkdir -p "${_plain}"
  local _result
  detect_ws_path _result "${_plain}"
  assert_equal "${_result}" "${TEMP_DIR}/plain"
}

@test "detect_ws_path fails with ERROR when base_path does not exist" {
  run -1 detect_ws_path _r "${TEMP_DIR}/nope"
  assert_output --partial "base_path does not exist"
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash
# ════════════════════════════════════════════════════════════════════

@test "_compute_conf_hash returns a sha256-shaped hex string" {
  local _h
  _compute_conf_hash "${TEMP_DIR}" _h
  [[ "${_h}" =~ ^[0-9a-f]{64}$ ]]
}

@test "_compute_conf_hash differs when per-repo setup.conf changes" {
  local _h1 _h2
  _compute_conf_hash "${TEMP_DIR}" _h1
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = off
EOF
  _compute_conf_hash "${TEMP_DIR}" _h2
  [[ "${_h1}" != "${_h2}" ]]
}

# ════════════════════════════════════════════════════════════════════
# write_env
# ════════════════════════════════════════════════════════════════════

@test "write_env creates .env with all required variables and SETUP_* metadata" {
  local _env="${TEMP_DIR}/.env"
  write_env "${_env}" \
    "testuser" "testgroup" "1001" "1001" \
    "x86_64" "dockerhub" "true" \
    "ros_noetic" "/workspace" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" \
    "all" "gpu" \
    "true" "abc123"

  assert [ -f "${_env}" ]
  run grep 'USER_NAME=testuser' "${_env}"; assert_success
  run grep 'USER_UID=1001'      "${_env}"; assert_success
  run grep 'GPU_ENABLED=true'   "${_env}"; assert_success
  run grep 'IMAGE_NAME=ros_noetic' "${_env}"; assert_success
  run grep 'NETWORK_MODE=host'  "${_env}"; assert_success
  run grep 'IPC_MODE=host'      "${_env}"; assert_success
  run grep 'PRIVILEGED=true'    "${_env}"; assert_success
  run grep 'GPU_COUNT=all'      "${_env}"; assert_success
  run grep -F 'GPU_CAPABILITIES="gpu"' "${_env}"; assert_success
  run grep 'SETUP_CONF_HASH=abc123' "${_env}"; assert_success
  run grep 'SETUP_GUI_DETECTED=true' "${_env}"; assert_success
  run grep -E '^SETUP_TIMESTAMP=' "${_env}"; assert_success
  run grep 'APT_MIRROR_UBUNTU=tw.archive.ubuntu.com' "${_env}"; assert_success
  run grep 'APT_MIRROR_DEBIAN=mirror.twds.com.tw' "${_env}"; assert_success
  run grep 'TZ=Asia/Taipei' "${_env}"; assert_success
  # bash-source round-trip: re-loading the file must not raise a
  # "command not found" on any multi-word value (regression: previously
  # GPU_CAPABILITIES="gpu compute utility graphics" was unquoted).
  run bash -c "set -o allexport; source '${_env}'"
  assert_success
  refute_output --partial "command not found"
}

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift
# ════════════════════════════════════════════════════════════════════

@test "_check_setup_drift no-op when .env missing" {
  run _check_setup_drift "${TEMP_DIR}"
  assert_success
}

@test "_check_setup_drift silent when nothing changed" {
  # Prime .env by running a full setup cycle (write_env + _compute_conf_hash)
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h}"
  # stub detect_gui/detect_gpu to match stored false
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_success
  refute_output --partial "WARNING"
}

@test "_check_setup_drift returns non-zero when conf hash changes" {
  local _h_old=""
  _compute_conf_hash "${TEMP_DIR}" _h_old
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h_old}"
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  # Drop in a new per-repo setup.conf → hash differs
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run _check_setup_drift "${TEMP_DIR}"
  # Non-zero exit lets build.sh/run.sh trigger auto-regen (v0.9.5+).
  assert_failure
  assert_output --partial "drift detected"
  assert_output --partial "setup.conf modified"
}

@test "_check_setup_drift returns non-zero when GPU detection changes" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  # Store with GPU=false
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h}"
  # Now detection says true
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="true"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_failure
  assert_output --partial "GPU detection changed"
}

# ════════════════════════════════════════════════════════════════════
# main --lang + error paths (unchanged behaviour)
# ════════════════════════════════════════════════════════════════════

@test "main returns error on unknown argument" {
  run main --bogus
  assert_failure
  assert_output --partial "Unknown argument"
}

@test "main returns error when --base-path value is missing" {
  run -127 bash -c "source /source/script/docker/setup.sh; main --base-path"
}

@test "main returns error when --lang value is missing" {
  run -127 bash -c "source /source/script/docker/setup.sh; main --lang"
}

@test "main --lang zh-TW sets Chinese messages for full run" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "更新完成"
}

@test "main resolves default _base_path via BASH_SOURCE when --base-path omitted" {
  # When invoked without --base-path, setup.sh walks 3 levels up from its own
  # location (script/docker/../../.. = repo root).  We verify the fallback by
  # copying setup.sh + its i18n.sh sidecar into a sandbox tree.
  mkdir -p "${TEMP_DIR}/sandbox_repo/template/script/docker"
  cp /source/script/docker/setup.sh \
    "${TEMP_DIR}/sandbox_repo/template/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh \
    "${TEMP_DIR}/sandbox_repo/template/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh \
    "${TEMP_DIR}/sandbox_repo/template/script/docker/_tui_conf.sh"
  cp /source/setup.conf "${TEMP_DIR}/sandbox_repo/template/setup.conf"

  run bash "${TEMP_DIR}/sandbox_repo/template/script/docker/setup.sh"
  assert_success
  assert [ -f "${TEMP_DIR}/sandbox_repo/.env" ]
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

@test "detect_image_name uses @basename rule alone (exercises _rule_basename)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plainname"
  assert_equal "${_result}" "plainname"
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name sanitization
#
# docker compose project names + image tags forbid '.' and anything
# outside [a-z0-9_-]. detect_image_name must normalise whatever the
# rules produce so downstream `docker compose -p <name>` doesn't
# reject the generated project name.
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name replaces '.' with '-' (regression: tmp.abcdef → tmp-abcdef)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/tmp.abcdef"
  assert_equal "${_result}" "tmp-abcdef"
}

@test "detect_image_name collapses runs of '-' and strips leading/trailing separators" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/..weird..name.."
  [[ "${_result}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
  assert_equal "${_result}" "weird-name"
}

# ════════════════════════════════════════════════════════════════════
# i18n
# ════════════════════════════════════════════════════════════════════

@test "_msg returns English messages by default" {
  _LANG="en"
  [[ "$(_msg env_done)" =~ updated ]]
}

@test "_msg returns Traditional Chinese messages when _LANG=zh-TW" {
  _LANG="zh-TW"
  [[ "$(_msg env_done)" =~ 更新完成 ]]
}

@test "_msg returns Simplified Chinese messages when _LANG=zh-CN" {
  _LANG="zh-CN"
  [[ "$(_msg env_done)" =~ 更新完成 ]]
}

@test "_msg returns Japanese messages when _LANG=ja" {
  _LANG="ja"
  [[ "$(_msg env_done)" =~ 更新完了 ]]
}

# Exercise every (key, language) branch so kcov sees the zh-CN / ja / default
# `unknown_arg` and `env_comment` case-arms. The env_done-only tests above
# only land on the first case of each language block.

@test "_msg env_comment and unknown_arg are defined in zh" {
  _LANG="zh-TW"
  [[ "$(_msg env_comment)" =~ 自動偵測 ]]
  [[ "$(_msg unknown_arg)" =~ 未知參數 ]]
}

@test "_msg env_comment and unknown_arg are defined in zh-CN" {
  _LANG="zh-CN"
  [[ "$(_msg env_comment)" =~ 自动检测 ]]
  [[ "$(_msg unknown_arg)" =~ 未知参数 ]]
}

@test "_msg env_comment and unknown_arg are defined in ja" {
  _LANG="ja"
  [[ "$(_msg env_comment)" =~ 自動検出 ]]
  [[ "$(_msg unknown_arg)" =~ 不明な引数 ]]
}

@test "_msg falls back to English when _LANG is unknown" {
  _LANG="xx"
  [[ "$(_msg env_done)" =~ updated ]]
  [[ "$(_msg env_comment)" =~ Auto-detected ]]
  [[ "$(_msg unknown_arg)" =~ "Unknown argument" ]]
}

# ════════════════════════════════════════════════════════════════════
# [build] section (arg_N KEY=VALUE schema)
# ════════════════════════════════════════════════════════════════════

@test "[build] template defaults ship TW mirrors via arg_N" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=tw.archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=mirror.twds.com.tw"
}

@test "[build] arg_N override replaces TW default when set" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build arg_1 \
    "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build arg_2 \
    "APT_MIRROR_DEBIAN=deb.debian.org"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=deb.debian.org"
}

@test "[build] back-compat: old apt_mirror_* named keys still read" {
  # Legacy repo setup.conf with the pre-arg_N schema must keep working
  # so users can upgrade template without rewriting setup.conf first.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[build]
apt_mirror_ubuntu = mirror.example.com
tz = Asia/Tokyo
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env'
    grep '^TZ=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=mirror.example.com"
  assert_output --partial "TZ=Asia/Tokyo"
}

@test "[build] user-added arg_N propagates to .env" {
  # Dockerfile with `ARG PYTHON_VERSION` can pick up a user-added
  # build arg. Extra args land in .env so compose build.args can
  # reference them.
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build arg_9 \
    "PYTHON_VERSION=3.12"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' 2>&1
    grep '^PYTHON_VERSION=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "PYTHON_VERSION=3.12"
}

@test "[build] target_arch = arm64 writes TARGET_ARCH to .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build target_arch arm64
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^TARGET_ARCH=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "TARGET_ARCH=arm64"
}

@test "[build] target_arch empty omits TARGET_ARCH from .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  # Explicit empty value (the template's default)
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build target_arch ""
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^TARGET_ARCH=' '${TEMP_DIR}/.env'
  "
  # grep -c prints "0" and exits 1 when pattern missing; we want exactly that.
  assert_failure
  assert_output "0"
}

@test "[build] network = host writes BUILD_NETWORK to .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build network host
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^BUILD_NETWORK=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "BUILD_NETWORK=host"
}

@test "[build] network empty omits BUILD_NETWORK from .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build network ""
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^BUILD_NETWORK=' '${TEMP_DIR}/.env'
  "
  assert_failure
  assert_output "0"
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

# ════════════════════════════════════════════════════════════════════
# Workspace writeback (first-time / user edit / opt-out)
# ════════════════════════════════════════════════════════════════════

@test "workspace first-time: writes \${WS_PATH} variable form (portable)" {
  # Regression (v0.9.4): writeback used to bake the absolute host path
  # into setup.conf. Committing that file broke other machines whose
  # filesystem layout differed. Now we write the \${WS_PATH} variable
  # form so docker-compose resolves it per-machine from .env.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${_repo}' 2>&1
  "
  assert_success
  assert [ -f "${_repo}/setup.conf" ]
  run grep '^mount_1' "${_repo}/setup.conf"
  assert_output --partial '${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: \${WS_PATH} form re-detects per machine" {
  # Round-trip: first-time writes \${WS_PATH} form → second run reads
  # setup.conf, sees the variable reference, and re-runs detect_ws_path
  # so WS_PATH in .env reflects THIS machine (not the one that first
  # committed the file).
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/script/docker/setup.sh; main --base-path '${_repo}'" \
    >/dev/null 2>&1
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env'
    grep '^mount_1' '${_repo}/setup.conf'
  "
  assert_success
  # WS_PATH is a non-empty absolute path — exact value depends on the
  # sandbox, but it must not be the literal variable string.
  refute_output --partial 'WS_PATH=${WS_PATH}'
  assert_output --regexp 'WS_PATH=/[^[:space:]]+'
  # mount_1 stays as the portable variable form.
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: respects user-pinned absolute path that exists" {
  local _repo="${TEMP_DIR}/repo"
  local _pin="${TEMP_DIR}/custom_ws"
  mkdir -p "${_repo}" "${_pin}"
  bash -c "source /source/script/docker/setup.sh; main --base-path '${_repo}'" \
    >/dev/null 2>&1
  # User pins mount_1 to an existing local path.
  sed -i "s|^mount_1.*|mount_1 = ${_pin}:/home/\${USER_NAME}/work|" \
    "${_repo}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env'
    grep '^mount_1' '${_repo}/setup.conf'
  "
  assert_success
  assert_output --partial "WS_PATH=${_pin}"
  assert_output --partial "mount_1 = ${_pin}:"
}

@test "workspace second-run: stale absolute path (nonexistent) warns + auto-migrates to \${WS_PATH}" {
  # Regression (v0.9.4): a repo cloned from github with mount_1 baked
  # as another machine's absolute path (e.g. /home/alice/work/ws) must
  # not try to mount that directory on /home/bob. setup.sh detects the
  # stale host path (absolute, non-existent), warns, and rewrites
  # mount_1 to the portable \${WS_PATH} form.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/script/docker/setup.sh; main --base-path '${_repo}'" \
    >/dev/null 2>&1
  # Plant a stale absolute path that does not exist on this machine.
  sed -i 's|^mount_1.*|mount_1 = /nonexistent/stale/ws:/home/${USER_NAME}/work|' \
    "${_repo}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main --base-path '${_repo}' 2>&1
    grep '^mount_1' '${_repo}/setup.conf'
    grep '^WS_PATH=' '${_repo}/.env'
  "
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "/nonexistent/stale/ws"
  # mount_1 is rewritten back to the portable form.
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
  # WS_PATH in .env is a local path, not the stale literal.
  refute_output --partial "WS_PATH=/nonexistent/stale/ws"
}

@test "workspace opt-out: cleared mount_1 means no workspace mount in compose" {
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/script/docker/setup.sh; main --base-path '${_repo}'" \
    >/dev/null 2>&1
  # User clears mount_1 (opt-out)
  sed -i 's|^mount_1.*|mount_1 =|' "${_repo}/setup.conf"
  bash -c "source /source/script/docker/setup.sh; main --base-path '${_repo}'" \
    >/dev/null 2>&1
  # mount_1 stays empty (not re-populated)
  run grep '^mount_1' "${_repo}/setup.conf"
  assert_equal "${output}" "mount_1 ="
  # compose.yaml has no workspace mount
  run grep ':/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name string rule
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name string:<value> short-circuits path parsing" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = string:my_app
rule_2 = prefix:docker_
rule_3 = @default:should_not_reach
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/docker_something"
  assert_equal "${_result}" "my_app"
}

@test "detect_image_name string value is still lowercased + sanitized" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = string:My.App.Name
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/whatever"
  assert_equal "${_result}" "my-app-name"
}
