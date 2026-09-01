#!/usr/bin/env bash
# just-version.sh - the ONE version of the `just` runner this base pins.
#
# Shipped inside the subtree so every downstream repo gets it (and its
# updates) for free on each upgrade, next to upstream.sh, which is the
# same pattern for the same reason: one definition, several consumers,
# instead of a literal repeated per consumer.
#
# ── Why the definition needs a home at all ───────────────────────────────
#
# `just` is the user-facing entry point for every repo this template
# scaffolds (ADR-00000005 / ADR-00000010 / ADR-00000011), and it used to
# reach a developer through four independent provenance paths that shared
# no version with one another:
#
#   the test-tools image        a bare `apk add` of alpine's package
#   CI's integration-e2e job    `extractions/setup-just`, no version input
#   --bootstrap-just            just.systems/install.sh, no --tag
#   the install hint below it   apt / brew / cargo, offered as equivalents
#
# Measured 2026-08-28 that was a 37-minor spread. Because every container
# operation IS a recipe, a version skew across those paths is a skew
# across the whole interface: a recipe that works on one path and fails on
# another is indistinguishable, from the outside, from a broken recipe.
#
# ── Why the definition lives in the tooling Dockerfile ───────────────────
#
# The declaration is `ARG JUST_VERSION` in
# <subtree-root>/dockerfile/Dockerfile.test-tools, and this file READS it
# rather than restating it. That direction is forced, not stylistic:
# script/test/test.sh derives the local test-tools image tag from the
# sha256 of that Dockerfile ALONE (it deliberately hashes no build
# context, so the tag does not churn on unrelated source edits). A
# version declared in any other file would be invisible to that digest,
# so bumping it would leave the tag unchanged and the previous image --
# carrying the previous `just` -- silently reused.
#
# Every other path reads this accessor: init.sh (the install hint and the
# --bootstrap-just installer), .github/workflows/self-test.yaml (the
# `just-version:` input of setup-just), .github/workflows/
# release-test-tools.yaml (the published-image smoke check) and
# script/test/drivers/just_provenance.sh (the lint that refuses a new
# provenance path with no pin).
#
# Reads nothing from the environment: it is a constant, not a knob.
#
# Usage:
#   ./just-version.sh          print the pinned version (e.g. 1.58.0)
#
# Sourced form (init.sh does this): `source just-version.sh` then call
# `_just_pinned_version`.

# Only set strict mode when running directly; when sourced, respect
# caller's settings.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# The declaration, relative to the subtree root, and the ARG that carries
# it. Named here so the error messages can point at the file to edit.
_JUST_VERSION_DECL_REL='dockerfile/Dockerfile.test-tools'
_JUST_VERSION_ARG='JUST_VERSION'

# _just_version_root -- the subtree root, derived from this file's own
# location (<root>/dist/script/base/just-version.sh). Not a cwd walk and
# not an environment variable: a downstream repo calls this from its own
# root, from .base/, and from a workflow step, and all three must read
# the same declaration.
#
# ${BASH_SOURCE[0]:-$0} rather than the bare indexed read: the array is
# not populated in every context (the kcov-instrumented shell of the
# coverage shard most of all) and the bare form aborts under the nounset
# this file may be running with.
_just_version_root() {
  local _self _dir
  _self="${BASH_SOURCE[0]:-$0}"
  _dir="$(cd -- "$(dirname -- "${_self}")" && pwd)" || return 1
  (cd -- "${_dir}/../../.." && pwd)
}

# _just_pinned_version -- print the pinned version, or fail loud.
#
# Fails rather than falling back to "whatever is latest": a silent
# fallback is precisely the four-path drift this file exists to end.
_just_pinned_version() {
  local _root _file
  _root="$(_just_version_root)" || {
    echo "just-version: cannot locate the subtree root from ${BASH_SOURCE[0]:-$0}" >&2
    return 1
  }
  _file="${_root}/${_JUST_VERSION_DECL_REL}"
  if [[ ! -f "${_file}" ]]; then
    echo "just-version: declaration not found -- ${_file} is missing" >&2
    return 1
  fi

  # Read the WHOLE file (sed prints every match and runs to EOF): a
  # reader that stopped at the first hit could not tell one declaration
  # from two, and two is a defect worth reporting rather than resolving
  # by arrival order. The stage-level `ARG JUST_VERSION` that re-declares
  # the build arg without a default carries no `=` and so is not a match.
  local -a _hits=()
  mapfile -t _hits < <(
    sed -n "s/^ARG[[:space:]]\{1,\}${_JUST_VERSION_ARG}=[[:space:]]*//p" "${_file}"
  )

  if [[ "${#_hits[@]}" -eq 0 ]]; then
    echo "just-version: no 'ARG ${_JUST_VERSION_ARG}=<version>' in ${_file}" >&2
    return 1
  fi
  if [[ "${#_hits[@]}" -gt 1 ]]; then
    echo "just-version: ${#_hits[@]} 'ARG ${_JUST_VERSION_ARG}=' declarations in ${_file}; there must be exactly one" >&2
    return 1
  fi

  local _value="${_hits[0]}"
  _value="${_value%\"}"; _value="${_value#\"}"
  _value="${_value%\'}"; _value="${_value#\'}"
  _value="${_value//[[:space:]]/}"
  if [[ ! "${_value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "just-version: 'ARG ${_JUST_VERSION_ARG}=${_hits[0]}' in ${_file} is not a bare semver" >&2
    return 1
  fi
  printf '%s\n' "${_value}"
}

# Only run when executed directly, not when sourced (for testing).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _just_pinned_version "$@"
fi
