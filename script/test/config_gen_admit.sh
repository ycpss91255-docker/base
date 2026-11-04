#!/usr/bin/env bash
#
# config_gen_admit.sh -- admit the config generator's build context against
# the host mutation baseline (base#1465).
#
# Usage:
#   config_gen_admit.sh <mutation> <src>
#
# <mutation> is the directory 00-manifest wrote (base#1464); <src> is the
# module as the build sees it (dockerfile/config-gen). The 01-admit step
# installs this script, and the constructor library beside it
# (config_gen_mutation_lang.sh), into the mutation context, and the
# Dockerfile's admit stage runs it before any Go: it is bash and coreutils
# only, so nothing from the snapshot is compiled or executed to judge the
# snapshot.
#
# Admission has no grammar of its own. Every line it accepts is one the
# producer (config_gen_mutation_targets.sh) writes through the same
# constructors for the module on disk. The checks run in this order, and
# the first refusal ends the run:
#
#   1. presence   the library, manifest, visible.sha256 and ignored.sha256
#                 are each a regular file; otherwise file=<it> reason=absent.
#   2. lists      each list is empty or ends in LF (reason=malformed); no
#                 name is listed twice in one list (reason=duplicate) or in
#                 both (file=ignored.sha256 reason=dual). Then E, the
#                 producer's sha256 line (_cgm_hash_line) for every entry
#                 under <src> that is not a directory -- an entry [[ -f ]]
#                 refuses (a dangling symlink, a fifo) is file=<it>
#                 reason=not_regular -- must equal, sorted, visible.sha256
#                 together with the ignored.sha256 entries <src> holds (an
#                 ignored entry the build's dockerignore dropped is not
#                 compared, base#1467). The first line that differs names the file: in
#                 both with another sha256, reason=sha_mismatch; only in a
#                 list, reason=missing; only on disk, reason=unlisted.
#   3. manifest   it ends in LF (reason=malformed). Line 1 is four words
#                 base= head= dirty= context= that _cgm_header re-renders
#                 to the same bytes (reason=header). The body is the none
#                 marker alone, or one or more records that _cgm_unquote and
#                 _cgm_record re-render to the same bytes (a constructor
#                 refusal is its own reason=record|path; any other
#                 difference is reason=record). A header alone is
#                 reason=body_empty; the marker beside a record, or twice,
#                 is reason=none_marker. All with file=manifest.
#   4. paths      over the whole record set, with Src the D paths and the
#                 R old paths, and Tgt the A, M, T, U paths and the R new
#                 paths (file=manifest): a record twice is
#                 reason=duplicate; a path twice in Src or twice in Tgt, a
#                 path in both whose Tgt record is not A (only an
#                 untracked file recreating a removed path is both), a Tgt
#                 path visible.sha256 does not list, or a Src path not
#                 recreated that it does list is reason=presence.
#
# A refusal is one stderr line,
#   cg_event config_gen_manifest_stale file=<f> reason=<reason>
# which config_gen_gates.sh re-emits as that event, and exit 1. <f> is the
# name (not its spelling) with each byte outside 0x21-0x7e, and the %
# itself, as %XX.
#
# Exit: 0 admitted; 1 refused or a missing argument.
#
# Style: Google Shell Style Guide.

set -euo pipefail
export LC_ALL=C

_CGA_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _CGA_DIR
readonly _CGA_LIB="${_CGA_DIR}/config_gen_mutation_lang.sh"
readonly _CGA_MOD='dockerfile/config-gen/'
readonly _CGA_NONE='none: no-go-change'

# The scratch directory main makes; removed on exit.
_CGA_TMP=''

# _cga_stale <file> <reason> -- refuse, exit 1.
_cga_stale() {
  _cgm_stale "${1}" "${2}" || true
  exit 1
}

# _cga_name <spelling> -- print the name <spelling> reads back to, or the
# spelling itself when it does not read back.
_cga_name() {
  if _cgm_unquote "${1}"; then
    printf '%s' "${_cgm_raw}"
  else
    printf '%s' "${1}"
  fi
}

# _cga_framed <file> <name> -- refuse a non-empty <file> whose last byte
# is not LF: a line-at-a-time read never returns an unterminated last line.
_cga_framed() {
  [[ -s "${1}" ]] || return 0
  [[ "$(tail -c 1 -- "${1}" | od -An -tx1)" == ' 0a' ]] || _cga_stale "${2}" malformed
}

