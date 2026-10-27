#!/usr/bin/env bats
#
# why: Mirrors `lib/setup_conf.sh`. setup.toml merging (`_load_setup_conf`
# over the one effective configuration -- tables key-level and recursive,
# arrays atomic, ADR-00000037) resolving the per-repo override from the repo-root
# `setup.toml` dotfile (a legacy `config/docker/setup.conf` is no longer
# read), `_get_conf_value` / `_get_conf_list_sorted` (incl. empty-skip), and
# the `_rule_basename` image-rule helper. Also guards the shipped `dist/`
# prose against pre-relocation path names: the four `setup_tui.sh` usage
# heredocs must advertise `setup.toml`, and no shipped text may still say
# `<repo>/setup.conf` or `.base/setup.conf` (#842).

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# _setup_conf_layers -- the chain every reader derives its population from
#
# The chain is three files, and it is defined HERE so no caller ever
# re-lists it. Its lowest layer is located from _SETUP_SCRIPT_DIR, which
# only setup.sh sets: a caller that reaches the readers without setup.sh
# (init.sh / upgrade.sh, and the Dockerfile-migration list they source)
# would otherwise be handed a silently truncated chain and would scan two
# of the three layers. The optional third argument is how such a caller
# names the template's dist/ dir instead -- the MEMBERSHIP and ORDER of
# the chain stay in this one function either way.
# ════════════════════════════════════════════════════════════════════
@test "_setup_conf_layers: an explicit dist dir places the template layer (#956)" {
  local -a _l=()
  _setup_conf_layers "${TEMP_DIR}" _l "${TEMP_DIR}/.base/dist"
  assert_equal "${#_l[@]}" "3"
  assert_equal "${_l[0]}" "${TEMP_DIR}/.base/dist/setup.toml"
  assert_equal "${_l[1]}" "${TEMP_DIR}/setup.toml"
  assert_equal "${_l[2]}" "${TEMP_DIR}/setup.local.toml"
}

@test "_setup_conf_layers: _SETUP_SCRIPT_DIR still places the template layer when no dist dir is given (#956)" {
  local -a _l=()
  _setup_conf_layers "${TEMP_DIR}" _l
  assert_equal "${#_l[@]}" "3"
  # setup_spec_helper sources wrapper/setup.sh, so _SETUP_SCRIPT_DIR is
  # the shipped wrapper dir and the template layer is dist/setup.toml.
  [[ "${_l[0]}" == */setup.toml ]]
  [[ "${_l[0]}" != "${_l[1]}" ]]
  assert_equal "${_l[1]}" "${TEMP_DIR}/setup.toml"
}

@test "_setup_conf_layers: no _SETUP_SCRIPT_DIR and no dist dir omits the template layer (#956)" {
  # The documented degenerate case. It is a truncated chain, and every
  # caller that cannot tolerate one has to notice: the count is the only
  # signal available, so it is pinned here.
  local -a _l=()
  local _SETUP_SCRIPT_DIR=""
  _setup_conf_layers "${TEMP_DIR}" _l
  assert_equal "${#_l[@]}" "2"
  assert_equal "${_l[0]}" "${TEMP_DIR}/setup.toml"
}

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf (per-repo replace / template fallback)
# ════════════════════════════════════════════════════════════════════
@test "_load_setup_conf returns every entry of the per-repo section" {
  # Was the SETUP_CONF fixture seam; the conf surface is the fixed pair of
  # real files, so the fixture is a real file at the path the resolver reads.
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "off"
count = "0"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_v[0]}" "off"
}

# ════════════════════════════════════════════════════════════════════
# An ambient SETUP_CONF must not steer config resolution
#
# SETUP_CONF was a test seam that replaced the WHOLE resolution with one
# unchecked path. The two assertions below are the two ways that bites a
# user: a stale value silently swaps the config out from under the repo,
# and a path that does not exist silently resolves to an EMPTY config --
# a silent failure, which invariant 2 forbids.
# ════════════════════════════════════════════════════════════════════
@test "_load_setup_conf ignores an ambient SETUP_CONF pointing at another file" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  cat > "${TEMP_DIR}/elsewhere.toml" <<'EOF'
[gui]
mode = "off"
EOF
  local -a _k=() _v=()
  SETUP_CONF="${TEMP_DIR}/elsewhere.toml" _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf does not resolve to an empty config when an ambient SETUP_CONF path is absent" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  local -a _k=() _v=()
  SETUP_CONF="${TEMP_DIR}/typo-nowhere.toml" _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_v[0]}" "force"
}

@test "_setup_conf_handle ignores an ambient SETUP_CONF" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  cat > "${TEMP_DIR}/elsewhere.toml" <<'EOF'
[gui]
mode = "off"
EOF
  SETUP_CONF="${TEMP_DIR}/elsewhere.toml" _setup_conf_handle "${TEMP_DIR}" _SCH
  run _conf_get _SCH gui mode
  assert_success
  assert_output "force"
}

