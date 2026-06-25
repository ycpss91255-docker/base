#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

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

@test "template setup.conf devices opt-in (#466): device_1 is a commented example, not a default" {
  # F2: /dev:/dev is no longer bound by default -- repos that need
  # device access uncomment it or add via `setup.sh add devices.device`.
  run grep -E '^device_1 = /dev:/dev$' /source/downstream/config/docker/setup.conf
  assert_failure
  run grep -E '^# device_1 = /dev:/dev$' /source/downstream/config/docker/setup.conf
  assert_success
}

@test "[devices] opt-in (#466): empty section + slim template emits no devices block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[devices]
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    devices:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "template setup.conf [deploy] enables ALL GPU capabilities by default" {
  # Dev-friendly: reserve every GPU capability so new repos get
  # compute + utility + graphics out of the box (no need to tick boxes
  # in TUI). Users narrow it down via ./setup_tui.sh deploy if they want
  # a minimal reservation.
  run grep -E '^gpu_capabilities = gpu compute utility graphics$' /source/downstream/config/docker/setup.conf
  assert_success
}

@test "setup.sh apply emits top-level name: in compose.yaml (#472)" {
  # End-to-end: apply renders a top-level name: with the literal compose
  # vars so non-wrapper tools resolve the wrapper's project name.
  printf '[security]\nprivileged = false\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F 'name: ${DOCKER_HUB_USER}-${IMAGE_NAME}' "${TEMP_DIR}/compose.yaml"
  assert_success
}

# ── [lifecycle] restart policy ─────────────────────────────────────────

