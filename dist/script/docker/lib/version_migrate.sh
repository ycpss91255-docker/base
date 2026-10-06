#!/usr/bin/env bash
#
# version_migrate.sh - the migrations between the version a consumer came
# FROM and the version it is now ON, and the runner that selects them.
#
# ── Why a version interval, and why it is read here ─────────────────────────
#
# An upgrade is never driven by the code in this tree. It is driven by the
# consumer's own vendored `upgrade.sh`, which shipped in an older release and
# can never be changed retroactively, so anything a new release needs DONE is
# unreachable from there. The one piece of current code such an upgrade runs
# is `init.sh`, re-executed from the freshly pulled subtree as the resync at
# Step 3 -- which is why every heal this tree carries lives there.
#
# Those heals each infer for themselves whether they still apply, by looking
# at the shape of the tree. That works and it is what the family already in
# `lib/dockerfile_migrate.sh`, `lib/smoke_migrate.sh` and
# `lib/setup_conf_migrate.sh` does. What it cannot express is "this applies
# to a repo arriving from before release X", because none of them knows what
# the repo arrived FROM. So each new one is discovered by a consumer, one
# incident at a time, and written as another shape test.
#
# The pair is recoverable, and that is the whole of this file. `git subtree
# pull --squash` lands a TWO-PARENT merge commit whose first parent is the
# pre-upgrade state, so at Step 3 the version the consumer came from is one
# `git show` away:
#
#   from = <prefix>/.version at HEAD's first parent
#   to   = <prefix>/.version on disk (the pull has already landed it)
#
# A migration declared as landing in version V then runs exactly when
# `from < V <= to`, and stops guessing.
#
# ── What the consumer's history makes permanent ─────────────────────────────
#
# The ledger is the consumer's own git history, which base cannot rewrite.
# Every released `upgrade.sh` already produces the merge this reads, so the
# shape is fixed for every repo that has ever taken an upgrade -- and so is
# the pairing of a shipped migration to its version: once a release goes out
# declaring V, the set of consumers whose interval covers V is decided by
# their history, not by anything a later release can say. Re-pointing a
# shipped migration at a different version silently changes who gets it.
# Recorded in doc/adr/00000006-upgrade-sh-path-contract.md.
#
# ── Apply policy ───────────────────────────────────────────────────────────
#
#   - Each migration is IDEMPOTENT. There is no ledger of what has already
#     run, deliberately: the interval is derived from the tree every time, so
#     a resync re-entered before the pull is committed selects the same
#     interval again and applies it again. Idempotence is the migration's
#     job, and running twice must be a no-op the second time.
#   - A migration that FAILS does not fail the resync. Every release up to
#     v0.42.0 arms no rollback around Step 3, so a non-zero exit there leaves
#     the pull committed and the repo half-upgraded. The failure is reported
#     loudly and the migrations AFTER it are skipped -- an ordered set may
#     have a later entry that assumes an earlier one finished.
#   - A migration that writes a path the resync publishes records it with
#     init.sh's `_init_record_write`, the same way every other conditional
#     write does, or the caller's commit will not carry it.
#
# ── Where there is no interval, and where there is one nobody can read ──────
#
# These are different situations and they must not collapse into the same
# silence. A bootstrap legitimately has nothing to migrate between; a
# consumer whose from-version cannot be read has an upgrade whose migrations
# were skipped, and nothing else will ever tell them. So the resolver names
# its reason, and the two classes land on different log bodies --
# `interval_migration_window` for "no interval exists",
# `interval_migration_unreadable` for "one does and could not be read".
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_VERSION_MIGRATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_VERSION_MIGRATE_SOURCED=1

