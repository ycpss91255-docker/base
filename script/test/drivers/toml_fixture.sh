#!/usr/bin/env bash
# drivers/toml_fixture.sh - "a fixture written to a .toml path parses as
# TOML" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_toml_fixture, the dispatcher entry point for
# ../toml_fixture_lint.sh -- the same relationship drivers/doc_counts.sh
# has with ../check_test_md_drift.sh: the engine holds the rule and is
# runnable on its own, this names it to the lint phase and fails the
# branch when it reports.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/doc_counts.sh / drivers/stale_setup_conf.sh
# conventions (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why this driver exists: a spec fixture named `setup.toml` that holds
# INI is refused by the bridge, and while the bridge's exit status was
# swallowed the refusal left an empty config handle whose every value
# fell back to the default the test happened to assert. Those tests were
# green for a reason that had nothing to do with what their names
# claimed, and nothing in the tree could tell the difference -- the
# measured proof is in the engine's header. The bodies are now TOML; this
# is what stops the next one, because the cheapest way to write a config
# fixture is still to copy an INI one, and the failure it causes is
# silent by construction.
#
# Scope: every *.bats under ${REPO_ROOT}/test/bats. A missing spec tree
# or a tree holding no fixture at all is an error in the engine rather
# than a vacuous pass here.
#
# Why a lint and not a spec of its own: the rule is about the WHOLE spec
# tree, and a @test that scans the tree runs inside the coverage suite
# under kcov on the matrix's critical path -- what base#1075 measured and
# what drivers/spec_repo_root.sh now refuses. The lint phase is where a
# whole-tree assertion belongs; test/bats/unit/toml_fixture_lint_spec.bats
# tests THIS driver against fixtures it builds, which is the other half
# of that split.

_TOML_FIXTURE_DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _TOML_FIXTURE_DRIVER_DIR

# shellcheck source=script/test/toml_fixture_lint.sh
source "${_TOML_FIXTURE_DRIVER_DIR}/../toml_fixture_lint.sh"

# ── TOML fixture body gate ───────────────────────────────────────────────────

_run_toml_fixture() {
  echo "--- Running TOML fixture body gate ---"

  # An ABSOLUTE root: the engine resolves <root>/test/bats and a relative
  # root would be read against whatever directory the dispatcher happens
  # to stand in. ${REPO_ROOT} is already absolute (test.sh derives it with
  # `pwd -P`); passing it explicitly keeps that a property of the call
  # rather than of the environment.
  if ! _toml_fixture_lint "${REPO_ROOT}"; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_toml_fixture \
      "a fixture body written to a .toml path does not parse as TOML. The offending bodies are named file:line above, each with the parser's own message. Convert the body to TOML (quoted string values, numbered list keys routed to the [[array of tables]] the bridge reads them back from) and re-derive the assertion -- a fixture the bridge refuses leaves an EMPTY config handle, so a test asserting a schema default passes without the fixture ever being read. A body that is deliberately not TOML carries a '# toml-fixture-lint: allow <reason>' marker directly above it."
    return 1
  fi
  echo "TOML fixture body gate: clean"
}
