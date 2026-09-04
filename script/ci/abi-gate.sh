#!/usr/bin/env bash
# abi-gate.sh -- decides whether a dependency bump may auto-release.
#
# A downstream repo that pins an upstream dependency wants the bump flow
# hands-off: detect a new upstream tag, update the pin, changelog it, merge on
# green, release. The step that cannot be mechanical without a rule is the last
# one, and this is that rule. It answers ONE question -- is this old -> new pin
# change ABI-safe by the convention this dependency itself follows -- and
# nothing else. Which version to cut, and whether to fan out, are the caller's
# and are settled by ADR-00000027.
#
# THE FAIL-OPEN DIRECTION IS DECLARING A BREAK SAFE, so every case this cannot
# decide refuses: an unreadable version on either side, an undeclared or
# unrecognised ABI axis, a downgrade, an unchanged pin, and a pair the
# upstream's own compatibility declaration does not sanction. A refusal is not
# an error in the process -- it is the gate handing the bump back to a person,
# which is where a breaking dependency change belongs.
#
# THERE IS NO DEFAULT ABI AXIS, deliberately. Which component of a version is a
# dependency's ABI is a fact about that dependency: librealsense's SONAME
# carries its minor, plenty of libraries only their major. Guessing it here
# would be a base-wide decision that silently releases somebody's break, so the
# caller declares it and an absent declaration refuses.
#
# Input : DEP_NAME         what is being bumped (appears in every message)
#         OLD_VERSION      the pin before this change
#         NEW_VERSION      the pin after it
#         ABI_AXIS         major | major.minor -- the component set that IS
#                          this dependency's ABI
#         UPSTREAM_COMPAT  optional: the dependency version the consuming
#                          upstream declares it requires. When set, the new pin
#                          must agree with it on the ABI axis, so a pair the
#                          upstream never shipped together cannot auto-release.
# Output: on approval, `decision=release` and a one-line `reason=` on stdout,
#         ready to append to GITHUB_OUTPUT.
# Exit  : 0 to auto-release; 1 for every refusal, which prints the reason on
#         stderr and NOTHING on stdout -- so a caller appending stdout to
#         GITHUB_OUTPUT has no `decision` key, and both the
#         `outputs.decision == 'release'` wiring and the bare exit status read
#         a refusal as "do not release". A caller that wants a refusal to be a
#         normal outcome rather than a red job runs the step with
#         `continue-on-error: true` and gates on its `outcome`.

set -euo pipefail

# A dependency version this gate is willing to compare: digits and dots, at
# least two components, an optional `v`. A suffixed version (2.56.1-rc1) is a
# prerelease or a vendor build rather than a released interface, and is refused
# rather than compared on the numbers in front of the suffix.
readonly VERSION_RE='^v?[0-9]+(\.[0-9]+)+$'

# _refuse <message>... -- state why nothing is being released, and stop.
# stderr only: stdout is the caller's output channel and a refusal must leave
# nothing on it.
_refuse() {
  printf 'abi-gate: %s -- NOT auto-releasing: %s\n' \
    "${DEP_NAME:-<dependency unnamed>}" "$*" >&2
  exit 1
}

_is_version() {
  [[ "${1}" =~ ${VERSION_RE} ]]
}

# _components <version> -- the version's numeric components, space separated.
# Only ever called on a value _is_version has already accepted.
_components() {
  local value="${1#v}"
  printf '%s' "${value//./ }"
}

