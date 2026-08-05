# Smoke Tests

Shared smoke specs that ship under `dist/test/bats/smoke/`: **34 tests**.

> **Not** part of the `just test` self-test grand total — these are
> Dockerfile `-test`-stage build-time assertions, not self-tests. See
> [TEST.md](TEST.md) for the index across all test types.

Shared specs that ship with `dist/test/bats/smoke/` (tool-first: the
`bats` layer mirrors base's own `test/bats/`) and run at Dockerfile
`-test`-stage build time (i.e. during `just docker build test`) inside
both this repo and every downstream repo that consumes the template.
They assert the integrity of the generated `compose.yaml` + the wrapper
scripts' `-h` / `--help` paths, plus the universal "does it even come
up" baseline (entrypoint installed, bash on PATH). **Not** part of the
self-test grand total (see [TEST.md](TEST.md)) (those run via
`just test` and never enter the build graph).

The tree is split per Dockerfile `-test` stage so each stage runs only
the specs that apply to it:

```
dist/test/bats/smoke/
  shared/        # runs on EVERY -test stage (entrypoint + bash baseline)
  devel-test/    # devel-test stage only (wrappers + compose.yaml)
  runtime-test/  # runtime-test stage only (reserved; opt-in runtime split)
```

How they reach downstream repos: each `Dockerfile` `-test` stage does an
explicit selective COPY of only `shared/` + its own `<stage>/`, from
both the template (`.base/dist/test/bats/smoke/`) and the repo
(`test/bats/smoke/`), then runs bats over the flattened `/smoke_test/`:

```dockerfile
COPY .base/dist/test/bats/smoke/shared/     /smoke_test/
COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/
COPY test/bats/smoke/shared/                /smoke_test/
COPY test/bats/smoke/devel-test/            /smoke_test/
RUN bats /smoke_test/
```

No whole-tree COPY, so the ephemeral `-test` image stays small; adding a
stage is a folder plus an analogous COPY block. The shared baseline and
any per-repo `test/bats/smoke/` overlay execute together.

Nothing in this tree skips, and nothing here asserts against the
generated `compose.yaml`. `compose.yaml` is a derived artifact listed in
`.dockerignore`, so it is not in any repo's build context and
`/lint/compose.yaml` cannot exist in any `-test` stage -- assertions
gated on its presence skipped in every build of every repo while reading
as coverage. What the emitter puts in the GUI block (and the structural
no-duplicate-service-key property) is asserted instead in
[unit.md](unit.md)'s `compose_emit/gen_spec.bats`, where
`generate_compose_yaml` can be driven with the GUI resolved both on and
off.

### dist/test/bats/smoke/shared/entrypoint.bats (2)

The cross-stage baseline that runs inside every `-test` stage (devel-test
and runtime-test). Asserts only the universal surface — the installed
entrypoint and bash on PATH — so it never touches `/lint` (populated only
in devel-test).

| Test | Description |
|------|-------------|
| `entrypoint.sh is installed and executable` | Entrypoint present |
| `bash is available on PATH` | Core shell present |

### dist/test/bats/smoke/devel-test/script_help.bats (27)

Locks the `-h` / `--help` invariants on the four wrapper scripts
(`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) plus the `_LANG`
auto-detection rules in `build.sh` (`LANG=zh_TW.UTF-8` → zh, `ja_JP`
→ ja, `en_US` → en, `SETUP_LANG` overrides `LANG`) plus #222
`--help` / `--lang` order independence (pre-pass scans for `--lang`
before main parse so `<script> --help --lang zh-TW` produces zh-TW
usage, not English).

| Test | Description |
|------|-------------|
| `build.sh -h exits 0` | Wrapper smoke |
| `build.sh --help exits 0` | Long flag |
| `build.sh -h prints usage` | Output sanity |
| `build.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help text describes auto-apply, not stale warn-on-drift |
| `run.sh -h exits 0` | Wrapper smoke |
| `run.sh --help exits 0` | Long flag |
| `run.sh -h prints usage` | Output sanity |
| `run.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help text describes auto-apply, not stale warn-on-drift |
| `exec.sh -h exits 0` | Wrapper smoke |
| `exec.sh --help exits 0` | Long flag |
| `exec.sh -h prints usage` | Output sanity |
| `stop.sh -h exits 0` | Wrapper smoke |
| `stop.sh --help exits 0` | Long flag |
| `stop.sh -h prints usage` | Output sanity |
| `build.sh detects zh from LANG=zh_TW.UTF-8` | i18n detect — zh-TW |
| `build.sh detects ja from LANG=ja_JP.UTF-8` | i18n detect — ja |
| `build.sh defaults to en for LANG=en_US.UTF-8` | i18n detect — en default |
| `build.sh SETUP_LANG overrides LANG` | i18n env override |
| `build.sh --help --lang zh-TW prints zh-TW usage (#222)` | - |
| `build.sh --help --lang zh-CN prints zh-CN usage (#222)` | - |
| `build.sh --help --lang ja prints ja usage (#222)` | - |
| `run.sh --help --lang zh-TW prints zh-TW usage (#222)` | - |
| `run.sh --help --lang ja prints ja usage (#222)` | - |
| `exec.sh --help --lang zh-TW prints zh-TW usage (#222)` | - |
| `exec.sh --help --lang ja prints ja usage (#222)` | - |
| `stop.sh --help --lang zh-TW prints zh-TW usage (#222)` | - |
| `stop.sh --help --lang ja prints ja usage (#222)` | - |

### dist/test/bats/smoke/devel-test/display_env.bats (5)

Asserts the `xhost` host-ACL branch of the `run.sh` the stage installs at
`/lint/run.sh`, by **executing** it: `run_wrapper_xhost` (shared
`test_helper`) drives the real wrapper through `--dry-run` with a logging
`xhost` shim first on PATH and reports what it actually called. Every
assertion is two-sided (names what must appear AND what must not), so a
swapped branch fails on both arms; a deleted branch fails because the
driver refuses to report an empty capture. Never skips.

| Test | Description |
|------|-------------|
| `run.sh grants the Wayland host ACL to the configured user` | Wayland session grants `+SI:localuser:<USER_NAME>` and not `+local:` |
| `run.sh grants the X11 host ACL under an X11 session` | X11 session grants `+local:` and not `+SI:localuser` |
| `run.sh defaults to the X11 host ACL when XDG_SESSION_TYPE is unset` | Unset session type falls back to the X11 grant |
| `run.sh grants exactly one host ACL per invocation` | Either/or branch: emitting both would leave the X11 ACL open on Wayland |
| `run.sh interpolates USER_NAME into the Wayland ACL, not a fixed name` | The grant names the configured host user, not a baked-in one |

### dist/test/bats/smoke/shared/test_helper.bash

Not a spec — runtime helpers loaded by every smoke spec via
`load "${BATS_TEST_DIRNAME}/test_helper"`: the `assert_cmd_installed` /
`assert_cmd_runs` / `assert_file_exists` / `assert_dir_exists` /
`assert_file_owned_by` / `assert_pip_pkg` assertions, plus the
`run_wrapper_xhost` wrapper driver. Everything in this file is exercised
via `test/bats/unit/smoke_helper_spec.bats` (which IS in the self-test
grand total) — including `run_wrapper_xhost` against the wrapper at its
source path, so the `xhost` branch is covered by base's own gate and not
only by a downstream image build.
