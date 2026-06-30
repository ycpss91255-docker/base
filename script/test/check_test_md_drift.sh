#!/usr/bin/env bash
#
# check_test_md_drift.sh - validate that doc/test/*.md count figures match
# the specs. The read-only twin of sync-doc-counts.sh: it re-derives every
# count from the SAME single source of truth (`grep -c '^@test'` per spec,
# via sync-doc-counts.sh's _sync_doc_counts) and exits non-zero when the
# committed docs have drifted -- so a PR that adds or removes a @test without
# running `just test sync-docs` fails the gate instead of shipping stale
# numbers. ISTQB taxonomy (ADR-00000018): unit / integration / system /
# acceptance levels + the shipped smoke type; empty level dirs count 0.
#
# Usage:
#   ./script/test/check_test_md_drift.sh            # check REPO_ROOT/doc/test
#   ./script/test/check_test_md_drift.sh <root>     # check <root>/doc/test
#
# Exit status: 0 = in sync; 1 = drift (the offending unified diff is printed
# to stderr).
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_CHECK_DRIFT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Reuse the generator as the single source of truth: rather than re-implement
# the count parsing (and risk the validator and generator disagreeing), run
# the real _sync_doc_counts against a throwaway copy of doc/test and diff the
# result against the committed docs. Identical output => in sync.
# shellcheck source=script/test/sync-doc-counts.sh
source "${_CHECK_DRIFT_DIR}/sync-doc-counts.sh"

# _check_test_md_drift [root] -- return 0 when <root>/doc/test/*.md already
# match what _sync_doc_counts would generate, 1 (with a diff on stderr) when
# they drift. Non-mutating: the generator runs against a temp copy; the spec
# source trees (test/, dist/) are symlinked in so their globs resolve without
# being copied.
_check_test_md_drift() {
  local _root="${1:-${REPO_ROOT:-.}}"
  [[ -d "${_root}/doc/test" ]] || return 0

  local _tmp
  _tmp="$(mktemp -d)" || return 1

  mkdir -p "${_tmp}/doc"
  cp -R "${_root}/doc/test" "${_tmp}/doc/test"
  ln -s "${_root}/test" "${_tmp}/test"
  [[ -d "${_root}/dist" ]] && ln -s "${_root}/dist" "${_tmp}/dist"

  _sync_doc_counts "${_tmp}" >/dev/null

  local _diff _rc=0
  _diff="$(diff -ru "${_root}/doc/test" "${_tmp}/doc/test" 2>/dev/null)" || _rc=1
  rm -rf "${_tmp}"

  if (( _rc != 0 )); then
    {
      printf 'doc/test count drift detected. Run: just test sync-docs (then commit):\n'
      printf '%s\n' "${_diff}"
    } >&2
    return 1
  fi
  return 0
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  if _check_test_md_drift "${_root}"; then
    printf 'doc/test counts are in sync under %s\n' "${_root}/doc/test"
    return 0
  fi
  return 1
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
