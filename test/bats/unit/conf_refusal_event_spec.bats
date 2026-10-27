#!/usr/bin/env bats
#
# conf_refusal_event_spec.bats -- every refusal on the config path that no
# spec named, asserted by its event id (base#1400).
#
# why: A refusal is identified by its event id, and only the JSON log sink
# prints one: the text sink prints the `display=` string instead, so the
# specs that force LOG_FORMAT=text cannot tell one refusal from another.
# A status-only check is weaker still -- an unregistered body is a fatal
# logger error that also answers 1, so it passes when the refusal it
# meant has been replaced by a logger crash. Each case here drives the
# real refusal with LOG_FORMAT=json and holds it to the five points of
# `assert_refusal` (test_helper.bash): exact status, empty stdout, the
# event id, the file and key it names, and no unregistered body. Where a
# failure can only be reached by faking the filesystem, the case says how
# it forces it.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  CONF="${TEMP_DIR}/setup.toml"
  LIB=/source/dist/script/docker/lib
  SETUP_SH=/source/dist/script/docker/wrapper/setup.sh
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# _seed_subtree_without_bridge_dockerfile
#   A vendored subtree (`.version` + `dist/`) whose dockerfile/ is empty,
#   so the containerised bridge has nothing to build from. SUB_LIB is the
#   copied lib directory.
_seed_subtree_without_bridge_dockerfile() {
  SUB="${TEMP_DIR}/consumer/vendored"
  mkdir -p "${SUB}/dist/script/docker" "${SUB}/dockerfile"
  cp -a "${LIB}" "${SUB}/dist/script/docker/lib"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
  SUB_LIB="${SUB}/dist/script/docker/lib"
}

# ════════════════════════════════════════════════════════════════════
# conf.sh
# ════════════════════════════════════════════════════════════════════

# why: A layer that does not parse must stop the load by name rather than
# hand back an empty configuration that reads as the template defaults.
@test "conf_toml_merge_failed: a malformed layer stops _conf_load_layers, naming the file" {
  # toml-fixture-lint: allow the parser's refusal of this layer IS the assertion
  printf '[build\ntz = "UTC"\n' > "${CONF}"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    _conf_load_layers H '${CONF}'
  "
  assert_refusal 1 conf_toml_merge_failed "${CONF}"
}

