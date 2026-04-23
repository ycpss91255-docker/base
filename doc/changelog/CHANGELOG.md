# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.9.0] - 2026-04-23

### Added (Wave 1 + Wave 2 — 2026-04-22)
- **GPU MIG detection** (`_detect_mig` / `_list_gpu_instances` in
  `_tui_conf.sh`): when host has NVIDIA MIG mode enabled, the deploy
  editor opens with a msgbox listing GPU / MIG instance UUIDs and
  advising `NVIDIA_VISIBLE_DEVICES=<MIG-UUID>` via `[environment]`
  since `count=N` targets whole GPUs only
- **`[build] tz` key**: container timezone exposed as a setup.conf
  value; pipes through to compose.yaml `build.args` as
  `TZ: ${TZ:-Asia/Taipei}`. Empty keeps Dockerfile default
- **`[devices] cgroup_rule_*`**: `device_cgroup_rules:` block for USB
  hotplug / dynamic device nodes; TUI devices editor now has a
  sub-menu to pick between device bindings and cgroup rules. New
  `_validate_cgroup_rule` validator

### Changed
- `[image] rule_*` dedup on write: re-adding a rule that already
  exists at another slot moves it to the new position instead of
  leaving two identical entries
- `_edit_list_section` add now reuses empty slots (e.g. cleared
  `mount_1` after user opted out of workspace), preventing the next
  mount from leapfrogging to `mount_2`
- TUI image-rule type picker simplified to function names only
  (`prefix` / `suffix` / `@basename` / `@default`); format + example
  shown in the value inputbox
- TUI footer buttons (`Save` / `Enter` / `Cancel`) no longer i18n'd;
  consistent English across all locales
- `_TUI_LANG_UPPER` initialised at source time so sourcing `setup_tui.sh`
  and calling a section editor directly (tests, REPL) no longer
  crashes on unbound variable under `set -u`
- **CLI consistency**: `exec.sh` / `stop.sh` now accept `--lang LANG`
  (matches `build.sh` / `run.sh`); `stop.sh` gains `-a` short flag
  for `--all` (matches common CLI patterns). Unknown lang values
  warn and fall back to `en` via `_sanitize_lang`
- **`--gen-image-conf` alias removed** from `init.sh` / `upgrade.sh`;
  the `--gen-conf` name is the only spelling. The alias was a
  rename-artifact and not documented outside in-tree help
- **`tui.sh` → `setup_tui.sh`**: pairs with `setup.sh` and makes the
  "interactive editor for setup.conf" relationship explicit.
  `init.sh` now creates `setup_tui.sh` and removes any stale `tui.sh`
  symlink left behind by pre-rename installs
- **`_print_config_summary` full dump**: `build.sh` / `run.sh` now
  print every populated `setup.conf` section (image / build / deploy /
  gui / network / security / resources / environment / tmpfs /
  devices / volumes) alongside identity, file paths, and the resolved
  GPU/GUI/TZ flags — so users see every value this run consumes
  without having to diff `.env` or run `docker compose config`

### Added
- **`[build] target_arch` TARGETARCH override**: new scalar key
  alongside the `arg_N` list. Non-empty value pins Docker's
  `TARGETARCH` build arg for both the main image and the test-tools
  image (main via compose `build.args`, test-tools via
  `build.sh --build-arg`). Empty (default) leaves BuildKit's
  auto-detection intact. Valid values: `amd64` / `arm64` / `arm` /
  `386` / `ppc64le` / `s390x` / `riscv64`. `setup_tui.sh` → Build
  adds a dedicated menu entry; `_validate_target_arch` catches typos
  like `aarch64` / `x86_64` (BuildKit uses `arm64` / `amd64`).
- **`Dockerfile.test-tools` multi-arch**: `ARG TARGETARCH=amd64`
  branches the ShellCheck + Hadolint download URLs via a `case`
  statement. BuildKit auto-fills on amd64 / arm64 hosts; falls back
  to amd64 binaries on legacy builders. Rejects unsupported arches
  loudly instead of silently grabbing a wrong-arch binary
- **`setup_tui.sh --lang <invalid>` surfaces a TUI msgbox** before
  the main menu opens. Previously the `_sanitize_lang` stderr warning
  scrolled away as soon as dialog/whiptail cleared the screen; the
  user saw a silently-English TUI with no hint why. New
  `_warn_if_lang_rejected` helper captures the raw input and opens a
  "Language fallback" msgbox listing the valid codes

### Performance
- **`make test` no longer runs kcov** — the dev loop pays for bats +
  shellcheck only. `make coverage` keeps the full kcov path for CI
  and release checks. `ci.sh --ci` honors `$COVERAGE=1` to include
  kcov when the outer `--coverage` flag is set
