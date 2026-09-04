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
  **#952** (the coverage figure in the release -- the sibling case that
  fixes where the line falls, merged as PR #974, see sec. 3);
  ADR-00000018 (the ISTQB taxonomy whose level directories the report
  groups by); ADR-00000027 (release cadence -- this rides the release
  commit that cadence already produces); docker_harness **#287** (the
  mechanical merge conflict this removes the cause of); **#1024** (the
  amendment below: a bound stored in a driver is a derived figure too).

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

The corollary that decides where the numbers go: **a derived figure that
describes the tree is stale from the moment the next commit lands.** Storing
it at a slower cadence than it changes does not fix that -- it only makes the
staleness harder to notice. So it is not stored at a slower cadence; it is
not stored at all.

What that turns on is the referent, not the storage. A figure that names the
thing it measured -- a coverage rate labelled with the version it was measured
on -- does not describe the moving tree and cannot go stale, so it may be
stored. Section 3 works this through on the case that forced it.

### 1. No test statistic is committed to the tree

The five grand-total lines and the 1,658 per-test rows leave
`doc/test/*.md`, together with the table scaffolding around them --
1,981 table lines in `unit.md` in total. The per-spec count in each
`### <path> (N)` heading goes with them: it is the same class of figure,
and keeping it would reintroduce the sync step this removes.

What remains in `doc/test/*.md` is the authored prose -- one section per
spec file, saying what it covers and why -- with no number in it.

