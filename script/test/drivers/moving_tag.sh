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

# A test-tools tag from a variable whose default is latest/main
# (${TAG:-latest}, ${TAG:=main}): unset, it resolves to the moving tag.
readonly _MOVING_TAG_VAR_DEFAULT_RE='(^|[^A-Za-z0-9_.-])test-tools:[A-Za-z0-9_.-]*\$\{[A-Za-z0-9_]+:?[-=](latest|main)\}'

# A test-tools tag taken from a workflow input (base#1122: the input
# defaulted to "latest"). The input name is BASH_REMATCH[1].
readonly _MOVING_TAG_INPUT_RE='test-tools:\$\{\{[[:space:]]*inputs\.([A-Za-z0-9_-]+)[[:space:]]*\}\}'
# A bare YAML key line (an input name) and a moving default under it.
readonly _MOVING_TAG_KEY_RE='^[[:space:]]*([A-Za-z0-9_-]+):[[:space:]]*$'
readonly _MOVING_TAG_DEFAULT_RE='^[[:space:]]*default:[[:space:]]*["'"'"']?(latest|main)["'"'"']?[[:space:]]*$'

# The allow-list: one '<path>|<kind>|<scope>|<count>|<token>|<reason>' entry
# per sanctioned occurrence. An occurrence is suppressed only when its path,
# kind and scope match an entry and its line carries the entry's token.
# Scope 'comment': the line starts with optional blanks then '#'.
# Scope 'line:<anchor>': the line contains the fixed string <anchor>.
# An entry covers at most <count> occurrences: one more is a new consumer.
readonly _MOVING_TAG_ALLOWLIST=()

# _moving_tag_allowlist -- print the allow-list, one entry per line.
_moving_tag_allowlist() {
  [[ "${#_MOVING_TAG_ALLOWLIST[@]}" -eq 0 ]] \
    || printf '%s\n' "${_MOVING_TAG_ALLOWLIST[@]}"
}

# _moving_tag_allowed <rel> <kind> <line> <entry>... -- 0 when an entry
# covers this occurrence; sets _MOVING_TAG_HIT to that entry's index.
_moving_tag_allowed() {
  local _rel="${1}" _kind="${2}" _line="${3}"
  shift 3
  # A tag fed by an input or a variable defaulting to latest/main is the
  # base#1122 regression itself: no entry suppresses it.
  [[ "${_kind}" != input-default && "${_kind}" != moving-default ]] \
    || return 1
  local _entry _path _ekind _scope _count _token _reason _i=-1
  for _entry in "$@"; do
    _i=$(( _i + 1 ))
    _MOVING_TAG_HIT="${_i}"
    IFS='|' read -r _path _ekind _scope _count _token _reason <<< "${_entry}"
    [[ "${_path}" == "${_rel}" && "${_ekind}" == "${_kind}" ]] || continue
    [[ -n "${_token}" && "${_line}" == *"${_token}"* ]] || continue
    case "${_scope}" in
      comment) [[ "${_line}" =~ ^[[:space:]]*# ]] && return 0 ;;
      line:?*) [[ "${_line}" == *"${_scope#line:}"* ]] && return 0 ;;
    esac
  done
  return 1
}

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

  local -a _allow=()
  local _entry
  while IFS= read -r _entry; do
    [[ -n "${_entry}" ]] && _allow+=("${_entry}")
  done < <(_moving_tag_allowlist)

  # Per entry: occurrences it matched, and where.
  local -a _hits=() _hit_at=()
  local _MOVING_TAG_HIT

  local _key _moving_inputs _kind
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
      _kind=""
      if [[ "${_line}" =~ ${_MOVING_TAG_RE} ]]; then
        _kind=moving
      elif [[ "${_line}" =~ ${_MOVING_TAG_UNTAGGED_RE} ]]; then
        _kind=untagged
      elif [[ "${_line}" =~ ${_MOVING_TAG_VAR_DEFAULT_RE} ]]; then
        _kind=moving-default
      elif [[ "${_line}" =~ ${_MOVING_TAG_INPUT_RE} \
        && "${_moving_inputs}" == *" ${BASH_REMATCH[1]} "* ]]; then
        _kind=input-default
      elif [[ "${_line}" =~ ${_MOVING_TAG_INDIRECT_RE} ]]; then
        _kind=indirect
      fi
      [[ -n "${_kind}" ]] || continue
      if _moving_tag_allowed "${_rel}" "${_kind}" "${_line}" "${_allow[@]}"; then
        _hits[_MOVING_TAG_HIT]=$(( ${_hits[_MOVING_TAG_HIT]:-0} + 1 ))
        _hit_at[_MOVING_TAG_HIT]+=" ${_rel}:${_lineno}"
        continue
      fi
      printf '%s:%d: %s -- %s\n' "${_rel}" "${_lineno}" "${_kind}" "${_line}"
      _violations=$(( _violations + 1 ))
    done < "${_file}"
  done

  local _i _path _ekind _scope _count _token _reason
  for _i in "${!_allow[@]}"; do
    IFS='|' read -r _path _ekind _scope _count _token _reason <<< "${_allow[_i]}"
    if [[ "${_hits[_i]:-0}" -gt "${_count}" ]]; then
      printf '%s: allow-list entry pins %s, saw %s --%s\n' \
        "${_path}" "${_count}" "${_hits[_i]}" "${_hit_at[_i]}"
      _violations=$(( _violations + 1 ))
    elif [[ "${_hits[_i]:-0}" -lt "${_count}" ]]; then
      printf '%s: allow-list entry is stale: pins %s, saw %s; update the entry and its reason in the same commit\n' \
        "${_path}" "${_count}" "${_hits[_i]:-0}"
      _violations=$(( _violations + 1 ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    _die ci_moving_tag \
      "${_violations} internal reference(s) to a moving or missing test-tools tag (:latest / :main / untagged). Pin the consumer to :<ver>; :latest and :main are human and bootstrap conveniences only (base#1647)."
    return 1
  fi
  echo "moving test-tools tag lint: clean"
}
