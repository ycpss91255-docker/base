#!/usr/bin/env bats
#
# Unit tests for script/docker/run.sh argument handling and control flow.
# See build_sh_spec.bats for the sandbox/mock strategy — this file mirrors it
# and focuses on run.sh-specific branches: --detach, --instance, TARGET
# routing (devel vs non-devel), already-running guard, and bootstrap/drift.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/template/script/docker"

  cp /source/script/docker/_lib.sh  "${SANDBOX}/template/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh  "${SANDBOX}/template/script/docker/i18n.sh"
  # Symlink (not copy) so kcov attributes coverage to /source/script/docker/run.sh.
  ln -s /source/script/docker/run.sh "${SANDBOX}/run.sh"

  MOCK_SETUP_LOG="${TEMP_DIR}/setup.log"
  export MOCK_SETUP_LOG

  cat > "${SANDBOX}/template/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  _base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-path) _base="$2"; shift 2 ;;
      --lang)      shift 2 ;;
      *)           shift ;;
    esac
  done
  printf 'setup.sh invoked --base-path %s\n' "${_base}" >> "${MOCK_SETUP_LOG}"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${_base}/.env"
  echo "# mock compose" > "${_base}/compose.yaml"
else
  _check_setup_drift() { :; }
fi
EOS
  chmod +x "${SANDBOX}/template/script/docker/setup.sh"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  # docker stub: `docker ps` reads from DOCKER_PS_FILE so individual tests
  # can simulate a running container; everything else is a no-op.
  DOCKER_PS_FILE="${TEMP_DIR}/docker_ps.out"
  export DOCKER_PS_FILE
  : > "${DOCKER_PS_FILE}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_FILE}"
  exit 0
fi
printf 'docker'
printf ' %q' "$@"
printf '\n'
EOS
  chmod +x "${BIN_DIR}/docker"

  cat > "${BIN_DIR}/xhost" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${BIN_DIR}/xhost"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

@test "run.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/run.sh" --help
  assert_success
  assert_output --partial "run.sh"
}

@test "run.sh --setup forces setup.sh to run" {
  run bash "${SANDBOX}/run.sh" --setup --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh -s short flag triggers setup.sh" {
  run bash "${SANDBOX}/run.sh" -s --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh bootstraps setup.sh when .env is missing" {
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${SANDBOX}/.env" ]
}

@test "run.sh skips setup.sh when .env AND setup.conf AND compose.yaml exist (drift-check path)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  refute_output --partial "First run"
  assert [ ! -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh bootstraps setup.sh when setup.conf is missing (even if .env exists)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  rm -f "${SANDBOX}/setup.conf"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh bootstraps setup.sh when compose.yaml is missing (fresh clone)" {
  # Regression (v0.9.2): compose.yaml is gitignored since v0.9.0, so
  # a fresh clone lands here with .env / setup.conf present but no
  # compose.yaml. That case must also bootstrap.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/setup.conf"
  rm -f "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ -f "${SANDBOX}/compose.yaml" ]
}

@test "run.sh bootstrap calls setup.sh directly, not setup_tui.sh" {
  # Regression (v0.9.2): bootstrap used to launch setup_tui.sh on a
  # TTY; user cancelling left the repo with no .env. Bootstrap must
  # always be non-interactive.
  cat > "${SANDBOX}/setup_tui.sh" <<'EOS'
#!/usr/bin/env bash
echo "TUI_INVOKED" >> "${MOCK_SETUP_LOG}.tui"
exit 0
EOS
  chmod +x "${SANDBOX}/setup_tui.sh"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ ! -f "${MOCK_SETUP_LOG}.tui" ]
}

@test "run.sh fails with clear error if setup.sh produced no .env" {
  cat > "${SANDBOX}/template/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  exit 0
else
  _check_setup_drift() { :; }
fi
EOS
  chmod +x "${SANDBOX}/template/script/docker/setup.sh"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_failure
  assert_output --partial ".env"
  assert_output --partial "--setup"
}

@test "run.sh --detach routes to 'compose up -d'" {
  run bash "${SANDBOX}/run.sh" --detach --dry-run
  assert_success
  assert_output --partial "up"
  assert_output --partial "-d"
}

@test "run.sh devel target routes to 'compose up -d' + 'compose exec'" {
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "exec"
}

@test "run.sh non-devel target routes to 'compose run --rm'" {
  run bash "${SANDBOX}/run.sh" --dry-run test
  assert_success
  assert_output --partial "run"
  assert_output --partial "--rm"
}

@test "run.sh --instance is appended to project/container name" {
  run bash "${SANDBOX}/run.sh" --dry-run --instance foo
  assert_success
  assert_output --partial "mockuser-mockimg-foo"
}

@test "run.sh refuses to start when container already running (devel + no -d)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  # Simulate a running container matching CONTAINER_NAME=mockimg
  echo "mockimg" > "${DOCKER_PS_FILE}"

  # Real mode (no --dry-run) triggers the guard; DRY_RUN=true bypasses it.
  run bash "${SANDBOX}/run.sh"
  assert_failure
  assert_output --partial "already running"
}

@test "run.sh --lang zh-TW prints Chinese usage text" {
  run bash "${SANDBOX}/run.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "run.sh --lang requires a value" {
  run bash "${SANDBOX}/run.sh" --lang
  assert_failure
}

@test "run.sh --instance requires a value" {
  run bash "${SANDBOX}/run.sh" --instance
  assert_failure
}

@test "run.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/run.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "run.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/run.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

@test "run.sh uses xhost +SI:localuser under Wayland session" {
  run env XDG_SESSION_TYPE=wayland bash "${SANDBOX}/run.sh" --dry-run
  assert_success
}

# ── Fallback _detect_lang (no template/ tree) ──────────────────────────────

@test "run.sh fallback _detect_lang maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/run.sh "${_tmp}/run.sh"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/run.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "run.sh fallback _detect_lang maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/run.sh "${_tmp}/run.sh"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/run.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "run.sh fallback _detect_lang maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/run.sh "${_tmp}/run.sh"
  LANG=ja_JP.UTF-8 run bash "${_tmp}/run.sh" -h
  assert_success
  assert_output --partial "使用法"
  rm -rf "${_tmp}"
}
