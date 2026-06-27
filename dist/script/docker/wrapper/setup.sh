#!/usr/bin/env bash
# setup.sh - Auto-detect system parameters and generate .env + compose.yaml
#
# Reads <repo>/setup.conf (or .base/setup.conf default) for the repo's
# runtime configuration ([image] rules, [build] apt_mirror, [deploy] GPU,
# [gui], [network], [volumes]), runs system detection (UID/GID, hardware,
# docker hub user, GPU, GUI, workspace path), then emits:
#   - <repo>/.env          (variable values + SETUP_* metadata for drift detection)
#   - <repo>/compose.yaml  (full compose with baseline + conditional blocks)
#
# Both output files are derived artifacts (gitignored). Source of truth is
# setup.conf + system detection. WS_PATH is detected once and written back
# to <repo>/setup.conf [volumes] mount_1; subsequent runs read mount_1.
#
# Usage: setup.sh [-h|--help] [--base-path <path>] [--lang en|zh-TW|zh-CN|ja]

# ── i18n messages ──────────────────────────────────────────────
# Resolve the symlink (<repo>/setup.sh → .base/dist/script/docker/setup.sh)
# so sibling sources (i18n.sh / _tui_conf.sh) are located in the
# template directory regardless of how the script was invoked.
_SETUP_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_SETUP_SCRIPT_DIR="$(cd -- "$(dirname -- "${_SETUP_SELF}")" && pwd -P)"
_SETUP_LIB_DIR="$(cd -- "${_SETUP_SCRIPT_DIR}/../lib" && pwd -P)"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/i18n.sh"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/_tui_conf.sh"
# setup.sh sources _lib.sh directly (not via _bootstrap), so set the
# verb here for transcript.sh's classification before the source.
export _WRAPPER_VERB=setup
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/_lib.sh"

# Part B: i18n.sh no longer seeds _LANG at source time -- resolve it
# explicitly so the _setup_msg_* tables work before --lang parsing (which
# overrides _LANG later via _sanitize_lang).
_resolve_lang _LANG

# i18n message table, split per category and routed through _log_*
# Renamed from a monolithic `_msg` to `_setup_msg`
# so sourcing this file from build.sh / run.sh doesn't
# silently shadow their own top-level `_msg`. The category split
# mirrors PR-2 (which did the same for build/run/exec/stop):
# each _setup_msg_<category> returns plain i18n body only; tag +
# LEVEL keyword are added by the _log_* caller (English-only; level
# keyword no longer translated —).

_setup_msg_env() {
  case "${_LANG}:${1:?}" in
    zh-TW:done)     echo ".env 與 compose.yaml 更新完成" ;;
    zh-CN:done)     echo ".env 与 compose.yaml 更新完成" ;;
    ja:done)        echo ".env と compose.yaml 更新完了" ;;
    *:done)         echo ".env + compose.yaml updated" ;;
    zh-TW:comment)  echo "自動偵測欄位請勿手動修改，如需變更 WS_PATH 可直接編輯此檔案" ;;
    zh-CN:comment)  echo "自动检测字段请勿手动修改，如需变更 WS_PATH 可直接编辑此文件" ;;
    ja:comment)     echo "自動検出フィールドは手動で編集しないでください。WS_PATH の変更はこのファイルを直接編集してください" ;;
    *:comment)      echo "Auto-detected fields, do not edit manually. Edit WS_PATH if needed" ;;
  esac
}

_setup_msg_errors() {
  case "${_LANG}:${1:?}" in
    zh-TW:unknown_arg)       echo "未知參數" ;;
    zh-CN:unknown_arg)       echo "未知参数" ;;
    ja:unknown_arg)          echo "不明な引数" ;;
    *:unknown_arg)           echo "Unknown argument" ;;
    zh-TW:unknown_subcmd)    echo "未知子指令" ;;
    zh-CN:unknown_subcmd)    echo "未知子命令" ;;
    ja:unknown_subcmd)       echo "不明なサブコマンド" ;;
    *:unknown_subcmd)        echo "Unknown subcommand" ;;
    zh-TW:unknown_section)   echo "未知 section" ;;
    zh-CN:unknown_section)   echo "未知 section" ;;
    ja:unknown_section)      echo "不明な section" ;;
    *:unknown_section)       echo "Unknown section" ;;
    zh-TW:invalid_value)     echo "無效的值" ;;
    zh-CN:invalid_value)     echo "无效的值" ;;
    ja:invalid_value)        echo "無効な値" ;;
    *:invalid_value)         echo "Invalid value" ;;
    zh-TW:key_not_found)     echo "找不到鍵" ;;
    zh-CN:key_not_found)     echo "找不到键" ;;
    ja:key_not_found)        echo "キーが見つかりません" ;;
    *:key_not_found)         echo "Key not found" ;;
    zh-TW:section_not_found) echo "找不到 section" ;;
    zh-CN:section_not_found) echo "找不到 section" ;;
    ja:section_not_found)    echo "section が見つかりません" ;;
    *:section_not_found)     echo "Section not found" ;;
  esac
}

_setup_msg_warnings() {
  case "${_LANG}:${1:?}" in
    zh-TW:no_repo_conf)    echo "未找到 repo 自有的 setup.conf — 全部 section 將使用模板預設值" ;;
    zh-CN:no_repo_conf)    echo "未找到 repo 自有的 setup.conf — 全部 section 将使用模板默认值" ;;
    ja:no_repo_conf)       echo "repo 固有の setup.conf が見つかりません — 全ての section でテンプレートのデフォルト値を使用します" ;;
    *:no_repo_conf)        echo "no per-repo setup.conf — using template defaults for all sections" ;;
    zh-TW:empty_repo_conf) echo "repo 的 setup.conf 沒有任何 section 覆寫 — 全部 section 將使用模板預設值" ;;
    zh-CN:empty_repo_conf) echo "repo 的 setup.conf 没有任何 section 覆写 — 全部 section 将使用模板默认值" ;;
    ja:empty_repo_conf)    echo "repo の setup.conf にセクション上書きがありません — 全ての section でテンプレートのデフォルト値を使用します" ;;
    *:empty_repo_conf)     echo "per-repo setup.conf has no section overrides — using template defaults for all sections" ;;
  esac
}

# usage_* messages are short subcommand-usage hints printed directly
# (no [setup] / LEVEL prefix) — they are help text, not log lines.
_setup_msg_usage() {
  case "${_LANG}:${1:?}" in
    zh-TW:set)    echo "用法: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-CN:set)    echo "用法: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    ja:set)       echo "使い方: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    *:set)        echo "Usage: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-TW:show)   echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:show)   echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    ja:show)      echo "使い方: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    *:show)       echo "Usage: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:list)   echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:list)   echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    ja:list)      echo "使い方: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    *:list)       echo "Usage: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:add)    echo "用法: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-CN:add)    echo "用法: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    ja:add)       echo "使い方: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    *:add)        echo "Usage: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-TW:remove) echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-CN:remove) echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    ja:remove)    echo "使い方: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    *:remove)     echo "Usage: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
  esac
}

