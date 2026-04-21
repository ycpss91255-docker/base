#!/usr/bin/env bash
# setup.sh - Auto-detect system parameters and generate .env + compose.yaml
#
# Reads <repo>/setup.conf (or template/setup.conf default) for the repo's
# runtime configuration (image_name rules, gpu, gui, network, volumes),
# runs system detection (UID/GID, hardware, docker hub user, GPU, GUI,
# workspace path), then emits:
#   - <repo>/.env          (variable values + SETUP_* metadata for drift detection)
#   - <repo>/compose.yaml  (full compose with baseline + conditional blocks)
#
# Both output files are derived artifacts (gitignored). Source of truth is
# setup.conf + system detection.
#
# Usage: setup.sh [--base-path <path>] [--lang zh|zh-CN|ja]

# ── i18n messages ──────────────────────────────────────────────
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/i18n.sh"

_msg() {
  local _key="${1}"
  case "${_LANG}" in
    zh)
      case "${_key}" in
        env_done)      echo ".env 與 compose.yaml 更新完成" ;;
        env_comment)   echo "自動偵測欄位請勿手動修改，如需變更 WS_PATH 可直接編輯此檔案" ;;
        unknown_arg)   echo "未知參數" ;;
      esac ;;
    zh-CN)
      case "${_key}" in
        env_done)      echo ".env 与 compose.yaml 更新完成" ;;
        env_comment)   echo "自动检测字段请勿手动修改，如需变更 WS_PATH 可直接编辑此文件" ;;
        unknown_arg)   echo "未知参数" ;;
      esac ;;
    ja)
      case "${_key}" in
        env_done)      echo ".env と compose.yaml 更新完了" ;;
        env_comment)   echo "自動検出フィールドは手動で編集しないでください。WS_PATH の変更はこのファイルを直接編集してください" ;;
        unknown_arg)   echo "不明な引数" ;;
      esac ;;
    *)
      case "${_key}" in
        env_done)      echo ".env + compose.yaml updated" ;;
        env_comment)   echo "Auto-detected fields, do not edit manually. Edit WS_PATH if needed" ;;
        unknown_arg)   echo "Unknown argument" ;;
      esac ;;
  esac
}

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# ════════════════════════════════════════════════════════════════════
# detect_user_info
#
# Usage: detect_user_info <user_outvar> <group_outvar> <uid_outvar> <gid_outvar>
# ════════════════════════════════════════════════════════════════════
detect_user_info() {
  local -n __dui_user="${1:?"${FUNCNAME[0]}: missing user outvar"}"; shift
  local -n __dui_group="${1:?"${FUNCNAME[0]}: missing group outvar"}"; shift
  local -n __dui_uid="${1:?"${FUNCNAME[0]}: missing uid outvar"}"; shift
  local -n __dui_gid="${1:?"${FUNCNAME[0]}: missing gid outvar"}"

  __dui_user="${USER:-$(id -un)}"
  __dui_group="$(id -gn)"
  __dui_uid="$(id -u)"
  __dui_gid="$(id -g)"
}

# ════════════════════════════════════════════════════════════════════
# detect_hardware
#
# Usage: detect_hardware <outvar>
# ════════════════════════════════════════════════════════════════════
detect_hardware() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  _outvar="$(uname -m)"
}

# ════════════════════════════════════════════════════════════════════
# detect_docker_hub_user
#
# Tries docker info first, falls back to USER, then id -un
#
# Usage: detect_docker_hub_user <outvar>
# ════════════════════════════════════════════════════════════════════
detect_docker_hub_user() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  local _name=""
  _name="$(docker info 2>/dev/null | awk '/^[[:space:]]*Username:/{print $2}')" || true
  _outvar="${_name:-${USER:-$(id -un)}}"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu
#
# Checks nvidia-container-toolkit via dpkg-query
#
# Usage: detect_gpu <outvar>
# outvar: "true" or "false"
# ════════════════════════════════════════════════════════════════════
detect_gpu() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  if dpkg-query -W -f='${db:Status-Abbrev}\n' -- "nvidia-container-toolkit" 2>/dev/null \
    | grep -q '^ii'; then
    _outvar=true
  else
    _outvar=false
  fi
}

# ════════════════════════════════════════════════════════════════════
# detect_gui
#
# Returns "true" if host has X11 or Wayland display set, "false" otherwise.
#
# Usage: detect_gui <outvar>
# ════════════════════════════════════════════════════════════════════
detect_gui() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    _outvar=true
  else
    _outvar=false
  fi
}

