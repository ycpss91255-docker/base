# No `latest` tag for `base`; resolve newest semver dynamically

> Serves: PRD invariant 6 (base is a subtree; downstream a thin caller)
> -- immutable version pinning of the propagation refs; mechanism.

- **Date:** 2026-05-29
- **Status:** Accepted
- **Amended:** 2026-10-06 -- the output-image exemption is scoped to the
  images a repo PUBLISHES. The tooling image, which the workers CONSUME,
  is a build-time dependency ref and falls under the pin rule like any
  other. See "The exemption was about publishing, not consuming" below.

## Context

`base` ships as an immutable, semver-tagged source that downstream
repos consume in two build-time-critical ways:

1. **As a `git subtree`** under `.base/`. `upgrade.sh` records the
   exact pulled tag in `.base/.version` and uses `_semver_cmp(local,
   latest)` to decide whether an update is available and to refuse
   implicit downgrades (per SemVer §11).
2. **As reusable GitHub Actions workflows.** Each downstream
   `.github/workflows/main.yaml` pins
   `ycpss91255-docker/base/.github/workflows/build-worker.yaml@vX.Y.Z`
   (and `release-worker.yaml@vX.Y.Z`); `upgrade.sh` Step 4 rewrites
   those refs to the target tag on every upgrade.

The question "should `base` also publish a moving `latest` tag (a ref
that always points at the newest release)?" was never written down,
yet the entire version-tracking machinery silently assumes the answer
is no. This came up while clarifying how `make upgrade` (with no
`VERSION`) resolves "the latest version": it does **not** read a
`latest` ref — `_get_latest_version()` runs
`git ls-remote --tags --sort=-v:refname | grep -oP
'refs/tags/v\d+\.\d+\.\d+$'`, picking the highest stable semver and
excluding `-rcN` prereleases by construction. GitHub's release page
also auto-marks the newest non-prerelease release as `Latest`, which
is a UI label on a release, not a git ref. Neither mechanism is a
physical `latest` tag, and nothing in the repo creates one.

Note this decision is scoped to `base`'s **own version tags** —
i.e. build-time dependency refs. It is deliberately distinct from the
**output Docker images** downstream repos publish, where a rolling
`:latest` (`is_latest` input) is intentionally supported for opt-in
consumers.

### The exemption was about publishing, not consuming

*(amendment, 2026-10-06)*

This ADR's original wording put `test-tools:main` beside `is_latest` in
the output-image exemption, and that conflated two sides of a rolling
tag. `is_latest` is a tag a repo **publishes** for whoever wants the
newest build; a mutable tag is the whole point of it, and nothing in the
repo's own CI builds from it.

The tooling image is the other side. `ghcr.io/.../test-tools:<tag>` is
what every downstream Dockerfile's test stage is declared `FROM`, so the
worker **consumes** it during the build — which makes it a build-time
dependency ref, exactly the thing the Decision below pins. Under the
exemption it was reached through a `test_tools_version` input defaulting
to the rolling `latest`, and the consequence is the one this ADR already
argues for mutable refs: the same downstream commit linted and tested
against different binaries on different days, with zero downstream diff
and no record of which tooling a build ran against. Four RC tags moving
`:latest` made that concrete.

So the exemption stands for published tags and does not extend to
consumption. The reference a worker builds from is derived from
`.version` in the base checkout it takes at its own ref — which is the
tag `release-test-tools.yaml` publishes the image under, so the worker's
`@vX.Y.Z` pin now covers its tooling too (base#1122). `test-tools:main`
and `test-tools:latest` continue to be published: `:main` is what base's
OWN self-test pulls to skip a from-source rebuild, inside one repo at one
commit, and `:latest` is a human's `docker pull`. Neither is a reference
any worker builds from.

## Decision

**`base` will not provide a `latest` tag (nor any moving ref) for its
own releases. The canonical "give me the newest version" path stays
dynamic semver resolution, and all build-time references stay pinned
to immutable `vX.Y.Z` tags.**

"Newest" is already served three ways without a physical `latest`
ref, and these remain the only supported paths:

- `make upgrade` (no `VERSION`) → `_get_latest_version()` resolves the
  highest stable semver tag (currently `v0.39.0`).
- Dependabot watches the `@vX.Y.Z` refs in `main.yaml`, compares
  against the newest tag, and files a bump PR.
- GitHub's auto-applied release `Latest` label points humans at the
  newest non-prerelease release.

## Alternatives

- **Publish and force-move a `latest` git tag on every release**
  (`git tag -f latest && git push -f`). Rejected: maintaining it
  requires force-pushing a tag on every release, which rewrites a ref
  consumers may have already fetched and breaks local clones / CI
  caches — a widely-discouraged practice. It adds maintenance burden
  and footguns for zero new capability, since "newest" is already
  resolvable dynamically.
- **Point downstream `@ref` at a `latest` (or `main`) ref instead of
  `@vX.Y.Z`.** Rejected: a mutable ref means the same downstream
  commit can execute different `base` workflow code on different CI
  runs — non-reproducible "green yesterday, red today" with zero
  downstream diff and no audit trail of which `base` version a build
  ran against. A mutable ref is also a supply-chain hazard: anyone
  able to move the ref silently changes what every downstream CI
  executes. GitHub's own guidance is to pin reusable workflows /
  actions to a release tag (or full SHA), not a moving ref.
- **Keep a `latest` ref purely for the subtree pull (not the
  workflow refs).** Rejected: it would break the version-tracking
  core. `.base/.version` and `_semver_cmp` depend on a concrete pinned
  version to compute "update available" and to block downgrades; a
  `latest` pin makes `local_ver` meaningless and `make upgrade-check`
  unable to tell whether a repo is behind. The repo has already been
  burned by mere `.version`/tag mismatches (e.g. the v0.18.2
  `.version` fix where stale pins made `upgrade-check` loop "upgrade
  available" forever); a `latest` ref would make that class of bug the
  default. It would also lose the automatic `-rcN` exclusion that the
  current regex-based resolution provides for free.

## Consequences

- **Costs avoided:** non-reproducible CI, supply-chain exposure from a
  mutable ref, broken semver comparison / downgrade guards, force-push
  tag churn, and bespoke prerelease-exclusion rules.
- **Cost accepted:** consumers who want the newest version must go
  through one of the three resolution paths above rather than pinning
  to a single stable string like `@latest`. This is intentional — the
  pin-to-an-immutable-version friction is the feature.
- **No follow-up work.** This ADR documents a status quo that was only
  ever encoded in `upgrade.sh` and the pinning conventions; no code
  changes. Future contributors proposing a `latest` tag for `base`
  should treat this as the standing rejection and supersede it only
  with a new ADR if the trade-offs change.
- The separately-supported rolling tag for **published output images**
  (`is_latest` → `:latest`) is unaffected; this decision does not
  constrain what a repo publishes.
- **What a worker CONSUMES is constrained** (amendment, 2026-10-06). The
  tooling image a build is declared `FROM` is a build-time dependency
  ref, so it is derived from `.version` in the version-matched base
  checkout rather than taken as an input defaulting to a rolling tag. The
  cost accepted is that a downstream build fails loudly in the window
  between a base tag being pushed and `release-test-tools.yaml`
  publishing the image under it — which is the fail-closed direction: the
  alternative was a green run against tooling nothing had chosen.
  `test-tools:main` and `test-tools:latest` stay published, and neither
  is consumed by a worker.
