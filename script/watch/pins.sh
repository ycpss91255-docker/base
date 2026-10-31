#!/usr/bin/env bash
#
# pins.sh - read and rewrite the version pins this repo declares.
#
# The offline half of the upstream-release watch: no network, no upstream
# knowledge. It answers "what does this checkout pin, and where", and it
# performs the one edit a bump consists of. check.sh adds the upstream
# comparison; the pin-coverage lint adds the completeness guard. All three
# read watch/lib.sh, which is where the marker grammar and the derivation
# are documented.
#
# Usage:
#   ./script/watch/pins.sh --list             # TSV table of every marker
#   ./script/watch/pins.sh --value <name>     # one pin's current version
#   ./script/watch/pins.sh --set <name> <ver> # rewrite that pin in place
#   ./script/watch/pins.sh --files            # the scanned files
#   ./script/watch/pins.sh --uncovered        # declarations with no marker
#
# `--value` is the reason the workflow's `just` install and the test-tools
# image cannot disagree: CI reads the number out of the Dockerfile rather
# than repeating it.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_PINS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly _PINS_DIR
# shellcheck source=script/watch/lib.sh
source "${_PINS_DIR}/lib.sh"

# The repo root is this file's grandparent (script/watch/ -> repo root).
# Overridable so a spec can point the reader at a fixture tree.
PIN_REPO_ROOT="${PIN_REPO_ROOT:-$(cd -- "${_PINS_DIR}/../.." && pwd)}"

_pins_usage() {
  cat >&2 <<'EOF'
Usage: ./script/watch/pins.sh <mode>

  --list                 One TSV record per marker:
                         state name resolver coordinate pattern skip
                         current file line
  --value <name>         Print the current version of one pinned entry.
  --set <name> <version> Rewrite that pin's declaration line in place.
  --files                Print the scanned files, repo-root-relative.
  --uncovered            Print every version declaration that no marker
                         claims (what the pin-coverage lint fails on).

PIN_REPO_ROOT overrides the tree that is read.
EOF
  return 2
}

# _pins_record <name> -- the TSV record of one pin, or nothing.
_pins_record() {
  local _name="${1}"
  _pin_read "${PIN_REPO_ROOT}" | awk -F'\t' -v n="${_name}" '$2 == n'
}

# _pins_value <name>
_pins_value() {
  local _name="${1}" _record
  _record="$(_pins_record "${_name}")"
  if [[ -z "${_record}" ]]; then
    printf 'pins: no pin named %s\n' "${_name}" >&2
    return 1
  fi
  local _state _n _resolver _coord _pattern _skip _current _file _line
  IFS=$'\t' read -r _state _n _resolver _coord _pattern _skip _current \
    _file _line <<< "${_record}"
  if [[ "${_state}" != "${_PIN_STATE_PINNED}" ]]; then
    printf 'pins: %s is declared %s -- it names no version\n' \
      "${_name}" "${_state}" >&2
    return 1
  fi
  printf '%s\n' "${_current}"
}

# _pins_refuse <file> <reason> <text> -- the one refusal record of a bump
# that leaves <file> as it was.
_pins_refuse() {
  _log_err pin pin_set_refused "file=${1}" "reason=${2}" \
    "display=pin_set_refused: ${1}: ${3}; the file is left as it was"
}

