# Environment vs runtime parameter boundary and field delivery model

> Serves: PRD invariant 3 (multi_run-expandable) via the axis-A
> `.env`-overlay model; also the one-source -> many-render goal (field
> delivery).

- **Date:** 2026-06-02
- **Status:** Accepted
- **Amended:** 2026-07-15 -- the structured-config **Field** cell of the
  parameter-routing table gains a field override channel (baked default +
  optional mount-wins `-v`), making it symmetric with the env row's `-e`; and
  the "compose does not travel" delivery model is refined to "a fully-resolved,
  self-contained compose travels". The general git-tracked provisioning axis
  this makes explicit, and the mechanism, are recorded in ADR-00000023.
- **Amended:** 2026-08-26 (#868) -- **A2's file-role assignment is REVERSED.**
  `.env` is now the tool's generated, container-bound defaults and
  `.env.local` is the user's override layer. See "Amendment: the env-file
  naming rule (2026-08-26)" below; the routing table and the A2 bullet list
  are annotated in place.

## Context

ADR-00000001 established "setup.conf is the main path; compose-native
mechanisms are an escape hatch", and listed "pure runtime value injection
(`--env-file <overlay>.env`)" as one escape-hatch case -- but it never drew
the line between what counts as a stable *environment* parameter and what
counts as a volatile *runtime* parameter.

That gap surfaced concretely: downstream repos keep wanting to push volatile
runtime params (env vars) into `setup.conf`, while `setup.conf` is meant to
hold "set-once, machine-bound" environment params. The intuitive criterion
"rarely adjusted" is subjective -- each maintainer draws it differently, so
the boundary does not hold over time.

Two further problems compounded this:

- Workload env vars are baked into `compose.yaml`'s `[environment]` block.
  Any tweak flips `SETUP_CONF_HASH`, forcing a regenerate (drift); committing
  them churns git history; section-replace forces copying a whole section to
  change one key.
- The field-deployment scenario keeps **only the docker image** -- the
  host-side `setup.conf` / `.env` / `compose.yaml` / wrappers do not travel
  with it. Workload env living in `compose.yaml` vanishes in the field, and
  container flags (`--privileged` / `--device` / `--network` / `--gpus`)
  cannot be baked into any image.

This is not a one-off. The same "per-invocation / one-off / standalone
override that does not belong baked into `setup.conf`" need has recurred and
was each time patched with a different escape hatch:

- #279 -- one-off `--build-arg` overrides, solved with a CLI flag pass-through.
- #338 -- per-invocation `[gui]` / x11-cookie overrides, solved with CLI flags;
  its body notes that editing `setup.conf` then reverting for a single run "is
  awkward".
- #465 -- isaac multi-instance ports / cache isolation, solved with a
  compose-override overlay (see ADR-00000001).
- #462 -- a `runtime.env` mirror so standalone scripts can read `[environment]`.

#497 consolidates that sprawl into one coherent workload-overlay layer. The
relationship to #75 is parallel, not contradictory: #75 consolidated scattered
*static config* (5 conf files) into one `setup.conf`; this decision
consolidates scattered *runtime overrides* into one `.env` overlay. #75's
"`.env` is a derived artifact" property concerned static-config generation; a
runtime overlay is a category #75 never addressed.

The implementation work is tracked in issue #497; this ADR records only the
rationale.

## Decision

**Boundary criterion.** Primary axis A -- *binding target*: "does this value
change when you switch machines?" Yes / machine-capability (GPU, arch, APT
mirror, display, privileged) -> environment, stays in `setup.conf`. Changes
per task (which dataset, which env var) -> workload. Axis C (does it need a
rebuild?) is the tie-breaker for grey cases.

**Three delivery channels** -- only channel 1 reaches the field:

