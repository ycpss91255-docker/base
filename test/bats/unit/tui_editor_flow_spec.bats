#!/usr/bin/env bats
#
# why: `tui_flow_spec.bats` proves the setup_tui.sh menus DISPATCH -- it
# spies on each section editor and asserts the right one was reached. What
# those editors then DO was the largest genuinely untested surface in the
# tree (base#1073 measured 307 untested bash lines in
# `dist/script/docker/wrapper/setup_tui.sh` with a real bash parser). This
# spec covers the bodies: what a menu row shows, which value a validator
# refuses, which namespaced key a write lands on, and what `main` /
# `_commit_and_setup` / `_do_reset` do to the world around them.
#
# It reuses the harness the flow spec established rather than inventing
# one: source setup_tui.sh, replace the `_tui_*` primitives with a
# file-backed scripted queue (a file, because the primitives are called
# inside `$(...)` and a variable-held cursor dies in the subshell), and
# assert on `_TUI_OVR_*` / `_TUI_REMOVED` / `_TUI_CURRENT`. Two additions:
# `_tui_menu` records the rows it was asked to render, so a test can assert
# what the user is shown, and `_tui_msgbox` records its calls, so "warned"
# and "stayed silent" are both assertable.
#
# Two hazards this spec is written around, both load-bearing:
#
# - `FILE_PATH` is `readonly` and resolves to the sourced tree. Everything
# keyed on it is steered by replacing the function that reads it, or
# through `_TUI_SCRIPT_DIR` / `_TUI_TPL_DIR`, which are plain variables.
#
# - Nothing here writes under `FILE_PATH`. The suite runs many-way
# parallel over one shared source tree, so `_do_reset`'s `rm -f` is
# intercepted by a shell function (which also makes "reset deletes the
# per-repo conf" assertable) and `main`'s commit is a spy.
#
# Grouped by concern:
#
# - `_edit_section_build` (placeholder vs stored value, arg badge counts
# only populated slots, target_arch / network validation, Cancel returns
# to the menu instead of leaving)
#
# - `_edit_section_security` (privileged yes/no, per-list capability
# counts, cap_add / cap_drop / security_opt lists)
#
# - `_edit_logging_keys` (per-service namespacing, driver / max_size /
# max_file / local_path validation, compress boolean, inherit
# placeholder, missing-section refusal)
#
# - `_edit_section_resources` (the ipc=host advisory, still stores)
#
# - `_edit_section_devices` / `_edit_section_ports` (sub-list routing, the
# non-bridge ports advisory)
#
# - Per-stage editors (`_edit_section_per_stage`, `_edit_per_stage_one`,
# `_edit_stage_deploy`, `_edit_stage_network`, `_edit_stage_volumes`,
# `_edit_stage_environment`)
#
# - `_commit_and_setup` (baseline merged with overrides, removals dropped,
# setup.sh apply re-run against the repo's base path)
#
# - `_do_reset` (declined = untouched; confirmed = conf removed, template
# reloaded, pending edits cleared)
#
# - `main` (subcommand dispatch including the `resources` direct jump and
# the `gpu` alias, unknown argument, `--lang` fallback notice, missing
# backend, cancel saves nothing)
#
# - a dead-code guard: every function setup_tui.sh defines has to be
# reachable from `dist/`, with the population derived from the file and the
# callers from the shipped tree rather than kept as a roster
#
# - the editors and menu arms the flow suite only ever spied on
# (`_tui_init_lang`, `_mark_removed` dedupe, the re-prompt paths in
# `_edit_section_network` / `_edit_section_deploy`, `_edit_section_gui` /
# `_volumes` / `_tmpfs`, the Advanced and Runtime menu arms,
# `_edit_stage_list` on an entry already in the config, and
# `_list_dockerfile_stages_available` de-duplicating a repeated stage)

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup_tui.sh

  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()

  _QFILE="${BATS_TEST_TMPDIR}/tui_queue"
  _MFILE="${BATS_TEST_TMPDIR}/tui_menu_rows"
  _BOXFILE="${BATS_TEST_TMPDIR}/tui_msgbox"
  : > "${_QFILE}"
  : > "${_MFILE}"
  : > "${_BOXFILE}"

  _tui_pop() {
    local _line
    _line="$(head -n 1 "${_QFILE}" 2>/dev/null || true)"
    [[ -z "${_line}" ]] && _line="1|"
    sed -i '1d' "${_QFILE}" 2>/dev/null || true
    printf '%s' "${_line#*|}"
    return "${_line%%|*}"
  }
  # Record what the user would have been shown. One row per line, a
  # `---` between renders, so a test can count renders as well as match
  # rows.
  _tui_menu() {
    printf '%s\n' "$@" >> "${_MFILE}"
    printf -- '---\n' >> "${_MFILE}"
    _tui_pop
  }
  _tui_select()    { _tui_pop; }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  _tui_checklist() { _tui_pop; }
  _tui_yesno()     {
    local _line
    _line="$(head -n 1 "${_QFILE}" 2>/dev/null || true)"
    [[ -z "${_line}" ]] && _line="1|"
    sed -i '1d' "${_QFILE}" 2>/dev/null || true
    return "${_line%%|*}"
  }
  _tui_msgbox() { printf '%s\n' "$@" >> "${_BOXFILE}"; return 0; }
  _tui_clear()  { return 0; }
  export -f _tui_pop _tui_menu _tui_select _tui_inputbox \
            _tui_radiolist _tui_checklist _tui_yesno _tui_msgbox _tui_clear
  export _QFILE _MFILE _BOXFILE
}

teardown() {
  return 0
}

# ── Stub helpers ─────────────────────────────────────────────────────────

queue() {
  : > "${_QFILE}"
  local _e
  for _e in "$@"; do
    printf '%s\n' "${_e}" >> "${_QFILE}"
  done
}

ovr_get() {
  local _k="${1}" i
  for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
    [[ "${_TUI_OVR_KEYS[i]}" == "${_k}" ]] && {
      printf '%s' "${_TUI_OVR_VALUES[i]}"
      return 0
    }
  done
  return 1
}

is_removed() {
  local _k="${1}" _r
  for _r in "${_TUI_REMOVED[@]}"; do
    [[ "${_r}" == "${_k}" ]] && return 0
  done
  return 1
}

# Was <row> one of the rows a menu was asked to render?
menu_row() { grep -Fqx -- "${1}" "${_MFILE}"; }

# How many menus were rendered?
menu_renders() { grep -c -- '^---$' "${_MFILE}"; }

