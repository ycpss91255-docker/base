#!/usr/bin/env bats
#
# schema_coverage_spec.bats — registry drift guards for lib/schema.sh
# (schema epic phase 3).
#
# Phase 1 added the validator registry; phase 2 added the
# ordered SCHEMA_SECTIONS + accessors. These tests assert the registry
# stays internally consistent and in sync with the setup.conf template,
# so schema drift fails CI instead of surfacing as a runtime surprise:
#   - every validator name resolves to a defined function,
#   - SCHEMA_SECTIONS matches the template section headers in file order,
#   - every SCHEMA_EMPTY key is a registered validator key,
#   - every registered key is reachable via SCHEMA_SECTIONS.
#
# Phase 3 follow-up adds the i18n-index column SCHEMA_I18N and the
# locale-coverage assertion the original scope deferred: every
# registered key maps to an i18n key (or an explicit "" opt-out for keys
# with no TUI editor), and every mapped i18n key is present in all four
# locale tables (en / zh-TW / zh-CN / ja). A missing translation in any
# locale, or a new validator key without an index entry, fails CI here.
#
# why: Registry drift guards (#562, schema epic #559 phase 3): the registry
# must stay internally consistent and in sync with the `setup.conf`
# template, so drift fails CI. The deferred i18n coverage now lands via the
# `SCHEMA_I18N` index column (#591): every registered key maps to a TUI
# message key (or an explicit `""` opt-out for keys with no editor), and
# every mapped key is present in all four locale tables (en / zh-TW / zh-CN
# / ja) -- a missing translation in any locale fails CI.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/schema.sh
}

# Source setup_tui.sh to populate the per-locale _TUI_MSG_* tables. The
# BASH_SOURCE guard at the bottom of setup_tui.sh keeps main from
# running, so this only loads the i18n tables + helpers (mirrors tui_spec).
_load_locale_tables() {
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup_tui.sh
}

# why: no ghost validators (#562)
@test "every SCHEMA_VALIDATOR validator name resolves to a defined function (#562)" {
  local _canon _fn _missing=""
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    _fn="${SCHEMA_VALIDATOR[${_canon}]}"
    declare -F "${_fn}" >/dev/null 2>&1 || _missing+=" ${_canon}=>${_fn}"
  done
  [ -z "${_missing}" ] || { echo "validators not defined:${_missing}"; false; }
}

# why: registry/template drift (#562)
@test "SCHEMA_SECTIONS matches the setup.conf template headers in file order (#562)" {
  # Registry / template drift guard: the ordered SCHEMA_SECTIONS list must
  # equal the [section] headers in the shipped template, in file order. A
  # section added to the template but not the registry (or vice versa)
  # fails here.
  local _tpl="/source/dist/.setup.conf"
  local -a _hdrs=()
  local _line
  while IFS= read -r _line; do
    _hdrs+=("${_line}")
  done < <(grep -oE '^\[[a-z_]+\]' "${_tpl}" | tr -d '[]')
  [ "${SCHEMA_SECTIONS[*]}" = "${_hdrs[*]}" ]
}

# why: no dead empty-policy entries (#562)
@test "every SCHEMA_EMPTY key is a registered SCHEMA_VALIDATOR key (#562)" {
  # The empty-value policy table may only reference keys that actually
  # have a validator -- an orphan SCHEMA_EMPTY entry is dead config.
  local _k _missing=""
  for _k in "${!SCHEMA_EMPTY[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] || _missing+=" ${_k}"
  done
  [ -z "${_missing}" ] || { echo "orphan SCHEMA_EMPTY keys:${_missing}"; false; }
}

