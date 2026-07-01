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
