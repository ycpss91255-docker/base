# Behavioural Tests (opt-in)

Behavioural specs under `test/bats/behavioural/`: **5 tests**.

> **Not** part of the `just test` self-test grand total — these require
> host docker access and are opt-in. See [TEST.md](TEST.md) for the index
> across all test types.

Specs that drive `docker buildx build --target runtime-test` against
synthesized fixtures so the runtime smoke gate in `Dockerfile.example`
is genuinely exercised end-to-end — not just static-grep asserted
in `template_spec.bats`. Issue #249.

Excluded from the self-test grand total (see [TEST.md](TEST.md)) because they require host
docker access (mounted via the `ci-behavioural` compose service)
which the default `ci` service does NOT provide. Run with `just
test behavioural` locally, or via the dedicated
`Behavioural Test` job in `self-test.yaml` on CI. Each test
invokes one `docker buildx build` (~5-15s amd64, ~30-60s arm64
QEMU); the dedicated `template-behavioural` buildx builder
(created/pruned per test.sh run) isolates the cache from the host's
default context.

### test/bats/behavioural/runtime_test_smoke_spec.bats (5)

| Test | Description |
|------|-------------|
| `runtime-test build succeeds with default smoke command` | Baseline `whoami && bash --version` ARG default works |
| `runtime-test build succeeds with && chain override (#243 word-split regression)` | Wrapper preserves shell operators |
| `runtime-test build succeeds with bash parameter expansion override (#249 dash-source regression)` | `${var:offset:length}` works (would fail under `sh -c`) |
| `runtime-test build succeeds with bash [[ test operator override (#249)` | `[[` works (sister bash-only regression guard) |
| `runtime-test build FAILS when smoke command exits non-zero (gate-fires assertion)` | Negative case: the gate actually gates |

