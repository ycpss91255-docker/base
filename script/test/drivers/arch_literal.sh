#!/usr/bin/env bash
# drivers/arch_literal.sh - "no bare architecture literal in a shipped
# Dockerfile" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_arch_literal, the mechanical half of the "architecture comes from
# TARGETARCH, never a literal" convention the shipped template Dockerfile
# documents.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/home_literal.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# Why: buildx builds ONE Dockerfile once per `--platform` and injects
# TARGETARCH ("amd64" / "arm64") into any stage that declares
# `ARG TARGETARCH`. A stage that instead writes the architecture into a
# string produces the SAME artifact for every platform -- the amd64 binary
# lands inside the arm64 image variant and only fails when someone runs it
# ("Exec format error"). The assumption does not announce itself: it is a
# string literal, and nothing reports which ones leaked. Separate
# per-architecture Dockerfiles trade "one place forgotten" for "two places
# out of sync"; expressing the target is Docker's own documented approach.
#
# What this lint can and cannot check: whether a repo SHOULD build a given
# platform at all, and whether emulation or cross-compilation is the right
# way to reach it, are judgement calls this driver does not pretend to
# decide. What IS mechanical is the literal in a shipped Dockerfile, and
# that is exactly what this scans for.
#
# Scope: DOCKERFILES under the trees that reach an image -- dist/ (the
# shipped template) plus the repo-root dockerfile/ tree (the test-tools and
# smoke images). Deliberately not shell scripts, workflows or docs: a
# wrapper naming a buildx platform list (`linux/amd64,linux/arm64`) and a
# narrative describing the failure are both legitimate, and TARGETARCH is a
# Dockerfile mechanism a shell script cannot read anyway. Scanning them
# would be the strict direction, which is how a lint gets muted.
#
# THE WRINKLE, and why the opt-out is not optional: TARGETARCH's values are
# Docker's, while upstream release assets frequently use others: the
# ShellCheck project publishes linux.x86_64 / linux.aarch64, and hadolint
# publishes Linux-x86_64 / Linux-arm64. ${TARGETARCH} cannot be dropped into a
# download URL directly; a mapping layer is normally required, and a
# CORRECT mapping table contains both spellings by construction. A lint
# that refused every architecture token would therefore fire on the correct
# implementation of the very thing it asks for.
#
# Two opt-outs, both requiring a stated reason after `--` (an opt-out
# without one is an off switch):
#
#   1. A marked mapping block, for the `case` that does the translation:
#        # arch-literal-lint: allow-begin -- <why>
#        ...
#        # arch-literal-lint: allow-end
#      Region markers sit OUTSIDE the instruction they bracket, so a
#      multi-line RUN needs no comment lines between its continuations.
#   2. A per-line allow, for the single line that needs one:
#        ARG SC_ARCH="x86_64"  # arch-literal-lint: allow -- <why>
#
# Unbalanced region markers (an unterminated begin, an unmatched end) fail
# the lint -- a silently swallowed region would re-open exactly the hole
# this guard closes.

# ── Bare architecture literal lint ───────────────────────────────────────────

# The scanned trees, repo-root-relative. Each must exist AND hold at least
# one Dockerfile: an empty match set would make the scan pass vacuously.
readonly _ARCH_LITERAL_SCAN_ROOTS=('dist' 'dockerfile')

# Which files in those trees are Dockerfiles. Covers the two shipped
# spellings (`Dockerfile`, `Dockerfile.<variant>`) plus the `<name>.Dockerfile`
# form some editors prefer.
readonly _ARCH_LITERAL_FILE_GLOBS=('Dockerfile' 'Dockerfile.*' '*.Dockerfile')

# The architecture tokens, in the spellings that actually appear in the
# wild: Docker's own (TARGETARCH / --platform), uname's, and the
# release-asset variants upstreams publish. Matched case-insensitively (the
# line is lowercased first) because `Linux-arm64` is the same assumption as
# `linux-arm64`, and bounded by a non-word character on each side so
# `TARGETARCH`, `arch`, and a sha256 digest never match.
readonly _ARCH_LITERAL_TOKENS=(
  'amd64'
  'arm64v8'
  'arm64'
  'arm32v7'
  'armv7l'
  'armv7'
  'armhf'
  'aarch64'
  'x86_64'
  'x86-64'
  'i386'
  'i686'
  'ppc64le'
  's390x'
  'riscv64'
)

# Marker text for the two opt-outs (see the header note). allow-begin /
# allow-end are tested BEFORE the per-line allow, so the shared 'allow'
# prefix cannot make a region marker read as a per-line one.
readonly _ARCH_LITERAL_ALLOW_BEGIN='arch-literal-lint: allow-begin'
readonly _ARCH_LITERAL_ALLOW_END='arch-literal-lint: allow-end'
readonly _ARCH_LITERAL_ALLOW_LINE='arch-literal-lint: allow'

