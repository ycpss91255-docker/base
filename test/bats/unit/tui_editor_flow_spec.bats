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
# keyed on it is steered through `_TUI_BASE_PATH` / `_TUI_SCRIPT_DIR` /
# `_TUI_TPL_DIR`, which are plain variables -- `stub_chain` points the
# whole conf layer chain at the test's own scratch dirs.
#
# - Nothing here writes under `FILE_PATH`. The suite runs many-way
# parallel over one shared source tree, so every save and every reset in
# this file lands under `BATS_TEST_TMPDIR`, `setup.sh` is a recorder, and
# `main`'s commit is a spy.
#
# - The config assertions ask the REAL merge (`effective` /
# `effective_family`, over `_setup_conf_handle`), never a grep on file
# text. base#1115 / base#1117 / base#1175 measured what a text gate is
# worth: three greps claiming to pin `xhost` behaviour passed against a
# `run.sh` with no `xhost` in it.
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
# - the conf layer chain (`_load_current` opening on the effective
# configuration, `_tui_local_layer_notice` /
# `_tui_shadowed_sections` naming the per-worktree layer,
# `_tui_aot_families_touched` derived from the array-of-tables table)
#
# - `_commit_and_setup` (the saved value is the one the readers resolve,
# an inherited scalar is not pinned down, a touched array is saved whole,
# a declined write is reported rather than reported as saved, setup.sh
# apply re-run against the repo's base path)
#
# - `_do_reset` (declined = untouched; confirmed = `setup.sh reset`
# dispatched, chain reloaded, pending edits cleared, the per-worktree
# layer left alone)
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
            _tui_checklist _tui_yesno _tui_msgbox _tui_clear
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

# Both of these are called almost everywhere as `menu_row "$(_tui_msg
# <key>)"` / `warned "$(_tui_msg <key>)"`, and an empty needle makes
# grep match anything -- so blanking a message string in all four locale
# tables left every assertion about it passing while the user got an
# empty menu row or an empty warning box. A message that resolves to
# nothing is a failure here, not a wildcard.

# Was <row> one of the rows a menu was asked to render?
menu_row() {
  [ -n "${1}" ] || return 1
  grep -Fqx -- "${1}" "${_MFILE}"
}

# How many menus were rendered?
menu_renders() { grep -c -- '^---$' "${_MFILE}"; }

# Did any msgbox carry <text>?
warned() {
  [ -n "${1}" ] || return 1
  grep -Fq -- "${1}" "${_BOXFILE}"
}

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

# A whole conf layer chain under the test's own directories: the template
# layer in `<tmp>/tpl`, the repo's committed layer and the operator's
# per-worktree layer in `<tmp>/repo`. Both ends are plain variables
# (`_TUI_BASE_PATH` / `_TUI_TPL_DIR`), so the editor under test resolves
# the same three paths `_setup_conf_layers` names for a real repo while
# nothing is written under the readonly FILE_PATH this suite shares.
#
# `stub_apply` after this one, never before: it points _TUI_TPL_DIR at the
# bare tmpdir and would undo the template layer's location.
stub_chain() {
  _CHAIN_REPO="${BATS_TEST_TMPDIR}/repo"
  _CHAIN_TPL="${BATS_TEST_TMPDIR}/tpl"
  mkdir -p "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _TUI_BASE_PATH="${_CHAIN_REPO}"
  _TUI_TPL_DIR="${_CHAIN_TPL}"
}

# What the REAL readers resolve for `<section>.<key>` over the test's
# chain, printed. Asked of `_setup_conf_handle` -- the merge every other
# reader in the tree goes through -- so a test can say "the setting took
# effect" instead of "a line appeared in a file". base#1115 / base#1117 /
# base#1175 are what a grep on file text is worth: three greps pinning
# `xhost` behaviour passed against a run.sh with no `xhost` in it.
effective() {
  local _section="${1}" _key="${2}"
  _setup_conf_handle "${_CHAIN_REPO}" _EFF "${_CHAIN_TPL}" || return 1
  _conf_get _EFF "${_section}" "${_key}" ""
}

# Every entry the readers resolve for one numbered family, in index order,
# one per line. The family's PREFIX is derived from the array-of-tables
# table (`_conf_toml_aot_section`), not spelled here, so a test naming
# `volumes` gets whatever prefix that table says `volumes` numbers under.
effective_family() {
  local _section="${1}" _path="${2}"
  _setup_conf_handle "${_CHAIN_REPO}" _EFF "${_CHAIN_TPL}" || return 1
  local -a _fams=()
  _conf_toml_aot_section "${_section}" _fams || return 1
  local _f _prefix=""
  for _f in "${_fams[@]}"; do
    [[ "${_f#*=}" == "${_path}" ]] && _prefix="${_f%%=*}"
  done
  [[ -n "${_prefix}" ]] || return 1
  local -a _entries=()
  _conf_list_sorted _EFF "${_section}" "${_prefix}_" _entries
  printf '%s\n' "${_entries[@]+"${_entries[@]}"}"
}

