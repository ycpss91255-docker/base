#!/usr/bin/env bash
#
# acceptance.sh -- scaffold a synthesized downstream repo from this checkout
# and drive the delivered `just` verbs from the consumer's chair.
#
# Acceptance level (ISTQB, ADR-00000018): what a downstream CONSUMER
# receives. init.sh scaffolds a repo whose vendored `.base/` is this
# checkout, and every assertion below is made through the same `just`
# verbs a consumer types -- build, run, exec, stop, the foreground run,
# start, setup apply, prune, base update, base completions, template new.
# Distinct from the `system` job, which exercises base's OWN image
# lifecycle (System level). See doc/test/acceptance.md.
#
# ONE copy, two callers (base#1409). The steps used to be written inline in
# self-test.yaml's `acceptance` job, so no local command could run them and
# the pre-PR mirror skipped the job outright. The job now runs this script,
# and so does `just test acceptance`; the two cannot drift, because there is
# nothing to drift between.
#
# What stays in the job, because only a runner has it: the buildx driver,
# the run-scoped test-tools image (script/ci/obtain_test_tools.sh), the
# pinned `just` install, and the run-scoped teardown. `just test acceptance`
# provides the local equivalents before it calls this script.
#
# setup-tui (the interactive TUI) is deliberately NOT driven here: doing it
# for real needs a pseudo-TTY. It stays covered by the unit tui_spec.
#
# Env:
#   CI_RUN_KEY          REQUIRED. The run identity every name this creates is
#                       keyed to (scaffold directory, image, container,
#                       network, prune probe), so a concurrent run's
#                       artifacts are never read as this run's, and
#                       script/ci/reclaim.sh --run <key> can prove ownership.
#   TEST_TOOLS_IMAGE    REQUIRED. The tooling image the consumer's lint stage
#                       is built FROM; it must already be in the daemon.
#   TOML_BRIDGE_IMAGE   the TOML bridge image the scaffolded repo reads its
#                       configuration through. Built here under this name.
#                       Default: a run-keyed tag, so reclaim.sh collects it.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_ACCEPTANCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _ACCEPTANCE_DIR
_ACCEPTANCE_ROOT="$(cd -- "${_ACCEPTANCE_DIR}/../.." && pwd -P)"
readonly _ACCEPTANCE_ROOT

# _step <title> -- announce a step, so a red run names where it stopped.
_step() {
  printf '\n==> %s\n' "$1"
}

# _build_toml_bridge -- the bridge image, pinned by name.
#
# NOT what makes the e2e repo work -- the shim provisions the bridge itself,
# under a content-digest tag, before the first TOML read. Kept, and pinned
# through TOML_BRIDGE_IMAGE, so this measures the scaffolded repo's
# lifecycle rather than a docker build inside it: a caller-pinned image is
# left alone by the shim. The provisioning path has its own coverage in the
# unit and integration tiers.
_build_toml_bridge() {
  _step "Build toml-bridge image (${TOML_BRIDGE_IMAGE})"
  docker build -t "${TOML_BRIDGE_IMAGE}" \
    -f "${_ACCEPTANCE_ROOT}/dockerfile/Dockerfile.toml-bridge" \
    "${_ACCEPTANCE_ROOT}/dockerfile"
}

