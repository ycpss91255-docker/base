#!/usr/bin/env bats
#
# Unit tests for _assemble_mount_value -- pure function that builds the
# host:container[:mode] string used by [devices] device_* and [volumes]
# mount_* entries.
#
# why: Unit tests for the TUI mount-string assembler
# (`_assemble_mount_value` / `_prompt_mount_with_picker`, #461):
# host:container[:mode] composition, combined access/propagation modes,
# `_validate_mount` round-trip, and space-bearing path rejection (#687).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  source /source/dist/script/docker/lib/_tui_conf.sh
}

# ──_assemble_mount_value ───────────────────────────────────

# why: Bare two-field mount
@test "_assemble_mount_value returns host:container when no mode (#461)" {
  run _assemble_mount_value /dev /dev
  assert_success
  assert_output "/dev:/dev"
}

# why: Single-mode suffix
@test "_assemble_mount_value returns host:container:mode for single mode (#461)" {
  run _assemble_mount_value /data /data ro
  assert_success
  assert_output "/data:/data:ro"
}

# why: Combined mode
@test "_assemble_mount_value accepts combined access,propagation (#461)" {
  run _assemble_mount_value /dev /dev rw,rslave
  assert_success
  assert_output "/dev:/dev:rw,rslave"
}

# why: Round-trip validation
@test "_assemble_mount_value output validates via _validate_mount (#461)" {
  # Assembled string must pass the validator (round-trip).
  local _result
  _result="$(_assemble_mount_value /dev /dev rw,rslave)"
  _validate_mount "${_result}"
}

# why: Empty-mode no suffix
@test "_assemble_mount_value empty mode means no suffix (#461)" {
  run _assemble_mount_value /a /b ""
  assert_success
  assert_output "/a:/b"
}

# why: Space-path rejection
@test "_assemble_mount_value space-bearing path is rejected by _validate_mount (#687)" {
  # A space-bearing host path round-trips through the assembler into
  # `/my data:/work`, which word-splits in `docker run -v /my data:/work`
  # and corrupts the compose volumes list. The validator must reject it so
  # the bad value never reaches an emitter.
  local _result
  _result="$(_assemble_mount_value '/my data' /work)"
  [ "${_result}" = "/my data:/work" ]
  run _validate_mount "${_result}"
  assert_failure
  # Either side of the colon, and the container side, are all guarded.
  run _validate_mount "/host:/my data"
  assert_failure
}

# ── TUI picker flow (mocked) ───────────────────────────────────

# why: Full picker assembly
@test "_prompt_mount_with_picker assembles full mount string from picker steps (#461)" {
  source /source/dist/script/docker/wrapper/setup_tui.sh
  _QFILE="${BATS_TEST_TMPDIR}/q"
  : > "${_QFILE}"
  # Queue 4 responses: host, container, access, propagation
  printf '0|/dev\n0|/dev\n0|rw\n0|rslave\n' > "${_QFILE}"
  _tui_pop() {
    local _line; _line="$(head -n 1 "${_QFILE}")"; sed -i '1d' "${_QFILE}"
    printf '%s' "${_line#*|}"; return "${_line%%|*}"
  }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  export -f _tui_pop _tui_inputbox _tui_radiolist; export _QFILE
  run _prompt_mount_with_picker ""
  assert_success
  assert_output "/dev:/dev:rw,rslave"
}

# why: Access-only picker
@test "_prompt_mount_with_picker no propagation gives just host:container:access (#461)" {
  source /source/dist/script/docker/wrapper/setup_tui.sh
  _QFILE="${BATS_TEST_TMPDIR}/q"
  : > "${_QFILE}"
  printf '0|/data\n0|/data\n0|ro\n0|none\n' > "${_QFILE}"
  _tui_pop() {
    local _line; _line="$(head -n 1 "${_QFILE}")"; sed -i '1d' "${_QFILE}"
    printf '%s' "${_line#*|}"; return "${_line%%|*}"
  }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  export -f _tui_pop _tui_inputbox _tui_radiolist; export _QFILE
  run _prompt_mount_with_picker ""
  assert_success
  assert_output "/data:/data:ro"
}

# why: Bare picker
@test "_prompt_mount_with_picker no access + no propagation gives just host:container (#461)" {
  source /source/dist/script/docker/wrapper/setup_tui.sh
  _QFILE="${BATS_TEST_TMPDIR}/q"
  : > "${_QFILE}"
  printf '0|/a\n0|/b\n0|none\n0|none\n' > "${_QFILE}"
  _tui_pop() {
    local _line; _line="$(head -n 1 "${_QFILE}")"; sed -i '1d' "${_QFILE}"
    printf '%s' "${_line#*|}"; return "${_line%%|*}"
  }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  export -f _tui_pop _tui_inputbox _tui_radiolist; export _QFILE
  run _prompt_mount_with_picker ""
  assert_success
  assert_output "/a:/b"
}
