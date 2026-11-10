#!/usr/bin/env bash
#
# selection_at_base.sh -- the per-job selection of a change, judged by the
# BASE side's map, base#1584.
#
# Usage:
#   selection_at_base.sh --base <ref> --event <event> (--diff | --paths)
#
# The one way to get a selection: CI's classify job and
# `test.sh --selection` both call this. It copies the map and its deny
# list out of <ref> with `git show <ref>:script/ci/<file>` into a scratch
# directory and runs that copy, with the working directory left at the
# checkout so its `git diff` still sees HEAD. The working tree's map is
# never run, so a pull request that edits the map, the deny list, the
# readers script or this file is judged by the base map, to which each of
# those files is an unknown path that selects every job.
#
# --diff passes `--base <ref>` to the map; --paths passes stdin through.
#
# Fails closed: when <ref> is empty or names no commit, when the base has
# no map or deny list (the pull request that adds them, or any base older
# than them), or when the base map exits non-zero, it prints every job
# `true`, names the reason on stderr as `check_selection_select_all
# reason=<r>` and exits 0. The job names then come from the working
# tree's `--jobs`; a name it leaves out reads `true` downstream anyway,
# because classify writes `true` for every job with no `false` line.

set -euo pipefail

_SAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly _SAB_DIR
readonly -a _SAB_FILES=(check_selection.sh config_gen_paths.sh)

_sab_usage() {
  printf 'usage: %s --base <ref> --event <event> (--diff | --paths)\n' "${0##*/}" >&2
}

# _sab_select_all <reason>
_sab_select_all() {
  local _job
  printf 'check_selection_select_all reason=%s\n' "$1" >&2
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] && printf '%s=true\n' "${_job}"
  done < <(bash "${_SAB_DIR}/check_selection.sh" --jobs 2>/dev/null || true)
}

main() {
  local _base="" _have_base=0 _event="" _mode=""
  while (($# > 0)); do
    case "$1" in
      --base | --event)
        (($# >= 2)) || { _sab_usage; return 2; }
        if [[ "$1" == --base ]]; then _have_base=1; _base="$2"; else _event="$2"; fi
        shift 2
        ;;
      --diff | --paths) _mode="${1#--}"; shift ;;
      *) _sab_usage; return 2 ;;
    esac
  done
  [[ "${_have_base}" -eq 1 && -n "${_event}" && -n "${_mode}" ]] || { _sab_usage; return 2; }

  [[ -n "${_base}" ]] || { _sab_select_all empty_base; return 0; }
  git rev-parse --verify --quiet "${_base}^{commit}" >/dev/null 2>&1 \
    || { _sab_select_all bad_base; return 0; }

  local _judge _f
  _judge="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now; the dir is local to this run
  trap "rm -rf '${_judge}'" EXIT
  for _f in "${_SAB_FILES[@]}"; do
    git show "${_base}:script/ci/${_f}" >"${_judge}/${_f}" 2>/dev/null \
      || { _sab_select_all map_missing_on_base; return 0; }
  done

  local _out _rc=0
  if [[ "${_mode}" == diff ]]; then
    _out="$(bash "${_judge}/check_selection.sh" --event "${_event}" --base "${_base}" </dev/null)" || _rc=$?
  else
    _out="$(bash "${_judge}/check_selection.sh" --event "${_event}" --paths)" || _rc=$?
  fi
  ((_rc == 0)) || { _sab_select_all base_map_failed; return 0; }
  printf '%s\n' "${_out}"
}

main "$@"
