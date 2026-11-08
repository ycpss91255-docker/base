# Dockerfile stages (convention)

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

Downstream repos follow a standard multi-stage layout, defined in
`dist/dockerfile/Dockerfile`. All stages share a common base image
parameterized by `ARG BASE_IMAGE`.

| Stage | Parent | Purpose | Shipped? |
|-------|--------|---------|----------|
| `sys` | `${BASE_IMAGE}` | User/group, sudo, timezone, locale, APT mirror, reproducibility manifest | intermediate |
| `devel-base` | `sys` | Development tools and language packages | intermediate |
| `devel` | `devel-base` | App-specific tools + `entrypoint.sh` + PlotJuggler (env repos) | **yes** (primary artifact) |
| `devel-test` | `devel` | Ephemeral: ShellCheck + Hadolint + Bats smoke, tools copied from `${TEST_TOOLS_IMAGE}` | no (discarded) |
| `builder` (optional) | `devel-base` | Compile step whose output `runtime` copies, so `runtime` ships no toolchain | intermediate |
| `runtime-base` (optional) | `${BASE_IMAGE}` | Minimal runtime deps (sudo, tini) | intermediate |
| `runtime` (optional) | `runtime-base` | Slim runtime image (application repos only) | yes, when enabled |
| `runtime-test` (optional) | `runtime` | Ephemeral: runtime smoke assertions | no (discarded) |

Notes:
- `BASE_IMAGE` defaults to the moving tag `ubuntu:24.04` and the apt layers on
  top of it are unversioned, so the same template version does not reproduce
  the same image over time. The drift is deliberate (consumers override
  `BASE_IMAGE`, and a dev image must be able to take a security update without
  a template release) but it is RECORDED: `sys` writes
  `/usr/local/share/base/base-image.env` (the base reference, whether that
  reference is digest-pinned, the digest the build was told to record, the
  base OS) and
  `/usr/local/share/base/packages.txt` (every package and its exact version,
  rewritten after each apt layer), and labels the image
  `org.opencontainers.image.base.name` / `.base.digest`. `runtime-base`
  re-emits both, since it starts from a fresh `${BASE_IMAGE}` and inherits
  nothing.
- What the shipped default does **not** record: built as shipped, the manifest
  says `base_image_pin=none` and leaves `base_image_digest` empty — nothing
  inside a build can ask the daemon which image a tag resolved to. Pass
  `BASE_IMAGE_DIGEST` (a record, not a pin) alongside `BASE_IMAGE` to fill it
  in. Pinning `BASE_IMAGE` to a digest builds on its own and records
  `base_image_pin=digest`, but still leaves that field empty: the annotation
  is written by a `LABEL`, and a `LABEL` cannot branch on whether the
  reference carries a digest — the expression that strips one returns the
  whole reference when there is none — so it carries the build arg and
  nothing else. Empty in both sinks is a truthful "not recorded", so the
  build does not refuse it; what fails is a `BASE_IMAGE_DIGEST` naming a
  different digest than the reference, caught by the shipped smoke spec in
  the `-test` stage.
- Repos that only ship a developer image (`env/*`) skip `runtime-base` /
  `runtime` — the section stays commented in `Dockerfile`.
- `devel-test` is always built from `devel`, so runtime assertions inside
  `test/bats/smoke/<repo>_env.bats` see the same binaries / files a user would
  find after `docker run ... <repo>:devel`.
- `Dockerfile.test-tools` builds the lint/test tool bundle (bats + shellcheck +
  hadolint + kcov + yq). The downstream `devel-test` stage consumes it through
  the `ARG TEST_TOOLS_IMAGE` build arg, which has **no default**: `build.sh`
  passes the version-scoped `test-tools:<base-version>` it builds into the host
  Docker daemon, and CI passes `ghcr.io/ycpss91255-docker/test-tools:<version>`
  (the pre-built multi-arch image `.github/workflows/release-test-tools.yaml`
  pushes on every tag), so buildx pulls the arch-correct binaries instead of
  rebuilding them per run. Leaving it unset resolves an empty base image and
  fails the build loudly, rather than reusing a stale local image of the
  wrong version.

## Baked artifacts live at `/opt`, not `$HOME`

