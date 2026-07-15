# base -- Product Requirements (PRD)

> base's north star: the fixed reference every decision is checked against.
> This document holds only **invariants** -- properties that must always be
> true of base. It changes only when base's **product goals** change, not when
> a mechanism changes. Individual decisions live in [`doc/adr/`](adr/); domain
> facts live in [`CONTEXT.md`](../CONTEXT.md); the working contract lives in
> [`CLAUDE.md`](../CLAUDE.md).

## Purpose

base is the single source of truth for containerised development-and-delivery
scaffolding across the `ycpss91255-docker` organisation. It exists so that
every downstream repo (ROS robotics, AI tooling, application deployment)
inherits one consistent, correct, maintained container lifecycle -- build, run,
test, and field-deliver -- instead of each repo re-implementing that lifecycle
and drifting from every other. base is vendored into each downstream as a
`.base/` subtree; the downstream stays a thin caller over base's shared logic.

## Scope

### In scope

- The lifecycle of a **single containerised service**: build (Dockerfile
  stages), run (compose generation + wrappers), test (self-test + shipped
  smoke), and field delivery (a self-contained deploy bundle).
- Host detection -> config resolution -> render, where one source
  (`setup.conf` + detection) fans out to every artifact (`compose.yaml`,
  `.env.generated`, the `.env` overlay, `deploy.sh`, the baked runtime `ENV`).
- The **shared CI mechanism** downstream repos call (reusable build/release
  workers + the `test-tools` image).
- The **propagation mechanism** (subtree + `init.sh` resync) that keeps
  downstream repos in sync with base.
- The **quality gates** that hold base itself to a trustworthy bar (the
  ISTQB-aligned self-test, the lint suite, the coverage gate).

### Deliberately out of scope

- Multiple services inside one container (see invariant 1).
- Field orchestrators / manifests (k8s, balena, ...); the deploy bundle targets
  a single-host `docker run` first.
- Non-NVIDIA GPU support (tracked separately).
- Downstream-specific business logic -- that stays in the downstream repo; base
  owns only the shared scaffolding.

## Core Invariants

Each invariant is a property that must hold across the whole of base and that
**no future ADR may violate**. The ADRs listed under each one are the decisions
that established or serve it -- they remain the record of *how* and *why*; this
document states *that it must always hold*.

### 1. One container = one service; base owns the single-service lifecycle

base produces containers that run exactly one service, and base -- not each
downstream -- owns that service's whole lifecycle: process init (PID 1
reaping / signal forwarding), restart policy, health supervision (watchdog),
and log persistence. A downstream gets a correct lifecycle for free; it never
re-implements one.

*Why it is fixed:* this is base's product shape. Every lifecycle feature is an
instance of it, and a change that broke it (multiple services per container, or
lifecycle pushed piecemeal into downstreams) would collapse the model and
everything built on it.

