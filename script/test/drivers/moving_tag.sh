#!/usr/bin/env bash
# drivers/moving_tag.sh - "nothing internal consumes a moving test-tools tag"
# per-tool driver for the self-test dispatcher (base#1647).
#
# Sourced library (no main): provides _run_moving_tag. References
# ${REPO_ROOT} (a global exported by test.sh) and _die. Follows
# drivers/arch_literal.sh conventions.
#
# Why: the release workflow publishes test-tools as :<ver> always, :latest
# for a non-prerelease tag and :main from main. :latest and :main are
# conveniences for humans and bootstrap; an internal build that resolves the
# tooling image by one of them gets whatever was pushed last (base#1122).

# ── Moving test-tools tag lint ───────────────────────────────────────────────

# The scanned trees and files, repo-root-relative.
readonly _MOVING_TAG_SCAN_ROOTS=(
  '.github' 'dist' 'dockerfile' 'script'
  'compose.yaml' 'justfile' 'init.sh' 'upgrade.sh'
)

# The unanchored .gitignore names, skipped wherever they sit inside a root:
# a local-only ignored file would fail the lint locally and pass on CI.
readonly _MOVING_TAG_SKIP_FILES=('.env' '.env.local' '.setup.conf.local')
readonly _MOVING_TAG_SKIP_DIRS=(
  'log' 'coverage' 'coverage-shards' 'multi_run'
  '.config-gen-bin' '__pycache__' '.prev-release'
)

# A test-tools reference carrying a moving tag, qualified
# (ghcr.io/ycpss91255-docker/test-tools) or under any other prefix
# (${ORG}/test-tools): test-tools after line start or a non-name character.
readonly _MOVING_TAG_RE='(^|[^A-Za-z0-9_.-])test-tools:(latest|main)([^A-Za-z0-9_.-]|$)'

# The qualified repository with no tag or digest: a base that a later line
# suffixes ("${IMAGE}:latest") carries no test-tools text on the tag line.
readonly _MOVING_TAG_UNTAGGED_RE='ghcr\.io/ycpss91255-docker/test-tools([^A-Za-z0-9_.:@/-]|$)'

# A test-tools tag built from a variable or a format (:${ver}, :%s): the
# value is decided at run time, so it is not a pin.
readonly _MOVING_TAG_INDIRECT_RE='(^|[^A-Za-z0-9_.-])test-tools:[A-Za-z0-9_.-]*[$%]'

# A test-tools tag taken from a workflow input (base#1122: the input
# defaulted to "latest"). The input name is BASH_REMATCH[1].
readonly _MOVING_TAG_INPUT_RE='test-tools:\$\{\{[[:space:]]*inputs\.([A-Za-z0-9_-]+)[[:space:]]*\}\}'
# A bare YAML key line (an input name) and a moving default under it.
readonly _MOVING_TAG_KEY_RE='^[[:space:]]*([A-Za-z0-9_-]+):[[:space:]]*$'
readonly _MOVING_TAG_DEFAULT_RE='^[[:space:]]*default:[[:space:]]*["'"'"']?(latest|main)["'"'"']?[[:space:]]*$'

_run_moving_tag() {
  echo "--- Running moving test-tools tag lint ---"
  local _violations=0
  local _root _abs_root _file _rel _line _lineno

  local _name
  local -a _prune=() _skip=()
  for _name in "${_MOVING_TAG_SKIP_DIRS[@]}"; do
    [[ "${#_prune[@]}" -eq 0 ]] || _prune+=(-o)
    _prune+=(-name "${_name}")
  done
  for _name in "${_MOVING_TAG_SKIP_FILES[@]}"; do
    _skip+=(! -name "${_name}")
  done

  local -a _files=()
  for _root in "${_MOVING_TAG_SCAN_ROOTS[@]}"; do
    _abs_root="${REPO_ROOT}/${_root}"
    [[ -e "${_abs_root}" ]] || continue
    while IFS= read -r -d '' _file; do
      _files+=("${_file}")
    done < <(find "${_abs_root}" -type d \( "${_prune[@]}" \) -prune \
      -o -type f ! -name '*.md' "${_skip[@]}" -print0 2>/dev/null | sort -z)
  done

  local _key _moving_inputs
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    # Inputs this file declares with a moving default, as " name name ".
    _key=""
    _moving_inputs=" "
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      if [[ "${_line}" =~ ${_MOVING_TAG_KEY_RE} ]]; then
        _key="${BASH_REMATCH[1]}"
      elif [[ -n "${_key}" && "${_line}" =~ ${_MOVING_TAG_DEFAULT_RE} ]]; then
        _moving_inputs+="${_key} "
      fi
    done < "${_file}"
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))
      if [[ "${_line}" =~ ${_MOVING_TAG_RE} ]]; then
        printf '%s:%d: moving -- %s\n' "${_rel}" "${_lineno}" "${_line}"
        _violations=$(( _violations + 1 ))
      elif [[ "${_line}" =~ ${_MOVING_TAG_UNTAGGED_RE} ]]; then
        printf '%s:%d: untagged -- %s\n' "${_rel}" "${_lineno}" "${_line}"
        _violations=$(( _violations + 1 ))
      elif [[ "${_line}" =~ ${_MOVING_TAG_INPUT_RE} \
        && "${_moving_inputs}" == *" ${BASH_REMATCH[1]} "* ]]; then
        printf '%s:%d: input-default -- %s\n' "${_rel}" "${_lineno}" "${_line}"
        _violations=$(( _violations + 1 ))
      elif [[ "${_line}" =~ ${_MOVING_TAG_INDIRECT_RE} ]]; then
        printf '%s:%d: indirect -- %s\n' "${_rel}" "${_lineno}" "${_line}"
        _violations=$(( _violations + 1 ))
      fi
    done < "${_file}"
  done

  if [[ "${_violations}" -gt 0 ]]; then
    _die ci_moving_tag \
      "${_violations} internal reference(s) to a moving or missing test-tools tag (:latest / :main / untagged). Pin the consumer to :<ver>; :latest and :main are human and bootstrap conveniences only (base#1647)."
    return 1
  fi
  echo "moving test-tools tag lint: clean"
}
