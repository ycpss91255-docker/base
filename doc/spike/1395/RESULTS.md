# base#1395 slice 1: batching spike results

SPIKE ONLY. This branch is never merged. Its code changes are throwaway, and
they exist only so that the runs below could be made.

This is the second version of this file. The first version used 15 warm
rounds in a fixed order, compared three output files with the timestamp
lines removed, and had no valid cold baseline. A protocol review found
those gaps. Section "Protocol review" lists each one and what was done
about it. The numbers below come from the reruns. The first set is kept in
`results/warm-rr.tsv` and `results/cold.tsv`, and it agrees with the
reruns on every reading.

## What was measured

The same `setup.sh apply --base-path <repo>` was run in every mode. `<repo>`
is always the same path (`$SPIKE_WORK/repo`). It is recreated before every
run with `dist/setup.toml` copied in as `setup.toml` and a two-stage
Dockerfile, so every run is a first generation. The chain is the shipped
template plus a repo layer identical to it, with no local layer. Wall time
covers the whole process. The harness is `measure.sh`. The raw rows are in
`results/*.tsv`, and `summarize.py` computes the statistics
(`results/summary.txt`).

| Mode | Engine calls per apply (observed with a logging docker shim, `results/call-counts.txt`) |
|---|---|
| `current-docker`: today, no batching, bridge forced through `docker run` | 15 `docker run` (11 `--merge --kv`, 2 `--tables`, 2 `--empty-families`), 15 `docker image inspect`, 1 `docker info` |
| `batch-docker`: Python bridge `--batch` (the patch on this branch) | 1 `docker run`, 1 `image inspect`, 1 `info` |
| `go-docker`: Go prototype in a container | 1 `docker run`, 1 `image inspect`, 1 `info` |
| `go-native`: Go prototype binary on the host | 0 `docker run`, 1 `info` |
| `floor`: views replayed from a recording, so the engine costs nothing | 0 `docker run`, 1 `info` |
| `current-native`: bridge on PATH (the CI / test-tools shape) | 15 bridge execs (11 `--merge`, 2 `--tables`, 2 `--empty-families`) |
| `batch-native`: `--batch`, bridge on PATH | 1 bridge exec |
| `current-docker-fixed`: `current-docker` with the first-build log record sent to stderr (cold only, see the finding below) | as `current-docker` |

**Go rows are a cost proxy, not a comparable full apply.** The prototype
does not speak the bridge's view protocol (see `MATRIX.md`), so it cannot
drive `apply` by itself. In `go-docker` and `go-native`, the one engine call
runs the prototype's `env` over the same layers. That call parses, merges,
validates and renders them, and its output is discarded. `apply` then reads
the views from the recorded Python `--batch` output. These rows measure what
a Go engine call costs in that position. They do not show that Go produces
the same views.

## Correctness, checked separately from timing

- **Every output file, unfiltered, with a frozen clock** (`measure.sh
  gate`, `results/gate.txt`). A `date` shim on PATH answers for one fixed
  instant, so no line is removed before comparing. After apply, the repo
  directory holds 7 files (`.env`, `.env.generated`, `.env.local`,
  `compose.yaml`, `.docker.xauth`, `Dockerfile`, `setup.toml`). Each file's
  mode and sha256 go into a manifest. The manifest digest is
  `4b4a3173ae1233dd` in all 7 modes, and every run had rc 0. `setup.toml`
  after the run hashes the same as `dist/setup.toml`, so apply did not
  rewrite its input.
- **Every view the batch serves equals the live single-view call**
  (`check-views.sh`, `results/views.txt`). For each cached view, the script
  runs the call it replaces with the cache emptied, and compares stdout
  bytes, stderr bytes and the exit status. On the timed fixture this gave
  11 views and 0 mismatches, both natively and through docker. On a
  divergent three-layer fixture (a legacy alias, a stage table, a fieldless
  `[[volumes]]`, and a local layer with an unknown `[[typo]]` array, so
  some views exit 1) it gave 16 views and 0 mismatches on both engines.