# Did any msgbox carry <text>?
warned() { grep -Fq -- "${1}" "${_BOXFILE}"; }

# Did nothing pop a msgbox at all?
never_warned() { [[ ! -s "${_BOXFILE}" ]]; }

# ════════════════════════════════════════════════════════════════════
# _edit_section_build
# ════════════════════════════════════════════════════════════════════

# why: an unset target_arch / build network means "let BuildKit decide", not
# "empty". Rendering the raw value would print a row ending in a bare `=`,
# which reads as a broken menu rather than as a default.
@test "_edit_section_build: unset arch and network render a named default, never a blank" {
  queue "0|__back"
  _edit_section_build
  run grep -cE '=[[:space:]]*$' "${_MFILE}"
  [ "${output}" -eq 0 ]
}

# why: the badge exists so the user can see the current pin without opening
# the editor; showing the stored value is the whole point of the row.
@test "_edit_section_build: the menu shows the stored target_arch and network" {
  _override_set build.target_arch arm64
  _override_set build.network host
  queue "0|__back"
  _edit_section_build
  run grep -c -- ' = arm64$' "${_MFILE}"
  [ "${output}" -eq 1 ]
  run grep -c -- ' = host$' "${_MFILE}"
  [ "${output}" -eq 1 ]
}

# why: a build arg the user cleared is an opt-out, not an entry. Counting it
# would show "(3)" over a list the editor renders with two rows.
@test "_edit_section_build: the args badge counts populated slots only" {
  _TUI_CURRENT[build.arg_1]="A=1"
  _TUI_CURRENT[build.arg_2]="B=2"
  _TUI_CURRENT[build.arg_3]=""
  queue "0|__back"
  _edit_section_build
  menu_row "$(_tui_msg build.args.label) (2)"
}

# why: TARGETARCH reaches `docker build --platform`; an architecture BuildKit
# does not know fails the build long after the TUI closed, so the refusal
# belongs at the prompt and the previous pin must survive it.
@test "_edit_section_build: an unknown architecture is refused and the old pin survives" {
  _override_set build.target_arch arm64
  queue "0|target_arch" "0|sparc" "0|__back"
  _edit_section_build
  [[ "$(ovr_get build.target_arch)" == "arm64" ]]
  warned "$(_tui_msg err.invalid_target_arch)"
}

# why: the accepting half of the same gate -- a registered architecture has
# to reach the override, or the editor refuses everything.
@test "_edit_section_build: a BuildKit architecture is accepted" {
  queue "0|target_arch" "0|ppc64le" "0|__back"
  _edit_section_build
  [[ "$(ovr_get build.target_arch)" == "ppc64le" ]]
  never_warned
}

# why: clearing the field is how a user un-pins the architecture. Empty is a
# valid value here, not a validation failure, and it must be written rather
# than skipped -- setup.sh reads the empty key and omits TARGETARCH.
@test "_edit_section_build: an empty architecture clears the pin" {
  _override_set build.target_arch arm64
  queue "0|target_arch" "0|" "0|__back"
  _edit_section_build
  [[ "$(ovr_get build.target_arch)" == "" ]]
}

# why: `build.network` is passed straight to `docker build --network`; a
# value that flag rejects is a build failure, so it is refused here.
@test "_edit_section_build: a network mode docker build would reject is refused" {
  queue "0|network" "0|carrier-pigeon" "0|__back"
  _edit_section_build
  run ovr_get build.network
  [ "${status}" -ne 0 ]
  warned "$(_tui_msg err.invalid_build_network)"
}

# why: `host` is the documented workaround for hosts where bridge NAT is
# broken, so it has to survive the validator.
@test "_edit_section_build: host is an accepted build network" {
  queue "0|network" "0|host" "0|__back"
  _edit_section_build
  [[ "$(ovr_get build.network)" == "host" ]]
}

# why: Esc out of one field should return to the build menu, not leave the
# section -- otherwise a mistyped key drops the user back to the main menu
# and loses the rest of their edits.
@test "_edit_section_build: cancelling an input returns to the menu, not out of it" {
  _override_set build.target_arch arm64
  queue "0|target_arch" "1|" "0|__back"
  _edit_section_build
  [[ "$(ovr_get build.target_arch)" == "arm64" ]]
  [ "$(menu_renders)" -eq 2 ]
}

# why: the args row is a doorway into the shared list editor; the entries it
# writes have to land in [build] as arg_N, not in the editor's own section.
@test "_edit_section_build: args opens the shared list editor under [build]" {
  queue "0|args" "0|add" "0|FOO=bar" "0|back" "0|__back"
  _edit_section_build
  [[ "$(ovr_get build.arg_1)" == "FOO=bar" ]]
}

