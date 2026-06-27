#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"
# ════════════════════════════════════════════════════════════════════
# .env.generated cache + .env workload overlay (A2 file roles,)
# ════════════════════════════════════════════════════════════════════

@test "apply writes the derived cache to .env.generated (not .env)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated" ]
  run grep -E '^SETUP_CONF_HASH=' "${TEMP_DIR}/.env.generated"
  assert_success
}

@test "apply scaffolds a .env workload overlay when absent" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  refute [ -f "${TEMP_DIR}/.env" ]
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env" ]
  # Scaffold carries guidance, not derived values (no SETUP_* metadata).
  run grep -E '^SETUP_CONF_HASH=' "${TEMP_DIR}/.env"
  assert_failure
}

@test "apply does NOT overwrite an existing hand-authored .env overlay" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  printf 'ROS_DOMAIN_ID=42\n' > "${TEMP_DIR}/.env"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run cat "${TEMP_DIR}/.env"
  assert_output "ROS_DOMAIN_ID=42"
}

@test "apply migrates a legacy .env cache to .env.generated + backs it up" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  # layout: .env IS the cache (carries the auto-gen marker) and
  # .env.generated does not exist yet.
  cat > "${TEMP_DIR}/.env" <<'EOF'
IMAGE_NAME=legacycache
SETUP_CONF_HASH=deadbeef
EOF
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  # The stale cache is backed up and a fresh derived cache is written.
  assert [ -f "${TEMP_DIR}/.env.bak" ]
  run grep -E '^IMAGE_NAME=legacycache$' "${TEMP_DIR}/.env.bak"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated" ]
  # .env is no longer the cache: it is the scaffolded overlay (no marker).
  run grep -E '^SETUP_CONF_HASH=' "${TEMP_DIR}/.env"
  assert_failure
}

@test "_scaffold_env_overlay is idempotent (never overwrites)" {
  printf 'USER_KEY=keep\n' > "${TEMP_DIR}/.env"
  run _scaffold_env_overlay "${TEMP_DIR}/.env"
  assert_success
  run cat "${TEMP_DIR}/.env"
  assert_output "USER_KEY=keep"
}

@test "apply emits env_file: - .env on the devel service (#502 overlay)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run grep -A1 -E '^    env_file:' "${TEMP_DIR}/compose.yaml"
  assert_success
  assert_output --partial "- .env"
}

# ════════════════════════════════════════════════════════════════════
# .Dockerfile.generated: [environment] baked as runtime-stage ENV (S3,)
# ════════════════════════════════════════════════════════════════════

@test "_yaml_dq wraps a value as a double-quoted scalar, escaping \\ then \" (#698)" {
  # The compose environment: sink routes each entry through _yaml_dq so a
  # value with YAML-structural chars survives the parse as one string. The
  # escape order is backslash first, then double-quote (so an embedded \"
  # is not double-escaped).
  local _out=""
  _yaml_dq 'MSG=a: b' _out
  [ "${_out}" = '"MSG=a: b"' ]
  _yaml_dq 'Q=a"b\c' _out
  [ "${_out}" = '"Q=a\"b\\c"' ]
  _yaml_dq 'GLOB=*' _out
  [ "${_out}" = '"GLOB=*"' ]
}

# ════════════════════════════════════════════════════════════════════
# config/app/ structured app-config dev bind-mount (S4,)
# ════════════════════════════════════════════════════════════════════

@test "apply dev-binds config/app/ into the devel service when present (#504)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  mkdir -p "${TEMP_DIR}/config/app"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run grep -F './config/app:/opt/app/config' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "apply omits the config/app bind when the directory is absent (#504)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run grep -F '/opt/app/config' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "main reset --yes works on first-time bootstrap (no prior .local or setup.conf) (#174)" {
  rm -f "${TEMP_DIR}/config/docker/setup.conf" "${TEMP_DIR}/config/docker/setup.conf"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  # First-time bootstrap is a no-op: no override existed, no snapshot
  # existed, so nothing to clear and no .bak files written.
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
}