# _scaffold -- create the temp repo and run init.sh in it.
_scaffold() {
  _step "Create temp repo and run init.sh"
  TMP_ROOT="$(mktemp -d)"
  # The scaffolded directory's BASENAME becomes IMAGE_NAME (the [image]
  # @basename rule), and IMAGE_NAME is what the image tag
  # (${DOCKER_HUB_USER}/${IMAGE_NAME}:<stage>), the container name
  # (${USER_NAME}-${IMAGE_NAME}) and the compose project are all built from
  # -- so keying this ONE name to the run makes all three unique. mktemp -d
  # alone does not: it randomises the PARENT, which no docker name is
  # derived from.
  REPO_NAME="e2e_test-ci-${CI_RUN_KEY}"
  REPO_DIR="${TMP_ROOT}/${REPO_NAME}"
  mkdir -p "${REPO_DIR}/.base"

  # Mirror the current template into the synthetic repo. A real vendored
  # subtree never carries `.git` (the consumer's `.git` lives at the repo
  # root, outside the subtree); `cp -a` of the checkout copies its `.git`
  # (a directory, or a file in a worktree), which the self-run guard
  # (ADR-00000011 sec.8) reads as "this is the base source". Strip it so
  # `.base/` is a genuine subtree and init.sh runs.
  cp -a "${_ACCEPTANCE_ROOT}/." "${REPO_DIR}/.base/"
  rm -rf "${REPO_DIR}/.base/.git"

  cd "${REPO_DIR}"
  bash .base/dist/script/base/init.sh

  # Sanity: the wrappers live under script/ and the root user entry is the
  # justfile.
  test -L script/build.sh && test -L script/run.sh \
    && test -L script/exec.sh && test -L script/stop.sh
  test -L script/setup_tui.sh
  test -L justfile
  test -f Dockerfile && test -f compose.yaml && test -f setup.toml
}

# _build_unpinned_tooling -- the consumer's own tooling image, nothing
# pinned (base#1172).
#
# Every other build here runs with TEST_TOOLS_IMAGE pinned, so build.sh
# skips its internal tooling build and none of them reach the path a
# downstream developer takes. Unset it so build.sh builds the
# version-scoped test-tools:<.base/.version> image itself, from the
# consumer's checkout, then run that image's toml-bridge and assert its
# exact output. The consumer root carries no dockerfile/toml_bridge.py --
# only the vendored .base/ does -- which the first check pins so this
# cannot pass vacuously.
_build_unpinned_tooling() {
  _step "Build the consumer's own tooling image, nothing pinned (base#1172)"
  if [[ -e dockerfile/toml_bridge.py ]]; then
    echo "ERROR: the scaffolded consumer carries dockerfile/toml_bridge.py at its root; this guard would pass vacuously"
    return 1
  fi
  env -u TEST_TOOLS_IMAGE just docker build test
  local ver got want
  ver="$(tr -d '[:space:]' < .base/.version)"
  got="$(printf 'a = 1\n[t]\nb = "x"\n' \
           | docker run --rm -i --entrypoint toml-bridge "test-tools:${ver}")"
  want='{"a": 1, "t": {"b": "x"}}'
  echo "toml-bridge in test-tools:${ver}: ${got}"
  if [[ "${got}" != "${want}" ]]; then
    echo "ERROR: toml-bridge printed '${got}', expected '${want}'"
    return 1
  fi
}

# _build_stages -- the test and devel stages. build.sh skips its internal
# test-tools build when TEST_TOOLS_IMAGE is set, and the image is already
# in the daemon, so `FROM ${TEST_TOOLS_IMAGE}` resolves locally.
_build_stages() {
  _step "Build test stage (just docker build test)"
  just docker build test
  _step "Build devel stage (just docker build)"
  just docker build
}

