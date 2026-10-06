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
  # THE SHIPPED TREE IS THE POPULATION, read in one find. This used to be
  # a list of roots -- script/docker/{wrapper,lib,runtime},
  # script/template, script/base, two config/shell setup scripts, plus
  # dockerfile/entrypoint.sh and test/bats/smoke/smoke.sh by name -- and
  # the tree grew two scripts outside every one of them:
  # deploy/cd-guard.sh, which downstream CD invokes before a deploy, and
  # config/shell/bashrc.d/30-name-host-groups.sh, which the Dockerfile
  # copies into ~/.bashrc.d and every interactive shell sources. An
  # unquoted expansion in either was read by no pass, and
  # --shellcheck-only still exited 0. A root list cannot report the root
  # it is missing; the tree can, so the tree is asked -- the same move the
  # script/ half below has already made twice.
  #
  # NO EXEMPTION LIST, deliberately. Every *.sh dist/ ships is lintable
  # where it sits, and a sourced fragment with no shebang carries its own
  # `# shellcheck shell=bash` directive rather than being excused here: a
  # file excused from the pass is a file whose next edit is unchecked,
  # which is the defect this find replaces. -type f so nothing but a
  # regular file is handed to shellcheck. -x so source-following resolves
  # the lib/ references the way the shipped scripts do.
  find "${REPO_ROOT}/dist" -name "*.sh" -type f -print0 \
    | xargs -0 shellcheck -x

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
  # base-own tooling: the self-test dispatcher, the gate scripts, the
  # per-tool drivers AND the CI-side scripts under script/ci. ONE find
  # over the whole tree rather than a hand-written list -- the list is
  # what let check_test_md_drift.sh, lint_bare_stderr.sh and
  # sync-readme-hashes.sh go unlinted, and the same batch that added
  # resolve-doc-counts.sh to it forgot them. Rooting at script/ rather
  # than script/test/ closes the same hole one level up: script/ci/ was
  # outside every pass. -type f skips the script/*.sh wrapper symlinks,
  # whose targets under dist/ are already linted above (twice, once
  # flat). -x so source-following resolves the _lib.sh / _log_*
  # references the way test.sh sees them.
  find "${REPO_ROOT}/script" -name "*.sh" -type f -print0 \
    | xargs -0 shellcheck -x
  # The repo-root compatibility forwarders. The find roots above are all
  # subdirectories, so a script at the root would otherwise go unlinted --
  # and a hand-written pair of names is how the SECOND forwarder would
  # arrive unlinted, which is the same shape of omission the forwarder
  # itself exists to close. A glob is the derivation: whatever sits at the
  # top level is linted, this one and the next.
  shellcheck -x "${REPO_ROOT}"/*.sh
}
