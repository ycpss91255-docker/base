# Coverage tooling: evaluate kcov alternatives to lift the per-file shard floor

- **Date:** 2026-06-27
- **Status:** Proposed
- **Relates to:** ADR-00000008 (sharded coverage PR gate, built on kcov),
  ADR-00000015 (test files mirror source -- the symptom-level lever),
  issue #758 (lower the coverage critical path)

## Context

Coverage is an enforced PR gate run under **kcov** (ADR-00000008). kcov
collects coverage via **ptrace**, single-stepping the traced process. That
has two costs measured in this repo:

1. **Per-run overhead.** kcov roughly +60% wall-clock over plain bats
   (`deploy_spec` 57s plain -> 92s under kcov).
2. **Per-file atomicity for sharding.** Because each spec file is run as
   one kcov invocation (to amortise the ptrace launch cost), a file cannot
   be split across shards. The longest single spec file is the hard floor
   on the slowest coverage shard, which sits on the PR critical path.

The dynamic + time-weighted + cached shard work (#725/#724/#733) and the
conf parse-once perf (#742) halved the critical path (~409s -> ~208s total;
slowest shard ~381s -> ~176s). ADR-00000015 lowers the per-file floor by
splitting god-test-files into source-aligned units. Both treat the
**symptom**. The **root** is the tool: if coverage overhead were near
zero, coverage could fold back into the normal test pass and the whole
separate-sharded-coverage architecture could be retired.

## Candidate tools

| tool | mechanism | note |
|---|---|---|
| **kcov** (current) | ptrace | cobertura native; language-agnostic; the +60% / per-file constraint above |
| **bashcov** | bash xtrace (`DEBUG` trap / `PS4` via `BASH_XTRACEFD`), no ptrace | works with bats; auto-merges; SimpleCov-based, so cobertura needs `simplecov-cobertura`; DEBUG-trap has its own per-command overhead and known correctness edges around `set -e`, subshells |
| **DIY `PS4` + `BASH_XTRACEFD`** | own `DEBUG` trap recording line hits | lightest, fully in our control; must write our own report emitter |
| **ShellSpec** | own BDD framework with built-in parallelism | its coverage is itself kcov under the hood -- does not remove the root |

## Decision (pending -- this ADR is Proposed)

Before committing to any tool change, run a **time-boxed throwaway spike**
(the prototype workflow) measuring **bashcov** and a **DIY PS4** tracer
against kcov on 2-3 representative specs (the heavy `deploy_spec`, a light
one). The spike must answer three gating questions with numbers:

1. **Speed** -- is it materially faster than kcov's ptrace?
2. **Reporting** -- can it emit cobertura the existing gate / timings cache
   consume, or what replaces them?
3. **Fidelity** -- does it stay accurate under our `set -u`, subshells, and
   `local -n` patterns (no false coverage gaps / no crashes)?

Decide only on the spike's evidence:

- If a lighter tracer clears all three: adopt it, and re-evaluate whether
  the separate sharded-coverage job (ADR-00000008) can collapse into the
  normal test pass.
- If none clears the bar: keep kcov; ADR-00000015's source-aligned splits
  remain the available lever, and this ADR is marked Rejected with the
  spike numbers recorded.

This is intentionally sequenced **after** ADR-00000015's P1 (the
source-aligned re-split), which is low-regret regardless of the tool
outcome.

## Consequences (if adopted)

- A coverage tool swap touches the test-tools image (currently bakes
  kcov), the gate's cobertura parser, and the `.shard-weights` timings
  cache -- an ADR-00000008-level change, hence the spike-first gate.
- A near-zero-overhead tracer could remove the dedicated coverage shards
  entirely, simplifying `self-test.yaml` and erasing the per-file floor as
  a concern -- the largest available structural win, but the riskiest.

## Alternatives

- **Do nothing; live with kcov.** Viable -- the symptom-level levers
  (sharding + ADR-00000015) already keep the gate within budget. This ADR
  exists because the user asked whether the constraint can be removed at
  the root, not because the gate is currently failing.
- **Skip the spike, swap to bashcov directly.** Rejected: bashcov's
  DEBUG-trap overhead and `set -e`/subshell fidelity are unproven for our
  code; swapping blind risks a slower or less accurate gate.