# ════════════════════════════════════════════════════════════════════
# _rule_basename
# ════════════════════════════════════════════════════════════════════

@test "_rule_basename returns last non-empty path component" {
  result="$(_rule_basename "/home/user/my_project")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename skips trailing slashes" {
  result="$(_rule_basename "/home/user/my_project/")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename handles single-component path" {
  result="$(_rule_basename "justname")"
  assert_equal "${result}" "justname"
}

@test "detect_image_name uses @basename rule alone (exercises _rule_basename)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plainname"
  assert_equal "${_result}" "plainname"
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name sanitization
#
# docker compose project names + image tags forbid '.' and anything
# outside [a-z0-9_-]. detect_image_name must normalise whatever the
# rules produce so downstream `docker compose -p <name>` doesn't
# reject the generated project name.
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name replaces '.' with '-' (regression: tmp.abcdef → tmp-abcdef)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/tmp.abcdef"
  assert_equal "${_result}" "tmp-abcdef"
}

@test "detect_image_name collapses runs of '-' and strips leading/trailing separators" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/..weird..name.."
  [[ "${_result}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
  assert_equal "${_result}" "weird-name"
}

# ════════════════════════════════════════════════════════════════════
# i18n
# ════════════════════════════════════════════════════════════════════

@test "_setup_msg returns English messages by default" {
  _LANG="en"
  [[ "$(_setup_msg env "done")" =~ updated ]]
}

@test "_setup_msg returns Traditional Chinese messages when _LANG=zh-TW" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env "done")" =~ 更新完成 ]]
}

@test "_setup_msg returns Simplified Chinese messages when _LANG=zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env "done")" =~ 更新完成 ]]
}

@test "_setup_msg returns Japanese messages when _LANG=ja" {
  _LANG="ja"
  [[ "$(_setup_msg env "done")" =~ 更新完了 ]]
}

# Exercise every (key, language) branch so kcov sees the zh-CN / ja / default
# `unknown_arg` and `env_comment` case-arms. The env_done-only tests above
# only land on the first case of each language block.

@test "_setup_msg env_comment and unknown_arg are defined in zh" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env comment)" =~ 自動偵測 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 未知參數 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env comment)" =~ 自动检测 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 未知参数 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in ja" {
  _LANG="ja"
  [[ "$(_setup_msg env comment)" =~ 自動検出 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 不明な引数 ]]
}

@test "_msg falls back to English when _LANG is unknown" {
  _LANG="xx"
  [[ "$(_setup_msg env "done")" =~ updated ]]
  [[ "$(_setup_msg env comment)" =~ Auto-detected ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ "Unknown argument" ]]
}

# ════════════════════════════════════════════════════════════════════
# [build] section (arg_N KEY=VALUE schema)
# ════════════════════════════════════════════════════════════════════

@test "[build] template defaults ship TW mirrors via arg_N" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env.generated'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=tw.archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=mirror.twds.com.tw"
}

@test "[build] arg_N override replaces TW default when set" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build arg_1 \
    "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build arg_2 \
    "APT_MIRROR_DEBIAN=deb.debian.org"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env.generated'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=deb.debian.org"
}

@test "[build] back-compat: old apt_mirror_* named keys still read" {
  # Legacy repo setup.conf with the pre-arg_N schema must keep working
  # so users can upgrade template without rewriting setup.conf first.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[build]
apt_mirror_ubuntu = mirror.example.com
tz = Asia/Tokyo
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env.generated'
    grep '^TZ=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=mirror.example.com"
  assert_output --partial "TZ=Asia/Tokyo"
}

@test "[build] user-added arg_N propagates to .env" {
  # Dockerfile with `ARG PYTHON_VERSION` can pick up a user-added
  # build arg. Extra args land in .env so compose build.args can
  # reference them.
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build arg_9 \
    "PYTHON_VERSION=3.12"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^PYTHON_VERSION=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "PYTHON_VERSION=3.12"
}