# _assert_runnability -- run detached and assert the runnability contract
# (base#579): assert results, don't just run steps. The v0.41.0 user-args bug
# made `whoami` print `initial` yet the job stayed green because nothing
# checked the output.
_assert_runnability() {
  _step "Run container detached and assert the runnability contract"
  # The configured user is host-detected by setup.sh and cached in
  # .env.generated; read it rather than hardcoding the runner's.
  # shellcheck disable=SC1091
  source ./.env.generated
  : "${USER_NAME:?USER_NAME missing from .env.generated}"
  echo "configured USER_NAME=${USER_NAME}"

  just docker run -d
  just docker exec echo "just docker exec OK from CI"

  # Derive the container name at runtime (compose names it
  # ${USER_NAME}-${IMAGE_NAME}-<svc>; IMAGE_NAME is the scaffolded repo
  # dir). Filtering by the run-scoped repo name avoids reconstructing the
  # full host-detected name and cannot read a CONCURRENT run's container
  # as this run's.
  local cname
  cname="$(docker ps --filter "name=${REPO_NAME}" --filter 'status=running' \
             --format '{{.Names}}')"
  cname="${cname%%$'\n'*}"

  # (2) container did NOT insta-exit (the entrypoint set -u class).
  if [[ -z "${cname}" ]]; then
    echo "ERROR: no running ${REPO_NAME} container after just docker run -d"
    docker ps -a
    return 1
  fi

  # (1) the in-container user is the configured one, not the v0.41.0
  # 'initial' bug nor 'root'.
  local who
  who="$(just docker exec id -un | tr -d '\r' | tail -n1)"
  echo "id -un inside container: ${who}"
  if [[ "${who}" != "${USER_NAME}" ]]; then
    echo "ERROR: container user '${who}' != configured '${USER_NAME}'"
    return 1
  fi

  # (3) the ENTRYPOINT actually ran -- the wired entry point is base's
  # orchestrator at /usr/local/lib/base/entrypoint.sh (Dockerfile
  # ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]), which SOURCES the
  # repo-owned bringup at /entrypoint.sh before it execs the workload
  # (ADR-00000032). `.Path` therefore names the base-owned half.
  local path
  path="$(docker inspect -f '{{.Path}}' "${cname}")"
  echo "container Path: ${path}"
  if [[ "${path}" != "/usr/local/lib/base/entrypoint.sh" ]]; then
    echo "ERROR: container entrypoint '${path}' != /usr/local/lib/base/entrypoint.sh"
    return 1
  fi

  # (4) the ~/work workspace mount is present and writable inside. Simple
  # per-call argv (not `just docker exec bash -c '<compound>'`, whose
  # quoting does not survive just's argument splitting) and an absolute
  # path (the mount lands at /home/${USER_NAME}/work).
  local work
  work="/home/${USER_NAME}/work"
  just docker exec test -d "${work}"
  just docker exec touch "${work}/.e2e_probe"
  just docker exec rm -f "${work}/.e2e_probe"
}

# _assert_no_leftovers <what> -- no container and no project network of
# this run survive.
_assert_no_leftovers() {
  # Each listing is captured whole before it is searched: piping it into
  # `grep -q` lets grep exit at the first match, the writer takes SIGPIPE,
  # and pipefail turns a FOUND leftover into "not found".
  local names networks
  names="$(docker ps -a --format '{{.Names}}')"
  networks="$(docker network ls --format '{{.Name}}')"
  # (5a) no project container remains.
  if grep -q "${REPO_NAME}" <<< "${names}"; then
    echo "ERROR: ${1} left a ${REPO_NAME} container behind"
    docker ps -a
    return 1
  fi
  # (5b) the compose project's default network is gone. `compose up`
  # creates ${DOCKER_HUB_USER}-${REPO_NAME}_default even under
  # network_mode: host; `compose down` removes it.
  if grep -q "${REPO_NAME}_default" <<< "${networks}"; then
    echo "ERROR: ${1} left a ${REPO_NAME} project network behind"
    docker network ls
    return 1
  fi
}

# _assert_teardown -- stop and assert full teardown.
_assert_teardown() {
  _step "Stop and assert full teardown (container + network gone)"
  just docker stop
  _assert_no_leftovers "just docker stop"
}

# _assert_foreground_run -- `just docker run <cmd>` (no -d) brings the
# devel service up, execs the CMD, then the base#386 auto-down tears the
# project down on exit. Assert the real in-container effect AND the
# auto-cleanup (base#386 / base#769).
_assert_foreground_run() {
  _step "Run foreground command variant and assert auto-cleanup (base#386 / base#769)"
  # shellcheck disable=SC1091
  source ./.env.generated
  : "${USER_NAME:?USER_NAME missing from .env.generated}"
  # QUIET=1 mutes the pre-run config summary so the captured stdout is the
  # in-container `id -un` output. </dev/null guards against any stdin read.
  local who
  who="$(QUIET=1 just docker run id -un </dev/null 2>/dev/null \
           | tr -d '\r' | tail -n1)"
  echo "foreground run id -un: ${who}"
  if [[ "${who}" != "${USER_NAME}" ]]; then
    echo "ERROR: foreground run ran as '${who}', expected '${USER_NAME}'"
    return 1
  fi
  _assert_no_leftovers "foreground run"
}