# _cga_listed <sorted> <spelling> -- true when <sorted> lists <spelling>.
_cga_listed() {
  # grep -c reads its whole input, so cut never meets a closed pipe.
  [[ "$(cut -f1 -- "${1}" | grep -cxF -- "${2}")" != 0 ]]
}

# _cga_lists <mutation> <src> -- step 2 of the header.
_cga_lists() {
  local v="${1}/visible.sha256" i="${1}/ignored.sha256" src="${2}" rel line s
  _cga_framed "${v}" visible.sha256
  _cga_framed "${i}" ignored.sha256
  [[ -z "$(cut -f1 -- "${v}" | sort | uniq -d)" ]] || _cga_stale visible.sha256 duplicate
  [[ -z "$(cut -f1 -- "${i}" | sort | uniq -d)" ]] || _cga_stale ignored.sha256 duplicate
  [[ -z "$(comm -12 <(cut -f1 -- "${v}" | sort -u) <(cut -f1 -- "${i}" | sort -u))" ]] \
    || _cga_stale ignored.sha256 dual
  : >"${_CGA_TMP}/e"
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    _cgm_hash_line "${_CGA_MOD}${rel}" "${src}/${rel}" >>"${_CGA_TMP}/e" \
      || _cga_stale "${_CGA_MOD}${rel}" not_regular
  done < <(cd -- "${src}" && find -P . ! -type d -print0 | sort -z)
  sort -- "${_CGA_TMP}/e" >"${_CGA_TMP}/e.sorted"
  # An ignored entry the context does not hold is one the build's
  # dockerignore dropped (base#1467): only the ones on disk are compared.
  : >"${_CGA_TMP}/i.held"
  while IFS= read -r line; do
    ! _cga_listed "${_CGA_TMP}/e.sorted" "${line%%$'\t'*}" || printf '%s\n' "${line}" >>"${_CGA_TMP}/i.held"
  done <"${i}"
  cat -- "${v}" "${_CGA_TMP}/i.held" | sort >"${_CGA_TMP}/r.sorted"
  cmp -s -- "${_CGA_TMP}/r.sorted" "${_CGA_TMP}/e.sorted" && return 0
  # The first line only one side holds names the file.
  IFS= read -r line < <(comm -3 -- "${_CGA_TMP}/r.sorted" "${_CGA_TMP}/e.sorted") || true
  if [[ "${line}" == $'\t'* ]]; then
    s="${line#$'\t'}"
    s="${s%%$'\t'*}"
    ! _cga_listed "${_CGA_TMP}/r.sorted" "${s}" || _cga_stale "$(_cga_name "${s}")" sha_mismatch
    _cga_stale "$(_cga_name "${s}")" unlisted
  fi
  s="${line%%$'\t'*}"
  ! _cga_listed "${_CGA_TMP}/e.sorted" "${s}" || _cga_stale "$(_cga_name "${s}")" sha_mismatch
  _cga_stale "$(_cga_name "${s}")" missing
}

