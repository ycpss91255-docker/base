#!/usr/bin/env bats
#
# Tests for the self-contained field-deploy generator in
# dist/script/docker/lib/deploy.sh. The deploy model produces an output
# FOLDER run via a fully-resolved, self-contained docker compose (ADR-3
# amended by ADR-00000023): _resolve_deploy_version (image-identity stamp),
# _resolve_deploy_context (the conf-resolution shared with apply),
# _generate_resolved_compose (the resolved compose.yaml -- no variable
# interpolation, no setup.conf/.env dep, dev-host binds stripped, restart
# added, tunable-manifest paths bound, per-stage params carried),
# _generate_deploy_launcher (the thin up/down/logs deploy.sh), and
# _generate_deploy_bundle (the folder orchestrator; docker steps mocked via
# _dry_run_cmd, no real daemon). The tunable-manifest parser lives in its
# sibling deploy_manifest_spec.bats.
#
# why: Covers the self-contained field-deploy generator (#832; ADR-3 amended
# by ADR-00000023). Deploy produces an output FOLDER run via a
# fully-resolved, self-contained `docker compose` (superseding the #497 raw
# `docker run` tar.xz): `_resolve_deploy_version` (the
# `<repo>:<stage>-<version>` image stamp), `_resolve_deploy_context` (the
# conf-resolution shared with apply), `_generate_resolved_compose` (the
# resolved `compose.yaml` -- no variable interpolation, no
# `setup.conf`/`.env` dependency, dev-host workspace bind stripped,
# `restart: unless-stopped` added, tunable-manifest paths bound, per-stage
# params carried, follows the stage for GUI/X11),
# `_generate_deploy_launcher` (the thin up/down/logs `deploy.sh`), and
# `_generate_deploy_bundle` (the folder orchestrator; docker/xz/cp steps
# mocked via `_dry_run_cmd`, no real daemon). Also covers `_setup_deploy`'s
# stage-eligibility guard (#841): the `--stage` a user names must satisfy
# `_is_deployable_stage` (PRD invariant 8 / ADR-00000023 sec.4), so the
# template-managed baseline, the legacy aliases and any `*-test` stage are
# refused before any build or bundle step.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
}

_write_conf() {
  local _dir="${1}"; shift
  mkdir -p "${_dir}"
  printf '%s\n' "$@" > "${_dir}/.setup.conf"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_version -- the version-iteration-safe stamp for the
# image identity <repo>:<stage>-<version> (git describe --tags --always
# --dirty; `unknown` outside a git tree).
# ════════════════════════════════════════════════════════════════════

# why: version tag
@test "_resolve_deploy_version: returns the tag in a tagged git tree (field-deploy)" {
  local _d; _d="$(mktemp -d)"
  git -C "${_d}" init -q
  git -C "${_d}" config user.email t@t; git -C "${_d}" config user.name t
  : > "${_d}/f"; git -C "${_d}" add f; git -C "${_d}" commit -qm init
  git -C "${_d}" tag v1.2.3
  run _resolve_deploy_version "${_d}"
  assert_success
  assert_output "v1.2.3"
  rm -rf "${_d}"
}

# why: dirty stamp
@test "_resolve_deploy_version: appends -dirty when the tree has uncommitted changes (field-deploy)" {
  local _d; _d="$(mktemp -d)"
  git -C "${_d}" init -q
  git -C "${_d}" config user.email t@t; git -C "${_d}" config user.name t
  : > "${_d}/f"; git -C "${_d}" add f; git -C "${_d}" commit -qm init
  git -C "${_d}" tag v1.2.3
  echo change >> "${_d}/f"
  run _resolve_deploy_version "${_d}"
  assert_success
  assert_output "v1.2.3-dirty"
  rm -rf "${_d}"
}

# why: tagless `--always` fallback
@test "_resolve_deploy_version: falls back to the short commit SHA in a tagless clone (#844)" {
  # The middle branch of `git describe --tags --always --dirty`: a real repo
  # with commits but no tags, where --always is what keeps the stamp
  # meaningful. Without it describe fails and every untagged repo silently
  # deploys as 'unknown', collapsing the version-collision avoidance.
  local _d; _d="$(mktemp -d)"
  git -C "${_d}" init -q
  git -C "${_d}" config user.email t@t; git -C "${_d}" config user.name t
  : > "${_d}/f"; git -C "${_d}" add f; git -C "${_d}" commit -qm init
  run _resolve_deploy_version "${_d}"
  assert_success
  refute_output "unknown"
  refute_output ""
  assert_output --regexp '^[0-9a-f]{7,}$'
  rm -rf "${_d}"
}

# why: non-git fallback
@test "_resolve_deploy_version: degrades to 'unknown' outside a git tree (field-deploy)" {
  local _d; _d="$(mktemp -d)"
  run _resolve_deploy_version "${_d}"
  assert_success
  assert_output "unknown"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_context -- the conf-resolution layer shared by both apply
# and the deploy generator. Loads setup.conf sections and resolves the
# docker/build scalars + list strings into one record.
# ════════════════════════════════════════════════════════════════════

# why: full resolution
@test "_resolve_deploy_context: resolves scalars + list strings from setup.conf (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" \
    "[deploy]" "gpu_mode = force" "gpu_count = 2" "gpu_capabilities = gpu compute" "gpu_runtime = nvidia" \
    "[network]" "mode = bridge" "ipc = private" "network_name = mynet" "port_1 = 8080:80" \
    "[security]" "privileged = true" \
    "[devices]" "device_1 = /dev/ttyUSB0" \
    "[environment]" "env_1 = FOO=bar" \
    "[resources]" "shm_size = 256m" \
    "[lifecycle]" "restart = on-failure"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_mode]}" "force"
  assert_equal "${_ctx[gpu_count]}" "2"
  assert_equal "${_ctx[gpu_caps]}" "gpu compute"
  assert_equal "${_ctx[gpu_runtime_mode]}" "nvidia"
  assert_equal "${_ctx[net_mode]}" "bridge"
  assert_equal "${_ctx[ipc_mode]}" "private"
  assert_equal "${_ctx[network_name]}" "mynet"
  assert_equal "${_ctx[privileged]}" "true"
  assert_equal "${_ctx[devices_str]}" "/dev/ttyUSB0"
  assert_equal "${_ctx[env_str]}" "FOO=bar"
  assert_equal "${_ctx[ports_str]}" "8080:80"
  assert_equal "${_ctx[shm_size]}" "256m"
  assert_equal "${_ctx[restart_policy]}" "on-failure"
  rm -rf "${_d}"
}

