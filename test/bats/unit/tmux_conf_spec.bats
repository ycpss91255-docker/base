#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  CONF="/source/dist/config/shell/tmux/tmux.conf"
}

# ════════════════════════════════════════════════════════════════════
# Core settings
# ════════════════════════════════════════════════════════════════════

# why: tmux prefix
@test "defines prefix key" {
  run grep -q "set-option -g prefix" "${CONF}"
  assert_success
}

# why: Shell setting
@test "sets default shell to bash" {
  run grep -q 'default-shell.*bash' "${CONF}"
  assert_success
}

# why: Terminal setting
@test "sets default terminal" {
  run grep -q "set -g default-terminal" "${CONF}"
  assert_success
}

# why: Mouse
@test "enables mouse support" {
  run grep -q "set -g mouse on" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Vi mode
# ════════════════════════════════════════════════════════════════════

# why: vi mode
@test "enables vi status-keys" {
  run grep -q "status-keys vi" "${CONF}"
  assert_success
}

# why: vi mode
@test "enables vi mode-keys" {
  run grep -q "mode-keys vi" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Key bindings
# ════════════════════════════════════════════════════════════════════

# why: Split bindings
@test "defines split-window bindings" {
  run grep -q "split-window" "${CONF}"
  assert_success
}

# why: Reload binding
@test "defines reload config binding" {
  run grep -q "source-file" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Status bar
# ════════════════════════════════════════════════════════════════════

# why: Status bar
@test "enables status bar" {
  run grep -q "set-option -g status on" "${CONF}"
  assert_success
}

# why: Status bar position
@test "sets status bar position" {
  run grep -q "status-position" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# TPM (plugin manager)
# ════════════════════════════════════════════════════════════════════

# why: tpm plugin
@test "declares tpm plugin" {
  run grep -q "@plugin 'tmux-plugins/tpm'" "${CONF}"
  assert_success
}

# why: tpm init
@test "initializes tpm at end of file" {
  run grep -q "tpm/tpm" "${CONF}"
  assert_success
}
