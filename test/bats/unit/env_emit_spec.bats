#!/usr/bin/env bats
#
# why: Mirrors `lib/env_emit.sh`. `write_env` (.env contents + SETUP_*
# metadata, SSH X11 `XAUTHORITY` override #321) and `_scaffold_env_overlay`
# idempotency.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# write_env: SSH X11 XAUTHORITY override
# ════════════════════════════════════════════════════════════════════
@test "write_env emits XAUTHORITY=<rewritten> when _ssh_x11_xauth arg is set (#321)" {
  local _env="${TEMP_DIR}/.env.generated"
  # Pass all positional args incl. the new trailing _ssh_x11_xauth.
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    "/path/to/.docker.xauth"
  assert [ -f "${_env}" ]
  run grep -F 'XAUTHORITY=/path/to/.docker.xauth' "${_env}"
  assert_success
  run grep -F 'SSH X11 forwarding cookie override' "${_env}"
  assert_success
}

@test "write_env does NOT emit XAUTHORITY override when _ssh_x11_xauth arg is empty (#321)" {
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    ""
  assert [ -f "${_env}" ]
  run cat "${_env}"
  refute_output --partial "SSH X11 forwarding cookie override"
  refute_output --partial $'\nXAUTHORITY='
}

# ════════════════════════════════════════════════════════════════════
# write_env
# ════════════════════════════════════════════════════════════════════
@test "write_env creates .env with all required variables and SETUP_* metadata" {
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    "testuser" "testgroup" "1001" "1001" \
    "x86_64" "dockerhub" "true" \
    "ros_noetic" "/workspace" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" \
    "all" "gpu" \
    "true" "abc123" "df456"

  assert [ -f "${_env}" ]
  run grep 'USER_NAME=testuser' "${_env}"; assert_success
  run grep 'USER_UID=1001'      "${_env}"; assert_success
  run grep 'GPU_ENABLED=true'   "${_env}"; assert_success
  run grep 'IMAGE_NAME=ros_noetic' "${_env}"; assert_success
  run grep 'NETWORK_MODE=host'  "${_env}"; assert_success
  run grep 'IPC_MODE=host'      "${_env}"; assert_success
  run grep 'PID_MODE=private'   "${_env}"; assert_success
  run grep 'PRIVILEGED=true'    "${_env}"; assert_success
  run grep 'GPU_COUNT=all'      "${_env}"; assert_success
  run grep -F 'GPU_CAPABILITIES="gpu"' "${_env}"; assert_success
  run grep 'SETUP_CONF_HASH=abc123' "${_env}"; assert_success
  run grep 'SETUP_DOCKERFILE_HASH=df456' "${_env}"; assert_success
  run grep 'SETUP_GUI_DETECTED=true' "${_env}"; assert_success
  run grep -E '^SETUP_TIMESTAMP=' "${_env}"; assert_success
  run grep 'APT_MIRROR_UBUNTU=tw.archive.ubuntu.com' "${_env}"; assert_success
  run grep 'APT_MIRROR_DEBIAN=mirror.twds.com.tw' "${_env}"; assert_success
  run grep 'TZ=Asia/Taipei' "${_env}"; assert_success
  # bash-source round-trip: re-loading the file must not raise a
  # "command not found" on any multi-word value (regression: previously
  # GPU_CAPABILITIES="gpu compute utility graphics" was unquoted).
  run bash -c "set -o allexport; source '${_env}'"
  assert_success
  refute_output --partial "command not found"
}

# ════════════════════════════════════════════════════════════════════
# .env.local -- the operator's override file (never touched by tooling)
# ════════════════════════════════════════════════════════════════════
@test "_scaffold_env_local is idempotent (never overwrites) (#868)" {
  printf 'USER_KEY=keep\n' > "${TEMP_DIR}/.env.local"
  run _scaffold_env_local "${TEMP_DIR}/.env.local"
  assert_success
  run cat "${TEMP_DIR}/.env.local"
  assert_output "USER_KEY=keep"
}

# ════════════════════════════════════════════════════════════════════
# write_env: the deferred project rename
# ════════════════════════════════════════════════════════════════════
@test "write_env emits PROJECT_NAME_PENDING only when a rename is deferred (#920)" {
  # PROJECT_NAME is the name the checkout RUNS under; the pending one is
  # what its configuration now resolves to but cannot take effect as until
  # the old project is empty. An ordinary file carries no such line.
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    "" "local-myrepo" "alice-myrepo"
  run grep -Fx 'PROJECT_NAME=local-myrepo' "${_env}"
  assert_success
  run grep -Fx 'PROJECT_NAME_PENDING=alice-myrepo' "${_env}"
  assert_success

  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    "" "alice-myrepo"
  run grep -Fx 'PROJECT_NAME=alice-myrepo' "${_env}"
  assert_success
  run grep -c '^PROJECT_NAME_PENDING=' "${_env}"
  assert_failure
}

