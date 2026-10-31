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
# Every `<path>\t<sha256>` line of visible.sha256 and ignored.sha256 names
# a module file as 00-manifest hashed it; a file in <src> whose sha256 now
# differs (an edit after the baseline was written) is refused, and so is
# a file in <src> that neither list names (added after the baseline), and
# a listed file <src> no longer holds (deleted after the baseline).
# Before either, the manifest's first line must be S1d's header,
# `base=<sha> head=<sha> dirty=yes|no context=pr|main-push`; any other
# first line is refused as file=manifest reason=header. Every later line
# must be the none marker `none: no-go-change` or a change record
# `<status>\t<path>` (status A, D, M or T; two paths for a rename or copy,
# R<score> or C<score>); any other body line, a wrong path count or another
# status included, is refused as file=manifest reason=record.
#
# On refusal one line goes to stdout,
#   cg_event config_gen_manifest_stale file=<path> reason=<reason>
# which config_gen_gates.sh re-emits as that event, and the exit is 1.
#
# Exit: 0 admitted; 1 refused or a missing argument.
#
# Style: Google Shell Style Guide.

set -euo pipefail
export LC_ALL=C

readonly _CGA_MOD='dockerfile/config-gen/'
readonly _CGA_NONE='none: no-go-change'

# _cga_stale <file> <reason> -- refuse, rc 1.
_cga_stale() {
  printf 'cg_event config_gen_manifest_stale file=%s reason=%s\n' "${1}" "${2}"
  exit 1
}

# _cga_header <manifest> -- refuse a first line that is not S1d's header.
_cga_header() {
  local line='' sha='([0-9a-f]{40}|[0-9a-f]{64})'
  IFS= read -r line <"${1}" || true
  [[ "${line}" =~ ^base=${sha}\ head=${sha}\ dirty=(yes|no)\ context=(pr|main-push)$ ]] ||
    _cga_stale manifest header
}

# _cga_body <manifest> -- refuse a body line that is neither the none
# marker nor a change record: `<status>\t<path>` with status A, D, M or T,
# or for a rename or copy
# (R<score>, C<score>) `<status>\t<old>\t<new>`.
_cga_body() {
  local line t=$'\t'
  local one="^[ADMT]${t}[^${t}]+$"
  local two="^[RC][^${t}]*${t}[^${t}]+${t}[^${t}]+$"
  while IFS= read -r line; do
    [[ "${line}" == "${_CGA_NONE}" ]] && continue
    if [[ "${line}" == [RC]* ]]; then
      [[ "${line}" =~ ${two} ]] || _cga_stale manifest record
    else
      [[ "${line}" =~ ${one} ]] || _cga_stale manifest record
    fi
  done < <(tail -n +2 -- "${1}")
}

# _cga_check <src> <list> -- refuse the first listed file whose sha256 in
# <src> differs from the one recorded, or that <src> no longer holds.
_cga_check() {
  local src="${1}" list="${2}" path want got
  while IFS=$'\t' read -r path want; do
    [[ -e "${src}/${path#"${_CGA_MOD}"}" || -L "${src}/${path#"${_CGA_MOD}"}" ]] ||
      _cga_stale "${path}" missing
    got="$(sha256sum <"${src}/${path#"${_CGA_MOD}"}" 2>/dev/null)" || got=''
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
  _cga_header "${mutation}/manifest"
  _cga_body "${mutation}/manifest"
  _cga_check "${src}" "${mutation}/visible.sha256"
  _cga_check "${src}" "${mutation}/ignored.sha256"
  _cga_walk "${src}" "${mutation}/visible.sha256" "${mutation}/ignored.sha256"
}

main "$@"