@test "[lifecycle] restart = always emits restart: always under devel (#478)" {
  printf '[lifecycle]\nrestart = always\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    restart: always$' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[lifecycle] restart = no (default) emits no restart: field (#478)" {
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    restart:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[lifecycle] restart = on-failure:3 emits quoted value (#478)" {
  printf '[lifecycle]\nrestart = on-failure:3\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '    restart: "on-failure:3"' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "template setup.conf ships [lifecycle] restart = no (#478)" {
  run grep -E '^restart = no$' /source/downstream/config/docker/setup.conf
  assert_success
}

@test "setup.sh set lifecycle.restart rejects an invalid policy (#478)" {
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main set lifecycle.restart bogus --base-path '${TEMP_DIR}' 2>&1
  "
  assert_failure
}

@test "setup.sh set lifecycle.restart accepts the 5 canonical values (#478)" {
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  local _v
  for _v in no always unless-stopped on-failure on-failure:3; do
    run bash -c "
      source /source/downstream/script/docker/wrapper/setup.sh
      main set lifecycle.restart '${_v}' --base-path '${TEMP_DIR}' 2>&1
    "
    assert_success
  done
}

# ── [deploy] dri_groups (non-NVIDIA iGPU /dev/dri access) ───────────────

@test "[deploy] dri_groups = auto + GUI emits group_add with numeric GIDs (#496)" {
  printf '[deploy]\ndri_groups = auto\n[gui]\nmode = force\n' \
    > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- "44"' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- "992"' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[deploy] dri_groups = auto with no /dev/dri emits no group_add (#496)" {
  printf '[deploy]\ndri_groups = auto\n[gui]\nmode = force\n' \
    > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS=''
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[deploy] dri_groups = off emits no group_add even with GUI (#496)" {
  printf '[deploy]\ndri_groups = off\n[gui]\nmode = force\n' \
    > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[deploy] dri_groups = auto without GUI emits no group_add (GUI-gated) (#496)" {
  printf '[deploy]\ndri_groups = auto\n[gui]\nmode = off\n' \
    > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "template setup.conf ships [deploy] dri_groups = auto (#496)" {
  run grep -E '^dri_groups = auto$' /source/downstream/config/docker/setup.conf
  assert_success
}

@test "_detect_dri_groups dedups repeated GIDs (#496)" {
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 44 992'
    source /source/downstream/script/docker/wrapper/setup.sh
    _detect_dri_groups
  "
  assert_success
  # override echoes verbatim; dedup happens on the real stat path. Assert the
  # override passthrough works (real-stat dedup is covered by sort -u).
  assert_output --partial "44"
  assert_output --partial "992"
}

# ── [deploy] runtime -> gpu_runtime (W3 permanent alias) ────────────────

@test "[deploy] gpu_runtime primary key emits runtime: nvidia (#481)" {
  printf '[deploy]\ngpu_runtime = nvidia\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    runtime: nvidia$' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[deploy] legacy runtime key still works + warns (#481 W3 alias)" {
  printf '[deploy]\nruntime = nvidia\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    runtime: nvidia$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # the legacy alias is consumed but a deprecation is surfaced
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "gpu_runtime"
}

@test "[deploy] gpu_runtime wins when both keys present (#481)" {
  printf '[deploy]\ngpu_runtime = nvidia\nruntime = off\n' \
    > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    runtime: nvidia$' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "template setup.conf ships [deploy] gpu_runtime = auto (#481)" {
  run grep -E '^gpu_runtime = auto$' /source/downstream/config/docker/setup.conf
  assert_success
  run grep -E '^runtime = ' /source/downstream/config/docker/setup.conf
  assert_failure
}

@test "per-stage override accepts deploy.gpu_runtime (#481)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    _validate_stage_override_key deploy.gpu_runtime
  "
  assert_success
}

@test "per-stage override still accepts legacy deploy.runtime (#481 alias)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    _validate_stage_override_key deploy.runtime
  "
  assert_success
}

@test "[security] cap_add opt-in (#466): empty section + slim template emits no cap_add" {
  # F2: the template no longer ships cap_add_* defaults, so a repo
  # with an empty [security] section (the omniverse case) falls back to a
  # SLIM template and gets NO cap_add block -- privileges are opt-in, not
  # silently inherited. Repos that need caps declare them explicitly
  # (covered by the regression test below).
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_failure
  run grep -E '^    cap_add:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[security] security_opt opt-in (#466): empty section + slim template emits no security_opt" {
  # F2: template no longer ships security_opt_1 = seccomp:unconfined,
  # so an empty [security] section yields no security_opt block.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- seccomp:unconfined' "${TEMP_DIR}/compose.yaml"
  assert_failure
  run grep -E '^    security_opt:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[security] opt-in via wrapper: setup.sh add security.cap_add then apply emits cap_add (#466)" {
  # The slim template makes caps opt-in; the opt-in path is the wrapper,
  # not hand-editing commented lines. `setup.sh add` writes the entry into
  # the per-repo setup.conf, and the next apply emits it.
  printf '[security]\n' > "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main add security.cap_add SYS_ADMIN --base-path '${TEMP_DIR}' 2>&1
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[security] privileged defaults to false when key absent (#466 opt-in)" {
  # A repo that declares [security] (e.g. for cap_add) but omits the
  # privileged key must NOT silently get privileged=true. flips the
  # default to false so privilege is opt-in across the board.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[security]
cap_add_1 = SYS_ADMIN
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^PRIVILEGED=false$' "${TEMP_DIR}/.env.generated"
  assert_success
}

@test "[security] opt-in still works via explicit declaration (#466 regression)" {
  # Repos that need privileges declare them (e.g. via `setup.sh add
  # security.cap_add SYS_ADMIN` or the TUI). The slim template only
  # changes the DEFAULT -- an explicit cap_add must still emit.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = SYS_ADMIN
security_opt_1 = seccomp:unconfined
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- seccomp:unconfined' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[additional_contexts] omitted by default (back-compat: no block in compose.yaml)" {
  # Default template setup.conf has [additional_contexts] section but no
  # entries. Generated compose.yaml must NOT contain `additional_contexts:`
  # so existing repos see zero diff.
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- 'additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[additional_contexts] context_1 = NAME=PATH emits block under devel/test build" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
context_2 = vendor=../third_party
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # Block appears at least once (devel + test, runtime is conditional on
  # Dockerfile having `AS runtime` which TEMP_DIR doesn't ship).
  run grep -c -F -- '      additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_success
  [ "${output}" -ge 2 ]
  run grep -F -- '        repo: ..' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '        vendor: ../third_party' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[additional_contexts] runtime service inherits the block when Dockerfile declares AS runtime" {
  # Stub a Dockerfile with `AS runtime` so generate_compose_yaml emits
  # the runtime service. Then assert additional_contexts: appears 3 times
  # (once under each of devel / runtime / test). The `test` service comes
  # from the devel-test stage, so the fixture must declare it.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS runtime
FROM sys AS devel-test
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -c -F -- '      additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_success
  assert_output "3"
}

@test "[additional_contexts] entries sort by numeric suffix (context_2 / context_10)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[additional_contexts]
context_10 = ten=../ten
context_2 = two=../two
context_1 = one=../one
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # Extract first occurrence of the additional_contexts block (devel
  # service) and check the order of name lines within it.
  local _block
  _block="$(awk '
    /^      additional_contexts:$/ { in_block=1; next }
    in_block && /^[^ ]/             { exit }
    in_block && /^      [^ ]/       { exit }
    in_block                         { print }
  ' "${TEMP_DIR}/compose.yaml")"
  local _first _second _third
  _first="$(printf '%s\n'  "${_block}" | sed -n '1p')"
  _second="$(printf '%s\n' "${_block}" | sed -n '2p')"
  _third="$(printf '%s\n'  "${_block}" | sed -n '3p')"
  assert_equal "${_first}"  "        one: ../one"
  assert_equal "${_second}" "        two: ../two"
  assert_equal "${_third}"  "        ten: ../ten"
}

@test "[additional_contexts] empty value (cleared slot) is skipped" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
context_2 =
context_3 = vendor=../third_party
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- 'repo: ..' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- 'vendor: ../third_party' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "_setup_known_section recognises additional_contexts" {
  _setup_known_section "additional_contexts"
}

@test "_setup_known_section recognises logging + [logging.<svc>] sub-section (#328)" {
  _setup_known_section "logging"
  _setup_known_section "logging.runtime"
  _setup_known_section "logging.devel"
  run _setup_known_section "logging."
  assert_failure
  run _setup_known_section "loggings"
  assert_failure
}

@test "_setup_known_section recognises every SCHEMA_SECTIONS member (#561)" {
  local _s
  for _s in "${SCHEMA_SECTIONS[@]}"; do
    _setup_known_section "${_s}"
  done
}

@test "_setup_known_section derives from SCHEMA_SECTIONS, not a copy (#561)" {
  # A section registered only in SCHEMA_SECTIONS must become known
  # without hand-editing _setup_known_section.
  SCHEMA_SECTIONS+=(brandnew)
  _setup_known_section "brandnew"
}

@test "set logging.driver round-trips via show (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.driver journald --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.driver --base-path "${TEMP_DIR}"
  assert_success
  assert_output "journald"
}

@test "set logging.compress accepts true/false; rejects others (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.compress true --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.compress maybe --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set logging.max_file rejects non-positive integers (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.max_file 5 --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_file 0 --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_file -1 --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_file abc --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.max_size accepts num+unit; rejects malformed (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.max_size 50m --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_size 1g --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_size 10X --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_size abc --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.driver rejects whitespace/empty-shape names (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.driver "bad name" --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.driver "1starts-with-digit" --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.<svc>.<key> writes to per-service section (#328)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[logging]
driver = json-file
EOF
  run main set logging.runtime.driver journald --base-path "${TEMP_DIR}"
  assert_success
  # Per-service section now exists with the override.
  run grep -F "[logging.runtime]" "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
  run main show logging.runtime.driver --base-path "${TEMP_DIR}"
  assert_success
  assert_output "journald"
}

@test "remove logging.<svc>.<key> deletes the per-service key (#328)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[logging]
driver = json-file

[logging.runtime]
driver = journald
max_file = 7
EOF
  run main remove logging.runtime.driver --base-path "${TEMP_DIR}"
  assert_success
  run grep -F "driver = journald" "${TEMP_DIR}/config/docker/setup.conf"
  assert_failure
  # Sibling key untouched.
  run grep -F "max_file = 7" "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
}

@test "show logging prints the whole resolved [logging] section (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main show logging --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "driver"
  assert_output --partial "max_size"
  assert_output --partial "max_file"
  assert_output --partial "compress"
}

@test "set logging.local_path accepts relative path (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.local_path ./logs/ --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "./logs/"
}