# why: template-merged defaults
@test "_resolve_deploy_context: applies effective defaults for a minimal repo conf (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[image_name]" "name = placeholder"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_mode]}" "auto"
  assert_equal "${_ctx[gpu_count]}" "all"
  assert_equal "${_ctx[gpu_runtime_mode]}" "auto"
  assert_equal "${_ctx[gui_mode]}" "auto"
  assert_equal "${_ctx[net_mode]}" "host"
  assert_equal "${_ctx[ipc_mode]}" "host"
  assert_equal "${_ctx[pid_mode]}" "private"
  assert_equal "${_ctx[privileged]}" "false"
  # The template ships `restart = unless-stopped`; a conf hand-stripped of
  # the key still resolves to that same default.
  assert_equal "${_ctx[restart_policy]}" "unless-stopped"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: a missing [lifecycle] restart falls back to the shipped default (#840)" {
  local _d; _d="$(mktemp -d)"
  # Hand-stripped conf -> the template's own default, not an empty policy.
  _write_conf "${_d}" "[image_name]" "name = placeholder"
  local -A _absent=()
  _resolve_deploy_context "${_d}" _absent
  assert_equal "${_absent[restart_policy]}" "unless-stopped"
  # An explicitly configured value is honoured verbatim.
  _write_conf "${_d}" "[lifecycle]" "restart = no"
  local -A _explicit=()
  _resolve_deploy_context "${_d}" _explicit
  assert_equal "${_explicit[restart_policy]}" "no"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: builds the WATCHDOG_* env block from [lifecycle] watchdog_* (#840)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[lifecycle]" "watchdog_check = pgrep -f my_node" \
    "watchdog_interval = 30" "watchdog_on_fail = restart"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[watchdog_env_str]}" \
    $'WATCHDOG_CHECK=pgrep -f my_node\nWATCHDOG_INTERVAL=30\nWATCHDOG_ON_FAIL=restart'
  rm -rf "${_d}"
}

# why: legacy alias
@test "_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode (#506/#481)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "runtime = nvidia"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_runtime_mode]}" "nvidia"
  rm -rf "${_d}"
}

# why: dri auto
@test "_resolve_deploy_context: dri_groups auto resolves host GIDs via the SETUP_DETECT_DRI_GROUPS operator override (#506/#496)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "dri_groups = auto"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44 110" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" "44 110"
  rm -rf "${_d}"
}

# why: dri off
@test "_resolve_deploy_context: dri_groups off yields empty (#506/#496)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "dri_groups = off"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44 110" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" ""
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_resolved_compose -- the fully-resolved, self-
# contained field compose.yaml. No variable interpolation, no
# setup.conf/.env dependency, no build section, dev-host binds stripped;
# restart: unless-stopped added; tunable-manifest paths bound; per-stage
# resolved params carried; follows the stage (does not blanket-strip GUI).
# ════════════════════════════════════════════════════════════════════

# Deterministic headless conf: no gpu, no dri, gui off -> the resolved
# compose carries only literals (nothing host- or display-dependent).
_write_headless_conf() {
  _write_conf "${1}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off"
}

# why: resolved + self-contained
@test "_generate_resolved_compose: self-contained -- no variable interpolation, restart present, image pinned (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_headless_conf "${_d}"
  local _out="${_d}/compose.yaml"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "local/myrepo:runtime-v1.2.3" "myrepo-runtime" "${_out}" _binds
  run cat "${_out}"
  assert_success
  # Fully resolved: no compose variable interpolation survives.
  refute_output --partial '${'
  assert_output --partial "image: local/myrepo:runtime-v1.2.3"
  assert_output --partial "container_name: myrepo-runtime"
  assert_output --partial "restart: unless-stopped"
  assert_output --partial "network_mode: host"
  # No build section and no host-side setup.conf / .env.generated dependency.
  refute_output --partial "build:"
  # env_file names only files that travel INSIDE the bundle.
  assert_output --partial "env_file:"
  assert_output --partial "- .env"
  assert_output --partial "- .env.local"
  rm -rf "${_d}"
}

