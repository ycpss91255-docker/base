# Where each parameter lives (env vs workload)

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

Not every runtime value belongs in `setup.toml`. The dividing question
(axis A, [ADR-00000003](../adr/00000003-env-vs-workload-param-boundary.md))
is **"does this value change when you switch machines?"** -- if yes it is
*environment* (machine-bound, stays in `setup.toml`); if it changes per
task it is *workload*. "Does it need a rebuild?" (axis C) breaks grey
cases. Three channels carry these values, and only the first survives
into a field deployment that ships just the image:

| Parameter kind | Examples | Where it lives | Dev host | Field |
|---|---|---|---|---|
| machine-bound / set-once | GPU reservation, `privileged`, device/volume mounts, `IMAGE_NAME`, APT mirror | `setup.toml` (committed) | rendered into `compose.yaml` | resolved into the bundle's self-contained `compose.yaml` (literal values, no `${VAR}`) |
| volatile workload **env vars** | `ROS_DOMAIN_ID`, `LOG_LEVEL`, API tokens, dataset selectors | `.env.local` (hand-authored, gitignored) | `env_file: [.env, .env.local]` -- the generated `.env` carries the `[environment]` defaults, yours override them (later file wins) | the bundle ships both: `.env` lists every default it runs with (incl. `WATCHDOG_*`), `.env.local` is where the operator retunes one without a rebuild |
| structured app **config** | bridge topic lists, pipeline definitions | `config/<component>/` (#504, #1000) | every component directory bind-mounted at `/opt/app/config/<component>` (edit + restart, no rebuild) | each `COPY`-baked at the same path + optional mount-wins override via `config/<component>/deploy.manifest` (edit `config/` + `./deploy.sh up`, no rebuild) |

`setup.toml`'s `[environment]` section is the *first* kind -- stable,
machine-bound env defaults. They are written into the generated `.env` and
baked into the runtime image as `ENV`. Put per-task env vars in `.env.local`
instead, so a tweak needs only `just docker run` (no `compose.yaml`
regenerate, no `SETUP_CONF_HASH` drift, no git churn).

Nothing in either file is emitted into a service's compose `environment:`
list, and that is deliberate: compose ranks `environment:` above `env_file`,
so a default left there would silently outrank your `.env.local` entry and
nothing would report it.

> The env-file pair, the runtime-stage `ENV` bake, and the self-contained
> field-deploy bundle land through the
> [#497](https://github.com/ycpss91255-docker/base/issues/497) epic; this
> section documents the routing model they implement.
