#!/usr/bin/env bash
# run.sh - Run Docker containers (interactive or detached)

set -euo pipefail

FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FILE_PATH
if [[ -f "${FILE_PATH}/template/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/template/script/docker/_lib.sh"
else
  # Fallback for /lint stage. See build.sh for rationale.
  _detect_lang() {
    case "${LANG:-}" in
      zh_TW*) echo "zh-TW" ;;
      zh_CN*|zh_SG*) echo "zh-CN" ;;
      ja*) echo "ja" ;;
      *) echo "en" ;;
    esac
  }
  _LANG="${SETUP_LANG:-$(_detect_lang)}"
fi

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./run.sh [-h] [-d|--detach] [-s|--setup] [--dry-run] [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

選項:
  -h, --help        顯示此說明
  -d, --detach      背景執行（docker compose up -d）
  -s, --setup       強制重跑 setup.sh 重新生成 .env + compose.yaml
                    （預設：.env 不存在時自動 bootstrap；存在時僅印 drift warning）
  --dry-run         只印出將執行的 docker 指令，不實際執行
  --instance NAME   啟動命名 instance（與預設並行,suffix=-NAME）
  --lang LANG       設定訊息語言（預設: en）

目標:
  devel    開發環境（預設）
  runtime  最小化 runtime
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./run.sh [-h] [-d|--detach] [-s|--setup] [--dry-run] [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

选项:
  -h, --help        显示此说明
  -d, --detach      后台运行（docker compose up -d）
  -s, --setup       强制重跑 setup.sh 重新生成 .env + compose.yaml
                    （默认：.env 不存在时自动 bootstrap；存在时仅打印 drift warning）
  --dry-run         只打印将执行的 docker 命令，不实际执行
  --instance NAME   启动命名 instance（与默认并行,suffix=-NAME）
  --lang LANG       设置消息语言（默认: en）

目标:
  devel    开发环境（默认）
  runtime  最小化 runtime
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./run.sh [-h] [-d|--detach] [-s|--setup] [--dry-run] [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

オプション:
  -h, --help        このヘルプを表示
  -d, --detach      バックグラウンドで実行（docker compose up -d）
  -s, --setup       setup.sh を強制実行して .env + compose.yaml を再生成
                    （デフォルト：.env が無ければ自動 bootstrap、あれば drift warning のみ）
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  --instance NAME   名前付き instance を起動（デフォルトと並行、suffix=-NAME）
  --lang LANG       メッセージ言語を設定（デフォルト: en）

ターゲット:
  devel    開発環境（デフォルト）
  runtime  最小化ランタイム
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./run.sh [-h] [-d|--detach] [-s|--setup] [--dry-run] [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

Options:
  -h, --help        Show this help
  -d, --detach      Run in background (docker compose up -d)
  -s, --setup       Force rerun setup.sh to regenerate .env + compose.yaml
                    (default: auto-bootstrap if .env missing; warn on drift if present)
  --dry-run         Print the docker commands that would run, but do not execute
  --instance NAME   Start a named parallel instance (suffix=-NAME)
  --lang LANG       Set message language (default: en)

Targets:
  devel    Development environment (default)
  runtime  Minimal runtime
EOF
      ;;
  esac
  exit 0
}

# _devel_cleanup tears down the project on shell exit so the container does
# not outlive the foreground `./run.sh` session.
#
# `down -t 0` skips the default 10s SIGTERM grace period: the user already
# exited the interactive bash, so there is nothing to drain gracefully —
# without -t 0 the script appears to hang for ~10s after `exit`.
_devel_cleanup() {
  _compose_project down -t 0 >/dev/null 2>&1 || true
}

main() {
  local RUN_SETUP=false
  local DETACH=false
  local TARGET="devel"
  local INSTANCE=""
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -d|--detach)
        DETACH=true
        shift
        ;;
      -s|--setup)
        RUN_SETUP=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --instance)
        INSTANCE="${2:?"--instance requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "run"
        shift 2
        ;;
      *)
        TARGET="$1"
        shift
        ;;
    esac
  done
  export DRY_RUN

  local _setup="${FILE_PATH}/template/script/docker/setup.sh"
  local _tui="${FILE_PATH}/setup_tui.sh"

  # _run_interactive: prefer setup_tui.sh when an interactive TTY is
  # present and the symlink is executable; otherwise fall back to
  # non-interactive setup.sh. Keeps CI / non-TTY paths unchanged.
  _run_interactive() {
    if [[ -t 0 && -t 1 && -x "${_tui}" ]]; then
      "${_tui}" --lang "${_LANG}"
    else
      "${_setup}" --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  }

  # Decide whether to run setup.sh / setup_tui.sh:
  #   - --setup flag                         → interactive (TUI on TTY, else setup.sh)
  #   - missing .env / setup.conf / compose.yaml → non-interactive bootstrap
  #   - otherwise                            → drift-check only
  #
  # Bootstrap stays non-interactive (see build.sh for the full rationale):
  # compose.yaml is gitignored since v0.9.0, every fresh clone lands here,
  # and dispatching through the TUI would leave cancelled sessions
  # without a .env.
  if [[ "${RUN_SETUP}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${FILE_PATH}/.env" ]] \
      || [[ ! -f "${FILE_PATH}/setup.conf" ]] \
      || [[ ! -f "${FILE_PATH}/compose.yaml" ]]; then
    printf "[run] INFO: First run — bootstrapping...\n"
    "${_setup}" --base-path "${FILE_PATH}" --lang "${_LANG}"
  else
    # shellcheck disable=SC1090
    source "${_setup}"
    # Drift → auto-regen (see build.sh for the full rationale).
    if ! _check_setup_drift "${FILE_PATH}"; then
      printf "[run] regenerating .env / compose.yaml (setup.conf drifted)\n"
      "${_setup}" --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  fi

  # Defensive: bootstrap must leave .env in place. See build.sh.
  if [[ ! -f "${FILE_PATH}/.env" ]]; then
    printf "[run] ERROR: setup did not produce .env.\n" >&2
    printf "[run] Re-run with './run.sh --setup' to open the editor.\n" >&2
    exit 1
  fi

  # Load .env, derive PROJECT_NAME (sets/exports INSTANCE_SUFFIX too).
  _load_env "${FILE_PATH}/.env"
  _compute_project_name "${INSTANCE}"

  # Pre-run snapshot so the user can see which files + values this
  # invocation resolved to before the container replaces the shell.
  # Mute with QUIET=1 for piped / CI logs.
  [[ "${QUIET:-0}" != "1" ]] && _print_config_summary run

  # Allow X11 forwarding (X11 or XWayland)
  if [[ "${XDG_SESSION_TYPE:-x11}" == "wayland" ]]; then
    xhost "+SI:localuser:${USER_NAME}" >/dev/null 2>&1 || true
  else
    xhost +local: >/dev/null 2>&1 || true
  fi

  # Container name mirrors compose.yaml's `container_name:`.
  local CONTAINER_NAME="${IMAGE_NAME}${INSTANCE_SUFFIX}"

  # Refuse to start if the target container is already running and user did
  # not explicitly opt into a parallel instance via --instance.
  # (For -d mode, the existing `down` step handles restart, so collision is OK.)
  if [[ "${DETACH}" != true && "${TARGET}" == "devel" \
      && "${DRY_RUN}" != true ]]; then
    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
      printf "[run] ERROR: Container '%s' is already running.\n" \
        "${CONTAINER_NAME}" >&2
      printf "[run] Either stop it with './stop.sh%s'\n" \
        "$([[ -n "${INSTANCE}" ]] && printf ' --instance %s' "${INSTANCE}")" >&2
      printf "[run] or start a parallel instance with './run.sh --instance NAME'.\n" >&2
      exit 1
    fi
  fi

  if [[ "${DETACH}" == true ]]; then
    _compose_project down 2>/dev/null || true
    _compose_project up -d "${TARGET}"
  elif [[ "${TARGET}" == "devel" ]]; then
    # Foreground devel: `up -d` + `exec` so a second terminal can join via
    # `./exec.sh`. Trap auto-`down` on exit to preserve the
    # "exit shell = container gone" semantic of the previous `compose run`.
    trap _devel_cleanup EXIT
    _compose_project up -d "${TARGET}"
    _compose_project exec "${TARGET}" bash
  else
    # Other one-shot stages (test, runtime, ...): keep `compose run --rm`.
    _compose_project run --rm "${TARGET}"
  fi
}

main "$@"
