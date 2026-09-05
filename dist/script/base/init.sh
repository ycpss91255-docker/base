#!/usr/bin/env bash
# init.sh - Initialize a repo with template
#
# Full setup from scratch (git subtree add needs HEAD, so an initial commit is
# required before adding the subtree):
#   mkdir <repo_name> && cd <repo_name>
#   git init
#   git commit --allow-empty -m "chore: initial commit"
#   git subtree add --prefix=.base \
#       https://github.com/ycpss91255-docker/base.git main --squash
#   ./.base/dist/script/base/init.sh
#
# (Substitute `git@github.com:...` for SSH if you have a key configured.)
#
# Steady-state users call `just base init`; the raw path above is only the
# one-time bootstrap before `just` is wired up.
#
# Auto-detects:
#   - Carries a published signal (`--list-existing-repo-signals`; today
#     `Dockerfile`) → existing repo: create symlinks
#   - Carries none of them → new repo: generate full project structure

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# init.sh lives deep in the subtree (.base/dist/script/base/init.sh,
# relocated in  ADR-00000011 §8 / ADR-00000006 Region A). Walk up from
# the script's own directory to the subtree root -- the directory carrying
# the subtree markers `.version` + `dist/` -- so TEMPLATE_DIR is the
# subtree root regardless of how deep the script is nested. The subtree
# prefix is its basename, used DIRECTLY as the symlink-target prefix below,
# so a downstream rename still works without code changes.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly SCRIPT_DIR
TEMPLATE_DIR="${SCRIPT_DIR}"
while [[ "${TEMPLATE_DIR}" != "/" ]]; do
  [[ -f "${TEMPLATE_DIR}/.version" && -d "${TEMPLATE_DIR}/dist" ]] && break
  TEMPLATE_DIR="$(cd -- "${TEMPLATE_DIR}/.." && pwd -P)"
done
[[ -f "${TEMPLATE_DIR}/.version" ]] || {
  echo "init.sh: cannot locate subtree root above ${SCRIPT_DIR}" >&2
  exit 1
}
readonly TEMPLATE_DIR
REPO_ROOT="$(cd -- "${TEMPLATE_DIR}/.." && pwd -P)"
readonly REPO_ROOT
TEMPLATE_REL="$(basename "${TEMPLATE_DIR}")"
readonly TEMPLATE_REL

# shellcheck source=dist/script/base/upstream.sh
source "${SCRIPT_DIR}/upstream.sh"
# The one definition of the pinned `just` runner version, shared with the
# tooling image and the CI e2e job. Sourced (not executed) so the hint and
# the bootstrap below read the same value from one place.
# shellcheck source=dist/script/base/just-version.sh
source "${SCRIPT_DIR}/just-version.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/gitignore.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/_lib.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/template_guard.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/dockerfile_migrate.sh"

_log() { _log_info init init_progress "display=$*"; }

# ── Symlink helper ──────────────────────────────────────────────────────────

_symlink() {
  local target="$1" link="$2"
  if [[ -L "${link}" || -f "${link}" ]]; then
    rm -f "${link}"
  fi
  ln -sf "${target}" "${link}"
  _log "  ${link} -> ${target}"
}

_create_symlinks() {
  _log "Creating symlinks:"
  # the seven user-facing wrappers live under script/ now, with
  # link targets relative to the link's directory ("../" prefix).
  # the root user entry is the `justfile` (the container-ops
  # Makefile was retired); recipes forward to ./script/<verb>.sh.
  mkdir -p script
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/build.sh" "script/build.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/run.sh" "script/run.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/exec.sh" "script/exec.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/stop.sh" "script/stop.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/prune.sh" "script/prune.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/setup.sh" "script/setup.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/setup_tui.sh" "script/setup_tui.sh"
  # Migration hygiene: drop root *.sh symlinks (now under
  # script) plus the pre-setup_tui-rename `tui.sh` legacy name. The
  # [[ -L X ]] guard makes the loop idempotent on already-migrated
  # repos and silent on very old forks that never carried setup.sh /
  # setup_tui.sh at root.
  # Migration hygiene also drops the retired root `Makefile` symlink
  # (ADR-00000005 phase 2): base no longer ships a container-ops
  # Makefile, so an upgrading repo's stale root symlink must go or it
  # dangles. (The base-only `justfile.test` is unrelated -- it is a
  # regular file under `.base/`, never a root symlink.)
  #
  # The removal is RECORDED (_init_record_write) where it happens, for the
  # reason every other conditional write is: the guard above is the
  # condition, it is gone by the time the staging step runs, and a consumer
  # carrying a hand-written REGULAR file at one of these names still has it,
  # untouched, when that step asks what to commit. Staging the name instead
  # of the record puts their file in a commit about a base release.
  local _stale
  while IFS= read -r _stale; do
    if [[ -L "${_stale}" ]]; then
      rm -f "${_stale}"
      _init_record_write "${_stale}"
      _log "  Removed stale root symlink ${_stale}"
    fi
  done < <(_init_retired_root_paths)
  # ADR-00000005 / ADR-00000010 / ADR-00000011: `just` is the user-facing
  # entry, now layered + fully namespaced. <repo>/justfile -> script/justfile
  # -> .base/dist/script/justfile (the entry), which `mod?`s the docker
  # + base namespaces. mod paths in the entry resolve relative to the repo
  # root (the symlink location), so each module is linked at its
  # <repo>/script/<ns>/justfile.<ns> path.
  mkdir -p script/docker script/base
  _symlink "script/justfile" "justfile"
  _symlink "../${TEMPLATE_REL}/dist/script/justfile" "script/justfile"
  _symlink "../../${TEMPLATE_REL}/dist/script/docker/justfile.docker" "script/docker/justfile.docker"
  # `base` namespace: `just base upgrade` / `just base update`
  # manage the .base subtree (apt-aligned); `just base init` re-wires symlinks;
  # `just base completions` installs opt-in shell tab-completion.
  _symlink "../../${TEMPLATE_REL}/dist/script/base/justfile.base" "script/base/justfile.base"
  _symlink "../../${TEMPLATE_REL}/dist/script/base/completions.sh" "script/base/completions.sh"
  # `template` namespace: `just template new <name>` scaffolds a
  # repo-local command group. The entry `mod?`s script/template/justfile.template;
  # new.sh + skel/ are linked alongside (base-owned, flow on upgrade).
  mkdir -p script/template
  _symlink "../../${TEMPLATE_REL}/dist/script/template/justfile.template" "script/template/justfile.template"
  _symlink "../../${TEMPLATE_REL}/dist/script/template/new.sh" "script/template/new.sh"
  _symlink "../../${TEMPLATE_REL}/dist/script/template/skel" "script/template/skel"

  if [[ ! -f .hadolint.yaml ]] \
    || diff -q .hadolint.yaml "${TEMPLATE_REL}/dist/.hadolint.yaml" \
      >/dev/null 2>&1; then
    _symlink "${TEMPLATE_REL}/dist/.hadolint.yaml" ".hadolint.yaml"
    _init_record_write ".hadolint.yaml"
  else
    _log "  Keeping custom .hadolint.yaml (differs from template)"
  fi

  _populate_config
  _seed_local
}

# _populate_config
#
# On first init (no <repo>/config), create an empty placeholder
# directory at `<repo>/config/` with a `.gitkeep`.
#
# The `.gitkeep` is the only thing base ever tells a repo author about
# `config/`, and that directory feeds TWO channels, not one: the
# build-time template overlay described below, and the structured
# app-config channel (`config/<component>/`, bind-mounted at
# `/opt/app/config/<component>` in development and baked at the same path
# for deploy -- PRD invariant 8's two opposite means). So the placeholder
# states both, plus the `config/<component>/` shape convention and the
# preset selector (ADR-00000030); nothing about an empty directory would
# suggest any of it, and a convention nobody is told is one every repo
# re-invents. It reaches NEW repos only -- an existing `config/` is
# preserved untouched by the guard below, deliberately, because that
# directory is the user's. The Dockerfile's
# layered COPY chain (template#254) reads `.base/dist/config/` first
# as the default layer and `<repo>/config/` second as the override
# overlay; an empty <repo>/config/ means "no overrides, take all
# template defaults". Downstream adds files under <repo>/config/
# only when they want to override a specific template default.
#
# Rationale (compared to the full-copy seed):
#   * a symlink would make edits spill into the subtree and fight
#     `git subtree pull`;
#   * a plain Dockerfile COPY from `.base/dist/config/` alone would
#     deny the user any per-repo override path at all;
#   * a full-copy seed gives the user a clean
#     repo-local editing surface but freezes their config at the
#     init-time template version -- subsequent template-side
#     improvements drift, requiring manual diff/reconcile;
#   * an EMPTY placeholder lets the layered COPY do
#     the merge at build time. Repos opt into per-file overrides
#     only when they need them; everything else flows through
#     from .base/dist/config/ on every build, keeping
#     <repo>/config/ small and the override-vs-default contract
#     visible in `git status` / `git diff`.
#
# Existing repos with a full <repo>/config/ snapshot from a
# pre-v0.22.0 init keep working unchanged: their copy still
# overrides every template default at build time, identical to
# behaviour. They can manually trim files that match
# template default to start receiving template-side improvements.
_populate_config() {
  # User already has a real config/ — preserve (contains their edits
  # or full-copy snapshot, both layered correctly).
  if [[ -d config && ! -L config ]]; then
    _log "  Keeping existing config/ directory"
    return 0
  fi
  # Stale symlink from an earlier init.sh version — drop it before
  # creating the placeholder. Without rm, `mkdir` would fail if the
  # symlink target is a real dir, or pollute the subtree if it's a
  # .base/dist/config/ symlink.
  if [[ -L config ]]; then
    rm -f config
  fi
  # Create empty placeholder + .gitkeep so the dir exists in git
  # (Docker COPY of <repo>/config/ requires the path to exist).
  mkdir -p config
  _init_record_write "config/.gitkeep"
  cat > config/.gitkeep <<'EOF'
# Placeholder so this directory exists in git. This directory is read
# TWICE, at two moments, and what you put where decides which.
#
# 1. Template overrides, at BUILD time. The Dockerfile's layered COPY
#    reads .base/dist/config/ first, then overlays <repo>/config/ on top,
#    into /tmp/config -- which is deleted in the same RUN. Drop a file
#    here only to override a specific template default
#    (e.g. <repo>/config/shell/bashrc to override the template's bashrc,
#    or <repo>/config/shell/bashrc.d/your-snippet.sh to add a drop-in).
#    Files NOT placed here keep flowing through from .base/dist/config/
#    on every build.
#
# 2. YOUR APP'S OWN CONFIG, in a directory of its own: config/<component>/
#    (config/realsense/, config/ros1_bridge/). Every such directory is
#    bind-mounted at /opt/app/config/<component> in development -- edit on
#    the host, restart, no rebuild -- and COPY-baked at the same path into
#    a deployable image, which is how one config survives both. A regular
#    file sitting directly under config/ gets NEITHER; `just setup` warns
#    about it by name.
#
#    Inside config/<component>/, group by kind only once a kind has more
#    than one file. Name a copy-me template <name>.example.<ext>, keeping
#    the real extension last. Do NOT add an audience level
#    (official/custom/internal/): which files a field operator may retune
#    is declared in config/<component>/deploy.manifest, one section per
#    deployable stage, and a directory that says it too can only disagree.
#    A file kept only to be diffed against upstream is a test fixture, not
#    config -- keep it out of config/, or it is mounted and baked for
#    nothing.
#
#    When a component ships several curated presets and the repo bakes one
#    of them, say WHICH with a committed repo-root symlink into
#    config/<component>/ -- e.g. camera.yaml -> config/realsense/yaml/none.yaml
#    -- and COPY it through a build ARG whose default is that symlink's
#    name, so `--build-arg` overrides one build without touching the tree.
#    `just setup` names every selector and the preset it currently points
#    at.
EOF
  _log "  Created empty config/ placeholder (.base/dist/config/ is the default layer; <repo>/config/ overlays per-file)"
}

