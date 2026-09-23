#!/usr/bin/env bats
#
# why: Mirrors `lib/ini_to_toml_migrate.sh`. Downstream repos upgrading to
# the TOML config format (ADR-00000037) need their existing INI files
# (.setup.conf, .setup.conf.local) and flat env (.env.local) converted
# to TOML on the first init.sh resync after the base upgrade. This spec
# pins the converter's:
#   - numbered-key -> array-of-tables mapping (the 8 INI patterns)
#   - scalar key quoting (string/boolean/integer)
#   - idempotency (skip when TOML file already exists)
#   - backup (.bak suffix)
#   - env_N unpack (environment.env_N = K=V -> [environment] K = "V")
#   - .env.local flat KEY=VALUE -> .env.local.toml [environment]

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _src
#   Source the lib in a fresh shell so each test drives the real function
#   body. _lib.sh brings in _ini_tokenize + _log_* messaging.
_src() {
  printf 'source %s/_lib.sh; source %s/ini_to_toml_migrate.sh' "${LIB}" "${LIB}"
}

# ── .setup.conf -> setup.toml: scalar keys ─────────────────────────────

# why: A plain scalar key becomes a TOML quoted string
@test "_migrate_ini_to_toml converts scalar keys to quoted TOML strings (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
[lifecycle]
restart = unless-stopped
init = true
[logging]
max_file = 3
compress = true
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/setup.toml"
  # Strings are quoted
  assert_output --partial 'mode = "off"'
  assert_output --partial 'restart = "unless-stopped"'
  # Booleans are bare
  assert_output --partial 'init = true'
  assert_output --partial 'compress = true'
  # Integers are bare
  assert_output --partial 'max_file = 3'
}

# why: Empty values become empty TOML strings
@test "_migrate_ini_to_toml emits empty values as empty TOML strings (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[project]
name =
[resources]
shm_size =
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial 'name = ""'
  assert_output --partial 'shm_size = ""'
}

# ── .setup.conf -> setup.toml: numbered keys ───────────────────────────

# why: The eight numbered-key patterns each become the right AoT shape
@test "_migrate_ini_to_toml converts image rule_N to [[image.rules]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = prefix:docker_
rule_2 = @basename
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[[image.rules]]'
  assert_output --partial 'rule = "prefix:docker_"'
  assert_output --partial 'rule = "@basename"'
}

# why: build arg_N splits on = and emits key/value AoT; wrong split loses the value
@test "_migrate_ini_to_toml converts build arg_N to [[build.args]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
target_arch =
network = auto
arg_1 = APT_MIRROR_UBUNTU=tw.archive.ubuntu.com
arg_2 = TZ=Asia/Taipei
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  # Scalars under [build]
  assert_output --partial '[build]'
  assert_output --partial 'network = "auto"'
  # Numbered keys as AoT
  assert_output --partial '[[build.args]]'
  assert_output --partial 'key = "APT_MIRROR_UBUNTU"'
  assert_output --partial 'value = "tw.archive.ubuntu.com"'
  assert_output --partial 'key = "TZ"'
  assert_output --partial 'value = "Asia/Taipei"'
}

# why: Volume paths contain colons; the converter must not split on them
@test "_migrate_ini_to_toml converts volumes mount_N to [[volumes]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
mount_1 = /home/user/work:/home/docker/work:rw
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[[volumes]]'
  assert_output --partial 'path = "/home/user/work:/home/docker/work:rw"'
}

# why: Two distinct AoT shapes live under one INI section; wrong dispatch conflates them
@test "_migrate_ini_to_toml converts security cap/opt to [[security.*]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = SYS_ADMIN
cap_add_2 = NET_ADMIN
security_opt_1 = seccomp:unconfined
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[security]'
  assert_output --partial 'privileged = false'
  assert_output --partial '[[security.cap_add]]'
  assert_output --partial 'cap = "SYS_ADMIN"'
  assert_output --partial 'cap = "NET_ADMIN"'
  assert_output --partial '[[security.security_opt]]'
  assert_output --partial 'opt = "seccomp:unconfined"'
}

