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

# why: A numbered INI family is an ordered list, and every reader of one
# sorts it by the numeric suffix (`_conf_list_sorted`) -- so `rule_2`
# written above `rule_1` is still tried second. An array of tables
# carries its order in the file instead, and the bridge numbers the
# blocks as it meets them, so converting in FILE order makes `rule_2`
# block 1: the rule that used to be tried second is now tried first, and
# for [[image.rules]] that is the image name the repo builds under. A
# zero-padded suffix is read with `10#`, or bash reads `08` as an invalid
# octal literal and the ordering dies instead of happening.
@test "_migrate_ini_to_toml emits a numbered family in suffix order, not file order (#1137)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_2 = @basename
rule_1 = prefix:docker_
rule_10 = suffix:_ws
rule_8 = @parent
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "grep -A1 -F '[[image.rules]]' '${TEMP_DIR}/setup.toml' | grep '^rule'"
  assert_success
  assert_output - << 'EOF'
rule = "prefix:docker_"
rule = "@basename"
rule = "@parent"
rule = "suffix:_ws"
EOF
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

# ── empty numbered-key slots keep their position ──────────────────────

# why: An empty `mount_1 =` is an opt-out slot, not a volume to emit --
# and the slot is still a slot. A numbered family is addressed by
# POSITION on both sides, so emitting only the populated slots renumbers
# the survivors: the extra bind became block 1, which every reader of
# `[volumes]` knows as `mount_1`, the workspace bind. The emptied slot is
# emitted as a FIELD-LESS `[[volumes]]` block, which the bridge's array
# spec reads back as an empty `mount_1`. Asserted through the bridge, not
# over the file text: a block carrying `source = ""` would look right in
# the file and read back wrong.
@test "_migrate_ini_to_toml keeps an emptied slot's position (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /data:/data
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'volumes	mount_1	'
  assert_line 'volumes	mount_2	/data:/data'
}

# why: The position is kept in the FILE; the runtime still treats the
# emptied slot as an opt-out. `_conf_list_sorted` is the reader every
# ordered list goes through, and it skips an empty value -- so a kept slot
# must not become an entry. This is the half of the retired
# `skips empty numbered-key slots` assertion that was always true, moved
# to the reader that actually decides it.
@test "_migrate_ini_to_toml: an emptied slot is no entry to the list reader (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
port_1 =
port_2 = 8080:80
EOF
  cat > "${TEMP_DIR}/probe.sh" <<PROBE
$(_src)
_migrate_ini_to_toml '${TEMP_DIR}' || exit 1
_conf_load_layers _PROBE '${TEMP_DIR}/setup.toml' || exit 1
declare -a _ports=()
_conf_list_sorted _PROBE network "port_" _ports
printf 'count=%s\n' "\${#_ports[@]}"
printf 'port=%s\n' "\${_ports[@]}"
PROBE
  run bash "${TEMP_DIR}/probe.sh"
  assert_success
  assert_line 'count=1'
  assert_line 'port=8080:80'
}

# why: The field-less block is not cosmetic. Letting the writer render an
# emptied slot's body instead produces `host = ""` / `container = ""`,
# which the bridge's array spec glues back into the NON-EMPTY string
# `":"` -- and `_conf_list_sorted` does not skip that, so a bogus port
# `":"` reaches compose. `build.args` is the same trap spelled `"="`.
# Both are invisible to a grep over the converted file.
@test "_migrate_ini_to_toml: an emptied slot reads back empty, not as a bare separator (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
port_1 =
port_2 = 8080:80
[build]
arg_1 =
arg_2 = TZ=Asia/Taipei
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'network	port_1	'
  assert_line 'network	port_2	8080:80'
  assert_line 'build	arg_1	'
  assert_line 'build	arg_2	TZ=Asia/Taipei'
  refute_line 'network	port_1	:'
  refute_line 'build	arg_1	='
}

# why: A slot BELOW the highest populated one need not exist in the INI at
# all -- `mount_2` alone still makes the extra bind the second entry,
# because that is the key the operator named it by. A present-keys-only
# rule leaves this hole open, so the family is emitted dense from 1 up to
# its highest populated index.
@test "_migrate_ini_to_toml: a slot the INI never names is still a slot (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
mount_2 = /data:/data
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'volumes	mount_1	'
  assert_line 'volumes	mount_2	/data:/data'
}

