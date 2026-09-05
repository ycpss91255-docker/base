#!/usr/bin/env bats
#
# Unit tests for _assemble_mount_value -- pure function that builds the
# host:container[:mode] string used by [devices] device_* and [volumes]
# mount_* entries.
#
# why: Unit tests for the TUI mount-string assembler
# (`_assemble_mount_value`, #461): host:container[:mode] composition,
# combined access/propagation modes, `_validate_mount` round-trip, and
# space-bearing path rejection (#687). The picker cases that used to sit
# below these drove `_prompt_mount_with_picker`, which base#1073 found had
# no production caller -- the mount editors all route through
# `_edit_list_entry` -- so the function and its three specs are gone.

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