*Serves / established by:* ADR-00000020; realised by restart (#478), init
(#792), watchdog (#797), per-start logs (#805, ADR-00000021).

### 2. Never fail silently

Any error or missing/incompatible configuration fails **loudly and early** --
never a silent skip that still shows green. Contracts self-validate before doing
real work; a violated invariant is caught by base's own CI, not discovered
downstream.

*Why it is fixed:* base is a shared foundation; a silent failure in it
propagates to every downstream undetected. Trustworthiness is the product.

*Serves / established by:* worker preflight self-validation (#800), the
compose overlay guard (#716, ADR-00000022), the ADR-numbering guard (#808), the
doc-count drift gate, the issue-ref / no-emoji lints.

### 3. multi_run-expandable by construction

base's emitted compose never contains a hardcoded per-instance literal: every
field that can collide across instances is emitted as an overlay-overridable
interpolation (`${VAR:-<default>}`). base-generated stacks can be expanded to
many instances without first forcing a retroactive base change.

*Why it is fixed:* it is a forward guarantee. It exists so multi_run can expand
later without hitting a wall; a decision that hardcoded a per-instance value
would silently re-introduce that wall.

*Serves / established by:* ADR-00000022 (+ its enforcing guard); the
per-instance-isolation-via-.env-overlay model (ADR-00000003 axis-A resolution).

### 4. Fail-safe defaults

When a default carries a "safe vs convenient" tension, base's default falls
toward **safe**, and the riskier/tighter option is opt-in. A convenient default
that could silently break a real deployment is not shipped as the default.

*Why it is fixed:* base's defaults reach every downstream unattended; the cost
of a silently-unsafe default is borne org-wide.

*Serves / established by:* ADR-00000019 (network stays `host`, because a
`bridge` default silently breaks cross-machine ROS); this is the general
principle, of which the network decision is one instance.

### 5. The two-branch default rule

A lifecycle knob defaults **ON** if and only if enabling it is transparent to a
correct single-service workload **and** its absence is a footgun; otherwise it
defaults **OFF / Docker-native**. Defaults are chosen by this rule, not per
maintainer taste.

*Why it is fixed:* it makes "what should default on?" a checkable rule rather
than a recurring judgement call, so defaults stay coherent as knobs accrue.

*Serves / established by:* ADR-00000020 (init defaults ON as the transparent-
and-footgun case; watchdog restart-service and network default OFF/Docker-
native as workload-semantics-changing cases).

### 6. base is a subtree; downstream is a thin caller

base ships as a `.base/` subtree vendored into each downstream repo. The
downstream's entrypoints (`main.yaml`, top-level justfile) are thin forwarders;
the shared build/test/lifecycle logic lives in base. There is one source of
truth, propagated -- not N copies maintained in parallel.

*Why it is fixed:* it is base's delivery shape and ownership contract. Pushing
real logic down into each downstream (a fat caller) would fragment the single
source of truth that base exists to be.

*Serves / established by:* ADR-00000010, ADR-00000011; the pull-based version
monitor + `init.sh` resync propagation.

### 7. (Quality) base holds a rigorous, industry-aligned test bar

base is tested to a rigorous, explicitly-levelled standard, and base's own CI
is the gate that proves it. *The commitment* is the invariant; the specific
taxonomy and coverage mechanism are swappable decisions.

*Why it is fixed:* downstreams trust base because base is verifiably correct; a
weaker bar would erode the reason to inherit from base at all.

*Serves / established by (commitment):* ADR-00000018 (the ISTQB-aligned
taxonomy). *Swappable mechanisms (not invariant):* the coverage tooling
(ADR-00000008 / ADR-00000016) and the CI throughput / shard strategy
(ADR-00000017).

### 8. Development and field are cleanly separated, and provisioned by opposite means

base keeps the **development** environment and the **deployable/field**
environment cleanly apart, and provides the same config by opposite means:

- **In development** -- config is bind-mounted into the container; edit it
  directly, re-run to apply.
- **In a deployable stage** -- config is baked into the image (a working
  default), plus an optional "mount a file to override it" hook, so a
  deployment adjusts config **without a rebuild**.

The developer-vs-user split follows **git-tracking**: committed = the
developer's default (baked); gitignored / not in the repo = the
user/operator-editable overlay. The **`devel` and `*-test` stages are never
deploy targets** -- only field-oriented stages deploy; every downstream repo
follows this.

*Why fixed:* base's value is that a downstream inherits one correct dev->field
path. A devel/test image is not a field artifact (binds source, carries the
toolchain, expects a live-edit surface); deploying it, or letting field config
need a rebuild, breaks the dev/field split every downstream relies on.

*Serves / established by:* ADR-00000003 (env/workload boundary + field
delivery; this generalizes its env-row override to config files); ADR-00000023
(config field-override + field-deploy mechanism); ADR-00000011 / ADR-00000018
(devel/runtime/*-test stage structure).

## Product Shape

- **Vendored subtree, thin caller** (invariant 6): base is the shared core;
  downstream calls it.
- **Single-service lifecycle ownership** (invariant 1): base owns build -> run
  -> supervise -> log -> field-deliver for one service.
- **One source, many render targets:** `setup.conf` + host detection resolve
  once and render `compose.yaml`, `.env.generated`, the `.env` overlay,
  `deploy.sh`, and the baked runtime `ENV` -- so the same configuration is
  correct on the dev host and in a field image (ADR-00000003).

## Roadmap

- **multi_run expansion.** Invariant 3 exists to unblock running many isolated
  instances from one base-generated stack; multi_run is the consumer.
- **Field-delivery maturity.** The `deploy.sh` bundle (ADR-00000003) grows a
  richer per-parameter confirmation surface (the graphical TUI page deferred
  from the #497 epic).
- **v1.0.0 cleanups.** Retire the legacy `[deploy] runtime` alias and other
  deprecations; land the full real-flow `just base upgrade` e2e test (#772).
- **Self-hosted CI evaluation.** Guard self-hosted-eligible jobs to same-repo
  events as the prerequisite (#766), then decide on migration.
- **ADR / PRD governance.** This PRD plus the ADR audit (the remainder of #808)
  and the ADR-numbering guard (landed) keep the decision log coherent.
