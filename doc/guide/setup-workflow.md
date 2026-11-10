# setup.sh workflow: TUI, host-detection overrides, hooks

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

## Interactive TUI

`just docker setup-tui` (`./script/setup_tui.sh`) opens the main menu. The backend is `dialog` or `whiptail` (when both are missing it prints a `sudo apt install dialog` hint and exits). Cancel / Esc leaves without saving; saving auto-invokes `setup.sh` to regenerate `.env.generated` + `compose.yaml`.

`just docker setup-tui <SECTION>` jumps straight to one editor. The `[deploy]` section configures GPU reservation only — it is named after Compose's `deploy:` key and has nothing to do with `just docker setup deploy`, which builds a field-deploy bundle. Its unambiguous name is therefore `gpu` (`just docker setup-tui gpu`); `deploy` still works and opens a notice explaining which of the two you got.

Main menu structure (#221):

```
Main
├─ image            IMAGE_NAME detection rules
├─ build            APT mirrors + Dockerfile build args
├─ Runtime  ──→     network / deploy (GPU) / gui / environment / logging
├─ Mounts   ──→     volumes / devices / tmpfs
├─ Advanced ──→     security / additional_contexts
│                   / per_stage (conditional) / Reset
├─ Features         conditional / power-user features index
│                   (today: per_stage status row)
└─ Save & Exit
```

`just docker setup-tui <section>` drills directly into a section editor (e.g. `just docker setup-tui volumes`), bypassing the main menu.

## Host-detection overrides

`setup.sh apply` probes the host for two properties that gate the
`auto` resolver modes. Operators can override the probe with an
environment variable when the host's real state is wrong for the
target (containerised / CI hosts, or simulating other hardware). The
override only short-circuits detection; the resolver logic is unchanged.

| Env var | Replaces | Value | Effect under `auto` |
|---|---|---|---|
| `SETUP_DETECT_JETSON` | `/etc/nv_tegra_release` probe | `true` / `false` | `deploy.gpu_runtime` -> `nvidia` and `build.network` -> `host` when `true` |
| `SETUP_DETECT_DRI_GROUPS` | `stat` of `/dev/dri/{card*,renderD*}` | space-separated GIDs (empty = none) | `deploy.dri_groups` emits `group_add` with these GIDs |

```bash
# Simulate a Jetson on a desktop (forces nvidia runtime + host build-net)
SETUP_DETECT_JETSON=true ./script/setup.sh apply

# Pin the /dev/dri render GIDs a container is granted on a CI host
SETUP_DETECT_DRI_GROUPS="44 992" ./script/setup.sh apply
```


These are first-class operator knobs, not test-only hooks.

## Per-wrapper hooks (#440)

Every wrapper (`run` / `build` / `exec` / `stop` / `prune` / `setup` /
`setup_tui`) checks for an optional repo-local script at:

```
script/hooks/pre/<wrapper>.sh    # runs after env prep, before main work
script/hooks/post/<wrapper>.sh   # runs after main work (or in EXIT trap for run.sh)
```

`init.sh` ships 14 executable stubs (`exit 0` by default), so the
hook framework is ready out of the box. Replace `exit 0` with your
own host-side steps (e.g. `multiarch/qemu-user-static` binfmt
registration, mount-point dir creation, hardware preflight). Stubs
are idempotent across upgrades — pre-#440 templates pick up the
scaffolding on the next `just base upgrade`.

**Contract:**

| Aspect | Behavior |
|---|---|
| Args | Same `"$@"` the wrapper received |
| Where | Host-side (NOT inside the container) |
| `pre` non-zero | Aborts the wrapper |
| `post` non-zero | Overrides wrapper exit code; cleanup still runs (run.sh) |
| Not executable | Hard fail with `chmod +x` hint |
| `--dry-run` | Both hooks silently skipped |

**Example — jetson_sdk_manager binfmt setup:**

```bash
# script/hooks/pre/run.sh
#!/usr/bin/env bash
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  docker run --rm --privileged \
    multiarch/qemu-user-static --reset -p yes
fi
```
