#!/usr/bin/env bats
#
# Unit tests for init.sh helpers. Complements the Level-1 integration test
# in test/integration/init_new_repo_spec.bats — which already covers
# end-to-end init.sh runs — by exercising individual helpers against
# edge cases that are hard to trigger from a real `bash .base/dist/script/base/init.sh`
# invocation (e.g. network-down version detection, main.yaml @ref
# fallback, _create_version_file with no argument).
#
# why: Unit coverage for `init.sh` helpers that previous rounds exercised
# only through the Level-1 integration test. Complements
# `test/bats/integration/init_new_repo_spec.bats` by locking edge cases that
# are hard to trigger from a real `bash template/init.sh` invocation
# (network-down version detection, main.yaml `@ref` fallback,
# `_create_version_file` with no argument).

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir

  # Mimic the integration-test layout so `init.sh` resolves TEMPLATE_DIR /
  # REPO_ROOT to a writable temp tree instead of /source. Symlinking
  # init.sh back to the real source keeps all edits in one place.
  # init.sh lives deep at dist/script/base/init.sh and self-locates
  # the subtree root by walking up to the dir carrying `.version` +
  # `dist/`, so seed both markers at .base/ and symlink at the deep
  # path; the walk-up still resolves TEMPLATE_DIR=.base, TEMPLATE_REL=.base.
  TMP_REPO="$(mktemp -d)"
  mkdir -p "${TMP_REPO}/.base/dockerfile" \
           "${TMP_REPO}/.base/dist/config" \
           "${TMP_REPO}/.base/dist/dockerfile" \
           "${TMP_REPO}/.base/dist/script/base" \
           "${TMP_REPO}/.base/dist/script/docker/lib"
  echo "v0.0.0-test" > "${TMP_REPO}/.base/.version"
  ln -s /source/dist/script/base/init.sh \
        "${TMP_REPO}/.base/dist/script/base/init.sh"
  # init.sh sources its sibling upstream.sh on load (the one definition of
  # the upstream slug / clone URL, shared with upgrade.sh and the version
  # monitor), so the seeded subtree needs it next to init.sh.
  ln -s /source/dist/script/base/upstream.sh \
        "${TMP_REPO}/.base/dist/script/base/upstream.sh"
  # init.sh also sources its sibling just-version.sh on load: the
  # ONE declaration of the pinned `just` runner version, read out of the
  # tooling Dockerfile, which the install hint and --bootstrap-just both
  # quote. Seed the accessor AND the file it reads.
  ln -s /source/dist/script/base/just-version.sh \
        "${TMP_REPO}/.base/dist/script/base/just-version.sh"
  ln -s /source/dockerfile/Dockerfile.test-tools \
        "${TMP_REPO}/.base/dockerfile/Dockerfile.test-tools"
  # init.sh sources lib/gitignore.sh on load. Symlink the real
  # lib so its functions are available to tests that hit _create_new_repo.
  ln -s /source/dist/script/docker/lib/gitignore.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/gitignore.sh"
  # init.sh also sources lib/template_guard.sh on load (the self-run guard,
  # ADR-00000011 sec.8). Symlink it so _source_init resolves it. The seeded
  # subtree root (.base/, no .git) makes the guard a no-op for these tests.
  ln -s /source/dist/script/docker/lib/template_guard.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/template_guard.sh"
  # init.sh sources _lib.sh on load (routes _log / _error through
  # _log_info / _log_err). _lib.sh sources i18n.sh + lib/*.sh sub-libs
  # so symlink all three surfaces.
  ln -s /source/dist/script/docker/lib/_lib.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/_lib.sh"
  ln -s /source/dist/script/docker/lib/i18n.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/i18n.sh"
  # Every sub-lib in lib/, by GLOB and not by roster. A hand-written list
  # sat here and had to be edited in lockstep with _lib.sh's own source
  # list; the first lib added after it was written took 65 specs in this
  # file down with `project_reclaim.sh: No such file or directory`, in a
  # sandbox that had nothing to do with the change. The glob says what the
  # comment above always meant -- _lib.sh sources lib/*.sh, so the sandbox
  # carries lib/*.sh -- and cannot drift from it. `-f` because a few
  # surfaces above are symlinked individually for their own reasons and
  # this pass reaches them too.
  local _sl
  for _sl in /source/dist/script/docker/lib/*.sh; do
    ln -sf "${_sl}" \
           "${TMP_REPO}/.base/dist/script/docker/lib/$(basename -- "${_sl}")"
  done
  unset _sl
  ln -s /source/dist/script/docker/lib/log-events.txt \
        "${TMP_REPO}/.base/dist/script/docker/lib/log-events.txt"
  cp /source/dist/dockerfile/entrypoint.sh \
     "${TMP_REPO}/.base/dist/dockerfile/entrypoint.sh"

  # Minimal Dockerfile.example stub for _create_new_repo's `cp` step.
  cat > "${TMP_REPO}/.base/dist/dockerfile/Dockerfile" <<'EOF'
FROM alpine
EOF

  # Stub scripts referenced by _create_symlinks — empty files are fine
  # because symlinks only need a valid target path, not a valid payload.
  mkdir -p "${TMP_REPO}/.base/dist/script/docker/wrapper"
  for _f in build.sh run.sh exec.sh stop.sh setup.sh setup_tui.sh; do
    : > "${TMP_REPO}/.base/dist/script/docker/wrapper/${_f}"
  done
  : > "${TMP_REPO}/.base/dist/script/justfile"
  : > "${TMP_REPO}/.base/dist/script/docker/justfile.docker"
  : > "${TMP_REPO}/.base/dist/.hadolint.yaml"

  cd "${TMP_REPO}"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TMP_REPO}"
}

# Source init.sh within a `bash -c` so the test controls when functions
# are loaded and can mutate PATH / cwd before invocation. `bash -c ... "$0"`
# pattern via `run` is awkward — we wrap in a helper.
_source_init() {
  # shellcheck disable=SC1091
  source "${TMP_REPO}/.base/dist/script/base/init.sh"
}

# ════════════════════════════════════════════════════════════════════
# _detect_template_version
# ════════════════════════════════════════════════════════════════════

# why: Happy path + head -1
@test "_detect_template_version: parses newest vX.Y.Z tag from git ls-remote" {
  # Mock emits refs in the order the real `--sort=-v:refname` would produce
  # (newest-first). _detect_template_version trusts the sort and just
  # takes `head -1`.
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
def456  refs/tags/v0.7.2
ghi789  refs/tags/v0.7.1
abc123  refs/tags/v0.7.0
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  # The walk-up marker .version (seeded in setup) doubles as
  # _detect_template_version's cache; remove it now that TEMPLATE_DIR is
  # resolved so this test exercises the git-ls-remote fallback path.
  rm -f "${TMP_REPO}/.base/.version"
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v0.7.2"
}

# why: Network-down fallback
@test "_detect_template_version: returns empty when git ls-remote fails" {
  mock_cmd "git" 'exit 128'
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" ""
}

# why: Nothing to match
@test "_detect_template_version: returns empty when no v*.*.* tags exist" {
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
abc123  refs/heads/main
def456  refs/tags/latest
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" ""
}

# why: Regex filters rc / pre-release
@test "_detect_template_version: ignores non-semver tags (e.g. rc suffixes)" {
  # --sort=-v:refname would rank v0.8.0-rc2 > v0.7.2-rc1 > v0.7.0, but
  # the regex strips the rc variants, leaving v0.7.0 as the only valid
  # vX.Y.Z entry.
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
ghi789  refs/tags/v0.8.0-rc2
def456  refs/tags/v0.7.2-rc1
abc123  refs/tags/v0.7.0
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v0.7.0"
}

# ════════════════════════════════════════════════════════════════════
# _detect_template_version: reads .version file
# ════════════════════════════════════════════════════════════════════

@test "_detect_template_version: an early-closing reader cannot empty the tag scan (#905)" {
  # Same pipeline as upgrade.sh's _get_latest_version, same `|| true`, and
  # the same surviving failure mode: `head -1` leaves after one line, the
  # `grep -oP` still writing dies of SIGPIPE, and the suppressed status
  # leaves an EMPTY version. init.sh then stamps a repo with no template
  # version at all rather than the tag it just resolved.
  #
  # Shims go on AFTER _source_init so they cannot perturb init.sh's
  # source-time self-location; only the function under test sees them.
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  shim_early_closing_reader "${MOCK_DIR}" head
  shim_late_writer "${MOCK_DIR}" git \
    "def456	refs/tags/v0.7.2" \
    "abc123	refs/tags/v0.7.0"

  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v0.7.2"
}

# why: .version file priority
@test "_detect_template_version: reads .version file when present (no network)" {
  echo "v1.5.0" > "${TMP_REPO}/.base/.version"
  # Mock git to fail (simulate offline)
  mock_cmd "git" 'exit 128'
  _source_init
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v1.5.0"
}

# why: Local-first resolution
@test "_detect_template_version: .version file takes priority over git ls-remote" {
  echo "v1.5.0" > "${TMP_REPO}/.base/.version"
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
abc123  refs/tags/v2.0.0
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v1.5.0"
}

# ════════════════════════════════════════════════════════════════════
# _create_new_repo: ref threading into main.yaml
# ════════════════════════════════════════════════════════════════════

# why: Ref threading
@test "_create_new_repo: main.yaml uses given ref in workflow @ref" {
  _source_init
  _create_new_repo "v9.9.9"
  assert [ -f "${TMP_REPO}/.github/workflows/main.yaml" ]
  run grep -E 'build-worker\.yaml@v9\.9\.9' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
  run grep -E 'release-worker\.yaml@v9\.9\.9' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
}

# why: Default ref
@test "_create_new_repo: main.yaml falls back to @main when ref arg omitted" {
  _source_init
  _create_new_repo
  run grep -E 'build-worker\.yaml@main' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
  run grep -E 'release-worker\.yaml@main' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
}

# why: Empty-string → `@main`
@test "_create_new_repo: main.yaml falls back to @main when ref arg is empty" {
  _source_init
  _create_new_repo ""
  run grep -E 'build-worker\.yaml@main' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
}

# why: setup.conf rules drive IMAGE_NAME
@test "_create_new_repo: does NOT generate .env.example (image name via setup.conf)" {
  _source_init
  _create_new_repo "main"
  [[ ! -f "${TMP_REPO}/.env.example" ]]
}

# ════════════════════════════════════════════════════════════════════
# _create_symlinks
# ════════════════════════════════════════════════════════════════════

# why: 7 wrappers under script/ with ../ targets; justfile at root, no
# Makefile
@test "_create_symlinks: places 7 wrapper symlinks under script/ (#330)" {
  _source_init
  _create_symlinks
  # Seven wrappers under script/ with ../.base/dist/script/docker/wrapper/<name>.sh targets.
  for _f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ -L "${TMP_REPO}/script/${_f}" ]
    run readlink "${TMP_REPO}/script/${_f}"
    assert_output "../.base/dist/script/docker/wrapper/${_f}"
    # And must NOT exist at root.
    assert [ ! -e "${TMP_REPO}/${_f}" ]
  done
  # the root user entry is the justfile, not a Makefile.
  assert [ -L "${TMP_REPO}/justfile" ]
  assert [ ! -e "${TMP_REPO}/Makefile" ]
}

# why: root justfile -> .base/script/docker/justfile
@test "_create_symlinks: places justfile at root with the direct .base/ target (#545)" {
  _source_init
  _create_symlinks
  # ADR-00000005: just is the new user-facing entry; the justfile symlink
  # sits at root (like Makefile) so `just <verb>` runs from the repo root.
  assert [ -L "${TMP_REPO}/justfile" ]
  run readlink "${TMP_REPO}/justfile"
  assert_output "script/justfile"
}

# why: Makefile retired; stale symlink dropped on upgrade
@test "_create_symlinks: does NOT symlink Makefile and cleans a stale root Makefile symlink (#546)" {
  # ADR-00000005 phase 2: the Makefile is retired in favour of `just`.
  # _create_symlinks must no longer create a root Makefile, and an
  # upgrading repo's pre-existing root Makefile symlink must be dropped
  # (init.sh resync) so it does not dangle once .base/ no longer ships one.
  _source_init
  ln -sf ".base/script/docker/Makefile" "${TMP_REPO}/Makefile"   # legacy symlink from an older base
  _create_symlinks
  assert [ ! -e "${TMP_REPO}/Makefile" ]
  assert [ ! -L "${TMP_REPO}/Makefile" ]
}

# why: Re-init over stale file at script/build.sh
@test "_create_symlinks: replaces a stale file at the new symlink path under script/ (#330)" {
  # Pretend an earlier run left a regular file where the symlink should go.
  # the symlinks live under script/, so the stale-replacement
  # logic in _symlink runs against script/build.sh, not root build.sh.
  mkdir -p "${TMP_REPO}/script"
  echo "stale" > "${TMP_REPO}/script/build.sh"
  _source_init
  _create_symlinks
  assert [ -L "${TMP_REPO}/script/build.sh" ]
}

# why: Migration: plant 7 root symlinks, re-run, all gone + script/ created
@test "_create_symlinks: removes stale root *.sh symlinks left by pre-#330 init (#330 migration loop)" {
  # Plant the seven root-level symlinks an older init.sh would have made;
  # the loop must drop them all so the user-facing entry is the
  # `script/` subfolder + root `Makefile`.
  for _f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    ln -sf ".base/script/docker/${_f}" "${TMP_REPO}/${_f}"
  done
  _source_init
  _create_symlinks
  for _f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ ! -e "${TMP_REPO}/${_f}" ]
    assert [ -L "${TMP_REPO}/script/${_f}" ]
  done
}

# why: Custom-hadolint preservation
@test "_create_symlinks: keeps custom .hadolint.yaml when it differs" {
  echo "# repo-specific rules" > "${TMP_REPO}/.hadolint.yaml"
  # Template's stub is empty — force a difference
  _source_init
  run _create_symlinks
  assert_success
  assert_output --partial "Keeping custom .hadolint.yaml"
  # Custom file should still be a regular file, not a symlink
  assert [ ! -L "${TMP_REPO}/.hadolint.yaml" ]
}

# ════════════════════════════════════════════════════════════════════
# _gen_setup_conf --force (reset path,)
# ════════════════════════════════════════════════════════════════════

@test "_gen_setup_conf default refuses to overwrite existing setup.conf" {
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  mkdir -p "${TMP_REPO}"
  echo "existing user config" > "${TMP_REPO}/.setup.conf"
  _source_init
  run _gen_setup_conf "false"
  assert_failure
  assert_output --partial "already exists"
}

@test "_gen_setup_conf --force overwrites and backs up existing setup.conf" {
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  mkdir -p "${TMP_REPO}"
  echo "old user conf" > "${TMP_REPO}/.setup.conf"
  _source_init
  run _gen_setup_conf "true"
  assert_success
  # new setup.conf must come from template
  run cat "${TMP_REPO}/.setup.conf"
  assert_output --partial "rules = @basename"
  # backup must contain the pre-overwrite user content
  assert [ -f "${TMP_REPO}/.setup.conf.bak" ]
  run cat "${TMP_REPO}/.setup.conf.bak"
  assert_output "old user conf"
}

@test "_gen_setup_conf --force also backs up .env to .env.bak" {
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  mkdir -p "${TMP_REPO}"
  echo "user conf" > "${TMP_REPO}/.setup.conf"
  echo "USER_NAME=existing" > "${TMP_REPO}/.env"
  _source_init
  run _gen_setup_conf "true"
  assert_success
  assert [ -f "${TMP_REPO}/.env.bak" ]
  run cat "${TMP_REPO}/.env.bak"
  assert_output "USER_NAME=existing"
}

# why: #692 missing-template _error
@test "_gen_setup_conf errors when the template setup.conf is absent (#692)" {
  # A broken/partial subtree has no template setup.conf -- the exact
  # scenario --gen-conf is meant to diagnose. _gen_setup_conf must fail
  # loudly rather than copy a non-existent source.
  rm -f "${TMP_REPO}/.base/dist/.setup.conf"
  rm -f "${TMP_REPO}/.setup.conf"
  _source_init
  run _gen_setup_conf "false"
  assert_failure
  assert_output --partial "Template setup.conf not found"
}

@test "_gen_setup_conf --force on clean repo does not create spurious .bak" {
  # No pre-existing setup.conf → first-time provision, nothing to back up.
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  rm -f "${TMP_REPO}/.setup.conf" "${TMP_REPO}/.env"
  _source_init
  run _gen_setup_conf "true"
  assert_success
  assert [ ! -f "${TMP_REPO}/.setup.conf.bak" ]
  assert [ ! -f "${TMP_REPO}/.env.bak" ]
}

# ════════════════════════════════════════════════════════════════════
# TEMPLATE_REL subtree-prefix auto-detection (prep)
# ════════════════════════════════════════════════════════════════════
#
# init.sh derives TEMPLATE_REL from `basename ${TEMPLATE_DIR}` (which is
# itself `dirname BASH_SOURCE[0]`). The conventional prefix is `.base/`
# but a downstream rename (e.g. `.base/`, planned for fanout) is
# picked up without code changes: the symlink targets and gen-conf paths
# follow whatever directory init.sh lives in.

@test "TEMPLATE_REL: auto-detects to '.base' when init.sh lives in .base/" {
  _source_init
  assert_equal "${TEMPLATE_REL}" ".base"
}

@test "TEMPLATE_REL: re-sourcing init.sh from .base/ keeps detection stable" {
  # the subtree always lives at `.base/`; re-sourcing init.sh
  # from that location must consistently derive TEMPLATE_REL = ".base"
  # so downstream symlinks point through the new prefix.
  source "${TMP_REPO}/.base/dist/script/base/init.sh"
  assert_equal "${TEMPLATE_REL}" ".base"
}

@test "_create_symlinks: targets follow TEMPLATE_REL through .base/ (#330 script/ subfolder)" {
  # Companion to the auto-detect test above: when TEMPLATE_REL is `.base`,
  # `_create_symlinks` must wire script/build.sh -> ../.base/dist/script/docker/wrapper/build.sh
  # (sub-folder link target is relative to the link's directory), and
  # justfile / .hadolint.yaml at root keep the direct .base/ target.
  source "${TMP_REPO}/.base/dist/script/base/init.sh"
  _create_symlinks
  run readlink "${TMP_REPO}/script/build.sh"
  assert_output "../.base/dist/script/docker/wrapper/build.sh"
  run readlink "${TMP_REPO}/justfile"
  assert_output "script/justfile"
  run readlink "${TMP_REPO}/.hadolint.yaml"
  assert_output ".base/dist/.hadolint.yaml"
}

# ════════════════════════════════════════════════════════════════════
# _create_new_repo .gitignore covers the *.bak siblings
# ════════════════════════════════════════════════════════════════════

@test "_create_new_repo: .gitignore includes .setup.conf.bak and .env.bak" {
  _source_init
  _create_new_repo "main"
  run grep -Fxq .setup.conf.bak "${TMP_REPO}/.gitignore"
  assert_success
  run grep -Fxq .env.bak "${TMP_REPO}/.gitignore"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _create_hook_stubs — 14 stubs (7 wrappers x 2 phases)
# ════════════════════════════════════════════════════════════════════

@test "_create_hook_stubs: creates script/hooks/{pre,post}/ with 14 stubs (#440)" {
  _source_init
  _create_hook_stubs
  local _kind _wrapper _file
  for _kind in pre post; do
    for _wrapper in build run exec stop prune setup setup_tui; do
      _file="${TMP_REPO}/script/hooks/${_kind}/${_wrapper}.sh"
      [[ -f "${_file}" ]] || { echo "missing ${_file}"; return 1; }
      [[ -x "${_file}" ]] || { echo "not executable: ${_file}"; return 1; }
    done
  done
}

@test "_create_hook_stubs: each stub starts with shebang and ends with exit 0 (#440)" {
  _source_init
  _create_hook_stubs
  local _file
  for _file in "${TMP_REPO}/script/hooks/pre/run.sh" \
               "${TMP_REPO}/script/hooks/post/build.sh"; do
    run head -n 1 "${_file}"
    assert_output "#!/usr/bin/env bash"
    run tail -n 1 "${_file}"
    assert_output "exit 0"
  done
}

@test "_create_hook_stubs: idempotent — preserves user-modified stub on re-run (#440)" {
  _source_init
  _create_hook_stubs
  local _file="${TMP_REPO}/script/hooks/pre/run.sh"
  # Simulate user editing their hook
  printf '#!/usr/bin/env bash\necho USER_CONTENT\nexit 0\n' > "${_file}"
  chmod +x "${_file}"
  # Re-run init's stub creator
  _create_hook_stubs
  run grep -F "USER_CONTENT" "${_file}"
  assert_success
}

@test "_create_new_repo: includes hook stubs in new-repo layout (#440)" {
  _source_init
  _create_new_repo "main"
  [[ -x "${TMP_REPO}/script/hooks/pre/run.sh" ]] || { echo "missing pre/run.sh"; return 1; }
  [[ -x "${TMP_REPO}/script/hooks/post/run.sh" ]] || { echo "missing post/run.sh"; return 1; }
}

@test "_init_existing_repo: creates missing hook stubs on upgrade (#440)" {
  _source_init
  # Simulate an existing repo on template — no hooks/ dir yet
  [[ ! -d "${TMP_REPO}/script/hooks" ]] || rm -rf "${TMP_REPO}/script/hooks"
  : > "${TMP_REPO}/Dockerfile"   # mark as "existing repo"
  _init_existing_repo
  [[ -x "${TMP_REPO}/script/hooks/pre/build.sh" ]] || { echo "missing pre/build.sh after upgrade"; return 1; }
  [[ -x "${TMP_REPO}/script/hooks/post/setup_tui.sh" ]] || { echo "missing post/setup_tui.sh after upgrade"; return 1; }
}

# ════════════════════════════════════════════════════════════════════
# _sync_base_monitor_workflow — per-repo base version monitor
# ════════════════════════════════════════════════════════════════════

@test "_sync_base_monitor_workflow: generates base-version-monitor.yaml" {
  _source_init
  _sync_base_monitor_workflow
  assert [ -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml" ]
}

@test "_sync_base_monitor_workflow: schedules weekly + manual dispatch" {
  _source_init
  _sync_base_monitor_workflow
  local _wf="${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  run grep -F 'schedule:' "${_wf}"
  assert_success
  run grep -F 'workflow_dispatch' "${_wf}"
  assert_success
}

@test "_sync_base_monitor_workflow: grants issues: write" {
  _source_init
  _sync_base_monitor_workflow
  run grep -F 'issues: write' \
    "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  assert_success
}

@test "_sync_base_monitor_workflow: runs the subtree-shipped checker via prefix" {
  _source_init
  _sync_base_monitor_workflow
  run grep -F '.base/dist/script/base/check-base-version.sh run' \
    "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  assert_success
}

@test "_sync_base_monitor_workflow: idempotent — never clobbers a user-tuned file" {
  _source_init
  mkdir -p "${TMP_REPO}/.github/workflows"
  echo "user-tuned" > "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  _sync_base_monitor_workflow
  run cat "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  assert_output "user-tuned"
}

@test "_create_new_repo: also generates base-version-monitor.yaml" {
  _source_init
  _create_new_repo "main"
  assert [ -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml" ]
}

# An upgrade is driven by the consumer's OWN vendored upgrade.sh, and every
# release up to v0.41.0 carries a hardcoded Dockerfile-patch step that knows
# only the paths that existed when it shipped. The one piece of CURRENT code
# such an upgrade runs is this file, re-executed from the freshly pulled
# tree -- so this is where a heal has to live if it is to reach a consumer
# upgrading FROM an old release rather than only one already on the new one.
@test "_init_existing_repo: heals a Dockerfile still naming the pre-dist layout (#915)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/config /tmp/config
EOF
  _init_existing_repo
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${TMP_REPO}/Dockerfile"
  grep -Fq "COPY .base/dist/config /tmp/config" "${TMP_REPO}/Dockerfile"
}

@test "_init_existing_repo: leaves an already-migrated Dockerfile untouched (#915)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  local _before
  _before="$(cat "${TMP_REPO}/Dockerfile")"
  _init_existing_repo
  [[ "$(cat "${TMP_REPO}/Dockerfile")" == "${_before}" ]]
}

# _git_seed_consumer
#   Turn the seeded TMP_REPO into a git repo with everything committed, so
#   what the resync stages afterwards is exactly what the resync did.
_git_seed_consumer() {
  git -C "${TMP_REPO}" init -q -b main
  git -C "${TMP_REPO}" config user.email t@t
  git -C "${TMP_REPO}" config user.name t
  git -C "${TMP_REPO}" add -A
  git -C "${TMP_REPO}" commit -q -m "chore: seed"
}

# _resync_and_stage
#   The existing-repo half of init.sh's `main`, in main's order: resync,
#   then stage what it wrote. Staging is a step of `main` rather than of
#   `_init_existing_repo` because `.setup.conf` is written between the two
#   (by `_call_setup`, which these unit arms do not run -- it shells out to
#   the real setup.sh; the integration arm covers that file). Calling both
#   here rather than asserting against `_init_existing_repo` alone is what
#   keeps these arms testing the order the released upgrade.sh drives.
_resync_and_stage() {
  _init_existing_repo
  _stage_resync_output
}

# The resync applies the migrations, and until base#1036 nobody staged their
# output: the caller that commits is the consumer's OWN vendored
# upgrade.sh, which stages a pair of filenames hardcoded when it shipped
# (v0.41.0's does not reach the Dockerfile at all). So the file the
# migration had just rewritten stayed uncommitted while the same run
# printed "git push". Staging belongs where the rewrite happens.

# why: The committing caller is a released script that cannot be changed;
# the run that rewrites the file is the only one that can stage it
@test "the resync: stages the Dockerfile its migrations rewrote (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  _git_seed_consumer
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line "Dockerfile"
}

# why: A user's half-finished edit is not the resync's to commit, which is
# what a `git add -A` sweep would make it
@test "the resync: leaves a file no migration touched unstaged (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  printf 'committed\n' > "${TMP_REPO}/NOTES.md"
  _git_seed_consumer
  printf 'my half-finished edit\n' >> "${TMP_REPO}/NOTES.md"
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial "NOTES.md"
}

# The Dockerfile is not the only thing the resync writes. It re-points the
# wrapper symlinks, lands the justfile layering and the monitor workflow,
# and drops the retired root wrappers -- all of it mechanical output of
# the same run, none of it the user's work to review. Leaving that half
# unstaged leaves the branch's own defect standing: the commit still says
# "template references to <ver>" while the tree it describes is on a
# different layout, and the run still ends with "git push".

# why: The wrappers are output of the same mechanical run as the
# Dockerfile, so leaving them out of the commit leaves the tree
# disagreeing with the release the commit claims
@test "the resync: stages the wrappers it installed (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  _git_seed_consumer
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line "justfile"
  assert_line "script/build.sh"
  assert_line ".hadolint.yaml"
}

# why: The resync DELETES the pre-relocation root wrappers, and a deletion
# left out of the commit is the same tree/commit disagreement one
# direction over
@test "the resync: stages the retired root wrapper it removed (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  # The pre-relocation layout: a root symlink the resync drops on sight.
  ln -s ".base/dist/script/docker/wrapper/build.sh" "${TMP_REPO}/build.sh"
  _git_seed_consumer
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only --diff-filter=D
  assert_line "build.sh"
}

# why: "git cannot answer" is not "there is nothing to stage" -- resolving
# it to silent success is how an unstaged rewrite gets pushed
@test "_stage_resync_output: warns when git cannot read the repo (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  _init_existing_repo
  # A worktree checkout whose gitdir has gone -- the shape this repo's own
  # integration specs run in. `rev-parse` exits 128, not 0.
  printf 'gitdir: %s/gone\n' "${TMP_REPO}" > "${TMP_REPO}/.git"
  run _stage_resync_output
  assert_success
  assert_output --partial "could not stage"
}

# why: `git add` fails the WHOLE batch on one path it will not take, so an
# entry pointing outside the repo costs the commit every other path --
# including the Dockerfile this staging exists to commit
@test "_stage_resync_output: a path outside the repo root loses only itself (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  _git_seed_consumer
  _init_existing_repo
  # A record naming somewhere this repo does not reach. No migration
  # writes outside the repo root today; the point is that the day one
  # does, the rewrite it made INSIDE still has to reach the commit.
  STRAY_DIR="$(mktemp -d)"
  printf 'not ours\n' > "${STRAY_DIR}/stray.txt"
  migrated_files() {
    printf '%s\n' "${TMP_REPO}/Dockerfile" "${STRAY_DIR}/stray.txt"
  }

  run _stage_resync_output
  assert_success
  assert_output --partial "stray.txt"

  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line "Dockerfile"
  rm -rf "${STRAY_DIR}"
}

# why: `just base init` is also a repair command for a hand-bootstrapped
# tree, and a directory that is genuinely not a repo is not a problem to
# report
@test "_stage_resync_output: is silent when the tree is no git repo at all (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  _init_existing_repo
  run _stage_resync_output
  assert_success
  refute_output --partial "could not stage"
}

# why: Nothing rewritten is nothing to stage -- and not an error
@test "the resync: stages no Dockerfile when no migration applies (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  _git_seed_consumer
  # Called directly, not through `run`: the resync arms an EXIT trap of its
  # own, and `run` would fire it in the wrapper's context. A non-zero
  # return fails the test here anyway, which is the "does not fail" half.
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial "Dockerfile"
}

# _init_installed_paths answers "what does a consumer CARRY", which is not
# "what did this run WRITE". Eight of the paths behind that list are
# written only under a condition and otherwise left exactly as they were
# found -- the 14 hook stubs, the script/local/ starter pair,
# config/.gitkeep, the monitor workflow, a .hadolint.yaml the user has
# customised, .gitignore, .dockerignore and .setup.conf. Staging the list
# wholesale therefore stages the user's own content in those files and, on
# the real upgrade path, commits it. The arms below name each writer,
# because a fix that reaches only the one that was reported leaves the
# same defect standing seven files over.

# why: init.sh never overwrites a hook stub, so what is in one is the
# user's; staging the published list wholesale commits their half-finished
# hook under a message about a base release
@test "the resync: leaves a hook stub the user wrote unstaged (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  mkdir -p "${TMP_REPO}/script/hooks/pre"
  printf 'exit 0\n' > "${TMP_REPO}/script/hooks/pre/build.sh"
  _git_seed_consumer
  printf 'my half-finished hook\n' >> "${TMP_REPO}/script/hooks/pre/build.sh"
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial "script/hooks/pre/build.sh"
}

# why: script/local/local.sh is REPO-OWNED by the naming contract -- the
# resync seeds it once and a subtree upgrade never clobbers it -- so its
# content after the first run is only ever the repo's own work
@test "the resync: leaves a repo-owned local.sh unstaged (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  mkdir -p "${TMP_REPO}/script/local"
  printf 'main() { :; }\n' > "${TMP_REPO}/script/local/local.sh"
  _git_seed_consumer
  printf 'my own recipe body\n' >> "${TMP_REPO}/script/local/local.sh"
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial "script/local/local.sh"
}

# why: _populate_config keeps an existing config/ untouched, so the
# .gitkeep inside it is whatever the repo put there -- the placeholder is
# seeded once and never rewritten
@test "the resync: leaves an existing config/.gitkeep unstaged (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  mkdir -p "${TMP_REPO}/config"
  printf 'placeholder\n' > "${TMP_REPO}/config/.gitkeep"
  _git_seed_consumer
  printf 'my note about this directory\n' >> "${TMP_REPO}/config/.gitkeep"
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial "config/.gitkeep"
}

# why: the monitor workflow is generated once and then left alone on every
# later run, so a repo that has tuned its schedule owns the file the
# staging step would commit
@test "the resync: leaves an edited monitor workflow unstaged (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  mkdir -p "${TMP_REPO}/.github/workflows"
  printf 'name: Base Version Monitor\n' \
    > "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  _git_seed_consumer
  printf '# my own schedule\n' \
    >> "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial "base-version-monitor.yaml"
}

# why: _create_symlinks deliberately KEEPS a .hadolint.yaml that differs
# from the template rather than re-pointing it, and a file the run refused
# to touch is not the run's to commit
@test "the resync: leaves a customised .hadolint.yaml unstaged (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  printf 'ignored:\n  - DL3008\n' > "${TMP_REPO}/.hadolint.yaml"
  _git_seed_consumer
  printf '  - DL3009\n' >> "${TMP_REPO}/.hadolint.yaml"
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial ".hadolint.yaml"
}

# why: the half of the property that must NOT regress -- a stub this run
# created is the run's own output, and dropping the whole conditional class
# from the commit would put the branch's own defect back one file over
@test "the resync: stages the hook stub it created this run (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  _git_seed_consumer
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line "script/hooks/pre/build.sh"
  assert_line "script/local/local.sh"
  assert_line "config/.gitkeep"
  assert_line ".github/workflows/base-version-monitor.yaml"
}

# _fake_setup_sh <body>
#   Stand in for the real setup.sh at the path _call_setup shells out to.
#   Its arguments are `apply --base-path <REPO_ROOT>`, so $3 is the repo.
_fake_setup_sh() {
  printf '#!/usr/bin/env bash\n%s\n' "${1}" \
    > "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh"
}

# .setup.conf is the one path of this shape whose writer is in another
# PROCESS: setup.sh writes it, on bootstrap or on a stale mount_1 rewrite,
# and leaves it alone on every other run. No in-process record reaches
# across that, so the content across the call is what says whether this run
# wrote the file.

# why: setup.sh leaves an existing .setup.conf alone on every run but a
# bootstrap or a stale-path rewrite, so what is in it is the repo's own
# tuning and staging it commits an edit the user had not finished
@test "the resync: leaves a .setup.conf setup.sh did not touch unstaged (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  printf '[project]\nname = mine\n' > "${TMP_REPO}/.setup.conf"
  _fake_setup_sh 'exit 0'
  _git_seed_consumer
  printf '# my half-finished tuning\n' >> "${TMP_REPO}/.setup.conf"
  _init_existing_repo
  _call_setup
  _stage_resync_output
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial ".setup.conf"
}

# why: the half that must not regress -- a first-time bootstrap writes the
# file, and leaving THAT out of the commit is the tree/commit disagreement
# the staging step exists to close
@test "the resync: stages the .setup.conf setup.sh bootstrapped (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  _fake_setup_sh 'printf "[project]\nname = seeded\n" > "${3}/.setup.conf"'
  _git_seed_consumer
  _init_existing_repo
  _call_setup
  _stage_resync_output
  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line ".setup.conf"
}

# why: the stale-mount_1 rewrite changes a file that was already there, so
# "did it exist before" is the wrong question and only the content answers
@test "the resync: stages a .setup.conf setup.sh rewrote in place (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  printf '[volumes]\nmount_1 = /gone:/work\n' > "${TMP_REPO}/.setup.conf"
  _fake_setup_sh 'printf "[volumes]\nmount_1 = portable\n" > "${3}/.setup.conf"'
  _git_seed_consumer
  _init_existing_repo
  _call_setup
  _stage_resync_output
  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line ".setup.conf"
}

# .gitignore and .dockerignore are the seventh and eighth paths of this
# shape, and the pair the enumeration above missed. _sync_managed_entries
# appends only the canonical entries the file is MISSING and returns
# without a write when none are -- "the common case for an up-to-date
# repo", in its own comment -- and both files carry a hand-maintained
# region above the managed block that the sync documents as never touched.
# So on the ordinary upgrade what is in one is the repo's own work, exactly
# as with a hook stub. Reached through `just base init`, which the code
# calls a repair command; an upgrade cannot reach it because git-subtree
# refuses a dirty tree first.

# _resync_twice_over_edit <file> <user-lines>
#   The shape both arms below need: one resync brings the ignore file up to
#   date, that lands in a commit, the user then appends a rule of their own,
#   and a SECOND resync -- which has nothing left to add -- runs over it.
#   What the second run stages is the question.
_resync_twice_over_edit() {
  : > "${TMP_REPO}/Dockerfile"
  _git_seed_consumer
  _init_existing_repo
  git -C "${TMP_REPO}" add -A
  git -C "${TMP_REPO}" commit -q -m "chore: first resync"
  printf '%s' "${2}" >> "${TMP_REPO}/${1}"
  _resync_and_stage
}

# why: the sync writes nothing when the file already carries every
# canonical entry, so on the ordinary upgrade .gitignore holds only the
# repo's own rules and staging it commits a rule the user had not finished
@test "the resync: leaves a .gitignore it did not write unstaged (#1036)" {
  _source_init
  _resync_twice_over_edit ".gitignore" '# my own rule
secrets/
'
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial ".gitignore"
}

# why: the sibling half of the same list -- .dockerignore is synced by the
# same mechanism, from the same canonical set, and carries the same
# hand-maintained build-context region the sync never touches
@test "the resync: leaves a .dockerignore it did not write unstaged (#1036)" {
  _source_init
  _resync_twice_over_edit ".dockerignore" '# my own context rule
fixtures/
'
  run git -C "${TMP_REPO}" diff --cached --name-only
  refute_output --partial ".dockerignore"
}

# why: the half that must not regress -- the run that actually creates the
# ignore files wrote them, and leaving THOSE out of the commit is the
# tree/commit disagreement the staging step exists to close
@test "the resync: stages the ignore files it wrote this run (#1036)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"
  _git_seed_consumer
  _resync_and_stage
  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line ".gitignore"
  assert_line ".dockerignore"
}

# why: `git add` refuses the WHOLE batch on a path outside the repo, and a
# path spelled out of the repo through the repo root with a `..` segment
# walks straight past a prefix test -- the one input shape the fence
# against that failure was not written for
@test "_stage_resync_output: a dot-dot path out of the repo loses only itself (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  _git_seed_consumer
  _init_existing_repo
  # Same destination as the arm above, different spelling: the path goes
  # THROUGH the repo root and back out of it, so it starts with
  # "${REPO_ROOT}/" while naming somewhere the repo does not reach.
  STRAY_DIR="$(mktemp -d)"
  printf 'not ours\n' > "${STRAY_DIR}/stray.txt"
  migrated_files() {
    printf '%s\n' "${TMP_REPO}/Dockerfile" \
      "${TMP_REPO}/../$(basename -- "${STRAY_DIR}")/stray.txt"
  }

  run _stage_resync_output
  assert_success
  assert_output --partial "stray.txt"

  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line "Dockerfile"
  rm -rf "${STRAY_DIR}"
}

# why: the ignored-path filter matches check-ignore's answer back against
# the strings it fed in, and under the default core.quotePath git C-quotes
# any path carrying a byte over 0x7F -- so the answer never equals the
# question, the ignored path survives the filter, and `git add` reports a
# failure over a batch it did stage
@test "_stage_resync_output: drops a gitignored path git would quote (#1036)" {
  _source_init
  cat > "${TMP_REPO}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  # A derived artifact of the user's, under a name git will not hand back
  # verbatim. Written before the seed so it is ignored, not tracked.
  printf 'caf\xc3\xa9.txt\n' > "${TMP_REPO}/.gitignore"
  printf 'derived\n' > "${TMP_REPO}/$(printf 'caf\xc3\xa9.txt')"
  _git_seed_consumer
  _init_existing_repo
  migrated_files() {
    printf '%s\n' "${TMP_REPO}/Dockerfile" \
      "${TMP_REPO}/$(printf 'caf\xc3\xa9.txt')"
  }

  run _stage_resync_output
  assert_success
  refute_output --partial "could not stage"

  run git -C "${TMP_REPO}" diff --cached --name-only
  assert_line "Dockerfile"
  refute_output --partial "caf"
}

# why: the containment test is the whole fence, so the segment resolution
# it rests on is worth pinning on its own -- including the cases that must
# NOT move, a name that merely begins with dots and a relative path this
# pass has no business rewriting
@test "_init_lexical_path: resolves the segments without touching disk (#1036)" {
  _source_init
  _init_lexical_path "/a/b/../c/./d"
  [[ "${_INIT_LEXICAL_PATH}" == "/a/c/d" ]] \
    || fail "expected /a/c/d, got ${_INIT_LEXICAL_PATH}"
  _init_lexical_path "/a//b/"
  [[ "${_INIT_LEXICAL_PATH}" == "/a/b" ]] \
    || fail "expected /a/b, got ${_INIT_LEXICAL_PATH}"
  # Never above the root: a walk that runs out of segments stops there.
  _init_lexical_path "/a/../.."
  [[ "${_INIT_LEXICAL_PATH}" == "/" ]] \
    || fail "expected /, got ${_INIT_LEXICAL_PATH}"
  # A leading-dots NAME is a name, not a walk.
  _init_lexical_path "/a/..b/c"
  [[ "${_INIT_LEXICAL_PATH}" == "/a/..b/c" ]] \
    || fail "expected /a/..b/c, got ${_INIT_LEXICAL_PATH}"
  # A relative path resolves against a cwd this pass does not know, so it
  # is handed back untouched and the caller drops it as foreign.
  _init_lexical_path "relative/x"
  [[ "${_INIT_LEXICAL_PATH}" == "relative/x" ]] \
    || fail "expected relative/x, got ${_INIT_LEXICAL_PATH}"
}

# why: the two lists are edited in different places for different reasons,
# and a conditional path spelled differently from its published name would
# silently fall back to being staged wholesale again
@test "_init_conditional_paths: every entry is a published installed path (#1036)" {
  _source_init
  # Non-empty first: a missing accessor makes the loop below read nothing
  # and report no stray, which is the same green as a correct list.
  run _init_conditional_paths
  assert_success
  [[ -n "${output}" ]] || fail "_init_conditional_paths named nothing"

  local _stray=""
  local _path
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    _init_installed_paths | grep -qxF -- "${_path}" \
      || _stray+="${_path} "
  done < <(_init_conditional_paths)
  [[ -z "${_stray}" ]] \
    || fail "not in _init_installed_paths: ${_stray}"
}

@test "_init_existing_repo: syncs base-version-monitor.yaml on upgrade (#777)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"   # mark as "existing repo"
  rm -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  _init_existing_repo
  assert [ -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml" ]
}

# ════════════════════════════════════════════════════════════════════
# _preflight_just / _bootstrap_just
# ════════════════════════════════════════════════════════════════════

# Build a clean bin dir holding symlinks to only the externals the
# preflight/bootstrap need (no `just`). The CI image ships `just` in
# /usr/bin alongside coreutils, so trimming PATH to standard dirs cannot
# hide it; a dedicated dir can. Echoes a PATH value (MOCK_DIR first so any
# mock_cmd stubs win) for the caller to scope to a single `run`, leaving
# the test shell's own PATH intact for teardown.
_nojust_path() {
  local _clean="${TMP_REPO}/.nojust"
  mkdir -p "${_clean}"
  local _cmd _src
  for _cmd in date cat mkdir env dirname basename grep sed tr head printf \
              rm chmod ln cp mv test bash sh; do
    _src="$(command -v "${_cmd}" 2>/dev/null)" || continue
    ln -sf "${_src}" "${_clean}/${_cmd}"
  done
  printf '%s' "${MOCK_DIR}:${_clean}"
}

# why: Missing runner -> non-fatal WARN
@test "_preflight_just: warns and exits 0 when just is absent (#607)" {
  _source_init
  PATH="$(_nojust_path)" run _preflight_just
  assert_success
  assert_output --partial "WARN"
  assert_output --partial "just runner not found on PATH"
}

# why: Structured event wired through
@test "_preflight_just: emits the init_just_missing event under LOG_FORMAT=json (#607)" {
  _source_init
  # JSON format carries the structured event name (text format renders the
  # display= message only); assert the registered body is wired through.
  PATH="$(_nojust_path)" LOG_FORMAT=json run _preflight_just
  assert_success
  assert_output --partial '"body":"init_just_missing"'
}

# why: Warning carries install pointer
@test "_preflight_just: install hint points at the documented methods (#607)" {
  _source_init
  PATH="$(_nojust_path)" run _preflight_just
  assert_success
  assert_output --partial "just.systems/install.sh"
  assert_output --partial "--bootstrap-just"
}

@test "_preflight_just: the install hint quotes the pin and calls package managers a fallback (#948)" {
  # The hint used to present apt / brew / cargo / the installer as a menu
  # of equivalent options. Measured 2026-08-28, `apt install just` on
  # Ubuntu 24.04 was 1.21.0 against an installer that fetched 1.52.0 --
  # 37 minors of "equivalent". The hint must name the version this repo
  # pins, offer the installer AT that version, and say that a host
  # package manager is a fallback rather than the same thing.
  _source_init
  local _pin
  _pin="$(/source/dist/script/base/just-version.sh)"
  PATH="$(_nojust_path)" run _preflight_just
  assert_success
  assert_output --partial "${_pin}"
  assert_output --partial "--tag ${_pin}"
  assert_output --partial "FALLBACK, not an equivalent"
}

@test "_just_install_hint: degrades to a placeholder when the pin cannot be read (#948)" {
  # A hint is a WARNING path: it must never abort init. When the
  # declaration is unreadable the hint prints `<unresolved>` and still
  # tells the user what to install, rather than propagating the accessor's
  # failure out of a warning. (Its sibling, _bootstrap_just, INSTALLS, so
  # it takes the opposite branch -- see the next-but-one case.)
  _source_init
  rm -f "${TMP_REPO}/.base/dockerfile/Dockerfile.test-tools"
  PATH="$(_nojust_path)" run _preflight_just
  assert_success
  assert_output --partial "<unresolved>"
  assert_output --partial "just is NOT auto-installed"
}

# why: Runner present -> no warning
@test "_preflight_just: silent and exits 0 when just is present (#607)" {
  _source_init
  mock_cmd "just" 'exit 0'
  run _preflight_just
  assert_success
  refute_output --partial "init_just_missing"
  refute_output --partial "just runner not found"
}

# why: Opt-in bootstrap skips when installed
@test "_bootstrap_just: no-op when just is already on PATH (#607)" {
  _source_init
  mock_cmd "just" 'exit 0'
  run _bootstrap_just
  assert_success
  assert_output --partial "already installed"
  refute_output --partial "Bootstrapping just"
}

# why: Opt-in installer pipeline to ~/.local/bin
@test "_bootstrap_just: runs the official installer into ~/.local/bin when absent (#607)" {
  _source_init
  # Mock curl + bash (the installer pipeline) into MOCK_DIR so it is
  # observable without touching the network. mock_cmd writes to MOCK_DIR,
  # which the no-just PATH puts first.
  mock_cmd "curl" 'echo "CURL_INVOKED $*"'
  # Mock bash echoes what it received on stdin (curl output) + its argv so
  # the whole `curl ... | bash -s -- --to <dir>` pipeline is observable.
  mock_cmd "bash" 'echo "STDIN: $(cat)"; echo "BASH_INSTALLER $*"'
  PATH="$(_nojust_path)" HOME="${TMP_REPO}/home" run _bootstrap_just
  assert_success
  assert_output --partial "Bootstrapping just"
  assert_output --partial "CURL_INVOKED"
  assert_output --partial "install.sh"
  assert_output --partial "BASH_INSTALLER -s -- --to"
  [[ -d "${TMP_REPO}/home/.local/bin" ]] || { echo "~/.local/bin not created"; return 1; }
}

@test "_bootstrap_just: installs the pinned version, not whatever is latest (#948)" {
  # Without --tag the official installer fetches the newest release, so
  # the host ends up on a version nothing else in the repo uses -- the
  # third of the four provenance paths that named no version.
  _source_init
  local _pin
  _pin="$(/source/dist/script/base/just-version.sh)"
  mock_cmd "curl" 'echo "CURL_INVOKED $*"'
  mock_cmd "bash" 'echo "STDIN: $(cat)"; echo "BASH_INSTALLER $*"'
  PATH="$(_nojust_path)" HOME="${TMP_REPO}/home" run _bootstrap_just
  assert_success
  assert_output --partial "--tag ${_pin}"
}

@test "_bootstrap_just: refuses to install anything when the pin cannot be resolved (#948)" {
  # The mirror of the hint's placeholder: this path INSTALLS, so an
  # unresolvable pin must stop it rather than degrade. Falling through
  # would run the installer with no --tag and put "whatever is latest" on
  # the host -- the third of the four unpinned provenance paths, restored.
  _source_init
  rm -f "${TMP_REPO}/.base/dockerfile/Dockerfile.test-tools"
  mock_cmd "curl" 'echo "CURL_INVOKED $*"'
  mock_cmd "bash" 'echo "BASH_INSTALLER $*"'
  PATH="$(_nojust_path)" HOME="${TMP_REPO}/home" run _bootstrap_just
  assert_failure
  assert_output --partial "refusing to install an unpinned runner"
  refute_output --partial "CURL_INVOKED"
}

# why: #692 installer-failure _error path
@test "_bootstrap_just: aborts with a clear error when the installer pipeline fails (#692)" {
  _source_init
  # The curl|bash installer pipeline returns non-zero (network down,
  # broken installer). _bootstrap_just must _error out, not silently
  # claim success. Mock bash (the pipeline tail) to fail.
  mock_cmd "curl" 'echo "CURL_INVOKED $*"'
  mock_cmd "bash" 'cat >/dev/null; exit 1'
  PATH="$(_nojust_path)" HOME="${TMP_REPO}/home" run _bootstrap_just
  assert_failure
  assert_output --partial "just bootstrap failed"
}

# ════════════════════════════════════════════════════════════════════
# _call_setup
# ════════════════════════════════════════════════════════════════════

# why: #692 warn-on-failure degrade
@test "_call_setup: warns but returns 0 when setup.sh exits non-zero (#692)" {
  _source_init
  # A failing setup.sh must degrade to a WARNING, never abort init/upgrade.
  cat > "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  run _call_setup
  assert_success
  assert_output --partial "setup.sh exited non-zero"
}

# why: #692 skip-when-absent branch
@test "_call_setup: skips with a notice when setup.sh is absent (#692)" {
  _source_init
  rm -f "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh"
  run _call_setup
  assert_success
  assert_output --partial "Skipping setup.sh"
}

# why: #692 happy path no-noise
@test "_call_setup: returns 0 on a setup.sh that succeeds (#692)" {
  _source_init
  cat > "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  run _call_setup
  assert_success
  refute_output --partial "exited non-zero"
  refute_output --partial "Skipping setup.sh"
}

# ════════════════════════════════════════════════════════════════════
# _smoke_test_count (S4 item 6 -- derived TEST.md figure source of truth)
# ════════════════════════════════════════════════════════════════════

@test "_smoke_test_count: sums ^@test across the per-stage smoke tree (S4 item 6)" {
  _source_init
  local _wd="${TMP_REPO}/count_repo"
  mkdir -p "${_wd}/test/bats/smoke/shared" \
           "${_wd}/test/bats/smoke/devel-test" \
           "${_wd}/test/bats/smoke/runtime-test"
  printf '@test "a" {\n  true\n}\n@test "b" {\n  true\n}\n' \
    > "${_wd}/test/bats/smoke/shared/env.bats"
  printf '@test "c" {\n  true\n}\n' \
    > "${_wd}/test/bats/smoke/devel-test/extra.bats"
  # .gitkeep placeholders carry no @test and must not inflate the count.
  : > "${_wd}/test/bats/smoke/runtime-test/.gitkeep"
  cd "${_wd}"
  run _smoke_test_count
  assert_success
  assert_output "3"
}

@test "_smoke_test_count: returns 0 when the smoke tree has no specs (S4 item 6)" {
  _source_init
  local _wd="${TMP_REPO}/empty_repo"
  mkdir -p "${_wd}/test/bats/smoke/shared"
  : > "${_wd}/test/bats/smoke/shared/.gitkeep"
  cd "${_wd}"
  run _smoke_test_count
  assert_success
  assert_output "0"
}

# ────────────────────────────────────────────────────────────────────
# _error -- the shared fatal path
#
# It passed the human message where _log_dispatch expects a REGISTERED
# EVENT ID, so every init.sh error surfaced as the logger's own
# "unregistered log body ... add it to log-events.txt" complaint: no
# [init] ERROR framing, no timestamp, no JSON record when piped, and an
# instruction to edit a registry file that means nothing to a user.
# upgrade.sh's sibling gets this right (_log_err upgrade
# upgrade_rollback "display=$*").
# ────────────────────────────────────────────────────────────────────

_stage_missing_template_conf() {
  rm -f "${TMP_REPO}/.base/dist/.setup.conf"
  rm -f "${TMP_REPO}/.setup.conf"
  _source_init
}

@test "_error: carries a registered event id under LOG_FORMAT=json (#876)" {
  _stage_missing_template_conf
  LOG_FORMAT=json run _gen_setup_conf "false"
  assert_failure
  assert_output --partial '"body":"init_failed"'
  refute_output --partial 'unregistered log body'
}

@test "_error: text output is framed like every other init record (#876)" {
  _stage_missing_template_conf
  LOG_FORMAT=text run _gen_setup_conf "false"
  assert_failure
  assert_output --partial '[init] ERROR'
  assert_output --partial 'Template setup.conf not found'
  refute_output --partial 'log-events.txt'
}

@test "_error: the human message rides the display attribute (#876)" {
  _stage_missing_template_conf
  LOG_FORMAT=json run _gen_setup_conf "false"
  assert_failure
  assert_output --partial '"display":"Template setup.conf not found'
}

# ════════════════════════════════════════════════════════════════════
# Existing-repo resync rollback
# ════════════════════════════════════════════════════════════════════
#
# init.sh cannot roll back the way upgrade.sh does. It runs mid-upgrade
# with the subtree pull already committed, so `git reset --hard` would undo
# the caller's work, and the files most worth protecting -- a hand-written,
# gitignored .env -- are not in git at all. "Restore" here therefore means a
# byte copy of the paths the resync can touch, taken before the first
# mutation and put back on failure.

@test "_init_protected_paths: covers the .env pair the env-naming rename moves (#937)" {
  _source_init
  run _init_protected_paths
  assert_success
  assert_line ".env"
  assert_line ".env.local"
}

@test "_init_protected_paths: covers every root the resync writes into (#937)" {
  _source_init
  run _init_protected_paths
  assert_success
  assert_line "Dockerfile"
  assert_line "script"
  assert_line "config"
  assert_line ".gitignore"
  assert_line ".dockerignore"
  assert_line "justfile"
}

# The env-naming rename moves a hand-written, gitignored file. Nothing in
# git can put it back, so the snapshot has to hold the bytes themselves.
@test "_init_restore_tree: an .env moved to .env.local is put back (#937)" {
  _source_init
  printf 'IMAGE_NAME=hand-written\n' > "${TMP_REPO}/.env"
  _init_snapshot
  mv "${TMP_REPO}/.env" "${TMP_REPO}/.env.local"

  _init_restore_tree
  assert [ -f "${TMP_REPO}/.env" ]
  assert [ ! -e "${TMP_REPO}/.env.local" ]
  [ "$(cat "${TMP_REPO}/.env")" = "IMAGE_NAME=hand-written" ]
  _init_rollback_cleanup
}

@test "_init_restore_tree: removes what the resync created (#937)" {
  _source_init
  _init_snapshot
  mkdir -p "${TMP_REPO}/script/hooks/pre"
  : > "${TMP_REPO}/script/hooks/pre/build.sh"
  ln -sf script/justfile "${TMP_REPO}/justfile"

  _init_restore_tree
  assert [ ! -e "${TMP_REPO}/script" ]
  assert [ ! -e "${TMP_REPO}/justfile" ]
  _init_rollback_cleanup
}

@test "_init_restore_tree: restores a rewritten file byte for byte (#937)" {
  _source_init
  printf 'FROM busybox\nCOPY .base/config /tmp/config\n' > "${TMP_REPO}/Dockerfile"
  _init_snapshot
  printf 'FROM busybox\nCOPY .base/dist/config /tmp/config\n' > "${TMP_REPO}/Dockerfile"

  _init_restore_tree
  [ "$(cat "${TMP_REPO}/Dockerfile")" = "$(printf 'FROM busybox\nCOPY .base/config /tmp/config')" ]
  _init_rollback_cleanup
}

# A restore that cannot find its own copy must not "restore" by deleting.
# Reporting failure is the whole contract: a rollback that quietly removes
# the user's file is worse than the half-written state it was undoing.
@test "_init_restore_tree: refuses to delete when its snapshot copy is missing (#937)" {
  _source_init
  printf 'IMAGE_NAME=hand-written\n' > "${TMP_REPO}/.env"
  _init_snapshot
  rm -f "${_INIT_ROLLBACK_DIR}/tree/.env"

  run _init_restore_tree
  assert_failure
  assert [ -f "${TMP_REPO}/.env" ]
  [ "$(cat "${TMP_REPO}/.env")" = "IMAGE_NAME=hand-written" ]
  _init_rollback_cleanup
}

# The rollback is armed with an EXIT trap. When init.sh is sourced rather
# than executed, that trap is installed into someone else's shell, so a
# successful resync has to hand it back exactly as it found it.
@test "_init_existing_repo: hands back the caller's EXIT trap on success (#937)" {
  : > "${TMP_REPO}/Dockerfile"
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1091
    source "$1/.base/dist/script/base/init.sh"
    trap "echo CALLER-TRAP-RAN" EXIT
    _init_existing_repo >/dev/null 2>&1
    trap -p EXIT
  ' _ "${TMP_REPO}"
  assert_success
  assert_output --partial "CALLER-TRAP-RAN"
  assert_output --partial "echo CALLER-TRAP-RAN"
}

# ════════════════════════════════════════════════════════════════════
# _populate_config -- the one text base seeds into every new repo about
# config/, and the two DIFFERENT channels that directory feeds
# (ADR-00000030).
#
# A repo's config/ is read twice, at two moments, for two purposes, and
# the placeholder used to describe only the first:
#
#   * build time: the Dockerfile's layered COPY into /tmp/config, deleted
#     in the same RUN -- the shell / pip template-override overlay.
#   * dev and field: every config/<component>/ bind-mounted at
#     /opt/app/config/<component> in development and COPY-baked at the
#     same path for deploy (PRD invariant 8's two opposite means).
#
# The second is where a repo puts its actual app config, and it is the one
# a repo author has to be told about, because nothing about an empty
# directory suggests it. So the placeholder must NAME the component
# directory, the path it lands on, and the manifest that makes one of its
# files field-tunable -- the three terms a reader needs in order to search
# for the rest.
# ════════════════════════════════════════════════════════════════════

# why: the seeded text names the structured channel
@test "_populate_config: the seeded placeholder names the config/<component>/ channel" {
  _source_init
  _populate_config
  run cat "${TMP_REPO}/config/.gitkeep"
  assert_output --partial "config/<component>/"
  assert_output --partial "/opt/app/config/<component>"
  assert_output --partial "deploy.manifest"
}

# why: the seeded text keeps the build-time channel
@test "_populate_config: the seeded placeholder still names the build-time overlay" {
  _source_init
  _populate_config
  run cat "${TMP_REPO}/config/.gitkeep"
  assert_output --partial ".base/dist/config/"
}

# why: seeded text and the record use one vocabulary
@test "_populate_config: the seeded placeholder and ADR-00000030 name the convention identically" {
  # The convention now lives in two artifacts by design, and ADR-00000028
  # is the reason that needs a guard rather than a shrug: the ADR carries
  # the RATIONALE (why a symlink, why no audience level) and the
  # placeholder carries the INSTRUCTION, at the one moment a repo author
  # meets config/. Different jobs, so neither is derivable from the other
  # -- but they share the convention's proper nouns, and a rename that
  # reaches only one of them leaves a new repo being told to create
  # something the record no longer describes.
  #
  # The three terms are LISTED, not derived from the placeholder's text,
  # and the reason is worth stating because this repo prefers derivation
  # (PRD design principle P2). The placeholder also documents the
  # build-time template overlay, whose examples (config/shell/bashrc and
  # friends) the ADR has no reason to mention at all, so a derivation over
  # the whole text would assert agreement the two artifacts do not owe
  # each other. These three are the structured channel's names, and the
  # set is closed because the convention is.
  _source_init
  _populate_config
  local _adr=/source/doc/adr/00000030-config-component-layout-and-preset-selector.md
  local _seed="${TMP_REPO}/config/.gitkeep"
  local _term
  for _term in 'config/<component>/' 'deploy.manifest' '.example.'; do
    grep -qF -- "${_term}" "${_seed}" \
      || { echo "the seeded placeholder no longer names: ${_term}"; return 1; }
    grep -qF -- "${_term}" "${_adr}" \
      || { echo "ADR-00000030 does not name: ${_term}"; return 1; }
  done
}
