#!/usr/bin/env bats
#
# conf_toml_writer_spec.bats -- the two config writers in lib/conf.sh
# (`_upsert_conf_value`, `_write_setup_conf`) emit TOML when the file
# they write is a `.toml` file.
#
# why: Every `setup.sh set` / `add` / `remove` and the `mount_1` bootstrap
# in setup_detect.sh go through these two writers. Until they learned
# TOML, each write appended INI (`mode = bridge`, `[volumes]`) into
# setup.toml, and the next bridge parse refused the file setup.sh had
# just written. The proof here is the round trip: writer output is fed
# straight to the bridge (`toml_bridge_parse --kv`) and the value is read
# back, rather than grepping for a substring the bridge might still
# reject.
#
# The bridge is the native `toml-bridge` binary in the test-tools image;
# no docker interaction from inside the test.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  TEMP_DIR="$(mktemp -d)"
  TPL=/source/dist/setup.toml
  CONF="${TEMP_DIR}/setup.toml"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _upsert_conf_value
# ════════════════════════════════════════════════════════════════════

# why: The first write every downstream repo ever sees: setup_detect.sh
# copies the shipped template and upserts `[volumes] mount_1`. If that
# file does not parse, nothing after bootstrap does. The value carries
# `${WS_PATH}` literally, so this also pins that the writer quotes rather
# than expands.
@test "_upsert_conf_value: the mount_1 bootstrap write on the shipped template parses through the bridge and reads back" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  # shellcheck disable=SC2016  # literal ${WS_PATH} / ${USER_NAME} intentional
  _upsert_conf_value "${CONF}" volumes mount_1 '${WS_PATH}:/home/${USER_NAME}/work'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  # shellcheck disable=SC2016
  assert_line 'volumes	mount_1	${WS_PATH}:/home/${USER_NAME}/work'
}

# why: `setup.sh set network.mode bridge` is the write the issue was
# filed on: the value has to come out quoted, and it has to land in the
# template's existing `[network]` table rather than open a second one --
# a table declared twice is the other way the bridge refuses the file.
# Booleans and integers stay bare, the way the template spells them.
@test "_upsert_conf_value: a scalar set lands quoted in its existing table, booleans and integers stay bare" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" network mode bridge
  _upsert_conf_value "${CONF}" lifecycle init false
  _upsert_conf_value "${CONF}" logging max_file 7

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'lifecycle	init	false'
  assert_line 'logging	max_file	7'

  run grep -c '^\[network\]$' "${CONF}"
  assert_output "1"
  run grep -Fx 'mode = "bridge"' "${CONF}"
  assert_success
  run grep -Fx 'init = false' "${CONF}"
  assert_success
  run grep -Fx 'max_file = 7' "${CONF}"
  assert_success
}

# why: Index N of the array IS the key `<prefix>_N`, so a write naming an
# index past the end has to LAND there. Appending one block gave it the
# next position under a different name, and on the shipped template --
# whose `[volumes]` holds no block at all -- `setup.sh set volumes.mount_2
# /data:/data` read back as `mount_1`, the workspace bind.
# `_reconcile_workspace_path` honours an existing absolute source at
# `mount_1` as a deliberately pinned workspace, so WS_PATH silently became
# the operator's data directory. The INI writer had no such failure: it
# wrote the key `mount_2` and left `mount_1` absent. The positions in
# between are padded field-less, the same rule and the same spelling the
# converter's dense emission already uses. Driven on the shipped template,
# because that no-blocks state is the seeded state of every downstream
# repo rather than an edge case.
@test "_upsert_conf_value: a write past the end of an array lands at the index it named" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_3 '/data:/data'

  # Two field-less blocks stand in front of it, so the value is entry 3.
  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "3"

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_3	/data:/data'
  # The workspace slot is NOT what the write landed in, and it reads back
  # empty rather than as the bogus `:` no list reader skips.
  refute_line --regexp '^volumes	mount_1	.'
  refute_line --regexp '^volumes	mount_2	.'

  # And the next write still addresses the padded slots by name.
  _upsert_conf_value "${CONF}" volumes mount_2 '/srv:/srv:ro'
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_2	/srv:/srv:ro'
  assert_line 'volumes	mount_3	/data:/data'
  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "3"
}

# why: The conversion table of the migration: a numbered list key is an
# `[[array of tables]]` entry, not a `mount_N` scalar. The N-th block IS
# entry N, so writing an index that exists replaces that block in place
# and writing the next index appends a block after it; the bridge
# numbers them back in file order. `build arg_4` on a template whose
# `[[build.args]]` holds three is the next position, so it needs no
# padding -- which is what separates it from the test above.
@test "_upsert_conf_value: numbered keys land as array-of-tables entries that the bridge numbers back" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '/a:/b'
  _upsert_conf_value "${CONF}" volumes mount_2 '/c:/d:ro'
  _upsert_conf_value "${CONF}" volumes mount_1 '/x:/y'
  _upsert_conf_value "${CONF}" build arg_4 'FOO=bar'
  _upsert_conf_value "${CONF}" network port_1 '8080:80'
  _upsert_conf_value "${CONF}" image rule_2 'suffix:_dev'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_1	/x:/y'
  assert_line 'volumes	mount_2	/c:/d:ro'
  assert_line 'build	arg_3	TZ=Asia/Taipei'
  assert_line 'build	arg_4	FOO=bar'
  assert_line 'network	port_1	8080:80'
  assert_line 'image	rule_1	prefix:docker_'
  assert_line 'image	rule_2	suffix:_dev'
  assert_line 'image	rule_3	@basename'

  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "2"
  run grep -c '^\[\[build.args\]\]$' "${CONF}"
  assert_output "4"
  run grep -c '^\[\[image.rules\]\]$' "${CONF}"
  assert_output "3"
  run grep -c '^mount_' "${CONF}"
  assert_output "0"
}

