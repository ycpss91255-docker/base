#!/usr/bin/env bash
# build.sh - Build Docker container images

set -euo pipefail

FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FILE_PATH
if [[ -f "${FILE_PATH}/template/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/template/script/docker/_lib.sh"
else
  # Fallback for /lint stage which COPYs only *.sh from repo root and has
  # no template/ tree. Only _LANG is needed for `usage()`; other helpers
  # are unused in this stage.
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
用法: ./build.sh [-h] [-s|--setup] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

選項:
  -h, --help     顯示此說明
  -s, --setup    強制重跑 setup.sh 重新生成 .env + compose.yaml
                 （預設：.env 不存在時自動 bootstrap；存在時僅印 drift warning）
  --no-cache     強制不使用 cache 重建
  --clean-tools  build 結束後移除 test-tools:local image（預設保留以加速下次 build）
  --dry-run      只印出將執行的 docker 指令，不實際執行
  --lang LANG    設定訊息語言（預設: en）

目標:
  devel    開發環境（預設）
  test     執行 smoke test
  runtime  最小化 runtime 映像
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./build.sh [-h] [-s|--setup] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

选项:
  -h, --help     显示此说明
  -s, --setup    强制重跑 setup.sh 重新生成 .env + compose.yaml
                 （默认：.env 不存在时自动 bootstrap；存在时仅打印 drift warning）
  --no-cache     强制不使用 cache 重建
  --clean-tools  build 结束后移除 test-tools:local image（默认保留以加速下次 build）
  --dry-run      只打印将执行的 docker 命令，不实际执行
  --lang LANG    设置消息语言（默认: en）

目标:
  devel    开发环境（默认）
  test     运行 smoke test
  runtime  最小化 runtime 镜像
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./build.sh [-h] [-s|--setup] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

オプション:
  -h, --help     このヘルプを表示
  -s, --setup    setup.sh を強制実行して .env + compose.yaml を再生成
                 （デフォルト：.env が無ければ自動 bootstrap、あれば drift warning のみ）
  --no-cache     キャッシュを使わず強制リビルド
  --clean-tools  build 終了後に test-tools:local image を削除（デフォルトは保持）
  --dry-run      実行される docker コマンドを表示するのみ（実行はしない）
  --lang LANG    メッセージ言語を設定（デフォルト: en）

ターゲット:
  devel    開発環境（デフォルト）
  test     smoke test を実行
  runtime  最小化ランタイムイメージ
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./build.sh [-h] [-s|--setup] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

Options:
  -h, --help     Show this help
  -s, --setup    Force rerun setup.sh to regenerate .env + compose.yaml
                 (default: auto-bootstrap if .env missing; warn on drift if present)
  --no-cache     Force rebuild without cache
  --clean-tools  Remove test-tools:local image after build (default: keep for faster next build)
  --dry-run      Print the docker commands that would run, but do not execute
  --lang LANG    Set message language (default: en)

Targets:
  devel    Development environment (default)
  test     Run smoke tests
  runtime  Minimal runtime image
EOF
      ;;
  esac
  exit 0
}

main() {
  local RUN_SETUP=false
  local NO_CACHE=false
  local CLEAN_TOOLS=false
  local TARGET="devel"
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -s|--setup)
        RUN_SETUP=true
        shift
        ;;
      --no-cache)
        NO_CACHE=true
        shift
        ;;
      --clean-tools)
        CLEAN_TOOLS=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
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
  local _tui="${FILE_PATH}/tui.sh"

  # _run_interactive: prefer tui.sh when an interactive TTY is present
  # and the symlink is executable; otherwise fall back to non-interactive
  # setup.sh. Keeps CI / non-TTY paths unchanged.
  _run_interactive() {
    if [[ -t 0 && -t 1 && -x "${_tui}" ]]; then
      "${_tui}" --lang "${_LANG}"
    else
      "${_setup}" --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  }

  # Decide whether to run setup.sh / tui.sh:
  #   - --setup flag          → always run interactive-or-setup
  #   - missing .env          → auto-bootstrap (first-time / fresh CI clone)
  #   - otherwise             → check for drift and warn (but continue)
  if [[ "${RUN_SETUP}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${FILE_PATH}/.env" ]] || [[ ! -f "${FILE_PATH}/setup.conf" ]]; then
    # Missing .env OR setup.conf → bootstrap. Covers fresh clones and
    # the "I rm'd setup.conf to reset to defaults" reset workflow.
    printf "[build] INFO: First run — bootstrapping...\n"
    _run_interactive
  else
    # shellcheck disable=SC1090
    source "${_setup}"
    _check_setup_drift "${FILE_PATH}" || true
  fi

  # Load .env for project name
  _load_env "${FILE_PATH}/.env"
  _compute_project_name ""

  # Build test-tools image if Dockerfile exists
  local _tools_dockerfile="${FILE_PATH}/template/dockerfile/Dockerfile.test-tools"
  local _tools_args=()
  [[ "${NO_CACHE}" == true ]] && _tools_args+=(--no-cache)
  if [[ -f "${_tools_dockerfile}" ]]; then
    if [[ "${DRY_RUN}" == true ]]; then
      printf '[dry-run] docker build'
      printf ' %q' "${_tools_args[@]}" -t test-tools:local \
        -f "${_tools_dockerfile}" "${FILE_PATH}" -q
      printf '\n'
    else
      docker build "${_tools_args[@]}" \
        -t test-tools:local \
        -f "${_tools_dockerfile}" \
        "${FILE_PATH}" -q >/dev/null
    fi
  fi

  if [[ "${CLEAN_TOOLS}" == true ]]; then
    _cleanup() { docker rmi test-tools:local 2>/dev/null || true; }
    trap _cleanup EXIT
  fi

  local _compose_args=()
  [[ "${NO_CACHE}" == true ]] && _compose_args+=(--no-cache)

  _compose_project build "${_compose_args[@]}" "${TARGET}"
}

main "$@"