- **The batched apply makes no live call behind the cache.** The docker
  shim saw exactly 1 `docker run` in `batch-docker`.
- **The same Go binary in both Go modes.** The sha256 of the native binary
  equals that of `/setupgen` copied out of `spike-setupgen:d0daf413bd53`
  (`331cc7d6...`, `results/env.txt`).

## Results

Host: i9-14900K (32 threads), Docker 29.7.2, buildx v0.36.1
(`results/env.txt`). Other tenants of the host ran CPU-heavy containers
during both sessions. `results/*.meta` records the top consumers at the
start and end of each set (up to about 3.8 cores, and once about 28 cores
at the end of the cold rerun). Every row records load1. Load1 stayed
between 2.1 and 5.8, below the 8.0 that is a quarter of the logical CPUs,
in every timed run of the reruns. Because the load was not under this
spike's control, every set is interleaved. In the warm set, each round runs
every mode once. Round r starts at mode (r - 1) mod 7, and every second
round runs in reverse, so no mode always sits in the same position or
always follows the same mode. The sequential set from the first session
(`results/warm-sequential.tsv`) shows why this matters: `floor` had a
median of 938 ms there and 323 ms interleaved.

Statistics: medians and quartiles come from `statistics.quantiles(n=4)`
(the "exclusive" method), over runs that exited 0. Failed runs are counted
separately. "Paired" is the median of the per-round difference between two
modes in the same round.

### Warm (engine image present), 20 rotated rounds (`results/warm-rr2.tsv`)

| Mode | Median ms | p25 to p75 | min | n |
|---|---|---|---|---|
| current-docker | **6139** | 5982 to 6987 | 5922 | 20 |
| batch-docker | **698** | 686 to 728 | 669 | 20 |
| go-docker | **671** | 656 to 689 | 644 | 20 |
| go-native | **314** | 308 to 324 | 302 | 20 |
| floor | 312 | 309 to 320 | 288 | 20 |
| current-native | **513** | 495 to 550 | 477 | 20 |
| batch-native | **336** | 326 to 565 | 321 | 20 |

Paired differences, same round:

| Comparison | What it isolates | Median ms (p25 to p75) | First mode slower in |
|---|---|---|---|
| current-docker minus batch-docker | batching, docker | **5443** (5287 to 6025) | 20 of 20 |
| batch-docker minus go-docker | language, same container boundary | **34** (8 to 53) | 16 of 20 |
| go-docker minus go-native | the container boundary | 352 (345 to 375) | 20 of 20 |
| current-native minus batch-native | batching, native | **172** (92 to 189) | 16 of 20 |
| batch-native minus go-native | language, native | **20** (12 to 130) | 18 of 20 |
| batch-native minus floor | the whole Python engine share | 20 (14 to 259) | 18 of 20 |
| go-native minus floor | the whole Go engine share | 4 (-2 to 13) | 14 of 20 |

The first set (15 rounds in a fixed order) gave 6501 / 716 / 695 / 320 /
323 / 531 / 340 ms for the same seven modes. In that set, batch-docker
minus go-docker was 6 ms (Go faster in 8 of 15 rounds). With rotation and
20 rounds, the language gap shows up as consistent: Go is faster by about
20 to 35 ms, in 16 to 18 of 20 rounds. That is 5 to 7 percent of a
batched apply.

### Cold, 10 rotated rounds (`results/cold2.tsv`)

Cold means that the engine image tag was removed **and** the whole cache of
a dedicated buildx builder (`spike1395`, docker-container driver,
`default-load=true`) was pruned before each run, so base layers were
fetched from the registry again. The modes rotate their start position in
each round.

| Mode | Median ms | p25 to p75 | rc != 0 |
|---|---|---|---|
| current-docker (unpatched) | none valid | (time to failure: 7764) | **10 of 10** (see the finding) |
| current-docker-fixed | **11524** | 11007 to 13260 | 0 |
| batch-docker | **5983** | 5852 to 6257 | 0 |
| go-docker | **8262** | 7454 to 9358 | 0 |

