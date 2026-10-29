# Config generator in Go

> Serves: PRD invariant 2 (never fail silently) -- one typed program reads, validates, edits and renders the configuration, so an unknown key, a wrong type or a lost entry is refused at load with file and key named instead of being dropped at a flattening seam.

- **Date:** 2026-10-29
- **Status:** Accepted
- **Relates to:** issue #1395 (this decision; owner decision comment of 2026-10-29), #1435 (speed and size evaluation, folded into #1395), #1407 (batching spike, draft, never merged), #1363 (format-preserving writes), #1176 (toml-bridge in its own repo, still open)
- **Amends:** ADR-00000037, the **Containerised parsing** section (its two paragraphs and the tomli paragraph that follows), the Consequences bullet "The `_ini_tokenize` bash parser is replaced by a containerised TOML bridge", and the closing bullet on JSON Schema validation. Everything else in ADR-00000037 stands: the four files and their names, key-level scalar merge, whole-array replace, the #1137 amendment (an empty array defines the array; only an absent key inherits), the #1235 amendment, and generated outputs in Docker-native formats. ADR-00000036 (caller-selected layers and output directories) is not reopened.

## Context

Today the configuration goes through three steps:

1. Bash calls `toml_bridge_parse` or `toml_bridge_merge` (`dist/script/docker/lib/toml_bridge.sh`).
2. Those run `dockerfile/toml_bridge.py` in a `docker run` of the `toml-bridge:<12 hex>` image. The image is built at first use from a content digest of its Dockerfile and every file it COPYs.
3. The bridge flattens the TOML into `section<TAB>key<TAB>value` rows (`--kv`), numbering array-of-tables entries back into `mount_1`, `port_2` and so on. About 20,000 lines of shell under `dist/script/docker/lib/` then rebuild the configuration from those rows and render `.env` and `compose.yaml`.

Six output modes (`--kv`, `--empty-arrays`, `--tables`, `--empty-families`, `--entries` and JSON) exist to carry back what the flattening loses.

Two evaluations were run before this decision.

