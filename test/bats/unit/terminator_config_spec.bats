#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  CONFIG="/source/dist/config/shell/terminator/config"
}

# ════════════════════════════════════════════════════════════════════
# Sections
# ════════════════════════════════════════════════════════════════════

# why: Config section
@test "has [global_config] section" {
  run grep -q "^\[global_config\]" "${CONFIG}"
  assert_success
}

# why: Config section
@test "has [keybindings] section" {
  run grep -q "^\[keybindings\]" "${CONFIG}"
  assert_success
}

# why: Config section
@test "has [profiles] section" {
  run grep -q "^\[profiles\]" "${CONFIG}"
  assert_success
}

# why: Config section
@test "has [layouts] section" {
  run grep -q "^\[layouts\]" "${CONFIG}"
  assert_success
}

# why: Config section
@test "has [plugins] section" {
  run grep -q "^\[plugins\]" "${CONFIG}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Profiles
# ════════════════════════════════════════════════════════════════════

# why: Default profile
@test "profiles has [[default]]" {
  run grep -q "\[\[default\]\]" "${CONFIG}"
  assert_success
}

# why: Font setting
@test "default profile disables system font" {
  run grep -q "use_system_font = False" "${CONFIG}"
  assert_success
}

# why: Scrollback setting
@test "default profile has infinite scrollback" {
  run grep -q "scrollback_infinite = True" "${CONFIG}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Layouts
# ════════════════════════════════════════════════════════════════════

# why: Window layout
@test "layouts has Window type" {
  run grep -q "type = Window" "${CONFIG}"
  assert_success
}

# why: Terminal layout
@test "layouts has Terminal type" {
  run grep -q "type = Terminal" "${CONFIG}"
  assert_success
}
