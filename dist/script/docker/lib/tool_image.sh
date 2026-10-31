#!/usr/bin/env bash
# tool_image.sh -- resolve, and provision when absent, a tool image built
# from the vendored subtree under a content-digest tag (base#1466).
#
# The TOML bridge (toml_bridge.sh, ADR-37) and the config generator
# (config_gen.sh, ADR-00000039) both ship their build inputs inside the
# subtree a consumer vendors, and both need the same four steps: find the
# subtree root, name the image by a digest of its inputs, build it once
# when it is absent, and remember the answer for the rest of the shell.
# This file holds those steps once, keyed by a namespace (`ns`) whose
# profile tool_image_define records.
#
# A PROFILE, NOT A TOOL'S LITERAL NAMES. Each tool differs in its repo,
# Dockerfile, build context, override variable, memo variable and build
# args. The build context is a profile field used by BOTH the digest and
# the build: the config generator's context is dockerfile/config-gen, not
# the Dockerfile's own directory, and a digest over the Dockerfile's
# directory would key its tag on every sibling tool's inputs.
#
# RESOLVE NEVER PRINTS. It writes the profile's memo variable in the
# caller's shell, so a caller cannot reach it through a command
# substitution -- where the memo would not survive and every read would
# inspect, and maybe build, again.
#
# A FAILED BUILD RETURNS, IT DOES NOT EXIT. The INI-to-TOML migration's
# commit gate reads an unavailable bridge as a declined conversion
# (base#1137); an exit here would turn that containment into a crash.
#
# Event ids are `<ns>_unprovisionable`, `<ns>_building` and
# `<ns>_build_failed`, under service `<ns>`; each tool registers its own
# in log-events.txt. The display text is the tool's, from the callback
#   _<ns>_tool_image_display <kind> <image> <path> <rc> <builder-out> <lib>
# with <kind> one of no_root, no_dockerfile, no_context, unhashable,
# building, build_failed.
#
# An optional `_<ns>_tool_image_preflight <image>` runs after the tag is
# derived and before the image is inspected or built; non-zero (having
# said why) stops the resolve.

