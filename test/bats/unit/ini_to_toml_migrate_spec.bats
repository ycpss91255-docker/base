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
#   - refusal: an input it cannot render as parseable TOML leaves the
#     source INI where it was, writes no target, and says so

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
  # source / target / mode, which is what the bridge's array spec reads a
  # `[[volumes]]` entry back from and what the shipped writer emits. A
  # single `path` field reads back as an empty mount.
  assert_output --partial 'source = "/home/user/work"'
  assert_output --partial 'target = "/home/docker/work"'
  assert_output --partial 'mode = "rw"'
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

# why: Port mappings split into a host and a container half. Both are
# string-typed -- the bridge glues them back with `:` and the compose
# emitter reads the one joined string -- so the converter quotes them
# whatever the INI digits looked like, the same rule every other
# array-of-tables field follows.
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
  assert_output --partial 'host = "8080"'
  assert_output --partial 'container = "80"'
}

# why: Device paths look like volume paths; the converter must pick the
# right AoT key. `[devices]` is also the one section with TWO numbered
# families, so each has to land in its own nested array -- a binding and a
# rule in the same INI used to convert into one name used as both an array
# and a table, which TOML refuses and which cost the whole file.
@test "_migrate_ini_to_toml converts devices device_N to [[devices.bindings]] (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[devices]
device_1 = /dev:/dev
cgroup_rule_1 = c 189:* rwm
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[[devices.bindings]]'
  assert_output --partial 'path = "/dev:/dev"'
  assert_output --partial '[[devices.cgroup_rules]]'
  assert_output --partial 'rule = "c 189:* rwm"'
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

# why: `[environment] env_N` has no array-of-tables home, so it is carried
# over as the scalar it was. The direct-key `KEY = "VALUE"` form the
# template documents is where D5 / D6 take the section; until those readers
# land, `_conf_list_sorted ... environment env_` is what reads it, so
# unpacking here drops the variable from `.env` and from the container.
@test "_migrate_ini_to_toml carries environment env_N over as a scalar (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[environment]
env_1 = SIGNALING_SERVER=localhost
env_2 = LOG_LEVEL=debug
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial '[environment]'
  assert_output --partial 'env_1 = "SIGNALING_SERVER=localhost"'
  assert_output --partial 'env_2 = "LOG_LEVEL=debug"'
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
  [[ "${_out}" == *'source = "/data"'* ]]
  [[ "${_out}" == *'target = "/data"'* ]]
}

# ── idempotency ────────────────────────────────────────────────────────

# why: A repo that already has setup.toml must not be re-converted
@test "_migrate_ini_to_toml is idempotent when setup.toml exists (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  printf '# existing content\n' > "${TEMP_DIR}/setup.toml"
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.toml"
  assert_output "# existing content"
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
  printf '# existing local\n' > "${TEMP_DIR}/setup.local.toml"
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/setup.local.toml"
  assert_output "# existing local"
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
  assert_output --partial 'source = "/my/path"'
  assert_output --partial 'target = "/container/path"'
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
  printf '# existing\n' > "${TEMP_DIR}/.env.local.toml"
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/.env.local.toml"
  assert_output "# existing"
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

# ── Round trip: what the converter writes is what the bridge reads ─────
#
# Every case above asserts the TEXT the converter emits. None of them asks
# the shipped reader what that text means, so a field name the bridge does
# not know, a key the runtime readers do not look for, and a value that is
# not valid TOML all pass. The cases below convert an INI file and then
# hand the result to the bridge in this checkout, so the assertion is the
# configuration the shell side gets back.

BRIDGE_PY="/source/dockerfile/toml_bridge.py"

