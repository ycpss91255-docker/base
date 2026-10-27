# base#1395 slice 1: batching spike results

SPIKE ONLY. This branch is never merged. Its code changes are throwaway, and
they exist only so that the runs below could be made.

## What was measured

The same `setup.sh apply --base-path <repo>` was run in every mode. `<repo>`
is a fresh directory holding `dist/setup.toml` copied as `setup.toml` and a
two-stage Dockerfile, so the chain is the shipped template plus a repo layer
identical to it. The repo directory was recreated before every run. Wall time
covers the whole process. The harness is `measure.sh`, the raw rows are in
`results/*.tsv`, and the medians come from `summarize.py`
(`results/summary.txt`).

| Mode | Engine calls per apply (observed, `results/call-counts.txt`) |
|---|---|
| `current-docker`: today, no batching, bridge forced through `docker run` | 15 `docker run` (11 `--merge --kv`, 2 `--tables`, 2 `--empty-families`), 15 `docker image inspect`, 1 `docker info` |
| `batch-docker`: Python bridge `--batch` (the patch on this branch) | 1 `docker run`, 1 `image inspect`, 1 `info` |
| `go-docker`: Go prototype in a container | 1 `docker run`, 1 `image inspect`, 1 `info` |
| `go-native`: Go prototype binary on the host | 0 `docker run`, 1 `info` |
| `floor`: views replayed from a recording, so the engine costs nothing | 0 `docker run`, 1 `info` |
| `current-native`: bridge on PATH (the CI / test-tools shape) | 15 bridge execs (11 `--merge`, 2 `--tables`, 2 `--empty-families`) |
| `batch-native`: `--batch`, bridge on PATH | 1 bridge exec |

All seven modes write byte-identical `.env`, `.env.generated` and
`compose.yaml` once the generation timestamp lines are dropped
(`measure.sh outputs`). Hashes 81139708..., 79ab3905... and 40cfd805... were
the same in every mode.

**What the Go rows measure.** The prototype does not speak the bridge's view
protocol (see `MATRIX.md`), so it cannot drive `apply` on its own. In
`go-docker` and `go-native`, the single engine call runs the prototype's
`env` over the same two layers. That call parses, merges, validates and
renders them, and its output is discarded. `apply` then reads the views from
the recorded Python `--batch` output. So the Go rows measure the **cost** of
a Go engine call in that position, not Go output fidelity.

## Results

Host: i9-14900K (32 threads), Docker 29.7.2, buildx v0.36.1
(`results/env.txt`). Load average 1 was 2.4 to 8.7 over the session. The CPU
load came from containers this spike did not start (`acd-study-*`, up to
about 3.5 cores). Warm runs were interleaved (each round runs every mode
once) so that this load lands on every mode alike. The sequential warm set
(`results/warm-sequential.tsv`) shows what happens otherwise: `floor` has a
median of 938 ms there and 323 ms interleaved.

### Warm (engine image present), 15 interleaved rounds

| Mode | Median ms | p25 to p75 | min | Median minus floor (derived) |
|---|---|---|---|---|
| current-docker | **6501** | 6091 to 7088 | 6050 | 6178, which is about 412 per call over 15 |
| batch-docker | **716** | 689 to 914 | 676 | 393 |
| go-docker | **695** | 673 to 1015 | 654 | 372 |
| go-native | **320** | 313 to 697 | 299 | about 0 (below the floor median, within noise) |
| floor | 323 | 315 to 555 | 289 | 0 |
| current-native | **531** | 504 to 869 | 484 | 208, which is about 14 per call over 15 |
| batch-native | **340** | 333 to 518 | 316 | 17 |

### Cold, 10 interleaved rounds

Cold means the engine image tag was removed **and** the whole cache of a
dedicated buildx builder (`spike1395`, docker-container driver,
`default-load=true`) was pruned before each run, so the base image layers
were fetched from the registry again.

| Mode | Median ms | p25 to p75 | rc != 0 |
|---|---|---|---|
| current-docker | 8346 | 7529 to 8968 | **10 of 10** (see the finding below) |
| batch-docker | **5880** | 5650 to 6219 | 0 |
| go-docker | **8586** | 8312 to 9020 | 0 |
| image build alone: bridge | 5389 | 5190 to 5702 | 0 |
| image build alone: Go | 7450 | 7122 to 8369 | 0 |

Native modes have no cold case here. The binary or the bridge is either
installed already (test-tools) or it is not used.

Image sizes: bridge `toml-bridge:c67e107678b7` is 53,983,346 B. The Go image
`spike-setupgen:d0daf413bd53` is 3,186,848 B, and so is the static Go binary.

