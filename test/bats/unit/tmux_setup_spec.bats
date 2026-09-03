#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  export HOME="${TEMP_DIR}"

  # shellcheck disable=SC1091
  source /source/dist/config/shell/tmux/setup.sh
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# check_deps
# ════════════════════════════════════════════════════════════════════

# why: Dependency check
@test "check_deps returns 0 when tmux and git are installed" {
  mock_cmd "tmux" 'exit 0'
  mock_cmd "git" 'exit 0'
  run check_deps
  assert_success
}

# why: Missing tmux
@test "check_deps fails when tmux is not installed" {
  mock_cmd "git" 'exit 0'
  PATH="${MOCK_DIR}" run check_deps
  assert_failure
  assert_output --partial "Error:"
}

# why: Missing git
@test "check_deps fails when git is not installed" {
  mock_cmd "tmux" 'exit 0'
  PATH="${MOCK_DIR}" run check_deps
  assert_failure
  assert_output --partial "Error:"
}

# ════════════════════════════════════════════════════════════════════
# _entry_point
# ════════════════════════════════════════════════════════════════════

# why: Entry point
@test "_entry_point calls main when deps pass" {
  mock_cmd "tmux" 'exit 0'
  mock_cmd "git" '
if [[ "$1" == "clone" ]]; then
  mkdir -p "${@: -1}/scripts"
  echo "exit 0" > "${@: -1}/scripts/install_plugins.sh"
  chmod +x "${@: -1}/scripts/install_plugins.sh"
fi
exit 0'
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

# why: tpm clone
@test "main clones tpm repository" {
  mock_cmd "tmux" 'exit 0'
  mock_cmd "git" '
if [[ "$1" == "clone" ]]; then
  mkdir -p "${@: -1}/scripts"
  echo "exit 0" > "${@: -1}/scripts/install_plugins.sh"
  chmod +x "${@: -1}/scripts/install_plugins.sh"
fi
exit 0'
  run main
  assert [ -d "${TEMP_DIR}/.tmux/plugins/tpm" ]
}

# why: Config dir
@test "main creates tmux config directory" {
  mock_cmd "tmux" 'exit 0'
  mock_cmd "git" '
if [[ "$1" == "clone" ]]; then
  mkdir -p "${@: -1}/scripts"
  echo "exit 0" > "${@: -1}/scripts/install_plugins.sh"
  chmod +x "${@: -1}/scripts/install_plugins.sh"
fi
exit 0'
  run main
  assert [ -d "${TEMP_DIR}/.config/tmux" ]
}

# why: Config copy
@test "main copies tmux.conf to config directory" {
  mock_cmd "tmux" 'exit 0'
  mock_cmd "git" '
if [[ "$1" == "clone" ]]; then
  mkdir -p "${@: -1}/scripts"
  echo "exit 0" > "${@: -1}/scripts/install_plugins.sh"
  chmod +x "${@: -1}/scripts/install_plugins.sh"
fi
exit 0'
  run main
  assert [ -f "${TEMP_DIR}/.config/tmux/tmux.conf" ]
}

# why: Direct-run guard
@test "script runs entry_point when executed directly" {
  mock_cmd "tmux" 'exit 0'
  mock_cmd "git" '
if [[ "$1" == "clone" ]]; then
  mkdir -p "${@: -1}/scripts"
  echo "exit 0" > "${@: -1}/scripts/install_plugins.sh"
  chmod +x "${@: -1}/scripts/install_plugins.sh"
fi
exit 0'
  run bash /source/dist/config/shell/tmux/setup.sh
  assert_success
}