if [[ -n "${_DOCKER_LIB_TOOL_IMAGE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_TOOL_IMAGE_SOURCED=1

_tool_image_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_tool_image_dir}/log.sh"
# The content-digest derivation, shared with the tooling tag and the image
# retention policy rather than reimplemented (base#1169).
# shellcheck source=dist/script/docker/lib/project_reclaim.sh
source "${_tool_image_dir}/project_reclaim.sh"
unset _tool_image_dir

declare -gA _TOOL_IMAGE_REPO=() _TOOL_IMAGE_LIB=() _TOOL_IMAGE_DOCKERFILE=() \
  _TOOL_IMAGE_CONTEXT=() _TOOL_IMAGE_OVERRIDE=() _TOOL_IMAGE_MEMO=() \
  _TOOL_IMAGE_ARGS=()

# tool_image_define <ns> <repo> <lib_dir> <dockerfile_rel> <context_rel>
#                   <override_var> <memo_var> [build_arg...]
#   Record the profile of tool <ns>. <dockerfile_rel> and <context_rel>
#   are relative to the subtree root found above <lib_dir>. The build args
#   are passed to `docker build` between `-f <dockerfile>` and the context.
tool_image_define() {
  local _ns="${1:?"${FUNCNAME[0]}: missing ns"}"
  _TOOL_IMAGE_REPO[${_ns}]="${2:?"${FUNCNAME[0]}: missing repo"}"
  _TOOL_IMAGE_LIB[${_ns}]="${3:?"${FUNCNAME[0]}: missing lib dir"}"
  _TOOL_IMAGE_DOCKERFILE[${_ns}]="${4:?"${FUNCNAME[0]}: missing dockerfile"}"
  _TOOL_IMAGE_CONTEXT[${_ns}]="${5:?"${FUNCNAME[0]}: missing context"}"
  _TOOL_IMAGE_OVERRIDE[${_ns}]="${6:?"${FUNCNAME[0]}: missing override var"}"
  _TOOL_IMAGE_MEMO[${_ns}]="${7:?"${FUNCNAME[0]}: missing memo var"}"
  shift 7
  # One string, NUL-free, re-split by tool_image_ensure; build args carry
  # no whitespace in either profile, and %q keeps one that does intact.
  local _a _args=""
  for _a in "$@"; do
    _args+="$(printf '%q' "${_a}") "
  done
  _TOOL_IMAGE_ARGS[${_ns}]="${_args% }"
}

# _tool_image_display <ns> <kind> [image] [path] [rc] [out]
#   The tool's display text for <kind>, as `display=<text>`.
_tool_image_display() {
  local _ns="$1" _kind="$2"
  printf 'display=%s' "$("_${_ns}_tool_image_display" "${_kind}" "${3-}" \
    "${4-}" "${5-}" "${6-}" "${_TOOL_IMAGE_LIB[${_ns}]}")"
}

# tool_image_subtree_root <ns>
#   The subtree root the shipped build inputs sit under: the directory
#   carrying the subtree markers `.version` + `dist/` above the tool's lib.
#   The same walk init.sh and upgrade.sh do, and for the same reason --
#   the prefix is the consumer's to name, so nothing may spell `.base`.
#   Non-zero and silent when there is none: the caller refuses.
tool_image_subtree_root() {
  local _dir="${_TOOL_IMAGE_LIB[${1:?"${FUNCNAME[0]}: missing ns"}]}"
  while [[ "${_dir}" != "/" ]]; do
    if [[ -f "${_dir}/.version" && -d "${_dir}/dist" ]]; then
      printf '%s\n' "${_dir}"
      return 0
    fi
    _dir="$(cd -- "${_dir}/.." && pwd -P)" || return 1
  done
  return 1
}

# _tool_image_under_root <ns> <rel>
#   <rel> under the subtree root of <ns>, or non-zero when there is none.
_tool_image_under_root() {
  local _root
  _root="$(tool_image_subtree_root "$1")" || return 1
  printf '%s/%s\n' "${_root}" "$2"
}

# tool_image_dockerfile <ns>
#   The shipped Dockerfile of <ns>, or non-zero when the subtree root
#   cannot be found.
tool_image_dockerfile() {
  local _ns="${1:?"${FUNCNAME[0]}: missing ns"}"
  _tool_image_under_root "${_ns}" "${_TOOL_IMAGE_DOCKERFILE[${_ns}]}"
}

# _tool_image_context <ns> -- the build context of <ns>, or non-zero.
_tool_image_context() {
  _tool_image_under_root "$1" "${_TOOL_IMAGE_CONTEXT[$1]}"
}

# tool_image_derive <ns>
#   `<repo>:<12 hex>` over the Dockerfile and every file it COPYs from the
#   profile's build context. Twelve digits for the reason the tooling tag
#   takes twelve: readable in `docker images`, and the collision surface
#   is the handful of checkouts on one host.
#
#   Every way of not getting an answer is a refusal, never a fallback to a
#   bare literal: a literal resolves to whatever a sibling checkout last
#   built under that name.
tool_image_derive() {
  local _ns="${1:?"${FUNCNAME[0]}: missing ns"}"
  local _dockerfile _context _hash=""
  if ! _dockerfile="$(tool_image_dockerfile "${_ns}")"; then
    _log_err "${_ns}" "${_ns}_unprovisionable" \
      "$(_tool_image_display "${_ns}" no_root)" \
      "lib=${_TOOL_IMAGE_LIB[${_ns}]}"
    return 1
  fi
  if [[ ! -f "${_dockerfile}" ]]; then
    _log_err "${_ns}" "${_ns}_unprovisionable" \
      "$(_tool_image_display "${_ns}" no_dockerfile "" "${_dockerfile}")" \
      "path=${_dockerfile}"
    return 1
  fi
  _context="$(_tool_image_context "${_ns}")" || return 1
  if [[ ! -d "${_context}" ]]; then
    _log_err "${_ns}" "${_ns}_unprovisionable" \
      "$(_tool_image_display "${_ns}" no_context "" "${_context}")" \
      "path=${_context}"
    return 1
  fi
  if ! _hash="$(_reclaim_tool_dockerfile_hash "${_dockerfile}" "${_context}")" \
    || [[ -z "${_hash}" ]]; then
    _log_err "${_ns}" "${_ns}_unprovisionable" \
      "$(_tool_image_display "${_ns}" unhashable "" "${_dockerfile}")" \
      "path=${_dockerfile}"
    return 1
  fi
  printf '%s:%s\n' "${_TOOL_IMAGE_REPO[${_ns}]}" "${_hash:0:12}"
}

# tool_image_ensure <ns> <image>
#   Make <image> exist. Present is the whole answer -- the tag is keyed to
#   its inputs, so a tag that is there was built from these inputs.
#
#   A failed build is reported with the builder's own output folded onto
#   one line -- it reaches the log as an attribute value, and the text sink
#   renders a body on one line -- and answers non-zero, without exiting.
tool_image_ensure() {
  local _ns="${1:?"${FUNCNAME[0]}: missing ns"}"
  local _image="${2:?"${FUNCNAME[0]}: missing image"}"
  docker image inspect "${_image}" > /dev/null 2>&1 && return 0

  local _dockerfile _context _out="" _rc=0
  _dockerfile="$(tool_image_dockerfile "${_ns}")" || return 1
  _context="$(_tool_image_context "${_ns}")" || return 1
  local -a _args=()
  eval "_args=(${_TOOL_IMAGE_ARGS[${_ns}]})"

  # stderr, not the INFO default of stdout: a caller's stdout is the
  # stream it reads as its answer (base#1400).
  _log_info "${_ns}" "${_ns}_building" \
    "$(_tool_image_display "${_ns}" building "${_image}" "${_dockerfile}")" \
    "image=${_image}" \
    "path=${_dockerfile}" >&2

  _out="$(docker build -t "${_image}" -f "${_dockerfile}" "${_args[@]}" \
    "${_context}" 2>&1)" || _rc=$?
  (( _rc == 0 )) && return 0

  _out="${_out//$'\n'/ }"
  _log_err "${_ns}" "${_ns}_build_failed" \
    "$(_tool_image_display "${_ns}" build_failed "${_image}" "${_dockerfile}" \
      "${_rc}" "${_out}")" \
    "image=${_image}" \
    "path=${_dockerfile}" \
    "status=${_rc}"
  return 1
}

# tool_image_resolve <ns>
#   Set the profile's memo variable to the image <ns> runs. A non-empty
#   override variable wins verbatim and is neither inspected nor built
#   (set but empty counts as unset); otherwise the memo answers, and
#   failing that the tag is derived, provisioned when absent, and
#   memoised. Prints nothing; answers non-zero, having said why.
tool_image_resolve() {
  local _ns="${1:?"${FUNCNAME[0]}: missing ns"}"
  local _override="${_TOOL_IMAGE_OVERRIDE[${_ns}]}"
  local _memo="${_TOOL_IMAGE_MEMO[${_ns}]}"
  if [[ -n "${!_override:-}" ]]; then
    printf -v "${_memo}" '%s' "${!_override}"
    return 0
  fi
  [[ -n "${!_memo:-}" ]] && return 0
  local _image
  _image="$(tool_image_derive "${_ns}")" || return 1
  if declare -F "_${_ns}_tool_image_preflight" > /dev/null; then
    "_${_ns}_tool_image_preflight" "${_image}" || return 1
  fi
  tool_image_ensure "${_ns}" "${_image}" || return 1
  printf -v "${_memo}" '%s' "${_image}"
  return 0
}