_setup_msg_reset() {
  case "${_LANG}:${1:?}" in
    zh-TW:confirm)   echo "將以模板預設值覆寫 setup.conf（舊檔備份為 setup.conf.bak / .env.bak）。繼續嗎？" ;;
    zh-CN:confirm)   echo "将以模板默认值覆写 setup.conf（旧文件备份为 setup.conf.bak / .env.bak）。继续吗？" ;;
    ja:confirm)      echo "テンプレートのデフォルト値で setup.conf を上書きします（旧ファイルは setup.conf.bak / .env.bak にバックアップ）。続行しますか？" ;;
    *:confirm)       echo "Overwrite setup.conf with template default? (prior setup.conf → .bak, prior .env → .env.bak)" ;;
    zh-TW:aborted)   echo "已取消，未變更任何檔案" ;;
    zh-CN:aborted)   echo "已取消，未更改任何文件" ;;
    ja:aborted)      echo "中断されました。ファイルは変更されていません" ;;
    *:aborted)       echo "Aborted; no files changed" ;;
    zh-TW:done)      echo "setup.conf 已重設為模板預設值（先前內容備份於 .bak）" ;;
    zh-CN:done)      echo "setup.conf 已重置为模板默认值（之前内容备份至 .bak）" ;;
    ja:done)         echo "setup.conf をテンプレートのデフォルトにリセットしました（旧内容は .bak に保存）" ;;
    *:done)          echo "setup.conf reset to template default (prior contents saved to .bak)" ;;
    zh-TW:needs_yes) echo "非互動模式：請加 --yes 才會執行 reset（避免誤刪）" ;;
    zh-CN:needs_yes) echo "非交互模式：请加 --yes 才会执行 reset（避免误删）" ;;
    ja:needs_yes)    echo "非対話モード: --yes を指定しないと reset は実行されません（誤削除防止）" ;;
    *:needs_yes)     echo "Non-interactive: pass --yes to confirm reset (prevents accidental destruction)" ;;
  esac
}

_setup_msg_stage() {
  case "${_LANG}:${1:?}" in
    zh-TW:invalid_format)           echo "Dockerfile stage 名稱格式無效，已跳過該 stage" ;;
    zh-CN:invalid_format)           echo "Dockerfile stage 名称格式无效，已跳过该 stage" ;;
    ja:invalid_format)              echo "Dockerfile stage 名のフォーマットが無効です。該当 stage はスキップされます" ;;
    *:invalid_format)               echo "invalid Dockerfile stage name format; stage skipped" ;;
    zh-TW:baseline_collision)       echo "Dockerfile stage 名稱與 template 內建 stage 衝突，請改名" ;;
    zh-CN:baseline_collision)       echo "Dockerfile stage 名称与 template 内建 stage 冲突，请改名" ;;
    ja:baseline_collision)          echo "Dockerfile stage 名が template 管理の stage と衝突しています。改名してください" ;;
    *:baseline_collision)           echo "Dockerfile stage name collides with a template-managed baseline stage; rename it" ;;
    zh-TW:reserved_tag)             echo "Dockerfile stage 名稱使用 template 控制的 image tag namespace，請改名" ;;
    zh-CN:reserved_tag)             echo "Dockerfile stage 名称使用 template 控制的 image tag namespace，请改名" ;;
    ja:reserved_tag)                echo "Dockerfile stage 名が template が管理する image tag namespace を使用しています。改名してください" ;;
    *:reserved_tag)                 echo "Dockerfile stage name uses a template-controlled image tag namespace; rename it" ;;
    zh-TW:unknown_referenced)       echo "setup.conf 內 [stage:...] 對應的 stage 在 Dockerfile 中不存在，已忽略該區段" ;;
    zh-CN:unknown_referenced)       echo "setup.conf 内 [stage:...] 对应的 stage 在 Dockerfile 中不存在，已忽略该区段" ;;
    ja:unknown_referenced)          echo "setup.conf 内の [stage:...] が指す stage が Dockerfile に存在しません。該当セクションは無視されます" ;;
    *:unknown_referenced)           echo "setup.conf [stage:...] references a stage missing from the Dockerfile; section ignored" ;;
    zh-TW:override_key_not_allowed) echo "[stage:...] 區段內含不在 per-stage 允許清單內的 key，已忽略該 key" ;;
    zh-CN:override_key_not_allowed) echo "[stage:...] 区段内含不在 per-stage 允许清单内的 key，已忽略该 key" ;;
    ja:override_key_not_allowed)    echo "[stage:...] セクション内に per-stage 許可リスト外の key が含まれています。該当 key は無視されます" ;;
    *:override_key_not_allowed)     echo "[stage:...] section contains a key outside the per-stage allowlist; key ignored" ;;
  esac
}

# Dispatcher — keeps a single _setup_msg call shape across the script.
_setup_msg_deploy() {
  case "${_LANG}:${1:?}" in
    zh-TW:runtime_deprecated) echo "[deploy] runtime 已更名為 gpu_runtime；舊鍵仍可用（永久別名），請改用 gpu_runtime（v1.0.0 將移除）" ;;
    zh-CN:runtime_deprecated) echo "[deploy] runtime 已更名为 gpu_runtime；旧键仍可用（永久别名），请改用 gpu_runtime（v1.0.0 将移除）" ;;
    ja:runtime_deprecated)    echo "[deploy] runtime は gpu_runtime に改名されました。旧キーは当面有効（恒久エイリアス）ですが gpu_runtime へ移行してください（v1.0.0 で削除）" ;;
    *:runtime_deprecated)     echo "[deploy] runtime is renamed to gpu_runtime; the old key still works (permanent alias) but please migrate to gpu_runtime (removal at v1.0.0)" ;;
  esac
}

_setup_msg() {
  local _category="${1:?_setup_msg requires category}"
  local _key="${2:?_setup_msg requires key}"
  "_setup_msg_${_category}" "${_key}"
}

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# ════════════════════════════════════════════════════════════════════
# usage
#
# Prints CLI help. Phase A: English-only text; case scaffolding is in
# place so per-language translations can be added without restructuring.
# ════════════════════════════════════════════════════════════════════
usage() {
  case "${_LANG}" in
    *)
      cat >&2 <<'EOF'
Usage: ./setup.sh [<subcommand>] [-h|--help] [--base-path <path>] [--lang <en|zh-TW|zh-CN|ja>]

Regenerate .env + compose.yaml from setup.conf + system detection.
Normally invoked indirectly via `./build.sh --setup` or `./setup_tui.sh`
Save; run directly for non-interactive / scripted / CI use.

Subcommands:
  apply         (default) Regenerate .env + compose.yaml. No-arg
                invocation falls back to apply for backward compat.
  check-drift   Compare current system / setup.conf against .env's
                SETUP_* metadata. Exit 0 when in sync, exit 1 (with
                drift descriptions on stderr) when regen is needed.
                Used by build.sh / run.sh to decide auto-regen.
  set <section>.<key> <value>
                Write a single value into <base-path>/config/docker/setup.conf
                (creates the section / key if missing). Validates
                known typed keys (deploy.gpu_count / volumes.mount_*
                / devices.cgroup_rule_* / network.port_* /
                environment.env_* / resources.shm_size). Does NOT
                regenerate .env — run `apply` afterwards if needed.
  show <section>[.<key>]
                Print the value of a single key, or all key=value
                pairs in a section (in on-disk order). Exits non-zero
                when the section / key is absent.
  list [<section>]
                Without an arg: print every section header + key in
                setup.conf. With an arg: equivalent to `show <section>`.
  add <section>.<list> <value>
                Append a value to a list-style section. Picks the next
                free numeric suffix (max+1) and writes `<list>_N = <value>`.
                e.g. `add volumes.mount /foo:/bar` lands in `mount_<next>`.
                Same validators as `set`.
  remove <section>.<key>            Delete the exact key.
  remove <section>.<list> <value>   Delete the first key under the
                section matching `<list>_*` whose value equals <value>.
  reset [-y|--yes]
                Overwrite setup.conf with the template default. Prior
                setup.conf / .env are saved to setup.conf.bak / .env.bak.
                Without --yes, prompts for confirmation; non-tty
                without --yes refuses to proceed.
  deploy [--stage S] [--output F] [--dry-run] [-y|--yes]
                Build a self-contained field bundle for stage S (default
                runtime): bake [environment] as ENV + COPY config/app
                into the image, docker build --target S, generate
                deploy.sh, docker save, and tar.xz {image, deploy.sh}.
                Previews the resolved launcher (every inlined docker
                flag) and prompts before building; --dry-run prints the
                plan only; -y skips the prompt. Default output is
                <base-path>/deploy/<name>-<stage>.tar.xz. Field flow:
                extract, docker load < image.tar, ./deploy.sh.

