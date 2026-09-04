#!/usr/bin/env bash
#
# probe_test_tools.sh - Does this test-tools image match THIS checkout?
#
# CI does not rebuild the tooling image for a PR that leaves
# dockerfile/Dockerfile.test-tools alone. It pulls the rolling `:main` tag
# instead, and `:main` is republished only by a push to main that touches
# that Dockerfile -- a multi-arch build including a native arm64 shard. So
# there is always a window, and after a failed republish an open-ended one,
# in which an unrelated PR's suite would run inside an image that does not
# correspond to its own checkout.
#
# Two distinct ways that hurts, and the guard used to see only the first:
#
#   ABSENT   a tool baked in by a change already on main is missing from
#            the :main this run pulled (the kcov case). Loud: the suite
#            fast-fails "kcov: not found".
#   STALE    the tool is there, at the version the pin used to name. Silent
#            and worse: shellcheck and hadolint are lint GATES, and a gate
#            running an older rule set does not fail, it under-reports.
#            Every rule added since the previous pin simply never runs,
#            and the green check is reporting on something other than what
#            the checkout asked for.
#
# So presence is necessary and not sufficient. For a tool whose version the
# checkout pins, the probe reads the pin out of that checkout and compares
# it with what the image actually reports. The expectation is never written
# here: a literal in this file would be a second place to bump, and two
# literals that agree with each other prove only that someone edited both.
#
# The runner is the third such tool and the one that is not a lint gate.
# `just` is this project's only control surface, and
# test/bats/integration/just_runner_version_spec.bats is fail-closed on a
# mismatch between the image's runner and ARG JUST_VERSION -- so a :main
# published before a version bump carries every required tool AND the wrong
# runner, and a presence-only probe would hand it to a PR that touched
# nothing related (base#948).
#
# The same argument reaches one pin further. Every stage of that Dockerfile
# is built `FROM alpine:${ALPINE_VERSION}`, and the series decides which
# bash the image ships -- which decides whether kcov can read this suite's
# coverage at all, since bash 5.3's xtrace quoting makes it report lines
# that ran as never run (the measured table sits beside the pin). An image
# on another series is a different image in the way that matters, so the
# series is compared first: it is the coarsest disagreement, and a tool
# reading taken from an image built on the wrong base answers a question
# nobody asked.
#
# The caller's contract is a verdict, not a diagnosis:
#
#   exit 0   the image corresponds to this checkout; use it
#   exit 1   it does not; the reason is on stderr. Every caller answers
#            this by rebuilding from dockerfile/Dockerfile.test-tools,
#            which is the strict side -- a rebuild costs minutes, a wrong
#            rule set costs a review.
#   exit 2   the probe could not form an expectation at all (a moved
#            release URL, a renamed file, a contradictory tool list).
#            Separated from 1 because "cannot tell" is not "does not
#            match", but it is emphatically not a pass: comparing an empty
#            expectation against an empty reading agrees with itself, and
#            that is the shape of pass this whole mechanism exists to
#            refuse.
#
# Usage:
#   ./script/ci/probe_test_tools.sh <image> [dockerfile]
#
# Env:
#   REQUIRED_TOOLS  tools the run EXECUTES and must therefore be present
#                   (default: kcov bats shellcheck hadolint just). A job
#                   that only uses the image as a `FROM` base needs no
#                   probe at all -- see the acceptance job.
#   PINNED_TOOLS    subset whose VERSION is pinned by the checkout and is
#                   therefore compared, not merely found
#                   (default: shellcheck hadolint just).
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_PROBE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# The tools a run executes, and the subset whose version is load-bearing.
# Overridable so a caller can narrow, never silently: an override that
# drops a PINNED tool is refused below rather than honoured.
: "${REQUIRED_TOOLS:=kcov bats shellcheck hadolint just}"
: "${PINNED_TOOLS:=shellcheck hadolint just}"

# _probe_default_dockerfile
#   The checkout's test-tools Dockerfile, resolved from THIS script's own
#   location rather than the caller's cwd: CI invokes the probe with the
#   image alone, and a cwd that is not the repo root must not turn the
#   comparison into an unreadable-pin refusal.
_probe_default_dockerfile() {
  local _root
  _root="$(cd -- "${_PROBE_DIR}/../.." && pwd -P)" || return 1
  printf '%s\n' "${_root}/dockerfile/Dockerfile.test-tools"
}

# _probe_run <image> <command>
#   Run one command inside the image and print its stdout. The single
#   seam through which this script touches docker, so the decision logic
#   above it is drivable from a unit spec with no daemon.
_probe_run() {
  local _image="${1:?BUG: _probe_run expects an image}"
  local _cmd="${2:?BUG: _probe_run expects a command}"
  docker run --rm "${_image}" sh -c "${_cmd}"
}