Paired: current-docker-fixed minus batch-docker is 5638 ms (slower in 10
of 10 rounds). batch-docker minus go-docker is -2156 ms, so Go was slower
in 10 of 10 rounds.

From the first session, image build alone (`results/cold.tsv`, 10 runs):
bridge 5389 ms, Go 7450 ms. Image sizes: bridge `toml-bridge:c67e107678b7`
is 53,983,346 B. The Go image `spike-setupgen:d0daf413bd53` is 3,186,848 B,
which is the static binary.

Native modes have no cold row. The binary or the bridge is either
installed already (test-tools) or it is not used. Native Go's real
delivery cost (a toolchain or a downloaded binary per architecture) was
not measured.

### CI-relevant time

- The unit and coverage tiers run inside test-tools, where `toml-bridge`
  is on PATH. That is the `current-native` shape: **513 ms per apply.
  Batching makes it 336 ms (paired saving 172 ms per apply).** How many
  bridge calls one CI run makes was **not measured**, so the saving per CI
  run is not stated. That host Python is 3.10.12, and the image runs
  3.13.13.
- The self-test acceptance jobs pin `TOML_BRIDGE_IMAGE`
  (`.github/workflows/self-test.yaml:1369`) and use the docker path, which
  is the `current-docker` shape. They were not timed on GitHub runners.
- For scale: the latest `main` CI run (40460923101, `f2a0fd1e`) took 410 s
  wall. Its longest job was `coverage (7/12)` at 349 s.

## Finding: the first `setup apply` on a host without the bridge image fails

This was observed on unpatched `origin/main` (`f2a0fd1e`). It failed in
all 10 cold `current-docker` runs of the first session, again in 10 of 10
in the rerun, and once more with `LOG_FORMAT=text`. The run exits 1 with
`apply_unknown_table`, and the "table" it names is the
`toml_bridge_building` log record.

- `_toml_bridge_ensure_image` logs `toml_bridge_building` with `_log_info`,
  and `_log_info` writes to **stdout** (`dist/script/docker/lib/log.sh:18`).
- The first build happens inside `_cll_kv="$(toml_bridge_merge --kv ...)"`
  (`conf.sh:566`), so that record becomes a row of the merged KV view.
  `_setup_conf_check_known` then refuses it as an unknown table.
- A second run (image now present) succeeds.

The rerun adds a test of that cause. The spike patch lets
`TOML_BRIDGE_SPIKE_LOG_STDERR=1` send only that one record to stderr. With
it (`current-docker-fixed`), the same cold run passes 10 of 10. The first
real use of today's docker path therefore costs a median of **11.5 s**,
and the batched path costs 6.0 s.

In the batched mode, the build runs in the parent shell (the prefetch),
where stdout is not captured. That is why `batch-docker` passes cold. This
happens because of where the call sits. It is not a fix. The defect should
be fixed on its own, before or together with a batching slice.

## Go / no-go against final-en.md sec. 9, decision 1

Decision 1 says: *"Go becomes worth it if batched native or test-tools use
shows a clear win, or if the strict schema removes a bug class that slice 0
cannot."* It sets no number. This spike did not declare a threshold before
measuring. The reading below uses the size of the gap compared with the
batching gain and the cold penalty, and the reader can check it against
any threshold.

1. **Batched native and test-tools use: a small, consistent gap, not a
   clear win.** Native Go is 314 ms and native batched Python is 336 ms,
   against a 312 ms floor. Paired, Go saves 20 ms per apply (18 of 20
   rounds). The Python engine's whole share of a batched native apply is
   about 20 ms. Go cannot save more than that.
2. **Containerised: the same picture.** Go is 671 ms and batched Python is
   698 ms. Paired, Go saves 34 ms per apply (16 of 20 rounds). In a
   container, start-up (about 350 ms, go-docker minus go-native) costs
   ten times more than the language difference.
