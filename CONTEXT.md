# base — Context

`base` is the shared container template that downstream repos under the
`ycpss91255-docker` org vendor as a `.base/` subtree: it owns the
wrappers, the `setup.conf` -> `.env`/`compose.yaml` resolution, and the
self-test gate. This glossary fixes the domain vocabulary so future work
and architecture reviews stop re-coining terms. It is a glossary only —
decisions live in [`doc/adr/`](doc/adr/), rationale in the issues.

## Language

### Domain

**base**:
The shared template repo (this repo); the single source downstream repos
vendor.
_Avoid_: template repo, upstream (when ambiguous).

**Downstream repo**:
A repo under the org that vendors **base** as a `.base/` subtree and
ships its own `Dockerfile` + `setup.conf`.
_Avoid_: consumer (acceptable as a synonym), client repo.

**`.base` subtree contract**:
The frozen set of paths inside `.base/` that a downstream repo and
`upgrade.sh` rely on; restructuring base must preserve it (ADR-00000006).
_Avoid_: subtree layout, base API.

**Wrapper**:
A user-facing entry script (`build` / `run` / `exec` / `stop` / `prune` /
`setup` / `setup_tui`) under `script/docker/wrapper/`, invoked through the
`just` recipes (ADR-00000005).
_Avoid_: command script, entrypoint (reserved for the container ENTRYPOINT).

**Stage**:
A Dockerfile build target (`FROM ... AS <stage>`); the unit the compose
and deploy renderers emit for.
_Avoid_: target (acceptable in Docker context), layer, image variant.

**Baseline stage**:
A reserved stage (`devel` / `devel-test`) that is not emitted as a
user service, as opposed to an **emittable stage**.
_Avoid_: base stage, default stage.

### Schema and configuration

**setup.conf**:
The per-repo declarative container config (INI-style sections) that
`setup.sh` resolves into `.env` + `compose.yaml`.
_Avoid_: config file, settings.

**setup.conf schema**:
The set of valid sections/keys and their validation rules, single-sourced
in `lib/schema.sh` (#559).
_Avoid_: config spec, model.

**Schema registry**:
`lib/schema.sh` — `SCHEMA_VALIDATOR` (canonical `<section>.<key>` ->
validator), `SCHEMA_SECTIONS` (ordered section list), `SCHEMA_EMPTY`
(empty-value policy), all routed through `_schema_validate` so setup.sh
and the TUI cannot drift (#559 / #560 / #561).
_Avoid_: validator map, schema table.

**Per-stage override**:
A `[stage:<name>]` section in setup.conf that refines the global config
for one **stage**; lists append by default, `<list>_inherit = false`
replaces (#220).
_Avoid_: stage config, per-stage section.

**Env vs workload parameter boundary**:
The split between set-once `[environment]` defaults (baked into the image
as `ENV`) and volatile per-task variables in the gitignored `.env`
workload overlay (ADR-00000003).
_Avoid_: env split, config layering.

**Field deploy**:
The self-contained `deploy.sh` launcher + `tar.xz` image bundle produced
by `setup.sh deploy` to run a baked **stage** off the dev host; it carries
docker-level run flags but not the dev binds (ADR-00000003, #506).
_Avoid_: export, ship, release bundle.

**Managed `.gitignore` block**:
The base-owned region of a downstream `.gitignore` that `lib/gitignore.sh`
(re)syncs to ignore derived artifacts (`.env`, `compose.yaml`).
_Avoid_: ignore block, generated gitignore.

### Architecture seams

Concepts named by the 2026-06-11 architecture review
(`/improve-codebase-architecture`). Each is a **seam** — a place behaviour
can be altered without editing in place.

**Resolved-config seam**:
`_resolve_deploy_context` + `_resolve_docker_flags` — resolve setup.conf
once into a record that both the compose and deploy renderers consume, so
the two cannot diverge (#563, #505/#506).
_Avoid_: resolver (too generic on its own).

**Conf accessor handle**:
The opaque handle returned by `_conf_load`; callers query setup.conf via
accessor verbs (`_conf_get` / `_conf_list` / `_conf_sections`) without
touching the internal parallel-array representation (#564).
_Avoid_: conf object, parsed config.

**Wrapper runtime**:
The shared `lib/wrapper.sh` that absorbs the wrappers' duplicated preamble
(language resolution, argument parsing) into one seam (#565, planned).
_Avoid_: wrapper base, common lib.

**Per-service compose emitter**:
`_emit_stage_service` — emits one stage's `compose.yaml` service fragment
from a resolved-stage value, isolating per-service YAML shape from the
generator (#566).
_Avoid_: compose generator (that is the whole `generate_compose_yaml`).

**Dockerfile-migration list**:
The declarative ordered `{detect, transform}` migration table in
`lib/dockerfile_migrate.sh` that `upgrade.sh` iterates to heal downstream
Dockerfiles, replacing the ad-hoc Step-5 seds (#567, planned).
_Avoid_: upgrade seds, Dockerfile patcher.

## Relationships

- A **downstream repo** vendors **base** via the **`.base` subtree
  contract**.
- `setup.sh` resolves **setup.conf** (validated by the **schema
  registry**) through the **resolved-config seam** into `.env` +
  `compose.yaml`.
- A **per-stage override** refines the global config for one **stage**;
  the **per-service compose emitter** renders each emittable **stage**.
- **Field deploy** bakes one **stage** into a self-contained bundle,
  honouring the **env vs workload parameter boundary** (docker-level flags
  travel; dev binds do not).
- `upgrade.sh` pulls the **`.base` subtree** and heals downstream
  Dockerfiles via the **Dockerfile-migration list**.

## Example dialogue

> **Dev:** "I added a `[stage:probe]` section — does that change the
> `devel` image?"
> **Maintainer:** "No. A **per-stage override** only refines the **stage**
> it names; `devel` is a **baseline stage** and keeps the global config.
> The **per-service compose emitter** renders `probe` as its own service."
>
> **Dev:** "And if I `setup.sh deploy --stage probe`?"
> **Maintainer:** "That produces a **field deploy** bundle for `probe`.
> Its `[environment]` defaults are baked as image `ENV`, but your `.env`
> workload overlay and the `~/work` bind stay behind — that is the **env
> vs workload parameter boundary**."

## Flagged ambiguities

- "config" was used for both **setup.conf** (the declarative input) and the
  generated `.env`/`compose.yaml` (the resolved output) — resolved: reserve
  "setup.conf" for the input and "generated config / derived artifacts" for
  the output.
- "entrypoint" was used for both the **wrapper** scripts and the container
  `ENTRYPOINT` — resolved: "wrapper" for the former, "ENTRYPOINT" for the
  latter.