# why: Every field of an array-of-tables entry is string-typed -- the
# bridge joins a volume's source/target/mode with `:` and formats a build
# arg into `key=value` -- so the renderer may not infer a type from the
# text. A numeric named volume (`123:/data`) rendered a bare
# `source = 123`, which handed `str.join` an int: `--kv` raised TypeError
# and the whole configuration stopped loading, not just that one mount.
# A build arg spelled `FEATURE=true` rendered a bare `value = true`, which
# is a TOML boolean and reaches the shell as `true` whatever the
# Dockerfile asked for. The rule is the family's, not one field's.
@test "_upsert_conf_value: array-of-tables fields stay quoted when the text spells an integer or a boolean" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '123:/data'
  _upsert_conf_value "${CONF}" build arg_4 'FEATURE=true'
  _upsert_conf_value "${CONF}" network port_1 '8080:80'
  _upsert_conf_value "${CONF}" image rule_1 '2024'

  run grep -Fx 'source = "123"' "${CONF}"
  assert_success
  run grep -Fx 'value = "true"' "${CONF}"
  assert_success
  run grep -Fx 'host = "8080"' "${CONF}"
  assert_success
  run grep -Fx 'rule = "2024"' "${CONF}"
  assert_success

  # The round trip the quoting exists for: the read gets through at all,
  # and every value arrives as the text that went in.
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_1	123:/data'
  assert_line 'build	arg_4	FEATURE=true'
  assert_line 'network	port_1	8080:80'
  assert_line 'image	rule_1	2024'
}

# why: The same rule one level further IN, on a free-typed TABLE key.
# `_conf_toml_scalar` may infer a type there, so the question is which
# text it may infer one FOR -- and the test is canonical, not valid. TOML
# accepts `-0`, `+1`, `0x10` and `1_000` as integers and reads them as 0,
# 1, 16 and 1000, so a bare render loses the operator's spelling:
# `[environment] env_1 = -0` read back `0`, the sign gone from a value
# someone typed (base#1234). All four are quoted now, and the round trip
# is what says so -- a grep on the file text would pass on a value the
# bridge still reduces.
@test "_upsert_conf_value: a table key that merely looks numeric is quoted and reads back as written" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" environment env_1 '-0'
  _upsert_conf_value "${CONF}" environment env_2 '+1'
  _upsert_conf_value "${CONF}" environment env_3 '0x10'
  _upsert_conf_value "${CONF}" environment env_4 '1_000'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'environment	env_1	-0'
  assert_line 'environment	env_2	+1'
  assert_line 'environment	env_3	0x10'
  assert_line 'environment	env_4	1_000'
}

# why: The control for the rule above, and the half a blanket "quote
# everything" would break. `init = true` / `max_file = 3` is how the
# shipped template spells its own keys, and a table key IS free-typed, so
# the genuine canonical forms have to keep coming back as a boolean and
# an integer rather than as the strings `"true"` and `"3"`. A negative
# integer and a plain `0` are canonical too -- only `-0` is not, because
# only `-0` fails to spell itself back. Driven through the template's own
# keys, so the fixture cannot drift from what ships.
@test "_upsert_conf_value: the template's own booleans and canonical integers stay bare" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" lifecycle init false
  _upsert_conf_value "${CONF}" security privileged true
  _upsert_conf_value "${CONF}" logging max_file 3
  _upsert_conf_value "${CONF}" logging container_log_keep 0
  _upsert_conf_value "${CONF}" logging container_log_days -14

  run grep -Fx 'init = false' "${CONF}"
  assert_success
  run grep -Fx 'privileged = true' "${CONF}"
  assert_success
  run grep -Fx 'max_file = 3' "${CONF}"
  assert_success
  run grep -Fx 'container_log_keep = 0' "${CONF}"
  assert_success
  run grep -Fx 'container_log_days = -14' "${CONF}"
  assert_success

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'lifecycle	init	false'
  assert_line 'security	privileged	true'
  assert_line 'logging	max_file	3'
  assert_line 'logging	container_log_keep	0'
  assert_line 'logging	container_log_days	-14'
}

# why: A per-stage override and a per-service logging override name
# sections and keys TOML cannot spell bare (`stage:headless`,
# `gui.mode`). Quoting them is what keeps the section flat on the way
# back, so `_conf_split_nskey`'s rule still applies to what the bridge
# emits.
@test "_upsert_conf_value: a section or key that is not a bare TOML name is quoted and reads back flat" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" stage:headless gui.mode off

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'stage:headless	gui.mode	off'
  run grep -Fx '["stage:headless"]' "${CONF}"
  assert_success
  run grep -Fx '"gui.mode" = "off"' "${CONF}"
  assert_success
}

# why: A value carrying a double quote or a backslash is the one that
# turns a naive `"%s"` into a file the bridge refuses (`\c` is not a
# TOML escape). Escaped, it round-trips to the byte the user typed.
@test "_upsert_conf_value: quotes and backslashes in a value are escaped and read back verbatim" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" environment env_1 'Q=a"b\c'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'environment	env_1	Q=a"b\c'
}

