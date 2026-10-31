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

# _pins_writable <file>
#
# Refuse a <file> a rename cannot replace on its own: a symlink (the write
# belongs to whatever it points at) and a hard link (the other names would
# keep the old version) (base#1463). A caller that does work before its
# commit asks this first, so the refusal costs nothing (base#1440).
_pins_writable() {
  local _abs="${1}"
  if [[ -L "${_abs}" ]]; then
    _pins_refuse "${_abs}" symlink "a symlink; the bump rewrites only a file the tree holds itself"
    return 1
  fi
  if [[ "$(stat -c '%h' -- "${_abs}")" != 1 ]]; then
    _pins_refuse "${_abs}" hard_link "hard-linked; a rename would leave its other names on the old version"
    return 1
  fi
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
  _pins_writable "${_abs}" || return 1
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

# The pin that names the Go image a go.mod bump regenerates go.sum in.
readonly _PINS_GOLANG_PIN=golang

# Regenerate go.sum in the pinned golang image. The module arrives as a tar
# on stdin, its paths relative to the module directory; stdout is moved to
# fd 3 and the shell's own stdout to stderr, so `go` chatter (`all modules
# verified`) never reaches the go.sum the caller captures. The tidy runs
# on the module copy in /tmp/w; when it would also change go.mod (compared
# by `go mod edit -json`, so spacing and comments do not count) the script
# exits 3 and no go.sum is taken. A module the tidy leaves with no go.sum
# (no dependencies) exits 5: that module has no go.sum. An archive that
# did not land as a module (no go.mod at the top of /tmp/w) exits 4
# before anything runs (base#1440).
# shellcheck disable=SC2016 # expanded by the container's shell, not here.
readonly _PINS_GO_SUM_SCRIPT='set -eu
exec 3>&1 1>&2
mkdir -p /tmp/w
cd /tmp/w
tar -xf -
test -f go.mod || exit 4
cp go.mod /tmp/go.mod.staged
go mod tidy
go mod edit -json /tmp/go.mod.staged > /tmp/staged.json
go mod edit -json > /tmp/tidied.json
cmp -s /tmp/staged.json /tmp/tidied.json || exit 3
go mod verify
test -f go.sum || exit 5
cat go.sum >&3'

# _pins_go_sum <image> <gomod> <staged-gomod> <out>
#
# Write to <out> the go.sum Go wants for the module whose go.mod is <gomod>
# once its bytes are <staged-gomod>'s (base#1440): the module directory,
# with the staged go.mod in place of the old one, is tidied and verified in
# <image>. Nothing in the tree is written.
_pins_go_sum() {
  local _image="${1}" _gomod="${2}" _staged="${3}" _out="${4}"
  local _mod="${_gomod%/*}" _dir _rc=0
  _dir="$(mktemp -d)" || return 1
  # The module is copied and the staged go.mod laid over the copy, so the
  # tar is plain `-C <dir> .`: busybox tar, the one in the test image, has
  # no --anchored (base#1440).
  { cp -R -- "${_mod}/." "${_dir}/" && cp -- "${_staged}" "${_dir}/go.mod"; } \
    || { rm -rf -- "${_dir}"; return 1; }
  tar -cf - -C "${_dir}" . \
    | docker run --rm -i --user "$(id -u):$(id -g)" \
        -e GOTOOLCHAIN=local -e HOME=/tmp -e GOCACHE=/tmp/gocache \
        -e GOMODCACHE=/tmp/gomodcache -e GOFLAGS= \
        --entrypoint /bin/sh "${_image}" -c "${_PINS_GO_SUM_SCRIPT}" \
        > "${_out}" || _rc=$?
  rm -rf -- "${_dir}"
  return "${_rc}"
}

# _pins_set_go_mod <file> <lineno> <new-line> [<image>]
#
# Commit a go.mod line change together with the go.sum Go wants for it
# (base#1440): _pins_stage_go_mod, then _pins_commit_go_mod.
_pins_set_go_mod() {
  _pins_stage_go_mod "${@}" || return 1
  _pins_commit_go_mod "${1}" "${2}" "${3}" "${_PINS_STAGED_SUM}"
}

# _pins_stage_go_mod <file> <lineno> <new-line> [<image>]
#
# Compute, before any file is touched, the go.sum Go wants once the go.mod
# line changes (base#1440), and leave its path in _PINS_STAGED_SUM: a temp
# copy beside go.sum, or empty when the tidied module has no go.sum. The
# go.sum is computed in <image> when one is given (a golang bump names the
# image it proposes), otherwise in the image the golang pin names now.
_PINS_STAGED_SUM=""
_pins_stage_go_mod() {
  local _abs="${1}" _n="${2}" _repl="${3}" _image="${4:-}" _record _term=$'\n'
  local _state _gname _resolver _coord _pattern _skip _gfile _gline
  local _sum="${_abs%/*}/go.sum" _staged _sumtmp
  if [[ -z "${_image}" ]]; then
    _record="$(_pins_record "${_PINS_GOLANG_PIN}")"
    IFS=$'\t' read -r _state _gname _resolver _coord _pattern _skip _image \
      _gfile _gline <<< "${_record}"
    if [[ "${_state}" != "${_PIN_STATE_PINNED}" ]]; then
      _pins_refuse "${_abs}" golang_pin_missing "no pinned ${_PINS_GOLANG_PIN} image to regenerate go.sum in"
      return 1
    fi
  fi
  _pins_writable "${_abs}" || return 1
  (( _n > $(wc -l < "${_abs}") )) && _term=""
  _staged="$(mktemp)" || return 1
  { head -n "$(( _n - 1 ))" "${_abs}"; printf '%s%s' "${_repl}" "${_term}"
    tail -n "+$(( _n + 1 ))" "${_abs}"; } > "${_staged}"
  if ! _sumtmp="$(mktemp "${_sum%/*}/.go.sum.pins.XXXXXX")"; then
    rm -f -- "${_staged}"
    _pins_refuse "${_sum}" temp_create "no temp copy could be created beside it"
    return 1
  fi
  local _rc=0
  _pins_go_sum "${_image}" "${_abs}" "${_staged}" "${_sumtmp}" || _rc=$?
  if (( _rc == 5 )); then
    # The tidied module has no go.sum.
    rm -f -- "${_staged}" "${_sumtmp}"
    _PINS_STAGED_SUM=""
    return 0
  elif (( _rc == 4 )); then
    rm -f -- "${_staged}" "${_sumtmp}"
    _pins_refuse "${_abs}" go_sum_layout "the module archive sent to ${_image%%@*} has no go.mod at its top"
    return 1
  elif (( _rc == 3 )); then
    rm -f -- "${_staged}" "${_sumtmp}"
    _pins_refuse "${_abs}" go_sum_semantic "go mod tidy in ${_image%%@*} would also rewrite it"
    return 1
  elif (( _rc != 0 )); then
    rm -f -- "${_staged}" "${_sumtmp}"
    _pins_refuse "${_abs}" go_sum_tidy "go mod tidy / go mod verify failed in ${_image%%@*}"
    return 1
  fi
  rm -f -- "${_staged}"
  if [[ -e "${_sum}" ]]; then
    chmod "$(stat -c '%a' -- "${_sum}")" "${_sumtmp}"
  else
    chmod 644 "${_sumtmp}"
  fi
  _PINS_STAGED_SUM="${_sumtmp}"
}

# _pins_commit_go_mod <file> <lineno> <new-line> <staged-sum>
#
# Commit the go.mod line change and the go.sum _pins_stage_go_mod computed
# (base#1440): go.mod first, then go.sum, each by a rename of a copy beside
# it. An empty <staged-sum> means the module wants no go.sum, so the one
# that is there is removed. A failed go.sum step puts go.mod back.
_pins_commit_go_mod() {
  local _abs="${1}" _n="${2}" _repl="${3}" _sumtmp="${4}"
  local _sum="${_abs%/*}/go.sum"
  # A copy of go.mod as it was, so a failed go.sum rename or removal can
  # put go.mod back and the tree never holds the new go.mod beside the old
  # go.sum.
  local _bak
  if ! _bak="$(mktemp "${_abs%/*}/.go.mod.pins.bak.XXXXXX")" \
      || ! cp -p -- "${_abs}" "${_bak}"; then
    rm -f -- ${_sumtmp:+"${_sumtmp}"} ${_bak:+"${_bak}"}
    _pins_refuse "${_abs}" temp_create "no backup copy could be created beside it"
    return 1
  fi
  if ! _pins_commit "${_abs}" "${_n}" "${_repl}"; then
    rm -f -- ${_sumtmp:+"${_sumtmp}"} "${_bak}"
    return 1
  fi
  if [[ -z "${_sumtmp}" ]]; then
    if [[ -e "${_sum}" ]] && ! rm -f -- "${_sum}"; then
      mv -f "${_bak}" "${_abs}"
      _pins_refuse "${_sum}" commit_failed "the go.sum the module no longer needs could not be removed; go.mod was put back"
      return 1
    fi
    rm -f -- "${_bak}"
    return 0
  fi
  if ! mv -f "${_sumtmp}" "${_sum}"; then
    rm -f -- "${_sumtmp}"
    mv -f "${_bak}" "${_abs}"
    _pins_refuse "${_sum}" commit_failed "the temp copy could not be renamed over it; go.mod was put back"
    return 1
  fi
  rm -f -- "${_bak}"
}

# _pins_go_minor <image> -- the major.minor of a golang image's tag, or
# nothing when the tag does not start with one.
_pins_go_minor() {
  local _tag="${1%%@*}"
  _tag="${_tag##*:}"
  [[ "${_tag}" =~ ^([0-9]+)\.([0-9]+) ]] || return 0
  printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# _pins_set_golang <old-image> <new-image>
#
# A golang bump to another minor moves the Go that builds every module, so
# the `go` directive of every tracked go.mod is rewritten to the new minor
# and its go.sum regenerated in <new-image>, the image proposed, not the
# one replaced (base#1440). Every module is staged before any is committed,
# so a tidy that fails on one module leaves every module alone. A bump
# within the minor touches no go.mod. The Dockerfile line
# <dockerfile>:<lineno> becomes <new-line> last; every module committed
# before a failed commit, the Dockerfile's included, is put back from a
# copy taken before the first commit, so the tree never holds a new go
# line under the old golang pin.
_pins_set_golang() {
  local _old_mm _new_mm _list _file _go_rec _go_ln _abs _repl _i _sum
  local _df="${3}" _df_ln="${4}" _df_repl="${5}"
  local -a _abss=() _lns=() _repls=() _sums=() _recs=() _mods=()
  _old_mm="$(_pins_go_minor "${1}")"
  _new_mm="$(_pins_go_minor "${2}")"
  if [[ -z "${_new_mm}" || "${_old_mm}" == "${_new_mm}" ]]; then
    _pins_commit "${_df}" "${_df_ln}" "${_df_repl}"
    return
  fi
  _list="$(_pin_files "${PIN_REPO_ROOT}")" || return 1
  # Every module's go line is read before any is staged: a module with no
  # go line has none to move, so the bump is refused before docker runs.
  while IFS= read -r _file; do
    [[ "${_file##*/}" == go.mod ]] || continue
    _abs="${PIN_REPO_ROOT}/${_file}"
    _go_rec="$(_pin_go_mod_go_line "${_abs}")" || return 1
    if [[ -z "${_go_rec}" ]]; then
      _pins_refuse "${_abs}" go_directive_missing "no go directive for the golang bump to move"
      return 1
    fi
    _mods+=("${_abs}"); _recs+=("${_go_rec}")
  done <<< "${_list}"
  for _i in "${!_mods[@]}"; do
    _abs="${_mods[_i]}"
    _go_rec="${_recs[_i]}"
    _go_ln="${_go_rec%%$'\t'*}"
    _repl="$(_pin_go_mod_set_go_line "${_abs}" "${_go_ln}" "${_go_rec#*$'\t'}" "${_new_mm}")"
    if ! _pins_stage_go_mod "${_abs}" "${_go_ln}" "${_repl}" "${2}"; then
      for _sum in "${_sums[@]}"; do [[ -z "${_sum}" ]] || rm -f -- "${_sum}"; done
      return 1
    fi
    _abss+=("${_abs}"); _lns+=("${_go_ln}"); _repls+=("${_repl}")
    _sums+=("${_PINS_STAGED_SUM}")
  done
  # A copy of each go.mod and go.sum as it was; an empty entry means the
  # module had no go.sum.
  local -a _baks=() _sumbaks=()
  local _bak _sumbak _mod
  for _i in "${!_abss[@]}"; do
    _mod="${_abss[_i]%/*}"
    _bak=""; _sumbak=""
    if ! _bak="$(mktemp "${_mod}/.go.mod.pins.orig.XXXXXX")" \
        || ! cp -p -- "${_abss[_i]}" "${_bak}" \
        || { [[ -e "${_mod}/go.sum" ]] \
             && { ! _sumbak="$(mktemp "${_mod}/.go.sum.pins.orig.XXXXXX")" \
                  || ! cp -p -- "${_mod}/go.sum" "${_sumbak}"; }; }; then
      rm -f -- ${_bak:+"${_bak}"} ${_sumbak:+"${_sumbak}"} "${_baks[@]}"
      for _sum in "${_sumbaks[@]}" "${_sums[@]}"; do [[ -z "${_sum}" ]] || rm -f -- "${_sum}"; done
      _pins_refuse "${_abss[_i]}" temp_create "no backup copy could be created beside it"
      return 1
    fi
    _baks+=("${_bak}"); _sumbaks+=("${_sumbak}")
  done
  # A commit's refusal is held until the rollback is known: when a module
  # cannot be put back, the refusal that leads is rollback_failed, never a
  # commit_failed that says the file is left as it was.
  local _failed="" _err="" _unrestored=""
  for _i in "${!_abss[@]}"; do
    if ! _err="$(_pins_commit_go_mod "${_abss[_i]}" "${_lns[_i]}" "${_repls[_i]}" "${_sums[_i]}" 2>&1)"; then
      for _sum in "${_sums[@]:_i+1}"; do [[ -z "${_sum}" ]] || rm -f -- "${_sum}"; done
      _failed=1
      break
    fi
  done
  [[ -n "${_failed}" ]] || _err="$(_pins_commit "${_df}" "${_df_ln}" "${_df_repl}" 2>&1)" || _failed=1
  for _i in "${!_abss[@]}"; do
    _mod="${_abss[_i]%/*}"
    if [[ -n "${_failed}" ]]; then
      mv -f -- "${_baks[_i]}" "${_abss[_i]}" || _unrestored+="${_abss[_i]}"$'\t'"${_baks[_i]}"$'\n'
      if [[ -n "${_sumbaks[_i]}" ]]; then
        mv -f -- "${_sumbaks[_i]}" "${_mod}/go.sum" \
          || _unrestored+="${_mod}/go.sum"$'\t'"${_sumbaks[_i]}"$'\n'
      else
        rm -f -- "${_mod}/go.sum" || _unrestored+="${_mod}/go.sum"$'\t-\n'
      fi
    else
      rm -f -- "${_baks[_i]}" ${_sumbaks[_i]:+"${_sumbaks[_i]}"}
    fi
  done
  while IFS=$'\t' read -r _file _bak; do
    [[ -n "${_file}" ]] || continue
    _log_err pin pin_set_refused "file=${_file}" "reason=rollback_failed" \
      "display=pin_set_refused: ${_file}: a commit failed and it could not be put back; its copy as it was is kept at ${_bak}"
  done <<< "${_unrestored}"
  [[ -z "${_err}" ]] || printf '%s\n' "${_err}" >&2
  [[ -z "${_failed}" ]]
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

  if [[ "${_file##*/}" == go.mod ]]; then
    _pins_set_go_mod "${_abs}" "${_line}" "${_new_line}" || return 1
  elif [[ "${_name}" == "${_PINS_GOLANG_PIN}" ]]; then
    _pins_set_golang "${_current}" "${_new}" "${_abs}" "${_line}" "${_new_line}" || return 1
  else
    _pins_commit "${_abs}" "${_line}" "${_new_line}" || return 1
  fi

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
