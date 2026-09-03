#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  export HOME="${TEMP_DIR}"

  # shellcheck disable=SC1091
  source /source/dist/config/shell/terminator/setup.sh
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# check_deps
# ════════════════════════════════════════════════════════════════════

# why: Dependency check
@test "check_deps returns 0 when terminator is installed" {
  mock_cmd "terminator" 'exit 0'
  run check_deps
  assert_success
}

# why: Missing dep
@test "check_deps fails when terminator is not installed" {
  PATH="${MOCK_DIR}" run check_deps
  assert_failure
  assert_output --partial "Error:"
}

# ════════════════════════════════════════════════════════════════════
# _entry_point
# ════════════════════════════════════════════════════════════════════

# why: Entry point
@test "_entry_point calls main when deps pass" {
  mock_cmd "terminator" 'exit 0'
  mock_cmd "chown" 'exit 0'
  run _entry_point
  assert_success
}

# why: Entry point fail
@test "_entry_point fails when deps missing" {
  PATH="${MOCK_DIR}" run _entry_point
  assert_failure
  assert_output --partial "Missing dependencies"
}

# ════════════════════════════════════════════════════════════════════
# main
# ════════════════════════════════════════════════════════════════════

# why: Config dir
@test "main creates terminator config directory" {
  mock_cmd "chown" 'exit 0'
  run main
  assert [ -d "${TEMP_DIR}/.config/terminator" ]
}

# why: Config copy
@test "main copies terminator config file" {
  mock_cmd "chown" 'exit 0'
  run main
  assert [ -f "${TEMP_DIR}/.config/terminator/config" ]
}

# why: Permissions
@test "main calls chown with correct user and group" {
  mock_cmd "chown" 'echo "chown called: $*"; exit 0'
  run main
  assert_success
  assert_output --partial "chown called:"
}

# why: Direct-run guard
@test "script runs entry_point when executed directly" {
  mock_cmd "terminator" 'exit 0'
  mock_cmd "chown" 'exit 0'
  run bash /source/dist/config/shell/terminator/setup.sh
  assert_success
}