# why: the value the user typed is the whole reason the TUI exists, and
# "reached a file" is not the claim -- the editor wrote <repo>/.setup.conf
# for the whole of ADR-00000037's freeze while every reader resolved the
# setup.toml chain, so a save printed its confirmation over a setting with
# no effect (base#1232). The assertion is therefore on what the REAL merge
# answers afterwards, through the same accessor setup.sh and the emitters
# use, not on a line in a file: a filename is not the property, the
# effective configuration is.
@test "_commit_and_setup: a saved value is the one the readers resolve" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  assert_equal "$(effective gui mode)" "auto"
  _override_set gui.mode force
  _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  assert_equal "$(effective gui mode)" "force"
}

# why: the menus have to open on the values IN FORCE. _load_current used to
# take two paths and read whichever existed first, so with a repo layer
# present the template's keys were invisible and with a per-worktree layer
# present its values were silently absent from the screen -- an editor
# whose baseline is one layer cannot show the user what is configured.
# Three layers, each contributing one key, is the smallest fixture in
# which reading any single file gives the wrong answer.
@test "_load_current: the baseline is the whole chain merged, not one file" {
  stub_chain
  printf '[gui]\nmode = "auto"\n\n[network]\nmode = "host"\nipc = "host"\n' \
    > "${_CHAIN_TPL}/setup.toml"
  printf '[network]\nmode = "bridge"\n' > "${_CHAIN_REPO}/setup.toml"
  printf '[network]\nipc = "shareable"\n' > "${_CHAIN_REPO}/setup.local.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  # template-only key, repo override, and the per-worktree layer's say.
  assert_equal "${_TUI_CURRENT[gui.mode]}" "auto"
  assert_equal "${_TUI_CURRENT[network.mode]}" "bridge"
  assert_equal "${_TUI_CURRENT[network.ipc]}" "shareable"
}

# why: a reload has to REPLACE the baseline. _do_reset reloads after
# dropping this repo's layer, and a merge into the previous map would keep
# showing keys the chain no longer resolves -- the user reads a value off
# a menu that nothing will emit.
@test "_load_current: a reload drops a key the chain no longer resolves" {
  stub_chain
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[network]\nmode = "bridge"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  assert_equal "${_TUI_CURRENT[network.mode]}" "bridge"
  rm -f "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  [ -z "${_TUI_CURRENT[network.mode]:-}" ]
  assert_equal "${_TUI_CURRENT[gui.mode]}" "auto"
}

# why: the baseline is now the EFFECTIVE configuration, so a save that
# wrote all of it would copy every inherited value down into this repo's
# committed file and the repo would stop tracking the template. Measured
# through the merge in BOTH directions, because either half alone passes
# on a wrong implementation: the key the user changed resolves to the new
# value, and the key the user never opened still resolves to the
# template's -- while this repo's own file does not name it.
@test "_commit_and_setup: an inherited scalar is not pinned into the repo layer" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  printf '[network]\nmode = "host"\nipc = "host"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[network]\nmode = "host"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _override_set network.mode bridge
  _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  assert_equal "$(effective network mode)" "bridge"
  assert_equal "$(effective network ipc)" "host"
  # Still inherited, not copied: the repo's layer says nothing about ipc.
  run grep -c 'ipc' "${_CHAIN_REPO}/setup.toml"
  assert_equal "${output}" "0"
}

# why: an array is replaced ATOMICALLY by the highest layer that declares
# it (ADR-00000037), so a repo layer naming ONE [[volumes]] entry replaces
# the inherited list with that single mount. A save that wrote only the
# slot the user touched would therefore delete the rest of the list with
# no message: adding a third mount to a template's two leaves the repo
# with the third alone, and slot 1 of [volumes] is the workspace bind. The
# population is read back through the real merge, so the claim is "the
# list the readers resolve", not "three blocks are in the file".
@test "_commit_and_setup: touching one array entry saves the whole list" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  cat > "${_CHAIN_TPL}/setup.toml" <<'EOF'
[[volumes]]
source = "./src"
target = "/opt/workspace"
mode = "rw"

[[volumes]]
source = "/dev/shm"
target = "/dev/shm"
mode = "rw"
EOF
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _override_set volumes.mount_3 '/data:/data:ro'
  _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  run effective_family volumes volumes
  assert_success
  assert_line --index 0 './src:/opt/workspace:rw'
  assert_line --index 1 '/dev/shm:/dev/shm:rw'
  assert_line --index 2 '/data:/data:ro'
}

