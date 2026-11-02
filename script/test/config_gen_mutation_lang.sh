#!/usr/bin/env bash
#
# config_gen_mutation_lang.sh -- the language of the config generator's
# host mutation baseline: one constructor per line kind (base#1464,
# base#1465).
#
# Sourced, never run. config_gen_mutation_targets.sh (the producer, S1d)
# writes every header, change record and sha256 line through these
# functions, and config_gen_admit.sh (admission, S1e) reads each line back
# through the same ones, so the two can never disagree on a spelling, a
# status, a score, an arity or a header value.
#
#   _cgm_header <base> <head> <dirty> <ctx>
#       prints `base=<base> head=<head> dirty=<dirty> context=<ctx>`.
#       base and head: both 40 or both 64 lowercase hex digits; dirty: yes
#       or no; ctx: pr or main-push. Otherwise file=manifest reason=header.
#   _cgm_record <status> <path> [<path>]
#       prints `<status>\t<spelling>[\t<spelling>]`. status A, D, M, T or U
#       with one path, or R and a three-digit score 000..100 with two; C
#       (git diff -M never writes it) and any other status, or another
#       path count, is file=manifest reason=record. Each path must start
#       with dockerfile/config-gen/ and be canonical (no empty, `.` or `..`
#       segment, no trailing /); otherwise file=manifest reason=path.
#   _cgm_quote <path>
#       prints the path's one spelling, no newline: as is, unless it holds
#       a control byte, a double quote or a backslash; then C-quoted as git
#       quotes with core.quotePath=false (\a \b \t \n \v \f \r \" \\,
#       other control bytes as \ooo).
#   _cgm_unquote <spelling>
#       sets _cgm_raw to the path the spelling reads back to; rc 1 when it
#       does not read back. It accepts more than _cgm_quote writes; a caller
#       that must hold a spelling to the producer's re-renders it.
#   _cgm_hash_line <path> <file>
#       prints `<spelling of path>\t<sha256 of file>`; rc 1 when <file> is
#       not something `[[ -f ]]` accepts (a dangling symlink, a fifo, a
#       directory), rc 2 when it cannot be read.
#
# A refusal is the event config_gen_manifest_stale with file= and reason=,
# then rc 1: logged with _log_err when the caller sourced the logger (the
# producer), else one stderr line `cg_event config_gen_manifest_stale
# file=<f> reason=<r>` (admission, inside the build, where no logger
# exists; config_gen_gates.sh re-emits it). <f> is written with each byte
# outside 0x21-0x7e, and the % itself, as %XX, so it stays one word.
#
# Style: Google Shell Style Guide.

_CGM_LANG_PREFIX='dockerfile/config-gen/'
# What _cgm_unquote sets, so no call needs a subshell (one would drop a
# trailing LF).
_cgm_raw=''

# _cgm_enc <value> -- <value> as one word: each byte outside 0x21-0x7e, and
# the % itself, written as %XX (uppercase hex).
_cgm_enc() {
  local out='' h
  # od, not printf "'c": bash's printf reads a byte past 0x7f as a signed
  # char on some builds (the test-tools image printed %DFC3 for 0xc3).
  for h in $(printf '%s' "${1}" | od -An -v -tx1); do
    case "${h}" in
      25) out+='%25' ;;
      2[1-9a-f] | [3-6][0-9a-f] | 7[0-9a-e]) out+="$(printf '%b' "\\x${h}")" ;;
      *) out+="%${h^^}" ;;
    esac
  done
  printf '%s' "${out}"
}

# _cgm_stale <file> <reason> -- emit the refusal; always rc 1.
_cgm_stale() {
  local f
  f="$(_cgm_enc "${1}")"
  if declare -F _log_err >/dev/null; then
    _log_err config-gen config_gen_manifest_stale "file=${f}" "reason=${2}" \
      "display=config-gen mutation baseline line refused: file=${f} reason=${2}"
  else
    printf 'cg_event config_gen_manifest_stale file=%s reason=%s\n' "${f}" "${2}" >&2
  fi
  return 1
}

