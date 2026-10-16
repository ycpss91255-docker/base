#!/usr/bin/env bash
#
# config_summary.sh - Resolved-runtime-config pretty-printer.
#
# Provides:
#   _lib_msg <key>            : i18n labels for the summary section headings
#                              and field labels (zh-TW / zh-CN / ja / en).
#   _print_config_summary <tag> : print the resolved runtime config right
#                              before the main action (docker build / up).
#
# Depends on:
#   - i18n.sh for ${_LANG}
#   - conf.sh for _dump_conf_section
#
# Caller must `_load_env` first so the .env-derived variables are in scope.
#
# Split out from _lib.sh. _lib_msg stays alongside the printer
# (its single consumer) per the issue body's "defer until it lands"
# guidance — now that it has landed, there's no other i18n surface
# pulling _lib_msg the other way.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_CONFIG_SUMMARY_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_CONFIG_SUMMARY_SOURCED=1

# Pull in _dump_conf_section + _log_color_enabled. Idempotent — each has its own guard.
_config_summary_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck disable=SC1091
source "${_config_summary_dir}/conf.sh"
# shellcheck source=dist/script/docker/lib/setup_conf.sh
source "${_config_summary_dir}/setup_conf.sh"
# shellcheck disable=SC1091
source "${_config_summary_dir}/log.sh"
unset _config_summary_dir

_summary_print() {
  local tag="${1}" style="${2-}"
  shift 2
  local prefix="" suffix=""
  if _log_color_enabled 1 && [[ -n "${style}" ]]; then
    case "${style}" in
      bold) prefix=$'\033[1m'; suffix=$'\033[0m' ;;
      dim)  prefix=$'\033[2m'; suffix=$'\033[0m' ;;
    esac
  fi
  printf '[%s] %s%s%s\n' "${tag}" "${prefix}" "$*" "${suffix}"
}

