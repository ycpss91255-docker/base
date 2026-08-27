#!/usr/bin/env bash
#
# wrapper.sh - cohesive runtime for the 5 docker wrappers.
#
# The five container-op wrappers (build / run / exec / stop / prune) used
# to repeat ~250 lines of preamble: the bootstrap-locator guard, the
# `--lang` pre-pass, the `_msg` dispatcher, and (for build / run) the
# setup/drift orchestration. This module hoists those cross-cutting
# surfaces so each wrapper shrinks to its verb-specific behaviour.
#
# Sourced (not executed). bootstrap.sh sources this file from the same
# lib/ directory after _lib.sh is loaded, so every wrapper that calls
# `_bootstrap "$@"` gets the runtime for free. The wrapper still owns its
# own file (preserving the `just <verb>` -> `./script/<verb>.sh` symlink
# contract that init.sh maintains) and declares which phases it needs.
#
# lib defensive-unset convention: this module is sourced from 5 distinct
# callers, each with a different subset of caller-locals in scope. Every
# reference to a caller-owned variable uses `${VAR:-}` / a guard so an
# unset name never trips `set -u`.
#
# ADR-00000011: this runtime is the intended home for the shared CLI lib
# (--help / --lang) the test / release / base / template scripts will
# adopt later. For it is scoped to the 5 docker
# wrappers only; the helpers are written to be reusable but nothing
# outside the docker wrappers is pulled in here yet.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_WRAPPER_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_WRAPPER_SOURCED=1

# ── _msg dispatcher ───────────────────────────────────────────────────
#
# Every wrapper that emits i18n strings declares its own per-category
# tables `_msg_<category>` (e.g. `_msg_bootstrap`, `_msg_errors`).
# This dispatcher keeps a single `_msg <category> <key>` call-site shape
# across all wrappers; it was byte-identical in all 5 before
#
# Resolves to `_msg_<category> <key>`; the table function reads the
# global _LANG. A wrapper that defines no message tables (e.g. a future
# table-less verb) simply never calls _msg.
_msg() {
  local _category="${1:?_msg requires category}"
  local _key="${2:?_msg requires key}"
  "_msg_${_category}" "${_key}"
}

