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
  assert_equal "${_ctx[restart_policy]}" "no"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode (#506/#481)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "runtime = nvidia"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_runtime_mode]}" "nvidia"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: dri_groups auto resolves host GIDs via the SETUP_DETECT_DRI_GROUPS operator override (#506/#496)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "dri_groups = auto"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44 110" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" "44 110"
  rm -rf "${_d}"
}

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
  # No build section / env_file / setup.conf dependency travels.
  refute_output --partial "build:"
  refute_output --partial "env_file"
  rm -rf "${_d}"
}

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

@test "_generate_resolved_compose: binds each tunable-manifest file mount-wins over the baked default (#833)" {
  local _d; _d="$(mktemp -d)"
  _write_headless_conf "${_d}"
  local _out="${_d}/compose.yaml"
  local -A _binds=([host.yaml]="/etc/app/host.yaml" [camera.yaml]="/camera_config.yaml")
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_out}" _binds
  run cat "${_out}"
  assert_output --partial "volumes:"
  assert_output --partial "- ./config/host.yaml:/etc/app/host.yaml"
  assert_output --partial "- ./config/camera.yaml:/camera_config.yaml"
  rm -rf "${_d}"
}

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

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_launcher -- the thin up/down/logs deploy.sh.
# No inlined docker flags; loads the image + drives compose. chmod +x,
# ShellCheck-clean.
# ════════════════════════════════════════════════════════════════════

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

@test "_generate_deploy_launcher: generated launcher is ShellCheck-clean (#832)" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  local _d; _d="$(mktemp -d)"
  local _out="${_d}/deploy.sh"
  _generate_deploy_launcher "${_out}" runtime
  run shellcheck "${_out}"
  assert_success
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _bake_config_copy -- splice COPY config/app into the target
# stage of the deploy Dockerfile.
# ════════════════════════════════════════════════════════════════════

@test "_bake_config_copy: splices COPY config/app into the target stage (#506/#504)" {
  local _d; _d="$(mktemp -d)"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/out"
  run cat "${_d}/out"
  assert_output --partial "COPY config/app /opt/app/config"
  local _from _copy _cmd
  _from="$(grep -n 'AS runtime' "${_d}/out" | head -1 | cut -d: -f1)"
  _copy="$(grep -n 'COPY config/app' "${_d}/out" | head -1 | cut -d: -f1)"
  _cmd="$(grep -n 'CMD' "${_d}/out" | head -1 | cut -d: -f1)"
  (( _from < _copy )) && (( _copy < _cmd ))
  rm -rf "${_d}"
}

@test "_bake_config_copy: handles src == out in place (#506/#504)" {
  local _d; _d="$(mktemp -d)"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS runtime
CMD ["/app"]
DOCK
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/Dockerfile"
  run cat "${_d}/Dockerfile"
  assert_output --partial "COPY config/app /opt/app/config"
  assert_output --partial "FROM scratch AS runtime"
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

# ════════════════════════════════════════════════════════════════════
# _setup_deploy -- the `setup.sh deploy` subcommand: resolved-compose
# preview + confirmation + _generate_deploy_bundle (folder output).
# ════════════════════════════════════════════════════════════════════

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

@test "_setup_deploy: refuses in a non-interactive shell without -y (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}"
  assert_failure
  assert_output --partial "non-interactive shell"
  rm -rf "${_d}"
}

@test "_setup_deploy: errors when the repo has no Dockerfile (#832)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}"
  printf '%s\n' "[deploy]" "gpu_mode = off" > "${_d}/.setup.conf"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_failure
  assert_output --partial "no Dockerfile"
  rm -rf "${_d}"
}

@test "_setup_deploy: rejects an unknown flag (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --bogus
  assert_failure
  rm -rf "${_d}"
}

@test "_setup_deploy: --stage selects the target stage (#832)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage devel --dry-run
  assert_success
  assert_output --partial "docker build --target devel"
  rm -rf "${_d}"
}

@test "main deploy routes to _setup_deploy (#832 dispatch)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run main deploy --base-path "${_d}" --dry-run
  assert_success
  assert_output --partial "deploy plan: stage=runtime"
  rm -rf "${_d}"
}
