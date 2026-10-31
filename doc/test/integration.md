# Integration Tests

Integration specs under `test/bats/integration/`: **266 tests**.

> Part of the `just test` self-test suite — what runs in the `Self Test`
> CI job. See [TEST.md](TEST.md) for the index across all test levels and
> types.

## Test Files

<!-- generated: catalogue sections -->

### test/bats/integration/apk_mirror_spec.bats (2)

The FORWARDING half of the APK_MIRROR contract -- the repo-root
`compose.yaml` passes the arg to the tooling build only when the caller set
one, so the upstream host keeps being named in exactly one place, the
Dockerfile. Passing it unconditionally would put an empty `--build-arg` in
front of the image's own default on every machine that needs no override,
and a `:-` default here would move the declaration of the upstream host into
a file the Dockerfile cannot see.

Compose's own interpolation is what decides this, not the file's text, so
the assertions drive `docker compose config` rather than grepping. The knob
itself -- the default, the skip at the default, the reach over every apk
stage -- is test/bats/unit/apk_mirror_spec.bats'.

| Test | Description |
|------|-------------|
| `compose.yaml: with APK_MIRROR unset the tooling build receives no mirror arg (#1008)` | Unset has to mean "the Dockerfile's default", not "an empty override the Dockerfile then has to defend itself against". This is the case every machine that can reach dl-cdn is in, so an unconditional forward would put an empty `--build-arg` in front of the image's own default everywhere and be noticed nowhere -- and the refutation is preceded by the bare `build.args` declaration that keeps it from being satisfied by a service that forwards the arg in no state at all. |
| `compose.yaml: the caller's APK_MIRROR reaches the tooling build (#1008)` | The other direction, and what makes the case above non-vacuous: a `build.args` entry deleted outright would also forward nothing when unset. Both halves together are what says the bare `- APK_MIRROR` form is doing its job -- override through, nothing through otherwise. |

### test/bats/integration/ci_preflight_contract_spec.bats (6)

