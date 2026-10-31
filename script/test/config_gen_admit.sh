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
# installs this script into the mutation context, and the Dockerfile's
# admit stage runs it before any Go: it is bash and coreutils only, so
# nothing from the snapshot is compiled or executed to judge the snapshot.
#
# The checks run in this order, and the first refusal ends the run:
#
#   presence         manifest, visible.sha256 and ignored.sha256 must each be
#                    a regular file (00-manifest writes all three);
#                    otherwise file=<it> reason=absent.
#   manifest bytes   TAB, LF and 0x20-0x7e only, as S1d writes it; any
#                    other byte (a CR from a CRLF rewrite included) is
#                    file=manifest reason=bytes. Then the framing: every
#                    line ends in LF, the last one included, and none is
#                    empty; otherwise reason=malformed.
#   manifest header  the first line must be S1d's header,
#                    `base=<sha> head=<sha> dirty=yes|no context=pr|main-push`;
#                    any other is file=manifest reason=header.
#   manifest body    every later line is the none marker `none: no-go-change`
#                    or a change record `<status>\t<path>` (status A, D, M or
#                    T; two paths for a rename or copy, R or C and git's
#                    three-digit score, R088); any other line, a wrong path count or
#                    another status included, is reason=record. S1d writes
#                    the marker only when no record exists, so the marker
#                    beside a record, or a second marker, is
#                    reason=none_marker; it always writes one of them, so a
#                    header alone is reason=body_empty. A record path is
#                    printed as git prints it, under `dockerfile/config-gen/`,
#                    so a path holding a `..`, `.` or empty segment, outside
#                    that prefix, or holding a `"` (the quote of a name git
#                    C-quotes) is reason=path. All with file=manifest.
#   each list        visible.sha256, then ignored.sha256. The same bytes
#                    only (a NUL, which a text read would drop, is
#                    reason=bytes) and the same framing (reason=malformed;
#                    an empty list, zero bytes, is S1d's no file); every line `<path>\t<64 hex digits>`
#                    (reason=record); a path listed twice in one list is
#                    reason=duplicate (00-manifest hashes each file once); a
#                    path the earlier list already names is reason=dual
#                    (00-manifest puts each file in exactly one list). All with file=<list>, the list read
#                    when the rule fired. Once a list's lines pass, a file
#                    it names whose sha256 in <src> differs (edited after
#                    the baseline) is reason=sha_mismatch, and one <src> no
#                    longer holds (deleted after it) is reason=missing, both
#                    with file=<path>.
#   disk walk        in byte order, an entry under <src> that is not a
#                    directory or a regular file is reason=not_regular; one
#                    neither list names (added after the baseline) is
#                    reason=unlisted. Both with file=<path>.
#
# On refusal one line goes to stdout,
#   cg_event config_gen_manifest_stale file=<path> reason=<reason>
# which config_gen_gates.sh re-emits as that event, and the exit is 1.
# <path> is written with each byte outside 0x21-0x7e, and the % itself, as
# %XX, so a name holding a space or a LF stays one word of one line.
#
# Exit: 0 admitted; 1 refused or a missing argument.
#
# Style: Google Shell Style Guide.

set -euo pipefail
export LC_ALL=C

readonly _CGA_MOD='dockerfile/config-gen/'
readonly _CGA_NONE='none: no-go-change'

# Paths every list read so far names, for the one-list rule.
declare -A _cga_listed=()

