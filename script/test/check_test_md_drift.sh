#!/usr/bin/env bash
#
# check_test_md_drift.sh - validate that doc/test/*.md still matches the
# specs. The read-only twin of sync-doc-counts.sh: it runs THAT generator
# against a throwaway copy and diffs, so validator and generator cannot
# disagree, and exits non-zero when the committed docs have drifted -- a PR
# that adds a @test, deletes a `# why:` block, or hand-edits the generated
# region fails the gate instead of shipping a catalogue that disagrees with
# the tree.
#
# Both halves of the catalogue are derived: the counts from
# `grep -c '^@test'` per spec, and the sections (blurb + one row per test)
# from the spec files' own `# why:` markers. So "byte-identical to what is
# committed" is the whole gate -- there is no preserved content for a
# regeneration to be merged into.
#
# The comparison is not doc/test-shaped any more, and it does not carry a
# list of what else to compare either. The generator is asked
# (`_sync_doc_counts_outputs`), the same question the merge resolver asks
# it, and every output outside doc/test is staged and diffed beside the
# documents. The description lint's undescribed ceiling (base#1024) is the
# first of those: without it a branch could describe tests, leave the
# number where it was, and read as in sync -- the slack that design
# accepts arriving as a green run rather than as a printed number. Naming
# that file here instead would have covered exactly it, and the next
# generated figure would have arrived uncompared with pass as the default.
#
# ISTQB taxonomy (ADR-00000018): unit / integration / system / acceptance
# levels + the shipped smoke type; empty level dirs count 0.
#
# Usage:
#   ./script/test/check_test_md_drift.sh            # check REPO_ROOT/doc/test
#   ./script/test/check_test_md_drift.sh <root>     # check <root>/doc/test
#
# <root> may be relative or absolute -- it is resolved to an absolute path
# before use, so both call styles give the same verdict (the sibling
# sync-doc-counts.sh accepts a relative root, so passing `.` to both is the
# natural thing to do).
#
# Exit status: 0 = in sync; 1 = drift (the offending unified diff is printed
# to stderr), or an unusable scan root (missing, no doc/test/, no specs).
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_CHECK_DRIFT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# Reuse the generator as the single source of truth: rather than re-implement
# the count parsing (and risk the validator and generator disagreeing), run
# the real _sync_doc_counts against a throwaway copy of doc/test and diff the
# result against the committed docs. Identical output => in sync.
# shellcheck source=script/test/sync-doc-counts.sh
source "${_CHECK_DRIFT_DIR}/sync-doc-counts.sh"

# Spec trees the count generator walks, root-relative. Used only by the
# "did the scan root actually yield any specs" guard below: if NONE of them
# matches, every level would compare 0 against 0 and the gate would pass
# vacuously -- exactly what a relocation of the spec tree must not do.
_CHECK_DRIFT_SPEC_GLOBS=(
  'test/bats/**/*_spec.bats'
  'dist/test/bats/smoke/**/*.bats'
)

# _check_drift_err <message> -- diagnostic to stderr. Block-redirected rather
# than a bare `printf ... >&2` because this script is a standalone, log.sh-free
# CI tool (same rationale class as drivers/coverage_gate.sh) and the bare-stderr
# lint scans script/test/.
_check_drift_err() {
  {
    printf 'check_test_md_drift: %s\n' "$1"
  } >&2
}

# _check_drift_resolve_root <root> -- print <root> as an absolute,
# symlink-resolved path; fail (naming <root>) when it does not exist.
#
# Why this is not optional: the comparison below copies doc/test into a temp
# dir and symlinks the spec trees in from <root>. A relative <root> would be
# recorded as a relative symlink target, i.e. resolved against the TEMP dir on
# that hop -- every spec glob then misses and every count comes back 0, so the
# gate reports total drift instead of erroring. sync-doc-counts.sh has no such
# hop, which is why it takes a relative root fine and the asymmetry surprises.
_check_drift_resolve_root() {
  local _root="$1" _abs
  if ! _abs="$(cd -- "${_root}" 2>/dev/null && pwd -P)"; then
    _check_drift_err "scan root '${_root}' does not exist or is not a directory."
    return 1
  fi
  printf '%s\n' "${_abs}"
}

# _check_drift_count_specs <root> -- number of spec files under <root> across
# _CHECK_DRIFT_SPEC_GLOBS.
_check_drift_count_specs() {
  local _root="$1" _glob _f _n=0
  # globstar for the `**` segments; saved/restored so sourcing this lib does
  # not leak the option to the caller (same idiom as _dir_test_count).
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _glob in "${_CHECK_DRIFT_SPEC_GLOBS[@]}"; do
    for _f in "${_root}"/${_glob}; do
      [[ -f "${_f}" ]] && _n=$(( _n + 1 ))
    done
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_n}"
}

