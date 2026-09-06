# upgrade.sh hard-coded paths are a protocol-stable contract

> Serves: PRD invariant 6 (base is a subtree; downstream a thin caller)
> -- the upgrade.sh frozen-path contract; mechanism.

- **Date:** 2026-06-08
- **Status:** Accepted
- **Amended:** 2026-06-24 by #654 / ADR-00000011 §8 -- Region A's frozen
  `.base/init.sh` root path is superseded. `init.sh` and `upgrade.sh` now
  live deep at `.base/dist/script/base/` and self-locate the subtree
  root via a walk-up (see the Region A note below); the lockstep discipline
  this ADR mandates is what governed that move.
- **Amended:** 2026-06-26 by #714 -- the shipped-tree directory was renamed
  `downstream/` -> `dist/`, so every frozen interior path moves from
  `.base/downstream/...` to `.base/dist/...` (this supersedes the
  `.base/downstream/` contract introduced by #625 / #654). The rename was a
  lockstep change exactly as this ADR mandates: `upgrade.sh` /
  `init.sh`'s subtree-root marker check, the Region B config-drift paths
  (`${TEMPLATE_REL}/dist/config[/docker/setup.conf]`), the Region A Step-3
  `init.sh` call, and the Region C `dockerfile_migrate` lib all moved in the
  same change. **Consumer migration:** an existing consumer on
  `.base/downstream/` that upgrades gets `.base/dist/` after the subtree
  pull, leaving its repo-level wrapper symlinks
  (`script/build.sh -> .base/downstream/...`) dangling; the upgrade->init
  resync heals them because `init.sh`'s `_symlink` helper `rm -f`s the stale
  link and re-`ln -sf`s it at `.base/dist/...` (so stale `.base/downstream/`
  symlinks are dropped and re-pointed). `dockerfile_migrate` migration 4 was
  widened to match `(downstream/|dist/)?` so a consumer Dockerfile on either
  historical path heals to the `dist/` target.
- **Amended:** 2026-07-15 by #831 -- `setup.conf` is `just setup`-managed,
  not hand-edited, so it left the hand-editable `config/` surface: the
  per-repo override moved from `<repo>/config/docker/setup.conf` to the
  repo-root dotfile `<repo>/.setup.conf`, and the template default from
  `${TEMPLATE_REL}/dist/config/docker/setup.conf` to
  `${TEMPLATE_REL}/dist/.setup.conf`. Per this ADR's discipline the move
  was lockstep: Region B's `_warn_setup_conf_drift` blob-hash path
  re-points to `dist/.setup.conf`, and a new `_migrate_legacy_setup_conf`
  step `git mv`s a legacy override to the root and warns loudly (never
  silently drops it). See the re-pointed frozen-path list note below.
  This reverses #262, which had nested setup.conf under `config/docker/`
  for layout uniformity.
- **Amended:** 2026-08-25 by #915 -- the 2026-06-24 amendment above was
  wrong on one point, and a consumer paid for it. It records that Region
  A's `init.sh` call "moved in the same change" as the file, which is
  true of THIS repo's copy and irrelevant to the failure: the copy of
  `upgrade.sh` that drives an upgrade is the CONSUMER'S, vendored at
  their current release, and it cannot be updated in lockstep with
  anything because it has already shipped. Every release up to
  `v0.41.0` still names `./${TEMPLATE_REL}/init.sh`, so on the first
  upgrade into a `dist/`-era tree step 3 died with exit 127 -- after
  the pull had committed -- leaving the repo claiming `v0.42.0` with a
  clean `git status` and every wrapper dangling. **The correction to the
  contract:** lockstep is necessary but NOT sufficient for any path an
  ALREADY-RELEASED caller names. Such a path must keep a forwarder at
  the old location for as long as a release that names it is supported.
  A repo-root `init.sh` now forwards to `dist/script/base/init.sh`; it
  is three lines with no logic of its own, so it cannot drift from the
  implementation, and it restores one name rather than the flat layout.
  The regression guard is behavioural rather than remembered:
  `test/bats/integration/prev_release_upgrade_spec.bats` runs the real
  released `upgrade.sh` against the current tree, so the next move of a
  frozen path fails in CI instead of at a consumer's terminal.
- **Amended:** 2026-09-04 by #1036 -- the correction above covers a path an
  already-released caller NAMES. The same asymmetry applies one step
  further, to work an already-released caller DOES. Every released
  `upgrade.sh` stages the migrated files at its own Step 5 by hardcoded
  filename, and v0.41.0's reaches the Dockerfile only down a branch the
  current migration list never takes -- so a cross-version upgrade committed
  the workflow `@tag` bump and the `.gitignore` sync, left the Dockerfile
  the Step-3 resync had just rewritten unstaged, and closed by telling the
  user to `git push`. As with the path, no edit to `upgrade.sh` reaches a
  consumer already sitting on v0.41.0 / v0.42.0. **The addition to the
  contract:** work whose result the CALLER has to commit belongs on the new
  tree's side of the boundary, staged where it is performed. Region A's
  Step-3 `init.sh` now stages what the resync wrote. The caller's Step 5
  stays harmless: the migrations are idempotent and `git add` of an
  already-staged path is a no-op.
- **Amended again:** 2026-09-05 by #1036, before the fix shipped. The
  paragraph above scoped the staging to the migration record
  (`migrated_files` in `dist/script/docker/lib/dockerfile_migrate.sh`) and
  argued that a list of filenames was the wrong shape because it decays the
  first time the work touches one more file. **That argument was right about
  the migrations and wrong about the resync.** The Dockerfile is not the
  only thing Step 3 writes: the same run re-points the wrapper symlinks,
  lands the justfile layering and the monitor workflow, and DELETES the
  pre-relocation root wrappers. Staging only the migration record left every
  one of those out, so the commit still described a tree on a different
  layout -- the defect this amendment was written to close, one file over.
  Two of the three things now staged are therefore lists of names, and the
  reason that is not the decay the earlier paragraph rejected is that
  neither is hand-kept against nothing: `_init_installed_paths` is diffed
  against a REAL resync in both directions by
  `test/bats/integration/init_installed_paths_spec.bats`, so a file added to
  the resync and not to the list fails CI; `_init_retired_root_paths`
  enumerates a closed historical set -- names that already stopped existing
  -- and is the single definition the resync deletes from, restores from and
  stages the deletion of, so it cannot come apart from itself. What stays
  forbidden is the shape the earlier paragraph was really aimed at: a sweep.
  `git add -A` over the tree would commit whatever the user happened to be
  editing, and every path staged here is base's own by the repo's naming
  contract -- shipped or generated, replaced on update, never hand-edited
  per instance -- so none of it is the user's work to review.
- **Amended a third time:** 2026-09-05 by #1036, again before the fix
  shipped. The last sentence above was false as written. The naming
  contract makes those paths base's to SHIP; it does not make them base's
  to REWRITE, and `_init_installed_paths` answers "what does a consumer
  carry", not "what did this run write". EIGHT of the paths behind that
  list are written only under a condition and otherwise left exactly as
  they were found -- the 14 hook stubs (whose entire purpose is that a
  user-authored hook survives every later upgrade), the REPO-OWNED
  `script/local/` pair, `config/.gitkeep`, the monitor workflow, a
  `.hadolint.yaml` the user has customised, `.gitignore` and
  `.dockerignore` (the sync APPENDS only the canonical entries a file is
  missing and returns without a write when none is -- "the common case for
  an up-to-date repo" -- and never touches the hand-maintained region above
  the managed block at all), and `.setup.conf`, which `setup.sh` writes
  only on a first-time bootstrap or a stale-`mount_1` rewrite. Staging the
  published list wholesale therefore committed
  the user's own half-finished hook under a message about a base release:
  the sweep the paragraph above forbids, arriving through the published
  list instead of through `git add -A`. **The correction:** the staged set
  is what THIS RUN WROTE. `_init_conditional_paths` names that subset and
  every write of one is recorded as it happens (`_INIT_WROTE`), because the
  condition it tested is gone by the time the staging step runs and
  re-deriving it from the tree is how the user's content gets classified as
  ours a second time. Three entries cannot be recorded by the writer
  itself: `.setup.conf`, whose writer is a separate process that no shell
  variable crosses, and the two ignore files, which three separate syncs
  write and none of which is asked "did anything change" -- for all three
  the file's CONTENT across the pass answers it instead, in `_call_setup`
  and `_sync_existing_gitignore` respectively. A spec pins the two lists to
  each other, and the integration arm now hands the real upgrade a
  customised hook stub -- a path inside the published list, which the
  earlier anti-sweep arms (both on `NOTES.md`, outside it) could not see.

  This paragraph first said SIX and named neither ignore file. The
  enumeration was drawn from the writers that seed a file when it is
  ABSENT, and the ignore sync does not look like one of those -- it runs on
  every resync and rewrites nothing only because it finds nothing missing.
  That is the same predicate wearing different clothes, which is why the
  list is now called conditional rather than seed-only: "seeded once" was
  a promise about `.gitignore` and `.setup.conf` that was not true, and the
  predicate the staging step needs is the weaker one.
- **Amended a fourth time:** 2026-09-05 by #1036, still before the fix
  shipped, on the two halves the correction above left standing. First,
  the same defect one list over: `_init_retired_root_paths` was staged by
  NAME, and the resync deletes one of those names only where it is a
  SYMLINK -- the `[[ -L ]]` guard is what makes the migration idempotent
  and silent on a fork that never carried the name. So the list enumerates
  what a run MAY delete, and a consumer's own hand-written `Makefile` or
  `run.sh` at the root went into the release commit with whatever they had
  uncommitted in it. It is now recorded where the removal happens, like
  every other conditional write; the index lookup stays, because it is what
  keeps a name this repo never tracked out of a pathspec that would fail
  the whole batch. Second, WHOSE index: the staging step asked `rev-parse
  --is-inside-work-tree`, which answers "is REPO_ROOT inside ANY work
  tree". On the input the function's own docstring is written for -- a repo
  bootstrapped by hand, which may not be a git repo at all -- sitting
  anywhere inside another repository's checkout, that resolved to proceed
  and wrote the entire resync into a third-party index, then reported how
  many paths it had staged. `--show-toplevel` compared against REPO_ROOT is
  the other half of the property `_init_drop_foreign_paths` already
  guarantees: that fence keeps a path outside REPO_ROOT out of `git add`,
  this one keeps `git add` inside REPO_ROOT's own repo. Both corrections
  are the same rule the amendment above states and neither followed all the
  way: the staged set is what THIS RUN WROTE, into THIS repo.
- **Amended:** 2026-09-06 by #1077 -- the 2026-08-25 correction was
  applied to ONE of two sibling paths. It says a path an already-released
  caller names must keep a forwarder at the old location for as long as a
  release that names it is supported, and the `dist/` reorganisation moved
  `init.sh` and `upgrade.sh` together. `init.sh` got the forwarder because
  a released `upgrade.sh` EXECS it and the failure was in front of us;
  `.base/upgrade.sh` got none, and it is named by the callers no code
  change can reach at all -- the person at the terminal following the
  README and the usage text their own vendored copy prints, this repo's
  `enforce_wrapper_first_upgrade.sh` hook, and any downstream runbook
  written in that window. The result was worse-shaped than the v0.42.0
  one: the upgrade REMOVED THE COMMAND THAT PERFORMED IT. The first
  `./.base/upgrade.sh vX.Y.Z` succeeded and the second exited 127, one
  release later, against a repo that was otherwise healthy -- so no run of
  the upgrade could report it. **Nothing in the contract changes**; a
  repo-root `upgrade.sh` forwarder now stands beside `init.sh`, on the
  same three-line no-logic shape.

  The half that does change is the regression guard this ADR named in
  2026-08-25. `prev_release_upgrade_spec.bats` drove the real released
  `upgrade.sh` against the current tree throughout, green, because every
  arm in it asked whether ONE upgrade succeeds and answered it about the
  tree the upgrade STARTED from. A frozen path missing from the tree the
  upgrade PRODUCES is outside what any of them can see: exit status,
  `.version`, dangling symlinks and the Dockerfile's COPY sources are all
  satisfied by a tree nobody asks to upgrade again. So the guard is now
  "upgrade twice" -- run the released driver, then re-run THE SAME COMMAND
  STRING on the tree it produced. Re-resolving the entry point instead
  would ask whether the new tree has SOME upgrade script, which the broken
  tree also answers yes to. It names no file, deliberately: a roster of
  paths that must exist goes stale the day a third frozen path appears,
  and "the tree an upgrade produces can be upgraded from" covers that one
  without an edit.

## Context

`upgrade.sh` runs entirely from the downstream repo root and drives the
`.base/` subtree forward to a target tag. Most of its filesystem
references are derived from a single `TEMPLATE_REL` anchor (the basename
of the directory the script lives in, today `.base`), so renaming the
subtree prefix itself stays cheap. But three regions reach *into* the
subtree at hard-coded sub-paths that `TEMPLATE_REL` does not abstract
away. #477 already hit this wall once: `_verify_subtree_intact` asserted
specific files at fixed paths and broke on the v0.39.0
`script/docker/setup.sh` -> `wrapper/setup.sh` reorg; it was fixed with a
structural invariant (subtree dir non-empty + well-formed `.version` +
target-version match) that no longer names interior paths.

The #477 audit surfaced three *sibling* path-coupling regions in the same
file that were deliberately left out of the structural-invariant fix and
recorded as backlog in #492. Each would hit the same wall on the next
reorg that touches its paths:

- **Region A -- direct `init.sh` invocation.** `_main` Step 3 calls
  `"./${TEMPLATE_REL}/init.sh"` for the symlink / `.gitignore` resync,
  and the `--gen-conf` branch delegates to
  `"./${TEMPLATE_REL}/init.sh" --gen-conf`. If `init.sh` is renamed or
  relocated, Step 3 fails with `No such file or directory` *after* the
  subtree pull has already landed, and the pull is **not rolled back**
  (the rollback path only fires from `_verify_subtree_intact` in Step 2).
  The repo is left half-upgraded: subtree pulled, but symlinks /
  `main.yaml` `@tag` / `.gitignore` not resynced.

  > **Amended 2026-06-24 (#654, ADR-00000011 §8).** `init.sh` was
  > relocated out of the subtree root to
  > `.base/dist/script/base/init.sh` (with `upgrade.sh` alongside).
  > Per this ADR's lockstep discipline the move was done in one slice that
  > also updated Step 3's call to
  > `"./${TEMPLATE_REL}/dist/script/base/init.sh"` (both the resync
  > and `--gen-conf` invocations). Critically, `upgrade.sh` no longer
  > derives `TEMPLATE_REL` from its own directory's basename (which is now
  > `base`, the wrong prefix): it **walks up** from its location to the
  > subtree root -- the dir carrying the `.version` + `dist/` markers
  > -- and `basename`s THAT (`.base`), so the `git subtree pull --prefix=`
  > flag and every interior path stay correct regardless of nesting depth.
  > The new self-location walk-up IS the contract that replaces the frozen
  > `.base/init.sh` root path; an integration test asserts the resolved
  > `--prefix` is the subtree basename, not `base`.

- **Region B -- `config/` drift detection.** The pre-pull snapshot
  (`HEAD:${TEMPLATE_REL}/config` and
  `HEAD:${TEMPLATE_REL}/config/docker/setup.conf`) and the post-pull
  `_warn_config_drift` / `_warn_setup_conf_drift` family compare tree /
  blob hashes at those fixed paths. If `config/` or
  `config/docker/setup.conf` moves, `git rev-parse --verify` returns
  nothing, so the entire drift-warning module silently no-ops (or, if
  only one side moves, emits false positives). The user loses the
  "upstream baseline changed -- reconcile your override" signal with no
  error -- the most dangerous failure mode, because it is silent.

- **Region C -- Dockerfile lint-stage auto-patch.** Step 5 (and the
  sibling #399 wrapper-copy patch) `grep` + `sed` the downstream
  `Dockerfile` to inject `COPY .base/script/docker/lib /lint/lib` and to
  rewrite `COPY *.sh /lint/` -> `COPY script/*.sh /lint/`, healing the
  #284 `lib/` split and the #330 wrapper consolidation. These hard-code
  `.base/script/docker/lib/` and the `script/docker/*.sh` umbrella-loader
  location. If `lib/` is relocated or the umbrella loaders move, the
  sed-generated `COPY` points at a wrong source and the downstream build
  stage fails with `COPY source not found`.

#492 chose to defer the *fix* (no path has an active relocation plan) and
to label it `backlog`, with a trigger checklist requiring any future
reorg of these paths to cross-reference the issue. #492's own body lists
three future-direction options -- ADR-frozen contract, a path-manifest
file, or `find`/glob discovery -- and notes that if the ADR route is
taken, the issue can be closed with a link to it. This ADR is that route.

## Decision

Declare the following `.base/` interior paths **protocol-stable**: they
are part of the contract `upgrade.sh` depends on, and **must not be moved
or renamed without updating `upgrade.sh` in the same change** (and
re-checking #492's trigger checklist):

- `.base/init.sh` -- invoked directly by Region A. *(Superseded
  2026-06-24 by #654: now `.base/dist/script/base/init.sh`, located
  via `upgrade.sh`'s walk-up to the subtree root rather than frozen at the
  root; see the Region A amendment above.)*
- `.base/config/` and `.base/config/docker/setup.conf` -- hashed by
  Region B's drift detection. *(Re-pointed 2026-07-15 by #831: the
  setup.conf blob is now `.base/dist/.setup.conf` (template default) with
  the downstream override at the repo-root `<repo>/.setup.conf`; the
  `.base/dist/config/` tree hash still guards the hand-editable shell
  config. #714 first moved these under `dist/`.)*
- `.base/script/docker/lib/` and the `.base/script/docker/*.sh` umbrella
  loaders -- targeted by Region C's Dockerfile auto-patch.

"Protocol-stable" means: these are not free-to-refactor implementation
details. A reorg may still move them, but only as a deliberate,
`upgrade.sh`-aware change -- the same discipline `TEMPLATE_REL` already
gives the subtree prefix, extended by convention to these interior paths.
The break consequences recorded per region above are the contract's
teeth: A leaves a half-upgraded repo with no rollback, B fails silently,
C breaks the next downstream build.

This closes #492: the issue's "if a future decision freezes these paths
as permanent contract (e.g. via an ADR), this issue can be closed and
replaced with a link to that ADR" condition is now met.

## Alternatives

- **Path-manifest file** (`.base/.path-manifest.txt` listing the actual
  paths; `upgrade.sh` reads from it). Same shape as the R2 design floated
  in the #477 grill, but for path discovery rather than integrity. It
  would let paths move by editing one declarative file -- but it adds a
  new artifact that must itself be kept in sync, ships in every subtree
  pull, and introduces a parse/validation surface. Rejected: it trades a
  remembered convention for a new moving part, for paths that have no
  relocation pressure.
- **`find` / glob discovery** (locate `init.sh` / `config/setup.conf` /
  `lib/` dynamically within `.base/`). Removes the path dependency
  entirely, but makes `upgrade.sh` guess intent: a glob that matches two
  candidates, or zero, has to decide what to do at the worst possible
  moment (mid-upgrade, post-pull). It also masks accidental moves instead
  of surfacing them, which is the opposite of what the silent-failure
  Region B needs. Rejected as over-engineering for a non-problem.
- **Do nothing beyond the #492 backlog note.** Leaves the contract
  implicit -- discoverable only by reading `upgrade.sh` or stumbling onto
  the issue. Rejected: the contract is load-bearing across every
  downstream upgrade and deserves a durable, linkable home.

## Consequences

- The convention must be *remembered*. This ADR plus #492's trigger
  checklist are the memory: any reorg touching the frozen paths is
  expected to cross-reference both and update `upgrade.sh` in lockstep.
  This is the accepted cost of choosing a frozen contract over a manifest
  or discovery -- no new code, no new file, no new parse surface, in
  exchange for a discipline a human (or agent) must hold.
- No code changes. `upgrade.sh` keeps its current hard-coded paths; this
  ADR ratifies them as intentional rather than incidental.
- The three break modes are now documented in one place, so a future
  maintainer who *does* need to move one of these paths knows exactly
  what to repair (Region A: add rollback or move the call; Region B:
  update both pre- and post-pull path pairs; Region C: update the
  grep+sed source paths) rather than rediscovering it from a failed
  upgrade.
- Complements the #477 `_verify_subtree_intact` R1+ structural invariant:
  #477 made the *integrity check* path-agnostic; this ADR freezes the
  *remaining* interior paths that could not be made path-agnostic without
  a manifest or discovery. The two together define the full path-coupling
  posture of `upgrade.sh`.
- #492 is closed with a link to this ADR. Future relocation pressure on
  any frozen path reopens the design question (manifest vs discovery) at
  that time, against a concrete need, rather than speculatively now.

