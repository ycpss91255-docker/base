#!/usr/bin/env bats
#
# Integration tests for upgrade.sh end-to-end.
#
# Fixture: a bare "template" remote seeded with two tags (v0.9.5, v0.9.7) plus a
# "downstream" consumer repo that has template added as a subtree at v0.9.5.
# Tests drive the real upgrade.sh against this fake remote and assert on
# the resulting working tree + git state.
#
# why: End-to-end verification for `upgrade.sh` driving a real subtree
# update against a fake template remote (bare repo with `v0.9.5` / `v0.9.7`
# tags on a minimal subtree layout) attached to a sandbox downstream repo.
# **Level 1** (no Docker). Exercises the happy path, the pre-flight guards,
# the destructive-FF rollback path added after the Jetson v0.9.7 incident
# (stubs `git-subtree pull` via `GIT_EXEC_PATH` to simulate the bug and
# asserts the repo is restored), and Step 5's declarative
# Dockerfile/entrypoint migration pass (#567 / #579) — sourcing
# `lib/dockerfile_migrate.sh` and running `apply_migrations` over the
# repo-root Dockerfile + sibling `script/entrypoint.sh` (the per-migration
# {detect, transform} units are unit-tested in
# `dockerfile_migrate_spec.bats`), plus the pre-pull `[lifecycle] restart`
# default retirement observed through a real upgrade run.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  UPGRADE="/source/dist/script/base/upgrade.sh"

  TMPL_WORK="${BATS_TEST_TMPDIR}/template_work"
  TMPL_BARE="${BATS_TEST_TMPDIR}/template.git"
  DOWN_DIR="${BATS_TEST_TMPDIR}/downstream"

  _seed_template_remote
  _seed_downstream_repo
}

# ── Fixture helpers ─────────────────────────────────────────────────────────

# _seed_template_remote
#   Build a tiny template layout matching what upgrade.sh's post-flight
#   checks look for (markers: .base/.version,
#   .base/dist/script/base/init.sh,
#   .base/dist/script/docker/wrapper/setup.sh), wrap two tagged
#   versions around it, and push to a bare repo we can treat as
#   TEMPLATE_REMOTE. init.sh / upgrade.sh live deep at
#   dist/script/base/ and self-locate the subtree root by walking
#   up to the dir carrying `.version` + `dist/`.
_seed_template_remote() {
  mkdir -p "${TMPL_WORK}/dist/script/docker/wrapper" \
           "${TMPL_WORK}/dist/script/base"
  git -C "${TMPL_WORK}" init -q -b main
  git -C "${TMPL_WORK}" config user.email t@t
  git -C "${TMPL_WORK}" config user.name t

  # v0.9.5: baseline subtree content. Use the real upgrade.sh under test so
  # the downstream repo (which invokes
  # ./.base/dist/script/base/upgrade.sh) runs the same code these
  # tests validate. .version + dist/ at the subtree root are the
  # walk-up markers upgrade.sh self-locates from.
  echo "v0.9.5" > "${TMPL_WORK}/.version"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/dist/script/base/init.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh"
  cp "${UPGRADE}" "${TMPL_WORK}/dist/script/base/upgrade.sh"
  # upgrade.sh sources its sibling upstream.sh at load (the one definition
  # of the upstream slug / clone URL), so the fake remote ships it too.
  cp /source/dist/script/base/upstream.sh "${TMPL_WORK}/dist/script/base/upstream.sh"
  # upgrade.sh sources _lib.sh on load (_log / _error wrap _log_*).
  # _lib.sh itself sources i18n.sh + lib/*.sh sub-libs, so copy
  # all three surfaces into the fake remote.
  mkdir -p "${TMPL_WORK}/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${TMPL_WORK}/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${TMPL_WORK}/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${TMPL_WORK}/dist/script/docker/lib/"
  # transcript.sh repoints log/<verb>/latest.log through runtime/logrotate.sh
  # (sourced when present), so the fake remote ships it for the transcript
  # arms below to observe latest.log at all (base#1371).
  mkdir -p "${TMPL_WORK}/dist/script/docker/runtime"
  cp /source/dist/script/docker/runtime/logrotate.sh \
    "${TMPL_WORK}/dist/script/docker/runtime/logrotate.sh"
  chmod +x "${TMPL_WORK}/dist/script/base/init.sh" \
           "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh" \
           "${TMPL_WORK}/dist/script/base/upgrade.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.5"
  git -C "${TMPL_WORK}" tag v0.9.5

  # v0.9.7: version bump + a new file (lets tests assert the new payload arrived).
  echo "v0.9.7" > "${TMPL_WORK}/.version"
  mkdir -p "${TMPL_WORK}/script/docker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/script/docker/new_script.sh"
  chmod +x "${TMPL_WORK}/script/docker/new_script.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7"
  git -C "${TMPL_WORK}" tag v0.9.7

  git init --bare -q "${TMPL_BARE}"
  git -C "${TMPL_WORK}" push -q "${TMPL_BARE}" v0.9.5 v0.9.7 main
}