# why: The layout-preservation property: comments, blank lines and
# untouched lines are copied through, so a hand-edited setup.toml
# survives a `set` with its annotations intact.
@test "_upsert_conf_value: comments and untouched lines survive a TOML write" {
  cp "${TPL}" "${CONF}"
  local _comments_before
  _comments_before="$(grep -c '^#' "${TPL}")"
  _upsert_conf_value "${CONF}" network mode bridge
  _upsert_conf_value "${CONF}" volumes mount_1 '/a:/b'

  run grep -c '^#' "${CONF}"
  assert_output "${_comments_before}"
  run grep -Fx '# mode defaults to host for cross-machine ROS compatibility.' "${CONF}"
  assert_success
  run grep -Fx 'ipc = "host"' "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _write_setup_conf
# ════════════════════════════════════════════════════════════════════

# why: The template-rewrite writer behind `setup.sh remove` and TUI Save.
# One save exercises every shape at once: a scalar override lands in its
# table, an existing array entry is replaced in place, a new one is
# appended after the last of its kind, a removed entry drops its block
# (the array compacts, so what was entry 3 reads back as entry 2), and
# a section the template never had is opened with a quoted header.
# The removed mount is the one ABOVE slot 1 on purpose: slot 1 of
# `[volumes]` is the workspace bind by position, so a save that would
# promote another mount into it is refused rather than compacted (the
# containment cases at the end of this file). Compaction is what every
# other entry of every family still does, which is the claim here.
@test "_write_setup_conf: a TOML rewrite with scalar, array, removed and new-section overrides parses and reads back" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '/a:/b'
  _upsert_conf_value "${CONF}" volumes mount_2 '/c:/d'

  local -a _keys=(network.mode image.rule_2 image.rule_4 volumes.mount_3 stage:headless.gui.mode deploy.gpu_count)
  local -a _vals=(bridge 'suffix:_dev' '@parent' /e:/f off 2)
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals 'volumes.mount_2 build.arg_2'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'image	rule_1	prefix:docker_'
  assert_line 'image	rule_2	suffix:_dev'
  assert_line 'image	rule_3	@basename'
  assert_line 'image	rule_4	@parent'
  assert_line 'volumes	mount_1	/a:/b'
  assert_line 'volumes	mount_2	/e:/f'
  refute_output --partial '/c:/d'
  assert_line 'build	arg_1	APT_MIRROR_UBUNTU=tw.archive.ubuntu.com'
  assert_line 'build	arg_2	TZ=Asia/Taipei'
  refute_output --partial 'APT_MIRROR_DEBIAN'
  assert_line 'stage:headless	gui.mode	off'
  assert_line 'deploy	gpu_count	2'

  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "2"
  run grep -c '^\[\[image.rules\]\]$' "${CONF}"
  assert_output "4"
  run grep -Fx '["stage:headless"]' "${CONF}"
  assert_success
}

# why: `setup remove build.arg_1` on a repo whose ONLY build argument that
# is -- the whole list, gone. Arrays are replaced atomically at every
# depth, so "the operator removed every entry" has to reach the merge as a
# replacement by nothing: an explicit `args = []`. Dropping the
# declaration instead makes the key ABSENT, which is the one state that is
# not a replacement -- the merge inherits the layer below and hands back
# every template entry the operator just removed, silently. A root-level
# array (`[[volumes]]`) needs its declaration in the file's root-key
# region, before the first table header, which is the only place a
# root-level key can go.
@test "_write_setup_conf: removing the last entry of an array leaves an explicit empty array" {
  cat > "${CONF}" << 'EOF'
[build]
target_arch = ""

[[build.args]]
key = "ONLY"
value = "1"

[[volumes]]
source = "/a"
target = "/b"
EOF
  local -a _keys=() _vals=()
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals 'build.arg_1 volumes.mount_1'

  run grep -Fx 'args = []' "${CONF}"
  assert_success
  run grep -Fx 'volumes = []' "${CONF}"
  assert_success
  run grep -c '^\[\[build.args\]\]$' "${CONF}"
  assert_output "0"
  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "0"

  # The file parses, and the emptied list is what the MERGE sees: the
  # template's own build args stay removed.
  run toml_bridge_merge --kv "${TPL}" "${CONF}"
  assert_success
  refute_line --regexp '^build\targ_'
  refute_line --regexp '^volumes\tmount_'
}

# why: `[network] # chosen mode` is a valid TOML table header and the
# bridge reads it as one. Both halves of the upsert writer required the
# `]` to be the last non-blank character of the line, so neither saw a
# header there: `setup.sh set network.mode bridge` never entered the
# table, appended a SECOND `[network]` at the end of the file, and left
# the original value standing. TOML rejects a table declared twice, so a
# user who annotated their own config got a file nothing can read -- and
# got it from a write that reported success.
@test "_upsert_conf_value: a table header with a trailing comment is entered, not declared a second time" {
  cat > "${CONF}" << 'EOF'
[network] # chosen mode
mode = "host"

[[volumes]] # the workspace
source = "/a"
target = "/b"
EOF
  _upsert_conf_value "${CONF}" network mode bridge
  _upsert_conf_value "${CONF}" volumes mount_1 '/c:/d'

  run grep -c '^\[network\]' "${CONF}"
  assert_output "1"
  run grep -c '^\[\[volumes\]\]' "${CONF}"
  assert_output "1"
  # The annotation the user wrote is still on the header.
  run grep -Fx '[network] # chosen mode' "${CONF}"
  assert_success

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'volumes	mount_1	/c:/d'
  refute_line 'network	mode	host'
}

