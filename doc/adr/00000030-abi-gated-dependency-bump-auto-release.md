# A dependency bump auto-releases only when a gate can prove it ABI-safe, and a gate never cuts anything but a Z

> Serves: PRD invariant 6 (base is a subtree; downstream is a thin caller)
> -- one convention in base rather than seventeen repo-local definitions of
> "safe to release"; also invariant 4 (fail-safe defaults -- "cannot
> determine" resolves to not releasing) and invariant 2 (never fail
> silently -- the gate states which rule refused, by name).

- **Date:** 2026-09-03
- **Status:** Accepted
- **Relates to:** ADR-00000027 (release cadence -- **amended in place** by
  this record, which adds a non-human, non-agent actor to its section 1 and
  a mechanical classifier to its section 3), ADR-00000002 (immutable
  version pinning -- why a resolved version has to be a `vX.Y.Z` tag and
  not a moving name), issue **#829** (the downstream ask this answers, and
  its decided mechanism), issue **#1012** (the defect class this design is
  written against: a version decision read off a ref that carries none, and
  an unrecognised input resolving to the most-consumed name)

## Context

A downstream repo that pins an upstream dependency -- `realsense_ros2`
pinning librealsense and realsense-ros is the case that raised this --
wants the bump flow hands-off: notice a new upstream tag, move the pin,
write the changelog entry, merge on green, release. Every step of that is
mechanical except the last, and the last one is where the judgement lives:
**releasing a bump says the thing downstream consumers can rebuild against
did not change.**

Three facts shaped what could be built.

**A bot cannot re-enter the tag path.** An event created with the default
`GITHUB_TOKEN` starts no new workflow run. A repo that pushes `vX.Y.Z` from
a workflow therefore gets no run from it, and
`.github/workflows/release-worker.yaml` is `on: workflow_call` only -- it is
reached by a downstream repo's `call-release` job, which today is gated on
`startsWith(github.ref, 'refs/tags/')`. So an auto-release either carries a
PAT to make the push look human, or it calls the worker directly from the
post-merge run. #829 settled on the direct call; the worker's version then
has to come from an input, because on that path `github.ref_name` is a
branch.

