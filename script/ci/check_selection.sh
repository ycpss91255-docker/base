#!/usr/bin/env bash
#
# check_selection.sh -- which heavy self-test jobs a change can affect,
# base#1584.
#
# Usage:
#   check_selection.sh --event <event> --paths     # NUL-separated paths on stdin
#
# Prints one `<job>=<true|false>` line per heavy job, in a fixed order.
#
# The map is SUBTRACTIVE: every changed path starts by selecting every
# heavy job, and only an exclusion row (cited next to its evidence) may
# take a job away. A path no row names therefore keeps every job, so a
# new or unknown path fails CLOSED.

set -euo pipefail

readonly -a _CS_JOBS=(config-gen mutation-roster coverage acceptance system)

_cs_usage() {
  printf 'usage: %s --event <event> --paths\n' "${0##*/}" >&2
}

main() {
  local _event="" _from_stdin=0
  while (($# > 0)); do
    case "$1" in
      --event)
        (($# >= 2)) || { _cs_usage; return 2; }
        _event="$2"
        shift 2
        ;;
      --paths)
        _from_stdin=1
        shift
        ;;
      *)
        _cs_usage
        return 2
        ;;
    esac
  done
  [[ -n "${_event}" && "${_from_stdin}" -eq 1 ]] || { _cs_usage; return 2; }

  # The selection is the union over every changed path. A path that no
  # row names selects every job.
  local _all=false _path
  while IFS= read -r -d '' _path; do
    case "${_path}" in
      # Docs select nothing: the doc-only allow-list classify's
      # code_changed gate already uses (.github/workflows/self-test.yaml).
      doc/* | README.md | LICENSE | CONTEXT.md) ;;
      *) _all=true ;;
    esac
  done

  local _job
  for _job in "${_CS_JOBS[@]}"; do
    printf '%s=%s\n' "${_job}" "${_all}"
  done
}

main "$@"
