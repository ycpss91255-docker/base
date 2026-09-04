#!/usr/bin/env bash
#
# base container ENTRYPOINT orchestrator.
#
# This file is base-owned and ships from `.base/dist/`: the Dockerfile's
# `COPY .base/dist/script/docker/runtime/ /usr/local/lib/base/` brings the
# whole helper directory into the image, so this lands at
# /usr/local/lib/base/entrypoint.sh beside the helpers it sources and
# UPDATES WITH EVERY SUBTREE PULL. That is the whole point: the plumbing
# below used to live in the repo-owned /entrypoint.sh, which init.sh seeds
# once and no upgrade ever rewrites, so a change here reached new repos
# only. `ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]` also records the
# ownership in the image itself -- `docker inspect` shows whose entry point
# it is.
#
# The repo-owned half is the BRINGUP at /entrypoint.sh (COPY'd from
# ${ENTRYPOINT_FILE}, seeded by init.sh from dist/dockerfile/entrypoint.sh).
# It is SOURCED, not exec'd: env it sets has to persist into the workload,
# and control has to come back here for the watchdog and the real exec. A
# bringup that ends in `exec "$@"` pre-empts both -- the migration notice in
# lib/dockerfile_migrate.sh warns about exactly that.
#
# Order is logging -> bringup -> watchdog -> exec, and each step needs the
# one before it:
#   logging   rebinds stdout/stderr through the host tee, so it wraps
#             everything after it.
#   bringup   sets the env (ROS overlay, ROS_DOMAIN_ID, ...) the workload
#             and the watchdog's health check both read.
#   watchdog  may never return (ON_FAIL=restart-service supervises the
#             service in place), so it arms last, around the real exec.
#
# Every source is `-r`-guarded: the devel stage always ships the helpers
# but the runtime stage's COPYs are opt-in, and a repo need not have a
# bringup at all. An image missing any of the three still starts clean --
# no missing-file stderr, no abort under the strict mode below.

# Only set strict mode when running directly; when sourced (by a spec),
# respect the caller's settings.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# _base_entrypoint_main <lib_dir> <bringup> [cmd...]
#   Run the four steps in order and exec <cmd...>. The paths are arguments
#   rather than literals so the real function can be driven against a
#   scratch tree by test/bats/unit/entrypoint_spec.bats; the in-image
#   values are frozen at the call site at the bottom of this file.
#
#   The sources sit inside a function on purpose and it costs nothing:
#   logging.sh's `exec > >(tee ...)` rebinds the shell, not a subshell, and
#   this function never returns -- it ends in the workload's exec.
_base_entrypoint_main() {
  local _lib_dir="${1:?_base_entrypoint_main requires a helper directory}"
  local _bringup="${2:?_base_entrypoint_main requires a bringup path}"
  shift 2

  if [[ -r "${_lib_dir}/logging.sh" ]]; then
    # shellcheck disable=SC1091  # in-image path, resolved at runtime
    . "${_lib_dir}/logging.sh"
  fi

  # The repo's own bringup. Sourced with the workload still in "$@", so a
  # bringup that inspects the command it is starting can.
  if [[ -r "${_bringup}" ]]; then
    # shellcheck disable=SC1090  # repo-owned, not resolvable from here
    . "${_bringup}"
  fi

  if [[ -r "${_lib_dir}/watchdog.sh" ]]; then
    # shellcheck disable=SC1091  # in-image path, resolved at runtime
    . "${_lib_dir}/watchdog.sh"
  fi

  exec "${@}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _base_entrypoint_main /usr/local/lib/base /entrypoint.sh "$@"
fi