Options:
  -h, --help            Show this help and exit.
  --base-path PATH      Repo root to operate on. Defaults to the repo
                        containing this script (.base/../..).
  --lang LANG           Set message language (en|zh-TW|zh-CN|ja).
                        Defaults to $SETUP_LANG or auto-detected from
                        $LANG.
  -q, --quiet           Suppress the success-confirmation lines on
                        set / add / remove / reset / apply. Errors
                        still go to stderr. Used by setup_tui.sh to
                        avoid double-printing after its `[tui] saved`
                        line.

Apply-only options (#338):
  --gui auto|force|off  Per-invocation override for [gui] mode. Wins
                        over $SETUP_GUI env var and setup.conf. Useful
                        for debugging X11 or one-off headless runs on
                        a GUI repo. Equivalent forms: `--gui=auto`.
  --no-x11-cookie       Skip the SSH X11 cookie rewrite even when
                        SSH X11 forwarding is detected. GUI itself
                        stays enabled per [gui] mode resolution;
                        $XAUTHORITY stays at the host value the user's
                        SSH session populated. Debug knob for #321.
  --print-resolved      Run all detection + resolution logic and
                        print the effective state to stdout as
                        `KEY=VALUE` lines (one per line), then exit
                        without writing .env / compose.yaml /
                        .gitignore. Subsumes the dry-run piece of
                        the #230 base-mcp setup_resolve plan.

Outputs (apply only — both derived artifacts, gitignored):
  <base-path>/.env          Exported variables + SETUP_* drift metadata
  <base-path>/compose.yaml  Full compose with baseline + conditional
                            blocks (GPU / GUI / extra volumes / etc.)

Source of truth is setup.conf (template default + optional per-repo
override via section-replace). Edit setup.conf, not the derived files.
EOF
      ;;
  esac
  exit 0
}


# ════════════════════════════════════════════════════════════════════
# INI parser for setup.conf
#
# _parse_ini_section moved to lib/conf.sh in (PR-B) so init.sh
# can reach it via _lib.sh without sourcing setup.sh. The function
# stays callable from this file via the same name (_lib.sh sources
# conf.sh in the umbrella loader near setup.sh's top).
# ════════════════════════════════════════════════════════════════════

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# Merges per-repo setup.conf with template default, section-replace
# strategy: if per-repo setup.conf has the section, use its entries;
# otherwise fall back to the template's section. SETUP_CONF env var forces
# a specific file (skips the merge entirely).
#
# collapsed back to 2-file model. <repo>/setup.conf is the user
# override (committed, not gitignored, survives template upgrade because
# template subtree pull never touches it — it lives outside .base).
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

  local _self_dir="${_SETUP_SCRIPT_DIR}"
  local _template_conf="${_self_dir}/../../../config/docker/setup.conf"
  local _repo_conf="${_base}/config/docker/setup.conf"

  # Try per-repo setup.conf first; if the section exists there, use it.
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

# _setup_conf_handle <base> <handle>
#
# Load the effective setup.conf into an opaque conf.sh <handle>: honours the
# SETUP_CONF override (single file, no merge), otherwise the template +
# per-repo section-replace merge (same precedence as _load_setup_conf, but as
# one queryable handle for the _conf_get / _conf_list_sorted accessors). The
# single place that resolves the template / repo / SETUP_CONF paths for the
# accessor readers.
_setup_conf_handle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base"}"
  local _h="${2:?"${FUNCNAME[0]}: missing handle"}"
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _conf_load "${SETUP_CONF}" "${_h}"
    return 0
  fi
  _conf_load_merged \
    "${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf" \
    "${_base}/config/docker/setup.conf" \
    "${_h}"
}

