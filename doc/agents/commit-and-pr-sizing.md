# Commit and PR sizing

How big a pull request and a commit may be in this repo, and how to split work
that is bigger. These rules apply to people and to agents alike. Enforcement is
a separate concern, tracked in `ycpss91255-docker/base#1629`.

## One PR = one behaviour

A PR addresses exactly one bug, one focused feature, or one cohesive refactor.
Issues found on the same day, or in the same CI run, are still separate issues
and separate PRs unless they are one behaviour.

## Stacked slices

Work that does not fit in one small PR is split into slices that can each be
reviewed and tested on their own, for example:

1. the library or helper layer;
2. fixtures and golden-file updates;
3. the CLI or workflow integration that uses them.

Each slice is its own PR. A later slice may be stacked on an earlier one, but
every slice must pass CI by itself. Inside a slice, one red/green pair covers
one behaviour.

## Atomic commits

A commit is the minimum logical unit: one cohesive change that builds and
tests green. Keep commit messages scoped to that one change.

## Merge commit

Squash merging is forbidden. Every PR lands with a merge commit, so each
commit on the branch keeps its sha for bisect and blame, and
`git log --first-parent` gives the PR-level history of `main`.

Because every branch commit reaches `main`, keep each PR to one behaviour and
avoid noise commits: merge `main` only when needed, and add no fixup or
review-round commits that carry no change. A PR that needs several distinct
behaviours is a sign it should be split into slices.

## When to split

Split before opening the PR if any of these hold:

- the PR body describes a second concern;
- the title needs "and" to be accurate;
- the changed files include unrelated areas.

## Owner action

Landing a PR's commits individually needs the repository's rebase-and-merge
setting, which is left as it is; this doc does not change it. At the time of
writing, `gh api repos/ycpss91255-docker/base --jq .allow_rebase_merge`
returns `true`. Squash merging is to be turned off once the merge helpers
default to merge commits (base#1690); it is not off yet.