# _assert_start -- `just docker start` is build (cached here) + a
# foreground `run` in one step (base#769). Assert the devel image is present
# (build half ran) and nothing leaks (foreground half cleaned up).
_assert_start() {
  _step "Build + run in one step via just docker start (base#769)"
  just docker start </dev/null
  local images names
  images="$(docker images --format '{{.Repository}}:{{.Tag}}')"
  names="$(docker ps -a --format '{{.Names}}')"
  if ! grep -q "${REPO_NAME}" <<< "${images}"; then
    echo "ERROR: just docker start did not leave a built ${REPO_NAME} image"
    docker images
    return 1
  fi
  if grep -q "${REPO_NAME}" <<< "${names}"; then
    echo "ERROR: just docker start left a container behind (auto-down failed)"
    docker ps -a
    return 1
  fi
}

# _assert_setup_apply -- delete the two derived artifacts and assert
# `setup apply` regenerates them from setup.toml + host detection (base#769).
_assert_setup_apply() {
  _step "Regenerate derived artifacts via just docker setup apply (base#769)"
  test -f .env.generated && test -f compose.yaml
  rm -f .env.generated compose.yaml
  just docker setup apply
  if [[ ! -f .env.generated || ! -f compose.yaml ]]; then
    echo "ERROR: setup apply did not regenerate .env.generated + compose.yaml"
    ls -la
    return 1
  fi
  grep -q 'services:' compose.yaml
  # shellcheck disable=SC1091
  source ./.env.generated
  : "${USER_NAME:?regenerated .env.generated missing USER_NAME}"
}

# _assert_prune -- a REAL prune (not --dry-run) of a run-scoped probe
# network (base#769).
#
# The probe's NAME is run-scoped because two concurrent runs creating one
# fixed name is a hard failure ("network with name ... already exists").
# The prune itself stays daemon-wide, deliberately: `docker network prune`
# removes only networks with NO container attached at all, so the worst it
# can do to a sibling is delete an idle project network compose recreates
# on its next invocation.
_assert_prune() {
  _step "Real prune via just docker prune (base#769)"
  local probe
  probe="e2e_prune_probe-ci-${CI_RUN_KEY}"
  docker network create "${probe}" >/dev/null
  # until=1s prunes networks created more than 1s ago; sleep so the probe
  # qualifies deterministically.
  sleep 2
  just docker prune --networks --until 1s
  local networks
  networks="$(docker network ls --format '{{.Name}}')"
  if grep -qx "${probe}" <<< "${networks}"; then
    echo "ERROR: just docker prune --networks did not remove the probe network"
    docker network ls
    return 1
  fi
}

# _assert_base_update -- `just base update` runs upgrade.sh --check against
# the published base tags (needs network). The recipe masks the apt-style
# "update available" exit 1 to 0, so assert a verdict line appears (base#769).
_assert_base_update() {
  _step "Check for base updates via just base update (base#769)"
  local out
  out="$(just base update 2>&1)"
  echo "${out}"
  if ! grep -Eq 'Already up to date|Update available|Local is ahead' <<< "${out}"; then
    echo "ERROR: just base update produced no version verdict"
    return 1
  fi
}

# _assert_completions -- install, exercise and uninstall the bash
# completion loader (base#769). XDG_DATA_HOME is isolated so the assertion is
# hermetic and the installer never touches the caller's real HOME.
_assert_completions() {
  _step "Install shell completions via just base completions (base#769)"
  local XDG_DATA_HOME="${REPO_DIR}/.xdg-data"
  export XDG_DATA_HOME
  local target="${XDG_DATA_HOME}/bash-completion/completions/just"
  just base completions install --shell bash
  if [[ ! -s "${target}" ]]; then
    echo "ERROR: completions install wrote no (or empty) loader at ${target}"
    return 1
  fi
  grep -q 'JUST_COMPLETE' "${target}"
  # The dynamic completer the loader invokes must itself emit non-empty
  # completion output against the layered justfile.
  local comp
  comp="$(JUST_COMPLETE=bash just 2>/dev/null || true)"
  if [[ -z "${comp}" ]]; then
    echo "ERROR: 'just' produced no completion output"
    return 1
  fi
  # Round-trip: uninstall removes the loader.
  just base completions uninstall --shell bash
  if [[ -e "${target}" ]]; then
    echo "ERROR: completions uninstall did not remove ${target}"
    return 1
  fi
}