# ── The declared set ───────────────────────────────────────────────────────
#
# One entry per migration, `"<version> <name>"`, where <version> is the
# release the migration LANDS IN and `_vmigrate_<name>_apply <repo_root>`
# performs it. Declaration order breaks ties between entries landing in the
# same version; across versions the runner orders by version ascending, so
# appending an entry out of order cannot reorder the set.
#
# It is EMPTY, and that is the point. Every heal this tree carries today
# infers its own applicability from the tree and must keep doing so: those
# are what make `just base init` a repair command for a repo that already
# took a bad upgrade, where there is no interval left to select on. This
# registry is for the next one -- the migration that is only correct for a
# repo arriving from before a particular release -- so that it does not have
# to be discovered by a consumer first.
#
# Not readonly: the released-caller integration spec declares into it to
# drive a real upgrade through the real runner.
_VERSION_MIGRATIONS=()

# ── Version arithmetic ─────────────────────────────────────────────────────

# _vm_is_semver <version>
#   Exit 0 iff <version> is a version this file can order: `vX.Y.Z` or
#   `X.Y.Z`, with an optional pre-release suffix.
_vm_is_semver() {
  [[ "${1:-}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

# _vm_key <version>
#   A fixed-width, zero-padded, lexically-sortable key for <version>.
#
#   The pre-release suffix is DROPPED rather than ordered. A migration is
#   declared against the release it lands in, and an rc of that release
#   carries it: a consumer going to `v0.43.0-rc1` has crossed v0.43.0's
#   migrations, and one already on `v0.43.0-rc1` going to `v0.43.0` has
#   crossed them already. Ordering rc1 below the release would run them
#   twice -- correct only because they are idempotent, and misleading in the
#   log either way.
#
#   Every arithmetic read of a key is `10#`-prefixed: the padding leaves
#   leading zeros, and bash reads those as octal.
_vm_key() {
  local _core="${1#v}"
  _core="${_core%%-*}"
  local -a _field=()
  IFS=. read -r -a _field <<< "${_core}"
  printf '%05d%05d%05d' \
    "$(( 10#${_field[0]:-0} ))" \
    "$(( 10#${_field[1]:-0} ))" \
    "$(( 10#${_field[2]:-0} ))"
}

# ── The upgrade pair ───────────────────────────────────────────────────────

# _vm_from_version <repo_root> <subtree_prefix>
#   The version the repo came from, read out of its own history.
#
#   stdout: the from-version on success, otherwise a one-token REASON.
#   exit 0: resolved.
#   exit 1: there is no interval at HEAD. Nothing was crossed, so nothing is
#           owed -- a fresh bootstrap, a standalone `just base init`, a
#           re-established subtree.
#   exit 2: an interval IS there and the from half cannot be read. Migrations
#           are being skipped and the caller has to say so.
#
#   The discriminator between the two is whether the first parent carried the
#   subtree at all. `git subtree add --squash` also lands a two-parent merge,
#   and its first parent predates the subtree entirely -- that is a bootstrap.
#   A first parent that HAS the subtree but no `.version` inside it is a
#   different thing: a vendored tree nothing can identify, where guessing
#   would mean running every migration ever declared against a repo whose
#   state is unknown.
#
#   REASONS, and which class each belongs to:
#     1  not-a-git-repo     a hand-made tree; init.sh runs there too
#     1  no-head            a repo with no commit yet
#     1  not-a-merge        a plain commit; `just base init`, not an upgrade
#     1  no-prior-subtree   the first subtree add
#     2  shallow-history    the parents are grafted away; see below
#     2  parent-unreachable the parent is named and its object is absent
#     2  version-missing    the subtree was there and carried no version
#     2  version-not-semver the version is there and cannot be ordered
_vm_from_version() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _prefix="${2:?"${FUNCNAME[0]}: missing subtree_prefix"}"

  if ! git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'not-a-git-repo'
    return 1
  fi
  if ! git -C "${_root}" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    printf 'no-head'
    return 1
  fi

  # "<head> <parent>..." -- a merge is three fields or more.
  local _line=""
  _line="$(git -C "${_root}" rev-list --parents -n 1 HEAD 2>/dev/null)" || _line=""
  local -a _commits=()
  read -r -a _commits <<< "${_line}"
  if (( ${#_commits[@]} < 3 )); then
    # A shallow clone GRAFTS the parents away, so a merge sitting on the
    # shallow boundary reports no parents at all -- git itself has erased
    # the pair, and the history is then indistinguishable from a root
    # commit. Measured: `git clone --depth 1` of a repo whose HEAD is a
    # subtree-pull merge reads back as parentless. That is not "nothing was
    # crossed", so it must not be reported as such.
    if (( ${#_commits[@]} < 2 )) \
       && [[ "$(git -C "${_root}" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
      printf 'shallow-history'
      return 2
    fi
    printf 'not-a-merge'
    return 1
  fi

  local _first="${_commits[1]}"
  # Named by the merge and not in the object store: a partial clone, a
  # replaced or grafted history, a repository that has lost objects.
  if ! git -C "${_root}" cat-file -e "${_first}^{commit}" 2>/dev/null; then
    printf 'parent-unreachable'
    return 2
  fi
  if ! git -C "${_root}" cat-file -e "${_first}:${_prefix}" 2>/dev/null; then
    printf 'no-prior-subtree'
    return 1
  fi

  local _raw=""
  if ! _raw="$(git -C "${_root}" show "${_first}:${_prefix}/.version" 2>/dev/null)"; then
    printf 'version-missing'
    return 2
  fi
  _raw="${_raw//[[:space:]]/}"
  if ! _vm_is_semver "${_raw}"; then
    printf 'version-not-semver'
    return 2
  fi
  printf '%s' "${_raw}"
}

# ── Selection ──────────────────────────────────────────────────────────────

# interval_migrations <from> <to>
#   The declared migrations landing in the half-open interval `from < V <= to`,
#   one `"<version> <name>"` per line, version ascending with declaration
#   order breaking ties.
#
#   `from` is EXCLUDED because the consumer is already on it: its migrations
#   ran when they arrived there. `to` is INCLUDED because that is the release
#   being installed now. Every declaration is validated whether or not it is
#   selected -- an unusable one is base's own bug, and reporting it only on
#   the upgrades that would have selected it is how it stays unreported.
interval_migrations() {
  local _from="${1:?"${FUNCNAME[0]}: missing from"}"
  local _to="${2:?"${FUNCNAME[0]}: missing to"}"
  (( ${#_VERSION_MIGRATIONS[@]} > 0 )) || return 0

  local _key_from _key_to
  _key_from="$(_vm_key "${_from}")"
  _key_to="$(_vm_key "${_to}")"

  local -a _rows=()
  local _index=0 _entry _version _name _key
  for _entry in "${_VERSION_MIGRATIONS[@]}"; do
    _index=$(( _index + 1 ))
    _version="${_entry%% *}"
    _name="${_entry#* }"
    if [[ -z "${_name}" || "${_name}" == "${_entry}" ]] \
       || ! _vm_is_semver "${_version}"; then
      _log_warn init interval_migration_declined \
        "display=  DECLARATION UNUSABLE: version-bound migration entry '${_entry}' is not '<version> <name>' with a comparable version, so it can never be selected. Fix the declaration in dist/script/docker/lib/version_migrate.sh." \
        "entry=${_entry}"
      continue
    fi
    if ! declare -F "_vmigrate_${_name}_apply" >/dev/null 2>&1; then
      _log_warn init interval_migration_declined \
        "display=  DECLARATION UNUSABLE: version-bound migration '${_name}' is declared for ${_version} but no _vmigrate_${_name}_apply exists, so it can never run." \
        "entry=${_entry}" "migration=${_name}"
      continue
    fi
    _key="$(_vm_key "${_version}")"
    (( 10#${_key} > 10#${_key_from} )) || continue
    (( 10#${_key} <= 10#${_key_to} )) || continue
    # The key and the index are both fixed-width, so one C-collated sort
    # orders by version and then by declaration order.
    _rows+=("$(printf '%s %04d %s %s' "${_key}" "${_index}" "${_version}" "${_name}")")
  done

  (( ${#_rows[@]} > 0 )) || return 0
  printf '%s\n' "${_rows[@]}" | LC_ALL=C sort | awk '{ print $3, $4 }'
}

# ── The runner ─────────────────────────────────────────────────────────────

# run_interval_migrations <repo_root> <subtree_prefix> <to_version>
#   Resolve the interval this repo just crossed and apply the migrations
#   inside it, in order. Always exits 0: it runs inside the resync of an
#   upgrade whose driver arms no rollback around it.
run_interval_migrations() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _prefix="${2:?"${FUNCNAME[0]}: missing subtree_prefix"}"
  local _to="${3:-}"

  if ! _vm_is_semver "${_to}"; then
    _log_warn init interval_migration_unreadable \
      "display=  the installed base version reads '${_to}', which cannot be ordered against anything, so no version-bound migration ran. Check ${_prefix}/.version." \
      "reason=to-not-semver" "to=${_to}"
    return 0
  fi

  # Holds the from-version on success and the REASON otherwise; the exit
  # code says which.
  local _from=""
  local _rc=0
  _from="$(_vm_from_version "${_root}" "${_prefix}")" || _rc=$?
  if (( _rc == 1 )); then
    _log_info init interval_migration_window \
      "display=  no base version interval at HEAD (${_from}) -- no version-bound migration to run" \
      "reason=${_from}" "to=${_to}"
    return 0
  fi
  if (( _rc != 0 )); then
    _log_warn init interval_migration_unreadable \
      "display=  this commit crosses a base version but the version it came FROM cannot be read (${_from}), so no version-bound migration ran. Any that this upgrade owed you has been skipped -- re-run \`just base init\` once ${_prefix}/.version is readable in the commit before it, or apply them by hand." \
      "reason=${_from}" "to=${_to}"
    return 0
  fi

  local _key_from _key_to
  _key_from="$(_vm_key "${_from}")"
  _key_to="$(_vm_key "${_to}")"
  if (( 10#${_key_from} > 10#${_key_to} )); then
    _log_warn init interval_migration_unreadable \
      "display=  the base version went BACKWARDS here, ${_from} -> ${_to}. Version-bound migrations only run forwards, so none ran; a downgrade is not something they can undo." \
      "reason=backwards" "from=${_from}" "to=${_to}"
    return 0
  fi

  local -a _selected=()
  mapfile -t _selected < <(interval_migrations "${_from}" "${_to}")

  _log_info init interval_migration_window \
    "display=  base version interval ${_from} -> ${_to}: ${#_selected[@]} version-bound migration(s) to run" \
    "from=${_from}" "to=${_to}" "count=${#_selected[@]}"

  local _row _version _name _apply_rc
  for _row in ${_selected[@]+"${_selected[@]}"}; do
    _version="${_row%% *}"
    _name="${_row#* }"
    _apply_rc=0
    "_vmigrate_${_name}_apply" "${_root}" || _apply_rc=$?
    if (( _apply_rc != 0 )); then
      _log_warn init interval_migration_unreadable \
        "display=  MIGRATION FAILED: ${_name} (lands in ${_version}) exited ${_apply_rc}. The upgrade itself is not rolled back, and the migrations after it were SKIPPED so none of them runs on a half-migrated repo. Fix the cause and re-run \`just base init\`." \
        "reason=apply-failed" "migration=${_name}" "version=${_version}" "code=${_apply_rc}"
      return 0
    fi
    _log_info init interval_migration_applied \
      "display=  applied version-bound migration ${_name} (lands in ${_version})" \
      "migration=${_name}" "version=${_version}" "from=${_from}" "to=${_to}"
  done
}