# _cga_header <line> -- re-render line 1 through _cgm_header, or refuse.
_cga_header() {
  local -a w=()
  IFS=' ' read -r -a w <<<"${1}"
  if (( ${#w[@]} != 4 )) || [[ "${w[0]}" != base=* || "${w[1]}" != head=* \
      || "${w[2]}" != dirty=* || "${w[3]}" != context=* ]]; then
    _cga_stale manifest header
  fi
  _cgm_header "${w[0]#base=}" "${w[1]#head=}" "${w[2]#dirty=}" "${w[3]#context=}" || exit 1
}

# _cga_record <line> -- re-render a body line through _cgm_unquote and
# _cgm_record, or refuse.
_cga_record() {
  local s
  local -a f=() raw=()
  IFS=$'\t' read -r -a f <<<"${1}"
  for s in "${f[@]:1}"; do
    _cgm_unquote "${s}" || _cga_stale manifest record
    raw+=("${_cgm_raw}")
  done
  _cgm_record "${f[0]:-}" "${raw[@]}" || exit 1
}

# _cga_manifest <mutation> -- step 3 of the header; writes the records it
# admitted, one per line, to ${_CGA_TMP}/records.
_cga_manifest() {
  local m="${1}/manifest" line n=0 marker=0 records=0
  _cga_framed "${m}" manifest
  [[ -s "${m}" ]] || _cga_stale manifest malformed
  : >"${_CGA_TMP}/render"
  : >"${_CGA_TMP}/records"
  while IFS= read -r line; do
    n=$(( n + 1 ))
    if (( n == 1 )); then
      _cga_header "${line}" >>"${_CGA_TMP}/render"
    elif [[ "${line}" == "${_CGA_NONE}" ]]; then
      (( marker == 0 && records == 0 )) || _cga_stale manifest none_marker
      marker=1
      printf '%s\n' "${line}" >>"${_CGA_TMP}/render"
    else
      (( marker == 0 )) || _cga_stale manifest none_marker
      records=$(( records + 1 ))
      _cga_record "${line}" >>"${_CGA_TMP}/records"
      tail -n 1 -- "${_CGA_TMP}/records" >>"${_CGA_TMP}/render"
    fi
  done <"${m}"
  (( marker == 1 || records > 0 )) || _cga_stale manifest body_empty
  # The rendering must be the file, byte for byte: a spelling, a field
  # split or a line ending the constructors do not write, and a byte a
  # line-at-a-time read drops (a NUL), all differ here.
  if ! cmp -s -- "${_CGA_TMP}/render" "${m}"; then
    head -n 1 -- "${_CGA_TMP}/render" | cmp -s - <(head -n 1 -- "${m}") \
      || _cga_stale manifest header
    _cga_stale manifest record
  fi
}

# _cga_paths <mutation> -- step 4 of the header, over the records
# _cga_manifest admitted.
_cga_paths() {
  local line p
  local -a f=()
  local -A seen=() src=() tgt=() listed=()
  while IFS=$'\t' read -r p _; do
    listed["${p}"]=1
  done <"${1}/visible.sha256"
  while IFS= read -r line; do
    [[ -z "${seen["${line}"]+x}" ]] || _cga_stale manifest duplicate
    seen["${line}"]=1
    IFS=$'\t' read -r -a f <<<"${line}"
    case "${f[0]}" in
      D)
        [[ -z "${src["${f[1]}"]+x}" ]] || _cga_stale manifest presence
        src["${f[1]}"]=D
        ;;
      R*)
        [[ -z "${src["${f[1]}"]+x}" ]] || _cga_stale manifest presence
        [[ -z "${tgt["${f[2]}"]+x}" ]] || _cga_stale manifest presence
        src["${f[1]}"]=R
        tgt["${f[2]}"]=R
        ;;
      *)
        [[ -z "${tgt["${f[1]}"]+x}" ]] || _cga_stale manifest presence
        tgt["${f[1]}"]="${f[0]}"
        ;;
    esac
  done <"${_CGA_TMP}/records"
  for p in "${!tgt[@]}"; do
    [[ -n "${listed["${p}"]+x}" ]] || _cga_stale manifest presence
    [[ -z "${src["${p}"]+x}" || "${tgt["${p}"]}" == A ]] || _cga_stale manifest presence
  done
  for p in "${!src[@]}"; do
    [[ -z "${tgt["${p}"]+x}" ]] || continue
    [[ -z "${listed["${p}"]+x}" ]] || _cga_stale manifest presence
  done
}

main() {
  local mutation="${1:?usage: config_gen_admit.sh <mutation> <src>}"
  local src="${2:?usage: config_gen_admit.sh <mutation> <src>}"
  local f
  if [[ ! -f "${_CGA_LIB}" || -L "${_CGA_LIB}" ]]; then
    printf 'cg_event config_gen_manifest_stale file=%s reason=absent\n' \
      config_gen_mutation_lang.sh >&2
    exit 1
  fi
  # shellcheck source=script/test/config_gen_mutation_lang.sh
  source "${_CGA_LIB}"
  for f in manifest visible.sha256 ignored.sha256; do
    [[ -f "${mutation}/${f}" && ! -L "${mutation}/${f}" ]] || _cga_stale "${f}" absent
  done
  _CGA_TMP="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now; the path never changes
  trap "rm -rf '${_CGA_TMP}'" EXIT
  _cga_lists "${mutation}" "${src}"
  _cga_manifest "${mutation}"
  _cga_paths "${mutation}"
}

main "$@"
