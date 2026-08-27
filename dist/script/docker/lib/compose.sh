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
# _recorded_project_name reads keys out of a generated env file, so env.sh
# comes in the same way (also idempotent via its own guard).
# shellcheck source=dist/script/docker/lib/env.sh
source "${_compose_dir}/env.sh"

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

# _recorded_project_name <env_file> <outvar>
#
# The project name this checkout is ALREADY running under, read out of its
# generated env file. Empty only when the file records no name at all.
#
# Two file shapes answer that question, and reading only the newer one is
# how the carry below misses the population it exists for.
#
#   PROJECT_NAME present -- the resolved value setup apply records since
#                the project name became a resolved value. It IS the name.
#
#   PROJECT_NAME absent  -- the shape every consumer on the previous
#                release carries. The name was never recorded then: the
#                emitted compose.yaml said
#                `name: ${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX:-}`
#                and the wrapper assembled the same string for its `-p`,
#                BOTH interpolating this very file. So the name is
#                `<DOCKER_HUB_USER>-<IMAGE_NAME>` -- two keys still in the
#                file, and the exact string the live containers carry as
#                their `com.docker.compose.project` label.
#
# Reading an absent PROJECT_NAME as "fresh checkout" would record the newly
# derived name with nothing pending -- the silent rename over a live stack
# that `_carry_project_name` exists to prevent, on the one population that
# is actually mid-migration.
#
# Both keys must be non-empty for the reconstruction: either half missing
# leaves a string compose would have refused as a project name, so there is
# no stack under it to keep continuity with. `INSTANCE_SUFFIX` is not part
# of it -- it was a per-invocation flag, never recorded in the file.
_recorded_project_name() {
  local _file="${1:?_recorded_project_name requires a file}"
  local -n _rpn_rec="${2:?_recorded_project_name requires an outvar}"

  _env_file_value "${_file}" PROJECT_NAME _rpn_rec
  [[ -n "${_rpn_rec}" ]] && return 0

  local _hub="" _image=""
  _env_file_value "${_file}" DOCKER_HUB_USER _hub
  _env_file_value "${_file}" IMAGE_NAME _image
  [[ -n "${_hub}" && -n "${_image}" ]] && _rpn_rec="${_hub}-${_image}"
  return 0
}

# _carry_project_name <recorded> <resolved> <configured>
#                      <name_outvar> <pending_outvar>
#
# Decide which project name `setup apply` RECORDS, given the one this
# checkout already had. Continuity wins over a changed DERIVATION: a
# checkout that already runs under a derived name keeps it, and the newly
# derived one is carried BESIDE it as pending rather than written over it.
#
# The project name is the key compose looks its own containers up by, so
# rewriting it while a stack is up hides that stack from every wrapper at
# once -- `stop` tears down an empty project, `run` starts a second copy
# over the live one, and the original is reachable only by raw `docker`.
# Compose cannot relabel a running container, so a rename can only take
# effect on an EMPTY project, and setup.sh is in no position to know
# whether this one is: it resolves configuration on hosts where docker
# need not be reachable. So it does not decide. It records both, and the
# wrapper -- which can ask the daemon -- adopts the pending name on the
# first build / run that finds the old project empty
# (`_wrapper_settle_project_name`, lib/wrapper.sh).
#
# A CONFIGURED `[project] name` is the exception, and takes effect at
# once. Deferring it would defeat the setting it is: its whole use is a
# second worktree that must NOT share the first's derived name, and the
# containers under that shared name are the other checkout's -- occupancy
# there is the reason to rename, not a reason to wait. A rename someone
# typed is also an act they can sequence around; the changed default that
# motivates the carry is one nobody asked for. setup.sh says so when it
# happens, so it is not silent either.
#
# A fresh checkout (no recorded name) and a resolution that did not change
# both yield "record the resolved one, nothing pending", which is every
# ordinary apply.
_carry_project_name() {
  local _recorded="${1-}"
  local _resolved="${2-}"
  local _configured="${3-}"
  local -n _cpn_name="${4:?"${FUNCNAME[0]}: missing name outvar"}"
  local -n _cpn_pending="${5:?"${FUNCNAME[0]}: missing pending outvar"}"

  if [[ -z "${_configured}" && -n "${_recorded}" \
        && "${_recorded}" != "${_resolved}" ]]; then
    _cpn_name="${_recorded}"
    _cpn_pending="${_resolved}"
    return 0
  fi
  _cpn_name="${_resolved}"
  _cpn_pending=""
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