# _setup_load_merged_full <template_path> <local_path> \
#                         <sections_outvar> <keys_outvar> <values_outvar>
#
# Returns the section-replace merged view of <template_path> overlaid by
# <local_path>: for each section present in .local, the template's
# entries for that section are replaced wholesale by .local's entries;
# sections .local omits keep template values.
#
# Output arrays mirror `_load_setup_conf_full` shape: sections list +
# parallel `<section>.<key>` and value arrays. Used by `show`/`list` so
# users see effective post-apply values without having to re-run apply
# after every set/add/remove.
#
# replaces direct reads of <base>/setup.conf in show/list, since
# setup.conf is now the materialized output of apply (potentially stale
# until the next apply).
_setup_load_merged_full() {
  local _tpl="${1:?}"
  local _loc="${2:?}"
  local -n _slm_sections="${3:?}"
  local -n _slm_keys="${4:?}"
  local -n _slm_values="${5:?}"

  _slm_sections=()
  _slm_keys=()
  _slm_values=()

  local -a _tpl_sects=() _tpl_keys=() _tpl_vals=()
  local -a _loc_sects=() _loc_keys=() _loc_vals=()
  if [[ -f "${_tpl}" ]]; then
    _load_setup_conf_full "${_tpl}" _tpl_sects _tpl_keys _tpl_vals
  fi
  if [[ -f "${_loc}" ]]; then
    _load_setup_conf_full "${_loc}" _loc_sects _loc_keys _loc_vals
  fi

  # Sections appearing only in template, in template order, then any
  # section in .local that template lacks.
  local _s
  for _s in "${_tpl_sects[@]}"; do
    _slm_sections+=("${_s}")
  done
  for _s in "${_loc_sects[@]}"; do
    local _seen=0 _e
    for _e in "${_slm_sections[@]}"; do
      [[ "${_e}" == "${_s}" ]] && { _seen=1; break; }
    done
    (( _seen )) || _slm_sections+=("${_s}")
  done

  # For each section in the union: if .local has it, copy .local's
  # entries (replace strategy); else copy template's entries.
  local _sec _i _ns
  for _sec in "${_slm_sections[@]}"; do
    local _local_has=0
    for _e in "${_loc_sects[@]}"; do
      [[ "${_e}" == "${_sec}" ]] && { _local_has=1; break; }
    done
    if (( _local_has )); then
      for (( _i=0; _i<${#_loc_keys[@]}; _i++ )); do
        _ns="${_loc_keys[_i]}"
        if [[ "${_ns}" == "${_sec}."* ]]; then
          _slm_keys+=("${_ns}")
          _slm_values+=("${_loc_vals[_i]}")
        fi
      done
    else
      for (( _i=0; _i<${#_tpl_keys[@]}; _i++ )); do
        _ns="${_tpl_keys[_i]}"
        if [[ "${_ns}" == "${_sec}."* ]]; then
          _slm_keys+=("${_ns}")
          _slm_values+=("${_tpl_vals[_i]}")
        fi
      done
    fi
  done
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
      # Only numeric suffixes participate; empty values mean opt-out
      [[ "${__gcls_num}" =~ ^[0-9]+$ ]] || continue
      [[ -z "${_gcls_values[i]}" ]] && continue
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
# Rule applicators for [image] rules (used by detect_image_name)
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

# _detect_jetson
#   True if running on Jetson (JetPack / L4T) — NVIDIA ships
#   /etc/nv_tegra_release as the canonical marker on tegra-based boards.
#   Env override: SETUP_DETECT_JETSON=true|false forces detection result
#   (used by tests to avoid touching /etc).
_detect_jetson() {
  if [[ -n "${SETUP_DETECT_JETSON:-}" ]]; then
    [[ "${SETUP_DETECT_JETSON}" == "true" ]]
    return
  fi
  [[ -f "/etc/nv_tegra_release" ]]
}

# _detect_dri_groups
#   Echo space-separated unique numeric GIDs that own the host's
#   /dev/dri/{card*,renderD*} nodes so a container can be granted
#   /dev/dri access via group_add on non-NVIDIA (Intel/AMD iGPU) hosts.
#   Numeric GIDs only -- the render GID varies per host, so names are
#   non-portable. Echoes empty when /dev/dri is absent (graceful).
#   Env override SETUP_DETECT_DRI_GROUPS forces the result (used by tests
#   to avoid touching /dev/dri).
_detect_dri_groups() {
  if [[ -n "${SETUP_DETECT_DRI_GROUPS:-}" ]]; then
    printf '%s' "${SETUP_DETECT_DRI_GROUPS}"
    return 0
  fi
  local _gids
  # stat over a non-matching glob just yields no output (stderr suppressed);
  # sort -u dedups the common case where card* + renderD* share the video GID.
  _gids="$(stat -c %g /dev/dri/card* /dev/dri/renderD* 2>/dev/null \
             | sort -u | tr '\n' ' ')"
  printf '%s' "${_gids% }"
}

# _resolve_runtime <mode> <outvar>
#   mode=nvidia → "nvidia" (force, e.g. desktop with csv-mode toolkit)
#   mode=auto   → "nvidia" iff _detect_jetson, else ""
#   mode=off|"" → "" (no runtime key emitted; Docker default runc)
#
# When non-empty, setup.sh emits `runtime: <value>` at service level in
# compose.yaml. Required on Jetson because its nvidia-container-toolkit
# runs in csv mode, which refuses the modern `--gpus` flow that
# `deploy.resources.reservations.devices` translates to.
_resolve_runtime() {
  local _mode="${1:-off}"
  local -n _rr_out="${2:?}"
  case "${_mode}" in
    nvidia) _rr_out="nvidia" ;;
    auto)
      if _detect_jetson; then _rr_out="nvidia"; else _rr_out=""; fi
      ;;
    off|""|*) _rr_out="" ;;
  esac
}

# _resolve_build_network <mode> <outvar>
#   mode=host / bridge / none / default → pass through
#   mode=auto → "host" iff _detect_jetson, else ""
#   mode=off | "" → "" (no network key emitted; Docker defaults to bridge)
#
# Jetson L4T kernels commonly lack the iptables modules docker's bridge
# NAT needs, so first-time `docker build` on Jetson dies with DNS
# resolution failures before the apt step. Auto-promoting to host-net
# on Jetson removes the trap door; desktop hosts keep default bridge.
_resolve_build_network() {
  local _mode="${1:-}"
  local -n _rbn_out="${2:?}"
  case "${_mode}" in
    host|bridge|none|default) _rbn_out="${_mode}" ;;
    auto)
      if _detect_jetson; then _rbn_out="host"; else _rbn_out=""; fi
      ;;
    off|""|*) _rbn_out="" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash <base_path> <outvar>
#
# sha256 of the effective config (template default + per-repo
# setup.conf override). Used to detect conf drift in build.sh/run.sh.
# Drift means "user changed their override (or template was upgraded)".
# ════════════════════════════════════════════════════════════════════
_compute_conf_hash() {
  local _base="${1:?}"
  local -n _cch_out="${2:?}"
  local _self_dir="${_SETUP_SCRIPT_DIR}"
  local _template_conf="${_self_dir}/../../../config/docker/setup.conf"
  local _repo_conf="${_base}/config/docker/setup.conf"

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
# Stage helpers
# ════════════════════════════════════════════════════════════════════

# _validate_stage_name <stage>
#
# Returns:
#   0 — valid; auto-emit as compose service
#   1 — invalid format (caller WARNs + skips, continues parsing other stages)
#   2 — collides with template-managed baseline
#       {sys, devel-base, devel, devel-test, runtime-test}; hard error
#       (caller exits non-zero). For backward compatibility during the
#       v0.21.x transition the legacy names {base, test} are also
#       accepted as baseline (downstream Dockerfiles renamed to
#       devel-base / devel-test over a coordinated rollout); they will
#       be removed from the blocklist in a future major release.
#   3 — collides with template-controlled image-tag namespace
#       ({latest} | v[0-9]*); hard error
#
# Exit codes are distinct so the parser/emitter can react differently
# (skip-with-warn vs abort) without re-validating.
_validate_stage_name() {
  local _stage="$1"
  # Order matters: collision / reserved checks fire BEFORE format check
  # so a name that matches both a reserved pattern AND has a format
  # quirk (e.g. `v1.2` — dotted, but still in v[0-9]* reserved
  # namespace) gets the more severe verdict (hard error 3) instead of
  # the milder format-only verdict (skip 1). Same name should not
  # silently drop as "invalid format" if its real problem is namespace
  # collision.

  # 1. baseline collision (template-managed stages)
  #    Forward-looking: sys / devel-base / devel / runtime-test
  #    Legacy (backward-compat during v0.21.x transition): base / test
  #    (A1'-b): `devel-test` is NOT in this set — it is emitted as a
  #    compose service (legacy name `test`) through the per-stage
  #    inherit-with-override loop, so `[stage:devel-test]` gives it a
  #    runtime control surface (e.g. GPU pytest). The service name `test`
  #    stays blocklisted below so a Dockerfile `AS test` can't collide
  #    with devel-test's emitted service.
  case "${_stage}" in
    sys|devel-base|devel|runtime-test) return 2 ;;
    base|test) return 2 ;;
  esac
  # 2. reserved tag namespace (template-controlled tag slots)
  case "${_stage}" in
    latest)   return 3 ;;
    v[0-9]*)  return 3 ;;
  esac
  # 3. format check (lowercase, leading letter, [a-z0-9_-])
  [[ "${_stage}" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  return 0
}

# _parse_dockerfile_stages <dockerfile_path>
#
# Reads `^FROM <base> AS <stage>` lines from the Dockerfile, dedups,
# filters out the baseline blocklist {sys, devel-base, devel,
# devel-test, runtime-test} (plus the legacy {base, test} accepted
# during the v0.21.x transition), and echoes the surviving stages
# one per line preserving file order.
#
# Match rules:
#   - Line must start with `FROM` (case-sensitive — Docker spec is
#     case-insensitive but tooling convention is uppercase)
#   - `AS` keyword must be uppercase (lowercase `as` is technically valid
#     but treated as user typo / hand-edited and ignored)
#   - Comments (#) on the line block the match — only bare directives count
#   - Trailing whitespace tolerated
#
# Missing Dockerfile → empty output (silent), exit 0. Caller decides
# whether to treat that as "no extra stages" or an error.
_parse_dockerfile_stages() {
  local _dockerfile="$1"
  [[ -f "${_dockerfile}" ]] || return 0
  # Read the Dockerfile directly (no grep|awk pipe) so an empty match
  # set under `set -o pipefail` does not propagate exit 1 back through
  # process substitution. BASH_REMATCH captures the stage name from
  # the same regex shape grep used.
  local _line _stage _seen=" "
  while IFS= read -r _line; do
    [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+([^[:space:]#]+)[[:space:]]*$ ]] || continue
    _stage="${BASH_REMATCH[1]}"
    case "${_stage}" in
      sys|devel-base|devel|runtime-test) continue ;;
      base|test) continue ;;
    esac
    case "${_seen}" in
      *" ${_stage} "*) continue ;;  # already emitted (dedup)
    esac
    _seen+="${_stage} "
    printf '%s\n' "${_stage}"
  done < "${_dockerfile}"
  return 0
}

# _compute_dockerfile_hash <base_path> <outvar>
#
# sha256 of the Dockerfile's stage-list projection (just `FROM ... AS
# <stage>` lines), NOT the whole Dockerfile. Drift detection scope:
# adding/removing a stage changes which compose services exist, so the
# hash must change on those edits — but unrelated `RUN apt-get install`
# changes must not, otherwise every Dockerfile edit triggers a full
# compose regen.
#
# Empty output if Dockerfile is missing (caller decides what to do).
_compute_dockerfile_hash() {
  local _base="${1:?}"
  local -n _cdh_out="${2:?}"
  local _dockerfile="${_base}/Dockerfile"
  if [[ ! -f "${_dockerfile}" ]]; then
    _cdh_out=""
    return 0
  fi
  # Build the stage-list projection inline (no grep|sha256sum pipe) so
  # an empty match set under pipefail does not propagate failure. The
  # regex matches grep's exact shape used by _parse_dockerfile_stages.
  local _line _stage_lines=""
  while IFS= read -r _line; do
    [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+[^[:space:]#]+[[:space:]]*$ ]] || continue
    _stage_lines+="${_line}"$'\n'
  done < "${_dockerfile}"
  _cdh_out="$(printf '%s' "${_stage_lines}" | sha256sum | cut -d' ' -f1)"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _generate_runtime_dockerfile <dockerfile> <env_str> <out>
#
# S3 ofbake the `[environment]` defaults as `ENV` into the
# runtime stage so a bare `docker run <runtime-image>` carries sane
# defaults with no env file -- delivery channel 1 (the only one that
# reaches the field). Copies <dockerfile> to <out>, inserting an
# `ENV KEY="VALUE"` block immediately after the `FROM ... AS runtime`
# line. <env_str> is the newline-separated `KEY=VALUE` [environment]
# list; cross-refs (`${KEY}`) are expanded against earlier siblings, the
# same way the compose `environment:` block does.
#
# Returns 0 and writes <out> only when the Dockerfile declares an
# `AS runtime` stage AND <env_str> is non-empty; returns 1 (writes
# nothing) otherwise, so a repo with no runtime stage keeps building from
# the plain Dockerfile (zero behaviour change). The dev `.env` overlay
# (S2) and `deploy.sh -e` (S6) still override these baked defaults at run
# time, because container env_file / environment beats image `ENV`.
# ════════════════════════════════════════════════════════════════════
_generate_runtime_dockerfile() {
  local _dockerfile="${1:?}"
  local _env_str="${2:-}"
  local _out="${3:?}"

  [[ -f "${_dockerfile}" && -n "${_env_str}" ]] || return 1

  local _line _has_runtime=0
  while IFS= read -r _line; do
    if [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+runtime[[:space:]]*$ ]]; then
      _has_runtime=1
      break
    fi
  done < "${_dockerfile}"
  (( _has_runtime )) || return 1

  local -a _env_expanded=()
  _expand_env_cross_refs "${_env_str}" _env_expanded

  local _tmp
  _tmp="$(mktemp "${_out}.XXXXXX")"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}" >> "${_tmp}"
    if [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+runtime[[:space:]]*$ ]]; then
      printf '# >>> [environment] baked defaults (generated by setup.sh, #503) <<<\n' >> "${_tmp}"
      local _kv _k _v
      for _kv in "${_env_expanded[@]}"; do
        [[ -z "${_kv}" || "${_kv}" != *=* ]] && continue
        _k="${_kv%%=*}"
        _v="${_kv#*=}"
        # The value is baked into a double-quoted `ENV K="<v>"` line. A
        # raw `"` would unbalance the quotes (`ENV MSG="say "hi""`) and a
        # `$` would trigger Dockerfile ENV expansion / shell command
        # substitution (`$(id)`) at build time instead of landing
        # literally. Escape backslash first, then `"` and `$`, so the
        # configured value is baked verbatim.
        _v="${_v//\\/\\\\}"
        _v="${_v//\"/\\\"}"
        _v="${_v//\$/\\\$}"
        printf 'ENV %s="%s"\n' "${_k}" "${_v}" >> "${_tmp}"
      done
    fi
  done < "${_dockerfile}"
  mv -- "${_tmp}" "${_out}"
  return 0
}


# ════════════════════════════════════════════════════════════════════
# Per-stage overrides
#
# `[stage:<name>]` sections in <repo>/setup.conf override top-level
# settings on a per-stage basis. Only the v1 allowlist (gui.mode, the
# whole [deploy] / [network] blocks, security.privileged, [volumes]
# mounts, [environment] env_*) is honored — anything else is WARN'd
# and skipped by the validator.
#
# List fields use append-default + opt-out semantics: stage's `mount_*`
# / `port_*` / `env_*` items are appended to the top-level list unless
# the matching `<list>_inherit = false` flag is set, in which case
# only the stage's own entries survive.
# ════════════════════════════════════════════════════════════════════

# _parse_stage_sections <file> <out_array_var>
#
# Scans <file> for `^\[stage:NAME\]$` headers, returns NAME list in
# file order. Stage names matching `[a-z][a-z0-9_-]*` are collected;
# malformed names are silently skipped here (caller surfaces them
# via _validate_stage_name). Empty / missing file → empty output.
_parse_stage_sections() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _pss_out="${2:?"${FUNCNAME[0]}: missing out array"}"
  _pss_out=()
  [[ -f "${_file}" ]] || return 0
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ^\[stage:([a-z][a-z0-9_-]*)\][[:space:]]*$ ]]; then
      _pss_out+=("${BASH_REMATCH[1]}")
    fi
  done < "${_file}"
}