# _lib_msg <key>
#
# Translation table for labels printed by `_print_config_summary`.
# Uses the same `${_LANG}:${_key}` → output pattern as setup.sh /
# build.sh's `_msg`. Kept in a separate namespace (`_lib_msg`) so
# caller scripts can still define their own `_msg` for script-specific
# log lines without name collisions.
#
# Translated: section headings + descriptive labels. Left untranslated
# (technical terms / identifiers users recognise across locales): file
# names (setup.toml / .env / compose.yaml), INI section names in [ ],
# .env variable names (TZ, APT_MIRROR_*, IPC, CAPS), command strings
# in "Customize" hint.
_lib_msg() {
  local _key="${1:?}"
  case "${_LANG:-en}:${_key}" in
    # Section headings
    zh-TW:files)             echo "檔案" ;;
    zh-CN:files)             echo "文件" ;;
    ja:files)                echo "ファイル" ;;
    *:files)                 echo "Files" ;;
    zh-TW:identity)          echo "身分" ;;
    zh-CN:identity)          echo "身份" ;;
    ja:identity)             echo "ID" ;;
    *:identity)              echo "Identity" ;;
    zh-TW:resolved)          echo "解析結果" ;;
    zh-CN:resolved)          echo "解析结果" ;;
    ja:resolved)             echo "解決済み" ;;
    *:resolved)              echo "Resolved" ;;
    zh-TW:variables)         echo "變數對映" ;;
    zh-CN:variables)         echo "变量映射" ;;
    ja:variables)            echo "変数マッピング" ;;
    *:variables)             echo "Variables" ;;
    # Identity field labels
    zh-TW:user)              echo "使用者" ;;
    zh-CN:user)              echo "用户" ;;
    ja:user)                 echo "ユーザー" ;;
    *:user)                  echo "user" ;;
    zh-TW:group)             echo "群組" ;;
    zh-CN:group)             echo "组" ;;
    ja:group)                echo "グループ" ;;
    *:group)                 echo "group" ;;
    zh-TW:hardware)          echo "硬體" ;;
    zh-CN:hardware)          echo "硬件" ;;
    ja:hardware)             echo "ハードウェア" ;;
    *:hardware)              echo "hardware" ;;
    zh-TW:image_tag)         echo "映像 / 標籤" ;;
    zh-CN:image_tag)         echo "镜像 / 标签" ;;
    ja:image_tag)            echo "イメージ / タグ" ;;
    *:image_tag)             echo "image / tag" ;;
    zh-TW:project)           echo "專案" ;;
    zh-CN:project)           echo "项目" ;;
    ja:project)              echo "プロジェクト" ;;
    *:project)               echo "project" ;;
    zh-TW:workspace)         echo "工作區" ;;
    zh-CN:workspace)         echo "工作区" ;;
    ja:workspace)            echo "ワークスペース" ;;
    *:workspace)             echo "workspace" ;;
    # Resolved field labels
    zh-TW:gpu_enabled)       echo "GPU 已啟用" ;;
    zh-CN:gpu_enabled)       echo "GPU 已启用" ;;
    ja:gpu_enabled)          echo "GPU 有効" ;;
    *:gpu_enabled)           echo "GPU enabled" ;;
    zh-TW:count)             echo "數量" ;;
    zh-CN:count)             echo "数量" ;;
    ja:count)                echo "数量" ;;
    *:count)                 echo "count" ;;
    zh-TW:caps)              echo "能力" ;;
    zh-CN:caps)              echo "能力" ;;
    ja:caps)                 echo "ケーパビリティ" ;;
    *:caps)                  echo "caps" ;;
    zh-TW:gui_enabled)       echo "GUI 已啟用" ;;
    zh-CN:gui_enabled)       echo "GUI 已启用" ;;
    ja:gui_enabled)          echo "GUI 有効" ;;
    *:gui_enabled)           echo "GUI enabled" ;;
    zh-TW:network)           echo "網路" ;;
    zh-CN:network)           echo "网络" ;;
    ja:network)              echo "ネットワーク" ;;
    *:network)               echo "network" ;;
    zh-TW:privileged)        echo "特權" ;;
    zh-CN:privileged)        echo "特权" ;;
    ja:privileged)           echo "特権" ;;
    *:privileged)            echo "privileged" ;;
    # Hints / errors
    zh-TW:conf_missing)      echo "(找不到 setup.toml — 執行 ./setup_tui.sh 或 ./%s.sh --setup)" ;;
    zh-CN:conf_missing)      echo "(找不到 setup.toml — 运行 ./setup_tui.sh 或 ./%s.sh --setup)" ;;
    ja:conf_missing)         echo "(setup.toml が見つかりません — ./setup_tui.sh または ./%s.sh --setup を実行してください)" ;;
    *:conf_missing)          echo "(setup.toml not found — run ./setup_tui.sh or ./%s.sh --setup)" ;;
    zh-TW:conf_empty)        echo "(setup.toml 沒有 section 覆寫 — 全部使用模板預設值；./setup_tui.sh 或 edit setup.toml)" ;;
    zh-CN:conf_empty)        echo "(setup.toml 没有 section 覆写 — 全部使用模板默认值；./setup_tui.sh 或 edit setup.toml)" ;;
    ja:conf_empty)           echo "(setup.toml にセクション上書きがありません — 全てテンプレート既定値を使用；./setup_tui.sh または edit setup.toml)" ;;
    *:conf_empty)            echo "(setup.toml has no section overrides — using template defaults; run ./setup_tui.sh or edit setup.toml)" ;;
    zh-TW:customize)         echo "自訂" ;;
    zh-CN:customize)         echo "自定义" ;;
    ja:customize)            echo "カスタマイズ" ;;
    *:customize)             echo "Customize" ;;
  esac
}