- **`bats --jobs $(nproc)` parallelism** — GNU parallel runs the
  524-test suite concurrently across files and within files. All
  specs already use per-test `mktemp -d` dirs so there's no shared
  filesystem state. Combined effect (cached apt):
  before ~1m27s (serial + kcov) → now ~42s (parallel, no kcov) ≈ 2x
  faster on the dev loop

### BREAKING
- **Language code `zh` renamed to `zh-TW`** (BCP-47). `--lang zh`
  no longer accepted; use `--lang zh-TW` (Taiwan Traditional).
  `zh-CN` / `ja` / `en` unchanged
- **`@env_example` image-name rule removed**: legacy rule that read
  `IMAGE_NAME` from `.env.example` deleted along with its TUI option
  + i18n keys. `.env` is a setup.sh-derived artifact so the rule
  created a cycle. Replace with explicit `rule_N = @default:<name>`
  or set `IMAGE_NAME` directly

### Removed (tried, reverted)
- **B7 vim keybindings** (attempted `DIALOGRC bindkey j/k/h/l`):
  reverted in `ccc0dbc`. `dialog` 1.3 rejects letter curses_keys —
  only symbolic names (`TAB` / `DOWN` / `UP` / `ENTER`) are valid.
  See repo-root `TODO.md` for alternative-backend options (gum /
  fzf / textual) queued for a future PR

### Changed (TUI UX 重構 — 2026-04-21 本地)
- **主選單重組**：11 項平鋪 → 5 常用（network / deploy / gui / volumes /
  environment）+ `advanced` 子選單（image / build / devices / tmpfs /
  security）
- **Save UX**：去掉 `__save` menu item，改用 dialog/whiptail 的
  `--extra-button --extra-label "Save & Exit"`（exit code 3 = save
  訊號，0 = 進選中項，1 = Cancel）
- **List sections 統一 single-layer**：volumes / environment / devices /
  tmpfs / ports 點 item 直接 inputbox；**空值 + OK = mark_removed**
  （該 key 從 setup.conf 消失）；list menu 只保留 Add / Back
- **Conditional triggers**：`shm_size` 不再是主選單項，改為
  `[network] ipc != host` 時從 network 結尾彈出；`ports` 改為
  `mode == bridge` 時從 network 結尾彈出
- **privileged 遷移**：從 `[network] privileged` 搬到新 `[security]
  privileged`。TUI 的 privileged yesno 由 Advanced → Security 編輯
- **`[security]` 新 section**：privileged / cap_add_* / cap_drop_* /
  security_opt_*。先前 compose.yaml 硬編的 SYS_ADMIN / NET_ADMIN /
  MKNOD / seccomp:unconfined 改為 setup.conf template 預設值，可由
  TUI 或手編調整

### Removed
- **cgroup (`device_cgroup_rules`)**：setup.conf 註解、parser、TUI、
  compose.yaml `device_cgroup_rules:` 產生邏輯全拿掉。使用者手寫
  `cgroup_N = ...` 會被忽略

### Added
- **Interactive TUI** (`setup_tui.sh`) for editing `<repo>/setup.conf` via
  dialog (with whiptail fallback). Main menu + direct-jump subcommands
  (`./setup_tui.sh image|build|network|deploy|gui|volumes`). Validates
  mount format, GPU count, and enum fields before save. On save,
  invokes `setup.sh` automatically to regenerate `.env` +
  `compose.yaml`. Symlinked from each repo root via `init.sh`.
  4-language i18n (en / zh / zh-CN / ja).
- **`_tui_backend.sh`** — dialog/whiptail abstraction
  (`_tui_menu`, `_tui_radiolist`, `_tui_checklist`, `_tui_inputbox`,
  `_tui_yesno`, `_tui_msgbox`). Preferred backend auto-detected;
  exits with install hint when neither is installed.
- **`_tui_conf.sh`** — pure-logic INI read/write helpers:
  `_load_setup_conf_full` (full file with section order preserved),
  `_write_setup_conf` (comment-preserving overwrite),
  `_upsert_conf_value` (single-key in-place edit), plus validators
  (`_validate_mount`, `_validate_gpu_count`, `_validate_enum`) and
  mount-string parsers.
- **`[build]` section** in `setup.conf` for Dockerfile build args
  (`apt_mirror_ubuntu`, `apt_mirror_debian`). Empty value keeps the
  hard-coded Taiwan mirror defaults.
