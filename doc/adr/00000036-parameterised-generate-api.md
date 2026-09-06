# base is a building block: both generate stages are parameterised APIs

> Serves: PRD invariant 3 (composable by construction) -- restated.
> The overlay contract ADR-00000022 built to serve that invariant turned out to
> serve it only for values, not for shapes.

- **Date:** 2026-09-06
- **Status:** Accepted
- **Relates to:** issue #1087 (this decision), issues #1051 / #1056 / #1062 /
  #1064 (the gaps that produced it), issue #25 (multi_run), issue #600 (the
  division of labour), ADR-00000022 (amended by this -- sections 1 and 3),
  ADR-00000025 (amended by this -- the `.setup.conf.local` axis),
  ADR-00000003 (environment vs workload parameter boundary)

## Context

`multi_run` is being rebuilt as the composition layer #600 describes: base
downstream repos are modules, and multi_run instantiates them -- **including
several instances of the same repo at once**, three lidar units being three
instances of one lidar repo -- and wires them together.

That makes "one repo, many instances" the primary case rather than an edge one,
and four issues filed from the consuming side each found the same wall from a
different angle:

- **#1051** -- fields that collide across instances with no override channel at
  all: `[logging] local_path` (two instances write the same `devel.log`),
  `devices:`, the `config/<c>` binds, stage-level overrides of
  `network_mode` / `privileged` / `ipc` / `pid`.
- **#1056** -- asking for a per-section verdict across all 15 sections, because
  the limits are undiscoverable: "the cost of the current situation is not the
  limits themselves; it is that they are undiscoverable."
- **#1062** -- values the emitter decides that have no config key at all:
  `container_name`, `hostname`, `profiles:`, `stdin_open` / `tty`, `env_file:`,
  and a shipped `[tmpfs]` section the validator does not know about.
- **#1064** -- two field-deploy bundles from one repo cannot co-exist, because
  the project name and the container name are the same baked string.

ADR-00000022 answered the same question in 2026-07 with an **overlay**: one
generated `compose.yaml` per repo, per-instance variation carried by `${VAR}`
interpolation from a per-instance `.env`, and an explicit rejection (its section
1) of regenerating `compose.yaml` per instance. Its section 3 additionally
recorded GPU, `runtime` and `hostname` as *correctly shared* -- co-located
instances share one host's GPU and one X11 cookie -- and therefore deliberately
outside the per-instance contract.

Two things about that answer did not survive contact with the composition case.

**An interpolation carries a value; it cannot carry a shape.** `[build] arg_N`,
`[image] rule_N`, `[gui] mode`, `[additional_contexts]`, an extra
`deploy.resources` block -- these change *which lines exist* in the emitted
file. No amount of `${VAR}` substitution reaches them, so under an overlay-only
contract they are permanently per-repo. #1056 grouped exactly these as "group 3,
where the boundary is undecided", and the honest answer under ADR-00000022 was
"never per-instance".

**"Shares a host" was conflated with "shares an assignment."** Three instances
on one host do share one GPU device tree. It does not follow that they must all
claim it identically: an assembler may want instance 1 on GPU 0, instance 2 on
GPU 1, and instance 3 with no GPU at all. Section 3's row is correct about the
hardware and wrong about the contract.

Underneath both is a framing question, and it is the one that actually decides
this: **is base a configurable application that happens to be reusable, or a
building block that an assembler drives?** ADR-00000022 assumed the first --
base owns the generated artifact, and multi_run adjusts it from outside. The
composition design requires the second.

## Decision

**base is a building block. Both of its generation stages -- devel
(`just docker setup`) and deploy (`just docker setup deploy`) -- are APIs an
orchestrator calls N times against one repo, each call carrying that instance's
parameters and writing a complete result into a directory the caller names. The
repo is not mutated by a call.**

The rule that follows, and the one that replaces #1056's request for a
15-section table:

> Anything base decides at build time or before the container starts must be
> reachable by the caller. Only what is internal to a running container is
> outside the contract.

A value the assembler cannot reach is a defect in the block, not a documented
limit. There is no list of exempt sections.

Two mechanisms carry it.

### 1. The `.setup.conf.local` layer takes a caller-supplied path

The conf chain is `<template>/.setup.conf` -> repo `.setup.conf` ->
`.setup.conf.local`, section-replace at each step. The third layer is already
the right shape: ADR-00000025 section 1 gave it the power to override **any**
section rather than a whitelist. What it lacks is an address -- its path is
fixed at `<repo>/.setup.conf.local`, so two concurrent instances cannot hold two
parameter sets without writing into the repo and racing each other.

A call names the file it wants read as that layer. Two calls, two files, no
write to the repo's own.

### 2. Generation takes an output directory

`deploy` already has `--output`. `devel` writes `compose.yaml` and `.env` into
the repo root with no alternative, so a second instance's generation overwrites
the first's. devel gains the same parameter, and a call emits a complete
self-contained set into the caller's directory.

