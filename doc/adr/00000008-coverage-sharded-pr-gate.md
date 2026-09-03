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
