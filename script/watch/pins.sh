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
  if [[ "${_old_line}" =~ ${_PIN_ASSIGN_RE} ]]; then
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

  # Write THROUGH the target rather than replacing it. `mktemp` creates
  # 0600 and `mv` carries that mode onto the file it lands on, so a
  # rewrite would leave the Dockerfile unreadable to the lint container's
  # user -- invisible in the bump job (a fresh checkout, and git records
  # 100644) and a "permission denied" on the next `just test` for anyone
  # who runs `just watch bump` on their own machine.
  local _tmp
  _tmp="$(mktemp)"
  awk -v n="${_line}" -v repl="${_new_line}" \
    'NR == n { print repl; next } { print }' "${_abs}" > "${_tmp}"
  cat -- "${_tmp}" > "${_abs}"
  rm -f -- "${_tmp}"

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