# why: The rewrite writer matches the same headers, and misses them the
# same way: an override for `network.mode` never matches a line inside a
# `[network]` it does not know it is in, so it is appended as a brand-new
# `[network]` section -- the same duplicate table, reached through TUI
# Save and `setup remove` instead. The array half has to agree too, or
# the block its numbered key addresses is a different block.
@test "_write_setup_conf: a table header with a trailing comment is entered, not declared a second time" {
  cat > "${CONF}" << 'EOF'
[network] # chosen mode
mode = "host"

[[image.rules]] # tried first
rule = "prefix:docker_"

[[image.rules]]
rule = "suffix:_ws"
EOF
  local -a _keys=(network.mode image.rule_1)
  local -a _vals=(bridge '@basename')
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals

  run grep -c '^\[network\]' "${CONF}"
  assert_output "1"

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'image	rule_1	@basename'
  assert_line 'image	rule_2	suffix:_ws'
}

# why: The other half of the removal. `args = []` is an ordinary key, and
# TOML will not let a key already bound to an array be extended by
# `[[build.args]]` blocks -- so an `add` after the remove that left the
# declaration standing produced `Cannot mutate immutable namespace
# ('build', 'args')`: the add reported success and every read after it
# failed. The declaration is therefore a decision the writers RE-MAKE,
# not a line they copy: dropped on the way through, written back only
# while the list is still empty. Remove-then-add has to be a round trip.
@test "_upsert_conf_value: refilling an emptied array drops the empty-array declaration" {
  cat > "${CONF}" << 'EOF'
volumes = []

[build]
target_arch = ""
args = []
EOF
  _upsert_conf_value "${CONF}" build arg_1 'BAZ=qux'
  _upsert_conf_value "${CONF}" volumes mount_1 '/a:/b'

  run grep -F 'args = []' "${CONF}"
  assert_failure
  run grep -F 'volumes = []' "${CONF}"
  assert_failure

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'build	arg_1	BAZ=qux'
  assert_line 'volumes	mount_1	/a:/b'
}

# why: The rewrite writer re-makes the same decision, and has the other
# half of it to get right as well: an array the file already declares
# empty is an operator decision, so a save that does not refill it must
# leave the declaration there rather than dropping the clear.
@test "_write_setup_conf: an override refills an emptied array, an unrelated save leaves it empty" {
  cat > "${CONF}" << 'EOF'
volumes = []

[build]
target_arch = ""
args = []
EOF
  local -a _keys=(build.arg_1)
  local -a _vals=('ONE=1')
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals

  run grep -F 'args = []' "${CONF}"
  assert_failure
  # Untouched by this save, so still explicitly empty.
  run grep -Fx 'volumes = []' "${CONF}"
  assert_success

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'build	arg_1	ONE=1'
  refute_line --regexp '^volumes\tmount_'
}

# why: `['network']` is a valid TOML table declaration -- a literal-quoted
# key -- and the bridge reads it as the table `network`.
# `_conf_header_name` stripped basic quotes only, so the name came back as
# `'network'`, no writer recognised the section, and setting
# `network.mode` appended a second `[network]`. That is the same duplicate
# table a trailing comment produced, reached through the other
# half-recognised header spelling.
@test "_upsert_conf_value: a literal-quoted table header is entered, not declared a second time" {
  cat > "${CONF}" << 'EOF'
['network']
mode = "host"
EOF
  _upsert_conf_value "${CONF}" network mode bridge

  run grep -c '^\[' "${CONF}"
  assert_output "1"
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  refute_line 'network	mode	host'
}

# why: An operator who clears a list is exactly the operator who writes
# down why: `args = [] # intentionally cleared` is valid TOML and still
# an empty array. Matching the value as the bare two characters missed
# it, so the declaration was copied through and the added
# `[[build.args]]` landed beside a key already bound to an array -- the
# `Cannot mutate immutable namespace` file again, reached by annotating
# the very decision the declaration records.
@test "_upsert_conf_value: an annotated empty-array declaration is still an empty array" {
  cat > "${CONF}" << 'EOF'
[build]
target_arch = ""
args = [ ]  # intentionally cleared
EOF
  _upsert_conf_value "${CONF}" build arg_1 'BAZ=qux'

  run grep -F 'args = [' "${CONF}"
  assert_failure
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'build	arg_1	BAZ=qux'
}

# why: A key the template only mentions in a comment (`watchdog_interval`
# under `[lifecycle]`) has no line to replace, so it is appended at the
# end of its table, before the next header. The renderers match
# patterns of their own on the way, and the header the walk is about to
# open must still be the one it read, not what a renderer last matched.
@test "_write_setup_conf: a scalar with no template line is appended inside its table, and the next table still opens" {
  cp "${TPL}" "${CONF}"
  local -a _keys=(lifecycle.watchdog_interval lifecycle.watchdog_check gui.mode)
  local -a _vals=(30 'curl -sf http://localhost:8080/health' x11)
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'lifecycle	watchdog_interval	30'
  assert_line 'lifecycle	watchdog_check	curl -sf http://localhost:8080/health'
  assert_line 'lifecycle	init	true'
  assert_line 'gui	mode	x11'
  run grep -c '^\[gui\]$' "${CONF}"
  assert_output "1"
  run grep -c '^\[lifecycle\]$' "${CONF}"
  assert_output "1"
}