# why: dev-host strip
@test "_generate_resolved_compose: strips the dev-host workspace bind and bakes env (no -v/-e) (#832)" {
  local _d; _d="$(mktemp -d)"
  # SC2016: literal ${WS_PATH} is the portable workspace-bind form in
  # setup.conf, not a shell expansion.
  # shellcheck disable=SC2016
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[environment]" "env_1 = FOO=bar" \
    "[volumes]" 'mount_1 = ${WS_PATH}:/work'
  local _out="${_d}/compose.yaml"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_out}" _binds
  run cat "${_out}"
  refute_output --partial "WS_PATH"
  refute_output --partial ":/work"
  refute_output --partial "FOO=bar"
  rm -rf "${_d}"
}

# why: tunable binds
@test "_generate_resolved_compose: binds each tunable-manifest file mount-wins over the baked default (#833)" {
  local _d; _d="$(mktemp -d)"
  _write_headless_conf "${_d}"
  local _out="${_d}/compose.yaml"
  local -A _binds=([host.yaml]="/etc/app/host.yaml" [camera.yaml]="/camera_config.yaml")
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_out}" _binds
  run cat "${_out}"
  assert_output --partial "volumes:"
  assert_output --partial "- ./config/host.yaml:/etc/app/host.yaml:ro"
  assert_output --partial "- ./config/camera.yaml:/camera_config.yaml:ro"
  rm -rf "${_d}"
}

# why: :ro default, :rw when declared
@test "_generate_resolved_compose: a tunable bind is read-only unless the manifest declared rw (#870)" {
  local _d; _d="$(mktemp -d)"
  _write_headless_conf "${_d}"
  local _out="${_d}/compose.yaml"
  local -A _binds=([host.yaml]="/etc/app/host.yaml" [calib.yaml]="/var/lib/app/calib.yaml")
  local -A _modes=([calib.yaml]="rw")
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_out}" _binds "" _modes
  run cat "${_out}"
  assert_output --partial "- ./config/host.yaml:/etc/app/host.yaml:ro"
  assert_output --partial "- ./config/calib.yaml:/var/lib/app/calib.yaml:rw"
  rm -rf "${_d}"
}

# why: per-stage params
@test "_generate_resolved_compose: carries the deployed stage's resolved params (privileged/gpu/devices) (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = force" "gpu_count = 2" \
    "gpu_capabilities = gpu compute" "dri_groups = off" "[gui]" "mode = off" \
    "[security]" "privileged = true" \
    "[devices]" "device_1 = /dev/ttyUSB0"
  local _out="${_d}/compose.yaml"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_out}" _binds
  run cat "${_out}"
  assert_output --partial "privileged: true"
  assert_output --partial "driver: nvidia"
  assert_output --partial "count: 2"
  assert_output --partial "devices:"
  assert_output --partial "- /dev/ttyUSB0"
  rm -rf "${_d}"
}

# why: follow-stage GUI
@test "_generate_resolved_compose: follows the stage -- gui off headless, gui force emits X11 (#832)" {
  local _d; _d="$(mktemp -d)"
  # gui off -> no X11.
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/off.yaml" _binds
  run cat "${_d}/off.yaml"
  refute_output --partial "DISPLAY"
  refute_output --partial "X11-unix"
  # gui force -> X11 passthrough travels (a gui stage is not stripped).
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = force"
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/on.yaml" _binds
  run cat "${_d}/on.yaml"
  assert_output --partial "DISPLAY"
  assert_output --partial "/tmp/.X11-unix:/tmp/.X11-unix:ro"
  rm -rf "${_d}"
}

# why: per-stage override
@test "_generate_resolved_compose: per-stage [stage:runtime] override is applied (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[network]" "mode = host" \
    "[stage:runtime]" "network.mode = bridge" "network.network_name = fieldnet"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run cat "${_d}/compose.yaml"
  assert_output --partial "- fieldnet"
  assert_output --partial "driver: bridge"
  refute_output --partial "network_mode: host"
  rm -rf "${_d}"
}

# why: ipc/shm literals
@test "_generate_resolved_compose: shm_size + ipc emitted as literals under non-host ipc (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[network]" "ipc = private" "[resources]" "shm_size = 256m"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run cat "${_d}/compose.yaml"
  assert_output --partial "shm_size: 256m"
  refute_output --partial '${'
  rm -rf "${_d}"
}

@test "_generate_resolved_compose: the watchdog env leaves environment: for the bundle .env (#868)" {
  # restart: only recovers a container that EXITS; the watchdog is the only
  # thing that recovers a service that is alive but wedged, so the field
  # bundle must carry the same WATCHDOG_* env the dev compose emits -- but
  # via env_file, because environment: outranks env_file and would make the
  # operator's .env.local override silently inert.
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[lifecycle]" "watchdog_check = pgrep -f my_node" "watchdog_interval = 30" \
    "watchdog_on_fail = restart"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run cat "${_d}/compose.yaml"
  assert_success
  refute_output --partial "WATCHDOG_"
  rm -rf "${_d}"
}