# why: An INI `[build]` whose only arg slot is empty resolved to ZERO
# build args: the pre-ADR-37 chain merged `[build]` by section-replace
# (ADR-00000025 sec. 3), so the repo's cleared slot replaced the
# template's three args. Dropping the family entirely makes the TOML key
# ABSENT -- the one state that is not a replacement -- and the key-level
# merge hands all three back. An emptied family converts to the writer's
# own `args = []` declaration, which replaces with nothing. Asserted
# through the MERGE, because the file alone cannot show inheritance.
@test "_migrate_ini_to_toml: a family with no populated slot converts to an emptied list (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
arg_1 =
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_merge --kv /source/dist/setup.toml '${TEMP_DIR}/setup.toml'"
  assert_success
  refute_line --regexp '^build	arg_'
}

# why: The published contract is that clearing `mount_1` opts the
# workspace bind out and that `setup.sh` does not re-populate it (README
# "Subsequent runs read mount_1 as source of truth"). Renumbering the
# family on conversion silenced that: `_reconcile_workspace_path` read the
# operator's EXTRA bind as `mount_1`, and because its source exists it is
# honoured as a pinned absolute path -- WS_PATH resolves to the data
# directory with no warning, and the container's workspace binds there.
# This is the end-to-end face of the position rule.
@test "_migrate_ini_to_toml: the workspace opt-out survives the conversion (base#1148)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}" "${TEMP_DIR}/data"
  cat > "${_base}/.setup.conf" <<EOF
[volumes]
mount_1 =
mount_2 = ${TEMP_DIR}/data:/data
EOF
  cat > "${TEMP_DIR}/probe.sh" <<PROBE
$(_src)
_migrate_ini_to_toml '${_base}' || exit 1
declare -a _vk=() _vv=()
_load_setup_conf '${_base}' volumes _vk _vv
_ws=""
_reconcile_workspace_path '${_base}' '${_base}/setup.toml' _vk _vv _ws
printf 'ws=%s\n' "\${_ws}"
PROBE
  run bash "${TEMP_DIR}/probe.sh"
  assert_success
  # The cleared branch: best-effort detection only, which with no `*_ws`
  # ancestor on the fixture path is the repo root itself -- NOT the data
  # directory the extra bind names.
  assert_line "ws=$(cd "${_base}" && pwd -P)"
  refute_output --partial "${TEMP_DIR}/data"
  # And the conf is untouched: the opt-out is still an opt-out on the next
  # run.
  run bash -c "$(_src); toml_bridge_parse '${_base}/setup.toml' --kv"
  assert_success
  assert_line 'volumes	mount_1	'
  assert_line "volumes	mount_2	${TEMP_DIR}/data:/data"
}

# ── repeated and unrepresentable numbered slots ───────────────────────

# why: Two keys of one family can reach the same index -- `port_1` twice,
# or `rule_01` beside `rule_1`, which both readers normalise to the same
# sort key -- and that input has no faithful conversion. The LIST readers
# count it as two entries; a lookup of the key reads ONE value. Two
# blocks moves whichever value is not first into position 2, and for
# `[volumes]` position 1 is the workspace bind; one block drops an entry
# the list had. A converter that renames the source away may do neither,
# so it declines and both lines stay on disk.
@test "_migrate_ini_to_toml declines two keys that are the same list entry (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
port_1 = 8080:80
port_1 = 9090:90
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert_output --partial '[network] port_1'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial '8080:80'
  assert_output --partial '9090:90'
}

# why: `rule_01` and `rule_1` are different KEYS that both readers
# normalise to one sort key, so they are the same list entry by two
# names. Keying only on the numeric value would have let one overwrite
# the other silently.
@test "_migrate_ini_to_toml declines a zero-padded twin of an existing entry (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_01 = suffix:_dev
rule_1 = prefix:app_
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
}

# why: The case that reaches the workspace with no duplicate at all. An
# entry of the array IS the key `<name>_N`, so a padded suffix changes
# what a LOOKUP of that key answers even though the LIST is unchanged:
# `[volumes]` whose only entry is `mount_01 = /data:/data` has an EMPTY
# `mount_1` before conversion -- the published opt-out -- and
# `/data:/data` at `mount_1` after it. That source exists, so
# `_reconcile_workspace_path` honours it as a deliberately pinned
# workspace and warns about nothing. Comparing the two LISTS cannot see
# this, which is why the suffix spelling is checked rather than inferred.
@test "_migrate_ini_to_toml declines a padded suffix that would take over a slot (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
mount_01 = /data:/data
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert_output --partial '[volumes] mount_01'
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial '/data:/data'
}