# why: no key stranded under an unlisted section (#562)
@test "every registered key is reachable via SCHEMA_SECTIONS (#562)" {
  # No validator key may be stranded under a section missing from
  # SCHEMA_SECTIONS: the count of keys reachable by walking
  # SCHEMA_SECTIONS + _schema_section_keys must equal the registry size.
  local _seen=0 _sec
  for _sec in "${SCHEMA_SECTIONS[@]}"; do
    local -a _k=()
    _schema_section_keys "${_sec}" _k
    _seen=$(( _seen + ${#_k[@]} ))
  done
  [ "${_seen}" -eq "${#SCHEMA_VALIDATOR[@]}" ]
}

# why: i18n-index is complete (#591)
@test "every SCHEMA_VALIDATOR key has a SCHEMA_I18N index entry (#591)" {
  # The i18n-index must be complete: every registered validator key needs
  # an SCHEMA_I18N row (a message key, or an explicit "" opt-out for keys
  # with no TUI editor). A new validator key added without an index entry
  # fails here, forcing the author to decide its i18n mapping.
  local _canon _missing=""
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    [[ -v "SCHEMA_I18N[${_canon}]" ]] || _missing+=" ${_canon}"
  done
  [ -z "${_missing}" ] || { echo "validator keys missing SCHEMA_I18N entry:${_missing}"; false; }
}

# why: no orphan index rows (#591)
@test "every SCHEMA_I18N key is a registered SCHEMA_VALIDATOR key (#591)" {
  # No orphan index rows: an SCHEMA_I18N entry pointing at a key with no
  # validator is dead config (mirrors the SCHEMA_EMPTY orphan guard).
  local _k _missing=""
  for _k in "${!SCHEMA_I18N[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] || _missing+=" ${_k}"
  done
  [ -z "${_missing}" ] || { echo "orphan SCHEMA_I18N keys:${_missing}"; false; }
}

# why: no missing translation in any locale (#591)
@test "every SCHEMA_I18N message key exists in all four locale tables (#591)" {
  # The coverage assertion deferred: resolve each registered key's
  # i18n key through SCHEMA_I18N and assert it is present in EN / ZH_TW /
  # ZH_CN / JA. A missing translation in any locale fails CI. Keys mapped
  # to "" (no TUI editor) are skipped — they carry no label to translate.
  _load_locale_tables

  local -n _t_en=_TUI_MSG_EN
  local -n _t_tw=_TUI_MSG_ZH_TW
  local -n _t_cn=_TUI_MSG_ZH_CN
  local -n _t_ja=_TUI_MSG_JA

  local _canon _msg _missing=""
  for _canon in "${!SCHEMA_I18N[@]}"; do
    _msg="${SCHEMA_I18N[${_canon}]}"
    [[ -z "${_msg}" ]] && continue   # explicit no-editor opt-out
    [[ -v "_t_en[${_msg}]" ]] || _missing+=" en:${_canon}->${_msg}"
    [[ -v "_t_tw[${_msg}]" ]] || _missing+=" zh-TW:${_canon}->${_msg}"
    [[ -v "_t_cn[${_msg}]" ]] || _missing+=" zh-CN:${_canon}->${_msg}"
    [[ -v "_t_ja[${_msg}]" ]] || _missing+=" ja:${_canon}->${_msg}"
  done
  [ -z "${_missing}" ] || { echo "i18n keys missing from a locale:${_missing}"; false; }
}

# ════════════════════════════════════════════════════════════════════
# Whole-table locale parity
#
# The case above asks a narrower question than its neighbours assume, and
# its own header says so: it walks SCHEMA_I18N, which is the index from
# REGISTERED SCHEMA KEYS to TUI message keys. What decides which messages
# exist is _TUI_MSG_EN, and the two populations are nowhere near the same
# size -- measured on 1c9ccb2, SCHEMA_I18N has 47 rows of which 31 are
# non-empty, against _TUI_MSG_EN's 227 keys, so that case covers 14% of the
# table it reads as parity. Injecting `_TUI_MSG_EN[probe.only_english]` and
# touching no other table left this file at 11 ok / 0 not ok.
#
# A tree-wide grep for `_TUI_MSG` finds no whole-table parity guard
# anywhere: no lint driver, no workflow, no other spec. What exists beyond
# the 31 is hand-picked -- tui_flow_spec asserts three `main.*` keys across
# the four tables and deploy_word_collision_spec loops the `deploy.ambiguous.*`
# family -- which is this repo's recorded anti-pattern rather than coverage.
#
# So the population below is _TUI_MSG_EN itself, and the degradation it
# catches is silent by construction: `_tui_msg` falls back to
# `${_TUI_MSG_EN[$key]:-$key}`, so an operator running under ja or zh-CN
# gets an English message box and no warning at all.
# ════════════════════════════════════════════════════════════════════

# Keys that are English BY CONSTRUCTION, with the reason. Not a list of
# keys nobody got round to -- that is the recorded lag below, kept separate
# on purpose.
#
# `_warn_if_lang_rejected` runs only AFTER `_sanitize_lang` has already
# fallen back to en, so the message box that reports a rejected --lang
# value is rendered in English whatever was asked for: a translated
# `lang.invalid.*` is unreachable code, and shipping one would read as a
# promise the dispatch cannot keep.
#
# Each entry is floored twice below: it must be a real EN key, and it must
# be ABSENT from all three translated tables. So this list cannot be used
# to quiet a key that someone HAS translated -- the day one is, the opt-out
# fails and has to go.
_TUI_MSG_ENGLISH_ONLY=(
  lang.invalid.title
  lang.invalid.body
)

# The recorded lag: `<LOCALE>|<key>` pairs that have no translation yet.
#
# This is a DEFICIT, not an exemption. All four tables received these keys'
# English and zh-TW text in one commit and zh-CN and ja simply did not
# follow; zh-TW is complete. They are written down because the gate above
# them is now over the WHOLE table, and a gate that reported this lag would
# be red on arrival -- so the lag is named, with every entry held to being a
# real one, and ANY key that goes untranslated from here on fails.
#
# Each entry is floored three ways below: its key must be a real EN key, it
# must still be missing from that locale, and it must not also claim to be
# English-only. So the list cannot go stale in either direction -- closing
# one of these gaps without deleting its line fails, and so does listing a
# gap that does not exist.
_TUI_MSG_UNTRANSLATED=(
  "ZH_CN|err.invalid_capability"
  "ZH_CN|err.invalid_env_kv"
  "ZH_CN|err.invalid_network_name"
  "ZH_CN|err.invalid_port_mapping"
  "ZH_CN|err.invalid_shm_size"
  "JA|err.invalid_capability"
  "JA|err.invalid_env_kv"
  "JA|err.invalid_network_name"
  "JA|err.invalid_port_mapping"
  "JA|err.invalid_shm_size"
)

# why: The parity population is _TUI_MSG_EN, the table that DECIDES which
# messages exist, rather than the schema index which only knows the 31
# messages a registered key points at. An English-only key added to the EN
# table now fails here instead of reporting nothing
@test "every _TUI_MSG_EN key exists in all three translated tables (#591)" {
  _load_locale_tables

  local -n _t_en=_TUI_MSG_EN
  # Non-vacuity: a reader that loaded no table would find nothing missing
  # from nothing, which is the pass this case exists to refuse. The floor is
  # well under the live count and is a floor, not a transcription of it.
  [ "${#_t_en[@]}" -ge 150 ]     || fail "_TUI_MSG_EN holds ${#_t_en[@]} keys; the tables did not load, so every comparison below is between two empty sets"

  local _k _loc _pair _why=""

  # Floor on the English-only opt-outs: a real EN key, translated nowhere.
  for _k in "${_TUI_MSG_ENGLISH_ONLY[@]}"; do
    [[ -v "_t_en[${_k}]" ]]       || _why+="  ${_k} is opted out of translation but is not an EN key at all"$'\n'
    for _loc in ZH_TW ZH_CN JA; do
      local -n _t="_TUI_MSG_${_loc}"
      [[ -v "_t[${_k}]" ]]         && _why+="  ${_k} is opted out of translation and ${_loc} translates it: delete the opt-out"$'\n'
      unset -n _t
    done
  done

  # Floor on the recorded lag: a real EN key, really still missing, and not
  # also claiming to be English-only.
  for _pair in "${_TUI_MSG_UNTRANSLATED[@]}"; do
    _loc="${_pair%%|*}"
    _k="${_pair#*|}"
    [[ -v "_t_en[${_k}]" ]]       || _why+="  recorded lag ${_pair} names no EN key"$'\n'
    local -n _t="_TUI_MSG_${_loc}"
    [[ -v "_t[${_k}]" ]]       && _why+="  recorded lag ${_pair} is closed: ${_loc} has it now, so delete the line"$'\n'
    unset -n _t
    printf '%s\n' "${_TUI_MSG_ENGLISH_ONLY[@]}" | grep -qxF -- "${_k}"       && _why+="  ${_k} is both English-only and a recorded lag; it is one or the other"$'\n'
  done

  # The gate itself, over the derived population.
  local _missing=""
  for _k in "${!_t_en[@]}"; do
    printf '%s\n' "${_TUI_MSG_ENGLISH_ONLY[@]}" | grep -qxF -- "${_k}" && continue
    for _loc in ZH_TW ZH_CN JA; do
      local -n _t="_TUI_MSG_${_loc}"
      if [[ ! -v "_t[${_k}]" ]]; then
        printf '%s\n' "${_TUI_MSG_UNTRANSLATED[@]}" | grep -qxF -- "${_loc}|${_k}" \
          || _missing+="  ${_loc} has no ${_k}"$'\n'
      fi
      unset -n _t
    done
  done

  [[ -z "${_why}" && -z "${_missing}" ]] || fail "locale parity over _TUI_MSG_EN (${#_t_en[@]} keys):
${_why}${_missing}A key reached under ja or zh-CN with no row there renders in English and says nothing about it -- _tui_msg falls back to \${_TUI_MSG_EN[\$key]}. Either translate it, record it in _TUI_MSG_UNTRANSLATED with the locale, or declare it English-only with the reason."
}

# why: accessor the TUI routes through (#591)
@test "_schema_i18n_key resolves scalar + list keys, falls back when free-form (#591)" {
  # The accessor the TUI routes through. Scalar + numbered-list keys resolve
  # to their indexed message key; a free-form key (no registry row) returns
  # the supplied fallback so callers keep their literal default.
  run _schema_i18n_key resources shm_size
  assert_success
  assert_output "resources.shm_size.prompt"

  # Numbered list suffix normalises to the registered prefix.
  run _schema_i18n_key network port_3
  assert_success
  assert_output "ports.entry.prompt"

  # Per-service logging section folds onto the [logging] key set.
  run _schema_i18n_key logging.devel driver
  assert_success
  assert_output "logging.driver.prompt"

  # Free-form (unregistered) key -> fallback echoed verbatim.
  run _schema_i18n_key tmpfs tmpfs_1 tmpfs.entry.prompt
  assert_success
  assert_output "tmpfs.entry.prompt"

  # No-editor opt-out ("" index value) -> fallback, not the empty string.
  run _schema_i18n_key logging wrapper_transcript fallback.key
  assert_success
  assert_output "fallback.key"
}

# ════════════════════════════════════════════════════════════════════
# Template / registry completeness
#
# Registering the five missing validators one by one is a fix for
# today's gap and nothing more -- the next key added to the template
# reopens it, which is exactly how gui.mode / deploy.gpu_mode /
# gpu_capabilities / dri_groups / security_opt_ got in. This guard makes
# an unregistered template key structurally impossible: every key the
# shipped setup.conf ships (live or as a commented example) must resolve
# to a SCHEMA_VALIDATOR entry, or be listed in SCHEMA_FREEFORM with a
# written reason.
# ════════════════════════════════════════════════════════════════════

# Emit "<section> <key>" for every key the shipped template declares:
# live `key = value` lines plus commented `# key = value` examples, which
# are documented knobs users uncomment.
_template_keys() {
  local _tpl="/source/dist/.setup.conf"
  local _section="" _line _key
  while IFS= read -r _line; do
    if [[ "${_line}" =~ ^\[([a-z_]+)\]$ ]]; then
      _section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ -n "${_section}" ]] || continue
    # Strict shape only: `key = value` / `key =`, optionally behind a
    # single leading `# `. Prose comments never match.
    [[ "${_line}" =~ ^#?[[:space:]]*([a-z][a-z0-9_]*)[[:space:]]*= ]] || continue
    _key="${BASH_REMATCH[1]}"
    printf '%s %s\n' "${_section}" "${_key}"
  done < "${_tpl}"
}

# Opt-out lookup that tolerates the map not existing at all, so a
# missing SCHEMA_FREEFORM surfaces as "this key has no opt-out" rather
# than a bash arithmetic-subscript error.
_is_freeform() {
  declare -p SCHEMA_FREEFORM >/dev/null 2>&1 || return 1
  [[ -v "SCHEMA_FREEFORM[${1}]" ]]
}

@test "every shipped setup.conf key is registered or an explicit free-form opt-out (#876)" {
  local _section _key _canon _pfx _missing=""
  while read -r _section _key; do
    _schema_canonical_key "${_section}" "${_key}" _canon
    [[ -n "${_canon}" ]] && continue
    _is_freeform "${_section}.${_key}" && continue
    if [[ "${_key}" =~ ^(.+_)[0-9]+$ ]]; then
      _pfx="${BASH_REMATCH[1]}"
      _is_freeform "${_section}.${_pfx}" && continue
    fi
    _missing+=" ${_section}.${_key}"
  done < <(_template_keys)
  [ -z "${_missing}" ] || {
    echo "template keys with no validator and no SCHEMA_FREEFORM opt-out:${_missing}"
    false
  }
}

@test "every SCHEMA_FREEFORM entry carries a written reason (#876)" {
  local _k _blank=""
  for _k in "${!SCHEMA_FREEFORM[@]}"; do
    [[ -n "${SCHEMA_FREEFORM[${_k}]}" ]] || _blank+=" ${_k}"
  done
  [ -z "${_blank}" ] || { echo "opt-outs with an empty reason:${_blank}"; false; }
}

@test "no key is both SCHEMA_VALIDATOR-registered and SCHEMA_FREEFORM-opted-out (#876)" {
  local _k _both=""
  for _k in "${!SCHEMA_FREEFORM[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] && _both+=" ${_k}"
  done
  [ -z "${_both}" ] || { echo "registered AND opted out:${_both}"; false; }
}