@test "_generate_bundle_env writes the field .env with watchdog + [environment] defaults (#868)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[environment]" "env_1 = APP_MODE=default" \
    "[lifecycle]" "watchdog_check = pgrep -f my_node" "watchdog_interval = 30"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  _generate_bundle_env "${_d}/.env" _ctx
  run cat "${_d}/.env"
  assert_success
  assert_output --partial "APP_MODE='default'"
  assert_output --partial "WATCHDOG_CHECK='pgrep -f my_node'"
  assert_output --partial "WATCHDOG_INTERVAL='30'"
  rm -rf "${_d}"
}

@test "_generate_resolved_compose: no environment: block when the watchdog is off and gui is off (#840)" {
  local _d; _d="$(mktemp -d)"
  _write_headless_conf "${_d}"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run cat "${_d}/compose.yaml"
  assert_success
  refute_output --partial "environment:"
  refute_output --partial "WATCHDOG_"
  rm -rf "${_d}"
}

@test "_generate_resolved_compose: gui X11 still owns the environment: block (#840)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = force" \
    "[lifecycle]" "watchdog_check = pgrep -f my_node"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run grep -c '^    environment:$' "${_d}/compose.yaml"
  assert_success
  assert_output "1"
  run cat "${_d}/compose.yaml"
  assert_output --partial "DISPLAY"
  refute_output --partial "WATCHDOG_CHECK"
  rm -rf "${_d}"
}

@test "_generate_resolved_compose: restart defaults to unless-stopped, an explicit policy wins (#840)" {
  local _d; _d="$(mktemp -d)"
  local -A _binds=()
  # No [lifecycle] restart -> the shipped default (auto-start on reboot).
  _write_headless_conf "${_d}"
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/absent.yaml" _binds
  run grep -E '^    restart:' "${_d}/absent.yaml"
  assert_output "    restart: unless-stopped"
  # Explicit `no` -> honoured instead of silently overridden.
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[lifecycle]" "restart = no"
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/no.yaml" _binds
  run grep -E '^    restart:' "${_d}/no.yaml"
  assert_output "    restart: no"
  # on-failure:N -> honoured, YAML-quoted (a bare `:` would read as a mapping).
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[lifecycle]" "restart = on-failure:5"
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/onfail.yaml" _binds
  run grep -E '^    restart:' "${_d}/onfail.yaml"
  assert_output '    restart: "on-failure:5"'
  rm -rf "${_d}"
}

@test "_generate_resolved_compose: a malformed [lifecycle] restart falls back to the field default (#840)" {
  # apply does no schema revalidation, so a hand-edited conf can feed a
  # bogus policy here; it must not reach `docker compose up`.
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[lifecycle]" "restart = bogus"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run grep -E '^    restart:' "${_d}/compose.yaml"
  assert_output "    restart: unless-stopped"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_launcher -- the thin up/down/logs deploy.sh.
# No inlined docker flags; loads the image + drives compose. chmod +x,
# ShellCheck-clean.
# ════════════════════════════════════════════════════════════════════

# why: launcher shape
@test "_generate_deploy_launcher: writes an executable up/down/logs launcher (#832)" {
  local _d; _d="$(mktemp -d)"
  local _out="${_d}/deploy.sh"
  _generate_deploy_launcher "${_out}" runtime
  [ -x "${_out}" ]
  run cat "${_out}"
  assert_output --partial "/usr/bin/env bash"
  assert_output --partial "set -euo pipefail"
  assert_output --partial "docker load"
  assert_output --partial "docker compose up -d"
  assert_output --partial "docker compose down"
  assert_output --partial "docker compose logs"
  # No inlined docker run flags (the compose carries everything).
  refute_output --partial "docker run"
  rm -rf "${_d}"
}

# why: no-arg default up
@test "_generate_deploy_launcher: a no-arg invocation defaults to up without a set -e early exit (#832)" {
  # Regression: the launcher runs under `set -euo pipefail`; a `[[ $# -gt 0 ]]
  # && shift` guard returns non-zero on the no-arg (default `up`) path and
  # would abort before compose. Prove no-arg reaches `compose up -d`.
  local _d; _d="$(mktemp -d)"
  local _bundle="${_d}/bundle"; mkdir -p "${_bundle}"
  _generate_deploy_launcher "${_bundle}/deploy.sh" runtime
  local _shim="${_d}/bin"; mkdir -p "${_shim}"
  cat > "${_shim}/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_LOG}"
exit 0
SH
  chmod +x "${_shim}/docker"
  export DOCKER_LOG="${_d}/log"
  export PATH="${_shim}:${PATH}"
  # No image.tar.xz -> load is skipped; no args -> defaults to up.
  run bash "${_bundle}/deploy.sh"
  assert_success
  run cat "${_d}/log"
  assert_output --partial "docker compose up -d"
  rm -rf "${_d}"
}

# why: shellcheck-clean output
@test "_generate_deploy_launcher: generated launcher is ShellCheck-clean (#832)" {
  # Optional on purpose: shellcheck is a capability of the TOOLING
  # IMAGE, not an artifact of this repo, so a pinned TEST_TOOLS_IMAGE
  # without it can only decline to look. Losing it from the image is
  # covered fail-closed instead: template_spec asserts the final stage
  # COPYs the binary in.
  command -v shellcheck >/dev/null 2>&1 \
    || skip "this test-tools image has no shellcheck (older pinned TEST_TOOLS_IMAGE); the COPY that installs it is pinned in template_spec"
  local _d; _d="$(mktemp -d)"
  local _out="${_d}/deploy.sh"
  _generate_deploy_launcher "${_out}" runtime
  run shellcheck "${_out}"
  assert_success
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _collect_config_components / _bake_config_copy -- the deploy half of
# the config/<component>/ channel, generalised over the component name.
#
# One derivation feeds BOTH halves: the dev bind in setup_cmd.sh and the
# COPY bake here read the same `config/*/` glob, so a repo can never be
# mounted in dev and left unbaked at deploy (PRD invariant 8's "opposite
# means" only holds if the two agree on the population).
# ════════════════════════════════════════════════════════════════════

# why: component population
@test "_collect_config_components: names every config/*/ dir, sorted" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/ros1_bridge" "${_d}/config/realsense" "${_d}/config/shell"
  local -a _got=()
  _collect_config_components "${_d}" _got
  [[ "${_got[*]}" == "realsense ros1_bridge shell" ]]
  rm -rf "${_d}"
}

# why: dir-only discriminator
@test "_collect_config_components: skips files and hidden entries" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense"
  : > "${_d}/config/params_ether.yaml"
  : > "${_d}/config/.gitkeep"
  mkdir -p "${_d}/config/.hidden"
  local -a _got=()
  _collect_config_components "${_d}" _got
  [[ "${_got[*]}" == "realsense" ]]
  rm -rf "${_d}"
}

