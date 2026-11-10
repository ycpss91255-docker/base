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
  local -A _sel=()
  local _job _path
  for _job in "${_CS_JOBS[@]}"; do _sel["${_job}"]=false; done
  while IFS= read -r -d '' _path; do
    case "${_path}" in
      # Docs select nothing: the doc-only allow-list classify's
      # code_changed gate already uses (.github/workflows/self-test.yaml).
      doc/* | README.md | LICENSE | CONTEXT.md) ;;
      # script/watch, script/test and script/ci are config-gen inputs:
      # the traced host side executes script/watch/pins.sh (step 30),
      # _rp_copy copies script/watch whole, and the job runs the
      # script/test and script/ci drivers. They keep every job.
      script/watch/* | script/test/* | script/ci/*)
        for _job in "${_CS_JOBS[@]}"; do _sel["${_job}"]=true; done
        ;;
      # Every justfile keeps every job, wherever it sits: the root
      # justfile loads the docker, test, release and watch modules, and a
      # syntax error in one unrelated module made `just a go` exit 1 in a
      # scratch probe, so a broken justfile.release fails `just test go`
      # (base#1584).
      justfile* | */justfile*)
        for _job in "${_CS_JOBS[@]}"; do _sel["${_job}"]=true; done
        ;;
      # E4: config-gen never reads init.sh. Its host side traced under
      # strace -f opened only dist/script/base/just-version.sh under
      # dist/, and the redpath's _rp_copy
      # (script/test/config_gen_redpath.sh) copies no dist/script/base/
      # file (base#1584).
      # E3: under script/, the trace and _rp_copy read only script/watch,
      # script/test and script/ci (kept above), so every other script/
      # path drops config-gen (base#1584).
      dist/script/base/init.sh | script/*)
        for _job in "${_CS_JOBS[@]}"; do
          [[ "${_job}" == config-gen ]] || _sel["${_job}"]=true
        done
        ;;
      *)
        for _job in "${_CS_JOBS[@]}"; do _sel["${_job}"]=true; done
        ;;
    esac
  done

  for _job in "${_CS_JOBS[@]}"; do
    printf '%s=%s\n' "${_job}" "${_sel[${_job}]}"
  done
}

main "$@"