# _check_drift_stage_generated <root> <tmp> -- copy every generated file
# that does NOT live under doc/test into <tmp> at its ROOT-RELATIVE path,
# printing those paths one per line.
#
# The set is the generator's own answer (`_sync_doc_counts_outputs`), the
# same question the merge resolver asks it, and not a constant kept here:
# a gate that names its outputs cannot notice the next one, and its
# default on a file it does not name is to pass. COPIED and not symlinked,
# unlike the spec trees: the generator WRITES these, and a symlink would
# have it write into the checkout the gate is meant to leave alone. The
# root-relative path matters -- a file placed anywhere but where the
# generator expects it is one the regeneration silently declines to write.
_check_drift_stage_generated() {
  local _root="$1" _tmp="$2" _out _rel
  while IFS= read -r _out; do
    case "${_out}" in
      "${_root}/doc/test/"*) continue ;;
    esac
    _rel="${_out#"${_root}"/}"
    mkdir -p "${_tmp}/$(dirname -- "${_rel}")"
    cp -- "${_out}" "${_tmp}/${_rel}"
    printf '%s\n' "${_rel}"
  done < <(_sync_doc_counts_outputs "${_root}")
}

# _check_drift_generated_diff <root> <tmp> <rel>... -- the unified diff of
# each named file, committed against regenerated; empty output and status
# 0 when they all match, status 1 when any differed.
_check_drift_generated_diff() {
  local _root="$1" _tmp="$2"
  shift 2
  local _rel _one _rc=0
  for _rel in "$@"; do
    [[ -f "${_tmp}/${_rel}" ]] || continue
    _one="$(diff -u "${_root}/${_rel}" "${_tmp}/${_rel}" 2>/dev/null)" || _rc=1
    [[ -z "${_one}" ]] || printf '%s\n' "${_one}"
  done
  return "${_rc}"
}

# _check_test_md_drift [root] -- return 0 when <root>/doc/test/*.md already
# match what _sync_doc_counts would generate, 1 (with a diff on stderr) when
# they drift. Non-mutating: the generator runs against a temp copy; the spec
# source trees (test/, dist/) are symlinked in so their globs resolve without
# being copied.
#
# [root] may be relative; it is resolved to an absolute path first. An
# unusable scan root (missing, no doc/test/, no spec files) is an ERROR, not
# an observation of "0 tests everywhere": reporting zeros would either look
# like total drift (the caller concludes their change broke every count) or,
# once the docs said 0 too, pass vacuously.
_check_test_md_drift() {
  local _root="${1:-${REPO_ROOT:-.}}"

  local _abs
  _abs="$(_check_drift_resolve_root "${_root}")" || return 1
  _root="${_abs}"

  if [[ ! -d "${_root}/doc/test" ]]; then
    _check_drift_err \
      "no doc/test/ under scan root ${_root} -- nothing to validate, so the gate would pass vacuously."
    return 1
  fi

  local _specs
  _specs="$(_check_drift_count_specs "${_root}")"
  if (( _specs == 0 )); then
    _check_drift_err \
      "no spec files under scan root ${_root} (looked for ${_CHECK_DRIFT_SPEC_GLOBS[*]}) -- every count would compare 0 against 0. Point the gate at the repo root, or update the spec globs if the spec tree moved."
    return 1
  fi

  local _tmp
  _tmp="$(mktemp -d)" || return 1

  mkdir -p "${_tmp}/doc"
  cp -R "${_root}/doc/test" "${_tmp}/doc/test"
  ln -s "${_root}/test" "${_tmp}/test"
  [[ -d "${_root}/dist" ]] && ln -s "${_root}/dist" "${_tmp}/dist"
  # The generated figures that do not live under doc/test -- the
  # description lint's ceiling is one (base#1024) -- staged at their
  # root-relative paths, so the comparison below covers whatever the
  # generator says it writes rather than whatever this file remembers.
  local -a _generated=()
  mapfile -t _generated < <(_check_drift_stage_generated "${_root}" "${_tmp}")

  if ! _sync_doc_counts "${_tmp}" >/dev/null; then
    rm -rf "${_tmp}"
    _check_drift_err \
      "the generator refused to run over the copied doc/test -- see its diagnostic above. Reporting drift here would name the wrong problem."
    return 1
  fi

  local _diff _generated_diff='' _rc=0
  _diff="$(diff -ru "${_root}/doc/test" "${_tmp}/doc/test" 2>/dev/null)" || _rc=1
  _generated_diff="$(_check_drift_generated_diff "${_root}" "${_tmp}" \
    "${_generated[@]+"${_generated[@]}"}")" || _rc=1
  rm -rf "${_tmp}"

  if (( _rc != 0 )); then
    {
      printf 'generated-figure drift detected. Run: just test sync-docs (then commit):\n'
      if [[ -n "${_diff}" ]]; then
        printf '%s\n' "${_diff}"
      fi
      if [[ -n "${_generated_diff}" ]]; then
        printf '%s\n' "${_generated_diff}"
      fi
    } >&2
    return 1
  fi
  return 0
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  # Resolve here too so the success line names the same absolute root the
  # comparison actually used, whatever the caller passed.
  local _abs
  _abs="$(_check_drift_resolve_root "${_root}")" || return 1
  if _check_test_md_drift "${_abs}"; then
    printf 'doc/test counts are in sync under %s\n' "${_abs}/doc/test"
    return 0
  fi
  return 1
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