# why: empty population
@test "_collect_config_components: empty result on a repo with no config/" {
  local _d; _d="$(mktemp -d)"
  local -a _got=(stale)
  _collect_config_components "${_d}" _got
  (( ${#_got[@]} == 0 ))
  rm -rf "${_d}"
}

# why: config COPY bake
@test "_bake_config_copy: splices COPY config/<component> into the target stage (#506/#504/#1000)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/out" "${_d}"
  run cat "${_d}/out"
  assert_output --partial "COPY config/realsense /opt/app/config/realsense"
  local _from _copy _cmd
  _from="$(grep -n 'AS runtime' "${_d}/out" | head -1 | cut -d: -f1)"
  _copy="$(grep -n 'COPY config/realsense' "${_d}/out" | head -1 | cut -d: -f1)"
  _cmd="$(grep -n 'CMD' "${_d}/out" | head -1 | cut -d: -f1)"
  (( _from < _copy )) && (( _copy < _cmd ))
  rm -rf "${_d}"
}

# why: in-place bake
@test "_bake_config_copy: handles src == out in place (#506/#504/#1000)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS runtime
CMD ["/app"]
DOCK
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/Dockerfile" "${_d}"
  run cat "${_d}/Dockerfile"
  assert_output --partial "COPY config/realsense /opt/app/config/realsense"
  assert_output --partial "FROM scratch AS runtime"
  rm -rf "${_d}"
}

# why: per-component target
@test "_bake_config_copy: bakes every component to its own destination (#1000)" {
  # Two components, two COPY lines, two distinct targets. The old code
  # had ONE hardcoded COPY into ONE destination, so a second component
  # had nowhere to go; the derivation <root>/<dirname> gives each its own
  # and, being a function of a sibling's name, can never collide.
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense" "${_d}/config/ros1_bridge"
  printf 'FROM scratch AS runtime\nCMD ["/app"]\n' > "${_d}/Dockerfile"
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/out" "${_d}"
  run cat "${_d}/out"
  assert_output --partial "COPY config/realsense /opt/app/config/realsense"
  assert_output --partial "COPY config/ros1_bridge /opt/app/config/ros1_bridge"
  rm -rf "${_d}"
}

# why: no name list
@test "_bake_config_copy: bakes config/shell and config/pip too (#1000)" {
  # Same decision as the dev-bind half, pinned on the deploy side so the
  # two cannot drift apart: no name list, so the two build-time dirs come
  # along. They land at /opt/app/config/<x>, which nothing in the image
  # reads, and their build-time use (/tmp/config, deleted in the same RUN)
  # is over before the field container exists.
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/shell" "${_d}/config/pip"
  printf 'FROM scratch AS runtime\nCMD ["/app"]\n' > "${_d}/Dockerfile"
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/out" "${_d}"
  run cat "${_d}/out"
  assert_output --partial "COPY config/shell /opt/app/config/shell"
  assert_output --partial "COPY config/pip /opt/app/config/pip"
  rm -rf "${_d}"
}

# why: nothing-to-bake
@test "_bake_config_copy: returns 1 and writes nothing when no component dir exists (#1000)" {
  # The "nothing to bake" non-result, matching its sibling
  # _generate_runtime_dockerfile: return 1, leave <out> alone, and let the
  # caller keep building from the plain Dockerfile. The guard is not
  # widened to fail-open -- the caller reports the empty case out loud.
  local _d; _d="$(mktemp -d)"
  printf 'FROM scratch AS runtime\nCMD ["/app"]\n' > "${_d}/Dockerfile"
  run _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/out" "${_d}"
  assert_failure
  refute [ -e "${_d}/out" ]
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _collect_preset_selectors / the selector half of _report_config_components
# -- how a repo says WHICH of its curated presets is the one it bakes
# (ADR-00000030).
#
# The population is derived, never listed: a selector is a repo-root
# SYMLINK whose link text names a path under config/. That is what
# separates it from base's own root symlinks (justfile, .hadolint.yaml ->
# .base/...), and it needs no filename convention to do it. The collector
# reports what the tree claims; deciding whether the claim resolves is the
# reporter's job, because a dangling selector is a docker build that dies
# on COPY with a message naming neither the symlink nor the preset.
# ════════════════════════════════════════════════════════════════════

# why: selector derivation
@test "_collect_preset_selectors: a root symlink into config/ is a selector, other root symlinks are not (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense/yaml" "${_d}/.base/script/docker"
  : > "${_d}/config/realsense/yaml/none.yaml"
  : > "${_d}/.base/script/docker/justfile"
  ln -s config/realsense/yaml/none.yaml "${_d}/camera.yaml"
  ln -s .base/script/docker/justfile "${_d}/justfile"
  : > "${_d}/README.md"
  local -a _names=() _targets=()
  _collect_preset_selectors "${_d}" _names _targets
  [[ "${_names[*]}" == "camera.yaml" ]]
  [[ "${_targets[*]}" == "config/realsense/yaml/none.yaml" ]]
  rm -rf "${_d}"
}

# why: dangling is collected, not hidden
@test "_collect_preset_selectors: collects a selector whose target does not exist (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense/yaml"
  ln -s config/realsense/yaml/gone.yaml "${_d}/camera.yaml"
  local -a _names=() _targets=()
  _collect_preset_selectors "${_d}" _names _targets
  [[ "${_names[*]}" == "camera.yaml" ]]
  rm -rf "${_d}"
}

