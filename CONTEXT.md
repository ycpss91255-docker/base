# base — Context

`base` is the shared container template that downstream repos under the
`ycpss91255-docker` org vendor as a `.base/` subtree: it owns the
wrappers, the `setup.conf` -> `.env`/`compose.yaml` resolution, and the
self-test gate. This glossary fixes the domain vocabulary so future work
and architecture reviews stop re-coining terms. It is a glossary only —
product intent and invariants live in [`doc/PRD.md`](doc/PRD.md), the
decisions serving them live in [`doc/adr/`](doc/adr/), rationale in the
issues.

## Language

### Domain

**base**:
The container-template SOURCE repo (this repo, `ycpss91255-docker/base`;
formerly named "template", renamed to base); the single source downstream
repos vendor.
_Avoid_: template repo (that is a different, distinct repo — see **template
repo**), upstream (when ambiguous).

**Downstream repo**:
A repo under the org that vendors **base** as a `.base/` subtree and
ships its own `Dockerfile` + `setup.conf`. The canonical term for the REPO;
bare "downstream" now always means the repo, never a directory.
_Avoid_: consumer (acceptable as a synonym), client repo.

**`dist/`**:
base's shipped tree (renamed from `downstream/` in #714 — `dist` =
*distribution*), vendored into each downstream repo as `.base/dist/`; the
single home of the consumer-facing tooling / config / Dockerfile. Always
written with the slash. It was the source of the "downstream" overload that
#714 retired.
_Avoid_: downstream/ (the old name), shipped/, shared/.

