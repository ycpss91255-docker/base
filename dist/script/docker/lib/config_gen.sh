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

# _config_gen_decode_frames <errfile> <name>
#   Re-emit each 8-field NUL frame the binary wrote to <errfile>
#   (tag, severity, event, file, line, col, key, text) as one config_gen
#   log record (base#1470). A frame that is not one -- a tag other than D,
#   an event id the registry does not know, fewer than 8 fields, or a
#   last field cut off before its NUL -- is refused as
#   config_gen_diag_malformed with reason=. Unframed text -- ahead of a
#   frame's tag, or left after the last frame with no NUL -- is forwarded
#   once as config_gen_stray_stderr; the decoder cannot tell whether
#   docker or the binary wrote it. Answers 1 when <errfile> held no frame.
_config_gen_decode_frames() {
  local -a _f=()
  local _field="" _n=0
  while IFS= read -r -d '' _field; do
    # Unframed text on the stream (such as a platform WARNING line) runs
    # into the next frame's tag; it is forwarded once and the frame keeps
    # its D tag (base#1470).
    if ((${#_f[@]} == 0)) && [[ "${_field}" == *$'\n'D ]]; then
      _config_gen_stray_stderr "${_field%$'\n'D}" "$2"
      _field=D
    fi
    _f+=("${_field}")
    _field=""
    if ((${#_f[@]} == 8)); then
      if [[ "${_f[0]}" != D ]]; then
        _config_gen_diag_malformed tag "$2"
      elif ! _log_is_registered "${_f[2]}"; then
        _config_gen_diag_malformed unregistered "$2"
      else
        _log_err config_gen "${_f[2]}" "display=${_f[7]}" \
          "file=${_f[3]}" "line=${_f[4]}" "col=${_f[5]}" "key=${_f[6]}" \
          "text=${_f[7]}"
      fi
      _f=()
      _n=$((_n + 1))
    fi
  done < "$1"
  # A started frame left open: its last field lacks a NUL (truncated) or
  # it has fewer than 8 fields (count). With no frame open, bytes the
  # failed read left in _field carry no NUL: they are unframed text,
  # forwarded once, never a frame (base#1470).
  if ((${#_f[@]} == 0)); then
    [[ -z "${_field}" ]] || _config_gen_stray_stderr "${_field%$'\n'}" "$2"
  else
    if [[ -n "${_field}" ]]; then
      _config_gen_diag_malformed truncated "$2"
    else
      _config_gen_diag_malformed count "$2"
    fi
    _n=$((_n + 1))
  fi
  ((_n > 0))
}

# _config_gen_stray_stderr <text> <name>
#   Forward unframed stderr <text> (no frame says who wrote it) as one
#   config_gen_stray_stderr record; <name> is the file config_gen_tables
#   was given (base#1470).
_config_gen_stray_stderr() {
  _log_err config_gen config_gen_stray_stderr \
    "display=config_gen_tables: unframed stderr for ${2}: ${1}" \
    "file=$2" "text=$1"
}

# _config_gen_diag_malformed <reason> <name>
#   The refusal for a diagnostic stream that is not an 8-field D frame;
#   <name> is the file config_gen_tables was given (base#1470).
_config_gen_diag_malformed() {
  _log_err config_gen config_gen_diag_malformed \
    "display=config_gen_tables: the diagnostic stream for ${2} is not an 8-field NUL frame (${1})" \
    "file=${2}" "reason=$1"
}

# config_gen_tables <file> <outvar>
#   Run `config-gen tables` on <file> (base#1470). <outvar> is cleared on
#   entry, so a failed run publishes nothing; the binary's status is the
#   answer and its diagnostics are re-emitted.
config_gen_tables() {
  # Exactly <file> and an identifier <outvar>, checked before the nameref
  # binds; rc 2 is the binary's own usage status. A nameref binds to the
  # nearest variable of its name, so every local here is under _cgt_ and
  # an outvar under that prefix is refused: no other name can resolve to
  # one of this function's locals (base#1470).
  if (($# != 2)) || [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || [[ "$2" == _cgt_* ]]; then
    _log_err config_gen config_gen_usage_invalid \
      "display=config_gen_tables: usage: config_gen_tables <file> <outvar>"
    return 2
  fi
  local -n _cgt_out="$2"
  _cgt_out=""
  config_gen_resolve || return 1
  # A stat first: a missing file must not reach `docker run` (base#1470).
  if [[ ! -e "$1" && ! -L "$1" ]]; then
    _log_err config_gen no_such_file \
      "display=config_gen_tables: no such file: $1" "file=$1"
    return 1
  fi
  # The file is read on the host and handed over on stdin, so a name that
  # is not a regular file, or that the caller cannot read, is refused here
  # with the frames the binary gives them (base#1937).
  if [[ ! -f "$1" ]]; then
    _log_err config_gen config_gen_input_not_regular \
      "display=config_gen_tables: $1 is not a regular file" "file=$1"
    return 1
  fi
  if ! { : < "$1"; } 2> /dev/null; then
    _log_err config_gen config_gen_input_unreadable \
      "display=config_gen_tables: $1 cannot be read" "file=$1"
    return 1
  fi
  local _cgt_tmp _cgt_rc=0
  _cgt_tmp="$(mktemp -d)"
  # The file goes in on stdin, as toml_bridge_parse feeds the bridge: a
  # caller under docker.sock names a path only it can see, which the host
  # daemon cannot bind-mount (base#1937).
  # shellcheck disable=SC2094 # "$1" is only the --name label here
  docker run --rm -i --user "$(id -u):$(id -g)" \
    "${_CONFIG_GEN_RESOLVED}" tables --name "$1" - \
    < "$1" > "${_cgt_tmp}/out" 2> "${_cgt_tmp}/err" || _cgt_rc=$?
  # A non-zero status with no diagnostic frame is refused on what is
  # observed: the status, and no frame. Any such run lands here, whether
  # docker or the binary wrote its stderr (base#1470).
  if ! _config_gen_decode_frames "${_cgt_tmp}/err" "$1" && ((_cgt_rc != 0)); then
    _log_err config_gen config_gen_run_failed \
      "display=config_gen_tables: the run for $1 failed with status ${_cgt_rc} and no diagnostic frame" \
      "file=$1" "status=${_cgt_rc}"
  fi
  if ((_cgt_rc == 0)); then
    # A bash variable cannot hold a NUL, so a table list carrying one is
    # refused instead of published truncated: `read -d ''` succeeds only
    # when it meets a NUL, and at EOF leaves the whole list in _cgt_list
    # (base#1470).
    local _cgt_list
    if IFS= read -r -d '' _cgt_list < "${_cgt_tmp}/out"; then
      _log_err config_gen config_gen_output_nul \
        "display=config_gen_tables: the table list of $1 holds a NUL byte, which a shell variable cannot carry" \
        "file=$1"
      _cgt_rc=1
    else
      _cgt_out="${_cgt_list}"
    fi
  fi
  rm -rf -- "${_cgt_tmp}"
  return "${_cgt_rc}"
}