# why: link-text normalisation
@test "_collect_preset_selectors: a ./-prefixed link text is the same selector (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/jetson"
  : > "${_d}/config/jetson/agx-orin-emmc.yaml"
  ln -s ./config/jetson/agx-orin-emmc.yaml "${_d}/jetson.yaml"
  local -a _names=() _targets=()
  _collect_preset_selectors "${_d}" _names _targets
  [[ "${_targets[*]}" == "config/jetson/agx-orin-emmc.yaml" ]]
  rm -rf "${_d}"
}

# why: empty population
@test "_collect_preset_selectors: a repo with no selector yields nothing (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/ros1_bridge"
  : > "${_d}/config/ros1_bridge/demo_bridge.yaml"
  local -a _names=(stale) _targets=(stale)
  _collect_preset_selectors "${_d}" _names _targets
  (( ${#_names[@]} == 0 ))
  (( ${#_targets[@]} == 0 ))
  rm -rf "${_d}"
}

# why: which preset is live
@test "_report_config_components: states which preset each selector currently selects (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense/yaml"
  : > "${_d}/config/realsense/yaml/none.yaml"
  ln -s config/realsense/yaml/none.yaml "${_d}/camera.yaml"
  LOG_FORMAT=json run _report_config_components "${_d}" realsense
  assert_output --partial '"body":"config_preset_selected"'
  assert_output --partial 'camera.yaml -> config/realsense/yaml/none.yaml'
  rm -rf "${_d}"
}

# why: dangling selector named
@test "_report_config_components: WARNs a selector whose preset is missing (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense/yaml"
  ln -s config/realsense/yaml/gone.yaml "${_d}/camera.yaml"
  LOG_FORMAT=json run _report_config_components "${_d}" realsense
  assert_output --partial '"body":"config_preset_dangling"'
  assert_output --partial 'camera.yaml'
  rm -rf "${_d}"
}

# why: silence when there is no selector
@test "_report_config_components: says nothing about presets when the repo has no selector (#826)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/realsense"
  LOG_FORMAT=json run _report_config_components "${_d}" realsense
  refute_output --partial 'config_preset_selected'
  refute_output --partial 'config_preset_dangling'
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_bundle -- the folder orchestrator. Docker / xz /
# cp steps run through _dry_run_cmd, so DRY_RUN=true asserts the plan
# without a real daemon.
# ════════════════════════════════════════════════════════════════════

_write_deploy_repo() {
  local _dir="${1}"
  mkdir -p "${_dir}"
  printf '%s\n' "[deploy]" "gpu_mode = off" "dri_groups = off" "[gui]" "mode = off" \
    "[environment]" "env_1 = ROS_DOMAIN_ID=42" \
    "[security]" "privileged = true" > "${_dir}/.setup.conf"
  cat > "${_dir}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
}

# why: bundle plan
@test "_generate_deploy_bundle: dry-run plans build (versioned image) + save + xz + install (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  local _out_dir="${_d}/deploy/out"
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_out_dir}"
  unset DRY_RUN
  assert_success
  # Image tagged <repo>:<stage>-<version> (version from git describe;
  # `unknown` outside a git tree here).
  assert_output --partial "docker build --target runtime"
  assert_output --partial ":runtime-"
  assert_output --partial "docker save"
  assert_output --partial "xz -f"
  assert_output --partial "mkdir -p ${_out_dir}"
  assert_output --partial "cp -a"
  # No tar.xz single-file bundle anymore.
  refute_output --partial "-cJf"
  rm -rf "${_d}"
}

# why: env-bake build
@test "_generate_deploy_bundle: dry-run builds from the baked Dockerfile when [environment] is set (#832/#503)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_d}/deploy/out"
  unset DRY_RUN
  assert_success
  assert_output --partial "Dockerfile.deploy"
  rm -rf "${_d}"
}