# _cgm_header <base> <head> <dirty> <ctx> -- the header line, or refuse.
_cgm_header() {
  local LC_ALL=C sha='^([0-9a-f]{40}|[0-9a-f]{64})$'
  if (( $# != 4 )) || [[ ! "${1}" =~ ${sha} ]] || [[ ! "${2}" =~ ${sha} ]] \
      || (( ${#1} != ${#2} )); then
    _cgm_stale manifest header
    return 1
  fi
  case "${3}" in yes | no) ;; *) _cgm_stale manifest header; return 1 ;; esac
  case "${4}" in pr | main-push) ;; *) _cgm_stale manifest header; return 1 ;; esac
  printf 'base=%s head=%s dirty=%s context=%s\n' "${1}" "${2}" "${3}" "${4}"
}

# _cgm_path_ok <path> -- true when <path> is under the module prefix and
# canonical.
_cgm_path_ok() {
  local p="${1}"
  [[ "${p}" == "${_CGM_LANG_PREFIX}"?* ]] || return 1
  [[ "/${p}/" != *//* && "/${p}/" != */./* && "/${p}/" != */../* ]]
}

# _cgm_record <status> <path> [<path>] -- the change record line, or
# refuse.
_cgm_record() {
  local LC_ALL=C st="${1:-}" p
  case "${st}" in
    A | D | M | T | U)
      (( $# == 2 )) || { _cgm_stale manifest record; return 1; }
      ;;
    R[0-9][0-9][0-9])
      if (( $# != 3 || 10#${st:1} > 100 )); then
        _cgm_stale manifest record
        return 1
      fi
      ;;
    *)
      _cgm_stale manifest record
      return 1
      ;;
  esac
  for p in "${@:2}"; do
    _cgm_path_ok "${p}" || { _cgm_stale manifest path; return 1; }
  done
  printf '%s' "${st}"
  for p in "${@:2}"; do
    printf '\t%s' "$(_cgm_quote "${p}")"
  done
  printf '\n'
}

# _cgm_quote <path> -- print <path> in the one spelling every output file
# uses (see the header); no trailing newline.
_cgm_quote() {
  local p="${1}" LC_ALL=C q='' c i
  case "${p}" in
    *[[:cntrl:]\"\\]*) ;;
    *)
      printf '%s' "${p}"
      return 0
      ;;
  esac
  for (( i = 0; i < ${#p}; i++ )); do
    c="${p:i:1}"
    case "${c}" in
      $'\a') q+='\a' ;;
      $'\b') q+='\b' ;;
      $'\t') q+='\t' ;;
      $'\n') q+='\n' ;;
      $'\v') q+='\v' ;;
      $'\f') q+='\f' ;;
      $'\r') q+='\r' ;;
      '"') q+='\"' ;;
      \\) q+="\\\\" ;;
      [[:cntrl:]]) q+="$(printf '\\%03o' "'${c}")" ;;
      *) q+="${c}" ;;
    esac
  done
  printf '"%s"' "${q}"
}

# _cgm_unquote <spelling> -- set _cgm_raw to the path <spelling> reads back
# to; rc 1 when it does not read back.
_cgm_unquote() {
  local LC_ALL=C s="${1}" raw='' c o i
  if [[ "${s}" != '"'* ]]; then
    _cgm_raw="${s}"
    return 0
  fi
  (( ${#s} >= 2 )) && [[ "${s}" == *'"' ]] || return 1
  s="${s:1:${#s}-2}"
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "${c}" != \\ ]]; then
      raw+="${c}"
      continue
    fi
    i=$(( i + 1 ))
    c="${s:i:1}"
    case "${c}" in
      a) raw+=$'\a' ;;
      b) raw+=$'\b' ;;
      t) raw+=$'\t' ;;
      n) raw+=$'\n' ;;
      v) raw+=$'\v' ;;
      f) raw+=$'\f' ;;
      r) raw+=$'\r' ;;
      '"' | \\) raw+="${c}" ;;
      [0-3])
        o="${s:i:3}"
        [[ "${o}" =~ ^[0-3][0-7][0-7]$ && "${o}" != 000 ]] || return 1
        # printf -v, not $(...): a command substitution drops a trailing
        # LF, which \012 would be.
        printf -v c '%b' "\\${o}"
        raw+="${c}"
        i=$(( i + 2 ))
        ;;
      *) return 1 ;;
    esac
  done
  _cgm_raw="${raw}"
}

# _cgm_hash_line <path> <file> -- `<spelling of path>\t<sha256 of file>`;
# rc 1 when <file> is not a regular file (after symlinks), rc 2 when it
# cannot be read.
_cgm_hash_line() {
  local sum
  [[ -f "${2}" ]] || return 1
  sum="$(sha256sum <"${2}")" || return 2
  printf '%s\t%s\n' "$(_cgm_quote "${1}")" "${sum%% *}"
}
