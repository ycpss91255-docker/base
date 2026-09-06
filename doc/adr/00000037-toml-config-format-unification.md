# Unify human-edited config to TOML with typed merge semantics

> Serves: PRD invariant 3 (composable by construction) via a
> machine-parsable, type-safe config format; also the
> one-source-many-render goal and ADR-00000036 (parameterised generate
> API).

- **Date:** 2026-09-06
- **Status:** Accepted
- **Relates to:** ADR-00000001 (setup.conf is the main path),
  ADR-00000003 (env vs workload param boundary),
  ADR-00000025 (per-worktree `.setup.conf.local` override),
  ADR-00000036 (parameterised generate API)

## Context

The current configuration pipeline uses two human-edited formats that
serve Docker container infrastructure:

1. **`.setup.conf`** -- a custom INI dialect parsed by a hand-written
   bash tokenizer (`_ini_tokenize`). 15 sections, 8 of which encode
   ordered lists via numbered keys (`mount_1`, `arg_1`, `device_1`,
   ...). Three-layer override: template `.setup.conf` -> repo
   `.setup.conf` -> `.setup.conf.local`.

2. **`.env.local`** -- a flat `KEY=VALUE` file for container service
   runtime env vars (ADR-00000003). Two-layer: generated `.env`
   (defaults) + `.env.local` (user overrides).

Three problems drove this decision:

- **Format weakness.** INI has no type system -- `true`, `1`, `yes`
  are all valid booleans to different parsers; no arrays, no nested
  structure. The numbered-key workaround (`mount_1`, `mount_2`, ...)
  is fragile: no validation, ordering is implicit, adding/removing
  requires manual renumbering.

- **Merge granularity mismatch.** ADR-00000025 sec. 3 adopted
  section-replace (the entire section is replaced by the upper
  layer) because numbered-key lists cannot be key-level merged
  without producing incoherent combinations neither layer wrote.
  This forced scalar sections (`[gui]`, `[network]`, ...) to also
  be section-replaced even though key-level merge is safe for them
  -- a user who wants to override only `[gui] mode` must copy the
  entire section.

- **Two formats for one concern.** `.setup.conf` and `.env.local`
  both serve Docker but use different formats, different parsers,
  and different merge rules. The split criterion (ADR-00000003 axis
  A: machine-bound vs task-volatile) is correct but could be
  expressed within one format with separate files.

The org has precedent: multi_run#26 chose TOML + Python `tomllib` for
its own config. The config-manager design document (v0.16, 2026-09-02)
independently chose TOML for its config manifest (`config-list.toml`)
with the reasoning: strictness ranking TOML > JSON > YAML (no `no`/`08`
ambiguity, mandatory type distinction, no indentation semantics).

Industry survey of merge strategies across 8 systems (Podman, Docker
Compose, Helm, Kustomize, NixOS, Ansible, Git config, toml-merge)
found a clear consensus: **scalar fields -> key-level merge; array
fields -> replace.** 6/8 systems use this pattern. The two that append
arrays (Docker Compose, NixOS) both needed escape mechanisms (`!reset`,
`mkForce`) to handle the cases where append is wrong.

## Decision

**Unify all human-edited Docker config files to TOML.** Four files,
split by service boundary (ADR-00000003 axis A):

| File | Whose | Concern | Layering |
|---|---|---|---|
| `setup.toml` | the repo's (committed) | Docker infrastructure: how the container is assembled | template -> repo -> (caller-supplied per ADR-36) |
| `setup.local.toml` | the operator's (gitignored) | Per-instance Docker infrastructure override | overrides `setup.toml` |
| `.env.toml` | the repo's (committed) | Container service runtime env defaults | template -> repo |
| `.env.local.toml` | the operator's (gitignored) | Per-instance service env override | overrides `.env.toml` |

**Split criterion.** The boundary is the **service boundary**, not
lifecycle (build vs run):

- `setup.toml` = Docker infrastructure (how the container is built and
  run): image rules, build args, GPU, GUI, network, volumes, devices,
  security, lifecycle, logging, deploy, additional contexts.
- `.env.toml` = service runtime env (how the application inside the
  container behaves): `ROS_MASTER_URI`, `ROS_DOMAIN_ID`, `LOG_LEVEL`,
  `WATCHDOG_ENABLED`, application-level parameters.

The two have **zero intersection**. If overlap is discovered, `.env.toml`
takes precedence because its purpose is the container-internal service.
The current `[environment]` section migrates OUT of `setup.toml` entirely
and into `.env.toml`.

**TOML structure.** Scalar sections use standard `[table]` syntax;
list-shaped sections use `[[array of tables]]`:

```toml
# scalar section -- key-level merge in overlay
[gui]
mode = "auto"

[network]
mode = "host"
ipc = "host"

# array section -- array replace in overlay
[[volumes]]
source = "./src"
target = "/opt/workspace"
mode = "rw"

[[volumes]]
source = "/dev/shm"
target = "/dev/shm"

[[build.args]]
key = "APT_MIRROR_UBUNTU"
value = "tw.archive.ubuntu.com"

[[devices]]
path = "/dev/video0"

[[image.rules]]
pattern = "jetson*"
tag = "l4t"
```