# why: a migration that loses a mount, an env var or a dropped capability is
#      worse than one that refuses: the repo comes back up with the
#      workspace unmounted, the variable gone and a capability the operator
#      removed restored, and the only record of what it used to be is a
#      .bak file nothing reads.
@test "_migrate_ini_to_toml: the converted file reads back as the same configuration (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
mount_1 = /home/user/work:/home/docker/work:rw
mount_2 = /data:/data
[environment]
env_1 = ROS_DOMAIN_ID=42
[security]
cap_add_1 = SYS_ADMIN
cap_drop_1 = NET_RAW
security_opt_1 = seccomp:unconfined
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success

  run python3 "${BRIDGE_PY}" --kv < "${TEMP_DIR}/setup.toml"
  assert_success
  assert_line "volumes	mount_1	/home/user/work:/home/docker/work:rw"
  assert_line "volumes	mount_2	/data:/data"
  assert_line "environment	env_1	ROS_DOMAIN_ID=42"
  assert_line "security	cap_add_1	SYS_ADMIN"
  assert_line "security	cap_drop_1	NET_RAW"
  assert_line "security	security_opt_1	seccomp:unconfined"
}

# why: the converter renames the INI out of the way, so a value it renders
#      as invalid TOML takes the only copy of the configuration with it.
#      A double quote inside a build arg and a backslash inside a watchdog
#      command are both ordinary INI values.
@test "_migrate_ini_to_toml: a quote or a backslash in a value survives (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
arg_1 = APP_FLAGS=--label="hello"
[lifecycle]
watchdog_check = pgrep -f a\bc
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success

  run python3 "${BRIDGE_PY}" --kv < "${TEMP_DIR}/setup.toml"
  assert_success
  assert_line 'build	arg_1	APP_FLAGS=--label="hello"'
  assert_line 'lifecycle	watchdog_check	pgrep -f a\bc'
}

# ── Refusal: the source INI outlives a conversion that does not parse ──
#
# Every case above converts an INI file the converter CAN place. The
# migration renames the source out of the way unconditionally, so an input
# it renders as invalid TOML took the operator's only copy with it: the
# repo was left with an unparseable setup.toml, a .setup.conf.bak that is
# in the shipped .gitignore, and an idempotency gate that will never
# convert again because the target now exists.
#
# A key repeated inside one section is such an input. INI reads are
# last-wins, so an operator who appended a line rather than editing one
# has a file that works; TOML refuses to overwrite a value, so the
# conversion of it does not parse. These cases assert the containment,
# not that particular input: whatever cannot be converted, the source
# survives it.

# why: an INI key repeated inside one section is last-wins and works, and
#      its conversion is a TOML document that overwrites a value, which
#      the parser refuses. The repo must come out of this with its
#      configuration still on disk and readable, because the refusal is
#      recoverable and the rename is not.
@test "_migrate_ini_to_toml keeps the INI when the conversion does not parse (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[project]
name = my-robot
[gui]
mode = off
mode = on
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert_output --partial '.setup.conf'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/.setup.conf.bak" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial 'mode = on'
}

# why: the refusal has to name the input, or the operator reading a resync
#      log of fifty lines cannot tell which of three files it was about,
#      and the one actionable fact -- that their config is untouched --
#      is the one they need.
@test "_migrate_ini_to_toml names the refused input and what the parser objected to (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
mode = on
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial "MIGRATION DECLINED for ${TEMP_DIR}/.setup.conf"
  assert_output --partial 'nothing was written and nothing was renamed'
  assert_output --partial 'Parser said:'
  refute_output --partial 'Your settings were converted'
}

# why: a refusal that leaves the half-written TOML behind is the same trap
#      one name over: the idempotency gate is `! -f target`, so a stray
#      temp promoted by a later hand would be read as the configuration,
#      and `git status` in a consumer repo would show a file no .gitignore
#      covers.
@test "_migrate_ini_to_toml leaves no temp file behind when it refuses (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
mode = on
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  run bash -c "ls -A '${TEMP_DIR}'"
  assert_output ".setup.conf"
}

# why: the two halves are independently gated, so a repo whose committed
#      conf converts and whose local override does not must keep the
#      conversion it earned and keep the override it still has. Refusing
#      both would throw away a good migration; retiring both would be the
#      original bug. The answer is still the refusal: the caller has to
#      stop either way, because the half that did not convert is the one
#      setup would otherwise seed over.
@test "_migrate_ini_to_toml refuses one half without discarding the other (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
mode = on
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert [ -f "${TEMP_DIR}/setup.toml" ]
  assert [ -f "${TEMP_DIR}/.setup.conf.bak" ]
  assert [ -f "${TEMP_DIR}/.setup.conf.local" ]
  assert [ ! -f "${TEMP_DIR}/setup.local.toml" ]
  assert [ ! -f "${TEMP_DIR}/.setup.conf.local.bak" ]
}