# _cga_enc <value> -- <value> as one word: each byte outside 0x21-0x7e,
# and the % itself, written as %XX (uppercase hex), so the value holds no
# space or LF and no two values share a spelling.
_cga_enc() {
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

# _cga_stale <file> <reason> -- refuse, rc 1.
_cga_stale() {
  printf 'cg_event config_gen_manifest_stale file=%s reason=%s\n' "$(_cga_enc "${1}")" "${2}"
  exit 1
}

# _cga_bytes <file> <name> -- refuse a byte other than TAB, LF or
# 0x20-0x7e in <file> (bytes); then a non-empty <file> whose last byte is
# not LF, or that holds an empty line (malformed). Every later read is a
# line-at-a-time `read`, which never returns an unterminated last line to
# the loop that judges it, so the framing is settled here, on the file,
# before any line is judged.
_cga_bytes() {
  ! grep -aq $'[^\t[:print:]]' -- "${1}" || _cga_stale "${2}" bytes
  if [[ -s "${1}" ]]; then
    [[ "$(tail -c 1 -- "${1}" | od -An -tx1)" == ' 0a' ]] || _cga_stale "${2}" malformed
  fi
  ! grep -aqx '' -- "${1}" || _cga_stale "${2}" malformed
}

# _cga_header <manifest> -- refuse a first line that is not S1d's header.
_cga_header() {
  local line='' sha='([0-9a-f]{40}|[0-9a-f]{64})'
  IFS= read -r line <"${1}" || true
  [[ "${line}" =~ ^base=${sha}\ head=${sha}\ dirty=(yes|no)\ context=(pr|main-push)$ ]] ||
    _cga_stale manifest header
}

# _cga_path <path>... -- refuse a record path holding a `..`, `.` or
# empty segment, not under the module prefix, or holding a `"`.
_cga_path() {
  local p
  for p in "$@"; do
    [[ "/${p}/" != */../* && "/${p}/" != */./* && "/${p}/" != *//* ]] ||
      _cga_stale manifest path
    [[ "${p}" == "${_CGA_MOD}"* ]] || _cga_stale manifest path
    [[ "${p}" != *'"'* ]] || _cga_stale manifest path
  done
}

# _cga_body <manifest> -- refuse a body line that is neither the none
# marker nor a change record: `<status>\t<path>` with status A, D, M or T,
# or `<status>\t<old>\t<new>` for a rename or copy (R or C and git's
# three-digit similarity score, R088, R100);
# and the marker beside a record, in either order, or a second marker; and
# a body with no line.
_cga_body() {
  local line t=$'\t' marker=0 record=0
  local one="^[ADMT]${t}[^${t}]+$"
  local two="^[RC][0-9]{3}${t}[^${t}]+${t}[^${t}]+$"
  while IFS= read -r line; do
    if [[ "${line}" == "${_CGA_NONE}" ]]; then
      ((record == 0 && marker == 0)) || _cga_stale manifest none_marker
      marker=1
      continue
    fi
    record=1
    ((marker == 0)) || _cga_stale manifest none_marker
    if [[ "${line}" == [RC]* ]]; then
      [[ "${line}" =~ ${two} ]] || _cga_stale manifest record
    else
      [[ "${line}" =~ ${one} ]] || _cga_stale manifest record
    fi
    local -a field
    IFS="${t}" read -r -a field <<<"${line}"
    _cga_path "${field[@]:1}"
  done < <(tail -n +2 -- "${1}")
  ((record == 1 || marker == 1)) || _cga_stale manifest body_empty
}

# _cga_check <src> <list> -- refuse a <list> line that is not
# `<path>\t<64 hex>` or whose path an earlier line names (duplicate) or an
# earlier list names (dual); then the first listed file whose sha256 in
# <src> differs from the one recorded, or that <src> no longer holds.
_cga_check() {
  local src="${1}" list="${2}" name="${2##*/}" path want got line file
  local rec=$'^[^\t]+\t[0-9a-f]{64}$'
  local -A seen=()
  _cga_bytes "${list}" "${name}"
  while IFS= read -r line; do
    [[ "${line}" =~ ${rec} ]] || _cga_stale "${name}" record
    path="${line%%$'\t'*}"
    [[ -z "${seen["${path}"]+x}" ]] || _cga_stale "${name}" duplicate
    [[ -z "${_cga_listed["${path}"]+x}" ]] || _cga_stale "${name}" dual
    seen["${path}"]=1
  done <"${list}"
  for path in "${!seen[@]}"; do
    _cga_listed["${path}"]=1
  done
  while IFS=$'\t' read -r path want; do
    file="${src}/${path#"${_CGA_MOD}"}"
    [[ -e "${file}" || -L "${file}" ]] || _cga_stale "${path}" missing
    got="$(sha256sum <"${file}" 2>/dev/null)" || got=''
    [[ "${got%% *}" == "${want}" ]] || _cga_stale "${path}" sha_mismatch
  done <"${list}"
}

# _cga_walk <src> <list>... -- refuse the first entry on disk under <src>,
# in byte order, that is not a directory or a regular file (a symlink the
# build would follow, which no sha256 binds), or that no <list> names.
_cga_walk() {
  local src="${1}" path rel
  shift
  local -A listed=()
  while IFS=$'\t' read -r path _; do
    listed["${path}"]=1
  done < <(cat -- "$@")
  while IFS= read -r -d '' rel; do
    path="${_CGA_MOD}${rel#./}"
    [[ -f "${src}/${rel}" && ! -L "${src}/${rel}" ]] ||
      _cga_stale "${path}" not_regular
    [[ -n "${listed["${path}"]+x}" ]] || _cga_stale "${path}" unlisted
  done < <(cd -- "${src}" && find . ! -type d -print0 | sort -z)
}

main() {
  local mutation="${1:?usage: config_gen_admit.sh <mutation> <src>}"
  local src="${2:?usage: config_gen_admit.sh <mutation> <src>}"
  local f
  for f in manifest visible.sha256 ignored.sha256; do
    [[ -f "${mutation}/${f}" && ! -L "${mutation}/${f}" ]] || _cga_stale "${f}" absent
  done
  _cga_bytes "${mutation}/manifest" manifest
  _cga_header "${mutation}/manifest"
  _cga_body "${mutation}/manifest"
  _cga_check "${src}" "${mutation}/visible.sha256"
  _cga_check "${src}" "${mutation}/ignored.sha256"
  _cga_walk "${src}" "${mutation}/visible.sha256" "${mutation}/ignored.sha256"
}

main "$@"