Drives `script/ci/preflight.sh` against the ACTUAL shipped requirement
manifests (`script/ci/preflight/build.manifest` + `release.manifest`) with a
deliberately-incomplete fake caller environment. A complete caller passes; a
caller that forgot `image_name` (build) or `archive_name_prefix` (release)
fails early with the plain-language `main.yaml` fix. The build contract
declares NO permission requirement (#980): the one it used to carry demanded
`packages: write` for the `registry` buildx cache backend, which no job of
the worker declares and no caller could supply, so it failed every caller
that followed its instructions. The backend and the requirement were removed
together, and a caller that grants nothing beyond `contents: read` passes.
`--list` self-describes the remaining contract.

| Test | Description |
|------|-------------|
| `build manifest: a complete caller passes preflight` | - |
| `build manifest: a caller that forgot image_name fails early, naming the fix` | - |
| `build manifest: a caller granting no write scope is complete (#980)` | The caller that grants nothing. Every job of build-worker.yaml declares `contents: read` and pushes nothing, so a caller holding no other scope is a COMPLETE caller -- and the build contract must say so. It did not: it demanded `packages: write` for a cache backend no job could reach, so the one caller shape that is entirely correct failed the gate written to help it (#980). |
| `build manifest --list: self-describes the contract, and demands no permission (#980)` | - |
| `release manifest: a complete caller passes preflight` | - |
| `release manifest: a caller that forgot archive_name_prefix fails early, naming the fix` | - |

### test/bats/integration/compose_host_identity_spec.bats (5)

| Test | Description |
|------|-------------|
| `compose.yaml: an unset HOST_UID fails naming the entry point to use (#895)` | - |
| `compose.yaml: an unset HOST_GID fails the same way (#895)` | - |
| `compose.yaml: every checkout-mounting service takes the supplied ids verbatim (#895)` | - |
| `compose.yaml: an unset BASE_CHECKOUT_PATH fails naming the entry point to use (#995)` | - |
| `compose.yaml: the label it stamps is the path the caller supplied (#995)` | - |

### test/bats/integration/compose_test_tools_image_spec.bats (3)

How the repo-root `compose.yaml` resolves `TEST_TOOLS_IMAGE` -- the one
variable naming both the image the build-only `test-tools` service writes
and the image the `ci` / `coverage` / `ci-system` services run. The
assertions drive `docker compose config` (pure client-side interpolation:
compose CLI, no daemon, no socket) rather than reading the file's text,
because the text is not what decides which image a run pulls.

| Test | Description |
|------|-------------|
| `compose.yaml: with TEST_TOOLS_IMAGE unset the tag the test-tools build writes is the tag the ci run reads (#896)` | #896 build side vs run side |
| `compose.yaml: with TEST_TOOLS_IMAGE unset every consumer service reaches the same outcome as the build (#896)` | #896 coverage / ci-system too |
| `compose.yaml: an unset TEST_TOOLS_IMAGE fails naming the just recipe to run (#896)` | #896 loud, and actionable |

### test/bats/integration/config_gen_mutation_targets_spec.bats (40)

The build context has no Git history, and on main after a merge origin/main
equals HEAD, so "which Go files changed" can only be decided on the host,
from an explicit execution context. Each obvious choice of base is wrong in
some checkout shape: HEAD^1 drops commits on a stale local main, merge-base
gives HEAD (an empty diff, a false "none") on main after a merge, and in a
--depth 1 clone merge-base exits 0 with HEAD. Every row below runs
script/test/config_gen_mutation_targets.sh on a real Git fixture; no row
reads the script's source.

CONFIG_GEN_MUTATION_CONTEXT pr (default when unset) | main-push
CONFIG_GEN_MUTATION_BASE optional override, verified + ancestor [--repo
<dir>] <out-dir> writes manifest, visible.sha256, ignored.sha256; replaces
<out-dir> whole

Every refusal row holds the five points and names the script as the file
that logged it (_assert_cgm_refusal). Every refusal row that names an
existing <out-dir> -- a directory, a file or a symlink -- snapshots it first
(_snapshot: entries, types, modes and sha256 of every file) and checks the
snapshot is unchanged; the two usage rows that name no existing <out-dir>
(missing_out, repo_value) have nothing to snapshot.

| Test | Description |
|------|-------------|
| `pr: on a stale local main the base is the merge-base, not HEAD^1 (base#1464)` | The first red of the slice. On a stale local main HEAD^1 drops b.go and a two-dot diff against origin/main adds origin's other.go as a delete; only the merge-base names exactly the PR's two files. |
| `context: unset defaults to pr (base#1464)` | Local runs and the pre-PR mirror pass no context; unset must mean pr. |
| `pr: on a detached PR merge checkout the base is origin/main's tip (base#1464)` | GitHub checks a PR out as a detached merge of its head into origin/main; the base is origin/main's tip, not the head's parent. |
| `main-push: on main after a --no-ff merge the base is HEAD^1 (base#1464)` | After a merge to main origin/main equals HEAD, so the pr rule would give an empty diff; main-push takes HEAD^1, which lists the merged files. |
| `main-push: on main after a squash commit the base is HEAD^1 (base#1464)` | GitHub merges this repo by squash, so the main-push run that matters most sees a single-parent commit; HEAD^1 there must still list every file the squash carried. |
| `override: a verified ancestor CONFIG_GEN_MUTATION_BASE is the base (base#1464)` | The override is the escape hatch for a checkout shape neither rule fits; once verified it must win over the context rule, or it is inert. |
| `base: a missing origin/main is refused as base_unreachable, rc 1 (base#1464)` | Without origin/main the pr rule has nothing to diff against; falling back to HEAD would give an empty diff and a false "none". |
| `base: a --depth 1 clone is refused by name, in either context (base#1464)` | In a --depth 1 clone merge-base exits 0 and prints HEAD, which would be a false "none"; the shallow clone is refused by name before any rule. |
| `base: main-push on a root commit (no HEAD^1) is refused, rc 1 (base#1464)` | A root commit has no HEAD^1; diffing against nothing would read as "none" instead of naming the missing parent. |
| `override: a CONFIG_GEN_MUTATION_BASE that is not a commit is refused, rc 1 (base#1464)` | A mistyped override must not silently fall back to the context rule; the caller asked for a specific base and gets a refusal naming it. |
| `override: a CONFIG_GEN_MUTATION_BASE that is not an ancestor of HEAD is refused, rc 1 (base#1464)` | A base off HEAD's history would diff in unrelated changes (origin's other.go here) as if the PR had made them. |
| `base: a repository with no commit (unborn HEAD) is refused as ref=HEAD, rc 1 (base#1464)` | A repository with no commit has no HEAD to diff against; it is refused by name before any base rule runs, in either context. |
| `base: an origin/main with no common ancestor is refused as no_merge_base, rc 1 (base#1464)` | origin/main from an unrelated history (a re-created remote, a wrong fetch) has no merge-base with HEAD; merge-base exits 1 and printing an empty base would diff against nothing. |
| `context: a value other than pr or main-push is refused, rc 2 (base#1464)` | A misspelled context in a workflow must fail loudly, not pick a rule; each rule gives a wrong base in the other's checkout shape. |
| `context: an empty CONFIG_GEN_MUTATION_CONTEXT is refused, not defaulted (base#1464)` | Only an unset variable defaults; an empty one is a caller that meant to set something and did not, which ${X:-pr} would hide. |
| `repo: a directory that is not a Git repository is refused, rc 2 (base#1464)` | Every base rule needs Git history; a non-repository is a caller error (rc 2), distinct from an unreachable base (rc 1). |
| `usage: no <out-dir> is refused as missing_out, rc 2 (base#1464)` | Without an <out-dir> there is nowhere to publish; refusing by name keeps a caller from mistaking an empty run for a clean one. |
| `usage: a second positional argument is refused as extra_arg, rc 2 (base#1464)` | An extra argument is a caller that meant something else; it must be refused before anything is created at either path. |
| `usage: --repo without a value is refused as repo_value, rc 2 (base#1464)` | A bare --repo must not consume the <out-dir> as the repository or fall back to the current directory. |
| `usage: an unknown option is refused as unknown_option, rc 2 (base#1464)` | A misspelled option must not be taken as the <out-dir>, which would then be replaced whole. |
| `usage: an <out-dir> that is a file or a symlink is refused as out_not_dir, rc 2 (base#1464)` | Publication replaces <out-dir> whole; through a file or a symlink that would destroy something the script never created, so both are refused. |
| `manifest: a change outside the module gives exactly the header and none: no-go-change (base#1464)` | The positive none case: a PR that touches no Go file must say so explicitly, and untracked files outside the module must not count. |
| `manifest: a none marker beside a Go diff is refused as none_beside_diff, rc 1 (base#1464)` | The none marker is re-checked against the repository independently of the line builder, so a builder that drops lines is refused rather than written as none. The writer is called with an empty line set in a fixture whose module does differ from the base. |
| `manifest: a none marker beside an untracked module file is refused, rc 1 (base#1464)` | The none re-check has two halves: a tracked diff and an untracked module file. Here the module equals the base and only an untracked file differs, so only the untracked half can refuse. |
| `manifest: a rename keeps both paths as R100 under diff.renames=false (base#1464)` | A user's diff.renames=false splits a rename into D and A unless -M is passed; the fixture sets it, so the row does not lean on Git's default. |
| `manifest: a delete is a D line (base#1464)` | A deleted Go file still changes the generator; dropping D lines would turn a delete-only PR into a false "none". |
| `dirty: a staged edit is dirty=yes and an M line (base#1464)` | Local runs test the working tree, not HEAD; a staged edit must reach the manifest and mark the run dirty. |
| `dirty: an unstaged edit is dirty=yes and an M line (base#1464)` | An unstaged edit is the common local case; diffing the index alone would miss it and report the tree clean. |
| `dirty: a staged new file is dirty=yes and an A line (base#1464)` | A staged new file is in neither HEAD nor the base; only a diff against the working tree lists it as an add. |
| `dirty: an untracked file is dirty=yes and an A line after the diff lines (base#1464)` | git diff never shows an untracked file, so it is appended separately, after the diff lines, keeping the line order stable. |
| `hashes: visible.sha256 covers tracked and untracked module files, ignored.sha256 the ignored ones (base#1464)` | The hash files let the container check it sees the host's tree; an ignored file left out of both would hide a difference the build reads. |
| `paths: names with control bytes, quotes, backslashes and non-ASCII are listed and hashed (base#1464)` | The review's finding: under Git's default quoting a non-ASCII name came out of ls-files as an octal-escaped, double-quoted string, which is no file on disk, so the hash files silently left it out while the run succeeded. Paths are enumerated NUL-delimited and every path in all three files is spelled one way: as is, unless it holds a control byte, a quote or a backslash, which are C-quoted the way Git does with core.quotePath=false. The expected lines are written out literally. |
| `paths: the spelling does not depend on core.quotePath (base#1464)` | The spelling is the script's, not the caller's Git configuration: the same tree under core.quotePath=false gives byte-identical files. |
| `paths: an ignored file with a non-ASCII or tab name is hashed into ignored.sha256 (base#1464)` | An ignored file with an odd name is hashed into ignored.sha256 under the same spelling, not dropped. |
| `publish: a second invocation replaces the output directory whole (base#1464)` | A plain mv into an existing directory nests the new output inside the old one, and writing only the script's own files leaves stale ones beside them; the directory is replaced whole. |
| `publish: the mv shim is on the script's path; a success over an existing output is two renames (base#1464)` | Without the sanity row a green failure row could be a shim the script never reached. Over an existing output a successful publication is exactly two renames, aside and install, and gives the same manifest as an unshimmed run. |
| `publish: an install that fails after the aside restores the destination (base#1464)` | The review's blocking point. With the old output moved aside and the install rename failing, set -e alone exits with the destination gone and its bytes only in an anonymous .cgm-old.* directory. The backup must be put back: same bytes, same file list, same mode. |
| `publish: an aside that fails leaves the destination untouched (base#1464)` | If the first rename fails nothing has moved yet; the refusal must name that stage and leave the destination exactly as it was. |
| `publish: an install that fails with no previous output refuses and leaves nothing (base#1464)` | With no previous output there is nothing to restore; a failed install must still refuse by name and leave neither the destination nor any scratch behind. |
| `publish: an install and a restore that both fail keep the backup and name it (base#1464)` | When the restore fails too, the bytes must survive somewhere named: the backup is kept and the event says where. |

### test/bats/integration/deploy_bundle_flow_spec.bats (7)

The field-deploy generator end-to-end across components (ADR-00000023): a
fixture repo (repo-root `setup.toml`, a Dockerfile with a `runtime` stage, a
`config/<component>/deploy.manifest` declaring one tunable path) drives the
real `_setup_deploy` -> `_generate_deploy_bundle` flow with a docker + xz
PATH-shim (no real daemon), and asserts the produced output folder
`deploy/<repo>-<stage>-<version>/` is correct. Distinct from the
isolated-function unit specs: this exercises the manifest -> resolve ->
resolved-compose -> bundle-files wiring as a flow.

| Test | Description |
|------|-------------|
| `deploy flow: produces the version-named output folder with all bundle files (field-deploy)` | folder + files |
| `deploy flow: the resolved compose is self-contained and pins the versioned image (field-deploy)` | self-contained compose |
| `deploy flow: the manifest path is delivered as an editable copy + a mount-wins bind (field-deploy)` | tunable delivery |
| `deploy flow: the thin launcher drives docker load + compose up/down (field-deploy)` | launcher shape |
| `deploy flow: the bundle ships .env + .env.local and the restart policy end to end (#868)` | - |
| `deploy flow: [environment] is baked as ENV into a stage that is not named runtime (#840)` | - |
| `deploy flow: the README names the versioned image + the tunable config workflow (field-deploy)` | README template |

### test/bats/integration/doc_counts_merge_spec.bats (2)

The unit spec drives the resolver's functions over hand-written marker
fixtures. This one reproduces what actually happens: two branches each added
tests, both bumped the same generated total in doc/test/unit.md, and the
merge conflicts on it -- the conflict shape every branch refresh in the base
review batch produced, resolved by hand six times in one of them.

One command has to leave a merged, regenerated, staged, gate-clean tree
behind. The catalogue prose is the half that used to need rescuing, and it
is the half this case now proves needs nothing: both branches authored their
descriptions in the SPEC files, so both collapses regenerate the same rows
from the same merged spec tree and there is nothing left for a collapse to
drop.

What can still be refused is a disagreement OUTSIDE the generated region,
where the document is hand-written and regeneration justifies nothing. The
second case drives that, and asserts nothing is staged.

| Test | Description |
|------|-------------|
| `resolve-doc-counts: resolves a real two-branch counter conflict end to end (#857)` | The whole toil, end to end. The load-bearing assertion is that BOTH branches' descriptions survive: a mechanical collapse keeps one side's document, and under the old design that dropped whichever description the other side had written. Here neither side's document holds a description at all, so there is nothing to drop. |
| `resolve-doc-counts: REFUSES a merge whose sides differ OUTSIDE the generated region, staging nothing (#857)` | The refusal that survives. Inside the fence there is nothing left to disagree about, but the preamble is still hand-written, and adopting one side of a sentence regeneration cannot justify is exactly the trap the hand-typed recipe carried. Nothing is staged, so a half-resolved tree cannot be committed by accident. |

### test/bats/integration/fresh_clone_portability_spec.bats (2)

End-to-end verification for the fresh-clone-on-a-different-machine scenario:
the consumer repo's `setup.conf` has already been committed by another
contributor and carries either a stale absolute `mount_1` path (the Jetson
bug) or the portable `${WS_PATH}` form. Runs the real `build.sh` +
`setup.sh` (no mocks) and asserts the auto-migration / per-machine detection
pipeline lands a valid `.env` + `compose.yaml`. **Level 1** (no Docker
invocation — `build.sh --dry-run`).

| Test | Description |
|------|-------------|
| `fresh clone with stale absolute mount_1: setup.conf is regenerated, no path leak (#174)` | - |
| `fresh clone with portable ${WS_PATH} mount_1: no warning, .env gets local path` | Happy path round-trip |

### test/bats/integration/gitignore_sync_spec.bats (13)

End-to-end coverage that wires `lib/gitignore.sh` through `init.sh`'s
new-repo + existing-repo paths and `upgrade.sh`'s commit step. Standalone
fixture (independent of `upgrade_spec.bats`'s stub-init fixture) because
gitignore sync requires the **real** `init.sh` to run during Step 3 of
`upgrade.sh`. Issue #172.

| Test | Description |
|------|-------------|
| `init.sh new-repo: .gitignore contains all canonical entries (#507: runtime.env retired)` | - |
| `init.sh new-repo: .gitignore has the 'managed by template' marker` | Marker comment present |
| `init.sh new-repo: .dockerignore contains all canonical derived entries (#604)` | - |
| `init.sh new-repo: .dockerignore has the 'managed by template' marker (#604)` | - |
| `init.sh new-repo: log/ lands in BOTH the .gitignore and .dockerignore canonical sets (#606)` | - |
| `init.sh existing-repo: appends missing canonical entries to user .gitignore` | Drift fill-in |
| `init.sh existing-repo: untracks compose.yaml that was committed` | 15-repo drift heal |
| `init.sh existing-repo: setup.conf stays committed across init runs (#201)` | 2-file model: setup.conf is user override |
| `init.sh existing-repo: idempotent — second run produces no .gitignore changes` | Re-run no-op |
| `init.sh existing-repo: appends missing canonical entries to a user .dockerignore, preserving build-context lines (#604)` | - |
| `init.sh existing-repo: idempotent — second run produces no .dockerignore changes (#604)` | - |
| `upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit` | One-shot upgrade |
| `upgrade.sh end-to-end: idempotent on a second run — no extra commits` | Re-upgrade clean |

### test/bats/integration/init_existing_repo_signals_spec.bats (5)

| Test | Description |
|------|-------------|
| `a repo carrying none of the published signals is scaffolded as new (#928)` | The baseline base#928 broke: with no signal present the new-repo path must actually run, and the three artifacts it alone installs are the currency the outage was measured in. |
| `each published signal, on its own, sends init down the existing-repo path (#928)` | The anti-decay half. A published list nothing exercises is a second statement of the branch condition, and a second statement is what goes stale -- so every entry is run through a real init rather than trusted. |
| `a repo carrying a file the list does NOT publish is still scaffolded as new (#928)` | The converse, without which the case above passes on a branch that treats ANY file as a signal: presence must not decide, the list must. |
| `no file a repo can carry, scaffold output or not, can quietly become a signal (#928)` | The case that closes the class rather than one file. base#928 was a file joining the branch condition without joining the list, and the population has to include what no scaffold writes -- `Dockerfile` came from exactly that half. |
| `the new-repo scaffold creates every published signal (#928)` | The other direction of the same proxy. A signal init never installs can only ever be supplied by somebody else, which is precisely how the template's shipped Dockerfile inverted it. |

### test/bats/integration/init_installed_paths_spec.bats (1)

| Test | Description |
|------|-------------|
| `the printed manifest equals what the resync installs (refs #927)` | - |

### test/bats/integration/init_new_repo_spec.bats (63)

End-to-end verification that `init.sh` produces a complete repo skeleton in
an empty directory. **Level 1** (file generation only, no Docker). The
**Level 2** equivalent runs as the `acceptance` job in
`.github/workflows/self-test.yaml` (the host-driven consumer/UX checks; see
[acceptance.md](acceptance.md)), which has access to a Docker daemon on the
host runner. It drives the documented `just` verbs with REAL execution on
native amd64 + arm64: the build / run -d / exec / stop runnability core
(#579/#603) plus (#769) the foreground `run` command variant, `start` (build
+ run), a real `prune`, an explicit `setup apply`, the `base update` check,
and the `base completions` installer. `setup-tui` (interactive) is
intentionally out of the e2e -- it needs a pseudo-TTY and stays covered by
the unit `tui_spec`.

| Test | Description |
|------|-------------|
| `init.sh detects empty dir and creates new repo skeleton` | Smoke |
| `new repo: Dockerfile is copied from template` | Dockerfile gen |
| `new repo: compose.yaml exists and references the repo name` | compose gen |
| `new repo: .env.example is NOT generated (image name via setup.toml rules)` | setup.toml rules drive IMAGE_NAME |
| `new repo: script/entrypoint.sh exists and is executable` | entrypoint gen |
| `new repo: the seeded entrypoint is a clean bringup under base's orchestrator (refs #364)` | the seeded entrypoint carries no base plumbing and no exec, the Dockerfile names the orchestrator, and the orchestrator is vendored -- the [logging] UX guarantee of #364 now held by base's half instead of by a repo-owned copy that a subtree pull could never reach. Also keeps the v0.30.0 regression guards: no ${USER}, no /home/ in the seeded file. |
| `new repo: smoke test skeleton exists for the repo` | smoke skeleton |
| `new repo: smoke tree is per-stage tool-first (shared/devel-test/runtime-test), not flat test/smoke/ (S4 items 5,8)` | - |
| `new repo: shared smoke spec loads test_helper (resolves via Dockerfile COPY at build time) (S4 item 8)` | - |
| `new repo: .github/workflows/main.yaml exists with reusable workflow ref` | CI gen |
| `new repo: .github/workflows/base-version-monitor.yaml exists (#777)` | - |
| `new repo: main.yaml grants contents: write on the release job only (#957)` | "only" asserted over the emitted file's OWN job list as an exact per-job entry set, plus a pinned grep status for the absent workflow-scope block. Inspecting the two known job blocks left the word unbacked: a third seeded job carrying two write grants kept all 62 specs green |
| `new repo: main.yaml leaves the build call at contents: read (#957)` | The build call's entry set is exactly `contents: read`, so an added scope fails as loudly as a widened one; both tests assert the derived job population first |
| `new repo: .gitignore exists` | gitignore |
| `new repo: .dockerignore exists (#604)` | - |
| `new repo: .dockerignore contains compose.yaml (derived artifact) (#604)` | - |
| `new repo: doc/ tree exists with README translations` | i18n docs |
| `new repo: doc/test/TEST.md exists` | TEST.md gen |
| `new repo: TEST.md total matches the actual generated @test count (no stale 1 test) (S4 item 6)` | - |
| `new repo: TEST.md per-file heading is level-3 (### path (N)) so sync-doc-counts can match (S4 item 6)` | - |
| `new repo: doc/changelog/CHANGELOG.md exists` | CHANGELOG gen |
| `new repo: build.sh symlink lives under script/, not root (#330)` | symlink target moved to script/build.sh |
| `new repo: 7 wrapper symlinks under script/, justfile at root (#330, #546)` | symlink set: 7 wrappers + justfile root, no Makefile |
| `new repo: config/ is an empty placeholder (template#254 layered override)` | config placeholder |
| `new repo: init.sh preserves pre-existing config/ directory (no clobber)` | config preservation |
| `new repo: script/local/justfile.local seeded (repo-local command-group registry, #632)` | #632 — repo-owned registry seeded |
| `new repo: init.sh preserves a pre-existing script/local/justfile.local (no clobber, #632)` | #632 — never clobbers repo registrations |
| `new repo: script/local/ seeds a bash companion template alongside justfile.local (S4 item 7)` | - |
| `new repo: init.sh preserves a pre-existing script/local/local.sh (no clobber, S4 item 7)` | - |
| `new repo: init.sh seeds local.sh even when justfile.local already exists (independent guards, S4 item 7)` | - |
| `new repo: script/template/ symlinks wired for the template namespace (#633)` | #633 — justfile.template + new.sh + skel symlinked |
| `new repo: script/base/ symlink wired for the base namespace (#652, #653)` | #652, #653 — justfile.base + completions.sh symlinked; entry mods base |
| `new repo: init.sh drops stale config symlink before creating placeholder` | config-symlink drop |
| `Dockerfile.example references CONFIG_SRC="config" (not .base/dist/config)` | - |
| `Dockerfile.example has layered config COPY chain (template#254): .base/dist/config first, then config` | layered COPY order |
| `Dockerfile.example declares ENV HOME before WORKDIR ${HOME}/work (#334)` | HOME env directive |
| `Dockerfile.example sets up bashrc.d drop-in directory (template#254)` | bashrc.d setup |
| `new repo: Dockerfile contains logging.sh in-image COPY (#368)` | - |
| `new repo: .base/.version exists (no legacy VERSION / .template_version)` | version file |
| `new repo: re-running init.sh on the result is idempotent` | idempotent |
| `new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)` | setup_tui under script/ |
| `new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)` | upgrade cleanup |
| `new repo: init.sh removes stale root *.sh symlinks (#330 migration)` | migrate 7 root symlinks to script/ |
| `new repo: build.sh -h works against the generated symlink` | smoke script/build.sh |
| `new repo: run.sh -h works against the generated symlink` | smoke script/run.sh |
| `new repo: exec.sh -h works against the generated symlink` | smoke script/exec.sh |
| `new repo: stop.sh -h works against the generated symlink` | smoke script/stop.sh |
| `new repo: setup.sh symlink under script/ → ../.base/dist/script/docker/wrapper/setup.sh` | - |
| `new repo: setup.sh -h works against the generated symlink` | smoke script/setup.sh |
| `init.sh --gen-conf copies setup.toml to repo root` | setup.toml gen |
| `init.sh --gen-conf refuses to overwrite existing setup.toml` | overwrite safety |
| `new repo: .gitignore contains compose.yaml (derived artifact)` | gitignore compose.yaml |
| `new repo: .gitignore contains .env (derived artifact)` | gitignore .env |
| `new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)` | setup.sh generated compose.yaml |
| `new repo: compose.yaml omits devices block by default (#466 opt-in)` | - |
| `new repo: setup.toml mount_1 is NOT empty after first init (workspace detected + written)` | workspace writeback non-empty |
| `new repo: init.sh leaves setup.toml at the umask mode, not 0600 (base#1356)` | The whole first-init flow is what leaves setup.toml behind -- the template copy, then the mount_1 bootstrap upsert, which lands its rewrite with `mv` from a 0600 `mktemp` sibling (base#1356). A fresh repo's setup.toml must come out at the mode a new file gets under the caller's umask, read off a probe file created under the same umask, not 0600. umask 022 so the 0600 the defect leaves and the umask mode differ. |
| `new repo: per-repo setup.toml auto-created on first init (workspace writeback)` | #201 — bootstrap writes WS_PATH back |
| `new repo: init warns + exits 0 + still creates symlinks when just is absent (#607)` | Missing runner -> non-fatal WARN, symlinks still laid down |
| `new repo: init is silent about just when the runner is present (#607)` | Runner present -> no warning |
| `init.sh refuses to run when the subtree root carries .git (base template source)` | Self-run guard (ADR-00000011 sec.8): .git at subtree root -> refuse, no scaffold |
| `existing repo: init never rewrites a main.yaml it did not create (#957)` | Delivery boundary: an existing repo's hand-maintained CI survives init byte-for-byte |
| `existing repo: init syncs the monitor workflow but seeds no main.yaml (#957)` | The same boundary stated positively: the monitor converges, main.yaml is new-repo-only (#927 / #928) |

### test/bats/integration/init_protected_paths_spec.bats (2)

| Test | Description |
|------|-------------|
| `every path the resync touches lies under a protected root (refs #1050)` | The rollback surface is derived from what the resync does, not from a list restated in the spec |
| `a rollback after a successful INI-to-TOML conversion restores the INI (refs base#1137)` | The other side of the containment pair (base#1137). That pair stopped a FAILED conversion from retiring the INI; this is a conversion that SUCCEEDS and is then rolled back. The migration writes `setup.toml` and renames `.setup.conf` to `.setup.conf.bak`, and the rollback surface named neither the source nor the name it is renamed to -- so the snapshot recorded `setup.toml` as absent and removed it, while the rename was left standing. The repo came out of a failed run carrying no configuration any shipped reader looks at, which is the outcome the containment exists to prevent, reached from the successful direction. |

### test/bats/integration/init_rollback_spec.bats (8)

| Test | Description |
|------|-------------|
| `just base init: the recipe passes straight through to init.sh (#937)` | - |
| `just base init: a mid-migration failure leaves the consumer byte-identical (#937)` | - |
| `just base init: the failed resync says it restored the files (#937)` | - |
| `a v0.41.0-style upgrade.sh (no trap): the consumer is left byte-identical (#937)` | - |
| `the current upgrade.sh: inner and outer rollback compose, not fight (#937)` | - |
| `a failed resync leaves the index clean, not just the working tree (base#1160)` | base#1160 -- a rolled-back resync left the smoke-tree rename staged |
| `a successful resync still stages the smoke-tree rename (base#1160)` | base#1160 -- dropping the stager must not drop the rename from the consumer's commit, which is strictly worse than the defect |
| `a failed resync leaves what the consumer had already staged alone (base#1160)` | base#1160 -- the rule _init_restore_index already held, pinned so the change above cannot quietly take it away |

### test/bats/integration/just_runner_version_spec.bats (1)

| Test | Description |
|------|-------------|
| `test-tools image: just --version equals the declared pin (#948)` | - |

### test/bats/integration/kcov_merge_union_spec.bats (3)

the in-job parallel coverage mode (base#726) runs the suite as N independent
kcov processes over disjoint slices and merges their reports with `kcov
--merge`. The merged report is then read as the PROJECT's figure -- the
release badge publishes it, and `just release coverage-badge` accepts it
because the run stamps `scope=full`.

Everything about that rests on one property of a tool this repo does not
own: a line covered in ONE slice and not another must be covered in the
merge. Union is the only correct reading. A sum inflates a shared library's
lines with the slice count; an intersection or a last-writer-wins would
report a whole-suite run as a fraction of itself. base#730 closed exactly
that class of defect on the OTHER merge -- the coverage-gate's per-line
union over the CI matrix's shard artifacts -- and that fix says nothing
about this one, because this one is kcov's.

The unit spec for the mode (test/bats/unit/coverage_local_spec.bats) mocks
kcov, which is right for pinning what the runner CALLS and wrong for pinning
what kcov DOES. This spec runs the real binary from the test-tools image
over a subject with two disjoint branches, so a kcov upgrade that changed
the merge is a red test here rather than a quiet drop in the published rate.

Deliberately NOT asserted: hit COUNTS. Cobertura carries a per-line `hits`,
and whether a merge adds them or takes the maximum is kcov's business --
nothing in this repo reads the number, only `hits > 0`. Asserting the
arithmetic would pin an implementation detail and fail on a change that
costs this repo nothing.

| Test | Description |
|------|-------------|
| `kcov: two slices of one subject cover different lines (#726)` | the guard that keeps every other case in this file from being vacuous. If both slices covered the same lines, a merge that dropped one input entirely -- or that intersected rather than unioned -- would still produce the right answer, and the union assertion would prove nothing. So: the two slices must genuinely disagree, in both directions. |
| `kcov --merge: the merged covered set is the UNION of the slices' (#726)` | the property the whole mode rests on. A line covered in ONE slice is covered in the merge -- exactly the union, neither more nor less. Asserted as set EQUALITY rather than as a count or a rate, because a merge that lost one slice's lines and gained an equal number of another's would match on any percentage and be wrong. |
| `kcov --merge: the merged instrumented set is the union, not a sum (#726)` | the denominator half, and the one a SUM would break first. Each slice's kcov runs with the same `--include-path`, so both reports carry the whole instrumented file; adding their `lines-valid` would count every shared line once per slice and drive the rate down as the slice count rose. That is base#730's defect, on the other merge. The merged denominator must be the union -- here, identical to either slice's. |

### test/bats/integration/prev_release_upgrade_spec.bats (16)

| Test | Description |
|------|-------------|
| `the newest released upgrade.sh leaves a tree its own command can upgrade again (#1077)` | An upgrade that deletes the command that performed it passes every other arm here -- one successful run over a tree nobody asks to upgrade again -- and fails at the consumer's terminal on their next release |
| `the previous released upgrade.sh leaves a tree its own command can upgrade again (N-1, #1077)` | The newest release is already on the path the current tree ships, so only the older driver names a path that has to be kept alive by a forwarder; pinning both ends is what stops this narrowing to one tag |
| `the oldest supported upgrade.sh commits what the migrations rewrote (#1036)` | The commit is made by the consumer's OWN released upgrade.sh, so the only proof that the migrated Dockerfile lands in it is to let that script drive; a unit test on the staging helper passes while the real upgrade still leaves the file behind |
| `the newest supported upgrade.sh commits what the migrations rewrote (#1036)` | The oldest driver is the only one whose own Step 5 misses the Dockerfile, so an arm that ran only there would go quiet as the window slides forward and the fix could be deleted with the suite green; the newest driver still leaves the rest of the resync unstaged without it |
| `a released upgrade.sh still migrates a hand-written .env to .env.local (#868)` | - |
| `a released upgrade.sh leaves an operator's existing env overrides in effect (base#1163)` | base#1163's loss was done BY the upgrade path, so it reached operators who had only followed the documented procedure, and the only thing holding it off since is a comment in init.sh saying why the converter is not called -- a comment nothing refutes and a later change can delete. The sibling base#868 arm cannot see it: it reads `.env.local` by name, and the loss recreates that name as a comment-only scaffold, so the file whose emptiness IS the defect satisfies it. This arm resolves the value through the emitted compose's own env_file chain rather than reading a named file, so it stays the same question when the env.local.toml readers move which file carries it (base#1168). The newest driver is the one an operator upgrading today runs, and the mechanism lives in the resync of the tree being upgraded INTO, which every supported driver reaches by the same route -- a second arm on an older tag would re-ask the identical question. |
| `the oldest supported upgrade.sh leaves the consumer running on its own configuration (#1086)` | The oldest driver predates the setup.conf relocation, so its own copy carries no migration for it -- this is the arm that fails when the fix lives anywhere the old driver cannot reach, and the upgrade it describes exits 0 with the repo's configuration gone |
| `the newest supported upgrade.sh leaves the consumer running on its own configuration (#1086)` | The newest driver reaches the relocation through its own pre-pull copy, so it answers the same question by a different route; pinning both ends is what stops the guard being read as "only the old driver has to carry a repo's config through an upgrade" |
| `a re-established subtree leaves the consumer running on its own configuration (#1086)` | The arms above ask through a released driver, so they stop being able to see #1086 the moment the compatibility window no longer reaches back past the relocation (base#1084); this one drives init.sh directly, and it is the only coverage the re-establish path -- which never runs upgrade.sh at all -- has |
| `the newest released upgrade.sh drives the current tree to a working consumer` | - |
| `the previous released upgrade.sh drives the current tree to a working consumer (N-1)` | - |
| `a released upgrade.sh runs the migration the version interval covers, and only that one (base#1097)` | The interval is the whole mechanism, and the oldest supported driver is the population it exists for -- its vendored copy knows nothing about any migration, so the only code that can select one is the init.sh the pull just landed. Measured on the unfixed tree the arm cannot even seed: nothing in the published release declares a version-bound migration |
| `neither a standalone resync nor the next release re-runs a migration the interval already covered (base#1097)` | Running once is half the contract. Base cannot stop the consumer re-running `just base init`, and it cannot stop them taking the next release; both re-enter the same runner, and a mechanism that applied everything it had on either would re-run work already done -- the double-apply the declared-interval shape exists to make impossible |
| `an interval the history can no longer supply can be named by hand and re-run (base#1097)` | Every warning this runner emits leaves a consumer owed work, and until the interval can be named by hand none of them could be acted on: the released driver commits at Step 4, so the merge the interval was read from is gone before the user has seen the message. The arm drives the recovery through `just base init`, which is what the message tells them to run, on a tree where the automatic path has already correctly declined |
| `a released upgrade.sh retires the stale devel-scoped restart default (base#1110)` | The population base#1110's migration exists for is a repo arriving from before the rescope, and the defect was that no such repo could reach it. This is that repo, driven by its own released driver over a real pull, reading the answer out of the file the readers use -- the one arm that was impossible to write while the gate read the tree the pull replaces |
| `a released upgrade.sh leaves a post-rescope restart = no alone (base#1110)` | The fail-safe is the other half, and it is the half the old gate was built to protect: past the rescope a `no` cannot be told from a choice somebody made, so a repo whose interval STARTS at the rescope must keep the value it arrived with. An arm that only proved the rewrite would pass just as well over a migration that rewrote everybody's |

### test/bats/integration/release_archive_contract_spec.bats (11)

Drives `script/ci/release-archive.sh` against the REAL shipped payload
manifest (`script/ci/release/archive.manifest`) over synthesised consumer
trees. base's own checkout cannot stand in for a consumer -- it has no
`.base/` subtree (it is the template source) and its smoke templates live
under `dist/` -- and, more to the point, a real tree cannot express the case
that matters: a repo deliberately MISSING a standard path. That vacuity is
why the same defect shipped twice.

| Test | Description |
|------|-------------|
| `archive manifest: a current-layout consumer (test/bats/smoke/) archives its whole payload (#914)` | Full payload, `test/bats/smoke/` layout: every declared path lands |
| `archive manifest: a previous-layout consumer (test/smoke/) archives without restructuring (#914)` | `test/smoke/` layout archives with no restructuring (the v0.42.0 casualty) |
| `archive manifest: neither smoke layout present still cuts a release (#914)` | No smoke tree at all still cuts a release; the absence is reported |
| `archive manifest: a consumer with no doc/ and no .hadolint.yaml still archives (#914)` | Missing docs + lint config degrade the archive, they do not fail it |
| `archive manifest: a consumer with no script/ wrappers still archives (#914)` | Missing wrapper tree degrades the archive, it does not fail it |
| `archive manifest: a tree with no Dockerfile fails, naming Dockerfile (#914)` | Mandatory gap fails naming `Dockerfile`, never `cp: cannot stat` |
| `archive manifest: a tree with no .base/ subtree fails, naming .base/ (#914)` | Mandatory gap fails naming `.base/`, never `cp: cannot stat` |
| `archive manifest: declares exactly two required entries (Dockerfile and .base/) (#914)` | Pins the mandatory set so widening it is a deliberate, reviewed edit |
| `archive manifest: still declares every path the hardcoded cp list carried (#914)` | No payload path was silently pruned while making the list tolerant |
| `archive manifest: a payload entry deleted behind its own comment is no longer declared (#914)` | The payload guard cannot be satisfied by the prose that explains the entry |
| `archive manifest: names no wrapper that init.sh no longer creates at the repo root (#914)` | The #558 instance: no removed root wrapper is declared as a payload path |

### test/bats/integration/smoke_layout_convergence_spec.bats (5)

The two init.sh paths must converge on the smoke layout. Divergence here is
invisible to per-path unit tests and only surfaces on a real downstream repo
months later, which is exactly how this was found.

| Test | Description |
|------|-------------|
| `created and migrated repos agree on the smoke tree layout (#1044)` | The two init.sh paths converge on the layout |
| `created and migrated repos agree on the Dockerfile smoke sources (#1044)` | The two init.sh paths converge on the COPY sources |
| `the migrated repo keeps its own spec, moved rather than dropped (#1044)` | The repo own spec survives the move |
| `the migrated repo's per-stage placeholders match a created one byte for byte (#1044)` | Placeholders come from one definition, so they cannot drift |
| `migrating twice is the same as migrating once (#1044)` | Idempotent end to end, not only per function |

### test/bats/integration/test_tools_pins_spec.bats (1)

The image really ships the versions its Dockerfile pins -- the behavioural
half of `test/bats/unit/test_tools_pins_spec.bats`. The suite runs INSIDE
the test-tools image, so every tool on `PATH` is the image's own copy and
the probe the roster names can simply be run. Fail-closed, for the reason
its `just` sibling states: an image whose tool disagrees with the
declaration is exactly the drift this exists to report, and a skip would
restore the silence. A probe that cannot run at all is reported too -- it is
not evidence that the version is right.

| Test | Description |
|------|-------------|
| `test-tools image: every pinned tool answers with the declared version (#1012)` | It iterates the roster rather than a list of tools, so a pin declared tomorrow is asserted tomorrow -- and a probe that cannot run at all is reported rather than read as agreement. |

### test/bats/integration/test_tools_toml_bridge_spec.bats (3)

The suite runs INSIDE the test-tools image, so `/usr/local/bin/toml-bridge`
on this filesystem is the copy every downstream repo inherits through the
test-tools-stage pattern. What stood for that seam was a grep for the `COPY
--from=` line in the Dockerfile, and a grep cannot tell a parser from a
file: the final stage installed no interpreter, so the bundled bridge
answered `env: 'python3': No such file or directory` on four published tags
while the grep stayed green and the ADR went on saying the capability was
there.

So these cases RUN it and read what it printed. An exit status alone would
not have separated the two states either: the shebang's failure and a parse
are both "the process ended", and only the parsed output says which one
happened. The last case drives the bridge to a non-zero exit on purpose, so
a probe that could not fail cannot be mistaken for one that passed.

DELIBERATELY FAIL-CLOSED, for the reason its pin sibling states
(test/bats/integration/test_tools_pins_spec.bats): an image that cannot run
the parser it ships is exactly the drift this exists to report, and a skip
would restore the silence.

| Test | Description |
|------|-------------|
| `test-tools image: the bundled toml-bridge parses TOML from stdin to JSON (#1222)` | The JSON contract is what the shim's non-KV mode returns to its callers, and the expectation is a worked example rather than a second parse of the same input -- a bridge that echoed its stdin, or one whose interpreter was missing, answers neither. |
| `test-tools image: the bundled toml-bridge emits the KV lines conf.sh reads (#1222)` | KV is the mode conf.sh actually loads a config through, and it is the one that carries a TYPE decision across the boundary: an unquoted TOML integer has to arrive as the bare digits bash compares, not as a quoted string or a Python repr. |
| `test-tools image: the bundled toml-bridge refuses malformed TOML under its own name (#1222)` | The case that keeps the two above from being satisfied by anything that merely produces bytes. A real parser REFUSES malformed input and says so under its own name; an interpreter that never started fails too, which is why the message is read and not just the status. |

### test/bats/integration/upgrade_spec.bats (51)

End-to-end verification for `upgrade.sh` driving a real subtree update
against a fake template remote (bare repo with `v0.9.5` / `v0.9.7` tags on a
minimal subtree layout) attached to a sandbox downstream repo. **Level 1**
(no Docker). Exercises the happy path, the pre-flight guards, the
destructive-FF rollback path added after the Jetson v0.9.7 incident (stubs
`git-subtree pull` via `GIT_EXEC_PATH` to simulate the bug and asserts the
repo is restored), and Step 5's declarative Dockerfile/entrypoint migration
pass (#567 / #579) — sourcing `lib/dockerfile_migrate.sh` and running
`apply_migrations` over the repo-root Dockerfile + sibling
`script/entrypoint.sh` (the per-migration {detect, transform} units are
unit-tested in `dockerfile_migrate_spec.bats`), plus the pre-pull
`[lifecycle] restart` default retirement observed through a real upgrade
run.

| Test | Description |
|------|-------------|
| `upgrade.sh v0.9.7: bumps .base/.version, pulls new content, updates main.yaml` | - |
| `upgrade.sh v0.9.7: the upgrade commit names the refs it actually rewrote (#1112)` | The commit message used to assert a general rule, and it was false on exactly the repos whose unnamed worker ref it had just left behind (#1112) |
| `upgrade.sh Step 5 announces the migration pass (#567)` | Step 5 runs the declarative migration dispatcher |
| `upgrade.sh heals a legacy wrapper-COPY Dockerfile via the migration list (#567 m1)` | End-to-end wrapper-copy heal + staged into the upgrade commit |
| `upgrade.sh nounset-guards a sibling entrypoint ROS source (#567 m8 / #579)` | End-to-end entrypoint nounset guard around the ROS setup.bash source |
| `upgrade.sh keeps a migrated entrypoint's 100755 mode in git (base#1323)` | a migration that rewrites a committed 100755 entrypoint must not turn it into 100644 in the upgrade's commit (base#1323). |
| `upgrade.sh Step 5 continues cleanly when no Dockerfile at repo root (#567)` | Subtree-only repos (no consumer Dockerfile) skip silently |
| `upgrade.sh migrations are idempotent — already-migrated Dockerfile unchanged (#567)` | A second upgrade is a no-op on an already-migrated Dockerfile |
| `upgrade.sh keeps the pip install when the repo ships real requirements (#956)` | Fanout guard: Step 5 must not delete a working dependency install |
| `upgrade.sh prints each Dockerfile migration notice once per run (base#1372)` | One upgrade reaches the migration dispatcher twice -- through the init.sh its Step 3 re-runs and again at its own Step 5 -- and every notice the dispatcher prints came out on both passes. Each warning, the ENTRYPOINT advisory and the summary line must print once per run |
| `upgrade.sh v0.9.7 is idempotent on a second run` | Re-run is no-op |
| `upgrade.sh --check reports update available from v0.9.5 → v0.9.7` | --check flag |
| `just base update (downstream entry): exit 0 when update available (#175, #546, #652)` | Regression #175: recipe wraps exit 1 (skips w/o just) |
| `just base update (downstream entry): exit 0 when up-to-date (#546)` | Up-to-date path stays green (skips w/o just) |
| `upgrade.sh --check: a fetch failure exits 2 or above, not the 'update available' 1 (base#1370)` | A fatal --check error is not "update available" (base#1370) |
| `just base update (downstream entry): a fetch failure exits non-zero with the check's own code (base#1370)` | Recipe propagates a failed check (skips w/o just, base#1370) |
| `upgrade.sh --check: a refused WRAPPER_TRANSCRIPT exits 2 or above, not the 'update available' 1 (base#1370)` | Every fatal --check path, not only the fetch, exits >= 2 (base#1370) |
| `upgrade.sh --check: a missing sourced helper exits 2 or above, not the 'update available' 1 (base#1370)` | A failure before any upgrade.sh code runs is still not "update available" (base#1370) |
| `just base update (downstream entry): a refused WRAPPER_TRANSCRIPT exits non-zero (base#1370)` | Recipe propagates a check refused outside _error (skips w/o just, base#1370) |
| `upgrade.sh fails fast when git identity is missing` | Pre-flight identity guard |
| `upgrade.sh fails fast when MERGE_HEAD is present` | Pre-flight merge-state guard |
| `upgrade.sh leaves no merge in progress when the subtree pull conflicts (#956)` | A conflicting pull aborts its own merge instead of leaving a mid-merge tree |
| `upgrade.sh --check: an unreachable remote logs upgrade_fetch_failed, not upgrade_rollback (base#1369)` | A log filtered for rollbacks must not see one on every network failure; a fetch failure under --check logs a fetch-failure body |
| `upgrade.sh (no version): an unreachable remote logs upgrade_fetch_failed, not upgrade_rollback (base#1369)` | The bare upgrade resolves the latest tag first; failing that fetch pulled nothing, so it is a fetch failure, not a rollback |
| `upgrade.sh: an unknown argument logs upgrade_unknown_arg, not upgrade_rollback (base#1369)` | A typo on the command line is an argument error; logging it as a rollback reports a repo restore that never happened |
| `upgrade.sh: --lang with no value logs upgrade_arg_missing_value (base#1369)` | `--lang` with no value is an argument error too; it used to die through a bare `${2:?}` expansion that logged no event at all |
| `upgrade.sh: a tree that is not a git repository logs upgrade_not_a_git_repo (base#1369)` | A downstream tree copied without its .git dies on the merge-state preflight's `git rev-parse --git-dir`; under set -e that used to leave only git's own stderr and no event naming what failed |
| `upgrade.sh: a repo with no commits logs upgrade_no_commits (base#1385)` | A downstream tree in a repo with no commits yet (git init, unborn HEAD) passed the merge-state preflight and then died under set -e on `git rev-parse HEAD` with only git's own stderr and no event |
| `upgrade.sh rolls back when git-subtree does a destructive fast-forward` | Destructive-FF rollback |
| `upgrade.sh rolls back the whole upgrade when a post-pull step fails` | - |
| `upgrade.sh: a successful upgrade finalizes its transcript (base#1371)` | - |
| `upgrade.sh: a rolled-back upgrade restores the repo AND finalizes its transcript (base#1371)` | - |
| `upgrade.sh: a rolled-back upgrade keeps the failing step's own exit code (base#1371)` | The rollback reads the exit status the transcript handler hands it rather than its own; with a failing step that exits 1, a rollback that always reported 1 would be indistinguishable, so the step exits 7 and the caller and the transcript must both carry 7 |
| `upgrade.sh: a failed rescue reset says so, exits 1 and still finalizes its transcript (base#1371)` | A rescue reset that cannot run is the one rollback outcome where an `exit` inside the exit-time callback would skip the transcript finalize, and where a "restored" message would tell the user a still-broken tree is safe to build on; init.sh leaves an index.lock behind so the reset fails |
| `upgrade.sh: a post-pull rollback logs upgrade_rollback only once the repo is restored (base#1369)` | A rollback record logged before the rescue reset runs claims a restore that has not happened; the exit rollback logs it only after |
| `upgrade.sh: an integrity-check rollback logs upgrade_rollback only once the repo is restored (base#1369)` | The integrity-check rollback is the second restore path; it too logs upgrade_rollback only after the reset has put the repo back |
| `upgrade.sh: a failed post-pull reset logs upgrade_rollback_failed, never upgrade_rollback (base#1369)` | When the exit rollback's reset fails, the tree is not restored, so the log carries upgrade_rollback_failed and no upgrade_rollback |
| `upgrade.sh: a failed integrity-check reset logs upgrade_rollback_failed, never upgrade_rollback (base#1369)` | The integrity-check rollback's reset can fail the same way; the stub leaves an index.lock after its destructive reset so the rescue reset cannot run |
| `upgrade.sh: a failed post-pull cleanup logs upgrade_rollback_failed, never upgrade_rollback (base#1369)` | The reset can succeed and the sweep of upgrade-created files still fail; a failed removal followed by a successful one must not read as a restored repo, so the log carries upgrade_rollback_failed and no upgrade_rollback while the leftover file is still there |
| `upgrade.sh: a failed integrity-check cleanup logs upgrade_rollback_failed, never upgrade_rollback (base#1369)` | The integrity-check rollback runs the same sweep; a failed removal there must not end on upgrade_rollback either |
| `upgrade.sh: a failed untracked-file enumeration logs upgrade_rollback_failed, never upgrade_rollback (base#1369)` | The sweep cannot remove files it never enumerated; when listing the untracked files fails, the rollback has not restored the tree and must end on upgrade_rollback_failed, never upgrade_rollback |
| `upgrade.sh: a failed pre-upgrade untracked snapshot stops the upgrade before the pull (base#1384)` | The pre-upgrade snapshot is what tells a rollback the user's own untracked files from the ones the upgrade created; a snapshot that failed to enumerate would make a later rollback sweep the user's files, so a failed snapshot must stop the upgrade before anything is pulled |
| `upgrade.sh: a rollback removes upgrade-created files whose names git quotes (base#1381)` | An aborted upgrade's files must all go, including those whose names git quotes; otherwise the rollback reports a restore that left them behind |
| `upgrade.sh: a rollback keeps the user's own untracked files whose names git quotes (base#1381)` | The snapshot and the sweep must agree on a quoted name, or a rollback deletes a file the user made before the upgrade started |
| `upgrade.sh: an aborted conflicting pull logs upgrade_subtree_pull_failed, never upgrade_rollback (base#1369)` | Aborting a conflicted pull's merge puts back a repo nothing was committed to; it is not a rollback, and a successful abort ends on upgrade_subtree_pull_failed with no upgrade_rollback record |
| `upgrade.sh: a failed merge abort logs upgrade_rollback_failed, never upgrade_rollback (base#1369)` | A merge abort that fails leaves the tree mid-merge; the log says upgrade_rollback_failed and claims no rollback |
| `upgrade.sh (#654 relocated): git subtree pull uses --prefix=.base, not --prefix=base` | Walk-up self-location resolves the subtree prefix to `.base` after the deep relocation; real subtree pull lands with no stray `base/` dir |
| `upgrade.sh refuses to run when the subtree root carries .git (base template source, #721)` | - |
| `upgrade.sh names a vendored edit on a path upstream did not touch (#1092)` | A squashed subtree pull reports a hand edit only where upstream touched the same path, so an edit to a path base shipped identically across the interval rides through the upgrade with no conflict and no message; the one real instance in the org sat in a vendored tree across seven releases and an upgrade before a byte-exact census found it, and silence is what invariant 2 exists to forbid |
| `upgrade.sh names a file the consumer added inside the vendored tree (#1092)` | The edited-path case and the extra-file case reach the report by different sides of the tree comparison, and a check built only on the first reads a file the consumer added into the vendored tree as upstream's own; that is the shape the census counted separately as only-in-consumer |
| `upgrade.sh reports no vendored drift when the pull lands byte-exact (#1092)` | The negative control for the two arms above. A report that fires on every upgrade names nothing, and the census that motivated this check reported zero partial upgrades across 2217 files -- so a clean pull has to stay quiet, and this is the arm that fails if the comparison picks up the resync's own work rather than the consumer's |

### test/bats/integration/verify_tag_on_main_spec.bats (6)

Tests for `script/ci/verify-tag-on-main.sh`, the guard the release worker
runs before cutting a Release. The org's tag rulesets (base#1124) admit any
commit that passed CI, including one that went green inside a PR that was
never merged, because a tag ruleset can only ask whether the target commit
passed its checks -- not whether it is on main. This guard asserts the one
thing the ruleset cannot: the commit under release is an ancestor of the
remote's main (base#1143). It is deliberately ONE rule for both of the
worker's entry paths -- a pushed tag and the direct auto-release call whose
commit is main's own tip -- so these drive a real git graph: a historical
main commit and the tip pass, a commit on an unmerged branch is refused, and
every unreadable case (no GITHUB_SHA, an unfetched main ref) fails CLOSED
with a message rather than passing, since failing to know where main is is
not evidence the commit is on it. The refusal writes to stderr only, so a
caller cannot mistake it for a pass.

Level: integration -- the subject's whole job is a `git merge-base
--is-ancestor` query, so the fixtures are real repositories rather than
stubs.

| Test | Description |
|------|-------------|
| `verify-tag-on-main: a commit on main is admitted` | A historical main commit (not the tip) is on main and must pass -- the guard tests reachability, not equality with the tip, so releasing an older main commit is admitted. |
| `verify-tag-on-main: main's own tip is admitted (the auto-release path)` | The direct auto-release path (release-version.sh's `version` input) runs on a push to main, so GITHUB_SHA is main's tip. The single rule admits it with no special case -- this pins that the tip passes. |
| `verify-tag-on-main: a commit that is not on main is refused, naming it` | The whole point. A commit on a branch that was never merged is exactly what the tag ruleset admits (it passed CI) and what this refuses, naming the commit so the failure says which tag to delete. |
| `verify-tag-on-main: an unset GITHUB_SHA is refused` | No commit to check is a caller-contract error, not a pass. The release job always has GITHUB_SHA; its absence means this was wired wrong, and guessing "on main" would defeat the guard. |
| `verify-tag-on-main: an unresolvable main ref is refused, not treated as off-main` | The fail-closed property. If main was never fetched the ref does not resolve, and "not an ancestor of nothing" must NOT read as off-main -- it is refused by name so a missing fetch step fails loudly rather than quietly blocking every release or, worse, passing one it never checked. |
| `verify-tag-on-main: a refusal prints nothing on stdout` | The release step must never mistake a refusal for a pass. A refusal writes to stderr and prints nothing on stdout, so no wiring that keys off this step's stdout can misread it. |

### test/bats/integration/wrapper_compose_dispatch_spec.bats (10)

Behaviour-based assertion (#490) that every wrapper routes its `docker
compose` calls through the `-p`-injecting dispatcher. Reuses the
`fresh_clone_portability_spec.bats` fixture pattern (cp `/source` ->
`.base/`, symlink the wrappers from the repo root, materialize `.env` +
`compose.yaml` via `build.sh --dry-run`), then runs each wrapper with
`--dry-run` and inspects the planned `[dry-run] docker compose -p <project>
<verb>` line. Immune to internal renames (replaces the old name-coupled
`_compose_project` / `_app_cleanup` greps in `template_spec.bats`) and
catches a raw-`docker compose` bypass (a missing `-p`). **Level 1** (no
Docker invocation).

| Test | Description |
|------|-------------|
| `build.sh --dry-run dispatches compose build with -p project flag` | build dispatch |
| `run.sh --dry-run (default devel) dispatches compose up + exec with -p` | run devel up+exec |
| `exec.sh --dry-run dispatches compose exec with -p` | exec dispatch |
| `stop.sh --dry-run dispatches compose down with -p` | stop dispatch |
| `run.sh foreground --dry-run installs cleanup that downs with --remove-orphans` | EXIT-trap cleanup |
| `no wrapper dispatches compose without -p (bypass regression)` | bypass catcher |
| `the -p project name and compose.yaml's name: are one value, not two computations` | - |
| `[project] name in setup.local.toml moves BOTH the -p and the emitted name:` | - |
| `two checkouts of one repo dispatch different projects after a local override` | - |
| `an unchanged repo keeps the project name it resolved before [project] existed` | - |

<!-- /generated -->
