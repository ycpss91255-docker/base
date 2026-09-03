#!/usr/bin/env bats
#
# why: Locks the `-h` / `--help` invariants on the four wrapper scripts
# (`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) plus the `_LANG`
# auto-detection rules in `build.sh` (`LANG=zh_TW.UTF-8` → zh, `ja_JP` → ja,
# `en_US` → en, `SETUP_LANG` overrides `LANG`) plus #222 `--help` / `--lang`
# order independence (pre-pass scans for `--lang` before main parse so
# `<script> --help --lang zh-TW` produces zh-TW usage, not English).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# -------------------- build.sh --------------------

# why: Wrapper smoke
@test "build.sh -h exits 0" {
  run bash /lint/build.sh -h
  assert_success
}

# why: Long flag
@test "build.sh --help exits 0" {
  run bash /lint/build.sh --help
  assert_success
}

# why: Output sanity
@test "build.sh -h prints usage" {
  run bash /lint/build.sh -h
  assert_line --partial "Usage:"
}

# why: Help text describes auto-apply, not stale warn-on-drift
@test "build.sh -h describes auto-apply default (no stale 'warn on drift', #365)" {
  run bash /lint/build.sh -h
  assert_success
  assert_line --partial "auto-regenerate"
  refute_line --partial "warn on drift"
}

# -------------------- run.sh --------------------

# why: Wrapper smoke
@test "run.sh -h exits 0" {
  run bash /lint/run.sh -h
  assert_success
}

# why: Long flag
@test "run.sh --help exits 0" {
  run bash /lint/run.sh --help
  assert_success
}

# why: Output sanity
@test "run.sh -h prints usage" {
  run bash /lint/run.sh -h
  assert_line --partial "Usage:"
}

# why: Help text describes auto-apply, not stale warn-on-drift
@test "run.sh -h describes auto-apply default (no stale 'warn on drift', #365)" {
  run bash /lint/run.sh -h
  assert_success
  assert_line --partial "auto-regenerate"
  refute_line --partial "warn on drift"
}

# -------------------- exec.sh --------------------

# why: Wrapper smoke
@test "exec.sh -h exits 0" {
  run bash /lint/exec.sh -h
  assert_success
}

# why: Long flag
@test "exec.sh --help exits 0" {
  run bash /lint/exec.sh --help
  assert_success
}

# why: Output sanity
@test "exec.sh -h prints usage" {
  run bash /lint/exec.sh -h
  assert_line --partial "Usage:"
}

# -------------------- stop.sh --------------------

# why: Wrapper smoke
@test "stop.sh -h exits 0" {
  run bash /lint/stop.sh -h
  assert_success
}

# why: Long flag
@test "stop.sh --help exits 0" {
  run bash /lint/stop.sh --help
  assert_success
}

# why: Output sanity
@test "stop.sh -h prints usage" {
  run bash /lint/stop.sh -h
  assert_line --partial "Usage:"
}

# -------------------- LANG auto-detect --------------------

# why: i18n detect — zh-TW
@test "build.sh detects zh from LANG=zh_TW.UTF-8" {
  run env LANG=zh_TW.UTF-8 bash /lint/build.sh -h
  assert_success
  assert_line --partial "用法:"
}

# why: i18n detect — ja
@test "build.sh detects ja from LANG=ja_JP.UTF-8" {
  run env LANG=ja_JP.UTF-8 bash /lint/build.sh -h
  assert_success
  assert_line --partial "使用法:"
}

# why: i18n detect — en default
@test "build.sh defaults to en for LANG=en_US.UTF-8" {
  run env LANG=en_US.UTF-8 bash /lint/build.sh -h
  assert_success
  assert_line --partial "Usage:"
}

# why: i18n env override
@test "build.sh SETUP_LANG overrides LANG" {
  run env LANG=ja_JP.UTF-8 SETUP_LANG=zh-TW bash /lint/build.sh -h
  assert_success
  assert_line --partial "用法:"
}

# ----------------------help / --lang argument order --------------------
#
# Pre-pass scans args for --lang before the main parse loop, so the
# locale set by --lang takes effect even when --help comes first.
# Without the fix, `<script> --help --lang zh-TW` printed English
# because usage exited before --lang was reached. Each pair below
# asserts that BOTH orderings produce the same localised first line.

@test "build.sh --help --lang zh-TW prints zh-TW usage (#222)" {
  run bash /lint/build.sh --help --lang zh-TW
  assert_success
  assert_line --partial "用法:"
}

@test "build.sh --help --lang zh-CN prints zh-CN usage (#222)" {
  run bash /lint/build.sh --help --lang zh-CN
  assert_success
  assert_line --partial "用法:"
}

@test "build.sh --help --lang ja prints ja usage (#222)" {
  run bash /lint/build.sh --help --lang ja
  assert_success
  assert_line --partial "使用法:"
}

@test "run.sh --help --lang zh-TW prints zh-TW usage (#222)" {
  run bash /lint/run.sh --help --lang zh-TW
  assert_success
  assert_line --partial "用法:"
}

@test "run.sh --help --lang ja prints ja usage (#222)" {
  run bash /lint/run.sh --help --lang ja
  assert_success
  assert_line --partial "使用法:"
}

@test "exec.sh --help --lang zh-TW prints zh-TW usage (#222)" {
  run bash /lint/exec.sh --help --lang zh-TW
  assert_success
  assert_line --partial "用法:"
}

@test "exec.sh --help --lang ja prints ja usage (#222)" {
  run bash /lint/exec.sh --help --lang ja
  assert_success
  assert_line --partial "使用法:"
}

@test "stop.sh --help --lang zh-TW prints zh-TW usage (#222)" {
  run bash /lint/stop.sh --help --lang zh-TW
  assert_success
  assert_line --partial "用法:"
}

@test "stop.sh --help --lang ja prints ja usage (#222)" {
  run bash /lint/stop.sh --help --lang ja
  assert_success
  assert_line --partial "使用法:"
}