# ════════════════════════════════════════════════════════════════════
# INI parser for setup.conf
# ════════════════════════════════════════════════════════════════════

# _parse_ini_section <file> <section> <keys_outvar> <values_outvar>
#
# Reads one section [<section>] from <file> into parallel arrays.
# Skips comments (#) and empty lines. Trims key/value whitespace.
# If a key is defined both in <base_path>/setup.conf and in template/setup.conf,
# caller should use _load_setup_conf which handles the merge (replace strategy).
_parse_ini_section() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _pis_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _pis_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _pis_keys=()
  _pis_values=()
  [[ -f "${_file}" ]] || return 0

  local __pis_line __pis_current="" __pis_k __pis_v
  while IFS= read -r __pis_line || [[ -n "${__pis_line}" ]]; do
    [[ -z "${__pis_line}" || "${__pis_line}" =~ ^[[:space:]]*# ]] && continue

    # Trim
    __pis_line="${__pis_line#"${__pis_line%%[![:space:]]*}"}"
    __pis_line="${__pis_line%"${__pis_line##*[![:space:]]}"}"
    [[ -z "${__pis_line}" ]] && continue

    # Section header
    if [[ "${__pis_line}" =~ ^\[(.+)\]$ ]]; then
      __pis_current="${BASH_REMATCH[1]}"
      continue
    fi

    # Only collect entries for the requested section
    [[ "${__pis_current}" == "${_section}" ]] || continue

    # Require key = value
    [[ "${__pis_line}" != *=* ]] && continue
    __pis_k="${__pis_line%%=*}"
    __pis_v="${__pis_line#*=}"
    __pis_k="${__pis_k#"${__pis_k%%[![:space:]]*}"}"
    __pis_k="${__pis_k%"${__pis_k##*[![:space:]]}"}"
    __pis_v="${__pis_v#"${__pis_v%%[![:space:]]*}"}"
    __pis_v="${__pis_v%"${__pis_v##*[![:space:]]}"}"

    _pis_keys+=("${__pis_k}")
    _pis_values+=("${__pis_v}")
  done < "${_file}"
}

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# Merges per-repo setup.conf with template default, section-replace strategy:
# if per-repo setup.conf has the section, use its entries; otherwise fall
# back to the template's section. SETUP_CONF env var forces a specific file.
_load_setup_conf() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _lsc_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lsc_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  # If SETUP_CONF is set, only read from it (no merge)
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _parse_ini_section "${SETUP_CONF}" "${_section}" _lsc_keys _lsc_values
    return 0
  fi

  local _self_dir
  _self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  local _template_conf="${_self_dir}/../../setup.conf"
  local _repo_conf="${_base}/setup.conf"

  # Try per-repo first; if the section exists there, use it.
  if [[ -f "${_repo_conf}" ]]; then
    local -a __lsc_k=() __lsc_v=()
    _parse_ini_section "${_repo_conf}" "${_section}" __lsc_k __lsc_v
    if (( ${#__lsc_k[@]} > 0 )); then
      _lsc_keys=("${__lsc_k[@]}")
      _lsc_values=("${__lsc_v[@]}")
      return 0
    fi
  fi

  # Fall back to template default
  _parse_ini_section "${_template_conf}" "${_section}" _lsc_keys _lsc_values
}

# _get_conf_value <keys_ref> <values_ref> <key> <default> <outvar>
#
# Returns the value for <key> in the parallel arrays; <default> if missing.
_get_conf_value() {
  local -n _gcv_keys="${1:?}"
  local -n _gcv_values="${2:?}"
  local _key="${3:?}"
  local _default="${4-}"
  local -n _gcv_out="${5:?}"

  local i
  for (( i=0; i<${#_gcv_keys[@]}; i++ )); do
    if [[ "${_gcv_keys[i]}" == "${_key}" ]]; then
      _gcv_out="${_gcv_values[i]}"
      return 0
    fi
  done
  _gcv_out="${_default}"
}

# _get_conf_list_sorted <keys_ref> <values_ref> <prefix> <outvar_array>
#
# Collects entries whose key starts with <prefix> (e.g. "mount_") and sorts
# by the numeric suffix. Returns VALUES in sorted order.
_get_conf_list_sorted() {
  local -n _gcls_keys="${1:?}"
  local -n _gcls_values="${2:?}"
  local _prefix="${3:?}"
  local -n _gcls_out="${4:?}"

  _gcls_out=()
  local -a __gcls_pairs=()
  local i __gcls_k __gcls_num
  for (( i=0; i<${#_gcls_keys[@]}; i++ )); do
    __gcls_k="${_gcls_keys[i]}"
    if [[ "${__gcls_k}" == "${_prefix}"* ]]; then
      __gcls_num="${__gcls_k#"${_prefix}"}"
      # Only numeric suffixes participate
      [[ "${__gcls_num}" =~ ^[0-9]+$ ]] || continue
      __gcls_pairs+=("${__gcls_num}:${_gcls_values[i]}")
    fi
  done

  # Sort by numeric prefix before ":"
  if (( ${#__gcls_pairs[@]} > 0 )); then
    local __gcls_sorted
    __gcls_sorted=$(printf '%s\n' "${__gcls_pairs[@]}" | sort -t: -k1,1n)
    while IFS= read -r __gcls_k; do
      _gcls_out+=("${__gcls_k#*:}")
    done <<< "${__gcls_sorted}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# Rule applicators for [image_name] rules (used by detect_image_name)
# ════════════════════════════════════════════════════════════════════

_rule_prefix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part _last=""
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    _last="${_part}"
    break
  done
  if [[ "${_last}" == "${_value}"* ]]; then
    echo "${_last#"${_value}"}"
  fi
}

_rule_suffix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    if [[ "${_part}" == *"${_value}" ]]; then
      echo "${_part%"${_value}"}"
      return
    fi
  done
}

_rule_env_example() {
  local _base="${BASE_PATH:-$1}"
  local _file="${_base}/.env.example"
  if [[ -f "${_file}" ]]; then
    grep -m1 '^IMAGE_NAME=' "${_file}" 2>/dev/null | cut -d= -f2-
  fi
}

_rule_basename() {
  local _path="$1"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    echo "${_part}"
    return
  done
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name
#
# Reads [image_name] rules from setup.conf (per-repo or template default).
# rules is a comma-separated ordered list; first match wins.
#
# Usage: detect_image_name <outvar> <path>
# ════════════════════════════════════════════════════════════════════
detect_image_name() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
  local _path="${1:?"${FUNCNAME[0]}: missing path"}"

  local _base="${BASE_PATH:-${_path}}"
  local -a __din_keys=() __din_values=()
  _load_setup_conf "${_base}" "image_name" __din_keys __din_values

  local _rules=""
  _get_conf_value __din_keys __din_values "rules" "" _rules

  local _found=""
  if [[ -n "${_rules}" ]]; then
    # Split on comma, trim each rule
    local -a _rule_arr=()
    IFS=',' read -ra _rule_arr <<< "${_rules}"
    local _rule _value
    for _rule in "${_rule_arr[@]}"; do
      _rule="${_rule#"${_rule%%[![:space:]]*}"}"
      _rule="${_rule%"${_rule##*[![:space:]]}"}"
      [[ -z "${_rule}" ]] && continue

      if [[ "${_rule}" == prefix:* ]]; then
        _value="${_rule#prefix:}"
        _found="$(_rule_prefix "${_path}" "${_value}")"
      elif [[ "${_rule}" == suffix:* ]]; then
        _value="${_rule#suffix:}"
        _found="$(_rule_suffix "${_path}" "${_value}")"
      elif [[ "${_rule}" == "@env_example" ]]; then
        _found="$(BASE_PATH="${_base}" _rule_env_example "${_path}")"
      elif [[ "${_rule}" == "@basename" ]]; then
        _found="$(_rule_basename "${_path}")"
      elif [[ "${_rule}" == @default:* ]]; then
        _found="${_rule#@default:}"
        printf "[setup] INFO: IMAGE_NAME using @default:%s\n" "${_found}" >&2
      fi

      [[ -n "${_found}" ]] && break
    done
  fi

  if [[ -z "${_found}" ]]; then
    printf "[setup] WARNING: IMAGE_NAME could not be detected. Using 'unknown'.\n" >&2
    _found="unknown"
  fi
  _outvar="${_found,,}"
}

# ════════════════════════════════════════════════════════════════════
# detect_ws_path
#
# Workspace detection strategy (in order):
#   1. If current directory is docker_*, use sibling *_ws (strip prefix)
#   2. Traverse path upward looking for a *_ws component
#   3. Fall back to parent directory
#
# Usage: detect_ws_path <outvar> <base_path>
# ════════════════════════════════════════════════════════════════════
detect_ws_path() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
  local _base_path="${1:?"${FUNCNAME[0]}: missing base_path"}"

  if [[ ! -d "${_base_path}" ]]; then
    printf "[setup] ERROR: detect_ws_path: base_path does not exist: %s\n" \
      "${_base_path}" >&2
    return 1
  fi
  _base_path="$(cd "${_base_path}" && pwd -P)"

  local _dirname=""
  _dirname="$(basename "${_base_path}")"

  if [[ "${_dirname}" == docker_* ]]; then
    local _name="${_dirname#docker_}"
    local _parent=""
    _parent="$(dirname "${_base_path}")"
    local _sibling="${_parent}/${_name}_ws"
    if [[ -d "${_sibling}" ]]; then
      _outvar="$(cd "${_sibling}" && pwd -P)"
      return 0
    fi
  fi

  local _check="${_base_path}"
  while [[ "${_check}" != "/" && "${_check}" != "." ]]; do
    if [[ "$(basename "${_check}")" == *_ws && -d "${_check}" ]]; then
      _outvar="$(cd "${_check}" && pwd -P)"
      return 0
    fi
    _check="$(dirname "${_check}")"
  done

  _outvar="$(dirname "${_base_path}")"
}

# ════════════════════════════════════════════════════════════════════
# Resolvers: mode + detection → final enabled state
# ════════════════════════════════════════════════════════════════════

# _resolve_gpu <mode> <detected> <outvar>
#   mode=auto   → enabled iff detected==true
#   mode=force  → always enabled
#   mode=off    → always disabled
_resolve_gpu() {
  local _mode="${1:?}"
  local _detected="${2:?}"
  local -n _rg_out="${3:?}"
  case "${_mode}" in
    force) _rg_out="true" ;;
    off)   _rg_out="false" ;;
    auto|*)
      if [[ "${_detected}" == "true" ]]; then _rg_out="true"; else _rg_out="false"; fi
      ;;
  esac
}

# _resolve_gui <mode> <detected> <outvar>
_resolve_gui() {
  local _mode="${1:?}"
  local _detected="${2:?}"
  local -n _rgu_out="${3:?}"
  case "${_mode}" in
    force) _rgu_out="true" ;;
    off)   _rgu_out="false" ;;
    auto|*)
      if [[ "${_detected}" == "true" ]]; then _rgu_out="true"; else _rgu_out="false"; fi
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash <base_path> <outvar>
#
# sha256 of the effective setup.conf content (per-repo overrides concatenated
# after template default). Used to detect conf drift in build.sh/run.sh.
# ════════════════════════════════════════════════════════════════════
_compute_conf_hash() {
  local _base="${1:?}"
  local -n _cch_out="${2:?}"
  local _self_dir
  _self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  local _template_conf="${_self_dir}/../../setup.conf"
  local _repo_conf="${_base}/setup.conf"

  # Use command substitution (not pipe-into-block) so the nameref
  # assignment happens in the function's scope, not a subshell.
  # The trailing `true` keeps the block's exit status 0 even when every
  # conditional cat is skipped (under `set -euo pipefail` a non-zero block
  # exit would propagate via command substitution and abort setup.sh).
  _cch_out="$(
    {
      [[ -f "${_template_conf}" ]] && cat "${_template_conf}"
      [[ -f "${_repo_conf}"     ]] && cat "${_repo_conf}"
      [[ -n "${SETUP_CONF:-}"   ]] && [[ -f "${SETUP_CONF}" ]] && cat "${SETUP_CONF}"
      true
    } | sha256sum | cut -d' ' -f1
  )"
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml <out> <repo_name> <gui_enabled> <gpu_enabled>
#                       <gpu_count> <gpu_caps> <extras_array_ref>
#
# Emits full compose.yaml with:
#   - Baseline: workspace + X11 (iff GUI) + GUI env block (iff GUI)
#   - Conditional: GPU deploy block (iff gpu_enabled=true)
#   - Extra volumes from [volumes] section (comes in via extras_array_ref)
# Network/IPC/privileged read from env var refs; .env provides values.
# ════════════════════════════════════════════════════════════════════
generate_compose_yaml() {
  local _out="${1:?}"
  local _name="${2:?}"
  local _gui="${3:?}"
  local _gpu="${4:?}"
  local _gpu_count="${5:?}"
  local _gpu_caps="${6:?}"
  local -n _gcy_extras="${7:?}"

  # Convert space-separated caps to YAML array form [a, b, c]
  local -a _caps_arr=()
  read -ra _caps_arr <<< "${_gpu_caps}"
  local _caps_yaml="["
  local _first=1 _cap
  for _cap in "${_caps_arr[@]}"; do
    if (( _first )); then
      _caps_yaml+="${_cap}"
      _first=0
    else
      _caps_yaml+=", ${_cap}"
    fi
  done
  _caps_yaml+="]"

  {
    cat <<'HEADER'
# AUTO-GENERATED BY setup.sh — DO NOT EDIT.
# Edit setup.conf instead. Regenerate via ./build.sh --setup or ./run.sh --setup.
HEADER
    cat <<YAML
services:
  devel:
    build:
      context: .
      dockerfile: Dockerfile
      target: devel
      args:
        APT_MIRROR_UBUNTU: \${APT_MIRROR_UBUNTU:-tw.archive.ubuntu.com}
        APT_MIRROR_DEBIAN: \${APT_MIRROR_DEBIAN:-mirror.twds.com.tw}
        USER_NAME: \${USER_NAME}
        USER_GROUP: \${USER_GROUP}
        USER_UID: \${USER_UID}
        USER_GID: \${USER_GID}
    image: \${DOCKER_HUB_USER:-local}/${_name}:devel
    container_name: ${_name}\${INSTANCE_SUFFIX:-}
    privileged: \${PRIVILEGED}
    network_mode: \${NETWORK_MODE}
    ipc: \${IPC_MODE}
    stdin_open: true
    tty: true
YAML
    if [[ "${_gui}" == "true" ]]; then
      cat <<'YAML'
    environment:
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=${XAUTHORITY:-}
YAML
    fi
    echo "    volumes:"
    if [[ "${_gui}" == "true" ]]; then
      cat <<'YAML'
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:${XAUTHORITY:-/dev/null}:ro
YAML
    fi
    cat <<'YAML'
      - ${WS_PATH}:/home/${USER_NAME}/work
YAML
    local _m
    for _m in "${_gcy_extras[@]}"; do
      echo "      - ${_m}"
    done
    if [[ "${_gpu}" == "true" ]]; then
      cat <<YAML
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${_gpu_count}
              capabilities: ${_caps_yaml}
YAML
    fi
    cat <<YAML

  test:
    build:
      context: .
      dockerfile: Dockerfile
      target: test
      args:
        APT_MIRROR_UBUNTU: \${APT_MIRROR_UBUNTU:-tw.archive.ubuntu.com}
        APT_MIRROR_DEBIAN: \${APT_MIRROR_DEBIAN:-mirror.twds.com.tw}
        USER_NAME: \${USER_NAME}
        USER_GROUP: \${USER_GROUP}
        USER_UID: \${USER_UID}
        USER_GID: \${USER_GID}
    image: \${DOCKER_HUB_USER:-local}/${_name}:test
    profiles:
      - test
YAML
  } > "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# write_env
#
# Usage: write_env <env_file> <user_name> <user_group> <uid> <gid>
#                  <hardware> <docker_hub_user> <gpu_detected>
#                  <image_name> <ws_path>
#                  <apt_mirror_ubuntu> <apt_mirror_debian>
#                  <network_mode> <ipc_mode> <privileged>
#                  <gpu_count> <gpu_caps>
#                  <gui_detected> <conf_hash>
# ════════════════════════════════════════════════════════════════════
write_env() {
  local _env_file="${1:?}"; shift
  local _user_name="${1}"; shift
  local _user_group="${1}"; shift
  local _uid="${1}"; shift
  local _gid="${1}"; shift
  local _hardware="${1}"; shift
  local _docker_hub_user="${1}"; shift
  local _gpu_detected="${1}"; shift
  local _image_name="${1}"; shift
  local _ws_path="${1}"; shift
  local _apt_mirror_ubuntu="${1}"; shift
  local _apt_mirror_debian="${1}"; shift
  local _network_mode="${1}"; shift
  local _ipc_mode="${1}"; shift
  local _privileged="${1}"; shift
  local _gpu_count="${1}"; shift
  local _gpu_caps="${1}"; shift
  local _gui_detected="${1}"; shift
  local _conf_hash="${1}"

  local _comment=""
  _comment="$(_msg env_comment)"
  cat > "${_env_file}" << EOF
# Auto-generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# ${_comment}

# ── User / hardware (auto-detected) ──────────
USER_NAME=${_user_name}
USER_GROUP=${_user_group}
USER_UID=${_uid}
USER_GID=${_gid}
HARDWARE=${_hardware}
DOCKER_HUB_USER=${_docker_hub_user}
GPU_ENABLED=${_gpu_detected}
IMAGE_NAME=${_image_name}

# ── Workspace ────────────────────────────────
WS_PATH=${_ws_path}

# ── APT Mirror ───────────────────────────────
APT_MIRROR_UBUNTU=${_apt_mirror_ubuntu}
APT_MIRROR_DEBIAN=${_apt_mirror_debian}

# ── Runtime config (from setup.conf) ─────────
NETWORK_MODE=${_network_mode}
IPC_MODE=${_ipc_mode}
PRIVILEGED=${_privileged}
GPU_COUNT=${_gpu_count}
GPU_CAPABILITIES=${_gpu_caps}

# ── Setup metadata (drift detection — do not edit) ──
SETUP_CONF_HASH=${_conf_hash}
SETUP_GUI_DETECTED=${_gui_detected}
SETUP_TIMESTAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
EOF
}

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift <base_path>
#
# Compares current system state + setup.conf hash against .env's SETUP_*
# metadata. Prints [WARNING] lines to stderr when drift detected. Always
# returns 0 (non-blocking). Caller is build.sh/run.sh before build/run.
#
# Requires .env to exist (caller checks first).
# ════════════════════════════════════════════════════════════════════
_check_setup_drift() {
  local _base="${1:?}"
  local _env_file="${_base}/.env"
  [[ -f "${_env_file}" ]] || return 0

  # Read stored values from .env without polluting caller's env
  local _stored_hash="" _stored_gui="" _stored_gpu="" _stored_uid=""
  _stored_hash="$(grep -oP '^SETUP_CONF_HASH=\K.*'    "${_env_file}" 2>/dev/null || true)"
  _stored_gui="$( grep -oP '^SETUP_GUI_DETECTED=\K.*' "${_env_file}" 2>/dev/null || true)"
  _stored_gpu="$( grep -oP '^GPU_ENABLED=\K.*'        "${_env_file}" 2>/dev/null || true)"
  _stored_uid="$( grep -oP '^USER_UID=\K.*'           "${_env_file}" 2>/dev/null || true)"

  local _now_hash="" _now_gui="" _now_gpu=""
  _compute_conf_hash "${_base}" _now_hash
  detect_gui _now_gui
  detect_gpu _now_gpu
  local _now_uid=""
  _now_uid="$(id -u)"

  local -a _drift=()
  [[ -n "${_stored_hash}" && "${_now_hash}" != "${_stored_hash}" ]] \
    && _drift+=("setup.conf modified since last setup")
  [[ -n "${_stored_gpu}"  && "${_now_gpu}"  != "${_stored_gpu}"  ]] \
    && _drift+=("GPU detection changed: ${_stored_gpu} → ${_now_gpu}")
  [[ -n "${_stored_gui}"  && "${_now_gui}"  != "${_stored_gui}"  ]] \
    && _drift+=("GUI detection changed: ${_stored_gui} → ${_now_gui}")
  [[ -n "${_stored_uid}"  && "${_now_uid}"  != "${_stored_uid}"  ]] \
    && _drift+=("USER_UID changed: ${_stored_uid} → ${_now_uid}")

  if (( ${#_drift[@]} > 0 )); then
    local _d
    printf "[setup] WARNING: drift detected since last setup.sh run:\n" >&2
    for _d in "${_drift[@]}"; do
      printf "[setup]   - %s\n" "${_d}" >&2
    done
    printf "[setup] Run with --setup to regenerate .env / compose.yaml.\n" >&2
  fi
}

# ════════════════════════════════════════════════════════════════════
# main
#
# Usage: main [--base-path <path>] [--lang <en|zh|zh-CN|ja>]
# ════════════════════════════════════════════════════════════════════
main() {
  local _base_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh|zh-CN|ja)"}"
        shift 2
        ;;
      *)
        printf "[setup] %s: %s\n" "$(_msg unknown_arg)" "$1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
  fi

  local _env_file="${_base_path}/.env"

  if [[ -f "${_env_file}" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "${_env_file}"
    set +o allexport
  fi

  # ── Detections ──
  local user_name="" user_group="" user_uid="" user_gid=""
  local hardware="" docker_hub_user="" gpu_detected="" gui_detected="" image_name=""
  local ws_path="${WS_PATH:-}"
  local apt_mirror_ubuntu="${APT_MIRROR_UBUNTU:-tw.archive.ubuntu.com}"
  local apt_mirror_debian="${APT_MIRROR_DEBIAN:-mirror.twds.com.tw}"

  detect_user_info       user_name user_group user_uid user_gid
  detect_hardware        hardware
  detect_docker_hub_user docker_hub_user
  detect_gpu             gpu_detected
  detect_gui             gui_detected
  BASE_PATH="${_base_path}" detect_image_name image_name "${_base_path}"

  if [[ -z "${ws_path}" ]] || [[ ! -d "${ws_path}" ]]; then
    detect_ws_path ws_path "${_base_path}"
  fi
  ws_path="$(cd "${ws_path}" && pwd -P)"

  # ── Load setup.conf sections ──
  local -a _gpu_k=() _gpu_v=() _gui_k=() _gui_v=() _net_k=() _net_v=() _vol_k=() _vol_v=()
  _load_setup_conf "${_base_path}" "gpu"     _gpu_k _gpu_v
  _load_setup_conf "${_base_path}" "gui"     _gui_k _gui_v
  _load_setup_conf "${_base_path}" "network" _net_k _net_v
  _load_setup_conf "${_base_path}" "volumes" _vol_k _vol_v

  local gpu_mode="" gpu_count="" gpu_caps=""
  local gui_mode=""
  local net_mode="" ipc_mode="" privileged=""
  _get_conf_value _gpu_k _gpu_v "mode"         "auto" gpu_mode
  _get_conf_value _gpu_k _gpu_v "count"        "all"  gpu_count
  _get_conf_value _gpu_k _gpu_v "capabilities" "gpu"  gpu_caps
  _get_conf_value _gui_k _gui_v "mode"         "auto" gui_mode
  _get_conf_value _net_k _net_v "mode"         "host" net_mode
  _get_conf_value _net_k _net_v "ipc"          "host" ipc_mode
  _get_conf_value _net_k _net_v "privileged"   "true" privileged

  # shellcheck disable=SC2034  # populated via nameref by _get_conf_list_sorted
  local -a extra_volumes=()
  _get_conf_list_sorted _vol_k _vol_v "mount_" extra_volumes

  # ── Resolve final enabled states ──
  local gpu_enabled_eff="" gui_enabled_eff=""
  _resolve_gpu "${gpu_mode}" "${gpu_detected}" gpu_enabled_eff
  _resolve_gui "${gui_mode}" "${gui_detected}" gui_enabled_eff

  # ── Compute hash for drift detection ──
  local conf_hash=""
  _compute_conf_hash "${_base_path}" conf_hash

  # ── Generate artifacts ──
  write_env "${_env_file}" \
    "${user_name}" "${user_group}" "${user_uid}" "${user_gid}" \
    "${hardware}" "${docker_hub_user}" "${gpu_detected}" \
    "${image_name}" "${ws_path}" \
    "${apt_mirror_ubuntu}" "${apt_mirror_debian}" \
    "${net_mode}" "${ipc_mode}" "${privileged}" \
    "${gpu_count}" "${gpu_caps}" \
    "${gui_detected}" "${conf_hash}"

  generate_compose_yaml "${_base_path}/compose.yaml" "${image_name}" \
    "${gui_enabled_eff}" "${gpu_enabled_eff}" \
    "${gpu_count}" "${gpu_caps}" \
    extra_volumes

  printf "[setup] %s\n" "$(_msg env_done)"
  printf "[setup] USER=%s (%s:%s)  GPU=%s/%s  GUI=%s/%s  IMAGE=%s  WS=%s\n" \
    "${user_name}" "${user_uid}" "${user_gid}" \
    "${gpu_enabled_eff}" "${gpu_mode}" \
    "${gui_enabled_eff}" "${gui_mode}" \
    "${image_name}" "${ws_path}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