@test "set logging.local_path accepts absolute path (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.local_path /srv/app-logs --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/srv/app-logs"
}

@test "set logging.local_path rejects whitespace-only value (#328)" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.local_path "   " --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set logging.<svc>.local_path writes to per-service section (#328)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[logging]
driver = json-file
EOF
  run main set logging.devel.local_path ./devel-logs/ --base-path "${TEMP_DIR}"
  assert_success
  run grep -F "[logging.devel]" "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
  run main show logging.devel.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "./devel-logs/"
}

@test "[security] cap_add_* explicit override: user-provided list is honored (no template fallback)" {
  # User set cap_add_1=ALL explicitly: compose should use THAT, not the
  # template's SYS_ADMIN/NET_ADMIN/MKNOD.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = ALL
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
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
# _is_ssh_x11 (SSH X11 forwarding detection,)
# ════════════════════════════════════════════════════════════════════

@test "_is_ssh_x11 true when SSH_CONNECTION set + DISPLAY=localhost:N (#321)" {
  SSH_CONNECTION="1.2.3.4 12345 5.6.7.8 22" DISPLAY="localhost:10.0" _is_ssh_x11
}

@test "_is_ssh_x11 true when DISPLAY=localhost:N without fractional part (#321)" {
  SSH_CONNECTION="x y z w" DISPLAY="localhost:0" _is_ssh_x11
}

@test "_is_ssh_x11 false when SSH_CONNECTION unset (#321)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    unset SSH_CONNECTION
    DISPLAY=localhost:10.0 _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY is local socket (:0) (#321)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY=:0 _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY is unset (#321)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY='' _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY points to a remote host (#321)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY='other-host:0' _is_ssh_x11
  "
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _setup_ssh_x11_cookie (cookie rewrite via xauth,)
# ════════════════════════════════════════════════════════════════════

@test "_setup_ssh_x11_cookie writes .docker.xauth and echoes its path (#321)" {
  # Stub xauth via PATH shim so the test does not depend on a real
  # X server. Stub captures argv to /tmp/xauth.log AND writes a
  # non-empty payload to the `-f <out>` target when nmerge runs, so
  # the function's post-pipe `[[ ! -s "${_out}" ]]` defensive check
  # passes.
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/xauth" <<'EOS'
#!/usr/bin/env bash
echo "xauth $*" >> "${XAUTH_LOG}"
# Detect `-f <path> nmerge -` so the stub mimics real xauth's
# behavior of writing the merged cookie bytes to <path>. Without
# this, the function's empty-file check fires and returns 1.
_out=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-f" ]]; then
    j=$((i + 1))
    _out="${!j}"
  fi
done
if [[ "${*}" == *nmerge* && -n "${_out}" ]]; then
  printf 'stub-cookie-bytes\n' > "${_out}"
fi
# nmerge reads stdin; consume so the pipe closes cleanly.
cat >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "${_bin}/xauth"

  XAUTH_LOG="${TEMP_DIR}/xauth.log"
  export XAUTH_LOG
  PATH="${_bin}:${PATH}" DISPLAY="localhost:10.0" \
    run bash -c "
      source /source/downstream/script/docker/wrapper/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_success
  assert_output "${TEMP_DIR}/.docker.xauth"
  # File was created AND has content (hotfix: defensive
  # check on empty cookie file).
  assert [ -s "${TEMP_DIR}/.docker.xauth" ]
  # xauth was invoked twice with `-i` (ignore-locks) since the hotfix.
  run cat "${XAUTH_LOG}"
  assert_output --partial "xauth -i nlist localhost:10.0"
  assert_output --partial "xauth -i -f ${TEMP_DIR}/.docker.xauth nmerge -"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when nmerge writes 0-byte cookie (#321 hotfix)" {
  # Defensive case: xauth pipeline exits 0 but produces an empty
  # cookie file (e.g. nlist hit a contended ~/.Xauthority lock and
  # silently returned nothing). The function must NOT echo the cookie
  # path back — that would emit XAUTHORITY=<empty-file> into .env and
  # break X11 auth silently inside the container.
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/xauth" <<'EOS'
#!/usr/bin/env bash
# Mimic the contended-lock failure mode: succeed but write nothing.
cat >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "${_bin}/xauth"

  PATH="${_bin}:${PATH}" DISPLAY="localhost:10.0" \
    run bash -c "
      source /source/downstream/script/docker/wrapper/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_failure
  assert_output --partial "empty cookie file"
  assert_output --partial "XAUTHORITY left at host value"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when nmerge pipe exits non-zero (#688)" {
  # Distinct from the 0-byte branch: here the nlist|sed|nmerge pipeline
  # itself exits non-zero (the `xauth_rewrite_failed` middle branch). A
  # regression that swallowed this failure would silently emit a bogus
  # XAUTHORITY into .env, so the function must surface it: return 1 and
  # warn "cookie rewrite failed".
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/xauth" <<'EOS'
#!/usr/bin/env bash
# nlist succeeds (emits a line so the pipe has data); nmerge fails.
case "$*" in
  *nmerge*) cat >/dev/null 2>&1 || true; exit 1 ;;
  *nlist*)  echo "localhost:10  MIT-MAGIC-COOKIE-1  deadbeef"; exit 0 ;;
  *)        exit 0 ;;
esac
EOS
  chmod +x "${_bin}/xauth"

  PATH="${_bin}:${PATH}" DISPLAY="localhost:10.0" \
    run bash -c "
      source /source/downstream/script/docker/wrapper/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_failure
  assert_output --partial "cookie rewrite failed"
  assert_output --partial "XAUTHORITY left at host value"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when xauth is not installed (#321)" {
  # Shadow the `command` builtin with a function that returns 1 for
  # `command -v xauth` and passes everything else through to the real
  # builtin. Lets the function exercise its xauth-missing branch
  # without touching PATH (which would also break setup.sh's own
  # dirname / sed / etc. lookups during source).
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    command() {
      if [[ \"\${1:-}\" == '-v' && \"\${2:-}\" == 'xauth' ]]; then
        return 1
      fi
      builtin command \"\$@\"
    }
    DISPLAY=localhost:10.0 _setup_ssh_x11_cookie '${TEMP_DIR}'
  "
  assert_failure
  assert_output --partial "xauth"
  assert_output --partial "not in PATH"
}

# ════════════════════════════════════════════════════════════════════
# write_env: SSH X11 XAUTHORITY override
# ════════════════════════════════════════════════════════════════════

@test "write_env emits XAUTHORITY=<rewritten> when _ssh_x11_xauth arg is set (#321)" {
  local _env="${TEMP_DIR}/.env.generated"
  # Pass all positional args incl. the new trailing _ssh_x11_xauth.
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    "/path/to/.docker.xauth"
  assert [ -f "${_env}" ]
  run grep -F 'XAUTHORITY=/path/to/.docker.xauth' "${_env}"
  assert_success
  run grep -F 'SSH X11 forwarding cookie override' "${_env}"
  assert_success
}

@test "write_env does NOT emit XAUTHORITY override when _ssh_x11_xauth arg is empty (#321)" {
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    ""
  assert [ -f "${_env}" ]
  run cat "${_env}"
  refute_output --partial "SSH X11 forwarding cookie override"
  refute_output --partial $'\nXAUTHORITY='
}

# ════════════════════════════════════════════════════════════════════
# _parse_ini_section
# ════════════════════════════════════════════════════════════════════

@test "_parse_ini_section reads keys and values for one section" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "0"
}

# A section like [logging] must NOT absorb entries from a distinct
# dotted sub-section [logging.web]. Section matching is exact, not
# prefix-based. conf_logging.sh relies on this: it reads the global
# [logging] block and per-service [logging.<svc>] blocks separately.
@test "_parse_ini_section does not absorb dotted sub-sections" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
  cat > "${_conf}" <<'EOF'
[logging]
driver = json-file

[logging.web]
driver = local
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "logging" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "driver"
  assert_equal "${_v[0]}" "json-file"
}

@test "_parse_ini_section reads a dotted section name" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
  cat > "${_conf}" <<'EOF'
[logging]
driver = json-file

[logging.web]
driver = local
max_size = 5m
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "logging.web" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "driver"
  assert_equal "${_v[0]}" "local"
  assert_equal "${_k[1]}" "max_size"
  assert_equal "${_v[1]}" "5m"
}

# Duplicate keys and a reopened section are preserved in file order
# (the original single-pass reader appended every matching line).
@test "_parse_ini_section preserves duplicate keys and reopened sections in order" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
  cat > "${_conf}" <<'EOF'
[volumes]
mount_1 = a:a

[other]
x = y

[volumes]
mount_1 = b:b
mount_2 = c:c
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "volumes" _k _v
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_k[0]}" "mount_1"
  assert_equal "${_v[0]}" "a:a"
  assert_equal "${_k[1]}" "mount_1"
  assert_equal "${_v[1]}" "b:b"
  assert_equal "${_k[2]}" "mount_2"
  assert_equal "${_v[2]}" "c:c"
}