@test "_compute_conf_hash ignores an ambient SETUP_CONF" {
  # The hash names the config that was actually resolved. Folding a file
  # resolution never read into it makes the drift signal describe something
  # else entirely.
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  cat > "${TEMP_DIR}/elsewhere.toml" <<'EOF'
[gui]
mode = "off"
EOF
  local _plain="" _ambient=""
  _compute_conf_hash "${TEMP_DIR}" _plain
  SETUP_CONF="${TEMP_DIR}/elsewhere.toml" _compute_conf_hash "${TEMP_DIR}" _ambient
  assert_equal "${_ambient}" "${_plain}"
}

# why: The repo-root setup.toml is the committed override layer; loading from the wrong path silently falls back to the template.
@test "_load_setup_conf reads the per-repo override from repo-root setup.toml" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "force"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

# why: ADR-00000037 settles the chain's rule for tables as key-level
# merge, unqualified, and amends the blanket section-replace it replaced.
# _load_setup_conf kept its own walk -- highest layer that defines the
# section supplies all of it -- while _setup_conf_handle went through the
# bridge merge and was key-level. `show` read one and the emitters read
# the other, so a repo could be told one configuration and built with
# another. One effective configuration, queried by both.
@test "_load_setup_conf merges a section key by key across the layers (ADR-00000037)" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[logging]
driver = "local"
max_size = "20m"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[logging]
driver = "journald"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "logging" _k _v
  local _got=""
  _get_conf_value _k _v driver "" _got
  assert_equal "${_got}" "journald"
  # The key the local layer says nothing about is inherited, not dropped.
  _get_conf_value _k _v max_size "" _got
  assert_equal "${_got}" "20m"
}

# why: the two readers must not be able to disagree. This asserts the
# agreement itself rather than one reader's answer, so a future change to
# either path that reintroduces a second precedence rule fails here --
# which is the failure mode the split had, undetected, until `show` and
# the emitters were compared by hand.
@test "_load_setup_conf answers what the merged handle answers (ADR-00000037)" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[network]
mode = "bridge"
ipc = "private"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[network]
mode = "host"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "network" _k _v
  _setup_conf_handle "${TEMP_DIR}" _AGREE
  local _key _via_section="" _via_handle=""
  for _key in mode ipc pid; do
    _get_conf_value _k _v "${_key}" "<absent>" _via_section
    _conf_get_into _AGREE network "${_key}" "<absent>" _via_handle
    assert_equal "${_via_section}" "${_via_handle}"
  done
  # And the value itself is the local layer's, so the case is not vacuous.
  _get_conf_value _k _v mode "" _via_section
  assert_equal "${_via_section}" "host"
}

@test "_load_setup_conf ignores a legacy config/docker/setup.conf override" {
  # After the relocation the old nested path is dead: an override left
  # there must NOT win over the template default.
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = legacy_should_be_ignored
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  # Template default [gui] mode = auto -- proves the legacy file is unread.
  assert_equal "${_v[0]}" "auto"
}

# ════════════════════════════════════════════════════════════════════
# Post-relocation path names in user-facing help / comments
# ════════════════════════════════════════════════════════════════════
@test "setup_tui.sh usage names the repo-root setup.toml in every language (#842)" {
  # Help that names a path the user cannot find is worse than no help:
  # all four heredocs must advertise the file the TUI actually edits.
  #
  # That file is `<repo>/setup.toml`. It was `.setup.conf` for the length
  # of ADR-00000037's freeze -- the editor's file, its writers and its
  # help were all still the INI pair, and a blanket rename of this
  # assertion once ran ahead of the ADR and made the spec describe an
  # interface the frozen wrapper did not have. base#1232 carried the
  # editor over, so the help and the save target move together here.
  #
  # Driving usage() means SOURCING the wrapper. That used to be
  # kcov-only-fatal and carried a COVERAGE skip here: the wrapper enabled
  # `set -euo pipefail` unconditionally, so the strict mode outlived the
  # source and the NEXT top-level command in this `bash -c` died inside
  # kcov's own PS4 (which expands an array that is empty at that level).
  # The wrapper now gates its strict mode on being executed directly, like
  # every sibling, so the skip is gone and this assertion runs in the
  # coverage shard too -- sourceable_scripts_spec.bats holds that property.
  local _lang
  for _lang in zh-TW zh-CN ja en; do
    run bash -c "
      # shellcheck disable=SC1091
      source /source/dist/script/docker/wrapper/setup_tui.sh
      _LANG='${_lang}' usage
    "
    assert_success
    assert_output --partial "<repo>/setup.toml"
    refute_output --partial "<repo>/.setup.conf"
    refute_output --partial "<repo>/setup.conf"
  done
}