**Speed and size (the evaluation report on #1435, which lives outside this tree; re-measured by an independent verifier at `01dee226`):**

- **Container start is the cost, not the parser.** One bridge call costs about 490 ms whatever the language (n=20): Python 494 ms, Rust 496 ms, Go 483 ms, and a bare `alpine cat` 500 ms. Native parse time of `setup.toml` is Python 24.6 ms, Rust 2.1 ms and Go 2.6 ms. Swapping the language therefore saves at most about 0.36 s of a `setup apply` that takes 9.8 to 10.2 s.
- **The repeated calls are the waste.** One `setup apply` runs **16** bridge `docker run`s. Ten of them are the identical call `--merge --kv dist/setup.toml setup.toml`, so **9** are removable duplicates, worth about 4.4 s. Each call also runs a `docker image inspect` (0.39 to 0.52 s in total), because `conf.sh` calls the merge inside `$(...)` and the resolved-image memo does not survive the subshell.
- **The batching spike (#1407) confirms it.** Warm `setup apply` medians: current 6139 ms, batched Python in docker 698 ms, a Go prototype in docker 671 ms, Go native 314 ms, zero-cost floor 312 ms. Cold medians: current with the first-build log record sent to stderr (the #1400 fix; unpatched, all 10 cold runs failed) 11524 ms, batched Python 5983 ms, Go 8262 ms.
- **Image size:** the current Python image is 54 MB (45.2 MB without tomli, 32.6 MB with a stdlib trim). Rust is 562 kB and Go is 2.82 MB.
- **First setup on a fresh host** (the original measurement; the verifier could not reproduce a fresh host): Python about 8 s, Go about 12 s, Rust about 28 to 30 s. The builder left on disk is none for Python, 253 MB for Go and 1.03 GB for Rust (builder sizes verified). With the base images already local, `--no-cache` builds take Python 4.2 s, Go 3.7 s and Rust 9.8 s.
- **Equivalence of partial ports** on a 741-fixture corpus: Rust 702 identical, Go (BurntSushi) 704. Every error text differs: 0 of 35 error fixtures match. Both ports accept TOML 1.1 where `tomllib` accepts only 1.0. Go sorts the keys inside array-of-tables entries.
- **Dependencies:** Go needs one module (BurntSushi/toml v1.6.0, a 2-line `go.sum`). Rust locks 20 crates besides the root and compiles 13 of them, and no existing pin resolver covers any of them.

**Stability (the evaluation comment on #1395, outside this tree; 62 config bugs from this repo's history, two independent classification passes, verified fix diffs):**

- **The design does the work, not the language.** Design D is one program that loads, merges, validates and emits the configuration, with a typed schema that refuses unknown keys. It fully prevents 10 of the 62 bugs and partly prevents 26. The other 26 (spec, TUI, migration, text drift) do not depend on the language.
- **Earliest catch stage per language:**

  | Stage | Python+schema | Go | Rust |
  |---|---:|---:|---:|
  | D (removed by the design) | 8 | 8 | 8 |
  | pkg (static binary) | 0 | 1 | 1 (needs a musl target) |
  | P (refused at parse or load) | 14 | 14 | 14 |
  | C (compile error) | 0 (1 with ruff, not run in CI) | 1 | 1 |
  | T (needs a runtime test) | 36 | 35 | 35 |
  | N (delivery boundary) | 4 | 3 | 3 |

- **The language effect is 0 to 2 bugs of 62.** Go and Rust tie at every firm stage. Rust's only extra catch is an idiom (#840, #1094 item 5: destructuring without `..`). Python reaches parity once ruff or pyflakes and mypy run in CI, which they do not today.
- **Ten "partly" bugs become "yes" only if the writers also call the model:** the `set`/`add`/`remove` writers, the TUI and the INI-to-TOML converter. Those ten are #150, #700, #1165, #1234, #1267, #1268, #1327, #1363, #1374 and the remove half of #1398.
- **Go-specific obligations:**
  - Unknown-key refusal is opt-in: check `MetaData.Undecoded()`.
  - Field presence must be modelled for #1309.
  - Map iteration is randomised, so emission must be deterministic.
  - Go has no mature format-preserving TOML writer (#1363).
  - errcheck and exhaustive linting are needed to get the C-stage catches.

**Library facts.** These were re-checked while drafting this record with a probe against BurntSushi/toml v1.6.0 in `golang:1.27.2-alpine3.24`:

- `MetaData.Keys()` returns keys in document order. `MetaData.Undecoded()` names every key that a typed decode left unread, for example `network.typo`.
- A type mismatch is refused with its line and key: `line 2 (last key "network.mode"): incompatible types`.
- `ParseError` carries a `Position` with line, column, byte offset and length.
- `MetaData` has **no** per-key position.
- **TOML 1.1 is accepted unconditionally.** The README says "Compatible with TOML version v1.1.0". `\e`, a trailing comma in an inline table and a multi-line inline table all decode without error, and there is no switch in the source to turn this off.
- `9223372036854775808` (2^63) is refused as out of range for int64.

pelletier/go-toml v2 decodes into structs with `DisallowUnknownFields`, but it has no ordered decode. Into a map, document order is lost, and this repo pins key and table order in its outputs.

## Decision

**The owner decided on 2026-10-29 (#1395) to rewrite the config generator in Go, as one typed program. Target release: v0.44.0.** v0.43.0 stays as it is at rc5.

### 1. Library: BurntSushi/toml v1.6.0

BurntSushi/toml is the one Go dependency. It was chosen over pelletier v2 because:

- `MetaData.Keys()` keeps document order, and the generator's outputs pin key and table order.
- `MetaData.Undecoded()` gives unknown-key refusal on top of a typed decode.

The generator adds two pieces of its own on top of the library:

- **A TOML 1.0 acceptance gate.** It runs before decode and refuses the TOML 1.1-only forms that the library accepts unconditionally:
  - `\e` and `\xHH` escapes;
  - newlines and trailing commas in inline tables;
  - times without seconds;
  - a leading BOM, which `tomllib` refuses.

  The oracle is `tomllib`. A differential test runs every corpus file through both, and their accept/reject verdicts must agree. The one recorded exception: an integer outside int64 range is refused. TOML 1.0 requires that refusal and `tomllib` does not apply it. The reason for keeping 1.0: the same files are read by the toml-bridge that Python consumers keep using, and by the `upgrade.sh` of earlier base releases. A file this generator accepts must stay readable by both.
- **A line locator.** It maps table headers and `key =` lines to line numbers. It does two jobs:
  - It attributes a refusal to `file:line` where the library has no key position, for example an `Undecoded()` key.
  - It is the span finder for format-preserving writes (section 4).

  The locator is not a second parser. Every result it gives is checked against the library's parse (sections 3 and 4).

Encoding JSON uses only the standard library. YAML and `.env` are written by the generator's own emitters to match the current bytes, so no YAML library is added.

### 2. One typed program, and what it owns

The generator is a single static binary, `config-gen`. It is a pure function of its inputs:

- the layer files, in the order ADR-00000036 lets the caller choose;
- explicit host facts that the shell detects and passes in: GPU, uid/gid, architecture and the rest of what `setup_detect.sh` finds. The container cannot see the host and never probes it.

It owns the following:

- **Load:**
  - the 1.0 gate;
  - a typed decode into a schema with per-field presence, so absent, empty and set are three distinct states;
  - unknown-key refusal in every command;
  - domain validation, moved from `schema.sh` with identical accept and reject sets.
- **Merge** under ADR-00000037, unchanged:
  - scalars merge key by key, and arrays of tables replace as a whole;
  - an empty array defines the array, and only an absent key inherits;
  - an absent layer contributes nothing;
  - a layer path that exists but is not a regular file is refused (#1400);
  - a layer that sets only the legacy alias key drops the inherited canonical key and does not rename it;
  - `["stage:<name>"]` tables are kept.
- **Query:** answers to named queries about the merged or per-layer configuration.
- **Edit:** `set`, `add` and `remove` on a layer file, for the CLI, the TUI save path and the INI-to-TOML converter.
- **Render:** `.env`, the container env files and `compose.yaml` in the caller's output directory.

Docker build, save and run, host detection, the TUI screens, INI tokenizing (the legacy chain and the converter's input) and Dockerfile parsing stay in shell.

**Preserved behaviour.** Every row of the #1407 compatibility matrix is preserved: absent layer skipped, partial layer merged by key, unknown array refused, legacy-alias un-inherit, stage tables, empty versus absent, and the accepted scalar spellings. The string-or-number fields (ports, volume sources) and a date in a string field render as the bridge renders them today. Key order inside each array-of-tables entry follows the document. A golden test pins that order, because both earlier Go ports reordered these keys. A field-less array-of-tables entry (`{}`), which the converter and the writers' padding use to spell a cleared slot, stays legal and is kept as one empty entry (#1309). So does an entry whose fields are all present but empty. Only a non-empty entry that lacks its family's gating field is refused, as `toml_bridge.py`'s `_check_entry` refuses it today.

**Behaviour that changes on purpose:**

- An unknown key or table is refused in every command, naming `file:line` and the key. Today the bridge's JSON mode passes it and only `apply` refuses it (#1328, #1374).
- A value outside its field's type is refused at load with its position. Today `--kv` passes it through and `privileged = "yes"` reaches the shell (#1314, #1315).
- An integer outside int64 is refused (see section 1).
- **A value or key containing U+0000 is refused** at schema validation, with `file:line`, the key and `conf_value_nul_refused`. TOML 1.0 allows it as the escape `\u0000`, and `tomllib` accepts it. Today the bridge emits the raw byte inside a `--kv` row with rc 0 (measured on `toml-bridge:c67e107678b7`), and bash then drops or truncates it silently. No destination can hold the byte: not a bash variable, not `.env`, not a compose value, not a process environment. Refusing it is therefore the only loud outcome. The 1.0 gate itself still accepts the syntax, so the gate's differential test against `tomllib` stays exact, and the refusal belongs to the schema. Every other code point, the C0 controls included, crosses the NUL-framed answer stream byte for byte. The schema still keeps the two refusals the bridge applies today: a value containing LF or CR, and a key or table name containing tab, LF or CR, are refused with `file:line` and the key named, as `toml_bridge.py` and the writer's `conf_upsert_newline_rejected` refuse them now. Those inputs are therefore `refuse` cases in the differential test below, not a fifth exception; lifting either refusal needs an amendment to this record.
- Error text is now `file:line:col: message`. One wording is kept: the duplicate-key class still reads `Cannot overwrite a value (at line L, column C)`, which `conf_toml_writer_spec.bats` pins. `toml_bridge_spec.bats` keeps testing the Python bridge, which is unchanged.

**How the differential tests treat these changes.** The tests that compare the generator with the bridge give every corpus input one declared expected outcome: `accept` (both accept, and the output must be byte-identical), `refuse` (both refuse; event ids and attribution are checked, error text is not), or `differs:<exception>`, where the bridge accepts and the generator refuses under one of the four exceptions above (unknown key, wrong type, integer outside int64, U+0000) with that exception's event id. Any other disagreement fails, including a bridge refusal the generator accepts and a `differs:` input refused for a different reason. The intentional changes are therefore tested as refusals, and no validation is relaxed to make the comparison pass.

Each failure also carries the event id from `log-events.txt`. Shell assertions on event ids (for example `conf_toml_parse_failed` and `conf_toml_merge_failed`) therefore hold across the engine change.

### 3. Interface: batched commands, JSON out, no `--kv`

- **Commands:**
  - `config-gen run`: the one request that reads. It takes the layer list once, optional facts and an output directory, a render set, and a list of queries.
  - `config-gen check`, `config-gen query <q>...` and `config-gen render`: shorthand for `run` with only that phase.
  - `config-gen edit <op>...`
  - `config-gen version`: prints the content digest and the toolchain version.
- **Phases of `run`, in fixed order:** load and validate every layer, then the per-layer checks, then the queries, then the render into a staging directory inside the output directory, then the commit, which renames each staged file into place. A fatal result in any phase stops the run before the commit. A refused configuration therefore never changes a generated file. An I/O failure during the commit itself is rc 4, and the diagnostics name the files that were and were not replaced.
- **Batching.** One invocation answers every query a shell command needs. `setup apply` makes **one** `docker run`: its queries, the per-layer views it checks, and the render, all in one `run`. That replaces 16 runs. `setup set`, `add` and `remove` make one call that validates against the layers below and writes.
- **Channels.** stdout carries the answer stream only. stderr carries the diagnostic stream only. Rendered files appear only in the output directory.
- **Structured answers are JSON.** That is the format for tests, for `setup show --json` and for Python consumers.
- **The shell reads a NUL-delimited record view of the same answer** (`--format nul`). Because the host has no `jq`, selection happens inside the generator and the shell never parses JSON. Both formats are produced from one answer value, and a golden test decodes the NUL view and compares it with the JSON.
  - The stream opens with a header, `CG1\0`, and closes with a trailer that carries the answer count. A stream without the trailer is refused as truncated.
  - It holds one frame per query, in request order. Each frame carries its query index, a status (`present` or `absent`) and its records. Each record is a list of named fields.
  - **Absence is per answer.** An optional `get` on a path that is not set answers `absent`. An explicitly empty string or a set-but-empty array answers `present`. A batch can therefore mix present, absent and empty answers in one run, with rc 0, and each reader applies its own default to an `absent` answer.
  - `require <path>` is the form whose absence is fatal (rc 3).
  - **Publication.** The generator builds the whole answer stream in memory and writes it only after every phase, the commit included, has succeeded. A fatal error before that first write, whether a refused configuration, a usage error, a `require` miss or an I/O error, leaves stdout empty. A stdout write that fails after publication has started is rc 4, and stdout may then hold a prefix of the stream without its trailer. A status inside the stream never reports a fatal error, and the process rc never reports an optional absence.
  - **The shim decodes only a complete stream.** It captures stdout, waits for the process to exit, and hands answers to its caller only when the rc is 0, the header is present, there is one well-formed frame per query in order, and the trailer's count equals the query count with no byte after it. Anything else gives the caller no answer at all and a named event, so a prefix written before a failure never reaches a reader.
- **No `--kv`.** No query returns the whole configuration flattened into numbered rows:
  - An array-of-tables entry is a record of named fields.
  - The CLI's `<section>.<prefix>_N` addressing (`setup remove volumes.mount_2`) stays a user-facing name. The generator translates it in `edit` and `query`, and it never becomes a transport format.
- **Exit codes:**
  - 0: success.
  - 1: configuration refused.
  - 2: usage.
  - 3: a path named by `require` is not set. An optional `get` never sets this code.
  - 4: I/O error. A failed stdout write is an I/O error, never 0, including one that fails after earlier writes succeeded.
- **Diagnostics.** Each diagnostic carries a severity, the event id, the file, line, column, key and display text. It is written in the same format the caller asked for:
  - With `--format nul`, which is what the shell uses, each diagnostic is a frame of exactly eight NUL-terminated fields, in this order: the frame tag `D`, severity, event id, file, line, column, key and display text. A field may hold `"`, `\`, LF, CR, tab and any other byte except NUL, verbatim, so the shell decodes it with `read -r -d ''` and no JSON parsing. A key that contained U+0000, which is refused, is shown with the six characters `\u0000` in its place.
  - The shim collects stderr in a temp file, decodes the frames and re-emits each one through `_log_err` or `_log_warn` with its event id. Bytes that are not frames, such as the docker CLI's own messages, are forwarded as `config_gen_stray_stderr` and never dropped. A short frame is refused by name.
  - With `--format json`, used by tests and people, each diagnostic is one JSON object per line. Both forms are produced from one value.

### 4. Writes preserve format without a format-preserving library

`edit` works in three steps:

1. The line locator finds the span the operation touches: a key line, an entry block, or a table that has become empty.
2. The edit replaces only that span, using the emitter's spelling for new content.
3. The result is checked twice before anything reaches disk:
   - **Semantic:** re-parsing gives exactly the model before the edit plus the operation.
   - **Byte:** every byte outside the span is unchanged.

If either check fails, the edit is refused with a message and the file is left untouched. A construct the locator does not model, such as a header-like line inside a multi-line string, therefore produces a loud refusal and never a corrupted file.

The write itself is atomic: a temporary file in the same directory, then a rename. It keeps the file's mode (#1356).

**In the container,** the write needs more than the bridge's read-only per-file mounts. One mount helper serves both writers, `edit` and the render phase's `--out-dir`, and it lands with the `run` contract, before either writer:

- The writable directory (the destination's parent for `edit`, the output directory for `run`), resolved with `realpath` on the host, is bind-mounted read-write at the same absolute path. Lower layers stay read-only, each at its own path. Paths inside the container therefore equal the paths on the host, and so do the paths the diagnostics name.
- A parent path that `--mount` cannot express (a `,` or a newline) is refused by name before `docker run`. An absent parent is refused, not created.
- The container runs as `--user <uid>:<gid>` of the caller, with the caller's umask. A created file is owned by the caller with the mode today's writer gives it, and a replaced file keeps its mode and owner.
- The native and container paths are held to the same bytes, mode, owner and rc by a parity spec. It covers creating an absent local layer, replacing an existing file, preserving modes, and refusing an unwritable directory. This closes the #1363 class: blank lines added, keys reordered, empty tables left behind. The `SETUP_CONF_HASH` drift that #1363 caused cannot recur.

### 5. Delivery: built in the consumer by content digest, plus a test-tools stage

- **Consumers:**
  - `dockerfile/Dockerfile.config-gen` (build context `dockerfile/`, module at `dockerfile/config-gen/`) is built at first use under `config-gen:<12 hex>`.
  - The 12 hex digits come from `_reclaim_tool_dockerfile_hash`, the derivation `toml-bridge` and `test-tools` already use. It hashes directory COPYs recursively, so an edit to any Go source, `go.mod` or `go.sum` changes the tag.
  - Build and provisioning reuse `toml_bridge.sh`'s resolve, ensure and build logic, generalised into a shared helper rather than copied.
  - `CONFIG_GEN_IMAGE` wins verbatim and is not provisioned. This is the one override, in the `TOML_BRIDGE_IMAGE` style.
- **CI and downstream test runs:**
  - `Dockerfile.test-tools` builds the binary in a Go stage and COPYs it to `/usr/local/bin/config-gen`.
  - The shim uses a native binary only when `config-gen version` prints the digest the shim derives. A stale binary on PATH falls back to the docker path and says so. Today any `toml-bridge` on PATH is trusted.
  - `release-test-tools.yaml` already builds on native amd64 and arm64 runners. Its smoke step executes the binary on both.
- **No separately published image in v0.44.0.** A `.version`-based tag is wrong for an unreleased or locally modified subtree, which must still build. A digest-tagged image published for every released revision would need a pull-then-build fallback, multi-arch publishing and retention. That is revisited only with #1176 or if first-use cost becomes a reported problem.
- **Build hygiene and pins:**
  - Build flags: `CGO_ENABLED=0`, `-trimpath`, `GOTOOLCHAIN=local`, and `go mod download && go mod verify` in their own layer.
  - The golang builder `ARG` carries a `tool-pin:` marker.
  - The BurntSushi requirement carries a `// tool-pin:` comment. `pin_coverage` recognises it from the first PR, in both of Go's whitespace-separated `require` forms: the single line and the parenthesised block. The watch then learns to check and bump it, and the bump regenerates `go.sum`.
  - **No indirect requirements.** The module has one dependency, so `go.mod` carries no `// indirect` requirement. Such a line is recognised as a declaration, so it cannot pass unseen, and `pin_coverage` refuses it by name; the watch therefore never bumps one. Allowing an indirect dependency needs an amendment to this record.
  - **test-tools pin roster.** `script/ci/test-tools-pins.sh` verifies every `*_VERSION` ARG of `Dockerfile.test-tools` against the built image and refuses an ARG with no probe. The golang ARG of the new Go stage pins a compiler that is not in the final image. So it joins an explicit **builder-only** class. Its probe asks the artefact the builder made (`config-gen version` prints the toolchain from `runtime.Version()`), and the release smoke on amd64 and arm64 checks it. The class does not let an unprobed final-image pin through.
  - golangci-lint and the mutation tool are pinned the same way.
- **Tests:**
  - The Go toolchain lives in the Dockerfile's `test` stage, not in test-tools.
  - `docker build --target test` runs gofmt, go vet, golangci-lint (errcheck, exhaustive), `go test -race` with a coverage floor, the fuzz seed corpora, and gremlins with an efficacy floor.
  - **Mutation targets come from the host.** The build context `dockerfile/` has no Git history, and on `main` after a merge `origin/main` is `HEAD`, so a `--diff origin/main` inside the build sees nothing. The `just` recipe derives the baseline on the host:
    - on a branch, the merge base with `origin/main`;
    - on a push to `main`, the merge commit's first parent.

    The changed files are those the build will compile: the diff from the baseline to the working tree (committed, staged and unstaged) plus untracked files. A Git-ignored file the build context would carry is refused, because no diff sees it. In CI the checkout is clean, so this equals the committed diff. The recipe maps the files to Go packages: a file in a package's own `testdata/` maps to that package, and a file in the module-root shared corpus or goldens maps to every package that imports `internal/testcorpus`, the one permitted reader of module-root `testdata/`. A file that maps to no package is refused. The manifest goes in as a named build context. An unreachable baseline, an empty manifest without an explicit `no-go-change` marker, and a stale package name each fail the gate. A planted surviving mutant turns the gate red in all four environments.
  - The same `just` recipe runs it locally, on GitHub-hosted runners, on the self-hosted runner and in the pre-PR mirror. The Go coverage floor is its own gate and is not merged into kcov's 80%.

### 6. toml-bridge stays, for Python consumers

base stops calling `toml-bridge`. `dockerfile/Dockerfile.toml-bridge`, `toml_bridge.py`, its JSON and `--merge` modes, its spec, and the copy in test-tools stay for Python consumers (#1395). The base-schema-shaped modes are removed only after an org-wide search finds no caller outside base:

- `--kv`
- `--empty-arrays`
- `--tables`
- `--empty-families`
- `--entries`

If a caller is found, they are deprecated for one minor release first. Moving the bridge to its own repo stays #1176.

## Consequences

- **`setup apply` goes from 16 container runs to 1.** Measured on the comparable spike, warm apply drops from about 6.1 s to about 0.7 s. The collapse of the 9 duplicate calls lands first, on the Python bridge, so the saving does not wait for the port.
- **Unknown keys, wrong types and silently dropped entries become load-time refusals with `file:line` attribution.** They are refused in the writers, the TUI save path and the converter as well as in `apply`. This turns the ten "partly" bugs listed in the Context into "prevented".
- **The image shrinks** from 54 MB (Python) to about 2.8 MB (Go).
- **The first setup on a developer host gets slower.** It goes from about 8 s to about 12 s (unverified), and leaves a golang builder of about 253 MB in the local image store. Field-deploy hosts never build the generator.
- **The team takes on a Go toolchain.** That means one module, three pinned tools (golang, golangci-lint, gremlins) and `go.sum` upkeep in the watch.
- **Generator code gets real coverage and mutation figures.** The Python bridge has none today, because it sits outside kcov's include path.
- **During the migration, a `setup` command may provision both images.** That cost ends when the last bridge call site is removed.
- **Two schema definitions become one.** Today `toml_bridge.py`'s array spec and `conf.sh`/`schema.sh` overlap. The Go schema replaces both for base. The Python copy remains only for the bridge's own JSON consumers.
- **ADR-00000037 gets a one-line pointer** at its Containerised parsing section: "Amended by ADR-00000039: the parser and generator for base are the Go `config-gen`; toml-bridge remains for Python consumers." Its Status stays Accepted.
- **CONTEXT.md gains the term "config generator"** (`config-gen`). The stale INI-era wording of "Conf layer chain" is corrected in the same change.
- **Revisit triggers:**
  - TOML 1.1 adoption, which would remove the 1.0 gate. It needs its own ADR, because older releases and Python consumers read the same files.
  - A mature Go format-preserving writer appearing.
  - First-use cost or offline hosts, which would point to a published image (#1176).

## Alternatives

- **A1: Python plus a schema** (keep the bridge, add a typed schema with unknown-key refusal, batch the calls, add ruff and mypy to CI).
  - **For:** this is the cheapest path. It needs no new toolchain, and the batching saving is the same: batched Python measured 698 ms warm against Go's 671 ms in #1407. It also has tomlkit for format-preserving writes.
  - **Against:**
    - On stability it reaches Go's level only after ruff or pyflakes and mypy are added to CI. Without them Go is ahead on #1162 (compile stage) and #1222 (static packaging), 1 bug each of 62.
    - Moving the writers in would add a tomlkit or tomli-w pin.
    - The 54 MB image could shrink only to 32.6 MB.
    - The bridge's coverage stays outside kcov unless coverage.py is wired in separately.
  - **Outcome:** the owner chose Go on 2026-10-29.
- **A2: Rust** (`toml` with serde, or toml_edit).
  - **Stability:** it ties Go at every firm stage. Its only extra catch is an idiom (#840, #1094 item 5), and toml_edit would cover #1363.
  - **Cost:**
    - It locks 20 crates, 13 of them compiled, and no existing pin resolver covers any of them.
    - It leaves a 1.03 GB builder on disk against Go's 253 MB.
    - First setup takes about 28 to 30 s against about 12 s for Go.
    - It needs a musl target on Alpine, which repeats #1222 if forgotten.
    - `deny_unknown_fields` stops working under `#[serde(flatten)]`.
    - Untagged-enum errors name no key.
  - **Outcome:** rejected on cost, with no stability gain.
- **A3: pelletier/go-toml v2.** It has typed decode with `DisallowUnknownFields`, but no ordered decode. Key and table order are pinned in outputs, so order would have to be rebuilt from the text. Rejected.
- **A4: Accept TOML 1.1 as BurntSushi does.** That would save the gate. But a file valid for v0.44.0 would then fail in `tomllib`-based Python consumers and in earlier base releases' readers, against the invariant that consumer behaviour is preserved unless an ADR says otherwise. Rejected for now. See the revisit triggers.
- **A5: Publish a multi-arch `config-gen` image and pull it.** It avoids the 253 MB builder and the first-use build. But it needs a build fallback for unreleased or modified subtrees anyway, adds registry reachability to configuration reads, and needs publishing and retention work. Deferred (see Decision 5 and #1176).
- **A6: Keep `.env` and `compose.yaml` rendering in shell, porting only parse and merge.** That leaves the numbered-row seam in place for the emitters, which are the largest consumers of `--kv`. The 9 flattening/reassembly-seam bugs in the 62-bug set came from that seam. Rejected. Rendering moves to Go, family by family, with byte-identical goldens.
