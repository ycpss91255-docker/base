# The tooling image is obtained by one script every job calls, not published by one job every job waits for

> Serves: PRD invariant 2 (never fail silently) -- a job that cannot tell
> whether its image corresponds to its checkout must not report on the run;
> and invariant 4 (fail-safe defaults -- an image that cannot be verified is
> rebuilt, never used).

- **Date:** 2026-09-04
- **Status:** Accepted
- **Relates to:** issue **#1010** (the defect this answers, and the
  different remedy it proposed), ADR-00000008 (the sharded coverage gate
  whose eight shards are the jobs the artifact alternative would have
  serialised), ADR-00000018 (ISTQB levels -- why `acceptance` is a distinct
  job from `system`, which is why it was a distinct copy)

## Context

Six jobs of `self-test.yaml` run inside
`ghcr.io/ycpss91255-docker/test-tools`. A pull request that leaves
`dockerfile/Dockerfile.test-tools` alone pulls the rolling `:main` tag
rather than rebuilding a multi-arch image; `:main` is republished only by a
push to main that touches that file. So there is always a window, and after
a failed republish an open-ended one, in which a suite runs inside an image
that does not correspond to its own checkout.

The mitigation for that window was a block of shell pasted into each
consuming job: pull, re-tag under the run's name, probe the result, rebuild
from source if the probe refuses. Five copies did all four steps. The
sixth, `acceptance`, pulled, re-tagged and `exit 0`-ed.

That job is the one the mitigation was written for. It scaffolds a
downstream repo and runs `just docker build test`, whose lint stage is
`FROM ${TEST_TOOLS_IMAGE}`. The exclusion even had a written rationale --
"acceptance executes none of the baked tools, it only uses the image as a
`FROM` base" -- and the rationale was false: the stage that image becomes
runs those tools.

Nothing could have caught it. A test over the workflow could asssert "five
jobs probe" and be green with any five; a test naming the six would have
been a roster somebody had to keep. The defect was not in any copy. It was
that there were copies.

## Decision

**The provisioning decision is one script, `script/ci/obtain_test_tools.sh`,
and every consuming job calls it.** The script weighs the three ways to have
the image -- this PR changed the Dockerfile so `:main` is stale by
definition; `:main` corresponds to the checkout and is used; it does not, or
could not be pulled, and the image is built from source -- and always
probes what it pulled.

The two jobs whose buildx runs `driver: docker` pass `--local-build inline`
so the fallback build happens inside the call; the four whose build runs
through `docker/build-push-action` (for the GHA layer cache) pass
`delegate` and gate that step on the script's `build_local` output. That is
the only difference between the callers, and it is one word.

**The roster the probe asserts is derived from the Dockerfile's final
stage**, not restated: its packages from the stage's `apk add`, its binaries
from what the stage COPYs or symlinks into `/usr/local/bin`. A tool added to
the image is a tool the probe asserts, with nobody in the loop.

**The guard is that no workflow run block names the rolling tag at all.**
That is the assertion a copy cannot satisfy, whoever writes the seventh job.

## Alternatives

**Hoist obtain-and-probe into one job that publishes the image as an
artifact the consumers download.** This is what #1010 proposed, and it does
remove both defects at once -- there is one obtain, so there is no sixth
call site to forget. It was rejected on three counts.

It serialises. Fourteen consumers currently start as soon as `classify`
finishes; behind a publishing job they start after it, and the eight
coverage shards ADR-00000008 exists to parallelise are the ones that wait.

It cannot serve the two-arch `acceptance` matrix from one artifact. That
job runs on `ubuntu-latest` and `ubuntu-24.04-arm`, so the artifact job
becomes a matrix too, and the "one obtain" it was bought for is two.

And it is slower on the hot path even ignoring both. `docker save` of this
image, an upload, and a `docker load` per job replaces a GHCR pull that
runs against a warm registry -- for an image whose whole point is that it
is already published.

**Declare the roster explicitly but assert it against the Dockerfile in a
test.** A test comparing two lists keeps both, and the failure lands on
whoever next edits the Dockerfile rather than on the code that was wrong.
Deriving has one list and no failure to route.

**Keep the copies and add a lint that every consuming job probes.** The
lint has to know which jobs consume the image, which is the roster problem
again one level up. It also leaves five copies of a decision that will
diverge in some other dimension next.

## Consequences

The seventh consuming job gets the probe by construction: there is nothing
to remember, and a hand-rolled pull fails the suite by name.

The probe now starts two containers per call instead of five to eight (one
package check, one binary check, plus the pinned-version reads), so the
wider roster costs less than the narrow one did.

A tool added to the Dockerfile immediately becomes something every pulled
`:main` is asserted to carry. Between that commit and the republish, every
job takes the from-source build. That is the intended cost -- it is what
"the image corresponds to this checkout" means -- but it is a real one, and
it lands on the merge that adds the tool rather than on a later PR.

The Dockerfile's final stage is now load-bearing text: a package moved into
a builder stage, or a binary installed somewhere other than
`/usr/local/bin`, changes what the probe requires. The reader is comment-
stripped and stage-scoped for exactly that reason, and both properties are
asserted in `probe_test_tools_spec.bats` rather than left to hold by
accident.