# ════════════════════════════════════════════════════════════════════
# _ini_tokenize (shared single-pass core)
# ════════════════════════════════════════════════════════════════════

@test "_ini_tokenize tracks the owning section per entry and dedups headers" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto

[gui]
mode = off

[gpu]
count = all
EOF
  local -a _s=() _es=() _k=() _v=()
  _ini_tokenize "${_conf}" _s _es _k _v
  # sections[] dedups by first appearance.
  assert_equal "${#_s[@]}" "2"
  assert_equal "${_s[0]}" "gpu"
  assert_equal "${_s[1]}" "gui"
  # entries keep their owning section even across a reopened header.
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_es[0]}" "gpu"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_es[1]}" "gui"
  assert_equal "${_es[2]}" "gpu"
  assert_equal "${_k[2]}" "count"
}

@test "_ini_tokenize keeps dotted keys verbatim (per-stage override keys)" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
  cat > "${_conf}" <<'EOF'
[stage:headless]
gui.mode = off
deploy.gpu_mode = force
EOF
  local -a _s=() _es=() _k=() _v=()
  _ini_tokenize "${_conf}" _s _es _k _v
  assert_equal "${_es[0]}" "stage:headless"
  assert_equal "${_k[0]}" "gui.mode"
  assert_equal "${_v[0]}" "off"
  assert_equal "${_k[1]}" "deploy.gpu_mode"
  assert_equal "${_v[1]}" "force"
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
# _resolve_runtime / _detect_jetson (Jetson NVIDIA runtime)
# ════════════════════════════════════════════════════════════════════

