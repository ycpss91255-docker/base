#!/usr/bin/env bash
#
# compose.sh - docker compose wrappers + project naming.
#
# Provides:
#   _is_self_managed_repo             : does this checkout own its compose.yaml?
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

# _resolve_project_name <configured> <hub_user> <image_name> <path> <outvar>
#
# The ONE producer of a compose project name. Given the configured
# `[project] name` (empty = "derive as before"), it yields the project
# name; with nothing configured it derives `<hub>-<image>`, and with
# neither of those it falls back to `local-<directory basename>`.
#
# One producer is the point. Both consumers -- the wrapper's `-p` and the
# emitted compose.yaml's `name:` -- read the SAME resolved value out of
# `.env.generated`, rather than each assembling `<hub>-<image>` themselves
# and happening to agree. `setup apply` calls this once, records the result
# as PROJECT_NAME, and the emitter writes `name: ${PROJECT_NAME}`; the
# wrapper calls it only when there is no `.env.generated` to read at all
# (base self-use, pre-bootstrap).
#
# This prefix now carries the WHOLE of per-host isolation: the emitted
# compose names no container (see compose_emit.sh's header), so compose
# derives `<project>-<service>-<n>` and the project name is the only thing
# keeping two OS users on one host out of each other's containers,
# networks and volumes. It carries it with no second mechanism here,
# because `<hub>` is already per-OS-user with nothing configured:
# `detect_docker_hub_user` (setup_detect.sh) falls back to
# `${USER:-$(id -un)}` when `docker info` reports no login, and that
# detection is the ONLY writer of DOCKER_HUB_USER -- so no recorded
# `.env.generated` carries an empty one, and no consumer derives the
# shared literal `local`.
#
# Deriving the prefix a second time HERE, from the OS user, would be
# unreachable rather than defensive: `detect_user_info` ends in that same
# `${USER:-$(id -un)}`, so a host that leaves the hub user empty leaves
# USER_NAME empty too and the lower rung could never differ from the one
# above it. An earlier draft of this change carried such a rung; it is
# gone (ADR-00000022 amendment).
#
# What the derivation genuinely cannot separate is two OS users sharing
# ONE Docker Hub login -- a shared service account hands both the same
# prefix. `[project] name` is the answer there, which is why a configured
# name WINS over the derivation rather than merely seeding it.
#
# base stays single-instance: `[project] name` is CONFIGURATION -- one name
# for this checkout, recorded in a file -- not multi-instance orchestration,
# which remains the compose layer's job (ADR-00000022).
_resolve_project_name() {
  local _configured="${1-}"
  local _hub="${2-}"
  local _image="${3-}"
  local _path="${4-}"
  local -n _rpn_out="${5:?"${FUNCNAME[0]}: missing outvar"}"

  if [[ -n "${_configured}" ]]; then
    _rpn_out="${_configured}"
    return 0
  fi
  # `local` and the directory basename are the LAST resorts, not a naming
  # policy: they apply only where nothing has been detected or resolved at
  # all -- base self-use before bootstrap, which has no `.env.generated` to
  # read a hub user or an image name out of.
  _rpn_out="${_hub:-local}-${_image:-$(basename -- "${_path:-${PWD}}")}"
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

# The banner `write_env` emits above PROJECT_NAME_PENDING, named once here
# because two files have to agree on it byte for byte: lib/env_emit.sh
# writes the deferred-rename block, and lib/wrapper.sh removes the block
# whole when it adopts the rename. A literal in both places drifts silently
# -- the remover would simply stop matching, and the only symptom would be
# a banner left standing over nothing.
readonly _PROJECT_PENDING_BANNER='# -- Deferred project rename (adopted once the old project is empty) --'

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
  _resolve_project_name "" "${DOCKER_HUB_USER:-}" "${IMAGE_NAME:-}" \
    "${FILE_PATH:-${PWD}}" PROJECT_NAME
}

# _is_self_managed_repo <path>
#
# True when <path> is a checkout that manages its own compose.yaml: no
# `.base/` subtree and no `.setup.conf` (ADR-00000011 sec.4). base itself
# is the shape -- it is the template SOURCE -- and so is any repo that
# opted out of generated config. A consumer always carries both, so this
# is false for every one of them.
#
# The ONE producer of that answer. It is asked in three places that must
# not drift apart: whether a missing `.env.generated` is normal
# (_compute_project_name), whether compose.yaml carries variables only
# this checkout can resolve (_export_self_managed_test_tools_image), and
# whether to run the setup lifecycle at all (_wrapper_setup_sync).
_is_self_managed_repo() {
  local _path="${1-}"
  [[ -n "${_path}" ]] || return 1
  [[ ! -d "${_path}/.base" && ! -f "${_path}/.setup.conf" ]]
}

# _export_self_managed_test_tools_image
#
# Put TEST_TOOLS_IMAGE in the environment of a self-managed checkout's
# compose calls, when the checkout can say what it is.
#
# A self-managed compose.yaml is hand-authored, and base's names every
# image `${TEST_TOOLS_IMAGE:?...}` with no default on purpose: two
# defaults are how a build writes one tag while a run reads another.
# compose interpolates the WHOLE file whatever verb it is handed, so
# `down`, `ps` and `exec` need that value exactly as much as `build`
# does -- without it compose refuses to read the file at all and the verb
# dies before it runs, tearing down and inspecting nothing.
#
# One producer, again: the checkout's own `script/test/test.sh
# --test-tools-image`, which is what build.sh delegates to for the same
# tag. A caller-pinned TEST_TOOLS_IMAGE (CI, `just test`, `just test
# stop`) is left verbatim.
#
# Silent no-op when the checkout offers no resolver, or the resolver
# fails: there is then nothing truthful to supply, and compose's own
# interpolation error names the value and the command that sets it, which
# is a better report than a guess.
_export_self_managed_test_tools_image() {
  [[ -z "${TEST_TOOLS_IMAGE:-}" ]] || return 0
  _is_self_managed_repo "${FILE_PATH:-}" || return 0

  local _resolver="${FILE_PATH}/script/test/test.sh"
  [[ -x "${_resolver}" ]] || return 0

  local _image=""
  _image="$("${_resolver}" --test-tools-image 2>/dev/null)" || return 0
  [[ -n "${_image}" ]] || return 0
  export TEST_TOOLS_IMAGE="${_image}"
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
# --env-file points at .env.generated (the derived interpolation cache).
# The container's own env -- the generated `.env` plus the operator's
# `.env.local` -- reaches it through each service's `env_file:` list, not
# through this CLI flag.
_compose_project() {
  # A self-managed checkout's compose.yaml may name variables only that
  # checkout can resolve. compose interpolates the whole file for every
  # verb, so this belongs here -- at the one point where a wrapper hands
  # compose.yaml over -- rather than in each verb that remembers to.
  _export_self_managed_test_tools_image

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