# ── shared-runtime message table ──────────────────────────────────────
#
# `_msg` above dispatches into the CALLER's tables, which is right for a
# wrapper's own verb-specific strings and wrong for a string this file
# emits itself: build.sh and run.sh would each have to carry the same four
# locales of it, and exec / stop / prune -- which call the probe but define
# no such table -- would abort on the lookup. So the shared runtime keeps
# its own namespace, exactly as config_summary.sh's `_lib_msg` does.
#
# Every `%s` is expanded by `printf -v` at the call site. The argument
# ORDER is fixed across all four locales (each entry says what it is) so
# one argument list serves them all.
_wrapper_msg() {
  local _key="${1:?_wrapper_msg requires key}"
  case "${_LANG:-en}:${_key}" in
    # %s: the compose SERVICE, then the compose PROJECT.
    zh-TW:service_probe_failed)
      echo "無法向 compose 查詢服務 '%s'（專案 '%s'）是否執行中，先視為未執行。" ;;
    zh-CN:service_probe_failed)
      echo "无法向 compose 查询服务 '%s'（项目 '%s'）是否运行中，先视为未运行。" ;;
    ja:service_probe_failed)
      echo "サービス '%s'（プロジェクト '%s'）の稼働状態を compose に問い合わせられませんでした。未実行として扱います。" ;;
    *:service_probe_failed)
      echo "Could not ask compose whether service '%s' is running in project '%s'; treating it as not running." ;;
    # %s: the RECORDED project name, then the RESOLVED one.
    zh-TW:project_renamed)
      echo "compose 專案名稱已更新：'%s' -> '%s'（舊名稱下沒有任何容器）。" ;;
    zh-CN:project_renamed)
      echo "compose 项目名称已更新：'%s' -> '%s'（旧名称下没有任何容器）。" ;;
    ja:project_renamed)
      echo "compose プロジェクト名を更新しました: '%s' -> '%s'（旧名のコンテナはありません）。" ;;
    *:project_renamed)
      echo "Compose project name updated: '%s' -> '%s' (nothing existed under the old name)." ;;
    zh-TW:project_rename_deferred)
      echo "compose 專案 '%s' 底下仍有容器，此 checkout 先維持該名稱；解析出的新名稱 '%s' 會在 './stop.sh' 之後生效。" ;;
    zh-CN:project_rename_deferred)
      echo "compose 项目 '%s' 下仍有容器，此 checkout 先维持该名称；解析出的新名称 '%s' 会在 './stop.sh' 之后生效。" ;;
    ja:project_rename_deferred)
      echo "compose プロジェクト '%s' にコンテナが残っているため、この checkout は同じ名前のままにします。解決された新しい名前 '%s' は './stop.sh' の後に有効になります。" ;;
    *:project_rename_deferred)
      echo "Compose project '%s' still has containers, so this checkout stays on that name; the resolved name '%s' takes effect after './stop.sh'." ;;
    # %s: the RECORDED project name, then the RESOLVED one. Volumes only:
    # `stop` will NOT clear this one, so it must not be advertised.
    zh-TW:project_rename_deferred_volumes)
      echo "compose 專案 '%s' 底下仍有具名 volume,此 checkout 先維持該名稱。改用解析出的新名稱 '%s' 會讓那些 volume 變成沒有任何 wrapper 找得到的孤兒,而 './stop.sh' 不會刪除它們;請先用 'docker volume ls --filter label=com.docker.compose.project=%s' 檢視並搬移或刪除,或以 setup.conf 的 [project] name 固定目前名稱。" ;;
    zh-CN:project_rename_deferred_volumes)
      echo "compose 项目 '%s' 下仍有具名 volume,此 checkout 先维持该名称。改用解析出的新名称 '%s' 会让那些 volume 变成没有任何 wrapper 找得到的孤儿,而 './stop.sh' 不会删除它们;请先用 'docker volume ls --filter label=com.docker.compose.project=%s' 查看并搬移或删除,或以 setup.conf 的 [project] name 固定目前名称。" ;;
    ja:project_rename_deferred_volumes)
      echo "compose プロジェクト '%s' に名前付きボリュームが残っているため、この checkout は同じ名前のままにします。解決された新しい名前 '%s' に切り替えると、それらはどの wrapper からも辿れない孤児になり、'./stop.sh' では削除されません。'docker volume ls --filter label=com.docker.compose.project=%s' で確認して移動または削除するか、setup.conf の [project] name で現在の名前を固定してください。" ;;
    *:project_rename_deferred_volumes)
      echo "Compose project '%s' still holds named volumes, so this checkout stays on that name. Adopting the resolved name '%s' would leave them as orphans no wrapper addresses, and './stop.sh' does not remove them: list them with 'docker volume ls --filter label=com.docker.compose.project=%s', then move or remove them -- or pin the current name with [project] name in setup.conf." ;;
    zh-TW:project_rename_probe_failed)
      echo "無法向 daemon 查詢 compose 專案 '%s' 底下的容器，因此延後改名為 '%s'。" ;;
    zh-CN:project_rename_probe_failed)
      echo "无法向 daemon 查询 compose 项目 '%s' 下的容器，因此延后改名为 '%s'。" ;;
    ja:project_rename_probe_failed)
      echo "compose プロジェクト '%s' のコンテナを daemon に問い合わせられなかったため、'%s' への改名を保留します。" ;;
    *:project_rename_probe_failed)
      echo "Could not ask the daemon what exists under compose project '%s', so the rename to '%s' is deferred." ;;
  esac
}