@test "_scaffold_env_local creates a comment-only override file naming .env (#868)" {
  run _scaffold_env_local "${TEMP_DIR}/.env.local"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.local" ]
  run cat "${TEMP_DIR}/.env.local"
  assert_output --partial ".env"
  # Comment-only: nothing here may look like a setting the user did not write.
  run grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "${TEMP_DIR}/.env.local"
  assert_output "0"
}

# ════════════════════════════════════════════════════════════════════
# write_container_env -- the generated, shipped `.env`
# ════════════════════════════════════════════════════════════════════
@test "write_container_env emits the [environment] defaults it is given (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" $'ROS_DOMAIN_ID=42\nLOG_LEVEL=debug' ""
  assert [ -f "${_out}" ]
  run grep -xF "ROS_DOMAIN_ID='42'" "${_out}"; assert_success
  run grep -xF "LOG_LEVEL='debug'"  "${_out}"; assert_success
}

@test "write_container_env emits the WATCHDOG_* block into .env, not compose (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" "" \
    $'WATCHDOG_CHECK=pgrep -f my_node\nWATCHDOG_INTERVAL=30'
  run grep -xF "WATCHDOG_CHECK='pgrep -f my_node'" "${_out}"; assert_success
  run grep -xF "WATCHDOG_INTERVAL='30'"            "${_out}"; assert_success
}

@test "write_container_env marks the file as ours and names .env.local (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" "" ""
  assert [ -f "${_out}" ]
  run cat "${_out}"
  assert_output --partial "Auto-generated"
  assert_output --partial ".env.local"
}

@test "write_container_env rewrites the file on every call (it is ours) (#868)" {
  local _out="${TEMP_DIR}/.env"
  printf 'STALE=yes\n' > "${_out}"
  write_container_env "${_out}" "FRESH=yes" ""
  run grep -qxF 'STALE=yes' "${_out}"; assert_failure
  run grep -xF "FRESH='yes'" "${_out}"; assert_success
}

@test "write_container_env expands cross-references against the interpolation cache (#868)" {
  local _cache="${TEMP_DIR}/.env.generated"
  printf 'WS_PATH=/home/dev/ws\n' > "${_cache}"
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" 'ROS_LOG_DIR=${WS_PATH}/log' "" "${_cache}"
  run grep -xF "ROS_LOG_DIR='/home/dev/ws/log'" "${_out}"
  assert_success
}

# `${VAR}` cross-reference expansion. Moved here from gen_spec.bats with
# the code: compose's own substitution layer never saw sibling environment
# entries, and now that the list is written to an env_file -- whose values
# compose takes LITERALLY -- expanding at write time is the only chance.
@test "write_container_env expands a cross-reference to an earlier sibling (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" \
    $'BUILD_TARGET=production\nLD_LIBRARY_PATH=/foo/${BUILD_TARGET}/lib' ""
  run grep -xF "LD_LIBRARY_PATH='/foo/production/lib'" "${_out}"
  assert_success
  run grep -F 'BUILD_TARGET}' "${_out}"
  assert_failure
}

@test "write_container_env leaves a forward reference literal (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" \
    $'LD_LIBRARY_PATH=/foo/${BUILD_TARGET}/lib\nBUILD_TARGET=production' ""
  run grep -xF 'LD_LIBRARY_PATH=${BUILD_TARGET}' "${_out}"
  assert_failure
  run grep -xF "LD_LIBRARY_PATH='/foo/\${BUILD_TARGET}/lib'" "${_out}"
  assert_success
  run grep -xF "BUILD_TARGET='production'" "${_out}"
  assert_success
}

@test "write_container_env leaves an unknown reference literal (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" 'PATH_PREFIX=/foo/${UNDEFINED_VAR}/bar' ""
  run grep -xF "PATH_PREFIX='/foo/\${UNDEFINED_VAR}/bar'" "${_out}"
  assert_success
}

@test "write_container_env expands multiple references in one value (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" \
    $'BUILD_TARGET=production\nARCH=aarch64\nPLUGIN_PATH=/opt/${BUILD_TARGET}/lib/${ARCH}' ""
  run grep -xF "PLUGIN_PATH='/opt/production/lib/aarch64'" "${_out}"
  assert_success
}

@test "write_container_env resolves a transitive reference chain (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" \
    $'ROOT=/opt\nBASE=${ROOT}/lib\nINCLUDE=${BASE}/include' ""
  run grep -xF "BASE='/opt/lib'" "${_out}"
  assert_success
  run grep -xF "INCLUDE='/opt/lib/include'" "${_out}"
  assert_success
}

