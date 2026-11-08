# Field deployment (`just docker setup deploy`)

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

`just docker setup deploy` (or the direct `./script/setup.sh deploy`) builds a
self-contained field-deploy **folder** from the same `setup.toml` -- the
deploy half of the routing model above
([ADR-00000023](../adr/00000023-config-field-override-and-field-deploy-contract.md),
amending [ADR-00000003](../adr/00000003-env-vs-workload-param-boundary.md);
[PRD invariant 8](../PRD.md)). It targets a *field-oriented* stage (default
`runtime`; **never** `devel` or a `*-test` stage) and produces a folder
carrying everything the target host needs -- the host never sees base's
toolchain, source tree, or `setup.toml`.

```bash
just docker setup deploy                      # build the runtime bundle (prompts first)
just docker setup deploy --stage runtime      # explicit field stage
just docker setup deploy --dry-run            # print the build plan, build nothing
just docker setup deploy --stage runtime -y   # skip the confirmation prompt
just docker setup deploy -o /tmp/robot-bundle # custom output folder
```

The bundle lands at `deploy/<repo>-<stage>-<version>/` (the repo-root
`deploy/` folder is gitignored; `<version>` = `git describe --tags --always
--dirty`, and the image is tagged `<repo>:<stage>-<version>` so loading
several field versions on one host never collides). It contains:

| File | What it is |
|---|---|
| `image.tar.xz` | the `xz`-compressed image (`deploy.sh` `docker load`s it) |
| `compose.yaml` | fully-resolved, self-contained compose -- literal values, **no `${VAR}` interpolation** (except a GUI stage's `${DISPLAY}` host passthrough), no `setup.toml` / `.env` dependency; carries `restart: unless-stopped` |
| `config/` | editable copies of each operator-tunable file (see below) |
| `deploy.sh` | thin `up` / `down` / `logs` launcher |
| `README` | field-operator instructions |

What it does, in order:

1. bake the `[environment]` defaults into the image as real `ENV` (S3) and
   `COPY` every `config/<component>/` into it at `/opt/app/config/<component>`
   (S4) -- so the field image is self-contained (no env file, no config bind
   travels);
2. `docker build --target <stage>` the immutable image, tagged
   `<repo>:<stage>-<version>`;
3. `docker save | xz` it into `image.tar.xz`;
4. write the fully-resolved `compose.yaml` (same shared resolver `apply` uses,
   so the field never drifts from dev), the `deploy.sh` launcher and the
   `README`, then extract each tunable file's baked default into `config/`.

Before building it prints the resolved `compose.yaml` so you can review every
resolved parameter, then prompts (skip with `-y`; `--dry-run` prints the plan
without building; a non-interactive shell without `-y` refuses).

**It refuses outright while `<repo>/setup.local.toml` exists.** That file is
gitignored, so a bundle built from it could not be reproduced from a clean
checkout -- and nothing about the bundle would say why
([PRD invariant 8](../PRD.md),
[ADR-00000025](../adr/00000025-per-worktree-setup-conf-local-override.md)).
The refusal fires before the preview and before any build step, so
`--dry-run` reports it too. `--allow-local-override` builds anyway and
records in the bundle's own `README` which sections came from the untracked
file, because the person running the bundle in the field is not the person
who chose to bypass the gate.

**On the field machine** -- copy the folder over, then drive it with the
`deploy.sh` launcher (it loads the image and drives `docker compose`; no
`docker run`, no `setup.toml`, no base toolchain):

```bash
cd <repo>-runtime-<version>
./deploy.sh up      # unxz | docker load the image, then docker compose up -d
./deploy.sh logs    # docker compose logs (add -f to follow)
./deploy.sh down    # docker compose down
```

`restart: unless-stopped` means the container auto-starts on host reboot; stop
it with `./deploy.sh down`.

**Adjusting config in the field (no rebuild).** A component declares which
container-internal paths a field operator may retune in a committed
`config/<component>/deploy.manifest` (INI-lite, per-stage sections each listing
absolute container paths). The bundle ships an editable copy of each declared
file under `config/`, and the resolved `compose.yaml` bind-mounts it over the
image's baked default (**mount-wins**). Edit a file under `config/` and re-run
`./deploy.sh up` -- the mounted copy wins, no rebuild. Paths **not** declared
stay baked-only. The image must bake a default file at every declared path,
else deploy generation fails loud with an actionable message.

Those binds are **read-only by default**: the operator edits on the host, the
container reads. A path opts into container writes with an explicit `rw` flag,
so the exception is reviewable data rather than a blanket permission:

```ini
[runtime]
/etc/myapp/camera.yaml                  # read-only, the default
/var/lib/myapp/calibration.yaml rw      # the container may write this one
```

Anything else after the path (a typo, a second token) is a malformed manifest
and fails loud naming the file and the line -- never a silent skip, never a
silent downgrade to read-only. The default is not permissive because nothing
in "the operator retunes a value" requires the container to write, and a
writable mount quietly depends on the container's baked-in user id matching
whoever unpacked the bundle on the field host: reads work either way, writes
fail on the machine that matters. Read-only turns that into an immediate,
obvious failure in development instead, and confines the user-id question to
the paths actually declared `rw` (see
[#870](https://github.com/ycpss91255-docker/base/issues/870)).

Workload env vars ride as baked `ENV` defaults (a GUI stage additionally reads
`${DISPLAY}` / `${XAUTHORITY}` etc. from the field host's own shell); the dev
workspace bind is intentionally dropped (the field image ships its own code).
`--group-add` GIDs (iGPU `/dev/dri`) are resolved on the generating host and
may need adjusting on a different field machine.

**Continuous deployment.** The deploy tool labels honestly and never blocks --
it stamps a `-dirty` / short-commit `<version>` so a review deploy of any tree
state is possible. For automated CD, call the base-shipped guard first:
`./.base/dist/deploy/cd-guard.sh` refuses to deploy unless the working tree is
clean **and** HEAD sits on a tag, so a shipped field bundle is always traceable
to a released version.
