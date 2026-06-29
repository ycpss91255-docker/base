# TEST.md

Template self-tests: **2157 tests** total (2070 unit + 87 integration).

> "Self-test total" is the `just test` suite — what runs in the
> `Self Test` CI job. Behavioural (5) and smoke (38) tests are tracked
> here too but are **not** in the 2157 figure: behavioural specs need
> host docker access and are opt-in, and smoke specs are Dockerfile
> `test`-stage build-time assertions, not self-tests.

This file is the index. Per-type spec catalogs (each carrying its own
test count) live in the sibling docs below.

## Test Docs by Type

| Doc | Scope | Count |
|-----|-------|-------|
| [unit.md](unit.md) | `test/bats/unit/` — library, wrappers, generators, templates | 2070 |
| [integration.md](integration.md) | `test/bats/integration/` — end-to-end init / upgrade / dispatch | 87 |
| [behavioural.md](behavioural.md) | `test/bats/behavioural/` — opt-in `runtime-test` buildx specs (host docker) | 5 |
| [smoke.md](smoke.md) | `dist/test/smoke/` — shipped build-time smoke templates | 38 |

Self-test grand total (unit + integration): **2157**.
