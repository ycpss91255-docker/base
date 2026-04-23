#!/usr/bin/env bats
#
# Unit tests for upgrade.sh, focused on _warn_config_drift — the
# helper that tells the user when the upstream template/config/ tree
# moved during a subtree pull so they can reconcile their per-repo
# <repo>/config/ copy.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  UPGRADE="/source/upgrade.sh"

  # Build a self-contained test harness: a shell script that redefines
  # `_log` (avoids pulling in upgrade.sh's top-level `cd REPO_ROOT`)
  # and extracts `_warn_config_drift` from upgrade.sh by sed range so
  # tests exercise the real function body, not a copy.
  TEMP_DIR="$(mktemp -d)"
  HARNESS="${TEMP_DIR}/harness.sh"
  cat > "${HARNESS}" <<'EOS'
_log() { printf '[upgrade] %s\n' "$*"; }
EOS
  sed -n '/^_warn_config_drift() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── _warn_config_drift logic ────────────────────────────────────────────────

@test "_warn_config_drift silent when no template/config in HEAD" {
  local _git_dir="${TEMP_DIR}/empty"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _warn_config_drift ''"
  assert_success
  refute_output --partial "WARNING"
}

@test "_warn_config_drift silent when pre and post hashes match" {
  local _git_dir="${TEMP_DIR}/same"
  mkdir -p "${_git_dir}/template/config"
  git -C "${_git_dir}" init -q -b main
  git -C "${_git_dir}" config user.email t@t
  git -C "${_git_dir}" config user.name t
  echo "one" > "${_git_dir}/template/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c1

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _pre=\$(git rev-parse HEAD:template/config)
    _warn_config_drift \"\${_pre}\"
  "
  assert_success
  refute_output --partial "WARNING"
}

@test "_warn_config_drift prints WARNING + diff hint when hashes differ" {
  local _git_dir="${TEMP_DIR}/drift"
  mkdir -p "${_git_dir}/template/config"
  git -C "${_git_dir}" init -q -b main
  git -C "${_git_dir}" config user.email t@t
  git -C "${_git_dir}" config user.name t
  echo "original" > "${_git_dir}/template/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c1
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD:template/config)"

  echo "updated" > "${_git_dir}/template/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c2

  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _warn_config_drift '${_pre}'"
  assert_success
  assert_output --partial "WARNING: template/config/ changed"
  assert_output --partial "diff -ruN template/config config"
  assert_output --partial "git diff ${_pre:0:12}"
}

# ── upgrade.sh structural invariants ────────────────────────────────────────

@test "upgrade.sh defines _warn_config_drift" {
  run grep -F '_warn_config_drift()' "${UPGRADE}"
  assert_success
}

@test "upgrade.sh invokes _warn_config_drift after subtree pull" {
  # The helper existing without a call site is a bug; count references
  # so a refactor that drops the invocation trips this test.
  local _n
  _n="$(grep -Fc '_warn_config_drift' "${UPGRADE}")"
  (( _n >= 2 ))
}

@test "upgrade.sh captures pre-pull template/config tree hash" {
  # The WARNING only fires when we have both pre and post hashes —
  # guard against dropping the snapshot line.
  run grep -F 'HEAD:template/config' "${UPGRADE}"
  assert_success
}
