# Integration Tests

Integration specs under `test/bats/integration/`: **94 tests**.

> Part of the `just test` self-test suite — what runs in the `Self Test`
> CI job. See [TEST.md](TEST.md) for the index across all test types and
> the self-test grand total.

## Test Files

### test/bats/integration/init_new_repo_spec.bats (59)

End-to-end verification that `init.sh` produces a complete repo skeleton in
an empty directory. **Level 1** (file generation only, no Docker). The
**Level 2** equivalent runs as the `acceptance` job in
`.github/workflows/self-test.yaml` (the host-driven consumer/UX checks;
see [acceptance.md](acceptance.md)), which has access to a Docker daemon on
the host runner. It drives the documented `just` verbs with REAL execution
on native amd64 + arm64: the build / run -d / exec / stop runnability core
(#579/#603) plus (#769) the foreground `run` command variant, `start`
(build + run), a real `prune`, an explicit `setup apply`, the `base update`
check, and the `base completions` installer. `setup-tui` (interactive) is
intentionally out of the e2e -- it needs a pseudo-TTY and stays covered by
the unit `tui_spec`.

| Test | Description |
|------|-------------|
| `init.sh detects empty dir and creates new repo skeleton` | Smoke |
| `new repo: Dockerfile is copied from template` | Dockerfile gen |
| `new repo: compose.yaml exists and references the repo name` | compose gen |
| `new repo: .env.example is NOT generated (image name via setup.conf rules)` | setup.conf rules drive IMAGE_NAME |
| `new repo: script/entrypoint.sh exists and is executable` | entrypoint gen |
| `new repo: script/entrypoint.sh sources [logging] helper by default (refs #364)` | default in-image helper source line + comment present; ${USER} / /home/ absent (regression guards) |
| `new repo: smoke test skeleton exists for the repo` | smoke skeleton |
| `new repo: .github/workflows/main.yaml exists with reusable workflow ref` | CI gen |
| `new repo: main.yaml grants permissions: contents: write` | #62 release perms |
| `new repo: .gitignore exists` | gitignore |
| `new repo: doc/ tree exists with README translations` | i18n docs |
| `new repo: doc/test/TEST.md exists` | TEST.md gen |
| `new repo: doc/changelog/CHANGELOG.md exists` | CHANGELOG gen |
| `new repo: build.sh symlink lives under script/, not root (#330)` | symlink target moved to script/build.sh |
| `new repo: 7 wrapper symlinks under script/, justfile at root (#330, #546)` | symlink set: 7 wrappers + justfile root, no Makefile |
| `new repo: config/ is an empty placeholder (template#254 layered override)` | config placeholder |
| `new repo: init.sh preserves pre-existing config/ directory (no clobber)` | config preservation |
| `new repo: init.sh drops stale config symlink before creating placeholder` | config-symlink drop |
| `Dockerfile.example references CONFIG_SRC="config" (not .base/config)` | CONFIG_SRC default |
| `Dockerfile.example has layered config COPY chain (template#254)` | layered COPY order |
| `Dockerfile.example declares ENV HOME before WORKDIR ${HOME}/work (#334)` | HOME env directive |
| `Dockerfile.example sets up bashrc.d drop-in directory (template#254)` | bashrc.d setup |
| `new repo: Dockerfile contains _entrypoint_logging.sh in-image COPY (#368)` | End-to-end check on init.sh-generated repo |
| `new repo: .base/.version exists (no legacy VERSION / .template_version)` | version file |
| `new repo: re-running init.sh on the result is idempotent` | idempotent |
| `new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)` | setup_tui under script/ |
| `new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)` | upgrade cleanup |
| `new repo: init.sh removes stale root *.sh symlinks (#330 migration)` | migrate 7 root symlinks to script/ |
| `new repo: build.sh -h works against the generated symlink` | smoke script/build.sh |
| `new repo: run.sh -h works against the generated symlink` | smoke script/run.sh |
| `new repo: exec.sh -h works against the generated symlink` | smoke script/exec.sh |
| `new repo: stop.sh -h works against the generated symlink` | smoke script/stop.sh |
| `new repo: setup.sh symlink under script/ → ../.base/script/docker/setup.sh` | setup.sh under script/ |
| `new repo: setup.sh -h works against the generated symlink` | smoke script/setup.sh |
| `init.sh --gen-conf copies setup.conf to repo root` | setup.conf gen |
| `init.sh --gen-conf refuses to overwrite existing setup.conf` | overwrite safety |
| `new repo: .gitignore contains compose.yaml (derived artifact)` | gitignore compose.yaml |
| `new repo: .gitignore contains .env (derived artifact)` | gitignore .env |
| `new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)` | setup.sh generated compose.yaml |
| `new repo: compose.yaml ships devices: /dev:/dev by default` | default device mount |
| `new repo: setup.conf mount_1 is NOT empty after first init` | workspace writeback non-empty |
| `new repo: per-repo setup.conf auto-created on first init (workspace writeback)` | #201 — bootstrap writes WS_PATH back |
| `new repo: script/local/justfile.local seeded (repo-local command-group registry)` | #632 — repo-owned registry seeded |
| `new repo: init.sh preserves a pre-existing script/local/justfile.local (no clobber)` | #632 — never clobbers repo registrations |
| `new repo: script/template/ symlinks wired for the template namespace` | #633 — justfile.template + new.sh + skel symlinked |
| `new repo: script/base/ symlink wired for the base namespace` | #652, #653 — justfile.base + completions.sh symlinked; entry mods base |
| `new repo: init warns + exits 0 + still creates symlinks when just is absent (#607)` | Missing runner -> non-fatal WARN, symlinks still laid down |
| `new repo: init is silent about just when the runner is present (#607)` | Runner present -> no warning |
| `init.sh refuses to run when the subtree root carries .git (base template source)` | Self-run guard (ADR-00000011 sec.8): .git at subtree root -> refuse, no scaffold |

### test/bats/integration/fresh_clone_portability_spec.bats (2)

End-to-end verification for the fresh-clone-on-a-different-machine scenario:
the consumer repo's `setup.conf` has already been committed by another
contributor and carries either a stale absolute `mount_1` path (the Jetson
bug) or the portable `${WS_PATH}` form. Runs the real `build.sh` +
`setup.sh` (no mocks) and asserts the auto-migration / per-machine detection
pipeline lands a valid `.env` + `compose.yaml`. **Level 1** (no Docker
invocation — `build.sh --dry-run`).

| Test | Description |
|------|-------------|
| `fresh clone with stale absolute mount_1: build.sh auto-migrates + generates local .env` | Stale-path auto-migrate |
| `fresh clone with portable ${WS_PATH} mount_1: no warning, .env gets local path` | Happy path round-trip |

### test/bats/integration/wrapper_compose_dispatch_spec.bats (6)

Behaviour-based assertion (#490) that every wrapper routes its `docker compose`
calls through the `-p`-injecting dispatcher. Reuses the
`fresh_clone_portability_spec.bats` fixture pattern (cp `/source` -> `.base/`,
symlink the wrappers from the repo root, materialize `.env` + `compose.yaml`
via `build.sh --dry-run`), then runs each wrapper with `--dry-run` and
inspects the planned `[dry-run] docker compose -p <project> <verb>` line.
Immune to internal renames (replaces the old name-coupled `_compose_project` /
`_app_cleanup` greps in `template_spec.bats`) and catches a raw-`docker
compose` bypass (a missing `-p`). **Level 1** (no Docker invocation).

| Test | Description |
|------|-------------|
| `build.sh --dry-run dispatches compose build with -p project flag` | build dispatch |
| `run.sh --dry-run (default devel) dispatches compose up + exec with -p` | run devel up+exec |
| `exec.sh --dry-run dispatches compose exec with -p` | exec dispatch |
| `stop.sh --dry-run dispatches compose down with -p` | stop dispatch |
| `run.sh foreground --dry-run installs cleanup that downs with --remove-orphans` | EXIT-trap cleanup |
| `no wrapper dispatches compose without -p (bypass regression)` | bypass catcher |

### test/bats/integration/upgrade_spec.bats (14)

End-to-end verification for `upgrade.sh` driving a real subtree update
against a fake template remote (bare repo with `v0.9.5` / `v0.9.7` tags
on a minimal subtree layout) attached to a sandbox downstream repo.
**Level 1** (no Docker). Exercises the happy path, the pre-flight
guards, the destructive-FF rollback path added after the Jetson v0.9.7
incident (stubs `git-subtree pull` via `GIT_EXEC_PATH` to simulate the
bug and asserts the repo is restored), and Step 5's declarative
Dockerfile/entrypoint migration pass (#567 / #579) — sourcing
`lib/dockerfile_migrate.sh` and running `apply_migrations` over the
repo-root Dockerfile + sibling `script/entrypoint.sh` (the per-migration
{detect, transform} units are unit-tested in `dockerfile_migrate_spec.bats`).

| Test | Description |
|------|-------------|
| `upgrade.sh v0.9.7: bumps template/.version, pulls new content, updates main.yaml` | Happy path |
| `upgrade.sh Step 5 announces the migration pass (#567)` | Step 5 runs the declarative migration dispatcher |
| `upgrade.sh heals a legacy wrapper-COPY Dockerfile via the migration list (#567 m1)` | End-to-end wrapper-copy heal + staged into the upgrade commit |
| `upgrade.sh nounset-guards a sibling entrypoint ROS source (#567 m8 / #579)` | End-to-end entrypoint nounset guard around the ROS setup.bash source |
| `upgrade.sh Step 5 continues cleanly when no Dockerfile at repo root (#567)` | Subtree-only repos (no consumer Dockerfile) skip silently |
| `upgrade.sh migrations are idempotent — already-migrated Dockerfile unchanged (#567)` | A second upgrade is a no-op on an already-migrated Dockerfile |
| `upgrade.sh v0.9.7 is idempotent on a second run` | Re-run is no-op |
| `upgrade.sh --check reports update available from v0.9.5 → v0.9.7` | --check flag |
| `just base update (downstream entry): exit 0 when update available (#175, #546, #652)` | Regression #175: recipe wraps exit 1 (skips w/o just) |
| `just base update (downstream entry): exit 0 when up-to-date (#546)` | Up-to-date path stays green (skips w/o just) |
| `upgrade.sh fails fast when git identity is missing` | Pre-flight identity guard |
| `upgrade.sh fails fast when MERGE_HEAD is present` | Pre-flight merge-state guard |
| `upgrade.sh rolls back when git-subtree does a destructive fast-forward` | Destructive-FF rollback |
| `upgrade.sh (#654 relocated): git subtree pull uses --prefix=.base, not --prefix=base` | Walk-up self-location resolves the subtree prefix to `.base` after the deep relocation; real subtree pull lands with no stray `base/` dir |

### test/bats/integration/gitignore_sync_spec.bats (13)

End-to-end coverage that wires `lib/gitignore.sh` through `init.sh`'s
new-repo + existing-repo paths and `upgrade.sh`'s commit step. Standalone
fixture (independent of `upgrade_spec.bats`'s stub-init fixture) because
gitignore sync requires the **real** `init.sh` to run during Step 3 of
`upgrade.sh`. Issue #172.

| Test | Description |
|------|-------------|
| `init.sh new-repo: .gitignore contains all 7 canonical entries` | New-repo path uses lib |
| `init.sh new-repo: .gitignore has the 'managed by template' marker` | Marker comment present |
| `init.sh existing-repo: appends missing canonical entries to user .gitignore` | Drift fill-in |
| `init.sh existing-repo: untracks compose.yaml that was committed` | 15-repo drift heal |
| `init.sh existing-repo: setup.conf stays committed across init runs (#201)` | 2-file model: setup.conf is user override |
| `init.sh existing-repo: idempotent — second run produces no .gitignore changes` | Re-run no-op |
| `upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit` | One-shot upgrade |
| `upgrade.sh end-to-end: idempotent on a second run — no extra commits` | Re-upgrade clean |

