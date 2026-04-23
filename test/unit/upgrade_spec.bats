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
  # `_log` / `_error` (avoids pulling in upgrade.sh's top-level `cd
  # REPO_ROOT`) and extracts helpers from upgrade.sh by sed range so
  # tests exercise the real function bodies, not copies.
  TEMP_DIR="$(mktemp -d)"
  HARNESS="${TEMP_DIR}/harness.sh"
  cat > "${HARNESS}" <<'EOS'
_log() { printf '[upgrade] %s\n' "$*"; }
_error() { printf '[upgrade] ERROR: %s\n' "$*" >&2; exit 1; }
EOS
  sed -n '/^_warn_config_drift() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_require_git_identity() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_require_clean_merge_state() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_verify_subtree_intact() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
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

# ── _require_git_identity ───────────────────────────────────────────────────

@test "_require_git_identity succeeds when name + email are set" {
  local _git_dir="${TEMP_DIR}/ident_ok"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  git -C "${_git_dir}" config user.name "t"
  git -C "${_git_dir}" config user.email "t@t"
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_git_identity"
  assert_success
}

@test "_require_git_identity fails when user.email is unset" {
  local _git_dir="${TEMP_DIR}/ident_noemail"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  git -C "${_git_dir}" config user.name "t"
  # GIT_CONFIG_GLOBAL=/dev/null + HOME= isolates from inherited identity
  run bash -c "
    cd '${_git_dir}'
    export HOME='${TEMP_DIR}/ident_noemail' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    source '${HARNESS}'
    _require_git_identity
  "
  assert_failure
  assert_output --partial "git identity not configured"
}

@test "_require_git_identity fails when user.name is unset" {
  local _git_dir="${TEMP_DIR}/ident_noname"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  git -C "${_git_dir}" config user.email "t@t"
  run bash -c "
    cd '${_git_dir}'
    export HOME='${TEMP_DIR}/ident_noname' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    source '${HARNESS}'
    _require_git_identity
  "
  assert_failure
  assert_output --partial "git identity not configured"
}

# ── _require_clean_merge_state ──────────────────────────────────────────────

@test "_require_clean_merge_state succeeds in clean repo" {
  local _git_dir="${TEMP_DIR}/clean"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_clean_merge_state"
  assert_success
}

@test "_require_clean_merge_state fails when MERGE_HEAD exists" {
  local _git_dir="${TEMP_DIR}/midmerge"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  touch "${_git_dir}/.git/MERGE_HEAD"
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_clean_merge_state"
  assert_failure
  assert_output --partial "MERGE_HEAD present"
}

@test "_require_clean_merge_state fails when rebase-merge dir exists" {
  local _git_dir="${TEMP_DIR}/midrebase"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  mkdir -p "${_git_dir}/.git/rebase-merge"
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_clean_merge_state"
  assert_failure
  assert_output --partial "rebase-merge present"
}

# ── _verify_subtree_intact ──────────────────────────────────────────────────

# Helper: build a minimal repo resembling a subtree consumer, then
# return its _pre_head so the test can call _verify_subtree_intact.
_mk_subtree_repo() {
  local _dir="$1"
  mkdir -p "${_dir}/template/script/docker"
  echo "v0.9.5" > "${_dir}/template/.version"
  echo "#!/usr/bin/env bash" > "${_dir}/template/init.sh"
  echo "#!/usr/bin/env bash" > "${_dir}/template/script/docker/setup.sh"
  git -C "${_dir}" init -q -b main
  git -C "${_dir}" config user.email t@t
  git -C "${_dir}" config user.name t
  git -C "${_dir}" add -A
  git -C "${_dir}" commit -q -m "initial"
}

@test "_verify_subtree_intact succeeds when all markers present" {
  local _git_dir="${TEMP_DIR}/intact_ok"
  _mk_subtree_repo "${_git_dir}"
  run bash -c "
    cd '${_git_dir}'
    _pre=\$(git rev-parse HEAD)
    source '${HARNESS}'
    _verify_subtree_intact \"\${_pre}\"
  "
  assert_success
}

@test "_verify_subtree_intact rolls back when template/.version is missing" {
  local _git_dir="${TEMP_DIR}/intact_noversion"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  # Simulate the destructive FF: template/* moved up, template/.version gone.
  rm "${_git_dir}/template/.version"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}'
  "
  assert_failure
  assert_output --partial "integrity check failed"
  assert_output --partial "template/.version"
  # Post-condition: marker is restored by the rollback `git reset --hard`.
  [ -f "${_git_dir}/template/.version" ]
}

@test "_verify_subtree_intact rolls back when template/script/docker/setup.sh is missing" {
  local _git_dir="${TEMP_DIR}/intact_nosetup"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  rm "${_git_dir}/template/script/docker/setup.sh"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}'
  "
  assert_failure
  assert_output --partial "template/script/docker/setup.sh"
  [ -f "${_git_dir}/template/script/docker/setup.sh" ]
}

# ── upgrade.sh structural invariants (safety guards) ───────────────────────

@test "upgrade.sh calls _require_git_identity before subtree pull" {
  # Confirm both that the helper is called AND the ordering is correct.
  local _id_line _pull_line
  _id_line="$(grep -n '_require_git_identity$' "${UPGRADE}" | tail -1 | cut -d: -f1)"
  _pull_line="$(grep -n 'git subtree pull' "${UPGRADE}" | head -1 | cut -d: -f1)"
  [ -n "${_id_line}" ]
  [ -n "${_pull_line}" ]
  (( _id_line < _pull_line ))
}

@test "upgrade.sh calls _verify_subtree_intact after subtree pull" {
  local _pull_line _verify_line
  _pull_line="$(grep -n 'git subtree pull' "${UPGRADE}" | head -1 | cut -d: -f1)"
  _verify_line="$(grep -n '_verify_subtree_intact "\${_pre_head}"' "${UPGRADE}" | head -1 | cut -d: -f1)"
  [ -n "${_pull_line}" ]
  [ -n "${_verify_line}" ]
  (( _verify_line > _pull_line ))
}

@test "upgrade.sh snapshots pre-pull HEAD for rollback" {
  run grep -F 'git rev-parse HEAD' "${UPGRADE}"
  assert_success
}
