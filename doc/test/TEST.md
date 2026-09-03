# TEST.md

Template self-tests: **3713 tests** total (3558 unit + 155 integration).

> "Self-test total" is the `just test` suite -- what runs in the
> `Self Test` CI job. System (19) and smoke (38) tests are tracked here
> too but are **not** in the 3713 figure: System specs need host docker
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
| [unit.md](unit.md) | `test/bats/unit/` -- library, wrappers, generators, templates (Unit level) | 3558 |
| [integration.md](integration.md) | `test/bats/integration/` -- init / upgrade / dispatch across components (Integration level) | 155 |
| [system.md](system.md) | `test/bats/system/` -- opt-in `runtime-test` buildx specs, gate-fires Regression (System level, host docker) | 19 |
| [acceptance.md](acceptance.md) | `test/bats/acceptance/` -- consumer framework + UX, UAT/OAT (Acceptance level; CI-only via the `acceptance` job, #785) | 0 |
| [smoke.md](smoke.md) | `dist/test/bats/smoke/` -- shipped per-stage build-time smoke templates (Smoke type) | 38 |

Self-test grand total (unit + integration): **3713**.

## Running one spec under kcov: `just test coverage-path`

```bash
just test coverage-path test/bats/unit/lib_spec.bats
just test coverage-path test/bats/unit/lib_spec.bats --filter 'nounset'
just test coverage-path test/bats/integration/          # a directory works too
```

Some bugs are only visible under instrumentation: the spec is red under kcov
and green without it. kcov wraps every bash process it traces, sets its own
`PS4`, and perturbs a nested `set -u` shell, so a spec can depend on something
that only the coverage run disturbs -- which is precisely the class the
coverage matrix exists to catch, and the class that is hardest to iterate on.
The other two instrumented entries are the whole suite and a whole shard,
minutes each; this one runs the spec you name.

**It reports no coverage figure, deliberately.** The kcov report goes to a
throwaway directory inside the container and is removed on the way out, so
nothing this mode runs can write `coverage/cobertura.xml` -- which the
coverage-gate merges into the project line rate -- or `coverage/timings.tsv`,
which becomes the next partition's weights. One spec's covered lines over the
whole tree's denominator is not a project rate. Ask for a figure with
`just test coverage` (full suite) or `just test coverage <n>/<total>` (one
shard); ask for a RUN with this.

**It does not consult the shard partition, and that is load-bearing.** The
partition is greedy longest-processing-time bin-packing over per-spec weights
read from `test/bats/.shard-weights`. CI restores that file from cache; a
checkout does not have it, so `_spec_weight` falls back to `@test` counts and
the local partition is a genuinely different one. Shard `<n>/<total>` therefore
names different specs locally than it does in CI -- during #898 a spec sat in
CI's shard 1/8 and the local 4/8, and a local `just test coverage 1/8` never
ran the failing specs at all. Naming the path removes the question: the spec
you name is the spec that runs, in both places.

`--bats-path` (`just test` has no recipe for it; use
`./script/test/test.sh --bats-path <spec>`) remains the FAST loop -- no
ShellCheck, no kcov, on the `ci` service. It refuses `--coverage` and still
does: that combination is this recipe, on the `coverage` service, which is
where kcov lives.

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
| `adr-structure` | every ADR carries its `> Serves:` back-pointer, `## Context` / `## Decision` / `## Consequences` / `## Alternatives`, and a Status of exactly `Accepted`, `Rejected` or `Superseded by ADR-NNNNNNNN` -- each of them EXACTLY ONCE, at column 0, which is what lets the lint check an ADR without deciding which of its lines are code. A second occurrence is a file that does not say which one is the record and is reported; an illustrated line is indented out of column 0, an amendment's copy demoted to `###`. The one shape a count cannot catch -- a part BOTH omitted AND present at column 0 somewhere that is not the record (a fenced illustration, a commented-out draft) -- PASSES; that fail-open is wider than the fence parser it replaces, and it is named with its direction in the driver header and pinned by a spec. A scan that examined zero ADRs refuses rather than passes | `lint-static (adr-structure)` | ungated |
| `stale-setup-conf` | no legacy `config/docker/setup.conf` under `dist/` | `lint-static (stale-setup-conf)` | ungated |
| `readme-sync` | localized READMEs still match `README.md` | `lint-static (readme-sync)` | ungated |
| `doc-counts` | the figures / catalog rows below | `doc-counts` (`--doc-counts-only`) | ungated |
| `home-literal` | no concrete username in a home path under `dist/` or `dockerfile/` (ADR-00000024) | `lint-static (home-literal)` | ungated |
| `arch-literal` | no bare architecture literal in a shipped Dockerfile under `dist/` or `dockerfile/`; architecture comes from `ARG TARGETARCH`, and a mapping onto an upstream asset spelling opts out with a stated reason | `lint-static (arch-literal)` | ungated |
| `bash-source-guard` | no undefaulted `BASH_SOURCE` self-location read under `dist/` or `script/` | `lint-static (bash-source-guard)` | ungated |
| `early-close-reader` | no `\| head` / `\| grep -q` under `dist/` or `script/`, where an early-closing reader strands its writer and `pipefail` inverts the answer | `lint-static (early-close-reader)` | ungated |
| `errexit-bang` | no `!` statement outside the LAST statement of any `*.bats` body in the repo, and none handing its verdict on via a `;`, an async `&` or an `\|\| true` anywhere in it, continuation lines included. An `\|\|` with a live right operand still exempts the statement -- `! A \|\| return 1` fails its test from any position -- unless a RIGHT operand -- one after such an operator, never the leading `!` that made the statement a candidate -- is itself `!`-inverted: bash exempts THAT from errexit too, so `! A \|\| ! B` aborts nothing and is judged by position and by `;` like any other statement. It is the list's FINAL operand that decides whether it can abort, and the whole class is declined rather than only the inert half, so a live chain (`! A \|\| ! B \|\| return 1`, which DOES abort from a non-final position) is reported alongside it: telling them apart needs the chain evaluated, not read, and that over-report costs one allow region. The judgement is made on the FOLDED statement: physical lines are joined while the text is INCOMPLETE -- a `\` continuation, a quote or a `(` still open, or a `\|` / `\|\|` / `&&` / `\|&` still waiting for its right operand -- and the scan then runs once from the first character, so a separator inside a `( ... )` is the argument's wherever the `(` and its `)` sit. The `\` join is a SPLICE, matching bash: `! grep -q A\` over `#b f; true` is the one word `A#b` and a live `; true`, while `! grep -q A \` over the same text is a comment. The fold answers where a statement STARTS as well as where it ends: a `!` line read in as an operator's right operand -- `echo a \|\|` over `! grep -q A f; true` -- is judged from the line the `!` opens on, over the span that begins there, so the `\|\|` in front of it stays the `echo`'s rather than being read as the `!`'s own hand-off. A statement still unfinished where its body closes is REPORTED when that span is a `!` one, or when an unterminated quote or `(` folded a line opening with `!` into it; otherwise it is unreadable but provably hid nothing this rule judges, which is stated in the driver rather than claimed away. Every row that judges a `!` line is silenced by the allow region; the two that report the FILE instead -- a body left open at EOF, an unbalanced allow marker -- are deliberately not, because the mechanism they are about must not be able to silence them. What is NOT modelled is listed in the driver header with the direction each errs in: `$'...'`, backticks, a heredoc's fixture text and a `!` that ends a compound command ending the body (#991) all OVER-report, which is the refusing direction. The ones that MISS are a `}` at column 0 inside a heredoc, a CRLF file (#990), and the `{ }` half of that same compound-command entry (#991): a brace group carries the `!` exemption out of itself, so a one-line `{ ! cmd; }` away from the body's last statement is inert in bash and unreported, because the scan needs `!` as the statement's first token and there it is `{`. Those two are not every miss the lint has, and the list does not claim to be: the `\|\|` narrowings the driver states separately miss as well -- an always-zero GROUP (`\|\| { true; }`, `\|\| ( true )`) and an operand outside the closed set of always-zero builtins that cannot fail in practice (`\|\| echo x`) are inert and go unreported, and a `;` behind either is swallowed with them (#992). A list whose FINAL operand cannot fail is inert in EVERY position, so position cannot catch it either -- `! A && ! B \|\| echo x` as a body's last statement is such a case, and a spec PINS it as a known miss so it cannot change shape unnoticed; that spec is inverted when #992 lands. The population is derived by walking the tree, not listed: `test/bats/` and the shipped `dist/test/bats/smoke/` both count | `lint-static (errexit-bang)` | ungated |
| `derived-figures` | a figure a document repeats matches the code that defines it | `lint-static (derived-figures)` | ungated |
| `i18n-orphan` | no identifier-shaped token in a translation's code spans that `README.md` never names | `lint-static (i18n-orphan)` | ungated |
| `changelog-entry` | no `[Unreleased]` changelog entry over 700 chars (measured whitespace-collapsed over the whole entry), no entry repeating another's lead bullet, no `### <category>` heading opening twice in one release block | `lint-static (changelog-entry)` | ungated |

`lint-static` is a matrix so a red check names the lint that failed, and it is
ungated because several of its entries (`adr-numbering`, `adr-structure`,
`readme-sync`) are breakable by a change `classify` scores as doc-only -- a `code_changed` gate
would skip them on exactly the PR they exist to catch. Every entry but
`hadolint` runs host-direct on a plain runner via `test.sh --<tool>-only`; the
hadolint binary exists only in the test-tools image, so it keeps its own job.

Adding a lint to `_LINT_TOOLS` without giving it a CI job fails the
completeness guard in `test/bats/unit/self_test_yaml_spec.bats`. That guard,
not this table, is what keeps the list honest -- four lints shipped local-only
before it existed, and `home-literal` / `bash-source-guard` /
`early-close-reader` each joined the matrix in the same change that introduced
them.

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