# why: the mirror image of the rule above. A scalar section is merged key
# by key, so writing a key the user did not touch is the defect there --
# and an array is replaced whole, so NOT writing a sibling entry is the
# defect here. One fixture, one save, both answers, because an
# implementation that gets one right by writing everything or nothing gets
# the other wrong.
@test "_commit_and_setup: an untouched array keeps inheriting" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  cat > "${_CHAIN_TPL}/setup.toml" <<'EOF'
[gui]
mode = "auto"

[[volumes]]
source = "./src"
target = "/opt/workspace"
mode = "rw"
EOF
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _override_set gui.mode force
  _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  assert_equal "$(effective gui mode)" "force"
  run effective_family volumes volumes
  assert_line --index 0 './src:/opt/workspace:rw'
  # And the repo layer declares no volumes array at all, so the template's
  # list is still INHERITED rather than copied down.
  run grep -c 'volumes' "${_CHAIN_REPO}/setup.toml"
  assert_equal "${output}" "0"
}

# why: the published opt-out is to CLEAR mount_1, not to remove it
# (README: "clear it to opt out of mounting a workspace"; v0.9 rules that
# setup.sh does not re-populate it). Clearing is not removing, and the
# editor's save has to leave the clear exactly as the operator left it --
# a save that re-detected or dropped the slot would silently re-mount a
# workspace the operator opted out of.
@test "_commit_and_setup: a cleared mount_1 stays cleared through a save" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  cat > "${_CHAIN_TPL}/setup.toml" <<'EOF'
[gui]
mode = "auto"

[[volumes]]
source = ""
target = ""
EOF
  cat > "${_CHAIN_REPO}/setup.toml" <<'EOF'
[gui]
mode = "auto"

[[volumes]]
source = ""
target = ""
EOF
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _override_set gui.mode force
  _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  assert_equal "$(effective gui mode)" "force"
  # `_conf_list_sorted` skips empty entries, so an opted-out workspace is
  # an EMPTY family -- and the slot is still there to be filled back in.
  run effective_family volumes volumes
  assert_equal "${output}" ""
  assert_equal "$(effective volumes mount_1)" ""
}

# why: `_write_setup_conf` DECLINES a save it cannot make faithfully --
# `_wsc_refuse_ws_slot_move` is the live case: removing volumes.mount_1
# compacts the list, so the next mount would take slot 1, which is the
# workspace bind by position. It returns non-zero with the destination
# untouched. The editor runs under `set -e`, so left unchecked that
# aborted mid-curses with only the writer's log line; and a save that
# reported success over a file it never wrote is the exact failure
# base#1232 exists to end. So: non-zero out, the repo layer byte-identical,
# and NO apply run -- regenerating from a config that did not change is
# the step that would make the refusal look like a save.
@test "_commit_and_setup: a declined write is reported, not reported as saved" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  cat > "${_CHAIN_REPO}/setup.toml" <<'EOF'
[[volumes]]
source = "./src"
target = "/opt/workspace"
mode = "rw"

[[volumes]]
source = "/data"
target = "/data"
mode = "rw"
EOF
  cp "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  local _before
  _before="$(cat "${_CHAIN_REPO}/setup.toml")"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _mark_removed volumes.mount_1
  run _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  assert_failure
  refute_output --partial "$(printf "$(_tui_msg saved)" "x")"
  assert_equal "$(cat "${_CHAIN_REPO}/setup.toml")" "${_before}"
  [ ! -s "${_APPLY}" ]
}

# why: .env.generated and compose.yaml are derived from setup.toml, so a
# save that does not re-run apply leaves the container running the previous
# configuration while the file says otherwise. The base path it hands over
# has to be the repo the editor just wrote, not the tree setup_tui.sh was
# sourced from.
@test "_commit_and_setup: re-runs setup.sh apply for the repo it saved" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  printf '[network]\nmode = "host"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[network]\nmode = "host"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  grep -q -- 'apply' "${_APPLY}"
  grep -q -- "--base-path ${_CHAIN_REPO}" "${_APPLY}"
}

# why: the saved path is the one thing the user needs after curses clears
# the screen; printing it is how they know where the edit went.
@test "_commit_and_setup: reports the path it saved" {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  printf '[network]\nmode = "host"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[network]\nmode = "host"\n' > "${_CHAIN_REPO}/setup.toml"
  _load_current "${_CHAIN_REPO}" "${_CHAIN_TPL}"
  run _commit_and_setup "${_CHAIN_REPO}/setup.toml" "${_CHAIN_TPL}/setup.toml"
  assert_success
  assert_output --partial "${_CHAIN_REPO}/setup.toml"
}