- **Workspace writeback**: on first run (when `<repo>/setup.conf` does
  not exist), `setup.sh` detects the workspace host path, copies
  `template/setup.conf` to `<repo>/setup.conf`, and writes the
  detected workspace into `[volumes] mount_1`. Subsequent runs read
  `mount_1` as the source of truth. Clearing `mount_1` is treated as
  opt-out; the workspace is omitted from `compose.yaml` and `setup.sh`
  does not re-populate it.
- `build.sh` / `run.sh` `--setup` / `-s` is now **TTY-aware**: under
  an interactive terminal with `setup_tui.sh` available, it launches the
  TUI; otherwise it runs `setup.sh` non-interactively (unchanged
  behaviour for CI / non-TTY).
- `init.sh _create_symlinks` adds `setup_tui.sh` alongside the existing
  five symlinks.
- **Single `setup.conf`** at repo root consolidates all runtime
  configuration consumed by `setup.sh`: `[image]`, `[build]`,
  `[deploy]`, `[gui]`, `[network]`, `[volumes]`. Template default
  lives at `template/setup.conf`; per-repo override at
  `<repo>/setup.conf` uses section-level replace strategy (a section
  present in the per-repo file fully replaces the template's section;
  omitted sections fall back to template).
- `setup.sh` new helpers: `_parse_ini_section`, `_load_setup_conf`,
  `_get_conf_value`, `_get_conf_list_sorted`, `_resolve_gpu`,
  `_resolve_gui`, `detect_gui`, `_compute_conf_hash`,
  `_check_setup_drift`, and `generate_compose_yaml`. `setup.sh` now
  emits a full `compose.yaml` alongside `.env` with conditional GPU
  `deploy` block, conditional GUI env/volumes, and extra volumes from
  `[volumes]` section.
- **Drift detection** via `.env` metadata: setup.sh writes
  `SETUP_CONF_HASH`, `SETUP_GUI_DETECTED`, `SETUP_TIMESTAMP` into
  `.env`; `build.sh` / `run.sh` compare stored values against current
  state and warn when `setup.conf` was modified, GPU/GUI detection
  changed, or UID changed. Warnings are non-blocking; user re-runs with
  `--setup` to regenerate.
- `build.sh` / `run.sh` **`--setup`** (`-s`) flag: forces setup.sh to
  regenerate `.env` + `compose.yaml`. Default behaviour: auto-bootstrap
  on missing `.env` (first run / CI fresh clone); warn on drift if
  `.env` exists.
- `init.sh` new option: `--gen-conf` copies `template/setup.conf` to
  `<repo>/setup.conf` for per-repo override. `--gen-image-conf` is kept
  as a back-compat alias.
- New unit spec `test/unit/compose_gen_spec.bats` (14 tests) covering
  `generate_compose_yaml` conditional output.

### Changed
- **PR #74's `template/config/setup/` directory removed**: the
  separate `image_name.conf` / `gpu.conf` / `gui.conf` / `network.conf`
  / `volumes.conf` files introduced in #74 are consolidated into a
  single `setup.conf` INI. `config/` now strictly contains container
  internal configs (bashrc, tmux, pip, terminator); runtime wiring
  lives at repo root alongside `Dockerfile`.
- `compose.yaml` is now a **derived artifact** (gitignored) generated
  by `setup.sh` on every invocation. Users inspect it for the current
  effective runtime config; source of truth is `setup.conf`.
- **BREAKING — setup.conf section rename**:
  `[image_name]` → `[image]`; `[gpu]` → `[deploy]` with keys prefixed
  (`mode` → `gpu_mode`, `count` → `gpu_count`,
  `capabilities` → `gpu_capabilities`). Also introduces `[build]`
  (apt mirrors). Template `setup.conf` updated; per-repo overrides
  must use the new names.
- `detect_image_name` now reads `[image] rules` (comma-separated
  ordered list) from `setup.conf` instead of a dedicated
  `image_name.conf` rule file. Rule semantics unchanged
  (`prefix:`, `suffix:`, `@env_example`, `@basename`, `@default:`).
- `build.sh` / `run.sh`: removed `--no-env` flag (semantic reversed —
  setup.sh no longer runs by default, so the opposite `--setup` flag
  was introduced). `exec.sh` / `stop.sh` unchanged (container state is
  already frozen when they run).
- `write_env` signature expanded with new columns written to `.env`:
  `NETWORK_MODE`, `IPC_MODE`, `PRIVILEGED`, `GPU_COUNT`,
  `GPU_CAPABILITIES`, `SETUP_CONF_HASH`, `SETUP_GUI_DETECTED`,
  `SETUP_TIMESTAMP`.
- `generate_compose_yaml` baseline: only `${WS_PATH}:/home/${USER_NAME}/work`
  is always emitted; `/dev:/dev` now lives in `setup.conf`'s
  `[volumes]` template default (user-replaceable). GUI-related
  volumes/env are emitted iff `[gui] mode` resolves enabled.