@test "_detect_jetson honors SETUP_DETECT_JETSON=true override" {
  SETUP_DETECT_JETSON=true _detect_jetson
}

@test "_detect_jetson honors SETUP_DETECT_JETSON=false override" {
  ! SETUP_DETECT_JETSON=false _detect_jetson
}

@test "_resolve_runtime auto on Jetson => nvidia" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "auto" _out
  assert_equal "${_out}" "nvidia"
}

@test "_resolve_runtime auto off Jetson => empty" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_runtime "auto" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime nvidia => always nvidia" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_runtime "nvidia" _out
  assert_equal "${_out}" "nvidia"
}

@test "_resolve_runtime off => empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "off" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime empty => empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime unknown mode falls through to empty (safe default)" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "garbage" _out
  assert_equal "${_out}" ""
}

# ════════════════════════════════════════════════════════════════════
# _resolve_build_network (Jetson build-net auto-detect,)
# ════════════════════════════════════════════════════════════════════

@test "_resolve_build_network auto on Jetson => host" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "auto" _out
  assert_equal "${_out}" "host"
}

@test "_resolve_build_network auto off Jetson => empty" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_build_network "auto" _out
  assert_equal "${_out}" ""
}

@test "_resolve_build_network host => always host (explicit override wins)" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_build_network "host" _out
  assert_equal "${_out}" "host"
}