@test "setup.sh usage describes the TOML-era apply, not the INI era, in every language (base#1326)" {
  # Three claims in setup.sh --help outlived the behaviour they described:
  #   - a bare `setup.sh` prints usage (main(), B-4), it does not fall
  #     back to apply;
  #   - the SETUP_* drift metadata is written to .env.generated (the file
  #     check-drift reads), not to .env;
  #   - the per-repo layer merges tables key by key and replaces arrays
  #     whole (the --local-conf text, ADR-00000037), not section-replace.
  local _lang
  for _lang in zh-TW zh-CN ja en; do
    run bash -c "
      # shellcheck disable=SC1091
      source /source/dist/script/docker/wrapper/setup.sh
      _LANG='${_lang}' usage
    "
    assert_success
    refute_output --partial "falls back to apply"
    refute_output --regexp '<output>/\.env +[^[:space:]].*SETUP_\*'
    refute_output --partial "section-replace"
    # The corrected statements themselves, not only the absence of the
    # old ones: deleting the Outputs block and the source-of-truth
    # paragraph would pass every refute above.
    assert_output --regexp '<output>/\.env\.generated +[^[:space:]].*SETUP_\* drift metadata'
    assert_output --partial "under the optional setup.local.toml: tables merge key by key and arrays"
    assert_output --partial "are replaced whole. Edit setup.toml, not the derived files."
    # `set --local` describes the same layer: it overrides the keys it
    # names (a measured merge keeps a committed key the local table does
    # not name), so it does not REPLACE the committed section.
    refute_output --partial "REPLACE the committed"
    assert_output --partial "its tables override only the keys they name"
    refute_output --partial "it will not
                change anything here"
  done
}

# why: setup.toml holds the workspace bind as the first `[[volumes]]`
# entry (source/target), not an INI `[volumes] mount_1` key; help that
# names the INI key sends the operator looking for a line the file never
# holds.
@test "setup.sh usage names the workspace bind as a setup.toml [[volumes]] entry, not [volumes] mount_1 (base#1373)" {
  local _lang _flat
  for _lang in zh-TW zh-CN ja en; do
    run bash -c "
      # shellcheck disable=SC1091
      source /source/dist/script/docker/wrapper/setup.sh
      _LANG='${_lang}' usage
    "
    assert_success
    # Newlines and indentation folded to single spaces, so a statement
    # wrapped across help lines is matched whole.
    _flat="$(printf '%s' "${output}" | tr -s ' \n' '  ')"
    [[ "${_flat}" != *'[volumes] mount_1'* ]]
    [[ "${_flat}" == *'or a stale absolute source in the first `[[volumes]]` entry) is refused instead'* ]]
  done
  # The file header describes the same write-back in the same terms.
  run grep -n 'mount_1' /source/dist/script/docker/wrapper/setup.sh
  assert_failure
}

@test "no shipped dist/ text still points at the pre-relocation <repo>/setup.conf (#842)" {
  run grep -rn 'repo>/setup\.conf' /source/dist
  assert_failure
}

@test "no shipped dist/ text names the non-existent .base/setup.conf default (#842)" {
  # The template baseline resolves to .base/dist/setup.toml; the old
  # shorthand points at a path that never existed post-relocation.
  run grep -rn '\.base/setup\.conf' /source/dist
  assert_failure
}

@test "_load_setup_conf falls back to template when section absent per-repo" {
  # Per-repo setup.toml has [gpu] but NOT [gui]
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "force"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  # Template default has [gui] mode = auto
  assert_equal "${_v[0]}" "auto"
}

# why: the template is the chain's lowest layer, and ADR-00000037's
# key-level table merge applies to it too: a repo that moves one key of a
# template table inherits the template's other keys rather than blanking
# them. The template is a fixture so the inherited keys are this test's own
# and not whatever dist/setup.toml happens to ship. Under a section-replace
# merge only `mode` would come back, and the two inherited asserts fail.
@test "_load_setup_conf merges a per-repo table key by key over the template's (ADR-00000037)" {
  mkdir -p "${TEMP_DIR}/tpl/script/docker/wrapper"
  cat > "${TEMP_DIR}/tpl/setup.toml" <<'EOF'
[gpu]
mode = "auto"
count = "all"
capabilities = "gpu compute"
EOF
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "off"
EOF
  local _SETUP_SCRIPT_DIR="${TEMP_DIR}/tpl/script/docker/wrapper"
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  local _got=""
  _get_conf_value _k _v mode "<absent>" _got
  assert_equal "${_got}" "off"
  _get_conf_value _k _v count "<absent>" _got
  assert_equal "${_got}" "all"
  _get_conf_value _k _v capabilities "<absent>" _got
  assert_equal "${_got}" "gpu compute"
}

# ════════════════════════════════════════════════════════════════════
# setup.local.toml -- the gitignored per-worktree layer
#
# Third layer of the same chain, with the same section-replace rule:
# template <- <repo>/setup.toml <- <repo>/setup.local.toml. It may
# override ANY section, because per-key merge over the eight `<prefix>_N`
# ordered-list sections is not merely inconsistent but broken (an item
# cannot be removed, and adding one needs the highest N of a layer the
# user cannot see).
# ════════════════════════════════════════════════════════════════════
# why: The local layer is the operator's per-worktree override; if it does not win, every worktree shares one config.
@test "_load_setup_conf: setup.local.toml overrides the per-repo section" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${_v[0]}" "off"
}

