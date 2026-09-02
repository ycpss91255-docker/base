# Documentation is derived from code, never duplicated beside it: test statistics live only in the release

> Serves: PRD invariant 10 (documentation is derived, not duplicated) --
> this is the decision that established it, and the first place it is
> applied. Also invariant 2 (never fail silently): a figure that is
> maintained by hand goes stale silently, and a catalogue 46% of whose
> descriptions are placeholders looks authoritative while saying nothing.

- **Date:** 2026-09-02
- **Status:** Accepted
- **Relates to:** **#922** (the catalogue Description column this
  supersedes -- the question "is the column required, optional or
  dropped" is answered here by removing the table it lives in); **#924**
  and PR **#943** (the hand-built release archive that PR deleted -- the
  reason recorded there is narrower than it reads, see sec. 4);
  **#952** (the coverage figure in the release -- an open sibling case
  whose branch currently contradicts this record, see sec. 3);
  ADR-00000018 (the ISTQB taxonomy whose level directories the report
  groups by); ADR-00000027 (release cadence -- this rides the release
  commit that cadence already produces); docker_harness **#287** (the
  mechanical merge conflict this removes the cause of).

## Context

`doc/test/TEST.md` and `doc/test/unit.md` carry two kinds of content, and
only one of them is written by a person. Every figure below was measured
against this repo on 2026-09-02 and names the command that reproduces it.

**Derived content.** A grand total (`Template self-tests: **3239 tests**
total (3090 unit + 149 integration).`), a per-spec count
(`### test/bats/unit/lib_spec.bats (54)`), and a table with one row per
`@test` listing that test's name. Every one of these is
`grep -c '^@test'` or a copy of a string already in a `.bats` file.

**Authored content.** One prose paragraph per spec file saying what that
file covers and why it is tested the way it is. No generator writes that
paragraph -- but it is not independent of the source either: in this repo
most of it restates the spec file's own header comment. The reason
`transcript_lnav_spec` checks the lnav format structurally with `grep` --
that the CI image ships no jq or lnav -- is stated in both
`test/bats/unit/transcript_lnav_spec.bats` and `doc/test/unit.md`. What
separates the two halves is therefore not novelty but derivability: a
generator can produce the counts and the table exactly, and can produce
neither paragraph. Whether the prose should in turn move into the spec
headers it echoes is a separate question, and is not decided here.

The derived half cost more than it returned, measured rather than
asserted:

**The grand total is five lines that every branch must edit.**
`TEST.md:3`, `TEST.md:7`, `TEST.md:23`, `TEST.md:29` and `unit.md:3`
(`grep -n '3239\|3090' doc/test/*.md`). Adding one test changes all
five, so two branches that each add a test collide there. Replaying
every merge of `origin/main` into a branch since 2026-08-25 with
`git merge-tree --write-tree --name-only`: of 65 such merges, 61
conflicted, and all 61 conflicted in `doc/test/` -- 50 of them there and
nowhere else. Over the same window 35 commits touched nothing outside
`doc/test/`, 23 of them carrying the identical subject
`docs(test): re-sync the suite counts after merging origin/main`.
docker_harness#287 -- an issue asking for the mechanical conflict to be
auto-resolved -- exists only because of these five lines.