# why: Esc at the section menu is "I did not mean to open this"; it must
# leave without writing anything.
@test "_edit_section_build: Esc at the menu writes nothing" {
  queue "1|"
  run _edit_section_build
  assert_success
  [ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_security
# ════════════════════════════════════════════════════════════════════

# why: privileged defaults to true in this tree, and the row is the only
# place the user sees that before deciding. A blank row would read as "not
# set" over a container that runs privileged.
@test "_edit_section_security: the privileged row shows the effective default" {
  queue "0|__back"
  _edit_section_security
  menu_row "privileged = true"
}

# why: the yes/no answer is the whole decision; mapping it to a literal
# string is what compose reads. An inverted mapping silently grants
# privilege.
@test "_edit_section_security: answering yes writes privileged=true" {
  queue "0|privileged" "0|" "0|__back"
  _edit_section_security
  [[ "$(ovr_get security.privileged)" == "true" ]]
}

# why: the other half of the same mapping -- declining must write the
# explicit false, not leave the key absent and inherit true.
@test "_edit_section_security: answering no writes privileged=false" {
  queue "0|privileged" "1|" "0|__back"
  _edit_section_security
  [[ "$(ovr_get security.privileged)" == "false" ]]
}

# why: three separate lists share one menu, and their badges are counted in
# one pass over the same array. A prefix that matched too broadly would
# report cap_add's entries under cap_drop.
@test "_edit_section_security: each capability list counts only its own entries" {
  _TUI_CURRENT[security.cap_add_1]="SYS_ADMIN"
  _TUI_CURRENT[security.cap_drop_1]="NET_RAW"
  _TUI_CURRENT[security.cap_drop_2]="MKNOD"
  _TUI_CURRENT[security.security_opt_1]="seccomp:unconfined"
  queue "0|__back"
  _edit_section_security
  menu_row "$(_tui_msg security.cap_add) (1)"
  menu_row "$(_tui_msg security.cap_drop) (2)"
  menu_row "$(_tui_msg security.security_opt) (1)"
}

# why: Linux capability names are upper case; docker rejects the lower-case
# spelling, so the editor has to refuse it at the prompt and still accept
# the canonical one on the retry.
@test "_edit_section_security: cap_add refuses a lower-case capability, accepts the canonical one" {
  queue "0|cap_add" "0|add" "0|sys_admin" "0|SYS_ADMIN" "0|back" "0|__back"
  _edit_section_security
  [[ "$(ovr_get security.cap_add_1)" == "SYS_ADMIN" ]]
}

# why: cap_drop and security_opt route through the same generic editor as
# cap_add; each has to land under its own prefix or two lists collapse into
# one.
@test "_edit_section_security: cap_drop and security_opt write under their own prefixes" {
  queue "0|cap_drop" "0|add" "0|NET_RAW" "0|back" \
        "0|security_opt" "0|add" "0|seccomp:unconfined" "0|back" "0|__back"
  _edit_section_security
  [[ "$(ovr_get security.cap_drop_1)" == "NET_RAW" ]]
  [[ "$(ovr_get security.security_opt_1)" == "seccomp:unconfined" ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_logging_keys
# ════════════════════════════════════════════════════════════════════

# why: one editor serves [logging] and every [logging.<svc>]; the section it
# was opened for is the only thing that changes. Writing to the global key
# from the devel screen would silently retarget every service.
@test "_edit_logging_keys: a per-service edit lands in that service's section" {
  queue "0|driver" "0|json-file" "0|__back"
  _edit_logging_keys logging.devel
  [[ "$(ovr_get logging.devel.driver)" == "json-file" ]]
  run ovr_get logging.driver
  [ "${status}" -ne 0 ]
}

# why: the screen title is the only thing telling the user which service
# they are editing, since every row below it is identical across services.
@test "_edit_logging_keys: the per-service title names the service" {
  queue "0|__back"
  _edit_logging_keys logging.test
  run grep -c -- 'test' "${_MFILE}"
  [ "${output}" -ge 1 ]
}

# why: an unset key inherits from the global block. Rendering it as blank
# would be indistinguishable from "set to empty", which is a different
# compose output.
@test "_edit_logging_keys: unset keys render as inherit, a set key renders its value" {
  _override_set logging.driver json-file
  queue "0|__back"
  _edit_logging_keys logging
  menu_row "$(_tui_msg logging.driver.label) = json-file"
  run grep -c -- '(inherit)$' "${_MFILE}"
  [ "${output}" -ge 1 ]
}

# why: the driver name reaches compose verbatim; a name with a leading digit
# or a space is not a driver docker can resolve, and the failure would
# surface at `docker compose up`, not here.
@test "_edit_logging_keys: a malformed driver name is refused" {
  queue "0|driver" "0|1nvalid name" "0|__back"
  _edit_logging_keys logging
  run ovr_get logging.driver
  [ "${status}" -ne 0 ]
  warned "$(_tui_msg err.invalid_log_driver)"
}

# why: `max-size` without a unit is not a size docker accepts; the editor
# has to send the user back and then take the corrected value.
@test "_edit_logging_keys: max_size without a unit is refused, then accepted with one" {
  queue "0|max_size" "0|10" "0|max_size" "0|10m" "0|__back"
  _edit_logging_keys logging
  [[ "$(ovr_get logging.max_size)" == "10m" ]]
  warned "$(_tui_msg err.invalid_log_max_size)"
}

# why: `max-file` is a count of rotated files; 0 would mean "keep no logs",
# which docker rejects outright.
@test "_edit_logging_keys: max_file rejects zero and takes a positive count" {
  queue "0|max_file" "0|0" "0|max_file" "0|3" "0|__back"
  _edit_logging_keys logging
  [[ "$(ovr_get logging.max_file)" == "3" ]]
}

# why: compress is a compose boolean, so the yes/no answer has to become the
# literal `true` / `false` and not the shell's exit status.
@test "_edit_logging_keys: compress writes the boolean the user answered" {
  queue "0|compress" "0|" "0|__back"
  _edit_logging_keys logging
  [[ "$(ovr_get logging.compress)" == "true" ]]
  queue "0|compress" "1|" "0|__back"
  _edit_logging_keys logging
  [[ "$(ovr_get logging.compress)" == "false" ]]
}

# why: a whitespace-only path would be created by the apply step as a
# directory whose name is a space, and the emitted compose YAML would carry
# an empty bind source.
@test "_edit_logging_keys: a whitespace-only local_path is refused" {
  queue "0|local_path" "0|   " "0|__back"
  _edit_logging_keys logging
  run ovr_get logging.local_path
  [ "${status}" -ne 0 ]
  warned "$(_tui_msg err.invalid_log_local_path)"
}

# why: a real path has to get through, or the whole local_path feature is
# unreachable from the TUI.
@test "_edit_logging_keys: a real local_path is stored" {
  queue "0|local_path" "0|/var/log/base" "0|__back"
  _edit_logging_keys logging
  [[ "$(ovr_get logging.local_path)" == "/var/log/base" ]]
}

# why: the section is the namespace every write is keyed on. Defaulting it
# would write `.driver` into no section at all, so the editor refuses
# instead of guessing.
@test "_edit_logging_keys: refuses to open without a section" {
  run _edit_logging_keys
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_resources
# ════════════════════════════════════════════════════════════════════

# why: with ipc=host the container shares the host's /dev/shm and shm_size
# does nothing. Saying so is the point of the advisory -- but the value is
# still stored, because the user may flip ipc later and expect it to be
# there.
@test "_edit_section_resources: warns that shm_size is inert under ipc=host, and still stores it" {
  _override_set network.ipc host
  queue "0|1g"
  _edit_section_resources
  warned "$(_tui_msg resources.title)"
  [[ "$(ovr_get resources.shm_size)" == "1g" ]]
}

# why: the advisory must not fire when the setting does take effect, or it
# becomes noise the user learns to dismiss.
@test "_edit_section_resources: stays silent when ipc is not host" {
  _override_set network.ipc private
  queue "0|2g"
  _edit_section_resources
  never_warned
  [[ "$(ovr_get resources.shm_size)" == "2g" ]]
}

# why: Esc is not "set it to empty". Cancelling has to leave the stored size
# exactly as it was.
@test "_edit_section_resources: cancelling leaves the stored size untouched" {
  _override_set network.ipc private
  _override_set resources.shm_size 2g
  queue "1|"
  _edit_section_resources
  [[ "$(ovr_get resources.shm_size)" == "2g" ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_devices / _edit_section_ports
# ════════════════════════════════════════════════════════════════════

# why: [devices] holds two unrelated lists behind one menu. A device entry
# filed as a cgroup rule (or the reverse) is emitted into the wrong compose
# key and the device never appears in the container.
@test "_edit_section_devices: device and cgroup_rule write to their own lists" {
  queue "0|device" "0|add" "0|/dev/ttyUSB0:/dev/ttyUSB0" "0|back" \
        "0|cgroup_rule" "0|add" "0|c 189:* rwm" "0|back" "0|back"
  _edit_section_devices
  [[ "$(ovr_get devices.device_1)" == "/dev/ttyUSB0:/dev/ttyUSB0" ]]
  [[ "$(ovr_get devices.cgroup_rule_1)" == "c 189:* rwm" ]]
}

# why: published ports are dropped by compose under network_mode host/none,
# so a user editing them there gets no error and no ports. The advisory is
# the only signal, and the entry is still accepted for when they switch to
# bridge.
@test "_edit_section_ports: warns that a non-bridge mode will drop the mapping" {
  _override_set network.mode host
  queue "0|add" "0|8080:80" "0|back"
  _edit_section_ports
  warned "$(_tui_msg ports.title)"
  [[ "$(ovr_get network.port_1)" == "8080:80" ]]
}

# why: under bridge the mapping does take effect, so the warning must not
# fire.
@test "_edit_section_ports: stays silent under bridge" {
  _override_set network.mode bridge
  queue "0|back"
  _edit_section_ports
  never_warned
}

# ════════════════════════════════════════════════════════════════════
# Per-stage editors
# ════════════════════════════════════════════════════════════════════

# why: a Dockerfile with only baseline stages has nothing to override. The
# editor has to say so rather than open an empty menu the user can only
# back out of.
@test "_edit_section_per_stage: says so when the Dockerfile has no editable stage" {
  _list_dockerfile_stages_available() { local -n _o="${1}"; _o=(); }
  _edit_section_per_stage
  warned "$(_tui_msg per_stage.empty)"
  [ "$(menu_renders)" -eq 0 ]
}

# why: the stage list is where a user finds out which stages they have
# already customised. A stage with overrides and one without must not read
# the same.
@test "_edit_section_per_stage: labels a customised stage by count and an untouched one as inheriting" {
  _list_dockerfile_stages_available() { local -n _o="${1}"; _o=(devel-test extra); }
  _override_set "stage:devel-test.gui.mode" force
  queue "0|__back"
  _edit_section_per_stage
  menu_row "1 $(_tui_msg per_stage.overrides_set)"
  menu_row "$(_tui_msg per_stage.inherits_all)"
}

# why: clicking a stage row is how the per-stage editor is entered at all,
# and the stage name has to travel with the click.
@test "_edit_section_per_stage: clicking a stage opens that stage's editor" {
  _list_dockerfile_stages_available() { local -n _o="${1}"; _o=(extra); }
  _SEEN="${BATS_TEST_TMPDIR}/seen"
  _edit_per_stage_one() { printf '%s\n' "${1}" >> "${_SEEN}"; }
  queue "0|extra" "0|__back"
  _edit_section_per_stage
  grep -Fqx -- 'extra' "${_SEEN}"
}

# why: five sections share one submenu and each has its own editor. A row
# wired to the wrong editor writes a correct-looking key into the wrong
# section of the stage.
@test "_edit_per_stage_one: each row opens its own stage editor with the stage name" {
  _SEEN="${BATS_TEST_TMPDIR}/seen"
  : > "${_SEEN}"
  _edit_stage_gui()         { printf 'gui %s\n' "${1}" >> "${_SEEN}"; }
  _edit_stage_deploy()      { printf 'deploy %s\n' "${1}" >> "${_SEEN}"; }
  _edit_stage_network()     { printf 'network %s\n' "${1}" >> "${_SEEN}"; }
  _edit_stage_volumes()     { printf 'volumes %s\n' "${1}" >> "${_SEEN}"; }
  _edit_stage_environment() { printf 'environment %s\n' "${1}" >> "${_SEEN}"; }
  queue "0|gui" "0|deploy" "0|network" "0|volumes" "0|environment" "0|__back"
  _edit_per_stage_one extra
  grep -Fqx -- 'gui extra' "${_SEEN}"
  grep -Fqx -- 'deploy extra' "${_SEEN}"
  grep -Fqx -- 'network extra' "${_SEEN}"
  grep -Fqx -- 'volumes extra' "${_SEEN}"
  grep -Fqx -- 'environment extra' "${_SEEN}"
}

# why: a per-stage key only overrides its stage if it is written under the
# `stage:<name>.` namespace; the same key without it is a global change.
@test "_edit_stage_deploy: a picked key is written under the stage's deploy namespace" {
  queue "0|gpu_count" "0|2" "0|__back"
  _edit_stage_deploy extra
  [[ "$(ovr_get 'stage:extra.deploy.gpu_count')" == "2" ]]
  run ovr_get deploy.gpu_count
  [ "${status}" -ne 0 ]
}

# why: a stage with no override inherits the top-level value, and the row
# has to say that rather than show an empty cell.
@test "_edit_stage_deploy: unset keys show the inherit placeholder" {
  queue "0|__back"
  _edit_stage_deploy extra
  run grep -c -- "^$(_tui_msg per_stage.inherits_all)$" "${_MFILE}"
  [ "${output}" -eq 4 ]
}

# why: privileged is bundled into the stage's network screen for the user's
# convenience, but it lives in [security] in setup.conf. Writing it under
# `network.` would produce a key nothing reads.
@test "_edit_stage_network: privileged is written into the stage's security section" {
  queue "0|privileged" "0|false" "0|__back"
  _edit_stage_network extra
  [[ "$(ovr_get 'stage:extra.security.privileged')" == "false" ]]
  run ovr_get 'stage:extra.network.privileged'
  [ "${status}" -ne 0 ]
}

# why: the three scalar rows share one dispatch arm; each has to keep its
# own dotted key or they overwrite one another.
@test "_edit_stage_network: mode, ipc and network_name keep their own keys" {
  queue "0|mode" "0|bridge" "0|ipc" "0|private" "0|network_name" "0|devnet" "0|__back"
  _edit_stage_network extra
  [[ "$(ovr_get 'stage:extra.network.mode')" == "bridge" ]]
  [[ "$(ovr_get 'stage:extra.network.ipc')" == "private" ]]
  [[ "$(ovr_get 'stage:extra.network.network_name')" == "devnet" ]]
}

# why: the ports row is a sub-list, not a scalar; its entries have to land
# as numbered port_N keys inside the stage's network section.
@test "_edit_stage_network: ports opens the stage's own port list" {
  queue "0|ports" "0|add" "0|8080:80" "0|__back" "0|__back"
  _edit_stage_network extra
  [[ "$(ovr_get 'stage:extra.network.port_1')" == "8080:80" ]]
}

# why: an empty scalar is how a stage gives an override back; it must mark
# the key removed rather than store an empty string, which is a different
# compose result.
@test "_edit_stage_scalar: an empty value hands the key back to the top level" {
  _override_set 'stage:extra.deploy.gpu_count' 4
  queue "0|"
  _edit_stage_scalar extra deploy.gpu_count
  is_removed 'stage:extra.deploy.gpu_count'
}

# why: volumes and environment are the same list editor with different
# arguments; each must keep its own section and prefix.
@test "_edit_stage_volumes / _edit_stage_environment: each writes under its own section" {
  queue "0|add" "0|/tmp:/tmp" "0|__back"
  _edit_stage_volumes extra
  [[ "$(ovr_get 'stage:extra.volumes.mount_1')" == "/tmp:/tmp" ]]
  queue "0|add" "0|FOO=bar" "0|__back"
  _edit_stage_environment extra
  [[ "$(ovr_get 'stage:extra.environment.env_1')" == "FOO=bar" ]]
}

# ════════════════════════════════════════════════════════════════════
# _commit_and_setup
# ════════════════════════════════════════════════════════════════════

# Point the editor's setup.sh invocation at a recorder, and its template
# directory at the test's own scratch dir. Both are plain variables;
# FILE_PATH is readonly and is never written to by anything here.
stub_apply() {
  _APPLY="${BATS_TEST_TMPDIR}/apply_args"
  : > "${_APPLY}"
  _TUI_SCRIPT_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${_TUI_SCRIPT_DIR}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "${_APPLY}"
  } > "${_TUI_SCRIPT_DIR}/setup.sh"
  chmod +x "${_TUI_SCRIPT_DIR}/setup.sh"
  _TUI_TPL_DIR="${BATS_TEST_TMPDIR}"
  export _APPLY
}

# why: the value the user typed is the whole reason the TUI exists; it has
# to reach the file on disk, not just the in-memory override array.
@test "_commit_and_setup: the edited value reaches the saved conf" {
  stub_apply
  local _tpl="${BATS_TEST_TMPDIR}/tpl.conf"
  local _repo="${BATS_TEST_TMPDIR}/.setup.conf"
  printf '[network]\nmode = host\n' > "${_tpl}"
  _load_current "${_repo}" "${_tpl}"
  _override_set network.mode bridge
  _commit_and_setup "${_repo}" "${_tpl}"
  grep -Eq '^mode[[:space:]]*=[[:space:]]*bridge$' "${_repo}"
}

# why: the TUI edits one key at a time but saves the whole file. A baseline
# key the user never opened must survive the save, or every edit silently
# resets the rest of the config.
@test "_commit_and_setup: a key the user never touched survives the save" {
  stub_apply
  local _tpl="${BATS_TEST_TMPDIR}/tpl.conf"
  local _repo="${BATS_TEST_TMPDIR}/.setup.conf"
  printf '[network]\nmode = host\nipc = shareable\n' > "${_tpl}"
  _load_current "${_repo}" "${_tpl}"
  _override_set network.mode bridge
  _commit_and_setup "${_repo}" "${_tpl}"
  grep -Eq '^ipc[[:space:]]*=[[:space:]]*shareable$' "${_repo}"
}

# why: .env.generated and compose.yaml are derived from setup.conf, so a
# save that does not re-run apply leaves the container running the previous
# configuration while the file says otherwise.
@test "_commit_and_setup: re-runs setup.sh apply for the repo it saved" {
  stub_apply
  local _tpl="${BATS_TEST_TMPDIR}/tpl.conf"
  local _repo="${BATS_TEST_TMPDIR}/.setup.conf"
  printf '[network]\nmode = host\n' > "${_tpl}"
  _load_current "${_repo}" "${_tpl}"
  _commit_and_setup "${_repo}" "${_tpl}"
  grep -q -- 'apply' "${_APPLY}"
  grep -q -- '--base-path' "${_APPLY}"
}

# why: the saved path is the one thing the user needs after curses clears
# the screen; printing it is how they know where the edit went.
@test "_commit_and_setup: reports the path it saved" {
  stub_apply
  local _tpl="${BATS_TEST_TMPDIR}/tpl.conf"
  local _repo="${BATS_TEST_TMPDIR}/.setup.conf"
  printf '[network]\nmode = host\n' > "${_tpl}"
  _load_current "${_repo}" "${_tpl}"
  run _commit_and_setup "${_repo}" "${_tpl}"
  assert_success
  assert_output --partial "${_repo}"
}

# ════════════════════════════════════════════════════════════════════
# _do_reset
# ════════════════════════════════════════════════════════════════════

# Intercept the one destructive call in this file. `rm` is a shell function
# here, which both keeps the delete off the shared source tree and makes
# "reset removes the per-repo conf" an assertion rather than a hope. _RMLOG
# is deliberately NOT `local`: the override outlives the test body, and a
# dead local would leave it appending to an empty path.
stub_rm() {
  _RMLOG="${BATS_TEST_TMPDIR}/rm_args"
  : > "${_RMLOG}"
  rm() { printf '%s\n' "$*" >> "${_RMLOG}"; }
}

# why: reset is destructive, so declining the confirmation has to change
# nothing at all -- no delete, no apply, no loss of the edits in progress.
@test "_do_reset: declining the confirmation changes nothing" {
  stub_apply
  stub_rm
  _override_set network.mode bridge
  queue "1|"
  _do_reset
  unset -f rm
  [ ! -s "${_RMLOG}" ]
  [ ! -s "${_APPLY}" ]
  [[ "$(ovr_get network.mode)" == "bridge" ]]
}

# why: reset means "go back to the template". That is three things at once
# -- drop the per-repo file, re-seed it from the template, and throw away
# the pending edits -- and leaving any one of them out gives the user a
# menu that still shows values the file no longer has.
@test "_do_reset: confirmed, it drops the conf, re-applies and clears pending edits" {
  stub_apply
  stub_rm
  printf '[network]\nmode = none\n' > "${BATS_TEST_TMPDIR}/.setup.conf"
  _override_set network.mode bridge
  _mark_removed network.ipc
  queue "0|"
  _do_reset
  unset -f rm
  grep -q -- '.setup.conf' "${_RMLOG}"
  grep -q -- 'apply' "${_APPLY}"
  [ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]
  [ "${#_TUI_REMOVED[@]}" -eq 0 ]
  [[ "${_TUI_CURRENT[network.mode]}" == "none" ]]
  warned "$(_tui_msg reset.done)"
}

# ════════════════════════════════════════════════════════════════════
# main
# ════════════════════════════════════════════════════════════════════

# Everything main touches outside its own argument handling, replaced by a
# recorder. _commit_and_setup is a spy because the real one writes under
# FILE_PATH, which this suite shares with every other spec running in
# parallel.
stub_main_deps() {
  stub_apply
  _MARK="${BATS_TEST_TMPDIR}/marks"
  : > "${_MARK}"
  export _MARK
  _transcript_begin()  { return 0; }
  _transcript_detach() { return 0; }
  _run_pre_hook()      { return 0; }
  _run_post_hook()     { printf 'post_hook\n' >> "${_MARK}"; }
  _backend_detect()    { TUI_BACKEND="stub"; return 0; }
  _load_current()      { return 0; }
  _commit_and_setup()  { printf 'commit %s\n' "${1}" >> "${_MARK}"; }
  _render_main_menu()  {
    printf 'main_menu\n' >> "${_MARK}"
    return "${_MENU_RC:-0}"
  }
  _edit_section_resources() { printf 'edit resources\n' >> "${_MARK}"; }
  _edit_section_deploy()    { printf 'edit deploy\n' >> "${_MARK}"; }
}

# why: `resources` is a SCHEMA_SECTIONS member, so `_tui_known_subcommand`
# accepts it and main dispatches straight to `_edit_section_<name>`. That
# CLI path is the section editor's only caller -- no menu row reaches it --
# and this is the test that says so.
@test "main: a section subcommand jumps straight to that section's editor" {
  stub_main_deps
  run main resources
  assert_success
  grep -Fqx -- 'edit resources' "${_MARK}"
}

# why: `deploy` is Compose's name for the GPU section and collides with
# `setup.sh deploy`; `gpu` is the unambiguous spelling of the same editor.
# The alias has to resolve to the same editor and stay silent about a
# collision the user has already avoided.
@test "main: the gpu alias opens the deploy editor without the collision notice" {
  stub_main_deps
  run main gpu
  assert_success
  grep -Fqx -- 'edit deploy' "${_MARK}"
  never_warned
}

# why: the colliding spelling still works, but the user is told which of the
# two `deploy` commands they just got. Dropping the notice makes the two
# indistinguishable.
@test "main: the deploy spelling opens the same editor and says which deploy it is" {
  stub_main_deps
  run main deploy
  assert_success
  grep -Fqx -- 'edit deploy' "${_MARK}"
  warned "$(_tui_msg deploy.ambiguous.title)"
}

# why: an argument that is not a section is a typo, and silently opening the
# main menu would hide it.
@test "main: an argument that is not a section is reported" {
  stub_main_deps
  run main not-a-section
  assert_output --partial 'unknown argument'
}

# why: _sanitize_lang's stderr warning is wiped by curses before the user
# can read it, so the fallback has to be surfaced inside the TUI instead --
# carrying the rejected value, or the user cannot tell what was wrong.
@test "main: an unknown --lang falls back and says so inside the TUI" {
  stub_main_deps
  run main --lang klingon
  assert_success
  warned "klingon"
}

# why: without dialog or whiptail there is no TUI to run. Exiting 2 rather
# than 0 is what lets a wrapper tell "cancelled" from "cannot start".
@test "main: exits 2 when no dialog backend is installed" {
  stub_main_deps
  _backend_detect() { return 1; }
  run main
  [ "${status}" -eq 2 ]
}

# why: Cancel at the main menu means discard. Committing anyway would write
# the partial edits the user just backed out of.
@test "main: cancelling the main menu saves nothing" {
  stub_main_deps
  _MENU_RC=1
  run main
  assert_success
  grep -Fqx -- 'main_menu' "${_MARK}"
  run grep -c -- '^commit ' "${_MARK}"
  [ "${output}" -eq 0 ]
}

# why: Save & Exit is the only path that writes, and the post-tui hook fires
# after the write so a repo's hook sees the regenerated compose.yaml.
@test "main: Save & Exit commits and then runs the post hook" {
  stub_main_deps
  _MENU_RC=0
  run main
  assert_success
  run grep -c -- '^commit ' "${_MARK}"
  [ "${output}" -eq 1 ]
  grep -Fqx -- 'post_hook' "${_MARK}"
}

# why: on a repo that has never been set up there is no .setup.conf to load,
# so the menus would open on an empty config. main seeds it by running apply
# first; skipping that is how mount_1 detection went missing.
@test "main: seeds the per-repo conf with an apply run when none exists" {
  stub_main_deps
  _MENU_RC=0
  run main
  assert_success
  grep -q -- 'apply' "${_APPLY}"
}

# why: -h must print usage rather than open the TUI, and it is the one path
# a user reaches when they do not know the subcommand names.
@test "main: -h prints usage and does not open the menu" {
  stub_main_deps
  run main -h
  assert_success
  run grep -c -- 'main_menu' "${_MARK}"
  [ "${output}" -eq 0 ]
}

# why: `gpu` is an alias, not a section; everything else is its own name.
# Canonicalising the wrong way round would send `deploy` to a
# `_edit_section_gpu` that does not exist.
@test "_tui_canonical_section: gpu resolves to deploy, other names are themselves" {
  [[ "$(_tui_canonical_section gpu)" == "deploy" ]]
  [[ "$(_tui_canonical_section deploy)" == "deploy" ]]
  [[ "$(_tui_canonical_section network)" == "network" ]]
}

# ════════════════════════════════════════════════════════════════════
# Dead-code guard
# ════════════════════════════════════════════════════════════════════

# why: base#1073 found three functions in setup_tui.sh with no caller, and
# one of them had three specs -- so a test suite is not evidence that
# production code is reachable. A hand-kept roster of "known dead" would go
# stale the moment a caller is deleted, so the population is derived from
# the file and the callers from the shipped tree. Dynamic dispatch is
# honoured rather than special-cased: a `"_prefix_${var}"` construct in the
# file makes every `_prefix_*` function reachable, which is how
# `_edit_section_resources` -- whose only caller is main's
# `setup_tui.sh resources` direct jump -- stays in.
# unreachable_functions <setup_tui.sh path> <dist dir>
#
# Prints, one per line, every function <path> defines that nothing under
# <dist dir> can reach. Extracted from the guard so the guard can also be
# pointed at a scratch copy carrying a function planted to be dead: a
# check that only ever runs against a tree it passes on cannot say
# whether it would notice a new one.
unreachable_functions() {
  local _f="${1}" _dist="${2}"
  local _flat="${BATS_TEST_TMPDIR}/dist_code"
  # Callers, with whole-line comments dropped: a function named in prose
  # is documentation, not a use, and that is exactly what hid one of the
  # three.
  grep -rh --include='*.sh' -vE '^[[:space:]]*#' "${_dist}" > "${_flat}"
  local -a _defs=() _prefixes=() _dead=()
  mapfile -t _defs < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${_f}" \
    | sed 's/()$//')
  mapfile -t _prefixes < <(grep -oE '"[A-Za-z_][A-Za-z0-9_]*_\$\{' "${_f}" \
    | sed -e 's/^"//' -e 's/\${$//' | sort -u)
  # Non-vacuity: a scan that found nothing to check must fail, not pass.
  [ "${#_defs[@]}" -gt 40 ] || return 1
  [ "${#_prefixes[@]}" -gt 0 ] || return 1
  local _fn _p _hits _reachable
  for _fn in "${_defs[@]}"; do
    _reachable=0
    for _p in "${_prefixes[@]}"; do
      [[ "${_fn}" == "${_p}"* ]] && _reachable=1 && break
    done
    (( _reachable )) && continue
    # One hit is the definition line itself; a caller is a second.
    _hits="$(grep -cE "(^|[^A-Za-z0-9_])${_fn}([^A-Za-z0-9_]|\$)" "${_flat}" \
      || true)"
    (( _hits <= 1 )) && _dead+=("${_fn}")
  done
  printf '%s\n' "${_dead[@]-}"
}

@test "setup_tui.sh: every function it defines is reachable from dist/" {
  local _got
  _got="$(unreachable_functions \
    /source/dist/script/docker/wrapper/setup_tui.sh /source/dist)"
  _got="$(printf '%s' "${_got}" | tr -d '[:space:]')"
  printf 'unreachable: %s\n' "${_got}" >&2
  [ -z "${_got}" ]
}

# why: main jumps straight to `"_edit_section_${_subcmd}"` for every name
# `_tui_known_subcommand` accepts, and that gate read the schema section
# list alone. `project` is on that list with a deliberate no-editor
# opt-out (schema.sh's SCHEMA_I18N note says the project name belongs in
# the gitignored .setup.conf.local, which the menu has no concept of), so
# `setup_tui.sh project` jumped to a function that does not exist -- a
# bash command-not-found, raised only after the backend probe and the
# seeding `setup.sh apply` run had already happened. Both directions are
# asserted over the whole SCHEMA_SECTIONS population, so a section that
# gains or loses an editor is covered without an edit here.
@test "main: every schema section opens its editor or is refused by name" {
  local _s
  for _s in "${SCHEMA_SECTIONS[@]}"; do
    stub_main_deps
    queue
    run main "${_s}"
    [[ "${output}" != *"command not found"* ]] || {
      printf 'section %s dispatched into nothing: %s\n' "${_s}" "${output}" >&2
      return 1
    }
    if ! declare -F "_edit_section_${_s}" >/dev/null; then
      [ "${status}" -ne 0 ]
      [[ "${output}" == *"${_s}"* ]]
    fi
  done
}

# why: the guard above is only worth its runtime if it would go red on a
# function that is dead TOMORROW, and the way it was first written it
# would not: an `_edit_section_*` name was waved through on the prefix
# alone, so a dead editor -- the majority of the file's functions by the
# dispatch it uses -- was invisible to it. This plants one of each kind
# in a scratch copy and requires the guard to name BOTH; the plain
# helper is the control that proves the planting itself works.
@test "the dead-code guard names a planted dead editor, not just a plain one" {
  local _scratch="${BATS_TEST_TMPDIR}/setup_tui_planted.sh"
  cp /source/dist/script/docker/wrapper/setup_tui.sh "${_scratch}"
  {
    printf '\n_edit_section_frobnicate() {\n  :\n}\n'
    printf '\n_plain_dead_helper() {\n  :\n}\n'
  } >> "${_scratch}"
  local _got
  _got="$(unreachable_functions "${_scratch}" /source/dist)"
  printf 'planted run reported: %s\n' "${_got}" >&2
  [[ "${_got}" == *_plain_dead_helper* ]]
  [[ "${_got}" == *_edit_section_frobnicate* ]]
}

# ════════════════════════════════════════════════════════════════════
# The editors the flow suite only ever spied on
# ════════════════════════════════════════════════════════════════════

# why: every message lookup goes through the table _tui_init_lang selects, so
# a locale that maps to the wrong table (or falls through to English) makes
# the whole TUI monolingual for that user. Checked through _tui_msg rather
# than the index variable: the table is what the user reads.
@test "_tui_init_lang: each supported locale selects its own message table" {
  local _lang _en
  _en="$(_LANG=en; _tui_init_lang; _tui_msg title)"
  for _lang in zh-TW zh-CN ja; do
    local _got
    _got="$(_LANG="${_lang}"; _tui_init_lang; _tui_msg title)"
    [[ -n "${_got}" ]]
    [[ "${_got}" != "${_en}" ]]
  done
  # An unknown value is English, not an empty table.
  [[ "$(_LANG=klingon; _tui_init_lang; _tui_msg title)" == "${_en}" ]]
}

# why: the removal list is replayed key by key when the file is written, so a
# key marked twice would be processed twice. Clearing the same entry from two
# screens is ordinary use.
@test "_mark_removed: marking the same key twice lists it once" {
  _mark_removed network.ipc
  _mark_removed network.ipc
  [ "${#_TUI_REMOVED[@]}" -eq 1 ]
}

# why: an invalid network name has to send the user back to the SAME field
# with what they typed still in it -- re-prompting from the old value throws
# away the correction they were making.
@test "_edit_section_network: a rejected network_name re-prompts and then accepts" {
  queue "0|bridge" "0|host" "0|private" "0|bad name" "0|devnet" "0|back"
  _edit_section_network
  [[ "$(ovr_get network.network_name)" == "devnet" ]]
  warned "$(_tui_msg err.invalid_network_name)"
}

# why: the shm_size prompt only appears when ipc is not host, and its
# rejection path is the one a user hits by typing a size without a unit.
@test "_edit_section_network: a rejected shm_size re-prompts and then accepts" {
  queue "0|host" "0|private" "0|private" "0|not-a-size" "0|1g"
  _edit_section_network
  [[ "$(ovr_get resources.shm_size)" == "1g" ]]
  warned "$(_tui_msg err.invalid_shm_size)"
}

# why: gpu_count reaches compose's `count:`; a value that is neither `all`
# nor a positive integer is refused rather than written, and the loop asks
# again instead of leaving the section.
@test "_edit_section_deploy: a rejected gpu_count re-prompts and then accepts" {
  _detect_mig() { return 1; }
  queue "0|auto" "0|zero" "0|2" "0|gpu" "0|auto"
  _edit_section_deploy
  [[ "$(ovr_get deploy.gpu_count)" == "2" ]]
  warned "$(_tui_msg err.invalid_gpu_count)"
}

# why: the runtime radio is the last step, and its rejection path does NOT
# loop -- it warns and leaves the key unwritten, so `runtime: nvidia` is
# never emitted from a value the resolver would not recognise.
@test "_edit_section_deploy: an unrecognised runtime is warned about, not written" {
  _detect_mig() { return 1; }
  queue "0|auto" "0|all" "0|gpu" "0|bogus"
  _edit_section_deploy
  run ovr_get deploy.gpu_runtime
  [ "${status}" -ne 0 ]
  warned "$(_tui_msg err.invalid_runtime)"
}

# why: `restart:` goes into compose verbatim; a policy docker does not know
# fails the service at start, so an unrecognised one is refused here and the
# key is left alone.
@test "_edit_section_lifecycle: an unrecognised restart policy is not written" {
  queue "0|sometimes"
  _edit_section_lifecycle
  run ovr_get lifecycle.restart
  [ "${status}" -ne 0 ]
  warned "$(_tui_msg err.invalid_restart)"
}

# why: the GUI editor is a single radio and the flow suite only ever proved
# the menu reaches it. Its job is to store the picked mode -- and to store
# nothing when the user escapes.
@test "_edit_section_gui: stores the picked mode, and nothing on Esc" {
  queue "0|force"
  _edit_section_gui
  [[ "$(ovr_get gui.mode)" == "force" ]]
  _TUI_OVR_KEYS=(); _TUI_OVR_VALUES=()
  queue "1|"
  _edit_section_gui
  [ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]
}

# why: volumes and tmpfs are one-line wrappers over the shared list editor,
# and the section/prefix pair they pass is the only thing that distinguishes
# them. A swapped pair files a bind mount as a tmpfs.
@test "_edit_section_volumes / _edit_section_tmpfs: each opens its own list" {
  queue "0|add" "0|/tmp:/tmp" "0|back"
  _edit_section_volumes
  [[ "$(ovr_get volumes.mount_1)" == "/tmp:/tmp" ]]
  queue "0|add" "0|/run:size=64m" "0|back"
  _edit_section_tmpfs
  [[ "$(ovr_get tmpfs.tmpfs_1)" == "/run:size=64m" ]]
}

# why: Advanced is the only route to security, named contexts and Reset, and
# the main menu is the only route to Advanced.
@test "_render_main_menu: advanced opens the advanced sub-menu" {
  _SEEN="${BATS_TEST_TMPDIR}/seen"
  _render_advanced_menu() { printf 'advanced\n' >> "${_SEEN}"; }
  queue "0|advanced" "0|__save"
  _render_main_menu
  grep -Fqx -- 'advanced' "${_SEEN}"
}

# why: the env-vars info page is guidance, not an editor -- the S2 invariant
# is that the TUI never writes .env. Reaching it must show the page and
# leave the config untouched.
@test "_render_runtime_menu: envinfo shows the guidance page and writes nothing" {
  queue "0|envinfo" "0|__back"
  _render_runtime_menu
  warned "$(_tui_msg envinfo.title)"
  [ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]
}

# why: the per-stage row is conditional on the Dockerfile having a
# non-baseline stage, and Reset is the destructive entry. Both are dispatched
# from this menu and nowhere else.
@test "_render_advanced_menu: offers per-stage when stages exist, and routes reset" {
  _list_dockerfile_stages_available() { local -n _o="${1}"; _o=(extra); }
  _SEEN="${BATS_TEST_TMPDIR}/seen"
  : > "${_SEEN}"
  _edit_section_per_stage() { printf 'per_stage\n' >> "${_SEEN}"; }
  _do_reset() { printf 'reset\n' >> "${_SEEN}"; }
  queue "0|per_stage" "0|reset" "0|__back"
  _render_advanced_menu
  menu_row "$(_tui_msg advanced.per_stage)"
  grep -Fqx -- 'per_stage' "${_SEEN}"
  grep -Fqx -- 'reset' "${_SEEN}"
}

# why: a stage list built only from pending overrides would not OFFER the
# entries already in setup.conf, and the user would have to retype a mount
# to change it. The row has to be rendered -- asserted here, because the
# queue would dispatch the click either way -- and editing it has to replace
# the value rather than append a second entry.
@test "_edit_stage_list: an entry already in the config is offered and can be edited" {
  _TUI_CURRENT[stage:extra.volumes.mount_1]="/a:/a"
  queue "0|mount_1" "0|/b:/b" "0|__back"
  _edit_stage_volumes extra
  menu_row "/a:/a"
  [[ "$(ovr_get 'stage:extra.volumes.mount_1')" == "/b:/b" ]]
  run ovr_get 'stage:extra.volumes.mount_2'
  [ "${status}" -ne 0 ]
}

# why: a Dockerfile that names one stage twice (a later `FROM ... AS extra`
# refining an earlier one) must offer that stage once; a duplicated row makes
# the per-stage menu look like there are two independent stages.
@test "_list_dockerfile_stages_available: a stage named twice is offered once" {
  local _d="${BATS_TEST_TMPDIR}/df"
  mkdir -p "${_d}"
  printf 'FROM alpine AS extra\nFROM alpine AS other\nFROM extra AS extra\n' \
    > "${_d}/Dockerfile"
  local -a _got=()
  _list_dockerfile_stages_available _got "${_d}"
  [ "${#_got[@]}" -eq 2 ]
  [[ "${_got[0]}" == "extra" ]]
  [[ "${_got[1]}" == "other" ]]
}
