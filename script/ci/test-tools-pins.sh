#!/usr/bin/env bash
# test-tools-pins.sh - the ROSTER of version pins the tooling image is
# built from, derived from the Dockerfile that declares them.
#
# Usage:
#   test-tools-pins.sh roster
#       One `<ARG>\t<pinned>\t<probe>` line per version pin declared in
#       dockerfile/Dockerfile.test-tools, in declaration order.
#   test-tools-pins.sh check <ARG> <observed>
#       Exit 0 when <observed> -- whatever the probe printed -- carries
#       the version <ARG> pins. Exit non-zero otherwise.
#
# ── The hazard ──────────────────────────────────────────────────────────
#
# The published-image smoke step in .github/workflows/release-test-tools
# ran fifteen probes and fourteen of them asserted an exit status and
# nothing else. That catches a tool's REMOVAL and never its staleness,
# which is precisely how the image sat 37 minors behind the `just` every
# other path installed while every one of those probes stayed green.
#
# `just` was repaired by comparing it to its declaration. The other three
# pins in that Dockerfile -- BATS_VERSION, KCOV_VERSION, ALPINE_VERSION --
# were still compared to nothing, and the last was not probed at all. A
# silently downlevel `bats` is the worst of them, since bats is the
# harness the whole repo is tested with: a stale one changes what every
# other spec means, quietly.
#
# ── Why this is a roster and not three more probes ──────────────────────
#
# Three more comparisons leave the same defect one ARG away: the next
# pinned tool arrives with no probe and nothing notices, exactly as these
# three did. So the POPULATION is computed from the declaration -- every
# `ARG <NAME>_VERSION=<value>` in that Dockerfile -- and `roster` REFUSES
# to answer while a declared pin has no probe, naming it. A tool cannot
# be pinned there and go unasserted, because the roster its consumers
# iterate cannot be produced while one of them has no way to be asked.
#
# What stays a fixed table is the vocabulary: HOW to ask a given tool its
# version. That is the detector, not the population -- the same split
# script/test/drivers/just_provenance.sh draws between its marker table
# and the tree it scans.
#
# Consumers: the smoke step of release-test-tools.yaml (the published
# image), test/bats/integration/test_tools_pins_spec.bats (the image the
# suite runs in) and test/bats/unit/test_tools_pins_spec.bats (this
# file's own contract).
#
# Reads nothing from the environment: the declaration is the whole input.

# Only set strict mode when running directly; when sourced, respect the
# caller's settings.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# The declaration, relative to the repo root. Named here so the error
# messages can point at the file to edit.
_TTP_DECL_REL='dockerfile/Dockerfile.test-tools'

# The probe vocabulary: for each pinned tool, the shell command that asks
# the image what it actually carries. Parallel arrays keyed by ARG name,
# because a probe is a command line and a packed field separator would
# have to be chosen against it.
#
# alpine is read from /etc/alpine-release rather than from a `--version`
# flag: it is the base image, not a program, and that file is the only
# thing in the image that knows which one it is.
_TTP_ARG=(
  'BATS_VERSION'
  'ALPINE_VERSION'
  'KCOV_VERSION'
  'JUST_VERSION'
)
_TTP_PROBE=(
  'bats --version'
  'cat /etc/alpine-release'
  'kcov --version'
  'just --version'
)

# _ttp_root -- the repo root, derived from this file's own location
# (<root>/script/ci/test-tools-pins.sh). Not a cwd walk: the accessor is
# called from the repo root, from a workflow step and from a spec, and
# all three must read the same declaration. The same derivation, for the
# same reason, as dist/script/base/just-version.sh.
#
# ${BASH_SOURCE[0]:-$0} rather than the bare indexed read: the array is
# not populated in every context (the kcov-instrumented shell most of
# all) and the bare form aborts under nounset.
_ttp_root() {
  local _self _dir
  _self="${BASH_SOURCE[0]:-$0}"
  _dir="$(cd -- "$(dirname -- "${_self}")" && pwd)" || return 1
  (cd -- "${_dir}/../.." && pwd)
}

# _ttp_probe_for <ARG> -- print the probe for <ARG>, or return 1.
_ttp_probe_for() {
  local _want="${1}" _i
  for _i in "${!_TTP_ARG[@]}"; do
    if [[ "${_TTP_ARG[_i]}" == "${_want}" ]]; then
      printf '%s\n' "${_TTP_PROBE[_i]}"
      return 0
    fi
  done
  return 1
}

# _ttp_declarations <outarray> -- fill <outarray> with `<ARG>=<value>` for
# every version pin the Dockerfile declares.
#
# Reads the WHOLE file: a reader that stopped at the first hit could not
# tell one declaration from two. The stage-level re-declarations that
# carry no `=` (`ARG JUST_VERSION` inside a builder stage) are not
# matches, which is what keeps a build arg's re-declaration from reading
# as a second pin.
_ttp_declarations() {
  local -n _ttpd_out="${1}"
  local _file="${2}"
  _ttpd_out=()
  mapfile -t _ttpd_out < <(
    sed -n 's/^ARG[[:space:]]\{1,\}\([A-Z0-9_]\{1,\}_VERSION\)=[[:space:]]*/\1=/p' \
      "${_file}"
  )
}

