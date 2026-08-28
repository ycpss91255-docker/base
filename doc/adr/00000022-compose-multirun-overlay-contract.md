# base<->multi_run compose contract: per-instance isolation is an overlay, enforced by a guard

> Serves: PRD invariant 3 (multi_run-expandable by construction) --
> established by the overlay contract + guard; also invariant 2 (a loud
> self-check).

- **Date:** 2026-07-08
- **Status:** Accepted
- **Relates to:** issue #716 (this decision), issue #25 (multi_run),
  ADR-00000001 (setup.conf is the main path, compose-native mechanisms are
  the escape hatch), ADR-00000003 (environment vs workload parameter
  boundary; the `.env` overlay + `env_file:` channel), ADR-00000019
  (network host default / bridge opt-in, the `ports` / `hostname` fields),
  ADR-00000020 (base owns the single-service lifecycle). Enforced by
  `test/bats/unit/compose_emit/overlay_guard_spec.bats`.

## Context

`multi_run` (issue #25) runs the same base-generated stack in three
scenarios: (1) one repo / many instances, (2) many repos / one instance,
(3) many repos / many instances. `docker compose` has **no native
instance axis** -- it models project, service, and `replicas`, but not
"the same service run N times with per-instance parameters". So any field
that must vary per instance, if base emits it into the generated
`compose.yaml` as a **hardcoded literal**, becomes a wall: two co-located
instances collide on host ports / writable paths / DDS domain, and
`multi_run` cannot isolate them without a retroactive change to base's
emitter.

The core mechanism -- "per-instance isolation = a `.env` overlay" -- was
already decided in the v0.42 docker-namespace epic. What was missing was
(a) an explicit resolution of the fields ADR-00000003 left in the axis-A
grey zone (`ports` / `network_mode`: machine-bound *environment* or
per-task *workload*?), and (b) any guarantee that a future emitter change
would not silently bake a fresh per-instance literal and re-erect the
wall. Discipline is not a guarantee; the v0.41 Dockerfile drift and the
#800 worker-contract gaps are the same failure class -- a latent blocker
that stays green until someone downstream hits it.

## Decision

### 1. Per-instance isolation is a `.env` overlay, never a compose regenerate

An instance is isolated by supplying **overlay values**, not by
regenerating `compose.yaml`. `compose.yaml` stays a single committed-shape
artifact; the per-instance delta lives entirely in overlay inputs
`multi_run` controls. This preserves ADR-00000003's two-role split:
`.env.generated` feeds compose `${VAR}` interpolation via `--env-file`,
and `.env` feeds the container via `env_file:`.

### 2. Environment-default / per-instance-overridable (the axis-A resolution)

Every field that can vary per instance is emitted as an
**overlay-overridable interpolation** (`${VAR:-<default>}` or `${VAR}`),
never a hardcoded literal. The default may stay machine-bound (resolved
from `setup.conf` as before), but an overlay-override path **always
exists**. A field is thus simultaneously an environment default (single
run: the overlay var is unset, compose substitutes the default, behaviour
is byte-equivalent) and per-instance-overridable (multi_run: the overlay
sets the var). This is the explicit resolution of the ADR-00000003 axis-A
grey zone for `ports` / `network_mode` and the rest: they are *both*, and
the interpolation form is what lets one emission serve both roles.

### 3. Override channel by field kind

The audit is a **starting point, not an exhaustive allowlist** -- ANY
field that can collide across instances must have an override path. The
channel differs by kind:

| Field kind | Per-instance override channel | Emitted form |
|---|---|---|
| project `name:` | compose interpolation from `--env-file` | `${PROJECT_NAME}` (was `${DOCKER_HUB_USER}-${IMAGE_NAME}`; see the 2026-08-05 amendment below) |
| `container_name:` | interpolated **and** removable (non-load-bearing, see §4) | `${USER_NAME}-<repo>[-<svc>]` -- **no longer emitted at all; see the 2026-08-26 amendment below** |
| `network_mode:` | compose interpolation | `${NETWORK_MODE}` |
| `privileged` / `ipc` / `pid` | compose interpolation | `${PRIVILEGED}` / `${IPC_MODE}` / `${PID_MODE}` |
| **`ports:`** | compose interpolation, **per published port** | `${PORT_<n>:-<default>}` (n = **1-based** index within the service's port list -- `PORT_1` = first port, matching base's 1-based indexed-key convention `port_1` / `mount_1` / `arg_1`) |
| workload env (`ROS_DOMAIN_ID`, tokens) | `.env` overlay via `env_file:` + baked ENV default (ADR-00000003 S3) | `- "KEY=value"` default; overlay wins in the field image |
| writable volume topology | compose-merge overlay (a mount is a topology decision, not a flat scalar) | bind/named mount string |
| `runtime` / `hostname` / GPU | **not per-instance** -- host-bound, correctly *shared* across co-located instances (all instances on a host share the runtime, the X11-cookie hostname, and the GPU) | literal / host-resolved |

**Amendment (2026-08-05, ADR-00000025): the project `name:` row's emitted
form, and the stage this ADR does NOT cover.** The row above is unchanged in
substance -- project `name:` is still an interpolation from `--env-file`, and
multi_run still overrides it by setting that variable in its runtime overlay.
What changed is *which* variable: the emitter used to re-assemble
`${DOCKER_HUB_USER}-${IMAGE_NAME}` while the wrapper computed the same string
in bash, two answerers to one question, and both now read the single
`PROJECT_NAME` that `setup apply` resolves into `.env.generated`. The
interpolation form -- the thing this ADR's forward invariant and its guard
actually pin -- is preserved deliberately: emitting the resolved literal would
have been simpler and would have re-erected the wall.

ADR-00000025 also adds a per-worktree `.setup.conf.local` config layer, and it
is worth being explicit that it is **not** this contract's mechanism, because
the resemblance invites the mistake. That layer acts BEFORE `compose.yaml` is
generated and yields one `compose.yaml` per worktree; per-instance isolation
here acts at interpolation time on ONE already-generated `compose.yaml`, which
is precisely why sec. 1 rejects a per-instance regenerate. A developer's
second worktree and multi_run's Nth instance are different stages of the
pipeline, and neither mechanism can do the other's job. ADR-00000025 sec. 5
carries the full division of labour.

**Amendment (2026-08-26, issue #920): base stopped emitting
`container_name:` itself.** §4 below records that the field is removable and
that `multi_run` *may* drop it; the emitter has now dropped it, so there is
no `container_name:` line in a generated `compose.yaml` for an overlay to
override or remove. The reason the weaker form was not enough: the guard
asked only that the value carry an interpolation, and `${USER_NAME}-<repo>`
satisfied that -- yet a container name is namespaced by the DAEMON, not by
the project, and `${USER_NAME}` is one string for all of a user's instances.
Two co-located stacks under distinct project names therefore still collided
at `up` (`name ... is already in use`), and compose refuses `--scale` while
any container_name is present. No value of the field can be per-instance
safe, so the guard now asserts its ABSENCE rather than its shape.

Per-host isolation moved entirely into the project name as a consequence,
and it holds there with NO second mechanism. The derivation is unchanged --
`${DOCKER_HUB_USER}-<image>` -- and that prefix is already per-OS-user with
nothing configured, because `detect_docker_hub_user` falls back to
`${USER:-$(id -un)}` when `docker info` reports no login and is the only
writer of the key. A configured `[project] name` still wins, and remains
the answer for the one case the derivation cannot separate: two OS users
sharing ONE Docker Hub login, which hands both the same prefix.

*Correction (same amendment).* A first cut of this change added an OS-user
rung to `_resolve_project_name` itself, on the belief that
`DOCKER_HUB_USER` is frequently unset and that such consumers were deriving
`local-<image>`. Both halves were wrong: detection cannot yield an empty
key, so no recorded `.env.generated` was ever in that state, and the rung
was unreachable regardless -- `detect_user_info` ends in the same
`${USER:-$(id -un)}`, so a host that leaves the hub user empty leaves
`USER_NAME` empty too. The rung was removed rather than documented, and
this paragraph stays so that a reader chasing a changed project name is not
sent to a condition that cannot occur.

A derived project name can nevertheless change under a deployed consumer,
without anyone asking for it -- and dropping `container_name` is what makes
that dangerous rather than untidy, since the second stack used to die
loudly on the baked name and now starts alongside the first. The trigger is
`just upgrade`: `upgrade.sh` runs `init.sh`, which runs `setup apply` during
the upgrade itself. (Not the drift re-apply on the next `build` / `run`:
`_check_setup_drift` hashes `setup.conf`, the Dockerfile stage list,
GPU/GUI detection and `USER_UID` -- nothing about the `.base` version or
`DOCKER_HUB_USER` -- so a subtree upgrade alone leaves check-drift green.) That apply re-detects
`DOCKER_HUB_USER` from `docker info`, so any repo whose recorded prefix no
longer matches what detection now yields -- a `docker logout`, a login as
a different account, CI versus a workstation -- resolves a different name
than the one its containers carry.

The population that made this urgent is the one still on the release
BEFORE the project name became a recorded value. Those `.env.generated`
files carry no `PROJECT_NAME` key at all: the emitter interpolated
`name: ${DOCKER_HUB_USER}-${IMAGE_NAME}` and the wrapper assembled the
same string for `-p`. Read naively, a missing key looks like a fresh
checkout, and a fresh checkout is exactly the case that renames without
deferring -- so the whole mechanism below would have skipped precisely the
repos it was written for. `_recorded_project_name` (lib/compose.sh)
reconstructs the old name from the two keys that ARE in the file.

The project name is the key compose looks its own containers up by, so
renaming while a stack is up would hide the stack from every wrapper at
once -- `stop` would tear down the new, empty project and `run` would
start a second copy over the first's bind mounts, host network and
devices, with the original reachable only by raw `docker`. Compose cannot
relabel a running container, so a rename can only take effect on an EMPTY
project.

**Decision: defer, do not skip.** While anything of the user's exists
under the recorded name, the wrapper keeps `.env.generated` on it and
records the resolved one as `PROJECT_NAME_PENDING`; the first `build` /
`run` that finds the old project empty adopts it. Both steps are reported,
so the name a checkout runs under never changes silently. "Empty" counts
containers AND named volumes, because both are keyed by the project name
and only one of them is recoverable afterwards: `stop` runs `compose down`
without `-v`, so a torn-down stack routinely leaves its volumes, and
adopting on a container-only probe would hand the user a fresh EMPTY
volume under the new name while the data sat in an orphan `prune
--volumes` later deletes. Project networks and built images are NOT
counted -- `compose down` removes the network, and an image is named
`<hub>/<repo>:<stage>` rather than by the project, so neither can be
orphaned by a rename. `stop` is therefore the whole migration for a repo
without named volumes -- it needs no new flag and addresses the stack the
user actually has, because `stop` / `exec` never regenerate and so read
the recorded name. A repo WITH named volumes keeps its old name until
someone moves or removes the data or pins `[project] name`, and is told
which of the two it is. The costs, accepted: a consumer who never stops keeps the
old (colliding) name indefinitely -- one working stack rather than two --
and while a stack is up the recorded `PROJECT_NAME` is deliberately not
the one `setup apply` just resolved. `PROJECT_NAME_PENDING` is what keeps
that divergence visible and self-clearing; it is re-derived by the next
apply, so nothing depends on it surviving. An unreachable daemon defers
too: deferring costs a cycle, renaming on a guess costs the stack.

A CONFIGURED `[project] name` is the exception and takes effect at once.
Deferring it would defeat the setting it is: its whole use is a second
worktree that must not share the first's derived name, and the containers
under that shared name are the OTHER checkout's -- occupancy there is the
reason to rename, not a reason to wait. A rename someone typed is also an
act they can sequence around, unlike a changed default. `setup apply` says
so when it displaces a recorded name, so that path is not silent either.

The reconciliation lives in the wrapper, not in `setup.sh`, because
whether a project is occupied is a question only the daemon can answer and
`setup.sh` resolves configuration on hosts where docker need not be
reachable at all.

The concrete change this decision required was `ports`: they were baked
literals and are now `${PORT_<n>:-<default>}`, `n` 1-based per the
convention above (a human who configured `[network] port_1` overrides
`PORT_1`, not `PORT_0` -- the off-by-one would be a footgun). The other
interpolation-
channel fields (`name` / `container_name` / `network_mode` / `ipc` /
`privileged` / `pid`) were already compliant; the guard locks them.
(`container_name` is since gone entirely -- see the 2026-08-26 amendment
above.)

### 4. Contract `multi_run` depends on (held, verified)

- `compose.yaml` resolves via `docker compose --env-file .env.generated
  config` -- interpolation defaults keep it resolvable with no overlay.
- `container_name` is **removable** without breaking the service: no
  service references it, and the top-level project `name:` namespaces the
  container, so `multi_run` may drop it entirely to let compose auto-name
  `<project>-<service>-<n>` per instance. (Verified, and then taken: base
  itself stopped emitting it -- 2026-08-26 amendment in §3. The wrapper
  prechecks that used to rebuild the name now ask `compose ps` for the
  service inside `-p <project>`.)
- Stage / service identity is **not tied to the literal name `devel`**:
  each service carries `build.target: <stage>`, `image: .../<stage>`, and
  `profiles: [<stage>]`, so `multi_run` extracts the stage stage-
  agnostically from `build.target` rather than matching the string
  `devel`.

### 5. Forward invariant + guard (the core deliverable)

**Forward invariant:** base's compose emission never emits a hardcoded
per-instance literal over the interpolation-channel field set. base-
generated stacks are multi_run-expandable *by construction*.

**Guard:** `overlay_guard_spec.bats` emits a compose that exercises the
per-instance fields and asserts each is an overlay interpolation, never a
baked literal -- and its predicate self-check proves it *discriminates* a
baked literal from a `${VAR:-default}` interpolation, so it fails
immediately if a future change hardcodes a per-instance field. This turns
"multi_run will not be blocked later" from a hope maintained by discipline
into a machine-enforced guarantee, caught in base's own CI rather than
discovered when multi_run tries to expand -- the same self-validation
spirit as the #800 worker preflight.

## Alternatives

- **Regenerate `compose.yaml` per instance.** Rejected: makes the
  committed artifact per-instance, defeats the single-shape contract, and
  re-flips `SETUP_CONF_HASH` on every instance (ADR-00000003's exact
  anti-goal for workload params).
- **A `compose.override.yaml` merge for every per-instance field.**
  Native and powerful, but forces hand-written compose per instance for
  scalars a flat `${VAR}` handles cleanly; kept as the channel only for
  volume *topology*, where a mount genuinely is structured (ADR-00000001's
  escape-hatch positioning).
- **Convert `runtime` / `hostname` to interpolations too.** Rejected as
  incorrect: they are host-bound and *should* be shared across co-located
  instances (a per-instance hostname would break the local X11 cookie all
  instances share; a per-instance runtime is meaningless on one host).
  Recording them as "shared, not per-instance" is the audit result, not an
  omission.

## Consequences

- `multi_run` can isolate an instance by supplying overlay `${PORT_<n>}` /
  `${NETWORK_MODE}` values (interpolation) and a per-instance `.env`
  (env_file), with no base change and no compose regenerate.
- A future emitter change that bakes a per-instance literal fails
  `overlay_guard_spec.bats` in base's own CI.
- `ports` emission changed shape (now `${PORT_<n>:-<default>}`); downstream
  repos pick it up on their next `just setup` regenerate, with identical
  resolved behaviour (the `:-` default reproduces the prior literal).
- The `#505` golden master and `gen_spec` port assertions were updated to
  the interpolation form; no runtime behaviour changed.
- A consumer upgrading with its stack UP keeps that stack and its old
  project name until the next `stop`, and is told so on every `build` /
  `run`; no container and no named volume is orphaned or duplicated
  (2026-08-26 amendment).
- A consumer whose project holds named volumes keeps its old project name
  indefinitely -- `stop` does not clear them -- and is told, on every
  `build` / `run`, that this is why and what would clear it. The accepted
  cost of never orphaning data is a repeated notice and a project name
  that stays on the pre-upgrade derivation.
- A CONFIGURED `[project] name` still takes effect at once, so it remains
  the one path that CAN strand an old project's containers and volumes;
  `setup apply` says so when it renames.
