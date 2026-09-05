# Shard kcov coverage + promote it to an enforced PR gate

> Serves: PRD invariant 7 (rigorous test bar) -- the coverage gate; a
> swappable mechanism, not the invariant.

- **Date:** 2026-06-24
- **Status:** Accepted
- **Amends:** #377 (which made coverage a non-gating, main-push-only
  metric)
- **Relates to:** #615, #613 (kcov env bugs fixed first so the gate is
  not flaky), ADR-00000004 / ADR-00000012 (test layout the shard
  partition walks)

## Context

#377 parallelised the normal test path (GNU `parallel --jobs N` inside
`_run_bats`; `bats-unit` split into a 1/N CI matrix) but left the
**coverage path fully serial**: a single
`kcov ... bats test/bats/unit/ test/bats/integration/` with no `--jobs`
and no matrix shard. The ~8-12 min coverage runtime was therefore
"serial x kcov" (kcov instruments every line and slows bats 2-5x), not
an inherent kcov floor.

#377 sidestepped that cost by making coverage **main-push-only** and
**explicitly non-gating** ("metric, not a gate"):

- `coverage` ran only on `push && ref == refs/heads/main`.
- It was deliberately kept out of `ci-rollup`'s `needs:`.
- Branch protection required only `ci-rollup`; the `codecov/project`
  status was not a required check; kcov never ran on PRs, so there was no
  PR coverage data to check.

Net effect: neither a coverage regression nor a kcov failure could block
any merge. #613 then found and fixed real kcov-env test bugs that had
been making the coverage job intermittently red — clearing the
precondition for letting coverage gate at all.

## Decision

### 1. Shard the kcov run across a CI matrix mirroring `bats-unit`

The `coverage` job becomes a `strategy.matrix` of kcov shards
(`shard: ['1/4', '2/4', '3/4', '4/4']`, `fail-fast: false`) that mirrors
the `bats-unit` matrix. Both matrices select their slice through one
shared primitive, `_shard_unit_files <n>/<total>` (round-robin over
`find test/bats/unit -name '*_spec.bats' | sort`), so coverage shard *k*
kcov's the **identical unit slice** the unit-test matrix runs. The 87
integration specs run on the **last shard only** (not every shard), so
no slice is kcov'd more than once.

Plumbing: a new `test.sh --coverage-shard N/T` flag sets coverage mode
and forwards `COVERAGE_SHARD` into the coverage container, where
`_run_coverage <n>/<total>` wraps kcov over that slice. Bare
`test.sh --coverage` (and `just test coverage`) keeps the full-suite path
for local / release use; `just test coverage 1/4` runs a single shard
locally. The coverage path also **skips the lint phase** unconditionally
(lint is measured by the dedicated lint jobs, so running it once per
coverage shard would be wasted work).

> Amendment (#686): the coverage container is no longer the upstream
> `kcov/kcov` Debian image — kcov is now source-built into the shared
> Alpine `test-tools` image, so the coverage matrix runs on the same
> pre-baked image as `bats-unit` (no per-shard apt-install). This is an
> environment change only; the sharded-matrix + `codecov/project` gate
> MECHANISM this ADR records is unchanged.

Per-shard wall-time lands in the `bats-unit` ballpark (~one shard,
~170s) and runs in parallel with `bats-unit`, so the added PR
critical-path cost is roughly one shard, not the old 8-12 min serial job.

### 2. Merge the shard reports via Codecov

Each shard uploads its partial report (`directory: ./coverage`) under a
distinct `flags: coverage-shard-<index>`. Codecov natively merges
multiple uploads for a commit ("Found N coverage files to report") into
one project coverage figure, so where a slice runs in the matrix does not
affect the merged total — only that every slice runs exactly once
(guaranteed by the exhaustive + disjoint round-robin partition).
`fail_ci_if_error: false` stays: an upload transport hiccup must not fail
a shard; the merge tolerates a missing shard and the *gate* is the
Codecov status, not the upload step.

### 3. Promote coverage to an enforced PR gate

- The `coverage` job now gates on
  `needs.classify.outputs.code_changed == 'true'` (the same output as the
  other PR-check jobs), so it **runs on PRs**, producing PR coverage
  data. The old `if: push && ref == refs/heads/main` is removed.
- `coverage` joins `ci-rollup`'s `needs:` (now 9 jobs), and the rollup
  verifier consumes `needs.coverage.result` with SKIPPED-as-pass for
  doc-only PRs. A **kcov test failure** therefore fails the matrix,
  fails `ci-rollup`, and blocks merge.
- A **coverage regression** is enforced via the `codecov/project` status
  configured in `.codecov.yaml` (`informational: false`), added as a
  required branch-protection check alongside `ci-rollup`.

### 4. Threshold choice

`.codecov.yaml`:

```yaml
coverage:
  status:
    project:
      default: { target: auto, threshold: 1%, informational: false }
    patch:
      default: { target: auto, threshold: 1%, informational: false }
```

- **project** `target: auto` compares against the PR base; `threshold:
  1%` absorbs kcov line-hit noise (the #613 fixes removed the spurious
  reds that previously plagued this path). `informational: false` makes
  the status fail on a real drop so branch protection can block.
- **patch** (new-code coverage) is decided explicitly as `target: auto`
  + `threshold: 1%` rather than a fixed percentage (e.g. 80%). The
  codebase has many intentionally-uncovered bash branches (`case ;;`
  arms, `/lint` fallback blocks, child-bash guards); a fixed patch target
  would make refactor PRs flaky — the exact #613-class brittleness this
  gate must avoid. `auto` keeps the patch status honest (new code should
  not be markedly less covered than the project) without false reds.

## Consequences

- A coverage regression or a kcov failure now blocks PR merge, raising
  merge confidence; this reverses #377's "coverage is a non-gating
  main-only metric" posture.
- GHA-minute cost rises: kcov now runs on every code-touching PR as a
  4-shard matrix instead of only on main push. Accepted — the per-shard
  wall-time is in the `bats-unit` ballpark and runs in parallel, so PR
  feedback latency barely moves while merge confidence improves.
- The coverage matrix and the unit matrix are now coupled through
  `_shard_unit_files`: changing one shard count without the other would
  desynchronise the slices. Documented in the helper; both default to 4.
- The gate's robustness depends on the #613 kcov-env fixes staying in
  place; if kcov flakiness returns, raise the project `threshold` before
  reverting the gate.

## Alternatives

- **Keep coverage main-only + non-gating (#377 status quo).** Rejected:
  it leaves coverage regressions and kcov breakage invisible until after
  merge; #613 already cleared the flakiness that justified the
  non-gating posture.
- **Single (un-sharded) coverage job on PRs.** Rejected: the 8-12 min
  serial kcov run would dominate PR wall-time, the cost #377 set out to
  avoid; sharding brings it down to ~one bats-unit shard.
- **A fixed patch target (e.g. 80%).** Rejected: the intentionally
  uncovered bash branches make a hard per-diff percentage flaky for
  refactor PRs; `target: auto` tracks the project rate instead.

## Amendment (#710): self-hosted, GitLab-portable gate; Codecov removed

- **Date:** 2026-06-25
- **Amendment status:** Accepted -- supersedes the Codecov merge +
  `codecov/project` status decided in sections 2 and 3 above.
- **Resolves:** #709 (`codecov/project` is Pro-only, so the project gate
  never worked on the free plan). **Relates:** #678 (no Codecov status to
  wire -- the gate moves into `ci-rollup` directly), #686, #677.