3. **Cold: Go is worse.** First use costs 8262 ms against 5983 ms (Go
   slower in 10 of 10 rounds), because the Go builder image is heavier
   (image build alone: 7450 against 5389 ms).
4. **Batching is the win, and it does not depend on the language.** Warm
   docker apply drops from 6139 to 698 ms (-89%, paired saving 5443 ms,
   20 of 20 rounds), and docker runs drop from 15 to 1. Native apply drops
   from 513 to 336 ms. First use drops from 11.5 s to 6.0 s. The output is
   byte-identical with the clock frozen, and every served view equals its
   live call.
5. **Strict schema.** The matrix shows the prototype's strictness rejecting
   input that today's bridge accepts on purpose (rows 7a to 7c), and
   refusing the legacy alias and the stage tables (4a, 5b). These are
   behaviour changes that need decisions. None of them is a bug class that
   only Go removes. Positioned unknown-key errors (row 3) are real
   ergonomics, but the bridge already refuses an unknown array in the views
   `apply` reads.

**Reading: NO-GO for Go now.** Decision 1 stays at "defer". Go is
measurably faster per call, by 20 to 35 ms, which is under 1 percent of
what batching saves in docker. It is about 2.2 s slower on first use, and its
views do not yet match. **GO for batching as its own slice in Python.**
The spike patch shows the shape: one `--batch` call, plus a cache in the
shell that a changed file invalidates. A production version needs a
content-identity key instead of size, mtime and inode, a defined failure
path, and tests. Fix the first-use stdout defect separately.

## Protocol review: risks raised and how each was handled

| Risk | Handled in this version |
|---|---|
| Batching gains credited to Go | Batching and language are separate paired rows (A to B, B to C, C to D). |
| Go adapter incomplete: full apply not comparable | Go rows are labelled as a cost proxy. No Go fidelity claim is made. `MATRIX.md` shows where it differs. |
| Fixed run order biases interleaving | Rerun with rotated and reversed order, 20 rounds (was 15, fixed order). |
| Output equality after removing timestamp lines, and only 3 files | Rerun as `measure.sh gate`: frozen clock, every file in the repo dir, modes and bytes, nothing removed. |
| Final output can hide a missing view | `check-views.sh`: every batched view is compared with its live call on two fixtures and both engines. |
| Native and container Go binaries may differ | sha256 compared, identical. |
| Failed runs inside the statistics | `summarize.py` takes medians over rc 0 only and reports failures separately. The cold baseline is now `current-docker-fixed`. |
| Cold definition: clean download versus only removing the tag | Each cold run removes the tag and prunes the whole builder cache. Base layers are fetched again. Kept as before. |
| `TOML_BRIDGE_IMAGE` bypasses provisioning | Not set in any run. Builds were observed in cold runs (the cold times include them). |
| Load and frequency | Load1 recorded per run, top CPU tenants recorded per set, interleaving. The governor, frequency and temperature were **not** recorded. |
| Quartile method not stated | Stated above. |
| Parser parity (duplicate keys, integer limits, dates, CR/LF transport) | **Not covered.** Each would add matrix rows. None would change the Go reading, which rests on cost. |
| CI time | Native apply cost is measured. A whole CI job was **not** timed. |

## Limits of this spike

- The Go rows replay Python's views. Go output fidelity to the bridge
  protocol is not shown, and `MATRIX.md` shows that it would differ.
- The native Python modes use host Python 3.10.12 with tomli 2.4.1. The
  image uses 3.13.13.
- One timed fixture: the template chain with two layers and no local
  layer. A larger chain would add views to the one call, not calls.
- Cold uses a docker-container buildx builder with `default-load`. The
  rerun's builder ran buildkit v0.33.1. A user's host normally builds with
  the `docker` driver, which skips the load export, so absolute cold
  numbers may differ. All the cold rows share the method.
- Load from other tenants of the host was not under this spike's control.
  The CPU governor, frequency and temperature were not recorded.