# ════════════════════════════════════════════════════════════════════
# The per-worktree layer -- named, never silently winning
# ════════════════════════════════════════════════════════════════════

# why: the menus show the EFFECTIVE values, that layer included, and a
# save goes to the COMMITTED one. Without the notice the operator reads a
# setup.local.toml value off the screen, changes the same section, and
# sees no difference on this machine -- the shape
# `_setup_warn_shadowed_write` already warns about at the CLI, which logs
# and is therefore invisible once curses owns the terminal. The sections
# are named, not just the fact, because that is what makes it actionable.
@test "_tui_local_layer_notice: names the per-worktree file and its sections" {
  stub_chain
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[gui]\nmode = "off"\n\n[network]\nmode = "bridge"\n' \
    > "${_CHAIN_REPO}/setup.local.toml"
  _tui_local_layer_notice "${_CHAIN_REPO}"
  warned "$(_setup_conf_local_path "${_CHAIN_REPO}")"
  warned 'gui'
  warned 'network'
}

# why: a notice that fires on every launch is a notice nobody reads. No
# per-worktree layer is the ordinary case and has to stay silent.
@test "_tui_local_layer_notice: silent when there is no per-worktree layer" {
  stub_chain
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_TPL}/setup.toml"
  _tui_local_layer_notice "${_CHAIN_REPO}"
  [ ! -s "${_BOXFILE}" ]
}

# why: the save-time half. A write to a section the per-worktree layer
# also defines may be inert HERE while still being the committed value for
# every other checkout, so it is reported rather than refused -- the same
# asymmetry `_setup_warn_shadowed_write` settles for `setup.sh set`. It
# names only the sections this session actually touched: re-reading the
# whole launch notice at the user would bury the one that matters.
@test "_tui_shadowed_sections: only the touched sections the local layer defines" {
  stub_chain
  printf '[gui]\nmode = "off"\n\n[network]\nmode = "bridge"\n' \
    > "${_CHAIN_REPO}/setup.local.toml"
  _override_set gui.mode force
  _override_set security.privileged false
  local -a _got=()
  _tui_shadowed_sections "${_CHAIN_REPO}" _got
  assert_equal "${#_got[@]}" "1"
  assert_equal "${_got[0]}" "gui"
}

# why: a removal is a write too -- clearing an entry of a list the local
# layer replaces whole is exactly as inert as setting a key it names, and
# a check that read the overrides alone reported nothing to warn about.
@test "_tui_shadowed_sections: a removal counts as touching the section" {
  stub_chain
  printf '[[volumes]]\nsource = "/d"\ntarget = "/d"\n' \
    > "${_CHAIN_REPO}/setup.local.toml"
  _mark_removed volumes.mount_2
  local -a _got=()
  _tui_shadowed_sections "${_CHAIN_REPO}" _got
  assert_equal "${#_got[@]}" "1"
  assert_equal "${_got[0]}" "volumes"
}

# why: which keys a save has to carry WHOLE is the array question, and the
# answer has to come off `_conf_toml_aot_section`'s `<prefix>=<path>`
# table rather than a roster here -- a test naming today's families passes
# forever while a new one silently loses its siblings on every save
# (base#1089 / base#1112 / base#1214). So the population is DERIVED: every
# section the schema has, every family that table gives it, one touched key
# each, and the family's path has to come back. `[environment]`'s `env_N`
# is excluded by having no row, which is the state base#1235 leaves open.
@test "_tui_aot_families_touched: derives the families from the array table" {
  local _section _fam _prefix _path
  local -a _fams=()
  local _checked=0
  for _section in "${SCHEMA_SECTIONS[@]}"; do
    _conf_toml_aot_section "${_section}" _fams || continue
    for _fam in "${_fams[@]}"; do
      _prefix="${_fam%%=*}"
      _path="${_fam#*=}"
      _TUI_OVR_KEYS=()
      _TUI_OVR_VALUES=()
      _TUI_REMOVED=()
      _override_set "${_section}.${_prefix}_1" 'x'
      local -a _got=()
      _tui_aot_families_touched _got
      assert_equal "${#_got[@]}" "1"
      assert_equal "${_got[0]}" "${_path}"
      _checked=$(( _checked + 1 ))
    done
  done
  # The derivation has to have found families, not silently nothing.
  [ "${_checked}" -ge 8 ]
}

# why: a scalar key must NOT drag its section's list into the save -- that
# is the other half of the rule, and an implementation that answers "every
# family of the touched section" would pass the derivation above and still
# rewrite [volumes] every time the user edits a mount's neighbour.
@test "_tui_aot_families_touched: a scalar key touches no family" {
  _override_set gui.mode force
  _override_set security.privileged false
  _override_set environment.env_1 'FOO=bar'
  local -a _got=()
  _tui_aot_families_touched _got
  assert_equal "${#_got[@]}" "0"
}