**Amendment (#999, 2026-09-03): the per-test table is KEPT and GENERATED;
the removal of the five grand-total lines stands.**

The decision this section records is that a listing a machine can produce
must not be stored where a person has to keep it true. Deleting the table
was one way to satisfy that. Generating it from the code is another, and
it is the one taken: the per-test descriptions moved into the `.bats`
files as `# why:` marker blocks on the lines above each `@test`, and
`sync-doc-counts.sh` renders `doc/test/*.md` from them into an explicitly
fenced region that is replaced wholesale on every run. Nothing reads a
description back out of the catalogue.

What that changes about this record, precisely:

- The **five grand-total lines** and the per-spec `### <path> (N)` count
  are untouched by this amendment. They are still a figure about a moving
  tree with no referent, they still cost 61 conflicts in 65 merges, and
  §1's decision to remove them stands.
- The **per-test table** is not that. Its rows are no longer stored beside
  the code they describe -- they are derived from it, on every run, and a
  row deleted from the document is restored byte-for-byte by the next one.
  It costs nobody a sync step, so the reason to delete it is gone.

Why the reasoning under "Alternatives" flipped. The last alternative below
already named this end state and called it "a reasonable end state",
declining it on one ground: that the table adds nothing over the test
names it copies, evidenced by the 46% of rows nobody filled and the
near-synonyms among the rest. That evidence measured the wrong thing. Both
symptoms were caused by WHERE the description lived: a row in a
4000-line document, reachable only after running a generator, which a
rename silently emptied (the catalogue documented that loss as a rule).
With the sentence authored on the line above the test the author is
already writing, the cost of filling one falls to nothing and a rename
carries it. Deleting was cheaper than relocating only while relocating
meant hand-relocating; #999 relocated 1209 descriptions and 106 section
blurbs with a script, and proved by set comparison that none was lost or
invented.

The consequence recorded below -- "**#922 is answered by removal**" -- is
therefore answered by RELOCATION instead. The Description column is
required, at its new site, under a transition ceiling that is one number
in `script/test/drivers/catalog_description.sh` and no roster.


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

The coverage badge is the case that shows where the line falls, and it landed
while this record was being written. #952 merged as PR #974 on 2026-09-02 and
commits `doc/badge/coverage.svg`: a figure derived from a coverage run,
written into a tracked file and refreshed at release cadence. Read against the
paragraph above it looks like the arrangement this section rejects. It is not,
and the reason is the discriminator this record needs:

**A derived figure may be stored when it names what it measured.**

`doc/badge/coverage.svg` renders `coverage v0.42.0: not measured` -- the
version is inside the artefact, and `coverage_badge_spec` asserts it matches
the current `.version`. So the badge is not a claim about the working tree
that goes stale; it is a claim about v0.42.0, and it stays true forever. The
objection above -- "a reader has no way to see which" -- has no purchase,
because the artefact answers it. The five grand-total lines had no referent:
`3239 tests` asserted something about *the tree*, which is why it was wrong
between every commit and its resync, and why every branch had to edit it.

The two costs separate the same way. The counts had a merge surface of 61
conflicts in 65 merges and a gate that forced every branch to run a
regenerator. The badge is written by one commit per release and by nothing
else, so it has no merge surface at all.

What does not survive review is the badge's *cadence enforcement*, and it is
recorded here because it is invariant 2's failure mode rather than this
record's. `script/release/justfile.release` states that the write is a
hand-run step today -- the bump that should call it lives in the harness repo,
tracked as docker_harness#289 -- and that forgetting it "is caught by
coverage_badge_spec ... but only after the tag, as a red main". A guard that
fires after the artefact it guards has shipped is a late failure, not a
prevented one. Storing the figure is fine; requiring a person to remember to
write it is not.

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

### Amendment (#1024, 2026-09-04): a BOUND is a derived figure too, and derived here means down-only

This record's rule is about statistics -- a figure describing a moving
tree, kept by hand, going stale between every commit and its resync. A
number that is a **bound** rather than a description was not in view, and
one arrived afterwards: the description lint's undescribed-test ceiling
(#999), a single `readonly` in `script/test/drivers/catalog_description.sh`
that the lint fails above.

It reproduced this ADR's defect under a different name. The policy is
down-only, so every branch that describes a test has a correct reason to
lower it; every branch therefore edits the same line, and every merge
conflicts on it -- the 61-conflicts-in-65-merges shape, one figure
instead of five. Worse, the conflict's correct resolution is **neither
side**: descriptions compose, so two branches lowering to 2617 and 2614
merge into a tree that measures 2609. It was landed wrong twice in one
cycle.

**The amendment: the ceiling is generated output.**
`script/test/sync-doc-counts.sh` writes it in the run that writes the
catalogues, from the same spec tree; the drift gate compares it; the
merge resolver recomputes it. That is a category change this ADR has to
say out loud, because it is the first time a **driver's constant** is
generated rather than a document: the rule "documentation is derived"
generalises to "a figure about the tree is derived, wherever it is
stored", and a `.sh` file is a place a figure can be stored.

**What does NOT generalise, and it is the reason a bound is not a
statistic.** A generator that writes whatever it measures turns a ratchet
into a mirror, and a lint that mirrors the tree bounds nothing. So the
write is one-directional in the other sense too: a measurement lower than
the record replaces it, a measurement higher leaves the record alone and
the breach reaches the lint. Raising the number stays a deliberate hand
edit in a reviewable diff, and a merge cannot raise it as a side effect.

#999's reasoning is untouched by this. "One number, not a roster of
per-test exemptions" was the choice, and it still is; what moved is who
writes the one number, not how many there are.

## Alternatives

**Keep the total, update it only at release.** Rejected in sec. 3: it
trades a merge conflict for a figure that is silently wrong most of the
time.

**(#1024) Store the ceiling where merges do not collide** -- a one-line
file with a `.gitattributes` merge driver whose resolution is "recompute".
Rejected on the same ground as the driver alternative below: it is
machinery nobody here has, invisible until it misfires, and it would
duplicate a recomputation the doc generator already performs.

**(#1024) Do not store the ceiling at all** -- fail when the undescribed
count exceeds the count at the merge base. Rejected: it needs a base ref
at lint time, which the container does not reliably have, and a lint whose
verdict depends on how much history was fetched is worse than no lint.

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

> **Amendment (#999, 2026-09-03):** this alternative was TAKEN. See the
> amendment in sec. 1 for why the evidence above measured the storage
> site rather than the table, and what the relocation cost in practice.
