#!/usr/bin/env bats
#
# validated_key_reach_spec.bats -- a key the schema accepts has to reach
# the artifact it is a setting for.
#
# base#1094 measured five keys that `_schema_validate` accepted and
# nothing downstream consumed, so the operator's setting silently did
# nothing. Two of the five were "never emitted anywhere" (`[network] pid`
# outside `host`, and the whole of `[logging]` in the field-deploy
# bundle); two were "emitted, then overruled by another key with no
# diagnostic" (`[resources] shm_size` under the shipped `ipc = host`, and
# `[network] mode` beside a `network_name`); one was "the validator
# cannot express the value at all" (`[deploy] dri_groups`).
#
# why: Covers base#1094 -- the keys that validate and then never reach
# the emitted artifact. The DERIVED gate here is the one that matters:
# `_resolve_deploy_context` is the code's own declaration of which
# config values the field bundle is built from, so its populated record
# IS the population, and every field of it has to be able to change the
# generated bundle under SOME configuration. A per-key assertion naming
# today's five would stay green while the sixth grew. The explicit tests
# below it cover the three defects a reachability check cannot see: a
# value that reaches one tier and not the other, and a value another key
# silently overrules.
#
# The two tiers are the dev compose (`generate_compose_yaml`) and the
# field-deploy bundle (`_generate_resolved_compose`). They are separate
# emitters over the same config, which is why base#1094's `[logging]`
# gap existed at all -- one of them called `_emit_logging_block` and the
# other had never heard of it.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  export SETUP_LANG=en
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
  TEMP_DIR="$(mktemp -d)"
  # Use the in-container bridge directly instead of `docker run` (mirrors
  # compose_emit/gen_spec.bats).
  toml_bridge_parse() {
    local _file="${1:?missing file}"
    shift
    [[ -f "${_file}" ]] || { echo "toml_bridge_parse: file not found: ${_file}" >&2; return 1; }
    /usr/local/bin/toml-bridge "$@" < "${_file}"
  }
  toml_bridge_merge() {
    local _kv_flag=""
    if [[ "${1:-}" == "--kv" ]]; then _kv_flag="--kv"; shift; fi
    local -a _args=("--merge")
    [[ -n "${_kv_flag}" ]] && _args+=("--kv")
    _args+=("$@")
    /usr/local/bin/toml-bridge "${_args[@]}"
  }
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# A conf directory holding exactly the text given. The WHOLE file, not a
# fragment appended to a baseline: a TOML table may not be opened twice,
# and a duplicate table makes the bridge refuse the file -- which, from
# the outside, looks exactly like "setting this key changed nothing".
# That confusion is what base#1164 was about, and a probe harness is the
# easiest place to reintroduce it.
_conf_dir() {
  local _d
  _d="$(mktemp -d --tmpdir="${TEMP_DIR}")"
  printf '%s' "${1}" > "${_d}/setup.toml"
  printf '%s' "${_d}"
}

# A minimal Dockerfile the dev emitter's per-stage loop needs.
_write_dockerfile() {
  cat > "${1}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
}

# The deterministic baseline every probe is a one-key edit of: headless,
# no GPU, no /dev/dri grant, host networking. Everything it emits is a
# literal, so a difference in the generated file is the probe's doing.
_REACH_BASE='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'

# One probe per field of the deploy context: the WHOLE conf, with that
# field moved off its baseline value (and nothing else moved except what
# the field needs to be live at all -- `shm_size` needs a non-host `ipc`,
# `ports` needs bridge). Completeness is DERIVED below against the
# context record's own key set, so a field added to the resolver without
# a probe is a red test rather than a silent hole in this gate.
declare -gA _REACH_PROBE=(
  [build_network]='[build]
network = "host"
[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_mode]='[deploy]
gpu_mode = "force"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_count]='[deploy]
gpu_mode = "force"
gpu_count = 3
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_caps]='[deploy]
gpu_mode = "force"
gpu_capabilities = "gpu compute"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_runtime_mode]='[deploy]
gpu_mode = "off"
gpu_runtime = "nvidia"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gui_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "force"
[network]
mode = "host"
'
  [dri_groups_str]='[deploy]