# why: `10#` fixes the BASE, not the range. A suffix past 2^63 wraps
# silently -- `rule_18446744073709551617` arrives as index 1 -- and is
# then emitted ahead of `rule_2`, where both readers sort it last. For
# `[[image.rules]]` that is the image name the repo builds under. The
# suffix is checked against its own arithmetic value and a mismatch is
# refused rather than ordered wrongly.
@test "_migrate_ini_to_toml declines a suffix the arithmetic cannot hold (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_18446744073709551617 = suffix:_dev
rule_2 = prefix:app_
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
}

# why: An EMPTY occurrence is none of those things. It carries no value,
# so it names no position and both sides agree it contributes nothing:
# a `_0` that no 1-based array has a slot for, `port_1 =` twice, and a
# suffix no arithmetic can hold -- with nothing after the `=`, each is an
# opt-out like any other. They still OWN the family, which is what
# decides whether the cleared list owes a declaration.
@test "_migrate_ini_to_toml: an empty occurrence is never unrenderable (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
mode = host
port_0 =
port_1 =
port_1 =
port_18446744073709551617 =
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run grep -Fx 'ports = []' "${TEMP_DIR}/setup.toml"
  assert_success
  run bash -c "$(_src); toml_bridge_merge --kv /source/dist/setup.toml '${TEMP_DIR}/setup.toml'"
  assert_success
  assert_line 'network	mode	host'
  refute_line --regexp '^network	port_'
}

# why: Under the INI chain a section was replaced WHOLE by the highest
# layer that put an entry in it, so a `.setup.conf.local` naming
# `[security]` at all left the layer below with NO cap_add entries. The
# TOML merge is key-level, so a converted local file that simply omits
# the array lets that list come back -- the operator's narrowing of the
# container's capabilities undone by the upgrade that converted it. Every
# family a section OWNS and populates nowhere now gets the writer's
# `path = []`. Asserted through the real three-layer merge.
@test "_migrate_ini_to_toml: a section that owned a list and emptied it keeps it empty (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
privileged = true
cap_add_1 = SYS_ADMIN
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[security]
privileged = false
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_merge --kv /source/dist/setup.toml '${TEMP_DIR}/setup.toml' '${TEMP_DIR}/setup.local.toml'"
  assert_success
  assert_line 'security	privileged	false'
  refute_line --regexp '^security	cap_add_'
}

# why: The gate on that is OWNERSHIP, not the bare header. A section
# header with no entries names no owner in the INI chain either -- the
# shipped template's own empty `[additional_contexts]` is exactly that --
# so it must not clear the layer below.
@test "_migrate_ini_to_toml: a section header with no entries clears nothing (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
arg_1 = KEEP=me
[additional_contexts]
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run grep -c 'additional_contexts = \[\]' "${TEMP_DIR}/setup.toml"
  assert_output "0"
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'build	arg_1	KEEP=me'
}

# why: A POPULATED `_0` is the other half. The INI list readers accept it
# and sort it FIRST, so it reaches the effective config, and a 1-based
# array has no slot for it: emitting it at the front would displace every
# position below it -- `mount_1`, the workspace bind, included -- and
# dropping it would lose a published port outright. A converter that
# renames the source away may do neither, so it declines and says which
# key to renumber.
@test "_migrate_ini_to_toml refuses a populated zero-indexed slot (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
port_0 = 8080:80
port_1 = 9090:90
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert_output --partial 'port_0'
  assert_output --partial 'Renumber'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/.setup.conf.bak" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run bash -c "ls -A '${TEMP_DIR}'"
  assert_output ".setup.conf"
}

# why: A scalar key under one of the three ROOT-level list sections has no
# TOML rendering at all: `volumes` cannot be an empty array and a table in
# one document, and the populated case collides the same way -- the
# `[[volumes]]` blocks against the `[volumes]` table. No schema key of
# this tree is such a scalar, so this pins the end such an input comes to:
# the commit gate refuses the file and the INI survives, which is what the
# containment is for. Pinned rather than worked around, because the
# alternative is dropping either the operator's scalar or the clearing.
@test "_migrate_ini_to_toml refuses a root list section carrying a scalar (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[volumes]
label = keep
mount_1 =
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
}

