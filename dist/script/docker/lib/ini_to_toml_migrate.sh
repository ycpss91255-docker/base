#!/usr/bin/env bash
#
# ini_to_toml_migrate.sh - one-time INI-to-TOML migration for downstream repos.
#
# Converts the pre-ADR-37 INI config files to their TOML equivalents
# during the first init.sh resync after a base upgrade:
#
#   .setup.conf        -> setup.toml
#   .setup.conf.local  -> setup.local.toml
#   .env.local         -> .env.local.toml
#
# Each conversion is gated on the source file existing AND the target
# NOT existing, so the migration is idempotent: a repo that already has
# the TOML file (whether from a fresh bootstrap or a previous upgrade)
# is left alone. The original file is renamed to .bak for verification --
# but only once the converted file has been parsed, see below.
#
# ── Verify before retiring the source ─────────────────────────────────
#
# The rename used to be unconditional, so an input the converter could
# not render as valid TOML took the operator's only copy of the
# configuration with it: the repo was left with an unparseable
# setup.toml, a .setup.conf.bak that the shipped .gitignore excludes,
# and an idempotency gate that will never convert again because the
# target now exists. The log line said the settings "were converted".
#
# Each conversion therefore lands on a temp file, hands that temp file
# to the SHIPPED bridge, and only promotes it to the target once the
# parse succeeds. A parse that fails writes nothing, renames nothing,
# removes the temp file and says which input it could not convert and
# what the parser objected to. The refusal is recoverable; the rename
# was not.
#
# ── Why HERE and not in upgrade.sh ─────────────────────────────────
#
# Same reasoning as _migrate_env_to_local, _migrate_legacy_setup_conf,
# and _migrate_smoke_tree: an upgrade is driven by the CONSUMER'S OWN
# vendored upgrade.sh, a copy that shipped before TOML support existed.
# init.sh is the one piece of CURRENT code the upgrade re-runs (Step 3
# resync), so the migration runs from the existing-repo resync path.
#
# ── Numbered-key -> array-of-tables mapping ────────────────────────
#
# A numbered INI key becomes the `[[array of tables]]` block the SHIPPED
# WRITER puts it in, and the conversion is DERIVED from that writer rather
# than listed here: _conf_toml_aot_slot says which array path a
# `<section>.<key>` belongs to, and _conf_toml_aot_fields renders the one
# block's body. Those are the same two functions `setup.sh set` / `add`
# write through, and the bridge's array spec is the other side of them.
#
# Why derived and not a table of its own. A converted file is read back by
# the bridge, and a field name only the converter knows reads back as an
# empty entry: a `[[volumes]]` block carrying `path` -- which is what a
# hand-written table here said -- loses every mount on the upgrade that
# converts the repo, silently, with the INI already renamed to .bak. The
# same holds for a numbered key with NO array home at all.
#
# What has no array home stays a quoted scalar under its own table, which
# is again what the writer does and what the runtime readers look for:
# `[environment] env_N` and `[security] cap_drop_N`. The direct-key
# `[environment] KEY = "V"` form the template documents is the D5 / D6
# destination; until those readers land,
# `_conf_list_sorted ... environment env_` is what reads the section, so
# unpacking here would drop the variable.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_INI_TO_TOML_MIGRATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_INI_TO_TOML_MIGRATE_SOURCED=1

_ini_to_toml_migrate_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/conf.sh
source "${_ini_to_toml_migrate_lib_dir}/conf.sh"
unset _ini_to_toml_migrate_lib_dir

# ── TOML value formatting ─────────────────────────────────────────────

# _ini_to_toml_format_value <value>
#
# Format a value as the TOML scalar that reads back to the same bash
# string, by delegating to conf.sh's _conf_toml_scalar -- the renderer the
# shipped writers already use.
#
# Not a second implementation: this one escaped a double quote and nothing
# else, so an ordinary INI value carrying a backslash (a watchdog `pgrep`
# pattern, a Windows-style path) came out as an undefined TOML escape and
# made the WHOLE converted file unparseable -- after the INI had been
# renamed to .bak, so the only copy of the configuration was the broken
# one. _conf_toml_scalar escapes backslash, double quote and tab, keeps a
# boolean and an integer bare, and refuses to render a leading-zero
# number as a bare integer TOML would reject.
_ini_to_toml_format_value() {
  local _fv_out=""
  _conf_toml_scalar "${1-}" _fv_out
  printf '%s' "${_fv_out}"
}

