# CI throughput ceiling (free + public) and the shard / runner strategy

- **Date:** 2026-06-29
- **Status:** Accepted
- **Relates to:** ADR-00000008 (sharded coverage PR gate), ADR-00000016
  (coverage tooling kept as kcov), issue #758 (CI-squeeze work), issue #766
  (self-hosted same-repo guard)

## Context

The self-test PR critical path is ~3m. A throughput grill set out to "push CI
to the limit" and to decide how the coverage shard count should be managed
(today a static `vars.CI_SHARDS`, default 8). The investigation produced
hard, API-verified constraints that bound what is achievable, so they are
recorded here to stop the topic being re-litigated.

### Verified constraints (measured / API-checked, not assumed)

- **Plan = GitHub Free -> 20 concurrent jobs, org-wide** (shared across every
  repo in the org). Observed peak in one self-test run: 15 concurrent (8
  coverage shards + ~7 other jobs).
- **GitHub-hosted exposes NO capacity / idle / remaining-slot API.** Direct
  checks: `…/actions/runner-limits` -> 404 (the field-returning endpoint some
  blogs cite does not exist), `…/actions/hosted-runners` -> 404 "not supported
  for this organization" (that is the paid larger-runner feature),
  `…/settings/billing/actions` -> 410 Gone. The 20-cap is enforced
  server-side and cannot be queried at runtime.
- **kcov coverage is serial / single-threaded per process.** Measured: a full
  unsharded `just test coverage` on the org's 32-core self-hosted runner took
  **522s (~8.7 min)** for the same 2135 tests. Extra cores do not speed a
  serial kcov run. Therefore **sharding is not removable** -- dropping it
  returns CI to ~8.7 min (~3x slower than the sharded ~3 min).
- **The two co-equal poles.** Slowest coverage shard ~155s and native arm64
  `integration-e2e` ~154s run in parallel; total is bounded by the larger.
  Cutting only one pole does not move the total (the other still sits at
  ~155s) -- they must be cut together.
- **Self-hosted reality.** The org has ONE self-hosted runner (32-core, GPU,
  org-level, currently unused by CI). Self-hosted `status`/`busy` ARE
  queryable. base is a PUBLIC repo with `fork-pr-contributor-approval =
  all_external_contributors` and zero fork PRs in history.

## Decision

1. **Shard count is auto-derived by ONE mechanism, not a hand-maintained
   number and not per-environment parameters.** `compute-shards` emits a
   single N consumed by a single matrix:
   - GitHub-hosted: `N = concurrency_budget = cap (20) - reserved_other_jobs
     (~7) ~= 12`. A *derived constant* -- it does not float (the cap pins it),
     but no human tunes it; it only shifts if the cap or the job set changes.
   - Self-hosted: `N = idle-runner / core budget` -- genuinely dynamic and
     queryable.
   - `vars.CI_SHARDS` remains the SINGLE optional override (applies in any
     environment, highest precedence). Operators manage zero parameters by
     default, one at most. There is deliberately NOT a separate hosted vs
     self-hosted parameter -- the environment branch lives inside the one
     compute-shards mechanism.
   - Sharding itself stays (removing it -> 522s serial, per the measurement).

2. **The free + public PR-CI ceiling is ~135s and that is a platform limit,
   not a process defect.** Reaching it needs BOTH levers (shard count at the
   hosted budget AND the e2e build cached); the specific e2e-build-cache
   mechanism is decided separately. Below ~135s is not reachable on free +
   public because the 20-cap caps shard parallelism and kcov's per-line cost
   is irreducible (ADR-00000016).

3. **Self-hosted is the only escape from the 20-cap, but it is gated for a
   public repo and deferred.** Using the self-hosted runner for PR CI would
   let coverage shard as parallel processes across its 32 cores (est.
   ~35-50s) and dodge the 20-cap, but a public repo must first land the
   same-repo guard (#766) so fork-PR code never executes on the machine, and
   must accept single-machine SPOF + contention with the owner's other work.
   Not scheduled.

4. **No paid GitHub runners** (owner decision). The escape paths beyond the
   free ceiling are: self-hosted (per decision 3) or a third-party runner
   provider -- both separate budget/ops decisions, out of scope here.

## Consequences

- The shard count stops being a maintained magic number; it self-sizes to the
  environment, generalising cleanly when/if self-hosted runners are adopted.
- "Why is CI ~3m and not faster?" has a recorded, evidence-backed answer: the
  free + public 20-cap plus serial-kcov cost. Speed work below ~135s is
  explicitly a runner-budget decision, not a workflow-tuning one.
- The self-hosted escape is documented but blocked on #766 + the SPOF
  trade-off, so it cannot be adopted accidentally.

## Alternatives

- **Keep a hardcoded `CI_SHARDS`.** Rejected: a maintained magic number the
  owner has to remember to bump; the budget/idle derivation removes it.
- **Remove sharding entirely (one coverage job).** Rejected by measurement:
  522s serial even on a 32-core machine; ~3x slower.
- **Move CI to the existing self-hosted runner now.** Rejected for now:
  public-repo fork-PR code-execution risk (needs #766 first) and
  single-machine SPOF / owner-workstation contention. Left as a documented,
  gated future path.
- **Buy concurrency (GitHub Team/Enterprise or third-party runners).**
  Rejected for now (owner decision); recorded as the other escape path.