# ── repeated scalar keys ───────────────────────────────────────────────

# why: An INI may repeat a key, and every chain accessor resolves
# `[gui] mode = off` followed by `mode = auto` to the LAST occurrence
# (`_conf_get` / `_conf_get_into` keep assigning). TOML does not: a key
# written twice is `Cannot overwrite a value`, and the whole file stops
# parsing. The converter emitted every occurrence, so the commit gate
# declined the conversion -- which keeps the INI, loses nothing, and
# declines again on every re-run, leaving such a repo unable to complete
# an upgrade until someone hand-resolved the duplicate.
@test "_migrate_ini_to_toml: a repeated scalar key resolves to its last occurrence (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
mode = auto
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'gui	mode	auto'
  refute_line 'gui	mode	off'
}

# why: The collapse keeps the key where the INI first named it, so a
# repeated key does not reorder the table around it -- and the duplicate
# is gone from the file, not merely shadowed by a later line the way the
# INI allowed.
@test "_migrate_ini_to_toml: a repeated scalar key is written once (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[logging]
driver = json-file
max_file = 3
driver = local
compress = true
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run grep -c '^driver = ' "${TEMP_DIR}/setup.toml"
  assert_output "1"
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'logging	driver	local'
  assert_line 'logging	max_file	3'
  assert_line 'logging	compress	true'
}

# why: The property behind every ordering case here: whatever the INI
# reader returned for a family, the converted file's reader must return
# the same list. Asserted by running `_conf_list_sorted` over the INI and
# over the conversion of it and comparing, rather than by hand-picking an
# order -- which is how the zero-padded tie got pinned backwards. The
# fixture carries two holes and a suffix well above them, the shape that
# makes the two sides disagree.
@test "_migrate_ini_to_toml: the converted list is the list the INI reader returned (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_8 = suffix:_dev
rule_1 = prefix:app_
rule_4 = @basename
EOF
  cat > "${TEMP_DIR}/probe.sh" <<PROBE
$(_src)
_conf_load_layers _INI '${TEMP_DIR}/.setup.conf' || exit 1
declare -a _before=()
_conf_list_sorted _INI image "rule_" _before
_migrate_ini_to_toml '${TEMP_DIR}' || exit 1
_conf_load_layers _TOML '${TEMP_DIR}/setup.toml' || exit 1
declare -a _after=()
_conf_list_sorted _TOML image "rule_" _after
printf 'before=%s\n' "\${_before[*]}"
printf 'after=%s\n' "\${_after[*]}"
PROBE
  run bash "${TEMP_DIR}/probe.sh"
  assert_success
  local _b _a
  _b="$(printf '%s\n' "${lines[@]}" | sed -n 's/^before=//p')"
  _a="$(printf '%s\n' "${lines[@]}" | sed -n 's/^after=//p')"
  assert_equal "${_a}" "${_b}"
  # Non-vacuous: three entries survive, in suffix order, across a hole
  # and a zero-padded suffix.
  assert_equal "${_b}" "prefix:app_ @basename suffix:_dev"
}

# why: `env_N` and `cap_drop_N` have no array-of-tables home, so they are
# carried over as quoted scalars -- and they are read by
# `_conf_list_sorted`, which is NOT last-wins. Collapsing a repeated one
# the way an ordinary scalar is collapsed dropped a variable, or a
# dropped capability, from a file the parser accepts and from an INI
# already renamed to .bak. Left uncollapsed, the duplicate reaches the
# commit gate as the unrenderable TOML it is: the conversion is declined
# and both lines are still on disk. A decline is recoverable.
@test "_migrate_ini_to_toml declines a repeated environment env_N rather than dropping one (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[environment]
env_1 = SIGNALING_SERVER=localhost
env_1 = LOG_LEVEL=debug
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial 'SIGNALING_SERVER=localhost'
  assert_output --partial 'LOG_LEVEL=debug'
}

# why: The same shape one section over. `cap_drop_N` is the other
# numbered key with no array home, and a dropped capability silently
# restored is a container that keeps a privilege the operator removed.
@test "_migrate_ini_to_toml declines a repeated security cap_drop_N rather than dropping one (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
cap_drop_1 = SYS_ADMIN
cap_drop_1 = NET_RAW
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
}

