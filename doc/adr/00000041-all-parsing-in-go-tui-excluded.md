# All parsing and generation in Go; the TUI excluded

> Serves: PRD invariant 2 (never fail silently) -- every place base reads a structured text (TOML, INI, a Dockerfile, a version string, a `.gitignore`, a drift record, a host fact) goes through one typed program that refuses what it cannot read, instead of a shell reassembly that drops it.

- **Date:** 2026-11-18
- **Status:** Accepted
- **Relates to:** issue #1561 (this decision; owner decision of 2026-11-18), #1395 (the Go generator work), #1435 (speed and size evaluation), #1731 (TUI deferred, option A), #1451 (S15, the TUI slice), #1459 (S23, the `--kv` removal)
- **Amends:** ADR-00000039, section 2, the sentence "Docker build, save and run, host detection, the TUI screens, INI tokenizing (the legacy chain and the converter's input) and Dockerfile parsing stay in shell." Everything else in ADR-00000039 stands: the library and the 1.0 gate, the typed program and its interface, format-preserving writes, the delivery and the place of toml-bridge.

## Context

ADR-00000039 moved only the configuration generator to Go: TOML in, `.env` and `compose.yaml` out. Its section 2 kept INI tokenizing, Dockerfile parsing, host detection, the docker wrappers and the TUI in shell. #1561 asked whether the rest of the repo should follow.

Two facts frame the answer.

- **The docker wrappers gain nothing from a language swap.** #1435 measured that container start dominates: swapping the language saves at most about 0.36 s of a 9.8 s `setup apply` (ADR-00000039, Context). The wrappers mostly start containers.
- **The editor choice holds for a wider scope.** A spike on 2026-11-18 re-ran the format-preserving edit question (set, add and remove on 8 fixtures, 24 cases, including a CRLF fixture) against three editors:

  | Editor | Correct | Wrong | Notes |
  |---|---:|---:|---|
  | ADR-00000039 line locator + splice + semantic and byte check (Go, BurntSushi v1.6.0) | 24 | 0 | byte-minimal, idempotent, CRLF kept; refused all 3 unsafe probes (a table with no header of its own, a multi-line inline array) |
  | Rust `toml_edit` 0.25.19 | 21 | 3 | all 3 wrong on the CRLF fixture (rewritten to LF, even on a no-op); silently replaced an inline array with a string; no self-check |
  | pelletier/go-toml v2.4.3, re-encode | 0 | 24 | no edit-in-place API; re-encoding lost every comment and reordered keys |

  `toml_edit` would also add a second toolchain and a dynamically linked binary to a Go-only static build.

## Decision

**The owner decided on 2026-11-18 (#1561) that all parsing and generation moves to Go.** Shell keeps only the scripts whose job is to call an external program.

### 1. What moves to Go

Into `config-gen`, under ADR-00000039's rules (typed load, refusal with `file:line`, batched commands, byte-identical output):

- the configuration: load, merge, query, edit and render, as ADR-00000039 already decides;
- INI tokenizing (`_ini_tokenize`) and the INI-to-TOML converter (`ini_to_toml_migrate.sh`, `setup_conf_migrate.sh`);
- Dockerfile parsing and migration (`dockerfile_migrate.sh`);
- version and semver parsing (`version_migrate.sh` and its callers);
- `.gitignore` and drift parsing (`gitignore.sh`, `drift.sh`);
- host-fact parsing: the text a probe returns is parsed in Go; the probe itself stays in shell.

### 2. What stays in shell

- The docker wrappers: build, run, exec, stop and prune. Measured, a port buys at most about 0.36 s of 9.8 s (#1435).
- The host probes, which call host programs the container cannot see. They pass raw facts to `config-gen`, as ADR-00000039 section 2 already requires.
- `init.sh` and `upgrade.sh` bootstrap, which runs before any Go binary exists.

### 3. The TUI is excluded

The TUI (`setup_tui.sh`, `_tui_conf.sh`, `_tui_backend.sh`) is unsupported while #1731 is open (option A). It is not migrated, and no TUI tests are written. S15 (#1451) stays parked. S23 (#1459) may disable the TUI entry point if the bridge removal breaks it.

### 4. Go over Rust stands

ADR-00000039's A2 rejected Rust on cost with no stability gain. The 2026-11-18 spike adds a correctness result for the editing path: the Go line locator passed 24 of 24 and refused every unsafe probe, where `toml_edit` was wrong on 3 and accepted a type change silently. Go stays the one language for the wider scope.

### 5. Delivery is unchanged

The moved code ships inside `config-gen`, built at first use by content digest (ADR-00000039 section 5). The host still needs bash and Docker only. No host binary is installed.

### 6. A fixture corpus before each switch

Outside the configuration there is no byte oracle like the bridge's corpus. Each newly moved area therefore gets its own fixture corpus, recorded from today's shell output, before the slice that switches its callers to Go. The switch slice is held to that corpus byte for byte, with intentional changes declared per input as in ADR-00000039 section 2.

## Consequences

- **#1561 is answered by this record.** Each new area is delivered as slices, its corpus slice before its switch slice.
- **The shell that remains is a thin layer of program calls.** A structured text it used to parse is now refused or accepted by the typed program, with `file:line`.
- **More Go code to test.** Each moved area carries the Go coverage and mutation floors of ADR-00000039 section 5.
- **The TUI may stop working** during S23. That is accepted under #1731 and revisited only when the owner reopens it.
- **ADR-00000039 gets a one-line pointer** at its section 2 shell list: "Amended by ADR-00000041: only the docker wrappers, the host probes and the bootstrap stay in shell; the TUI is excluded."
- **Revisit triggers:** #1731 reopened (the TUI comes back into scope), or a measurement that shows a docker wrapper spending its time outside container start.

## Alternatives

- **A1: Keep ADR-00000039's scope.** INI, Dockerfile, version, gitignore and drift parsing would stay in shell, and they are the same class of seam the generator removes. Rejected.
- **A2: Port everything, the docker wrappers included.** Their time is container start, so the port buys at most about 0.36 s of 9.8 s for a large rewrite. Rejected.
- **A3: Rust for the editing path.** `toml_edit` was wrong on the CRLF fixture and accepted a silent type change, and it adds a second toolchain. Rejected.
- **A4: Migrate the TUI with the rest.** Blocked by the owner's #1731 decision (option A). Rejected for now.