# why: Port mappings split into host/container integers; wrong type breaks compose
@test "_migrate_ini_to_toml converts network port_N to [[network.ports]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
mode = bridge
port_1 = 8080:80
port_2 = 3000:3000
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[network]'
  assert_output --partial 'mode = "bridge"'
  assert_output --partial '[[network.ports]]'
  assert_output --partial 'host = 8080'
  assert_output --partial 'container = 80'
}

# why: Device paths look like volume paths; the converter must pick the right AoT key
@test "_migrate_ini_to_toml converts devices device_N to [[devices]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[devices]
device_1 = /dev:/dev
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[[devices]]'
  assert_output --partial 'path = "/dev:/dev"'
}

# why: tmpfs entries carry size options after a colon; the value must stay whole
@test "_migrate_ini_to_toml converts tmpfs tmpfs_N to [[tmpfs]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[tmpfs]
tmpfs_1 = /tmp:size=64m
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[[tmpfs]]'
  assert_output --partial 'path = "/tmp:size=64m"'
}

# why: Context entries split on = into name/source; wrong split drops the build context path
@test "_migrate_ini_to_toml converts additional_contexts context_N to [[additional_contexts]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[additional_contexts]
context_1 = myctx=./path
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[[additional_contexts]]'
  assert_output --partial 'name = "myctx"'
  assert_output --partial 'source = "./path"'
}

# ── environment env_N unpack ───────────────────────────────────────────

# why: env_N entries unpack to direct KEY = "VALUE" pairs, not AoT
@test "_migrate_ini_to_toml unpacks environment env_N to direct key-value (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[environment]
env_1 = SIGNALING_SERVER=localhost
env_2 = LOG_LEVEL=debug
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[environment]'
  assert_output --partial 'SIGNALING_SERVER = "localhost"'
  assert_output --partial 'LOG_LEVEL = "debug"'
  # Must NOT produce [[environment.*]]
  refute_output --partial '[[environment'
}

# ── empty numbered-key slots are skipped ───────────────────────────────

# why: An empty mount_1 = is an opt-out slot, not a volume to emit
@test "_migrate_ini_to_toml skips empty numbered-key slots (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /data:/data
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  local _out
  _out="$(cat "${TEMP_DIR}/setup.toml")"
  # Only mount_2 is emitted (non-empty)
  local _count
  _count="$(grep -c '^\[\[volumes\]\]' "${TEMP_DIR}/setup.toml")"
  [ "${_count}" -eq 1 ]
  [[ "${_out}" == *'path = "/data:/data"'* ]]
}

# ── idempotency ────────────────────────────────────────────────────────

# why: A repo that already has setup.toml must not be re-converted
@test "_migrate_ini_to_toml is idempotent when setup.toml exists (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  printf 'existing content\n' > "${TEMP_DIR}/setup.toml"
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output "existing content"
  # INI file is NOT backed up (nothing happened)
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/.setup.conf.bak" ]
}

# why: A repo that already has setup.local.toml must not be re-converted
@test "_migrate_ini_to_toml is idempotent when setup.local.toml exists (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = wayland
EOF
  printf 'existing local\n' > "${TEMP_DIR}/setup.local.toml"
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.local.toml"
  assert_output "existing local"
  assert [ -f "${TEMP_DIR}/.setup.conf.local" ]
}

# ── backup ─────────────────────────────────────────────────────────────

# why: The original INI file is renamed to .bak for the user to verify
@test "_migrate_ini_to_toml backs up .setup.conf to .setup.conf.bak (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ ! -f "${TEMP_DIR}/.setup.conf" ]
  assert [ -f "${TEMP_DIR}/.setup.conf.bak" ]
  run cat "${TEMP_DIR}/.setup.conf.bak"
  assert_output --partial 'mode = auto'
}