### Context

This repo is being imported into the company GitLab, where Codecov is
unavailable and uploading coverage to an external SaaS is data leakage.
Separately, #709 found `codecov/project` is a Pro-only status, so the
section-3 branch-protection gate never actually enforced anything on the
free plan. Both push the same way: drop Codecov entirely and enforce the
coverage floor locally, with a mechanism that ports to GitLab CI
unchanged.

### Decision

1. **Remove Codecov.** The `codecov/codecov-action` upload step, the
   `CODECOV_TOKEN` usage, the no-op `flags: coverage-shard-N`, and
   `.codecov.yaml` are deleted. No coverage data leaves CI.

2. **Self-hosted merge + floor gate.** kcov already writes a
   `cobertura.xml` per shard whose root `<coverage>` element carries
   `lines-covered` / `lines-valid`. A new CI-agnostic script,
   `script/test/drivers/coverage_gate.sh`, MERGES the per-shard reports
   into one project line-rate by SUMMING `covered` and `valid` across
   shards -- `SUM(covered) / SUM(valid)`, a line-weighted total -- and
   exits non-zero when it is below `COVERAGE_MIN`. It does NOT average the
   per-shard `line-rate` attributes: shards have different denominators
   (integration runs on the last shard only), so averaging would weight a
   small shard equally with a large one and report a wrong total. The
   script reads files and sets an exit code with no GitHub/GitLab
   coupling, so it gates identically under both.

3. **Threshold = v1 absolute floor.** `COVERAGE_MIN` defaults to **50**
   (percent, env-overridable), set just below the current measured
   project rate (~52.9%) so it does not false-fail today. It is meant to
   **ratchet up** as coverage improves. v2 (a follow-up, NOT built here)
   is regression-vs-main-baseline: store/fetch main's coverage % and fail
   on a drop beyond a threshold -- the original #615 intent. v1 keeps it
   simple with no baseline storage.

4. **Wired through `ci-rollup`.** Each coverage shard uploads its kcov
   report (HTML + cobertura) as a CI artifact (`actions/upload-artifact`,
   keyed by `strategy.job-index`). A new `coverage-gate` job downloads
   every shard artifact (`actions/download-artifact`, `pattern:
   coverage-shard-*`) and runs `coverage_gate.sh` over the merged set.
   `coverage-gate` joins `ci-rollup`'s `needs:` (which branch protection
   already requires), so a sub-floor rate blocks merge with **no
   branch-protection change** and no external SaaS.

5. **Visibility without SaaS.** kcov's HTML + cobertura are kept. On
   GitHub the gate appends a coverage summary table to
   `$GITHUB_STEP_SUMMARY` (built-in, free). Publishing the kcov HTML to
   GitHub Pages is a documented follow-up (deferred to keep this slice
   small).

### GitLab portability mapping (for the future move; mechanical)

The gate script stays CI-agnostic; only the job wrapper changes:

- **MR diff annotations:** point GitLab at kcov's cobertura via
  `artifacts: { reports: { coverage_report: { coverage_format:
  cobertura, path: coverage/**/cobertura.xml } } }`.
- **MR coverage % widget / badge:** add a `coverage:` regex on the
  coverage job, e.g. `coverage: '/merged line rate ([0-9.]+)%/'`, which
  matches the line `coverage_gate.sh` prints to stdout
  (`coverage_gate: merged line rate <N>% ...`).
- **The floor gate itself** is unchanged: GitLab runs the same
  `bash script/test/drivers/coverage_gate.sh coverage/**/cobertura.xml`;
  a non-zero exit fails the pipeline (the merge gate), exactly as the
  GitHub `coverage-gate` job does.

### Consequences (amendment)

- No coverage leaves CI; the gate is enforceable on any plan (the #709
  Pro-only blocker is gone) and ports to GitLab by editing the job
  wrapper, not the gate logic.
- The line-weighted merge is the load-bearing detail; it is unit-tested
  in `test/bats/unit/coverage_gate_spec.bats` (floor pass/fail, the
  sum-not-average math with unequal denominators, and missing/empty/
  malformed report handling).
- The section-2 Codecov merge and the section-3 `codecov/project` status
  are SUPERSEDED; the section-1 sharding and the "coverage is a gating PR
  check via `ci-rollup`" posture remain.

## Amendment (#724 / #725 / #730): shard count is dynamic, the partition is time-balanced, the merge is a per-line union

The section-1 sharding evolved to compress the PR critical path further
without weakening the gate (coverage stays a required PR check):