# ── --lang pre-pass ───────────────────────────────────────────────────
#
# _wrapper_lang_prepass <verb> "$@"
#
# Scans the wrapper's argv for `--lang <value>` and seeds the global
# _LANG before the main parse loop runs, so usage (which exits via
# -h/--help) renders in the requested locale even when --help precedes
# --lang on the command line. The canonical main parse loop still
# handles --lang itself (validation, error-on-missing-value) on the
# normal path; this pre-pass only front-loads the locale for the early
# usage exit.
#
# bootstrap.sh already ran `_resolve_lang _LANG` (SETUP_LANG / $LANG
# detection) so _LANG holds a valid default before this is called; a
# --lang here overrides it and is re-validated via _sanitize_lang.
#
# _LANG is mutated as a global (no `local` declared for it here). The
# leading <verb> is the script name forwarded to _sanitize_lang for its
# `[<verb>] WARNING:` prefix on an unsupported value.
_wrapper_lang_prepass() {
  local _verb="${1:?_wrapper_lang_prepass requires verb}"
  shift
  local _i
  for (( _i=1; _i<=$#; _i++ )); do
    if [[ "${!_i}" == "--lang" ]]; then
      local _next=$((_i+1))
      _LANG="${!_next:-}"
      _sanitize_lang _LANG "${_verb}"
      break
    fi
  done
}

# ── service-running probe (run + exec) ────────────────────────────────
#
# _wrapper_service_running <service>
#
# Exit 0 iff <service> has at least one running container IN THIS PROJECT.
#
# run.sh asks this to refuse starting on top of a live service; exec.sh
# asks the negation to refuse exec'ing into a dead one.
#
# It asks COMPOSE, not the daemon's container list, and the scoping is the
# reason. The emitted compose.yaml names no container, so the name a running
# container carries is `<project>-<service>-<n>` -- compose's to derive, and
# nothing a wrapper should reassemble to compare against. Reconstructing one
# made the wrapper a second answerer to "what is this container called", and
# it answered per HOST: two stacks of one repo under two project names were
# indistinguishable to it. `_compose_project` already carries `-p`, so the
# question is project-scoped by construction -- the same mechanism that lets
# those two stacks coexist at all.
#
# Requires PROJECT_NAME + FILE_PATH (both callers have run _load_env +
# _compute_project_name before asking).
#
# The answer is CAPTURED, never piped into a reader that can leave early.
# The predecessor spelled it `docker ps --format '{{.Names}}' | grep -qx
# "${name}"`, and that hands the answer to a reader that stops reading:
# `grep -q` leaves the instant it matches, a probe still writing then takes
# SIGPIPE and exits 141, and the file-scope `pipefail` of both wrappers
# makes 141 the PIPELINE's status. An `if` reads 141 as false, so a
# SUCCESSFUL match is reported as "not running". The status was not lost --
# it was INVERTED, and neither caller failed loudly: run.sh silently started
# a second container over the live one, exec.sh silently refused a running
# one. A busy host is exactly the writer that has not finished, and this
# ships to every downstream repo, on whatever host they have.
#
# A failing probe (no daemon, no compose.yaml yet) still ANSWERS "not
# running" -- the conclusion the caller would reach anyway -- but it no
# longer answers that silently. Dropping the stderr made a probe FAILURE
# indistinguishable from a probe that ran and found nothing, and the two
# decide opposite things for the caller: exec.sh refuses a service that is
# in fact up, and run.sh's guard fails open and brings a second stack up
# over a live one. `ps --status` is one concrete way to get there -- it is
# a newer flag than the "Compose v2" README.md promises, and a compose that
# rejects it reports every service as stopped -- so the diagnostic is
# captured and re-emitted as a warning naming the service and the project.
# Fail-open is kept (a probe is not the caller's verb); what changes is
# that the failure is on the terminal.
_wrapper_service_running() {
  local _service="${1:?_wrapper_service_running requires a service name}"
  local _wsr_ids="" _wsr_err="" _wsr_rc=0 _wsr_body=""
  _wrapper_probe _wsr_ids _wsr_err _wrapper_compose_ps "${_service}" \
    || _wsr_rc=$?
  if (( _wsr_rc != 0 )); then
    # shellcheck disable=SC2059  # the i18n template IS the format string
    printf -v _wsr_body "$(_wrapper_msg service_probe_failed)" \
      "${_service}" "${PROJECT_NAME:-?}"
    if [[ -n "${_wsr_err}" ]]; then
      _wsr_body+="
${_wsr_err}"
    fi
    _log_warn compose service_probe_failed "display=${_wsr_body}" \
      "service=${_service}" "project=${PROJECT_NAME:-}"
    return 1
  fi
  [[ -n "${_wsr_ids}" ]]
}

# _wrapper_compose_ps <service> -- the probe's command, factored out so
# _wrapper_probe can run it as a plain argv.
#
# A read-only question, so it is asked even under DRY_RUN; the assignment
# prefix is the whole scope of the override, and _wrapper_probe runs this
# inside a command substitution anyway, so nothing leaks to the caller.
# Both callers skip the precheck under --dry-run regardless; this keeps the
# probe honest for any future one that does not.
_wrapper_compose_ps() {
  DRY_RUN=false _compose_project ps --status running \
    -q "${1:?_wrapper_compose_ps requires a service name}"
}

# _wrapper_probe <stdout_outvar> <stderr_outvar> <cmd> [args...]
#
# Run <cmd>, capture BOTH streams, return its status. The two streams stay
# separate (a temp file, not a `2>&1` merge) because the caller compares
# stdout against emptiness: a diagnostic merged into it would read as an
# answer. When no temp file can be made the command still runs and its
# answer is still captured -- only the diagnostic is lost, which is no
# worse than dropping it unconditionally.
_wrapper_probe() {
  local -n _wp_out="${1:?_wrapper_probe requires a stdout outvar}"
  local -n _wp_err="${2:?_wrapper_probe requires a stderr outvar}"
  shift 2
  _wp_out=""
  _wp_err=""
  local _wp_tmp="" _wp_rc=0
  if ! _wp_tmp="$(mktemp "${TMPDIR:-/tmp}/wrapper-probe.XXXXXX" 2>/dev/null)" \
      || [[ -z "${_wp_tmp}" || ! -f "${_wp_tmp}" ]]; then
    _wp_out="$("$@" 2>/dev/null)" || _wp_rc=$?
    return "${_wp_rc}"
  fi
  _wp_out="$("$@" 2>"${_wp_tmp}")" || _wp_rc=$?
  _wp_err="$(< "${_wp_tmp}")"
  rm -f "${_wp_tmp}"
  return "${_wp_rc}"
}

# ── compose project name: renaming an OCCUPIED project ────────────────
#
# The project name is not a label. It is the key compose looks its own
# containers up by, so rewriting it while a stack is up hides that stack
# from every wrapper at once: `stop` tears down the new, empty project,
# `run` starts a SECOND copy over the first one's bind mounts, host
# network and devices, and the original survives as an orphan only raw
# `docker` can reach. `--remove-orphans` does not reach it either --
# orphans are same-project containers of a removed service.
#
# That is not a hypothetical. `_resolve_project_name`'s fallback changed
# with the drop of `container_name` (ADR-00000022 amendment): a checkout
# with DOCKER_HUB_USER unset derived `local-<image>` and now derives
# `<osuser>-<image>`. Nobody asks for that rename -- `upgrade` runs
# `init.sh`, which runs `setup apply`, and the resolved name changes under
# a stack that is still up.
#
# Compose cannot relabel a running container, so a rename can only take
# effect on an EMPTY project. The split of labour follows from that:
#
#   setup.sh   never breaks continuity on a changed DERIVATION. The name
#              it RECORDS stays the one the checkout already had, and the
#              newly derived one goes beside it as PROJECT_NAME_PENDING
#              (`_carry_project_name`, lib/compose.sh). It cannot do
#              better -- whether a project is occupied is a question only
#              the daemon can answer, and setup resolves configuration on
#              hosts where docker need not be reachable at all. (A
#              CONFIGURED `[project] name` is taken at once and warned
#              about there; deferring it would defeat the setting.)
#
#   the wrapper settles it. build / run can ask the daemon, so they do:
#              the first one that finds the old project EMPTY adopts the
#              pending name, and one that finds it occupied reports why it
#              is not adopting yet.
#
# So `stop` is the whole migration for the ordinary repo -- no new flag,
# and it addresses the stack the user actually has, because `stop` /
# `exec` never regenerate and so read the recorded name. A consumer who
# never stops keeps ONE working stack under its old name instead of two
# under two.
#
# `stop` is NOT the whole migration for a repo with NAMED VOLUMES: it runs
# `compose down` without `-v`, so the volumes outlive it and the project
# stays occupied (`_wrapper_project_occupied` counts them for exactly that
# reason). Such a repo keeps its old name until someone moves or removes
# the data, or pins the name with `[project] name`. That is the intended
# outcome, not a gap: the pending name is a changed DERIVATION nobody
# asked for, and staying on the old one costs a name while adopting it
# would cost the data.
#
# The cost is a `.env.generated` whose PROJECT_NAME is deliberately not
# what `setup apply` last resolved. PROJECT_NAME_PENDING is what keeps
# that divergence visible and self-clearing rather than sticky; it is
# re-derived by every apply, so nothing depends on it surviving.

# _wrapper_project_occupied <project> <stderr_outvar> <held_outvar>
#
# 0 = something of the user's still lives under this project's label,
# 1 = nothing does, 2 = the daemon could not be asked (diagnostic in
# <stderr_outvar>). <held_outvar> names WHAT holds it -- `containers`,
# `volumes`, or `containers volumes` -- so the caller can say something
# true about how to clear it, since `stop` clears only one of the two.
#
# Containers AND named volumes, because both are keyed by the project name
# and only one of them is recoverable afterwards. `stop` runs
# `compose down` WITHOUT `-v`, so a torn-down stack routinely leaves its
# volumes behind: a project with data in it reads as empty by containers
# alone, the rename is adopted, and compose then creates a fresh EMPTY
# volume under the new name while the user's data sits in an orphan no
# wrapper addresses -- and which `prune --volumes` later deletes as
# unused. Named volumes are a first-class, user-reachable feature here
# (`_classify_volume_lhs` routes a non-path `[volumes] mount_N` LHS to a
# top-level stub with no `name:` / `external:`, which compose prefixes
# with the project), so this is a supported configuration losing data, not
# an exotic one.
#
# `--all`, not just running: `stop` removes the containers it stops, so a
# leftover exited one is a stack the user still owns and still expects
# `stop` to reach.
#
# Networks and images are deliberately NOT counted, and the asymmetry is
# the same test: a project network is removed by the `compose down` that
# `stop` already runs and holds nothing if it survives, and a built image
# is named `<hub>/<repo>:<stage>` rather than by the project, so neither
# can be orphaned by a rename. Counting either would defer every rename
# forever for no gain.
#
# Asked of the DAEMON by label rather than through `compose ps`, because
# the compose.yaml on disk has just been regenerated and the question is
# about what exists under the PREVIOUS name -- a question no current
# project file has to be able to parse.
_wrapper_project_occupied() {
  local _project="${1:?_wrapper_project_occupied requires a project}"
  local -n _wpo_err="${2:?_wrapper_project_occupied requires an err outvar}"
  local -n _wpo_held="${3:?_wrapper_project_occupied requires a held outvar}"
  local _wpo_label="label=com.docker.compose.project=${_project}"
  local _wpo_ids="" _wpo_vols="" _wpo_rc=0
  _wpo_held=""

  _wrapper_probe _wpo_ids _wpo_err docker ps --all --quiet \
    --filter "${_wpo_label}" || _wpo_rc=$?
  (( _wpo_rc != 0 )) && return 2
  [[ -n "${_wpo_ids}" ]] && _wpo_held="containers"

  # Asked even when containers already answered "occupied": the message
  # the caller prints tells the user how to clear the project, and `stop`
  # is only the whole answer when there is nothing but containers in it.
  local _wpo_verr=""
  _wrapper_probe _wpo_vols _wpo_verr docker volume ls --quiet \
    --filter "${_wpo_label}" || _wpo_rc=$?
  if (( _wpo_rc != 0 )); then
    _wpo_err="${_wpo_verr}"
    return 2
  fi
  if [[ -n "${_wpo_vols}" ]]; then
    _wpo_held+="${_wpo_held:+ }volumes"
  fi

  [[ -n "${_wpo_held}" ]]
}

# _wrapper_record_project_name <env_file> <name> <pending>
#
# Rewrite PROJECT_NAME and set (or, with an empty <pending>, drop)
# PROJECT_NAME_PENDING, atomically. Every other line is copied through
# byte for byte -- this is a two-key edit of a generated file, not a
# regeneration of it, and the wrapper is in no position to regenerate one.
#
# Temp-file-then-rename, and the mode is carried over: `mktemp` makes 0600
# and the file it replaces is the one `docker compose --env-file` reads
# next. A failed temp creation returns before the original is touched, so
# a failed write is never destructive.
_wrapper_record_project_name() {
  local _file="${1:?_wrapper_record_project_name requires a file}"
  local _name="${2?_wrapper_record_project_name requires a name}"
  local _pending="${3-}"
  local _tmp=""
  if ! _tmp="$(mktemp "${_file}.XXXXXX" 2>/dev/null)" \
      || [[ -z "${_tmp}" || ! -f "${_tmp}" ]]; then
    _log_warn compose project_rename_write_failed \
      "display=cannot create a temp file next to ${_file}; the compose project name was left as it is" \
      "file=${_file}"
    return 1
  fi
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    case "${_line}" in
      PROJECT_NAME=*)         printf 'PROJECT_NAME=%s\n' "${_name}" ;;
      PROJECT_NAME_PENDING=*) : ;;
      *)                      printf '%s\n' "${_line}" ;;
    esac
  done < "${_file}" > "${_tmp}"
  if [[ -n "${_pending}" ]]; then
    printf 'PROJECT_NAME_PENDING=%s\n' "${_pending}" >> "${_tmp}"
  fi
  chmod --reference="${_file}" "${_tmp}" 2>/dev/null || true
  if ! mv -f "${_tmp}" "${_file}"; then
    rm -f "${_tmp}"
    _log_warn compose project_rename_write_failed \
      "display=cannot replace ${_file}; the compose project name was left as it is" \
      "file=${_file}"
    return 1
  fi
}

