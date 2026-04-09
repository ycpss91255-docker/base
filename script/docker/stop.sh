#!/usr/bin/env bash
# stop.sh - Stop and remove Docker containers

set -euo pipefail

FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FILE_PATH
if [[ -f "${FILE_PATH}/template/script/docker/i18n.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/template/script/docker/i18n.sh"
else
  _detect_lang() {
    case "${LANG:-}" in
      zh_TW*) echo "zh" ;;
      zh_CN*|zh_SG*) echo "zh-CN" ;;
      ja*) echo "ja" ;;
      *) echo "en" ;;
    esac
  }
  _LANG="${SETUP_LANG:-$(_detect_lang)}"
fi

usage() {
  case "${_LANG}" in
    zh)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [--instance NAME] [--all]

停止並移除容器。預設只停止 default instance。

選項:
  -h, --help        顯示此說明
  --instance NAME   只停止指定的命名 instance
  --all             停止所有 instance(預設 + 全部命名 instance)
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [--instance NAME] [--all]

停止并移除容器。默认只停止 default instance。

选项:
  -h, --help        显示此说明
  --instance NAME   只停止指定的命名 instance
  --all             停止所有 instance(默认 + 全部命名 instance)
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./stop.sh [-h] [--instance NAME] [--all]

コンテナを停止・削除します。デフォルトは default instance のみ。

オプション:
  -h, --help        このヘルプを表示
  --instance NAME   指定された名前付き instance のみ停止
  --all             すべての instance を停止（デフォルト + 全名前付き instance）
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./stop.sh [-h] [--instance NAME] [--all]

Stop and remove containers. Default: stop only the default instance.

Options:
  -h, --help        Show this help
  --instance NAME   Stop only the named instance
  --all             Stop ALL instances (default + every named instance)
EOF
      ;;
  esac
  exit 0
}

INSTANCE=""
ALL_INSTANCES=false
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      ;;
    --instance)
      INSTANCE="${2:?"--instance requires a value"}"
      shift 2
      ;;
    --all)
      ALL_INSTANCES=true
      shift
      ;;
    *)
      PASSTHROUGH+=("$1")
      shift
      ;;
  esac
done

# Load .env for project name
set -o allexport
# shellcheck disable=SC1091
source "${FILE_PATH}/.env"
set +o allexport

# Helper: down a single project (with the right INSTANCE_SUFFIX so compose.yaml
# resolves the same container_name as run.sh used).
_down_one() {
  local _suffix="${1}"
  local _project="${DOCKER_HUB_USER}-${IMAGE_NAME}${_suffix}"
  INSTANCE_SUFFIX="${_suffix}" docker compose -p "${_project}" \
    -f "${FILE_PATH}/compose.yaml" \
    --env-file "${FILE_PATH}/.env" \
    down "${PASSTHROUGH[@]}"
}

if [[ "${ALL_INSTANCES}" == true ]]; then
  # Find all docker compose projects whose name starts with our prefix.
  _prefix="${DOCKER_HUB_USER}-${IMAGE_NAME}"
  mapfile -t _projects < <(
    docker ps -a --format '{{.Label "com.docker.compose.project"}}' \
      | sort -u | grep -E "^${_prefix}(\$|-)" || true
  )
  if [[ ${#_projects[@]} -eq 0 ]]; then
    printf "[stop] No instances found for %s\n" "${IMAGE_NAME}" >&2
    exit 0
  fi
  for _proj in "${_projects[@]}"; do
    _suffix="${_proj#"${_prefix}"}"
    _down_one "${_suffix}"
  done
elif [[ -n "${INSTANCE}" ]]; then
  _down_one "-${INSTANCE}"
else
  _down_one ""
fi