**Merge semantics.** Type-aware, matching the industry consensus:

- **Scalar keys within a `[table]`**: key-level merge. The upper layer
  overrides only the keys it defines; unmentioned keys inherit from
  the lower layer.
- **`[[array of tables]]`**: array replace. If the upper layer defines
  any `[[volumes]]` entry, the entire volumes array replaces the lower
  layer's. No append, no index-based merge.

This resolves ADR-00000025 sec. 3's concern: the numbered-key ordered
lists that forced section-replace are gone. Scalar sections that were
collateral damage of the blanket section-replace rule can now be
key-level merged safely.

**Generated outputs remain Docker-native format:**

```
compose.yaml     <- from setup.toml (infrastructure)
.env             <- from setup.toml (infra env) + .env.toml (service env)
.env.local       <- from .env.local.toml
.env.generated   <- interpolation cache (unchanged)
```

**Host parsing.** The host must parse TOML before containers exist
(chicken-and-egg: parse results ARE `docker compose up` inputs). Tool
selection is deferred to implementation; candidates: `taplo` (Rust
static binary), `dasel`, or a minimal Docker bootstrap container.

## Alternatives

- **A1 -- Stay with INI + flat `.env`.** Zero migration cost, but
  preserves the numbered-key fragility, the section-replace
  collateral damage on scalar sections, and the two-format
  maintenance burden. The hand-written `_ini_tokenize` parser has
  known edge cases. Rejected because the problems compound as
  sections grow.

- **A2 -- YAML for everything.** Rich type system, native in Docker
  Compose. Rejected because: YAML has well-documented parsing
  ambiguities (`no` as boolean, `08` as string vs int depending on
  YAML version), indentation-significant syntax is error-prone for
  hand-editing, and the config-manager project already chose TOML
  over YAML with the same reasoning.

- **A3 -- JSON for everything.** Strict and unambiguous. Rejected
  because: no comments (unacceptable for human-edited config files),
  trailing-comma errors, verbose syntax for the kind of config
  humans write by hand.

- **A4 -- Single file (setup.toml only) with `[environment]` section
  for service env.** Simpler, but violates the service boundary:
  `setup.toml` is Docker infrastructure, and forcing users to edit
  Docker config to change application-level env vars conflates two
  concerns. The realsense_ros1 repo demonstrates the split is real
  and practiced: its `setup.conf [environment]` is empty; all
  service runtime env vars (`ROS_MASTER_URI`, `ROS_IP`,
  `WATCHDOG_ENABLED`) come via `.env.local`.

- **A5 -- Terraform-style `.tf` + `.tfvars` split.** Rejected
  because `setup.conf` drives both build and run; the lifecycle
  boundary that Terraform splits on (declaration vs values) does not
  map to our structure.

- **A6 -- Array append instead of replace.** Rejected by industry
  evidence: 6/8 surveyed systems use array replace; the two that
  append (Docker Compose, NixOS) both needed escape mechanisms.
  Append also reintroduces the inability to remove items that
  ADR-00000025 sec. 3 identified as broken for ordered lists.

## Consequences

- The `[environment]` section moves from `setup.toml` to `.env.toml`.
  `setup.toml` has zero application-level env vars.

- Scalar-section overrides become lighter: an operator who wants only
  `[gui] mode = "wayland"` writes one key, not the entire section.

- Array-section overrides remain explicit: writing any `[[volumes]]`
  replaces the full list, preserving the "what you see is what you
  get" property.

- The `_ini_tokenize` bash parser is replaced by a TOML parser.
  Host-side tool selection is an implementation detail, not an
  architectural decision.

- `setup_tui.sh` (2975 lines + 691-line backend) is frozen until the
  TOML migration completes. The TUI's INI-aware editor functions
  (`_edit_section_*`) cannot operate on TOML structure. A rebuild or
  replacement (possibly by the config-manager Web UI) follows the
  migration.

- Migration path for downstream repos: a one-time converter
  (`setup.conf` -> `setup.toml`, `.env.local` -> `.env.local.toml`)
  runs during the first `init.sh` resync after upgrade, gated on
  file existence (same pattern as the `.env` -> `.env.local` migration
  in ADR-00000003's 2026-08-26 amendment).

- Amends ADR-00000025 sec. 3: section-replace is no longer blanket.
  The merge rule is now type-aware (scalar key-level, array replace).
  The reasoning in sec. 3 (ordered lists cannot be key-merged) remains
  correct and is the basis for the array-replace half of the new rule.

- Amends ADR-00000001: "setup.conf keeps section-replace semantics"
  is refined to type-aware merge semantics for `setup.toml`.

- Timing: this migration is internal to the generate API (ADR-36).
  The TOML files are inputs to the same pipeline that currently reads
  `.setup.conf`; generated outputs (`compose.yaml`, `.env`) are
  unchanged. ADR-36's parameterised API accepts `setup.local.toml` as
  the caller-supplied layer.

- JSON Schema validation of the parsed TOML structure (as practiced by
  the config-manager project, sec. 6.2) is a natural follow-up but not
  part of this decision.