# _wrapper_settle_project_name <verb> <file_path>
#
# Adopt a deferred project rename once the old project is empty, or say
# why it is not being adopted yet. No-op -- and no docker call -- when
# `.env.generated` records no pending name, which is every ordinary run.
_wrapper_settle_project_name() {
  local _verb="${1:?_wrapper_settle_project_name requires verb}"
  local _file_path="${2:?_wrapper_settle_project_name requires FILE_PATH}"
  local _env="${_file_path}/.env.generated"
  [[ -f "${_env}" ]] || return 0

  local _old="" _new=""
  _env_file_value "${_env}" PROJECT_NAME _old
  _env_file_value "${_env}" PROJECT_NAME_PENDING _new
  [[ -n "${_old}" && -n "${_new}" && "${_old}" != "${_new}" ]] || return 0

  local _probe_err="" _held="" _occupied=0
  _wrapper_project_occupied "${_old}" _probe_err _held || _occupied=$?

  local _body=""
  if (( _occupied == 1 )); then
    # Empty: the rename can take effect, and nothing of the user's moves.
    _wrapper_record_project_name "${_env}" "${_new}" "" || return 0
    # shellcheck disable=SC2059  # the i18n template IS the format string
    printf -v _body "$(_wrapper_msg project_renamed)" "${_old}" "${_new}"
    _log_info "${_verb}" project_renamed "display=${_body}" \
      "from=${_old}" "to=${_new}"
    return 0
  fi

  # Occupied, or unanswerable. Both keep the recorded name: deferring
  # costs a cycle under the old name, renaming on a guess costs the stack.
  if (( _occupied == 2 )); then
    # shellcheck disable=SC2059  # the i18n template IS the format string
    printf -v _body "$(_wrapper_msg project_rename_probe_failed)" \
      "${_old}" "${_new}"
    if [[ -n "${_probe_err}" ]]; then
      _body+="
${_probe_err}"
    fi
    _log_warn "${_verb}" project_rename_probe_failed "display=${_body}" \
      "project=${_old}" "pending=${_new}"
    return 0
  fi
  # Occupied. WHAT holds it decides which of the two things to say,
  # because only one of them is cleared by the command the user reaches
  # for: `stop` removes containers and leaves named volumes. Telling
  # someone whose project holds only volumes that `./stop.sh` settles the
  # rename would send them to a command that changes nothing, once per
  # build / run, forever.
  if [[ "${_held}" == "volumes" ]]; then
    # shellcheck disable=SC2059  # the i18n template IS the format string
    printf -v _body "$(_wrapper_msg project_rename_deferred_volumes)" \
      "${_old}" "${_new}" "${_old}"
    _log_warn "${_verb}" project_rename_deferred_volumes "display=${_body}" \
      "project=${_old}" "pending=${_new}" "held=${_held}"
    return 0
  fi
  # shellcheck disable=SC2059  # the i18n template IS the format string
  printf -v _body "$(_wrapper_msg project_rename_deferred)" "${_old}" "${_new}"
  _log_warn "${_verb}" project_rename_deferred "display=${_body}" \
    "project=${_old}" "pending=${_new}" "held=${_held}"
  return 0
}