# why: An index of a numbered family with no 1-based slot would land the
# value in another block -- `mount_0` became the workspace bind. The
# writer refuses before any temp file exists.
@test "conf_write_index_rejected: a set on mount_0 is refused, naming the file and the key" {
  printf '[network]\nmode = "host"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    _upsert_conf_value '${CONF}' volumes mount_0 /a:/b
  "
  assert_refusal 1 conf_write_index_rejected "file=${CONF}" "volumes.mount_0"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: Removing slot 1 of [volumes] compacts the array and promotes the
# next mount into the workspace bind, so the remove verb refuses it.
@test "conf_write_ws_slot_refused: setup remove volumes.mount_1 is refused, naming the file and the slot" {
  # shellcheck disable=SC2016  # the portable ${WS_PATH} form is literal
  printf '[[volumes]]\nsource = "${WS_PATH}"\ntarget = "/work"\n\n[[volumes]]\nsource = "/srv/data"\ntarget = "/data"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${SETUP_SH}'
    main remove volumes.mount_1 --base-path '${TEMP_DIR}'
  "
  assert_refusal 2 conf_write_ws_slot_refused "file=${CONF}" "key=volumes.mount_1"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: A temp file that cannot be created must stop the rewrite before the
# destination is touched. FORCED by shadowing `mktemp` with a shell
# function that fails: as root (the test-tools image) no directory mode
# stops a create, so a read-only directory cannot provoke it.
@test "conf_write_tmp_failed: _write_setup_conf refuses when its temp file cannot be created" {
  [ "${COVERAGE:-0}" = 1 ] && skip "mktemp-failure stub is kcov-fragile (#613)"
  printf '[network]\nmode = "host"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    mktemp() { return 1; }
    declare -a _k=(network.mode) _v=(bridge)
    _write_setup_conf '${CONF}' '${CONF}' _k _v
  "
  assert_refusal 1 conf_write_tmp_failed "file=${CONF}"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: A removal the line writer cannot reach (an inline table) leaves a
# file the parse gate accepts with the value still in it; the save is
# refused instead of reported as done.
@test "conf_write_not_applied: a removal the rewrite did not make is refused, naming the file and the key" {
  printf 'resources = { shm_size = "64m" }\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    declare -a _k=() _v=()
    _write_setup_conf '${CONF}' '${CONF}' _k _v resources.shm_size
  "
  assert_refusal 1 conf_write_not_applied "file=${CONF}" "target=resources.shm_size"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: The rewrite must take the destination's mode before it lands, or a
# user's setup.toml is left at 0600. FORCED by shadowing `chmod` with a
# shell function that fails: root's chmod does not fail on a real file.
@test "conf_write_mode_failed: _write_setup_conf refuses when the mode cannot be carried over" {
  [ "${COVERAGE:-0}" = 1 ] && skip "chmod-failure stub is kcov-fragile (#613)"
  printf '[network]\nmode = "host"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    chmod() { return 1; }
    declare -a _k=(network.mode) _v=(bridge)
    _write_setup_conf '${CONF}' '${CONF}' _k _v
  "
  assert_refusal 1 conf_write_mode_failed "file=${CONF}"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: A failed final mv (a read-only mount) must be reported, the temp
# removed and the destination left alone. FORCED by shadowing `mv` with a
# shell function that fails: root can replace a file in any directory
# the test can create.
@test "conf_write_mv_failed: _write_setup_conf refuses when the final mv fails" {
  [ "${COVERAGE:-0}" = 1 ] && skip "mv-failure stub is kcov-fragile (#613)"
  printf '[network]\nmode = "host"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    mv() { return 1; }
    declare -a _k=(network.mode) _v=(bridge)
    _write_setup_conf '${CONF}' '${CONF}' _k _v
  "
  assert_refusal 1 conf_write_mv_failed "file=${CONF}"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: The per-key writer edits a file in place and has nothing to edit
# when the file is not there; it refuses, naming the path.
@test "conf_upsert_file_missing: _upsert_conf_value refuses a file that is not there, naming it" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    _upsert_conf_value '${TEMP_DIR}/absent.toml' network mode host
  "
  assert_refusal 1 conf_upsert_file_missing "${TEMP_DIR}/absent.toml"
  assert [ ! -e "${TEMP_DIR}/absent.toml" ]
}

# why: A rewrite the configuration reader refuses is not promoted. A
# family spelled as a table scalar gets an array block beside it from the
# writer, and the reader refuses a family carried both ways.
@test "conf_write_declined: a set the reader would refuse is declined, naming the file and the key" {
  printf '[security]\nprivileged = false\ncap_drop_1 = "NET_RAW"\n' > "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/conf.sh'
    _upsert_conf_value '${CONF}' security cap_drop_1 CHOWN
  "
  assert_refusal 1 conf_write_declined "file=${CONF}" "target=security.cap_drop_1"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# toml_bridge.sh
# ════════════════════════════════════════════════════════════════════

# why: With no shipped Dockerfile there is nothing to build the parser
# from, and guessing a tag would answer with another checkout's parser.
@test "toml_bridge_unprovisionable: a subtree with no bridge Dockerfile refuses the read, naming the path" {
  _seed_subtree_without_bridge_dockerfile
  printf '[gui]\nmode = "wayland"\n' > "${CONF}"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json TOML_BRIDGE_FORCE_DOCKER=1
    unset TOML_BRIDGE_IMAGE
    source '${SUB_LIB}/toml_bridge.sh'
    toml_bridge_parse '${CONF}' --kv
  "
  assert_refusal 1 toml_bridge_unprovisionable \
    "path=${SUB}/dockerfile/Dockerfile.toml-bridge"
}

# why: A failed build stops the read with the builder's complaint rather
# than an empty stream, and the read's stdout -- the stream a caller
# collects as configuration rows -- carries nothing, not even the
# progress event announcing the build. FORCED with a `docker` stub on
# PATH that reports the image absent and fails the build.
@test "toml_bridge_build_failed: a failed parser build refuses the read, naming the Dockerfile" {
  _seed_subtree_without_bridge_dockerfile
  cp -a /source/dockerfile/Dockerfile.toml-bridge /source/dockerfile/toml_bridge.py \
    "${SUB}/dockerfile/"
  printf '[gui]\nmode = "wayland"\n' > "${CONF}"
  create_mock_dir
  mock_cmd docker \
    'case "$1" in
       image) exit 1 ;;
       build) echo "no space left on device" >&2; exit 125 ;;
       *)     exit 1 ;;
     esac'
  run --separate-stderr bash -c "
    export LOG_FORMAT=json TOML_BRIDGE_FORCE_DOCKER=1
    unset TOML_BRIDGE_IMAGE
    source '${SUB_LIB}/toml_bridge.sh'
    toml_bridge_parse '${CONF}' --kv
  "
  assert_refusal 1 toml_bridge_build_failed \
    "path=${SUB}/dockerfile/Dockerfile.toml-bridge" "status=125"
}

# why: A parse of a file that is not there answers before any parser runs.
@test "no_such_file: toml_bridge_parse refuses a file that is not there, naming it" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/toml_bridge.sh'
    toml_bridge_parse '${TEMP_DIR}/absent.toml' --kv
  "
  assert_refusal 1 no_such_file "${TEMP_DIR}/absent.toml"
}

# why: A merge naming no layer at all is a caller mistake, not an empty
# configuration.
@test "merge_no_files: toml_bridge_merge refuses a call naming no layer" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${LIB}/toml_bridge.sh'
    toml_bridge_merge --kv
  "
  assert_refusal 1 merge_no_files
}

# ════════════════════════════════════════════════════════════════════
# setup_conf.sh / setup_cmd.sh / compose_emit.sh
# ════════════════════════════════════════════════════════════════════

# why: A --local-conf the call cannot honour must not resolve to the
# template defaults while the caller is told its parameters applied.
@test "conf_local_override_unusable: apply --local-conf naming no file is refused, naming the path" {
  cp /source/dist/setup.toml "${CONF}"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${SETUP_SH}'
    main apply --base-path '${TEMP_DIR}' --local-conf '${TEMP_DIR}/absent.toml'
  "
  assert_refusal 1 conf_local_override_unusable "path=${TEMP_DIR}/absent.toml"
  assert [ ! -e "${TEMP_DIR}/.env" ]
  assert [ ! -e "${TEMP_DIR}/compose.yaml" ]
}

# why: `set` of a key no reader reads would write a value nothing applies;
# it is refused before anything is written (base#1374).
@test "conf_unknown_key: setup set on a misspelt key is refused, naming the key" {
  cp /source/dist/setup.toml "${CONF}"
  cp "${CONF}" "${TEMP_DIR}/before.toml"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${SETUP_SH}'
    main set deploy.gpu_cuont 1 --base-path '${TEMP_DIR}'
  "
  assert_refusal 2 conf_unknown_key "deploy.gpu_cuont"
  run cmp "${TEMP_DIR}/before.toml" "${CONF}"
  assert_success
}

# why: A table no reader knows would have its settings dropped while apply
# reported success (base#1328).
@test "apply_unknown_table: apply refuses an unknown table, naming the file and the table" {
  printf '[deploy2]\nx = "1"\n' > "${CONF}"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${SETUP_SH}'
    main apply --base-path '${TEMP_DIR}'
  "
  assert_refusal 1 apply_unknown_table "file=${CONF}" "table=deploy2"
  assert [ ! -e "${TEMP_DIR}/.env" ]
  assert [ ! -e "${TEMP_DIR}/compose.yaml" ]
}

# why: A relocated set names the repo root inside short-form binds, where
# a colon is the field separator; what cannot be expressed is not written.
@test "compose_relocated_root_unusable: apply --output refuses a repo root carrying a colon, naming it" {
  local _repo="${TEMP_DIR}/re:po"
  mkdir -p "${_repo}"
  cp /source/dist/setup.toml "${_repo}/setup.toml"
  printf 'FROM ubuntu:24.04 AS sys\nFROM sys AS devel\n' > "${_repo}/Dockerfile"
  run --separate-stderr bash -c "
    export LOG_FORMAT=json
    source '${SETUP_SH}'
    main apply --base-path '${_repo}' --output '${TEMP_DIR}/inst-1' -q
  "
  assert_refusal --stdout-logs-only 1 compose_relocated_root_unusable "path=${_repo}"
  assert [ ! -e "${TEMP_DIR}/inst-1/compose.yaml" ]
}