### CI-relevant time

- The unit and coverage tiers run inside test-tools, where `toml-bridge`
  is on PATH. That is the `current-native` shape: **531 ms per apply,
  about 14 ms of it per bridge call above the floor.** Batching makes it
  **340 ms** (-191 ms per apply). How many bridge calls one CI run makes
  was **not measured**, so the saving per CI run is not stated.
- The self-test acceptance jobs pin `TOML_BRIDGE_IMAGE`
  (`.github/workflows/self-test.yaml:1369`) and use the docker path, which
  is the `current-docker` shape. They were not timed on GitHub runners.
- For scale: the latest `main` CI run (40460923101, `f2a0fd1e`) took 410 s
  wall. Its longest job was `coverage (7/12)` at 349 s.

## Finding: the first `setup apply` on a host without the bridge image fails

This was observed on unpatched `origin/main` (`f2a0fd1e`). It was reproduced
in all 10 cold `current-docker` runs, and once more with `LOG_FORMAT=text`.
The run exits 1 with `apply_unknown_table`, and the "table" it names is the
`toml_bridge_building` log record.

- `_toml_bridge_ensure_image` logs `toml_bridge_building` with `_log_info`,
  and `_log_info` writes to **stdout** (`dist/script/docker/lib/log.sh:18`).
- The first build happens inside `_cll_kv="$(toml_bridge_merge --kv ...)"`
  (`conf.sh:566`), so that record becomes a row of the merged KV view.
  `_setup_conf_check_known` then refuses it as an unknown table.
- A second run (image now present) succeeds: `rc=0`, 7486 ms.

In the batched mode, the build runs in the parent shell (prefetch), where
stdout is not captured. That is why `batch-docker` cold passes 10 of 10. This
is an accident of where the call sits, not a fix. The defect should be fixed
on its own (for example, provisioning messages go to stderr). The
`current-docker` cold median above is therefore the time to that failure.
Adding a warm rerun, a user's real first use costs about 8346 + 6501 =
14.8 s (derived, not measured as one unit).

## Go / no-go against final-en.md sec. 9, decision 1

Decision 1 says: *"Go becomes worth it if batched native or test-tools use
shows a clear win, or if the strict schema removes a bug class that slice 0
cannot."*

1. **Batched native and test-tools use: no clear win.** Native Go is 320 ms
   and native batched Python is 340 ms, against a 323 ms floor. The Python
   engine's whole share of a batched apply is about 17 ms (5%). Go cannot save
   more than that.
2. **Containerised: no win.** Go is 695 ms and batched Python is 716 ms. The
   21 ms gap is inside both interquartile ranges. In a container, start-up
   dominates whatever the language.
3. **Cold: Go is worse.** First use costs 8586 ms against 5880 ms, because the
   Go builder base is heavier (image build alone: 7450 against 5389 ms).
4. **Batching is the win, and it does not depend on the language.** Warm
   docker apply drops from 6501 to 716 ms (-89%), and docker runs drop from
   15 to 1. The output is byte-identical. The evaluation predicted about
   4.8 s from arithmetic. Measured, the saving is 5.8 s.
5. **Strict schema.** The matrix shows the prototype's strictness rejecting
   input that today's bridge accepts on purpose (rows 7a-7c), and refusing
   the legacy alias and the stage tables (4a, 5b). These are behaviour
   changes that need decisions. None of them is a bug class that only Go
   removes. Positioned unknown-key errors (row 3) are real ergonomics, but
   the bridge already refuses an unknown array in the views `apply` reads.

**Reading: NO-GO for Go now.** Decision 1 stays at "defer". **GO for batching
as its own slice in Python.** It takes about 89% of warm `apply` time and
does not need the engine to change. The spike patch shows the shape: one
`--batch` call, plus a cache in the shell that a changed file invalidates. A
production version needs a content-identity key rather than size, mtime and
inode, a defined failure path, and tests. Fix the first-use stdout defect
separately, before or with that slice.

## Limits of this spike

- The Go rows replay Python's views. Go output fidelity to the bridge
  protocol is not shown, and `MATRIX.md` shows it would differ.
- The native Python modes use host Python 3.10.12 with tomli 2.4.1. The
  image uses 3.13.13.
- One fixture: the template chain with two layers present and no local
  layer. A larger chain would add views to the one call, not calls.
- Cold uses a docker-container buildx builder with `default-load`. A user's
  host normally builds with the `docker` driver, which skips the load
  export. Absolute cold numbers may differ. The bridge and Go rows share
  the method.
- Load from other tenants of the host was not under this spike's control.
  It is recorded per run (`load1`, `load5` columns).
