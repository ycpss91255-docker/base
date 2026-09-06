# Architecture diagrams live in doc/arch/ as self-contained HTML

> Serves: PRD invariant 10 (documentation is derived, not duplicated)
> -- visual architecture artifacts parallel to prose ADRs, one
> convention across all repos.

- **Date:** 2026-09-06
- **Status:** Accepted
- **Relates to:** ADR-00000037 (toml-config-format-unification),
  ADR-00000036 (parameterised generate API)

## Context

The project accumulates architectural decisions in `doc/adr/` as
prose Markdown. ADRs record **why** a decision was made, but the
resulting structure -- file relationships, data flow, merge
semantics, phase dependencies -- is hard to convey in prose alone.

ADR-00000037 (TOML config unification) demonstrated the gap: six
inline SVG diagrams, four tables, and two before/after comparisons
were needed to make the four-file structure, type-aware merge
semantics, and generation pipeline legible. Embedding that volume
of visual content inside a Markdown ADR would degrade readability
of the decision record itself.

The project has no static site generator, no documentation build
pipeline, and no external diagram hosting. Diagrams must be
viewable by opening a file in a browser -- nothing to install,
nothing to build.

Multiple repos under the org need to follow the same convention so
that cross-repo architecture references are predictable.

## Decision

**Architecture diagrams go in `doc/arch/<topic>.html` as
self-contained HTML files.** Convention:

- **Location:** `doc/arch/`, parallel to `doc/adr/`. ADRs record
  decisions; arch diagrams record the resulting structure.

- **Format:** Single `.html` file, no build step. Open in any
  browser. All CSS in `<style>`, all diagrams as inline SVG, no
  external images. The only permitted external dependency is Google
  Fonts (`fonts.googleapis.com`) with a real fallback stack -- the
  page remains fully legible offline when fonts fall back.

- **Naming:** `<topic>.html` in kebab-case. No numeric prefix
  (unlike ADR filenames) because diagrams have no sequence
  semantics. Examples: `config-pipeline.html`,
  `entrypoint-flow.html`, `ci-matrix.html`.

- **Theme:** CSS custom properties with light/dark support via
  `prefers-color-scheme` media query and `data-theme` attribute.
  Every colour defined as a token on `:root`.

- **Language:** Descriptive text in Traditional Chinese. Technical
  terms (TOML, Docker, ADR, key-level merge, array replace, etc.)
  remain in English. `<title>` in Chinese.

- **Cross-reference:** ADRs reference diagrams with a relative
  path: `See [config architecture](../arch/config-pipeline.html)`.
  Diagrams reference their parent ADR(s) in a subtitle or ref line.

- **Downstream repos:** Create `doc/arch/` and follow the same
  convention. Do not copy base's diagrams into downstream repos --
  base decisions stay in base. Downstream ADRs reference base
  diagrams by repo name: "See base `doc/arch/config-pipeline.html`".

## Alternatives

- **A1 -- Embed diagrams in ADR Markdown.** Zero new files. Rejected
  because Mermaid fences are limited (no fine-grained positioning,
  no semantic colour tokens, no dark-theme control), and large
  inline SVG blocks destroy ADR readability. The ADR becomes a
  diagram document instead of a decision record.

- **A2 -- External diagram tool (draw.io, Figma, Miro).** Richer
  editing. Rejected because: requires an account, diagrams are not
  version-controlled alongside the code, offline access depends on
  export discipline, and cross-repo convention enforcement is
  impossible.

- **A3 -- Generated diagrams from code (Structurizr, D2, PlantUML).**
  Source is plain text, diffable. Rejected because: adds a build
  dependency (the project has none), and the diagrams needed here
  are bespoke visual explanations with precise layout and semantic
  colouring, not auto-layout boxes-and-arrows.

- **A4 -- Put diagrams in `doc/adr/` alongside their ADR.**
  Co-locates decision and visual. Rejected because: one ADR may
  need multiple diagrams (ADR-37 needs six), and mixing `.md` and
  `.html` in the ADR directory blurs the "one ADR = one Markdown
  file" convention that `new-adr.sh` and the ADR index rely on.

- **A5 -- PNG / SVG image files referenced from Markdown.** Simple.
  Rejected because: binary PNGs are not diffable, standalone SVG
  files cannot carry their own CSS theming, and neither format
  supports interactive elements if needed later.

## Consequences

- `doc/arch/` is a new directory in the repo tree. The
  `check-claude-md-tree.sh` lint (if it covers `doc/`) needs to
  include it.

- Architecture diagrams are first-class artifacts: committed,
  reviewed in PRs, versioned with the code. No external dependency
  beyond a browser.

- ADRs stay focused on prose rationale. The "see diagram" link is
  one line, not 200 lines of embedded SVG.

- Downstream repos that adopt `doc/arch/` get a predictable
  location for their own diagrams without inheriting base's content.

- HTML files are slightly harder to diff than Markdown in a PR
  review. Mitigated by: (a) SVG is text, so line-level diffs work;
  (b) the file is opened in a browser for visual review anyway.

- First diagram: `doc/arch/config-pipeline.html` (ADR-37 TOML
  config architecture, 11 sections, 883 lines).
