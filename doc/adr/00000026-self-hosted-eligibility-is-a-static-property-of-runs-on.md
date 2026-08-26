# Self-hosted eligibility is a static property of `runs-on`, and the guard is linted rather than remembered

> Serves: PRD invariant 7 (rigorous test bar) -- the CI gate must be
> trustworthy, which includes not executing untrusted code on the org's
> own hardware and not reporting a partial run as a full one.

- **Date:** 2026-08-26
- **Status:** Accepted
- **Relates to:** ADR-00000017 (CI throughput ceiling; names this guard as
  the hard prerequisite for any self-hosted migration), ADR-00000008
  (sharded coverage PR gate / ci-rollup as the single required check),
  issue #766

## Context

`base` is a **public** repo. The org registers **one org-level self-hosted
runner**, and the settings that matter were checked rather than assumed:

- `GET /orgs/ycpss91255-docker/actions/runners` -> one runner,
  `C01013328-ycpss91255-docker-org`, `status=online`, labels
  `self-hosted, Linux, X64, gpu`.
- `GET /orgs/ycpss91255-docker/actions/runner-groups` -> a single `Default`
  group, `visibility: all`, **`allows_public_repositories: true`**,
  `restricted_to_workflows: false`.
- `GET /repos/ycpss91255-docker/base` -> `visibility: public`.
- `GET /repos/.../actions/permissions/fork-pr-contributor-approval` ->
  `all_external_contributors`.

The runner is a developer workstation (`hostname` = `C01013328`) that also
hosts unrelated tenants -- a second runner tree for `ycpss91255-research`,
a GitLab runner container, long-running GPU workloads. So "the machine a
fork PR could reach" is not a hypothetical future box; it is the machine
the maintainer works on.

ADR-00000017 recorded self-hosted as a documented-but-gated path and named
this guard as its prerequisite. The remaining question was not *what* the
condition should be -- the issue already wrote it -- but **how to make
"every eligible job carries it" survive the next person who adds a job.**

That question has a track record in this repo. A hand-maintained roster of
"the things that must all be listed" has decayed three separate times: the
`_LINT_TOOLS` table (lints landed local-only because nothing forced a CI
join), the downstream repo roster, and the release archive's hardcoded
path list (which shipped the same class of break twice, on a different
path each time). A guard applied by hand to today's N jobs is the same
shape and would fail the same way at job N+1.

## Decision

### 1. Eligibility is computed from `runs-on`, not from a list of job names

A job is **self-hosted-eligible** unless a lint can PROVE, statically, that
every label its `runs-on` can resolve to is a **reserved GitHub-hosted
label** (`ubuntu-*`, `windows-*`, `macos-*`). Anything unproven defaults to
eligible -- the rule fails closed.

Resolution follows, in order: a literal scalar or literal sequence; then
`${{ matrix.<key> }}` resolved against the job's **own literal**
`strategy.matrix` (both the `include:` form and the bare list form).
Everything else is eligible: a `group:` child (a runner group has no
hosted reading), a `matrix: ${{ fromJSON(...) }}` whose label set is
computed at runtime, `${{ inputs.runner }}` or any other expression, and a
job with no `runs-on` that calls a **remote** reusable workflow (a local
`uses: ./...` is exempt, because the callee's own jobs are checked where
they are defined).

**Why a label-family pattern rather than a roster.** Those three families
are reserved by GitHub and cannot be claimed by a self-hosted runner, so
membership is a property of the label decided by GitHub -- not a list this
repo maintains and must remember to update. The rule therefore survives a
migration untouched: the day any `runs-on` stops naming one of those
families, that job needs the guard, whether it was written today or years
from now. Note that the org runner's own `Linux` and `X64` labels fall
outside the allow-list too, which is the intended reading.

### 2. The guard is enforced by a lint in `_LINT_TOOLS`, not by review

`script/test/drivers/self_hosted_guard.sh` scans `.github/workflows/` --
the directory, not a file list -- classifies every job by the rule above,
and fails naming each eligible job that lacks the condition, printing the
condition verbatim so it can be pasted. It is registered in `_LINT_TOOLS`,
which (via the existing completeness guard in `self_test_yaml_spec`)
*forces* it to have a CI job; it runs as a `lint-static` matrix entry and
in the local `just test` lint phase. Like the other drivers it carries its
own non-vacuity checks: a missing workflow directory, an empty one, or a
parse that yields zero jobs is a failure, not a pass.

### 3. The condition is a FORK test, not a PR test

```yaml
if: >-
  github.event_name != 'pull_request' ||
  github.event.pull_request.head.repo.full_name == github.repository
```

