#!/usr/bin/env bash
# drivers/shellcheck.sh - ShellCheck per-tool driver for the self-test
# dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_shellcheck, including the flat-layout consumer-parity pass added
# in
#
# Contract: runs INSIDE the ci container where test.sh invokes it.
# References ${REPO_ROOT} (a global exported by test.sh). Function name +
# behaviour are byte-identical to the pre-split monolith so the call
# sites in test.sh's main are unchanged.

# ── ShellCheck ───────────────────────────────────────────────────────────────

_run_shellcheck() {
  echo "--- Running ShellCheck ---"
  find "${REPO_ROOT}/dist/script/docker/wrapper" -name "*.sh" -print0 | xargs -0 shellcheck -x
  find "${REPO_ROOT}/dist/script/docker/lib" -name "*.sh" -print0 | xargs -0 shellcheck -x
  find "${REPO_ROOT}/dist/script/docker/runtime" -name "*.sh" -print0 | xargs -0 shellcheck -x
  find "${REPO_ROOT}/dist/script/template" -name "*.sh" -print0 | xargs -0 shellcheck -x
  find "${REPO_ROOT}/dist/script/base" -name "*.sh" -print0 | xargs -0 shellcheck -x

  # local==CI parity: the consumer Dockerfile devel-test stage lints
  # the SHIPPED wrappers + libs with `shellcheck -S warning` and WITHOUT -x,
  # after COPYing them FLAT into /lint/{wrapper,lib} -- so cross-file
  # source-following is gone. The -x passes above hide cross-file-only
  # findings (e.g. SC2034 on a var set in a wrapper but read in
  # lib/wrapper.sh), and even a no-x pass in the real tree resolves source=
  # directives differently than the flat copy. Reproduce the EXACT consumer
  # invocation -- flat layout + no -x -- so `just test` catches this class
  # before the acceptance job / the downstream fanout does.
  local _lintdir
  _lintdir="$(mktemp -d)"
  mkdir -p "${_lintdir}/wrapper" "${_lintdir}/lib"
  cp "${REPO_ROOT}"/dist/script/docker/wrapper/*.sh "${_lintdir}/wrapper/"
  cp "${REPO_ROOT}"/dist/script/docker/lib/*.sh "${_lintdir}/lib/"
  shellcheck -S warning "${_lintdir}"/wrapper/*.sh "${_lintdir}"/lib/*.sh
  rm -rf "${_lintdir}"
  shellcheck -x "${REPO_ROOT}/script/test/test.sh"
  shellcheck -x "${REPO_ROOT}/script/test/sync-doc-counts.sh"
  # The per-tool drivers are base-own self-test tooling (sourced by
  # test.sh); shellcheck them with -x so source-following resolves the
  # _lib.sh / _log_* references the same way test.sh sees them.
  find "${REPO_ROOT}/script/test/drivers" -name "*.sh" -print0 | xargs -0 shellcheck -x
  shellcheck -x "${REPO_ROOT}/dist/script/base/init.sh"
  shellcheck -x "${REPO_ROOT}/dist/script/base/upgrade.sh"
  shellcheck -x "${REPO_ROOT}/dist/config/shell/terminator/setup.sh"
  shellcheck -x "${REPO_ROOT}/dist/config/shell/tmux/setup.sh"
}