# _summary_dump_section <tag> <section> <keys_arrayvar> <values_arrayvar>
#
# The POPULATED keys of one section of the resolved view, as
# `key = value` lines under a `[<section>]` header -- and nothing at all,
# header included, when the section has none. Reads the namespaced
# `<section>.<key>` arrays `_load_setup_conf_full` fills, so a numbered
# family arrives already numbered back from its `[[array of tables]]`.
#
# An empty value means "use the Docker / template default" and is noise
# in a summary, which is the rule the INI dump this replaces applied to
# the same lines -- including a cleared list slot.
#
# Every local is `_sds_`-prefixed, the outvars handed to
# `_conf_split_nskey` included: it declares locals of its own, and a
# nameref pointing at a bare name resolves to the CALLEE's variable.
_summary_dump_section() {
  local _tag="${1:?}" _sec="${2:?}"
  local -n _sds_keys="${3:?}" _sds_vals="${4:?}"
  local _sds_i _sds_s="" _sds_k="" _sds_printed=0
  for (( _sds_i = 0; _sds_i < ${#_sds_keys[@]}; _sds_i++ )); do
    _conf_split_nskey "${_sds_keys[_sds_i]}" _sds_s _sds_k || continue
    [[ "${_sds_s}" == "${_sec}" ]] || continue
    [[ -n "${_sds_vals[_sds_i]}" ]] || continue
    if (( ! _sds_printed )); then
      printf "[%s]   [%s]\n" "${_tag}" "${_sec}"
      _sds_printed=1
    fi
    printf "[%s]     %s = %s\n" "${_tag}" "${_sds_k}" "${_sds_vals[_sds_i]}"
  done
}

# _summary_dump_entries <tag> <sections> <rows>
#
# setup.toml as the file spells it: each block under its own header --
# `[build]` for a table's scalars, `[[build.args]]` (or `[[volumes]]` at
# the root) once per array entry -- and each field by the name the file
# gives it (`key` / `value`, `rule`), blocks in the order the bridge
# emits them, which is the order the file writes them, across sections
# too: rows are never regrouped by section, so `[[security.cap_add]]`,
# `[[build.args]]`, `[[security.cap_drop]]` print in that order
# (base#1339). <sections> is a space-separated list; a block of any
# other section is skipped, as the INI dump skips one. <rows> is the output of
# `toml_bridge_parse --entries`, which numbers the blocks so that two
# entries of one array print as two blocks. A table scalar arrives only
# when populated, so a section with none prints nothing at all; an
# entry's field arrives even when empty, and prints as `""` -- the
# `value = ""` of a build argument set empty is part of that argument.
#
# The KV view `_load_setup_conf_full` reads is not used here: its
# `<prefix>_N` keys (`rule_1`, `arg_1`) are the shell's internal names
# for an array entry, not names a setup.toml contains, and a summary in
# them shows the user a vocabulary their file does not use (base#1339).
_summary_dump_entries() {
  local _tag="${1:?}" _secs=" ${2:?} " _rows="${3-}"
  local _sde_row _sde_s _sde_n _sde_h _sde_f _sde_v _sde_last=""
  while IFS= read -r _sde_row; do
    [[ -n "${_sde_row}" ]] || continue
    _sde_s="${_sde_row%%$'\t'*}"; _sde_row="${_sde_row#*$'\t'}"
    [[ "${_secs}" == *" ${_sde_s} "* ]] || continue
    _sde_n="${_sde_row%%$'\t'*}"; _sde_row="${_sde_row#*$'\t'}"
    _sde_h="${_sde_row%%$'\t'*}"; _sde_row="${_sde_row#*$'\t'}"
    _sde_f="${_sde_row%%$'\t'*}"; _sde_v="${_sde_row#*$'\t'}"
    [[ -n "${_sde_v}" ]] || _sde_v='""'
    if [[ "${_sde_n}" != "${_sde_last}" ]]; then
      printf "[%s]   %s\n" "${_tag}" "${_sde_h}"
      _sde_last="${_sde_n}"
    fi
    printf "[%s]     %s = %s\n" "${_tag}" "${_sde_f}" "${_sde_v}"
  done <<< "${_rows}"
}

# _print_config_summary <tag>
#
# Print the resolved runtime config right before the main action
# (docker build / up). Goal: first-time users can see every value
# this run will consume — file paths, .env-derived identity/hardware,
# and the complete [image]/[build]/[deploy]/[gui]/[network]/
# [security]/[resources]/[environment]/[tmpfs]/[devices]/[volumes]
# section contents from setup.toml — without having to diff `.env`
# or run `docker compose config`.
#
# Expects FILE_PATH + standard .env variables already in scope
# (caller must `_load_env` first). Missing values render as "-".
#
# Labels honor ${_LANG} via `_lib_msg`; technical terms stay
# untranslated (see _lib_msg header).
#
# Args:
#   $1: short tag prefix for log lines (e.g. "build", "run")
_print_config_summary() {
  local _tag="${1:?_print_config_summary requires a log tag}"
  local _fp="${FILE_PATH:-.}"
  local _conf="${_fp}/setup.toml"
  local _line="────────────────────────────────────────────────────────────"
  local _img="${DOCKER_HUB_USER:-local}/${IMAGE_NAME:-unknown}"
  # Report what -p will actually be, never a re-derivation of it: the
  # summary exists so the user can see what this invocation resolved to,
  # and a summary that computes its own answer can print a name the run
  # does not use.
  local _proj="${PROJECT_NAME:-unknown}"

  _summary_print "${_tag}" dim  "${_line}"
  _summary_print "${_tag}" bold "$(_lib_msg files)"
  printf "[%s]   setup.toml   : %s\n"   "${_tag}" "${_conf}"
  # A config layer nobody else can see must not be invisible in the run that
  # uses it. Printed only when it actually supplies sections, and it names
  # WHICH -- the sections in which this run is using something other than
  # the committed values. Section, not key: a local table overrides the
  # keys it names and a local array replaces its list whole, and the
  # section is the granularity that covers both honestly.
  local -a _pcs_local=()
  _setup_conf_local_sections "${_fp}" _pcs_local
  if (( ${#_pcs_local[@]} > 0 )); then
    local _pcs_list="${_pcs_local[*]}"
    # Asked for, not spelled: the layer is addressable (ADR-00000036), so
    # a summary that names the default path would tell the operator the
    # run read their worktree file while it read the caller's.
    printf "[%s]   local override: %s (overrides in: %s)\n" \
      "${_tag}" "$(_setup_conf_local_path "${_fp}")" "${_pcs_list// /, }"
  fi
  printf "[%s]   .env         : %s\n"   "${_tag}" "${_fp}/.env"
  printf "[%s]   compose.yaml : %s\n"   "${_tag}" "${_fp}/compose.yaml"
  _summary_print "${_tag}" bold "$(_lib_msg identity)"
  printf "[%s]   %-12s : %s (uid=%s)  %s=%s (gid=%s)\n" "${_tag}" \
    "$(_lib_msg user)" "${USER_NAME:--}" "${USER_UID:--}" \
    "$(_lib_msg group)" "${USER_GROUP:--}" "${USER_GID:--}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg hardware)" "${HARDWARE:--}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg image_tag)" "${_img}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg project)" "${_proj}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg workspace)" "${WS_PATH:--}"

  # Variables block: explicit map from setup.toml placeholders to the
  # detected runtime values. Identity prints the resolved values with
  # i18n labels (e.g. "使用者 : alice"); the [volumes] dump prints raw
  # `${USER_NAME}` / `${WS_PATH}` placeholders. This block bridges the
  # two so users can read mount_* lines without re-deriving the mapping
  # from translated labels.
  _summary_print "${_tag}" bold "$(_lib_msg variables)"
  printf "[%s]   \${USER_NAME} = %s\n"  "${_tag}" "${USER_NAME:--}"
  printf "[%s]   \${USER_UID}  = %s\n"  "${_tag}" "${USER_UID:--}"
  printf "[%s]   \${USER_GROUP} = %s\n" "${_tag}" "${USER_GROUP:--}"
  printf "[%s]   \${USER_GID}  = %s\n"  "${_tag}" "${USER_GID:--}"
  printf "[%s]   \${WS_PATH}   = %s\n"  "${_tag}" "${WS_PATH:--}"

  # setup.toml section-by-section dump. Each section prints only if
  # non-empty to stay readable. Order matches the TUI main menu so
  # the printout and setup_tui.sh layout mirror each other.
  if [[ -f "${_conf}" ]]; then
    _summary_print "${_tag}" bold "setup.toml"
    # When the file exists but contains no [section] headers (empty file
    # / comments-only / whitespace-only), every section silently falls
    # back to template defaults. Surface a parallel hint to the
    # missing-conf branch so users on build.sh's drift-check rebuild
    # path see the heads-up too
    if ! grep -qE '^[[:space:]]*\[[^]]+\]' "${_conf}"; then
      # shellcheck disable=SC2059  # format string is intentional (i18n table owns no %s)
      printf "[%s]   $(_lib_msg conf_empty)\n" "${_tag}"
    else
      # Read the PARSED file, not its lines. `_dump_conf_section`
      # is an INI reader -- it matches an exact `[section]` header and
      # stops at the next one -- so against a setup.toml every numbered
      # family disappeared from this summary: an `[[volumes]]` block is
      # not inside `[volumes]`, and `[build]` ended at the first
      # `[[build.args]]`. The mounts, the devices, the build args, the
      # ports and the capability lists -- every array-valued setting the
      # run actually consumes -- were missing from the one screen a
      # first-time user reads before a build, while the scalars printed
      # with their TOML quotes still on. The parse is printed in the
      # file's own vocabulary (`[[build.args]]`, `key = ...`), never the
      # KV view's `arg_N` names (base#1339). Loaded ONCE: each call is a
      # bridge invocation, and eleven of them per summary is eleven
      # `docker run`s.
      local _sec _content _l
      local -a _pcs_secs=(image build deploy gui network security resources
                          environment tmpfs devices volumes)
      if [[ "${_conf}" == *.toml ]]; then
        _summary_dump_entries "${_tag}" "${_pcs_secs[*]}" \
          "$(toml_bridge_parse "${_conf}" --entries)"
      else
        for _sec in "${_pcs_secs[@]}"; do
          _content="$(_dump_conf_section "${_conf}" "${_sec}")"
          [[ -z "${_content}" ]] && continue
          printf "[%s]   [%s]\n" "${_tag}" "${_sec}"
          while IFS= read -r _l; do
            printf "[%s]     %s\n" "${_tag}" "${_l}"
          done <<< "${_content}"
        done
      fi
    fi
  else
    # shellcheck disable=SC2059  # format string is intentional (i18n table owns %s)
    printf "[%s]   $(_lib_msg conf_missing)\n" "${_tag}" "${_tag}"
  fi

  # Resolved post-merge flags that the user can't infer from setup.toml
  # alone (GPU/GUI depend on host detection in addition to mode=auto).
  _summary_print "${_tag}" bold "$(_lib_msg resolved)"
  printf "[%s]   %s : %s  count=%s  caps=%s\n" "${_tag}" \
    "$(_lib_msg gpu_enabled)" "${GPU_ENABLED:--}" "${GPU_COUNT:--}" "${GPU_CAPABILITIES:--}"
  printf "[%s]   %s : %s\n" "${_tag}" \
    "$(_lib_msg gui_enabled)" "${SETUP_GUI_DETECTED:--}"
  printf "[%s]   %s     : %s  ipc=%s  pid=%s  %s=%s\n" "${_tag}" \
    "$(_lib_msg network)" "${NETWORK_MODE:--}" "${IPC_MODE:--}" \
    "${PID_MODE:--}" "$(_lib_msg privileged)" "${PRIVILEGED:--}"
  printf "[%s]   TZ=%s  apt_ubuntu=%s  apt_debian=%s\n" "${_tag}" \
    "${TZ:--}" "${APT_MIRROR_UBUNTU:--}" "${APT_MIRROR_DEBIAN:--}"

  printf "[%s] %s: ./setup_tui.sh  |  ./%s.sh --setup  |  edit setup.toml\n" \
    "${_tag}" "$(_lib_msg customize)" "${_tag}"
  _summary_print "${_tag}" dim "${_line}"
}