# why: The local override must also be backed up so the user can verify the conversion
@test "_migrate_ini_to_toml backs up .setup.conf.local (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = wayland
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.local.toml" ]
  assert [ ! -f "${TEMP_DIR}/.setup.conf.local" ]
  assert [ -f "${TEMP_DIR}/.setup.conf.local.bak" ]
}

# ── .setup.conf.local -> setup.local.toml ──────────────────────────────

# why: The per-instance override is converted the same way
@test "_migrate_ini_to_toml converts .setup.conf.local to setup.local.toml (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = wayland
[volumes]
mount_1 = /my/path:/container/path
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.local.toml" ]
  run cat "${TEMP_DIR}/setup.local.toml"
  assert_output --partial '[gui]'
  assert_output --partial 'mode = "wayland"'
  assert_output --partial '[[volumes]]'
  assert_output --partial 'path = "/my/path:/container/path"'
}

# ── inertness ──────────────────────────────────────────────────────────

# why: No INI file means no conversion and no output file
@test "_migrate_ini_to_toml is inert when there is no INI file (#1137)" {
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  assert [ ! -f "${TEMP_DIR}/setup.local.toml" ]
}

# ── .env.local -> .env.local.toml ─────────────────────────────────────

# why: Flat KEY=VALUE wraps under [environment]
@test "_migrate_env_local_to_toml converts .env.local to .env.local.toml (#1137)" {
  cat > "${TEMP_DIR}/.env.local" <<'EOF'
ROS_MASTER_URI=http://localhost:11311
LOG_LEVEL=debug
EOF
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.local.toml" ]
  run cat "${TEMP_DIR}/.env.local.toml"
  assert_output --partial '[environment]'
  assert_output --partial 'ROS_MASTER_URI = "http://localhost:11311"'
  assert_output --partial 'LOG_LEVEL = "debug"'
}

# why: The env override must be backed up; without this the user loses their original file
@test "_migrate_env_local_to_toml backs up .env.local to .env.local.bak (#1137)" {
  printf 'KEY=VALUE\n' > "${TEMP_DIR}/.env.local"
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ ! -f "${TEMP_DIR}/.env.local" ]
  assert [ -f "${TEMP_DIR}/.env.local.bak" ]
}

# why: A second init cycle must not overwrite an operator's already-converted env overrides
@test "_migrate_env_local_to_toml is idempotent when .env.local.toml exists (#1137)" {
  printf 'KEY=VALUE\n' > "${TEMP_DIR}/.env.local"
  printf 'existing\n' > "${TEMP_DIR}/.env.local.toml"
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/.env.local.toml"
  assert_output "existing"
  # Original not backed up (nothing happened)
  assert [ -f "${TEMP_DIR}/.env.local" ]
}

# why: Comments and blanks from flat env are noise in TOML; carrying them pollutes the output
@test "_migrate_env_local_to_toml skips comments and blank lines (#1137)" {
  cat > "${TEMP_DIR}/.env.local" <<'EOF'
# comment
KEY=VALUE

# another comment
OTHER=VAL
EOF
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/.env.local.toml"
  assert_output --partial 'KEY = "VALUE"'
  assert_output --partial 'OTHER = "VAL"'
  refute_output --partial '# comment'
}

# why: A repo with no .env.local must not produce a phantom .env.local.toml
@test "_migrate_env_local_to_toml is inert when there is no .env.local (#1137)" {
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ ! -f "${TEMP_DIR}/.env.local.toml" ]
}

# why: Values with = in them split on the FIRST = only
@test "_migrate_env_local_to_toml handles values containing = (#1137)" {
  printf 'JAVA_OPTS=-Xmx=1g\n' > "${TEMP_DIR}/.env.local"
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/.env.local.toml"
  assert_output --partial 'JAVA_OPTS = "-Xmx=1g"'
}

# ── per-stage section quoting ──────────────────────────────────────────

# why: A section name containing : needs TOML quoting
@test "_migrate_ini_to_toml quotes section names containing colon (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[stage:headless]
gui.mode = off
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '["stage:headless"]'
  assert_output --partial '"gui.mode" = "off"'
}