**A version decision read off the wrong source is this repo's live defect
class.** #1012: `release-test-tools.yaml` writes `:latest` from a `tags:
'v*'` trigger, so `v0.42.0-rc4` moved the tag every unpinned consumer
builds from -- four times. Its unrecognised-input branch resolves to the
same `:latest`. Both are the same mistake in different clothes: a decision
about a version taken from something that does not carry one, and an input
the code could not read resolving to the most permissive answer. An
auto-release gate written the same way would industrialise it.

**Nobody can define "ABI-safe" once for every dependency.** librealsense's
SONAME carries its minor; plenty of libraries carry only their major; a 0.x
version promises nothing at either level. A gate with a built-in answer is
a base-wide guess that silently releases somebody's break.

## Decision

### 1. The gate decides one thing, and refuses everything it cannot decide

`script/ci/abi-gate.sh` answers exactly one question -- is this
`old -> new` pin change ABI-safe by the convention this dependency itself
follows. It refuses, by name and with the reason on stderr:

- a version it cannot read on either side, including a suffixed one
- an ABI axis that is undeclared, or declared as something it does not
  recognise
- a 0.x pin declared with a major-only axis (the fix is in the message:
  declare `major.minor`; it is not silently re-read as that, because a
  declaration nobody corrects goes on meaning something other than what it
  says)
- a downgrade, and an unchanged pin
- a pair the upstream's own compatibility declaration does not sanction

A refusal prints **nothing on stdout**, so a caller appending stdout to
`GITHUB_OUTPUT` is left with no `decision` key: the
`outputs.decision == 'release'` wiring and the bare exit status both read a
refusal as "do not release". There is no arrangement of the caller in which
an unanswerable bump releases itself.

### 2. The ABI axis is declared per dependency, and has no default

`ABI_AXIS=major` or `ABI_AXIS=major.minor`, supplied by the repo doing the
bumping. Which component is a dependency's ABI is a fact about that
dependency, so base does not hold an opinion about it; a repo that declares
nothing gets no auto-release, which is the correct default rather than a
gap.

### 3. Follow the upstream's declared compatibility

Where a wrapper declares the dependency version it was built against, the
new pin must agree with that declaration on the ABI axis (`UPSTREAM_COMPAT`).
Two dependencies each bumped to their own newest is a combination the
upstream never shipped, and each half being ABI-clean on its own does not
make the pair tested.

### 4. A gate may cut a Z. It may never cut a Y or an X

An ABI-safe dependency bump is a patch release. Anything the gate refuses
is not released by machine at all: it goes to a person, who classifies it
under ADR-00000027 section 3 -- and a bump that moves a dependency's
interface is very often a Y, which section 2 keeps human. This is the
boundary that makes an automatic release compatible with a cadence whose
whole point is that behaviour changes are somebody's decision.

### 5. The release is cut by calling the worker, not by pushing a tag

`release-worker.yaml` takes an optional `version` input, resolves it
through `script/ci/release-version.sh`, and sets the release's `tag_name`
from the result, creating that tag at the commit being released. So the
post-merge run calls the worker directly and no tag event is needed. The
resolver applies the same fail-closed rule as the gate: a version it cannot
read is refused rather than resolved to the ref, to a default, or to any
name something already consumes. The prerelease flag is derived from the
resolved version, never from `github.ref_name`, which is `main` on this
path and would have published every RC as a full release.

### 6. The reasoning is recorded, not requested

The gate prints `reason=` beside its approval, and its refusals name the
rule that fired. ADR-00000027 section 3 requires an automatic Z to carry
the classification that justified it so the call is reviewable after the
fact; for a machine-cut Z that record is the gate's own line, and it is a
report rather than a request for approval.

### What this record does NOT decide

- **Whether a compatibility declaration is mandatory.** It is honoured when
  supplied and absent otherwise. Making it required for every repo is a
  cross-repo policy call, and extracting it from a given upstream (parsing
  a `CMakeLists.txt`, say) is repo-specific work that does not belong in a
  shared gate.
- **The shape of the downstream bump workflow.** The trigger, the changelog
  edit and the next-version computation live in the repo doing the bump.
  base supplies the gate and the release entry point; it does not supply
  the workflow, and a shared reusable one is a separate decision with its
  own evidence.

## Consequences

- A repo gets auto-release by declaring an ABI axis per pinned dependency
  and wiring two steps. A repo that declares nothing keeps releasing by
  hand, silently and correctly.
- **A refusal is loud.** The gate exits non-zero, so a post-merge run that
  refuses shows as a failed step rather than a green run that quietly did
  nothing. It blocks no merge -- the bump is already in -- and a caller that
  prefers a refusal to be a normal outcome runs the step with
  `continue-on-error: true` and gates on its `outcome`.
- **The gate trusts the declared axis; it cannot see a SONAME.** A
  dependency that breaks its ABI without moving the component its repo
  declared will pass. That residual risk is accepted knowingly: the
  alternative is base deciding per dependency, which is the guess this
  record exists to refuse. It is bounded by the axis being a per-repo
  declaration a human wrote once and can tighten.
- `release-worker.yaml` -- `on: workflow_call` only, so no tag reaches it
  directly -- now has a second way in: a caller that passes a version rather
  than one whose own job is gated on a tag ref. The tag path is unchanged:
  the input defaults to empty and the resolver falls back to the ref.
- The worker now refuses a tag that is not `vX.Y.Z[-suffix]`. Any repo that
  released under a differently-shaped tag fails at the resolve step with the
  expected shape in the message, instead of publishing a release nothing can
  pin (ADR-00000002).
- An auto-released Z does not fan out, by ADR-00000027 section 4, so this
  cannot turn one dependency bump into seventeen upgrade PRs.

## Alternatives

- **Give the gate a default ABI axis.** Rejected: any default is wrong for
  some dependency, and wrong in the direction that releases a break. The
  librealsense case (SONAME carrying the minor) and a plain
  major-only library disagree, and both are ordinary.
- **Release unless the bump is proven breaking.** Rejected: it inverts the
  burden of proof onto the case that costs the most. It is also #1012's
  unrecognised-input branch restated as a policy.
- **Push the tag with a PAT so the existing tag path fires.** Rejected in
  #829: every downstream repo would have to create, scope and rotate a
  secret to get a behaviour the direct call gives with the default token.
- **Let a gate cut a Y when the bump is breaking.** Rejected: a breaking
  dependency change is precisely the case a person is for, and it
  contradicts ADR-00000027 section 2.
- **Leave the rule to each downstream repo.** Rejected: seventeen
  definitions of ABI-safe, of which the fail-open ones are the invisible
  ones. A shared gate is also a shared place to fix a rule.
- **Make a refusal a silent green no-op.** Rejected: a run that decided not
  to release and said nothing is indistinguishable from one that never
  looked (PRD invariant 2).