@test "[build] target_arch = arm64 writes TARGET_ARCH to .env" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build target_arch arm64
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^TARGET_ARCH=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "TARGET_ARCH=arm64"
}

@test "[build] target_arch empty omits TARGET_ARCH from .env" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  # Explicit empty value (the template's default)
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build target_arch ""
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^TARGET_ARCH=' '${TEMP_DIR}/.env.generated'
  "
  # grep -c prints "0" and exits 1 when pattern missing; we want exactly that.
  assert_failure
  assert_output "0"
}

@test "[build] network = host writes BUILD_NETWORK to .env" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build network host
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^BUILD_NETWORK=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "BUILD_NETWORK=host"
}

@test "[build] network empty omits BUILD_NETWORK from .env" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build network ""
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^BUILD_NETWORK=' '${TEMP_DIR}/.env.generated'
  "
  assert_failure
  assert_output "0"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_list_sorted skips empty values
# ════════════════════════════════════════════════════════════════════

@test "_get_conf_list_sorted skips entries with empty value" {
  local -a _k=("mount_1" "mount_2" "mount_3") _v=("" "/b:/b" "")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "1"
  assert_equal "${_out[0]}" "/b:/b"
}

# ════════════════════════════════════════════════════════════════════
# Workspace writeback (first-time / user edit / opt-out)
# ════════════════════════════════════════════════════════════════════

@test "workspace first-time: writes \${WS_PATH} variable form (portable)" {
  # Regression (v0.9.4): writeback used to bake the absolute host path
  # into setup.conf. Committing that file broke other machines whose
  # filesystem layout differed. Now we write the \${WS_PATH} variable
  # form so docker-compose resolves it per-machine from .env.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
  "
  assert_success
  assert [ -f "${_repo}/config/docker/setup.conf" ]
  run grep '^mount_1' "${_repo}/config/docker/setup.conf"
  assert_output --partial '${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: \${WS_PATH} form re-detects per machine" {
  # Round-trip: first-time writes \${WS_PATH} form → second run reads
  # setup.conf, sees the variable reference, and re-runs detect_ws_path
  # so WS_PATH in .env reflects THIS machine (not the one that first
  # committed the file).
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env.generated'
    grep '^mount_1' '${_repo}/config/docker/setup.conf'
  "
  assert_success
  # WS_PATH is a non-empty absolute path — exact value depends on the
  # sandbox, but it must not be the literal variable string.
  refute_output --partial 'WS_PATH=${WS_PATH}'
  assert_output --regexp 'WS_PATH=/[^[:space:]]+'
  # mount_1 stays as the portable variable form.
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: respects user-pinned absolute path via setup.conf (#174)" {
  local _repo="${TEMP_DIR}/repo"
  local _pin="${TEMP_DIR}/custom_ws"
  mkdir -p "${_repo}" "${_pin}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # user pins go into the override file (.local), not the
  # materialized snapshot.
  cat > "${_repo}/config/docker/setup.conf" <<EOF
[volumes]
mount_1 = ${_pin}:/home/\${USER_NAME}/work
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env.generated'
    grep '^mount_1' '${_repo}/config/docker/setup.conf'
  "
  assert_success
  # Effective WS_PATH on this machine is the user-pinned absolute path.
  assert_output --partial "WS_PATH=${_pin}"
  # The override file (.local) keeps the pinned form verbatim — apply
  # doesn't rewrite user intent.
  assert_output --partial "mount_1 = ${_pin}:"
}

@test "workspace second-run: stale setup.conf path is harmlessly overwritten (#174)" {
  # setup.conf was tracked → cross-machine clones inherited
  # alice's absolute path on bob's checkout, forcing setup.sh to
  # detect-and-rewrite. setup.conf is gitignored + a derived
  # snapshot, so the only way a "stale" path lands is a manual edit
  # between applies. Apply now silently regenerates setup.conf from
  # template + .local (which contain the portable form) — no warning
  # needed, the stale value is gone after one apply.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  sed -i 's|^mount_1.*|mount_1 = /nonexistent/stale/ws:/home/${USER_NAME}/work|' \
    "${_repo}/config/docker/setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env.generated'
  "
  assert_success
  # Stale path does not leak into .env (apply regenerates from .local +
  # template + fresh ws_path detection, ignoring the manually-mutated
  # setup.conf entry for [volumes]).
  refute_output --partial "WS_PATH=/nonexistent/stale/ws"
}

@test "fresh bootstrap: empty dir + main apply emits workspace mount in compose.yaml (#201 regression)" {
  # bug: bootstrap wrote mount_1 to <repo>/config/docker/setup.conf, then
  # immediately reloaded via _load_setup_conf which only consulted
  # setup.conf.local (empty) + template (empty mount_1). The just-written
  # value was lost and compose.yaml omitted the workspace mount.
  # (2-file model): bootstrap writes to <repo>/config/docker/setup.conf and
  # _load_setup_conf reads from the same file, so the reload picks up
  # the freshly-written mount_1.
  local _repo="${TEMP_DIR}/fresh"
  mkdir -p "${_repo}"
  unset SETUP_CONF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
  "
  assert_success
  # compose.yaml contains the workspace mount line (portable form)
  run grep -F -- '${WS_PATH}:/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_success
}

@test "workspace opt-out: cleared mount_1 means no workspace mount in compose" {
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # User clears mount_1 (opt-out)
  sed -i 's|^mount_1.*|mount_1 =|' "${_repo}/config/docker/setup.conf"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # mount_1 stays empty (not re-populated)
  run grep '^mount_1' "${_repo}/config/docker/setup.conf"
  assert_equal "${output}" "mount_1 ="
  # compose.yaml has no workspace mount
  run grep ':/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name string rule
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name string:<value> short-circuits path parsing" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = string:my_app
rule_2 = prefix:docker_
rule_3 = @default:should_not_reach
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/docker_something"
  assert_equal "${_result}" "my_app"
}

@test "detect_image_name string value is still lowercased + sanitized" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = string:My.App.Name
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/whatever"
  assert_equal "${_result}" "my-app-name"
}

