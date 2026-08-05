# TEST.md

Template self-tests: **2681 tests** total (2563 unit + 118 integration).

> "Self-test total" is the `just test` suite -- what runs in the
> `Self Test` CI job. System (9) and smoke (34) tests are tracked here
> too but are **not** in the 2681 figure: System specs need host docker
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
| [unit.md](unit.md) | `test/bats/unit/` -- library, wrappers, generators, templates (Unit level) | 2563 |
| [integration.md](integration.md) | `test/bats/integration/` -- init / upgrade / dispatch across components (Integration level) | 118 |
| [system.md](system.md) | `test/bats/system/` -- opt-in `runtime-test` buildx specs, gate-fires Regression (System level, host docker) | 9 |
| [acceptance.md](acceptance.md) | `test/bats/acceptance/` -- consumer framework + UX, UAT/OAT (Acceptance level; CI-only via the `acceptance` job, #785) | 0 |
| [smoke.md](smoke.md) | `dist/test/bats/smoke/` -- shipped per-stage build-time smoke templates (Smoke type) | 34 |

Self-test grand total (unit + integration): **2681**.

## Static lints and where they are enforced

The `just test` lint phase runs the tools listed in `script/test/test.sh`'s
`_LINT_TOOLS` table. That table is the local gate; it is **not** the CI gate,
because no CI job runs the phase (the lint jobs narrow to one tool, and every
bats / coverage job sets `BATS_ONLY=1` / `COVERAGE=1`, which skip it). Each
tool therefore needs its own join to `.github/workflows/self-test.yaml`:

| Lint | Enforces | CI job | Gated? |
|------|----------|--------|--------|
| `shellcheck` | shell static analysis | `shellcheck` (`--shellcheck-only`) | `code_changed` |
| `hadolint` | Dockerfile static analysis | `hadolint` (`--lint --hadolint`, in the test-tools image) | `code_changed` |
| `issueref` | no transient `#NNN` in code comments (ADR-00000013) | `lint-static (issueref)` | ungated |
| `adr-numbering` | `doc/adr/` duplicate-free + well-formed | `lint-static (adr-numbering)` | ungated |
| `stale-setup-conf` | no legacy `config/docker/setup.conf` under `dist/` | `lint-static (stale-setup-conf)` | ungated |
| `readme-sync` | localized READMEs still match `README.md` | `lint-static (readme-sync)` | ungated |
| `doc-counts` | the figures / catalog rows below | `doc-counts` (`--doc-counts-only`) | ungated |
| `home-literal` | no concrete username in a home path under `dist/` or `dockerfile/` (ADR-00000024) | `lint-static (home-literal)` | ungated |
| `bash-source-guard` | no undefaulted `BASH_SOURCE` self-location read under `dist/` or `script/` | `lint-static (bash-source-guard)` | ungated |

`lint-static` is a matrix so a red check names the lint that failed, and it is
ungated because two of its entries (`adr-numbering`, `readme-sync`) are
breakable by a change `classify` scores as doc-only -- a `code_changed` gate
would skip them on exactly the PR they exist to catch. Every entry but
`hadolint` runs host-direct on a plain runner via `test.sh --<tool>-only`; the
hadolint binary exists only in the test-tools image, so it keeps its own job.

Adding a lint to `_LINT_TOOLS` without giving it a CI job fails the
completeness guard in `test/bats/unit/self_test_yaml_spec.bats`. That guard,
not this table, is what keeps the list honest -- four lints shipped local-only
before it existed, and `home-literal` / `bash-source-guard` each joined the
matrix in the same change that introduced them.

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
| `just test` lint phase (`just test lint --doc-counts`) | every local full gate | **yes** -- this is the gate |
| the `doc-counts` CI job (`test.sh --doc-counts-only`) | every CI run, ungated (a hand-edited count is a doc-only change) | **yes** -- same driver, hard-mandatory in `ci-rollup` |
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
