#!/usr/bin/env bash
#
# mutation_required.sh -- the required-kill roster runner (base#1461).
#
# Usage:
#   ./script/test/drivers/mutation_required.sh [--root <dir>] [--check]
#   ./script/test/drivers/mutation_required.sh --apply <subject> <old-file> <new-file>
#
# Every shell refusal guard a config-gen slice adds is listed, with the
# mutation that disables it, in script/test/mutation_required/<slice>.tsv.
# This runner reads every row of every roster file, validates ALL of them
# before any baseline runs, probes each row with
# script/test/mutation-probe.sh in a private sandbox copy of the checkout,
# and exits 0 only when every row is PINNED. Before it, nothing read the
# roster: a pinning test could be deleted with every gate green.
#
# Row contract, one for every roster file:
#   <id> TAB <subject> TAB <spec> TAB <old> TAB <new>
# `#` lines and blank lines are skipped. <old> and <new> are decoded with
# exactly three escapes, `\\` `\t` `\n`; any other `\x` or a trailing `\`
# is reason=bad_escape. <old> must occur exactly once in <subject>; <new>
# may be empty (a deletion) and must differ from <old>.
#
# --root <dir>  the checkout whose roster is read (default: this checkout).
# --check       validate the roster and run nothing.
# --apply       the one way a row edits its subject, run by the probe from
#               the sandbox root: replace the one occurrence of <old-file>'s
#               bytes in <subject> with <new-file>'s, keeping the mode;
#               exit 1, the file untouched, on zero or several occurrences.
#
# Environment:
#   MUTATION_REQUIRED_JOBS   rows probed at once, 1..99 (default 4).
#   MUTATION_REQUIRED_PROBE  the probe to run (default: this checkout's
#                            script/test/mutation-probe.sh).
#
# Each row runs in its own worker process group: build the sandbox (a
# `git ls-files` copy of the working tree, committed in a fresh repository,
# every step fail-closed), derive the sandbox's own compose project from
# its path (an inherited COMPOSE_PROJECT_NAME is not used), probe, and tear
# down -- a container of that project still running keeps the sandbox and
# fails the row. Verdicts are published only after every worker is reaped,
# and a failing run publishes no pass. The first INT / TERM is forwarded to
# every worker, which forwards it to its probe; the run then exits 130 /
# 143 with no verdict.
#
# Exit: 0 every row PINNED (or --check clean); 1 a row invalid, survived,
# refused, held or a sandbox failed, or an empty roster; 2 usage or
# MUTATION_REQUIRED_JOBS invalid; 130 / 143 interrupted.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -uo pipefail
fi

_MR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _MR_DIR
_MR_SELF="${_MR_DIR}/$(basename -- "${BASH_SOURCE[0]:-$0}")"
readonly _MR_SELF
# shellcheck source=dist/script/docker/lib/log.sh
source "${_MR_DIR}/../../../dist/script/docker/lib/log.sh"

readonly _MR_SERVICE='mutation-required'
readonly _MR_ROSTER_REL='script/test/mutation_required'

# ── the three escapes ───────────────────────────────────────────────────────