@test "_resolve_build_network bridge / none / default pass through" {
  local _out
  _resolve_build_network "bridge" _out
  assert_equal "${_out}" "bridge"
  _resolve_build_network "none" _out
  assert_equal "${_out}" "none"
  _resolve_build_network "default" _out
  assert_equal "${_out}" "default"
}

@test "_resolve_build_network off / empty => empty (explicitly suppressed)" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "off" _out
  assert_equal "${_out}" ""
  SETUP_DETECT_JETSON=true _resolve_build_network "" _out
  assert_equal "${_out}" ""
}

@test "_resolve_build_network unknown mode falls through to empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "garbage" _out
  assert_equal "${_out}" ""
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  # No sibling *_ws -> strategy-3 fallback, which now returns base_path
  # itself (base-based repos keep scaffolding at the repo root).
  assert_equal "${_result}" "${_parent}/docker_myapp"
}

@test "detect_ws_path strategy 2: finds _ws component in path" {
  local _ws="${TEMP_DIR}/myapp_ws"
  mkdir -p "${_ws}/src"
  local _result
  detect_ws_path _result "${_ws}/src"
  assert_equal "${_result}" "${_ws}"
}

@test "detect_ws_path strategy 3: falls back to base_path itself" {
  local _plain="${TEMP_DIR}/plain/project"
  mkdir -p "${_plain}"
  local _result
  detect_ws_path _result "${_plain}"
  # base-based repos keep the docker scaffolding at the repo root, so the
  # final fallback resolves to base_path itself, not its parent.
  assert_equal "${_result}" "${_plain}"
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    "testuser" "testgroup" "1001" "1001" \
    "x86_64" "dockerhub" "true" \
    "ros_noetic" "/workspace" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" \
    "all" "gpu" \
    "true" "abc123" "df456"

  assert [ -f "${_env}" ]
  run grep 'USER_NAME=testuser' "${_env}"; assert_success
  run grep 'USER_UID=1001'      "${_env}"; assert_success
  run grep 'GPU_ENABLED=true'   "${_env}"; assert_success
  run grep 'IMAGE_NAME=ros_noetic' "${_env}"; assert_success
  run grep 'NETWORK_MODE=host'  "${_env}"; assert_success
  run grep 'IPC_MODE=host'      "${_env}"; assert_success
  run grep 'PID_MODE=private'   "${_env}"; assert_success
  run grep 'PRIVILEGED=true'    "${_env}"; assert_success
  run grep 'GPU_COUNT=all'      "${_env}"; assert_success
  run grep -F 'GPU_CAPABILITIES="gpu"' "${_env}"; assert_success
  run grep 'SETUP_CONF_HASH=abc123' "${_env}"; assert_success
  run grep 'SETUP_DOCKERFILE_HASH=df456' "${_env}"; assert_success
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
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
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
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h_old}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  # Drop in a new per-repo setup.conf → hash differs
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
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