# why: The same property the upsert writer has, on the rewrite writer:
# a save must not strip the template's commentary.
@test "_write_setup_conf: comments survive a TOML rewrite" {
  cp "${TPL}" "${CONF}"
  local _comments_before
  _comments_before="$(grep -c '^#' "${TPL}")"
  local -a _keys=(network.mode) _vals=(bridge)
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals

  run grep -c '^#' "${CONF}"
  assert_output "${_comments_before}"
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
}

# ════════════════════════════════════════════════════════════════════
# The INI destination is untouched
# ════════════════════════════════════════════════════════════════════

# why: The frozen TUI (ADR-00000037) still writes `.setup.conf` through
# the same two writers. Format follows the destination's extension, so
# its file must keep coming out as INI: bare values, bare headers.
@test "writers: a non-TOML destination still gets INI" {
  local _ini="${TEMP_DIR}/.setup.conf"
  printf '[network]\nmode = host\n' > "${_ini}"
  _upsert_conf_value "${_ini}" network mode bridge
  _upsert_conf_value "${_ini}" volumes mount_1 '/a:/b'
  _upsert_conf_value "${_ini}" stage:headless gui.mode off
  run cat "${_ini}"
  assert_line 'mode = bridge'
  assert_line '[volumes]'
  assert_line 'mount_1 = /a:/b'
  assert_line '[stage:headless]'
  assert_line 'gui.mode = off'

  local -a _keys=(network.mode volumes.mount_2) _vals=(none /c:/d)
  _write_setup_conf "${_ini}" "${_ini}" _keys _vals
  run cat "${_ini}"
  assert_line 'mode = none'
  assert_line 'mount_2 = /c:/d'
  refute_output --partial '"'
}

# ════════════════════════════════════════════════════════════════════
# The setup.sh call sites
# ════════════════════════════════════════════════════════════════════

# why: The acceptance criterion as stated: what `setup.sh set` / `add` /
# `remove` leave behind has to parse through the bridge. `add` twice
# has to append twice (its slot is computed from the TOML view now, so
# the second add is entry 2 and not an overwrite of entry 1), and
# `remove` by value has to find the entry in that same view. The value
# removed is the one in slot 2: remove-by-value resolves to a SLOT, and
# a resolution that lands on slot 1 of `[volumes]` -- the workspace bind
# by position -- is refused rather than compacted, which the containment
# cases at the end of this file cover on their own.
@test "setup.sh set, add and remove leave a setup.toml the bridge parses" {
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  cp "${TPL}" "${_repo}/setup.toml"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set network.mode bridge --base-path '${_repo}' -q || exit 11
    main add volumes.mount /a:/b --base-path '${_repo}' -q || exit 12
    main add volumes.mount /c:/d --base-path '${_repo}' -q || exit 13
    main add build.arg FOO=bar --base-path '${_repo}' -q || exit 14
    main remove volumes.mount /c:/d --base-path '${_repo}' -q || exit 15
  "
  assert_success

  run toml_bridge_parse "${_repo}/setup.toml" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'volumes	mount_1	/a:/b'
  refute_output --partial '/c:/d'
  assert_line 'build	arg_4	FOO=bar'
}

# why: An array-of-tables entry is ONE string on the shell side. The
# writer splits it textually and the bridge's array spec glued the halves
# back unconditionally, so an entry that had only ONE side came back
# carrying a separator the operator never wrote. The two are different
# settings, not two spellings of one: `--build-arg HTTP_PROXY` inherits
# the value from the build environment while `--build-arg HTTP_PROXY=`
# sets it to the empty string, and `80` is a published port where `80:`
# is not a mapping compose accepts at all. Neither half of the seam can
# carry the rule alone -- a writer that renders the absent half leaves
# `value = ""` indistinguishable from a deliberate trailing `=`, and a
# reader that keeps manufacturing the separator undoes a writer that
# omitted it -- so the distinction is FIELD PRESENCE in the written TOML,
# absent meaning the operator wrote no second half. Asserted through the
# bridge rather than over the file text, which looks correct whichever
# way it reads back.
@test "_upsert_conf_value: a one-sided array entry round-trips without gaining a separator" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" build   arg_4   'HTTP_PROXY'
  _upsert_conf_value "${CONF}" build   arg_5   'HTTPS_PROXY='
  _upsert_conf_value "${CONF}" network port_1  '80'
  _upsert_conf_value "${CONF}" network port_2  '8080:80'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'build	arg_4	HTTP_PROXY'
  assert_line 'build	arg_5	HTTPS_PROXY='
  assert_line 'network	port_1	80'
  assert_line 'network	port_2	8080:80'
}

# why: `volumes` was believed to escape the one-sided glue because its
# serialiser joins only the TRUTHY parts, but truthiness is the wrong
# test for a THREE-field entry: the writer emits `target` whenever the
# first colon is there and `mode` whenever the second is, empty or not,
# so a read-only mount with no container half (`/srv/data::ro`) came back
# as `/srv/data:ro` -- the mode SHIFTED into the target position, which
# mounts the host directory at the path `ro`. Presence rather than
# truthiness is what keeps a field's position, and it is the same rule
# the two-field families need, so there is one spelling of it rather than
# two.
@test "_upsert_conf_value: an empty middle field keeps its position instead of shifting the mode into it" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '/srv/data::ro'
  _upsert_conf_value "${CONF}" volumes mount_2 '/srv/cache:'
  _upsert_conf_value "${CONF}" volumes mount_3 '/a:/b:rw'
  _upsert_conf_value "${CONF}" volumes mount_4 ''

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_1	/srv/data::ro'
  assert_line 'volumes	mount_2	/srv/cache:'
  assert_line 'volumes	mount_3	/a:/b:rw'
  # The other side of the rule: an entry whose fields are ALL empty is
  # the operator's opt-out -- the published way to clear the workspace
  # mount -- and must stay an empty value rather than become the bare
  # `:` that `_conf_list_sorted` does not skip.
  assert_line 'volumes	mount_4	'
}

