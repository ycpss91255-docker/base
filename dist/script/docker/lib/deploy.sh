#!/usr/bin/env bash
#
# deploy.sh - field deploy.sh generator + the shared deploy-context resolver.
#
# Provides:
#   _emit_docker_run_flags    : resolved flag record -> `docker run` argv fragment
#   _resolve_deploy_context   : setup.conf -> the conf-derived resolution shared
#                               by `apply` (compose) and the deploy generator
#   _generate_deploy_sh       : write the self-contained field launcher
#   _bake_config_copy         : COPY structured config into the runtime stage
#   _generate_deploy_bundle   : build --target -> docker save -> tar.xz bundle
#   _expand_env_cross_refs    : expand ${VAR} cross-refs in env values
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). These call
# into setup.sh-resident deps (_setup_conf_handle, _resolve_build_network,
# _detect_dri_groups, _setup_msg, the _SETUP_SCRIPT_DIR global) and conf.sh
# accessors (_conf_get_into / _conf_list_sorted); all resolve at call-time via
# the _lib.sh load order, so this lib does not re-source them.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_DEPLOY_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_DEPLOY_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# _emit_docker_run_flags <flags_assoc> <out_array>
#
# S6 ofmap a resolved docker-flag record to a `docker run`
# argv fragment for the self-contained field launcher (`deploy.sh`). The
# deploy generator resolves the chosen stage's flags through the S5
# layer (_resolve_docker_flags) and merges in the top-level-only fields,
# then calls this to turn that record into runnable `docker run` args.
#
# <flags_assoc> recognised keys (all optional; absent = unset):
#   privileged          "true" -> --privileged
#   gpu / gpu_count / gpu_caps
#                       gpu="true" -> --gpus (count>0 -> count=N[,capabilities=csv];
#                       else "all")
#   runtime             non-empty & not off/auto -> --runtime=<v>
#   net_mode / net_name host -> --network=host; bridge+name -> --network=<name>
#   ipc_mode            non-empty & != private -> --ipc=<v>
#   pid_mode            host -> --pid=host
#   shm_size            set & ipc_mode != host -> --shm-size=<v>
#   restart             set & != no -> --restart=<v>
#   volumes (nl list)   each -> -v <entry>
#   ports (nl list)     each -> -p <entry>  (only when net_mode=bridge)
#   devices (nl list)   plain -> --device <entry>; entry with a propagation
#                       mode (rslave/rshared/...) -> -v <entry> (docker run
#                       --device has no propagation, mirroring compose)
#   cap_add (nl list)   each -> --cap-add <cap>
#   cap_drop (nl list)  each -> --cap-drop <cap>
#   security_opt (nl)   each -> --security-opt <opt>
#   dri_groups (space)  each gid -> --group-add <gid>
#   cgroup_rules (nl)   each -> --device-cgroup-rule <rule>
#
# Deliberately NOT mapped: [environment] (baked into the image as ENV by
# S3, so the launcher carries only docker-level flags) and gui / X11 (the
# field launcher targets headless run; GUI is a dev-only compose concern).
# Each flag and its value are pushed as SEPARATE array elements so the
# caller can quote them individually when writing deploy.sh.
# ════════════════════════════════════════════════════════════════════
_emit_docker_run_flags() {
  local -n _edrf_f="${1:?"${FUNCNAME[0]}: missing flags assoc"}"
  local -n _edrf_out="${2:?"${FUNCNAME[0]}: missing out array"}"
  local _item

  # Push "<flag> <item>" for each non-empty line of a newline-list value.
  _edrf_push_list() {
    local _flag="${1}" _list="${2}"
    [[ -n "${_list}" ]] || return 0
    while IFS= read -r _item; do
      [[ -n "${_item}" ]] || continue
      _edrf_out+=("${_flag}" "${_item}")
    done <<< "${_list}"
  }

  [[ "${_edrf_f["privileged"]:-}" == "true" ]] && _edrf_out+=("--privileged")

  if [[ "${_edrf_f["gpu"]:-}" == "true" ]]; then
    local _gc="${_edrf_f["gpu_count"]:-}" _gcaps="${_edrf_f["gpu_caps"]:-}" _spec
    if [[ "${_gc}" =~ ^[0-9]+$ ]] && (( _gc > 0 )); then
      _spec="count=${_gc}"
      [[ -n "${_gcaps}" ]] && _spec+=",capabilities=${_gcaps// /,}"
    else
      _spec="all"
    fi
    _edrf_out+=("--gpus" "${_spec}")
  fi

  local _rt="${_edrf_f["runtime"]:-}"
  if [[ -n "${_rt}" && "${_rt}" != "off" && "${_rt}" != "auto" ]]; then
    _edrf_out+=("--runtime=${_rt}")
  fi

  local _nm="${_edrf_f["net_mode"]:-}" _nn="${_edrf_f["net_name"]:-}"
  if [[ "${_nm}" == "host" ]]; then
    _edrf_out+=("--network=host")
  elif [[ "${_nm}" == "bridge" && -n "${_nn}" ]]; then
    _edrf_out+=("--network=${_nn}")
  fi

  local _ipc="${_edrf_f["ipc_mode"]:-}"
  [[ -n "${_ipc}" && "${_ipc}" != "private" ]] && _edrf_out+=("--ipc=${_ipc}")

  [[ "${_edrf_f["pid_mode"]:-}" == "host" ]] && _edrf_out+=("--pid=host")

  local _shm="${_edrf_f["shm_size"]:-}"
  [[ -n "${_shm}" && "${_ipc}" != "host" ]] && _edrf_out+=("--shm-size=${_shm}")

  local _rs="${_edrf_f["restart"]:-}"
  [[ -n "${_rs}" && "${_rs}" != "no" ]] && _edrf_out+=("--restart=${_rs}")

  _edrf_push_list "-v" "${_edrf_f["volumes"]:-}"

  if [[ "${_nm}" == "bridge" ]]; then
    _edrf_push_list "-p" "${_edrf_f["ports"]:-}"
  fi

  # Devices: a propagation mode in the 3rd colon field cannot ride on
  # `docker run --device`, so route those to `-v` (mirrors the compose
  # device->volume redirect from); plain devices stay on --device.
  local _dev
  if [[ -n "${_edrf_f["devices"]:-}" ]]; then
    while IFS= read -r _dev; do
      [[ -n "${_dev}" ]] || continue
      if [[ "${_dev}" =~ :(rslave|rshared|rprivate|slave|shared|private)([,:]|$) ]]; then
        _edrf_out+=("-v" "${_dev}")
      else
        _edrf_out+=("--device" "${_dev}")
      fi
    done <<< "${_edrf_f["devices"]}"
  fi

  _edrf_push_list "--cap-add" "${_edrf_f["cap_add"]:-}"
  _edrf_push_list "--cap-drop" "${_edrf_f["cap_drop"]:-}"
  _edrf_push_list "--security-opt" "${_edrf_f["security_opt"]:-}"

  local _gid
  if [[ -n "${_edrf_f["dri_groups"]:-}" ]]; then
    for _gid in ${_edrf_f["dri_groups"]}; do
      _edrf_out+=("--group-add" "${_gid}")
    done
  fi

  _edrf_push_list "--device-cgroup-rule" "${_edrf_f["cgroup_rules"]:-}"

  unset -f _edrf_push_list
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_context <base_path> <out_assoc>
#
# S6b ofthe single conf-derived resolution layer shared by
# `apply` (the compose renderer) and the deploy generator. Loads the
# relevant setup.conf sections from <base_path> and resolves the
# scalar modes + aggregated list strings that both paths consume, into
# <out_assoc>. This is the global counterpart to the per-stage
# _resolve_docker_flags (S5): apply unpacks the record into its existing
# locals, and the deploy generator (S6b-gen) feeds it as the parent for
# the runtime stage. Keeping one resolver means the field deploy can
# never drift from what `apply` would produce for the same setup.conf.
#
# Pure resolution: it does NOT apply the `--gui` CLI / SETUP_GUI env
# override (apply layers that on top of the returned gui_mode), it does
# NOT resolve the detection-dependent enabled booleans (callers run
# _resolve_gpu / _resolve_gui with their own host detection), and it does
# NOT touch the WS_PATH / mount_1 migration or the device/volume
# validation warnings (those stay apply-side -- dev-specific side
# effects). The one intrinsic side effect kept here is the legacy
# `[deploy] runtime` deprecation warning, since it is tied to
# resolving gpu_runtime from the conf.
#
# Populated keys: build_network gpu_mode gpu_count gpu_caps
#   gpu_runtime_mode gui_mode net_mode ipc_mode pid_mode network_name
#   privileged restart_policy dri_groups_str devices_str cgroup_rule_str
#   env_str tmpfs_str ports_str cap_add_str cap_drop_str sec_opt_str
#   shm_size  (assoc subscripts quoted so ShellCheck does not read them
#   as arithmetic refs (SC2154) -- the out-param is a nameref).
# ════════════════════════════════════════════════════════════════════
_resolve_deploy_context() {
  local _rdc_base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _rdc_out="${2:?"${FUNCNAME[0]}: missing out assoc"}"

  # Parse the section-replace-merged conf ONCE into an opaque handle, then read
  # every scalar/list from it -- replacing the former 10x per-section
  # _load_setup_conf re-parse (each call re-tokenized the whole conf). Same
  # merge precedence + SETUP_CONF override (ADR-00000008 follow-up).
  _setup_conf_handle "${_rdc_base}" _RDC_CONF

  local _tmp=""

  # build-time network (scalar [build] network; auto -> host on Jetson).
  local _build_network_mode="" _build_network=""
  _conf_get_into _RDC_CONF build network auto _build_network_mode
  _resolve_build_network "${_build_network_mode}" _build_network
  _rdc_out["build_network"]="${_build_network}"

  # [deploy] GPU family.
  _conf_get_into _RDC_CONF deploy gpu_mode         auto _tmp; _rdc_out["gpu_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF deploy gpu_count        all  _tmp; _rdc_out["gpu_count"]="${_tmp}"
  _conf_get_into _RDC_CONF deploy gpu_capabilities gpu  _tmp; _rdc_out["gpu_caps"]="${_tmp}"
  # gpu_runtime is the canonical key; legacy `runtime` is a permanent
  # alias (W3) consumed with a deprecation warning, removed at v1.0.0.
  local _gpu_runtime_mode=""
  _conf_get_into _RDC_CONF deploy gpu_runtime "" _gpu_runtime_mode
  if [[ -z "${_gpu_runtime_mode}" ]]; then
    local _legacy_runtime=""
    _conf_get_into _RDC_CONF deploy runtime "" _legacy_runtime
    if [[ -n "${_legacy_runtime}" ]]; then
      _gpu_runtime_mode="${_legacy_runtime}"
      _log_warn setup conf_runtime_key_deprecated \
        "display=$(_setup_msg deploy runtime_deprecated)"
    else
      _gpu_runtime_mode="auto"
    fi
  fi
  _rdc_out["gpu_runtime_mode"]="${_gpu_runtime_mode}"

  # [gui] mode (conf only -- caller layers the --gui / SETUP_GUI override).
  _conf_get_into _RDC_CONF gui mode auto _tmp; _rdc_out["gui_mode"]="${_tmp}"

  # [network] + [security] scalars.
  _conf_get_into _RDC_CONF network mode         host    _tmp; _rdc_out["net_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF network ipc          host    _tmp; _rdc_out["ipc_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF network pid          private _tmp; _rdc_out["pid_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF network network_name ""      _tmp; _rdc_out["network_name"]="${_tmp}"
  # privileged opt-in -- default false when the key is absent.
  _conf_get_into _RDC_CONF security privileged  false   _tmp; _rdc_out["privileged"]="${_tmp}"

  # [lifecycle] restart policy (default no).
  _conf_get_into _RDC_CONF lifecycle restart no _tmp; _rdc_out["restart_policy"]="${_tmp}"

  # dri_groups (non-NVIDIA iGPU /dev/dri); auto -> detect host GIDs.
  local _dri_groups_mode="" _dri_groups_str=""
  _conf_get_into _RDC_CONF deploy dri_groups auto _dri_groups_mode
  [[ "${_dri_groups_mode}" == "auto" ]] && _dri_groups_str="$(_detect_dri_groups)"
  _rdc_out["dri_groups_str"]="${_dri_groups_str}"

  # [devices] device_* + cgroup_rule_*.
  local -a _devices_arr=() _cgroup_rule_arr=()
  _conf_list_sorted _RDC_CONF devices "device_"      _devices_arr
  _conf_list_sorted _RDC_CONF devices "cgroup_rule_" _cgroup_rule_arr
  local _devices_str="" _cgroup_rule_str=""
  (( ${#_devices_arr[@]}      > 0 )) && _devices_str="$(printf '%s\n' "${_devices_arr[@]}")"
  (( ${#_cgroup_rule_arr[@]}  > 0 )) && _cgroup_rule_str="$(printf '%s\n' "${_cgroup_rule_arr[@]}")"
  _rdc_out["devices_str"]="${_devices_str}"
  _rdc_out["cgroup_rule_str"]="${_cgroup_rule_str}"

  # [environment] env_*, [tmpfs] tmpfs_*, [network] port_*.
  local -a _env_arr=() _tmpfs_arr=() _ports_arr=()
  _conf_list_sorted _RDC_CONF environment "env_"   _env_arr
  _conf_list_sorted _RDC_CONF tmpfs       "tmpfs_" _tmpfs_arr
  _conf_list_sorted _RDC_CONF network     "port_"  _ports_arr
  local _env_str="" _tmpfs_str="" _ports_str=""
  (( ${#_env_arr[@]}   > 0 )) && _env_str="$(printf '%s\n'   "${_env_arr[@]}")"
  (( ${#_tmpfs_arr[@]} > 0 )) && _tmpfs_str="$(printf '%s\n' "${_tmpfs_arr[@]}")"
  (( ${#_ports_arr[@]} > 0 )) && _ports_str="$(printf '%s\n' "${_ports_arr[@]}")"
  _rdc_out["env_str"]="${_env_str}"
  _rdc_out["tmpfs_str"]="${_tmpfs_str}"
  _rdc_out["ports_str"]="${_ports_str}"

  # [security] cap_add_*, cap_drop_*, security_opt_* with template fallback:
  # a per-repo [security] that wipes a list falls back to the template
  # baseline rather than Docker's stripped default (rationale).
  local -a _cap_add_arr=() _cap_drop_arr=() _sec_opt_arr=()
  _conf_list_sorted _RDC_CONF security "cap_add_"      _cap_add_arr
  _conf_list_sorted _RDC_CONF security "cap_drop_"     _cap_drop_arr
  _conf_list_sorted _RDC_CONF security "security_opt_" _sec_opt_arr
  local _tpl_setup_conf
  _tpl_setup_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
  local -a _tpl_sec_k=() _tpl_sec_v=()
  [[ -f "${_tpl_setup_conf}" ]] \
    && _parse_ini_section "${_tpl_setup_conf}" "security" _tpl_sec_k _tpl_sec_v
  (( ${#_cap_add_arr[@]}  == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "cap_add_"      _cap_add_arr
  (( ${#_cap_drop_arr[@]} == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "cap_drop_"     _cap_drop_arr
  (( ${#_sec_opt_arr[@]}  == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "security_opt_" _sec_opt_arr
  local _cap_add_str="" _cap_drop_str="" _sec_opt_str=""
  (( ${#_cap_add_arr[@]}  > 0 )) && _cap_add_str="$(printf '%s\n'  "${_cap_add_arr[@]}")"
  (( ${#_cap_drop_arr[@]} > 0 )) && _cap_drop_str="$(printf '%s\n' "${_cap_drop_arr[@]}")"
  (( ${#_sec_opt_arr[@]}  > 0 )) && _sec_opt_str="$(printf '%s\n'  "${_sec_opt_arr[@]}")"
  _rdc_out["cap_add_str"]="${_cap_add_str}"
  _rdc_out["cap_drop_str"]="${_cap_drop_str}"
  _rdc_out["sec_opt_str"]="${_sec_opt_str}"

  # [resources] shm_size (only meaningful when ipc != host).
  _conf_get_into _RDC_CONF resources shm_size "" _tmp; _rdc_out["shm_size"]="${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_sh <base_path> <stage> <image_ref> <container_name> <out> [<ctx_assoc>]
#
# S6b-gen ofwrite a self-contained `docker run` field
# launcher (`deploy.sh`) for the baked <stage> image. Ties the three
# resolution layers together:
#   _resolve_deploy_context  (global conf, S6b) -> the stage parent
#   _resolve_docker_flags    (per-stage overrides, S5) -> effective record
#   _emit_docker_run_flags   (S6a) -> the `docker run` argv fragment
#
# The launcher carries only docker-level flags. By design it omits:
#   - environment (-e): [environment] is baked into the image as ENV (S3);
#   - volumes (-v): bind mounts reference dev-host paths absent in the
#     field, and structured config is COPY-baked (S4); so the field image
#     is self-contained.
# GPU enablement is resolved with the generating host's detection (same as
# apply); the runtime stage's [stage:runtime] overrides still apply. The
# image / container name are overridable at run time via DEPLOY_IMAGE /
# DEPLOY_CONTAINER_NAME, and trailing args are appended to the container
# command. The generated file is chmod +x and ShellCheck-clean.
#
# Consumed by the S6 bundle orchestrator (S6c): build --target <stage> ->
# docker save -> tar.xz {image, deploy.sh}.
# ════════════════════════════════════════════════════════════════════
_generate_deploy_sh() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _image_ref="${3:?"${FUNCNAME[0]}: missing image_ref"}"
  local _container_name="${4:?"${FUNCNAME[0]}: missing container_name"}"
  local _out="${5:?"${FUNCNAME[0]}: missing out path"}"
  # optional pre-resolved context. The bundle orchestrator resolves
  # _resolve_deploy_context once (for the Dockerfile env bake) and threads
  # it in here so the field launcher consumes the same canonical record
  # rather than re-resolving setup.conf a second time within one deploy.
  local _ctx_src="${6:-}"

  # Global conf context (shared with apply via S6b). Consume the passed
  # record when given, else resolve standalone (direct callers / tests).
  # The working var is function-prefixed (_gds_ctx) so a caller passing an
  # assoc literally named `_ctx` is not shadowed by this local nameref bind.
  local -A _gds_ctx=()
  if [[ -n "${_ctx_src}" ]]; then
    local -n _gds_ctx_in="${_ctx_src}"
    local _gds_k
    for _gds_k in "${!_gds_ctx_in[@]}"; do
      _gds_ctx["${_gds_k}"]="${_gds_ctx_in[${_gds_k}]}"
    done
  else
    _resolve_deploy_context "${_base}" _gds_ctx
  fi

  # Detection-dependent enabled state + runtime, resolved like apply does.
  local _gpu_detected="" _gpu_enabled="" _runtime_resolved=""
  detect_gpu _gpu_detected
  _resolve_gpu "${_gds_ctx["gpu_mode"]}" "${_gpu_detected}" _gpu_enabled
  _resolve_runtime "${_gds_ctx["gpu_runtime_mode"]}" _runtime_resolved

  # Per-stage [stage:<stage>] overrides, filtered to the allowlist.
  local -a _so_k=() _so_v=() _sof_k=() _sof_v=()
  _load_stage_overrides "${_base}" "${_stage}" _so_k _so_v
  local _ki
  for (( _ki = 0; _ki < ${#_so_k[@]}; _ki++ )); do
    if _validate_stage_override_key "${_so_k[_ki]}"; then
      _sof_k+=("${_so_k[_ki]}")
      _sof_v+=("${_so_v[_ki]}")
    fi
  done

  # Parent record for the per-stage resolver. gui is forced off (the field
  # launcher is headless); volumes_top / env_top are empty so the field run
  # carries no bind mounts and no -e (baked ENV instead).
  local -A _parent=(
    [gui]="false"
    [gpu]="${_gpu_enabled}"
    [gpu_count]="${_gds_ctx["gpu_count"]}"
    [gpu_caps]="${_gds_ctx["gpu_caps"]}"
    [runtime]="${_runtime_resolved}"
    [net_mode]="${_gds_ctx["net_mode"]}"
    [ipc_mode]="${_gds_ctx["ipc_mode"]}"
    [pid_mode]="${_gds_ctx["pid_mode"]}"
    [net_name]="${_gds_ctx["network_name"]}"
    [volumes_top]=""
    [env_top]=""
    [ports_top]="${_gds_ctx["ports_str"]}"
    [cap_add_top]="${_gds_ctx["cap_add_str"]}"
    [cap_drop_top]="${_gds_ctx["cap_drop_str"]}"
    [sec_opt_top]="${_gds_ctx["sec_opt_str"]}"
  )
  local -A _eff=()
  _resolve_docker_flags _sof_k _sof_v _parent _eff

  # Merge the per-stage effective scalars with the top-level-only fields
  # (devices / caps / security_opt / shm / dri / cgroup / restart) into the
  # record _emit_docker_run_flags maps. volumes / environment are omitted.
  # privileged: _resolve_docker_flags only fills it from a [stage:*]
  # security.privileged override (empty otherwise, since compose carries the
  # global value via the devel `${PRIVILEGED}` env var). The field launcher
  # has no such env layer, so fall back to the global [security] privileged.
  local -A _flags=(
    [privileged]="${_eff["privileged"]:-${_gds_ctx["privileged"]}}"
    [gpu]="${_eff["gpu"]}"
    [gpu_count]="${_eff["gpu_count"]}"
    [gpu_caps]="${_eff["gpu_caps"]}"
    [runtime]="${_eff["runtime"]}"
    [net_mode]="${_eff["net_mode"]}"
    [net_name]="${_eff["net_name"]}"
    [ipc_mode]="${_eff["ipc_mode"]}"
    [pid_mode]="${_eff["pid_mode"]}"
    [ports]="${_eff["ports"]}"
    [shm_size]="${_gds_ctx["shm_size"]}"
    [restart]="${_gds_ctx["restart_policy"]}"
    [devices]="${_gds_ctx["devices_str"]}"
    [cap_add]="${_eff["cap_add"]}"
    [cap_drop]="${_eff["cap_drop"]}"
    [security_opt]="${_eff["security_opt"]}"
    [dri_groups]="${_gds_ctx["dri_groups_str"]}"
    [cgroup_rules]="${_gds_ctx["cgroup_rule_str"]}"
  )
  local -a _argv=()
  _emit_docker_run_flags _flags _argv

  # %q-quote the IMAGE / CONTAINER_NAME defaults so a name bearing a `"`,
  # `$(...)`, or backtick lands as a single literal token in the generated
  # launcher instead of breaking the assignment or command-substituting at
  # field run time. This mirrors the per-flag %q protection below; the seam
  # used to inline these as a bare heredoc default expansion.
  local _image_ref_q _container_name_q
  printf -v _image_ref_q '%q' "${_image_ref}"
  printf -v _container_name_q '%q' "${_container_name}"

  # Emit deploy.sh. Runtime-expanded vars / backticks are escaped so they
  # land literally in the generated script; per-arg %q quoting keeps each
  # flag a single, safely-quoted token.
  {
    cat <<EOF
#!/usr/bin/env bash
# AUTO-GENERATED field deployment launcher (setup.sh S6,). DO NOT EDIT.
#
# Self-contained \`docker run\` launcher for the baked \`${_stage}\` image.
# The docker-level flags below are inlined from the resolved \`${_stage}\`
# stage of setup.conf; [environment] defaults and structured config are
# baked into the image (S3/S4), so no env file or config bind travels.
# Field flow: \`docker load < <image>.tar\` then \`./deploy.sh\`.
#
# Overrides: DEPLOY_IMAGE / DEPLOY_CONTAINER_NAME env vars; any args after
# \`./deploy.sh\` are appended to the container command. Note: --group-add
# GIDs (iGPU /dev/dri) are from the generating host and may need adjusting
# on a different field machine.
set -euo pipefail

IMAGE=\${DEPLOY_IMAGE:-${_image_ref_q}}
CONTAINER_NAME=\${DEPLOY_CONTAINER_NAME:-${_container_name_q}}

exec docker run \\
  --detach \\
  --name "\${CONTAINER_NAME}" \\
EOF
    local _a
    for _a in "${_argv[@]}"; do
      printf '  %q \\\n' "${_a}"
    done
    # SC2016: the ${IMAGE} / "$@" tokens are emitted verbatim into the
    # generated deploy.sh and expand at field run time, not here.
    # shellcheck disable=SC2016
    printf '  "${IMAGE}" \\\n'
    # shellcheck disable=SC2016
    printf '  "$@"\n'
  } > "${_out}"
  chmod +x "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _bake_config_copy <src_dockerfile> <stage> <out>
#
# S4 deploy half: splice `COPY config/app /opt/app/config`
# into the <stage> stage of <src_dockerfile>, writing the result to <out>.
# The dev side bind-mounts config/app (apply); the field image bakes it in
# as an immutable layer so the deploy bundle is self-contained. Insert is
# right after the `FROM ... AS <stage>` line (handles src == out via a
# temp file). Caller only invokes this when <base>/config/app exists.
# ════════════════════════════════════════════════════════════════════
_bake_config_copy() {
  local _src="${1:?"${FUNCNAME[0]}: missing src dockerfile"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _out="${3:?"${FUNCNAME[0]}: missing out"}"
  local _tmp _line
  _tmp="$(mktemp)"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}" >> "${_tmp}"
    if [[ "${_line}" =~ ^FROM[[:space:]].*[[:space:]]AS[[:space:]]+"${_stage}"[[:space:]]*$ ]]; then
      printf '# >>> config/app baked (generated by setup.sh, #504/#506) <<<\n' >> "${_tmp}"
      printf 'COPY config/app /opt/app/config\n' >> "${_tmp}"
    fi
  done < "${_src}"
  mv -- "${_tmp}" "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_bundle <base_path> <stage> <out_bundle>
#
# S6c oforchestrate the self-contained field bundle.
#   1. resolve image name + [environment] defaults
#   2. _generate_runtime_dockerfile -> baked-ENV Dockerfile (S3); falls
#      back to the plain Dockerfile when there is no runtime stage / no
#      [environment]
#   3. _bake_config_copy -> COPY config/app into the image when present (S4)
#   4. docker build --target <stage> -t <name>:<stage>
#   5. _generate_deploy_sh -> deploy.sh (S6b-gen)
#   6. docker save -> image.tar
#   7. tar -cJf <out_bundle> image.tar deploy.sh  (the tar.xz field bundle)
#
# The generated Dockerfile + deploy.sh are written under a temp dir (no
# repo side effect; `docker build -f <tmp> <base>` keeps the build context
# at the repo). The docker / tar steps go through _dry_run_cmd, so
# DRY_RUN=true prints the plan without building. Field flow: extract the
# bundle, `docker load < image.tar`, `./deploy.sh`.
# ════════════════════════════════════════════════════════════════════
_generate_deploy_bundle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _bundle="${3:?"${FUNCNAME[0]}: missing out_bundle"}"

  local _name=""
  BASE_PATH="${_base}" detect_image_name _name "${_base}"
  local _image="${_name}:${_stage}"
  local _container="${_name}-${_stage}"

  local -A _ctx=()
  _resolve_deploy_context "${_base}" _ctx

  local _work
  _work="$(mktemp -d)"
  local _gen="${_work}/Dockerfile.deploy"
  local _build_dockerfile="${_base}/Dockerfile"

  # Bake [environment] as ENV into the runtime stage (S3). On no-op (no
  # runtime stage / empty env) keep the plain Dockerfile.
  if _generate_runtime_dockerfile "${_base}/Dockerfile" "${_ctx["env_str"]}" "${_gen}"; then
    _build_dockerfile="${_gen}"
  fi
  # Bake config/app into the image (S4 deploy half) when the repo ships it.
  if [[ -d "${_base}/config/app" ]]; then
    _bake_config_copy "${_build_dockerfile}" "${_stage}" "${_gen}"
    _build_dockerfile="${_gen}"
  fi

  # Generate the field launcher up front so the plan is inspectable even
  # under DRY_RUN (the docker/tar steps below are the only guarded ones).
  _generate_deploy_sh "${_base}" "${_stage}" "${_image}" "${_container}" "${_work}/deploy.sh" _ctx

  local _rc=0
  _dry_run_cmd docker build --target "${_stage}" \
    -f "${_build_dockerfile}" -t "${_image}" "${_base}" || _rc=$?
  if (( _rc == 0 )); then
    _dry_run_cmd docker save -o "${_work}/image.tar" "${_image}" || _rc=$?
  fi
  if (( _rc == 0 )); then
    _dry_run_cmd tar -C "${_work}" -cJf "${_bundle}" image.tar deploy.sh || _rc=$?
  fi

  rm -rf "${_work}"
  return "${_rc}"
}

# _parse_logging_svc_sections / _collect_logging moved to
# lib/conf_logging.sh in (PR-A) so both setup.sh and the
# upcoming PR-B gitignore sync (lib/gitignore.sh) can share them
# without circular sourcing. _lib.sh now pulls conf_logging.sh in
# automatically, so callers below still resolve the same names.

# _sync_logging_local_paths_gitignore moved to lib/gitignore.sh in
# (PR-B) and renamed _sync_logging_gitignore (now takes only
# <base_path>, calls _collect_logging itself). Sync runs at
# init.sh / upgrade.sh time instead of every setup.sh apply, so
# the file stays in step across template versions even when no
# wrapper has fired since the last setup.conf edit.

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml <out> <repo_name> <gui_enabled> <gpu_enabled>
#                       <gpu_count> <gpu_caps> <extras_array_ref>
#                       [<network_name>]
#
# Emits full compose.yaml with:
#   - Baseline: workspace + X11 (iff GUI) + GUI env block (iff GUI)
#   - Conditional: GPU deploy block (iff gpu_enabled=true)
#   - Extra volumes from [volumes] section (comes in via extras_array_ref)
#   - When network_name is given (only meaningful for mode=bridge), the
#     service joins that external network and a top-level `networks:`
#     block declares it external. Otherwise falls back to the env-driven
#     `network_mode: ${NETWORK_MODE}`.
# IPC/privileged always read from env var refs; .env provides values.
# ════════════════════════════════════════════════════════════════════

# _expand_env_cross_refs <input-newline-list> <output-array-name>
#
# Reads `KEY=VALUE` entries (one per line, blank lines skipped) and
# substitutes `${KEY}` references in each value with the value of an
# earlier-seen sibling KEY. Order-sensitive: forward references (a value
# referencing a sibling not yet parsed) survive as the literal `${VAR}`,
# as do unknown references with no matching sibling -- compose.yaml's
# own substitution layer (.env / shell env) gets a chance at file-load
# time, surfacing genuinely undefined names visibly rather than silently
# substituting empty.
#
# Resolvespreviously, sibling cross-references in
# `[environment] env_N` were emitted literally and compose's `${VAR}`
# substitution does NOT consult sibling environment entries -- so e.g.
#   env_1 = BUILD_TARGET=production
#   env_2 = LD_LIBRARY_PATH=/foo/${BUILD_TARGET}/lib
# would ship `LD_LIBRARY_PATH=/foo//lib` to the container.
_expand_env_cross_refs() {
  local _input="$1"
  local -n _expand_out_arr="$2"
  _expand_out_arr=()
  declare -A _seen=()
  local _line _k _v _ref_k _ref_v _expanded
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _expanded="${_v}"
    # Substitute every ${ref_k} found in _v against earlier siblings.
    # Multiple-pass not needed because _seen already holds fully-expanded
    # values from prior iterations (transitive references resolve through
    # the chain naturally).
    for _ref_k in "${!_seen[@]}"; do
      _ref_v="${_seen[${_ref_k}]}"
      _expanded="${_expanded//\$\{${_ref_k}\}/${_ref_v}}"
    done
    _seen["${_k}"]="${_expanded}"
    _expand_out_arr+=("${_k}=${_expanded}")
  done <<< "${_input}"
}
