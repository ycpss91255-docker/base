# TEST.md

Template self-tests: **2234 tests** total (2132 unit + 102 integration).

> "Self-test total" is the `just test` suite -- what runs in the
> `Self Test` CI job. System (5) and smoke (40) tests are tracked here
> too but are **not** in the 2234 figure: System specs need host docker
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
| [unit.md](unit.md) | `test/bats/unit/` -- library, wrappers, generators, templates (Unit level) | 2132 |
| [integration.md](integration.md) | `test/bats/integration/` -- init / upgrade / dispatch across components (Integration level) | 102 |
| [system.md](system.md) | `test/bats/system/` -- opt-in `runtime-test` buildx specs, gate-fires Regression (System level, host docker) | 5 |
| [acceptance.md](acceptance.md) | `test/bats/acceptance/` -- consumer framework + UX, UAT/OAT (Acceptance level; CI-only via the `acceptance` job, #785) | 0 |
| [smoke.md](smoke.md) | `dist/test/bats/smoke/` -- shipped per-stage build-time smoke templates (Smoke type) | 40 |

Self-test grand total (unit + integration): **2234**.