# why: A repo that skips a section still needs local override to reach through to the template default.
@test "_load_setup_conf: setup.local.toml overrides the template for a section the repo omits" {
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${_v[0]}" "off"
}

# why: the two halves of ADR-00000037's merge rule, in one section, at the
# reader the emitters go through. A table merges key by key, so a local
# layer that moves `mode` leaves `ipc` to the layer below instead of
# blanking it. An array is replaced ATOMICALLY, so the local layer's one
# port is the whole list: assembling one ordered list out of two layers
# would leave no way to remove an entry and would ask the author of the
# upper layer to know the highest index in a layer they cannot see.
@test "_load_setup_conf: a table merges key by key, an array is replaced whole" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[network]
mode = "bridge"
ipc = "private"

[[network.ports]]
host = 8080
container = 80

[[network.ports]]
host = 9090
container = 90
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[network]
mode = "host"

[[network.ports]]
host = 18080
container = 80
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "network" _k _v
  local _got=""
  # Table: the key the local layer names is its value...
  _get_conf_value _k _v mode "<absent>" _got
  assert_equal "${_got}" "host"
  # ...and the one it does not name is inherited, not blanked.
  _get_conf_value _k _v ipc "<absent>" _got
  assert_equal "${_got}" "private"
  # Array: the local layer's list, whole. port_2 does not leak back in
  # from the layer underneath to make one list out of two.
  _get_conf_value _k _v port_1 "<absent>" _got
  assert_equal "${_got}" "18080:80"
  _get_conf_value _k _v port_2 "<absent>" _got
  assert_equal "${_got}" "<absent>"
}

# why: A local layer that mentions one section must not blank out every other section in the resolved config.
@test "_load_setup_conf: sections setup.local.toml omits keep the layer below" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "force"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

# why: _setup_conf_handle is the single entry point the wrappers use; if its layering disagrees with _load_setup_conf, every wrapper reads stale config.
@test "_setup_conf_handle: setup.local.toml wins over the per-repo layer" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"
EOF
  _setup_conf_handle "${TEMP_DIR}" _LOCAL_H
  run _conf_get _LOCAL_H gui mode
  assert_success
  assert_output "off"
}

# why: A local-layer edit that leaves the hash unchanged means the wrapper reuses artifacts built from a different config.
@test "_compute_conf_hash: editing setup.local.toml is drift" {
  # The hash must describe the config that was actually resolved -- a
  # layer that changes the resolved value and leaves the hash alone means
  # the wrapper reuses artifacts generated from something else.
  local _before="" _after=""
  _compute_conf_hash "${TEMP_DIR}" _before
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"
EOF
  _compute_conf_hash "${TEMP_DIR}" _after
  [[ "${_before}" != "${_after}" ]] || { echo "hash unchanged: ${_before}"; return 1; }
}