# _seed_downstream_repo
#   Simulate a consumer repo at the moment right after `git subtree add
#   --prefix=.base ... v0.9.5 --squash`: a committed README, a
#   main.yaml with @v0.9.5 references ready to be bumped, and .base/ as
#   a proper subtree.
#
#   The main.yaml calls EVERY reusable worker base ships, and the list is
#   derived from `.github/workflows/` rather than written out here. A fixture
#   carrying only the workers Step 4 happened to name cannot tell "the
#   rewrite covered everything" from "the rewrite covered the two it was
#   told about", which is how a consumer sat 21 minors behind on
#   publish-worker. DOWN_WORKERS carries the derived list to the arms below
#   so they assert over the same population.
_seed_downstream_repo() {
  mkdir -p "${DOWN_DIR}/.github/workflows"
  git -C "${DOWN_DIR}" init -q -b main
  git -C "${DOWN_DIR}" config user.email t@t
  git -C "${DOWN_DIR}" config user.name t

  echo "DOWNSTREAM" > "${DOWN_DIR}/README.md"

  # shellcheck disable=SC1091
  source /source/dist/script/base/upstream.sh
  DOWN_WORKERS=()
  local _wf
  for _wf in /source/.github/workflows/*.yaml /source/.github/workflows/*.yml; do
    [[ -f "${_wf}" ]] || continue
    grep -qE '^[[:space:]]*workflow_call:' "${_wf}" || continue
    DOWN_WORKERS+=("$(basename "${_wf}")")
  done
  (( ${#DOWN_WORKERS[@]} > 0 )) \
    || fail "no workflow under .github/workflows/ declares workflow_call, so this fixture would call no worker at all"

  {
    printf 'jobs:\n'
    local _n=0
    for _wf in "${DOWN_WORKERS[@]}"; do
      _n=$(( _n + 1 ))
      printf '  call-%s:\n    uses: %s/.github/workflows/%s@v0.9.5\n' \
        "${_n}" "${BASE_UPSTREAM_SLUG}" "${_wf}"
    done
  } > "${DOWN_DIR}/.github/workflows/main.yaml"

  git -C "${DOWN_DIR}" add -A
  git -C "${DOWN_DIR}" commit -q -m "initial downstream"

  git -C "${DOWN_DIR}" subtree add -q --prefix=.base \
    "file://${TMPL_BARE}" v0.9.5 --squash
}

# ── Happy path ──────────────────────────────────────────────────────────────

@test "upgrade.sh v0.9.7: bumps .base/.version, pulls new content, updates main.yaml" {
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Upgrading: v0.9.5 → v0.9.7"
  assert_output --partial "Done! Upgraded to v0.9.7"

  # Version bumped
  [ "$(cat .base/.version)" = "v0.9.7" ]
  # New file from v0.9.7 arrived under the subtree prefix
  [ -f ".base/script/docker/new_script.sh" ]
  # EVERY shipped worker's @tag reference bumped to v0.9.7 -- the population
  # is the one _seed_downstream_repo derived, so a worker added to base later
  # is asserted over here without this arm being edited.
  local _worker
  local -a _stale=()
  for _worker in "${DOWN_WORKERS[@]}"; do
    grep -Fq "/${_worker}@v0.9.7" .github/workflows/main.yaml \
      || _stale+=("${_worker}")
  done
  (( ${#_stale[@]} == 0 )) \
    || fail "the upgrade left these shipped workers' @ref at v0.9.5: ${_stale[*]}"
  # README.md and other downstream content untouched
  [ "$(cat README.md)" = "DOWNSTREAM" ]
}

# why: The commit message used to assert a general rule, and it was false on
# exactly the repos whose unnamed worker ref it had just left behind (#1112)
@test "upgrade.sh v0.9.7: the upgrade commit names the refs it actually rewrote (#1112)" {
  cd "${DOWN_DIR}"
  (( ${#DOWN_WORKERS[@]} >= 2 )) \
    || skip "base ships one reusable worker; this arm needs two to tell a rewritten ref from an untouched one"

  # One worker is ALREADY at the target, so the run has both kinds of ref in
  # front of it. The old message said "workflow @tag updated to <ver>"
  # whatever happened, so it could not tell the two apart -- which is how it
  # claimed credit for a ref no sed had ever touched.
  local _current="${DOWN_WORKERS[0]}"
  sed -i "s|/${_current}@v0.9.5|/${_current}@v0.9.7|" .github/workflows/main.yaml
  git add .github/workflows/main.yaml
  git commit -q -m "pin ${_current} at the target already"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success

  # The claim is read off the one line that makes it. Membership is tested
  # space-delimited rather than as a substring: `build-worker.yaml` is a
  # substring of `multi-distro-build-worker.yaml`, and a substring test would
  # read the second as a mention of the first.
  local _claim _worker
  _claim="$(git log -1 --format=%B | grep -m1 '^- main\.yaml:')" \
    || fail "the upgrade commit says nothing about main.yaml: $(git log -1 --format=%B)"
  _claim=" ${_claim} "

  for _worker in "${DOWN_WORKERS[@]:1}"; do
    [[ "${_claim}" == *" ${_worker} "* ]] \
      || fail "the upgrade commit does not name ${_worker}, whose @ref it rewrote:${_claim}"
  done
  [[ "${_claim}" != *" ${_current} "* ]] \
    || fail "the upgrade commit claims it rewrote ${_current}, which was already at the target:${_claim}"
}

# ── Step 5: declarative Dockerfile/entrypoint migrations ───────
# upgrade.sh Step 5 sources lib/dockerfile_migrate.sh and runs the
# apply_migrations dispatcher over the repo-root Dockerfile (and its sibling
# script/entrypoint.sh). These drive the real upgrade.sh end-to-end against
# the fake remote, confirming the migrations run, stage their changes, and
# stay idempotent.

# why: Step 5 runs the declarative migration dispatcher
@test "upgrade.sh Step 5 announces the migration pass (#567)" {
  cd "${DOWN_DIR}"
  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Step 5/5: apply Dockerfile/entrypoint migrations (#567 / #579)"
}

# why: End-to-end wrapper-copy heal + staged into the upgrade commit
@test "upgrade.sh heals a legacy wrapper-COPY Dockerfile via the migration list (#567 m1)" {
  cd "${DOWN_DIR}"
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY *.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  git add Dockerfile
  git commit -q -m "add Dockerfile (legacy wrapper COPY)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  # wrapper_copy writes the flat path and flat_to_dist, later in the list,
  # carries it to the shipped tree; the settled result is the dist one.
  grep -Fq "COPY .base/dist/script/docker/wrapper/*.sh /lint/" Dockerfile
  refute grep -Eq '^[[:space:]]*COPY[[:space:]]+\*\.sh[[:space:]]+/lint/' Dockerfile
  # The rewritten Dockerfile is staged into the upgrade's commit.
  git diff --cached --quiet
}

# why: End-to-end entrypoint nounset guard around the ROS setup.bash source
@test "upgrade.sh nounset-guards a sibling entrypoint ROS source (#567 m8 / #579)" {
  cd "${DOWN_DIR}"
  : > Dockerfile  # presence-only; the dispatcher runs against the entrypoint
  mkdir -p script
  cat > script/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
  git add Dockerfile script/entrypoint.sh
  git commit -q -m "add Dockerfile + nounset-unsafe entrypoint"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  grep -Fxq "set +u" script/entrypoint.sh
  grep -Fxq "set -u" script/entrypoint.sh
}

# why: a migration that rewrites a committed 100755 entrypoint must not
# turn it into 100644 in the upgrade's commit (base#1323).
@test "upgrade.sh keeps a migrated entrypoint's 100755 mode in git (base#1323)" {
  cd "${DOWN_DIR}"
  : > Dockerfile  # presence-only; the dispatcher runs against the entrypoint
  mkdir -p script
  cat > script/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
  chmod 0755 script/entrypoint.sh
  git add Dockerfile script/entrypoint.sh
  git commit -q -m "add Dockerfile + executable nounset-unsafe entrypoint"
  local _before
  _before="$(git rev-parse HEAD)"

  # Under a restrictive umask, so the mode cannot come from the umask.
  run bash -c 'umask 077; exec env TEMPLATE_REMOTE="$1" ./.base/dist/script/base/upgrade.sh v0.9.7' _ "file://${TMPL_BARE}"
  assert_success
  grep -Fxq "set +u" script/entrypoint.sh
  # The upgrade recorded no mode change for the entrypoint, in its
  # commit or left in the working tree.
  run git diff --summary "${_before}" -- script/entrypoint.sh
  refute_output --partial "mode change"
  run git ls-files -s script/entrypoint.sh
  assert_output --regexp '^100755 '
}

# why: Subtree-only repos (no consumer Dockerfile) skip silently
@test "upgrade.sh Step 5 continues cleanly when no Dockerfile at repo root (#567)" {
  cd "${DOWN_DIR}"
  # Default _seed_downstream_repo fixture leaves no Dockerfile at root —
  # exercise the dispatcher's no-Dockerfile skip branch.
  [ ! -f Dockerfile ]

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "no Dockerfile"
}

# why: A second upgrade is a no-op on an already-migrated Dockerfile
@test "upgrade.sh migrations are idempotent — already-migrated Dockerfile unchanged (#567)" {
  cd "${DOWN_DIR}"
  # "Already migrated" is the DIST spelling: the flat wrapper path this
  # fixture used to carry is one the shipped-tree move deleted, so a
  # Dockerfile still naming it is not a fixed point -- it is a repo that
  # cannot build, and the dispatcher is right to rewrite it.
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/wrapper/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  git add Dockerfile
  git commit -q -m "add Dockerfile (already migrated)"
  cp Dockerfile "${BATS_TEST_TMPDIR}/Dockerfile.orig"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  diff Dockerfile "${BATS_TEST_TMPDIR}/Dockerfile.orig"
}

# The fanout case the pip-helper migration must not get wrong: a mechanical
# `just upgrade` reaches every consumer repo, and the retired-helper line is
# byte-identical whether the repo's own config/pip/requirements.txt is the
# shipped placeholder or a real dependency list. Deleting it in the second
# case leaves a build that still goes green with the packages missing.
# why: Fanout guard: Step 5 must not delete a working dependency install
@test "upgrade.sh keeps the pip install when the repo ships real requirements (#956)" {
  cd "${DOWN_DIR}"
  mkdir -p config/pip
  echo "numpy==1.26.4" > config/pip/requirements.txt
  cat > Dockerfile <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
EOF
  git add Dockerfile config
  git commit -q -m "add Dockerfile + a populated config/pip/requirements.txt"
  cp Dockerfile "${BATS_TEST_TMPDIR}/Dockerfile.pip-orig"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "kept"
  diff Dockerfile "${BATS_TEST_TMPDIR}/Dockerfile.pip-orig"
}

# _publish_current_tree_as_v0_9_7
#   Re-tag v0.9.7 as a copy of THIS working tree, so the upgrade's Step 3
#   resync runs the real init.sh rather than the fixture's stub. The
#   driver stays the current upgrade.sh the v0.9.5 fixture vendors, so
#   both of the run's migration passes -- the one init.sh makes and the
#   one at Step 5 -- are current code. Copied from /source into the
#   fixture, never run against /source itself (base#1075).
_publish_current_tree_as_v0_9_7() {
  find "${TMPL_WORK}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  tar -C /source \
    --exclude=./.git --exclude=./.prev-release \
    --exclude=./coverage --exclude=./log \
    -cf - . | tar -C "${TMPL_WORK}" -x -o -f -
  echo "v0.9.7" > "${TMPL_WORK}/.version"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7 carrying the current tree"
  git -C "${TMPL_WORK}" tag -f v0.9.7 >/dev/null 2>&1
  git -C "${TMPL_WORK}" push -q -f "${TMPL_BARE}" v0.9.7
}

# _count_lines <needle>
#   How many lines of ${output} contain <needle>, read off the output
#   itself so "printed once" and "printed twice" are both visible.
_count_lines() {
  printf '%s\n' "${output}" | grep -cF -- "$1" || true
}

# why: One upgrade reaches the migration dispatcher twice -- through the
# init.sh its Step 3 re-runs and again at its own Step 5 -- and every
# notice the dispatcher prints came out on both passes. Each warning, the
# ENTRYPOINT advisory and the summary line must print once per run
@test "upgrade.sh prints each Dockerfile migration notice once per run (base#1372)" {
  _publish_current_tree_as_v0_9_7

  cd "${DOWN_DIR}"
  mkdir -p config/pip
  echo "numpy==1.26.4" > config/pip/requirements.txt
  cat > Dockerfile <<'DOCKERFILE'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE
  git add Dockerfile config
  git commit -q -m "add Dockerfile (own ENTRYPOINT + populated requirements)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Done! Upgraded to v0.9.7"

  # All three counted before any is asserted, so a failure shows every one.
  local _counts
  _counts="pip_unchanged=$(_count_lines "Dockerfile unchanged: retired CONFIG_DIR pip helper line kept")"
  _counts+=" entrypoint_advisory=$(_count_lines "Dockerfile still runs the repo's own /entrypoint.sh")"
  _counts+=" summary=$(_count_lines "Dockerfile migrations:")"
  assert_equal "${_counts}" "pip_unchanged=1 entrypoint_advisory=1 summary=1"
}

# why: Re-run is no-op
@test "upgrade.sh v0.9.7 is idempotent on a second run" {
  cd "${DOWN_DIR}"

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7 >/dev/null

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Already at v0.9.7"
  [ "$(cat .base/.version)" = "v0.9.7" ]
}

# why: --check flag
@test "upgrade.sh --check reports update available from v0.9.5 → v0.9.7" {
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh --check
  # _check exits 1 when an update is available (documented contract), and
  # exactly 1: every other failure of --check exits 2 or above (base#1370).
  assert_failure 1
  assert_output --partial "Local:  v0.9.5"
  assert_output --partial "Latest: v0.9.7"
  assert_output --partial "Update available"
}

# Seed the layered consumer entry + docker module so `just docker
# upgrade-check` resolves like a real repo. The docker module pins recipes
# to the repo root via `set working-directory := '../..'` (relative to
# script/docker), so the entry must sit at the repo root and the module at
# script/docker/ -- a bare `cp justfile.docker justfile` would mis-resolve
# the working-directory. The seeded subtree fixture omits these files.
_seed_entry() {
  cp /source/dist/script/justfile justfile
  mkdir -p script/docker script/base
  cp /source/dist/script/docker/justfile.docker script/docker/justfile.docker
  cp /source/dist/script/base/justfile.base script/base/justfile.base
}

# why: Regression #175: recipe wraps exit 1 (skips w/o just)
@test "just base update (downstream entry): exit 0 when update available (#175, #546, #652)" {
  # Regression: the upgrade-check recipe wraps upgrade.sh so the
  # runner does not mistake exit 1 (update available) for a build failure.
  # Optional on purpose: `just` is a capability of the TOOLING IMAGE,
  # not an artifact of this repo, and TEST_TOOLS_IMAGE can be pinned to
  # a published test-tools tag older than the one that first shipped it.
  # Dropping it from the image is NOT what this skip covers -- the
  # pinned fetch of `just` is asserted unconditionally by template_spec,
  # so a removal fails there rather than going quiet here. Staleness is a
  # different question and is NOT skipped: just_runner_version_spec
  # compares the image's version against the declaration, fail-closed.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE); the pinned fetch itself is asserted in template_spec"
  cd "${DOWN_DIR}"
  _seed_entry

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" just base update
  assert_success
  assert_output --partial "Local:  v0.9.5"
  assert_output --partial "Latest: v0.9.7"
  assert_output --partial "Update available"
}

# why: Up-to-date path stays green (skips w/o just)
@test "just base update (downstream entry): exit 0 when up-to-date (#546)" {
  # Optional on purpose: `just` is a capability of the TOOLING IMAGE,
  # not an artifact of this repo, and TEST_TOOLS_IMAGE can be pinned to
  # a published test-tools tag older than the one that first shipped it.
  # Dropping it from the image is NOT what this skip covers -- the
  # pinned fetch of `just` is asserted unconditionally by template_spec,
  # so a removal fails there rather than going quiet here. Staleness is a
  # different question and is NOT skipped: just_runner_version_spec
  # compares the image's version against the declaration, fail-closed.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE); the pinned fetch itself is asserted in template_spec"
  cd "${DOWN_DIR}"
  _seed_entry

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7 >/dev/null

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" just base update
  assert_success
  assert_output --partial "Already up to date."
}

# why: A fatal --check error is not "update available" (base#1370)
@test "upgrade.sh --check: a fetch failure exits 2 or above, not the 'update available' 1 (base#1370)" {
  # --check exits 1 for "update available"; a check that could not run at
  # all must not share that code, or every wrapper that tolerates 1 also
  # swallows the failure (the v0.12 contract: codes >= 2 propagate).
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="${BATS_TEST_TMPDIR}/nonexistent/repo.git" \
    ./.base/dist/script/base/upgrade.sh --check
  assert_output --partial "Could not fetch latest version"
  (( status >= 2 )) \
    || fail "a failed --check exited ${status}; 0 reads as up to date and 1 as update available"
}

# why: Recipe propagates a failed check (skips w/o just, base#1370)
@test "just base update (downstream entry): a fetch failure exits non-zero with the check's own code (base#1370)" {
  # Optional on purpose: `just` is a capability of the TOOLING IMAGE,
  # not an artifact of this repo, and TEST_TOOLS_IMAGE can be pinned to
  # a published test-tools tag older than the one that first shipped it.
  # Dropping it from the image is NOT what this skip covers -- the
  # pinned fetch of `just` is asserted unconditionally by template_spec,
  # so a removal fails there rather than going quiet here. Staleness is a
  # different question and is NOT skipped: just_runner_version_spec
  # compares the image's version against the declaration, fail-closed.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE); the pinned fetch itself is asserted in template_spec"
  cd "${DOWN_DIR}"
  _seed_entry

  local _remote="${BATS_TEST_TMPDIR}/nonexistent/repo.git"
  run env TEMPLATE_REMOTE="${_remote}" ./.base/dist/script/base/upgrade.sh --check
  local _check_status="${status}"

  run env TEMPLATE_REMOTE="${_remote}" just base update
  assert_output --partial "Could not fetch latest version"
  (( status != 0 )) \
    || fail "just base update exited 0 although the version check could not fetch"
  [[ "${status}" == "${_check_status}" ]] \
    || fail "just base update exited ${status}; the failed check exited ${_check_status}"
}

# why: Every fatal --check path, not only the fetch, exits >= 2 (base#1370)
@test "upgrade.sh --check: a refused WRAPPER_TRANSCRIPT exits 2 or above, not the 'update available' 1 (base#1370)" {
  # The transcript setup refuses a value it cannot read and exits on its
  # own, outside upgrade.sh's _error. The exit code a --check caller sees
  # must still not read as "update available".
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" WRAPPER_TRANSCRIPT=invalid \
    ./.base/dist/script/base/upgrade.sh --check
  assert_output --partial "WRAPPER_TRANSCRIPT must be true or false"
  (( status >= 2 )) \
    || fail "a --check refused at transcript setup exited ${status}; 1 reads as update available"
}

# why: A failure before any upgrade.sh code runs is still not "update available" (base#1370)
@test "upgrade.sh --check: a missing sourced helper exits 2 or above, not the 'update available' 1 (base#1370)" {
  # upstream.sh is sourced at load, before _lib.sh and before main. A
  # source that fails there stops the script under set -e; that exit is
  # not one of _check's results either.
  cd "${DOWN_DIR}"
  rm -f .base/dist/script/base/upstream.sh

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
    ./.base/dist/script/base/upgrade.sh --check
  assert_output --partial "upstream.sh"
  (( status >= 2 )) \
    || fail "a --check whose helper is missing exited ${status}; 1 reads as update available"
}

# why: Recipe propagates a check refused outside _error (skips w/o just, base#1370)
@test "just base update (downstream entry): a refused WRAPPER_TRANSCRIPT exits non-zero (base#1370)" {
  # Optional on purpose: `just` is a capability of the TOOLING IMAGE,
  # not an artifact of this repo, and TEST_TOOLS_IMAGE can be pinned to
  # a published test-tools tag older than the one that first shipped it.
  # Dropping it from the image is NOT what this skip covers -- the
  # pinned fetch of `just` is asserted unconditionally by template_spec,
  # so a removal fails there rather than going quiet here. Staleness is a
  # different question and is NOT skipped: just_runner_version_spec
  # compares the image's version against the declaration, fail-closed.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE); the pinned fetch itself is asserted in template_spec"
  cd "${DOWN_DIR}"
  _seed_entry

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" WRAPPER_TRANSCRIPT=invalid just base update
  assert_output --partial "WRAPPER_TRANSCRIPT must be true or false"
  (( status != 0 )) \
    || fail "just base update exited 0 although the version check was refused"
}

# ── Legacy setup.conf auto-migration: NOT HERE any more ─────────────
#
# The relocation of a pre-relocation `config/docker/setup.conf` override
# used to be four tests here, driving upgrade.sh's own pre-pull copy of
# the migration. That copy is gone: it could only ever run for a consumer
# ALREADY on a release that carries it, which is never a consumer still
# carrying the old path (base#1086). The migration now runs from the Step
# 3 resync, and this fixture's template ships a stub `init.sh` that exits
# 0, so an arm here would assert against a resync that does not happen.
#
# Its coverage moved to where the code is:
#   - test/bats/unit/setup_conf_migrate_spec.bats, for every branch of the
#     relocation including the BOTH-files merge these tests only ever saw
#     warn;
#   - prev_release_upgrade_spec.bats's "leaves the consumer running on its
#     own configuration" arms, which drive a REAL released upgrade.sh over
#     a REAL init.sh and assert the emitted config, rather than asserting
#     that a file moved.
#
# One property genuinely ended with the pre-pull copy: the relocation no
# longer makes a scoped commit of its own, so it can no longer promise the
# user's unrelated STAGED work stays out of it. The resync stages and the
# caller commits (ADR-00000006), and that caller's closing commit has
# always been unscoped.

# ── Restart-default migration: NOT HERE any more either ─────────────
#
# Two tests here drove upgrade.sh's pre-pull rewrite of a stale
# `[lifecycle] restart = no`. That copy is gone for the same reason the
# four above it are, one step worse: it gated on the VENDORED template
# under `.base/` still reading `restart = no` -- the tree the pull is about
# to replace -- while the function and the new template default shipped in
# the same release. Every published tag carrying the function carries a
# template saying `unless-stopped`, so the gate closed on all of them and
# the migration returned 0 having done nothing (base#1110).
#
# Both tests passed anyway, and how they passed is the point:
#
#   - the firing one seeded `.base/dist/setup.toml` with `restart = "no"`
#     by hand, which is the one pairing no release produces. It asserted
#     against a tree that cannot exist.
#   - the fail-safe one ("leaves a deliberately configured restart policy
#     alone") asserted that a value was NOT rewritten, which is also what a
#     migration that never runs produces. It was green through the total
#     inversion -- base#1115 / base#1117 / base#1175's shape.
#
# Its coverage moved to where the code is:
#   - test/bats/unit/version_migrate_spec.bats, for the rewrite and for the
#     shipped declared set that selects it;
#   - prev_release_upgrade_spec.bats's "retires the stale devel-scoped
#     restart default" / "leaves a post-rescope restart = no alone" arms,
#     which drive a REAL released upgrade.sh over a REAL init.sh and read
#     the answer out of the file the readers use;
#   - test/bats/unit/upgrade_migration_reachability_spec.bats, which
#     refuses the placement rather than the instance.
#
# As with base#1086, an arm here could not be kept even if it were worth
# keeping: this fixture's template ships a stub `init.sh` that exits 0, so
# the Step 3 resync the migration now runs from does not happen.

# ── Pre-flight guards ───────────────────────────────────────────────────────

# why: Pre-flight identity guard
@test "upgrade.sh fails fast when git identity is missing" {
  cd "${DOWN_DIR}"

  # Strip both repo-local and inherited identity so git config resolves empty.
  git config --unset user.email
  git config --unset user.name

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      HOME="${BATS_TEST_TMPDIR}" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_SYSTEM=/dev/null \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "git identity not configured"
  # Pre-flight aborted before subtree pull ran.
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# why: Pre-flight merge-state guard
@test "upgrade.sh fails fast when MERGE_HEAD is present" {
  cd "${DOWN_DIR}"
  touch .git/MERGE_HEAD

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "MERGE_HEAD present"
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# _seed_conflicting_v098
#   Publish a v0.9.8 that changes .base/dist/script/docker/wrapper/setup.sh
#   and commit a different edit to the same file downstream, so
#   `git subtree pull ... v0.9.8` stops on a conflicted merge. Run from
#   DOWN_DIR.
_seed_conflicting_v098() {
  printf '#!/usr/bin/env bash\nexit 0\n# upstream edit\n' \
    > "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh"
  echo "v0.9.8" > "${TMPL_WORK}/.version"
  git -C "${TMPL_WORK}" commit -qam "v0.9.8"
  git -C "${TMPL_WORK}" tag v0.9.8
  git -C "${TMPL_WORK}" push -q "${TMPL_BARE}" v0.9.8

  printf '#!/usr/bin/env bash\nexit 0\n# downstream edit\n' \
    > .base/dist/script/docker/wrapper/setup.sh
  git commit -qam "local edit inside .base"
}

# why: A conflicting pull aborts its own merge instead of leaving a
# mid-merge tree
@test "upgrade.sh leaves no merge in progress when the subtree pull conflicts (#956)" {
  cd "${DOWN_DIR}"

  # The EXIT rollback trap is armed only AFTER the pull has committed, and
  # it genuinely cannot be armed before -- so a pull that conflicts aborts
  # under `set -e` with no rollback at all, leaving MERGE_HEAD, a staged
  # .base/.version and conflict markers inside the vendored subtree. The
  # user then meets it as the NEXT run's clean-merge-state refusal, on a
  # tree they never chose to leave mid-merge.
  #
  # Fixture: a template version that CHANGES a file the downstream also
  # changed, which is what git-subtree's merge cannot resolve.
  _seed_conflicting_v098
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.8
  assert_failure
  assert_output --partial "conflicted merge"

  # Nothing mid-flight: no merge in progress, HEAD where it was, working
  # tree clean, and the vendored file free of conflict markers.
  assert [ ! -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ -z "$(git status --porcelain)" ]
  refute grep -q '^<<<<<<<' .base/dist/script/docker/wrapper/setup.sh
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# ── Fatal-error event bodies ────────────────────────────────────────────────

# _assert_fatal_body <output> <body>
#   The run's ERROR record (LOG_FORMAT=json) carries <body>, and no record
#   claims upgrade_rollback: these paths never pulled, so nothing was
#   rolled back (base#1369).
_assert_fatal_body() {
  local _line
  _line="$(printf '%s\n' "$1" | grep -F '"severity_text":"ERROR"' | head -n 1)"
  [ -n "${_line}" ] || { echo "no ERROR record in: $1" >&2; return 1; }
  [[ "${_line}" == *"\"body\":\"$2\""* ]] || { echo "body: ${_line}" >&2; return 1; }
  [[ "$1" != *'"body":"upgrade_rollback"'* ]] || { echo "rollback logged: $1" >&2; return 1; }
}

# why: A log filtered for rollbacks must not see one on every network
# failure; a fetch failure under --check logs a fetch-failure body
@test "upgrade.sh --check: an unreachable remote logs upgrade_fetch_failed, not upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"

  run env LOG_FORMAT=json TEMPLATE_REMOTE=/nonexistent/repo.git \
      ./.base/dist/script/base/upgrade.sh --check
  assert_failure
  _assert_fatal_body "${output}" upgrade_fetch_failed
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# why: The bare upgrade resolves the latest tag first; failing that fetch
# pulled nothing, so it is a fetch failure, not a rollback
@test "upgrade.sh (no version): an unreachable remote logs upgrade_fetch_failed, not upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"

  run env LOG_FORMAT=json TEMPLATE_REMOTE=/nonexistent/repo.git \
      ./.base/dist/script/base/upgrade.sh
  assert_failure
  _assert_fatal_body "${output}" upgrade_fetch_failed
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# why: A typo on the command line is an argument error; logging it as a
# rollback reports a repo restore that never happened
@test "upgrade.sh: an unknown argument logs upgrade_unknown_arg, not upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh --bogus
  assert_failure
  _assert_fatal_body "${output}" upgrade_unknown_arg
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# why: `--lang` with no value is an argument error too; it used to die
# through a bare `${2:?}` expansion that logged no event at all
@test "upgrade.sh: --lang with no value logs upgrade_arg_missing_value (base#1369)" {
  cd "${DOWN_DIR}"

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh --lang
  assert_failure 1
  _assert_fatal_body "${output}" upgrade_arg_missing_value
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# why: A downstream tree copied without its .git dies on the merge-state
# preflight's `git rev-parse --git-dir`; under set -e that used to leave
# only git's own stderr and no event naming what failed
@test "upgrade.sh: a tree that is not a git repository logs upgrade_not_a_git_repo (base#1369)" {
  local _copy="${BATS_TEST_TMPDIR}/no_git_copy"
  cp -a "${DOWN_DIR}/." "${_copy}"
  rm -rf "${_copy}/.git"
  local _gitconfig="${BATS_TEST_TMPDIR}/identity.gitconfig"
  printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "${_gitconfig}"
  cd "${_copy}"

  run env LOG_FORMAT=json GIT_CONFIG_GLOBAL="${_gitconfig}" \
      GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_fatal_body "${output}" upgrade_not_a_git_repo
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# ── Rollback on destructive subtree pull ────────────────────────────────────

# _install_destructive_ff_stub <stub_dir> [after_reset_cmd]
#   Write a git-subtree stub into <stub_dir> that simulates the Jetson
#   v0.9.7 failure mode: fetches the tag, then hard-resets HEAD to
#   FETCH_HEAD (which has template content at REPO ROOT, not under .base).
#   The resulting working tree loses .base/.version and template-prefixed
#   files.
#
#   `git subtree` resolves via GIT_EXEC_PATH (default /usr/lib/git-core),
#   NOT PATH, so a plain PATH-prepended stub is ignored. Callers point
#   GIT_EXEC_PATH at <stub_dir>; the stub forwards non-`pull` subcommands
#   back to the distro location for any incidental use.
#
#   <after_reset_cmd>, when given, runs in the stub after its reset, so a
#   caller can leave the repo in a state the rescue reset then trips on.
_install_destructive_ff_stub() {
  local _stub_dir="$1"
  local _after="${2:-}"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git-subtree" <<'STUB'
#!/usr/bin/env bash
# Forward everything except `pull` to the real git-subtree. Relies on
# /usr/lib/git-core/git-subtree being present; if the distro places it
# elsewhere, the test will need to be adjusted.
if [[ "$1" != "pull" ]]; then
  exec /usr/lib/git-core/git-subtree "$@"
fi
shift
_remote=""
_ref=""
while (( $# )); do
  case "$1" in
    --prefix=*) shift ;;
    --squash) shift ;;
    -m) shift 2 ;;
    file://*|https://*|git@*) _remote="$1"; shift ;;
    v*) _ref="$1"; shift ;;
    *) shift ;;
  esac
done
git fetch "${_remote}" "${_ref}" >/dev/null 2>&1
git reset --hard FETCH_HEAD >/dev/null 2>&1
STUB
  printf '%s\n' "${_after}" >> "${_stub_dir}/git-subtree"
  chmod +x "${_stub_dir}/git-subtree"
}

# why: Destructive-FF rollback
@test "upgrade.sh rolls back when git-subtree does a destructive fast-forward" {
  cd "${DOWN_DIR}"

  # Stub git-subtree's `pull` into the Jetson v0.9.7 destructive
  # fast-forward (see _install_destructive_ff_stub).
  local _stub_dir="${BATS_TEST_TMPDIR}/stub_bin"
  _install_destructive_ff_stub "${_stub_dir}"

  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  # Transcript capture on (the runner exports WRAPPER_TRANSCRIPT=false):
  # this rollback runs straight from the integrity check rather than from
  # the exit rollback, and must leave the transcript finalized all the
  # same (base#1371).
  run env -u FILE_PATH WRAPPER_TRANSCRIPT=true \
      GIT_EXEC_PATH="${_stub_dir}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7

  assert_failure 1
  assert_output --partial "integrity check failed"
  # R1+ detects destructive FF via subtree dir missing, ahead of the
  # later .version / version-mismatch checks. The legacy assertion against
  # ".base/.version" missing was specific to the pre-R1+ marker list.
  assert_output --partial "subtree dir missing"
  assert_output --partial "Rolling back"
  assert_output --partial "upgrade aborted"

  # Post-condition: repo restored. HEAD back to pre-pull, subtree markers
  # present, version still v0.9.5 — the user's working copy is usable.
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ -f ".base/.version" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]
  [ -f ".base/dist/script/docker/wrapper/setup.sh" ]
  [ -f "README.md" ]

  # ...and the transcript of the aborted run is finalized, not left raw.
  _assert_upgrade_transcript_finalized 1
}

# ── A failed step leaves the repo unchanged, not half-upgraded ──────────────
#
# Rollback used to fire only from the post-pull integrity check, so a
# failure in any LATER step left the pull committed: .version claiming the
# new release, `git status` clean, and the resync that makes the repo usable
# never run. That is a repo that says it upgraded and did not, with no
# signal for anyone who is not reading the terminal. Every post-pull step
# now rolls back the same way the integrity check does.
@test "upgrade.sh rolls back the whole upgrade when a post-pull step fails" {
  # A v0.9.7 whose init.sh writes something and then fails. The write is
  # the interesting half: `git reset --hard` alone does not remove a file
  # that was never tracked, so without an explicit sweep the "restored"
  # tree would still be carrying the aborted upgrade's leftovers.
  cat > "${TMPL_WORK}/dist/script/base/init.sh" <<'INIT'
#!/usr/bin/env bash
touch "$(dirname "${BASH_SOURCE[0]:-$0}")/../../../../half_written_wrapper.sh"
exit 1
INIT
  chmod +x "${TMPL_WORK}/dist/script/base/init.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7 whose init.sh fails"
  git -C "${TMPL_WORK}" tag -f v0.9.7 >/dev/null 2>&1
  git -C "${TMPL_WORK}" push -q -f "${TMPL_BARE}" v0.9.7

  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "Rolling back"
  assert_output --partial "upgrade aborted"

  # Unchanged, with an error -- the whole point.
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]
  [ ! -e "half_written_wrapper.sh" ]
  run git status --porcelain
  assert_output ""
}

# ── Both outcomes finalize the upgrade transcript (base#1371) ──────────────
#
# upgrade.sh records its run under log/upgrade/ through transcript.sh, whose
# single EXIT handler appends the closing line, strips the raw capture into
# <ts>.log and repoints latest.log. A run that leaves only <ts>.log.raw, no
# closing line, or latest.log naming an older run has lost the record of
# exactly the run someone is going to look up.
#
# The self-test runner exports WRAPPER_TRANSCRIPT=false for every spec, so
# these arms switch it back on for the one upgrade run they observe; the log/
# tree lands in the throwaway DOWN_DIR fixture, never in /source.

# _assert_upgrade_transcript_finalized <expected_exit_code>
#   The newest log/upgrade/*.log ends with `transcript_complete
#   exit_code=<code> duration=..`, no raw capture is left behind, and
#   latest.log points at that file.
_assert_upgrade_transcript_finalized() {
  local _code="$1"
  local _dir="${DOWN_DIR}/log/upgrade"
  assert [ -d "${_dir}" ]
  run find "${_dir}" -name '*.raw'
  assert_output ""
  local _f
  _f="$(find "${_dir}" -maxdepth 1 -type f -name '*.log' | sort | tail -n1)"
  assert [ -n "${_f}" ]
  run tail -n1 "${_f}"
  assert_output --regexp "transcript_complete exit_code=${_code} duration=[0-9]+s"
  assert [ -L "${_dir}/latest.log" ]
  assert_equal "$(readlink "${_dir}/latest.log")" "$(basename "${_f}")"
}

@test "upgrade.sh: a successful upgrade finalizes its transcript (base#1371)" {
  cd "${DOWN_DIR}"

  run env -u FILE_PATH WRAPPER_TRANSCRIPT=true \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Done! Upgraded to v0.9.7"

  _assert_upgrade_transcript_finalized 0
}

@test "upgrade.sh: a rolled-back upgrade restores the repo AND finalizes its transcript (base#1371)" {
  # Same failing v0.9.7 as the post-pull rollback arm above: init.sh fails
  # after the subtree pull has committed, so the rollback fires.
  cat > "${TMPL_WORK}/dist/script/base/init.sh" <<'INIT'
#!/usr/bin/env bash
exit 1
INIT
  chmod +x "${TMPL_WORK}/dist/script/base/init.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7 whose init.sh fails"
  git -C "${TMPL_WORK}" tag -f v0.9.7 >/dev/null 2>&1
  git -C "${TMPL_WORK}" push -q -f "${TMPL_BARE}" v0.9.7

  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env -u FILE_PATH WRAPPER_TRANSCRIPT=true \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "Rolling back"
  assert_output --partial "upgrade aborted"
  local _rc="${status}"

  # Rollback still restores the repo...
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]

  # ...and the transcript records the failing exit code the caller saw.
  _assert_upgrade_transcript_finalized "${_rc}"
}

# _publish_failing_init <body>
#   Re-tag v0.9.7 in the template with an init.sh whose body is <body>, so
#   the upgrade fails at Step 3, after the subtree pull has committed.
_publish_failing_init() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" \
    > "${TMPL_WORK}/dist/script/base/init.sh"
  chmod +x "${TMPL_WORK}/dist/script/base/init.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7 whose init.sh fails"
  git -C "${TMPL_WORK}" tag -f v0.9.7 >/dev/null 2>&1
  git -C "${TMPL_WORK}" push -q -f "${TMPL_BARE}" v0.9.7
}

# why: The rollback reads the exit status the transcript handler hands it
# rather than its own; with a failing step that exits 1, a rollback that
# always reported 1 would be indistinguishable, so the step exits 7 and the
# caller and the transcript must both carry 7
@test "upgrade.sh: a rolled-back upgrade keeps the failing step's own exit code (base#1371)" {
  _publish_failing_init 'exit 7'

  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env -u FILE_PATH WRAPPER_TRANSCRIPT=true \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 7
  assert_output --partial "(exit 7)"
  assert_output --partial "upgrade aborted; repo restored to pre-upgrade state"

  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]
  _assert_upgrade_transcript_finalized 7
}

# why: A rescue reset that cannot run is the one rollback outcome where an
# `exit` inside the exit-time callback would skip the transcript finalize,
# and where a "restored" message would tell the user a still-broken tree is
# safe to build on; init.sh leaves an index.lock behind so the reset fails
@test "upgrade.sh: a failed rescue reset says so, exits 1 and still finalizes its transcript (base#1371)" {
  _publish_failing_init 'touch "$(git rev-parse --git-dir)/index.lock"; exit 7'

  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env -u FILE_PATH WRAPPER_TRANSCRIPT=true \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  assert_output --partial "rollback FAILED"
  refute_output --partial "repo restored to pre-upgrade state"

  # The tree really is not restored -- the message above is the truth.
  [ "$(git rev-parse HEAD)" != "${_pre_head}" ]
  rm -f "$(git rev-parse --git-dir)/index.lock"

  _assert_upgrade_transcript_finalized 1
}

# ── A rollback event reports a restore that happened (base#1369) ────────────
#
# upgrade_rollback is the record a log filter reads as "the repo was put
# back". So it is logged only once the restore has succeeded; a restore
# that fails logs upgrade_rollback_failed and no upgrade_rollback at all.
# Each arm runs with LOG_FORMAT=json and reads the records' bodies.

# _assert_rollback_only_after_restore <output>
#   At least one upgrade_rollback record, and every one of them is the
#   "repo restored to pre-upgrade state" report: none was logged on the
#   way into a restore that had not happened yet.
_assert_rollback_only_after_restore() {
  local _recs
  _recs="$(printf '%s\n' "$1" | grep -F '"body":"upgrade_rollback"' || true)"
  [ -n "${_recs}" ] || { echo "no upgrade_rollback record in: $1" >&2; return 1; }
  if printf '%s\n' "${_recs}" | grep -vF 'repo restored to pre-upgrade state' | grep -q .; then
    echo "upgrade_rollback logged before the restore: ${_recs}" >&2
    return 1
  fi
}

# _assert_rollback_failed_not_rollback <output>
#   An upgrade_rollback_failed record and no upgrade_rollback record.
_assert_rollback_failed_not_rollback() {
  [[ "$1" == *'"body":"upgrade_rollback_failed"'* ]] \
    || { echo "no upgrade_rollback_failed record in: $1" >&2; return 1; }
  [[ "$1" != *'"body":"upgrade_rollback"'* ]] \
    || { echo "upgrade_rollback logged for a failed restore: $1" >&2; return 1; }
}

# _install_failing_merge_abort <stub_dir>
#   A `git` PATH shim that fails `git merge --abort` and forwards every
#   other invocation to the real git.
_install_failing_merge_abort() {
  local _stub_dir="$1"
  local _real_git
  _real_git="$(command -v git)"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "merge" && "\$2" == "--abort" ]]; then
  exit 128
fi
exec "${_real_git}" "\$@"
STUB
  chmod +x "${_stub_dir}/git"
}

# why: A rollback record logged before the rescue reset runs claims a
# restore that has not happened; the exit rollback logs it only after
@test "upgrade.sh: a post-pull rollback logs upgrade_rollback only once the repo is restored (base#1369)" {
  _publish_failing_init 'exit 7'
  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 7
  _assert_rollback_only_after_restore "${output}"
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
}

# why: The integrity-check rollback is the second restore path; it too
# logs upgrade_rollback only after the reset has put the repo back
@test "upgrade.sh: an integrity-check rollback logs upgrade_rollback only once the repo is restored (base#1369)" {
  cd "${DOWN_DIR}"
  local _stub_dir="${BATS_TEST_TMPDIR}/stub_bin"
  _install_destructive_ff_stub "${_stub_dir}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json GIT_EXEC_PATH="${_stub_dir}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_rollback_only_after_restore "${output}"
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
}

# why: When the exit rollback's reset fails, the tree is not restored, so
# the log carries upgrade_rollback_failed and no upgrade_rollback
@test "upgrade.sh: a failed post-pull reset logs upgrade_rollback_failed, never upgrade_rollback (base#1369)" {
  _publish_failing_init 'touch "$(git rev-parse --git-dir)/index.lock"; exit 7'
  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_rollback_failed_not_rollback "${output}"
  [ "$(git rev-parse HEAD)" != "${_pre_head}" ]
  rm -f "$(git rev-parse --git-dir)/index.lock"
}

# why: The integrity-check rollback's reset can fail the same way; the
# stub leaves an index.lock after its destructive reset so the rescue
# reset cannot run
@test "upgrade.sh: a failed integrity-check reset logs upgrade_rollback_failed, never upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"
  local _stub_dir="${BATS_TEST_TMPDIR}/stub_bin"
  _install_destructive_ff_stub "${_stub_dir}" \
    'touch "$(git rev-parse --git-dir)/index.lock"'
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json GIT_EXEC_PATH="${_stub_dir}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_rollback_failed_not_rollback "${output}"
  [ "$(git rev-parse HEAD)" != "${_pre_head}" ]
  rm -f "$(git rev-parse --git-dir)/index.lock"
}

# _install_failing_rm <stub_dir> <pattern>
#   An `rm` PATH shim that fails for any argument matching the glob
#   <pattern> and forwards every other invocation to the real rm.
_install_failing_rm() {
  local _stub_dir="$1"
  local _pattern="$2"
  local _real_rm
  _real_rm="$(command -v rm)"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/rm" <<STUB
#!/usr/bin/env bash
for _a in "\$@"; do
  if [[ "\${_a}" == ${_pattern} ]]; then
    echo "rm stub: refusing \${_a}" >&2
    exit 1
  fi
done
exec "${_real_rm}" "\$@"
STUB
  chmod +x "${_stub_dir}/rm"
}

# why: The reset can succeed and the sweep of upgrade-created files still
# fail; a failed removal followed by a successful one must not read as a
# restored repo, so the log carries upgrade_rollback_failed and no
# upgrade_rollback while the leftover file is still there
@test "upgrade.sh: a failed post-pull cleanup logs upgrade_rollback_failed, never upgrade_rollback (base#1369)" {
  _publish_failing_init 'touch aaa-cleanup-blocker zzz-upgrade-created; exit 7'
  cd "${DOWN_DIR}"
  local _stub_dir="${BATS_TEST_TMPDIR}/rm_shim"
  _install_failing_rm "${_stub_dir}" '*aaa-cleanup-blocker'
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json PATH="${_stub_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_rollback_failed_not_rollback "${output}"
  # The reset ran and the later removal succeeded; only the blocked file
  # is left -- the record above is the truth.
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  assert [ -e aaa-cleanup-blocker ]
  assert [ ! -e zzz-upgrade-created ]
}

# why: The integrity-check rollback runs the same sweep; a failed removal
# there must not end on upgrade_rollback either
@test "upgrade.sh: a failed integrity-check cleanup logs upgrade_rollback_failed, never upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"
  local _stub_dir="${BATS_TEST_TMPDIR}/stub_bin"
  _install_destructive_ff_stub "${_stub_dir}" \
    'touch aaa-cleanup-blocker zzz-upgrade-created'
  local _rm_dir="${BATS_TEST_TMPDIR}/rm_shim"
  _install_failing_rm "${_rm_dir}" '*aaa-cleanup-blocker'
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json GIT_EXEC_PATH="${_stub_dir}" \
      PATH="${_rm_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_rollback_failed_not_rollback "${output}"
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  assert [ -e aaa-cleanup-blocker ]
  assert [ ! -e zzz-upgrade-created ]
}

# _install_failing_ls_files <stub_dir> <marker>
#   A `git` PATH shim that fails `git ls-files` once <marker> exists and
#   forwards every other invocation to the real git. The marker lets the
#   pre-upgrade snapshot enumerate normally and fails only the rollback's.
_install_failing_ls_files() {
  local _stub_dir="$1"
  local _marker="$2"
  local _real_git
  _real_git="$(command -v git)"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ls-files" && -e "${_marker}" ]]; then
  echo "git stub: ls-files refused" >&2
  exit 128
fi
exec "${_real_git}" "\$@"
STUB
  chmod +x "${_stub_dir}/git"
}

# why: The sweep cannot remove files it never enumerated; when listing the
# untracked files fails, the rollback has not restored the tree and must
# end on upgrade_rollback_failed, never upgrade_rollback
@test "upgrade.sh: a failed untracked-file enumeration logs upgrade_rollback_failed, never upgrade_rollback (base#1369)" {
  local _marker="${BATS_TEST_TMPDIR}/ls_files_fails"
  _publish_failing_init "touch zzz-upgrade-created '${_marker}'; exit 7"
  cd "${DOWN_DIR}"
  local _stub_dir="${BATS_TEST_TMPDIR}/git_shim"
  _install_failing_ls_files "${_stub_dir}" "${_marker}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json PATH="${_stub_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 1
  _assert_rollback_failed_not_rollback "${output}"
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  assert [ -e zzz-upgrade-created ]
}

# _install_first_ls_files_fails <stub_dir> <marker>
#   A `git` PATH shim that fails only the FIRST `git ls-files` call and
#   forwards every other invocation to the real git. <marker> is a file
#   the shim creates on that first call, so later calls -- the rollback's
#   sweep among them -- enumerate normally.
_install_first_ls_files_fails() {
  local _stub_dir="$1"
  local _marker="$2"
  local _real_git
  _real_git="$(command -v git)"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ls-files" && ! -e "${_marker}" ]]; then
  : > "${_marker}"
  echo "git stub: first ls-files refused" >&2
  exit 128
fi
exec "${_real_git}" "\$@"
STUB
  chmod +x "${_stub_dir}/git"
}

# why: The pre-upgrade snapshot is what tells a rollback the user's own
# untracked files from the ones the upgrade created; a snapshot that
# failed to enumerate would make a later rollback sweep the user's files,
# so a failed snapshot must stop the upgrade before anything is pulled
@test "upgrade.sh: a failed pre-upgrade untracked snapshot stops the upgrade before the pull (base#1384)" {
  # A run that is not stopped would pull v0.9.7, fail its init.sh, and
  # roll back -- sweeping every untracked file the empty snapshot missed.
  _publish_failing_init 'exit 7'
  cd "${DOWN_DIR}"
  echo "user data" > mine.txt
  local _stub_dir="${BATS_TEST_TMPDIR}/git_shim"
  _install_first_ls_files_fails "${_stub_dir}" \
    "${BATS_TEST_TMPDIR}/ls_files_failed_once"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json PATH="${_stub_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert [ -e mine.txt ]
  [ "$(cat mine.txt)" = "user data" ]
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]
  [[ "${output}" != *'Step 1/5: git subtree pull'* ]]
  [[ "${output}" != *'"body":"upgrade_rollback"'* ]]
  local _last
  _last="$(printf '%s\n' "${output}" | grep -F '"severity_text":"ERROR"' | tail -n 1)"
  [[ "${_last}" == *'"body":"upgrade_untracked_snapshot_failed"'* ]]
}

# ── Untracked names git quotes (base#1381) ──────────────────────────────────
#
# A line-oriented `git ls-files` C-quotes any path holding a tab, a newline,
# a double quote, a backslash or (under the default core.quotepath) a
# non-ASCII byte, so a sweep that reads it line by line hands `rm -f` a
# name that does not exist and the real file stays.

# why: An aborted upgrade's files must all go, including those whose names
# git quotes; otherwise the rollback reports a restore that left them behind
@test "upgrade.sh: a rollback removes upgrade-created files whose names git quotes (base#1381)" {
  _publish_failing_init $'touch "tab\there" "new\nline" "caf\xc3\xa9-\xe6\x96\x87" plain-created; exit 7'
  cd "${DOWN_DIR}"
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 7
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  assert [ ! -e plain-created ]
  assert [ ! -e $'tab\there' ]
  assert [ ! -e $'new\nline' ]
  assert [ ! -e $'caf\xc3\xa9-\xe6\x96\x87' ]
  [ -z "$(git ls-files -z --others --exclude-standard | tr -d '\0')" ]
}

# why: The snapshot and the sweep must agree on a quoted name, or a rollback
# deletes a file the user made before the upgrade started
@test "upgrade.sh: a rollback keeps the user's own untracked files whose names git quotes (base#1381)" {
  _publish_failing_init 'touch zzz-upgrade-created; exit 7'
  cd "${DOWN_DIR}"
  echo "tab" > $'mine\twith-tab'
  echo "newline" > $'mine\nwith-newline'
  echo "unicode" > $'mine-caf\xc3\xa9'
  echo "quote" > 'mine"with\quote'

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure 7
  assert [ ! -e zzz-upgrade-created ]
  [ "$(cat $'mine\twith-tab')" = "tab" ]
  [ "$(cat $'mine\nwith-newline')" = "newline" ]
  [ "$(cat $'mine-caf\xc3\xa9')" = "unicode" ]
  [ "$(cat 'mine"with\quote')" = "quote" ]
}

# why: Aborting a conflicted pull's merge puts back a repo nothing was
# committed to; it is not a rollback, and a successful abort ends on
# upgrade_subtree_pull_failed with no upgrade_rollback record
@test "upgrade.sh: an aborted conflicting pull logs upgrade_subtree_pull_failed, never upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"
  _seed_conflicting_v098

  run env LOG_FORMAT=json TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.8
  assert_failure
  [[ "${output}" != *'"body":"upgrade_rollback"'* ]]
  local _last
  _last="$(printf '%s\n' "${output}" | grep -F '"severity_text":"ERROR"' | tail -n 1)"
  [[ "${_last}" == *'"body":"upgrade_subtree_pull_failed"'* ]]
  assert [ ! -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]
}

# why: A merge abort that fails leaves the tree mid-merge; the log says
# upgrade_rollback_failed and claims no rollback
@test "upgrade.sh: a failed merge abort logs upgrade_rollback_failed, never upgrade_rollback (base#1369)" {
  cd "${DOWN_DIR}"
  _seed_conflicting_v098
  local _stub_dir="${BATS_TEST_TMPDIR}/git_shim"
  _install_failing_merge_abort "${_stub_dir}"

  run env LOG_FORMAT=json PATH="${_stub_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.8
  assert_failure
  _assert_rollback_failed_not_rollback "${output}"
  # The tree really is still mid-merge -- the record above is the truth.
  assert [ -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]
}

# ──walk-up self-location resolves --prefix to the subtree basename ─────
#
# Regression guard for the relocation: upgrade.sh moved deep to
# .base/dist/script/base/upgrade.sh and now derives the subtree
# prefix by WALKING UP to the dir carrying `.version` + `dist/`
# (SUBTREE_ROOT), then `basename`-ing it. The danger is deriving the
# prefix from the script's OWN deep directory (`base`) instead of the
# subtree root (`.base`), which would make `git subtree pull
# --prefix=base` corrupt the repo. Capture the actual --prefix the
# relocated script passes and assert it is the subtree basename `.base`,
# then let the real git-subtree run so we also confirm a clean upgrade
# (no stray base/ dir at repo root).
# why: Walk-up self-location resolves the subtree prefix to `.base` after
# the deep relocation; real subtree pull lands with no stray `base/` dir
@test "upgrade.sh (#654 relocated): git subtree pull uses --prefix=.base, not --prefix=base" {
  cd "${DOWN_DIR}"

  # Wrap `git` on PATH: intercept `git subtree pull`, record its --prefix=
  # argument, then delegate the FULL invocation to the real git binary so
  # the upgrade lands normally. (A `git` PATH-shim is used rather than the
  # rollback test's GIT_EXEC_PATH git-subtree stub because the real
  # git-subtree re-invokes `git subtree` internally and must still resolve
  # the distro git-subtree -- the wrapper keeps GIT_EXEC_PATH intact.)
  local _real_git
  _real_git="$(command -v git)"
  local _stub_dir="${BATS_TEST_TMPDIR}/prefix_capture_bin"
  local _prefix_log="${BATS_TEST_TMPDIR}/captured_prefix.txt"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "subtree" && "\$2" == "pull" ]]; then
  for _a in "\$@"; do
    case "\${_a}" in
      --prefix=*) printf '%s\n' "\${_a#--prefix=}" > "${_prefix_log}" ;;
    esac
  done
fi
exec "${_real_git}" "\$@"
STUB
  chmod +x "${_stub_dir}/git"

  run env PATH="${_stub_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Done! Upgraded to v0.9.7"

  # The load-bearing assertion: prefix is the subtree basename .base.
  [ -f "${_prefix_log}" ]
  assert_equal "$(cat "${_prefix_log}")" ".base"

  # And the real pull landed cleanly: version bumped, no stray base/ dir
  # at the repo root, payload under .base/.
  [ "$(cat .base/.version)" = "v0.9.7" ]
  [ ! -e "base" ]
  [ -f ".base/script/docker/new_script.sh" ]
}

# ════════════════════════════════════════════════════════════════════
# upgrade.sh self-run guard (ADR-00000011 sec.8)
# ════════════════════════════════════════════════════════════════════

@test "upgrade.sh refuses to run when the subtree root carries .git (base template source, #721)" {
  cd "${DOWN_DIR}"

  # The base template SOURCE is itself a git checkout/worktree, so its
  # subtree root carries `.git`; a vendored `.base/` subtree never does
  # (the consumer's `.git` lives at the repo root, outside the subtree).
  # Give the subtree root a `.git` to mimic the source, and assert
  # upgrade refuses instead of running a nonsensical subtree pull into
  # base's PARENT dir.
  rm -rf .base/.git
  mkdir -p .base/.git

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "template source"
  # Pre-flight aborted before subtree pull ran: version untouched.
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# ════════════════════════════════════════════════════════════════════
# A local edit to a path upstream did not touch
# ════════════════════════════════════════════════════════════════════
#
# `git subtree pull --squash` raises a conflict only where BOTH sides
# changed the same path. For a path base shipped identically across the
# interval the merge sees a change on the local side and none upstream, so
# it keeps the local version with no conflict and no message -- and the
# upgrade's own output is then indistinguishable from one that landed a
# byte-exact tree. A byte-exact census of every vendored tree in the org
# found exactly one such edit, which had ridden through an upgrade
# untouched; what the census could not find was any run, check or output
# that would have reported it.
#
# The subject of the first arm is DERIVED from the fixture's two tags
# rather than written down here. A named path stops being "shipped
# identically across the interval" the moment the fixture changes that
# file, and the arm would then quietly pass by exercising the conflict path
# it exists to avoid.

# _path_unchanged_between_tags
#   Print one subtree-relative *.sh path whose blob the fixture ships
#   identically at BOTH tags. `comm -23` over the sorted path list and the
#   sorted changed-path list is the whole derivation. Restricted to *.sh so
#   the edit below can be a trailing comment, which every shell file in the
#   fixture tolerates -- these arms are about what the upgrade REPORTS, not
#   about breaking the tree it reports on.
_path_unchanged_between_tags() {
  local _all="${BATS_TEST_TMPDIR}/tag_paths.txt"
  local _changed="${BATS_TEST_TMPDIR}/tag_changed.txt"
  git -C "${TMPL_WORK}" ls-tree -r --name-only v0.9.5 | sort > "${_all}"
  git -C "${TMPL_WORK}" diff-tree -r --name-only v0.9.5 v0.9.7 | sort > "${_changed}"
  comm -23 "${_all}" "${_changed}" | grep -E '\.sh$' | head -n 1
}

# why: A squashed subtree pull reports a hand edit only where upstream
# touched the same path, so an edit to a path base shipped identically
# across the interval rides through the upgrade with no conflict and no
# message; the one real instance in the org sat in a vendored tree across
# seven releases and an upgrade before a byte-exact census found it, and
# silence is what invariant 2 exists to forbid
@test "upgrade.sh names a vendored edit on a path upstream did not touch (#1092)" {
  cd "${DOWN_DIR}"

  local _subject
  _subject="$(_path_unchanged_between_tags)"
  [ -n "${_subject}" ] \
    || fail "the fixture ships no *.sh path identically at both tags, so this arm cannot pose the case it names"

  printf '# an edit the consumer made inside the vendored tree\n' >> ".base/${_subject}"
  git add ".base/${_subject}"
  git commit -q -m "local edit inside the vendored tree"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "${_subject}"

  # The direction base chose: the consumer's edit is KEPT and reported, not
  # silently replaced by upstream's copy. Losing it is the other failure,
  # and this is the half a report-only fix must not drift into.
  grep -Fq '# an edit the consumer made inside the vendored tree' ".base/${_subject}"
}

# why: The edited-path case and the extra-file case reach the report by
# different sides of the tree comparison, and a check built only on the
# first reads a file the consumer added into the vendored tree as upstream's
# own; that is the shape the census counted separately as only-in-consumer
@test "upgrade.sh names a file the consumer added inside the vendored tree (#1092)" {
  cd "${DOWN_DIR}"

  local _extra="dist/script/base/consumer_added.sh"
  # Absence upstream is asserted, not assumed: a fixture that grew this
  # path would turn the arm into a test of the ordinary payload compare.
  refute git -C "${TMPL_WORK}" cat-file -e "v0.9.5:${_extra}"
  refute git -C "${TMPL_WORK}" cat-file -e "v0.9.7:${_extra}"

  printf '#!/usr/bin/env bash\nexit 0\n' > ".base/${_extra}"
  git add ".base/${_extra}"
  git commit -q -m "add a repo-local file inside the vendored tree"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "${_extra}"
  [ -f ".base/${_extra}" ]
}

# why: The negative control for the two arms above. A report that fires on
# every upgrade names nothing, and the census that motivated this check
# reported zero partial upgrades across 2217 files -- so a clean pull has to
# stay quiet, and this is the arm that fails if the comparison picks up the
# resync's own work rather than the consumer's
@test "upgrade.sh reports no vendored drift when the pull lands byte-exact (#1092)" {
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  refute_output --partial "do not match what base shipped"
  # And it was actually checked. "nothing to report" and "could not look" are
  # the same silence from the terminal, which is the whole complaint.
  refute_output --partial "could not be checked"

  # And the tree really is byte-exact, so "quiet" is not quiet-because-blind.
  # The upstream commit is read off git-subtree's own recorded metadata, the
  # same source the check under test reads, so the two cannot disagree about
  # which release the tree is being held to.
  local _split
  _split="$(git log --format=%B -5 | sed -n 's/^git-subtree-split: //p' | head -n 1)"
  [ -n "${_split}" ]
  assert_equal "$(git rev-parse "${_split}^{tree}")" "$(git rev-parse 'HEAD:.base')"
}