# ── setup / drift orchestration (build + run) ─────────────────────────
#
# _wrapper_setup_sync <verb>
#
# The shared bootstrap / drift lifecycle that build.sh and run.sh both
# need before they touch docker: decide whether to (re)run setup.sh,
# regenerate .env.generated + compose.yaml on drift, and fail loudly if
# setup left no .env behind. exec / stop / prune do NOT call this -- they
# expect the derived artifacts to already exist (a real repo has them
# after its first build), so the orchestration stays opt-in per verb.
#
# Reads (all caller-owned, guarded for `set -u`):
#   FILE_PATH            repo root (readonly, set by _bootstrap)
#   _LANG                resolved locale
#   RUN_SETUP            "true" forces an interactive (TUI/setup.sh) run
#   SETUP_FORWARD_ARGS   array; per-invocation overrides forwarded
#                        into setup.sh apply (short-circuits the TUI)
#
# Phase decision (unchanged from the build/run inline blocks):
#   - RUN_SETUP=true                          -> interactive run
#   - missing .env / setup.conf / compose.yaml -> non-interactive bootstrap
#   - otherwise                                -> drift-check, regen on drift
#
# Bootstrap MUST stay non-interactive: compose.yaml is gitignored since
# v0.9.0, so every fresh clone hits the bootstrap path. Dispatching it
# through the TUI would leave a cancelled (Esc / Ctrl-C) session with no
# .env, and the next step would die inside _load_env on a missing file.
#
# Drift regen runs setup.sh as a SUBPROCESS (not `source`) so setup.sh's
# internal helpers never leak into the wrapper's namespace -- this closes
# the class where sourcing setup.sh shadowed the wrapper's _msg
# and silently blanked out the drift_regen / no_env status lines.
#
# On a missing .env after setup, emits the no_env / rerun_setup error
# pair and exits 1.
_wrapper_setup_sync() {
  local _verb="${1:?_wrapper_setup_sync requires verb}"
  local _file_path="${FILE_PATH:?_wrapper_setup_sync requires FILE_PATH}"
  local _lang="${_LANG:-en}"

  # Self-managed compose (base self-use): base is the template SOURCE
  # -- it has no `.base/` subtree and ships a hand-authored compose.yaml, so
  # there is no setup.conf to generate from and regenerating would clobber
  # it. Skip the whole setup-sync lifecycle. This is the general
  # "no .base/ subtree + no setup.conf -> the repo manages its own compose"
  # rule (ADR-00000011 sec.4), not a base special-case; consumers always
  # carry a `.base/` subtree so this never fires for them.
  if [[ ! -d "${_file_path}/.base" \
        && ! -f "${_file_path}/.setup.conf" ]]; then
    return 0
  fi

  local _setup="${_file_path}/.base/dist/script/docker/wrapper/setup.sh"
  local _tui="${_file_path}/setup_tui.sh"

  # per-invocation overrides. Defensive copy so an unset
  # SETUP_FORWARD_ARGS (a future caller that skips the override surface)
  # degrades to an empty array under `set -u` instead of aborting.
  local -a _forward_args=()
  if [[ -n "${SETUP_FORWARD_ARGS+x}" ]]; then
    _forward_args=("${SETUP_FORWARD_ARGS[@]}")
  fi

  # _run_interactive: prefer setup_tui.sh on an interactive TTY when the
  # symlink is executable; otherwise non-interactive setup.sh.
  # per-invocation overrides (--gui / --no-x11-cookie) accumulate in
  # SETUP_FORWARD_ARGS and short-circuit through setup.sh apply -- the
  # TUI Save would persist them to setup.conf, the wrong semantics for a
  # debug knob.
  _run_interactive() {
    if (( "${#_forward_args[@]}" > 0 )); then
      "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}" \
        "${_forward_args[@]}"
    elif [[ -t 0 && -t 1 && -x "${_tui}" ]]; then
      "${_tui}" --lang "${_lang}"
    else
      "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}"
    fi
  }

  if [[ "${RUN_SETUP:-false}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${_file_path}/.env.generated" ]] \
      || [[ ! -f "${_file_path}/.setup.conf" ]] \
      || [[ ! -f "${_file_path}/compose.yaml" ]]; then
    _log_info "${_verb}" "${_verb}_bootstrap" "display=$(_msg bootstrap info)"
    "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}"
  else
    # Drift-check path. Derived artifacts (.env.generated + compose.yaml)
    # carry no user-owned data, so regenerating on drift is always safe and
    # saves the user from remembering `--setup`. Subprocess invocation
    # avoids the _msg shadow class.
    if ! "${_setup}" check-drift --base-path "${_file_path}" --lang "${_lang}"; then
      _log_info "${_verb}" "${_verb}_drift_regen" "display=$(_msg drift regen)"
      "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}"
    fi
  fi

  # Defensive: setup above must leave .env in place. If it did not (user
  # cancelled an interactive TUI, setup.sh crashed, ...), surface a
  # useful error instead of letting _load_env fail on a missing file.
  if [[ ! -f "${_file_path}/.env.generated" ]]; then
    _log_err  "${_verb}" "${_verb}_no_env" "display=$(_msg errors no_env)"
    _log_info "${_verb}" "${_verb}_rerun_setup" "display=$(_msg errors rerun_setup)"
    exit 1
  fi

  # Last, because it reconciles what setup just wrote against what the
  # daemon actually has. Runs on every build / run, not only after a regen:
  # a deferred rename is adopted by the first invocation that finds the old
  # project empty, and no regen has to happen for that to be true.
  _wrapper_settle_project_name "${_verb}" "${_file_path}"
}
