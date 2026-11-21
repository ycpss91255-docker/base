#!/usr/bin/env bats
#
# config_gen_s32_golden_spec.bats -- the s32 corpus of the INI-to-TOML
# converter, pinned as goldens (base#2056, slice S32a of base#1765).
#
# why: The Go converter that replaces `_migrate_ini_to_toml` must match the
# shell byte for byte. Each corpus/s32/<name>.ini is converted by the shell
# into a temp dir; the resulting setup.toml must equal the committed
# golden/s32/<name>.toml, the event ids the shell logs must equal the list
# below, and the function's return must be 0. The spec fails while a golden
# is missing or differs, so a golden can never drift from the shell.

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"
TESTDATA="/source/dockerfile/config-gen/testdata"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _check_s32 <name> <event ids, space separated>
#   Convert corpus/s32/<name>.ini with the shell, then compare the bytes of
#   the written setup.toml with golden/s32/<name>.toml, the logged event ids
#   (JSON log body, in order) with the expected list, and the return with 0.
_check_s32() {
  local _name="${1}" _events="${2}" _got
  cp "${TESTDATA}/corpus/s32/${_name}.ini" "${TEMP_DIR}/.setup.conf"
  LOG_FORMAT=json run --separate-stderr bash -c \
    "source '${LIB}/_lib.sh'; source '${LIB}/ini_to_toml_migrate.sh'; _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  _got="$(printf '%s\n%s\n' "${output}" "${stderr}" \
    | sed -n 's/.*"body":"\([a-z_]*\)".*/\1/p' | paste -sd' ')"
  assert_equal "${_got}" "${_events}"
  assert [ -f "${TESTDATA}/golden/s32/${_name}.toml" ]
  run cmp "${TEMP_DIR}/setup.toml" "${TESTDATA}/golden/s32/${_name}.toml"
  assert_success
}

@test "s32 a repeated key keeps the last value (base#2056)" {
  _check_s32 s32_repeat_key "ini_to_toml_migrated"
}

@test "s32 scalar values quote strings and keep plain integers bare (base#2056)" {
  _check_s32 s32_scalar_values "ini_to_toml_migrated"
}

@test "s32 backslash and tab are escaped in the quoted string (base#2056)" {
  _check_s32 s32_backslash_tab "ini_to_toml_migrated"
}

@test "s32 a section without numbered families converts alone (base#2056)" {
  _check_s32 s32_absent_family "ini_to_toml_migrated"
}

@test "s32 deploy runtime is renamed to gpu_runtime (base#2056)" {
  _check_s32 s32_runtime_alias "ini_to_toml_runtime_renamed ini_to_toml_migrated"
}