# ════════════════════════════════════════════════════════════════════
# — --quiet flag + success confirmation output
# ════════════════════════════════════════════════════════════════════

@test "setup.sh set: prints 3-line confirmation by default" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output --partial "[setup] set [build] arg_4 = ROS2_DISTRO=jazzy"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh set --quiet: produces empty stdout" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set --quiet --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output ""
}

@test "setup.sh set -q: short form also suppresses output" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set -q --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output ""
}

@test "setup.sh set --quiet: still writes the value (mutation not skipped)" {
  bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set --quiet --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  run cat "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
  assert_output --partial "arg_4 = ROS2_DISTRO=jazzy"
}

@test "setup.sh add: prints 3-line confirmation by default" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main add --base-path '${TEMP_DIR}' build.arg HARDWARE=arm64
  "
  assert_success
  assert_output --partial "[setup] add [build] arg_"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh add --quiet: produces empty stdout" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main add --quiet --base-path '${TEMP_DIR}' build.arg HARDWARE=arm64
  "
  assert_success
  assert_output ""
}

@test "setup.sh remove: prints 3-line confirmation by default" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<EOC
[build]
arg_1 = HARDWARE=arm64
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main remove --base-path '${TEMP_DIR}' build.arg_1
  "
  assert_success
  assert_output --partial "[setup] remove [build] arg_1"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh remove --quiet: produces empty stdout" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<EOC
[build]
arg_1 = HARDWARE=arm64
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main remove --quiet --base-path '${TEMP_DIR}' build.arg_1
  "
  assert_success
  assert_output ""
}