- Version tracking moved from `.template_version` (repo root, manually
  maintained) to `template/VERSION` (inside subtree, auto-synced by
  `git subtree pull`). `init.sh` and `upgrade.sh` automatically clean up
  the legacy `.template_version` file. `build-worker.yaml` reads
  `template/VERSION` with `.template_version` fallback for transition.

### Documentation
- README (4 languages) and `init.sh` header now document the full
  bootstrap sequence for a brand-new repo: `git init` + an empty initial
  commit must run before `git subtree add`, otherwise subtree fails with
  `ambiguous argument 'HEAD'` and `working tree has modifications`.

### Removed
- `template/config/image_name.conf` (content absorbed into
  `template/setup.conf` under `[image_name] rules =`).
- `--no-env` flag on `build.sh` / `run.sh` (replaced by default
  no-run-setup + opt-in `--setup`).

### Fixed
- `test/smoke/test_helper.bash`: `assert_cmd_installed` now returns `1`
  after calling `fail`, so callers can short-circuit via `|| return 1`
  instead of silently falling through. `assert_cmd_runs` and
  `assert_pip_pkg` now short-circuit when the target command is missing,
  so they no longer execute `run <missing-cmd>` and emit a spurious
  Bats BW01 warning.
- `test/unit/lib_spec.bats`, `test/unit/pip_setup_spec.bats`,
  `test/unit/setup_spec.bats`: replace `run <cmd>` / `assert_failure`
  pairs with `run -127 <cmd>` on the five tests whose command is
  expected to exit 127 (`_load_env` missing arg, `_compose` on empty
  PATH, `pip setup.sh` without pip, `setup.sh main --base-path` /
  `--lang` missing value). Silences Bats BW01. Files that use `run -N`
  flags now declare `bats_require_minimum_version 1.5.0` to silence
  BW02.

## [v0.8.1] - 2026-04-15

### Fixed
- `upgrade.sh`: drop the auto-appended `Co-Authored-By: Claude ...`
  trailer from the `chore: update template references` commit message.
  AI-attribution lines are visual noise for reviewers and the project
  convention is to omit them everywhere (PR body, commit message, code).

## [v0.8.0] - 2026-04-15

### Added
- `test/smoke/test_helper.bash`: shared runtime assertion helpers for
  downstream-repo smoke specs — `assert_cmd_installed`, `assert_cmd_runs`,
  `assert_file_exists`, `assert_dir_exists`, `assert_file_owned_by`,
  `assert_pip_pkg`. Each prints a decorated diagnostic on failure so the
  bats log points at the exact missing artifact. Keeps downstream smoke
  specs terse and self-documenting.
- `init.sh` new-repo skeleton now emits two sample smoke assertions
  (`entrypoint.sh is installed and executable`, `bash is available on
  PATH`) demonstrating the shared helpers, instead of one bare
  `[ -x /entrypoint.sh ]` assertion.
- `test/unit/ci_spec.bats` (5 tests): covers `script/ci/ci.sh`
  `_install_deps` — happy path plus the three explicit error branches
  for `apt-get update` / `apt-get install` / `git clone bats-mock`.
- `test/unit/smoke_helper_spec.bats` (19 tests): unit coverage for every
  runtime assertion helper above, including failure paths.
- `test/unit/setup_spec.bats`: 3 new `detect_ws_path` cases — explicit
  ERROR on missing `base_path`, and path-normalization coverage for
  strategies 1 and 3 when the input contains `..` segments.
- `test/unit/init_spec.bats` (15 tests): unit coverage for `init.sh`
  helpers previously reachable only through the Level-1 integration
  test — `_detect_template_version` (git-remote parsing, failure
  paths, rc-tag filtering), `_create_version_file` (parameterized
  version, `unknown` fallback, overwrite), `_create_new_repo`
  (workflow `@ref` threading including empty-ref → `@main` fallback),
  and `_create_symlinks` (full symlink set, stale-file replacement,
  custom `.hadolint.yaml` preservation).
- `test/unit/ci_spec.bats`: 3 new `_run_shellcheck` tests — wired-file
  regression guard, `script/docker/*.sh` discovery via `find`, and
  strict-mode propagation on lint failure.

### Fixed
- `init.sh`: stop hard-coding `v0.5.0` as the fallback version in the
  generated `main.yaml`. Workflow refs now fall back to the `main` branch
  (a valid git ref) when no tag is detected, instead of an arbitrary old
  tag. Version detection is done once up-front and shared between
  `.template_version` and the reusable-workflow `@ref`.