### What this does to the four issues

- **#1051**: every field it lists is pre-start, so every one becomes reachable.
  The `[logging] local_path` case in particular no longer needs to survive as an
  interpolation -- the value is resolved per call, before emission.
- **#1056**: answered by the rule above rather than by a table. Group 3 is
  reachable; group 1's GPU row is reopened.
- **#1062**: every emitter-decided value becomes a key with today's behaviour as
  its default, `container_name` included (default: emit nothing).
- **#1064**: yes -- the bundle's project and container names become parameters
  with the current baked value as the default, which preserves the stable
  `docker logs` name that motivated baking them.

### Amendments this makes to existing ADRs

**ADR-00000022 section 1** rejected per-instance regeneration. That reasoning
held while generation could only write into the repo: regenerating meant
mutating a shared checkout, and two instances would fight over one file. Once a
call writes to a caller-named directory outside the repo, the objection does not
apply. Per-instance generation is now the supported path for shape-changing
parameters. The `.env` overlay is **not** withdrawn -- it remains correct and
cheaper for values that do not change the emitted file's shape, and every
channel in section 3's table keeps working.

**ADR-00000022 section 3's last row** -- GPU, `runtime`, `hostname` as correctly
shared -- is narrowed to a statement about the host, not about the contract.
These become caller-reachable.

**ADR-00000025 section 6** drew the line that `.setup.conf.local` is a
per-worktree axis and not a per-instance one. That line was drawn because the
file had one fixed location, which made "another parameter set" mean "another
checkout". With a caller-supplied path the same layer serves both axes: a
developer still gets the per-worktree file at the default location, and an
orchestrator passes its own. The layer's semantics -- section-replace, overrides
any section, gitignored at the default path -- are unchanged.

## Alternatives

**Widen the interpolation channel until everything is a `${VAR}`.** Rejected:
it cannot work. Build args, image rules and conditional blocks change which
lines exist, and interpolation substitutes into lines that already exist. This
was the actual finding, not a preference -- #1056's "group 3" is precisely the
set that proved it.

**Publish the 15-section boundary table #1056 asked for and keep the current
limits.** Rejected. It is a coherent answer and it was seriously considered: it
costs nothing to write and it would end the undiscoverability the issue
complains about. It was rejected because the limits it would document are
artifacts of where the generator writes its output, not properties of the
domain. Documenting an accident as a contract makes it permanent.

**Let multi_run generate compose files itself.** Rejected. It would duplicate
the schema, the validators, the stage resolution and the Dockerfile-stage
discovery, and the two implementations would drift -- the failure mode
`resolve_compose.py` already demonstrated before multi_run#26 removed it. It
also loses the two things base solves that multi_run cannot: packing each repo's
image, and keeping `env_file:` indirection so secrets are not inlined into a
resolved artifact.

**Per-instance regeneration into the repo, coordinated by locking.** Rejected:
it mutates a shared checkout, serialises what should be parallel, and leaves the
repo in whichever instance's state was generated last.

## Consequences

**The generated artifact stops being a repo-owned file.** A call's output is the
caller's. `compose.yaml` in the repo root becomes the default output of the
default call rather than the only place generation can land, and `.gitignore`'s
managed block keeps covering it for the developer path.

**The emitter loses the right to decide anything silently.** Every literal it
carries -- `build.context`, `dockerfile`, `networks: driver: bridge`,
`deploy.resources.reservations.devices[0].driver: nvidia`, the X11 passthrough
list, the `devel-test` -> `test` service rename -- is either a key with a
default or is documented as emitter-owned with the reason. #1062 is the
inventory.

**A second guard obligation.** `overlay_guard_spec.bats` today passes because
its fixture avoids every violating branch (#1051 section C). The guard now has
to prove the stronger property: that two calls differing only in their
parameters produce two results differing in exactly those parameters. A fixture
that exercises no divergent branch is worse than no guard, and this repo has
already paid for that shape more than once.

**The support surface grows.** Every newly reachable parameter is a parameter
someone can set wrongly, and the validators, the TUI and the docs all widen with
it. This is the real cost of the decision and it is accepted deliberately: the
alternative is an assembler that accumulates a list of things it cannot do.

**Compatibility.** Nothing a consumer runs today changes behaviour. The default
call with no new arguments reads `<repo>/.setup.conf.local` and writes to the
repo root, exactly as now. The new parameters are additive.

**multi_run#26 changes shape.** Its current design takes the repo's already
generated `compose.yaml` and drives it with `-p` plus an overlay. Under this
decision it calls base to generate per instance instead. That is a real cost on
the consuming side and was accepted with the decision.

**Follow-ups unblocked:** #1051, #1056, #1062, #1064 all resolve through #1087
rather than each needing its own mechanism. **Still open:** #1052 (whether a
module declares a dataflow interface at all) is untouched -- this decision is
about how a block is parameterised, not about what one block offers another.
