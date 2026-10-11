# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps
those roles to the label strings used in this repo's tracker
(`ycpss91255-docker/base` GitHub Issues), and documents the one further state
role this repo adds on top of them, for **six state labels** in total.

This repo uses the **canonical names verbatim**: every label string equals its
role name, so nothing has to be translated when a skill names a role.

| Role / label      | Colour   | Description                                                                    |
| ----------------- | -------- | ------------------------------------------------------------------------------ |
| `needs-triage`    | `fbca04` | Maintainer needs to evaluate this issue                                        |
| `needs-info`      | `d876e3` | Waiting on reporter for more information                                       |
| `ready-for-agent` | `0E8A16` | Spec is fully specified and ready for an agent to implement                    |
| `ready-for-human` | `1D76DB` | Requires human implementation: judgment calls, external access, or manual testing |
| `wontfix`         | `ffffff` | This will not be worked on                                                     |
| `needs-decision`  | `006b75` | Waiting on a maintainer decision, not more information                         |

The first five are the canonical roles the skills know. The sixth,
`needs-decision`, is local to this repo: no skill names it, so `/triage` will
never apply it on its own and a human has to.

## The three-way boundary

`needs-triage`, `needs-decision` and `needs-info` are three different states,
not three spellings of "stuck".

- **`needs-triage` — nobody has looked yet.** Intake. The issue has not been evaluated by anyone, so nothing is known about what it is blocked on.
- **`needs-decision` — someone has looked, and the issue is blocked on a judgement.** Post-intake. The issue is understood; what is missing is a call, not a fact and not a pair of hands.
- **`needs-info` — waiting on a reporter, not on a maintainer.** The next move belongs to the person who filed the issue. If the next move belongs to a maintainer, this is the wrong label: it is `needs-decision` (a judgement is owed) or `needs-triage` (nobody has looked).

The direction of the wait is what separates `needs-info` from
`needs-decision`. Both mean "blocked", but one points outward at the reporter
and the other points inward at the maintainers.

## `needs-decision` is not a parking label

An issue that is fully specified and is only waiting for someone to write the
code or the text is **`ready-for-agent` or `ready-for-human`, not
`needs-decision`**. Waiting for capacity is not the same as waiting for a
decision.

The test: **could a competent implementer start today without choosing
anything?** If yes, the decision is already made, and the issue is ready — the
only remaining question is who does it, which is what `ready-for-agent` and
`ready-for-human` answer. If no, name the choice that is missing and the issue
is `needs-decision`.

## Discipline: exactly one state label per issue

An issue carries **exactly one** of the six state labels. Applying a new state
means removing the old one in the same edit, not stacking them: an issue that
is both `needs-triage` and `ready-for-agent` is a contradiction, and an issue
with no state label is invisible to `/triage`.

The commonest violation is promoting an issue out of intake and leaving
`needs-triage` behind. Applying `needs-decision`, `needs-info`,
`ready-for-agent`, `ready-for-human` or `wontfix` means removing
`needs-triage` from that issue.

## Labels that are NOT triage states

Three other axes exist, and none of them substitutes for a state label.

- **`backlog` and `upstream` are orthogonal to the state machine.** An issue can be `ready-for-agent` and `backlog` at once, or `needs-decision` and `upstream` at once. They are not states, they are not substitutes for a state, and a state transition **does not strip them** — `/triage` must carry them across unchanged.
- **`bug` / `documentation` / `enhancement` are the org kind axis.** Exactly one per issue, in parallel with exactly one state label. `/triage`'s two category roles map to `bug` and `enhancement`; `documentation` is the third kind the org uses for docs-only work.
- **`dependencies` and `github_actions` belong to Dependabot**, which applies them to its own pull requests. They are not triage vocabulary and `/triage` should ignore them.

## Live state: the table matches GitHub and the stock-default cleanup is done

**Every label in the table above exists on `ycpss91255-docker/base`** with
the colour and description shown. The tracker was migrated on 2026-09-09.
Verified against the live set with:

```
$ gh label list -R ycpss91255-docker/base
$ gh issue list -R ycpss91255-docker/base --label needs-triage --state all
```

The live set is **thirteen labels and nothing else**: the six state roles in
the table, the three kind labels, `backlog` and `upstream`, and Dependabot's
`dependencies` and `github_actions`. Anything outside that list is drift.

What was applied:

- **`triage` was renamed in place to `needs-triage`** with `gh label edit triage --name needs-triage`, not deleted and recreated, so every issue that carried `triage` still carries the intake role under its canonical name. The live count is **32 issues** across open and closed. No label named `triage` remains.
- **`needs-info`, `ready-for-human` and `needs-decision` were created** with the exact colours and descriptions in the table.
- **`needs-decision` is byte-identical to the two reference repos**: name, colour `006b75` and description match `ycpss91255-docker/agent_harness` and `ycpss91255-research/vendor_kit` exactly, so an agent naming the role in any of the three repos lands on the same label.
- **`ready-for-agent` and `wontfix` already matched** and were not touched.

That is the label half of `ycpss91255-docker/base#1182` (the five canonical
roles) and of `ycpss91255-docker/base#1183` (`needs-decision`). Whether
either issue is closed on the strength of it is the maintainer's call; the
labels are live regardless.

### Done, from #1182: the stock defaults

The other half of `ycpss91255-docker/base#1182` has landed. All five of
GitHub's stock default labels are gone from the tracker, and none of them is
part of this vocabulary:

- **`duplicate`, `invalid`, `good first issue` and `help wanted`** had never been applied to an issue or a pull request here, and were deleted outright.
- **`question`** was deleted too. It was on one closed issue, `#765`, which now carries no labels at all -- so the delete did strip it, as the pending note here warned it would, and that was decided rather than stumbled into.

Re-derive before trusting this section, with `gh label list` and, per name,
`gh issue list --label "<name>" --state all` plus the `gh pr list` equivalent.

### A stock default is never renamed into a state role

`question` shared colour `d876e3` with `needs-info` while it existed, and the
temptation was to rename it rather than delete it. That would have been
wrong, and the rule outlives the label: **a stock default is not a deliberate
synonym for a state in this vocabulary.** Renaming `question` into
`needs-info` would have silently relabelled every issue that happened to
carry the default as "waiting on the reporter", which is a claim nobody had
made about any of them. `needs-info` was created fresh for exactly that
reason.

The same reasoning applies to any label that reappears looking like an intake
or waiting state. Delete it, or map its issues onto a state role by hand; do
not rename it into one.

### `triage` came back once, and how it was closed out

The rename above is an assertion that rots: nothing stops a label named
`triage` being **recreated**, and one was -- empty description, colour
`ededed`, carried by two open issues (`#1192` and `#1193`) and by nothing
else, while this file still said no such label remained. GitHub creates a
label on demand when one is applied by a name that does not exist, so a
single `--label triage` is all it takes.

It was closed out in the direction this file already argued for: both issues
were given `needs-triage`, the canonical intake role, `triage` was removed
from them, usage was re-checked at zero across issues and pull requests, and
only then was the label deleted. The relabelling came first precisely so the
delete stripped nothing -- the same care the `question` delete above needed.

So the assertion stands, but treat it as a thing to re-derive rather than a
fact on file. `gh label list -R ycpss91255-docker/base` is the check.
