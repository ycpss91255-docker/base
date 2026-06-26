#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"
# ════════════════════════════════════════════════════════════════════
# Per-section setup.conf parameter end-to-end coverage
#
# Each test sets a single key in <repo>/config/docker/setup.conf and asserts the
# expected line appears in compose.yaml or .env. Companion negative
# tests confirm the corresponding compose / env block is omitted when
# the key is empty / cleared. Ensures every key documented in
# .base/dist/config/docker/setup.conf has a setting → output assertion.
# ════════════════════════════════════════════════════════════════════

# ── [deploy] ─────────────────────────────────────────────────────────

@test "[deploy] gpu_mode = off omits deploy.resources block from compose.yaml" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[deploy]
gpu_mode = off
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'deploy:' '${TEMP_DIR}/compose.yaml' | head -1
  "
  assert_output ""
}

@test "[deploy] gpu_mode = force emits deploy.resources GPU block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[deploy]
gpu_mode = force
gpu_count = all
gpu_capabilities = gpu compute
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E 'driver: nvidia' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] gpu_count = 2 emits count: 2 in compose deploy block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[deploy]
gpu_mode = force
gpu_count = 2
gpu_capabilities = gpu
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E 'count: 2$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] gpu_capabilities multi-value emits as YAML array" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[deploy]
gpu_mode = force
gpu_count = all
gpu_capabilities = gpu compute utility
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'capabilities: [gpu, compute, utility]' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] runtime = nvidia emits runtime: nvidia at service level" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[deploy]
gpu_mode = off
runtime = nvidia
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^    runtime: nvidia$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] runtime = off omits runtime line entirely" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[deploy]
gpu_mode = off
runtime = off
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^    runtime:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [gui] ────────────────────────────────────────────────────────────

@test "[gui] mode = off omits X11 / DISPLAY env from compose" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = off
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'DISPLAY' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

@test "[gui] mode = force emits X11 environment + /tmp/.X11-unix mount" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F '/tmp/.X11-unix:/tmp/.X11-unix:ro' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

# ── [network] ────────────────────────────────────────────────────────

@test "[network] mode = host writes NETWORK_MODE=host to .env" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^NETWORK_MODE=' '${TEMP_DIR}/.env.generated'
  "
  assert_output "NETWORK_MODE=host"
}

@test "[network] ipc = private writes IPC_MODE=private to .env" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = private
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^IPC_MODE=' '${TEMP_DIR}/.env.generated'
  "
  assert_output "IPC_MODE=private"
}

@test "[network] pid = host writes PID_MODE=host to .env" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
pid = host
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^PID_MODE=' '${TEMP_DIR}/.env.generated'
  "
  assert_output "PID_MODE=host"
}

@test "[network] pid default (private) writes PID_MODE=private to .env" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^PID_MODE=' '${TEMP_DIR}/.env.generated'
  "
  assert_output "PID_MODE=private"
}

@test "[network] pid default (private) omits pid: line from compose.yaml" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep 'pid:' '${TEMP_DIR}/compose.yaml'
  "
  assert_failure
}

@test "[network] pid = host emits pid: host in compose.yaml" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
pid = host
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'pid: \${PID_MODE}' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[network] network_name = my_bridge under mode=bridge emits external network ref" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = bridge
ipc = private
network_name = my_bridge
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^networks:' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[network] port_1 = 8080:80 emits ports: block under bridge mode" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = bridge
ipc = private
port_1 = 8080:80
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '8080:80' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[network] port_* under mode=host is silently dropped" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
port_1 = 8080:80
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '8080:80' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [resources] ──────────────────────────────────────────────────────

@test "[resources] shm_size = 2gb under ipc=private emits shm_size: 2gb" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
ipc = private
[resources]
shm_size = 2gb
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E 'shm_size: 2gb' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[resources] shm_size empty omits shm_size line" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[resources]
shm_size =
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'shm_size:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [environment] ────────────────────────────────────────────────────

@test "[environment] env_1 = ROS_DOMAIN_ID=7 emits environment: block in compose" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = ROS_DOMAIN_ID=7
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'ROS_DOMAIN_ID=7' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[environment] empty section omits environment: block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^    environment:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [tmpfs] ──────────────────────────────────────────────────────────

@test "[tmpfs] tmpfs_1 = /tmp emits tmpfs: block with the entry" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[tmpfs]
tmpfs_1 = /tmp
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^      - /tmp$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[tmpfs] tmpfs_1 with size= suffix preserved verbatim" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[tmpfs]
tmpfs_1 = /tmp/cache:size=1g
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F '/tmp/cache:size=1g' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[tmpfs] empty section omits tmpfs: block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[tmpfs]
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^    tmpfs:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [devices] ────────────────────────────────────────────────────────

