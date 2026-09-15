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

## Live drift: this table is the target, not the current state

**The labels in the table above do not all exist on GitHub yet.** This file
describes where `ycpss91255-docker/base` is going; the tracker has not been
migrated. Read it as a spec, and check the live set before relying on a label
being applicable:

```
$ gh label list -R ycpss91255-docker/base
```

Where each row stands today:

- **`ready-for-agent` and `wontfix` already match** — name, colour and description as in the table. Nothing to do.
- **`triage` is `needs-triage` under a non-canonical name.** It carries the intake role and is applied to roughly 30 issues. It must be **renamed in place**, `gh label edit triage --name needs-triage -R ycpss91255-docker/base`, never deleted and recreated: `gh label delete` drops the label off every issue that carries it, and those ~30 assignments are not recoverable afterwards. A rename keeps them.
- **`needs-info`, `ready-for-human` and `needs-decision` do not exist yet** and have to be created with the exact colours and descriptions in the table above.

The work is tracked by two issues: `ycpss91255-docker/base#1182` covers the
five canonical roles, and `ycpss91255-docker/base#1183` covers
`needs-decision`.

### `question` is not `needs-info`

`ycpss91255-docker/base` still carries `question`, one of GitHub's stock
default labels, with GitHub's own stock description. It is an **undeleted
default, not a deliberate `needs-info` synonym**, and it must **not** be
renamed into `needs-info`: doing so would silently relabel every issue that
happens to carry the default as "waiting on the reporter", which is a claim
nobody has made about any of them. Create `needs-info` fresh, and decide the
fate of `question` separately.

Until `needs-info` exists, an issue waiting on its reporter is not
distinguishable by label in this repo, and seeing `question` on an issue tells
you nothing about that.
