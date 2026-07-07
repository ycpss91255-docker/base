# `[lifecycle] init` (PID1 reaper): compose-level toggle, default ON

- **Date:** 2026-07-07
- **Status:** Accepted
- **Relates to:** issue #792 (this decision, recorded in the issue's
  "Decision (grilled): compose `init: true` toggle, default ON" comment),
  issue #478 (`[lifecycle] restart`, the sibling lifecycle knob this
  mirrors), issue #797 (the watchdog restart-service mode that depends on
  comprehensive reaping)

## Context

A container's PID 1 has special kernel duties: it must reap orphaned
(zombie) children and forward received signals. A normal application
entrypoint running as PID 1 does neither, which is a footgun: `docker stop`
sends SIGTERM to PID 1, and an entrypoint that does not handle it hangs
until the 10s grace window elapses and Docker escalates to SIGKILL; and any
child whose parent exits gets re-parented to PID 1 and, unreaped,
accumulates as a zombie.

Docker solves this with `init: true` (compose) / `--init` (run): the daemon
mounts its bundled init (`docker-init` = tini) as PID 1, and the workload's
entrypoint runs as PID 2 as tini's direct child. tini reaps every orphan in
the container and forwards signals to its direct child.

base runs everything through `just` → `docker compose`, and its
`setup.conf` → `compose.yaml` generation model already carries the sibling
`[lifecycle] restart` knob (#478). Some app repos additionally carry an
unused, never-wired `tini` binary in a `runtime-base` stage — dead weight
that a compose-level init makes removable.

## Decision

**Add a `[lifecycle] init` key that makes `compose_emit.sh` emit `init:
true` on the service, and default it ON.**

1. **Mechanism — compose-level (solution 1).** The key flows
   `setup.conf` → `_resolve_deploy_context` (`deploy.sh`) →
   `generate_compose_yaml` → the emitter, mirroring `[lifecycle] restart`.
   The devel service and every per-stage standalone block emit `init:
   true`; stages that `extends: devel` inherit it. This uses the daemon's
   init, so **no tini is baked into any image**. Baking tini as the
   Dockerfile ENTRYPOINT (solution 2) is **rejected** as inconsistent with
   the `just` → `docker compose` model and the `setup.conf`-driven
   generation the rest of the runtime config already uses.

2. **Default — ON.** Enforced at both layers: the seeded `setup.conf` ships
   `init = true`, AND the code-level key-absent fallback resolves to
   `true`, so an existing downstream that regenerates (or a conf missing
   the key) also gets it. An explicit `init = false` omits the field.

3. **Independent of `restart`.** `restart` is the whole-container restart
   policy; `init` is the PID 1 reaper. They compose freely.

## The refined default rule (why ON is a principled exception)

base's prior convention is "lifecycle knobs default off" (e.g. `restart`
defaults to `no`). `init` is a deliberate exception, and the rule is
refined rather than broken: **a lifecycle knob defaults ON only when BOTH
(a) it is transparent to a correct single-service workload, AND (b) its
absence is a footgun.** `init` meets both — `init: true` changes nothing
observable for a well-behaved single-process container, while running as
PID 1 without reaping / signal forwarding silently degrades `stop` and
leaks zombies. `restart` meets neither (it changes observable
restart behavior and its absence is not a footgun), so it stays default
off. The exception is narrow and testable, not a licence to default other
knobs on.

## Alternatives considered

- **Default OFF (match `restart`).** Rejected: it leaves the footgun armed
  by default and gains nothing, since ON is transparent to correct
  workloads. The refined rule above is what distinguishes the two knobs.
- **Bake tini into the Dockerfile as ENTRYPOINT (solution 2).** Rejected:
  inconsistent with the compose-generation model, bakes a binary into every
  image, and duplicates what the daemon's init already provides for free.
- **Register a per-stage `[stage:*]` init override.** Deferred as
  unneeded: init is a whole-container property with no demonstrated
  per-stage divergence; the standalone block simply re-emits the global
  value. Can be added later without breaking the current shape.

## Consequences

- On the next compose regeneration every service gains `init: true` — a
  low-risk, beneficial behavior change. Downstream repos pick it up on
  `setup.sh apply`.
- Zombie reaping is now comprehensive in every container, which is exactly
  what the #797 watchdog's restart-service mode needs (killed subtrees do
  not accumulate as zombies).
- **Caveat (documented in the README + seeded `setup.conf`):** tini
  forwards signals only to its **direct child** (PID 2 = the entrypoint).
  An entrypoint that itself supervises children must still `trap` + forward
  signals to them — init does not reach grandchildren for *signalling*.
  Reaping, however, *is* comprehensive.
- The unused, never-wired `tini` in some app repos' `runtime-base` stage
  becomes removable — a per-repo follow-up (e.g. `realsense_ros1` /
  `realsense_ros2`), tracked separately and out of scope for #792.
