# `compose.yaml` lives at the repo root, and a test has a level AND a type

> Serves: PRD invariant 2 (never fail silently) -- both halves are questions
> whose wrong answer is silent: a compose file Compose cannot find changes the
> project name rather than erroring, and a taxonomy read as one axis makes a
> live test category look retired.

- **Date:** 2026-09-05
- **Status:** Accepted
- **Relates to:** ADR-00000011 (`just` is the single control surface, and the
  compose services it drives), ADR-00000018 (the ISTQB taxonomy this records
  the read-back of), ADR-00000022 (per-instance compose contract -- the
  project-name derivation this depends on)

## Context

Two questions asked on 2026-09-05, both from a reasonable reading of the tree,
both answered wrong by that reading. Neither had a record to point at.

**1. "`compose.yaml` at the repo root is CI's, so should it be under
`.github/`?"** The premise is that it is CI-only. It is not:
`script/test/drivers/../test.sh` names `-f "${REPO_ROOT}/compose.yaml"` on the
path `just test` takes locally, and no workflow file names it at all -- CI
reaches it the same way a developer does, through `just`. The file defines six
services (`test-tools`, `smoke`, `ci`, `ci-system`, `coverage`, `default`), not
one CI service.

That correction does not settle the location question, because "`just test` IS
the local half of CI" is also true. The location has its own reasons.

**2. "We no longer have smoke, only unit and integration -- is there rotted
doc or code?"** There is not. 17 tracked files under `smoke`, and two changes
landed on 2026-09-05 alone (#1045 moved the tree, #1050 protected it from a
half-applied rollback). The reading came from ADR-00000018's model being
remembered as one axis.

Checked while answering: `behavioural`, the category ADR-00000018 retired,
appears 88 times in the tree. Every live occurrence is the adjective ("the
behavioural half", as against the static half), not the category. The changelog
occurrences are history and stay. No rot.

## Decision

### 1. `compose.yaml` stays at the repo root

Three reasons, in order of how expensive it is to get wrong:

**The project name is derived from the file's directory.** Compose's documented
fallback is "the `basename` of the project directory containing the config
file". This repo computes its own project name (`base-<sha256(repo root)[0:12]>`,
stamped as the `base.checkout.path` label so ownership is provable), so moving
the file would not break `just` -- but it would make a bare `docker compose`
disagree with `just` about which project it is in. The file's own header
records what a previous divergence of exactly this shape cost: two different
defaults for the tooling image meant `docker compose build` tagged one image
while `docker compose run` pulled another, the suite ran against the published
image, and nothing warned.

**Discovery is designed for the root.** Compose "traverses the working directory
and its parent directories looking for a `compose.yaml`". At the root, every
subdirectory of the repo finds it. Under `.github/`, nothing does, and every
invocation needs `-f`.

**`.github/` is GitHub's namespace.** Workflows, issue templates, CODEOWNERS,
FUNDING -- read by GitHub. A Docker toolchain file there is findable only by
someone who already knows it moved.

### 2. A test has a LEVEL and a TYPE, and they are different questions

ADR-00000018 established this. It is recorded again here because the model is
routinely read as a single list, and reading it that way makes `smoke` look
retired.

| axis | question | values here |
|---|---|---|
| **Level** | how much of the system is under test | Unit, Integration, System, Acceptance |
| **Type** | what property is being checked | smoke, e2e, regression |
| **Static** | not a test at all | lint |

Every test has both. They are orthogonal, not a hierarchy, and `smoke` is a
**type** -- ADR-00000018's own words are that it "was misclassified as a
level".

**Why smoke still looks like a level, and why that is not a defect.** It has
its own directory, `dist/test/bats/smoke/`, because of *when* it runs rather
than *how much* it covers: those specs are COPYed into every Dockerfile
`-test` stage and executed during `docker build` -- "the does-it-even-come-up
baseline that runs inside EVERY `-test` stage". They are not in the `just test`
bats loop. The directory reflects an execution point, not a fifth scope.

`test/bats/acceptance/` holds no specs today. That is deliberate (a CI-only
level) and tracked by #1046 -- but an empty directory reads as an abandoned one,
which is the other half of why this record exists.

## Alternatives

**Move `compose.yaml` under `.github/`.** The argument is coherent and is the
one that prompted this record: the file is only ever executed by CI or by
`just test`, which is CI's local half, so "it is infrastructure, put it with
the infrastructure" follows. Rejected on the project-name derivation, which is
a mechanism rather than a preference -- Compose names the project after the
directory holding the config file, so a bare `docker compose` would disagree
with `just` about which project it is in, and this file's own header records
what a divergence of exactly that shape already cost once. Discovery and the
`.github/` convention are the second and third reasons, not the first.

**Move it and pass `-f` everywhere.** Removes the discovery objection and none
of the others; adds a flag to every invocation, including the ones a person
types by hand while debugging, which is where the divergence would show up
last.

**Say nothing and let the taxonomy be re-derived each time.** What happened
until now. The cost is measured rather than supposed: the question "we no
longer have smoke, is there rotted doc or code?" was asked on 2026-09-05 about
a category with 17 tracked files that had been modified twice that same day.
Answering it took an audit; the audit found no rot. A record is cheaper than
repeating the audit.

## Consequences

- The location question has an answer to point at, with the mechanism (project
  name from the config file's directory) rather than the convention.
- Anyone reading `doc/test/` and finding four level catalogues plus a smoke
  catalogue has the two-axis model to read them with.
- **Not settled here:** whether `dist/test/bats/smoke/` should be split
  per-stage now that every repo is on the layout (#1046), and whether the
  acceptance level gets content (#1046 again). This record says what the axes
  are, not what should be in each cell.
- If the project name ever stops being self-computed, the compose location
  becomes load-bearing rather than merely conventional, and this record's first
  reason gets stronger rather than weaker.
