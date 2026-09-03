# The `config/<component>/` layout, and the selector that says which preset a build bakes

> Serves: PRD invariant 8 (development and field are cleanly separated, and
> provisioned by opposite means) -- the half ADR-00000023 left open, namely
> WHICH config a build bakes; also invariant 4 (the committed preset is the
> inert one), invariant 2 (a selector that resolves to nothing is reported,
> not discovered inside `docker build`), and invariant 10 / ADR-00000028
> (one record per fact, which is why audience is not a directory).

- **Date:** 2026-09-03
- **Status:** Accepted
- **Relates to:** issues #826 (the runtime/deploy config convention, ask 1)
  and #827 (the `config/<component>/` directory architecture, all five
  asks); ADR-00000023 (the field-override + field-deploy contract this
  completes -- its sec. 4 forward-references these two issues as what makes
  the rule downstream-explicit); ADR-00000003 (env vs workload parameter
  boundary); ADR-00000001 (`.setup.conf` is the main path, compose-native
  mechanisms the escape hatch -- why the selector is NOT a conf key);
  ADR-00000028 (documentation is derived, not duplicated -- why an audience
  directory is refused); issue #1000, which made `config/*/` the unit both
  halves of invariant 8 provision and is what this builds on.

## Context

ADR-00000023 settled how a field operator retunes a **baked** config file
without a rebuild: a `COPY`-baked default plus an optional mount that wins,
declared per stage in `config/<component>/deploy.manifest`. It assumed an
answer to two questions it never wrote down, and #826 and #827 are exactly
those two:

- **Which config gets baked in the first place.** A repo that ships eight
  camera profiles bakes one of them. `deploy.manifest` names paths *inside
  the image*; it cannot name the profile that became that path, and it runs
  at deploy, long after the build chose.
- **What the inside of `config/<component>/` looks like.** #1000 made that
  directory the unit both halves of invariant 8 provision. It said nothing
  about its contents.

An earlier audit recorded that ADR-00000023 already closes both. Re-checked
against the file: it answers **one** of #826's three asks -- ask 2, the
no-rebuild override -- and **none** of #827's five. Its only mention of
either issue is the forward pointer in sec. 4 and in its Consequences,
which says these issues are what make the deployable-stage rule
downstream-explicit. That is an ADR naming an open question, not answering
it. Nothing under `doc/adr/`, `doc/PRD.md` or `CONTEXT.md` used the words
"preset", "type-first" or "upstream-baseline" before this record.

**What the org actually has**, surveyed 2026-09-03 over the 23 non-archived
repos under `ycpss91255-docker` with `gh api repos/<r>/contents/config` and
the git trees behind it -- because a convention no repo can adopt without a
migration has to say what the migration is, and the last convention written
without that survey (`deploy.manifest`) has 0 of 23 adoption:

- **Six component directories exist, across five repos**, and their shapes
  do not agree. `realsense_ros1/config/realsense/` and
  `realsense_ros2/config/realsense/` group their files into subdirectories
  (`yaml/`, `launch/`, `filters/`, `udev/`, `json/`); the other four --
  `ros1_bridge/config/ros1_bridge/` (five yaml files),
  `jetson_sdk_manager/config/jetson/` (eight), the same repo's
  `config/packages/` (two) and `isaac/config/ros2/` (one) -- are flat.
- **The audience split #827 was filed against is already gone.** Neither
  realsense repo still carries `custom/ official/ internal/ example/`, and
  `realsense_ros2` has moved its diff-only upstream baseline to
  `.github/upstream-baseline/`. realsense is the reference implementation
  now, not the counterexample.
- **Preset selection has already converged on one shape, in three repos.**
  `realsense_ros1` (`camera.yaml`, `filters.yaml`), `realsense_ros2`
  (`camera.yaml`) and `jetson_sdk_manager` (`jetson.yaml`) each commit a
  repo-root symlink -- mode `120000`, whose whole content is a path --
  pointing into `config/<component>/`. The two realsense repos read it
  through a build ARG whose default is the symlink's own name
  (`ARG CAMERA_CONFIG="camera.yaml"`, then `COPY "${CAMERA_CONFIG}"`), and
  both point at an empty `none.yaml`.