# _probe_pinned_version <dockerfile> <tool>
#   The version this checkout pins for <tool>, read from its
#   `ARG <TOOL>_VERSION=` declaration, leading v stripped. Prints nothing
#   and returns 1 when no such declaration is present, or when more than
#   one is -- an unreadable pin is a defect for the caller to report, never
#   an absent constraint the caller may skip, and two declarations name no
#   single version for an image to agree with.
#
#   This used to read the version out of the literal release URL, because
#   that is where it was written. It no longer is: a version inside a
#   line-continued RUN has no line of its own for a `tool-pin:` marker to
#   attach to, so both linters were hoisted onto `ARG` lines and the URLs
#   now interpolate them -- the shape `just` was already in, and the reason
#   _probe_just_pin below is spelled differently from this. Reading the ARG
#   is therefore not a second provenance path; it is the same one, reached
#   at its declaration rather than at its use.
_probe_pinned_version() {
  local _file="${1:?BUG: _probe_pinned_version expects a file}"
  local _tool="${2:?BUG: _probe_pinned_version expects a tool}"
  [[ -f "${_file}" ]] || return 1
  local _arg _script _v
  _arg="${_tool^^}_VERSION"
  # The sed program is named rather than inlined for two reasons. It keeps
  # the extraction under one screen width, and it keeps the substitution on
  # a line of its own: a `\`-continued command substitution is one bash
  # statement spread over two source lines, and kcov credits its execution
  # to neither of them, so the read below was permanently unmeasurable
  # while plainly running.
  #
  # The stage-level `ARG <TOOL>_VERSION` that re-declares a build arg
  # without a default carries no `=`, so it is not a match and does not
  # read as a second declaration.
  _script="s|^ARG[[:space:]]\{1,\}${_arg}=[[:space:]]*||p"
  local -a _hits=()
  while IFS= read -r _v; do
    _hits+=("${_v}")
  done < <(sed -n "${_script}" "${_file}")
  [[ "${#_hits[@]}" -eq 1 ]] || return 1
  _v="${_hits[0]}"
  _v="${_v%\"}"; _v="${_v#\"}"
  _v="${_v%\'}"; _v="${_v#\'}"
  _v="${_v//[[:space:]]/}"
  _v="${_v#v}"
  [[ "${_v}" =~ ^[0-9][0-9.]*$ ]] || return 1
  printf '%s\n' "${_v}"
}

# _probe_just_pin
#   The pinned `just` version, read through dist/script/base/just-version.sh.
#
#   Why this one tool is not read the way the other two are. Its release
#   URL names `${JUST_VERSION}` rather than a literal, so there is no
#   version in the URL to grep; the version is `ARG JUST_VERSION` in the
#   same Dockerfile, and that declaration already has exactly ONE reader in
#   the tree. A second sed here would be a fifth provenance path for the
#   runner -- the drift the accessor exists to end (base#948) -- so the probe
#   calls the accessor instead of re-deriving what it reads.
#
#   The consequence, stated because it is asymmetric: the optional
#   <dockerfile> override moves the shellcheck / hadolint / alpine
#   expectations and does NOT move this one, because the accessor resolves
#   the declaration from its own location in the checkout.
_probe_just_pin() {
  local _accessor="${_PROBE_DIR}/../../dist/script/base/just-version.sh"
  [[ -x "${_accessor}" ]] || return 1
  local _v
  _v="$("${_accessor}")" || return 1
  [[ -n "${_v}" ]] || return 1
  printf '%s\n' "${_v}"
}

# _probe_tool_pin <dockerfile> <tool>
#   The version this checkout pins for <tool>, whichever way that tool's
#   pin is written. One seam so the verdict loop asks the same question of
#   every PINNED tool and the per-tool spelling stays here.
_probe_tool_pin() {
  local _file="${1:?BUG: _probe_tool_pin expects a file}"
  local _tool="${2:?BUG: _probe_tool_pin expects a tool}"
  case "${_tool}" in
    just) _probe_just_pin ;;
    *) _probe_pinned_version "${_file}" "${_tool}" ;;
  esac
}

# _probe_pinned_series <dockerfile>
#   The alpine SERIES the checkout pins, from `ARG ALPINE_VERSION=`. Prints
#   nothing and returns 1 when the ARG is absent or declared more than
#   once: two pins disagreeing with each other is a state in which no
#   expectation exists, not one where a reader may pick a side.
_probe_pinned_series() {
  local _file="${1:?BUG: _probe_pinned_series expects a file}"
  [[ -f "${_file}" ]] || return 1
  local _script _line
  local -a _hits=()
  # Named for the same reason as the version reader's program below: a
  # `\`-continued command substitution is one statement over two source
  # lines and kcov credits its execution to neither.
  _script='s|^ARG ALPINE_VERSION=\([0-9][0-9.]*\)[[:space:]]*$|\1|p'
  while IFS= read -r _line; do
    _hits+=("${_line}")
  done < <(sed -n "${_script}" "${_file}")
  [[ "${#_hits[@]}" -eq 1 ]] || return 1
  printf '%s\n' "${_hits[0]}"
}

