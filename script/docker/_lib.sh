#!/usr/bin/env bash
#
# _lib.sh - Shared helpers for build.sh / run.sh / exec.sh / stop.sh.
#
# Sourced (not executed). Provides:
#   _LANG                            : detected message language
#   _load_env <env_file>             : source .env into the environment
#   _compute_project_name <instance> : set INSTANCE_SUFFIX and PROJECT_NAME
#   _compose                         : `docker compose` wrapper honoring DRY_RUN
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SOURCED=1

# _detect_lang prints the language code derived from $LANG.
_detect_lang() {
  case "${LANG:-}" in
    zh_TW*) echo "zh" ;;
    zh_CN*|zh_SG*) echo "zh-CN" ;;
    ja*) echo "ja" ;;
    *) echo "en" ;;
  esac
}

# Load i18n.sh if present, otherwise fall back to a minimal _LANG.
_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "${_lib_dir}/i18n.sh" ]]; then
  # shellcheck disable=SC1091
  source "${_lib_dir}/i18n.sh"
else
  _LANG="${SETUP_LANG:-$(_detect_lang)}"
fi
unset _lib_dir

# _load_env sources the given .env file with allexport so every assignment
# becomes an exported variable visible to docker compose.
#
# Args:
#   $1: absolute path to .env file
_load_env() {
  local env_file="${1:?_load_env requires an env file path}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${env_file}"
  set +o allexport
}

# _compute_project_name derives INSTANCE_SUFFIX and PROJECT_NAME for the
# current invocation, and exports INSTANCE_SUFFIX so compose.yaml can resolve
# ${INSTANCE_SUFFIX:-} when computing container_name.
#
# Args:
#   $1: instance name (may be empty for the default instance)
#
# Requires:
#   DOCKER_HUB_USER, IMAGE_NAME already in the environment (from .env).
#
# Sets (and exports INSTANCE_SUFFIX):
#   INSTANCE_SUFFIX  e.g. "-foo" or ""
#   PROJECT_NAME     e.g. "alice-myrepo-foo"
_compute_project_name() {
  local instance="${1:-}"
  if [[ -n "${instance}" ]]; then
    INSTANCE_SUFFIX="-${instance}"
  else
    INSTANCE_SUFFIX=""
  fi
  export INSTANCE_SUFFIX
  # shellcheck disable=SC2034  # PROJECT_NAME is consumed by callers, not _lib.sh
  PROJECT_NAME="${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX}"
}