# why: tunable extract
@test "_generate_deploy_bundle: dry-run plans a docker cp per tunable-manifest path (#833)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  mkdir -p "${_d}/config/camera"
  printf '%s\n' "[runtime]" "/camera_config.yaml" > "${_d}/config/camera/deploy.manifest"
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_d}/deploy/out"
  unset DRY_RUN
  assert_success
  assert_output --partial "docker create"
  assert_output --partial "docker cp"
  assert_output --partial ":/camera_config.yaml"
  rm -rf "${_d}"
}

# why: fail-loud guard
@test "_generate_deploy_bundle: a malformed manifest fails loud before building (#833)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  mkdir -p "${_d}/config/camera"
  printf '%s\n' "[runtime]" "not-absolute" > "${_d}/config/camera/deploy.manifest"
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_d}/deploy/out"
  unset DRY_RUN
  assert_failure
  refute_output --partial "docker build"
  rm -rf "${_d}"
}

# why: missing baked default
@test "_generate_deploy_bundle: fails loud when the image bakes no file at a declared tunable path (#833)" {
  # The baked-default + mount-wins model requires the image to bake a FILE at
  # each manifest path; a bind whose target is missing fails at up with a
  # cryptic runc mount error. Prove the generator catches it at build time
  # with a clear message. docker cp is shimmed to fail (image lacks the path).
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  mkdir -p "${_d}/config/camera"
  printf '%s\n' "[runtime]" "/etc/app/missing.yaml" \
    > "${_d}/config/camera/deploy.manifest"
  local _shim="${_d}/bin"; mkdir -p "${_shim}"
  cat > "${_shim}/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  save) shift; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && : > "$2"; shift; done; exit 0 ;;
  cp) exit 1 ;;   # image bakes no file at the declared path
  *) exit 0 ;;
esac
SH
  chmod +x "${_shim}/docker"
  cat > "${_shim}/xz" <<'SH'
#!/usr/bin/env bash
_f=""; for _a in "$@"; do _f="${_a}"; done
[[ -f "${_f}" ]] && mv "${_f}" "${_f}.xz"; exit 0
SH
  chmod +x "${_shim}/xz"
  export PATH="${_shim}:${PATH}"
  # Real run (not DRY_RUN) so the extraction + existence check actually fire.
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_d}/deploy/out"
  assert_failure
  assert_output --partial "bakes no file"
  assert_output --partial "/etc/app/missing.yaml"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_deploy -- the `setup.sh deploy` subcommand: resolved-compose
# preview + confirmation + _generate_deploy_bundle (folder output).
# ════════════════════════════════════════════════════════════════════

# why: deploy dry-run
@test "_setup_deploy: --dry-run previews the resolved compose + prints the build plan (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_success
  assert_output --partial "deploy plan: stage=runtime"
  assert_output --partial "resolved compose.yaml to be generated"
  assert_output --partial "restart: unless-stopped"
  assert_output --partial "docker build --target runtime"
  assert_output --partial "docker save"
  rm -rf "${_d}"
}

# why: preview matches the bundle
@test "_setup_deploy: the preview shows each tunable bind at its declared access (#870)" {
  # The preview is what the operator reviews before agreeing to build, so it
  # has to carry the same access modes the generated bundle will.
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  mkdir -p "${_d}/config/app_cfg"
  printf '%s\n' "[runtime]" "/etc/app/host.yaml" "/var/lib/app/calib.yaml rw" \
    > "${_d}/config/app_cfg/deploy.manifest"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_success
  assert_output --partial "- ./config/host.yaml:/etc/app/host.yaml:ro"
  assert_output --partial "- ./config/calib.yaml:/var/lib/app/calib.yaml:rw"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# .setup.conf.local and the field bundle (PRD invariant: an artifact
# built for the field must not silently depend on a config layer that is
# not under version control)
#
# The refusal is the default because the failure it prevents is silent and
# remote: a bundle whose values came from a gitignored file cannot be
# reproduced from a clean checkout, and nothing about the bundle would say
# so. The escape hatch exists because there are legitimate one-off field
# builds; what it must never be is quiet.
# ════════════════════════════════════════════════════════════════════

@test "_setup_deploy: refuses while .setup.conf.local is present (#893)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  printf '[gui]\nmode = force\n' > "${_d}/.setup.conf.local"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_failure
  assert_output --partial ".setup.conf.local"
  assert_output --partial "gui"
  assert_output --partial "--allow-local-override"
  rm -rf "${_d}"
}

@test "_setup_deploy: --allow-local-override proceeds and says what it accepted (#893)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  printf '[gui]\nmode = force\n' > "${_d}/.setup.conf.local"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run \
    --allow-local-override
  assert_success
  assert_output --partial "deploy plan: stage=runtime"
  assert_output --partial ".setup.conf.local"
  rm -rf "${_d}"
}

@test "_setup_deploy: no refusal when there is no local override (#893)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_success
  refute_output --partial ".setup.conf.local"
  rm -rf "${_d}"
}

@test "_render_deploy_readme: records the untracked sections a bundle was built from (#893)" {
  local _d; _d="$(mktemp -d)"
  _render_deploy_readme "${_d}/README" myrepo runtime myrepo:runtime-v1 "gui network"
  run cat "${_d}/README"
  assert_success
  assert_output --partial ".setup.conf.local"
  assert_output --partial "gui, network"
  rm -rf "${_d}"
}

