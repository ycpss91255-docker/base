#!/usr/bin/env bash
#
# sync-doc-counts.sh - regenerate the test-count figures in doc/test/*.md
# from the specs themselves, so they stop being hand-edited every PR.
#
# Single source of truth: `grep -c '^@test'` over each spec file. The
# check_test_md_drift.sh hook stays the validating safety net; this is the
# generator that makes the docs match. Idempotent.
#
# Usage:
#   ./script/test/sync-doc-counts.sh            # sync REPO_ROOT/doc/test/*.md
#   ./script/test/sync-doc-counts.sh <root>     # sync <root>/doc/test/*.md
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# _dir_test_count <root> <relglob> -- total `^@test` count across the spec
# files matching <root>/<relglob>. This is the authoritative per-type total
# (what `just test` actually runs), independent of how many specs happen to
# have an individual `### <path> (N)` doc heading.
_dir_test_count() {
  local _root="$1" _glob="$2" _f _sum=0 _c
  # globstar so a caller can pass `<dir>/**/*_spec.bats` to recurse into
  # per-lib sub-folders (test/bats/unit/<lib>/<subunit>_spec.bats,
  # ADR-00000015). Saved/restored so sourcing this lib does not leak the
  # option to the caller.
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _f in "${_root}"/${_glob}; do
    [[ -f "${_f}" ]] || continue
    _c="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _sum=$(( _sum + ${_c:-0} ))
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_sum}"
}

# _sync_headings <root> <doc> -- rewrite each `### <relpath> (N)` heading's N
# from grep -c '^@test' on <root>/<relpath> (leaving headings whose path does
# not resolve untouched).
_sync_headings() {
  local _root="$1" _doc="$2" _tmp _line
  [[ -f "${_doc}" ]] || return 0
  _tmp="$(mktemp "${_doc}.XXXXXX")" || return 1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ^###[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]]; then
      local _path="${BASH_REMATCH[1]}" _n
      if [[ -f "${_root}/${_path}" ]]; then
        _n="$(grep -cE '^@test' "${_root}/${_path}" 2>/dev/null || true)"
        printf '### %s (%s)\n' "${_path}" "${_n:-0}"
        continue
      fi
    fi
    printf '%s\n' "${_line}"
  done < "${_doc}" > "${_tmp}"
  mv "${_tmp}" "${_doc}"
}

# _sync_type_total <doc> <count> -- rewrite the per-type `...: **N tests**.`
# header to <count>.
_sync_type_total() {
  local _doc="$1" _count="$2"
  [[ -f "${_doc}" ]] || return 0
  sed -i -E "s/(: )\*\*[0-9]+ tests\*\*/\1**${_count} tests**/" "${_doc}"
}

# _sync_test_md_index <root> -- rewrite TEST.md's derived figures (grand total,
# per-type table, "not in the N figure") from the per-type totals.
_sync_test_md_index() {
  local _root="$1"
  local _t="${_root}/doc/test/TEST.md"
  [[ -f "${_t}" ]] || return 0
  # ISTQB taxonomy (ADR-00000018): levels unit / integration / system /
  # acceptance, plus the shipped build-time smoke type. system replaces the
  # retired behavioural category. Empty level dirs (e.g. acceptance before
  # S5 content lands) resolve to 0 via _dir_test_count's no-match path.
  local _u _i _sy _a _sm _tot
  _u="$(_dir_test_count "${_root}" 'test/bats/unit/**/*_spec.bats')"
  _i="$(_dir_test_count "${_root}" 'test/bats/integration/**/*_spec.bats')"
  _sy="$(_dir_test_count "${_root}" 'test/bats/system/**/*_spec.bats')"
  _a="$(_dir_test_count "${_root}" 'test/bats/acceptance/**/*_spec.bats')"
  _sm="$(_dir_test_count "${_root}" 'dist/test/bats/smoke/**/*.bats')"
  _tot=$(( _u + _i ))
  sed -i -E \
    "s/\*\*[0-9]+ tests\*\* total \([0-9]+ unit \+ [0-9]+ integration\)/**${_tot} tests** total (${_u} unit + ${_i} integration)/" \
    "${_t}"
  sed -i -E "s/not\*\* in the [0-9]+ figure/not** in the ${_tot} figure/" "${_t}"
  sed -i -E "s#(\[unit\.md\]\(unit\.md\).*\| )[0-9]+ #\1${_u} #" "${_t}"
  sed -i -E "s#(\[integration\.md\]\(integration\.md\).*\| )[0-9]+ #\1${_i} #" "${_t}"
  sed -i -E "s#(\[system\.md\]\(system\.md\).*\| )[0-9]+ #\1${_sy} #" "${_t}"
  sed -i -E "s#(\[acceptance\.md\]\(acceptance\.md\).*\| )[0-9]+ #\1${_a} #" "${_t}"
  sed -i -E "s#(\[smoke\.md\]\(smoke\.md\).*\| )[0-9]+ #\1${_sm} #" "${_t}"
  sed -i -E "s/(grand total \(unit \+ integration\): )\*\*[0-9]+\*\*/\1**${_tot}**/" "${_t}"
}

# _sync_doc_counts [root] -- regenerate all doc/test/*.md count figures.
_sync_doc_counts() {
  local _root="${1:-${REPO_ROOT:-.}}"
  local _doc
  for _doc in "${_root}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    _sync_headings "${_root}" "${_doc}"
  done
  _sync_type_total "${_root}/doc/test/unit.md" \
    "$(_dir_test_count "${_root}" 'test/bats/unit/**/*_spec.bats')"
  _sync_type_total "${_root}/doc/test/integration.md" \
    "$(_dir_test_count "${_root}" 'test/bats/integration/**/*_spec.bats')"
  _sync_type_total "${_root}/doc/test/system.md" \
    "$(_dir_test_count "${_root}" 'test/bats/system/**/*_spec.bats')"
  _sync_type_total "${_root}/doc/test/acceptance.md" \
    "$(_dir_test_count "${_root}" 'test/bats/acceptance/**/*_spec.bats')"
  _sync_type_total "${_root}/doc/test/smoke.md" \
    "$(_dir_test_count "${_root}" 'dist/test/bats/smoke/**/*.bats')"
  _sync_test_md_index "${_root}"
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  _sync_doc_counts "${_root}"
  printf 'synced doc/test counts under %s\n' "${_root}/doc/test"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