# _pins_spliced_ok <file> <temp> <lineno> <new-line> <terminator>
#
# True when <temp> is <file> with line <lineno> replaced by <new-line> and
# <terminator>, and every other byte identical: the bytes before the line,
# the line itself, and everything after it, to the end of both files.
_pins_spliced_ok() {
  local _abs="${1}" _tmp="${2}" _n="${3}" _repl="${4}" _term="${5}"
  local LC_ALL=C _pre _old _new
  _pre="$(head -n "$(( _n - 1 ))" "${_abs}" | wc -c)" || return 1
  _old="$(head -n "${_n}" "${_abs}" | wc -c)" || return 1
  _old=$(( _old - _pre ))
  _new=$(( ${#_repl} + ${#_term} ))
  cmp -s -n "${_pre}" "${_abs}" "${_tmp}" || return 1
  cmp -s -n "${_new}" <(printf '%s%s' "${_repl}" "${_term}") "${_tmp}" 0 "${_pre}" || return 1
  cmp -s "${_abs}" "${_tmp}" "$(( _pre + _old ))" "$(( _pre + _new ))"
}

# _pins_commit <file> <lineno> <new-line>
#
# Replace line <lineno> of <file> with <new-line>, byte for byte, and
# change nothing else; on any failure the file keeps its bytes and its mode
# and no temp copy is left (base#1463).
#
# The new line is never handed to a tool that reads escapes: it went
# through `awk -v repl=...` once, which turned a preserved `// x \n y`
# comment into two lines (review round 3). It is spliced instead -- the
# lines before it by `head`, the line by `printf '%s'`, the lines after it
# by `tail` -- into a temp copy BESIDE the file, so the commit is one
# rename on one filesystem. The copy is checked byte for byte against the
# splice, given the file's mode (`mktemp` creates 0600, and a 0600
# Dockerfile is a "permission denied" on the next local `just test`), and
# only then moved over the file. A last line with no newline keeps having
# none.
#
# A rename replaces the name it lands on, so a symlink (the write belongs
# to whatever it points at) and a hard link (the other names would keep
# the old version) are refused by name rather than split.
_pins_commit() {
  local _abs="${1}" _n="${2}" _repl="${3}" _tmp _term=$'\n' _nl
  local LC_ALL=C
  if [[ -L "${_abs}" ]]; then
    _pins_refuse "${_abs}" symlink "a symlink; the bump rewrites only a file the tree holds itself"
    return 1
  fi
  if [[ "$(stat -c '%h' -- "${_abs}")" != 1 ]]; then
    _pins_refuse "${_abs}" hard_link "hard-linked; a rename would leave its other names on the old version"
    return 1
  fi
  _nl="$(wc -l < "${_abs}")"
  (( _n > _nl )) && _term=""
  if ! _tmp="$(mktemp "${_abs%/*}/.${_abs##*/}.pins.XXXXXX")"; then
    _pins_refuse "${_abs}" temp_create "no temp copy could be created beside it"
    return 1
  fi
  if ! { head -n "$(( _n - 1 ))" "${_abs}" > "${_tmp}" \
         && printf '%s%s' "${_repl}" "${_term}" >> "${_tmp}" \
         && tail -n "+$(( _n + 1 ))" "${_abs}" >> "${_tmp}"; }; then
    rm -f -- "${_tmp}"
    _pins_refuse "${_abs}" write_failed "its temp copy could not be written"
    return 1
  fi
  if ! _pins_spliced_ok "${_abs}" "${_tmp}" "${_n}" "${_repl}" "${_term}"; then
    rm -f -- "${_tmp}"
    _pins_refuse "${_abs}" check_failed "its temp copy is not the file with line ${_n} replaced"
    return 1
  fi
  if ! chmod "$(stat -c '%a' -- "${_abs}")" "${_tmp}"; then
    rm -f -- "${_tmp}"
    _pins_refuse "${_abs}" mode_failed "its mode could not be carried onto the temp copy"
    return 1
  fi
  if ! mv -f "${_tmp}" "${_abs}"; then
    rm -f -- "${_tmp}"
    _pins_refuse "${_abs}" commit_failed "the temp copy could not be renamed over it"
    return 1
  fi
}

# _pins_set <name> <version>
#
# Rewrite the pin's TARGET LINE, replacing the old version with the new one
# exactly once. The replacement is anchored the same way extraction is (the
# ARG's right-hand side, or the token after the coordinate), so a line that
# also contains the old string elsewhere cannot be corrupted -- and the
# result is verified by re-reading the pin, so a rewrite that did not take
# fails here rather than in a green PR that changed nothing.
_pins_set() {
  local _name="${1}" _new="${2}" _record
  _record="$(_pins_record "${_name}")"
  if [[ -z "${_record}" ]]; then
    printf 'pins: no pin named %s\n' "${_name}" >&2
    return 1
  fi
  local _state _n _resolver _coord _pattern _skip _current _file _line
  IFS=$'\t' read -r _state _n _resolver _coord _pattern _skip _current \
    _file _line <<< "${_record}"
  if [[ "${_state}" != "${_PIN_STATE_PINNED}" ]]; then
    printf 'pins: %s is declared %s -- there is no version to set\n' \
      "${_name}" "${_state}" >&2
    return 1
  fi
  if [[ "${_current}" == "${_new}" ]]; then
    printf 'pins: %s is already %s\n' "${_name}" "${_new}" >&2
    return 0
  fi

  local _abs="${PIN_REPO_ROOT}/${_file}"
  local _old_line _new_line
  _old_line="$(awk -v n="${_line}" 'NR == n' "${_abs}")"
  if [[ "${_file##*/}" == go.mod ]]; then
    # A go.mod pin is a require entry the scanner read, so the scanner
    # rewrites it: the version token alone, located by the lexer
    # (base#1463). Neither rewrite below matches `require <path> <ver>`.
    _new_line="$(_pin_go_mod_set_line "${_abs}" "${_line}" "${_new}")" || return 1
  elif [[ "${_old_line}" =~ ${_PIN_ASSIGN_RE} ]]; then
    local _head="${BASH_REMATCH[1]}" _rhs="${BASH_REMATCH[3]}"
    local _quote="" _value _tail
    _value="$(_pin_rhs_value "${_rhs}")"
    # Everything after the version -- the spacing and any trailing comment
    # -- is carried across verbatim. Rebuilding the line from the `NAME=`
    # prefix alone deletes it, and on a pin line that comment is normally
    # the reason the version is what it is ("held: 2.13 rejects our DL3059
    # usage"): exactly the sentence a reviewer of a bump proposal needs to
    # read, deleted by the bump itself.
    _tail="$(_pin_rhs_tail "${_rhs}")"
    [[ "${_value}" == \"*\" ]] && _quote='"'
    [[ "${_value}" == \'*\' ]] && _quote="'"
    _new_line="${_head}${_quote}${_new}${_quote}${_tail}"
  else
    _new_line="${_old_line/${_coord}:${_current}/${_coord}:${_new}}"
    if [[ "${_new_line}" == "${_old_line}" ]]; then
      _new_line="${_old_line/${_coord}@${_current}/${_coord}@${_new}}"
    fi
  fi
  if [[ "${_new_line}" == "${_old_line}" ]]; then
    printf 'pins: %s: nothing on %s:%s changed -- the rewrite did not match\n' \
      "${_name}" "${_file}" "${_line}" >&2
    return 1
  fi

  _pins_commit "${_abs}" "${_line}" "${_new_line}" || return 1

  local _check
  _check="$(_pins_value "${_name}")"
  if [[ "${_check}" != "${_new}" ]]; then
    printf 'pins: %s reads back as %s after the rewrite, not %s\n' \
      "${_name}" "${_check}" "${_new}" >&2
    return 1
  fi
  printf 'pins: %s %s -> %s (%s:%s)\n' \
    "${_name}" "${_current}" "${_new}" "${_file}" "${_line}"
}

main() {
  case "${1:-}" in
    --list)  _pin_read "${PIN_REPO_ROOT}" ;;
    --files) _pin_files "${PIN_REPO_ROOT}" ;;
    --uncovered) _pin_uncovered "${PIN_REPO_ROOT}" ;;
    --value) _pins_value "${2:?--value expects <name>}" ;;
    --set)   _pins_set "${2:?--set expects <name> <version>}" \
               "${3:?--set expects <name> <version>}" ;;
    -h|--help) _pins_usage ;;
    *) _pins_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
