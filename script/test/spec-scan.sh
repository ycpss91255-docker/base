#!/usr/bin/env bash
#
# spec-scan.sh - the ONE definition of "which files are this suite's spec
# files", shared by the description lint and by the generator that writes
# the lint's ceiling.
#
# WHY THIS IS SHARED, AND IN WHICH DIRECTION. The description lint
# (drivers/catalog_description.sh) deliberately does NOT inherit the
# generator's idea of the population: the generator walks five per-level
# globs, and a lint that asked the generator which specs exist would agree,
# by construction, that a spec the generator has stopped seeing has nothing
# to check. That argument is about the direction lint <- generator, and it
# still holds.
#
# The sharing here runs the other way. The generator now writes a number
# ABOUT THE LINT'S POPULATION (the undescribed ceiling, base#1024), so the
# question it has to answer is not "which specs do I document" but "which
# specs does the lint read" -- and two answers to that question would be a
# ceiling measured over one set and enforced over another, agreeing on the
# day it was written and drifting after. The scan therefore has one home,
# the lint's, and the generator reads it from here.
#
# Sourced library, no main, and no `readonly`: the drivers and the
# generator can reach it in the same shell (test.sh sources every driver,
# and the doc-counts driver sources the generator), so a second source has
# to be a no-op rather than a "readonly variable" abort.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# The spec trees, repo-root-relative. The WHOLE bats tree rather than the
# five globs the catalogues happen to cover: a spec parked outside a
# level directory is still a spec whose tests want descriptions, and the
# gap between "documented" and "linted" is where the previous design's
# 606 hidden tests lived.
_SPEC_SCAN_GLOBS=(
  'test/bats/**/*_spec.bats'
  'dist/test/bats/smoke/**/*.bats'
)

# _spec_scan_files <root> -- every spec file in scope, one per line,
# root-relative.
#
# Sorted explicitly under LC_ALL=C: the callers run both in the musl
# test-tools container and on a glibc host, whose collations order
# `log_spec.bats` and `logrotate_spec.bats` oppositely, and a findings
# list (or a count taken in a different order) that reorders between the
# two is a diff nobody can read. The globstar dance happens in the
# subshell, so nothing leaks to the caller.
_spec_scan_files() {
  local _root="$1"
  (
    shopt -s globstar
    local _glob _f
    for _glob in "${_SPEC_SCAN_GLOBS[@]}"; do
      for _f in "${_root}"/${_glob}; do
        # `|| continue` and not `&& printf`: under pipefail the loop's
        # status is the last iteration's, so a final non-file match would
        # fail the pipeline and be reported as a broken caller.
        [[ -f "${_f}" ]] || continue
        printf '%s\n' "${_f#"${_root}"/}"
      done
    done
  ) | LC_ALL=C sort
}
