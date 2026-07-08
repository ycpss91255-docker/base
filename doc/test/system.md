# System Tests (opt-in)

System specs under `test/bats/system/`: **5 tests**.

> **Not** part of the `just test` self-test grand total -- these require
> host docker access and are opt-in. See [TEST.md](TEST.md) for the index
> across all test levels.

ISTQB taxonomy (ADR-00000018): the **System** level exercises the whole
built image end-to-end; these specs are the **Regression** type -- they
guard the previously-fixed runtime smoke-gate defects (#249 / #243).
They replace the retired `behavioural` category.

System is base's OWN image / build-gate perspective (technical specs),
distinct from the **Acceptance** level ([acceptance.md](acceptance.md)),
which verifies what the downstream consumer receives (the scaffolded
framework + its `just` UX, UAT/OAT) via the host-driven `acceptance` CI
job. Two adjacent top levels, two vehicles: System = these bats specs on
the `ci-system` compose service; Acceptance = the `acceptance` job.

The System level has a second, CI-only vehicle for the **build-gate
mechanism itself**: the `worker-selftest` job in `self-test.yaml` (#802).
Base only checked its shared reusable worker `build-worker.yaml`
*statically* (actionlint + the structural `build_worker_yaml_spec.bats`
grep); it was never actually *run* in base's own CI, so a semantic break
(an input that became required with no caller passing it, a broken cache
change, a matrix condition that produces no jobs, a removed build step)
surfaced only when a downstream ran the worker in production. The
`worker-selftest` job closes that gap by invoking the worker end-to-end via
a local reusable-workflow call (`uses: ./.github/workflows/build-worker.yaml`)
against a minimal fixture (`test/fixtures/build-worker/Dockerfile` -- a
trivial alpine no-op that builds in seconds; the point is to exercise the
orchestration, not build a real image). Deliberately breaking the worker
turns it red. It is gated on `system_relevant` and joins the `ci-rollup`
aggregator + the `release` gate, so it is required before a tag. The
worker's own extractable logic is pushed further down the pyramid to Unit
level (`build_worker_compute_matrix_spec.bats` / `build_worker_cache_scope_spec.bats`)
and the caller-contract preflight to Acceptance (#800), so this job only
proves the residual orchestration wires together and really builds. This
vehicle is CI-only (a reusable-workflow call runs only on GitHub); its
wiring is locked by `self_test_yaml_spec.bats` and its real execution is the
CI job.

Specs that drive `docker buildx build --target runtime-test` against
synthesized fixtures so the runtime smoke gate in `Dockerfile.example`
is genuinely exercised end-to-end -- not just static-grep asserted
in `template_spec.bats`. Issue #249.

Excluded from the self-test grand total (see [TEST.md](TEST.md)) because they require host
docker access (mounted via the `ci-system` compose service)
which the default `ci` service does NOT provide. Run with `just
test system` locally, or via the dedicated
`System Regression Test` job in `self-test.yaml` on CI. Each test
invokes one `docker buildx build` (~5-15s amd64, ~30-60s arm64
QEMU); the dedicated `template-system` buildx builder
(created/pruned per test.sh run) isolates the cache from the host's
default context.

### test/bats/system/runtime_test_smoke_spec.bats (5)

| Test | Description |
|------|-------------|
| `runtime-test build succeeds with default smoke command` | Baseline `whoami && bash --version` ARG default works |
| `runtime-test build succeeds with && chain override (#243 word-split regression)` | Wrapper preserves shell operators |
| `runtime-test build succeeds with bash parameter expansion override (#249 dash-source regression)` | `${var:offset:length}` works (would fail under `sh -c`) |
| `runtime-test build succeeds with bash [[ test operator override (#249)` | `[[` works (sister bash-only regression guard) |
| `runtime-test build FAILS when smoke command exits non-zero (gate-fires assertion)` | Negative case: the gate actually gates |