1. Baked into the image (`ENV` / build-arg / COPY'd config + entrypoint).
2. Dev-host run config (`compose.yaml` + env files + wrappers) -- does not
   travel.
3. Field launcher (`docker run` flags) -- supplies what an image cannot carry.

**File roles ("A2").** `setup.conf` (committed source, environment) +
`setup.sh` detection render multiple targets:

- `.env.generated` -- derived interpolation cache (today's `.env`, renamed;
  audited to be a 100% pure cache with no hand-authored content, so
  regeneration is loss-free). Fed to compose via `--env-file` for
  `${VAR}` interpolation only; it is NOT injected into containers, so the
  cache's USER_UID / PRIVILEGED / SETUP_* metadata never leak into the
  runtime env.
- `.env` -- repurposed as the gitignored **user workload overlay**; never
  touched by `setup.sh` (scaffolded once on first apply). Injected into
  each container via the service `env_file: - .env` directive. (Two-role
  split, refined in #502: the interpolation cache and the container
  overlay are distinct files with distinct delivery paths, not a single
  `env_file: [.env.generated, .env]` list. compose precedence is
  `environment:` > `env_file`, so the overlay overriding `[environment]`
  defaults completes in S3, when `[environment]` becomes the
  lowest-precedence baked `ENV`.)
  **REVERSED 2026-08-26 (#868):** `.env` is the tool's generated
  container-env defaults and `.env.local` is the user's overlay. The
  `env_file:` list is `[.env, .env.local]`, later wins. See the amendment
  section at the end of this ADR.
- `compose.yaml` -- dev-host run config.
- `deploy.sh` (new) -- self-contained field launcher: a `docker run` with
  flags inlined, generated by its own generator, with a per-parameter
  confirmation step before generation; the target image tag is a
  repo-selectable stage.
- Runtime stage bakes `[environment]` defaults as `ENV` so the field image
  carries sane defaults on its own.

**Detection stays in `setup.sh`** (code), not expressed as `$()` inside
`setup.conf`.

**Bare `docker compose up` support is dropped** -- everything runs through
`make` / wrappers. This is precisely what frees the `.env` name to be
repurposed.

## Parameter routing (usage)

Where a given parameter lives follows axis A ("does it change when you
switch machines?"). Three channels, distinguished by *kind* of value:

| Parameter kind | Where it lives | Dev host | Field |
|---|---|---|---|
| machine-bound / set-once (GPU, `privileged`, mounts, `IMAGE_NAME`, APT mirror) | `setup.conf` (committed) | rendered into `compose.yaml` | inlined as `docker run` flags in the generated `deploy.sh` |
| volatile workload **env vars** (`ROS_DOMAIN_ID`, `LOG_LEVEL`, tokens) | `.env.local` (hand-authored, gitignored) -- was `.env`, reversed in #868 | injected per service via `env_file: [.env, .env.local]`; the generated `.env` carries the `[environment]` defaults and `.env.local` overrides them | shipped in the bundle as `.env` (defaults, incl. `WATCHDOG_*`) + `.env.local` (operator overrides), on top of the baked `ENV` |
| structured app **config** (bridge topics, pipeline lists) | an app config file/dir (e.g. `config/<repo>/*.yaml`) | bind-mounted into the container (edit + restart, no rebuild) | `COPY`-baked default + optional field `-v` override (mount-wins) |

The third channel is distinct from the `.env` overlay: the overlay
carries flat `KEY=VALUE` env vars only; structured config goes to its own
file and follows the immutable-image bake model of ADR-00000001 (dev
bind-mount for fast iteration, deploy-time bake for a self-contained
field image). Concrete use-case examples (which env var goes where for a
given repo) live in the README, not here -- this records the routing
*decision*, not a tutorial.

## Alternatives

- **A1 -- keep `.env` derived, add a new `env.local` overlay.** Zero
  migration, preserves the "derived = never edit" invariant, and degrades
  gracefully under a bare `docker compose up`. Rejected only because the user
  always uses wrappers and prefers the conventional `.env` as the edit target;
  the convention win drove the choice toward A2.
- **A3 -- single `.env`, both derived and hand-edited, `setup.sh` preserves
  user keys.** Breaks the "derived = never edit" invariant, risks clobbering
  user data on a parser bug, and muddies the drift-hash boundary. Rejected.
- **Detection-as-commands in `setup.conf` (`USER_UID = $(id -u)`).** Turns a
  committed, shared config into arbitrary code execution; does not remove the
  materialized cache (docker needs literal values); discards tested, i18n'd
  detection logic. Rejected.
- **No-file live-inject** (wrapper computes detection each run, no cache
  file). Loses the inspectable cache and the home for `SETUP_*` drift
  metadata, and recomputes every run. Rejected; keep `.env.generated`.
- **`compose.override.yaml` as the workload channel.** Native and powerful,
  but forces hand-written compose syntax -- contradicting the `setup.conf`
  abstraction. Per ADR-00000001 it stays an escape hatch, not the default
  path for workload env.

## Consequences

- Editing `.env` (workload) needs only `make run`: no compose regenerate, no
  `SETUP_CONF_HASH` flip, no git churn, no section-copy.
- 17-repo migration: `.env` -> `.env.generated`, add the new `.env` overlay,
  update gitignore (fanout in the spirit of #201).
- `setup.sh` gains a single flag-resolution layer feeding two thin renderers
  (`compose.yaml` and `deploy.sh`); two output formats to maintain.
- The field image is self-contained for workload env defaults (baked `ENV`);
  container flags are supplied by the generated `deploy.sh` in the field.
- Bare `docker compose up` no longer works (empty interpolation). Accepted
  because the workflow is wrapper-only.
- Refines ADR-00000001: its "pure runtime value injection (`--env-file`
  overlay)" escape-hatch case becomes the blessed primary path for workload
  env, via the `.env` overlay + `env_file:`.
- Consolidates the runtime-override escape hatches (#279 / #338 / #465 /
  #462): future such needs route through the `.env` overlay or the unified
  flag-resolution layer rather than spawning a new per-case mechanism.
  Parallel to #75's static-config consolidation, not a reversal of it.
- **Amended (2026-07-15, ADR-00000023):** the structured-config Field cell is
  no longer bake-only. It is now a `COPY`-baked *default* plus an optional
  field `-v` override (mount-wins) -- the file analog of this ADR's env-row
  `deploy.sh -e`, so both rows are symmetric. The general axis this makes
  explicit is **git-tracking**: a committed config file is the developer's
  baked default; a gitignored / bundle-shipped file is the operator-editable
  overlay that mounts over it in the field without a rebuild. The
  "compose does not travel" delivery constraint (channel 2 above) is likewise
  refined -- a *fully-resolved, self-contained* compose does travel, with no
  `setup.conf` / `.env.generated` dependency. Both the provisioning axis and
  the field-deploy mechanism are recorded in ADR-00000023.
- Open questions deferred to #497: `deploy.sh` confirm-step UX (extend
  `setup_tui.sh` vs new flow), final naming (`deploy.sh` vs `field-run.sh`),
  the fate of `runtime.env` (#462), and interaction with #439 (legacy
  `.env.example` / IMAGE_NAME fallback). The last of those is settled in
  the 2026-08-26 amendment below: `.env.example` has no role and no code
  left reading it.

## Amendment: the env-file naming rule (2026-08-26, #868)

**A2's choice of which file the user edits is reversed.** One rule now
governs every generated name in the repo: **the standard name is ours; a
suffix marks a local variant.**

| file | whose | enters the container | fate |
|---|---|---|---|
| `.env` | ours -- shipped / generated defaults | yes | regenerated on every apply |
| `.env.local` | the user's / operator's overrides | yes | never touched by tooling |
| `.env.generated` | ours -- host-detection interpolation cache | no | unchanged by this amendment |

### Why the reversal

A2 picked `.env` as the user's edit target because that is the
conventional meaning of the name in the dotenv / Laravel tradition. That
reasoning is still true in isolation, and the ecosystem is genuinely split
-- Next.js treats `.env` as shared committed defaults with `.env.local` as
the user's override, which is the other half of the same convention. With
no external authority to defer to, the choice is internal, and internal
consistency decided it: `Dockerfile`, `compose.yaml` and `.setup.conf` are
already ours-and-regenerated under their standard names, and
`.setup.conf.local` is already the operator's local variant under a
suffix. One rule that covers all of them beats a rule for the env family
and a different rule for everything else.

`.env.generated` deliberately keeps its suffix: it exists only to fill
`${VAR}` slots in `compose.yaml` via `--env-file` and never reaches a
container. Renaming it to `.env` would make one name mean two things that
do not arrive at the same place -- the exact confusion the rule removes.
Its suffix marks a category, not ownership, and it also carries the "do
not hand-edit" signal.

### What the reversal forced, beyond the names

A2 acknowledged that compose ranks `environment:` above `env_file` and
deferred the fix to S3. Leaving it deferred is what makes the rename
dangerous rather than cosmetic: an override channel that exists, is
documented, and is silently outranked is worse than no channel at all,
because nothing reports the loss. So the `[environment]` list and the
`[lifecycle] WATCHDOG_*` block moved OUT of every service `environment:`
list and into the generated `.env`, on the dev host and in the field
bundle alike. `environment:` now carries only what cannot move: the X11
passthrough, which interpolates from the running host's own shell.

One shape is exempt, and deliberately: a `[stage:*]` with
`environment.env_inherit = false` asked to DROP the top-level list, so
handing it the shared `.env` would put it straight back. That stage takes
`.env.local` alone and restates its own env plus the lifecycle block
inline. It is the one place a compose `environment:` entry still outranks
the override file, and it is reached only by a conf that opted out.

Moving the list also moved its `${VAR}` expansion. compose used to resolve
those references itself against `.env.generated`; an `env_file` value is
taken literally, so `apply` expands against the cache before writing and
leaves genuinely unknown names visible rather than silently empty. Values
are written single-quoted for the same class of reason -- an unquoted
env_file value is truncated at an inline ` #` and a double-quoted one has
`${...}` expanded, both silently.

### The sub-questions the epic left open

- **Is `.env` committed or gitignored?** Gitignored, and it already was.
  It is generated from `.setup.conf` and host detection, so committing it
  would put a machine-specific render in everyone's tree and churn git on
  every apply. `.env.local` joins it in the canonical gitignore list, for
  the reason `.setup.conf.local` is there: an untracked layer that got
  committed silently becomes everyone's config.
- **Does `.env.example` still have a role?** No, and there is nothing left
  to remove -- the check the epic asked for came back empty. `init.sh`
  stopped generating it, and the `IMAGE_NAME` fallback #439 touched no
  longer reads it: detection resolves the name through `[image] rules`
  with `@default:unknown` as the last resort (`detect_image_name`), and
  two specs already assert the file is NOT created. The generated `.env`
  is the example now: it lists every container-bound value in effect, with
  its resolved value, which is strictly more than a sample file could
  carry. base's only remaining mention is the harness `CLAUDE.md`, which
  is a symlink to a file base cannot change.
- **Suffix wording.** `.env.local`, over `.env.site` / `.env.override`.
  It matches the Next.js precedent this rule is otherwise aligned with,
  and -- more decisive here -- it matches `.setup.conf.local`, which
  already means exactly this in this repo. A second word for one concept
  is a second thing to learn.

### Migration

Every downstream repo has a hand-written, gitignored, unrecoverable `.env`
under the old rule. `_migrate_env_to_local` renames it to `.env.local`
before anything can regenerate, gated on the file's own content (an
auto-gen marker, or no assignment line at all, means there is nothing of
the user's to move) so it fires once and is inert after.

It is called from `init.sh`, not from `upgrade.sh`, and that is the
load-bearing detail: an upgrade is driven by the consumer's OWN vendored
`upgrade.sh`, which shipped in an older release and cannot be changed
retroactively, so a migration added to `upgrade.sh` would first run one
release too late -- after the rename had already taken effect. Every
release's `upgrade.sh` re-runs the freshly pulled `init.sh` as its resync
step, which makes that the earliest point in the upgrade running current
code, and nothing between there and the user's next `just setup` writes
`.env`.
