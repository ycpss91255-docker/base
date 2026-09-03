# ADR index + PRD audit

This is the index of base's Architecture Decision Records **and** the
audit that maps each ADR onto [`doc/PRD.md`](../PRD.md) -- base's north
star. Every ADR now carries a one-line `> Serves:` back-reference to the
PRD invariant (1-11), goal, or scope item it upholds; this table is the
consolidated view.

**The filesystem is the ADR registry.** There is no database and no
manually-curated master list of numbers -- the set of `doc/adr/NNNNNNNN-<slug>.md`
files *is* the registry. The ADR-numbering lint
(`script/test/drivers/adr_numbering.sh`, wired into `just test`; landed
with the PRD work under #808 / #823) guards it: a duplicate ADR number or
a malformed filename **fails** CI, while a numbering **gap** is warned,
not failed. This `README.md` is deliberately *not* an ADR file (its name
does not match `NNNNNNNN-<slug>.md`), so it does not perturb that lint.

**Authoring rule.** The ADR-structure lint
(`script/test/drivers/adr_structure.sh`) requires exactly one occurrence of
each required part -- `> Serves:`, `## Context`, `## Decision`,
`## Consequences`, `## Alternatives`, `- **Status:**` -- at column 0, so an
ADR that illustrates one of those lines indents the illustration out of
column 0, and an amendment that restates a section or a status uses a `###`
heading or a different key (`- **Amendment status:**`). The rule is about
column 0 and nothing else -- the lint does not know what a fence is -- so a
parked or commented-out copy of one of those lines counts exactly like a
live one and is indented too.

## Anomalies (resolved)

- **`00000009` is an intentional gap.** There is no ADR-9 and none will
  be back-filled; the number was skipped. The numbering lint warns on it
  and passes. Do not invent a `00000009`.
- **`ADR-00000020` is a single canonical record.** A parallel-authoring
  incident once produced two files both numbered `ADR-00000020` (the very
  case the #823 numbering lint now catches). The canonical
  `00000020-base-owns-single-service-lifecycle.md` is the foundational
  "base owns the single-service lifecycle" axiom; the separate
  init-default-toggle content was **folded into** it (init defaults ON is
  ADR-20's two-branch-rule example, see its Consequences). There is no
  second ADR-20.

## Verdict vocabulary

| Verdict | Meaning |
|---|---|
| `keep` | Accurate as written; no change needed (inline amendments, where present, are already recorded in the file). |
| `amend` | A factual detail is now stale and should be refreshed (tracked as a follow-up, not edited here). |
| `supersede` | Replaced by a later ADR (named). |
| `merge` | Overlaps another ADR and could be consolidated (named). |
| `elevates-invariant` | Established a PRD Core Invariant (named 1-11). |
| `elevates-principle` | Established a PRD Design Principle (named P1-P9). |

The eleven PRD Core Invariants: **1** one container = one service / base
owns the single-service lifecycle; **2** never fail silently; **3**
multi_run-expandable by construction; **4** fail-safe defaults; **5** the
two-branch default rule; **6** base is a subtree / downstream a thin
caller; **7** rigorous, industry-aligned test bar; **8** development and
field are cleanly separated, provisioned by opposite means; **9** identity
and naming are resolved once, from a file; **10** documentation is
derived from the code, never duplicated beside it; **11** a default is
decided by two questions, not by preference. ADRs that are pure
*mechanisms* serve a goal but map to no invariant -- the table says so
explicitly. Below the invariants the PRD also carries **Design
Principles** (P1-P9) and a **Conflict Priority** order; an ADR that
establishes one of those is `elevates-principle`.

## Audit table

| ADR | Verdict | Serves | Note |
|---|---|---|---|
| 00000001 -- setup.conf vs compose-native boundary | keep | mechanism (config-resolution boundary; serves the one-source-render goal), no invariant | The escape-hatch/`--env-file` case was refined into a primary path by ADR-00000003. |
| 00000002 -- no `latest` tag for base | keep | invariant 6 (subtree / propagation) -- mechanism | Immutable version pinning of subtree + workflow refs keeps propagation reproducible. Dated example `v0.39.0` is self-dating. |
| 00000003 -- env vs workload boundary + field delivery | keep (amended by 00000023) | invariant 3 (axis-A `.env` overlay model) + goal (one source -> many render; field delivery); also invariant 8 (its env-row override generalizes to config files) | Foundational to the PRD Product Shape; refines ADR-00000001; the overlay model is the seed ADR-00000022 later elevates. **Amended 2026-07-15 (ADR-00000023):** its structured-config Field cell gains a mount-wins `-v` override and "compose does not travel" is refined to "a resolved compose travels" (in-file amendment note). |
| 00000004 -- category-first test layout | supersede (by 00000012) | invariant 7 (test bar) -- mechanism | Category-first reversed to tool-first; Status already records the supersession. |
| 00000005 -- adopt `just` over the Makefile | keep | invariant 6 (thin-caller entrypoint) -- mechanism | The single discoverable user entry ADR-00000010/00000011 build on. Dated `13 downstream repos` / `v0.39.0` are self-dating. |
| 00000006 -- upgrade.sh path contract | keep | invariant 6 (subtree upgrade path) -- mechanism | Frozen interior paths; already carries forward-pointers to ADR-00000010/00000011's `dist/` moves. |
| 00000007 -- log TTY cache + transcript layering | keep | mechanism (wrapper log/transcript single-sink fidelity), no invariant | Ensures a transcript tee cannot silently flip terminal output format. |
| 00000008 -- sharded coverage PR gate | keep | invariant 7 (coverage gate -- a *swappable* mechanism, not the invariant) | Heavily amended inline (Codecov removed, dynamic shards, per-line union merge); all recorded in-file. |
| 00000010 -- layered `just` entry + base/downstream split | elevates-invariant (6) | invariant 6 (subtree / thin caller) | Established the `dist/` split + layered entry. Its docker-top-level decision was superseded-in-part by ADR-00000011 sec.1 -- recommend a forward-pointer (follow-up). |
| 00000011 -- zero-special-case `just` command model | elevates-invariant (6) | invariant 6 (subtree / thin caller) | The current command model + generic test runner; amends ADR-00000010 and ADR-00000006. |
| 00000012 -- tool-first test layout | keep (supersedes 00000004) | invariant 7 (test bar) -- mechanism | Its category *vocabulary* was later amended by ADR-00000018; forward-pointer already present. |
| 00000013 -- strip transient issue refs from comments | keep | invariant 2 (never fail silently) -- the issue-ref lint | PRD invariant 2 names the issue-ref lint as one of its enforcing guards. |
| 00000014 -- decompose setup.sh into subsystem libs | keep | mechanism (source architecture / testability), no invariant | Deep-module decomposition; underpins invariant 7's testability but is an architecture decision. |
| 00000015 -- test files mirror source | keep | invariant 7 (test bar) -- mechanism | Lowers the per-file coverage shard floor; complements ADR-00000008/00000012. |
| 00000016 -- coverage tooling evaluation | keep | invariant 7 (swappable coverage mechanism) | Status is **Rejected**: the spike disproved the "kcov = heavy ptrace" premise; kcov stays. Accurate record. |
| 00000017 -- CI throughput ceiling + shard strategy | keep | invariant 7 (swappable CI/shard mechanism) | PRD explicitly lists this as a swappable mechanism under invariant 7. |
| 00000018 -- ISTQB test taxonomy | elevates-invariant (7) | invariant 7 (rigorous, industry-aligned test bar) | The *commitment* establisher; supersedes only ADR-00000012's category vocabulary. |
| 00000019 -- network host default, bridge opt-in | elevates-invariant (4) | invariant 4 (fail-safe defaults) | The general principle's instance; a sibling lifecycle-defaults decision to ADR-00000020. |
| 00000020 -- base owns the single-service lifecycle | elevates-invariant (1) | invariant 1 (single-service lifecycle); also invariant 5 (two-branch default rule) | Canonical single ADR-20; init-toggle content folded in (see Anomalies). |
| 00000021 -- per-start container logs + shared logrotate | keep | invariant 1 (single-service lifecycle) -- mechanism | The #805 log-persistence lifecycle capability realising invariant 1. |
| 00000022 -- compose<->multi_run overlay contract | keep (amended by 00000025) | invariant 3 (multi_run-expandable by construction); also invariant 2 (the overlay guard) | The overlay contract + `overlay_guard_spec.bats`; PRD names it under both invariants 2 and 3. **Amended 2026-08-05 (ADR-00000025):** the project `name:` row's emitted form is now `${PROJECT_NAME}` (still an interpolation, so the forward invariant and its guard are untouched), plus an explicit statement that a per-worktree `.setup.conf.local` is NOT this contract's mechanism -- it acts before `compose.yaml` is generated (in-file amendment note). |
| 00000023 -- config field-override + self-contained field-deploy contract | elevates-invariant (8) | invariant 8 (dev/field separation, provisioned by opposite means) -- established with ADR-00000003 | The git-tracked provisioning axis, baked-default + mount-wins `-v` override (file analog of ADR-3's env `-e`), deploy-as-resolved-self-contained-compose (amends ADR-3's "compose does not travel"), the deployable-stage rule, and the `config/<component>/deploy.manifest` tunability channel. Reconciled with ADR-00000022 (single-file config `-v` != general volume topology). Mechanism in #831 / #832 / #833. **Amended twice in-file (#874):** sec. 2 now states the mount-override is read-only by default with an explicit `rw` opt-in (#870), and sec. 4's `deployable = not devel and not *-test` is restated as what `_is_deployable_stage` actually enforces (it also rejects `sys` / `devel-base` and the legacy aliases). |
| 00000024 -- bake self-built artifacts at `/opt`, not `$HOME` | keep | invariant 8 (dev/field separation) -- mechanism; also invariant 2 via the `home-literal` lint | `ENV HOME` resolves at BUILD time, so anything baked under `$HOME` is coupled to the build-time `USER_NAME` and breaks on a rebuild / GHCR pull / `docker save`+`load` under a different user. Artifacts go to absolute `/opt`; `~/x -> /opt/x` is a discoverability symlink nothing sources. Its mechanical rule (no concrete username in a path) is gated by the `home-literal` lint. |
| 00000025 -- per-worktree `.setup.conf.local` override + one resolved project name | elevates-invariant (9) | invariant 9 (runtime-name divergence is a file-recorded override) -- established; also invariant 2 (shadowed-write warning, deploy refusal, config-summary row) and invariant 8 (the field refusal) | Third conf layer (`.setup.conf.local`, gitignored, section-replace like the two below it), `[project] name` shipped empty, and `_resolve_project_name` as the single producer both `-p` and compose's `name:` read via `.env.generated`. Un-retires the `.gitignore` entry #879 retired. Removes `SETUP_CONF`. Explicitly NOT a reversal of #600 (configuration, not orchestration) and NOT ADR-00000022's channel (acts before compose.yaml is generated) -- **amends ADR-00000022 in-file** with that division of labour and the `${PROJECT_NAME}` row. |
| 00000026 -- self-hosted eligibility is a static property of `runs-on` | keep | invariant 7 (rigorous test bar) -- mechanism; also invariant 2 (the `self-hosted-guard` lint, and the fork-PR rollup failure instead of a vacuous green) | The org runs ONE org-level self-hosted runner in a `visibility: all` / `allows_public_repositories: true` group, on a shared workstation, and this repo is public. Eligibility is computed from `runs-on` (anything that does not statically resolve to a reserved `ubuntu-*` / `windows-*` / `macos-*` label is eligible and fails closed), so the guard cannot be missed by job N+1 the way `_LINT_TOOLS` / the downstream roster / the release archive path list each were. Enforced by the `self-hosted-guard` lint; `ci-rollup` fails a fork PR rather than collapsing a guarded skip into a green required check. Prerequisite named by ADR-00000017. |
| 00000027 -- release cadence + fanout trigger (Z automatic/per-bug, X/Y human, only X/Y fans out) | keep | invariant 6 (subtree / propagation) -- the cadence at which the single source of truth propagates, and who decides each step; also invariant 2 (the classification reasoning is recorded, so a wrong call is reviewable rather than invisible) | Policy behind the `semver-bump` / `/release` procedure, not a new mechanism. A `vX.Y.Z` (Z>0) is cut by the agent without asking -- restoring `semver-bump`'s own table -- and **one bug = one Z**, so a downstream can name the release carrying its fix; `vX.Y.0` / `vX.0.0` stay the maintainer's. The binding half is classification: an issue whose fix changes behaviour is a Y no matter what it is labelled (the v0.42.1 content -- #914, #915, PR #929, #882 -- is the recorded case). #927's fanout is triggered by X/Y **only**: `just base upgrade <tag>` is one `git subtree pull` to that tag, so a Y delivers every Z in between and nothing is skipped -- only the notification is batched. PR-body requirements depend on #926. |
| 00000028 -- documentation is derived, not duplicated (test statistics live only in the release) | elevates-invariant (10) | invariant 10 (documentation is derived, not duplicated) -- established; also invariant 2 (a hand-maintained figure goes stale silently) | The five grand-total lines and the 1,658 per-test rows leave `doc/test/*.md`; the statistics exist only in a release, rendered from the JUnit XML the tag-push run itself emits. Records the distinction from PR #943 (which deleted a hand-built *source* archive GitHub already produces, not run evidence) and names #952's committed coverage SVG as the open case the invariant decides. Record only -- the mechanism is a separate change, and it is what drops the doc-count drift gate from invariant 2's guard list. |
| 00000029 -- early return is the default function shape | elevates-principle | PRD design principle P1 (early return is the default shape of every function) -- established; no invariant directly (it is the function-level shape ADR-00000014's seams assume, so it stands behind invariant 7's testability) | Decision 1 of the #994 quality epic. States the shape rather than the limit: the depth/length/parameter thresholds are a net that reports where the shape was not applied, not a target. Records the rejection of a baseline file (a hand-kept roster that decays and converts a gate into an inventory of debt) and of gating new code only, and the framing error it corrects -- an earlier nesting audit read depth as 44 violations to rank and fix, which buys 44 fixes and then 44 more because it never reaches the next function written. |

## Audit conclusion

- **keep:** 17 (00000001, 00000002, 00000003, 00000005, 00000006,
  00000007, 00000008, 00000012, 00000013, 00000014, 00000015, 00000016,
  00000017, 00000021, 00000024, 00000026, 00000027) -- 00000003 is `keep
  (amended by 00000023)`, the amendment recorded inline in-file. 00000024,
  00000026 and 00000027 postdate the audit itself and are listed for index
  completeness.
- **supersede:** 1 (00000004, by 00000012 -- already recorded)
- **elevates-invariant:** 9 (00000010, 00000011 -> inv 6; 00000018 -> inv
  7; 00000019 -> inv 4; 00000020 -> inv 1; 00000022 -> inv 3; 00000023 ->
  inv 8; 00000025 -> inv 9; 00000028 -> inv 10). Invariant 11 was not
  established by an ADR: it is invariant 5 generalised in the PRD itself,
  and ADR-00000020 / ADR-00000019 / ADR-00000007 are the instances it
  reads back.
- **elevates-principle:** 1 (00000029 -> P1). Postdates the audit; listed
  for index completeness.
- **amend:** 0 in the verdict column; 1 recommended follow-up (a
  forward-pointer on 00000010 -- see below)
- **merge:** 0

The decision log is already internally coherent: every ADR that was
reversed or refined by a later one carries its own inline
amendment/supersession note. The audit's net additions are the per-ADR
`> Serves:` invariant back-references and this index. The only structural
gap found is that ADR-00000010's now-reversed "docker top-level" decision
has no forward-pointer to ADR-00000011; it is listed as a follow-up for a
maintainer to close, not edited here (per the "no technical-content edits
in this slice" rule).