# _ttp_roster -- print the roster, or refuse.
_ttp_roster() {
  local _root _file
  _root="$(_ttp_root)" || {
    echo "test-tools-pins: cannot locate the repo root from ${BASH_SOURCE[0]:-$0}" >&2
    return 2
  }
  _file="${_root}/${_TTP_DECL_REL}"
  if [[ ! -f "${_file}" ]]; then
    echo "test-tools-pins: declaration not found -- ${_file} is missing" >&2
    return 2
  fi

  local -a _decls=()
  _ttp_declarations _decls "${_file}"
  if [[ "${#_decls[@]}" -eq 0 ]]; then
    echo "test-tools-pins: no 'ARG <NAME>_VERSION=<value>' in ${_file}. An empty roster satisfies every consumer that iterates it, in silence, so it is refused rather than printed." >&2
    return 2
  fi

  local _d _arg _pin _probe _missing=""
  local -a _rows=()
  for _d in "${_decls[@]}"; do
    _arg="${_d%%=*}"
    _pin="${_d#*=}"
    _pin="${_pin%\"}"; _pin="${_pin#\"}"
    _pin="${_pin%\'}"; _pin="${_pin#\'}"
    _pin="${_pin//[[:space:]]/}"
    if [[ -z "${_pin}" ]]; then
      echo "test-tools-pins: 'ARG ${_arg}=' in ${_file} declares an empty version" >&2
      return 2
    fi
    if ! _probe="$(_ttp_probe_for "${_arg}")"; then
      _missing+=" ${_arg}"
      continue
    fi
    _rows+=("$(printf '%s\t%s\t%s' "${_arg}" "${_pin}" "${_probe}")")
  done

  if [[ -n "${_missing}" ]]; then
    echo "test-tools-pins: ${_file} pins${_missing} but this file carries no probe for it, so the roster cannot say whether the image really ships it. Add the command that asks the tool its version to the probe table in $(basename -- "${BASH_SOURCE[0]:-$0}"). Refusing rather than skipping is the point: a pin nobody can ask about is the staleness this roster exists to end." >&2
    return 2
  fi

  printf '%s\n' "${_rows[@]}"
}

# _ttp_check <ARG> <observed> -- does <observed> carry the pinned version?
#
# The rule is one rule for every tool: the pin must appear in the output
# as a whole dotted-version token, or as a dotted PREFIX of one. The
# prefix half is not laxity -- ALPINE_VERSION pins a SERIES (3.21) and
# /etc/alpine-release answers 3.21.7, so an equality rule would fail
# every image this Dockerfile can build. The token boundaries are what
# keep it from being a substring test: `v43` is not satisfied by `v431`
# and `1.13.0` is not satisfied by `1.13.01`, which is exactly the
# false green a plain `case ... in *"${pin}"*)` would give.
_ttp_check() {
  local _arg="${1-}" _observed="${2-}" _root _file
  if [[ -z "${_arg}" ]]; then
    echo "test-tools-pins: check needs an ARG name and the probe's output" >&2
    return 2
  fi
  if ! _ttp_probe_for "${_arg}" > /dev/null; then
    echo "test-tools-pins: '${_arg}' is not on the roster -- this file carries no probe for it, so there is nothing to compare against." >&2
    return 2
  fi

  _root="$(_ttp_root)" || return 2
  _file="${_root}/${_TTP_DECL_REL}"
  local -a _decls=()
  _ttp_declarations _decls "${_file}"

  local _d _pin=""
  for _d in "${_decls[@]}"; do
    if [[ "${_d%%=*}" == "${_arg}" ]]; then
      _pin="${_d#*=}"
      _pin="${_pin//[[:space:]]/}"
    fi
  done
  if [[ -z "${_pin}" ]]; then
    echo "test-tools-pins: ${_file} declares no ARG ${_arg}=<version>" >&2
    return 2
  fi

  if [[ -z "${_observed}" ]]; then
    echo "test-tools-pins: the probe for ${_arg} printed nothing. Empty output is not agreement -- it is a probe that did not run." >&2
    return 1
  fi

  # The pin is data, not a pattern: escape every regex metacharacter in
  # it before it becomes one. A `.` left unescaped makes 1.13.0 match
  # 1x13y0, which is a substring test wearing a boundary check's clothes.
  local _quoted
  _quoted="$(printf '%s' "${_pin}" | sed 's/[][\.^$*+?(){}|/-]/\\&/g')"

  if [[ "${_observed}" =~ (^|[^0-9A-Za-z.])${_quoted}(\.[0-9]+)*([^0-9.]|$) ]]; then
    return 0
  fi
  echo "test-tools-pins: ${_arg} is pinned at ${_pin} but the probe answered '${_observed}'" >&2
  return 1
}

# _ttp_main <subcommand> [arg]... -- dispatch. An unrecognised subcommand
# is refused and the message names what IS answered.
_ttp_main() {
  local _cmd="${1-}"
  case "${_cmd}" in
    roster) shift; _ttp_roster "${@}" ;;
    check)  shift; _ttp_check "${@}" ;;
    *)
      echo "test-tools-pins: no such subcommand '${_cmd}'. This answers: roster -- one tab-separated '<ARG> <pinned> <probe>' line per version pin the tooling Dockerfile declares; check <ARG> <observed> -- whether the probe's output carries that pin." >&2
      return 2
      ;;
  esac
}

# Only run when executed directly, not when sourced (for testing).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _ttp_main "$@"
fi
