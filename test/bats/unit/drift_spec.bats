#!/usr/bin/env bats
#
# why: Mirrors `lib/drift.sh`. `_check_setup_drift` no-op / silent /
# non-zero paths when the conf hash or GPU detection changes against a
# cached `.env`.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift
# ════════════════════════════════════════════════════════════════════
@test "_check_setup_drift no-op when .env missing" {
  run _check_setup_drift "${TEMP_DIR}"
  assert_success
}

@test "_check_setup_drift silent when nothing changed" {
  # Prime .env by running a full setup cycle (write_env + _compute_conf_hash)
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  # stub detect_gui/detect_gpu to match stored false
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_success
  refute_output --partial "WARNING"
}

@test "_check_setup_drift warns and reports drift when grep has no -P (base#1644)" {
  # A grep without PCRE (BSD, busybox) fails every `grep -oP` read; each read
  # ends in `|| true`, so every stored value came back empty, every
  # comparison was skipped and drift was never reported, with no output.
  # The host check must say so, and must not claim the state is in sync.
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }
  grep() {
    local _a
    for _a in "$@"; do
      if [[ "${_a}" == -*P* ]]; then
        echo "grep: invalid option -- 'P'" >&2
        return 2
      fi
    done
    command grep "$@"
  }

  run --separate-stderr _check_setup_drift "${TEMP_DIR}"
  assert_failure
  [[ "${stderr}" == *"grep -P"* ]] \
    || fail "no diagnostic naming grep -P on stderr: ${stderr}"
}

@test "_check_setup_drift stays silent with a grep that supports -P (base#1644)" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run --separate-stderr _check_setup_drift "${TEMP_DIR}"
  assert_success
  [[ -z "${stderr}" ]] || fail "unexpected stderr: ${stderr}"
}

@test "_check_setup_drift returns non-zero when conf hash changes" {
  local _h_old=""
  _compute_conf_hash "${TEMP_DIR}" _h_old
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h_old}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  # Drop in a new per-repo setup.toml → hash differs
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "off"
EOF

  run _check_setup_drift "${TEMP_DIR}"
  # Non-zero exit lets build.sh/run.sh trigger auto-regen (v0.9.5+).
  assert_failure
  assert_output --partial "drift detected"
  assert_output --partial "setup.toml modified"
}

@test "_check_setup_drift returns non-zero when GPU detection changes" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  # Store with GPU=false
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  # Now detection says true
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="true"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_failure
  assert_output --partial "GPU detection changed"
}