**The per-test table duplicates the `.bats` files.** `unit.md` carries
1,981 table lines, of which 1,658 are per-test rows whose left column is
copied from the spec file. The right-hand Description column is
hand-written, and **761 of those 1,658 rows (46%) hold the placeholder
`-`** (`grep -c '| - |$' doc/test/unit.md`). Where it is filled it
usually restates the test name (`_lib.sh is idempotent when sourced
twice` -> `Double-source guard`). The table is also not an index of the
suite: 104 sections cover the unit specs, 74 with a
`| Test | Description |` table, 12 with a hand-made `| Category | Tests |`
grouping and 18 with prose alone, so 1,658 rows stand against 3,090 unit
`@test`s -- 54% of the suite has a row and the rest has none. Which
shape a section gets is a documented editorial choice (`unit.md`, "How
this catalogue is maintained"), so the unevenness is deliberate; what it
costs is that no reader can use the table to answer "what is tested".

**The counts describe the tree, and a person is asked to keep them true.**
`check_test_md_drift.sh` re-derives every figure on every run and fails
the gate when the committed docs disagree -- which is what forces every
branch to run `just test sync-docs` and produce the resync commit. The
checker is correct; it is the storage that is wrong.

## Decision

**Documentation is derived from the code, not duplicated beside it.**

A figure or a listing that can be computed from the tree is computed when
it is needed. It is not stored in a tracked file that a person, a hook, or
a gate must then keep in agreement with the tree. Prose that a machine
cannot derive -- intent, rationale, the reason a check is shaped the way
it is -- is authored, and it is the only thing a documentation file
should hold.

This is the living-documentation position: documentation is extracted
from the code and the tests rather than duplicated into a separate
document, so it cannot drift out of agreement with them.

The corollary that decides where the numbers go: **a derived figure stored
in the tree is stale from the moment the next commit lands.** Storing it
at a slower cadence than it changes does not fix that -- it only makes the
staleness harder to notice. So it is not stored at a slower cadence; it is
not stored at all.

### 1. No test statistic is committed to the tree

The five grand-total lines and the 1,658 per-test rows leave
`doc/test/*.md`, together with the table scaffolding around them --
1,981 table lines in `unit.md` in total. The per-spec count in each
`### <path> (N)` heading goes with them: it is the same class of figure,
and keeping it would reintroduce the sync step this removes.

What remains in `doc/test/*.md` is the authored prose -- one section per
spec file, saying what it covers and why -- with no number in it.

`check_test_md_drift.sh` and the count half of `sync-doc-counts.sh` are
removed with the figures they served. Nothing in a branch's normal work
touches `doc/test/` any more, so the file stops being a merge surface.
PRD invariant 2 lists the doc-count drift gate among the guards that
establish it; that one entry drops from invariant 2 when this mechanism
lands, and the invariant itself is untouched.

### 2. Test statistics exist only in the release, and come from the run

A tag push already runs the full suite. `classify` returns
`code_changed=true` and `system_relevant=true` unconditionally for any
non-`pull_request` event, and the `release` job in `self-test.yaml`
needs `shellcheck`, `doc-counts`, `lint-static`, `hadolint`,
`bats-fragile`, `bats-integration`, `coverage`, `acceptance`, `system`
and `worker-selftest`, so all of them have finished before the Release
is created. Unit specs run inside the sharded `coverage` matrix and in
`bats-fragile`; there is no job named `unit` or `integration`. The
release gate is already what the industry calls a quality gate; what was
missing was collecting its result.

So the report is **the output of that run**, not a scan of the source:

- each test job emits JUnit XML (`bats --report-formatter junit -o <dir>`,
  which bats supports natively and which `script/test/drivers/bats.sh`
  already runs to collect per-spec timings) and uploads it as an artifact;
- the `release` job collects every artifact, merges them, and renders a
  per-suite summary into the Release body;
- the merged JUnit XML is attached to the Release as an asset, so the
  per-test detail is available to a machine without putting 1,981 lines
  in front of a human.

**Why the run and not the source.** Counting `@test` in the tree yields a
name and a number. The run yields pass / fail / skip, duration, the
failure message, and the suite structure -- and it cannot disagree with
reality, because it *is* reality. It also needs no maintenance: the test
framework produces it.

**Why JUnit XML and not CTRF.** CTRF describes itself as an open standard
for JSON test reports and publishes a schema, which JUnit XML -- a
de-facto format with no owning specification -- has never had. That is
the case for preferring CTRF eventually. It is not preferred now because
bats emits JUnit natively and this repo already consumes it, while CTRF
would need a conversion layer and nothing here aggregates across tools
yet. JUnit XML now; CTRF when a second producer appears.

### 3. There is no information gap, because there is nothing to be stale

The alternative considered and rejected was to keep the total in
`TEST.md` and let only the release commit write it. That removes the
conflict but creates a worse property: `main` would show the previous
release's figure while carrying a different one, and a reader has no way
to see which. A number that is *sometimes* right is harder to use than no
number, because it must be distrusted every time.

Removing it entirely means the only place a test statistic appears is the
place where it was measured, attached to the artifact it describes.

There is a live counter-example inside the repo, named here so it is not
missed. #952 is open, and its branch `feat/952-coverage-badge` commits
`doc/badge/coverage.svg`: a figure derived from a coverage run, written
into a tracked file and refreshed at release cadence. That is the
arrangement this section rejects. Which shape the coverage figure ends up
taking is #952's call and not this record's; what this record settles is
that the two cannot both stand.

### 4. What PR #943 actually decided

PR #943 (closing #924) deleted the `release` job's whole "Create release
archive" step -- the `mkdir` / `cp -r` / `tar` / `zip` -- and with it the
`files:` input that attached the result. Read as a blanket rule against
release assets it would forbid this decision's XML asset, so the
distinction is recorded here.

What #943 removed was a **hand-built source archive that GitHub already
produces** -- a strictly worse subset of the tarball GitHub attaches to
every release, assembled from a hardcoded nine-operand `cp -r` list that
had silently omitted seven of the sixteen tracked top-level entries,
`.version`, `CONTEXT.md` and the repo-root `init.sh` among them
(measured at `db264975`, the last commit before #943 landed), because
`cp` says nothing about a path nobody listed. The related failure where a
multi-operand `cp -r` under `bash -e` lost a release outright, twice,
belongs to the downstream archive #914 replaced with a declared manifest
-- a different artifact, which #943 explicitly left alone. #943's
objection is to duplicating an artifact the platform already provides.

A JUnit XML report is not something GitHub produces. It is evidence of
the run, it exists nowhere else, and attaching it therefore duplicates
nothing. One consequence has to be stated rather than discovered: #943
also wrote into `README.md` that a base release carries GitHub's source
archives "and no other asset". That sentence is amended when this
decision's mechanism lands, so that the two records reconcile instead of
contradicting each other.

## Consequences

**A branch stops touching `doc/test/` unless it changed the prose.** The
61-conflicts-in-65-merges rate and the 35 commits per cycle whose entire
content is `doc/test/` both go away. docker_harness#287 can be closed as
no-longer-reachable rather than implemented.

**#922 is answered by removal.** The question was whether the Description
column is required, optional or dropped. The table it belongs to is
deleted, so the column has no owner to under-serve: 46% placeholders
become zero rows.

**The per-test listing improves rather than disappears.** It stops being
a 1,658-row hand-synced table that covers 54% of the suite and records
what the tests are *called*, and becomes a machine-readable record of
what every test *did*, per release, permanently attached to the tag it
describes.

**A reader of `main` cannot see a test count.** This is deliberate. The
count of a moving branch has no stable meaning, and the previous design
answered the question with a figure that was wrong between every commit
and its resync. Someone who needs the number for the working tree runs
`just test`; someone who needs it for a version reads that version's
release.

**The prose becomes load-bearing.** With no table beneath it, the
paragraph per spec file is the whole of `doc/test/`. It must say why the
file exists and why it tests the way it does -- which is what it already
does well, and is the half no generator can write.

## Alternatives

**Keep the total, update it only at release.** Rejected in sec. 3: it
trades a merge conflict for a figure that is silently wrong most of the
time.

**Auto-resolve the conflict with a git merge driver.** A `.gitattributes`
driver could regenerate the count during a merge. It removes the conflict
but not the cause, needs a `git config` line in every clone (a driver
cannot be committed), and silently degrades to a conflict in a fresh clone
that has not run it. It also leaves the figure still needing to be right
in every commit.

**Move the counts to an orphan branch.** An append-only metrics branch
never conflicts with `main`. Rejected because it is unnecessary here: the
tests are already in git at every commit, so any historical figure is
derivable with `git grep -c '^@test' <rev>` without storing anything, and
each release's report is attached to its own tag. A second store would be
a second thing to keep true.

**Move the per-test descriptions into the `.bats` files and generate the
table.** This satisfies the principle and is a reasonable end state. It is
not taken now because the table adds nothing over the test names it
copies -- the evidence is the 46% that nobody filled and the near-synonyms
among those that were. Deleting is cheaper than relocating, and if a
per-test description turns out to be wanted later it belongs beside the
test, not in a document.