# ── Numbered-key detection ─────────────────────────────────────────────

# _ini_to_toml_is_numbered <section> <key>
#
# Return 0 when <key> is a numbered key that HAS an array-of-tables home,
# asked of the shipped writer rather than re-matched here. A numbered key
# with no array home (`env_N`, `cap_drop_N`) answers 1 and
# is carried over as a scalar, which is where every reader looks for it.
#
# The out-variable names are prefixed, like every nameref target in this
# tree: _conf_toml_aot_slot has locals of its own called `_path` and
# `_idx`, and a nameref pointing at either of those names resolves to the
# callee's local instead of ours -- it comes back empty, and the key then
# reads as one with no array home.
_ini_to_toml_is_numbered() {
  local _itn_path="" _itn_idx=""
  _conf_toml_aot_slot "${1-}" "${2-}" _itn_path _itn_idx
}

# ── Numbered-key -> AoT emission ──────────────────────────────────────

# _ini_to_toml_emit_aot <path> <value> <outvar>
#
# Append the one `[[<path>]]` block one slot of a numbered family becomes
# to <outvar>. The body comes from the shipped writer
# (_conf_toml_aot_fields), so the field names are the ones the bridge's
# array spec reads back and there is no second spelling to drift. The
# PATH is the caller's, because the caller has already asked
# _conf_toml_aot_slot for it -- and because a hole in the family has no
# INI key to ask about.
#
# An EMPTIED slot becomes a FIELD-LESS block, which is what keeps the
# family's positions. It is not the same thing as rendering the empty
# value: `_conf_toml_aot_fields build.args ""` produces `key = ""` /
# `value = ""`, and the bridge glues those halves back into the
# NON-EMPTY string `"="` -- a bogus build arg that `_conf_list_sorted`
# does not skip, because it only skips an empty value. `network.ports`
# is the same trap spelled `":"`. A block with no fields at all reads
# back empty for every family: each serialiser in the bridge's array
# spec answers "" for an absent field, and the two that glue halves
# together are gated on the first half being present.
_ini_to_toml_emit_aot() {
  local _eao_p="$1" _eao_v="$2"
  local -n _aot_out="$3"

  local _eao_fields=""
  if [[ -n "${_eao_v}" ]]; then
    _conf_toml_aot_fields "${_eao_p}" "${_eao_v}" _eao_fields
  fi

  _aot_out+="[[${_eao_p}]]"$'\n'
  # A populated slot whose body came back empty still keeps its block:
  # dropping it would renumber every slot after it, which is the defect
  # this function's field-less block exists to prevent.
  if [[ -n "${_eao_fields}" ]]; then
    _aot_out+="${_eao_fields}"$'\n'
  fi
  _aot_out+=$'\n'
}

# ── Commit gate ───────────────────────────────────────────────────────

