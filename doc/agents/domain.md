# Domain Docs

How the engineering skills should consume this repo's domain documentation
when exploring the codebase.

## `doc/`, not `docs/`

**This repo's documentation directory is `doc/`.** The stock templates that
ship with the `setup-matt-pocock-skills` skill say `docs/` throughout, and
every one of those paths is wrong here. This file is where that is recorded,
per `ycpss91255-docker/base#1170`: when a skill's own text names `docs/adr/`
or `docs/`, read it as `doc/adr/` and `doc/`. There is no `docs/` directory in
this repo and creating one would split the documentation in two.

The same substitution applies to anything a skill writes: a new ADR, a
generated index, a link inside an issue body. Write `doc/`.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root: the glossary and the domain model.
- **`doc/adr/`**: read the ADRs that touch the area you're about to work in. `doc/adr/README.md` is the index and the PRD audit, and is the cheapest way to find the relevant ones without opening all of them.
- **`doc/PRD.md`**: base's north star. Every ADR carries a `> Serves:` line pointing back at a PRD invariant, goal or scope item, so the PRD is what an ADR is ultimately arguing from.

If any of these files don't exist, **proceed silently**. Don't flag their
absence; don't suggest creating them upfront. The `/domain-modeling` skill
(reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates
them lazily when terms or decisions actually get resolved.

## File structure

This repo is **single-context**: one `CONTEXT.md` at the root, one ADR
directory, no `CONTEXT-MAP.md` and no per-context glossaries.

```
/
├── CONTEXT.md
├── doc/
│   ├── PRD.md
│   └── adr/
│       ├── README.md                              ← index + PRD audit
│       ├── 00000001-setup-conf-vs-compose.md
│       ├── 00000002-no-latest-tag.md
│       └── ...
├── script/
└── test/
```

ADR filenames are `NNNNNNNN-<slug>.md` — an **eight-digit** zero-padded
number, not the four digits the stock templates show — and ADRs are cited in
prose as `ADR-00000001`, with the full eight digits. The filesystem is the ADR
registry: there is no separate list of numbers, and a lint
(`script/test/drivers/adr_numbering.sh`, wired into `just test`) fails CI on a
duplicate number or a malformed filename. `doc/adr/README.md` is deliberately
not an ADR filename so that it does not perturb that lint.

Use `.agents/scripts/new-adr.sh` to start a new ADR rather than hand-picking a
number.

If a `CONTEXT-MAP.md` ever appears at the root, this repo has become
multi-context and this section is out of date — read the map and each
`CONTEXT.md` it points at.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor
proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`.
Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either
you're inventing language the project doesn't use (reconsider) or there's a
real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than
silently overriding:

> _Contradicts ADR-00000002 (no `latest` tag for base), but worth reopening
> because…_

An ADR that a change actually overturns gets a superseding ADR, not a quiet
edit: the `adr` skill and `.agents/scripts/new-adr.sh` are the path for that.
