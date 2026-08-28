# Smoke Tests

Shared smoke specs that ship under `dist/test/bats/smoke/`: **37 tests**.

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

## Running them: `just test smoke`

```bash
just test smoke              # run every shipped smoke spec
just test smoke --no-cache   # ignore the layer cache and re-run them
```

base is the template SOURCE, so it has no `Dockerfile` and no `-test`
stage of its own -- which used to leave the specs it *ships* with nowhere
to run at all. Verifying one meant hand-reproducing the stage with raw
`docker build` / `docker run`, twice (once as root, once as the real
stage's non-root user), which interrupts for a permission decision on
every invocation and leaves nothing the next person can reuse.

`just test smoke` builds `dockerfile/Dockerfile.smoke` through the
`docker` namespace (ADR-00000011 sec.5), the same way `just test system`
builds the tooling image. **Building it IS the test**: the file ends in
`RUN bats /smoke_test/`, exactly as the `-test` stage does, so a failing
spec fails a build rather than being reported by something that could
stop reporting.

### What it mirrors, and what it trades away

Mirrored, because it is what makes the run meaningful:

- the `/lint` COPY set -- the wrappers plus the `lib/` chain they source,
  copied **root-owned** and not `--chown`'d, as the stage does;
- the flattened `/smoke_test/`, built from `smoke/shared/` +
  `smoke/devel-test/`;
- `/entrypoint.sh`, which the shared baseline asserts;
- `BATS_LIB_PATH`, without which every spec errors in `setup`;
- a **non-root** `USER` before the bats run. A harness that ran these as
  root against the source tree would be green in exactly the cases the
  real stage is red.

`test/bats/unit/smoke_harness_spec.bats` walks the shipped stage's COPY
lines and fails when the harness stops reproducing one, so the mirror
cannot quietly fall a stage behind.

Traded away, deliberately: **the base image**. A real `devel-test` stage
is `FROM devel` -- the consumer's Ubuntu image with its apt packages --
and building that means scaffolding a whole consumer repo and a
multi-minute apt build, which is base's `acceptance` CI job's work, not a
local one-command loop's. The harness is `FROM ${TEST_TOOLS_IMAGE}`
instead (the Alpine tooling image, which already carries bats +
bats-support + bats-assert), so anything OS- or package-specific is out of
its reach. That is also why the per-repo `test/bats/smoke/` overlay is not
copied in: base ships these specs, it does not consume them. The stage's
lint half (ShellCheck over the wrappers, Hadolint over the Dockerfile) is
not duplicated either -- `just test lint` already runs both.

### Scope, cache, and why it is not in the default gate

**Scope is `devel-test`**, which is every shipped smoke spec today. There
is no stage argument: `runtime-test` ships none, and its real base is the
MINIMAL runtime image, so running the shared baseline against this
devel-shaped harness and labelling the result `runtime-test` would be a
false green. A unit test fails the day `smoke/runtime-test/` gains a spec,
which is when that decision is due.

**A `CACHED` run is a true statement, not a skipped one -- and it now says
so.** The specs, the wrappers and the lib chain are all COPYed in the
layers directly above `RUN bats`, so touching any of them invalidates it;
a cache hit means these exact inputs already passed. What used to be left
to the reader is that a cache hit and a real run printed the same thing,
so `just test smoke` could be read as evidence of a run that never
happened. The build wrapper now reports which check steps executed and
which were CACHED, and an all-cached run warns that this invocation
verified nothing. Use `--no-cache` when you want to watch it happen
anyway.

**Not part of the default `just test`.** That gate is the fast self-test
-- no daemon, no image build -- and these are a different level: a
Dockerfile stage's build-time assertions, which is also why they are
excluded from the self-test grand total in [TEST.md](TEST.md). Their CI
coverage stays the `acceptance` job, which builds a real scaffolded
consumer's `-test` stage on both arches. The harness itself is covered by
`test/bats/unit/smoke_harness_spec.bats` (in the default gate) and
`test/bats/system/smoke_harness_spec.bats` (under `just test system`).

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

### dist/test/bats/smoke/shared/reproducibility.bats (3)

The reproducibility manifest the template's `sys` stage (and `runtime-base`,
when the runtime split is enabled) writes: `base-image.env` and
`packages.txt` under `/usr/local/share/base/`. Base's own unit specs read
the template as TEXT, which cannot see the failure this file exists for —
a manifest written from a stage where `${BASE_IMAGE}` expanded to the empty
string, so the file lands with an empty record and every static grep stays
green. Skips (rather than fails) when NEITHER file is present: this spec
reaches a consumer through `.base/dist/`, which `just upgrade` refreshes,
while the Dockerfile that writes the manifest is the consumer's own and is
not rewritten by the upgrade. A repo that writes one file and not the
other, or writes an empty record, has adopted the manifest and broken it,
and fails.

| Test | Description |
|------|-------------|
| `the reproducibility manifest is complete` | Both manifest files land in every `-test` stage |
| `the manifest names the base image this stage was built from` | Non-empty `base_image_ref` value plus a `base_image_pin` verdict — the empty-expansion failure |
| `the manifest records package versions, not just package names` | `dpkg-query -W` name/version pairs, not a bare name list |

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