**`.base` subtree contract**:
The frozen set of paths inside `.base/` (now `.base/dist/...`) that a
downstream repo and `upgrade.sh` rely on; restructuring base must preserve
it (ADR-00000006, amended by #714).
_Avoid_: subtree layout, base API.

**origin**:
The symlink single-source-of-truth: the real files under `dist/script/<ns>/`
that base-own `script/<ns>/` and a downstream's `script/<ns>/` both symlink
into, so base uses the very tooling it ships (ADR-00000011 sec.4).
_Avoid_: source, canonical copy.

**base-own tooling**:
base's self-only tooling that is NOT shipped to downstream repos:
`script/test`, `script/release` (real directories, no `dist/` origin).
_Avoid_: internal scripts, CI tooling.

**Wrapper**:
A user-facing entry script (`build` / `run` / `exec` / `stop` / `prune` /
`setup` / `setup_tui`) under `dist/script/docker/wrapper/`, invoked through the
`just` recipes (ADR-00000005).
_Avoid_: command script, entrypoint (reserved for the container ENTRYPOINT).

**tooling image (test-tools)**:
base's CI toolchain image (`dockerfile/Dockerfile.test-tools`), bundling
bats / shellcheck / hadolint / kcov; not a deployable artifact.
_Avoid_: ci image, builder image.

**consumer image (devel / runtime)**:
What a downstream repo builds via `just docker build` from
`dist/dockerfile/Dockerfile` — the repo's own product image, built at a
given **stage**. `devel` is the dev-host workstation stage and is never a
deploy target; the field-deployable artifact is built from a **deployable
stage** (`runtime` is the template's example name), never `devel`, a
`*-test` stage, or a build intermediate (PRD invariant 8,
ADR-00000023 sec. 4).
_Avoid_: app image (acceptable informally), product image.

**template repo**:
`ycpss91255-docker/template`, the GitHub Template repo — a pre-scaffolded
downstream skeleton with `.base/` already vendored, used to bootstrap new
downstream repos. Distinct from **base** and from **`just template`**.
_Avoid_: starter, skeleton repo (informal only).

**`just template`**:
The namespace that scaffolds a repo-local command group under
`script/local/<name>/` (an extension point; a subtree upgrade never
overwrites it). Always written `just template`. Distinct from the
**template repo**.
_Avoid_: template namespace (use the full `just template`).

**base's "Dockerfile / config"**:
Say this literally — e.g. `dist/dockerfile/Dockerfile`, `dist/config/`. Do
NOT call base's Dockerfile or config "template" / "the template Dockerfile".
_Avoid_: template Dockerfile, template config.

**`@<path>`**:
The user's chat shorthand for a filesystem path (e.g. `@dist/script/justfile`).
A notation convention, not a code construct.
_Avoid_: at-path, reference.

**Stage**:
A Dockerfile build target (`FROM ... AS <stage>`); the unit the compose
and deploy renderers emit for.
_Avoid_: target (acceptable in Docker context), layer, image variant.

**Baseline stage**:
A template-managed stage name `{sys, devel-base, devel, runtime-test}`
(legacy aliases `{base, test}` during the v0.21.x transition) that a
downstream Dockerfile may not re-declare, as opposed to an **emittable
stage**. The set is `_validate_stage_name`'s `return 2` arms
(`lib/stage.sh`) and nothing else; the `derived-figures` lint pins every
document that repeats it. `devel-test` is deliberately NOT baseline: it
is emitted as the `test` service, which is what gives
`[stage:devel-test]` a runtime control surface.
_Avoid_: base stage, default stage.

**Deployable stage**:
A stage eligible to be built into a **deploy bundle**, and the only kind
of stage the compose emitter gives a `restart:` policy to. Defined by
`_is_deployable_stage` (`lib/stage.sh`), shared by exactly those two
callers so the rule has one definition: everything is deployable EXCEPT
`devel` (it is the interactive shell), any `*-test` stage (it exists to
run, assert and exit), `sys` / `devel-base` (build intermediates with no
runnable service), and the legacy aliases `base` / `test`.
_Avoid_: field stage (acceptable informally), production stage,
runtime stage (that is one example name, not the category).

**Baked artifact**:
Something an image builds into itself (a colcon workspace, an SDK, a
compiled tool), as opposed to something bind-mounted at run time. It lives
at an absolute `/opt/<name>` path, never under `$HOME`, because `$HOME`
resolves to the BUILD-time `USER_NAME` (ADR-00000024). A
`~/<name> -> /opt/<name>` symlink is a **discoverability symlink**: for
humans, never sourced.
_Avoid_: home workspace, `~/x_ws` (as the canonical path).

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
Producing and running a **deploy bundle** — the act; `setup.sh deploy`
generates, `deploy.sh up` runs it on the field host.
_Avoid_: export, ship, release.

**Deploy bundle**:
The artifact `setup.sh deploy` produces for one **deployable stage**: the
folder `deploy/<repo>-<stage>-<version>/` holding `image.tar.xz`, a
fully-resolved self-contained `compose.yaml` (literal values, no
`setup.conf` / `.env.generated` dependency), a `config/` folder of
operator-editable copies, a thin `deploy.sh` up/down/logs launcher and a
field-operator `README`. It is driven by `docker compose`, not by raw
`docker run` flags — ADR-00000023 sec. 3 amends ADR-00000003's "compose
does not travel" for exactly this artifact: a *resolved* compose does
travel. The dev binds do not.
_Avoid_: release bundle, tarball, image bundle (it is more than the
image), `deploy.sh` bundle.

**`deploy.manifest`**:
A committed `config/<component>/deploy.manifest` (INI-lite, one section
per **deployable stage**) naming the absolute container paths a field
operator may retune without a rebuild. base ships an editable copy of each
under the bundle's `config/` and binds it over the image's baked default
(**mount-wins**); the repo's entrypoint keeps the semantics. Binds are
read-only unless the path declares `rw`. base moves the files the manifest
lists and never parses their contents (ADR-00000023 sec. 5, #870).
_Avoid_: tunable list, override manifest, config manifest.

**Managed `.gitignore` block**:
The base-owned region of a downstream `.gitignore` that `lib/gitignore.sh`
(re)syncs to ignore derived artifacts (`.env`, `compose.yaml`).
_Avoid_: ignore block, generated gitignore.

### Logging and observability

**Single-sink dispatch**:
`log.sh`'s one-rendering-per-record model (#438): each log line is
rendered once in a single format chosen from the run's startup TTY-ness
(text when interactive, JSON when piped), routed to stdout (DEBUG / INFO)
or stderr (WARN / ERROR / FATAL); `LOG_FORMAT=text|json` forces the
format. The wrapper transcript tee layers over this without a second
render (ADR-00000007).
_Avoid_: dual-render, per-sink format, tee logger.

**Run trace id**:
The W3C-Trace-Context `trace_id` propagated via `TRACEPARENT` and surfaced
in JSON log records; `_log_with_trace` mints one per run and
`_log_with_span` inherits it. The wrapper transcript reuses it as the
filename correlation id (`log/<verb>/<ts>-<traceid8>.log`).
_Avoid_: request id, correlation id, span id (the span id is the
per-operation child).

**Interactive vs non-interactive verb**:
A container-ops verb classification for transcript capture (#606 / #608).
*Non-interactive* verbs (build / setup / stop / prune / upgrade) run to
completion without handing the terminal over, so the transcript captures
them end-to-end. *Interactive* verbs (run attached / exec / setup-tui)
hand the terminal to an interactive docker/TUI process; the transcript
captures only the orchestration phase and then `_transcript_detach`s
before the session. `run -d` is non-interactive (full capture).
_Avoid_: foreground/background (orthogonal), TTY verb.

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
`lib/dockerfile_migrate.sh` that `upgrade.sh` Step 5 iterates (via the
`apply_migrations` dispatcher) to heal downstream Dockerfiles + entrypoints,
replacing the ad-hoc Step-5 seds (#567, folds #579 facet B).
_Avoid_: upgrade seds, Dockerfile patcher.

## Relationships

- A **downstream repo** vendors **base** via the **`.base` subtree
  contract**.
- `setup.sh` resolves **setup.conf** (validated by the **schema
  registry**) through the **resolved-config seam** into `.env` +
  `compose.yaml`.
- A **per-stage override** refines the global config for one **stage**;
  the **per-service compose emitter** renders each emittable **stage**.
- **Field deploy** bakes one **deployable stage** into a **deploy
  bundle**, honouring the **env vs workload parameter boundary** (a
  fully-resolved `compose.yaml` travels; dev binds do not), and ships an
  editable copy of every path a **`deploy.manifest`** declares.
- `upgrade.sh` pulls the **`.base` subtree** and heals downstream
  Dockerfiles via the **Dockerfile-migration list**.
- The **base version monitor** (`check-base-version.sh`, shipped in the
  subtree; the `base-version-monitor.yaml` workflow `init.sh` generates)
  is the *pull* counterpart to `upgrade.sh`'s *push*: each repo polls
  `base`'s latest stable release and opens an **upgrade-reminder issue**
  in itself when behind — no PAT, no central repo list.

## Example dialogue

> **Dev:** "I added a `[stage:probe]` section — does that change the
> `devel` image?"
> **Maintainer:** "No. A **per-stage override** only refines the **stage**
> it names; `devel` is a **baseline stage** and keeps the global config.
> The **per-service compose emitter** renders `probe` as its own service."
>
> **Dev:** "And if I `setup.sh deploy --stage probe`?"
> **Maintainer:** "That produces a **deploy bundle** for `probe`, if
> `probe` is a **deployable stage**.
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