# _mr_decode <text> -- print <text> with `\\` `\t` `\n` decoded; non-zero on
# any other escape or a trailing backslash. Not printf %b, which knows a
# dozen more.
_mr_decode() {
  local _in="${1}" _out='' _c _i
  for (( _i = 0; _i < ${#_in}; _i++ )); do
    _c="${_in:_i:1}"
    if [[ "${_c}" == "\\" ]]; then
      _i=$(( _i + 1 ))
      (( _i < ${#_in} )) || return 1
      case "${_in:_i:1}" in
        "\\") _out+="\\" ;;
        t) _out+=$'\t' ;;
        n) _out+=$'\n' ;;
        *) return 1 ;;
      esac
    else
      _out+="${_c}"
    fi
  done
  printf '%s' "${_out}"
}

# ── finding <old> in a file ─────────────────────────────────────────────────

# _mr_splice <mode> <file> -- with MR_OLD (and MR_NEW) in the environment:
# mode `count` prints 0, 1 or 2 (two or more) occurrences of MR_OLD in
# <file>; mode `apply` prints the file with its one occurrence replaced,
# exit 3 unless there is exactly one. Occurrences are counted at every start
# offset, so overlapping ones (`aa` in `aaa`) are two: the second search
# resumes one byte past the first match's start, not past its end. awk's
# index(), byte-wise: bash's own `${s%%"$old"*}` is quadratic and took
# seconds on a 120 KB subject.
_mr_splice() {
  local _mode="${1}" _file="${2}" _nonl=0
  if [[ -s "${_file}" ]] && [[ "$(tail -c 1 -- "${_file}" | wc -l)" -eq 0 ]]; then
    _nonl=1
  fi
  LC_ALL=C MR_MODE="${_mode}" MR_NONL="${_nonl}" awk '
    { s = s $0 "\n" }
    END {
      if (ENVIRON["MR_NONL"] == 1) s = substr(s, 1, length(s) - 1)
      o = ENVIRON["MR_OLD"]
      i = (o == "") ? 0 : index(s, o)
      if (i == 0) n = 0
      else n = index(substr(s, i + 1), o) ? 2 : 1
      if (ENVIRON["MR_MODE"] == "count") { print n; exit 0 }
      if (n != 1) exit 3
      printf "%s%s%s", substr(s, 1, i - 1), ENVIRON["MR_NEW"], substr(s, i + length(o))
    }' "${_file}"
}

# _mr_has_nul <file> -- 0 when <file> carries a NUL byte. A shell value
# cannot hold one (a command substitution drops it), so a NUL-bearing file
# is one this driver cannot rewrite byte-exactly.
_mr_has_nul() {
  [[ "$(tr -d '\000' < "${1}" | wc -c)" != "$(wc -c < "${1}")" ]]
}

# _mr_apply <subject> <old-file> <new-file> -- the --apply mode. A subject
# with a NUL byte is refused, not rewritten without it.
_mr_apply() {
  local _subj="${1:-}" _oldf="${2:-}" _newf="${3:-}" _old='' _new='' _out
  [[ -n "${_subj}" && -f "${_subj}" && ! -L "${_subj}" ]] || return 1
  ! _mr_has_nul "${_subj}" || return 1
  [[ -f "${_oldf}" && -f "${_newf}" ]] || return 1
  IFS= read -r -d '' _old < "${_oldf}" || true
  IFS= read -r -d '' _new < "${_newf}" || true
  [[ -n "${_old}" ]] || return 1
  _out="$(MR_OLD="${_old}" MR_NEW="${_new}" _mr_splice apply "${_subj}"; rc=$?
          printf 'x'; exit "${rc}")" || return 1
  printf '%s' "${_out%x}" > "${_subj}" || return 1
  return 0
}

# ── validation, before any baseline ─────────────────────────────────────────

# Per row, filled by _mr_validate: the location, id, subject, spec, decoded
# old and new.
_MR_ROWS_LOC=()
_MR_ROWS_ID=()
_MR_ROWS_SUBJ=()
_MR_ROWS_SPEC=()
_MR_ROWS_OLD=()
_MR_ROWS_NEW=()

# _mr_invalid <loc> <id> <reason> <display> -- one refused row.
_mr_invalid() {
  _log_err "${_MR_SERVICE}" mutation_required_row_invalid "row=${1}" "id=${2}" \
    "reason=${3}" "display=mutation roster row ${1} (id '${2}') is invalid: ${4}"
}

# _mr_path_reason <root> <path> -- print a path reason (path_absolute,
# path_dotdot, path_symlink) and return 0, or return 1 for a plain path.
_mr_path_reason() {
  local _root="${1}" _p="${2}" _prefix='' _seg _rest
  if [[ "${_p}" == /* ]]; then printf 'path_absolute'; return 0; fi
  case "/${_p}/" in */../*|*/./*) printf 'path_dotdot'; return 0 ;; esac
  _rest="${_p}"
  while :; do
    _seg="${_rest%%/*}"
    _prefix="${_prefix:+${_prefix}/}${_seg}"
    if [[ -L "${_root}/${_prefix}" ]]; then printf 'path_symlink'; return 0; fi
    [[ "${_rest}" == */* ]] || break
    _rest="${_rest#*/}"
  done
  return 1
}

# _mr_validate <root> -- read every roster file, refuse every invalid row,
# fill _MR_ROWS_*. 0 when every row is valid and there is at least one.
_mr_validate() {
  local _root="${1}" _dir="${1}/${_MR_ROSTER_REL}" _f _rel _line _n _bad=0
  local _id _subj _spec _old _new _rest _reason _count _key _loc
  local -a _fl=() _files=()
  local -A _ids=() _tuples=()
  if [[ -d "${_dir}" ]]; then
    mapfile -t _files < <(LC_ALL=C find "${_dir}" -maxdepth 1 -name '*.tsv' -type f | LC_ALL=C sort)
  fi
  for _f in "${_files[@]+"${_files[@]}"}"; do
    _rel="${_MR_ROSTER_REL}/$(basename -- "${_f}")"
    if _mr_has_nul "${_f}"; then
      _mr_invalid "${_rel}:0" '' nul "the file carries a NUL byte"
      _bad=1
      continue
    fi
    _n=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _n=$(( _n + 1 ))
      _loc="${_rel}:${_n}"
      [[ -z "${_line}" || "${_line}" == '#'* ]] && continue
      _fl=()
      _rest="${_line}"
      while [[ "${_rest}" == *$'\t'* ]]; do
        _fl+=( "${_rest%%$'\t'*}" )
        _rest="${_rest#*$'\t'}"
      done
      _fl+=( "${_rest}" )
      _id="${_fl[0]}"
      if [[ "${_line}" == *$'\r'* ]]; then
        _mr_invalid "${_loc}" "${_id}" cr "the row carries a carriage return"
        _bad=1; continue
      fi
      if (( ${#_fl[@]} != 5 )); then
        _mr_invalid "${_loc}" "${_id}" field_count \
          "${#_fl[@]} TAB-separated fields, the contract is <id> <subject> <spec> <old> <new>"
        _bad=1; continue
      fi
      _subj="${_fl[1]}"; _spec="${_fl[2]}"
      if [[ -z "${_id}" || -z "${_subj}" || -z "${_spec}" || -z "${_fl[3]}" ]]; then
        _mr_invalid "${_loc}" "${_id}" empty_field "id, subject, spec and old must be non-empty"
        _bad=1; continue
      fi
      if [[ ! "${_id}" =~ ^[a-z0-9-]+$ ]]; then
        _mr_invalid "${_loc}" "${_id}" id_invalid "an id is [a-z0-9-]+"
        _bad=1; continue
      fi
      if _reason="$(_mr_path_reason "${_root}" "${_subj}")" \
        || _reason="$(_mr_path_reason "${_root}" "${_spec}")"; then
        _mr_invalid "${_loc}" "${_id}" "${_reason}" "subject and spec are plain paths under the root"
        _bad=1; continue
      fi
      if [[ ! -f "${_root}/${_subj}" ]]; then
        _mr_invalid "${_loc}" "${_id}" subject_missing "no file ${_subj}"
        _bad=1; continue
      fi
      if _mr_has_nul "${_root}/${_subj}"; then
        _mr_invalid "${_loc}" "${_id}" subject_has_nul \
          "${_subj} carries a NUL byte, which --apply cannot carry through a byte-exact edit"
        _bad=1; continue
      fi
      if [[ "${_spec}" != test/bats/* ]]; then
        _mr_invalid "${_loc}" "${_id}" spec_not_under_test_bats "${_spec} is not a spec under test/bats/"
        _bad=1; continue
      fi
      if [[ ! -f "${_root}/${_spec}" ]]; then
        _mr_invalid "${_loc}" "${_id}" spec_missing "no spec ${_spec}: the pinning test is gone"
        _bad=1; continue
      fi
      if ! _old="$(_mr_decode "${_fl[3]}" && printf 'x')" \
        || ! _new="$(_mr_decode "${_fl[4]}" && printf 'x')"; then
        _mr_invalid "${_loc}" "${_id}" bad_escape "old and new know only the escapes \\\\ \\t \\n"
        _bad=1; continue
      fi
      _old="${_old%x}"; _new="${_new%x}"
      if [[ "${_old}" == "${_new}" ]]; then
        _mr_invalid "${_loc}" "${_id}" new_equals_old "the mutation changes no byte"
        _bad=1; continue
      fi
      _count="$(MR_OLD="${_old}" _mr_splice count "${_root}/${_subj}")"
      if [[ "${_count}" == 0 ]]; then
        _mr_invalid "${_loc}" "${_id}" old_not_found "old does not occur in ${_subj}"
        _bad=1; continue
      elif [[ "${_count}" != 1 ]]; then
        _mr_invalid "${_loc}" "${_id}" old_ambiguous "old occurs more than once in ${_subj}"
        _bad=1; continue
      fi
      if [[ -n "${_ids["${_rel}|${_id}"]:-}" ]]; then
        _mr_invalid "${_loc}" "${_id}" duplicate_row "id ${_id} is also row ${_ids["${_rel}|${_id}"]}"
        _bad=1; continue
      fi
      _key="${_subj}"$'\t'"${_spec}"$'\t'"${_fl[3]}"$'\t'"${_fl[4]}"
      if [[ -n "${_tuples["${_key}"]:-}" ]]; then
        _mr_invalid "${_loc}" "${_id}" duplicate_row "the same mutation is row ${_tuples["${_key}"]}"
        _bad=1; continue
      fi
      _ids["${_rel}|${_id}"]="${_loc}"
      _tuples["${_key}"]="${_loc}"
      _MR_ROWS_LOC+=( "${_loc}" )
      _MR_ROWS_ID+=( "${_id}" )
      _MR_ROWS_SUBJ+=( "${_subj}" )
      _MR_ROWS_SPEC+=( "${_spec}" )
      _MR_ROWS_OLD+=( "${_old}" )
      _MR_ROWS_NEW+=( "${_new}" )
    done < "${_f}"
  done
  (( _bad == 0 )) || return 1
  if (( ${#_MR_ROWS_LOC[@]} == 0 )); then
    _log_err "${_MR_SERVICE}" mutation_required_roster_empty "dir=${_MR_ROSTER_REL}" \
      "display=the mutation roster ${_MR_ROSTER_REL} holds no row; a roster that checks nothing is not a pass"
    return 1
  fi
  return 0
}

# ── the worker: one row, one sandbox, one process group ─────────────────────

# Set by the worker's INT / TERM trap; the probe pid it forwards to.
_MRW_SIG=''
_MRW_PROBE=''

_mrw_on_signal() {
  [[ -z "${_MRW_SIG}" ]] || return 0
  _MRW_SIG="${1}"
  [[ -z "${_MRW_PROBE}" ]] || kill -s "${1}" "${_MRW_PROBE}" 2>/dev/null || true
}

# _mrw_res <event> [<attr>=<value>]... -- write the row's result, the one
# thing a worker says; the driver publishes it. Newlines in a value fold to
# ` | ` so every line is one attribute.
_mrw_res() {
  local _a
  {
    printf '%s\n' "${1}"
    shift
    for _a in "$@"; do
      _a="${_a//$'\n'/ | }"
      printf '%s\n' "${_a}"
    done
  } > "${_MRW_DIR}/res.tmp" && mv -f "${_MRW_DIR}/res.tmp" "${_MRW_DIR}/res"
}

# _mrw_step <name> <cmd>... -- run one sandbox build step; on failure record
# sandbox_failed and return 1. A pending signal also stops the build.
_mrw_step() {
  local _name="${1}" _rc=0
  shift
  "$@" > "${_MRW_DIR}/step.err" 2>&1 || _rc=$?
  if [[ -n "${_MRW_SIG}" ]]; then return 1; fi
  if (( _rc != 0 )); then
    _mrw_res mutation_required_sandbox_failed "step=${_name}" "rc=${_rc}" \
      "detail=$(tail -n 5 "${_MRW_DIR}/step.err" 2>/dev/null)"
    return 1
  fi
  return 0
}

# _mrw_filter <all> <deleted> <out> -- the NUL list <all> less the names in
# <deleted>, de-duplicated (an unmerged path is listed once per stage),
# written one per line for `tar -T`. busybox tar (the test-tools image) has
# no --null and GNU tar reads a -T line starting with `-` as an option and
# unquotes backslashes, so a name holding a newline or a backslash, or
# starting with `-`, is refused rather than copied as something else.
_mrw_filter() {
  local _p
  local -a _all=() _del=()
  local -A _gone=() _seen=()
  mapfile -d '' -t _all < "${1}" || return 1
  mapfile -d '' -t _del < "${2}" || return 1
  for _p in "${_del[@]+"${_del[@]}"}"; do _gone["${_p}"]=1; done
  : > "${3}" || return 1
  for _p in "${_all[@]+"${_all[@]}"}"; do
    [[ -z "${_gone["${_p}"]:-}" && -z "${_seen["${_p}"]:-}" ]] || continue
    _seen["${_p}"]=1
    case "${_p}" in
      *$'\n'*|*\\*|-*) echo "a path tar -T cannot carry: ${_p@Q}"; return 1 ;;
    esac
    printf '%s\n' "${_p}" >> "${3}" || return 1
  done
}

# _mrw_verify <root> <sandbox> <list> -- every listed path is in the
# sandbox with the type it has in the root, and the sandbox holds nothing
# else.
_mrw_verify() {
  local _root="${1}" _sbx="${2}" _p _have _want
  local -a _l=()
  mapfile -t _l < "${3}" || return 1
  for _p in "${_l[@]+"${_l[@]}"}"; do
    if [[ -L "${_root}/${_p}" ]]; then
      [[ -L "${_sbx}/${_p}" ]] || { echo "not a link in the sandbox: ${_p}"; return 1; }
    elif [[ -f "${_root}/${_p}" ]]; then
      [[ -f "${_sbx}/${_p}" && ! -L "${_sbx}/${_p}" ]] || { echo "not a file in the sandbox: ${_p}"; return 1; }
    elif [[ -d "${_root}/${_p}" ]]; then
      [[ -d "${_sbx}/${_p}" ]] || { echo "not a directory in the sandbox: ${_p}"; return 1; }
    else
      echo "gone from the root while it was copied: ${_p}"; return 1
    fi
  done
  _want="${#_l[@]}"
  _have="$(cd -- "${_sbx}" && find . \( -type f -o -type l \) | wc -l)"
  (( _have <= _want )) || { echo "the sandbox holds ${_have} files, the list ${_want}"; return 1; }
}

# _mrw_clean <sandbox> -- the committed sandbox has nothing to report.
_mrw_clean() {
  local _s
  _s="$(git -C "${1}" status --porcelain -z)" || return 1
  [[ -z "${_s}" ]] || { echo "the sandbox is dirty after its commit: ${_s}"; return 1; }
}

# _mrw_commit <sandbox> -- a fresh repository holding the copy, every file
# added (a tracked file that matches .gitignore included), no hooks.
_mrw_commit() {
  git -C "${1}" init -q \
    && git -C "${1}" add -A -f \
    && git -C "${1}" -c user.name=mutation-required -c user.email=mutation-required@localhost \
         -c commit.gpgsign=false -c core.hooksPath=/dev/null \
         commit -q --no-verify -m 'mutation-required sandbox'
}

# _mrw_verdict <rc> <out> <spec> -- map the probe's result; prints the
# event and attributes, one per line.
_mrw_verdict() {
  local _rc="${1}" _out="${2}" _spec="${3}" _i _n _hit=-1 _cnt=0
  local _pinned="mutation probe: PINNED. The assertions that noticed, at scope=spec:${_spec}:"
  local _count_re="^mutation probe: ([0-9]+) executed / ([0-9]+) not ok / ([0-9]+) skipped at scope=spec:"
  local -a _l=() _w=()
  mapfile -t _l < "${_out}"
  for (( _i = 0; _i < ${#_l[@]}; _i++ )); do
    if [[ "${_l[_i]}" == "${_pinned}" ]]; then _hit="${_i}"; _cnt=$(( _cnt + 1 )); fi
  done
  if (( _rc == 0 )); then
    if (( _cnt == 1 && _hit > 0 )) \
      && [[ "${_l[_hit-1]}" == "mutation probe: "*" at scope=spec:${_spec}" ]] \
      && [[ "${_l[_hit-1]}" =~ ${_count_re} ]]; then
      _n="${BASH_REMATCH[2]}"
      if (( _n >= 1 )); then
        for (( _i = _hit + 1; _i < ${#_l[@]}; _i++ )); do
          [[ "${_l[_i]}" == 'not ok '* ]] && _w+=( "${_l[_i]}" )
        done
        printf '%s\n' mutation_required_pinned "witnesses=$(IFS='|'; printf '%s' "${_w[*]+"${_w[*]}"}")"
        return 0
      fi
    fi
    printf '%s\n' mutation_required_probe_refused "rc=${_rc}"
    return 0
  fi
  if (( _rc == 1 )) && grep -qF "mutation probe: NOT PINNED at scope=" "${_out}"; then
    printf '%s\n' mutation_required_survived verdict=NOT_PINNED
  elif (( _rc == 2 )) && grep -qF "mutation probe: INCONCLUSIVE at scope=" "${_out}"; then
    printf '%s\n' mutation_required_survived verdict=INCONCLUSIVE
  else
    printf '%s\n' mutation_required_probe_refused "rc=${_rc}"
  fi
}

# _mr_worker <row-dir> -- probe the row described in <row-dir>/meta (NUL
# fields: subject, spec), with <row-dir>/old and <row-dir>/new. Root, probe
# and the names to avoid come from MR_W_* in the environment.
_mr_worker() {
  _MRW_DIR="${1}"
  trap '_mrw_on_signal INT' INT
  trap '_mrw_on_signal TERM' TERM
  local -a _meta=()
  mapfile -d '' -t _meta < "${_MRW_DIR}/meta"
  local _subj="${_meta[0]}" _spec="${_meta[1]}" _root="${MR_W_ROOT}"
  local _sbx='' _name='' _rc=0 _mut
  local -a _verdict=()

  _mrw_teardown() {
    local _ids _qrc=0
    [[ -n "${_sbx}" ]] || return 0
    if [[ -z "${_name}" ]]; then
      rm -rf -- "${_sbx}"
      return 0
    fi
    _ids="$(timeout 30 docker ps -q --filter "label=com.docker.compose.project=${_name}" 2>/dev/null)" || _qrc=$?
    if (( _qrc == 0 )) && [[ -z "${_ids}" ]]; then
      rm -rf -- "${_sbx}"
      return 0
    fi
    _mrw_res mutation_required_sandbox_held "path=${_sbx}" "project=${_name}" \
      "query_rc=${_qrc}" "containers=${_ids}"
    return 1
  }

  _mrw_finish() {
    if [[ -n "${_MRW_SIG}" ]]; then
      _mrw_teardown || return 0
      _mrw_res mutation_required_interrupted "signal=${_MRW_SIG}"
      return 0
    fi
    _mrw_teardown || return 0
    (( ${#_verdict[@]} == 0 )) || _mrw_res "${_verdict[@]}"
  }

  _sbx="$(mktemp -d "${TMPDIR:-/tmp}/mutation-required.XXXXXX")" || {
    _mrw_res mutation_required_sandbox_failed step=mktemp rc=1; return 0; }
  # shellcheck disable=SC2016  # expanded by the sh that runs the step.
  if ! { _mrw_step enumerate sh -c 'git -C "$1" ls-files -z --cached --others --exclude-standard > "$2"' \
      _ "${_root}" "${_MRW_DIR}/list.all" \
    && _mrw_step enumerate sh -c 'git -C "$1" ls-files -z --deleted > "$2"' \
      _ "${_root}" "${_MRW_DIR}/list.del" \
    && _mrw_step filter _mrw_filter "${_MRW_DIR}/list.all" "${_MRW_DIR}/list.del" "${_MRW_DIR}/list" \
    && _mrw_step archive tar -c -f "${_MRW_DIR}/snap.tar" -C "${_root}" --no-recursion -T "${_MRW_DIR}/list" \
    && _mrw_step extract tar -x -f "${_MRW_DIR}/snap.tar" -C "${_sbx}" \
    && _mrw_step verify _mrw_verify "${_root}" "${_sbx}" "${_MRW_DIR}/list" \
    && _mrw_step commit _mrw_commit "${_sbx}" \
    && _mrw_step clean _mrw_clean "${_sbx}"; }; then
    _mrw_finish
    return 0
  fi

  # The sandbox's own project, from the sandbox's own test.sh over its
  # unique path. An inherited COMPOSE_PROJECT_NAME would be printed back
  # verbatim, so it is removed for the question and then refused as the
  # answer, as is the live checkout's name.
  _name="$(env -u COMPOSE_PROJECT_NAME "${_sbx}/script/test/test.sh" --compose-project-name 2>/dev/null)" || _rc=$?
  if [[ -n "${_MRW_SIG}" ]]; then _name=''; _mrw_finish; return 0; fi
  if (( _rc != 0 )) || [[ -z "${_name}" || "${_name}" == "${MR_W_INHERITED:-}" \
    || ( -n "${MR_W_LIVE:-}" && "${_name}" == "${MR_W_LIVE}" ) ]]; then
    _mrw_res mutation_required_sandbox_failed step=project "rc=${_rc}" "project=${_name}"
    _name=''
    _mrw_finish
    return 0
  fi

  printf -v _mut '%q ' bash "${_MR_SELF}" --apply "${_subj}" "${_MRW_DIR}/old" "${_MRW_DIR}/new"
  _rc=0
  set -m
  COMPOSE_PROJECT_NAME="${_name}" bash "${MR_W_PROBE:?}" --root "${_sbx}" --subject "${_subj}" \
    --spec "${_spec}" --mutate "${_mut}" \
    < /dev/null > "${_MRW_DIR}/out" 2> "${_MRW_DIR}/err" &
  _MRW_PROBE="$!"
  set +m
  # A signal that landed between the fork and the line above is forwarded
  # here; the trap forwards any later one.
  [[ -z "${_MRW_SIG}" ]] || kill -s "${_MRW_SIG}" "${_MRW_PROBE}" 2>/dev/null || true
  while :; do
    _rc=0
    wait "${_MRW_PROBE}" || _rc=$?
    if (( _rc > 128 )) && kill -0 "${_MRW_PROBE}" 2>/dev/null; then continue; fi
    break
  done
  _MRW_PROBE=''
  if [[ -z "${_MRW_SIG}" ]]; then
    mapfile -t _verdict < <(_mrw_verdict "${_rc}" "${_MRW_DIR}/out" "${_spec}")
    if [[ "${_verdict[0]:-}" != mutation_required_pinned ]]; then
      _verdict+=( "transcript=$(cat "${_MRW_DIR}/out" "${_MRW_DIR}/err" 2>/dev/null)" )
    fi
  fi
  _mrw_finish
  return 0
}

# ── the driver ──────────────────────────────────────────────────────────────

# The first INT / TERM the driver received, and the live worker pids.
_MR_SIG=''
declare -A _MR_LIVE=()

_mr_on_signal() {
  [[ -z "${_MR_SIG}" ]] || return 0
  _MR_SIG="${1}"
  local _p
  for _p in "${!_MR_LIVE[@]}"; do
    kill -s "${1}" -- "-${_p}" 2>/dev/null || true
  done
}

_MR_WORK=''
_mr_cleanup() {
  [[ -z "${_MR_WORK}" ]] || rm -rf -- "${_MR_WORK}"
}

# _mr_reap_one -- wait for any live worker and drop it from _MR_LIVE. A
# trap that interrupts the wait leaves the set unchanged.
_mr_reap_one() {
  local _pid='' _p
  wait -n -p _pid "${!_MR_LIVE[@]}" 2>/dev/null || true
  if [[ -n "${_pid:-}" ]]; then
    unset '_MR_LIVE[$_pid]'
    return 0
  fi
  # wait -n names no pid when a trap interrupted it, or when the set holds
  # a pid it no longer knows; drop those.
  for _p in "${!_MR_LIVE[@]}"; do
    kill -0 "${_p}" 2>/dev/null || { wait "${_p}" 2>/dev/null; unset '_MR_LIVE[$_p]'; }
  done
}

# _mr_row_err <event> <i> [<attr>=<value>]... -- one refusal about row <i>,
# its location and id first. One line, event first: the shape
# log_event_registry.sh reads as a forwarding wrapper.
_mr_row_err() { _log_err "${_MR_SERVICE}" "${1}" "row=${_MR_ROWS_LOC[$2]}" "id=${_MR_ROWS_ID[$2]}" "${@:3}"; }

# _mr_publish_interrupted -- the signal exit: no verdict, the held
# sandboxes named.
_mr_publish_interrupted() {
  local _i _ev
  local -a _r=()
  for (( _i = 0; _i < ${#_MR_ROWS_LOC[@]}; _i++ )); do
    [[ -f "${_MR_WORK}/row${_i}/res" ]] || continue
    mapfile -t _r < "${_MR_WORK}/row${_i}/res"
    _ev="${_r[0]}"
    if [[ "${_ev}" == mutation_required_sandbox_held ]]; then
      _mr_row_err mutation_required_sandbox_held "${_i}" "${_r[@]:1}" \
        "display=a container of the sandbox's project was still running (or docker could not be asked); the sandbox is kept"
    fi
  done
  _log_err "${_MR_SERVICE}" mutation_required_interrupted "signal=${_MR_SIG}" \
    "display=interrupted by SIG${_MR_SIG}, so there is no verdict"
  [[ "${_MR_SIG}" == INT ]] && return 130
  return 143
}

# _mr_run <root> <jobs> -- probe every validated row, at most <jobs> at a
# time, then publish.
_mr_run() {
  local _root="${1}" _jobs="${2}" _i _pid _live='' _probe _ev _fail=0
  local -a _r=()
  _probe="${MUTATION_REQUIRED_PROBE:-${_MR_DIR}/../mutation-probe.sh}"
  _MR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/mutation-required-run.XXXXXX")" || return 1
  _live="$(env -u COMPOSE_PROJECT_NAME "${_root}/script/test/test.sh" --compose-project-name 2>/dev/null)" || _live=''
  for (( _i = 0; _i < ${#_MR_ROWS_LOC[@]}; _i++ )); do
    [[ -z "${_MR_SIG}" ]] || break
    mkdir -p "${_MR_WORK}/row${_i}"
    printf '%s\0%s\0' "${_MR_ROWS_SUBJ[_i]}" "${_MR_ROWS_SPEC[_i]}" > "${_MR_WORK}/row${_i}/meta"
    printf '%s' "${_MR_ROWS_OLD[_i]}" > "${_MR_WORK}/row${_i}/old"
    printf '%s' "${_MR_ROWS_NEW[_i]}" > "${_MR_WORK}/row${_i}/new"
    while (( ${#_MR_LIVE[@]} >= _jobs )) && [[ -z "${_MR_SIG}" ]]; do
      _mr_reap_one
    done
    [[ -z "${_MR_SIG}" ]] || break
    # Its own process group, so a forwarded signal reaches the worker and
    # its build steps, and INT is not ignored as it is for a background job
    # started without job control.
    set -m
    MR_W_ROOT="${_root}" MR_W_PROBE="${_probe}" MR_W_LIVE="${_live}" \
      MR_W_INHERITED="${_MR_INHERITED}" \
      bash "${_MR_SELF}" --worker "${_MR_WORK}/row${_i}" < /dev/null &
    _pid="$!"
    set +m
    _MR_LIVE["${_pid}"]=1
    [[ -z "${_MR_SIG}" ]] || kill -s "${_MR_SIG}" -- "-${_pid}" 2>/dev/null || true
  done
  while (( ${#_MR_LIVE[@]} > 0 )); do
    _mr_reap_one
  done

  if [[ -n "${_MR_SIG}" ]]; then
    _mr_publish_interrupted
    return
  fi

  # Every worker is reaped: publish. Failures first decide the run; a
  # failing run publishes no pass.
  for (( _i = 0; _i < ${#_MR_ROWS_LOC[@]}; _i++ )); do
    if [[ ! -f "${_MR_WORK}/row${_i}/res" ]]; then
      _mr_row_err mutation_required_sandbox_failed "${_i}" step=worker rc=unknown \
        "display=the worker for row ${_MR_ROWS_LOC[_i]} ended without a result"
      _fail=1
      continue
    fi
    mapfile -t _r < "${_MR_WORK}/row${_i}/res"
    _ev="${_r[0]}"
    case "${_ev}" in
      mutation_required_pinned) ;;
      mutation_required_survived)
        _mr_row_err mutation_required_survived "${_i}" \
          "subject=${_MR_ROWS_SUBJ[_i]}" "spec=${_MR_ROWS_SPEC[_i]}" "${_r[@]:1}" \
          "display=row ${_MR_ROWS_LOC[_i]} (${_MR_ROWS_ID[_i]}): ${_MR_ROWS_SPEC[_i]} stays green with the guard in ${_MR_ROWS_SUBJ[_i]} disabled -- nothing pins it"
        _fail=1 ;;
      mutation_required_probe_refused)
        _mr_row_err mutation_required_probe_refused "${_i}" \
          "subject=${_MR_ROWS_SUBJ[_i]}" "spec=${_MR_ROWS_SPEC[_i]}" "${_r[@]:1}" \
          "display=row ${_MR_ROWS_LOC[_i]} (${_MR_ROWS_ID[_i]}): the probe gave no PINNED verdict a reader can check"
        _fail=1 ;;
      mutation_required_sandbox_failed)
        _mr_row_err mutation_required_sandbox_failed "${_i}" "${_r[@]:1}" \
          "display=row ${_MR_ROWS_LOC[_i]} (${_MR_ROWS_ID[_i]}): the sandbox could not be built, so no probe ran"
        _fail=1 ;;
      mutation_required_sandbox_held)
        _mr_row_err mutation_required_sandbox_held "${_i}" "${_r[@]:1}" \
          "display=row ${_MR_ROWS_LOC[_i]} (${_MR_ROWS_ID[_i]}): a container of the sandbox's project was still running (or docker could not be asked); the sandbox is kept and the row fails"
        _fail=1 ;;
      *)
        _mr_row_err mutation_required_probe_refused "${_i}" rc=unknown \
          "display=row ${_MR_ROWS_LOC[_i]} (${_MR_ROWS_ID[_i]}): the worker wrote an unreadable result"
        _fail=1 ;;
    esac
  done
  (( _fail == 0 )) || return 1
  for (( _i = 0; _i < ${#_MR_ROWS_LOC[@]}; _i++ )); do
    mapfile -t _r < "${_MR_WORK}/row${_i}/res"
    # Progress, not a refusal, but on stderr with the rest of the run's
    # events: stdout stays empty for whoever reads the run's answer.
    _log_info "${_MR_SERVICE}" mutation_required_pinned "row=${_MR_ROWS_LOC[_i]}" \
      "id=${_MR_ROWS_ID[_i]}" "${_r[@]:1}" \
      "display=row ${_MR_ROWS_LOC[_i]} (${_MR_ROWS_ID[_i]}) PINNED by ${_MR_ROWS_SPEC[_i]}" >&2
  done
  return 0
}

_MR_INHERITED=''

main() {
  local _root='' _check=0 _jobs
  if [[ "${1:-}" == --apply ]]; then
    shift
    _mr_apply "$@"
    return
  fi
  if [[ "${1:-}" == --worker ]]; then
    _mr_worker "${2:?}"
    return
  fi
  trap '_mr_on_signal INT' INT
  trap '_mr_on_signal TERM' TERM
  trap _mr_cleanup EXIT
  while (( $# > 0 )); do
    case "${1}" in
      --root)
        if (( $# < 2 )); then
          _log_err "${_MR_SERVICE}" mutation_required_usage_invalid reason=root_missing \
            "display=--root needs a directory; usage: mutation_required.sh [--root <dir>] [--check]"
          return 2
        fi
        _root="${2}"; shift 2 ;;
      --check) _check=1; shift ;;
      *)
        _log_err "${_MR_SERVICE}" mutation_required_usage_invalid reason=unknown_argument "argument=${1}" \
          "display=unknown argument ${1}; usage: mutation_required.sh [--root <dir>] [--check]"
        return 2 ;;
    esac
  done
  # Every git variable that would point a git call at another repository
  # (GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE, ...) is dropped once, here, so
  # the enumeration, the sandbox build, the probe and its runner all see
  # the checkout they were given.
  local _v
  while IFS= read -r _v; do
    [[ -n "${_v}" ]] && unset -v "${_v}"
  done < <(git rev-parse --local-env-vars 2>/dev/null)
  _MR_INHERITED="${COMPOSE_PROJECT_NAME:-}"
  unset -v COMPOSE_PROJECT_NAME
  [[ -n "${_root}" ]] || _root="${_MR_DIR}/../../.."
  if ! _root="$(cd -- "${_root}" 2>/dev/null && pwd -P)"; then
    _log_err "${_MR_SERVICE}" mutation_required_usage_invalid reason=root_invalid \
      "display=--root is not a directory"
    return 2
  fi
  _jobs="${MUTATION_REQUIRED_JOBS:-4}"
  if [[ ! "${_jobs}" =~ ^[1-9][0-9]?$ ]]; then
    _log_err "${_MR_SERVICE}" mutation_required_jobs_invalid "jobs=${_jobs}" \
      "display=MUTATION_REQUIRED_JOBS is ${_jobs}; it is a row count from 1 to 99"
    return 2
  fi
  _mr_validate "${_root}" || return 1
  if [[ -n "${_MR_SIG}" ]]; then
    _mr_publish_interrupted
    return
  fi
  (( _check == 0 )) || return 0
  _mr_run "${_root}" "${_jobs}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