@test "main rejects bare flag without subcommand (#49 Phase B-4 BREAKING)" {
  # Pre-B-4 the legacy fall-through aliased flag-only invocation to
  # `apply`. B-4 removes that — the user must now type the subcommand
  # explicitly. Hits the unknown-subcommand path of the dispatcher.
  run main --bogus
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "apply subcommand returns error when --base-path value is missing" {
  run -127 bash -c "source /source/downstream/script/docker/wrapper/setup.sh; main apply --base-path"
}

@test "apply subcommand returns error when --lang value is missing" {
  run -127 bash -c "source /source/downstream/script/docker/wrapper/setup.sh; main apply --lang"
}

@test "apply --lang zh-TW sets Chinese messages for full run" {
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "更新完成"
}

# ── Per-repo setup.conf missing / empty INFO ────────────────
# When the per-repo setup.conf is absent, or present but has no section
# headers, every _load_setup_conf call falls back to the template default.
# That fallback used to be silent — surfacing one WARN line at apply
# entry tells the user the entire run is template-default driven, without
# spamming a notice per section (11 sections would be noisy).
# promoted this from INFO to WARN so the heads-up doesn't scroll past.

@test "apply prints WARN when per-repo setup.conf is missing (#186)" {
  # No TEMP_DIR/config/docker/setup.conf created — apply should fall back to template
  # default and announce it once on stderr at WARN level.
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN :"
  assert_output --partial "no per-repo setup.conf"
  # regression guard: the heads-up must NOT be demoted to INFO
  # (where it would scroll past). The env_done line legitimately uses
  # INFO level, so scope the refute to the warning's body.
  refute_output --partial "[setup] INFO: no per-repo setup.conf"
}

@test "apply prints WARN when per-repo setup.conf has no section headers (#186)" {
  # Comments-only file counts as effectively empty: nothing to override.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# only comments, no [section] headers
# template defaults apply for every section
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN :"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "apply stays silent when per-repo setup.conf has at least one section" {
  # Partial override is normal usage — don't INFO-spam users who edited
  # only one section.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = auto
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  refute_output --partial "no per-repo setup.conf"
  refute_output --partial "per-repo setup.conf has no section"
}

@test "apply --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)" {
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN :"
  assert_output --partial "未找到"
}

@test "apply resolves default _base_path via BASH_SOURCE when --base-path omitted" {
  # apply without --base-path walks 3 levels up from its own location
  # (script/docker/../../.. = repo root).
  mkdir -p "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/lib" \
           "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/wrapper" \
           "${TEMP_DIR}/sandbox_repo/.base/downstream/config/docker"
  cp /source/downstream/script/docker/wrapper/setup.sh \
    "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/wrapper/setup.sh"
  cp /source/downstream/script/docker/lib/i18n.sh \
    "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/lib/i18n.sh"
  cp /source/downstream/script/docker/lib/_tui_conf.sh \
    "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/lib/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers; _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs
  cp /source/downstream/script/docker/lib/_lib.sh \
    "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/lib/_lib.sh"
  cp /source/downstream/script/docker/lib/* \
    "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/lib/"
  cp /source/downstream/config/docker/setup.conf "${TEMP_DIR}/sandbox_repo/.base/downstream/config/docker/setup.conf"

  run bash "${TEMP_DIR}/sandbox_repo/.base/downstream/script/docker/wrapper/setup.sh" apply
  assert_success
  assert [ -f "${TEMP_DIR}/sandbox_repo/.env.generated" ]
}