gpu_mode = "off"
dri_groups = "44 104"
[gui]
mode = "force"
[network]
mode = "host"
'
  [net_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "bridge"
network_name = "probenet"
'
  [network_name]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "bridge"
network_name = "probenet"
'
  [ipc_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
ipc = "shareable"
'
  [pid_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
pid = "container:probe0"
'
  [privileged]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[security]
privileged = true
'
  [restart_policy]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[lifecycle]
restart = "on-failure:5"
'
  [init]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[lifecycle]
init = false
'
  [watchdog_env_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[lifecycle]
watchdog_check = "probe-cmd"
'
  [devices_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[devices.bindings]]
path = "/dev/probe0:/dev/probe0"
'
  [cgroup_rule_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[devices.cgroup_rules]]
rule = "c 81:* rmw"
'
  [env_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[environment]
env_1 = "PROBE0=1"
'
  [tmpfs_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[tmpfs]]
path = "/probe0"
'
  [ports_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "bridge"
network_name = "probenet"
[[network.ports]]
host = 18080
container = 80
'
  [cap_add_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[security.cap_add]]
cap = "SYS_NICE"
'
  [cap_drop_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[security.cap_drop]]
cap = "NET_RAW"
'
  [sec_opt_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[security.security_opt]]
opt = "seccomp:unconfined"
'
  [shm_size]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
ipc = "shareable"
[resources]
shm_size = "2g"
'
  [logging_global_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[logging]
driver = "json-file"
max_size = "5m"
max_file = 3
compress = true
'
  [logging_per_svc_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[logging.runtime]
driver = "local"
max_size = "9m"
'
)

# The fields whose value legitimately reaches no line of the bundle's
# compose.yaml, each with the reason. An entry here is a claim about
# WHERE the value goes, not permission for it to go nowhere.
declare -gA _REACH_EXEMPT=(
  [build_network]="build-time only: the bundle ships a pre-built image and carries no build: section, so a build network has nothing to configure there"
  [env_str]="rides the bundle .env, deliberately NOT compose environment: -- compose ranks environment: above env_file, so a value left there would make the operator's .env.local override silently inert (_generate_resolved_compose's header states this)"
  [watchdog_env_str]="same as env_str: the WATCHDOG_* thresholds are the operator's field-retunable knobs, so they ride .env where .env.local can override them"
)

# Write the bundle compose for <conf_dir> into <out_file>.
_reach_bundle() {
  local _conf="${1}" _out="${2}"
  local -A _binds=() _ctx=()
  _resolve_deploy_context "${_conf}" _ctx
  _generate_resolved_compose "${_conf}" runtime img name "${_out}" _binds _ctx
}

# Print the stdin lines whose 0-based index i has i % <K> == <k>
# (base#2003): one part of the reach gate's field list.
_reach_part_of() {
  awk -v k="${1:?missing part}" -v n="${2:?missing part count}" \
    '(NR - 1) % n == k'
}

# The reach gate's title, without its part suffix (base#2003). The 4 part
# @tests below spell it out literally, because the catalogue, count and
# issueref tools read `@test` lines as text.
_REACH_TITLE='every deploy-context field can change the generated bundle compose, or is a declared exemption'

# Print n-1 when <title> is exactly "<_REACH_TITLE>, part n of 4
# (base#1094)" for n in 1..4; otherwise say so and fail (base#2003).
_reach_part_from_title() {
  local _title="${1?missing title}" _n
  for _n in 1 2 3 4; do
    if [[ "${_title}" == "${_REACH_TITLE}, part ${_n} of 4 (base#1094)" ]]; then
      echo "$(( _n - 1 ))"
      return 0
    fi
  done
  echo "not a reach-part title: ${_title}"
  return 1
}

# Print, one per line, the non-exempt fields of the context record named
# <ctx> that the reach part named by this @test's title checks
# (base#2003). Fails, saying why, when the title is not a reach-part
# title, when a stage of the selection fails, or when it selects nothing.
_reach_part_fields() {
  local -n _rpf_ctx="${1:?missing context record}"
  local _k _all _part _f
  _k="$(_reach_part_from_title "${BATS_TEST_DESCRIPTION}")" || { echo "${_k}"; return 1; }
  _all="$(set -o pipefail
    for _f in "${!_rpf_ctx[@]}"; do
      [[ -v "_REACH_EXEMPT[${_f}]" ]] || printf '%s\n' "${_f}"
    done | LC_ALL=C sort)" || { echo "listing the deploy-context fields failed"; return 1; }
  _part="$(_reach_part_of "${_k}" 4 <<< "${_all}")" || { echo "selecting reach part ${_k} failed"; return 1; }
  [[ -n "${_part}" ]] || { echo "reach part ${_k} selected no field"; return 1; }
  printf '%s\n' "${_part}"
}

# The reach check for the part this @test's title names (base#2003): each
# non-exempt field of that part must change the bundle compose.
_reach_check_part() {
  local _base_dir _baseline="${TEMP_DIR}/baseline.yaml"
  _base_dir="$(_conf_dir "${_REACH_BASE}")"
  local -A _ctx=() _base_binds=()
  _resolve_deploy_context "${_base_dir}" _ctx

  local _sel
  _sel="$(_reach_part_fields _ctx)" || { echo "${_sel}"; return 1; }
  local -a _fields=()
  mapfile -t _fields <<< "${_sel}"

  _generate_resolved_compose "${_base_dir}" runtime img name "${_baseline}" _base_binds _ctx

  local _f _inert="" _probe _dir _out
  for _f in "${_fields[@]}"; do
    _probe="${_REACH_PROBE[${_f}]:-}"
    [[ -n "${_probe}" ]] || continue   # the probe-completeness test owns this
    _dir="$(_conf_dir "${_probe}")"
    # A probe the bridge refuses would read as "the key changed nothing".
    run toml_bridge_parse "${_dir}/setup.toml"
    assert_success
    _out="${TEMP_DIR}/probe-${_f}.yaml"
    _reach_bundle "${_dir}" "${_out}"
    cmp -s "${_baseline}" "${_out}" && _inert+=" ${_f}"
  done
  [ -z "${_inert}" ] || {
    echo "deploy-context fields that cannot change the bundle compose:${_inert}"
    echo "each is a value the schema accepts and the emitter drops; emit it, or add a _REACH_EXEMPT row saying where it does go"
    false
  }
}

# ════════════════════════════════════════════════════════════════════
# The derived gate
# ════════════════════════════════════════════════════════════════════

# why: base#1094 -- `_resolve_deploy_context`'s populated record is the
# code's own declaration of which config values the field bundle is
# built from, so holding the probe table equal to it is what stops this
# gate from quietly covering 23 of 24 fields. Measured on 0faacb57: 24
# fields.
@test "every deploy-context field has a reach probe, and every probe names a field (base#1094)" {
  local -A _ctx=()
  _resolve_deploy_context "$(_conf_dir "${_REACH_BASE}")" _ctx
  (( ${#_ctx[@]} > 0 )) || { echo "the deploy context resolved to nothing"; false; }

  local _f _missing="" _orphan=""
  for _f in "${!_ctx[@]}"; do
    [[ -v "_REACH_PROBE[${_f}]" ]] || _missing+=" ${_f}"
  done
  for _f in "${!_REACH_PROBE[@]}"; do
    [[ -v "_ctx[${_f}]" ]] || _orphan+=" ${_f}"
  done
  [ -z "${_missing}" ] || {
    echo "deploy-context fields with no reach probe:${_missing}"
    false
  }
  [ -z "${_orphan}" ] || {
    echo "probes naming no deploy-context field:${_orphan}"
    false
  }
}

# why: base#1094 -- the defect's exact shape: a key validates, the
# resolver reads it into the context, and the emitter never consumes it,
# so the operator's setting does nothing and nothing says so. `pid_mode`
# and the two `[logging]` fields were in that state. The population is
# derived from the context record, so a field added tomorrow and then
# dropped by the emitter fails here; the alternative -- naming today's
# fields -- is the assertion that would have passed all through
# base#1094.
#
# Split into 4 parts (base#2003) so no one @test runs past the per-test
# timeout under coverage. Each part checks the fields `_reach_part_of`
# assigns it; a field with no probe is the probe-completeness test's job.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 1 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#1094 -- part 2 of the reach gate split by base#2003. Part 1
# carries the rationale.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 2 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#1094 -- part 3 of the reach gate split by base#2003. Part 1
# carries the rationale.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 3 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#1094 -- part 4 of the reach gate split by base#2003. Part 1
# carries the rationale.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 4 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#2003 -- the reach gate runs in parts so no one @test runs
# past the per-test timeout under coverage, and a part is the fields at
# index i with i % K == k. Over a worked literal, so a constant part, a
# dropped index, or an index counted from 1 each gives other lines.
@test "a reach part is every K-th field from its index (base#2003)" {
  local _in
  _in="$(printf '%s\n' a b c d e f)"
  run _reach_part_of 0 4 <<< "${_in}"
  assert_success
  assert_output "$(printf '%s\n' a e)"
  run _reach_part_of 1 4 <<< "${_in}"
  assert_success
  assert_output "$(printf '%s\n' b f)"
  run _reach_part_of 2 4 <<< "${_in}"
  assert_success
  assert_output "c"
  run _reach_part_of 3 4 <<< "${_in}"
  assert_success
  assert_output "d"
}

# why: base#2003 -- each reach part takes its part from its own title,
# and only a title equal to one of the 4 exact reach-part titles gives
# one. The titles are typed here rather than read from the constant, so
# a drift between the two fails. A copy-edited title, a trailing word, a
# part outside 1..4 and a title with no part are each refused.
@test "a reach part number comes only from an exact reach-part title (base#2003)" {
  local _t='every deploy-context field can change the generated bundle compose, or is a declared exemption'
  run _reach_part_from_title "${_t}, part 1 of 4 (base#1094)"
  assert_success
  assert_output "0"
  run _reach_part_from_title "${_t}, part 4 of 4 (base#1094)"
  assert_success
  assert_output "3"

  local _bad
  for _bad in \
    "copy-edited reach title, part 2 of 4 (base#1094)" \
    "${_t}, part 2 of 4 (base#1094) x" \
    "${_t}, part 5 of 4 (base#1094)" \
    "${_t} (base#1094)"; do
    run _reach_part_from_title "${_bad}"
    assert_failure
    refute_output --regexp '^[0-9]+$'
  done
}

# why: base#2003 -- a part @test only runs if it is registered. Bats
# refuses two tests with one title in a file, and every part takes its
# part from an exact title, so 4 registered exact titles are parts 1..4
# once each. Counted through bats' own --count and --filter, so a
# deleted part makes the count 3.
@test "the four reach parts are registered once each (base#2003)" {
  run bats --count --filter "^${_REACH_TITLE}, part [1-4] of 4 \\(base#1094\\)\$" "${BATS_TEST_FILENAME}"
  assert_success
  assert_output "4"
}

# why: base#2003 -- the 4 parts together have to check every non-exempt
# field exactly once. Each part's fields come from `_reach_part_fields`
# under that part's own title, the same call the part @tests make, so a
# selection that hands every part the same index repeats one part and
# drops the other three, and the sorted union differs from the field list.
@test "the four reach parts together select every non-exempt field once (base#2003)" {
  local -A _ctx=()
  _resolve_deploy_context "$(_conf_dir "${_REACH_BASE}")" _ctx
  local _t='every deploy-context field can change the generated bundle compose, or is a declared exemption'
  local _n _sel _got="" _f _want
  for _n in 1 2 3 4; do
    _sel="$(BATS_TEST_DESCRIPTION="${_t}, part ${_n} of 4 (base#1094)" _reach_part_fields _ctx)" \
      || { echo "part ${_n}: ${_sel}"; false; }
    _got+="${_sel}"$'\n'
  done
  _want="$(for _f in "${!_ctx[@]}"; do
    [[ -v "_REACH_EXEMPT[${_f}]" ]] || printf '%s\n' "${_f}"
  done | LC_ALL=C sort)"
  [ -n "${_want}" ] || { echo "the deploy context has no non-exempt field"; false; }
  assert_equal "$(printf '%s' "${_got}" | LC_ALL=C sort)" "${_want}"
}

# why: base#2003 -- a part whose field selection fails, or selects
# nothing, has checked nothing, so it has to fail rather than report a
# pass over zero fields. The selection's last stage is replaced here by
# one that fails and by one that prints nothing.
@test "a reach part fails when its field selection fails or selects nothing (base#2003)" {
  local _t='every deploy-context field can change the generated bundle compose, or is a declared exemption, part 1 of 4 (base#1094)'
  _reach_part_of() { return 1; }
  BATS_TEST_DESCRIPTION="${_t}" run _reach_check_part
  assert_failure
  _reach_part_of() { :; }
  BATS_TEST_DESCRIPTION="${_t}" run _reach_check_part
  assert_failure
}

# why: base#1094 -- an exemption is a claim about where the value goes,
# and an unexplained one is the hole this gate exists to close. Mirrors
# schema.sh's SCHEMA_FREEFORM reason rule.
@test "every reach exemption names a deploy-context field and carries a reason (base#1094)" {
  local -A _ctx=()
  _resolve_deploy_context "$(_conf_dir "${_REACH_BASE}")" _ctx
  local _k _bad=""
  for _k in "${!_REACH_EXEMPT[@]}"; do
    [[ -v "_ctx[${_k}]" ]] || _bad+=" ${_k}(no such field)"
    [[ -n "${_REACH_EXEMPT[${_k}]}" ]] || _bad+=" ${_k}(no reason)"
  done
  [ -z "${_bad}" ] || { echo "bad exemptions:${_bad}"; false; }
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (1): [network] pid = container:<name>
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 1 -- `_validate_pid_mode` accepts
# `container:<name>` and the TUI offers it, while both emitters wrote
# `pid:` only when the value was exactly `host`. A user who set
# `container:foo` got a green config and a compose file with no `pid:`
# line at all. `private` stays omitted on purpose: Docker rejects it as a
# literal and omitting the key gives the same private namespace.
@test "pid = container:<name> reaches the dev compose, and private still does not (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_out}" myrepo \
      false false 0 gpu _extras "" "" "" "" "" "" host host 'container:probe0' )
  run grep -cE '^    pid: ' "${_out}"
  assert_output "1"

  local _priv="${TEMP_DIR}/private.yaml" _extras2=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_priv}" myrepo \
      false false 0 gpu _extras2 "" "" "" "" "" "" host host private )
  run grep -cE '^    pid: ' "${_priv}"
  assert_output "0"
}

# why: base#1094 item 1, field tier. The bundle writes literals rather
# than `${PID_MODE}`, so the value itself has to arrive -- a bundle that
# merely carried the key would be no use to the device.
@test "pid = container:<name> reaches the field bundle as a literal (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[pid_mode]}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run grep -F 'pid: container:probe0' "${TEMP_DIR}/field.yaml"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (2): [resources] shm_size under the shipped ipc = host
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 2 -- the shipped template sets `ipc = "host"`, and
# both emitters drop `shm_size` unless ipc is something else. So the
# DEFAULT configuration makes the only key in `[resources]` do nothing.
# `ports` has the identical situation under `mode = host` and has printed
# a diagnostic for it since base#879; this one printed nothing. The fix is
# the same diagnostic, not a default change (ADR-00000019 chose the host
# defaults deliberately).
@test "a shm_size dropped under ipc = host is reported by the dev emitter (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    '' '' '' '' '' '2g' host host private 2>&1"
  assert_success
  assert_output --partial "honours shm_size only when ipc is not host"
  run grep -c 'shm_size' "${_out}"
  assert_output "0"
}

@test "a shm_size that is emitted under a non-host ipc is not reported (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml"
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    '' '' '' '' '' '2g' host shareable private 2>&1"
  assert_success
  refute_output --partial "honours shm_size only when ipc is not host"
  run grep -cF 'shm_size: 2g' "${_out}"
  assert_output "1"
}

# why: base#1094 item 2 -- the diagnostic has to fire where the user can
# act on it, which is also when the value is stored. The ports precedent
# (base#879) fires at both points and so does this.
@test "setting resources.shm_size under the shipped ipc = host warns at store time (base#1094)" {
  local _d
  _d="$(_conf_dir '[network]
ipc = "host"
')"
  run bash /source/dist/script/docker/wrapper/setup.sh set resources.shm_size 2g --base-path "${_d}"
  assert_success
  assert_output --partial "honours shm_size only when ipc is not host"
}

@test "setting resources.shm_size under a non-host ipc stays quiet (base#1094)" {
  local _d
  _d="$(_conf_dir '[network]
ipc = "shareable"
')"
  run bash /source/dist/script/docker/wrapper/setup.sh set resources.shm_size 2g --base-path "${_d}"
  assert_success
  refute_output --partial "honours shm_size only when ipc is not host"
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (3): [network] mode beside a network_name
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 3 -- two keys answered one question and the loser
# was silent. Three of the five emission sites already agreed that mode
# decides and `network_name` only applies under bridge (the per-stage
# service emitter, and both branches of the field bundle); the devel
# service and the top-level `networks:` declaration consulted only
# `network_name`. So one setup.toml produced bridge networking in
# development and host networking on the device, with nothing said. The
# devel service now follows the same rule as its own siblings.
@test "mode = host beside a network_name keeps host networking in the dev compose (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_out}" myrepo \
      false false 0 gpu _extras mynet "" "" "" "" "" host host private ) >/dev/null 2>&1
  run grep -cE '^    network_mode: ' "${_out}"
  assert_output "1"
  run grep -c '^networks:$' "${_out}"
  assert_output "0"
}

@test "mode = bridge beside a network_name still joins the named network (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_out}" myrepo \
      false false 0 gpu _extras mynet "" "" "" "" "" bridge host private ) >/dev/null 2>&1
  run grep -cF '      - mynet' "${_out}"
  assert_output "1"
  run grep -c '^networks:$' "${_out}"
  assert_output "1"
}

# why: base#1094 item 3, the case a global-mode reading gets wrong. A
# `[stage:<name>]` override can set network.mode = "bridge" while the
# global mode is host: that stage joins the inherited name, so the
# top-level declaration has to be there or compose refuses the whole
# project for referencing an undeclared network. The declaration is
# therefore driven by what the service blocks EMITTED, not by
# re-deriving the condition from the global mode -- a second derivation
# of one question being the family base#1094 belongs to.
@test "a stage overriding mode to bridge still gets its named network declared (base#1094)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS probe
DOCK
  cat > "${TEMP_DIR}/setup.toml" <<'CONF'
[network]
mode = "host"
network_name = "mynet"

["stage:probe"]
"network.mode" = "bridge"
CONF
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  generate_compose_yaml "${_out}" myrepo \
    false false 0 gpu _extras mynet "" "" "" "" "" host host private >/dev/null 2>&1

  # The stage joined it ...
  run grep -cF '      - mynet' "${_out}"
  assert_output "1"
  # ... so the project declares it.
  run grep -c '^networks:$' "${_out}"
  assert_output "1"
  # ... and devel, which did not join, still has host networking.
  local _devel_block
  _devel_block="$(awk '/^  devel:/{f=1;next} /^  [a-z]/{f=0} f' "${_out}")"
  assert [ -n "$(grep -F 'network_mode:' <<< "${_devel_block}")" ]
}

# why: base#1094 item 3 -- the issue's words: "Silence is the one option
# that is not available." The precedence is now stated in the template
# beside both keys, and warned about when it applies.
@test "a network_name under a non-bridge mode is reported, naming both keys (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml"
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    mynet '' '' '' '' '' host host private 2>&1"
  assert_success
  assert_output --partial "joins a named network only under mode = bridge"
}