# _seed_local
#
# Seed the REPO-OWNED script/local/ starter pair (ADR-00000010): the
# command-group registry justfile.local + a companion bash template
# local.sh. Both are real files the repo commits, never overwritten by a
# subtree upgrade, mirroring the skel/ pair pattern (justfile.skel +
# skel.sh) that `just template new` uses. Each file has its OWN
# non-clobber guard, so an existing repo carrying only justfile.local (a
# pre-S4 init) still picks up local.sh on its next upgrade, and vice
# versa -- neither guard short-circuits the other.
_seed_local() {
  mkdir -p script/local
  if [[ -f script/local/justfile.local ]]; then
    _log "  Keeping existing script/local/justfile.local"
  else
    cat > script/local/justfile.local <<'EOF'
# Repo-local just command groups (registry). REPO-OWNED: committed by this
# repo, never clobbered by a base subtree upgrade. The base entry imports
# this file optionally (`import?`), so an empty registry is fine.
#
# Register a group with one `mod?` line (path relative to this file's dir,
# i.e. script/local):
#
#   mod? deploy 'deploy/justfile.deploy'
#
# then `just deploy <recipe>` runs it. Scaffold a new group with
# `just template new <name>` -- it appends the `mod?` line here for you.
#
# A companion bash template ships beside this file as local.sh. Wire it to
# a recipe you add here, e.g.:
#
#   local-hello:
#       @./local.sh
EOF
    _init_record_write "script/local/justfile.local"
    _log "  Created script/local/justfile.local (repo-local command-group registry)"
  fi

  if [[ -f script/local/local.sh ]]; then
    _log "  Keeping existing script/local/local.sh"
  else
    cat > script/local/local.sh <<'EOF'
#!/usr/bin/env bash
# local.sh -- companion bash template for repo-local just recipes.
#
# REPO-OWNED: committed by this repo, never clobbered by a base subtree
# upgrade (like justfile.local beside it). It is a starting point -- replace
# the body with your own logic and back a recipe in justfile.local, e.g.:
#
#   local-hello:
#       @./local.sh
#
# For a fuller, namespaced command group prefer `just template new <name>`,
# which scaffolds script/local/<name>/{justfile.<name>,<name>.sh} and
# registers it for you; this top-level local.sh is the lightweight option.
set -euo pipefail

main() {
  echo "hello from script/local/local.sh -- edit me"
}

main "$@"
EOF
    chmod +x script/local/local.sh
    _init_record_write "script/local/local.sh"
    _log "  Created script/local/local.sh (companion bash template)"
  fi
}