# why: The collapse still applies to a key a SCALAR accessor reads, which
# is the whole point of it, and a numbered neighbour in the same section
# must not stop it. `[logging] driver` is collapsed; `env_1` next door
# would not be.
@test "_migrate_ini_to_toml: a numbered key beside a repeated scalar does not block the collapse (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[logging]
driver = json-file
max_file = 3
driver = local
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'logging	driver	local'
  assert_line 'logging	max_file	3'
}

# why: The ORDER of the two occurrences decides it. An emptied occurrence
# AFTER a populated one at the same index is the disagreement from the
# other side -- the list readers keep the value they collected, a key
# lookup reads the clear -- so it declines. BEFORE one it is not a
# disagreement at all: both sides answer the populated value, and one
# block is the faithful rendering. The first version of this check
# refused both ways.
@test "_migrate_ini_to_toml declines a clear that lands on a filled entry (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
port_1 = 8080:80
port_1 =
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert_output --partial 'clears entry 1'
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial '8080:80'
}

# why: The other order converts, and so does an emptied occurrence whose
# suffix is not its own spelling -- it names no entry for anything to
# collide with, so it must not reach the index check at all.
@test "_migrate_ini_to_toml: a clear before the value it precedes is no collision (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[tmpfs]
tmpfs_18446744073709551617 =
tmpfs_1 =
tmpfs_1 = /tmp
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run grep -c '^\[\[tmpfs\]\]$' "${TEMP_DIR}/setup.toml"
  assert_output "1"
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'tmpfs	tmpfs_1	/tmp'
}

# why: The same two orders on the scalar side, where `env_N` lives. A
# clear BEFORE the value collapses to the value, which is what both the
# list reader and a key lookup answer. A clear AFTER one would retract it
# for the lookup and not for the list reader, so it is left as the
# duplicate TOML key it is and the gate declines.
@test "_migrate_ini_to_toml: a cleared env_N slot refilled on the next line collapses (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[environment]
env_1 =
env_1 = SIGNALING_SERVER=localhost
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  run bash -c "$(_src); toml_bridge_parse '${TEMP_DIR}/setup.toml' --kv"
  assert_success
  assert_line 'environment	env_1	SIGNALING_SERVER=localhost'
}

# why: The other order on the scalar side. A clear AFTER a value retracts
# it for a key lookup and not for the list reader, which keeps every
# non-empty entry it collected -- so there is no one line the converted
# file can carry. It stays the duplicate TOML key it is and the gate
# declines, with both lines where the operator left them.
@test "_migrate_ini_to_toml declines an env_N cleared after it was filled (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[environment]
env_1 = SIGNALING_SERVER=localhost
env_1 =
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial 'SIGNALING_SERVER=localhost'
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
# A key whose NAME carries a space is such an input. An INI parser trims
# around the `=` and nothing else, so `max size = 10m` is a key a working
# config can carry -- unread, because no reader asks for that name, and
# harmless -- while TOML has no bare key with a space in it, so the
# conversion of it does not parse. (A key REPEATED inside one section
# used to be the input here; it is now collapsed to its last occurrence,
# the answer every chain accessor gave, so it converts. See the
# repeated-scalar-key cases above.) These cases assert the containment,
# not that particular input: whatever cannot be converted, the source
# survives it.

# why: an INI key carrying a space in its name is harmless there and
#      unrenderable in TOML, so its conversion is a document the parser
#      refuses. The repo must come out of this with its configuration
#      still on disk and readable, because the refusal is recoverable and
#      the rename is not.
@test "_migrate_ini_to_toml keeps the INI when the conversion does not parse (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[project]
name = my-robot
[logging]
max size = 10m
EOF
  run bash -c "$(_src); _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_failure
  assert_output --partial 'MIGRATION DECLINED'
  assert_output --partial '.setup.conf'
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -f "${TEMP_DIR}/.setup.conf.bak" ]
  assert [ ! -f "${TEMP_DIR}/setup.toml" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial 'max size = 10m'
}

# why: the refusal has to name the input, or the operator reading a resync
#      log of fifty lines cannot tell which of three files it was about,
#      and the one actionable fact -- that their config is untouched --
#      is the one they need.
@test "_migrate_ini_to_toml names the refused input and what the parser objected to (base#1148)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[logging]
max size = 10m
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
[logging]
max size = 10m
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
[logging]
max size = 10m
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
[logging]
max size = 10m
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