A same-repo PR passes on the second disjunct. A branch push, a **tag
push**, `schedule` and `workflow_dispatch` pass on the **first** disjunct
without ever reading the `pull_request` payload -- which is `null` for
those events, so the second disjunct alone would be wrong and would
silently disable the release path. Under `workflow_call` the `github`
context is the **caller's**, so inside a reusable worker the condition
reads "the calling repo's run was not started by a fork PR against that
repo" -- the correct question, since it is the caller's fork PR whose code
the worker would build.

A job may AND the guard with its own gate; what the lint requires is that
the canonical expression appear verbatim in the normalised `if:` text, so
`<existing> && (<guard>)` satisfies it and a reworded near-miss does not.
`github.repository_owner`-style rewrites are the specific trap: they pass
for every fork inside the same org, which is not the property being
asserted.

### 4. A guarded skip must never make `ci-rollup` vacuously green

This is the half that is more dangerous than the risk being closed. The
guard's effect is a **skip**, and `ci-rollup` treats SKIPPED as
pass-equivalent for conditionally-gated jobs (it has to, or doc-only PRs
could not merge). `worker-selftest` calls `build-worker.yaml`, whose
`build` job now carries the guard: on a fork PR that job skips while the
worker's other jobs succeed, so `needs.worker-selftest.result` is
`success` and the rollup would report a build that never ran as a green
**required** check -- for precisely the untrusted PR.

So `ci-rollup` carries an explicit fork-PR branch that sets `fail=1` with a
named reason. A required check is a claim that the commit was fully
tested; on a fork PR that claim is false, and the honest answer is red with
an explanation, not green. The maintainer's path for an external
contribution is to re-push it as a same-repository branch, which is the
standard posture for a public repo whose org owns a self-hosted runner.

## Consequences

- Today's eligible set is exactly three jobs -- `build-worker`'s `build`,
  `publish-worker`'s `publish`, `release-test-tools`'s `build` -- all three
  eligible for the same reason (a `fromJSON` runtime matrix). Every other
  job in the tree resolves statically to a reserved hosted label and is
  deliberately **not** guarded, so fork PRs keep getting real CI on
  GitHub-hosted runners for everything the lint can prove is safe.
- The change is operationally inert on every event that exists today:
  `release-test-tools` has no `pull_request` trigger at all, `publish-worker`
  is called from tag-push release flows, and `build-worker`'s only changed
  behaviour is that a **fork** PR of a consuming repo no longer builds.
  There are zero fork PRs in this repo's history.
- A self-hosted migration cannot silently land unguarded: pointing any
  `runs-on` at a non-hosted label, or adding a self-hosted entry to a
  literal matrix (which does not change the `runs-on` line at all), turns
  the lint red until the condition is added.
- The eligible **count** is pinned in the spec, so a change to the eligible
  set is a deliberate edit rather than a silent drift.
- Cost: three jobs whose runner label is genuinely hosted today carry a
  condition they do not yet need. That is the price of the fail-closed
  default, and it is paid where the migration would start anyway.

## Alternatives

- **Apply the condition to every job.** Rejected: it would skip the whole
  suite for a fork PR, and with the rollup's SKIPPED=pass rule that
  converts the required check into a vacuous green -- the exact class this
  cycle has been clearing out. It also removes any CI signal from external
  contributions for a risk that only attaches to some jobs.
- **Apply it only to jobs whose `runs-on` literally says `self-hosted`.**
  Rejected: that is a *detector for the migration having already happened*,
  not a prerequisite for it. It cannot see a self-hosted entry added to a
  matrix, a runner group, or a runtime-computed label set.
- **A hand-maintained list of guarded jobs, checked by a spec.** Rejected
  on this repo's own record: `_LINT_TOOLS`, the downstream roster and the
  release archive path list all decayed exactly this way. The list has to
  be derived from the file, not written beside it.
- **Solve it by runner selection instead (force fork PRs onto hosted
  runners).** Attractive because fork PRs would keep full CI, but it
  requires every job's `runs-on` to become an expression -- which, under
  the rule above, makes every job unprovable and therefore eligible, and
  moves the safety property into a computed value no static check can
  read. Rejected as strictly harder to verify than the `if:`.
- **Rely on `fork-pr-contributor-approval = all_external_contributors`
  alone.** Rejected: it is a human gate, and the residual risk this ADR
  closes is exactly the day a maintainer approves an external PR without
  realising a job now runs on the workstation. It remains a useful second
  layer, not the mechanism.
- **Restrict the runner group instead (`allows_public_repositories:
  false`, or `restricted_to_workflows`).** Not rejected -- a genuinely good
  complementary control, and cheaper than this one. But it is org
  configuration, invisible in the repo, unversioned and untestable from
  here; a repo-local guard that CI enforces is the part that belongs in
  the repo. Worth doing as well, not instead.