# _arch_literal_regex -- the alternation, assembled from the token table so
# the list stays one readable column.
_arch_literal_regex() {
  local _joined
  _joined="$(printf '%s|' "${_ARCH_LITERAL_TOKENS[@]}")"
  printf '(^|[^a-z0-9_])(%s)([^a-z0-9_]|$)' "${_joined%|}"
}

# _arch_literal_has_reason <line> <marker> -- does the opt-out marker on
# this line carry a `-- <why>` justification? The tail after the marker must
# hold a `--` followed by something that is not whitespace.
_arch_literal_has_reason() {
  local _line="${1}" _marker="${2}" _tail
  _tail="${_line#*"${_marker}"}"
  [[ "${_tail}" =~ ^[[:space:]]*--[[:space:]]*[^[:space:]] ]]
}

_run_arch_literal() {
  echo "--- Running bare architecture literal lint ---"
  local _violations=0
  local _root _abs_root _file _rel _line _lc _lineno _in_allow _begin_line _hit
  local _glob _re
  _re="$(_arch_literal_regex)"

  local -a _files=()
  for _root in "${_ARCH_LITERAL_SCAN_ROOTS[@]}"; do
    _abs_root="${REPO_ROOT}/${_root}"
    if [[ ! -d "${_abs_root}" ]]; then
      _die ci_arch_literal \
        "scan root '${_root}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the trees that reach an image."
      return 1
    fi
    local -a _root_files=()
    local -a _find_args=()
    for _glob in "${_ARCH_LITERAL_FILE_GLOBS[@]}"; do
      [[ "${#_find_args[@]}" -eq 0 ]] || _find_args+=('-o')
      _find_args+=('-name' "${_glob}")
    done
    while IFS= read -r -d '' _file; do
      _root_files+=("${_file}")
    done < <(find "${_abs_root}" -type f \( "${_find_args[@]}" \) -print0 2>/dev/null | sort -z)
    if [[ "${#_root_files[@]}" -eq 0 ]]; then
      _die ci_arch_literal \
        "scan root '${_root}/' holds no Dockerfile -- the lint would pass vacuously. Either the tree moved or the file-name globs (${_ARCH_LITERAL_FILE_GLOBS[*]}) stopped matching it."
      return 1
    fi
    _files+=("${_root_files[@]}")
  done

  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if [[ "${_line}" == *"${_ARCH_LITERAL_ALLOW_BEGIN}"* ]]; then
        if ! _arch_literal_has_reason "${_line}" "${_ARCH_LITERAL_ALLOW_BEGIN}"; then
          printf '%s:%d: allow-begin with no stated reason (append " -- <why>")\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_ARCH_LITERAL_ALLOW_END}"* ]]; then
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        continue
      fi

      [[ "${_in_allow}" -eq 1 ]] && continue

      if [[ "${_line}" == *"${_ARCH_LITERAL_ALLOW_LINE}"* ]]; then
        if _arch_literal_has_reason "${_line}" "${_ARCH_LITERAL_ALLOW_LINE}"; then
          continue
        fi
        printf '%s:%d: per-line allow with no stated reason (append " -- <why>")\n' \
          "${_rel}" "${_lineno}"
        _violations=$(( _violations + 1 ))
        continue
      fi

      _lc="${_line,,}"
      if [[ "${_lc}" =~ ${_re} ]]; then
        _hit="${BASH_REMATCH[2]}"
        printf '%s:%d: %s -- %s\n' \
          "${_rel}" "${_lineno}" "${_hit}" "${_line}"
        _violations=$(( _violations + 1 ))
      fi
    done < "${_file}"

    if [[ "${_in_allow}" -eq 1 ]]; then
      printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
        "${_rel}" "${_begin_line}"
      _violations=$(( _violations + 1 ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_arch_literal \
      "${_violations} bare architecture literal(s) / unbalanced or unjustified allow marker(s) in a shipped Dockerfile (${_ARCH_LITERAL_SCAN_ROOTS[*]}). buildx builds one Dockerfile per --platform, so a literal ships the WRONG artifact inside every other platform's image and only fails at run time. Declare \`ARG TARGETARCH\` (no default -- a default shadows BuildKit's auto-injection) and build the value from it. Upstream assets that spell the architecture differently (linux.x86_64 / Linux-arm64) need a mapping \`case\`, which is the one legitimate home for both spellings: bracket it with '# ${_ARCH_LITERAL_ALLOW_BEGIN} -- <why>' / '# ${_ARCH_LITERAL_ALLOW_END}', or opt one line out with '# ${_ARCH_LITERAL_ALLOW_LINE} -- <why>'."
    return 1
  fi
  echo "bare architecture literal lint: clean"
}