- `script/docker/setup.sh` `detect_ws_path`: normalize `base_path` with
  `cd ... && pwd -P` before composing sibling/parent paths, so relative
  or `..`-laden inputs do not produce surprising matches. Emits a clear
  error when the base path does not exist.
- `script/docker/setup.sh`: use `${0:-}` consistently in the
  `BASH_SOURCE == $0` guard (line 400) for parity with line 51.
- `script/ci/ci.sh` `_install_deps`: emit explicit error messages when
  `apt-get update`, `apt-get install`, or `git clone bats-mock` fails,
  instead of relying on `set -e` to exit silently.

### Changed
- `script/ci/ci.sh`: guard `main "$@"` and `set -euo pipefail` behind a
  `BASH_SOURCE == $0` check so the helpers (`_install_deps`, `_die`) can
  be sourced by unit tests without executing the CI pipeline. Matches
  the pattern already used in `script/docker/setup.sh`.
- `init.sh`: wrap top-level flow in `main()` + `BASH_SOURCE == $0` guard
  so helpers (`_detect_template_version`, `_create_version_file`,
  `_create_new_repo`, `_create_symlinks`) are sourceable from unit
  tests without triggering a full `init.sh` run. Strict mode is also
  gated so sourcing respects the caller's settings. Behaviour when
  invoked directly is unchanged.

## [v0.7.2] - 2026-04-14

### Changed
- Align `build.sh` / `run.sh` / `exec.sh` / `stop.sh` with Google Shell Style
  Guide: wrap top-level logic in a `main()` function with `local` variables,
  fix `case` indentation. Behavior unchanged.
- `config/pip/setup.sh`, `config/shell/tmux/setup.sh`,
  `config/shell/terminator/setup.sh`: drop `-x` from strict mode
  (`set -eux` → `set -euo pipefail`) so docker build logs stay quieter.
  Tracing can still be enabled on demand via `bash -x`.
- `script/ci/ci.sh`: refactor kcov `--exclude-path` into a readable array
  instead of one long comma-joined string. Behavior unchanged.
- Re-indent all `.bats` files under `test/smoke/`, `test/unit/`, and
  `test/integration/` from 4-space to 2-space per Google Shell Style Guide.
  Heredoc bodies untouched. Behavior unchanged; all 247 tests still pass.

## [v0.7.1] - 2026-04-10

### Fixed
- `run.sh` foreground devel: `./run.sh` appeared to hang for ~10s after the
  user typed `exit` because the cleanup trap ran `compose down` with the
  default 10s SIGTERM grace period. Pass `-t 0` so the already-exited
  interactive container is killed immediately.

## [v0.7.0] - 2026-04-09

### Added
- `build.sh` / `run.sh` / `exec.sh` / `stop.sh`: `--dry-run` flag prints the
  `docker` / `docker compose` commands that would run instead of executing them.
  Useful for debugging compose / env / instance resolution without side effects.
- `exec.sh`: precheck refuses with a friendly error pointing at `./run.sh`
  (and `--instance NAME` if applicable) when the target container is not running,
  instead of letting `compose exec` print the cryptic `service "devel" is not running`.

### Changed
- Refactor: extracted shared helpers (`_LANG` setup, `_load_env`, `_compute_project_name`,
  `_compose`, `_compose_project`) into `template/script/docker/_lib.sh`. `build.sh`,
  `run.sh`, `exec.sh`, and `stop.sh` now source `_lib.sh` and call the helpers instead
  of duplicating the same i18n / env-loading / compose-flag boilerplate.
- `exec.sh`: passes the user command as a positional array (`"$@"`) to `compose exec`,
  so arguments containing whitespace are preserved instead of being word-split.
- `run.sh`: trap is now `trap _devel_cleanup EXIT` (calls a named function) instead of
  an inline string-expanded command, matching `build.sh`'s style.

## [v0.6.8] - 2026-04-09

### Added
- `run.sh` / `exec.sh` / `stop.sh`: `--instance NAME` flag for parallel container instances
  - `./run.sh --instance dev2` starts a parallel container alongside the default
  - `./exec.sh --instance dev2 [cmd]` enters that named instance
  - `./stop.sh --instance dev2` stops only that one
  - `./stop.sh --all` stops the default + every named instance for this image
- Project name and container name now include `${INSTANCE_SUFFIX}` so each
  instance has isolated docker compose project (own network/volumes)
- `init.sh`-generated `compose.yaml` uses
  `container_name: ${IMAGE_NAME}${INSTANCE_SUFFIX:-}`
  - Default invocation (no `--instance`) keeps the clean name `${IMAGE_NAME}` —
    backward-compatible with external tools that grep `docker exec ${IMAGE_NAME}`