@test "_render_deploy_readme: says nothing about local overrides when there were none (#893)" {
  local _d; _d="$(mktemp -d)"
  _render_deploy_readme "${_d}/README" myrepo runtime myrepo:runtime-v1 ""
  run cat "${_d}/README"
  assert_success
  refute_output --partial ".setup.conf.local"
  rm -rf "${_d}"
}

@test "_generate_deploy_bundle: hands the untracked sections to the bundle README (#893)" {
  # The generator, not the subcommand, is what puts the record in the
  # artifact -- so the record survives any other entry point into a bundle.
  # Probed at the seam because the bundle is only assembled for real when
  # docker runs, and this suite never invokes a daemon.
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  printf '[gui]\nmode = force\n[network]\nmode = bridge\n' \
    > "${_d}/.setup.conf.local"
  README_PROBE="${_d}/readme-sections"
  _render_deploy_readme() { printf '%s\n' "${5-}" > "${README_PROBE}"; : > "${1}"; }
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_bundle "${_d}" "runtime" "${_d}/out"
  unset DRY_RUN
  run cat "${README_PROBE}"
  assert_success
  assert_output "gui network"
  rm -rf "${_d}"
}

# why: non-tty refuse
@test "_setup_deploy: refuses in a non-interactive shell without -y (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}"
  assert_failure
  assert_output --partial "non-interactive shell"
  rm -rf "${_d}"
}

# why: no-Dockerfile guard
@test "_setup_deploy: errors when the repo has no Dockerfile (#832)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}"
  printf '%s\n' "[deploy]" "gpu_mode = off" > "${_d}/.setup.conf"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_failure
  assert_output --partial "no Dockerfile"
  rm -rf "${_d}"
}

# why: arg validation
@test "_setup_deploy: rejects an unknown flag (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --bogus
  assert_failure
  rm -rf "${_d}"
}

# why: stage select
@test "_setup_deploy: --stage selects the target stage (#832/#841)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  # A second deployable stage, so the assertion proves --stage steers the
  # build target rather than re-asserting the `runtime` default.
  printf '%s\n' "FROM runtime AS field" 'CMD ["/app"]' >> "${_d}/Dockerfile"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage field --dry-run
  assert_success
  assert_output --partial "deploy plan: stage=field"
  assert_output --partial "docker build --target field"
  rm -rf "${_d}"
}

# ── Stage eligibility: `deployable = not devel and not *-test` ──────────
# (ADR-00000023 sec.4 / PRD invariant 8), enforced in _setup_deploy via
# the shared _is_deployable_stage predicate.

# why: stage eligibility (baseline)
@test "_setup_deploy: refuses a template-baseline stage (#841)" {
  local _d _s
  for _s in sys devel-base devel devel-test runtime-test; do
    _d="$(mktemp -d)"
    _write_deploy_repo "${_d}"
    SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage "${_s}" --dry-run
    assert_failure
    assert_output --partial "not a deployable stage"
    assert_output --partial "${_s}"
    refute_output --partial "docker build"
    rm -rf "${_d}"
  done
}

# why: stage eligibility (legacy alias)
@test "_setup_deploy: refuses a legacy baseline alias (#841)" {
  local _d _s
  for _s in base test; do
    _d="$(mktemp -d)"
    _write_deploy_repo "${_d}"
    SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage "${_s}" --dry-run
    assert_failure
    assert_output --partial "not a deployable stage"
    refute_output --partial "docker build"
    rm -rf "${_d}"
  done
}

# why: stage eligibility (*-test)
@test "_setup_deploy: refuses a downstream-shaped <x>-test stage (#841)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  printf '%s\n' "FROM runtime AS field-test" 'CMD ["/run-tests"]' >> "${_d}/Dockerfile"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage field-test --dry-run
  assert_failure
  assert_output --partial "not a deployable stage"
  refute_output --partial "docker build"
  rm -rf "${_d}"
}

# why: guard fires before build
@test "_setup_deploy: a refused stage writes no bundle even with -y (#841)" {
  # -y skips the confirmation prompt, so this is the shape that would have
  # produced a real field bundle from a devel image. The guard must fire
  # before any build / bundle step.
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage devel -y
  unset DRY_RUN
  assert_failure
  refute_output --partial "docker build"
  refute_output --partial "docker save"
  refute [ -d "${_d}/deploy" ]
  rm -rf "${_d}"
}

# why: dispatch wiring
@test "main deploy routes to _setup_deploy (#832 dispatch)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run main deploy --base-path "${_d}" --dry-run
  assert_success
  assert_output --partial "deploy plan: stage=runtime"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: warns when the legacy [deploy] runtime key is present but shadowed (#876)" {
  # Same rule the per-stage layer follows: gpu_runtime is authoritative,
  # and the deprecated key is reported whenever it is still in the conf
  # -- otherwise a half-finished migration is invisible on both paths.
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_runtime = off" "runtime = nvidia"
  local -A _ctx=()
  LOG_FORMAT=json run _resolve_deploy_context "${_d}" _ctx
  assert_success
  assert_output --partial '"body":"conf_runtime_key_deprecated"'
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_runtime_mode]}" "off"
  rm -rf "${_d}"
}