@test "a network_name under mode = bridge is not reported (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml"
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    mynet '' '' '' '' '' bridge host private 2>&1"
  assert_success
  refute_output --partial "joins a named network only under mode = bridge"
}

@test "setting network.network_name under the shipped host default warns at store time (base#1094)" {
  local _d
  _d="$(_conf_dir '[network]
mode = "host"
')"
  run bash /source/dist/script/docker/wrapper/setup.sh set network.network_name mynet --base-path "${_d}"
  assert_success
  assert_output --partial "joins a named network only under mode = bridge"
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (4): [deploy] dri_groups cannot express a value
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 4 -- the key looked like a setting and was a
# switch: the validator took only `auto` / `off`, and the GIDs themselves
# were reachable only through the `SETUP_DETECT_DRI_GROUPS` environment
# variable -- the mechanism ADR-00000025 section 9 removed everywhere
# else ("no ambient environment variable can steer the chain"). The key
# now carries the list, with `auto` still the default and the env var
# still honoured for the auto path.
@test "dri_groups carrying an explicit GID list reaches group_add without the env var (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[dri_groups_str]}")"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" "44 104"

  SETUP_DETECT_DRI_GROUPS="" _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run grep -cE '^      - "(44|104)"$' "${TEMP_DIR}/field.yaml"
  assert_output "2"
}