# ════════════════════════════════════════════════════════════════════
# _do_reset
# ════════════════════════════════════════════════════════════════════

# why: reset is destructive, so declining the confirmation has to change
# nothing at all -- nothing run, no loss of the edits in progress.
@test "_do_reset: declining the confirmation changes nothing" {
  stub_chain
  stub_apply
  _override_set network.mode bridge
  queue "1|"
  _do_reset
  [ ! -s "${_APPLY}" ]
  [[ "$(ovr_get network.mode)" == "bridge" ]]
}

# why: reset means "go back to the template". That is three things at once
# -- drop this repo's own layer, re-seed it from the template, and throw
# away the pending edits -- and leaving any one of them out gives the user
# a menu that still shows values the chain no longer resolves. The drop is
# delegated to `setup.sh reset`, which IS "replace the repo's setup.toml
# with the template baseline" and archives the file it replaces; a second
# `rm -f` here would be a second meaning for Reset. So the assertions are
# that the subcommand was dispatched, that apply followed it, and that the
# baseline afterwards is what the REAL merge answers -- the template's
# value, not the override the user had pending.
@test "_do_reset: confirmed, it resets through setup.sh, re-applies and clears edits" {
  stub_chain
  stub_apply
  printf '[network]\nmode = "none"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[network]\nmode = "bridge"\n' > "${_CHAIN_REPO}/setup.toml"
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  # The recorder does not actually reset, so do what it stands for.
  rm -f "${_CHAIN_REPO}/setup.toml"
  _override_set network.mode host
  _mark_removed network.ipc
  queue "0|"
  _do_reset
  grep -q -- 'reset --yes' "${_APPLY}"
  grep -q -- 'apply' "${_APPLY}"
  grep -q -- "--base-path ${_CHAIN_REPO}" "${_APPLY}"
  [ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]
  [ "${#_TUI_REMOVED[@]}" -eq 0 ]
  assert_equal "${_TUI_CURRENT[network.mode]}" "none"
  warned "$(_tui_msg reset.done)"
}

# why: reset drops THIS REPO's layer and the operator's per-worktree file
# is not this repo's -- it is gitignored, never touched by tooling, and
# `setup.sh reset` leaves it alone. So a reset on a machine carrying one
# does not go "back to template defaults" there, and the menus have to
# keep showing what is actually in force rather than the template.
@test "_do_reset: the per-worktree layer survives a reset and still shows" {
  stub_chain
  stub_apply
  printf '[gui]\nmode = "auto"\n' > "${_CHAIN_TPL}/setup.toml"
  printf '[gui]\nmode = "off"\n' > "${_CHAIN_REPO}/setup.local.toml"
  _TUI_TPL_DIR="${_CHAIN_TPL}"
  queue "0|"
  _do_reset
  [ -f "${_CHAIN_REPO}/setup.local.toml" ]
  assert_equal "${_TUI_CURRENT[gui.mode]}" "off"
}

# ════════════════════════════════════════════════════════════════════
# main
# ════════════════════════════════════════════════════════════════════

