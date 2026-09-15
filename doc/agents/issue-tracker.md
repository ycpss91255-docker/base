# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues on
**`ycpss91255-docker/base`**. Every operation goes through the `gh` CLI.

Creating and editing an issue goes through `.agents/scripts/gh-issue.sh`,
which checks this repo's conventions before anything reaches GitHub; every
other operation is a plain `gh` call. The `.agents/hooks/redirect_gh_issue.sh`
PreToolUse hook notices a direct `gh issue create` or `gh issue edit` and
points at the script, so a skill that reaches for the raw command loses one
round trip rather than filing something malformed.

**PRs as a request surface: no.** External pull requests are not part of
the triage queue here; `/triage` covers issues only, and a bare `#42`
resolves to an issue.

## Conventions

- **Create an issue**: `.agents/scripts/gh-issue.sh create --title "scope: ..." --body-file <path> --label <kind> [--label <state>]`. Write the body to a file first; the script always hands it to `gh` as `--body-file`. `.agents/hooks/enforce_gh_body_file.sh` denies a `gh issue create` that carries an inline `--body` or no `--label`, so both flags are mandatory in practice, not merely conventional.
- **Edit an issue**: `.agents/scripts/gh-issue.sh edit <number> --title "..."` / `--body-file <path>`. The target may be the issue number or its URL, the two forms `gh` itself accepts.
- **Read an issue**: `gh issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."` for a short single-line comment; anything multi-line or long goes through `--body-file`, which the same hook enforces.
- **Apply / remove labels**: `.agents/scripts/gh-issue.sh edit <number> --add-label "..."` / `--remove-label "..."`. The label flags take a comma-separated list, as in `gh` itself.
- **Close**: `gh issue close <number> --comment-file <path>`.

Infer the repo from `git remote -v`; `gh` does this automatically when run
inside a clone, and this clone's `origin` is
`https://github.com/ycpss91255-docker/base.git`. Pass `-R
ycpss91255-docker/base` explicitly when a command runs from outside the
worktree, such as from a sibling repo or a scratch directory.

## Title and body format

The shape of a title, the five standard body sections, the close-comment
tiers and the cross-reference keyword vocabulary are specified once, in the
vendored `gh-artifact-format` skill (`.agents/skills/gh-artifact-format/`).
That skill is the single home for the format; this document does not restate
it, and where the two ever disagree the skill wins for format and this
document wins for which command to run.

## Labels

Which label to apply, and what the state labels mean, is
[triage-labels.md](triage-labels.md). All six state labels are live on GitHub
as of 2026-09-09; that file also records what remains from #1182.

## When a skill says "publish to the issue tracker"

Create a GitHub issue on `ycpss91255-docker/base`, via
`.agents/scripts/gh-issue.sh create`.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as
tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `.agents/scripts/gh-issue.sh create --label wayfinder:map ...`, which still needs its kind label.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/ycpss91255-docker/base/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/ycpss91255-docker/base/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `.agents/scripts/gh-issue.sh edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --body-file <path>`, then `gh issue close <n>`, then append a context pointer to the map's Decisions-so-far.

## Cross-repo issues

A `#<n>` written in this repo means an issue in `ycpss91255-docker/base`. An
issue in a sibling repo is written in full, `ycpss91255-docker/<repo>#<n>`,
because a bare number resolves against whichever repo the reader happens to be
standing in. GitHub shares one number space across issues and pull requests,
so a bare `#42` may be either: resolve with `gh pr view 42` and fall back to
`gh issue view 42`.