### Changed
- `run.sh`: foreground devel now refuses to start if a container with the
  default name is already running. Use `./stop.sh` first or pass
  `--instance NAME` to start a parallel one.

### Note
- Existing 17 consumer repos must update their `compose.yaml` to use
  `container_name: ${IMAGE_NAME}${INSTANCE_SUFFIX:-}` (one-line edit) before
  `--instance` works there. Default behavior unchanged until they upgrade.

## [v0.6.7] - 2026-04-09

### Added
- `test/integration/init_new_repo_spec.bats`: 21 Level-1 integration tests
  - Verifies `init.sh` produces a complete repo skeleton in an empty dir
    (Dockerfile, compose.yaml, .env.example, symlinks, doc tree, .github/workflows, etc.)
  - Runs inside the existing `make -f Makefile.ci test` container — no Docker needed
  - Total tests: 180 → 201 (180 unit + 21 integration)
- `.github/workflows/self-test.yaml`: new `integration-e2e` job (Level 2)
  - Runs `init.sh` → `build.sh test` → `build.sh` → `run.sh -d` → `exec.sh` → `stop.sh`
    on a synthetic temp repo, on a real GitHub runner with Docker daemon
  - `release` job now depends on both `test` and `integration-e2e`
- `script/ci/ci.sh`: now also runs `bats test/integration/` alongside `test/unit/`

## [v0.6.6] - 2026-04-09

