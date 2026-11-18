#!/usr/bin/env bash
# config_gen.sh -- host-side provisioning of the config generator image
# (base#1466, ADR-00000039).
#
# The config generator ships as a Go module under dockerfile/config-gen
# with dockerfile/Dockerfile.config-gen, inside the subtree a consumer
# vendors. config_gen_resolve names its image `config-gen:<12 hex>`, a
# digest of the Dockerfile and the module (base#1169's identity rule),
# builds the `final` stage once when it is absent, and memoises the answer
# in _CONFIG_GEN_RESOLVED for the rest of the shell. The steps are
# lib/tool_image.sh's, shared with the TOML bridge.
#
# THE BUILD CONTEXT IS dockerfile/config-gen, the module itself (the
# Dockerfile's `COPY . .`), not the Dockerfile's directory: a digest over
# dockerfile/ would move the tag on every sibling tool's edit.
#
# CONFIG_GEN_IMAGE, when non-empty, wins verbatim and is neither inspected
# nor built; set but empty counts as unset, as TOML_BRIDGE_IMAGE does.

_config_gen_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/tool_image.sh
source "${_config_gen_dir}/tool_image.sh"

tool_image_define config_gen config-gen "${_config_gen_dir}" \
  dockerfile/Dockerfile.config-gen dockerfile/config-gen CONFIG_GEN_IMAGE \
  _CONFIG_GEN_RESOLVED --target final
unset _config_gen_dir

# The image config_gen_resolve last resolved. Kept across a re-source of
# this file, so a second source does not cost a second inspect.
_CONFIG_GEN_RESOLVED="${_CONFIG_GEN_RESOLVED-}"

# _config_gen_tool_image_display <kind> <image> <path> <rc> <out> <lib>
#   The config generator's wording for each record tool_image.sh writes.
_config_gen_tool_image_display() {
  case "$1" in
    no_root)
      printf '%s' "cannot name the config generator image: no subtree root (a directory carrying .version and dist/) above ${6}, so the shipped dockerfile/Dockerfile.config-gen cannot be found. Re-vendor the subtree, or pin an image with CONFIG_GEN_IMAGE." ;;
    no_dockerfile)
      printf '%s' "cannot build the config generator image: ${3} is missing from the vendored subtree. Re-run the upgrade so the subtree is complete, or pin an image with CONFIG_GEN_IMAGE." ;;
    no_context)
      printf '%s' "cannot build the config generator image: its build context ${3} (the Go module) is missing from the vendored subtree. Re-run the upgrade so the subtree is complete, or pin an image with CONFIG_GEN_IMAGE." ;;
    unhashable)
      printf '%s' "cannot name the config generator image: a build input of ${3} could not be resolved or read (the refusal above names it). A digest taken over the rest would name an image it does not describe." ;;
    building)
      printf '%s' "building the config generator image ${2} from ${3} (target final). Once per revision of the generator: a later run whose build inputs are identical resolves this same tag and skips the build." ;;
    build_failed)
      printf '%s' "the config generator image ${2} could not be built from ${3} (docker build exited ${4}). Builder said: ${5}. Fix the cause and re-run, or pin an image with CONFIG_GEN_IMAGE." ;;
  esac
}

# _config_gen_tool_image_preflight <image>
#   Without docker the build would fail with "command not found" folded
#   into a build_failed record that does not name the cause; name it.
_config_gen_tool_image_preflight() {
  if ! command -v docker > /dev/null 2>&1; then
    _log_err config_gen config_gen_docker_missing \
      "display=cannot provision the config generator image ${1}: docker is not on PATH. Install docker, or pin an image with CONFIG_GEN_IMAGE." \
      "image=${1}"
    return 1
  fi
}

# config_gen_resolve
#   Set _CONFIG_GEN_RESOLVED to the config generator image, provisioning
#   it when it is this checkout's derived tag and is absent. Prints
#   nothing -- call it directly, never through $(...), or the memo is lost
#   with the subshell. Answers 1, having said why, when it cannot; it
#   never exits the caller.
config_gen_resolve() {
  tool_image_resolve config_gen
}

# _config_gen_decode_frames <errfile>
#   Re-emit each 8-field NUL frame the binary wrote to <errfile>
#   (tag, severity, event, file, line, col, key, text) as one config_gen
#   log record (base#1470).
_config_gen_decode_frames() {
  local -a _f=()
  local _field
  while IFS= read -r -d '' _field; do
    _f+=("${_field}")
    if ((${#_f[@]} == 8)); then
      _log_err config_gen "${_f[2]}" "display=${_f[7]}" \
        "file=${_f[3]}" "line=${_f[4]}" "col=${_f[5]}" "key=${_f[6]}" \
        "text=${_f[7]}"
      _f=()
    fi
  done < "$1"
}

# config_gen_tables <file> <outvar>
#   Run `config-gen tables` on <file> (base#1470). <outvar> is cleared on
#   entry, so a failed run publishes nothing; the binary's status is the
#   answer and its diagnostics are re-emitted.
config_gen_tables() {
  local -n _cgt_out="$2"
  _cgt_out=""
  config_gen_resolve || return 1
  # A stat only: the host never opens the path, and a missing src must
  # not reach `docker run` (base#1470).
  if [[ ! -e "$1" && ! -L "$1" ]]; then
    _log_err config_gen no_such_file \
      "display=config_gen_tables: no such file: $1" "file=$1"
    return 1
  fi
  local _tmp _rc=0
  _tmp="$(mktemp -d)"
  docker run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$(pwd -P)/$1,dst=/in/f,readonly" \
    "${_CONFIG_GEN_RESOLVED}" tables --name "$1" /in/f \
    > "${_tmp}/out" 2> "${_tmp}/err" || _rc=$?
  _config_gen_decode_frames "${_tmp}/err"
  if ((_rc == 0)); then
    # A bash variable cannot hold a NUL, so a table list carrying one is
    # refused instead of published truncated (base#1470).
    local _chunk _list="" _n=0
    while IFS= read -r -d '' _chunk; do
      _list+="${_chunk}"
      _n=$((_n + 1))
    done < "${_tmp}/out"
    _list+="${_chunk}"
    if ((_n > 0)); then
      _log_err config_gen config_gen_output_nul \
        "display=config_gen_tables: the table list of $1 holds a NUL byte, which a shell variable cannot carry" \
        "file=$1"
      _rc=1
    else
      _cgt_out="${_list}"
    fi
  fi
  rm -rf -- "${_tmp}"
  return "${_rc}"
}
