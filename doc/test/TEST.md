# TEST.md

Template self-tests: **2083 tests** total (1998 unit + 85 integration).

> "Self-test total" is the `just test` suite — what runs in the
> `Self Test` CI job. Behavioural (5) and smoke (38) tests are tracked
> here too but are **not** in the 2083 figure: behavioural specs need
> host docker access and are opt-in, and smoke specs are Dockerfile
> `test`-stage build-time assertions, not self-tests.

This file is the index. Per-type spec catalogs (each carrying its own
test count) live in the sibling docs below.

## Test Docs by Type

| Doc | Scope | Count |
|-----|-------|-------|
| [unit.md](unit.md) | `test/bats/unit/` — library, wrappers, generators, templates | 1998 |
| [integration.md](integration.md) | `test/bats/integration/` — end-to-end init / upgrade / dispatch | 85 |
| [behavioural.md](behavioural.md) | `test/bats/behavioural/` — opt-in `runtime-test` buildx specs (host docker) | 5 |
| [smoke.md](smoke.md) | `downstream/test/smoke/` — shipped build-time smoke templates | 38 |

Self-test grand total (unit + integration): **2083**.