@test "setup.sh reset --yes: prints next: hint and file: by default" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main reset --yes --base-path '${TEMP_DIR}'
  "
  assert_success
  assert_output --partial "[setup]"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh reset --yes --quiet: produces empty stdout" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main reset --yes --quiet --base-path '${TEMP_DIR}'
  "
  assert_success
  assert_output ""
}

@test "setup.sh apply --quiet: suppresses the env_done + USER=... summary" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --quiet --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  refute_output --partial "[setup] USER="
}

# ════════════════════════════════════════════════════════════════════
# setup.sh apply CLI flags (--gui / --no-x11-cookie / --print-resolved)
# ════════════════════════════════════════════════════════════════════

@test "apply --gui off overrides [gui] mode via print-resolved (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force
EOF
  # Baseline: mode=force resolves GUI_ENABLED=true regardless of host
  # GUI detection.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
  # CLI override flips GUI to off, ignoring setup.conf.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui off --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
}

@test "apply --gui=force enables GUI even when setup.conf says off (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = off
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui=force --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
}

@test "apply --gui rejects values outside auto|force|off (#338)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui bogus 2>&1
  "
  assert_failure
  assert_output --partial "Invalid value"
}

@test "apply --print-resolved prints KEY=VALUE state without writing .env (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = off
[deploy]
gpu_mode = off
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  # Expected resolved lines
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
  assert_output --partial "GPU_MODE=off"
  assert_output --partial "GPU_ENABLED=false"
  # And NO file was written.
  [[ ! -f "${TEMP_DIR}/.env.generated" ]]
  [[ ! -f "${TEMP_DIR}/compose.yaml" ]]
}

@test "apply --print-resolved respects --gui override in the dump (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SETUP_DETECT_JETSON=false main apply --base-path '${TEMP_DIR}' --gui force --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
}

@test "apply --no-x11-cookie records X11_COOKIE_SKIP=1 in print-resolved (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --no-x11-cookie --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "X11_COOKIE_SKIP=1"
}

@test "apply without --no-x11-cookie records X11_COOKIE_SKIP=0 (default) (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "X11_COOKIE_SKIP=0"
}

@test "apply SETUP_GUI env var overrides setup.conf when --gui not passed (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SETUP_GUI=off main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
}

@test "apply --gui CLI wins over SETUP_GUI env var (resolution order CLI > env) (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SETUP_GUI=off main apply --base-path '${TEMP_DIR}' --gui force --print-resolved 2>/dev/null
  "
  assert_success
  # CLI --gui force wins
  assert_output --partial "GUI_MODE=force"
}

# ════════════════════════════════════════════════════════════════════
# P2: propagation + non-privileged guard
# ════════════════════════════════════════════════════════════════════

@test "apply warns when device propagation used without privileged (#450 P2)" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOC'
[security]
privileged = false
[devices]
device_1 = /dev:/dev:rslave
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  assert_output --partial "propagation"
  assert_output --partial "privileged"
}

@test "apply suppresses propagation warning when privileged is true (#450 P2)" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOC'
[security]
privileged = true
[devices]
device_1 = /dev:/dev:rslave
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  refute_output --partial "propagation"
}

# ════════════════════════════════════════════════════════════════════
# P4: duplicate device/volume target path detection
# ════════════════════════════════════════════════════════════════════

@test "apply warns when device and volume have same target path (#450 P4)" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOC'
[devices]
device_1 = /dev:/dev:rslave
[volumes]
mount_5 = /dev:/dev
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  assert_output --partial "duplicate"
}

@test "apply does NOT warn duplicate when device and volume targets differ (#450 P4)" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOC'
[devices]
device_1 = /dev:/dev:rslave
[volumes]
mount_5 = /data:/data
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  refute_output --partial "duplicate"
}

# ════════════════════════════════════════════════════════════════════
# S7: runtime.env retired. apply no longer emits it; [environment]
# still reaches compose.yaml (and is baked as ENV for the field via S3).
# ════════════════════════════════════════════════════════════════════

