# The container entry point is base's; the repo's entrypoint is a bringup it sources

> Serves: PRD invariant 6 (base is a subtree, a downstream repo is a thin
> caller) -- the mechanism half of it. Anything base must be able to change
> later has to SHIP from `.base/`; a file seeded into a repo and then owned
> by it is, by construction, a place base can never change again.

- **Date:** 2026-09-03
- **Status:** Accepted
- **Relates to:** **#945** (the issue this implements); ADR-00000006 (the
  frozen `.base` path contract -- this ADDS `/usr/local/lib/base/entrypoint.sh`
  and changes no frozen path); ADR-00000020 (base owns the single-service
  lifecycle -- the watchdog step this ordering arms); ADR-00000021 (per-start
  container logs -- the tee step it opens first)

## Context

`init.sh` seeds `dist/dockerfile/entrypoint.sh` into a new repo as
`script/entrypoint.sh`, the Dockerfile installs it at `/entrypoint.sh`, and
`ENTRYPOINT ["/entrypoint.sh"]` runs it. That seeded file carried base's own
plumbing: `. /usr/local/lib/base/logging.sh`, `. /usr/local/lib/base/watchdog.sh`,
and the final `exec "$@"`.

From the moment it lands, the file is the repo's. A subtree pull does not
rewrite a repo-owned file, so every change base made to that plumbing
reached NEW repos only. Adding a third runtime helper, or reordering the two
it already had, was not a change to base -- it was a change to seventeen
consumer repos, exactly the class of breakage the v0.41.0 Dockerfile drift
was.

What makes it a defect rather than a design is the asymmetry with the
helpers themselves. `logging.sh`, `logrotate.sh` and `watchdog.sh` ship
correctly: one `COPY .base/dist/script/docker/runtime/ /usr/local/lib/base/`
brings the whole directory into the image, so they DO update with a subtree
pull (ADR trail: #971 collapsed the per-file COPYs for this reason). Only
the file that SOURCED them was stuck in a seeded copy.

## Decision

**Split the entrypoint by ownership, and put base's half where base's other
runtime files already ship from.**

1. **The orchestrator** -- base-owned. It lives at
   `dist/script/docker/runtime/entrypoint.sh` and therefore lands in the
   image at `/usr/local/lib/base/entrypoint.sh` through the directory COPY
   that is already in every consumer Dockerfile. It is the container
   `ENTRYPOINT`. It owns the ordering:

       logging.sh  ->  the repo bringup  ->  watchdog.sh  ->  exec "$@"

   Each step needs the one before it: the tee rebinds stdout/stderr and so
   wraps everything after it; the bringup sets the environment both the
   health check and the workload read; the watchdog may take over the
   process (`on_fail = restart-service`) and never return, so it arms last,
   around the real exec. Every source is readability-guarded, because the
   runtime stage's COPY is opt-in and a repo need not have a bringup.

2. **The bringup** -- repo-owned. It keeps its name (`script/entrypoint.sh`)
   and its image path (`/entrypoint.sh`), holds only the repo's own bringup,
   and is **sourced, not executed**: env it sets has to persist into the
   workload, and control has to return for the watchdog and the exec. It
   therefore carries no `exec` and none of base's plumbing.

**base does not migrate existing repos.** Each repo flips its own
`ENTRYPOINT` and cleans its own bringup, in one commit, in its own PR. base
ships a warn-only detector in the migration list that names the shape and
writes nothing.

The two edits are coupled in one direction: flipping `ENTRYPOINT` before
cleaning the bringup breaks the container, because the un-removed `exec`
fires mid-source. Cleaning first is inert. Doing neither is also inert --
an un-migrated repo runs exactly as before.

## Consequences

- base can add a runtime source line to the orchestrator and every migrated
  repo picks it up on its next subtree pull. That is the whole point.
- A new repo gets the model from the template with no migration at all.
- An existing repo is UNCHANGED by this release: its `ENTRYPOINT` still
  names its own file, which still execs. The orchestrator does land in its
  image on the next rebuild -- through the directory COPY -- where it sits
  inert until the repo flips the `ENTRYPOINT`.
- "Unchanged" has to hold for the `-test` stages too, and it does not come
  for free: the shipped smoke baseline runs inside every one of them and
  asserts the orchestrator, while the runtime stage's helper-directory COPY
  is opt-in. So that assertion is guarded on the model -- it skips where
  /entrypoint.sh still execs, i.e. where that file is the entry point --
  and only bites once a repo has adopted the split, where a missing
  orchestrator is a container that will not start.
- `docker inspect` now records the fact: the `ENTRYPOINT` visibly names a
  `/usr/local/lib/base/` path, so "the entry point is base's" is in the
  image rather than only in this file.
- The bringup being sourced has a real edge: a `set -euo pipefail` in it
  applies to the orchestrator shell from that point on. That is the same
  strict mode the orchestrator already runs under, so the effect is nil
  today, but a bringup that turns an option OFF and does not restore it
  leaks into the exec.
- That edge runs the OTHER way too, and there it is not nil: the
  orchestrator's `set -euo pipefail` now applies to a bringup that never
  set it. The file `init.sh` seeded before this release carries no `set`
  line, so a repo migrating one that sources a ROS overlay runs that source
  under nounset for the first time and dies on ROS's unbound
  `AMENT_TRACE_SETUP_FILES` before the workload starts. The existing
  nounset-source migration is the guard for exactly that, so it now reads
  the ENTRYPOINT as a second source of nounset rather than only the `set`
  line in the file, and README's migration steps carry the `set +u` bracket
  -- the migration can only heal the upgrade AFTER the flip, so the flip
  commit has to carry it itself.
- Two shapes are now footguns the warn-only detector names rather than
  prevents: a bringup that still execs (the watchdog never arms) and one
  that still sources a helper (a second per-start log, or a second
  watchdog). base sees both only at upgrade time, not at build time.
- The notice fires on every upgrade of every un-migrated repo until it
  migrates. That is intended -- it is the fanout's own progress bar -- but
  it is noise for a repo that has decided not to migrate yet.

## Alternatives

- **Keep one file and have `upgrade.sh` rewrite it.** Rejected. The file has
  been hand-edited in every repo for a year; only its owner can tell an
  added bringup line from base plumbing. A parser that guessed would be the
  exact fragility this split exists to leave behind -- and it would be
  guessing on the one file whose failure mode is "the container does not
  start".
- **Swap the paths: orchestrator at `/entrypoint.sh`, bringup somewhere
  else.** Rejected. It moves the repo-owned file in-image (breaking the
  shipped smoke assertion and every repo's own reference to it) and hides
  the ownership change behind an unchanged `ENTRYPOINT ["/entrypoint.sh"]`
  literal, which is precisely the fact worth recording.
- **Rename the repo file to `bringup.sh`.** Rejected: it is the repo's entry
  point conceptually, and the rename would cost every consumer a Dockerfile
  edit to buy a word. The "called by base" fact is recorded in the file's
  own header and in the `ENTRYPOINT` line instead.
- **An `/etc/entrypoint.d/*.sh` drop-in directory.** Rejected as
  over-design: a repo has one bringup, and a drop-in directory is ordering
  machinery for a problem no repo in this org has.
- **Leave it.** Rejected by the measurement: the plumbing had already been
  changed twice (the `_entrypoint_logging.sh` rename, the watchdog source
  line), and each time the fix had to be carried into every repo by hand.
