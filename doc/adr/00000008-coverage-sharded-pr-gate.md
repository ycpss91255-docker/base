# Shard kcov coverage + promote it to an enforced PR gate

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