# why: TOML has two quote forms for a key, and a hand-edited file uses
# either: `'mode' = 'host'` is a literal-quoted key and exactly as valid
# as `"mode"`. `_conf_line_key` stripped only the double quotes, so the
# key came back as `'mode'`, `setup.sh set network.mode bridge` did not
# recognise the line it was there to replace, and it appended a SECOND
# `mode` to the table -- which TOML refuses, so a file that parsed before
# the write stopped parsing after it while the write reported success.
# The table HEADER matcher already took both forms; this is that rule one
# level down. Asserted through the parse, because the symptom is a file
# the bridge rejects rather than a wrong value.
@test "_upsert_conf_value: a literal-quoted key is the key it names, not a second one" {
  cat > "${CONF}" << 'EOF'
[network]
'mode' = 'host'
EOF
  _upsert_conf_value "${CONF}" network mode bridge
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
}

# why: THE BACKSTOP, and the reason it is a parse rather than a fifth
# pattern. The writers are line-oriented, so a value spanning physical
# lines had its FIRST line replaced and the rest left standing:
# `watchdog_check = """` / `pgrep -f my_node` / `"""` became
# `watchdog_check = "pgrep -f other"` above the orphaned body, and the
# bridge answered `Expected '=' after a key in a key/value pair`. That is
# the fourth shape of one class this branch has fixed -- a commented
# header declared twice, an empty-array declaration beside new blocks, a
# literal-quoted key appended as a duplicate, this -- and patching the
# fifth as it is reported leaves the sixth. So the rewrite is now
# promoted only once the SHIPPED bridge has parsed it, the same gate
# `_ini_to_toml_commit` puts in front of the converter. A refused write
# leaves the operator's file byte-for-byte as it was, which is what this
# asserts: not that the edit succeeds, but that a failure costs nothing.
@test "_upsert_conf_value: a rewrite the bridge refuses is not promoted, and the file is untouched" {
  cat > "${CONF}" << 'EOF'
[lifecycle]
watchdog_check = """
pgrep -f my_node
"""
EOF
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run _upsert_conf_value "${CONF}" lifecycle watchdog_check 'pgrep -f other'
  assert_failure
  run diff -u "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
  # Still the TOML it was. Asked in JSON mode, not `--kv`: this value
  # decodes to a string CONTAINING a newline, which the tab-separated
  # shell view refuses on its own account (see toml_bridge_spec). The
  # claim here is about the file, not about the stream.
  run toml_bridge_parse "${CONF}"
  assert_success
}

# why: Index N of the array IS the key `<prefix>_N`, and the writer
# addresses a block by its POSITION, so a suffix that is not the plain
# decimal spelling of a position lands somewhere else under a different
# name. Measured on the shipped template, whose `[volumes]` holds no
# block: `set volumes.mount_0` and `set volumes.mount_01` each wrote one
# block that read back as `mount_1` -- the workspace bind, whose existing
# absolute source `_reconcile_workspace_path` honours as a pinned
# workspace. The converter already declines both shapes by name for the
# same reason; this is the writer getting the same check. Refused before
# the temp file exists, so the original is untouched, which is what the
# second parse of each case asserts.
@test "_upsert_conf_value: an index with no 1-based slot is refused, not rerouted" {
  cp "${TPL}" "${CONF}"
  run _upsert_conf_value "${CONF}" volumes mount_0 '/data:/data'
  assert_failure
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  refute_line --regexp '^volumes	mount_1	.'

  cp "${TPL}" "${CONF}"
  run _upsert_conf_value "${CONF}" volumes mount_01 '/pad:/pad'
  assert_failure
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  refute_line --regexp '^volumes	mount_1	.'
}

