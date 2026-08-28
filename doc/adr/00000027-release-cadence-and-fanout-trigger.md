# Release cadence and fanout trigger: Z is automatic and per-bug, X/Y are human, and only X/Y fans out

> Serves: PRD invariant 6 (base is a subtree; downstream is a thin
> caller) -- this is the cadence at which the single source of truth
> actually propagates, and who decides each step; also invariant 2 (never
> fail silently) via the recorded classification reasoning, which is what
> makes a mis-classified release reviewable instead of invisible.

- **Date:** 2026-08-28
- **Status:** Accepted
- **Relates to:** the `semver-bump` skill and `/release`
  (`.claude/commands/release.md`) -- the operational procedure this is the
  policy behind; issue **#927** (the fanout mechanism whose *trigger* this
  constrains -- #927 decides how a release reaches downstream, this decides
  which releases do), **#926** (the locked changelog category set and
  per-`0.Y` files the PR-body extraction depends on), **#952** (the coverage
  figure rides in the release commit); ADR-00000008's #710 amendment
  (precedent for recording a cadence decision beside the mechanism it
  governs), ADR-00000002 (immutable version pinning -- there is no `latest`
  to drift onto, so a downstream's position is always a named tag),
  ADR-00000006 / ADR-00000011 (the `upgrade.sh` path contract the
  "nothing is skipped" argument rests on)

## Context

The release procedure is fully mechanised and lives outside this repo, in
the harness: the `semver-bump` skill, `/release`, and the
`release-bump.sh` / `release-tag.sh` primitives, with
`batch-base-upgrade.sh` on the fanout side. What none of them state is
**when** a release is cut and **who** decides -- the procedure answers
"how", and the cadence was carried in habit instead.

Two things made that gap start to cost something.

**The ACK rule had already been decided, and was being misread.**
`semver-bump`'s bump-classification table reads, verbatim:

| Tag shape | Bump | Requires |
|---|---|---|
| `vX.Y.Z` where `Z>0` | Z (bug fix) | tag + push (no RC, no ACK) |
| `vX.Y.0` where `Y > prev_Y` | Y (feature / behaviour / break) | prior `vX.Y.0-rcN` with CI all `success`/`skipped` |
| `vX.0.0` where `X > prev_X` | X (ceremonial) | above PLUS `RELEASE_X_BUMP_ACK=<tag>` |

A Z tag needs no approval and never did. During the v0.42.x cycle this was
over-read as "every final tag needs approval", which is the X row's rule
applied to all three.

**The mechanism now has a blast radius.** #927 settled how a base release
reaches downstream: base's release fans an upgrade PR out directly, scope
**discovered by scanning** for a default branch carrying `.base/.version`
rather than read off an allowlist, and the PR is **opened and left open --
CI going green does not merge it**. Scanning the org today returns
**exactly 17 repos**: `ai_agent`, `claude_code`, `codex_cli`, `gemini_cli`,
`isaac`, `jetson_sdk_manager`, `omniverse_web_viewer`, `realsense_ros1`,
`realsense_ros2`, `ros1_bridge`, `ros2_distro`, `ros_distro`,
`sick_humble`, `sick_noetic`, `template`, `urg_node_humble`,
`urg_node_noetic`. Every one of them is a PR a human has to read.

So "when do we release" stopped being a matter of taste. Bound to the
wrong trigger it is 17 PRs; bound to the wrong approver it is either a
maintainer pressing a button on every bug fix, or an agent imposing a
breaking migration on 17 repos unattended.

## Decision

### 1. A Z release is cut by the agent without asking, one per bug

`vX.Y.Z` with `Z > 0` is tagged and pushed on the agent's own initiative.
This is not new policy -- it restores what the table above already said.

**One bug fixed = one Z release.** Not a batch. The property being bought
is that a downstream can name the release that carries the fix it needs;
a batch destroys exactly that, and cannot be recovered from the tag
afterwards.

### 2. An X or Y release is cut by a human, always

`vX.Y.0` and `vX.0.0` are the maintainer's to cut. No exception and no
standing authorization: an agent may prepare the RC, run the gate and say
the tree is ready, and then stops. X additionally keeps the
`RELEASE_X_BUMP_ACK` gate the script already enforces.

### 3. The judgement that matters is the classification, not the tagging

**An issue whose fix changes behaviour is not a Z, whatever it is filed
as.** It is a Y, and a Y returns to the human. `semver-bump` already says
"if you're unsure whether a change is Y or Z, lean Y"; this ADR makes that
binding rather than advisory, because with §1 in force the agent's
classification is the only gate left before a tag exists.

The v0.42.1 episode is why this clause is written down. That release was
**not** cut, because its content was not Z-shaped:

- `c6b53ea2` (closes **#914**) replaced the release archive's hardcoded
  `cp -r` operand list with a declared payload -- `script/ci/release/archive.manifest`
  plus a `release-archive.sh` assembler. The archive's payload contract
  changed shape.
- `3a36f8b4` (closes **#915**) put an EXIT trap over the whole post-pull
  window of `upgrade.sh`, so a failure after the subtree pull now undoes
  it. That is a rollback mechanism that did not previously exist.
- `7a36cf1a` (**PR #929**, refs #915) added `dockerfile_migrate.sh`
  migrations that `init.sh` applies to `${REPO_ROOT}/Dockerfile` -- base
  **rewrites a file the consumer tracks in git**.
- `d67b6aae` (closes **#882**) added `_report_verification_run` to
  `dist/script/docker/wrapper/build.sh`, wired as
  `_report_verification_run "${TARGET}" "${_VERIFY_LOG}" || exit 1`. A
  build that exited 0 before can now exit 1, in a wrapper every consumer
  vendors.

A consumer taking that content would meet a rewritten Dockerfile and a new
failure mode. None of it is a bug fix in the sense Z means.

Two details of that set are worth stating precisely, because the tempting
short version of this rule is wrong. **The label is not the signal:** the
four were labelled unevenly -- #915 carries `bug`, #914 and #882 carry
`triage`, and **#929 is not an issue at all**, it is the PR that landed the
Dockerfile migration as a follow-up to #915. What actually read as Z was
the uniform `fix(...)` commit type and the bug-report framing, not a label.
So the rule cannot be implemented as "check the label"; it is read off what
the change *does*.

**The reasoning is stated, not asked.** When cutting a Z the agent records
its classification and why in the release, so the call is reviewable after
the fact. That is a report, not a request for approval. The maintainer
retains a veto on the classification -- not a button on each release.

### 4. Fanout is triggered by X and Y only; a Z does not fan out

Under §1 a bug is a release, and this cycle produced six bug issues in two
days. Binding #927's fanout to every release would make one bug 17 PRs,
each of which a human must read because #927 forbids auto-merging them.

**So a Z is tagged and does not fan out.** A downstream that urgently needs
a particular Z tracks it itself.

This costs nothing in completeness, and the reason is not obvious enough to
leave unwritten: **`just upgrade <tag>` is a subtree pull *to* that tag,
not a sequential application of the releases in between.** In
`dist/script/base/upgrade.sh`, `_upgrade`'s "Step 1/5" is a single

```bash
git subtree pull --prefix="${TEMPLATE_REL}" \
  "${TEMPLATE_REMOTE}" "${target_ver}" --squash \
  -m "chore: upgrade ${TEMPLATE_REL} subtree to ${target_ver}"
```

There is no loop over intermediate tags: the tree that lands is the tree at
`target_ver`. A downstream upgrading to the next Y therefore receives every
Z cut in between, in full, whether or not it ever saw them announced.
**Nothing is skipped; only the notification is batched.**

The gap this does create is real and is accepted deliberately: a downstream
currently hitting a bug that a Z has already fixed gets no signal until the
next Y. The alternative -- a notification per Z across 17 repos -- converts
notification into noise, and noise is not read, which costs more than the
gap. A genuinely urgent fix is a case where the maintainer directs a
one-off fanout by hand. **The normal path is batched; the exception is
human.** Building a mechanism for the exception is the part being rejected.

### 5. What a Y fanout PR body must carry

Because a Y now spans every Z since the last fanout, its PR body is the
only place a downstream maintainer sees those Zs at all. It must carry:

- **BREAKING entries expanded, at the top, never collapsed.** The reader is
  scanning 17 PRs and must be able to tell "routine bump" from "this one
  rewrites my Dockerfile" without opening each.
- **The fixes that affect the receiving repo**, in the body proper.
- **Base-internal changes in a collapsed `<details>`, explicitly labelled
  as not affecting this repo.** Omitting them is dishonest -- they ARE in
  the subtree being pulled -- and listing them flat is noise.
- **A table of the releases spanned**, each marked Z or Y and automatic or
  human, so this cadence rule is visible from the PR rather than
  remembered.
- **A statement that the PR is not auto-merged** (#927's rule): CI proves
  the upgrade builds; whether to take it is the receiving repo's call.

The extraction depends on **#926** (locked category set, per-`0.Y`
changelog files). Until #926 lands, pulling clean sections out of the
single changelog file is not reliable enough to generate this body from.

### Follow-ups this ADR does not perform

`semver-bump`'s SKILL.md and `/release` state the *procedure* and are
silent on cadence; they need to carry §1-§3 so an agent reading only the
skill reaches the same answer. Both live in the harness at the workspace
root, outside this repo, and are deliberately left untouched here.

## Consequences

- **Release frequency rises substantially.** The per-run cost of the
  release procedure becomes load-bearing in a way it was not when releases
  were monthly; a slow or manual step in it now repeats per bug.
- `release-bump.sh` runs far more often, so everything it regenerates --
  the compare-link block, and per #952 the coverage figure -- is exercised
  continuously rather than once a cycle. That is a benefit: a stale
  generator now fails early instead of on release day.
- **The tag-triggered workflows run per Z**, so their CI cost is now
  per-bug rather than per-cycle.
- A downstream can name the exact release carrying the fix it needs, which
  is the whole point of not batching.
- **A mis-classified Z reaches downstream only at the next Y**, which
  leaves a window to catch it and re-classify before anyone receives it.
  That is a mild safety property, and it is a consequence of batching the
  fanout rather than a reason for it.
- The maintainer's remaining release work is the two decisions that carry
  judgement -- cutting X/Y, and vetoing a wrong Z classification -- rather
  than acknowledging tags.

## Alternatives

- **Batch several bug fixes into one Z.** Rejected: a downstream can then
  no longer name the release that carries its fix. The batch also tends to
  accumulate behaviour changes until it is really a Y, which is the
  failure §3 exists to prevent, arriving by a different road.
- **Fan out on every release, including Z.** Rejected on volume: 17 PRs per
  bug, each requiring a human read under #927's no-auto-merge rule. The
  reviewing cost is linear in bugs times repos and nothing about it
  amortises.
- **Open an issue rather than a PR in each repo per Z.** Rejected: the same
  volume problem one notch quieter. 17 issues per bug is still a stream
  nobody reads, and an unread notification is worse than a batched one
  because it looks like coverage.
- **Let the agent cut X and Y too, once CI is green.** Rejected: green CI
  proves the tree builds, not that imposing a behaviour change or a
  BREAKING migration on 17 repos is the right call today. That decision is
  the maintainer's, and it is not a property of the test suite.
- **Keep requiring approval for Z as well** -- the status quo during
  v0.42.x. Rejected: it makes the maintainer a button-presser on releases
  whose content is, by definition, only fixes, while the judgement that
  actually matters (is this really a Z?) is one the agent has to make
  either way. It buys ceremony at the point of least risk and nothing at
  the point of most.
