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
_compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_compose_dir}/log.sh"

# _resolve_project_name <configured> <hub_user> <os_user> <image_name> <path> <outvar>
#
# The ONE producer of a compose project name. Given the configured
# `[project] name` (empty = "derive as before"), it yields the project
# name; with nothing configured it derives `<hub>-<image>`, falling back to
# the OS user for the prefix and to the directory basename for the suffix.
#
# One producer is the point. Both consumers -- the wrapper's `-p` and the
# emitted compose.yaml's `name:` -- read the SAME resolved value out of
# `.env.generated`, rather than each assembling `<hub>-<image>` themselves
# and happening to agree. `setup apply` calls this once, records the result
# as PROJECT_NAME, and the emitter writes `name: ${PROJECT_NAME}`; the
# wrapper calls it only when there is no `.env.generated` to read at all
# (base self-use, pre-bootstrap).
#
# Why the prefix falls back to the OS USER and not to a literal: the
# emitted compose names no container (see compose_emit.sh's header), so
# compose derives `<project>-<service>-<n>` and the project name is the ONLY
# thing keeping two OS users on one host out of each other's containers,
# networks and volumes. `DOCKER_HUB_USER` is frequently unset -- it is a
# registry identity, and a host with no Docker Hub account has none -- and
# the literal `local` it used to fall back to is the SAME string for every
# user on that host. Deriving `local-<image>` would have put both users in
# one project: the collision promoted from one container to a whole stack.
# The OS user is the identity that is always present and always differs,
# which is why the container name used it. Order of preference is unchanged
# where it was already right: a configured `[project] name` wins, then the
# hub user, then the OS user.
#
# base stays single-instance: `[project] name` is CONFIGURATION -- one name
# for this checkout, recorded in a file -- not multi-instance orchestration,
# which remains the compose layer's job (ADR-00000022).
_resolve_project_name() {
  local _configured="${1-}"
  local _hub="${2-}"
  local _user="${3-}"
  local _image="${4-}"
  local _path="${5-}"
  local -n _rpn_out="${6:?"${FUNCNAME[0]}: missing outvar"}"

  if [[ -n "${_configured}" ]]; then
    _rpn_out="${_configured}"
    return 0
  fi
  # `local` and the directory basename are the LAST resorts, not a naming
  # policy: they apply only when there is no identity / no resolved config
  # to read at all.
  _rpn_out="${_hub:-${_user:-local}}-${_image:-$(basename -- "${_path:-${PWD}}")}"
}

# _compute_project_name puts PROJECT_NAME in scope for the current
# invocation.
#
# Normal path: `_load_env` has just sourced `.env.generated`, which carries
# the PROJECT_NAME `setup apply` resolved, so there is nothing to compute --
# recomputing over it is exactly how a resolved project name used to be
# discarded.
#
# Fallback path: no `.env.generated` at all (base self-use / pre-bootstrap).
# Then, and only then, _resolve_project_name derives one from whatever is in
# scope. A `.env.generated` that exists but omits PROJECT_NAME is a cache
# written before the key existed: that is not the fallback case, it is a
# stale cache, and it says so instead of quietly deriving a name whose
# source the user cannot find.
_compute_project_name() {
  [[ -n "${PROJECT_NAME:-}" ]] && return 0

  local _generated="${FILE_PATH:-}/.env.generated"
  if [[ -n "${FILE_PATH:-}" && -f "${_generated}" ]]; then
    _log_warn compose project_name_missing_from_env \
      "display=${_generated} carries no PROJECT_NAME: it was generated before the project name became a resolved value. Deriving one for this run; re-run './setup.sh apply' (or any wrapper, which regenerates on drift) to record it." \
      "file=${_generated}"
  fi

  # shellcheck disable=SC2034  # PROJECT_NAME is consumed by callers, not _lib.sh
  _resolve_project_name "" "${DOCKER_HUB_USER:-}" "${USER_NAME:-}" \
    "${IMAGE_NAME:-}" "${FILE_PATH:-${PWD}}" PROJECT_NAME
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
  # .env.generated is absent in a self-managed repo (base self-use);
  # only pass --env-file when it exists so docker compose does not error on
  # a missing interpolation cache. Consumers always have it post-setup.
  local -a _env_file_arg=()
  if [[ -f "${FILE_PATH}/.env.generated" ]]; then
    _env_file_arg=(--env-file "${FILE_PATH}/.env.generated")
  fi
  _compose -p "${PROJECT_NAME}" \
    -f "${FILE_PATH}/compose.yaml" \
    "${_env_file_arg[@]}" \
    "$@"
}