@test "dri_groups = off still grants nothing (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_BASE}")"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" ""
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (5): [logging] in the field-deploy bundle
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 5 -- `_emit_logging_block` was called by the dev
# emitter and never by `deploy.sh`, so a repo configuring a driver,
# max_size, max_file and compress got all four in development and none
# of them in the artifact shipped to a device. That is the one place
# where an unbounded log actually fills a disk. `local_path` stays out of
# the bundle on purpose: it is a host bind, not a Docker logging option,
# and the block has never emitted it.
@test "a configured [logging] reaches the field bundle, matching the dev compose (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[logging_global_str]}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run cat "${TEMP_DIR}/field.yaml"
  assert_success
  assert_line "    logging:"
  assert_line "      driver: json-file"
  assert_line '        max-size: "5m"'
  assert_line '        max-file: "3"'
  assert_line '        compress: "true"'
}

# why: base#1094 item 5 -- `[logging.<svc>]` is the per-service override
# layer, and the bundle's service is the deployed stage. A bundle that
# took only the global block would drop exactly the override an operator
# wrote for that stage.
@test "a [logging.<stage>] override reaches the field bundle for that stage (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[logging_per_svc_str]}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run cat "${TEMP_DIR}/field.yaml"
  assert_success
  assert_line "      driver: local"
  assert_line '        max-size: "9m"'
}