# _ini_to_toml_commit <source_file> <tmp_file> <toml_file>
#
# Promote a just-written conversion to <toml_file>, but only after the
# SHIPPED bridge has parsed it. On a parse failure: remove the temp file,
# leave <toml_file> absent, say which input could not be converted and
# what the parser objected to, and answer non-zero so the caller does not
# retire <source_file>.
#
# The parse goes through toml_bridge_parse, not a regex of our own. The
# whole point is to ask the reader that will have to read this file once
# the source is gone, and a second opinion written here would be exactly
# the drift the derived placement above exists to avoid.
#
# An unavailable bridge reads as a refusal, not as a pass. That is the
# safe direction: an unverified conversion whose source has been renamed
# is the unrecoverable outcome, while a refusal costs the operator one
# re-run. Which hosts can run the bridge at all is a separate open
# question on this epic (ADR-00000037); it does not change which way an
# unanswered question should fail.
#
# The parser diagnostic is folded onto one line: it reaches the log as an
# attribute value, and the text sink renders a body on one line.
_ini_to_toml_commit() {
  local _src="${1:?"${FUNCNAME[0]}: missing source file"}"
  local _tmp="${2:?"${FUNCNAME[0]}: missing tmp file"}"
  local _toml="${3:?"${FUNCNAME[0]}: missing toml file"}"

  local _why=""
  if _why="$(toml_bridge_parse "${_tmp}" 2>&1 >/dev/null)"; then
    mv -f -- "${_tmp}" "${_toml}"
    return 0
  fi

  rm -f -- "${_tmp}"
  _why="${_why//$'\n'/ }"
  _log_warn init ini_to_toml_migration_declined \
    "display=MIGRATION DECLINED for ${_src}: the INI-to-TOML conversion (ADR-00000037) produced a file the TOML parser refuses, so nothing was written and nothing was renamed -- your configuration is still at ${_src}, unchanged. Parser said: ${_why:-the TOML parser could not be run}. Convert the file into ${_toml} by hand and re-run \`just base init\`, or report the file on the base issue tracker." \
    "path=${_src}" \
    "target=${_toml}" \
    "reason=${_why}"
  return 1
}

# ── Core converter ────────────────────────────────────────────────────