# _load_stage_overrides <base_path> <stage> <keys_outvar> <values_outvar>
#
# Reads the `[stage:<stage>]` section from <base_path>/setup.conf into
# parallel arrays. Stage sections only live in the per-repo file
# (template's setup.conf doesn't carry stage overrides — it doesn't
# know which Dockerfile stages exist downstream). Honors SETUP_CONF
# the same way _load_setup_conf does.
_load_stage_overrides() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local -n _lso_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lso_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"
  _lso_keys=()
  _lso_values=()

  local _conf
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _conf="${SETUP_CONF}"
  else
    _conf="${_base}/config/docker/setup.conf"
  fi
  [[ -f "${_conf}" ]] || return 0
  _parse_ini_section "${_conf}" "stage:${_stage}" _lso_keys _lso_values
}

# _validate_stage_override_key <key>
#
# Returns 0 when <key> is in the v1 per-stage override allowlist,
# 1 otherwise. Allowlist scope:
#
#   [deploy]      gpu_mode, gpu_count, gpu_capabilities, runtime
#   [gui]         mode
#   [network]     mode, ipc, pid, network_name, port_<N>, port_inherit
#   [security]    privileged, cap_add_<N>, cap_add_inherit,
#                 cap_drop_<N>, cap_drop_inherit,
#                 security_opt_<N>, security_opt_inherit
#   [volumes]     mount_<N>, mount_inherit
#   [environment] env_<N>, env_inherit
#
# security cap_add / cap_drop / security_opt: added in v2 once a
# real downstream need surfaced (jetson_sdk_manager#69 — per-stage caps so
# a read-only probe stage drops the flash stage's SYS_ADMIN). Same
# append-by-default / *_inherit=false-replaces list convention as
# volumes / env / ports.
#
# Excluded by design:
#   [image_name] / [build] / [devices] / [tmpfs] /
#   [additional_contexts] / [resources] — outside the "Isaac Sim
#   per-stage runtime" use case driving them. Re-evaluate once a real
#   downstream need surfaces.
_validate_stage_override_key() {
  local _key="${1:?"${FUNCNAME[0]}: missing key"}"
  case "${_key}" in
    deploy.gpu_mode|deploy.gpu_count|deploy.gpu_capabilities|deploy.gpu_runtime|deploy.runtime) return 0 ;;
    gui.mode) return 0 ;;
    network.mode|network.ipc|network.pid|network.network_name) return 0 ;;
    security.privileged) return 0 ;;
    network.port_inherit|volumes.mount_inherit|environment.env_inherit) return 0 ;;
    security.cap_add_inherit|security.cap_drop_inherit|security.security_opt_inherit) return 0 ;;
  esac
  if [[ "${_key}" =~ ^(network\.port|volumes\.mount|environment\.env|security\.cap_add|security\.cap_drop|security\.security_opt)_[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

# _resolve_stage_scalar <keys_var> <values_var> <key> <fallback> <out_var>
#
# Look up <key> in the stage's parallel arrays. If found, set <out_var>
# to that value; otherwise set <out_var> to <fallback>. Used for
# per-stage scalar overrides (gui.mode, network.mode, etc.) where there
# is no merge — the stage value either replaces the top-level or
# falls through entirely.
_resolve_stage_scalar() {
  local -n _rss_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rss_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _fallback="${4-}"
  local -n _rss_out="${5:?"${FUNCNAME[0]}: missing out var"}"
  local i
  for (( i = 0; i < ${#_rss_keys[@]}; i++ )); do
    if [[ "${_rss_keys[i]}" == "${_key}" ]]; then
      _rss_out="${_rss_values[i]}"
      return 0
    fi
  done
  _rss_out="${_fallback}"
}

# _resolve_stage_list <keys_var> <values_var> <prefix> <inherit_key> \
#                     <top_level_str> <out_var>
#
# Computes the effective list for a list field (volumes.mount_*,
# network.port_*, environment.env_*) on a per-stage basis.
#
# Args:
#   keys_var / values_var  Stage's parallel override arrays
#   prefix                 Full dotted prefix e.g. "volumes.mount_"
#                          — keys matching `<prefix>[0-9]+` are list items
#   inherit_key            Meta-key e.g. "volumes.mount_inherit"
#                          — value "false" switches to replace mode
#   top_level_str          Newline-separated top-level list (the same
#                          aggregate format setup.sh uses elsewhere)
#   out_var                Newline-separated effective list (no
#                          trailing newline)
#
# Default (inherit unspecified or anything ≠ "false"): top-level entries
# come first, stage entries appended afterward in setup.conf order.
# Replace mode (inherit=false): only stage entries appear; top-level
# is dropped. The opt-out lets a stage opt out of inherited mounts
# entirely (e.g. headless that wants no host-side ssh keys, regardless
# of the top-level mount_2 setting).
_resolve_stage_list() {
  local -n _rsl_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rsl_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local _prefix="${3:?"${FUNCNAME[0]}: missing prefix"}"
  local _inherit_key="${4:?"${FUNCNAME[0]}: missing inherit_key"}"
  local _top="${5-}"
  local -n _rsl_out="${6:?"${FUNCNAME[0]}: missing out var"}"

  # Default to inheriting top-level. Only the literal "false" toggles
  # replace mode — anything else (including "true", empty, malformed)
  # keeps the safe append-default behavior.
  local _inherit="true" i
  for (( i = 0; i < ${#_rsl_keys[@]}; i++ )); do
    if [[ "${_rsl_keys[i]}" == "${_inherit_key}" ]]; then
      [[ "${_rsl_values[i]}" == "false" ]] && _inherit="false"
      break
    fi
  done

  # Collect stage's own list entries in setup.conf order. Match only
  # `<prefix><digits>` so meta-keys like `mount_inherit` (which share
  # the prefix) are not pulled in.
  local -a _stage_entries=()
  local _suffix
  for (( i = 0; i < ${#_rsl_keys[@]}; i++ )); do
    [[ "${_rsl_keys[i]}" == "${_prefix}"* ]] || continue
    _suffix="${_rsl_keys[i]#"${_prefix}"}"
    [[ "${_suffix}" =~ ^[0-9]+$ ]] || continue
    _stage_entries+=("${_rsl_values[i]}")
  done

  if [[ "${_inherit}" == "true" ]]; then
    if [[ -n "${_top}" ]] && (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="${_top}"$'\n'"$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    elif [[ -n "${_top}" ]]; then
      _rsl_out="${_top}"
    elif (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    else
      _rsl_out=""
    fi
  else
    if (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    else
      _rsl_out=""
    fi
  fi
}

# _resolve_docker_flags <stage_keys> <stage_values> <parent_assoc> <out_assoc>
#
# THE single per-stage docker-flag resolution layer. Given one
# stage's [stage:<name>] overrides (already filtered to the allowlist)
# layered over the parent (devel / top-level) already-resolved values,
# it computes the stage's effective docker flags into <out_assoc>.
#
# Both renderers call this so per-stage semantics never drift:
#   - the compose renderer (generate_compose_yaml's per-stage loop), and
#   - the deploy renderer (S6), which resolves the runtime stage's
#     flags to emit a field docker-run launcher.
#
# Modes (gui / gpu) inherit the parent's already-resolved boolean unless
# the stage forces off / force — per-stage does NOT re-detect hardware
# (that host-specific detection is the global resolution's job, upstream
# of this layer). Other scalars fall back to the parent's effective
# value; list fields (volumes / environment / ports) delegate to
# _resolve_stage_list (append-by-default, replace on `*_inherit = false`).
#
# Args:
#   $1 stage_keys    (array ref)  filtered [stage:*] override keys
#   $2 stage_values  (array ref)  parallel override values
#   $3 parent        (assoc ref)  parent fallbacks + top-level lists:
#        gui gpu gpu_count gpu_caps runtime net_mode ipc_mode pid_mode
#        net_name volumes_top env_top ports_top
#        cap_add_top cap_drop_top sec_opt_top
#   $4 out           (assoc ref)  effective record, keys:
#        gui gpu gpu_count gpu_caps runtime net_mode ipc_mode pid_mode
#        net_name privileged volumes environment ports
#        cap_add cap_drop security_opt
_resolve_docker_flags() {
  local -n _rdf_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rdf_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local -n _rdf_parent="${3:?"${FUNCNAME[0]}: missing parent assoc"}"
  local -n _rdf_out="${4:?"${FUNCNAME[0]}: missing out assoc"}"
  local _mode _tmp

  # gui / gpu: off|force decide outright; anything else (incl. absent or
  # "auto") inherits the parent's already-resolved boolean. Assoc-array
  # subscripts are quoted as string literals so ShellCheck does not read
  # them as arithmetic variable references (SC2154) -- _rdf_out is a
  # nameref, so ShellCheck cannot infer it is associative.
  _resolve_stage_scalar _rdf_keys _rdf_values "gui.mode" "" _mode
  case "${_mode}" in
    off)   _rdf_out["gui"]="false" ;;
    force) _rdf_out["gui"]="true" ;;
    *)     _rdf_out["gui"]="${_rdf_parent["gui"]}" ;;
  esac

  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_mode" "" _mode
  case "${_mode}" in
    off)   _rdf_out["gpu"]="false" ;;
    force) _rdf_out["gpu"]="true" ;;
    *)     _rdf_out["gpu"]="${_rdf_parent["gpu"]}" ;;
  esac

  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_count" "${_rdf_parent["gpu_count"]}" _tmp
  _rdf_out["gpu_count"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_capabilities" "${_rdf_parent["gpu_caps"]}" _tmp
  _rdf_out["gpu_caps"]="${_tmp}"

  # gpu_runtime primary, legacy deploy.runtime alias as fallback.
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_runtime" "${_rdf_parent["runtime"]}" _tmp
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.runtime" "${_tmp}" _tmp
  _rdf_out["runtime"]="${_tmp}"

  _resolve_stage_scalar _rdf_keys _rdf_values "network.mode" "${_rdf_parent["net_mode"]}" _tmp
  _rdf_out["net_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.ipc" "${_rdf_parent["ipc_mode"]}" _tmp
  _rdf_out["ipc_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.pid" "${_rdf_parent["pid_mode"]}" _tmp
  _rdf_out["pid_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.network_name" "${_rdf_parent["net_name"]}" _tmp
  _rdf_out["net_name"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "security.privileged" "" _tmp
  _rdf_out["privileged"]="${_tmp}"

  _resolve_stage_list _rdf_keys _rdf_values "volumes.mount_" "volumes.mount_inherit" "${_rdf_parent["volumes_top"]}" _tmp
  _rdf_out["volumes"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "environment.env_" "environment.env_inherit" "${_rdf_parent["env_top"]}" _tmp
  _rdf_out["environment"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "network.port_" "network.port_inherit" "${_rdf_parent["ports_top"]}" _tmp
  _rdf_out["ports"]="${_tmp}"

  # per-stage [security] cap_add / cap_drop / security_opt as list
  # fields, same append-by-default / *_inherit=false-replaces convention as
  # volumes / env / ports above. A stage sets `cap_add_inherit = false`
  # (and lists no entries) to drop all inherited caps — e.g. a read-only
  # probe stage that should not inherit the flash stage's SYS_ADMIN.
  _resolve_stage_list _rdf_keys _rdf_values "security.cap_add_" "security.cap_add_inherit" "${_rdf_parent["cap_add_top"]}" _tmp
  _rdf_out["cap_add"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "security.cap_drop_" "security.cap_drop_inherit" "${_rdf_parent["cap_drop_top"]}" _tmp
  _rdf_out["cap_drop"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "security.security_opt_" "security.security_opt_inherit" "${_rdf_parent["sec_opt_top"]}" _tmp
  _rdf_out["security_opt"]="${_tmp}"
}



# ════════════════════════════════════════════════════════════════════
# write_env
#
# Usage: write_env <env_file> <user_name> <user_group> <uid> <gid>
#                  <hardware> <docker_hub_user> <gpu_detected>
#                  <image_name> <ws_path>
#                  <apt_mirror_ubuntu> <apt_mirror_debian> <tz>
#                  <network_mode> <ipc_mode> <pid_mode> <privileged>
#                  <gpu_count> <gpu_caps>
#                  <gui_detected> <conf_hash>
#                  [<network_name>] [<user_build_args>] [<target_arch>]
#
# user_build_args is a newline-separated list of "KEY=VALUE" pairs
# from `[build] arg_N` entries outside the three known keys
# (APT_MIRROR_UBUNTU / APT_MIRROR_DEBIAN / TZ). Each pair is appended
# as an exported env var so compose.yaml's generated build.args block
# can reference them via ${KEY}.
#
# target_arch (optional): when non-empty, exported as TARGET_ARCH so
# build.sh / compose.yaml can force the Docker TARGETARCH build arg.
# Empty/omitted means "don't touch" — BuildKit's auto-detection of the
# host / --platform stays intact.
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
  local _tz="${1}"; shift
  local _network_mode="${1}"; shift
  local _ipc_mode="${1}"; shift
  local _pid_mode="${1}"; shift
  local _privileged="${1}"; shift
  local _gpu_count="${1}"; shift
  local _gpu_caps="${1}"; shift
  local _gui_detected="${1}"; shift
  local _conf_hash="${1}"; shift
  local _dockerfile_hash="${1}"; shift
  local _network_name="${1:-}"; shift || true
  local _user_build_args="${1:-}"; shift || true
  local _target_arch="${1:-}"; shift || true
  local _build_network="${1:-}"; shift || true
  # SSH X11 forwarding cookie override. Empty when not in an
  # SSH X11 session, in which case host's XAUTHORITY flows through to
  # compose unchanged.
  local _ssh_x11_xauth="${1:-}"

  local _comment=""
  _comment="$(_setup_msg env comment)"
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

# ── Timezone ─────────────────────────────────
TZ=${_tz}

# ── Runtime config (from setup.conf) ─────────
NETWORK_MODE=${_network_mode}
NETWORK_NAME=${_network_name}
IPC_MODE=${_ipc_mode}
PID_MODE=${_pid_mode}
PRIVILEGED=${_privileged}
GPU_COUNT=${_gpu_count}
GPU_CAPABILITIES="${_gpu_caps}"

# ── Setup metadata (drift detection — do not edit) ──
SETUP_CONF_HASH=${_conf_hash}
SETUP_DOCKERFILE_HASH=${_dockerfile_hash}
SETUP_GUI_DETECTED=${_gui_detected}
SETUP_TIMESTAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
EOF

  # ── SSH X11 forwarding cookie override ──
  # Set by apply flow when _is_ssh_x11 detects an SSH X11 session.
  # Compose reads .env via --env-file and uses the value here for
  # `${XAUTHORITY:-}` substitution in the GUI block. Without this,
  # libX11 inside the container looks up the cookie under the
  # container's hostname (a Docker-assigned random) and fails because
  # SSH wrote the cookie keyed to the host's hostname. The rewritten
  # cookie at .docker.xauth uses the `ffff` family code so the
  # hostname check is skipped.
  if [[ -n "${_ssh_x11_xauth:-}" ]]; then
    {
      printf '\n# ── SSH X11 forwarding cookie override (#321) ──\n'
      printf 'XAUTHORITY=%s\n' "${_ssh_x11_xauth}"
    } >> "${_env_file}"
  fi

  # ── Extra [build] args (user-added, beyond APT_MIRROR_* / TZ) ──
  # Appended after the fixed block so downstream consumers read them
  # via the same set -o allexport source.
  if [[ -n "${_user_build_args:-}" ]]; then
    {
      printf '\n# ── Extra build args (from [build] arg_N) ──\n'
      local _line _k _v
      while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        _k="${_line%%=*}"
        _v="${_line#*=}"
        # Quote the value so multi-word / shell-metachar values round-trip
        # safely through `source .env` (regression: GPU_CAPABILITIES).
        printf '%s=%q\n' "${_k}" "${_v}"
      done <<< "${_user_build_args}"
    } >> "${_env_file}"
  fi

  # TARGETARCH override: only emit when the user explicitly set it in
  # [build] target_arch. Empty stays unset so build.sh / compose skip
  # the --build-arg and BuildKit's auto-fill kicks in.
  if [[ -n "${_target_arch:-}" ]]; then
    {
      printf '\n# ── TARGETARCH override (from [build] target_arch) ──\n'
      printf 'TARGET_ARCH=%q\n' "${_target_arch}"
    } >> "${_env_file}"
  fi

  # BUILD_NETWORK override: only emit when the user set [build] network.
  # Empty stays unset so build.sh skips the `--network` flag and docker
  # compose build inherits its default.
  if [[ -n "${_build_network:-}" ]]; then
    {
      printf '\n# ── BUILD_NETWORK override (from [build] network) ──\n'
      printf 'BUILD_NETWORK=%q\n' "${_build_network}"
    } >> "${_env_file}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _scaffold_env_overlay <path>
#
# Create the hand-authored `.env` workload overlay with guidance
# comments if it does not exist (A2 file roles). Idempotent:
# never overwrites an existing file -- the overlay is user-owned after
# its first creation, so setup.sh leaves it alone on every later apply.
# ════════════════════════════════════════════════════════════════════
_scaffold_env_overlay() {
  local _path="${1:?}"
  [[ -e "${_path}" ]] && return 0
  cat > "${_path}" << 'EOF'
# Workload overlay -- hand-authored, gitignored. setup.sh creates this
# file once and never edits it again. Put per-task / volatile env vars
# here as KEY=VALUE (e.g. ROS_DOMAIN_ID=42, LOG_LEVEL=debug, API tokens).
# They are injected into the container via `env_file: - .env` and take
# effect with only `just run` -- no regenerate, no SETUP_CONF_HASH drift,
# no git churn. Machine-bound / set-once params (GPU, privileged, mounts,
# IMAGE_NAME, APT mirror) belong in config/docker/setup.conf instead.
# See README "Where each parameter lives (env vs workload)".
EOF
}

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift <base_path>
#
# Compares current system state + setup.conf hash against .env's SETUP_*
# metadata. Prints drift descriptions to stderr when drift detected and
# returns 1 so the caller (build.sh / run.sh) can auto-regenerate the
# derived artifacts. Returns 0 (silent) when in sync.
#
# Requires .env to exist (caller checks first).
# ════════════════════════════════════════════════════════════════════
_check_setup_drift() {
  local _base="${1:?}"
  local _env_file="${_base}/.env.generated"
  [[ -f "${_env_file}" ]] || return 0

  # Read stored values from .env.generated without polluting caller's env
  local _stored_hash="" _stored_df_hash="" _stored_gui="" _stored_gpu="" _stored_uid=""
  _stored_hash="$(   grep -oP '^SETUP_CONF_HASH=\K.*'       "${_env_file}" 2>/dev/null || true)"
  _stored_df_hash="$(grep -oP '^SETUP_DOCKERFILE_HASH=\K.*' "${_env_file}" 2>/dev/null || true)"
  _stored_gui="$(    grep -oP '^SETUP_GUI_DETECTED=\K.*'    "${_env_file}" 2>/dev/null || true)"
  _stored_gpu="$(    grep -oP '^GPU_ENABLED=\K.*'           "${_env_file}" 2>/dev/null || true)"
  _stored_uid="$(    grep -oP '^USER_UID=\K.*'              "${_env_file}" 2>/dev/null || true)"

  local _now_hash="" _now_df_hash="" _now_gui="" _now_gpu=""
  _compute_conf_hash       "${_base}" _now_hash
  _compute_dockerfile_hash "${_base}" _now_df_hash
  detect_gui _now_gui
  detect_gpu _now_gpu
  local _now_uid=""
  _now_uid="$(id -u)"

  local -a _drift=()
  [[ -n "${_stored_hash}"    && "${_now_hash}"    != "${_stored_hash}"    ]] \
    && _drift+=("setup.conf modified since last setup")
  [[ -n "${_stored_df_hash}" && "${_now_df_hash}" != "${_stored_df_hash}" ]] \
    && _drift+=("Dockerfile stage list changed since last setup (added/removed FROM ... AS <stage>)")
  [[ -n "${_stored_gpu}"     && "${_now_gpu}"     != "${_stored_gpu}"     ]] \
    && _drift+=("GPU detection changed: ${_stored_gpu} → ${_now_gpu}")
  [[ -n "${_stored_gui}"     && "${_now_gui}"     != "${_stored_gui}"     ]] \
    && _drift+=("GUI detection changed: ${_stored_gui} → ${_now_gui}")
  [[ -n "${_stored_uid}"     && "${_now_uid}"     != "${_stored_uid}"     ]] \
    && _drift+=("USER_UID changed: ${_stored_uid} → ${_now_uid}")

  if (( ${#_drift[@]} > 0 )); then
    local _d
    _log_warn setup env_drift_detected "display=drift detected since last setup.sh run:"
    for _d in "${_drift[@]}"; do
      _log_warn setup env_drift_detail "display=  - ${_d}" "detail=${_d}"
    done
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_check_drift
#
# Subcommand handler for `setup.sh check-drift`. Parses --base-path /
# --lang flags then delegates to _check_setup_drift, which prints drift
# descriptions to stderr and returns 1 when the .env metadata no longer
# matches current system / setup.conf state.
#
# Build.sh / run.sh invoke this as a subprocess (instead of sourcing
# setup.sh) so internal helpers like _setup_msg can never shadow
# caller-side _msg keys ('s class of bug).
#
# Usage: _setup_check_drift [--base-path <path>] [--lang <code>]
# ════════════════════════════════════════════════════════════════════
_setup_check_drift() {
  local _base_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  _announce_template_default_fallback "${_base_path}"
  _check_setup_drift "${_base_path}"
}

# ════════════════════════════════════════════════════════════════════
# _announce_template_default_fallback <base_path>
#
# Surface a one-shot WARN when the per-repo setup.conf provides no
# overrides — either missing entirely or present but containing no
# [section] headers. Called from both `_setup_apply` and
# `_setup_check_drift` so build.sh / run.sh's drift-check rebuild path
# also surfaces the heads-up (follow-up to).
# Emitted to stderr to keep stdout machine-parseable. promoted
# the level from INFO to WARN so the notice doesn't scroll past
# unnoticed in normal build.sh / run.sh output.
# ════════════════════════════════════════════════════════════════════
_announce_template_default_fallback() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  # Existence check tracks the per-repo override file (setup.conf), the
  # source of truth
  local _repo_conf="${_base}/config/docker/setup.conf"
  if [[ ! -f "${_repo_conf}" ]]; then
    _log_warn setup conf_no_repo_conf "display=$(_setup_msg warnings no_repo_conf)"
  elif ! grep -qE '^[[:space:]]*\[[^]]+\]' "${_repo_conf}"; then
    _log_warn setup conf_empty_repo_conf "display=$(_setup_msg warnings empty_repo_conf)"
  fi
}


# ════════════════════════════════════════════════════════════════════
# main
#
# Top-level entry. Routes to subcommand handlers; preserves the legacy
# flag-only invocation (`setup.sh --base-path X --lang Y`) by falling
# top-level subcommand dispatch.
#
# B-4 BREAKING: no-arg / flag-only invocations no longer alias to
# `apply`. Either pass `-h`/`--help` (or no args, which now prints
# the same help) or use an explicit subcommand.
#
# Usage: main <subcommand> [args...]
#   subcommands: apply | check-drift | set | show | list | add | remove | reset
# ════════════════════════════════════════════════════════════════════
main() {
  _transcript_begin  # capture this run's output (no-op if disabled)
  local _subcmd=""
  # B-4 BREAKING: no-arg → help (was: silently aliased to apply).
  # Bare flag invocations (`setup.sh --base-path X --lang Y`, no
  # subcommand) also error now — the legacy fall-through is gone, so
  # accidental invocations don't clobber .env / compose.yaml without
  # an explicit subcommand. Downstream callers (build.sh / run.sh) all
  # pass `apply` explicitly as of this commit.
  if [[ $# -eq 0 ]]; then
    usage
  fi
  case "$1" in
    -h|--help)
      usage
      ;;
    apply|check-drift|set|show|list|add|remove|reset|deploy)
      _subcmd="$1"
      shift
      ;;
    *)
      _log_err setup conf_unknown_subcmd "display=$(_setup_msg errors unknown_subcmd): $1" "subcmd=$1"
      return 1
      ;;
  esac

  # pre-setup hook fires before any subcommand runs. Skipped
  # under --dry-run. Captured here (not per-subcommand) so all
  # subcommands get uniform pre/post coverage.
  _run_pre_hook setup "$@" || exit $?

  case "${_subcmd}" in
    apply)        _setup_apply       "$@" ;;
    check-drift)  _setup_check_drift "$@" ;;
    set)          _setup_set         "$@" ;;
    show)         _setup_show        "$@" ;;
    list)         _setup_list        "$@" ;;
    add)          _setup_add         "$@" ;;
    remove)       _setup_remove      "$@" ;;
    reset)        _setup_reset       "$@" ;;
    deploy)       _setup_deploy      "$@" ;;
  esac
  local _rc=$?

  # post-setup hook fires after the subcommand returns.
  _run_post_hook setup "$@" || exit $?
  return "${_rc}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