- **The one repo that picks a preset WITHOUT a symlink shows what the
  symlink buys.** `ros1_bridge` has `ARG BRIDGE_FILE="bridge.yaml"` and no
  `bridge.yaml` in the tree, so the default names nothing; its Dockerfile
  carries a three-branch `if / elif / else` around the install, twice, once
  per stage, to survive that.
- **Two spellings of "copy me" are live**, and they are not equivalent:
  `.example.` with the real extension last (`rs_camera_remap.example.launch`,
  `sensor_options.example.yaml`) and `.example` appended after it
  (`host.yaml.example`, in `isaac` and `omniverse_web_viewer`). Both of the
  latter also sit directly under `config/`, which is the population #1000
  already WARNs about as provisioned by neither half.

## Decision

### 1. A preset lives in its component directory; a repo-root symlink says which one is baked

Curated presets are ordinary files inside `config/<component>/`. They need
no home of their own: that directory is already bind-mounted at
`/opt/app/config/<component>` in development and `COPY`-baked at the same
path for deploy, so a preset library is provisioned by the channel that
exists.

Which preset **this repo** bakes is declared by a **committed repo-root
symlink into `config/<component>/`**, and the build reads it through a
build `ARG` whose default is that symlink's name. Three properties follow,
and together they are the reason this beats the alternatives below:

- The repo's default is one file whose entire content is the chosen path,
  so changing it is a one-line diff that a reviewer reads without opening
  anything else.
- A single build overrides it with `--build-arg` and touches no tracked
  file -- the same "no committed change" property ADR-00000023 sec. 2 gives
  the deploy side, applied one moment earlier.
- The ARG default names a file that **exists**, so the `COPY` is
  unconditional. That is the whole of what `ros1_bridge`'s duplicated
  three-branch fallback is working around.

The selector is a repo-root file and not a `.setup.conf` key on purpose.
It must be resolvable by `COPY` **inside the build context**, and base
cannot render a conf key into a build arg generically because it does not
know the repo's ARG name -- knowing it would make base the owner of a
downstream's config schema, which ADR-00000023 sec. 5 refuses. It is also
the one form of this choice that is visible from `ls -l`.

base derives the selectors rather than being told: a root entry that is a
symlink AND whose link text names a path under `config/`. That excludes
base's own root symlinks (`justfile`, `.hadolint.yaml`, which point into
`.base/`) with no filename rule and no list to fall off (PRD design
principle P2). Every `setup` run names each selector and the preset it
currently resolves to, and WARNs by name about one that resolves to
nothing.

### 2. The committed target is the inert preset

The preset a fresh clone builds is the one that changes nothing -- an empty
`none.yaml`, upstream's own defaults. Choosing a profile is then an act
someone performed and recorded, never something a clone inherited by
accident. This is invariant 4 applied to the config row, and both realsense
repos already do it.

### 3. Group by kind only once a kind has a second file

Inside `config/<component>/`, files stay flat until a kind has more than
one member; the second `*.launch` is what creates `launch/`. Not
"type-first always".

The measurement decided this. The rule as written describes **6 of 6**
component directories in the org today and costs zero migration; a
mandatory type level would move **4 of the 6**, one of them a directory
holding a single file. #827's own argument against the audience split --
that a level does not earn its keep when a category has one or two files --
is a general argument, and applying it to the type level too is the only
consistent reading of it.

### 4. A copy-me template is a filename, not a directory

`<name>.example.<ext>`, sitting at the top of the component directory where
it is seen. The real extension stays **last**, so tooling that selects by
extension still finds it: `realsense_ros1` lint-`COPY`s
`config/realsense/filters/` into the image and validates the yaml there, and
a `*.yaml.example` is invisible to a `*.yaml` glob. `example/` as a
directory is refused for the reason in sec. 6.

### 5. A file kept only to be diffed against upstream is not config