# _cmp <a-components> <b-components> -- 0 when equal, 1 when a > b, 2 when
# a < b. Missing trailing components count as zero, so 2.56 and 2.56.0 are the
# same version.
_cmp() {
  # shellcheck disable=SC2206  # deliberate word-split on the space separator.
  local -a a=(${1}) b=(${2})
  local i len="${#a[@]}"
  if (( ${#b[@]} > len )); then
    len="${#b[@]}"
  fi
  for (( i = 0; i < len; i++ )); do
    if (( 10#${a[i]:-0} > 10#${b[i]:-0} )); then
      return 1
    fi
    if (( 10#${a[i]:-0} < 10#${b[i]:-0} )); then
      return 2
    fi
  done
  return 0
}

# _axis_equal <a-components> <b-components> <width> -- do the two versions
# agree on the first <width> components, i.e. on the ABI axis.
_axis_equal() {
  # shellcheck disable=SC2206  # deliberate word-split on the space separator.
  local -a a=(${1}) b=(${2})
  local width="${3}" i
  for (( i = 0; i < width; i++ )); do
    if [[ "${a[i]:-0}" != "${b[i]:-0}" ]]; then
      return 1
    fi
  done
  return 0
}

# _axis_width <axis> -- how many leading components the declared axis covers,
# or non-zero for an axis this does not recognise.
#
# It reports rather than refuses, and the caller states the refusal. A `_refuse`
# here would run inside the caller's command substitution, where `exit` leaves
# only the SUBSHELL -- the script would carry on with an empty width, and an
# empty width compares nothing, which is the fail-open this gate exists to
# prevent. An unrecognised axis never resolves to either known one.
_axis_width() {
  case "${1}" in
    major) printf '1' ;;
    major.minor) printf '2' ;;
    *) return 1 ;;
  esac
}

_check_compat() {
  local compat="${1}" new="${2}" new_c="${3}" width="${4}"
  _is_version "${compat}" \
    || _refuse "the upstream compatibility declaration is '${compat}', which this cannot read as a version. An unreadable constraint is not a satisfied one."
  _axis_equal "$(_components "${compat}")" "${new_c}" "${width}" \
    || _refuse "the new pin ${new} is outside the compatibility the upstream declares (${compat}). Only a pair the upstream itself sanctions auto-releases; bumping each dependency to its own latest is a combination nobody has tested."
}

main() {
  local dep="${DEP_NAME:-}" old="${OLD_VERSION:-}" new="${NEW_VERSION:-}"
  local axis="${ABI_AXIS:-}" compat="${UPSTREAM_COMPAT:-}"

  [[ -n "${dep}" ]] \
    || _refuse "DEP_NAME is not set -- a decision nobody can attribute to a dependency is not reviewable."
  [[ -n "${old}" && -n "${new}" ]] \
    || _refuse "OLD_VERSION and NEW_VERSION must both be set; there is no bump to judge without both ends of it."

  [[ -n "${axis}" ]] \
    || _refuse "ABI_AXIS is not set. Declare which component of this dependency's version is its ABI -- ABI_AXIS=major or ABI_AXIS=major.minor. There is no default: the answer is a fact about the dependency, and guessing it would let a breaking bump release itself."
  local width
  width="$(_axis_width "${axis}")" \
    || _refuse "ABI_AXIS is '${axis}', which this does not recognise. Expected major or major.minor."

  _is_version "${old}" \
    || _refuse "the old pin is '${old}', which this cannot read as a version. A pin that cannot be compared cannot be shown to be ABI-safe."
  _is_version "${new}" \
    || _refuse "the new pin is '${new}', which this cannot read as a version. A pin that cannot be compared cannot be shown to be ABI-safe."

  local old_c new_c
  old_c="$(_components "${old}")"
  new_c="$(_components "${new}")"

  if [[ "${width}" == "1" && ( "${old_c%% *}" == "0" || "${new_c%% *}" == "0" ) ]]; then
    _refuse "${old} -> ${new} is a 0.x pin, whose major promises nothing about compatibility. Declare ABI_AXIS=major.minor for this dependency; it is not re-read as that here, because a declaration nobody corrects goes on meaning something other than what it says."
  fi

  local order=0
  _cmp "${new_c}" "${old_c}" || order="$?"
  case "${order}" in
    0)
      _refuse "the pin does not change (${old}); there is nothing to release."
      ;;
    2)
      _refuse "${old} -> ${new} is a downgrade. That is a revert or a mistake, and either way it is a person's call, not a routine bump."
      ;;
  esac

  _axis_equal "${old_c}" "${new_c}" "${width}" \
    || _refuse "${old} -> ${new} moves the ${axis}, which is this dependency's declared ABI. A rebuild against it is not a formality, so this bump goes to a person."

  if [[ -n "${compat}" ]]; then
    _check_compat "${compat}" "${new}" "${new_c}" "${width}"
  fi

  printf 'decision=release\n'
  printf 'reason=%s %s -> %s leaves the %s unchanged%s\n' \
    "${dep}" "${old}" "${new}" "${axis}" \
    "${compat:+, and matches the compatibility upstream declares (${compat})}"
}

main "$@"
