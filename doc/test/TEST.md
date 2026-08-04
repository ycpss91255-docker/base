# TEST.md

Template self-tests: **2474 tests** total (2356 unit + 118 integration).

> "Self-test total" is the `just test` suite -- what runs in the
> `Self Test` CI job. System (8) and smoke (40) tests are tracked here
> too but are **not** in the 2474 figure: System specs need host docker
> access and are opt-in, and smoke specs are Dockerfile `test`-stage
> build-time assertions, not self-tests. Acceptance is a CI-only level (0
> bats specs by design): it drives a real scaffolded consumer + built
> image via the host-driven `acceptance` job, not the mounted-`/source`
> sandbox (see [acceptance.md](acceptance.md)).

This file is the index. The taxonomy is ISTQB-aligned (ADR-00000018):
the **levels** are Unit -> Integration -> System -> Acceptance, plus the
shipped build-time **Smoke** type. Per-category spec catalogs (each
carrying its own test count) live in the sibling docs below.

## Test Docs by Level / Type

| Doc | Scope | Count |
|-----|-------|-------|
| [unit.md](unit.md) | `test/bats/unit/` -- library, wrappers, generators, templates (Unit level) | 2356 |
| [integration.md](integration.md) | `test/bats/integration/` -- init / upgrade / dispatch across components (Integration level) | 118 |
| [system.md](system.md) | `test/bats/system/` -- opt-in `runtime-test` buildx specs, gate-fires Regression (System level, host docker) | 8 |
| [acceptance.md](acceptance.md) | `test/bats/acceptance/` -- consumer framework + UX, UAT/OAT (Acceptance level; CI-only via the `acceptance` job, #785) | 0 |
| [smoke.md](smoke.md) | `dist/test/bats/smoke/` -- shipped per-stage build-time smoke templates (Smoke type) | 40 |

Self-test grand total (unit + integration): **2474**.

## Maintaining these docs

Every figure and every catalog row in this directory is derived from the specs
themselves. Regenerate with `just test sync-docs`; validate without writing
with `just test sync-docs-check`. Never hand-edit a count or hand-add a row --
see [unit.md](unit.md) for the full contract.

**Where the check is enforced (one rule, three entry points).** All three run
the same `script/test/check_test_md_drift.sh`; they differ only in when they
speak and whether they can stop you:

| Entry point | When | Blocking? |
|-------------|------|-----------|
| `just test` lint phase (`just test lint --doc-counts`) | every local full gate, and every CI `Self Test` run | **yes** -- this is the gate |
| `just test sync-docs-check` | on demand | yes, but only if a human runs it |
| harness repo `.claude/hooks/check_test_md_drift.sh` (PostToolUse) | seconds after the Edit that caused the drift, in an interactive session only | no -- advisory |

The hook duplicates the gate deliberately: its value is latency, not
authority. It holds no rule of its own, so it cannot drift from the gate, and
if it is ever removed nothing is lost but the early warning. When the two
disagree, the lint phase is authoritative -- it is the one that can fail a
branch.

**Merging a branch into these files:** both sides bump the same generated
counters, so `doc/test/*.md` conflicts on almost every branch refresh. Do not
resolve it by hand and do not collapse it with an ad-hoc `awk`: run

```bash
just test resolve-docs
```

which collapses the markers, regenerates from the merged spec tree, verifies,
and stages -- and refuses loudly, staging nothing, when the two sides disagree
about something regeneration cannot settle (a catalog row each side describes
differently, or any hand-written prose that differs). A mechanical collapse
adopts whichever side it kept for exactly that content, which is how the
"System (N) and smoke (N)" line above shipped stale three times before the
generator learned to derive it.