@test "[devices] device_1 = /dev/video0:/dev/video0 emits devices: block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[devices]
device_1 = /dev/video0:/dev/video0
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E -- '- /dev/video0:/dev/video0' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[devices] cgroup_rule_1 emits device_cgroup_rules: block" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[devices]
device_1 = /dev:/dev
cgroup_rule_1 = c 189:* rwm
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'c 189:* rwm' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

# ── [volumes] mount_2..N ─────────────────────────────────────────────

@test "[volumes] mount_2 = /data:/data emits as additional volume entry" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /data:/data
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E -- '- /data:/data' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[volumes] mount_N supports :ro suffix" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /etc/machine-id:/etc/machine-id:ro
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F '/etc/machine-id:/etc/machine-id:ro' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

# ── [security] privileged toggle ─────────────────────────────────────

@test "[security] privileged = false writes PRIVILEGED=false to .env" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^PRIVILEGED=' '${TEMP_DIR}/.env.generated'
  "
  assert_output "PRIVILEGED=false"
}

# ── apply-time trust boundary (hand-edited setup.conf) ────────────────
# apply reads setup.conf via the conf.sh readers and emits compose.yaml
# with NO schema revalidation (validation lives only on the set/add write
# paths). These tests pin the apply-time contract for malformed /
# metacharacter values that a user can hand-write into the file.

@test "[environment] apply does NOT execute a command-substitution env value (#687)" {
  # A `$(...)` payload in env_1 must reach compose.yaml as inert text, not
  # be executed at apply time (it stays text; compose's own layer never
  # runs it either since there is no eval).
  rm -f "${TEMP_DIR}/pwn687"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<EOF
[environment]
env_1 = EVIL=\$(touch ${TEMP_DIR}/pwn687)
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  [ ! -e "${TEMP_DIR}/pwn687" ]
}

@test "[environment] apply emits an injection-style env value on a single line (#687)" {
  # The INI reader is line-oriented, so a hand-written value cannot smuggle
  # a real newline; the metacharacter payload stays on one environment:
  # entry and never becomes a second YAML key.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = EVIL=$(touch /tmp/x)
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'EVIL=' '${TEMP_DIR}/compose.yaml'
  "
  assert_output "1"
}

@test "[lifecycle] apply does not emit a restart: line for a malformed policy (#687)" {
  # A hand-written invalid policy (bypassing the set-path validator) must
  # not silently produce a bogus `restart: sometimes` in compose.yaml.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[lifecycle]
restart = sometimes
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'restart: sometimes' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

@test "[environment] apply quotes an env value containing a colon-space so YAML keeps it a scalar (#698)" {
  # A validator-accepted value with a YAML-structural ': ' (e.g.
  # MSG=a: b) emitted UNQUOTED parses as the mapping {MSG=a: b} —
  # silent env corruption. The emit must wrap each entry as a
  # double-quoted YAML scalar, mirroring ports/cgroup.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = MSG=a: b
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'MSG=a: b' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
  assert_output --partial '- "MSG=a: b"'
}

@test "[environment] apply quotes an env value with a leading flow indicator (#698)" {
  # A leading '*' (YAML alias/flow indicator) emitted unquoted breaks
  # the parse; quoting makes it an inert scalar.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = GLOB=*
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'GLOB=' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
  assert_output --partial '- "GLOB=*"'
}

@test "[environment] apply quotes an env value with an inline ' #' comment marker (#698)" {
  # An unquoted ' #' truncates the YAML scalar at the comment; quoting
  # preserves the whole value.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = NOTE=a #b
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'NOTE=a #b' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
  assert_output --partial '- "NOTE=a #b"'
}

@test "[environment] apply escapes embedded double-quote / backslash in env value (#698)" {
  # The YAML double-quoted scalar must escape \" and \\ so the value
  # round-trips verbatim (mirrors the Dockerfile baked-ENV sink).
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = Q=a"b\c
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'Q=' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
  assert_output --partial '- "Q=a\"b\\c"'
}

@test "[network] apply does not emit a literal network_mode: line for a bogus hand-edited mode (#698)" {
  # apply does no schema revalidation, so a hand-edited [stage:*]
  # network.mode bypasses the set-path validator. A bogus value must be
  # dropped (fall back to the env-var ref) rather than emit a malformed
  # literal `network_mode: bogus` that breaks `docker compose up`.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host

[stage:headless]
network.mode = bogus: value
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'network_mode: bogus' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

@test "[network] apply does not emit a literal ipc:/pid: line for a bogus hand-edited mode (#698)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
ipc = host
pid = private

[stage:headless]
network.ipc = bogus: value
network.pid = bogus: value
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    { grep -c 'ipc: bogus' '${TEMP_DIR}/compose.yaml' || true; } | head -1
  "
  assert_output "0"
}