# Env-file quoting. The values used to land in a compose `environment:`
# list, where a YAML double-quoted scalar protected them. An env_file is a
# different parser with its own hazards -- an unquoted value is truncated
# at an inline ` #`, and a double-quoted one has its `${VAR}` expanded --
# so every value is emitted as a quoted scalar with `\`, `"` and `$`
# escaped. Silent truncation of a token or a check command is exactly the
# class of failure a field operator cannot diagnose.
@test "write_container_env quotes a value carrying an inline ' #' (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" 'NOTE=a #b' ""
  run grep -xF "NOTE='a #b'" "${_out}"
  assert_success
}

@test "write_container_env quotes a value carrying a colon-space (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" 'MSG=a: b' ""
  run grep -xF "MSG='a: b'" "${_out}"
  assert_success
}

@test "write_container_env passes a double quote and a backslash through (#868)" {
  # Neither is special to the single-quoted form, and the parser does NOT
  # unescape a doubled backslash -- doubling one would ADD a character.
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" 'Q=a"b\c' ""
  run grep -xF "Q='a\"b\\c'" "${_out}"
  assert_success
}

@test "write_container_env escapes the delimiter inside a value (#868)" {
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" "NOTE=it's fine" ""
  run grep -xF "NOTE='it\\'s fine'" "${_out}"
  assert_success
}

@test "write_container_env keeps \$ literal, unexpanded (#868)" {
  # A double-quoted env_file value is variable-expanded and `\$` does not
  # stop it, so the single-quoted form is what keeps the reference intact.
  local _out="${TEMP_DIR}/.env"
  write_container_env "${_out}" "" 'WATCHDOG_NOTIFY=echo $HOSTNAME'
  run grep -xF "WATCHDOG_NOTIFY='echo \$HOSTNAME'" "${_out}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _migrate_env_to_local -- a hand-written .env predates the naming rule
# ════════════════════════════════════════════════════════════════════
@test "_migrate_env_to_local renames a hand-written .env to .env.local (#868)" {
  printf '# mine\nROS_DOMAIN_ID=7\n' > "${TEMP_DIR}/.env"
  run _migrate_env_to_local "${TEMP_DIR}"
  assert_success
  assert [ ! -e "${TEMP_DIR}/.env" ]
  run cat "${TEMP_DIR}/.env.local"
  assert_output --partial "ROS_DOMAIN_ID=7"
}

@test "_migrate_env_to_local is inert on a second run (#868)" {
  printf 'ROS_DOMAIN_ID=7\n' > "${TEMP_DIR}/.env"
  _migrate_env_to_local "${TEMP_DIR}"
  printf 'REGENERATED=1\n' > "${TEMP_DIR}/.env"
  run _migrate_env_to_local "${TEMP_DIR}"
  assert_success
  # The user's file is not clobbered by the regenerated one.
  run cat "${TEMP_DIR}/.env.local"
  assert_output --partial "ROS_DOMAIN_ID=7"
  refute_output --partial "REGENERATED=1"
  assert [ -f "${TEMP_DIR}/.env" ]
}

@test "_migrate_env_to_local leaves a generated .env alone (#868)" {
  printf '# Auto-generated by setup.sh on 2026-01-01 00:00:00\nFOO=bar\n' \
    > "${TEMP_DIR}/.env"
  run _migrate_env_to_local "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env" ]
  assert [ ! -e "${TEMP_DIR}/.env.local" ]
}

@test "_migrate_env_to_local leaves a comment-only scaffold alone (#868)" {
  printf '# Workload overlay -- hand-authored, gitignored.\n#\n' \
    > "${TEMP_DIR}/.env"
  run _migrate_env_to_local "${TEMP_DIR}"
  assert_success
  assert [ ! -e "${TEMP_DIR}/.env.local" ]
}

@test "_migrate_env_to_local is a no-op when there is no .env (#868)" {
  run _migrate_env_to_local "${TEMP_DIR}"
  assert_success
  assert [ ! -e "${TEMP_DIR}/.env.local" ]
}

@test "_migrate_env_to_local stages the removal when .env was git-tracked (#868)" {
  git -C "${TEMP_DIR}" init -q
  git -C "${TEMP_DIR}" config user.email t@t
  git -C "${TEMP_DIR}" config user.name t
  printf 'ROS_DOMAIN_ID=7\n' > "${TEMP_DIR}/.env"
  git -C "${TEMP_DIR}" add -f .env
  git -C "${TEMP_DIR}" commit -q -m "tracked env"
  run _migrate_env_to_local "${TEMP_DIR}"
  assert_success
  run git -C "${TEMP_DIR}" diff --cached --name-status
  assert_output --partial "D	.env"
  run cat "${TEMP_DIR}/.env.local"
  assert_output --partial "ROS_DOMAIN_ID=7"
}