# why: The control for the removal case below, and the reason it needed a
# second gate at all. A SET into an inline table is already caught by the
# parse gate: the writer opens a `[resources]` table where `resources` is
# already a key bound to one, which TOML refuses, so the rewrite does not
# parse and is not promoted. The removal is the one that slips through,
# because it writes nothing new.
@test "_upsert_conf_value: a set into an inline table is refused by the parse gate" {
  printf 'resources = { shm_size = "64m" }\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run _upsert_conf_value "${CONF}" resources shm_size '128m'
  assert_failure
  run diff -u "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: A removal that did NOTHING leaves a file the parse gate is happy
# with -- readable, with the value still in it. The writers edit a key
# written on its own line, and `resources = { shm_size = "64m" }` is a
# valid inline table the bridge finds `resources.shm_size` inside: the
# rewrite copied the line through, parsed clean, and `setup.sh remove
# resources.shm_size` reported success and exit 0 with the limit still
# configured. So the gate now asks the reader what the file SAYS, which
# is the only check that also covers a shape nobody has thought of yet.
# A numbered-family key is excluded on purpose, and the helper's header
# says why: removing an array entry COMPACTS the ones after it, so
# `<prefix>_N` is expected to survive holding the next value, and whether
# that is right for slot 1 of `[volumes]` is base#1233's open question --
# not something this gate may settle by refusing.
@test "_write_setup_conf: a removal the rewrite did not make is refused, and the file is untouched" {
  printf 'resources = { shm_size = "64m" }\n' > "${CONF}"
  local -a _k=() _v=()
  run _write_setup_conf "${CONF}" "${CONF}" _k _v "resources.shm_size"
  assert_failure
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'resources\tshm_size\t64m'
}

# why: The question an array-entry removal can be asked WITHOUT answering
# base#1233. Compaction means `<prefix>_N` is expected to survive holding
# the next value, so an absence check would fail on a correct removal --
# but the family getting SHORTER is unambiguous either way, and says
# nothing about which value lands where. The first spelling of this gate
# excused array keys unconditionally, and an inline ARRAY is a spelling
# the line-oriented writer cannot reach any more than an inline table:
# `args = [{ key = "FOO", value = "bar" }]` exposes `build.arg_1` to the
# reader, the rewrite left it untouched, and the removal reported success
# with `FOO=bar` still active.
@test "_write_setup_conf: an array removal the rewrite did not make is refused" {
  printf '[build]\nargs = [{ key = "FOO", value = "bar" }]\n' > "${CONF}"
  local -a _k=() _v=()
  run _write_setup_conf "${CONF}" "${CONF}" _k _v "build.arg_1"
  assert_failure
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'build\targ_1\tFOO=bar'
}

# why: The control, and the half the length check must not break. A
# removal the writer CAN make compacts, so `arg_1` survives holding what
# was `arg_2` -- which is exactly why the check is on the length and not
# on the key's absence. A gate that refused this would have made
# `setup.sh remove` unusable on every numbered family.
@test "_write_setup_conf: a block-spelled array removal compacts and is accepted" {
  cat > "${CONF}" << 'EOF'
[build]

[[build.args]]
key = "FOO"
value = "bar"

[[build.args]]
key = "KEEP"
value = "yes"
EOF
  local -a _k=() _v=()
  _write_setup_conf "${CONF}" "${CONF}" _k _v "build.arg_1"
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'build\targ_1\tKEEP=yes'
  refute_line --regexp '^build	arg_2	'
}

# why: The one array position that identifies something rather than just
# ordering it. Removing an entry COMPACTS the ones after it, so `remove
# volumes.mount_1` promotes whatever was slot 2 -- and slot 1 of
# `[volumes]` is the workspace bind, by POSITION and nothing else.
# Measured both ways on a two-mount file: with the promoted bind's source
# PRESENT, `_reconcile_workspace_path` honours it as a deliberately
# pinned workspace with no warning at all and WS_PATH resolves to the
# operator's data directory; with it ABSENT, the stale-path branch WARNs
# and overwrites the operator's own bind with the portable workspace
# mount. Neither is a removal of mount_1. So the save is declined before
# the rewrite is built -- the answer the converter already gives for a
# shape it cannot represent faithfully -- and the message names the
# CLEAR, which is the published opt-out and moves no other slot.
@test "_write_setup_conf: removing slot 1 of [volumes] while a later mount survives is refused" {
  cat > "${CONF}" << 'EOF'
[[volumes]]
source = "/ws"
target = "/work"

[[volumes]]
source = "/srv/data"
target = "/data"
EOF
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  local -a _k=() _v=()
  run _write_setup_conf "${CONF}" "${CONF}" _k _v "volumes.mount_1"
  assert_failure
  assert_output --partial 'volumes.mount_1'
  assert_output --partial 'setup.sh set volumes.mount_1'
  run diff -u "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'volumes\tmount_1\t/ws:/work'
  assert_line $'volumes\tmount_2\t/srv/data:/data'
}

# why: The refusal above has to be NARROW or it is a blanket ban on
# `remove`. Slot 1 can only be taken over when something is left to
# promote into it, so removing the one and only mount cannot corrupt
# anything: the array is replaced by nothing, which is `volumes = []`,
# and `_reconcile_workspace_path` reads that as the cleared workspace --
# its silent branch, which touches no file. This is the control for the
# containment, pinned through the MERGE rather than the file text.
@test "_write_setup_conf: removing slot 1 of [volumes] when it is the only mount is not refused" {
  printf '[[volumes]]\nsource = "/ws"\ntarget = "/work"\n' > "${CONF}"
  local -a _k=() _v=()
  _write_setup_conf "${CONF}" "${CONF}" _k _v "volumes.mount_1"
  run toml_bridge_merge --kv "${TPL}" "${CONF}"
  assert_success
  refute_line --regexp '^volumes\tmount_'
}

# why: The second control, and the ordinary case the containment must not
# touch: an entry ABOVE slot 1. Removing it compacts the entries after it
# and leaves slot 1 exactly where it was, so the workspace bind is never
# promoted into or out of. A gate that refused this would have made
# `setup.sh remove` unusable on `[volumes]` altogether.
@test "_write_setup_conf: a [volumes] removal above slot 1 still compacts" {
  cat > "${CONF}" << 'EOF'
[[volumes]]
source = "/ws"
target = "/work"

[[volumes]]
source = "/srv/data"
target = "/data"

[[volumes]]
source = "/srv/logs"
target = "/logs"
EOF
  local -a _k=() _v=()
  _write_setup_conf "${CONF}" "${CONF}" _k _v "volumes.mount_2"
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'volumes\tmount_1\t/ws:/work'
  assert_line $'volumes\tmount_2\t/srv/logs:/logs'
  refute_line --regexp '^volumes	mount_3	'
  refute_output --partial '/srv/data'
}

# why: The same takeover reached without a second block in the file. A
# save that removes slot 1 and ADDS an entry at another index has nothing
# to compact, but the added block is appended as the array's only one, so
# it reads back as `mount_1` -- the operator's `/srv/data:/data` became
# the workspace bind (measured). The refusal asks whether anything is
# left to occupy slot 1, not how many blocks the file has, so this case
# is one answer and not a second rule.
@test "_write_setup_conf: a save that removes slot 1 of [volumes] and adds a mount is refused" {
  printf '[[volumes]]\nsource = "/ws"\ntarget = "/work"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  local -a _k=(volumes.mount_2) _v=(/srv/data:/data)
  run _write_setup_conf "${CONF}" "${CONF}" _k _v "volumes.mount_1"
  assert_failure
  run diff -u "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: The containment is about COMPACTION, which only the TOML
# destination does. An INI file keeps every remaining key's own suffix
# and tolerates the gap, so `mount_2` stays `mount_2` and nothing is
# promoted into the workspace position -- the frozen TUI's `.setup.conf`
# must keep removing mount_1 as it always has.
@test "_write_setup_conf: an INI destination still removes mount_1, which promotes nothing" {
  local _ini="${TEMP_DIR}/.setup.conf"
  printf '[volumes]\nmount_1 = /ws:/work\nmount_2 = /srv/data:/data\n' > "${_ini}"
  local -a _k=() _v=()
  _write_setup_conf "${_ini}" "${_ini}" _k _v "volumes.mount_1"
  run cat "${_ini}"
  assert_line 'mount_2 = /srv/data:/data'
  refute_output --partial '/ws:/work'
}

# ════════════════════════════════════════════════════════════════════
# One numbered family, one spelling: the write face (base#1243)
# ════════════════════════════════════════════════════════════════════

# why: A WRITE THAT CANNOT DO WHAT IT SAYS MUST NOT REPORT SUCCESS, and
# this one did. On a file carrying `cap_add_1` as a table scalar AND a
# `[[security.cap_add]]` block, `setup.sh set security.cap_add_1 CHOWN`
# maps the key through `_conf_toml_aot_slot` to array block 1, replaces
# THAT, and leaves the scalar line untouched -- measured: exit 0, with
# the effective list then `CHOWN NET_RAW`. So an operator who added one
# capability got two, one of them the value they had just replaced, and
# `add` / `remove` reach the same writer with no path to the stale
# scalar. The commit gate now asks the question in the mode the
# configuration is actually read in, so the rewrite is not promoted and
# the operator's file is left exactly as it was. `cap_add` and not
# `cap_drop` on purpose: this family has had an array home from the
# start, so the write face is the family's and not one slice's.
@test "_upsert_conf_value: a set on a numbered family carried both ways is declined, and the file is untouched (base#1243)" {
  cat > "${CONF}" << 'EOF'
[security]
privileged = false
cap_add_1 = "NET_RAW"

[[security.cap_add]]
cap = "SYS_ADMIN"
EOF
  cp "${CONF}" "${TEMP_DIR}/before.toml"

  run _upsert_conf_value "${CONF}" security cap_add_1 'CHOWN'
  assert_failure
  assert_output --partial "WRITE DECLINED"
  assert_output --partial "security.cap_add_1"

  run diff -u "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: The control the gate must not break: a write on a file spelling
# the family the ONE way the writers produce still round-trips. The
# array spelling is the winner here -- `_conf_toml_aot_slot` routes every
# numbered key of a family with an array home to the array renderer, so
# it is the only spelling either writer can emit -- and a set that
# replaces block 1 leaves the family one-spelled and readable. A gate
# that refused this would have made `setup.sh set` unusable on every
# numbered family.
@test "_upsert_conf_value: a set on a single-spelling array family still round-trips (base#1243)" {
  cat > "${CONF}" << 'EOF'
[security]
privileged = false

[[security.cap_add]]
cap = "SYS_ADMIN"

[[security.cap_add]]
cap = "NET_RAW"
EOF
  _upsert_conf_value "${CONF}" security cap_add_1 'CHOWN'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'security\tcap_add_1\tCHOWN'
  assert_line $'security\tcap_add_2\tNET_RAW'
}

# why: The other half of "one spelling wins", and a deliberate behaviour
# change. A file carrying the family ONLY as table scalars is readable --
# both accessors agree on it -- but the writers cannot produce that
# spelling for a family with an array home, so the rewrite appends a
# `[[security.cap_drop]]` block beside the scalar line and MAKES the
# ambiguous file. Before the gate asked in the reading mode, that write
# reported success and left the two readers disagreeing. Declining it is
# the only answer that neither reports a success it did not achieve nor
# migrates a spelling, which base#1243 bounds out; the refusal is also
# why no `setup.sh` subcommand for clearing a stale scalar is owed.
@test "_upsert_conf_value: a set that would make the file ambiguous is declined, not promoted (base#1243)" {
  cat > "${CONF}" << 'EOF'
[security]
privileged = false
cap_drop_1 = "NET_RAW"
EOF
  cp "${CONF}" "${TEMP_DIR}/before.toml"

  run _upsert_conf_value "${CONF}" security cap_drop_1 'CHOWN'
  assert_failure
  assert_output --partial "WRITE DECLINED"

  run diff -u "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success

  # The file it was: still one-spelled, still readable, still saying what
  # the operator wrote.
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line $'security\tcap_drop_1\tNET_RAW'
}