# _dump_conf_section <file> <section>
#
# Emit key=value lines from the named INI section of <file>, skipping
# blank lines and comments. Stops at the next section header or EOF.
# Silent on missing file or missing section.
_dump_conf_section() {
  local _file="$1" _sec="$2"
  [[ -f "${_file}" ]] || return 0
  # Filter out empty values (`key =` / `key = `). An empty value means
  # "use the Docker / template default" and is noise in the summary.
  # Populated keys print as-is; cleared list slots (arg_N = / mount_N =)
  # are also hidden so they don't show up as blank rows.
  awk -v sec="[${_sec}]" '
    $0 == sec { in_sec=1; next }
    /^\[/ && in_sec { in_sec=0 }
    in_sec && /^[[:space:]]*#/ { next }
    in_sec && /^[[:space:]]*$/ { next }
    in_sec && /^[[:space:]]*[^#=]+=[[:space:]]*$/ { next }
    in_sec { print }
  ' "${_file}"
}

# _print_config_summary <tag>
#
# Print the resolved runtime config right before the main action
# (docker build / up). Goal: first-time users can see every value
# this run will consume — file paths, .env-derived identity/hardware,
# and the complete [image]/[build]/[deploy]/[gui]/[network]/
# [security]/[resources]/[environment]/[tmpfs]/[devices]/[volumes]
# section contents from setup.conf — without having to diff `.env`
# or run `docker compose config`.
#
# Expects FILE_PATH + standard .env variables already in scope
# (caller must `_load_env` first). Missing values render as "-".
#
# Args:
#   $1: short tag prefix for log lines (e.g. "build", "run")
_print_config_summary() {
  local _tag="${1:?_print_config_summary requires a log tag}"
  local _fp="${FILE_PATH:-.}"
  local _conf="${_fp}/setup.conf"
  local _line="────────────────────────────────────────────────────────────"
  local _img="${DOCKER_HUB_USER:-local}/${IMAGE_NAME:-unknown}"
  local _proj="${PROJECT_NAME:-${DOCKER_HUB_USER:-local}-${IMAGE_NAME:-unknown}}"

  printf "[%s] %s\n" "${_tag}" "${_line}"
  printf "[%s] Files\n" "${_tag}"
  printf "[%s]   setup.conf   : %s\n"   "${_tag}" "${_conf}"
  printf "[%s]   .env         : %s\n"   "${_tag}" "${_fp}/.env"
  printf "[%s]   compose.yaml : %s\n"   "${_tag}" "${_fp}/compose.yaml"
  printf "[%s] Identity\n" "${_tag}"
  printf "[%s]   user         : %s (uid=%s)  group=%s (gid=%s)\n" "${_tag}" \
    "${USER_NAME:--}" "${USER_UID:--}" "${USER_GROUP:--}" "${USER_GID:--}"
  printf "[%s]   hardware     : %s\n" "${_tag}" "${HARDWARE:--}"
  printf "[%s]   image / tag  : %s\n" "${_tag}" "${_img}"
  printf "[%s]   project      : %s\n" "${_tag}" "${_proj}"
  printf "[%s]   workspace    : %s\n" "${_tag}" "${WS_PATH:--}"

  # setup.conf section-by-section dump. Each section prints only if
  # non-empty to stay readable. Order matches the TUI main menu so
  # the printout and setup_tui.sh layout mirror each other.
  if [[ -f "${_conf}" ]]; then
    printf "[%s] setup.conf\n" "${_tag}"
    local _sec _content _l
    for _sec in image build deploy gui network security resources \
                environment tmpfs devices volumes; do
      _content="$(_dump_conf_section "${_conf}" "${_sec}")"
      [[ -z "${_content}" ]] && continue
      printf "[%s]   [%s]\n" "${_tag}" "${_sec}"
      while IFS= read -r _l; do
        printf "[%s]     %s\n" "${_tag}" "${_l}"
      done <<< "${_content}"
    done
  else
    printf "[%s]   (setup.conf not found — run ./setup_tui.sh or ./%s.sh --setup)\n" \
      "${_tag}" "${_tag}"
  fi

  # Resolved post-merge flags that the user can't infer from setup.conf
  # alone (GPU/GUI depend on host detection in addition to mode=auto).
  printf "[%s] Resolved\n" "${_tag}"
  printf "[%s]   GPU enabled : %s  count=%s  caps=%s\n" "${_tag}" \
    "${GPU_ENABLED:--}" "${GPU_COUNT:--}" "${GPU_CAPABILITIES:--}"
  printf "[%s]   GUI enabled : %s\n" "${_tag}" "${SETUP_GUI_DETECTED:--}"
  printf "[%s]   network     : %s  ipc=%s  privileged=%s\n" "${_tag}" \
    "${NETWORK_MODE:--}" "${IPC_MODE:--}" "${PRIVILEGED:--}"
  printf "[%s]   TZ=%s  apt_ubuntu=%s  apt_debian=%s\n" "${_tag}" \
    "${TZ:--}" "${APT_MIRROR_UBUNTU:--}" "${APT_MIRROR_DEBIAN:--}"

  printf "[%s] Customize: ./setup_tui.sh  |  ./%s.sh --setup  |  edit setup.conf\n" \
    "${_tag}" "${_tag}"
  printf "[%s] %s\n" "${_tag}" "${_line}"
}

# _compose runs `docker compose` with the given args, or prints what it would
# run if DRY_RUN=true. Use this instead of calling docker compose directly so
# every script honors --dry-run uniformly.
_compose() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    printf '[dry-run] docker compose'
    printf ' %q' "$@"
    printf '\n'
  else
    docker compose "$@"
  fi
}

# _compose_project runs `_compose` with -p / -f / --env-file pre-filled, so
# callers only need to pass the verb and its args.
#
# Requires:
#   PROJECT_NAME : set by _compute_project_name
#   FILE_PATH    : the repo root (where compose.yaml and .env live)
_compose_project() {
  _compose -p "${PROJECT_NAME}" \
    -f "${FILE_PATH}/compose.yaml" \
    --env-file "${FILE_PATH}/.env" \
    "$@"
}