### Fixed
- `run.sh`: foreground `devel` mode could not be entered via `./exec.sh` from another terminal
  - Symptom: `service "devel" is not running` even though `docker ps` showed it
  - Root cause: foreground used `compose run --name`, which creates a one-off container
    invisible to `compose exec` (the underlying mechanism behind `./exec.sh`)
  - Fix: foreground `devel` now uses `compose up -d` + `compose exec devel bash`
    + a `trap … down EXIT` to preserve the original "exit shell = container gone" semantic
  - Other targets (`test`, `runtime`, ...) still use `compose run --rm` (one-shot stages
    that don't need exec)
  - `compose.yaml` `container_name: ${IMAGE_NAME}` is unchanged, so external scripts
    that do `docker exec ${IMAGE_NAME}` (e.g. local CI helpers) continue to work

### Removed
- `stop.sh`: orphan-container cleanup `docker rm -f "${IMAGE_NAME}"` no longer needed
  (no more orphan from `compose run --name`)

## [v0.6.5] - 2026-04-09

### Fixed
- `build.sh`/`run.sh`/`exec.sh`/`stop.sh`: graceful fallback when `i18n.sh` is missing
  - v0.6.1 added `source template/script/docker/i18n.sh` but consumer Dockerfile
    `test` stages do `COPY *.sh /lint/` without the template tree, so the source
    failed and broke smoke tests in all consumer repos
  - Fix: each script checks for i18n.sh and falls back to inline `_detect_lang`
    if missing — no Dockerfile changes required in consumer repos

## [v0.6.4] - 2026-04-09

### Fixed
- `upgrade.sh`: greedy sed pattern clobbered `release-worker.yaml@<ver>` reference,
  replacing it with `build-worker.yaml@<ver>` and breaking release CI in consumer repos
  - Root cause: `s|template/\.github/workflows/.*@v[0-9.]*|...build-worker.yaml@...|`
    matched both worker references; the dedicated `release-worker` line that follows
    only worked when the first sed didn't already overwrite it
  - Fix: drop the greedy first sed, keep only the per-worker-name targeted seds

## [v0.6.3] - 2026-04-09

### Added
- `upgrade.sh`: `--gen-image-conf` flag (delegates to `init.sh --gen-image-conf`)
  - Lets users copy `image_name.conf` to repo root for per-repo customization
    without needing to remember the init.sh path

## [v0.6.2] - 2026-04-09

### Changed
- Remove all `# LCOV_EXCL_*` markers from shell scripts to expose real coverage
  - Coverage now reflects actual instrumented lines (95.76% vs prior masked 100%)
  - 2 new direct-run tests for `tmux/setup.sh` and `terminator/setup.sh` (171 total)
  - Remaining 10 uncovered lines in `setup.sh` are kcov bash backend limitations
    (case `;;` arms, `done` redirect close, child-bash guards)

## [v0.6.1] - 2026-04-08

### Added
- `build.sh`: `--clean-tools` flag to remove `test-tools:local` image after build
- `script/docker/i18n.sh`: shared `_detect_lang()` and `_LANG` initialization
  - Sourced by build.sh, run.sh, exec.sh, stop.sh, setup.sh
  - Eliminates ~28 lines of duplication across 5 scripts
  - Adding a new language now requires editing only one file
- `dockerfile/Dockerfile.test-tools`: include `bats-mock` (jasonkarns v1.2.5)
  - Other repos' smoke tests can now use `stub`/`unstub` for command mocking

### Changed
- `build.sh`: keep `test-tools:local` image by default (was removed on EXIT)
  - Avoids race conditions in parallel builds
  - Subsequent builds skip the test-tools build (Docker layer cache)
  - Use `--clean-tools` to restore old behavior

## [v0.6.0] - 2026-04-01

### Added
- `build.sh`: `--no-cache` flag for force rebuild (passes to both
  test-tools image build and docker compose build)
- `config/image_name.conf`: rule-driven IMAGE_NAME detection
  - Rule types: `prefix:<value>`, `suffix:<value>`, `@env_example`, `@basename`, `@default:<value>`
  - Per-repo override: place `image_name.conf` in repo root
  - Default rules: `@env_example` → `prefix:docker_` → `suffix:_ws` → `@default:unknown`
- `init.sh --gen-image-conf`: copy template's image_name.conf to repo root
  for per-repo customization

### Changed
- `detect_image_name`: refactored to read rules from `image_name.conf` instead
  of hardcoded logic
- **BREAKING**: `image_name.conf` keywords now require `@` prefix
  (`env_example` → `@env_example`, `basename` → `@basename`) to distinguish
  from user-defined values
- Default conf order: `@env_example` → `prefix:docker_` → `suffix:_ws` → `@default:unknown`
  (`.env.example` highest priority; `@default:unknown` as final fallback
  prints INFO log so users know to set IMAGE_NAME explicitly)
- New `@default:<value>` keyword: explicit fallback value with INFO log
- WARNING only when no rule matches AND no `@default:` set (custom conf scenario)

### Fixed
- `stop.sh`: remove orphan container left by `docker compose run --name`
  (`docker compose down` only cleans up `up`-mode containers, not `run`-mode)
- `upgrade.sh`: re-run `init.sh` after subtree pull to sync symlinks
  (avoids stale symlinks when template directory structure changes)

### Removed
- Stale comments referencing `get_param.sh` (historical, no longer relevant)

## [v0.5.0] - 2026-03-31

### Added
- `setup.sh`: add `APT_MIRROR_UBUNTU` and `APT_MIRROR_DEBIAN` to `.env`
  - Default: `tw.archive.ubuntu.com` (Ubuntu), `mirror.twds.com.tw` (Debian)
  - Preserves existing values from `.env` on re-run
- `setup.sh`: warn when `IMAGE_NAME` cannot be detected and `.env.example` not found
- `display_env.bats`: auto-skip GUI tests for headless repos
- `dockerfile/Dockerfile.test-tools`: pre-built test tools image (ShellCheck + Hadolint + Bats)
- `dockerfile/Dockerfile.example`: Dockerfile template for new repos
- `init.sh`: support creating new repo with full project structure
- `build.sh`: auto-build `test-tools:local` before compose build
- 5 new tests (137 total)

### Changed
- **BREAKING**: Directory restructure
  - `build.sh`, `run.sh`, `exec.sh`, `stop.sh`, `Makefile`, `setup.sh` → `script/docker/`
  - `ci.sh` → `script/ci/`
  - `init.sh`, `upgrade.sh` → template root (user-facing)
- Other repos symlink path: `template/build.sh` → `template/script/docker/build.sh`

## [v0.4.2] - 2026-03-30

### Fixed
- `run.sh`: set `--name "${IMAGE_NAME}"` in foreground mode (`docker compose run`) so container name matches `container_name` in compose.yaml

### Removed
- `script/migrate.sh`: all repos migrated, no longer needed
- i18n translations for TEST.md and CHANGELOG.md (keep English only)

## [v0.4.1] - 2026-03-29

### Changed
- Rename `test/smoke_test/` → `test/smoke/`
- Fix README.md TOC anchor and add missing Tests section

## [v0.4.0] - 2026-03-29

### Changed
- Move `config/` back to root level (was `script/config/` in v0.3.0) — configs are not scripts
- Fix `self-test.yaml` release archive: remove stale root `setup.sh` reference
- Fix mermaid architecture diagrams: `setup.sh` shown in correct `script/` box
- Add Table of Contents to zh-TW and zh-CN READMEs
- Add `Makefile.ci` entry to "What's included" table (all translations)
- Fix "Running Tests" section to use `make -f Makefile.ci` (all translations)
- Rename `test/smoke_test/` → `test/smoke/`

## [v0.3.0] - 2026-03-29

### Changed
- **BREAKING**: Rename repo `docker_template` → `template`
- **BREAKING**: Move `setup.sh` → `script/setup.sh`
- **BREAKING**: Move `config/` → `script/config/` (reverted in v0.4.0)
- Apply Google Shell Style Guide to all shell scripts
- Split `Makefile` into `Makefile` (repo entry) + `Makefile.ci` (CI entry)
- Fix directory structure, test counts, bashrc style in documentation
- 132 tests (was 124)

### Migration notes
- Other repos: subtree prefix changes from `docker_template/` to `template/`
- `CONFIG_SRC` path in Dockerfile: `docker_template/config` → `template/config`
- Symlinks: `docker_template/*.sh` → `template/*.sh`

## [v0.2.0] - 2026-03-28

### Added
- `script/ci.sh`: CI pipeline script (local + remote)
- `Makefile`: unified command entry
- Restructured `test/unit/` and `test/smoke_test/`
- Restructured `doc/` with i18n (readme/, test/, changelog/)
- Coverage permissions fix (chown with HOST_UID/HOST_GID)

### Changed
- `smoke_test/` moved to `test/smoke_test/` (**BREAKING**: Dockerfile COPY path change)
- `compose.yaml` calls `script/ci.sh --ci` instead of inline bash
- `self-test.yaml` calls `script/ci.sh` instead of docker compose directly

## [v0.1.0] - 2026-03-28

### Added
- **Shared shell scripts**: `build.sh`, `run.sh` (with X11/Wayland support), `exec.sh`, `stop.sh`
- **setup.sh**: `.env` generator merged from `docker_setup_helper` (auto-detect UID/GID, GPU, workspace path, image name)
- **Config files**: bashrc, tmux, terminator, pip configs from `docker_setup_helper`
- **Shared smoke tests** (`smoke_test/`):
  - `script_help.bats` — 16 tests for script help/usage
  - `display_env.bats` — 10 tests for X11/Wayland environment (GUI repos)
  - `test_helper.bash` — unified bats loader
- **Template self-tests** (`test/`): 114 tests with ShellCheck + Bats + Kcov coverage
- **CI reusable workflows**:
  - `build-worker.yaml` — parameterized Docker build + smoke test
  - `release-worker.yaml` — parameterized GitHub Release
  - `self-test.yaml` — template's own CI
- **`migrate.sh`**: batch migration script for converting repos from `docker_setup_helper` to `template`
- `.hadolint.yaml`: shared Hadolint rules
- `.codecov.yaml`: coverage configuration
- Documentation: README (English), README.zh-TW.md, README.zh-CN.md, README.ja.md, TEST.md

### Changed
- `setup.sh` default `_base_path` traverses 1 level up (`/..`) instead of 2 (`/../..`) to match new `template/setup.sh` location

### Migration notes
- Replace `docker_setup_helper/` subtree with `template/` subtree
- Shell scripts at root become symlinks to `template/`
- Local `build-worker.yaml` / `release-worker.yaml` replaced by reusable workflow calls in `main.yaml`
- Dockerfile `CONFIG_SRC` path: `docker_setup_helper/src/config` → `template/config`
- Shared smoke tests loaded via `COPY template/smoke_test/` in Dockerfile (not symlinks)

[v0.6.8]: https://github.com/ycpss91255-docker/template/compare/v0.6.7...v0.6.8
[v0.6.7]: https://github.com/ycpss91255-docker/template/compare/v0.6.6...v0.6.7
[v0.6.6]: https://github.com/ycpss91255-docker/template/compare/v0.6.5...v0.6.6
[v0.6.5]: https://github.com/ycpss91255-docker/template/compare/v0.6.4...v0.6.5
[v0.6.4]: https://github.com/ycpss91255-docker/template/compare/v0.6.3...v0.6.4
[v0.6.3]: https://github.com/ycpss91255-docker/template/compare/v0.6.2...v0.6.3
[v0.6.2]: https://github.com/ycpss91255-docker/template/compare/v0.6.1...v0.6.2
[v0.6.1]: https://github.com/ycpss91255-docker/template/compare/v0.6.0...v0.6.1
[v0.6.0]: https://github.com/ycpss91255-docker/template/compare/v0.5.0...v0.6.0
[v0.5.0]: https://github.com/ycpss91255-docker/template/compare/v0.4.2...v0.5.0
[v0.4.2]: https://github.com/ycpss91255-docker/template/compare/v0.4.1...v0.4.2
[v0.4.1]: https://github.com/ycpss91255-docker/template/compare/v0.4.0...v0.4.1
[v0.4.0]: https://github.com/ycpss91255-docker/template/compare/v0.3.0...v0.4.0
[v0.3.0]: https://github.com/ycpss91255-docker/template/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/ycpss91255-docker/template/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/ycpss91255-docker/template/releases/tag/v0.1.0