@test "_setup_effective_full: show/list read the local layer too" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gui]
mode = "force"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"
EOF
  local -a _s=() _k=() _v=()
  _setup_effective_full "${TEMP_DIR}" _s _k _v
  local _i _seen=""
  for (( _i = 0; _i < ${#_k[@]}; _i++ )); do
    [[ "${_k[_i]}" == "gui.mode" ]] && _seen="${_v[_i]}"
  done
  assert_equal "${_seen}" "off"
}

# why: the template layer's directory comes from _SETUP_SCRIPT_DIR, and a
# caller that reaches the readers WITHOUT setup.sh has none -- setup_tui.sh
# is one, a sibling of setup.sh in the same wrapper dir that resolves the
# directory itself. _setup_conf_layers already took the argument; the
# handle and the *_full view did not, so such a caller could only get the
# whole chain by assembling a layer list of its own, which is precisely how
# the editor and the emitters came to disagree about what is configured
# (base#1232). Measured on a template-ONLY key, because that is the key a
# dropped template layer loses and every other assertion would still pass
# without it.
@test "_setup_conf_handle: a caller with no _SETUP_SCRIPT_DIR can pass the template dir" {
  local _tpl="${TEMP_DIR}/dist"
  mkdir -p "${_tpl}"
  cat > "${_tpl}/setup.toml" <<'EOF'
[gui]
mode = "auto"

[network]
mode = "host"
EOF
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[network]
mode = "bridge"
EOF
  local _saved="${_SETUP_SCRIPT_DIR:-}"
  _SETUP_SCRIPT_DIR=""
  _setup_conf_handle "${TEMP_DIR}" _TD "${_tpl}"
  assert_equal "$(_conf_get _TD gui mode "")" "auto"
  assert_equal "$(_conf_get _TD network mode "")" "bridge"
  # And the *_full reshaping of the same handle takes it too.
  local -a _s=() _k=() _v=()
  _setup_effective_full "${TEMP_DIR}" _s _k _v "${_tpl}"
  local _i _seen=""
  for (( _i = 0; _i < ${#_k[@]}; _i++ )); do
    [[ "${_k[_i]}" == "gui.mode" ]] && _seen="${_v[_i]}"
  done
  assert_equal "${_seen}" "auto"
  _SETUP_SCRIPT_DIR="${_saved}"
}

@test "_setup_conf_local_sections: names the sections the local layer shadows" {
  # Nothing may be silently shadowed: the callers that warn / announce need
  # the section list, not just a boolean.
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gui]
mode = "off"

[network]
mode = "bridge"
EOF
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "2"
  assert_equal "${_sects[0]}" "gui"
  assert_equal "${_sects[1]}" "network"
}

# why: An array declared with NO entries is a declaration, and the entries
# alone cannot see it. `args = []` replaces the lower layer's list with
# nothing (ADR-00000037's zero-entry amendment), so this file DOES change
# the effective configuration -- the template's three build args resolve
# to zero through the real merge -- while the bridge emits no `--kv` row
# for it. Read off the entries alone the answer was "no local sections",
# and the caller whose answer is a REFUSAL let it through: `_setup_deploy`
# bars a field bundle from depending on the gitignored local layer, so a
# bundle built from this clear came from untracked configuration with
# nothing in its README naming the section.
@test "_setup_conf_local_sections: an array declared with no entries is a section the local layer defines" {
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[build]
args = []
EOF
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "1"
  assert_equal "${_sects[0]}" "build"
}

# why: The two spellings the first case does not reach. A family whose
# path has no dot is declared at the ROOT -- TOML gives a root-level key
# one home, the region before the first table header -- so there is no
# `[volumes]` header for the tokenizer to list the section under, and the
# answer cannot come from the section list at all. And an operator who
# clears a list is exactly the one who writes down why, so the annotated
# spelling has to count too: `_conf_toml_empty_array_decl` already
# matches it for the writers, and reading the bare two characters instead
# was a defect there once.
@test "_setup_conf_local_sections: a root-level and an annotated empty array both count" {
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
volumes = []

[security]
cap_add = [ ]  # deliberately dropped every added capability
EOF
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "2"
  run printf '%s\n' "${_sects[@]}"
  assert_line 'volumes'
  assert_line 'security'
}

# why: The control. A section whose only contribution is an ordinary
# array ENTRY was already counted and must stay counted, and a comment
# that merely mentions an array is not a declaration -- a rule that read
# any `[]` in the file would name a section the layer does not define,
# which is the opposite failure and the one that would make the deploy
# refusal fire on a file that changes nothing.
@test "_setup_conf_local_sections: an entry still counts and a commented declaration does not" {
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[[volumes]]
source = "/srv"
target = "/srv"

[build]
# args = [] would clear them; not doing that here
EOF
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "1"
  assert_equal "${_sects[0]}" "volumes"
}

@test "_setup_conf_local_sections: empty when no local layer is present" {
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "0"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_value / _get_conf_list_sorted
# ════════════════════════════════════════════════════════════════════
@test "_get_conf_value returns value for present key" {
  local -a _k=("mode" "count") _v=("auto" "all")
  local _out
  _get_conf_value _k _v "mode" "DEFAULT" _out
  assert_equal "${_out}" "auto"
}

@test "_get_conf_value returns default for absent key" {
  local -a _k=("mode") _v=("auto")
  local _out
  _get_conf_value _k _v "missing" "DEFAULT" _out
  assert_equal "${_out}" "DEFAULT"
}

@test "_get_conf_list_sorted returns values sorted by numeric suffix" {
  local -a _k=("mount_3" "mount_1" "mount_10" "mount_2")
  local -a _v=("/three:/three" "/one:/one" "/ten:/ten" "/two:/two")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "4"
  assert_equal "${_out[0]}" "/one:/one"
  assert_equal "${_out[1]}" "/two:/two"
  assert_equal "${_out[2]}" "/three:/three"
  assert_equal "${_out[3]}" "/ten:/ten"
}

@test "_get_conf_list_sorted skips non-matching keys" {
  local -a _k=("mount_1" "mode" "mount_2")
  local -a _v=("/a:/a" "auto" "/b:/b")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "2"
  assert_equal "${_out[0]}" "/a:/a"
  assert_equal "${_out[1]}" "/b:/b"
}

# ════════════════════════════════════════════════════════════════════
# _rule_basename
# ════════════════════════════════════════════════════════════════════
@test "_rule_basename returns last non-empty path component" {
  result="$(_rule_basename "/home/user/my_project")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename skips trailing slashes" {
  result="$(_rule_basename "/home/user/my_project/")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename handles single-component path" {
  result="$(_rule_basename "justname")"
  assert_equal "${result}" "justname"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_list_sorted skips empty values
# ════════════════════════════════════════════════════════════════════
@test "_get_conf_list_sorted skips entries with empty value" {
  local -a _k=("mount_1" "mount_2" "mount_3") _v=("" "/b:/b" "")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "1"
  assert_equal "${_out[0]}" "/b:/b"
}

# ════════════════════════════════════════════════════════════════════
# The chain's top layer takes a caller-supplied address (ADR-00000036)
#
# base's two generate stages are APIs an orchestrator calls N times
# against ONE repo. The third layer is already the one that overrides any
# section (ADR-00000025 sec.1); what it lacked was an address, so two
# concurrent parameter sets meant two checkouts. `_setup_conf_local_path`
# is the ONE spelling of that path, so pointing it elsewhere moves the
# layer for every reader and writer at once rather than for the one that
# was remembered -- which is why the assertions below go through the real
# merge and the real drift hash, not through the chain array alone.
# ════════════════════════════════════════════════════════════════════

# why: The chain's top layer is assembled in _setup_conf_layers, and it
# spelled `<base>/setup.local.toml` inline rather than asking
# _setup_conf_local_path. A second spelling of one path is how an override
# reaches some readers and not others, so the membership assertion here is
# that the chain's last element IS whatever that resolver answers.
@test "_setup_conf_layers: the top layer is whatever _setup_conf_local_path resolves (base#1087)" {
  local -a _l=()
  printf '[gpu]\nmode = "force"\n' > "${TEMP_DIR}/caller-a.toml"
  local _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-a.toml"
  _setup_conf_layers "${TEMP_DIR}" _l "${TEMP_DIR}/.base/dist"
  assert_equal "${#_l[@]}" "3"
  assert_equal "${_l[1]}" "${TEMP_DIR}/setup.toml"
  assert_equal "${_l[2]}" "${TEMP_DIR}/caller-a.toml"
  # The default path is GONE from the chain, not merely outranked: an
  # orchestrator's call must not pick up the operator's own worktree file.
  local _e
  for _e in "${_l[@]}"; do
    [[ "${_e}" != "${TEMP_DIR}/setup.local.toml" ]] || \
      fail "the default local layer is still in the chain: ${_e}"
  done
}

# why: An address nothing reads is not an address. Asserted through the
# real merge (_setup_conf_handle + _conf_get, the accessors every emitter
# resolves through) rather than through the path list, so a chain that
# names the caller's file but merges the repo's would fail here.
@test "_setup_conf_handle merges the caller-supplied local layer, not the default one (base#1087)" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "off"
EOF
  cat > "${TEMP_DIR}/setup.local.toml" <<'EOF'
[gpu]
mode = "auto"
EOF
  cat > "${TEMP_DIR}/caller-a.toml" <<'EOF'
[gpu]
mode = "force"
EOF
  local _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-a.toml"
  _setup_conf_handle "${TEMP_DIR}" _H "${TEMP_DIR}/.base/dist"
  local _got=""
  _conf_get_into _H gpu mode "" _got
  assert_equal "${_got}" "force"
}

# why: Two calls against one repo must be able to hold two parameter sets
# at once. Observed as two different merge results from two different
# caller files with the repo untouched between them -- the acceptance
# criterion base#1087 states, at the resolver.
@test "two caller-supplied local layers resolve to two configurations over one repo (base#1087)" {
  cat > "${TEMP_DIR}/setup.toml" <<'EOF'
[gpu]
mode = "off"
EOF
  printf '[gpu]\nmode = "force"\n' > "${TEMP_DIR}/caller-a.toml"
  printf '[gpu]\nmode = "auto"\n'  > "${TEMP_DIR}/caller-b.toml"
  local _a="" _b=""
  ( _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-a.toml"
    _setup_conf_handle "${TEMP_DIR}" _HA "${TEMP_DIR}/.base/dist"
    _conf_get_into _HA gpu mode "" _a; printf '%s\n' "${_a}" ) > "${TEMP_DIR}/a.out"
  ( _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-b.toml"
    _setup_conf_handle "${TEMP_DIR}" _HB "${TEMP_DIR}/.base/dist"
    _conf_get_into _HB gpu mode "" _b; printf '%s\n' "${_b}" ) > "${TEMP_DIR}/b.out"
  assert_equal "$(cat "${TEMP_DIR}/a.out")" "force"
  assert_equal "$(cat "${TEMP_DIR}/b.out")" "auto"
  # The repo's own files are what two concurrent calls must not fight
  # over, so assert they still say what they said.
  run cat "${TEMP_DIR}/setup.toml"
  assert_output --partial 'mode = "off"'
  assert [ ! -f "${TEMP_DIR}/setup.local.toml" ]
}

# why: _setup_conf_local_sections is the answer a REFUSAL is built on
# (_setup_deploy bars a field bundle whose values came from the gitignored
# layer) and the one the config summary names. Read off the default path
# while the chain merged a caller's file, it would clear a bundle built
# from configuration nobody can reproduce.
@test "_setup_conf_local_sections reports the caller-supplied layer's sections (base#1087)" {
  printf '[gpu]\nmode = "force"\n' > "${TEMP_DIR}/setup.local.toml"
  printf '[network]\nmode = "bridge"\n' > "${TEMP_DIR}/caller-a.toml"
  local _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-a.toml"
  local -a _s=()
  _setup_conf_local_sections "${TEMP_DIR}" _s
  assert_equal "${#_s[@]}" "1"
  assert_equal "${_s[0]}" "network"
}

# why: Conf drift decides whether build.sh / run.sh reuse the artifacts of
# a previous generation. A layer that steers resolution but sits outside
# the hash lets a call reuse another call's compose.yaml, so the override
# has to reach _compute_conf_hash too -- which it does by construction
# only while that function derives its population from _setup_conf_layers.
@test "_compute_conf_hash follows the caller-supplied local layer (base#1087)" {
  printf '[gpu]\nmode = "off"\n' > "${TEMP_DIR}/setup.toml"
  printf '[gpu]\nmode = "force"\n' > "${TEMP_DIR}/caller-a.toml"
  printf '[gpu]\nmode = "auto"\n'  > "${TEMP_DIR}/caller-b.toml"
  local _ha="" _hb=""
  _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-a.toml" _compute_conf_hash "${TEMP_DIR}" _ha
  _SETUP_CONF_LOCAL="${TEMP_DIR}/caller-b.toml" _compute_conf_hash "${TEMP_DIR}" _hb
  [[ -n "${_ha}" ]] || fail "no hash computed for caller A"
  [[ "${_ha}" != "${_hb}" ]] || \
    fail "two caller-supplied layers hashed identically: ${_ha}"
}

# why: A parameterised API handed something it cannot honour must refuse.
# An override naming a file that is not there would otherwise resolve to
# an absent layer -- which the chain treats as "contributes nothing" -- and
# the call would silently emit the template defaults while reporting
# success. base#1092 / #1097 / #1119 / #1120 / #1223 are the same class.
@test "_setup_conf_local_check refuses an override that names no file (base#1087)" {
  LOG_FORMAT=json run --separate-stderr _setup_conf_local_check "${TEMP_DIR}/not-there.toml"
  assert_refusal 1 conf_local_override_unusable "path=${TEMP_DIR}/not-there.toml"
}

# why: A directory at the override path is the other way the layer cannot
# be read, and it is not caught by an existence test alone.
@test "_setup_conf_local_check refuses an override that is not a regular file (base#1087)" {
  mkdir -p "${TEMP_DIR}/a-dir.toml"
  LOG_FORMAT=json run --separate-stderr _setup_conf_local_check "${TEMP_DIR}/a-dir.toml"
  assert_refusal 1 conf_local_override_unusable "path=${TEMP_DIR}/a-dir.toml"
}

# why: An unreadable file is the third way the layer cannot be honoured,
# and the only one an existence or a regular-file test lets through
# (base#1399). Root reads a mode-000 file anyway, so as root the check
# runs as `nobody`. `nobody` has to reach the file, but the only
# directory this test may widen is TEMP_DIR, which its setup created:
# the ones above it belong to the host, and widening them as root would
# outlive the fixture (base#1399 review round 1). So TEMP_DIR alone gets
# o+x, and the case is skipped -- saying why -- when no unprivileged user
# can be reached or when TEMP_DIR's parent does not let `nobody` through.
@test "_setup_conf_local_check refuses an override it cannot read (base#1399)" {
  local _f="${TEMP_DIR}/unreadable.toml"
  printf '[gpu]\nmode = "force"\n' > "${_f}"
  chmod 000 "${_f}"
  local _probe="source /source/dist/script/docker/wrapper/setup.sh
    LOG_FORMAT=json _setup_conf_local_check '${_f}'"
  if [[ "$(id -u)" -eq 0 ]]; then
    su -s /bin/bash nobody -c true 2>/dev/null \
      || skip "running as root and cannot drop to nobody, so no unreadable file can be staged"
    chmod o+x "${TEMP_DIR}"
    su -s /bin/bash nobody -c "test -e '${_f}'" 2>/dev/null \
      || skip "nobody cannot traverse to ${TEMP_DIR} without widening a directory this test did not create"
    run --separate-stderr su -s /bin/bash nobody -c "${_probe}"
  else
    run --separate-stderr bash -c "${_probe}"
  fi
  assert_refusal 1 conf_local_override_unusable "path=${_f}" "not readable"
}

# why: The check has to pass the honourable case, or the refusal above
# would be satisfied by a function that refuses everything.
@test "_setup_conf_local_check accepts a readable regular file (base#1087)" {
  printf '[gpu]\nmode = "force"\n' > "${TEMP_DIR}/caller-a.toml"
  run _setup_conf_local_check "${TEMP_DIR}/caller-a.toml"
  assert_success
}

# why: With no override set, the chain is exactly what it was. The
# per-worktree default is the case every existing checkout is in, so it is
# pinned beside the override rather than left to the tests above.
@test "_setup_conf_local_path falls back to the per-worktree default (base#1087)" {
  local _SETUP_CONF_LOCAL=""
  assert_equal "$(_setup_conf_local_path "${TEMP_DIR}")" "${TEMP_DIR}/setup.local.toml"
}

# why: The chain's shipped header said there is no env var that relocates
# it, because such a lever "is a second, unchecked resolution path that
# silently wins over the real one" -- and the way it wins silently is by
# naming nothing: an absent layer contributes nothing, so the call would
# emit the template defaults. ADR-00000036 gives the layer an address, and
# this is the half that keeps the old objection answered: the resolver
# REFUSES an address it cannot honour rather than resolving past it.
@test "_setup_conf_layers refuses an override that names no file, instead of resolving past it (base#1087)" {
  printf '[gpu]\nmode = "off"\n' > "${TEMP_DIR}/setup.toml"
  local -a _l=()
  _SETUP_CONF_LOCAL="${TEMP_DIR}/gone.toml"
  LOG_FORMAT=json run --separate-stderr _setup_conf_layers "${TEMP_DIR}" _l "${TEMP_DIR}/.base/dist"
  assert_refusal 1 conf_local_override_unusable "path=${TEMP_DIR}/gone.toml"
}

# why: And the readers built on the chain inherit that refusal, or the one
# that matters -- the merge every emitter resolves through -- would hand
# back a configuration assembled without the layer the caller named.
@test "_setup_conf_handle propagates the refusal of an unhonourable override (base#1087)" {
  printf '[gpu]\nmode = "off"\n' > "${TEMP_DIR}/setup.toml"
  _SETUP_CONF_LOCAL="${TEMP_DIR}/gone.toml"
  LOG_FORMAT=json run --separate-stderr _setup_conf_handle "${TEMP_DIR}" _HX "${TEMP_DIR}/.base/dist"
  assert_refusal 1 conf_local_override_unusable "path=${TEMP_DIR}/gone.toml"
}

# why: A chain that moved must be reported as moved, and one that did not
# must not -- the second half matters as much, because a detector that
# always fires would make every --output call refuse and the whole
# parameterised API unusable.
@test "_setup_conf_chain_changed reports a layer the call created (base#1087)" {
  local -a _l=("${TEMP_DIR}/setup.toml" "${TEMP_DIR}/setup.local.toml")
  local -A _snap=()
  _setup_conf_chain_snapshot _l _snap
  printf '[gpu]\nmode = "force"\n' > "${TEMP_DIR}/setup.toml"
  run _setup_conf_chain_changed _l _snap
  assert_success
}

@test "_setup_conf_chain_changed reports no change over an untouched chain (base#1087)" {
  printf '[gpu]\nmode = "off"\n' > "${TEMP_DIR}/setup.toml"
  local -a _l=("${TEMP_DIR}/setup.toml" "${TEMP_DIR}/setup.local.toml")
  local -A _snap=()
  _setup_conf_chain_snapshot _l _snap
  run _setup_conf_chain_changed _l _snap
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf_full -- a layer that is there but cannot be parsed
#
# _toml_tokenize refuses a failed parse (non-zero, arrays empty, the
# conf_toml_parse_failed event). Its projection must carry that refusal
# to its caller, not discard it and answer zero over zero keys: that is
# a broken file reported as an empty one, and `setup remove` then says
# the key is missing (base#1398). The valid and absent layers are pinned
# in the same case so the refusal cannot be bought by failing them too.
# ════════════════════════════════════════════════════════════════════

# why: The projection every key-level reader goes through. Without the
# refusal a malformed setup.toml loads as zero keys with success, so a
# broken file is indistinguishable from an empty one (base#1398).
@test "_load_setup_conf_full answers non-zero with nothing loaded when the TOML parse fails (base#1398)" {
  local _conf_sh=/source/dist/script/docker/lib/conf.sh
  local _probe
  _probe="source ${_conf_sh}
declare -a s=(stale_s) k=(stale_k) v=(stale_v)
_load_setup_conf_full \"\$1\" s k v
printf 'rc=%s sects=%s keys=%s vals=%s\n' \"\$?\" \"\${#s[@]}\" \"\${#k[@]}\" \"\${#v[@]}\""

  # Every out-array is seeded with a stale entry, so "nothing loaded"
  # means the function emptied them, not that they were never touched.

  # A valid file: rc 0, with its key and value and no stale entry.
  printf '[gui]\nmode = "off"\n' > "${TEMP_DIR}/valid.toml"
  run env LOG_FORMAT=json bash -c "${_probe}" _ "${TEMP_DIR}/valid.toml"
  assert_success
  assert_output --partial "rc=0 sects=1 keys=1 vals=1"

  # An absent file: rc 0, with nothing.
  run env LOG_FORMAT=json bash -c "${_probe}" _ "${TEMP_DIR}/absent.toml"
  assert_success
  assert_output --partial "rc=0 sects=0 keys=0 vals=0"

  # A malformed file: rc 1, nothing loaded, and the parse failure named.
  # toml-fixture-lint: allow the parser's refusal of this layer IS the assertion
  printf '[gui]\nmode = "off\n' > "${TEMP_DIR}/setup.toml"
  # The probe's own report is the only stdout; the refusal is judged on
  # stderr, with the layer it names (base#1400).
  run --separate-stderr env LOG_FORMAT=json bash -c "${_probe}" _ "${TEMP_DIR}/setup.toml"
  assert_success
  assert_output "rc=1 sects=0 keys=0 vals=0"
  assert_logged_event conf_toml_parse_failed "path=${TEMP_DIR}/setup.toml"
}
