# `just` command model: zero-special-case namespaces, generic tooling, min->max coverage

- **Date:** 2026-06-23
- **Status:** Accepted
- **Amends:** ADR-00000010 (docker is no longer top-level; `ci`/`cd`
  namespaces renamed; entry shape) and ADR-00000006 (`init.sh` /
  `upgrade.sh` leave the base root)
- **Builds on:** ADR-00000005 (`just` as the user-facing entry)

## Context

ADR-00000010 shipped the layered entry + base/downstream split, but kept
two asymmetries that turned out to be load-bearing irritants once the
namespaces multiplied:

1. **docker recipes stayed top-level** (`just build`, `just run`) while
   everything else was a `mod?` namespace (`just ci ...`,
   `just template ...`). The top-level docker recipes are a *special
   case*: adding any new top-level verb risks the duplicate-name hard
   error, and the mental model ("some verbs are bare, some are
   namespaced") has to be memorised.

2. **The namespace names described mechanism, not action.** `ci` / `cd`
   are pipeline-stage jargon; a user wanting "run the tests" or "cut a
   release" has to translate. And the natural request "I want every CI
   check under one roof" did not map onto `ci` + a separate top-level
   `lint`.

Three further requirements surfaced while using the layered entry:

- **Coverage from smallest to largest unit.** Every command should scale
  from one file / one check up to the whole suite, *narrowing via
  options* rather than memorising sub-recipes or passing bare positional
  args whose meaning is positional.
- **One generic tool, per-repo content.** base self-tests the template
  (shellcheck + bats over its own scripts/specs); a consumer tests its
  image (build the devel-test stage, run smoke). These were modelled as
  *different* tooling. They are not: the *tools* (shellcheck, bats,
  hadolint) are identical; only the *content* of `test/` differs. Modelling
  them as one generic runner is what lets the whole `script/` tree be a
  single shared origin.
- **`init.sh` / `upgrade.sh` at the base root are an eyesore** and break
  the "every action lives in a namespace" rule.

`just` 1.52 facts from ADR-00000010 still hold (symlink-relative import
resolution; duplicate top-level recipe name = hard error; `mod?` =
namespace; `import?`/`mod?` of a missing file is not an error).
Additionally verified for this decision:

- `just <ns> <recipe> --help` and `just <ns> --help` reach the module;
  per-recipe help and `--lang` are surfaced by the recipe forwarding the
  flag to its backing script (the wrappers already localise via `--lang`).
- Dynamic shell completion (`clap_complete`, `JUST_COMPLETE=<shell> just`)
  is **module-aware** -- it drills into `just docker <tab>` and
  `just test lint <tab>`. The distro `just.fish` (shipped by the *fish*
  package, not `just`) only lists top-level recipes and does **not**
  drill, which is why an explicit completion installer is needed.

## Decision

### 1. Zero special cases: every action is a namespace

The entry mods every group; **nothing is top-level**. docker joins the
other namespaces:

```just
mod? docker   'script/docker/justfile.docker'
mod? test     'script/test/justfile.test'
mod? release  'script/release/justfile.release'
mod? base     'script/base/justfile.base'
mod? template 'script/template/justfile.template'      # consumer only in practice
import? 'script/local/justfile.local'                  # repo-owned user groups
default:
    @just --list
```

`just build` becomes `just docker build`. The cost (longer invocations)
is accepted in exchange for one rule with no exceptions, and completion
(below) makes the extra token a single `<tab>`.

### 2. Action-named namespaces

| was (ADR-00000010) | now | rationale |
|---|---|---|
| `just build/run/...` (top-level) | `just docker build/run/exec/stop/prune/setup/setup-tui` | docker is the action group, no special case |
| `just ci` | `just test` | the action is "test"; **all** CI checks live here, incl. lint |
| `just cd` | `just release` | the action is "cut a release" |
| `init` / `upgrade` / `upgrade-check` (root scripts) | `just base init` / `just base upgrade [ver]` / `just base update` | manage the `.base` dependency; `update`/`upgrade` mirror apt (refresh-check vs apply) |

`lint` is **not** a top-level peer of `test`; it is `just test lint`
(a sub-action of the test namespace). A new top-level command would need
its own `justfile.<x>` + scripts; lint is part of testing, so it stays
inside `test`.

### 3. min->max coverage via `--option` narrowing

Every command runs the **maximum** scope bare and **narrows** through
`--long` / `-short` options -- never bare positional args whose meaning is
positional:

```
just test                       # everything (shellcheck + bats + ... + coverage as configured)
just test --file <path>         # one spec file
just test --filter <regex>      # specs matching a pattern
just test lint                  # all linters
just test lint --shellcheck [<level>]   # only shellcheck (optionally at a severity level)
just test lint --hadolint               # only hadolint
just docker build                       # default stage
just docker build --stage <name>        # a specific stage (base self-test: --stage test-tools)
just base upgrade                       # latest tag
just base upgrade --tag <vX.Y.Z>        # a specific tag
```

The single-file test mode (previously supported) is preserved as
`--file`. `test-tools` is built explicitly as
`just docker build --stage test-tools`; the test runner invokes it
internally rather than `build` growing a magic `test` argument.

### 4. Generic tooling, per-repo content, single source of truth

The whole `script/<ns>/` tree is **generic tooling with a single source of
truth**; only repo-specific *content* differs. Therefore:

- The **real files live in `downstream/script/<ns>/`** (the shipped tree),
  which is the single source of truth. base-own **`script/<ns>/` symlinks
  into `downstream/script/<ns>/`** so base uses the very tooling it ships,
  with no duplicate base-own copy. A consumer's **`script/<ns>/` symlinks
  into `.base/downstream/script/<ns>/`** -- a **single hop** to the real
  file. (Per-sub symlinks, not a single whole-`script/` symlink, so
  `script/local/` and `script/entrypoint.sh` can stay *inside* `script/`
  and remain repo-owned -- alignment is kept.)
- **Content is per-repo and never symlinked**: `test/` (specs),
  `config/`, `Dockerfile`, `compose.yaml`. base has its own
  (`test/{unit,integration,behavioural}`, `Dockerfile.test-tools`,
  base `compose.yaml`); a consumer has its own (`test/smoke/`, app
  `Dockerfile`).

**Origin-direction is build-verified (corrected 2026-06-23).** The
opposite direction -- real files in base `script/<ns>/`, with
`downstream/script/<ns>/` as a *directory* symlink back -- was tested and
rejected: it makes the consumer wrapper symlinks (`<repo>/script/build.sh
-> .base/downstream/script/docker/wrapper/build.sh`) a **two-hop** chain
(file symlink through a directory symlink), and BuildKit does **not**
resolve that at `COPY` time. The required lint copy `COPY script/*.sh
/lint/` then fails with `"/script/build.sh": not found`. (A single
directory-symlink path such as `COPY .base/downstream/script/docker/lib
/lint/lib` *does* resolve; only the two-hop chain fails.) Keeping the real
bytes at the `downstream/` path the consumer references makes every
consumer symlink single-hop -- the shape already proven in CI -- and
leaves the consumer Dockerfile COPY paths and the ADR-00000006 Region C
`upgrade.sh` paths **unchanged**. For docker this is exactly today's
on-disk layout, so #654 is not a file move but the addition of the
base-own `script/<ns>` symlinks plus the consumer per-sub symlinks.

### 5. Generic test runner

`script/test/test.sh` is one runner that adapts to the **content present**
using the **same** tools everywhere:

- shellcheck over the repo's scripts;
- host-side bats for `test/unit` + `test/integration` if present;
- build the Dockerfile `devel-test` stage + run `test/smoke` if present;
- `test/behavioural` if present; `--coverage` runs kcov.

base (has unit/integration/behavioural, no app devel-test) runs those;
a consumer (has smoke + a Dockerfile) builds + smokes. **One runner, the
content decides.** This is what makes `script/test/` symlinkable like the
rest.

### 6. `--help` and `--lang` at every level

Every level responds to `--help` and `--lang`:

- entry: `just --list` (bare) / `just --help`;
- namespace: `just <ns>` (no action) prints localised namespace help;
  `just <ns> --help` likewise;
- recipe: `just <ns> <action> --help` / `--lang <code>` forward to the
  backing script, which owns the localised help/usage (the docker
  wrappers already do this; `test` / `release` / `base` scripts gain the
  same `--help` / `--lang` handling).

### 7. Opt-in completion installer (no host pollution)

Because the distro `just.fish` does not drill into namespaces, base ships
`just base completions install [--shell bash|zsh|fish]` and
`just base completions uninstall`. It writes the `clap_complete` dynamic
completion to the user's per-shell completion dir **only on explicit
request** and removes it on uninstall -- it never edits the host shell rc
implicitly. README documents this as a prerequisite for namespace tab
completion.

### 8. `init.sh` / `upgrade.sh` leave the root (amends ADR-00000006)

`init.sh` and `upgrade.sh` move into the `base` namespace's tooling. Per
§4 the real files live in `downstream/script/base/` (the shipped source of
truth) and base-own `script/base/` symlinks into it. They back
`just base init` / `just base upgrade` / `just base update`.

- **Region A** (ADR-00000006/00000010 froze `.base/init.sh` at root) is
  **superseded**: the bootstrap path becomes
  `.base/downstream/script/base/init.sh` (a brand-new consumer's documented
  one-time bootstrap command updates accordingly; the wrapper-first rule
  from ADR-00000005 means steady-state users call `just base ...`, not the
  raw script).
- **Regions B/C** keep their ADR-00000010 `downstream/` locations.
- `upgrade.sh`'s self-referential and frozen-path constants move in the
  same slice that relocates the script, per ADR-00000006's lockstep
  discipline.

## Final command list

```
just                              # list
just docker  build [--stage <s>] | run [-d] | start | exec [-t <svc> -- <cmd>]
             | stop | prune | setup | setup-tui
just test    [--file <f>] [--filter <re>]
just test    lint [--shellcheck [<level>] | --hadolint]
just test    coverage | behavioural
just release [--tag <vX.Y.Z>] [...]
just base    init | update | upgrade [--tag <vX.Y.Z>]
             | completions install [--shell <sh>] | completions uninstall
just template new <name>          # consumer: scaffold a repo-local group
just <group> <recipe>             # consumer repo-local groups
# every level: --help, --lang <code>
```

## Consequences

- **Breaking again for consumers**, on top of ADR-00000010: `just build`
  -> `just docker build`, `just ci` -> `just test`, `just cd` ->
  `just release`, root `init.sh`/`upgrade.sh` -> `just base ...`. The
  fanout slice re-inits every downstream repo; the bootstrap doc path
  changes. Justified: it buys one rule with zero special cases, which is
  cheaper to teach and to extend than the mixed model.
- **Tab completion becomes a documented opt-in step**, not automatic --
  accepted to avoid touching the host shell config without consent.
- **One test runner** removes the base-vs-consumer tooling fork; the cost
  is a content-detecting runner (a branch on what `test/` contains), which
  is deliberately *not* counted as a "special case" because it is one file
  with one interface, not divergent command surfaces.
- Lands as a revision epic of thin slices, each gated by the base
  self-test, superseding the not-yet-fanned-out parts of ADR-00000010's
  epic.

## Alternatives

- **Keep docker top-level for ergonomics.** Rejected: the special case is
  exactly what made the model hard to extend and teach; completion
  recovers most of the ergonomic loss.
- **`lint` as a top-level peer of `test`.** Rejected: lint is a CI check,
  so it belongs under `test`; a top-level peer would re-introduce the
  "which actions are bare" ambiguity and need its own justfile + scripts.
- **Bare positional args (`just test foo.bats`).** Rejected in favour of
  `--file` / `--filter`: explicit options scale uniformly from min to max
  and self-document; positional meaning does not.
- **Separate base-own vs consumer test tooling.** Rejected: the tools are
  identical and only content differs, so a generic runner keeps the whole
  `script/` tree a single symlinked origin (no duplication, no drift).
- **Auto-install completions on `init`.** Rejected: writing to the host
  shell config without explicit consent is host pollution; made an opt-in
  `just base completions install` instead.