# _assert_template_new -- drive the REAL `just template new <name>` recipe
# in the scaffolded consumer and assert the produced consumer artifact
# (base#785): new.sh is unit-tested in isolation, but the recipe -- the
# `template` namespace wiring and the consumer symlink chain that resolves
# it -- is exercised nowhere else.
_assert_template_new() {
  _step "Scaffold a repo-local command group via just template new (base#785)"
  local name="deploy"
  # Guard against a false green: the group must not pre-exist.
  if [[ -e "script/local/${name}" ]]; then
    echo "ERROR: script/local/${name} already exists before scaffolding"
    return 1
  fi

  just template new "${name}"

  # (1) the scaffolded group dir + its two files exist, and the command
  # script is executable.
  if [[ ! -f "script/local/${name}/justfile.${name}" \
        || ! -x "script/local/${name}/${name}.sh" ]]; then
    echo "ERROR: just template new did not scaffold script/local/${name}/"
    ls -la "script/local/${name}" || true
    return 1
  fi
  # (2) __NAME__ placeholders were substituted (no leftover token).
  if grep -RqF '__NAME__' "script/local/${name}/"; then
    echo "ERROR: scaffolded files still contain the __NAME__ placeholder"
    return 1
  fi
  # (3) the group is registered in the repo-owned registry.
  if ! grep -qF "mod? ${name} '${name}/justfile.${name}'" \
       script/local/justfile.local; then
    echo "ERROR: group '${name}' not registered in script/local/justfile.local"
    cat script/local/justfile.local || true
    return 1
  fi
  # (4) the freshly-registered group resolves through the consumer entry:
  # `just --list ${name}` lists the scaffolded module's example `hello`
  # recipe (proves the module + registry wiring, no side effect).
  local listing
  listing="$(just --list "${name}" 2>&1)" || listing=""
  if ! grep -qw 'hello' <<< "${listing}"; then
    echo "ERROR: 'just --list ${name}' does not resolve the scaffolded module"
    just --list "${name}" || true
    just --list || true
    return 1
  fi
  # (5) actually RUN the scaffolded example recipe end-to-end: it cd's into
  # the module dir and execs the generated ./${name}.sh, whose __NAME__ was
  # substituted, so the greeting must name the group.
  local out
  out="$(just "${name}" hello)"
  echo "${out}"
  if [[ "${out}" != *"hello from the ${name} group"* ]]; then
    echo "ERROR: 'just ${name} hello' did not run the scaffolded recipe"
    return 1
  fi
}

# _cleanup_tmp -- drop the scaffold tree. Its docker artifacts are not
# touched here: they carry the run key in their names, and
# script/ci/reclaim.sh --run <key> is what proves and removes them.
_cleanup_tmp() {
  if [[ -n "${TMP_ROOT:-}" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}" 2>/dev/null || true
  fi
}

main() {
  : "${CI_RUN_KEY:?acceptance.sh: CI_RUN_KEY is required -- it keys every name this run creates}"
  : "${TEST_TOOLS_IMAGE:?acceptance.sh: TEST_TOOLS_IMAGE is required -- the consumer lint stage is built FROM it}"
  TOML_BRIDGE_IMAGE="${TOML_BRIDGE_IMAGE:-toml-bridge:acceptance-ci-${CI_RUN_KEY}}"
  export TOML_BRIDGE_IMAGE

  TMP_ROOT=""
  trap _cleanup_tmp EXIT

  _build_toml_bridge
  _scaffold
  _build_unpinned_tooling
  _build_stages
  _assert_runnability
  _assert_teardown
  _assert_foreground_run
  _assert_start
  _assert_setup_apply
  _assert_prune
  _assert_base_update
  _assert_completions
  _assert_template_new
  _step "acceptance: every assertion passed"
}

main "$@"
