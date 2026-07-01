# Smoke Tests

Shared smoke specs that ship under `dist/test/bats/smoke/`: **40 tests**.

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
`display_env.bats` self-skips on headless repos by detecting the absence
of GUI lines in the generated `compose.yaml`.

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

### dist/test/bats/smoke/devel-test/display_env.bats (11)

Asserts the generated `compose.yaml` carries the X11 / Wayland env
+ volume block expected by GUI containers, and that `run.sh` runs the
right `xhost` command per session type. Auto-skipped when the repo's
`compose.yaml` has no GUI block (headless repos like `multi_run`).

| Test | Description |
|------|-------------|
| `compose.yaml contains WAYLAND_DISPLAY env` | Wayland env line |
| `compose.yaml contains XDG_RUNTIME_DIR env` | Wayland session dir env |
| `compose.yaml contains XAUTHORITY env` | X11 auth env |
| `compose.yaml mounts XDG_RUNTIME_DIR as rw` | Wayland socket mount |
| `compose.yaml mounts XAUTHORITY volume` | X11 auth mount |
| `compose.yaml has no consecutive duplicate keys` | YAML hygiene |
| `compose.yaml mounts X11-unix volume` | X11 socket mount |
| `run.sh contains XDG_SESSION_TYPE check` | Session-type branch |
| `run.sh calls xhost +SI:localuser on wayland` | Wayland xhost path |
| `run.sh calls xhost +local: on X11` | X11 xhost path |
| `run.sh defaults to X11 xhost when XDG_SESSION_TYPE unset` | Fallback path |

### dist/test/bats/smoke/shared/test_helper.bash

Not a spec — runtime helper (`assert_compose_has` / `skip_if_headless`
etc.) loaded by every smoke spec via `load "${BATS_TEST_DIRNAME}/test_helper"`.
Asserts in this file are exercised via `test/bats/unit/smoke_helper_spec.bats`
(which IS in the self-test grand total).
