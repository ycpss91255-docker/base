#!/usr/bin/env bash
#
# compose.sh - docker compose wrappers + project naming.
#
# Provides:
#   _compute_project_name             : derive PROJECT_NAME
#   _compose                          : `docker compose` wrapper honoring DRY_RUN
#   _compose_project                  : _compose with -p / -f / --env-file pre-filled
#
# Split out from _lib.sh in

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_COMPOSE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_COMPOSE_SOURCED=1

# _compose delegates its DRY_RUN echo/exec split to log.sh's
# _dry_run_cmd (-B), so pull log.sh in directly (idempotent via its
# own double-source guard) -- mirrors config_summary.sh. Keeps compose.sh
# self-sufficient when a caller sources it without the full _lib.sh.
_compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_compose_dir}/log.sh"

# _compute_project_name derives PROJECT_NAME for the current invocation.
# base is single-instance: one fixed-name project per repo. Multi-
# instance orchestration (unique project names, port overrides) belongs to
# the compose layer, mirroring how `docker` has no project concept and
# `docker compose` owns -p.
#
# Requires:
#   DOCKER_HUB_USER, IMAGE_NAME already in the environment (from .env).
#
# Sets:
#   PROJECT_NAME     e.g. "alice-myrepo"
_compute_project_name() {
  # shellcheck disable=SC2034  # PROJECT_NAME is consumed by callers, not _lib.sh
  PROJECT_NAME="${DOCKER_HUB_USER}-${IMAGE_NAME}"
}

# _compose runs `docker compose` with the given args, or prints what it would
# run if DRY_RUN=true. Use this instead of calling docker compose directly so
# every script honors --dry-run uniformly. Delegates the DRY_RUN echo/exec
# split to log.sh's _dry_run_cmd (-B) so the dry-run format lives in one
# place; output is byte-identical (`[dry-run] docker compose <%q args>`).
_compose() {
  _dry_run_cmd docker compose "$@"
}

# _compose_project runs `_compose` with -p / -f / --env-file pre-filled, so
# callers only need to pass the verb and its args.
#
# Requires:
#   PROJECT_NAME : set by _compute_project_name
#   FILE_PATH    : the repo root (where compose.yaml + .env.generated live)
#
# --env-file points at .env.generated (the derived interpolation cache,
# ). The hand-authored .env workload overlay reaches containers via
# each service's `env_file: - .env` directive, not this CLI flag.
_compose_project() {
  _compose -p "${PROJECT_NAME}" \
    -f "${FILE_PATH}/compose.yaml" \
    --env-file "${FILE_PATH}/.env.generated" \
    "$@"
}