# _probe_reports_version <text> <version>
#   Does the tool's own --version output carry exactly this version? The
#   dots are escaped so they cannot match any character, and the number is
#   bounded on both sides so 0.11.0 is not satisfied by 0.11.01 or by a
#   longer digit run that merely contains it.
_probe_reports_version() {
  local _text="${1?BUG: _probe_reports_version expects the tool output}"
  local _version="${2:?BUG: _probe_reports_version expects a version}"
  local _re="${_version//./\\.}"
  [[ "${_text}" =~ (^|[^0-9.])${_re}([^0-9.]|$) ]]
}

# _probe_image <image> [dockerfile]
#   The verdict. See the exit-status contract in the header.
_probe_image() {
  local _image="${1:?BUG: _probe_image expects an image}"
  local _file="${2:-$(_probe_default_dockerfile)}"

  local -a _required=() _pinned=()
  read -ra _required <<< "${REQUIRED_TOOLS}"
  read -ra _pinned <<< "${PINNED_TOOLS}"

  # Non-vacuity. A probe over an empty list answers "yes" to every image.
  if [[ "${#_required[@]}" -eq 0 ]]; then
    printf 'probe: REQUIRED_TOOLS is empty, so this probe would accept any image. Name the tools the run executes.\n' >&2
    return 2
  fi

  # A tool whose version matters that the probe never even looks for is a
  # list that has drifted apart, not a deliberately narrower probe.
  local _p _r _found
  for _p in "${_pinned[@]}"; do
    _found=false
    for _r in "${_required[@]}"; do
      [[ "${_r}" == "${_p}" ]] && _found=true
    done
    if [[ "${_found}" != "true" ]]; then
      printf 'probe: %s is in PINNED_TOOLS but not in REQUIRED_TOOLS (%s), so its version would never be compared.\n' \
        "${_p}" "${REQUIRED_TOOLS}" >&2
      return 2
    fi
  done

  # The series, before any tool: see the header. A reading the image cannot
  # produce is a mismatch rather than a pass, and the comparison is on the
  # whole series field -- a pin of 3.2 does not agree with a 3.22 image.
  local _series _release
  if ! _series="$(_probe_pinned_series "${_file}")"; then
    printf 'probe: could not read the alpine series pin (ARG ALPINE_VERSION) from %s. The file moved, or it names the series twice. Refusing to report agreement with an image whose base is unknown.\n' \
      "${_file}" >&2
    return 2
  fi
  _release="$(_probe_run "${_image}" 'cat /etc/alpine-release' 2>/dev/null)" \
    || _release=""
  case "${_release}" in
    "${_series}" | "${_series}".*) ;;
    *)
      printf 'probe: %s pins alpine %s but %s reports: %s\n' \
        "${_file}" "${_series}" "${_image}" "${_release:-<nothing>}" >&2
      return 1
      ;;
  esac
  printf 'probe: alpine %s matches the pin.\n' "${_series}"

  local _tool _pin _actual
  for _tool in "${_required[@]}"; do
    if ! _probe_run "${_image}" "command -v ${_tool}" >/dev/null 2>&1; then
      printf 'probe: %s carries no %s.\n' "${_image}" "${_tool}" >&2
      return 1
    fi

    _found=false
    for _p in "${_pinned[@]}"; do
      [[ "${_p}" == "${_tool}" ]] && _found=true
    done
    [[ "${_found}" == "true" ]] || continue

    if ! _pin="$(_probe_tool_pin "${_file}" "${_tool}")"; then
      printf 'probe: could not read the %s pin from %s (or, for the runner, through dist/script/base/just-version.sh). The release URL moved, or the file did. Refusing to report agreement between two empty strings.\n' \
        "${_tool}" "${_file}" >&2
      return 2
    fi
    _actual="$(_probe_run "${_image}" "${_tool} --version" 2>/dev/null)" \
      || _actual=""
    if ! _probe_reports_version "${_actual}" "${_pin}"; then
      printf 'probe: %s pins %s v%s but %s reports: %s\n' \
        "${_file}" "${_tool}" "${_pin}" "${_image}" "${_actual:-<nothing>}" >&2
      return 1
    fi
    printf 'probe: %s v%s matches the pin.\n' "${_tool}" "${_pin}"
  done

  printf 'probe: %s carries every required tool at the pinned version.\n' \
    "${_image}"
}

main() {
  if [[ "$#" -lt 1 || -z "${1}" ]]; then
    printf 'usage: probe_test_tools.sh <image> [dockerfile]\n' >&2
    return 2
  fi
  _probe_image "${1}" "${2:-$(_probe_default_dockerfile)}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