@test "apply no longer emits runtime.env; [environment] still lands in compose.yaml (#507)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOC'
[environment]
env_1 = FOO=bar
env_2 = BAR=${FOO}_x
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # runtime.env is retired -- it must NOT be created.
  assert [ ! -f "${TEMP_DIR}/runtime.env" ]
  # The resolved (cross-ref expanded) values still reach compose.yaml.
  run grep -F 'BAR=bar_x' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "_write_runtime_env is removed (#507)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    declare -F _write_runtime_env
  "
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _reconcile_workspace_path — the WS_PATH / mount_1 reconciliation
# state machine extracted from _setup_apply into a testable seam. The 4
# (+empty) branches become direct unit tests instead of being reachable
# only through a full apply. detect_ws_path is deterministic here: with no
# *_ws sibling on the fixture path it falls back to base_path itself.
# ════════════════════════════════════════════════════════════════════

@test "_reconcile_workspace_path: portable form detects WS_PATH locally, mount_1 untouched (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}/config/docker"
  # shellcheck disable=SC2016  # literal ${WS_PATH} is the portable form stored in setup.conf
  printf '[volumes]\nmount_1 = ${WS_PATH}:/home/${USER_NAME}/work\n' \
    > "${_base}/config/docker/setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_base}/config/docker/setup.conf" _vk _vv _ws
  # detect_ws_path fallback = base_path itself = ${_base}.
  assert_equal "${_ws}" "$(cd "${_base}" && pwd -P)"
  # mount_1 stays the portable form (no rewrite).
  run cat "${_base}/config/docker/setup.conf"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
}

@test "_reconcile_workspace_path: absolute existing host path is honored as WS_PATH (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}/config/docker"
  local _pinned="${TEMP_DIR}/pinned_ws"
  mkdir -p "${_pinned}"
  printf '[volumes]\nmount_1 = %s:/work\n' "${_pinned}" \
    > "${_base}/config/docker/setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_base}/config/docker/setup.conf" _vk _vv _ws
  assert_equal "${_ws}" "${_pinned}"
  # conf untouched (absolute path honored, not rewritten).
  run cat "${_base}/config/docker/setup.conf"
  assert_output --partial "mount_1 = ${_pinned}:/work"
}

@test "_reconcile_workspace_path: stale absolute path warns + rewrites mount_1 to portable (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}/config/docker"
  printf '[volumes]\nmount_1 = /nonexistent/contributor-a/repo:/work\n' \
    > "${_base}/config/docker/setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  run _reconcile_workspace_path "${_base}" "${_base}/config/docker/setup.conf" _vk _vv _ws
  assert_success
  assert_output --partial "stale"
  # mount_1 migrated back to the portable form.
  run cat "${_base}/config/docker/setup.conf"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
  refute_output --partial "/nonexistent/contributor-a/repo"
}

@test "_reconcile_workspace_path: empty mount_1 detects WS_PATH only, conf untouched (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}/config/docker"
  printf '[volumes]\nmount_1 =\n' > "${_base}/config/docker/setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_base}/config/docker/setup.conf" _vk _vv _ws
  assert_equal "${_ws}" "$(cd "${_base}" && pwd -P)"
  run cat "${_base}/config/docker/setup.conf"
  assert_output --partial "mount_1 ="
}

@test "_reconcile_workspace_path: first-time bootstrap copies template + writes portable mount_1 (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}"
  local _repo_conf="${_base}/config/docker/setup.conf"
  # No repo conf yet -> bootstrap from the real template.
  [ ! -f "${_repo_conf}" ]
  local -a _vk=() _vv=()
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_repo_conf}" _vk _vv _ws
  # template was copied into place + mount_1 written portable.
  assert [ -f "${_repo_conf}" ]
  run cat "${_repo_conf}"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
  assert_equal "${_ws}" "$(cd "${_base}" && pwd -P)"
}