The container user is baked at **build** time: the `sys` stage takes the
`USER_NAME` / `USER_UID` / `USER_GID` build args and `devel` then sets
`ENV HOME="/home/${USER_NAME}"`. `just docker build` injects the local host's user,
while CI and the release path bake `user` (UID 1000) -- so `$HOME` differs
between two images built from the same commit.

Anything an image bakes **under `$HOME`** is therefore coupled to the
build-time username, and that only bites at deploy time: run a prebuilt /
GHCR / `docker save`+`load` image under a different `USER_NAME`, or rebuild
with one, and every home-relative path points at a different, **empty**
`/home/<other>/...`. The baked workspace is invisible and
`source ~/some_ws/install/setup.bash` fails. An absolute `/opt/...` path is
immune -- there is no `$HOME` indirection left to resolve.

The convention, stated in the shipped `Dockerfile` where you will meet it:

1. Install self-built artifacts (colcon workspaces, SDKs, compiled tools) at
   absolute `/opt/<name>`. Reserve `$HOME` for dotfiles and convenience
   symlinks.
2. Source the **absolute** path from the entrypoint / bashrc, never `~` or
   `$HOME`. A `~/<name> -> /opt/<name>` symlink created in the per-user `RUN`
   block is encouraged for interactive discoverability, but nothing may
   *source* it.
3. Never spell a concrete username into a path -- use `${HOME}` /
   `${USER_NAME}`.

Rule 3 is mechanical and gated: the `home-literal` lint
(`just test lint --home-literal`, CI job `lint-static` (one of its groups)) fails
on a concrete username in a home path anywhere under `dist/` or
`dockerfile/`. Rules 1-2 are a judgement call no grep can make. Rationale:
[ADR-00000024](../adr/00000024-bake-artifacts-at-opt-not-home.md).

## Adding extra stages (#215)

Any `FROM <base> AS <stage>` outside the baseline blocklist
`{sys, devel-base, devel, runtime-test}` (legacy
`{base, test}` also accepted during the v0.21.x transition) is
auto-emitted as a compose service that
`extends: devel` (inherits volumes / network / GPU / GUI / cap_add /
additional_contexts) and overrides only `build.target` / `image` /
`stdin_open` / `tty` / `profiles`. Use case:
entrypoint variants like NVIDIA Isaac Sim's `headless` + `gui` on top
of `devel`.

User flow:

```dockerfile
# Add to Dockerfile (no setup.toml change needed)
FROM devel AS headless
ENTRYPOINT ["/isaac-sim/runheadless.sh"]
CMD ["-v"]

FROM devel AS gui
ENTRYPOINT ["/isaac-sim/runapp.sh"]
```

```bash
just docker build                            # regenerates compose.yaml, builds all stages
just docker run -t headless                  # runs the headless variant
just docker run -t gui                       # runs the gui variant
just docker exec -t headless bash            # exec into running headless container

# Kit-style args (containing `=`) pass straight through as recipe
# arguments — no env-var workaround needed:
just docker exec -t headless-stream /isaac-sim/runheadless.sh -v --/app/livestream/port=49100

# Equivalent direct wrapper invocation:
./script/build.sh
./script/run.sh -t headless
./script/exec.sh -t headless bash
```

Constraints:

- Stage names must match `^[a-z][a-z0-9_-]*$` — uppercase / leading
  digit / dot etc. are rejected (WARN + skip; the rest of the parse
  continues).
- Names colliding with the baseline `{sys, devel-base, devel,
  runtime-test}` (plus legacy aliases `{base, test}` during the
  v0.21.x transition) are a hard error from `setup.sh apply`. So are
  names colliding with the template-controlled image-tag namespace
  (`latest`, `v[0-9]*`). `devel-test` is **not** in that set and **not**
  a collision — it is emitted as the `test` service through the
  per-stage model (#493, see below), which is what gives
  `[stage:devel-test]` a runtime control surface.
- Adding / removing a stage triggers `setup.sh check-drift` (via
  `SETUP_DOCKERFILE_HASH` in `.env.generated`), so wrappers auto-regenerate
  `compose.yaml` on the next invocation. Unrelated `RUN apt-get
  install` edits do **not** trigger drift.

## Per-stage `setup.toml` overrides (#220)

Stages auto-emitted by #215 share devel's runtime config (volumes /
GPU / network / GUI) by default. When a stage needs different runtime
settings — e.g. NVIDIA Isaac Sim's `headless` running a WebRTC
livestream wants `network=bridge` + a port mapping + `gui=off`, while
`devel` and `gui` keep `network=host` + X11 — add a `[stage:<name>]`
table to your repo's `setup.toml`. TOML quotes a table name containing a
colon, so it is written `["stage:headless"]`, and the dotted override keys
are quoted too:

```toml
[gui]
mode = "auto"

[network]
mode = "host"

["stage:headless"]
"gui.mode" = "off"
"network.mode" = "bridge"
"network.port_1" = "8080:80"
"deploy.gpu_capabilities" = "gpu compute utility graphics video"
```

Use `just docker setup-tui` for an interactive editor:

- **Advanced → Per-stage overrides**: drills straight into the editor.
  The entry only appears when your Dockerfile has at least one
  non-baseline stage.
- **Features → Per-stage overrides** (#221): always-visible
  discoverability surface that lists conditional / power-user
  features. When the precondition is met it acts as a shortcut into
  the same editor; when not, it pops a msgbox explaining how to
  enable.

Allowlist (v1 — keys that can be overridden per-stage):

| Section | Keys |
|---|---|
| `[deploy]` | `gpu_mode`, `gpu_count`, `gpu_capabilities`, `gpu_runtime` (legacy `runtime` still accepted) |
| `[gui]` | `mode` |
| `[network]` | `mode`, `ipc`, `pid`, `network_name`, `port_<N>`, `port_inherit` |
| `[security]` | `privileged`, `cap_add_<N>`, `cap_add_inherit`, `cap_drop_<N>`, `cap_drop_inherit`, `security_opt_<N>`, `security_opt_inherit` |
| `[volumes]` | `mount_<N>`, `mount_inherit` |
| `[environment]` | `env_<N>`, `env_inherit` |

List fields (`mount_*` / `port_*` / `env_*` / `cap_add_*` / `cap_drop_*`
/ `security_opt_*`) follow **append-default**: the stage's items are
appended to top-level entries. To replace top-level entirely, set
`<list>_inherit = false` (e.g. `volumes.mount_inherit = false`, or
`security.cap_add_inherit = false` to drop a stage's inherited caps —
#526: a read-only probe stage clears the flash stage's `SYS_ADMIN`).

Notes:

- `[stage:devel]` is **reserved** (v1 no-op + WARN). Edit top-level
  sections to tune devel. Revisit in v2.
- `[stage:devel-test]` (#493) is the override surface for the **`test`
  service** (the `devel-test` Dockerfile stage). By default `test`
  `extends: devel` and inherits its runtime config; declare
  `[stage:devel-test]` to diverge — e.g. `deploy.gpu_mode = force` to
  give GPU-requiring runtime tests (Isaac Sim pytest) a GPU even when
  devel has none. The service name stays `test` (`./script/exec.sh -t
  test` unchanged); `build.target` stays `devel-test`.
- `[stage:sys|base|test]` is a **hard error** (baseline collision) —
  use `[stage:devel-test]` to control the test service, not
  `[stage:test]`.
- `[stage:foo]` referencing a stage absent from the Dockerfile is
  **WARN + skipped** (the rest of `setup.sh apply` continues).
- Override keys outside the allowlist are **WARN + skipped per-key**.

## Smoke test helpers (for downstream repos)

`dist/test/bats/smoke/shared/test_helper.bash` (flattened next to each
spec in the image, and loaded by every smoke spec via
`load "${BATS_TEST_DIRNAME}/test_helper"`) ships a small set of runtime
assertion helpers. Downstream repos should prefer these over ad-hoc
`[ -f ... ]` / `command -v` checks so failures produce decorated
diagnostics pointing at the missing artifact.

| Helper | Usage |
|--------|-------|
| `assert_cmd_installed <cmd>` | Fails unless `<cmd>` is on `PATH` |
| `assert_cmd_runs <cmd> [flag]` | Fails unless `<cmd> <flag>` exits 0 (default flag: `--version`) |
| `assert_file_exists <path>` | Fails unless `<path>` is a regular file |
| `assert_dir_exists <path>` | Fails unless `<path>` is a directory |
| `assert_file_owned_by <user> <path>` | Fails unless `<path>`'s owner is `<user>` |
| `assert_pip_pkg <pkg>` | Fails unless `pip show <pkg>` returns 0 |
