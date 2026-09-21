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

# why: The conversion table of the migration: a numbered list key is an
# `[[array of tables]]` entry, not a `mount_N` scalar. The N-th block IS
# entry N, so writing an index that exists replaces that block in place
# and writing the next index appends a block after it; the bridge
# numbers them back in file order.
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
# (the array compacts, so what was entry 2 reads back as entry 1), and
# a section the template never had is opened with a quoted header.
@test "_write_setup_conf: a TOML rewrite with scalar, array, removed and new-section overrides parses and reads back" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '/a:/b'
  _upsert_conf_value "${CONF}" volumes mount_2 '/c:/d'

  local -a _keys=(network.mode image.rule_2 image.rule_4 volumes.mount_3 stage:headless.gui.mode deploy.gpu_count)
  local -a _vals=(bridge 'suffix:_dev' '@parent' /e:/f off 2)
  _write_setup_conf "${CONF}" "${CONF}" _keys _vals 'volumes.mount_1 build.arg_2'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'image	rule_1	prefix:docker_'
  assert_line 'image	rule_2	suffix:_dev'
  assert_line 'image	rule_3	@basename'
  assert_line 'image	rule_4	@parent'
  assert_line 'volumes	mount_1	/c:/d'
  assert_line 'volumes	mount_2	/e:/f'
  refute_output --partial '/a:/b'
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
# `remove` by value has to find the entry in that same view.
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
    main remove volumes.mount /a:/b --base-path '${_repo}' -q || exit 15
  "
  assert_success

  run toml_bridge_parse "${_repo}/setup.toml" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'volumes	mount_1	/c:/d'
  refute_output --partial '/a:/b'
  assert_line 'build	arg_4	FOO=bar'
}
