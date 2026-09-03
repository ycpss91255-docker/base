# base -- Product Requirements (PRD)

> base's north star: the fixed reference every decision is checked against.
> It holds three layers and nothing else: **invariants**, properties that
> must always be true of base and that no ADR may violate; **design
> principles**, the judgement criteria base decides by when two options are
> both available; and the **conflict priority**, which of two legitimate
> properties gives way when a decision cannot have both. It changes only
> when base's **product goals** or the criteria behind them change, not when
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
  `.env.generated`, the generated `.env`, `deploy.sh`, the baked runtime
  `ENV`).
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

**A lifecycle capability that presupposes a long-running service applies only
to deployable stages.** A `devel` or `*-test` container is a *session*, not a
service: its life is the interactive shell or the test run, and it is meant to
exit. So the **restart policy is emitted only for deployable stages and the
field bundle -- never for `devel`, never for `*-test`** (which stages are
deployable is invariant 8's rule, not a second definition). Because every
context the policy still reaches is one where a container failing to come back
*is* the footgun, its default is ON.

*Why it is fixed:* auto-restart on a session container makes it impossible to
leave -- `exit` relaunches it forever. Auto-restart on a field service is the
whole point: it must survive a crash and a host reboot unattended. The same
setting is therefore correct in one place and broken in the other, so the scope
is not a tuning choice that a future decision may widen back.

*Serves / established by:* ADR-00000020 (incl. its 2026-08-03 stage-scoping
amendment); realised by restart (#478), init (#792), watchdog (#797), per-start
logs (#805, ADR-00000021).

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
per-instance-isolation-via-env-overlay model (ADR-00000003 axis-A
resolution; the overlay file is `.env.local`).

### 4. Fail-safe defaults

When a default carries a "safe vs convenient" tension, base's default falls
toward **safe**, and the riskier/tighter option is opt-in. A convenient default
that could silently break a real deployment is not shipped as the default.

*Why it is fixed:* base's defaults reach every downstream unattended; the cost
of a silently-unsafe default is borne org-wide.

*Serves / established by:* ADR-00000019 (network stays `host`, because a
`bridge` default silently breaks cross-machine ROS); this is the general
principle, of which the network decision is one instance.

### 5. The two-branch default rule, applied to lifecycle knobs

**Invariant 11 is the rule; this is where it was first written down and
what it lands on for a lifecycle knob.** The two questions there --
can enabling it break a working setup, and does forgetting it hurt --
are for a lifecycle knob the two branches this invariant is named for:
"transparent to a correct single-service workload" and "its absence is a
footgun". Both must hold to default ON.

What this invariant adds to invariant 11 is the **landing**: a lifecycle
knob that does not default ON does not default to some third base-chosen
setting, it defaults **OFF / Docker-native** -- the behaviour a plain
`docker run` would have given. base owning the lifecycle (invariant 1) is
not a licence to change what an unconfigured container does; the knob
exists so a downstream can ask for more than Docker's behaviour, never so
base can quietly substitute its own.

*Why it is fixed:* invariant 1 makes base the owner of every downstream's
lifecycle, which means a base-chosen default is not one of several
settings a reader might find -- it is the only behaviour that repo has
ever seen. Docker-native is the one landing a downstream maintainer can
predict without reading base, so it is what an OFF has to mean.

*Serves / established by:* ADR-00000020 (init defaults ON as the
transparent-and-footgun case; watchdog restart-service and network
default OFF/Docker-native as workload-semantics-changing cases);
generalised by invariant 11.

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
user/operator-editable overlay. The names follow one rule everywhere -- the
standard name is the tool's and is regenerated (`Dockerfile`,
`compose.yaml`, `.setup.conf`, `.env`), a suffix marks the local variant
that is the operator's and is never rewritten (`.setup.conf.local`,
`.env.local`). Only a **deployable stage** deploys; every
downstream repo follows this. `_is_deployable_stage` (`lib/stage.sh`) is the
one predicate that enforces it, and it rejects more than the two obvious
cases: **`devel`** (the interactive shell), **any `*-test` stage** (it exists
to run, assert and exit), **`sys` and `devel-base`** (build intermediates with
no runnable service at all), and the legacy aliases `base` / `test`. The
invariant is whatever that predicate says -- stated here in full so the two
cannot disagree.

*Why fixed:* base's value is that a downstream inherits one correct dev->field
path. A devel/test image is not a field artifact (binds source, carries the
toolchain, expects a live-edit surface); deploying it, or letting field config
need a rebuild, breaks the dev/field split every downstream relies on.

**A field artifact must not silently depend on a config layer that is not
under version control.** The gitignored per-worktree override
(`.setup.conf.local`) is a development convenience by construction: it is
visible on exactly one machine. A bundle built from it cannot be reproduced
from a clean checkout, and nothing about the bundle would say why. So
`setup deploy` REFUSES while that layer exists, and the explicit escape
hatch records in the bundle itself which sections came from it -- because
the person holding the bundle in the field is not the person who chose to
bypass the gate.

*Serves / established by:* ADR-00000003 (env/workload boundary + field
delivery; this generalizes its env-row override to config files); ADR-00000023
(config field-override + field-deploy mechanism); ADR-00000011 / ADR-00000018
(devel/runtime/*-test stage structure); ADR-00000025 (the untracked-layer
refusal).

### 9. Identity and naming are resolved once, from a file

Two properties, one subject -- what a run calls the things it creates:

- **Image identity is a function of build inputs.** Identical inputs
  resolve to one tag; different inputs can never share one. Two builds that
  agree on every input SHOULD share an image (that is a cache hit, and it is
  correct); two that differ must not be able to displace each other's.
- **Divergence in runtime naming between two checkouts comes from an
  explicit, file-recorded override** -- never from an ambient variable, and
  never from an accident of directory naming. If two checkouts run under
  different project names, a file in each says so.

*Why it is fixed:* both failure modes are silent, and both cost work that
already looked finished. A shared tag lets one run displace the image
another is mid-way through using, with no error at all -- a coverage pass
once reported green having lost its instrumentation that way. A project
name derived from a directory basename means two checkouts silently share
containers and networks, and stay isolated only by the accident of being
named apart; the same name derived from an ambient variable is invisible to
anyone reading the repo and does not survive a new terminal. Naming is
infrastructure, so it has to be as reviewable as the rest of the config.

*Serves / established by:* ADR-00000025 (`[project] name` resolved once into
`.env.generated`, read by both the wrapper's `-p` and the emitted
`name:`; the gitignored per-worktree layer that records the divergence);
the content-keyed tooling tag + checkout-keyed test project (#891 / #892).

### 10. Documentation is derived from the code, never duplicated beside it

A figure or a listing that can be computed from the tree is computed when
it is read, not stored in a tracked file that somebody must then keep in
agreement with the tree. What a documentation file holds is what no
generator can produce: intent, rationale, and the reason a thing is shaped
the way it is.

The corollary that decides where derived values live: **a derived figure
that describes the tree is stale from the moment the next commit lands.**
Storing it at a slower cadence than it changes does not fix that -- it
makes the staleness harder to notice, and a number that is only sometimes
right is harder to use than no number, because it must be distrusted every
time. So such a value is not stored at a slower cadence; it is not stored.

What that turns on is the referent, not the storage. A figure that names
what it measured -- a coverage rate labelled with the version it was
measured on -- makes no claim about the moving tree, so it cannot go stale
and it may be committed. The test totals had no referent: `3239 tests`
asserted something about the tree, which is why every branch had to edit
it.

Where a derived value is genuinely wanted by a reader, it is attached to
the thing it describes at the moment it was measured -- a release carries
its own test report -- rather than being maintained in a document that
outlives its own accuracy.

*Why it is fixed:* this is invariant 7's argument applied to the other
half of what base ships. Invariant 7 fixes base's TEST bar on the grounds
that "downstreams trust base because base is verifiably correct"; a
downstream never runs base's suite, it inherits the consequence. The same
holds for the documentation: base is vendored into every downstream, and
what a downstream reads to decide how to use the foundation is base's own
documentation. A document that looks authoritative and is wrong is
invariant 2's silent failure, propagated -- and it is worse than a wrong
figure in a report, because the reader has no way to tell which sentences
are derived and stale from which are authored and current. So how base
stores its documentation is a property of the product on exactly the
footing invariant 7 stands on, not a housekeeping preference.

The duplicate also costs on three measured axes at once (figures measured
2026-09-02). It **rots**: 46% of the per-test
catalogue's hand-written descriptions are placeholders (761 of 1,658 rows
in `doc/test/unit.md`), and where filled they mostly restate the test name
they sit beside. It **collides**: five lines carrying a test total are
edited by every branch, so 61 of the 65 merges of `origin/main` into a
branch since 2026-08-25 conflicted in `doc/test/`, and 35 commits over
that window touched nothing else. And it **misleads**: a committed figure
looks authoritative exactly when it is wrong, which is between every
commit and the sync that follows it.

*Serves / established by:* ADR-00000028 (test statistics live only in the
release, sourced from the run's JUnit XML rather than from a scan of the
source); ADR-00000027 (the release cadence this rides); the
`derived-figures` lint, which enforces the same rule for the named
constants it covers. Invariant 2's guard list names the doc-count drift
gate, which ADR-00000028 removes along with the figures it guarded; that
entry drops from invariant 2 when that mechanism lands. #952 (the release
coverage badge, merged as PR #974) is the case that fixes where the line
falls: it names the version it measured, so it is stored.

### 11. A default is decided by two questions, not by preference

Every default base ships is settled by asking, in order:

1. **If it is on, can it make something that currently works
   incorrect?** Yes -> it defaults **off**.
2. **If someone forgets to turn it on, does something go wrong?** Yes ->
   it defaults **on**.

Only when **both** hold -- it cannot break a working setup, *and* its
absence is a defect waiting to happen -- does a setting default on.
Every other combination defaults off, including the common one where
neither question has a "yes": a setting nobody is hurt by forgetting is
not worth the blast radius of shipping it enabled to every downstream.

Four things decide what the two questions are asked *about*, and they
are what make the rule mechanical rather than rhetorical:

- **The unit is a (setting, scope) pair, not a setting.** The same
  setting can be correct on in one scope and correct off in another, and
  asking the questions per scope is what produces that rather than
  forcing one answer everywhere. Restart policy is the worked case: on a
  `devel` or `*-test` container, restart-on makes `exit` incorrect
  (question 1: yes -> off); on a deployable stage it cannot make a
  correct long-running service incorrect and forgetting it means the
  service does not survive a crash or a host reboot (question 1: no,
  question 2: yes -> on). Invariant 1 states that scoping as a fixed
  property; this rule is where it comes from.
- **Question 1 asks about something that *works*, not something that
  *passes*.** A guard that turns a vacuous green into a red has not made
  anything incorrect -- it has stopped something incorrect from
  reporting otherwise, which is invariant 2's whole subject. A check
  whose absence lets a defect ship green answers "no" to question 1 and
  "yes" to question 2, and so defaults on.
- **A "yes" to question 1 has two answers, not one.** Defaulting off is
  the cheap one; removing the way the setting can break a working setup
  is the other, and it is available whenever the breakage is a property
  of the implementation rather than of the feature. The wrapper
  transcript is the recorded case: tee-ing a transcript could re-flip
  single-sink dispatch and change a terminal's output format, which is a
  question-1 yes. Base did not default it off -- it cached TTY-ness at
  startup so the tee cannot re-flip anything, turning the yes into a no
  (ADR-00000007), and `wrapper_transcript` ships `true`.
- **The rule adjudicates a toggle, not a magnitude.** `container_log_keep
  = 20` has no "off", so neither question applies to it; how large a
  default number should be is invariant 4's direction question, answered
  by which way the harm falls.
- **It is a correctness test, not a security analysis.** A permissive
  setting breaks nothing that works, so question 1 does not catch it;
  `[security] privileged` reaches `false` through the neither-yes branch,
  which is the right landing but not for the reason that matters. What
  makes it the right landing is invariant 4 -- the tension there is
  safe-versus-convenient, and the direction is safe. Where the two
  disagree the answer is still off, because both branches only ever
  license an ON.

Applied to seven of the defaults base ships today -- those chosen for
having a recorded rationale to check the rule against, not by a sweep of
every default in the tree -- it reproduces each:

| Default | Q1: can on break a working setup? | Q2: does forgetting hurt? | Yields | Ships |
|---|---|---|---|---|
| `[lifecycle] init` | no -- PID1 reaping is transparent to a correct single-service workload | yes -- zombies accrue and signals are not forwarded | on | `true` |
| watchdog `restart-service` | yes -- it relaunches a service the workload meant to stop | -- | off | commented out |
| `[network]` bridge (vs `host`) | yes -- a `172.17.x` address is not routable off-box, so cross-machine ROS goes silently unreachable | -- | off | `mode = host` |
| `[security] privileged` | no -- it is permissive, so nothing that works stops working | no -- a container that does not need it is not hurt by its absence | off (the neither-yes branch) | `false` |
| `[logging] wrapper_transcript` | no, once ADR-00000007 removed the re-flip | yes -- the debugging record is missing exactly when it is wanted | on | `true` |
| GHCR untagged-image cleanup | yes -- an untagged child a live tag still references would 404 a `docker pull` | -- | off | dry-run until `GHCR_CLEANUP_ENFORCE` |
| config mount-override writable | yes -- the container could rewrite the operator's file | -- | off | read-only, `rw` opt-in |

*Why it is fixed:* base's defaults are the configuration every downstream
runs before anybody edits anything, and they arrive by subtree upgrade
rather than by choice -- a downstream inherits a moved default in the
same commit that delivers the fix it asked for, from a maintainer who is
not in the room and cannot be asked. So the question a default must
survive is not "which setting do we prefer" but "which setting is safe to
apply, unattended, to a repo we cannot see". Invariant 4 fixes which
*direction* is safe when the tension is safe-versus-convenient; it does
not say whether a given setting is in that tension at all, or when a
default is allowed to move. Without a test the answer is recalled rather
than derived, and recollection does not survive the number of toggles
base already ships: two maintainers, or one maintainer six months apart,
reach opposite conclusions and both sound defensible. Making it two
questions makes a default *reviewable* -- it is challenged by disputing
an answer about the workload, which is a fact, instead of by disputing
taste, which is not. That is the same reason invariant 2 refuses a silent
skip: base is a shared foundation, so its judgement calls have to be
checkable by someone who was not part of them.

*Serves / established by:* invariant 5, which is this rule applied to
lifecycle knobs and where it was first written down (ADR-00000020 -- init
on as the transparent-and-footgun case, watchdog restart-service off as
the workload-semantics-changing one); ADR-00000019 (the network default,
question 1 answered by cross-machine ROS); ADR-00000007 (the case that
fixes the second answer to a question-1 yes); invariant 4, which supplies
the direction this supplies the test for.

## Design Principles

Beneath the invariants and above the individual decisions. An invariant
is a property of the product that no ADR may violate; a design principle
is a **judgement criterion** -- how base decides, when two correct-looking
options are both available. They are weaker than invariants on purpose: a
principle can be departed from in a decision that says why, and the ADR
recording that departure is the artifact. An invariant cannot.

Every principle below was **derived from decisions base has already
taken**, not imported from a list, and each one cites where it is
currently written. Where a principle is already fully stated somewhere,
this section points at it and does not restate it -- duplicating a
decision into a second document is what ADR-00000028 and invariant 10
forbid, and a governance document is not exempt from its own rule.

### P1. Early return is the default shape of every function

A guard clause at the top -- validate, reject, return -- is how a
function is written here, not a remedy applied once a nesting or length
threshold is breached. Thresholds are a net, not a target: depth 4 is
what happens when the guard was not written, and the number is how base
finds out, not what base is aiming at.

*Where written:* ADR-00000029 (this principle's record; the earlier
framing it corrects treated depth as a ranked list of violations to fix,
which produces the fixes and not the shape).
*Serves:* no invariant directly. It is the source shape ADR-00000014's
decomposition already assumes -- a lib is only a seam if its functions
can be read one branch at a time -- and so it stands behind invariant 7's
testability rather than beside it.

### P2. Derive the population; never enumerate it

Where a check, a figure or a roster can be computed from the tree, it is
computed. A hand-kept list is wrong from the first item added elsewhere,
and it is wrong silently -- the list does not know it is short, so the
check it feeds reports clean.

*Where written:* ADR-00000026 (eligibility is computed from each job's
`runs-on`, explicitly "a label-family pattern rather than a roster",
after `_LINT_TOOLS`, the downstream roster and the release archive path
list had each been missed by the next addition); ADR-00000028 (a figure
that can be computed is not stored); `doc/adr/README.md` ("the filesystem
is the ADR registry -- there is no database and no manually-curated
master list of numbers").
*Serves:* invariants 2 and 10.

### P3. A check that finds nothing must distinguish an empty population from a broken scan

"Zero violations" and "zero files examined" are different results and a
guard has to be able to say which one it got. A scan whose matcher has
stopped matching reports exactly what a clean tree reports, so the
difference has to be measured -- the count of things examined -- and a
zero there is a refusal, not a pass.

*Where written:* ADR-00000026 (anything the lint cannot statically prove
is eligible -- the rule fails closed -- and `ci-rollup` fails a fork PR
rather than collapsing a guarded skip into a green required check).
*Serves:* invariant 2. This is the mechanical half of "never fail
silently": a gate that has quietly stopped gating is the silent failure
that is hardest to notice, because its output is indistinguishable from
success.

### P4. One rule has one owner and many entry points

A rule is implemented once and every caller reaches that implementation.
Two implementations that must agree are a drift with a delay on it, and
the delay is however long it takes for one of them to be edited alone.

*Where written:* ADR-00000011 (the CI job runs the same driver `just
test` runs locally, so the local gate and the CI gate cannot drift);
ADR-00000024 (the mechanical half of the rule is gated by one lint);
invariant 8 (`_is_deployable_stage` is "the one predicate", and the
invariant is stated in full precisely "so the two cannot disagree"); the
`doc-counts` gate, described in `test.sh` as one rule with three entry
points of which this is the blocking one.
*Serves:* invariants 2 and 6.

### P5. Zero special cases outranks a shorter invocation

Where a rule can hold without exception at the cost of ergonomics, base
pays the ergonomics. One rule with no exceptions is learnable once and
stays true; a rule with two exceptions has to be recalled with them, and
the third exception is the one nobody remembers.

*Where written:* ADR-00000011 sec.1, in base's own words: "The cost
(longer invocations) is accepted in exchange for one rule with no
exceptions." `just build` became `just docker build`, reversing
ADR-00000010's top-level-docker carve-out.
*Serves:* invariant 6 -- a thin caller can only stay thin if the shape it
forwards has no cases in it.

### P6. Relocate into an existing seam before creating a new one

When code needs a home, the first question is which established seam it
belongs to; a new file is created only for what genuinely has none. A
parallel namespace that duplicates seams already present is how a
decomposition ends up with more surface than it removed.

*Where written:* ADR-00000014 rule 1 ("Relocate into existing libs first;
create new libs only for the homeless ... We do NOT introduce a parallel
`setup_*.sh` namespace that duplicates seams that already exist").
*Serves:* no invariant. It is a source-architecture criterion, and the
seams it applies to are named in `CONTEXT.md`.

### P7. Every escape hatch is explicit, named, and records why it was taken

base ships escape hatches rather than pretending every case fits. What it
does not ship is a silent one: taking the hatch is a visible act, it is
named at the point of use, and where the consequence outlives the person
who chose it, the artifact carries the reason.

*Where written:* ADR-00000001 (compose-native mechanisms are an escape
hatch "reserved for genuinely custom needs", not a second main path);
ADR-00000025 (`setup deploy` refuses while an untracked config layer
exists, and the explicit override records in the bundle which sections
came from it -- "because the person holding the bundle in the field is
not the person who chose to bypass the gate"); ADR-00000023 as amended by
#874 (a config mount-override is read-only with an explicit `rw` opt-in);
the `changelog-entry` opt-out, which is a comment pair carrying `<why>`;
the `arch-literal` lint, whose mapping exception "opts out with a stated
reason".
*Serves:* invariant 2.

### P8. Additive first, retirement second

A change that would break a consumer is split so the break is its own
deliberate step. The new path lands beside the old one, both work, and
the removal is a separate decision that can be timed, announced and
reverted independently of the thing that motivated it.

*Where written:* ADR-00000005 ("Rollout is additive first, retirement
second, split so the breaking change is deliberate"); ADR-00000014 rule 3
(one slice = one issue = one PR, behaviour identical, the existing specs
standing as the regression net).
*Serves:* invariant 6. base propagates by subtree upgrade, so every
consumer takes the step at a moment base does not choose; a combined
add-and-remove is a step they cannot take halfway.

### P9. A record lives where its reader will be standing

The same fact is not written into every document that could hold it. It
is written where the person who needs it is already looking, and the
other places link to it. Which document that is follows from who the
reader is and what they are trying to decide.

*Where written:* `script/test/drivers/changelog_entry.sh`'s header, which
states the rule and the placement together -- "this repo already decided
that the PR body is the canonical decision record, enforced by a hook on
`gh pr create` ... A changelog entry answers two questions -- what
changed, and does it affect me. Not why, and not what was rejected";
ADR-00000013 (drop the transient issue number from a code comment, keep
the sentence -- the number's reader is in the tracker, the sentence's
reader is in the file); ADR-00000027 sec.3 (the release classification's
reasoning is recorded so a wrong call is reviewable rather than
invisible).
*Serves:* invariant 10 -- this is its "authored, not derived" half asked
about placement rather than about generation.

### Stated elsewhere, not repeated here

Three principles that belong to this layer by shape are already stated in
full above it or beside it, so they are referenced rather than restated:

- **Naming follows ownership** -- the standard name is base's and is
  regenerated, a suffix marks the operator's and is never rewritten. This
  is part of invariant 8, not a principle beneath it.
- **Test files mirror source; source structure is never decided by
  tests** -- ADR-00000015, which states it and its consequences
  completely.
- **Deep modules: a small interface over a private implementation** --
  ADR-00000014 plus the seam vocabulary in `CONTEXT.md`.

## Conflict Priority

What this order is **for**: two properties base holds are both
legitimate, both wanted, and a particular decision cannot have both. The
order says which one gives way. That is all it says.

What it is **not** for: it is not a licence to rank "this is hard" above
anything. Difficulty is not one of the properties below and never enters
the comparison -- a change that is hard to make safely is a finding about
the code (ADR-00000029), not a competing claim. A decision that reaches
for this order has to name the two properties in tension and show that
having both is genuinely impossible here; if it cannot, the conflict is
imagined and the order does not apply.

Higher wins.

**1. Correctness of what the consumer runs.** The artifact a downstream
builds, runs or ships to the field behaves as its operator has every
reason to expect. *Rests on invariants 1, 2 and 8.*

**2. A defect is loud, and early.** Where something is wrong, the run
says so at the first point a human is present, rather than continuing and
reporting green. *Rests on invariant 2.*

**3. One owner for one rule.** A rule is implemented once, propagated,
and reached through as many entry points as are wanted. *Rests on
invariants 6 and 10; this is P4 as a property rather than as a
criterion.*

**4. Convenience at the point of use.** Fewer steps, shorter
invocations, less to type and less to know. *Rests on no invariant, which
is why it is last -- not because it does not matter.*

### Worked examples, each from a conflict base actually settled

**1 over 2 -- the log-retention clamp (ADR-00000021).**
`container_log_keep` and `container_log_days` are validated as positive
integers by the schema registry, so a bad value in `.setup.conf` is
refused loudly at `just setup`, where a human is standing. The same
values arrive at the container entrypoint a second time through a
hand-editable `compose.yaml`, and there
`dist/script/docker/runtime/logging.sh` **clamps** a non-positive value
back to 20 / 14 without a word. Property 2 taken alone says refuse; the
refusal would mean the container does not start, or starts with a prune
that wipes every log -- so property 1 wins and the clamp is silent. The
order is what makes this a decision rather than an inconsistency with
invariant 2: loud where a human is present, safe where one is not.

**2 over 3 -- the fork-PR rollup (ADR-00000026).** The one-owner answer
to "did CI pass" is a single rollup status summarising the matrix, and a
guarded job that skips contributes a skip to it. base refuses that:
`ci-rollup` **fails** a fork PR rather than let a guarded skip collapse
into a green required check, and the eligibility lint fails closed on
every `runs-on` it cannot statically prove. A vacuous green is the
failure invariant 2 exists to prevent, so the tidier single status gives
way.

**3 over 4 -- namespacing every action (ADR-00000011 sec.1).** Recorded
in the ADR's own words: "The cost (longer invocations) is accepted in
exchange for one rule with no exceptions." `just build` became `just
docker build`, reversing the top-level-docker carve-out ADR-00000010 had
made for exactly the convenience being given up here.

**1 over 4 -- the network default (ADR-00000019) and the `/opt` bake
(ADR-00000024).** #794 proposed flipping `network.mode` to `bridge` on
least-privilege grounds, which is the more idiomatic and more convenient
posture; it was reversed because a bridge's `172.17.x` address is not
routable off-box and cross-machine ROS would go silently unreachable.
Likewise `~/name` is the convenient path to source and `/opt/name` is
not, but `ENV HOME` resolves at build time, so anything sourced through
`$HOME` breaks under a different `USER_NAME`; the symlink stays for
discoverability and nothing sources it.

**2 over 4 -- the deploy refusal (ADR-00000025).** The convenient
outcome of `setup deploy` is a bundle. base refuses to produce one while
a gitignored `.setup.conf.local` exists, because a bundle built from a
layer visible on one machine cannot be reproduced from a clean checkout
and nothing about the bundle would say why.

### When the order does not decide it

Two properties at the same rank do not resolve by this list, and neither
does a conflict between an invariant and anything at all -- an invariant
is not a property that can give way, which is what makes it an invariant.
A decision that finds itself trading one invariant against another has
found a defect in the invariants, and the artifact is an amendment to
this document, not an ADR that picks a winner.

## Product Shape

- **Vendored subtree, thin caller** (invariant 6): base is the shared core;
  downstream calls it.
- **Single-service lifecycle ownership** (invariant 1): base owns build -> run
  -> supervise -> log -> field-deliver for one service.
- **One source, many render targets:** `setup.conf` + host detection resolve
  once and render `compose.yaml`, `.env.generated`, the container-bound
  `.env`, `deploy.sh`, and the baked runtime `ENV` -- so the same configuration is
  correct on the dev host and in a field image (ADR-00000003). The source is
  a layered chain of files -- shipped default, the repo's committed
  override, the operator's gitignored per-worktree override -- resolved
  section-by-section, with no ambient environment variable able to steer it
  (ADR-00000025).

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