The discriminator is one question: **does the container read it at run
time?** If yes it is config, whoever wrote it -- vendored upstream data a
node loads stays in `config/<component>/`. If it exists only to be compared
against a pinned upstream tag, it is a test fixture; it belongs with the
tests (`realsense_ros2` uses `.github/upstream-baseline/`), and leaving it
under `config/` gets it bind-mounted and baked into every field image for
nothing, while suggesting to a user that it is a file they may edit.

### 6. Audience is not a directory

No `official/ custom/ internal/ example/` level. Which files a field
operator may retune is already recorded, per deployable stage, in
`config/<component>/deploy.manifest` (ADR-00000023 sec. 5); everything
unlisted is baked-only. A directory that says it too is a second record of
one fact, and the two can only disagree -- which is invariant 10, and the
same argument ADR-00000028 makes about test statistics.

## Alternatives

- **Select the preset with a `.setup.conf` key.** Rejected: the value has
  to reach `COPY` inside the build context, and base would have to know the
  downstream's ARG name to render it there. ADR-00000001 makes `.setup.conf`
  the main path for what base itself resolves; the preset is a downstream's
  own build input, and ADR-00000023 sec. 5 already draws that line ("base
  delivers files; the repo consumes them").
- **A build ARG naming the preset path directly, with no symlink.**
  Rejected on the measurement: it is `ros1_bridge`'s shape, its default
  names a file that is not in the repo, and the cost is a three-branch
  fallback duplicated across two stages plus a repo default that is invisible
  until you read the Dockerfile.
- **Bake every preset and choose one at run time.** Rejected: it moves a
  build-time choice into the runtime image for the sake of choice a field
  operator already has -- ADR-00000023's mount-wins override is exactly that
  channel, and it does not require carrying seven unused profiles into a
  field artifact.
- **Mandatory type-first grouping, as #827 proposed it.** Rejected: it
  migrates 4 of the 6 component directories that exist, including one
  holding a single file, and buys nothing the "second file creates the
  directory" rule does not already buy on the two directories that are
  genuinely mixed.
- **Keep the audience sub-split for repos that want it.** Rejected: an
  optional second record of the tunability fact is still a second record,
  and "optional" means the drift appears only in the repos that opted in.
- **A top-level `preset/` tree, outside `config/`.** Rejected: it would be
  provisioned by neither half of invariant 8's channel, which is precisely
  the shape #1000 taught us to WARN about.

## Consequences

- **base states the choice it used to hide.** Every `setup` run -- both the
  dev-bind half and the deploy-bake half, from one call site -- names each
  selector and the preset it resolves to, and WARNs about one that resolves
  to nothing. That failure used to surface as a `docker build` dying on a
  `COPY` whose message names neither the symlink nor the missing file, after
  the layers above it had rebuilt.
- **A new repo is told the convention.** The `config/.gitkeep` base seeds
  now states both channels that directory feeds and the rules above. It
  reaches **new repos only**: `_populate_config` preserves an existing
  `config/`, deliberately, because that directory is the user's.
- **The migration is small and it is not zero.** Sections 1, 2, 3 and 6 cost
  nothing: no component directory in the org contradicts them today. Section
  4 renames two files (`isaac` and `omniverse_web_viewer`'s
  `host.yaml.example`), both of which also have to move under a component
  directory to be provisioned at all. Section 5 is already done in
  `realsense_ros2` and untested elsewhere. `ros1_bridge` adopting section 1
  is a symlink plus deleting a fallback branch in two stages.
- **Three repos keep app config where neither half reaches it.** `seggpt`,
  `urg_node_humble` and the two `host.yaml.example` repos hold regular files
  directly under `config/`. They are WARNed by name at every run and are the
  fanout's real work; this record does not move them.
- **`config/docker/` survives in 15 of the 23 repos**, holding the
  `setup.conf` that #831 relocated to the repo root. Under the derived
  population it is a component directory like any other, so it is
  bind-mounted and baked -- inert, but it means a stale copy of a
  tool-managed file travels into images. Naming it here; retiring it is its
  own change.
- **The convention is written but not enforced downstream.** base can check
  what base can see -- the selectors in the tree it is run against. Nothing
  gates a downstream's directory shape, and a lint that could would have to
  live in the repos being linted. Adoption is 0 of 23 until a release
  carries this and the fanout runs.
