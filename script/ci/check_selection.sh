#!/usr/bin/env bash
#
# check_selection.sh -- which heavy self-test jobs a change can affect,
# base#1584.
#
# Usage:
#   check_selection.sh --event <event> --paths     # NUL-separated paths on stdin
#   check_selection.sh --event <event> --base <ref> # paths from git diff <ref>...HEAD
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
  printf 'usage: %s --event <event> (--base <ref> | --paths)\n' "${0##*/}" >&2
}

# _cs_in_roster <spec>
#   Succeeds when a script/test/mutation_required/*.tsv row names <spec>
#   in its third (spec) column, or when a roster TSV cannot be read, so
#   an unreadable roster keeps the job.
_cs_in_roster() {
  local _spec="$1" _dir _tsv _found=1
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../test/mutation_required" 2>/dev/null && pwd)" || return 0
  local -a _tsvs=("${_dir}"/*.tsv)
  [[ -r "${_tsvs[0]}" ]] || return 0
  for _tsv in "${_tsvs[@]}"; do
    [[ -r "${_tsv}" ]] || return 0
    if awk -F'\t' -v s="${_spec}" '!/^#/ && $3 == s { f = 1 } END { exit !f }' "${_tsv}"; then
      _found=0
    fi
  done
  return "${_found}"
}

# _cs_print_all
#   Prints every heavy job as selected: the answer for a run that is not
#   a pull request, and for a diff that cannot be read (fail closed).
_cs_print_all() {
  local _job
  for _job in "${_CS_JOBS[@]}"; do printf '%s=true\n' "${_job}"; done
}

# _cs_select_all
#   Marks every heavy job selected in the caller's _sel map.
_cs_select_all() {
  local _job
  for _job in "${_CS_JOBS[@]}"; do _sel["${_job}"]=true; done
}

# _cs_select_all_but <job>
#   Marks every heavy job except <job> selected in the caller's _sel map.
_cs_select_all_but() {
  local _job
  for _job in "${_CS_JOBS[@]}"; do
    [[ "${_job}" == "$1" ]] || _sel["${_job}"]=true
  done
}

main() {
  local _event="" _from_stdin=0 _base=""
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
      --base)
        (($# >= 2)) || { _cs_usage; return 2; }
        _base="$2"
        shift 2
        ;;
      *)
        _cs_usage
        return 2
        ;;
    esac
  done
  [[ -n "${_event}" ]] || { _cs_usage; return 2; }
  [[ "${_from_stdin}" -eq 1 || -n "${_base}" ]] || { _cs_usage; return 2; }

  # The selection is the union over every changed path. A path that no
  # row names selects every job.
  local -A _sel=()
  local _job _path
  # Only a pull request narrows the selection: push, tag and
  # workflow_dispatch runs select every job, so main runs the full suite
  # (owner decision, base#1584).
  if [[ "${_event}" != pull_request ]]; then
    _cs_print_all
    return 0
  fi
  # With --base the paths come from the PR diff. A diff that cannot be
  # read names no path, so nothing may be dropped: every job is selected
  # (fail closed, base#1584).
  if [[ -n "${_base}" && "${_from_stdin}" -eq 0 ]]; then
    local _diff
    _diff="$(mktemp)"
    if ! git diff -z --name-only --no-renames "${_base}...HEAD" >"${_diff}" 2>/dev/null; then
      rm -f "${_diff}"
      _cs_print_all
      return 0
    fi
    exec 0<"${_diff}"
    rm -f "${_diff}"
  fi
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
        _cs_select_all
        ;;
      # Every justfile keeps every job, wherever it sits: the root
      # justfile loads the docker, test, release and watch modules, and a
      # syntax error in one unrelated module made `just a go` exit 1 in a
      # scratch probe, so a broken justfile.release fails `just test go`
      # (base#1584).
      justfile* | */justfile*)
        _cs_select_all
        ;;
      # config-gen reads dist/script/base/just-version.sh (its just-pin
      # step, and the strace -f trace of its host side) and
      # dist/script/docker/lib/ (the redpath's _rp_copy,
      # script/test/config_gen_redpath.sh, copies lib/log.*). Both keep
      # every job (base#1584).
      dist/script/base/just-version.sh | dist/script/docker/lib/*)
        _cs_select_all
        ;;
      # E2: config-gen reads no other dist/ file. The trace opened
      # only just-version.sh under dist/, and _rp_copy copies no other
      # dist/ file (base#1584).
      # E3: under script/, the trace and _rp_copy read only script/watch,
      # script/test and script/ci (kept above), so every other script/
      # path drops config-gen (base#1584).
      # E4: the root init.sh and upgrade.sh are not in the trace,
      # _rp_copy does not copy them, and no script/test/config_gen* file
      # or dockerfile/Dockerfile.config-gen names them (base#1584).
      dist/* | script/* | init.sh | upgrade.sh)
        _cs_select_all_but config-gen
        ;;
      # E1: a unit spec is a leaf -- no file under test/ or script/ loads
      # or sources a `*_spec.bats` -- so config-gen and acceptance never
      # execute it, and script/ci/system_paths.sh lists test/bats/system
      # only, not test/bats/unit or test/bats/integration. It keeps
      # coverage, and keeps mutation-roster when a roster TSV names it in
      # its spec column or the roster cannot be read (base#1584).
      test/bats/unit/*_spec.bats | test/bats/integration/*_spec.bats)
        _sel[coverage]=true
        if _cs_in_roster "${_path}"; then _sel[mutation-roster]=true; fi
        ;;
      # E1 for a system spec: the same leaf argument drops config-gen and
      # acceptance, but script/ci/system_paths.sh lists test/bats/system/**,
      # so the system job keeps it (base#1584).
      test/bats/system/*_spec.bats)
        _sel[coverage]=true
        _sel[system]=true
        if _cs_in_roster "${_path}"; then _sel[mutation-roster]=true; fi
        ;;
      *)
        _cs_select_all
        ;;
    esac
  done

  for _job in "${_CS_JOBS[@]}"; do
    printf '%s=%s\n' "${_job}" "${_sel[${_job}]}"
  done
}

main "$@"