# why: the flat-env converter renames its source too, and it renders every
#      value by wrapping it in double quotes with nothing escaped, so an
#      env value that carries a quote -- a JVM flag, a label argument --
#      is already unparseable TOML. Whichever way that rendering is fixed,
#      the operator's .env.local must not be the thing that pays for it.
@test "_migrate_env_local_to_toml keeps .env.local when the conversion does not parse (base#1148)" {
  printf 'JAVA_OPTS=-Dfoo="bar"\n' > "${TEMP_DIR}/.env.local"
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ ! -f "${TEMP_DIR}/.env.local.toml" ]
  assert [ ! -f "${TEMP_DIR}/.env.local.bak" ]
  run cat "${TEMP_DIR}/.env.local"
  assert_output 'JAVA_OPTS=-Dfoo="bar"'
}

# why: a refusal only protects the configuration if the caller hears it.
#      init.sh's resync continues into `_call_setup`, which seeds a
#      setup.toml from the template defaults -- and that seeded file
#      satisfies the `! -f target` gate, so a migration that merely
#      declined quietly would never be attempted again and the surviving
#      INI would stop taking effect. The refusal has to reach the caller
#      as a non-zero answer.
@test "_migrate_ini_to_toml answers non-zero when it refuses (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
mode = on
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
}

# why: the answer has to distinguish a refusal from the two ordinary
#      outcomes, or a caller that stops on non-zero stops on every repo
#      that has nothing to migrate and on every repo that migrated fine.
@test "_migrate_ini_to_toml answers zero when it converts and when it is inert (base#1148)" {
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.toml" ]
}

# why: the flat-env converter has the same caller contract to honour, and
#      base#1163 restores its call site once the .env.toml readers land.
@test "_migrate_env_local_to_toml answers non-zero when it refuses (base#1148)" {
  printf 'JAVA_OPTS=-Dfoo="bar"\n' > "${TEMP_DIR}/.env.local"
  run bash -c "$(_src); _migrate_env_local_to_toml '${TEMP_DIR}'"
  assert_failure
  assert [ -f "${TEMP_DIR}/.env.local" ]
}

# why: The two halves the upgrade commit needs, recorded where the write
#      happens. `_stage_resync_output` stages every path `_INIT_WROTE`
#      names since base#1097, and nothing else can name this migration's
#      output -- the published lists are written before the migration
#      exists. Un-recorded, a migrated consumer's fresh clone comes up on
#      the template defaults: `setup.toml` untracked and the tracked
#      `.setup.conf` deleted but not staged. The DELETION is asserted as
#      well as the write, because a commit carrying one and not the other
#      leaves the repo with two configurations.
@test "_migrate_ini_to_toml records both sides of the conversion (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  run bash -c "declare -gA _INIT_WROTE=()
_init_record_write() { _INIT_WROTE[\"\$1\"]=1; }
$(_src)
_migrate_ini_to_toml '${TEMP_DIR}'
printf 'RECORDED %s\n' \"\${!_INIT_WROTE[@]}\" | LC_ALL=C sort"
  assert_success
  assert_line "RECORDED .setup.conf"
  assert_line "RECORDED setup.toml"
  # The backup is NOT recorded: it is a canonical gitignore entry, so
  # recording it would only be dropped again at the check-ignore fence.
  refute_line "RECORDED .setup.conf.bak"
}

# why: The record is a hand-off to init.sh and the lib is also sourced on
#      its own -- by this spec, and by anything converting outside a
#      resync. A bare call to a function that is not there would print a
#      "command not found" into the middle of a migration's own output.
@test "_migrate_ini_to_toml converts with no record to write to (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.toml" ]
  refute_output --partial "command not found"
  refute_output --partial "_init_record_write"
}