# why: base#1094 item 5 -- the shipped template sets driver / max_size /
# max_file / compress, so "configure nothing" is not "no logging
# options": it is the template's bounds. Those are the ones that matter,
# because the repo that never thought about logging is the one whose
# device disk fills. This asserts the DEFAULT reaches the bundle, not
# just an explicitly configured value.
@test "the shipped [logging] defaults reach a bundle that configures nothing (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_BASE}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run cat "${TEMP_DIR}/field.yaml"
  assert_success
  assert_line "    logging:"
  assert_line "      driver: json-file"
  assert_line '        max-size: "10m"'
}

# why: base#1094 item 5 -- the defect was two emitters over one config
# disagreeing, so the assertion that holds the fix is agreement, not
# presence. Both tiers are handed the same _collect_logging result and
# their `logging:` blocks are compared line for line; a future change to
# one emitter's block that the other does not get fails here.
@test "the bundle's logging block is the same block the dev compose emits (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[logging_global_str]}")"
  _write_dockerfile "${_d}"
  local _g="" _p=""
  _collect_logging "${_d}" _g _p

  local _dev="${_d}/compose.yaml" _extras=()
  ( cd "${_d}" && generate_compose_yaml "${_dev}" myrepo \
      false false 0 gpu _extras "" "" "" "" "" "" host host private \
      "" "" "" "" "" "" "" "" "" "${_g}" "${_p}" ) >/dev/null 2>&1
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"

  # The block only: everything around it differs by design (the dev
  # compose interpolates, the bundle resolves). The block is the
  # `logging:` line plus the lines indented deeper than it, so the
  # extraction ends at the next service-level key whatever that is.
  local _dev_block _field_block
  _dev_block="$(awk '/^    logging:$/{f=1;print;next} f&&/^      /{print;next} f{exit}' "${_dev}")"
  _field_block="$(awk '/^    logging:$/{f=1;print;next} f&&/^      /{print;next} f{exit}' "${TEMP_DIR}/field.yaml")"
  [[ -n "${_dev_block}" ]] || { echo "the dev compose emitted no logging block"; false; }
  assert_equal "${_field_block}" "${_dev_block}"
}