- **Dynamic shard count (#725).** The matrix is no longer the hardcoded
  `['1/4'..'4/4']`. A `compute-shards` job emits `["1/N",...,"N/N"]` from
  `vars.CI_SHARDS` (default 8, clamped [1,12]); the coverage matrix consumes
  it via `fromJSON`. The count is a repo variable because "shard to runner
  count" is not runtime-detectable on GitHub-hosted (parallelism is bounded
  by the plan's concurrent-job limit); it also generalises to self-hosted
  (set the var to the fleet size). `_shard_unit_files` / `--coverage-shard
  N/T` already accept any total T.

- **Time-balanced, integration-pooled partition (#724).** `_shard_unit_files`
  now partitions unit + integration specs in ONE pool (integration is no
  longer appended whole to the last shard, which made that shard the sole
  bottleneck -- measured 326s vs 87-192s for the others at 8 shards). The
  greedy-LPT weight moves from `@test` count to `_spec_weight` (recorded
  seconds from `SHARD_WEIGHTS_FILE`, else `@test` count as a graceful
  fallback). An automated timings source (so the seconds are real, not a
  count proxy) is a deliberate follow-up.

- **Per-line union merge (#730).** `coverage_gate.sh` now merges the shard
  cobertura reports by per-line UNION (a line is covered if ANY shard ran
  it; valid = distinct source lines), NOT `SUM(covered)/SUM(valid)` over the
  root counters. Every shard's kcov reports the whole tree, so source shared
  across shards was double-counted -- the SUM rate drifted DOWN with the
  shard count (4 shards ~52.9% passed; 8 shards 42.42% false-failed). The
  union is shard-count-invariant (real 8-shard data: 51.42%). This SUPERSEDES
  the section-"MERGE MATH" line-weighted SUM described above.

- **Self-maintaining real-runtime weights (#733).** The "automated timings
  source" the #724 bullet deferred. Each coverage shard runs `kcov ... bats
  --report-formatter junit`, and `_junit_to_timings` converts the per-file
  `<testsuite time=...>` entries into a `coverage/timings.tsv`
  (`<seconds> <basename>`) uploaded in the shard artifact. The coverage-gate
  job (which already downloads every shard artifact) merges them via
  `coverage_gate.sh --merge-timings` and, on main-branch pushes only,
  `actions/cache/save`s the result; every run `actions/cache/restore`s it to
  the in-repo `test/bats/.shard-weights` path `_spec_weight` reads by default,
  so the partition self-balances by REAL seconds. PR runs are read-only (PR-
  runner noise never poisons the shared weights); a cache miss or a brand-new
  spec degrades to the `@test`-count fallback. This is the established
  best-practice shape: runtime-weighted greedy-LPT with a self-maintaining
  cached durations file -- cf. CircleCI ("timings-based test splitting gives
  the most accurate split ... the most recent timings data is always used"),
  Knapsack Pro (balance by time so every node finishes together), and
  pytest-split's `least_duration` (largest-first into the lightest group) fed
  by a stored `.test_durations`. The greedy-LPT partition is provably near-
  optimal: Graham (1969, SIAM J. Appl. Math. 17(2):416-429) bounds LPT
  makespan at `(4/3 - 1/(3m))` x optimal. The hard floor is the single
  longest spec FILE (whole-file granularity); splitting a hot file by example
  is a future refinement, not built here.

The "coverage is a gating PR check via `ci-rollup`" posture is unchanged.

## Amendment (#853 / #855): the floor is re-based to 80

Section 3 set `COVERAGE_MIN` to **50**, "just below the current measured
project rate (~52.9%)", and said it was meant to ratchet up. It is now
**80**.

The ratchet is not the whole story: the measurement itself was wrong. The
per-line union key of the previous amendment was the RAW `<class
filename>` kcov emits, and kcov reports one source file under several
prefix-truncated aliases, so every alias re-counted that file's lines
into the denominator. #853 canonicalises the filename before it becomes
part of the key, which moved the SAME suite from ~51% to **84.72%**
(`5907/6972` lines on `main`, run `30814141976`) -- the project rate had
been understated by roughly 33 points, and a 50 floor against an 85%
reality left about 35 points of dead slack in a required check.

80 leaves **4.72 points** of margin below the measured rate: wide enough
that ordinary per-PR churn does not false-fail the gate, narrow enough
that a real regression trips it instead of being absorbed. The v1
absolute-floor posture is unchanged -- this re-bases the number, it does
not adopt the v2 regression-vs-main-baseline gate, which remains the
documented follow-up.

## Amendment (#952): Decision 5's visibility half -- the figure is published per release, in the release commit

- **Date:** 2026-08-28
- **Amendment status:** Accepted -- completes the visibility half of the
  #710 amendment's Decision 5, which shipped the `$GITHUB_STEP_SUMMARY`
  table and deferred everything durable. **Relates:** #710 (Codecov removed,
  the dynamic badge with it), #709.

### Context

Decision 5 kept kcov's HTML and appended a summary table to
`$GITHUB_STEP_SUMMARY`. Both live for the length of one CI run. When the
Codecov badge was deleted, a **static** shields.io badge took its place:

```markdown
![Coverage](https://img.shields.io/badge/Coverage-Kcov-blueviolet?style=flat-square)
```

It reads `Coverage-Kcov` whatever the number does. The figure is computed
on every coverage run -- `coverage_gate.sh` prints `merged line rate <N>%`
and tabulates it -- and then discarded. A README that shows a badge nobody
can be wrong about is worse than one that shows nothing: it makes a reader
believe someone is watching.

### Decision

**The gate's line rate is rendered into a self-contained SVG committed to
the repo, stamped with the version it belongs to, and regenerated into the
release commit.**

*Status of the release step:* the generator and its refusals shipped with
this amendment; the automatic caller has NOT. Wiring it into the harness
release bump is `docker_harness#289` (see 4). Until that lands, the step
is `just release coverage-badge`, run by hand at bump time, and this ADR
says so rather than describing the end state as if it were built.

1. **A committed SVG, not an endpoint badge.** `doc/badge/coverage.svg` is
   plain markup with no external reference; the README draws it as
   `![Coverage](doc/badge/coverage.svg)`. The shields.io *endpoint*
   pattern (`img.shields.io/endpoint?url=raw.githubusercontent.com/...`)
   was considered and rejected twice over: it needs the repo to be
   **public**, because `raw.githubusercontent.com` will not serve a
   private repo to shields.io and shields.io cannot carry a token -- so it
   could never fan out to the mostly-private downstream repos -- and the
   URL binds to `raw.githubusercontent.com`, which is precisely the
   coupling class this ADR's #710 amendment removed. A committed SVG has
   neither problem and ports to GitLab as a file.

2. **The figure carries its version.** The badge reads
   `coverage vX.Y.Z | 84.7%`, never a bare percentage. The cadence is once
   per release (see 4), so a bare number would be read as the coverage of
   `main` and be wrong for the whole cycle -- the same failure as the
   static badge, differently dressed.

3. **The number comes from the gate's own merge math, re-run locally.**
   `script/release/coverage_badge.sh` SOURCES `coverage_gate.sh` and calls
   `_coverage_gate_run` over the kcov reports in `coverage/` -- the output
   of `just test coverage`. The per-line union and the path-alias
   canonicalisation of the previous amendments are not re-implemented, so
   the badge and the gate cannot disagree about what the project rate is.
   The alternatives were **reading the figure back out of the last CI run**
   (fast, but couples the release to one CI provider's API and to a run
   being findable for the exact commit) and **having CI publish the figure
   into the repo** (a commit per merge whose whole content is one digit).
   Recomputing costs a local kcov run before a release -- minutes, on an
   operation that happens a few times a month -- and costs no coupling at
   all: it is the same script, reading files, on a workstation or under
   either CI.

4. **It will be a step of the release bump, not a new mechanism -- and it
   is not one yet.** `.claude/scripts/release-bump.sh` in the harness
   already owns every mechanical release edit -- `.version`, the
   `[Unreleased]` promotion, the regenerated compare-link block. The badge
   **is to become** the fourth thing it regenerates, so that it rides the
   `chore: release vX.Y.Z` commit: **zero new commits**, no new trigger,
   and nothing anyone maintains by hand. That script's own header is the
   argument: the compare-link block stopped being updated around `v0.6.8`
   and ~90 releases rendered a dangling reference, because a hand-run step
   decays. A hand-maintained percentage would decay identically.

   That wiring could not ship here: `release-bump.sh` lives in
   `docker_harness`, a different repo, so this change can only offer the
   seam. It does -- a standalone script with the same `0` / `1` / `2` exit
   triple `release-bump.sh` itself uses -- and the wiring is
   `docker_harness#289`. **Until that issue lands the figure is one
   hand-run command** (`just release coverage-badge`, before the release
   commit is made), which is precisely the decay mode this decision argues
   against; the honest reading of the interval is that it is a known,
   tracked debt, not a completed mechanism. What it is NOT is silent:
   `coverage_badge_spec` asserts the committed badge names the current
   `.version`, so a release cut without the step turns `main` red.

5. **Refusal, never a carried-over figure.** A release whose coverage
   never ran must not publish a stale or an invented number. The generator
   writes nothing and exits 1 when there is no report under `coverage/`,
   when the reports **do not record the sha they were produced from** or
   that sha **is not `HEAD`**, when they **do not record that the whole
   suite produced them**, when a report is **older than the commit
   being released** (it measured an earlier tree), or when instrumented
   sources are **modified in the worktree** (the reports describe neither
   the commit nor the tree). The recorded sha is the load-bearing one:
   `just test coverage` writes it to `coverage/.head-sha`
   (`_stamp_coverage_head`), because comparing the report's mtime against
   `HEAD`'s commit time only catches reports that are too OLD. Measure
   `main`, check an older tag out, and every timestamp check passes over a
   clean worktree while the reports describe a different tree. The
   release edits themselves -- `.version`, the CHANGELOG, the badge --
   are deliberately not in that pathspec, so the check passes on a
   half-applied bump and fails on a code change.

   The sha alone was not enough, and the gap was reachable by an ordinary
   sequence. `just test coverage <n>/<total>` -- the recipe that proves
   the sharded path locally -- writes its slice into the SAME `coverage/`
   tree the full run uses. A stamp that recorded only the sha then
   certified a partition as `HEAD`'s measurement: matching sha, clean
   worktree, fresh mtimes, and a badge off by a factor of N. So the stamp
   records the SCOPE as well -- `scope=full` or
   `scope=partial <m>/<n> specs` on a second line, truncating any earlier
   stamp -- and the generator publishes only `full`. A stamp carrying no
   scope is refused too: unscoped is unknown, and unknown is not
   evidence. The sha answers WHICH tree; the scope answers WHETHER the
   whole suite ran, and the promise of this amendment needs both.

   **The scope is derived from the measurement, not from the
   invocation**, and that correction came after four attempts to fix it
   the other way. Read off the shard FLAG, the scope described the
   arguments rather than the reports, so every input that narrows the run
   without passing through that flag certified a partition as whole: an
   inherited `COVERAGE_SHARD`, an inherited `COVERAGE_PATH` (which the
   in-container dispatch reads first, and which makes the run write no
   report at all), and whichever selector `_run_via_compose` forwards
   next. Each round closed one door and the next round found another,
   because the inputs to an invocation are not an enumerable set. What
   was MEASURED is: `_measured_coverage_scope` compares
   `coverage/timings.tsv` -- the manifest kcov's bats writes, one line
   per spec file that ran -- against the tree's spec inventory, and a run
   narrowed by anything at all leaves fewer specs in it. The manifest is
   erased with the certificate before every run, so a run that writes no
   manifest ends with no stamp rather than with the previous run's. What
   remains enumerable is bounded and mechanically checked: the kcov
   selectors are the `-e NAME="${NAME:-}"` lines of `_run_via_compose`,
   read out of the source by a spec that fails until the coverage
   dispatch assigns each of them. `--unmeasured` renders
   `coverage vX.Y.Z | not measured` in grey: an explicit statement of
   absence, which is what the badge carried for `v0.42.0`, the last
   release cut before this mechanism existed.

### Cadence -- and why it is written down three times

**The figure refreshes once per release.** Not per merge: nobody acts on
52.9% becoming 52.8%, and a commit per merge whose entire content is one
digit fills `git log` with entries no one will read. "What is the coverage
of v0.43.0" is a fact about a shipped artifact, and that is the question a
README figure should answer.

A reader who does not know the cadence misreads the figure as current, so
it is stated where each kind of reader stands: **on the badge itself** (the
version is in the image), **here**, and **in the tooling** -- the
`coverage-badge` recipe doc in `script/release/justfile.release` and the
generator's own `--help`, both of which state the once-per-release cadence
and the ordering it implies (regenerate on the bump's working tree, before
the release commit; afterwards `HEAD` is no longer the measured commit and
the generator refuses).

The fourth place is the one that matters most and is **not written yet**:
the harness-side `.claude/commands/release.md` / `semver-bump` skill, where
the person cutting the release is actually reading. That lives in
`docker_harness` and is part of `docker_harness#289` along with the wiring.
Recording it as done here would be worse than the gap.

### GitLab portability mapping (mechanical, as above)

- **The badge**: unchanged. A committed SVG referenced by a repo-relative
  path renders in GitLab's Markdown exactly as in GitHub's; nothing
  external is involved.
- **The generator**: unchanged. It reads `coverage/**/cobertura.xml`, the
  same artifact GitLab's `coverage_report` consumes, and shells out only
  to `git` and `awk`.
- **The release step**: the bump is a workstation script in either world.
  Nothing in this mechanism reads a GitHub API, an artifact store or an
  environment variable that only one CI defines.

### Consequences (amendment)

- The README figure is now falsifiable: it names a version, and the number
  next to it was produced by the gate over that version's tree.
- A release now needs a local coverage run first, on the commit being
  released, or the generator refuses. That is the intended trade: the
  alternative to paying minutes is publishing a figure nobody measured.
- `just test coverage` now leaves `coverage/.head-sha` behind, carrying
  the sha and the scope (`full`, or `partial <m>/<n> specs`, derived from
  the run manifest `coverage/timings.tsv`). It is the only local evidence
  of which tree the reports describe and how much of the suite produced
  them; `just test clean` removes it with the rest of `coverage/`.
- A local shard run (`just test coverage 1/4`) can no longer be published
  as a release figure, at any commit. That is a refusal an operator can
  hit while doing nothing wrong -- checking the sharded path and then
  cutting a release -- and the cure is one full `just test coverage`.
- Until `docker_harness#289` lands, the regeneration is a hand-run step,
  and the guard against forgetting it is a red `main` after the tag rather
  than a refused bump. That is the known cost of the repo boundary, and it
  is tracked, not assumed away.
- `v0.42.0`'s badge says `not measured`, honestly: it was cut before this
  existed and no report for its tree survives. The first measured figure
  is `v0.43.0`'s.
- Publishing the kcov **HTML** remains Decision 5's other, still-deferred
  half; it has its own obstacle (Pages on a private repo needs a paid
  plan) and is out of scope here.

## Amendment (#726): coverage has TWO parallel modes -- hosted matrix and local in-job -- over one partition

- **Date:** 2026-09-05
- **Amendment status:** Accepted -- extends Decision 1. The sharded
  hosted matrix is unchanged and remains the PR gate. **Relates:** #724
  (the shared LPT partition both modes slice with), #725 (dynamic shard
  count), #730 (the union merge), #1060 (which measured where `bats
  --jobs` under one kcov holds and where it does not; this amendment is
  the remedy for the case it left serial), ADR-00000017 (the throughput
  ceiling this is measured against), ADR-00000026 (self-hosted
  eligibility is a static property of `runs-on`).

### Context

Decision 1 sharded kcov ACROSS a CI matrix. That is the only parallelism
a GitHub-hosted plan sells: one runner runs one job, so the way to use
eight machines is eight jobs.

Two things it does not cover. **On one fat machine the matrix buys
nothing** -- a single self-hosted runner takes the eight entries one after
another, so `CI_SHARDS` there is a way of making the same work slower.
And the run this repo needs MOST is one the matrix never touches: the
#952 amendment made `just release coverage-badge` publish only a
`scope=full` measurement, so every release pays for a whole-suite local
coverage run. That run was serial, and serial is not a kcov floor -- this
ADR's own Context says the cost is "serial x kcov". kcov's bash engine
parses one xtrace stream per traced process and is single-threaded, so N
concurrent bats jobs under ONE kcov all feed one parser. The #1060
amendment below measured where that costs accuracy and found a BOUNDARY
rather than a blanket: on a SHARD, parallel bats under one kcov reproduces
the serial covered set in seven of eight runs and misses 3 lines of 6207
in the eighth, so shards now run parallel; on the FULL SUITE it does not,
so the full-suite run stays serial. What is lost there is trace, not
execution -- the missing lines belong to subprocess-heavy specs whose
tests PASS -- so the bound is trace VOLUME through the one parser.

That bound does not reach **N independent kcov PROCESSES**: each traces
its own children into its own database, each parser reads only its own
slice's volume, and nothing is shared until the merge. This amendment is
the remedy for the case #1060 could not take -- it gives the full-suite
path the machine by removing the single parser, not by parallelising bats
behind it.

### Decision

**Coverage has two parallel modes. They differ in HOW the slices are
distributed, never in WHAT a slice is.**

1. **Hosted matrix (production, unchanged).** `test.sh --coverage-shard
   N/T`, one slice per GitHub-hosted job, merged by the `coverage-gate`
   job's per-line union over the shard artifacts. This is the PR gate.

2. **Local in-job.** `test.sh --coverage-local [--jobs N]` (default N =
   `nproc`; `just test coverage-local [N]`) runs EVERY slice of the same
   partition as N concurrent kcov processes inside one dispatch, and
   merges them with `kcov --merge` into `coverage/kcov-merged/`. It writes
   the same `coverage/` tree the serial run writes and leaves the same
   `timings.tsv`, so the scope stamp reads `full` and the release badge
   accepts it.

   The scope is the point, not a detail: a mode that measured the whole
   suite and stamped `partial` would be refused by the badge generator and
   the serial run would still be on the release critical path.

3. **ONE partition primitive serves both.** Both call
   `_shard_unit_files <n>/<total>` (#724's greedy LPT over recorded
   seconds). A second partitioner would be a second roster, and the
   failure mode of two rosters is a spec that belongs to neither.

4. **A lost slice is a REFUSAL, not a smaller number.** A slice that
   produced no report -- a kcov that died after its tests passed, leaving
   an empty output directory and a zero status -- fails the run. Merging
   the survivors would publish a smaller line set under a whole-suite
   certificate, which reads as a coverage regression rather than as the
   lost slice it is. The same applies to a job count that is not a
   positive integer and to a slice that matched no spec files (more slices
   than the suite has specs).

5. **The local mode is NOT in the PR gate, and that is deliberate.**
   `self-test.yaml` is untouched; the local mode's CI exposure is an
   opt-in `workflow_dispatch` workflow, `.github/workflows/coverage-local.yaml`,
   on `[self-hosted, gpu]`, carrying the fork guard every
   self-hosted-eligible job in this tree carries (ADR-00000026). One
   self-hosted runner is a single point of failure and a contention point:
   a required check that queues behind another tenant's job can be blocked
   by work unrelated to the PR, and a machine that is down blocks every
   merge. The hosted matrix has neither property. Should the fleet ever
   grow, promoting the mode is a `runs-on` plus a trigger, not a rewrite --
   which is the second reason to build it now rather than at migration
   time.

### Consequences (amendment)

- A full-scope coverage run -- the one every release needs -- can use the
  whole machine instead of one core. The PR gate's latency is unchanged,
  because the PR gate did not move.
- kcov's `--merge` becomes load-bearing for the local mode, where the CI
  path relies on the gate's own per-line union (#730). They are two
  implementations of one property, and the property is checkable against
  the LINE SET rather than the percentage -- a matching rate over a
  different set is not equivalence. The measurement below is that check.
  **It did not come back empty**, and the amendment states what it found
  rather than the equality it set out to claim.
- The self-hosted workflow is authored but, at the time of writing, has
  not been RUN: no self-hosted runner was reachable from where this
  landed. It is stated rather than implied, because a validation nobody
  performed is not a validation.
- `--coverage-local` is refused in combination with `--coverage-shard`,
  `--coverage-path` and `--bats-path`, each by a message naming the flag
  the operator typed.

### Alternatives (amendment)

- **`kcov` over `bats --jobs`.** The obvious in-job parallelism, and the
  one the #1060 amendment measured rather than assumed. It is not rejected
  everywhere -- #1060 turned it ON for shards, where the trace volume
  through the one parser stays inside the bound. It is rejected for THIS
  run: at whole-suite volume the covered set moves (8617 lines serial,
  reproducibly, against 8532 and 8587 parallel), and the full-scope run is
  the one that feeds the release badge, so a figure that shifts a point
  between two runs of one tree is worse than a slow one.
- **Raise `CI_SHARDS` and point the matrix at the self-hosted runner.**
  It does not parallelise anything on ONE runner (the entries serialise),
  and it puts the PR gate on a shared workstation -- the SPOF and
  contention this amendment's Decision 5 refuses.
- **Make the local mode the PR gate outright.** Same objection, plus it
  would delete the hosted matrix's ability to run when the workstation is
  off.
- **Let the coverage-gate union the per-slice reports instead of
  `kcov --merge`.** It would reuse the merge math #730 already proved,
  but it leaves no single HTML report for a human to open, and the badge
  generator's `discover_reports` treats a top-level `kcov-merged/` as THE
  project report -- so the local run would have to be special-cased in the
  release path. Kept as the fallback if the equivalence check ever fails.

### Measurement (amendment)

Four whole-suite runs of ONE tree (`bea6324`, 32 cores, one at a time on
an otherwise idle machine), compared on the canonicalised `(file, line)`
sets of their merged cobertura reports rather than on their rates. The
canonicalisation is the coverage-gate's own longest-path-suffix rule, so
kcov's prefix-truncated aliases are not read as differences.

| run | wall | instrumented | covered | stamp |
|-----|------|--------------|---------|-------|
| `just test coverage` (serial) | 2052 s | 9667 | 8179 | `scope=full` |
| `just test coverage-local` (32 slices) | 299 s | 9667 | 8152 | `scope=full` |
| the same, again | 294 s | 9667 | 8152 | `scope=full` |
| `just test coverage-local 1` (1 slice) | 2022 s | 9667 | 8167 | `scope=full` |

**What holds.**

- **6.9x**, and the release path is the beneficiary: 34 minutes becomes 5.
- The **instrumented set is identical** in all four -- symmetric
  difference 0 over 9667 lines. The denominator does not move with the
  slice count, which is the invariant #730 had to restore for the CI
  path's merge and is the one a sum would break first.
- The mode is **deterministic**: two 32-slice runs agree on every one of
  8152 lines, in both directions.
- Both parallel runs stamp **`scope=full`**, which is the acceptance the
  release badge turns on. The scope is derived from the merged run
  manifest, and both manifests name all 164 specs -- the same 164 the
  serial run names.

**What does not hold, stated rather than rounded away.** The covered sets
are NOT equal. They are strictly nested:

    32-slice (8152)  subset of  1-slice (8167)  subset of  serial (8179)

27 lines, 0.33% of the covered set, in three files:
`dist/script/docker/lib/help.sh` (12), `config_summary.sh` (14),
`bootstrap.sh` (1) -- almost all of them arms of localised `case` lookup
tables, where a line is executed only if something asked for that exact
`<lang>:<key>`.

The 1-slice run is what separates the two candidate causes, and it
acquits the merge. At one slice there is no partition: the whole suite
runs in ONE bats process, exactly as the serial run does, and the report
still goes through `kcov --merge`. It loses 12 of the serial run's lines
and gains none. A merge cannot lose what was never split, so those 12 are
lost BEFORE the merge -- the remaining difference between the two runs is
that the serial runner hands bats the pool DIRECTORIES with `--recursive`
while this one hands it an explicit file list in greedy-LPT order. The
suite therefore covers slightly different lines depending on the order it
runs in. Splitting it 32 ways loses 15 more, which is the same effect
with the processes separated as well.

So the finding is about the SUITE, not about this mode: some spec's
coverage depends on what ran before it in the same bats process. It is
recorded here and left open, because closing it means finding that spec
and giving it its own fixture -- work that belongs to whoever owns the
coupling, not to the runner that exposed it.

**What it costs meanwhile.** A badge published from a parallel run reads
0.33 points lower than one published from a serial run of the same tree,
against a floor of 80 and a rate near 84. Nothing in the gate moves. But
the two modes are not interchangeable to the line, and this amendment does
not claim they are.

Independent of the suite, `kcov --merge` itself is now pinned as a UNION
by `test/bats/integration/kcov_merge_union_spec.bats`, against the real
binary over a subject with two disjoint branches: the merged covered set
equals the union of the slices', and the merged instrumented set equals
the union rather than the sum.

## Amendment (#1060): a shard's bats runs parallel under kcov; the full-suite run does not, and that asymmetry is measured

- **Date:** 2026-09-05
- **Amendment status:** Accepted -- completes the correction this ADR's own
  Context opened and half-applied. Section 1's sharding is unchanged, and so
  is the "coverage is a gating PR check via `ci-rollup`" posture.
  **Relates:** #726 (a kcov process per slice), #1002 (whose thesis this
  supersedes), ADR-00000016, ADR-00000017.

### What was left in place

The Context above reads #377 correctly: it "left the **coverage path fully
serial** ... The ~8-12 min coverage runtime was therefore **serial x kcov**
... **not an inherent kcov floor**." Only one of those two factors was then
addressed. Section 1 divided the kcov half across a CI matrix and left the
serial half running inside every shard, where it stayed for two and a half
months.

The mechanism was a flag with two writers. `script/test/drivers/bats.sh` held
TWO hand-assembled bats invocations, not one: `_run_coverage` and
`_run_system`, each with its own argument list, and `_run_system` with its own
`nproc` probe and its own `--jobs` besides. What was unique to `_run_coverage`
is narrower and is the actual finding -- it was the only bats invocation in
the driver that never received `--jobs` at all. Every other runner --
including `_run_coverage_path`, added later -- takes its arguments from
`_bats_args_with_label`, which appends `--jobs $(nproc)` where GNU parallel
is present and falls back to serial with a message where it is not.
`git log -S'--jobs' -- script/test/drivers/bats.sh` returns only the driver
split: the flag was never removed from the coverage path, it was never added.
That there were two copies is why the decision below is "one writer for the
flag" rather than "add the flag here": a second copy is how the divergence
arose, and a third is what the guard refuses.

### Decision

**`_run_coverage` builds its bats arguments through
`_bats_args_with_label`,** and the helper takes a third argument naming the
caller's jobs policy (`parallel`, the default, or `serial`). Writing
`--jobs` a second time by hand -- which is how the divergence arose -- is
refused by a spec that allows the flag exactly one occurrence in the driver,
inside the helper; `_run_system`, the other hand-rolled copy, is routed
through the helper as well. An unrecognised policy is a `_die`, not a
default, and so is an EMPTY one: the helper reads `${3-parallel}`, so an
omitted third argument takes the documented default while a caller
expanding an unset variable reaches the refusal instead of the parallel
branch.

**The policy is derived from what the run will WALK, not from the
argument it was called with.** The full-suite branch declares `serial`. The
shard branch compares the slice `_shard_unit_files` returns against the
whole pool (`_coverage_pool_files`, one writer for "what the whole suite
is") and declares `serial` when the two are the same set, `parallel`
otherwise. Keying the policy on WHETHER a shard argument was passed is not
enough: `1/1` is a shard by syntax and the entire suite by content, and it
earns `scope=full`, the only scope `coverage_badge.sh` publishes -- so it
would have published the parallel figure this amendment measures as
under-reporting. `just test coverage 1/1` reaches that case, and so does
`vars.CI_SHARDS=1`, which `self-test.yaml` clamps into `[1,12]` and turns
into the matrix `["1/1"]`. This is the same derivation the release
certificate uses (`_measured_coverage_scope` compares the run manifest
against the inventory): an invocation is not evidence of what a run
measured, so neither the scope nor the policy is read off one.

The asymmetry is the finding, not a hedge:

- **A shard's line set holds, and where it does not the miss is 0.05%.**
  Three slices (two different partitions of 1/8, plus 6/8), comparing the
  covered and valid sets the coverage gate merges -- canonical
  `(file, line)` keys, symmetric difference computed in BOTH directions.
  Eight parallel runs: SEVEN reproduce the serial covered set exactly
  (7835/9229, 6373/7360 and 6207/7439 lines, empty difference each way),
  and the eighth was short **3 lines of 6207**, one-directionally.
  Serial runs of a slice agree with each other exactly. Wall time for the
  whole recipe: 147s / 164s serial against 47s-53s (shard 1/8) and 371s
  against 196s (shard 6/8). **The CI matrix runs shards and merges them
  by per-line UNION over a floor with ~4.7 points of margin, so a miss of
  that size cannot reach the gate's verdict -- it is not zero, and it is
  what #726 makes structurally zero.**

- **The full suite's line set does move, so it stays serial.** At ~4500
  tests, two serial runs record the same 8617 covered lines; two parallel
  runs record 8532 and 8587 -- each a strict SUBSET of the serial set (0
  lines covered in parallel that serial missed, twice) and differing from
  each other. `lines-valid` is identical in every run (10194), so only the
  numerator moves: 84.53% against 83.70% and 84.24%. This is the run that
  stamps `scope=full` and feeds the release badge of the #952 amendment,
  and a badge that moves a point between two runs of one tree is the
  falsifiable-figure promise broken from the inside.

- **What is lost is trace, not execution.** The dropped lines cluster in
  subprocess-heavy code (`setup_cmd.sh`, `watchdog.sh`, `prune.sh`,
  `transcript.sh`, `help.sh`, `bootstrap.sh`) whose tests PASS in both runs
  -- `just docker help renders zh-TW recipe summaries` is `ok` in each, and
  its zh-TW `case` arms appear only in the serial report. N parallel bats
  jobs feed their trace streams to ONE kcov process whose parser is
  single-threaded: the miss scales with the volume of trace and never
  reverses sign (no parallel run has ever recorded a line serial missed,
  in ten comparisons), which is a reader losing samples rather than a
  flaky test. That parser is also the share of the runtime `--jobs` cannot
  divide. **Making it scale, and with it the full-suite path, is #726 (a
  kcov process per slice) -- a different change, not a competing one.**

- **The residual is disclosed, not absorbed.** A gate that ever becomes the
  regression-vs-baseline v2 this ADR still lists as a follow-up would be
  comparing figures whose noise floor is now non-zero on the shard path;
  that comparison has to be made against #726 landing first, or against a
  serial policy for the gate too.

### The junit report and the weights it feeds

`_junit_to_timings` reads one `report.xml` and writes `coverage/timings.tsv`,
which the next partition weighs. Under `--jobs` bats still emits ONE coherent
report: after a parallel full run the manifest names all 173 specs and the
run stamps `scope=full`, which is exactly the check that a narrowed or
truncated report would fail.

The per-spec seconds in it are wall-clock under contention, not per-test in
isolation: mean 4.32x the serial figure, median 4.00, min 0.50, max 27.0.
That distortion does not unbalance the partition, because greedy-LPT reads
relative weights and these are recorded in the same regime they will predict.
Driving the real `_shard_unit_files` at 8 shards and weighing each partition
by the parallel durations it must balance: weights from a serial run give
makespan 1446 (loads 754-1446); weights from a parallel run give 1138 (loads
1111-1138). The transition run is the 1446 case -- better than the
`@test`-count fallback, and one run long.

### Consequences (amendment)

- The PR critical path drops by the measured shard figures above, against a
  merged gate rate whose measured movement is at most 3 lines in 6207 on one
  shard of eight, unioned away wherever another shard ran the same line.
- `just test coverage` (full suite) is unchanged in duration -- ~35 min on a
  32-core host for this tree. The parallel version of it exists and is 4x
  faster; it is not adopted because it under-reports. Anyone tempted to
  flip that policy should re-run the comparison above first, and #726 is
  what would make the answer different.
- The helper now carries a policy argument, so "this run must be serial"
  and "this host has no GNU parallel" are distinguishable in the run's own
  first line (`serial by policy` against `serial; parallel not in PATH`).
- `_run_system` gains `--recursive` and the fallback message it never had,
  which is what routing it through the helper means.
- A shard invocation whose slice IS the whole suite (`1/1`, or any
  `<n>/<total>` a small enough tree makes exhaustive) runs serial and says
  `serial by policy` in its first line. It is slower than the argument
  suggests, and that is the point: it is the run that would otherwise
  publish a parallel figure as `scope=full`.

## Amendment (#1068): the job count is a FLOOR on concurrency, and a third policy meters the kcov runners

- **Date:** 2026-09-05
- **Amendment status:** Accepted -- narrows the Decision of the amendment
  above. Section 1's sharding, the one-writer guard, the shard /
  full-suite asymmetry and the `1/1`-is-the-suite rule are all unchanged.
  What changes is the COUNT the one writer derives and the size of the
  policy vocabulary it accepts -- so the two-name enumeration in the
  #1060 Decision (`parallel`, the default, or `serial`) and its
  description of the helper as one that "appends `--jobs $(nproc)`" are
  superseded here rather than left to be read as current.
  **Relates:** #726 (a kcov process per slice), #1002, #1060.

### What the previous amendment did not look at

It routed every bats invocation in the driver through
`_bats_args_with_label` and left the count that helper derives exactly as
it found it: `$(nproc 2>/dev/null || echo 4)`. `nproc` is the right
question for a CPU-BOUND workload and this suite is not one -- a bats
test spends its time waiting on subprocesses, and #1002 measured 1-2 of
32 cores busy for the length of a run. CI's runner has four cores, so
`--jobs $(nproc)` there produced exactly the ratio the flag exists to
remove.

Measured on one real coverage shard, through the production path, under a
4-CPU cpuset, two reps per point: `--jobs 1` (serial control) 108.4s /
108.9s, `--jobs 4` (what CI ran) 113.4s / 104.8s, `--jobs 8` 82.7s /
87.7s, `--jobs 32` 62.2s / 63.1s, `--jobs 64` 61.9s / 62.5s. One rep at 4
is slower than serial and one is faster: indistinguishable. Plain bats on
the same shard and the same four cores is 88.4s / 93.8s at `--jobs 4`
against 42.5s / 42.2s at `--jobs 32`, so the effect belongs to the SUITE
and not to kcov.

Re-measured on a different 22-spec slice under the same 4-CPU cpuset, two
reps per point: plain bats 75.7s / 81.7s serial, 83.8s / 98.9s at
`--jobs 4`, 41.9s / 44.0s at `--jobs 32`; the same slice under kcov
139.3s / 114.6s serial, 111.1s / 122.3s at 4, 67.9s / 70.2s at 32. A
different partition and the same three conclusions: 4 is not
distinguishable from serial, 32 is ~1.8x serial, and the ratio survives
kcov being in the loop.

`nproc 2>/dev/null || echo 4` also answered two different questions with
one number. A failed probe and a genuine four-core machine both printed
`jobs=4`, and on CI both were true at once, so a run's own log could not
say which had happened -- the same shape of silent wrong answer the
policy argument was added to refuse one line above.

### Decision

**1. The count is `max(cores, 32)`: a floor, never `k x nproc`.** 32 is a
KNEE and not a peak, which is what decides the SHAPE of the rule. Four
INTERLEAVED reps per point on a 32-core host, same slice: 16 jobs 43.7s,
32 jobs 26.5s, 64 jobs 25.8s, 128 jobs 25.7s. Below the knee costs 1.65x;
above it the curve is flat out to 4x the core count. (A first two-rep
pass read 128 as worse than 32 -- 60.7s / 47.3s against 49.0s / 47.3s --
and the 60.7s does not survive repetition; that reading is withdrawn, and
with it any claim that a large machine must be held to its cores.)

So the count ABOVE the knee is free, and a floor is chosen for the
property a re-tuner needs rather than for a winner: it is monotone, and
it cannot land BELOW the knee, where `k x cores` lands on any machine
smaller than 32/k -- which is the four-core runner this started on. 32 is
a property of the WORKLOAD, how many waiting tests it takes to keep the
pipe full, not of a machine, which is why nothing here scales it.
Re-derive it by sweeping `--jobs` against one shard on a constrained
cpuset, interleaving the points so one slow rep cannot become the
finding; do not multiply it.

**2. A third policy, `metered`, is one job per core with no floor**, and
the driver's two kcov runners (`_run_coverage`'s shard branch and
`_run_coverage_path`) declare it. The amendment above established why: N
bats jobs drain into ONE single-threaded trace parser, so the share that
does not divide by `--jobs` is the share that decides what the report
says. Measured on one shard: 4 -> 32 jobs is 1.75x and costs a
REPRODUCIBLE hole -- four runs at 16/32 jobs union to 31 lines short of
the serial covered set, 30 of them the compose-lifecycle region of
`dist/script/docker/wrapper/run.sh`, ~0.45 points off the reported rate
-- where two runs at `--jobs 4` union to the serial set exactly. The
re-measurement above reproduces the shape on its own slice: two serial
runs record a byte-identical 3093 covered lines, the union of two
`--jobs 4` runs loses none of them, and the union of two `--jobs 32` runs
is 18 short with 17 of the 18 in one file. Faster while losing lines is
not an improvement for the runner whose output IS the line set.
`metered` is refused-by-default like the other two: an unknown or empty
third argument still `_die`s.

**3. An unreadable core count falls back and LABELS ITSELF one**, where
an unreadable policy still `_die`s, and the two are not in tension. An
unreadable POLICY is a caller's bug and there is no correct run to give
it; an unreadable CORE COUNT is an ENVIRONMENT, the same kind as
`parallel` missing from PATH, which this helper already falls back on and
names. Under `metered` the fallback is 1 rather than the floor: with no
core count there is nothing to meter to, and fewer jobs is the safe
direction for a run whose output is a line set.

### Consequences (amendment)

- Six runners with no kcov in the loop take the floor: unit, integration,
  unit-shard, bats-path, bats-fragile and system. On the four-core CI
  runner the `bats-integration`, `bats-fragile` and `system` jobs go from
  four concurrent bats jobs to 32. On any host with 32 or more cores
  NOTHING CHANGES -- `max(32, 32)` is what `nproc` already returned -- so
  a green gate on a large developer machine is evidence about the tests
  and the docs, not about the floor. The CI jobs are where it is
  confirmed.
- `system` is the runner whose every test waits on `docker`, so it has
  the most to gain and is also the one whose concurrency this widens
  furthest: two of its four spec files pin
  `BATS_NO_PARALLELIZE_WITHIN_FILE`, so up to 13 of its 19 tests can now
  be in flight at once against the four that could before, each one a
  `docker buildx build` on a four-core runner. That is the one behaviour
  here a local gate cannot settle.
- The coverage matrix is unaffected. `metered` resolves to the core
  count, which is what the shard path already ran at, so the reported
  rate and the release badge move by nothing; what the policy buys is
  that the next change to the DEFAULT cannot silently take 0.45 points
  off them.
- The four labels a run prints are mutually distinguishable --
  `(cores, at or above the floor)`, `(floor, over N cores)`,
  `(fallback: nproc gave no core count)`, `(metered to the core count)`
  -- so a run's own first line says which of the four happened, which is
  precisely what `jobs=4` could not.
- `nproc` reports the CPUs a process may be SCHEDULED on, an affinity
  mask, and not a CFS quota: in a container started with `--cpus=2` on a
  32-core host it still prints 32 (measured). The floor does not care --
  it oversubscribes on purpose -- but `metered`'s invariant is stated in
  cores, so in a quota-limited container it is not held and the kcov
  drain is oversubscribed anyway. Nothing base launches is capped that
  way (its own compose services set no CPU limit, and a GitHub-hosted
  runner is a whole VM), so this is a boundary of the policy and not a
  live defect; a self-hosted runner that meters CPU by quota would make
  it one.
