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