# _ini_to_toml_convert <ini_file> <toml_file>
#
# Read an INI file and write its TOML equivalent. Uses _ini_tokenize
# from conf.sh for parsing. Writes to a temp file, which
# _ini_to_toml_commit promotes to <toml_file> only once the bridge has
# parsed it; answers non-zero, having written no <toml_file>, when it has
# not.
_ini_to_toml_convert() {
  local _ini="${1:?"${FUNCNAME[0]}: missing ini file"}"
  local _toml="${2:?"${FUNCNAME[0]}: missing toml file"}"

  local -a _sects=() _es=() _keys=() _vals=()
  _ini_tokenize "${_ini}" _sects _es _keys _vals

  local _result="" _root_decls=""
  local _s _i _j

  for _s in ${_sects[@]+"${_sects[@]}"}; do
    # Separate scalar and numbered keys for this section.
    #
    # A repeated scalar key collapses to its LAST occurrence, held at the
    # position of its first. An INI is free to name a key twice -- the
    # chain accessors `_conf_get` / `_conf_get_into` keep assigning as
    # they walk, so `[gui] mode = off` followed by `mode = auto`
    # resolved to `auto` -- but TOML refuses a key written twice
    # (`Cannot overwrite a value`) and stops parsing the whole file. The
    # commit gate caught that, so the outcome was a DECLINED conversion
    # with the INI intact rather than data loss; it was still a repo that
    # could not complete an upgrade, declining again on every re-run,
    # until someone hand-resolved the duplicate.
    #
    # (`_get_conf_value`, the raw-array accessor in setup_conf.sh,
    # answers the FIRST occurrence instead. That divergence predates this
    # file; the chain accessor is the one the layer merge reads through,
    # and its answer is what a converted file has to keep.)
    # The collapse is for a key a SCALAR accessor reads. A key shaped
    # `<prefix>_<digits>` is read by the list accessors instead, and
    # those are not last-wins: `_conf_list_sorted` collects every
    # non-empty entry, so `[environment] env_1` named twice is a
    # TWO-variable list. The ones with no array-of-tables home --
    # `env_N`, `cap_drop_N` -- stay quoted scalars here, which is where
    # every reader of them looks, so collapsing them would drop a
    # variable or a dropped capability from a file the parser accepts
    # and from an INI already renamed to .bak. They are left uncollapsed:
    # the duplicate then reaches the commit gate as the unrenderable TOML
    # it is, the conversion is DECLINED, and the operator's two lines are
    # still there. A decline is recoverable; a silent loss is not. The
    # price is that such a repo cannot upgrade until the duplicate is
    # resolved by hand, and that is the deliberate trade: see the
    # repeated-scalar-key cases in the spec for the shape that IS
    # collapsed.
    local -a _sc_keys=() _sc_vals=()
    local -a _num_order=()
    local -A _sc_at=()
    local _aot_buf="" _decl_buf=""

    for (( _i = 0; _i < ${#_keys[@]}; _i++ )); do
      [[ "${_es[_i]}" == "${_s}" ]] || continue
      if _ini_to_toml_is_numbered "${_s}" "${_keys[_i]}"; then
        _num_order+=("${_i}")
      elif [[ "${_keys[_i]}" =~ ^.+_[0-9]+$ ]]; then
        _sc_keys+=("${_keys[_i]}")
        _sc_vals+=("${_vals[_i]}")
      elif [[ -n "${_sc_at[${_keys[_i]}]+set}" ]]; then
        _sc_vals["${_sc_at[${_keys[_i]}]}"]="${_vals[_i]}"
      else
        _sc_at["${_keys[_i]}"]="${#_sc_keys[@]}"
        _sc_keys+=("${_keys[_i]}")
        _sc_vals+=("${_vals[_i]}")
      fi
    done

    # Emit each numbered family DENSE from index 1 up to its highest
    # POPULATED index, and nothing above that.
    #
    # Why dense, and why from 1. A numbered family is addressed by
    # POSITION on both sides: the N-th `[[volumes]]` block IS
    # `volumes.mount_N`, because that is how the bridge numbers the
    # blocks it meets. So an emptied slot that is not emitted does not
    # just disappear -- it renumbers every slot after it.
    # `_reconcile_workspace_path` reads slot 1 as the workspace bind, and
    # clearing `mount_1` is the published opt-out (README; v0.9), so an
    # INI with an empty `mount_1` and a `mount_2 = /data:/data` converted
    # into ONE block makes the operator's data directory the workspace --
    # silently, because an absolute source that exists is honoured as a
    # pinned path and warns about nothing. The shipped INI template's
    # `[volumes]` IS `mount_1 =`, so that is the seeded state of every
    # downstream repo, not an edge case. The same renumbering under
    # `[[image.rules]]` changes the image name the repo builds under,
    # which this converter has already been fixed for once (v0.43).
    #
    # Dense from 1 rather than "every index the INI names": a hole below
    # the highest populated slot need not be a key at all. A `[volumes]`
    # carrying only `mount_2 = ...` still means the extra bind is the
    # SECOND entry, because that is the name the operator gave it, and a
    # present-keys-only rule would hand it position 1.
    #
    # Nothing above the highest populated index, because a trailing run
    # of emptied slots carries no position for anything to be displaced
    # from.
    #
    # An emptied slot is emitted field-less, NOT with an empty body: see
    # _ini_to_toml_emit_aot for what rendering the empty value costs.
    #
    # A REPEATED index keeps every occurrence. The list readers
    # (`_conf_list_sorted`, `_get_conf_list_sorted`) collect every
    # non-empty entry and sort the collection -- neither is last-wins, so
    # `port_1 = 8080:80` twice is a TWO-port list, and `port_01` beside
    # `port_1` is two entries with one sort key. Collapsing them to one
    # would silently drop a published port, with the INI already renamed
    # to .bak. The occurrences of one index are therefore emitted in the
    # order those readers put them in, by sorting each family through the
    # SAME `sort -t: -k1,1n` they use, so the tie-break is theirs and not
    # a second opinion. That the blocks after a repeat shift up is the
    # list's own shape: three entries occupy three positions whatever
    # they were named.
    #
    # `10#` on every arithmetic read of a suffix: bash's default
    # arithmetic base reads a zero-padded value as octal, and `08` is not
    # a valid octal literal -- the comparison dies instead of ordering it
    # (base#1097 lost time to exactly this).
    if (( ${#_num_order[@]} > 0 )); then
      local -A _itc_pairs=() _itc_max=()
      local -a _itc_paths=()
      local _ni _itc_path _itc_suf _itc_n _itc_cur _itc_hi _itc_line _itc_v
      for _ni in "${_num_order[@]}"; do
        _itc_path=""
        _itc_suf=""
        _conf_toml_aot_slot "${_s}" "${_keys[_ni]}" _itc_path _itc_suf || continue
        _itc_n=$(( 10#${_itc_suf} ))
        # ANY key of the family registers it, a `_0` and an emptied slot
        # included: registration is what decides whether a cleared list
        # owes a declaration, and `[network] port_0 =` on its own is
        # still an operator who left that list with nothing in it.
        if [[ -z "${_itc_max[${_itc_path}]+set}" ]]; then
          _itc_paths+=("${_itc_path}")
          _itc_max["${_itc_path}"]=0
        fi
        # An array of tables is 1-based -- `PORT_1` = first published
        # port is published contract (ADR-00000022) -- so a `_0` key
        # names a slot that cannot exist in the converted file. The INI
        # list readers DO accept it and sort it first, so emitting it
        # there would displace every position below it (`mount_1`, the
        # workspace bind, included) and dropping it would lose a
        # published port or bind outright. Neither is acceptable in a
        # converter that renames the source away, so this is refused:
        # the operator renumbers from 1 and re-runs, and until then the
        # INI is exactly where it was. An EMPTY `_0` slot carries
        # nothing and names no position, so it is simply ignored.
        if (( _itc_n < 1 )); then
          [[ -n "${_vals[_ni]}" ]] || continue
          _log_warn init ini_to_toml_index_unrepresentable \
            "display=MIGRATION DECLINED for ${_ini}: \`[${_s}] ${_keys[_ni]}\` numbers a list entry 0, and the TOML array of tables it converts to is 1-based (ADR-00000022), so there is no block for it to become. Nothing was written and nothing was renamed -- your configuration is still at ${_ini}, unchanged. Renumber the entries of that list from 1 and re-run \`just base init\`." \
            "path=${_ini}" \
            "key=${_s}.${_keys[_ni]}"
          return 1
        fi
        # An empty occurrence contributes no entry, which is what both
        # list readers do with one.
        [[ -n "${_vals[_ni]}" ]] || continue
        # The pair carries the RAW suffix, not the normalised index: the
        # readers sort `<suffix>:<value>` lines and `sort -t: -k1,1n`
        # breaks a numeric tie by comparing the WHOLE line, so `rule_01`
        # beside `rule_1` is ordered by the text `01` against `1` and
        # not by the values. Normalising first made the values the
        # tie-break and reversed the pair -- which for `[[image.rules]]`
        # is the image name the repo builds under. `10#` is applied
        # where the line is grouped instead.
        _itc_pairs["${_itc_path}"]+="${_itc_suf}:${_vals[_ni]}"$'\n'
        _itc_cur="${_itc_max[${_itc_path}]}"
        if (( _itc_n > _itc_cur )); then
          _itc_max["${_itc_path}"]="${_itc_n}"
        fi
      done

      # Families in path order, which groups each one together -- it
      # matters for the one section carrying TWO of them (`device_N` and
      # `cgroup_rule_N` under [devices]); the two number independently,
      # so grouping is for the reader of the file, not for correctness.
      while IFS= read -r _itc_path; do
        [[ -n "${_itc_path}" ]] || continue
        _itc_hi="${_itc_max[${_itc_path}]}"
        if (( _itc_hi == 0 )); then
          # Every slot the INI named is empty, so the family is a list
          # the operator REPLACED WITH NOTHING -- under the pre-ADR-37
          # chain `[build]` merged by section-replace (ADR-00000025
          # sec. 3), so a repo whose only arg slot was empty resolved to
          # zero build args. Emitting no blocks makes the TOML key
          # ABSENT, the one state that is not a replacement, and the
          # key-level merge then inherits the template's whole list.
          # The writer's own `path = []` declaration is the replacement
          # with nothing, and _conf_toml_array_decl is the writer's
          # answer to WHERE it goes: inside the owning table for a
          # dotted path, and in the root-key region -- the region before
          # the first table header, the only home TOML gives a root key
          # -- for a path that has no table.
          #
          # A root-level family whose section ALSO carries a scalar key
          # (`[volumes] label = ...`) has no rendering at all: TOML will
          # not let `volumes` be an empty array and a table in one
          # document, and that is true of the populated case too, where
          # the `[[volumes]]` blocks collide with the `[volumes]` table.
          # The commit gate refuses such a file and the INI survives,
          # which is the right end for an input with no representation.
          # No schema key of this tree is a scalar under one of those
          # three sections.
          local _itc_t="" _itc_k=""
          _conf_toml_array_decl "${_itc_path}" _itc_t _itc_k
          if [[ -n "${_itc_t}" ]]; then
            _decl_buf+="${_itc_k} = []"$'\n'
          else
            _root_decls+="${_itc_k} = []"$'\n'
          fi
          continue
        fi
        # Group this family's entries by index, in the readers' own order.
        # No LC_ALL here, deliberately. This is the one sort whose
        # answer has to AGREE with the readers', and neither reader
        # forces a collation -- both inherit the caller's. Pinning C
        # would order `prefix:Z` against `prefix:a` one way while the
        # reader of the converted file ordered them the other.
        local -A _itc_slot=()
        while IFS= read -r _itc_line; do
          [[ -n "${_itc_line}" ]] || continue
          _itc_slot[$(( 10#${_itc_line%%:*} ))]+="${_itc_line#*:}"$'\n'
        done < <(printf '%s' "${_itc_pairs[${_itc_path}]-}" \
                   | sort -t: -k1,1n)
        for (( _itc_n = 1; _itc_n <= _itc_hi; _itc_n++ )); do
          if [[ -z "${_itc_slot[${_itc_n}]+set}" ]]; then
            _ini_to_toml_emit_aot "${_itc_path}" "" _aot_buf
            continue
          fi
          while IFS= read -r _itc_v; do
            [[ -n "${_itc_v}" ]] || continue
            _ini_to_toml_emit_aot "${_itc_path}" "${_itc_v}" _aot_buf
          done <<< "${_itc_slot[${_itc_n}]}"
        done
      done < <(printf '%s\n' ${_itc_paths[@]+"${_itc_paths[@]}"} \
                 | LC_ALL=C sort -u)
    fi

    # Emit section header + scalar keys. The header is emitted for a
    # section that has only an emptied family too: the declaration is an
    # ordinary key of the table and has nowhere else to go, so the table
    # a `[build]` with nothing but `arg_1 =` never declared is declared
    # here.
    if (( ${#_sc_keys[@]} > 0 )) || [[ -n "${_decl_buf}" ]]; then
      if [[ "${_s}" == *:* ]]; then
        _result+="[\"${_s}\"]"$'\n'
      else
        _result+="[${_s}]"$'\n'
      fi
      for (( _j = 0; _j < ${#_sc_keys[@]}; _j++ )); do
        local _fk="${_sc_keys[_j]}"
        # Quote keys that contain dots (dotted keys in stage overrides).
        if [[ "${_fk}" == *.* ]]; then
          _fk="\"${_fk}\""
        fi
        _result+="${_fk} = $(_ini_to_toml_format_value "${_sc_vals[_j]}")"$'\n'
      done
      _result+="${_decl_buf}"
      _result+=$'\n'
    fi

    # Emit array-of-tables entries (after the section's scalars).
    if [[ -n "${_aot_buf}" ]]; then
      _result+="${_aot_buf}"
    fi
  done

  # A root-level array's declaration goes in the root-key region, ahead
  # of every table header the walk above wrote.
  if [[ -n "${_root_decls}" ]]; then
    _result="${_root_decls}"$'\n'"${_result}"
  fi

  # Write to a temp file, and let the commit gate decide whether it
  # becomes the configuration.
  local _tmp="${_toml}.$$"
  printf '%s' "${_result}" > "${_tmp}"
  _ini_to_toml_commit "${_ini}" "${_tmp}" "${_toml}"
}

# ── The conversions this module performs ──────────────────────────────

# _ini_to_toml_conversions
#
# One row per conversion _migrate_ini_to_toml performs, as
# `source<TAB>target`, repo-root-relative.
#
# THE table. The converter below walks it instead of spelling each
# conversion out, and init.sh derives this migration's entries of the
# rollback surface from it (_init_protected_paths via
# _ini_to_toml_migration_paths), so a conversion added here is covered by
# the edit that adds it. The alternative is a second list of "files the
# rollback should care about", kept in agreement with this one by
# somebody remembering -- the shape base#1090 and base#1113 spent PRs
# removing.
#
# _migrate_env_local_to_toml's own pair is deliberately NOT a row here.
# It has no caller in the resync until base#1163 restores one, so the
# resync cannot touch those names and a rollback has nothing of theirs
# to put back; the change that restores the caller adds the row.
_ini_to_toml_conversions() {
  cat <<'EOF'
.setup.conf	setup.toml
.setup.conf.local	setup.local.toml
EOF
}

# _ini_to_toml_migration_paths
#
# Every repo-root-relative path those conversions can create, rename away
# or leave behind: each source, the `.bak` the rename puts it at, and the
# target the conversion writes.
#
# This is the ROLLBACK's view of the table above, and it lives here
# because the table does. A rollback that knows a migration's target but
# not its source removes the new file -- its snapshot recorded that name
# as absent -- and leaves the rename standing, so a run that failed ends
# with neither file: not the converted one and not the configuration it
# converted. That is strictly worse than either endpoint, and it is the
# successful-conversion side of the containment base#1137 closed from the
# failed side.
_ini_to_toml_migration_paths() {
  local _src _dst
  while IFS=$'\t' read -r _src _dst; do
    [[ -n "${_src}" && -n "${_dst}" ]] || continue
    printf '%s\n%s.bak\n%s\n' "${_src}" "${_src}" "${_dst}"
  done < <(_ini_to_toml_conversions)
}

# _ini_to_toml_record <repo-relative-path>
#
# Record a path this migration wrote, so `_stage_resync_output` puts it in
# the upgrade commit. init.sh's `_init_record_write` is the only record
# that step reads, and since base#1097 it stages EVERY recorded path
# rather than using the record as a filter over two closed lists -- which
# is the mechanism a migration's output needs, because no list written
# before the migration existed can name it.
#
# A no-op where `_init_record_write` is not defined. The lib is also
# sourced on its own -- by the unit specs, and by anything driving a
# conversion outside a resync -- and there is no commit to stage into
# there.
_ini_to_toml_record() {
  declare -F _init_record_write > /dev/null 2>&1 || return 0
  _init_record_write "${1:?"${FUNCNAME[0]}: missing repo-relative path"}"
}

# ── Migration entry points ────────────────────────────────────────────

# _migrate_ini_to_toml <repo_root>
#
# Convert every row of _ini_to_toml_conversions whose source is present
# and whose target is not: .setup.conf -> setup.toml and
# .setup.conf.local -> setup.local.toml today. Each row is gated
# independently on [[ -f source && ! -f target ]].
#
# The rename of each source is gated a second time, on its conversion
# having parsed: a row that _ini_to_toml_convert refused has already said
# so and left both files alone, so there is nothing to retire and nothing
# to announce. Each row answers for itself -- a repo whose .setup.conf
# converts and whose .setup.conf.local does not keeps the conversion it
# got.
#
# ONE announcement body for every row, with the two file names in it,
# rather than one body per row. The two bodies this replaced said the
# same thing about two rows of one table, which made the registry a
# third place a conversion had to be added.
#
# A refusal in any row is then reported to the CALLER as a non-zero
# answer, and that is the half that makes the containment hold. Nothing
# downstream of the resync knows a migration was declined: `main` goes on
# to call setup, which seeds a setup.toml from the template defaults, and
# the seeded file satisfies this function's own `! -f target` gate. The
# surviving INI would stop taking effect and would never be converted
# again. Declining quietly, the way _migrate_smoke_tree declines, is only
# safe because nothing later writes the smoke tree.
_migrate_ini_to_toml() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _rc=0

  local _src _dst _ini _toml
  while IFS=$'\t' read -r _src _dst; do
    [[ -n "${_src}" && -n "${_dst}" ]] || continue
    _ini="${_root%/}/${_src}"
    _toml="${_root%/}/${_dst}"
    [[ -f "${_ini}" && ! -f "${_toml}" ]] || continue
    if _ini_to_toml_convert "${_ini}" "${_toml}"; then
      mv -- "${_ini}" "${_ini}.bak"
      # BOTH sides of the conversion, or the upgrade commit describes a
      # tree it does not carry: the TOML file this run wrote, and the
      # tracked INI the rename took away, whose DELETION is as much this
      # run's output as the write is. Without them a fresh clone of a
      # migrated consumer gets the template defaults -- `setup.toml`
      # untracked, `.setup.conf` deleted but not staged -- which is
      # base#1036 reached through a migration rather than through a
      # rewrite. `_stage_resync_output` drops the `.bak` on its own: it is
      # a canonical gitignore entry, so check-ignore reports it.
      _ini_to_toml_record "${_dst}"
      _ini_to_toml_record "${_src}"
      _log_warn init ini_to_toml_migrated \
        "display=MIGRATION: ${_src} -> ${_dst}. The configuration format has been upgraded from INI to TOML (ADR-00000037). Your settings were converted and the original was backed up to ${_src}.bak." \
        "path=${_toml}"
    else
      _rc=1
    fi
  done < <(_ini_to_toml_conversions)

  return "${_rc}"
}

# _migrate_env_local_to_toml <repo_root>
#
# Convert .env.local (flat KEY=VALUE) -> .env.local.toml (TOML with
# [environment] section). Gated on [[ -f .env.local && ! -f
# .env.local.toml ]], and the rename of the source gated again on the
# conversion having parsed, for the reason the file header gives. A
# refusal answers non-zero, like the sibling above: this one has no
# caller yet, and the caller base#1163 restores needs the same signal.
_migrate_env_local_to_toml() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _env="${_root%/}/.env.local"
  local _toml="${_root%/}/.env.local.toml"

  [[ -f "${_env}" && ! -f "${_toml}" ]] || return 0

  local _result
  _result=$'[environment]\n'

  local _line _k _v
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    # Skip comments and blank lines.
    [[ -z "${_line}" || "${_line}" =~ ^[[:space:]]*# ]] && continue
    # Skip lines without =
    [[ "${_line}" == *=* ]] || continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    # Trim whitespace.
    _k="${_k#"${_k%%[![:space:]]*}"}"
    _k="${_k%"${_k##*[![:space:]]}"}"
    _v="${_v#"${_v%%[![:space:]]*}"}"
    _v="${_v%"${_v##*[![:space:]]}"}"
    [[ -n "${_k}" ]] || continue
    # Strip matching outer quotes (docker compose convention).
    if [[ "${_v}" =~ ^\"(.*)\"$ ]]; then
      _v="${BASH_REMATCH[1]}"
    elif [[ "${_v}" =~ ^\'(.*)\'$ ]]; then
      _v="${BASH_REMATCH[1]}"
    fi
    _result+="${_k} = \"${_v}\""$'\n'
  done < "${_env}"

  # Write to a temp file; the commit gate parses it and only then does it
  # become .env.local.toml and the source become a .bak.
  local _tmp="${_toml}.$$"
  printf '%s' "${_result}" > "${_tmp}"
  _ini_to_toml_commit "${_env}" "${_tmp}" "${_toml}" || return 1
  mv -- "${_env}" "${_env}.bak"
  _log_warn init env_local_to_toml_migrated \
    "display=MIGRATION: .env.local -> .env.local.toml. The per-instance env override was converted from flat KEY=VALUE to TOML (ADR-00000037) and the original was backed up to .env.local.bak." \
    "path=${_toml}"
}