_detect_template_version() {
  # Prefer .version file inside template (auto-synced by subtree pull)
  local version_file="${TEMPLATE_DIR}/.version"
  if [[ -f "${version_file}" ]]; then
    tr -d '[:space:]' < "${version_file}"
    return 0
  fi
  # Fallback: query remote tags (for fresh subtree add before .version existed).
  # Default from the one shared upstream constant (upstream.sh); override
  # via the TEMPLATE_REMOTE env var (SSH, or a private fork) -- see README
  # "Pointing .base at a different upstream".
  local _remote="${TEMPLATE_REMOTE:-${BASE_UPSTREAM_REMOTE}}"
  # In-shell scan, for the reason upgrade.sh's _get_latest_version carries
  # at length: `... | head -1 | sed ...` hands the answer to a reader that
  # stops reading, the `grep -oP` still writing dies of SIGPIPE, `pipefail`
  # makes 141 the pipeline's status, and the `|| true` that stopped the
  # resulting abort discarded the status with it -- leaving an EMPTY
  # version that reads as "the remote has no tags". Nothing here can be
  # killed by a reader that stopped reading, because there is no reader.
  # `--sort=-v:refname` puts the newest first, so the first vX.Y.Z ref
  # wins and rc / pre-release tags are skipped.
  local _line _ref _result=""
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ -n "${_result}" ]]; then
      continue
    fi
    # "<sha><TAB><ref>"; strip through the last run of whitespace, for the
    # reason upgrade.sh's twin spells out -- the replaced `grep -oP`
    # matched the ref anywhere on the line.
    _ref="${_line##*[[:space:]]}"
    if [[ "${_ref}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      _result="${_ref#refs/tags/}"
    fi
  done < <(git ls-remote --tags --sort=-v:refname "${_remote}" 2>/dev/null)
  printf '%s' "${_result}"
}

# ── New repo scaffolding ────────────────────────────────────────────────────

# _init_existing_repo_signals
#   Every repo-relative path whose presence means "this repo has been set up
#   before", one per line, sorted (LC_ALL=C) and duplicate-free. It is the
#   whole of the new-vs-existing decision: `_init_repo_is_existing` below
#   reads nothing else, so the list and the branch cannot disagree.
#
#   WHY IT IS PUBLISHED. The decision is a PROXY. A file only an initialized
#   repo was supposed to carry stands in for "initialized", and that holds
#   only while nothing ELSE ships the file. It inverted once: the template
#   began shipping a `Dockerfile`, so every repo bootstrapped from it arrived
#   carrying the proxy, took the existing-repo branch, and never got the
#   new-repo scaffold -- no CI workflow, no changelog, no smoke tree. Months
#   passed and no test failed, because the proxy existed only as a condition
#   inside `main`: nothing outside this file could name what it depended on.
#
#   Printing it (`--list-existing-repo-signals`) is what makes the assumption
#   checkable from where the collision actually happens. The template repo is
#   the one place the shipped file set and the vendored installer are both on
#   disk, and its guard derives the discriminator from this list rather than
#   restating the condition -- a restatement being the thing that goes stale.
#
#   A signal must be a file the new-repo path itself creates. One that is not
#   can never flip a repo from new to existing on its own, so it can only
#   arrive from somewhere else, which is precisely the inversion above.
#   test/bats/integration/init_existing_repo_signals_spec.bats runs a real
#   init per published path and reads the branch off the artifacts.
_init_existing_repo_signals() {
  cat <<'EOF'
Dockerfile
EOF
}

# _init_repo_is_existing
#   True when the repo at cwd carries any published signal. Same test the
#   branch has always made (`[[ -f Dockerfile ]]`), asked of the list instead
#   of a literal.
_init_repo_is_existing() {
  local _signal
  while IFS= read -r _signal; do
    [[ -n "${_signal}" ]] || continue
    if [[ -f "${_signal}" ]]; then
      return 0
    fi
  done < <(_init_existing_repo_signals)
  return 1
}

_detect_repo_name() {
  basename "${REPO_ROOT}"
}

# _smoke_test_count -- total `^@test` count across the freshly-generated
# per-stage smoke specs under test/bats/smoke/. This is the SAME source of
# truth base's script/test/sync-doc-counts.sh uses (`grep -c '^@test'`),
# reimplemented inline because that script lives in base's own tree, not the
# shipped subtree (dist/), so init.sh cannot source it from a consumer's
# .base/. Keeps the generated doc/test/TEST.md figure equal to what the
# generated specs actually contain. Run with cwd = REPO_ROOT (main cd's
# there before scaffolding).
_smoke_test_count() {
  local _f _sum=0 _c
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _f in test/bats/smoke/**/*.bats; do
    [[ -f "${_f}" ]] || continue
    _c="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _sum=$(( _sum + ${_c:-0} ))
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_sum}"
}

_create_new_repo() {
  local ref="${1:-main}"
  local name=""
  name="$(_detect_repo_name)"
  _log "Creating new repo: ${name}"

  # Dockerfile
  cp "${TEMPLATE_DIR}/dist/dockerfile/Dockerfile" Dockerfile
  _log "  Created Dockerfile (from template)"

  # compose.yaml is a derived artifact generated by setup.sh based on
  # setup.conf; _call_setup at the end of this flow will emit it.

  # script/entrypoint.sh
  mkdir -p script
  cp "${TEMPLATE_DIR}/dist/dockerfile/entrypoint.sh" script/entrypoint.sh
  chmod +x script/entrypoint.sh
  _log "  Created script/entrypoint.sh"

  # test/bats/smoke/<stage>/ -- per-Dockerfile-stage smoke tree, tool-first
  # (bats layer), mirroring .base/dist/test/bats/smoke/. shared/ runs on
  # every -test stage; devel-test/ and runtime-test/ hold stage-specific
  # specs. The repo-specific env spec asserts entrypoint + bash, both
  # present in every stage, so it lands under shared/. The per-stage
  # devel-test/ and runtime-test/ folders start empty (a .gitkeep
  # placeholder) so the Dockerfile's per-stage selective COPY resolves
  # before the consumer adds specs -- including the commented-out
  # runtime-test COPY block, which needs the folder to exist the moment
  # the runtime split is enabled. Mirrors the dist smoke tree 1:1 (S3).
  mkdir -p test/bats/smoke/shared test/bats/smoke/devel-test \
    test/bats/smoke/runtime-test
  cat > "test/bats/smoke/shared/${name}_env.bats" <<BATS
#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the \`devel\` image built
# from this repo's Dockerfile, via the \`devel-test\` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, assert_pip_pkg, ...) to keep
# assertions terse. Add one assertion per meaningful installation
# artifact. Assertions here run on EVERY -test stage (shared/), so keep
# them to the universal surface; put stage-specific checks under
# test/bats/smoke/<stage>/.

setup() {
  load "\${BATS_TEST_DIRNAME}/test_helper"
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}
BATS
  cat > test/bats/smoke/devel-test/.gitkeep <<'KEEP'
# Reserved for devel-test-only smoke specs. Empty until a devel-test
# specific assertion is added; the shared/ baseline still runs here.
KEEP
  cat > test/bats/smoke/runtime-test/.gitkeep <<'KEEP'
# Reserved for runtime-test-only smoke specs (opt-in runtime split). Empty
# until the runtime stage is enabled and a runtime-specific assertion is
# added; the shared/ baseline still runs here. The placeholder keeps the
# folder present so the Dockerfile's commented-out runtime-test COPY block
# resolves the moment the split is turned on.
KEEP
  _log "  Created test/bats/smoke/shared/${name}_env.bats"

  # .github/workflows/main.yaml
  #
  # Emitted HERE and nowhere else, so the job-scoped grant below reaches
  # newly created repos only, and that was checked rather than assumed.
  # An existing repo's main.yaml is its own hand-maintained file (extra
  # jobs, a pinned tag), so init deliberately never rewrites it -- and the
  # never-overwrite shape used for base-version-monitor.yaml would be a
  # no-op on a repo that already has the file, which every already-seeded
  # downstream does. This function is also unreachable through
  # bootstrap.sh today: the template ships a Dockerfile, so init takes the
  # existing-repo branch instead. Re-granting an already-seeded downstream
  # is delivery work tracked on its own, not this seed's; both halves of
  # the boundary are pinned in
  # test/bats/integration/init_new_repo_spec.bats.
  mkdir -p .github/workflows
  cat > .github/workflows/main.yaml <<YAML
name: Main CI/CD

on:
  push:
    branches: [main, master]
    tags:
      - 'v*'
  pull_request:
  workflow_dispatch:

jobs:
  call-docker-build:
    # The build worker checks out and builds; it pushes no image and
    # touches no package, so the build call stays read-only. A called
    # workflow can only narrow this grant, never widen it.
    permissions:
      contents: read
    uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/build-worker.yaml@${ref}
    with:
      image_name: ${name}

  call-release:
    needs: call-docker-build
    if: startsWith(github.ref, 'refs/tags/')
    # call-release uses softprops/action-gh-release@v2, which needs
    # contents: write to create a GitHub Release. A called workflow can
    # only narrow the grant it is handed, and GitHub Actions' default
    # GITHUB_TOKEN is read-only, so this grant must live here
    # (release-worker.yaml declaring it upstream is not enough). It sits on
    # this job rather than at the workflow scope so call-docker-build does
    # not inherit a write it never uses.
    permissions:
      contents: write
    uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/release-worker.yaml@${ref}
    with:
      archive_name_prefix: ${name}
YAML
  _log "  Created .github/workflows/main.yaml"

  # .github/workflows/base-version-monitor.yaml (per-repo upgrade reminder)
  _sync_base_monitor_workflow

  # .gitignore: source canonical set from lib/gitignore.sh so future
  # template-added derived artifacts propagate via the existing-repo
  # sync path on next upgrade. PR-B adds the [logging]
  # local_path managed block here so new repos start with the right
  # entries without waiting for the first setup.sh apply.
  _sync_gitignore "${REPO_ROOT}/.gitignore"
  _sync_logging_gitignore "${REPO_ROOT}"
  _log "  Created .gitignore"

  # .dockerignore: same derived-artifact set as .gitignore so generated
  # files (.env / compose.yaml / coverage/ ...) never bloat the Docker
  # build context. Per-repo build-context lines stay hand-maintained
  # above the managed block.
  _sync_dockerignore "${REPO_ROOT}/.dockerignore"
  _log "  Created .dockerignore"

  # doc/
  mkdir -p doc/test doc/changelog
  cat > README.md <<MD
# ${name}

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

## Quick Start

\`\`\`bash
./build.sh && ./run.sh
\`\`\`

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.
MD

  for lang_file in "README.zh-TW.md" "README.zh-CN.md" "README.ja.md"; do
    cat > "doc/${lang_file}" <<MD
# ${name}

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**
MD
  done
  _log "  Created README.md + doc/ translations"

  # TEST.md figures are DERIVED, never hardcoded: count `^@test` across the
  # smoke specs just generated (same source of truth as sync-doc-counts.sh)
  # so the total matches reality, and use a `### <path> (N)` level-3 heading
  # the auto-counter can actually match (the pre-S4 scaffold shipped a stale
  # "**1 test**" under a `##` heading the counter's regex skipped).
  local _smoke_spec="test/bats/smoke/shared/${name}_env.bats"
  local _smoke_total _shared_n
  _smoke_total="$(_smoke_test_count)"
  _shared_n="$(grep -cE '^@test' "${_smoke_spec}" 2>/dev/null || true)"
  cat > doc/test/TEST.md <<MD
# TEST.md

Smoke tests: **${_smoke_total:-0} tests** total.

Build-time smoke specs run inside each Dockerfile \`-test\` stage. Specs live
under \`test/bats/smoke/{shared,devel-test,runtime-test}/\`; \`shared/\` runs on
every \`-test\` stage, the per-stage folders hold stage-specific assertions.
The figure above is the total \`@test\` count across all stage folders, kept
in sync with \`grep -cE '^@test'\` (base's \`sync-doc-counts.sh\` source of
truth) -- regenerate it when you add or remove specs.

## Smoke specs

### ${_smoke_spec} (${_shared_n:-0})

| Test | Description |
|------|-------------|
| \`entrypoint.sh is installed and executable\` | Entrypoint present + executable |
| \`bash is available on PATH\` | bash resolvable on PATH |
MD
  _log "  Created doc/test/TEST.md"

  cat > doc/changelog/CHANGELOG.md <<MD
# Changelog

## [Unreleased]

### Added
- Initial release
MD
  _log "  Created doc/changelog/CHANGELOG.md"

  # hook scaffolding under script/hooks/{pre,post}/.
  _create_hook_stubs
  _log "  Created script/hooks/{pre,post}/ stubs"
}

# ── Existing-repo resync rollback ───────────────────────────────────────────
#
# The resync rewrites files the CONSUMER owns -- the Dockerfile's COPY
# sources, .gitignore / .dockerignore, the wrapper symlinks -- and it runs
# inside an upgrade that has ALREADY committed the subtree pull. Whether a
# rewrite that fails partway is undone used to depend entirely on WHICH
# caller drove it: the current upgrade.sh arms an EXIT trap around its whole
# post-pull window, the vendored v0.41.0 copy every deployed consumer still
# runs has no trap at all, and `just base init` has none either. Protection
# that lives in the caller therefore reaches only the caller that does not
# need it. It lives here instead, so the guarantee travels with the
# mutation rather than with whoever happened to invoke it.
#
# WHAT "RESTORE" MEANS HERE. upgrade.sh restores with `git reset --hard`
# plus a sweep of the paths that became untracked. init.sh cannot do either.
# It runs mid-upgrade with the pull already committed, so a reset would undo
# the CALLER'S work -- history is the caller's to own, and this rollback
# touches none of it. It cannot lean on git for content either: a `.env` is
# gitignored, and a `just base init` over a dirty tree would lose the user's
# uncommitted edits. So the snapshot is a BYTE COPY of every root the resync
# can write into, taken before the first mutation and kept OUTSIDE the repo
# (a copy inside it would show up in the caller's own untracked sweep).
# Restoring replaces each root wholesale, which returns what the run
# deleted and removes what it created in one step. The index is restored
# separately, because the resync's `git rm --cached` of now-derived
# artifacts is state the working tree cannot show.
#
# HOW THE TWO TRAPS COMPOSE. Every caller runs init.sh as a SEPARATE
# PROCESS -- upgrade.sh Step 3 and the `just base init` recipe both invoke
# the script -- so the two traps never share a shell and cannot disarm each
# other. This one fires when init.sh exits, restores the files init.sh
# rewrote, touches no history, and exits non-zero; the caller's `set -e`
# then aborts and its own trap (when it has one) undoes the commit the pull
# made. Inner is a strict subset of outer and runs first, so the outer reset
# lands on an already-restored tree and finds nothing left to disagree with.
# When init.sh is SOURCED instead (the unit specs), any EXIT trap already
# installed is saved and handed back rather than clobbered.

_INIT_ROLLBACK_DIR=""
_INIT_ROLLBACK_ARMED=false
_INIT_ROLLBACK_PREV_TRAP=""

# _init_installed_paths
#   Every repo-relative path the existing-repo resync guarantees a
#   consumer will carry, as one path per line, sorted (LC_ALL=C) and
#   duplicate-free.
#
#   WHY THIS IS A PUBLISHED LIST AND NOT AN INTERNAL ONE. These files
#   reach a consumer through exactly one route -- init.sh, run as the
#   resync step of an upgrade -- so a repo that cannot upgrade never gets
#   them, and until now nothing could even name what it was missing. The
#   version marker answers "which release is this repo pinned to"; this
#   answers "did that release's files arrive", which is a different
#   question and the one that went unasked while the base-version monitor
#   sat at zero adoption.
#
#   SCOPE: committable files only. The resync also materialises derived
#   artifacts (.env, .env.local, compose.yaml, the log tree); those are
#   gitignored by the same run, so no remote audit can see them, and
#   listing them would report every repo as broken. Parent directories
#   are implied by their entries, never listed. Contrast
#   _init_protected_paths below, which is the ROLLBACK surface -- the
#   roots a failed run must restore, derived artifacts included.
#
#   Both directions of this list are enforced by
#   test/bats/integration/init_installed_paths_spec.bats, which runs a
#   real resync against a real consumer and diffs what it wrote against
#   what this prints. Adding a file to the resync without adding it here
#   fails that spec, which is what keeps the list from decaying into the
#   hand-maintained copy it exists to replace.
_init_installed_paths() {
  cat <<'EOF'
.dockerignore
.github/workflows/base-version-monitor.yaml
.gitignore
.hadolint.yaml
.setup.conf
config/.gitkeep
justfile
script/base/completions.sh
script/base/justfile.base
script/build.sh
script/docker/justfile.docker
script/exec.sh
script/hooks/post/build.sh
script/hooks/post/exec.sh
script/hooks/post/prune.sh
script/hooks/post/run.sh
script/hooks/post/setup.sh
script/hooks/post/setup_tui.sh
script/hooks/post/stop.sh
script/hooks/pre/build.sh
script/hooks/pre/exec.sh
script/hooks/pre/prune.sh
script/hooks/pre/run.sh
script/hooks/pre/setup.sh
script/hooks/pre/setup_tui.sh
script/hooks/pre/stop.sh
script/justfile
script/local/justfile.local
script/local/local.sh
script/prune.sh
script/run.sh
script/setup.sh
script/setup_tui.sh
script/stop.sh
script/template/justfile.template
script/template/new.sh
script/template/skel
EOF
}

# _init_conditional_paths
#   The subset of _init_installed_paths the resync writes only under a
#   condition, and leaves exactly as it found it once that condition has
#   stopped holding.
#
#   WHY THIS EXISTS. _init_installed_paths answers "what does a consumer
#   CARRY", which is the question the delivery audit asks. The staging step
#   needs a different one -- "what did THIS RUN write" -- and for most of
#   that list the two answers coincide: the wrappers and the justfile
#   layering are re-pointed on every run, whatever was there before. For
#   the paths below they do not. Each is written only when its own
#   condition holds, so what is in one on any other run is the repo's own
#   work:
#
#     - the 14 hook stubs, whose whole point is that a user-authored hook
#       survives every later re-init and upgrade (_create_hook_stubs);
#     - the script/local/ starter pair, REPO-OWNED by the naming contract
#       (ADR-00000010, _seed_local);
#     - config/.gitkeep, which an existing config/ keeps (_populate_config);
#     - the monitor workflow, generated once (_sync_base_monitor_workflow);
#     - .hadolint.yaml, which _create_symlinks refuses to re-point once it
#       differs from the template;
#     - .gitignore and .dockerignore, which the sync APPENDS to only when a
#       canonical entry is missing -- it returns without a write when none
#       is, "the common case for an up-to-date repo" in its own comment --
#       and whose hand-maintained region above the managed block it never
#       touches at all;
#     - .setup.conf, which setup.sh writes on a first-time bootstrap or a
#       stale-mount_1 rewrite and leaves alone otherwise.
#
#   The ignore pair and .setup.conf are why this list is CONDITIONAL and
#   not seed-only, which is what it was called before the pair was in it.
#   Neither is seeded once: an ignore file is written again on any release
#   that adds a canonical entry, and .setup.conf is rewritten in place by a
#   stale-mount repair. "Seeded once" is a promise about them that is not
#   true, and the predicate the staging step actually needs is the weaker
#   one -- written only under a condition, so ask the run.
#
#   Staging these wholesale put the user's half-finished hook into a commit
#   whose message names a base release -- the sweep the staging step was
#   written to avoid, arriving through the published list instead of
#   through `git add -A`. What makes them stageable again is the RECORD
#   below: a run that actually wrote one names it, and only a named one is
#   staged.
#
#   Kept as its own list rather than as a flag on the big one because the
#   big one is a published surface with two consumers that must not learn
#   about this distinction. A spec in test/bats/unit/init_spec.bats asserts
#   every entry here is also an installed path, so the two cannot drift
#   into naming different files.
_init_conditional_paths() {
  cat <<'EOF'
.dockerignore
.github/workflows/base-version-monitor.yaml
.gitignore
.hadolint.yaml
.setup.conf
config/.gitkeep
script/hooks/post/build.sh
script/hooks/post/exec.sh
script/hooks/post/prune.sh
script/hooks/post/run.sh
script/hooks/post/setup.sh
script/hooks/post/setup_tui.sh
script/hooks/post/stop.sh
script/hooks/pre/build.sh
script/hooks/pre/exec.sh
script/hooks/pre/prune.sh
script/hooks/pre/run.sh
script/hooks/pre/setup.sh
script/hooks/pre/setup_tui.sh
script/hooks/pre/stop.sh
script/local/justfile.local
script/local/local.sh
EOF
}

# _INIT_WROTE / _init_record_write <repo-relative-path>
#   The conditional paths THIS run actually wrote, recorded at the moment
#   they are written. Only the writing pass knows: the condition it tested
#   ("the file was not there", "it still matches the template", "an entry
#   was missing") is gone by the time the staging step runs, and re-deriving
#   it from the tree is how the user's own content gets classified as ours
#   again.
#
#   Reset at the top of the resync so a sourced init.sh -- the unit specs,
#   and nothing else -- cannot carry one run's record into the next.
#
#   `-g` because a bare `declare` inside a FUNCTION declares a local, and
#   the unit specs source this file from inside a bats test function: the
#   array would go out of scope with the source, leave the subscripts below
#   to be read as arithmetic against an ordinary indexed array, and take
#   the whole resync down with it.
declare -gA _INIT_WROTE=()

_init_record_write() {
  _INIT_WROTE["${1:?BUG: _init_record_write expects a repo-relative path}"]=1
}

# _init_protected_paths
#   Every repo-root-relative path the existing-repo resync can create,
#   rewrite or delete. Directories are listed AS directories: the resync
#   both adds to and removes from them, and putting a whole root back is
#   what makes "the way it was" one operation rather than a diff.
#
#   Grouped by the mutation that puts each entry here:
#     _create_symlinks             justfile, script/, config/,
#                                  .hadolint.yaml, and the pre-relocation
#                                  root wrappers it deletes on sight
#     _sync_existing_gitignore     .gitignore, .dockerignore
#     _create_hook_stubs           script/hooks/
#     _sync_base_monitor_workflow  the generated monitor workflow
#     _migrate_dockerfile          Dockerfile, script/entrypoint.sh
#     the .env -> .env.local rename  both names. Neither is recoverable
#                                  from git -- they are gitignored and
#                                  hand-written -- so they are named here
#                                  even though the migration that moves
#                                  them lands separately.
#
#   The retired root wrappers come from _init_retired_root_paths below,
#   which is also what _create_symlinks deletes from and what the staging
#   step commits the deletion of.
_init_protected_paths() {
  cat <<'EOF'
Dockerfile
justfile
.hadolint.yaml
.gitignore
.dockerignore
.env
.env.local
script
config
.github/workflows/base-version-monitor.yaml
EOF
  _init_retired_root_paths
}

# _init_retired_root_paths
#   The pre-relocation root wrapper names the resync drops on sight: the
#   seven user-facing wrappers that moved under `script/`, the
#   pre-setup_tui-rename `tui.sh`, and the retired container-ops
#   `Makefile` (ADR-00000005 phase 2).
#
#   One accessor rather than a literal per caller, because three of them
#   need the same answer and would drift the first time one was edited:
#   _create_symlinks removes these, _init_protected_paths has to restore
#   them if the run fails, and _stage_resync_output has to put the REMOVAL
#   in the commit -- a tracked file deleted but not staged is the same
#   tree/commit disagreement as a rewrite that never got staged.
_init_retired_root_paths() {
  cat <<'EOF'
build.sh
run.sh
exec.sh
stop.sh
prune.sh
setup.sh
setup_tui.sh
tui.sh
Makefile
EOF
}

# _init_snapshot
#   Copy every protected root that exists into a scratch tree outside the
#   repo and record which ones existed. Runs BEFORE the first mutation, so
#   a snapshot that cannot be taken aborts a run that has changed nothing
#   -- the one moment where failing is free.
_init_snapshot() {
  _INIT_ROLLBACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/base-init-resync.XXXXXX")" \
    || _error "cannot create the resync snapshot directory"
  mkdir -p "${_INIT_ROLLBACK_DIR}/tree" \
    || _error "cannot create the resync snapshot directory"
  : > "${_INIT_ROLLBACK_DIR}/present" \
    || _error "cannot write the resync snapshot manifest"

  local _path _live _copy
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    _live="${REPO_ROOT:?}/${_path}"
    # `-e` follows the link, so a DANGLING symlink reads as absent. It is
    # still a path that is there and has to come back -- the retired root
    # wrappers are exactly that shape -- so test for the link itself too.
    [[ -e "${_live}" || -L "${_live}" ]] || continue
    _copy="${_INIT_ROLLBACK_DIR}/tree/${_path}"
    mkdir -p "$(dirname -- "${_copy}")" \
      || _error "cannot snapshot ${_path} before the resync"
    cp -a -- "${_live}" "${_copy}" \
      || _error "cannot snapshot ${_path} before the resync"
    printf '%s\n' "${_path}" >> "${_INIT_ROLLBACK_DIR}/present"
  done < <(_init_protected_paths)

  _init_snapshot_index
}

# _init_snapshot_index
#   Record the index entries of the canonical derived artifacts -- the only
#   paths the resync removes from the index, via `git rm --cached`. A staged
#   deletion left behind by an aborted run is a change the consumer never
#   made and cannot see in the working tree. No-op outside a git repo.
_init_snapshot_index() {
  : > "${_INIT_ROLLBACK_DIR}/index"
  git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local _entry
  while IFS= read -r _entry; do
    [[ -n "${_entry}" ]] || continue
    git -C "${REPO_ROOT}" ls-files -s -z -- "${_entry%/}" \
      >> "${_INIT_ROLLBACK_DIR}/index" 2>/dev/null || true
  done < <(_canonical_gitignore_entries)
}

# _init_restore_tree
#   Put every protected root back the way the snapshot found it: a root
#   that existed is replaced by its copy, a root that did not is removed.
#
#   Returns non-zero if ANY root could not be restored. A root whose
#   snapshot copy has gone missing is deliberately LEFT ALONE rather than
#   removed: a rollback that "restores" by deleting the user's file is
#   worse than the half-written state it was undoing, and the caller
#   reports the failure instead of claiming a restore that did not happen.
_init_restore_tree() {
  local -a _present=()
  if [[ -f "${_INIT_ROLLBACK_DIR}/present" ]]; then
    mapfile -t _present < "${_INIT_ROLLBACK_DIR}/present"
  fi

  local _path _live _copy _known _was_there
  local _rc=0
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    _live="${REPO_ROOT:?}/${_path}"
    _copy="${_INIT_ROLLBACK_DIR}/tree/${_path}"

    _was_there=false
    for _known in ${_present[@]+"${_present[@]}"}; do
      if [[ "${_known}" == "${_path}" ]]; then
        _was_there=true
        break
      fi
    done

    if [[ "${_was_there}" != "true" ]]; then
      rm -rf -- "${_live}" || _rc=1
      continue
    fi
    if [[ ! -e "${_copy}" && ! -L "${_copy}" ]]; then
      _rc=1
      continue
    fi
    rm -rf -- "${_live}" || { _rc=1; continue; }
    mkdir -p -- "$(dirname -- "${_live}")" || { _rc=1; continue; }
    cp -a -- "${_copy}" "${_live}" || _rc=1
  done < <(_init_protected_paths)

  return "${_rc}"
}

# _init_restore_index
#   Re-add the index entries the resync removed. Only entries that are GONE
#   from the index are put back; one that is still there is left exactly as
#   it is, so nothing staged around this run is overwritten by a stale
#   snapshot. NUL-delimited on both sides so a path needing quoting round-
#   trips unchanged.
_init_restore_index() {
  [[ -s "${_INIT_ROLLBACK_DIR}/index" ]] || return 0
  git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local _entry _path _readd=""
  while IFS= read -r -d '' _entry; do
    [[ -n "${_entry}" ]] || continue
    _path="${_entry#*$'\t'}"
    if [[ -n "$(git -C "${REPO_ROOT}" ls-files -- "${_path}" 2>/dev/null)" ]]; then
      continue
    fi
    _readd+="${_entry}"$'\0'
  done < "${_INIT_ROLLBACK_DIR}/index"

  [[ -n "${_readd}" ]] || return 0
  printf '%s' "${_readd}" | git -C "${REPO_ROOT}" update-index -z --index-info
}

# _init_rollback_cleanup
#   Drop the scratch snapshot. Never called on the rollback-FAILED path:
#   there the copy is the user's only way back, and the error names it.
_init_rollback_cleanup() {
  [[ -n "${_INIT_ROLLBACK_DIR}" ]] || return 0
  rm -rf -- "${_INIT_ROLLBACK_DIR}"
  _INIT_ROLLBACK_DIR=""
}

# _init_run_prev_exit_trap
#   Run the EXIT trap that was installed before this one, if any. Only a
#   SOURCED init.sh can have one -- all three real callers execute it as a
#   separate process -- but a trap installed into someone else's shell must
#   not swallow theirs.
#
#   `trap -p EXIT` prints `trap -- 'BODY' EXIT`, BODY single-quoted. The
#   outer eval strips that quoting and hands BODY to the inner eval, which
#   runs it. bash does not re-enter an EXIT trap from inside one, so
#   re-installing it would not be enough.
_init_run_prev_exit_trap() {
  [[ -n "${_INIT_ROLLBACK_PREV_TRAP}" ]] || return 0
  local _body="${_INIT_ROLLBACK_PREV_TRAP}"
  _body="${_body#trap -- }"
  _body="${_body% EXIT}"
  _INIT_ROLLBACK_PREV_TRAP=""
  eval "eval ${_body}"
}

# _init_rollback_trap
#   Armed for the whole existing-repo resync and disarmed once its last
#   mutation has succeeded. A non-zero exit in between restores the
#   consumer's files; a zero exit does nothing but tidy up.
#
#   A restore that did not fully work exits 1 with the tree named as NOT
#   restored and the manual command spelled out, rather than reporting the
#   original failure over a tree it left half-way. Reporting success -- or
#   reporting only the first failure -- is what let this class through.
_init_rollback_trap() {
  local _status=$?
  trap - EXIT
  if (( _status == 0 )) || [[ "${_INIT_ROLLBACK_ARMED}" != "true" ]]; then
    _init_rollback_cleanup
    _init_run_prev_exit_trap
    exit "${_status}"
  fi
  _INIT_ROLLBACK_ARMED=false

  _log_err init init_rollback "display=resync failed (exit ${_status}); restoring the consumer files it had already rewritten." "status=${_status}"
  local _rc=0
  _init_restore_tree || _rc=1
  _init_restore_index || _rc=1
  if (( _rc != 0 )); then
    _log_err init init_rollback_failed "display=rollback FAILED -- the working tree is NOT restored. The pre-resync copy is kept at ${_INIT_ROLLBACK_DIR}; restore it by hand with: cp -a ${_INIT_ROLLBACK_DIR}/tree/. ${REPO_ROOT}/" "snapshot=${_INIT_ROLLBACK_DIR}"
    exit 1
  fi
  _log_err init init_rollback "display=resync aborted; the consumer's files are back as they were"
  _init_rollback_cleanup
  _init_run_prev_exit_trap
  exit "${_status}"
}

# _init_arm_rollback / _init_disarm_rollback
#   The bracket around the resync. Arming snapshots first and installs the
#   trap second, so the trap is never live over a snapshot that does not
#   exist; disarming hands the caller's own EXIT trap back untouched.
_init_arm_rollback() {
  _init_snapshot
  _INIT_ROLLBACK_PREV_TRAP="$(trap -p EXIT)"
  _INIT_ROLLBACK_ARMED=true
  trap _init_rollback_trap EXIT
}

_init_disarm_rollback() {
  _INIT_ROLLBACK_ARMED=false
  trap - EXIT
  if [[ -n "${_INIT_ROLLBACK_PREV_TRAP}" ]]; then
    eval "${_INIT_ROLLBACK_PREV_TRAP}"
    _INIT_ROLLBACK_PREV_TRAP=""
  fi
  _init_rollback_cleanup
}

# ── Existing repo initialization ────────────────────────────────────────────

_init_existing_repo() {
  _INIT_WROTE=()
  _init_arm_rollback
  _log "Existing repo detected (Dockerfile found)"
  # BEFORE anything can regenerate: a `.env` written back when that name
  # meant "yours" is moved to `.env.local`. This runs here, not in
  # upgrade.sh, on purpose. An upgrade is driven by the CONSUMER'S OWN
  # vendored upgrade.sh -- a copy that shipped in an older release and
  # knows nothing about the rename -- but every one of those releases
  # re-runs the NEWLY PULLED init.sh as its resync step, so this is the
  # earliest point in the upgrade that runs current code. Nothing between
  # here and the user's next `just setup` writes `.env`.
  _migrate_env_to_local "${REPO_ROOT}"
  _create_symlinks
  _sync_existing_gitignore
  # ensure the pre/post hook scaffolding exists. Idempotent;
  # already-present stubs are left untouched. Upgrades from
  # templates pick up the 14 stubs automatically here.
  _create_hook_stubs
  # ensure the base version monitor workflow exists; existing repos
  # pick it up on their next upgrade (upgrade.sh Step 3 re-runs init).
  _sync_base_monitor_workflow
  _migrate_dockerfile
  _init_disarm_rollback
}

# _migrate_dockerfile
#   Heal a repo-root Dockerfile (and its sibling entrypoint) that still
#   names a layout a base release has since moved, via the shared
#   declarative migration list.
#
#   Why HERE and not only in upgrade.sh: an upgrade is driven by the
#   consumer's OWN vendored upgrade.sh, which shipped in an older release
#   and cannot be changed retroactively. Every release up to v0.41.0
#   carries its own hardcoded Dockerfile-patch step that knows only the
#   paths that existed when it shipped, and it short-circuits ("already
#   copies ... - skip") on exactly the lines the dist relocation deleted.
#   The one piece of CURRENT code such an upgrade runs is this file,
#   re-executed from the freshly pulled subtree as its resync step -- so
#   this is the only place a new heal reaches a consumer upgrading FROM an
#   old release rather than one already on the new one.
#
#   Every migration is idempotent, so the current upgrade.sh running the
#   same dispatcher again at its own Step 5 is a no-op. It is also what
#   makes `just base init` a repair command for a repo that has ALREADY
#   taken a bad upgrade, where the version check short-circuits before any
#   migration would run.
_migrate_dockerfile() {
  apply_migrations "${REPO_ROOT}/Dockerfile"
}

# _stage_resync_output
#   Stage what the resync wrote, so it lands in the commit the CALLER
#   makes rather than being left behind it.
#
#   WHY THE STAGING IS HERE and not in the script that commits. The script
#   that commits is the consumer's OWN vendored upgrade.sh, and it stages a
#   pair of filenames written into it when it shipped. v0.41.0's reaches
#   the Dockerfile only down a branch these migrations never take, so a
#   cross-version upgrade committed the workflow @tag bump and the
#   .gitignore sync, left everything the resync had just written unstaged,
#   and closed by telling the user to `git push` -- a commit claiming the
#   new release over a tree on a different layout (base#1036). That copy
#   cannot be fixed retroactively for anyone; this file can, because every
#   release re-runs the NEWLY PULLED init.sh as its resync step. Staging
#   beside the work also makes the NEXT cross-version upgrade correct by
#   construction, whatever the caller does.
#
#   WHAT IS STAGED is everything this run can NAME as its own output:
#
#     - the migration record (lib/dockerfile_migrate.sh's migrated_files),
#       which the dispatcher closes over the files it rewrote;
#     - _init_installed_paths, the published list of what the resync
#       guarantees a consumer carries -- wrappers, the justfile layering,
#       the monitor workflow -- already kept honest by a spec that diffs it
#       against a real resync, MINUS the conditional paths of it this run
#       did not write (see _init_conditional_paths and the _INIT_WROTE
#       record);
#     - _init_retired_root_paths, whose entries the resync DELETES: a
#       tracked file removed but not staged leaves the same tree/commit
#       disagreement one direction over, and git's index is the only place
#       those still exist to be named -- MINUS the ones this run did not
#       remove, since the resync drops such a name only when it is a
#       symlink and a consumer's hand-written regular file at it is theirs
#       (the same _INIT_WROTE record, for the same reason).
#
#   Never `git add -A`. Every path above was written by THIS run, so none
#   of it is the user's work to review, while a sweep would commit whatever
#   they happened to be editing. "What a consumer carries" is not the same
#   set and was the first version of this: the published list also names
#   the 14 hook stubs, the script/local/ pair, config/.gitkeep, the monitor
#   workflow, .hadolint.yaml, the two ignore files and .setup.conf, each of
#   which the resync writes only under a condition and otherwise leaves
#   exactly as it found it -- so staging the list wholesale committed the
#   user's own half-finished hook under a message about a base release, the
#   sweep this paragraph forbids arriving by the other door. A path the
#   user has told git to ignore is theirs, not ours, so it is dropped
#   rather than forced.
#
#   Failing to stage is reported, never fatal: the resync itself succeeded,
#   and aborting here would roll back a good upgrade over an index the user
#   can fix with one `git add`.
_stage_resync_output() {
  local -a _paths=()
  local _path

  mapfile -t _paths < <(migrated_files)

  # A conditional path is this run's output only if this run wrote it;
  # every other one holds the repo's own work and is not ours to commit.
  local -A _conditional=()
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    _conditional["${_path}"]=1
  done < <(_init_conditional_paths)

  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    [[ -e "${REPO_ROOT}/${_path}" || -L "${REPO_ROOT}/${_path}" ]] || continue
    if [[ -n "${_conditional[${_path}]:-}" \
      && -z "${_INIT_WROTE[${_path}]:-}" ]]; then
      continue
    fi
    _paths+=("${REPO_ROOT}/${_path}")
  done < <(_init_installed_paths)

  _init_drop_foreign_paths
  (( ${#_paths[@]} > 0 )) || return 0
  _init_git_can_stage || return 0
  _init_drop_unmatchable_paths
  (( ${#_paths[@]} > 0 )) || return 0

  # The retired wrappers are gone from disk, so only the index can say
  # which of them this repo was tracking. A name it never tracked must not
  # reach `git add`, which fails the whole batch on a pathspec matching
  # nothing.
  #
  # Filtered by the same record the conditional installed paths are, and
  # for the same reason: the resync removes one of these names only when it
  # is a SYMLINK, so the list names what this run MAY have deleted, never
  # what it did. A consumer's own hand-written `Makefile` or `run.sh` at
  # the root survives the resync untouched and is theirs to commit -- the
  # sweep the paragraph above forbids, arriving through the second list.
  local -a _retired=()
  mapfile -t _retired < <(_init_retired_root_paths)
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    [[ -n "${_INIT_WROTE[${_path}]:-}" ]] || continue
    _paths+=("${REPO_ROOT}/${_path}")
  done < <(git -C "${REPO_ROOT}" ls-files -- "${_retired[@]}" 2>/dev/null)

  # check-ignore consults the index, so a TRACKED file is never reported
  # here even when a pattern would otherwise match it -- what is dropped is
  # only what the user has told git to keep out.
  #
  # NUL-delimited in both directions. Newline-delimited, git answers under
  # `core.quotePath`, whose default C-quotes any path carrying a byte over
  # 0x7F -- so under a repo path with a non-ASCII character the key coming
  # back never equals the key that went in, the ignored path survives this
  # filter, `git add` refuses it, and the run reports "could not stage"
  # over a batch it did stage. `-z` also makes a path containing a newline
  # round-trip, which the reader below could not otherwise do.
  local -A _ignored=()
  while IFS= read -r -d '' _path; do
    [[ -n "${_path}" ]] || continue
    _ignored["${_path}"]=1
  done < <(printf '%s\0' "${_paths[@]}" \
    | git -C "${REPO_ROOT}" check-ignore -z --stdin 2>/dev/null)

  local -a _stage=()
  for _path in "${_paths[@]}"; do
    [[ -n "${_ignored[${_path}]:-}" ]] || _stage+=("${_path}")
  done
  (( ${#_stage[@]} > 0 )) || return 0

  # `-A` so a staged path can be a removal as well as a write.
  if ! git -C "${REPO_ROOT}" add -A -- "${_stage[@]}" > /dev/null 2>&1; then
    _log_warn init init_progress "display=  could not stage what the resync wrote -- run \`git add\` over it by hand before pushing"
    return 0
  fi
  _log "  staged for the upgrade commit: ${#_stage[@]} path(s) the resync wrote (review with: git diff --cached)"
}

# _init_lexical_path <path>
#   Set _INIT_LEXICAL_PATH to <path> with its `.` and `..` segments
#   resolved and its empty ones collapsed. Purely textual: no stat, no
#   readlink, nothing that can fail or that depends on the path existing --
#   the caller is deciding whether to hand a name to `git add`, and half
#   the names it asks about are files a migration has just written or is
#   about to.
#
#   Lexical resolution and physical resolution differ where a `..` follows
#   a symlink, and lexical is the one wanted here: `script/` in a consumer
#   IS a symlink into the subtree, so resolving links would relocate paths
#   that git stages perfectly well, and the answer would change with the
#   tree rather than with the name.
#
#   `..` at the root stays at the root, matching every path resolver: a
#   name cannot escape above `/`. A RELATIVE path is handed back untouched
#   -- it resolves against a cwd this function is not told about, and the
#   one caller drops it as foreign either way.
#
#   Answers through a variable rather than stdout for the reason
#   _init_drop_foreign_paths does below: a command substitution eats
#   trailing newlines, and not silently altering the paths it is handed is
#   the whole job.
_INIT_LEXICAL_PATH=""

_init_lexical_path() {
  local _path="${1-}" _seg _res=""
  if [[ "${_path}" != /* ]]; then
    _INIT_LEXICAL_PATH="${_path}"
    return 0
  fi
  # `read -d /` splits on the separator and on nothing else, so a segment
  # containing a space, a tab or a glob character survives it intact. The
  # appended `/` terminates the last segment.
  while IFS= read -r -d '/' _seg; do
    case "${_seg}" in
      '' | '.') ;;
      '..') _res="${_res%/*}" ;;
      *) _res+="/${_seg}" ;;
    esac
  done < <(printf '%s/' "${_path}")
  _INIT_LEXICAL_PATH="${_res:-/}"
  return 0
}

# _init_drop_foreign_paths
#   Remove from the caller's `_paths` any entry that is not under
#   REPO_ROOT, naming what it dropped.
#
#   `git add` is all-or-nothing over its pathspec: handed one path outside
#   the repository it exits 128 and stages NONE of the batch. So a single
#   foreign entry in the record would un-stage the Dockerfile, the wrappers
#   and the workflow along with it -- and the run would continue, because
#   failing to stage is deliberately not fatal. That is base#1036 arriving
#   through the code written to fix it, so the batch is filtered before
#   `git add` sees it rather than after it has refused.
#
#   Nothing reaches this today: `apply_migrations` is handed
#   ${REPO_ROOT}/Dockerfile and derives the entrypoint beside it, and the
#   other two sources build their paths from REPO_ROOT. It is a fence
#   around the record's GENERALITY -- `migrated_files` is a published
#   surface whose set of writers is open -- and a migration that does write
#   outside the repo is a bug in that migration, not a reason to lose the
#   rewrite the same run made inside it.
#
#   A fence for the general case has to answer the general question, so the
#   comparison runs on _init_lexical_path's output. The first version of it
#   was a prefix test on the unresolved string, which reads
#   `${REPO_ROOT}/../elsewhere/x` as inside the repo and hands `git add`
#   precisely the argument described above. "Cannot tell whether this is
#   inside the repo" must not resolve to "proceed".
#
#   Operates on the caller's array by name rather than returning a list,
#   because a path may legitimately contain anything but a newline and
#   round-tripping it through a substitution is where that stops being true.
_init_drop_foreign_paths() {
  local -a _kept=() _foreign=()
  local _candidate _root
  _init_lexical_path "${REPO_ROOT}"
  _root="${_INIT_LEXICAL_PATH}"
  for _candidate in ${_paths[@]+"${_paths[@]}"}; do
    # Compared after the `.` and `..` segments are resolved, kept in the
    # spelling it arrived in. A raw prefix test reads
    # `${REPO_ROOT}/../elsewhere/x` as inside the repo -- it starts with
    # the root -- and hands `git add` the one argument that fails the whole
    # batch, which is this function's entire reason to exist.
    _init_lexical_path "${_candidate}"
    if [[ "${_INIT_LEXICAL_PATH}" == "${_root}/"* ]]; then
      _kept+=("${_candidate}")
    else
      _foreign+=("${_candidate}")
    fi
  done

  (( ${#_foreign[@]} > 0 )) \
    && _log_warn init init_progress "display=  not staging ${#_foreign[@]} path(s) written outside ${REPO_ROOT}: ${_foreign[*]} -- commit them by hand if they belong to this repo"

  _paths=(${_kept[@]+"${_kept[@]}"})
  return 0
}

# _init_drop_unmatchable_paths
#   Remove from the caller's `_paths` any entry git has nothing to match --
#   not on disk and not in the index -- naming what it dropped.
#
#   The SAME whole-batch refusal _init_drop_foreign_paths exists for, from
#   inside the repo instead of outside it. `git add` fails its entire
#   pathspec on a name that matches nothing, and "failing to stage" is
#   deliberately non-fatal, so one such entry costs the commit the
#   Dockerfile the run just rewrote and the run still closes by telling the
#   user to push. That is base#1036 arriving through the code written to
#   fix it, so the batch is filtered before `git add` sees it.
#
#   NOT an existence test. A path the run DELETED is still its output, and
#   `git add -A` records the removal -- but only where git was tracking it,
#   which is why the index is the second question rather than the whole
#   answer being the first. `migrated_files` names exactly that shape
#   today: `_dfm_reconcile_targets` records a target whose content changed
#   in either direction, deletion included, and an untracked one is
#   unreachable by any pathspec. The published-list half asks its own,
#   stricter question before this one -- a file the resync guarantees but
#   did not put there is not a deletion to commit under a release message
#   -- so what actually reaches here is the migration record.
#
#   Operates on the caller's array by name for the reason
#   _init_drop_foreign_paths does: a path may contain anything but a
#   newline, and round-tripping it through a substitution is where that
#   stops being true.
_init_drop_unmatchable_paths() {
  local -a _kept=() _unmatchable=()
  local _candidate
  for _candidate in ${_paths[@]+"${_paths[@]}"}; do
    if [[ -e "${_candidate}" || -L "${_candidate}" ]] \
      || git -C "${REPO_ROOT}" ls-files --error-unmatch -- "${_candidate}" \
        > /dev/null 2>&1; then
      _kept+=("${_candidate}")
    else
      _unmatchable+=("${_candidate}")
    fi
  done

  (( ${#_unmatchable[@]} > 0 )) \
    && _log_warn init init_progress "display=  not staging ${#_unmatchable[@]} path(s) git cannot match -- nothing there and nothing tracked: ${_unmatchable[*]}"

  _paths=(${_kept[@]+"${_kept[@]}"})
  return 0
}

# _init_git_can_stage
#   Whether there is an index to stage into -- and, when there is not,
#   whether that is worth saying out loud.
#
#   `just base init` is also a repair command, and a repo bootstrapped by
#   hand may not be a git repo at all: nothing to stage into is neither a
#   failure nor news. But git failing while a `.git` IS sitting there is a
#   different answer -- a worktree checkout whose gitdir has moved, dubious
#   ownership, no git on PATH -- and resolving THAT to silent success is
#   how the work this function exists to stage gets pushed uncommitted.
#   Ask git first; let the presence of `.git` say which "no" it was.
_init_git_can_stage() {
  git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    && return 0
  if [[ -e "${REPO_ROOT}/.git" || -L "${REPO_ROOT}/.git" ]]; then
    _log_warn init init_progress "display=  could not stage what the resync wrote: git cannot read ${REPO_ROOT} as a work tree -- stage and commit it by hand before pushing"
  fi
  return 1
}

# _create_hook_stubs
#   Creates 14 stub files (7 wrappers x 2 phases) under
#   script/hooks/{pre,post}/. Idempotent: never overwrites an
#   existing file (so user-authored hooks survive re-init / upgrade).
#   All freshly-written stubs land with mode 755 so the
#   non-executable hard-fail path in lib/hook.sh never trips
#   spuriously on a fresh init.
_create_hook_stubs() {
  mkdir -p "${REPO_ROOT}/script/hooks/pre" "${REPO_ROOT}/script/hooks/post"
  local _wrapper _kind _file _verb _abort
  for _kind in pre post; do
    if [[ "${_kind}" == "pre" ]]; then
      _verb="before"
      _abort="aborts the wrapper"
    else
      _verb="after"
      _abort="fails the wrapper with this rc"
    fi
    for _wrapper in build run exec stop prune setup setup_tui; do
      _file="${REPO_ROOT}/script/hooks/${_kind}/${_wrapper}.sh"
      [[ -e "${_file}" ]] && continue
      _init_record_write "script/hooks/${_kind}/${_wrapper}.sh"
      cat > "${_file}" <<HOOK
#!/usr/bin/env bash
# ${_kind}-${_wrapper} hook: host-side, runs ${_verb} ${_wrapper}.sh main logic.
# Receives the same "\$@" as ${_wrapper}.sh. Non-zero exit ${_abort}.
# Replace \`exit 0\` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{$_wrapper}.sh runs with --dry-run.
exit 0
HOOK
      chmod 755 "${_file}"
    done
  done
}

# _sync_base_monitor_workflow
#   Generate .github/workflows/base-version-monitor.yaml if absent.
#   Idempotent like _create_hook_stubs: never overwrites,
#   so a repo that hand-tunes the schedule keeps its edits across
#   upgrades. The version-compare + issue-dedupe logic ships in the
#   subtree (check-base-version.sh) and refreshes on every upgrade, so
#   the generated workflow is a thin weekly scheduler. Called from both
#   the new-repo path and the existing-repo (upgrade) path so every repo
#   converges on it.
# The actions/checkout ref baked into the workflow below. Hoisted out of
# the heredoc so it has a declaration site a `tool-pin:` marker can sit on:
# written inline it was a `uses:` ref that NOTHING could advance -- this
# repo's dependabot only reads workflow files and a heredoc is not one, and
# the downstream repos it is written into have no updater at all.
# tool-pin: unpinned downstream-checkout-action -- a MAJOR ref on purpose,
# so every generated repo picks up actions/checkout patches without waiting
# for a base release. A major names no comparable version, so the watch
# lists it as floating on every run instead of pretending to check it.
readonly _INIT_MONITOR_CHECKOUT_REF='actions/checkout@v7'

_sync_base_monitor_workflow() {
  local _wf="${REPO_ROOT}/.github/workflows/base-version-monitor.yaml"
  [[ -e "${_wf}" ]] && return 0
  mkdir -p "${REPO_ROOT}/.github/workflows"
  cat > "${_wf}" <<YAML
name: Base Version Monitor

# Opens a tracking issue in THIS repo when ycpss91255-docker/base ships a
# newer stable release than the pinned subtree (${TEMPLATE_REL}/.version).
# Pull-based: each repo polls and files into itself with the default
# GITHUB_TOKEN -- no PAT, no central repo list. Generated by init.sh; the
# comparison logic ships in the subtree
# (${TEMPLATE_REL}/dist/script/base/check-base-version.sh) and refreshes
# on upgrade, so this file is just a thin weekly scheduler.

on:
  schedule:
    - cron: '37 5 * * 1'
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: ${_INIT_MONITOR_CHECKOUT_REF}
      - name: Check for a newer base release
        env:
          GH_TOKEN: \${{ github.token }}
          GH_REPO: \${{ github.repository }}
        run: ./${TEMPLATE_REL}/dist/script/base/check-base-version.sh run
YAML
  _init_record_write ".github/workflows/base-version-monitor.yaml"
  _log "  Created .github/workflows/base-version-monitor.yaml"
}

# _sync_existing_gitignore
#   On existing-repo init / upgrade, append any canonical entries the
#   user's .gitignore is missing AND `git rm --cached` any tracked
#   files that have since become derived artifacts. Heals the 15-repo
#   drift, in one shot — no separate sweep PR needed.
#
#   Records whether the pass actually WROTE either ignore file, because
#   both are conditional paths (_init_conditional_paths) and the staging
#   step stages one only when this run wrote it. Neither can be recorded by
#   its writer the way a hook stub is: three separate syncs write .gitignore
#   -- the canonical append, the retired-entry prune inside it, and the
#   [logging] block rebuild -- and each already answers a different question
#   than "did anything change". The file's CONTENT across the whole pass
#   answers it once, for every writer present and future, which is also how
#   _call_setup records `.setup.conf` across a separate process.
#
#   The `; printf x` on every read is load-bearing, for the reason spelled
#   out at _call_setup: a command substitution eats trailing newlines, so
#   without it a pass whose only change was one would read as no change and
#   go unstaged -- the tree/commit disagreement this staging exists to
#   close.
_sync_existing_gitignore() {
  local _gitignore="${REPO_ROOT}/.gitignore"
  local _dockerignore="${REPO_ROOT}/.dockerignore"
  local _git_before="" _docker_before="" _git_after="" _docker_after=""
  [[ -f "${_gitignore}" ]] \
    && _git_before="$(cat -- "${_gitignore}" 2> /dev/null; printf x)"
  [[ -f "${_dockerignore}" ]] \
    && _docker_before="$(cat -- "${_dockerignore}" 2> /dev/null; printf x)"

  _sync_gitignore "${_gitignore}"
  _untrack_canonical_in_repo "${REPO_ROOT}"
  # append-missing the same derived-artifact set into .dockerignore
  # (created if absent), preserving user build-context lines.
  _sync_dockerignore "${_dockerignore}"
  # PR-B: rebuild the [logging] local_path managed block from the
  # current setup.conf. Used to live in setup.sh apply (runtime); now
  # tied to init/upgrade lifecycle so the file stays consistent even
  # when setup.conf changed between wrapper invocations.
  _sync_logging_gitignore "${REPO_ROOT}"

  [[ -f "${_gitignore}" ]] \
    && _git_after="$(cat -- "${_gitignore}" 2> /dev/null; printf x)"
  [[ -f "${_dockerignore}" ]] \
    && _docker_after="$(cat -- "${_dockerignore}" 2> /dev/null; printf x)"
  [[ "${_git_after}" == "${_git_before}" ]] \
    || _init_record_write ".gitignore"
  [[ "${_docker_after}" == "${_docker_before}" ]] \
    || _init_record_write ".dockerignore"
  return 0
}

# ── Generate per-repo setup.conf ────────────────────────────────────────────
#
# Copies <subtree-prefix>/.setup.conf to <repo>/.setup.conf
# so the user can override any section. Replace strategy: a section present
# in the per-repo file fully replaces the template's corresponding section;
# omitted sections fall back to template.

_gen_setup_conf() {
  local _src="${TEMPLATE_DIR}/dist/.setup.conf"
  local _dst="${REPO_ROOT}/.setup.conf"
  local _force="${1:-false}"
  # .setup.conf is a repo-root dotfile — no parent dir to create.
  if [[ ! -f "${_src}" ]]; then
    _error "Template setup.conf not found at ${_src}"
  fi
  if [[ -f "${_dst}" ]]; then
    if [[ "${_force}" != "true" ]]; then
      _error "setup.conf already exists at ${_dst}. Remove it first or edit directly."
    fi
    # --force path: back up the existing conf (and .env, since a reset
    # will regenerate it from the new conf baseline) to *.bak siblings
    # before overwriting. `.gitignore` ignores these so they never get
    # committed by accident.
    local _bak="${_dst}.bak"
    cp -f "${_dst}" "${_bak}"
    _log "Backed up existing setup.conf → ${_bak}"
    if [[ -f "${REPO_ROOT}/.env" ]]; then
      local _env_bak="${REPO_ROOT}/.env.bak"
      cp -f "${REPO_ROOT}/.env" "${_env_bak}"
      _log "Backed up existing .env → ${_env_bak}"
    fi
  fi
  cp -f "${_src}" "${_dst}"
  _log "Created ${_dst}"
  _log "Edit it to customize runtime settings for this repo."
}

# ── Trigger setup.sh to materialize .env + compose.yaml ─────────────────────

# _call_setup
#   Run setup.sh over this repo, and record whether it wrote `.setup.conf`.
#
#   `.setup.conf` is a published installed path, so the staging step has to
#   decide whether it is this run's output -- and it is one only sometimes.
#   setup.sh writes it on a first-time bootstrap and on a stale-mount_1
#   rewrite, and leaves it exactly as it found it on every other run (see
#   `_reconcile_workspace_path` in lib/setup_detect.sh). On the ordinary
#   upgrade, therefore, the file holds the repo's own tuning.
#
#   Recorded by comparing the file's CONTENT across the call, for a reason
#   the ignore files share (see _sync_existing_gitignore) and take one step
#   further: here the writer is a separate PROCESS, and no shell variable
#   crosses that at all. The `; printf x` on both reads is not a flourish:
#   a command substitution eats trailing newlines, so without it a run
#   whose only change was one would read as no change and go unstaged,
#   leaving the working tree disagreeing with the commit -- the failure
#   this whole step exists to close.
_call_setup() {
  local _conf="${REPO_ROOT}/.setup.conf"
  local _before="" _after=""
  [[ -f "${_conf}" ]] && _before="$(cat -- "${_conf}" 2> /dev/null; printf x)"

  local _setup="${TEMPLATE_DIR}/dist/script/docker/wrapper/setup.sh"
  if [[ ! -f "${_setup}" ]]; then
    _log "Skipping setup.sh (${_setup} not found)"
    return 0
  fi
  _log "Running setup.sh to generate .env + compose.yaml"
  if ! bash "${_setup}" apply --base-path "${REPO_ROOT}" >/dev/null; then
    _log "WARNING: setup.sh exited non-zero; inspect manually and rerun ./build.sh --setup"
  fi

  [[ -f "${_conf}" ]] && _after="$(cat -- "${_conf}" 2> /dev/null; printf x)"
  [[ "${_after}" == "${_before}" ]] || _init_record_write ".setup.conf"
  return 0
}

# _error <message>
#
# The shared fatal path. _log_* takes a REGISTERED EVENT ID as its
# second argument and the human text as a display= attribute -- passing
# the message positionally made every init.sh failure print the logger's
# own unregistered-body complaint instead of the error. Same shape as
# upgrade.sh's sibling.
_error() { _log_err init init_failed "display=$*"; exit 1; }

# ── just runner host preflight ───────────────────────────────────────
#
# `just` is the user-facing entry point for every repo this template
# scaffolds (ADR-00000005 / ADR-00000010 / ADR-00000011): the generated
# `justfile` symlink forwards `just <ns> <verb>` to script/<verb>.sh. But
# the runner lives on the HOST, not in the subtree -- vendoring it is
# rejected (arch-specific binary, --squash injects it into every
# downstream history, a committed binary never updates; Notes).
# So init.sh probes whether `just` is on PATH and, on a miss, emits ONE
# advisory warning pointing at the install methods. It is deliberately
# NON-FATAL: the symlinks + wrappers are already laid down, so installing
# `just` later makes the repo work immediately, and each recipe has a raw
# `./script/<verb>.sh` fallback in the meantime. Idempotent (a pure
# command-presence probe with no side effects), so it is safe on both the
# new-repo and existing-repo init paths.

_just_install_hint() {
  # Single source of truth for the install pointer, mirroring README
  # "Prerequisites". Terse on purpose: the README carries the full method
  # list, this is just enough to unblock the user at the moment it matters.
  #
  # It used to print apt / brew / cargo / the installer as a flat menu of
  # equivalent options. They are not equivalent: measured 2026-08-28,
  # `apt install just` on Ubuntu 24.04 gave 1.21.0 while the installer
  # fetched 1.52.0 and CI ran 1.58.0. So the hint now names the version
  # this repo PINS and points first at the one method that can install
  # exactly it.
  #
  # A hint must never abort init, so an unresolvable pin degrades to a
  # placeholder rather than propagating a failure out of a warning path.
  local _pin
  _pin="$(_just_pinned_version 2>/dev/null)" || _pin="<unresolved>"
  cat <<EOF
  just is NOT auto-installed by init.sh. This repo PINS just ${_pin} --
  the test-tools image, CI and the bootstrap below all run that exact
  version, so a recipe behaves the same everywhere. Install it with the
  official prebuilt-binary installer, which takes the version:
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin --tag ${_pin}
    # or let init bootstrap it for you (opt-in): just base init --bootstrap-just
EOF
  # just-provenance: advisory-begin -- a host package manager installs
  #   whatever version its own registry carries and cannot be pointed at
  #   the pin, so these three are printed as a fallback and the text says
  #   so. Listing them as pinnable sites would be a lie; muting them
  #   silently is how they came to read as equivalents in the first place.
  cat <<'EOF'
  A host package manager is a FALLBACK, not an equivalent -- it installs
  whatever version it carries, which may be many minors behind the pin:
    apt install just      # Debian 13+ / Ubuntu 24.04+
    brew install just     # macOS / Linuxbrew
    cargo install just    # from crates.io
  See README "Prerequisites" or https://github.com/casey/just#installation.
EOF
  # just-provenance: advisory-end
}

_preflight_just() {
  if command -v just >/dev/null 2>&1; then
    return 0
  fi
  # One clear warning carried on a single WARN event. The display= body
  # is a leading line plus the install hint so the whole advisory rides
  # one log record rather than fragmenting across several.
  _log_warn init init_just_missing \
    "display=just runner not found on PATH -- the repo's \`just <ns> <verb>\` commands will not run until it is installed.
$(_just_install_hint)"
}

# _bootstrap_just
#
# Opt-in only (--bootstrap-just). Runs the OFFICIAL prebuilt-binary
# installer into ~/.local/bin exactly as documented in README; never
# invoked without the flag. Prints a PATH reminder when ~/.local/bin is
# absent from PATH so the freshly installed binary is actually reachable.
_bootstrap_just() {
  if command -v just >/dev/null 2>&1; then
    _log "just is already installed ($(command -v just)); nothing to bootstrap"
    return 0
  fi
  # --tag, not "whatever is latest". Without it the installer fetches the
  # newest release of the day, which is how this path came to disagree
  # with the tooling image and with CI; and unlike the hint above, this
  # one INSTALLS, so an unresolvable pin is a hard error rather than a
  # placeholder.
  local _pin
  if ! _pin="$(_just_pinned_version)"; then
    _error "cannot resolve the pinned just version from ${TEMPLATE_DIR}/${_JUST_VERSION_DECL_REL} -- refusing to install an unpinned runner"
  fi
  local _bindir="${HOME}/.local/bin"
  _log_warn init init_bootstrap_just \
    "display=Bootstrapping just ${_pin} via the official installer into ${_bindir} (opt-in)."
  mkdir -p "${_bindir}"
  if ! curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
      | bash -s -- --to "${_bindir}" --tag "${_pin}"; then
    _error "just bootstrap failed -- install manually (see README Prerequisites)"
  fi
  _log "Installed just to ${_bindir}"
  case ":${PATH}:" in
    *":${_bindir}:"*) : ;;
    *) _log "  NOTE: ${_bindir} is not on PATH -- add it (e.g. in ~/.bashrc) to use \`just\`" ;;
  esac
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  # init.sh is a human-facing `base` namespace recipe, so it accepts
  # --lang and honors SETUP_LANG/$LANG via i18n.sh (sourced by _lib.sh). Its
  # own messages are English-only pending the localized pass; --lang
  # is validated here so the flag is accepted, not an error, uniformly with
  # the docker wrappers. Strip --lang <code> before the positional dispatch.
  local _LANG
  _resolve_lang _LANG
  local _bootstrap_just=false
  local -a _args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "init"
        shift 2
        ;;
      # opt-in host bootstrap of the `just` runner. Parsed before the
      # positional dispatch so it composes with the new/existing-repo flow
      # (run the bootstrap first, then init proceeds with `just` present).
      --bootstrap-just)
        _bootstrap_just=true
        shift
        ;;
      *) _args+=("$1"); shift ;;
    esac
  done
  set -- "${_args[@]+"${_args[@]}"}"

  if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    cat >&2 <<'EOF'
Usage: ./<subtree-prefix>/init.sh [--gen-conf [--force]] [--bootstrap-just]
       [--list-installed-paths] [--list-existing-repo-signals]
       [--lang <en|zh-TW|zh-CN|ja>]

Initialize a repo with the template subtree. Auto-detects:
  - Carries a signal (--list-existing-repo-signals) → create symlinks,
    then run setup.sh
  - Carries none of them → generate full project structure, then run
    setup.sh

The subtree prefix is taken from init.sh's own directory; the standard
prefix is `.base/` but the script handles any prefix without code
changes.

Version is tracked in <subtree-prefix>/.version (auto-synced by subtree
pull).

Options:
  --gen-conf         Copy <subtree-prefix>/.setup.conf to
                     <repo>/.setup.conf so the user can
                     override any section (image_name / gpu / gui /
                     network / volumes / security / stage:*). Refuses
                     to overwrite an existing per-repo setup.conf unless
                     --force is given.
  --force            With --gen-conf: overwrite existing setup.conf,
                     backing up the previous .setup.conf to .setup.conf.bak
                     and .env to .env.bak first.
  --list-installed-paths
                     Print, one per line, every repo-relative path an
                     existing-repo resync guarantees a consumer carries,
                     then exit without touching anything. The delivery
                     audit reads this instead of keeping its own copy.
  --list-existing-repo-signals
                     Print, one per line, every repo-relative path whose
                     presence makes init treat this repo as ALREADY set
                     up (the new-vs-existing discriminator), then exit
                     without touching anything. A checker that must know
                     the discriminator -- the template's guard against
                     shipping a file that collides with it -- reads this
                     instead of restating the condition.
  --bootstrap-just   Opt-in: install the `just` runner via the official
                     prebuilt-binary installer into ~/.local/bin before
                     init proceeds, at the version this repo pins (the
                     same one the test-tools image and CI run). Without
                     this flag, a missing `just` only triggers a non-fatal
                     warning (never auto-installed). No-op when `just` is
                     already on PATH.

By default init prints a one-line warning when `just` is not on PATH
(`just` is the user-facing entry point, ADR-00000005); init still
completes so installing `just` later makes the repo work immediately.

Run from the repo root after:
  git subtree add --prefix=<subtree-prefix> \
      <template-remote-url> <version> --squash
EOF
    return 0
  fi

  # `--list-installed-paths` is a QUERY, answered here for the same reason
  # --help is answered above: before the template-source guard and before
  # the `cd` into REPO_ROOT. The caller is an auditor asking the base
  # checkout what a consumer should contain, not a consumer being
  # initialized, so the guard that (correctly) refuses to scaffold inside
  # base must not refuse to answer a question. Nothing below this point is
  # reached, so the run mutates nothing.
  if [[ "${1:-}" == "--list-installed-paths" ]]; then
    _init_installed_paths
    return 0
  fi

  # `--list-existing-repo-signals` is a QUERY too, answered here for the
  # same reasons: the caller is asking what init.sh READS to classify a
  # repo, not asking it to initialize one, and the answer has to be
  # obtainable from a base checkout the self-run guard would (correctly)
  # refuse to scaffold in. Nothing below this point runs, so the query
  # mutates nothing.
  if [[ "${1:-}" == "--list-existing-repo-signals" ]]; then
    _init_existing_repo_signals
    return 0
  fi

  # Refuse to run inside the base template source itself (ADR-00000011 sec.8).
  # A vendored `.base/` subtree never carries `.git`; the base checkout/
  # worktree does, so `.git` at the resolved subtree root means "this is the
  # template source, not a consumer" -- proceeding would scaffold into base's
  # PARENT dir. After --help (which must work anywhere), before any mutation.
  _assert_not_template_source "${TEMPLATE_DIR}" init || exit 1

  cd "${REPO_ROOT}"

  if [[ "${1:-}" == "--gen-conf" ]]; then
    local _force=false
    [[ "${2:-}" == "--force" ]] && _force=true
    _gen_setup_conf "${_force}"
    return 0
  fi

  # opt-in `just` bootstrap runs first so the rest of init proceeds
  # with the runner present (and the closing preflight stays quiet).
  if [[ "${_bootstrap_just}" == "true" ]]; then
    _bootstrap_just
  fi

  local template_version=""
  template_version="$(_detect_template_version)"

  local _resynced=false
  if _init_repo_is_existing; then
    _init_existing_repo
    _resynced=true
  else
    _create_new_repo "${template_version:-main}"
    _create_symlinks
  fi

  _call_setup

  # AFTER _call_setup, not at the end of _init_existing_repo, because
  # `.setup.conf` is written there and it is one of the paths
  # _init_installed_paths publishes. Staging one step earlier committed
  # every other file the resync wrote and left that one untracked -- the
  # same tree/commit disagreement this staging exists to close, one file
  # over. Nothing after this point writes a published path.
  #
  # Existing-repo path only. A brand-new repo has no upgrade commit to
  # join: `_create_new_repo` runs before the first commit exists, and the
  # released `upgrade.sh` that this staging feeds never takes that branch.
  if [[ "${_resynced}" == "true" ]]; then
    _stage_resync_output
  fi

  # host preflight for the `just` runner. Runs on BOTH the new-repo
  # and existing-repo paths (placed in main, after the scaffolding/setup
  # that lays down the justfile symlink). Non-fatal: warns and continues.
  _preflight_just

  _log ""
  _log "Done!"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