# Everything main touches outside its own argument handling, replaced by a
# recorder. The base path and the template layer are pointed at the test's
# own scratch dirs, so main's conf paths resolve there rather than under
# the readonly FILE_PATH this suite shares with every other spec running
# in parallel; _commit_and_setup stays a spy for the same reason.
stub_main_deps() {
  stub_chain
  stub_apply
  _TUI_TPL_DIR="${_CHAIN_TPL}"
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

# why: on a repo that has never been set up there is no setup.toml to load,
# so the menus would open on an empty config. main seeds it by running apply
# first; skipping that is how mount_1 detection went missing.
@test "main: seeds the per-repo conf with an apply run when none exists" {
  stub_main_deps
  _MENU_RC=0
  run main
  assert_success
  grep -q -- 'apply' "${_APPLY}"
}

# why: the editor's save target has to be a layer the readers actually
# resolve. For the whole of ADR-00000037's freeze it was not: main wrote
# `<repo>/.setup.conf` while `_setup_conf_layers` named only `.toml`
# layers, so a save had no effect at all (base#1232). The chain is DERIVED
# from `_setup_conf_layers` rather than spelled as a filename here -- the
# claim is membership of the chain, so a layer that is renamed or
# relocated keeps this test honest instead of pinning today's name.
@test "main: the path it commits to is one of the layers the readers resolve" {
  stub_main_deps
  _MENU_RC=0
  run main
  assert_success
  local _target
  _target="$(sed -n 's/^commit //p' "${_MARK}")"
  [ -n "${_target}" ]
  local -a _layers=()
  _setup_conf_layers "${_CHAIN_REPO}" _layers "${_CHAIN_TPL}"
  [ "${#_layers[@]}" -ge 3 ]
  local _l _hit=0
  for _l in "${_layers[@]}"; do
    [[ "${_l}" == "${_target}" ]] && _hit=1
  done
  [ "${_hit}" -eq 1 ] || {
    printf 'commit target %s is in none of: %s\n' "${_target}" "${_layers[*]}" >&2
    return 1
  }
  # And it is the repo's OWN layer, not the template and not the
  # gitignored per-worktree one: a save that landed in the template would
  # change every repo built from it, and one that landed in the local
  # layer would be invisible to CI and every other checkout.
  assert_equal "${_target}" "${_CHAIN_REPO}/setup.toml"
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

# unreachable_functions <setup_tui.sh path> <dist dir>
#
# Prints, one per line, every function <path> defines that nothing under
# <dist dir> can reach. Extracted from the guard so the guard can also be
# pointed at a scratch copy carrying a function planted to be dead: a
# check that only ever runs against a tree it passes on cannot say
# whether it would notice a new one.
#
# REACHABILITY, not mention-counting. <path> is split into its function
# bodies plus the top-level remainder; the roots are the names something
# mentions from OUTSIDE every one of those bodies -- the other files
# under <dist dir>, and <path>'s own top-level code -- plus the names
# main's `"_edit_section_${_subcmd}"` dispatch can actually be handed,
# which is asked of `_tui_known_subcommand` rather than waved through on
# the prefix. From those roots it walks body to body to a fixed point,
# and whatever it never arrives at is dead.
#
# Counting mentions instead, which is how this guard was first written,
# is wrong in three ways that the planted-shape test below now pins:
#
# - a function that names itself in its own `${1:?...}` message is its
# own second mention and reads as called. That is not hypothetical: it
# is why `_assemble_mount_value` sat in _tui_conf.sh with no caller.
#
# - a ring of dead functions that call each other keeps every link
# alive, because each one has a mention that is not its definition.
#
# - every `"<name>_${` in the file became a prefix that blanket-exempted
# any function carrying it. Two of the three it harvests -- `rule_` and
# `_TUI_MSG_` -- are a config-key prefix and an array-name prefix that
# dispatch no function at all, so `rule_anything` was unfalsifiable.
# Under reachability there is no exemption list: a name is alive because
# something reaches it, and the one real dynamic dispatch is resolved by
# asking the program which names it can hand that jump.
unreachable_functions() {
  local _f="${1}" _dist="${2}"
  local _work="${BATS_TEST_TMPDIR}/reach"
  rm -rf "${_work}"
  mkdir -p "${_work}/bodies"

  # Split into one file per function body, plus everything outside them.
  # `^name() {` ... `^}` is the layout throughout both this file and the
  # scratch copies, and the split refuses to guess: the count it parsed
  # is checked against the count grep sees, and an unterminated body is
  # a hard failure rather than a body silently swallowing the rest.
  awk -v out="${_work}" '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{$/ && !infn {
      infn = 1
      name = $1
      sub(/\(\)$/, "", name)
      parsed++
      next
    }
    infn && /^\}$/ { infn = 0; next }
    infn { print > (out "/bodies/" name); next }
    { print > (out "/toplevel") }
    END { print parsed+0 > (out "/parsed"); print infn+0 > (out "/open") }
  ' "${_f}"

  local -a _defs=()
  mapfile -t _defs < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${_f}" \
    | sed 's/()$//')
  # Non-vacuity: a scan that mis-parsed the file, found nothing to check,
  # or lost the dispatch oracle must fail, not pass. The population floor
  # is one, not a census figure that would need re-tuning every time a
  # function lands: the real evidence that extraction still works is that
  # two DIFFERENT patterns agree on the count. awk requires `() {` at end
  # of line and grep requires only `()` at line start, so a broken regex
  # moves one of them and not the other.
  [ "$(cat "${_work}/parsed")" = "${#_defs[@]}" ] || return 1
  [ "$(cat "${_work}/open")" = "0" ] || return 1
  [ "${#_defs[@]}" -ge 1 ] || return 1
  declare -F _tui_known_subcommand >/dev/null || return 1

  # Identifiers mentioned by each body and by the outside, with comments
  # dropped: a function named in prose is documentation, not a use, and
  # that is what hid one of base#1073's three. Whole-line comments go
  # first; the sed then takes trailing ones, and it requires a blank on
  # BOTH sides of the `#` so that `${_line#*|}` and `#!/usr/bin/env bash`
  # are left alone.
  local -A _seen=()
  local _scope _id _path
  _ids() {
    grep -vE '^[[:space:]]*#' "${1}" \
      | sed -E 's/[[:blank:]]+#[[:blank:]].*$//' \
      | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sort -u
  }
  # The other shipped files, then this file's top-level code. The file
  # under test drops out by exact path, NOT by `find -samefile`: the
  # suite runs on busybox find, which has no such primary and fails the
  # whole expression, so the corpus arrived empty and every name looked
  # unreferenced. The removal is verified rather than assumed -- exactly
  # one path has to disappear -- because the failure mode of getting it
  # wrong in the other direction is the file counting as its own caller,
  # which is silent.
  find "${_dist}" -name '*.sh' -type f > "${_work}/all_files"
  grep -vxF -- "${_f}" "${_work}/all_files" > "${_work}/other_files" || true
  [ "$(wc -l < "${_work}/other_files")" \
    -eq "$(( $(wc -l < "${_work}/all_files") - 1 ))" ] || return 1
  : > "${_work}/outside"
  if [ -s "${_work}/other_files" ]; then
    xargs cat < "${_work}/other_files" >> "${_work}/outside"
  fi
  if [ -f "${_work}/toplevel" ]; then
    cat "${_work}/toplevel" >> "${_work}/outside"
  fi
  while read -r _id; do _seen["OUTSIDE|${_id}"]=1; done < <(_ids "${_work}/outside")
  for _scope in "${_defs[@]}"; do
    _path="${_work}/bodies/${_scope}"
    [ -f "${_path}" ] || continue
    while read -r _id; do _seen["${_scope}|${_id}"]=1; done < <(_ids "${_path}")
  done

  local -A _reach=()
  local -a _queue=()
  local _fn
  for _fn in "${_defs[@]}"; do
    if [[ -n "${_seen[OUTSIDE|${_fn}]-}" ]]; then
      _reach["${_fn}"]=1
      _queue+=("${_fn}")
    elif [[ "${_fn}" == _edit_section_* ]] \
      && _tui_known_subcommand "${_fn#_edit_section_}"; then
      # main's direct jump is `"_edit_section_${_subcmd}"`, and the names
      # it can be handed are not "anything carrying this prefix" -- they
      # are exactly what `_tui_known_subcommand` accepts. Asking the
      # program is what keeps a dead editor visible: under a blanket
      # prefix exemption, 14 of these -- every editor whose only caller
      # IS that dispatch -- were checked by nothing at all, which is the
      # class of hole base#1073 opened this work to close.
      _reach["${_fn}"]=1
      _queue+=("${_fn}")
    fi
  done
  # A population with no roots at all is a broken scan, not a clean tree.
  [ "${#_queue[@]}" -gt 0 ] || return 1

  local _cur
  while (( ${#_queue[@]} )); do
    _cur="${_queue[0]}"
    _queue=("${_queue[@]:1}")
    for _fn in "${_defs[@]}"; do
      [[ -n "${_reach[${_fn}]-}" ]] && continue
      # Self-mention is not a call: a body only keeps a name alive once
      # something else has reached that body.
      [[ "${_fn}" == "${_cur}" ]] && continue
      [[ -n "${_seen[${_cur}|${_fn}]-}" ]] || continue
      _reach["${_fn}"]=1
      _queue+=("${_fn}")
    done
  done

  local -a _dead=()
  for _fn in "${_defs[@]}"; do
    [[ -n "${_reach[${_fn}]-}" ]] || _dead+=("${_fn}")
  done
  printf '%s\n' "${_dead[@]-}"
}

# why: base#1073 found three functions in setup_tui.sh with no caller, and
# one of them had three specs -- so a test suite is not evidence that
# production code is reachable. A hand-kept roster of "known dead" would
# go stale the moment a caller is deleted, so the population is derived
# from the files and the callers from the shipped tree. Dynamic dispatch
# is resolved by asking the program which names it can dispatch, not by
# waving a prefix through, which is how `_edit_section_resources` --
# whose only caller is main's `setup_tui.sh resources` direct jump --
# stays in while a dead editor does not.
# The population is every shipped file of the TUI, not setup_tui.sh
# alone, because the dead code a TUI change leaves behind does not stay
# in one file. Deleting `_prompt_mount_with_picker` from the wrapper took
# with it the ONLY two call sites of `_tui_radiolist` in
# lib/_tui_backend.sh and the only caller of `_assemble_mount_value` in
# lib/_tui_conf.sh; a guard that reads the wrapper alone reports a clean
# tree while two primitives ship with nothing to call them. The glob is
# what makes that derived: a new `_tui_*.sh` joins the population by
# existing.
@test "the TUI's shipped files define no function nothing can reach" {
  local -a _files=(
    /source/dist/script/docker/wrapper/setup_tui.sh
    /source/dist/script/docker/lib/_tui_*.sh
  )
  # The glob has to have matched the TUI's own libs, not silently nothing.
  [ "${#_files[@]}" -ge 3 ]
  local _f _got _all=""
  for _f in "${_files[@]}"; do
    _got="$(unreachable_functions "${_f}" /source/dist)"
    _got="$(printf '%s' "${_got}" | tr -d '[:space:]')"
    [ -z "${_got}" ] || _all+="${_f##*/}: ${_got}; "
  done
  printf 'unreachable: %s\n' "${_all}" >&2
  [ -z "${_all}" ]
}

# why: main jumps straight to `"_edit_section_${_subcmd}"` for every name
# `_tui_known_subcommand` accepts, and that gate read the schema section
# list alone. `project` is on that list with a deliberate no-editor
# opt-out (schema.sh's SCHEMA_I18N note says the project name belongs in
# the gitignored setup.local.toml, which the menu has no concept of), so
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
# function that is dead TOMORROW, and every shape below is one it waved
# through at some point. Each is planted in a scratch tree and has to be
# named back. A plain dead helper is the control, which proves the
# planting works. A dead `_edit_section_*` is one a blanket prefix
# exemption waved through even though 14 of the file's editors have no
# caller but the `"_edit_section_${_subcmd}"` dispatch. One whose only
# mention outside its own definition is a trailing comment is one a
# whole-line-only comment strip counted as a caller. `rule_*` and
# `_TUI_MSG_*` are what harvesting every `"<name>_${` in the file as a
# dispatch prefix collects -- `image.rule_${_n}` and
# `_TUI_MSG_${_TUI_LANG_UPPER}`, a config-key prefix and an array-name
# prefix that dispatch no function at all -- and then exempts anything
# carrying them from the check entirely. A pair of dead functions that
# call each other survives mention-counting because each is the other's
# second mention, so a whole dead limb stays green. And one that names
# itself in its own `${1:?...}` message is its own second mention: not
# hypothetical, since that idiom appears 81 times in dist/, and it is why
# `_assemble_mount_value` outlived its only caller in lib/_tui_conf.sh
# without anything noticing.
@test "the dead-code guard names every shape of dead function planted in a tree" {
  local _dir="${BATS_TEST_TMPDIR}/planted_dist"
  mkdir -p "${_dir}"
  local _scratch="${_dir}/setup_tui.sh"
  cp /source/dist/script/docker/wrapper/setup_tui.sh "${_scratch}"
  {
    printf '\n_plain_dead_helper() {\n  :\n}\n'
    printf '\n_edit_section_frobnicate() {\n  :\n}\n'
    printf '\n_dead_named_only_in_prose() {\n  :\n}\n'
    printf 'true  # successor to _dead_named_only_in_prose\n'
    printf '\nrule_dead_thing() {\n  :\n}\n'
    printf '\n_TUI_MSG_dead_thing() {\n  :\n}\n'
    printf '\n_dead_leaf() {\n  :\n}\n'
    printf '\n_dead_caller_of_dead_leaf() {\n  _dead_leaf\n}\n'
    printf '\n_dead_naming_itself() {\n'
    printf '  local _x="${1:?_dead_naming_itself requires an argument}"\n'
    printf '  printf %%s "${_x}"\n}\n'
  } >> "${_scratch}"
  local _got _fn
  _got="$(unreachable_functions "${_scratch}" "${_dir}")"
  printf 'planted run reported: %s\n' "${_got}" >&2
  for _fn in _plain_dead_helper _edit_section_frobnicate \
    _dead_named_only_in_prose rule_dead_thing _TUI_MSG_dead_thing \
    _dead_leaf _dead_caller_of_dead_leaf _dead_naming_itself; do
    [[ "${_got}" == *"${_fn}"* ]] || {
      printf 'the guard did not name planted dead function %s\n' "${_fn}" >&2
      return 1
    }
  done
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
# from this menu and nowhere else. BOTH directions of the condition are
# asserted: offering per-stage on a Dockerfile with only a baseline stage
# opens an editor over an empty stage list, and asserting only the
# stages-exist branch leaves the condition itself untested -- making the
# row unconditional passed a suite that checked just the positive side.
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

# why: the other half of that condition. A Dockerfile whose only stage is
# the baseline has nothing for the per-stage editor to edit, so the row
# must not be offered at all.
@test "_render_advanced_menu: no per-stage row when the Dockerfile has no extra stage" {
  _list_dockerfile_stages_available() { local -n _o="${1}"; _o=(); }
  queue "0|__back"
  _render_advanced_menu
  run menu_row "$(_tui_msg advanced.per_stage)"
  [ "${status}" -ne 0 ]
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
