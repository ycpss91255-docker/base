#!/usr/bin/env bats
#
# config_gen_paths_spec.bats -- "a pull request drops config-gen only for a
# path config-gen provably does not read", base#1584.
#
# why: script/ci/config_gen_paths.sh is the config-gen DENY list: an exact
# path on it drops the config-gen job (check_selection.sh, row 3). The
# list is checked from both sides. List side: each entry is a tracked
# regular file outside config-gen's drivers and the trees it reads whole.
# Reader side: no entry is a file the traced config-gen host run read
# (script/ci/config_gen_readers.sh), and no config-gen input text names
# one. A file that becomes a reader fails this spec in the PR that makes
# it one, because that PR changes a file under script/test/, script/ci/,
# dist/script/docker/lib/ or dockerfile/, which runs coverage.
#
# Expected values come from the four rules in config_gen_paths.sh's
# header, the canaries r3's traced run saw
# (scratchpad 1584-r3d/bashenv-out.txt) and the workflow and scripts
# themselves, never from the deny list's own output.

bats_require_minimum_version 1.5.0

# The traced run is computed once per file and shared by every case: it
# runs config-gen's whole host side, both gates scripts in full.
setup_file() {
  local _rc=0
  bash /source/script/ci/config_gen_readers.sh --root /source --by-channel \
    >"${BATS_FILE_TMPDIR}/readers.tsv" 2>"${BATS_FILE_TMPDIR}/readers.err" || _rc=$?
  printf '%s\n' "${_rc}" >"${BATS_FILE_TMPDIR}/readers.rc"
}

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  DENY_SH=/source/script/ci/config_gen_paths.sh
  READERS="${BATS_FILE_TMPDIR}/readers.tsv"
}

# The files r3's traced config-gen host run saw (bashenv-out.txt), each a
# file some host step executes or sources. A traced run that does not see
# all of them did not trace config-gen.
CANARIES="dist/script/base/just-version.sh
dist/script/docker/lib/log.sh
script/watch/pins.sh
script/watch/lib.sh
script/ci/test-tools-pins.sh"

# _require_readers -- fails the case naming why when the traced run failed.
_require_readers() {
  local _rc
  _rc="$(cat "${BATS_FILE_TMPDIR}/readers.rc")"
  [[ "${_rc}" == 0 && -s "${READERS}" ]] \
    || fail "config_gen_readers.sh exited ${_rc}: $(head -c 2000 "${BATS_FILE_TMPDIR}/readers.err")"
}

# _reader_set <tsv> -- the paths of every channel, one per line, sorted.
_reader_set() {
  awk -F'\t' '$1 != "rp" {print $2}' "$1" | LC_ALL=C sort -u
}

# _deny_list -- config_gen_paths.sh's entries, sorted.
_deny_list() {
  bash "${DENY_SH}" | LC_ALL=C sort -u
}

# _overlap <list-file> <set-file> -- the lines in both.
_overlap() {
  LC_ALL=C comm -12 <(LC_ALL=C sort -u "$1") <(LC_ALL=C sort -u "$2")
}

# _input_texts <root> -- every config-gen input text under <root>: the
# config-gen jobs' `run:` blocks as config_gen_readers.sh --run-blocks
# reads them (every job that gates on select_config_gen; it fails when
# there is none), dockerfile/Dockerfile.config-gen and every file under
# script/test/config_gen* (steps included).
_input_texts() {
  local _r="$1" _f
  bash /source/script/ci/config_gen_readers.sh --root "${_r}" --run-blocks || return 1
  cat "${_r}/dockerfile/Dockerfile.config-gen"
  while IFS= read -r _f; do
    cat "${_f}"
  done < <(find "${_r}"/script/test/config_gen* -type f | LC_ALL=C sort)
}

# _named_entries <root> <list-file> -- the entries of <list-file> that some
# config-gen input text under <root> names literally.
_named_entries() {
  local _text _e
  _text="$(_input_texts "$1")" || return 1
  while IFS= read -r _e; do
    [[ -n "${_e}" ]] || continue
    grep -qF -- "${_e}" <<<"${_text}" && printf '%s\n' "${_e}"
  done <"$2"
  return 0
}

# why: cycle 10, rules (a) and (b). An entry that is a symlink would let a
# change to the target's twin path skip config-gen (RR4-F2): the 8 tracked
# symlinks (script/{build,exec,prune,run,setup,setup_tui,stop}.sh,
# script/docker/justfile.docker) must never be entries. An entry under
# config-gen's drivers, the selection's own files or a tree config-gen
# reads whole (_rp_copy, config_gen_redpath.sh; the just-pin step) would
# drop config-gen for a change it reads. git cannot read /source when it
# is a mounted worktree (coverage_badge_spec.bats), so the tracked check
# runs where git can, and the regular-file check runs everywhere.
@test "config_gen_paths: every entry is a regular file outside config-gen's own trees (base#1584)" {
  local _e _bad="" _n=0 _git=0
  git -c safe.directory='*' -C /source rev-parse --git-dir >/dev/null 2>&1 && _git=1
  while IFS= read -r _e; do
    [[ -n "${_e}" ]] || continue
    _n=$((_n + 1))
    if [[ -L "/source/${_e}" || ! -f "/source/${_e}" ]]; then
      _bad+="${_e}: not a regular file"$'\n'
    fi
    case "${_e}" in
      dist/* | script/* | init.sh | upgrade.sh) ;;
      *) _bad+="${_e}: outside dist/, script/, init.sh and upgrade.sh"$'\n' ;;
    esac
    case "${_e}" in
      script/test/* | script/ci/* | script/watch/* | dist/script/docker/lib/* \
        | dist/script/base/just-version.sh | justfile* | */justfile*)
        _bad+="${_e}: under a tree config-gen runs or reads whole"$'\n' ;;
    esac
    case "${_e}" in
      *[*?[]*) _bad+="${_e}: holds a glob character"$'\n' ;;
    esac
    if [[ "${_git}" -eq 1 ]]; then
      local _mode
      _mode="$(git -c safe.directory='*' -C /source ls-files -s --error-unmatch -- "${_e}" 2>/dev/null | awk '{print $1}')"
      [[ "${_mode}" == 100644 || "${_mode}" == 100755 ]] \
        || _bad+="${_e}: tracked mode '${_mode}', not a regular file"$'\n'
    fi
  done < <(bash "${DENY_SH}")
  [[ "${_n}" -gt 0 ]] || fail "config_gen_paths.sh printed no entry"
  [[ -z "${_bad}" ]] || fail "entries the rules do not admit:
${_bad}"
}

# why: cycle 11, rule (c). The traced run must have traced config-gen
# (every canary), and no entry may be a file it read, logically or
# physically, in either tracer channel.
@test "config_gen_paths: no entry is a file the traced config-gen host run read (base#1584)" {
  _require_readers
  local _set="${BATS_TEST_TMPDIR}/set" _deny="${BATS_TEST_TMPDIR}/deny" _c _miss=""
  _reader_set "${READERS}" >"${_set}"
  _deny_list >"${_deny}"
  while IFS= read -r _c; do
    grep -qxF -- "${_c}" "${_set}" || _miss+=" ${_c}"
  done <<<"${CANARIES}"
  [[ -z "${_miss}" ]] || fail "the traced run missed these canaries:${_miss}"
  run _overlap "${_deny}" "${_set}"
  assert_success
  assert_output ""
}

# why: cycle 11's red, kept as a case: an entry that IS a reader must be
# reported. dist/script/base/just-version.sh is the just-pin step's own
# script.
@test "config_gen_paths: an entry the traced run read is reported (base#1584)" {
  _require_readers
  local _set="${BATS_TEST_TMPDIR}/set" _deny="${BATS_TEST_TMPDIR}/deny"
  _reader_set "${READERS}" >"${_set}"
  { _deny_list; echo dist/script/base/just-version.sh; } >"${_deny}"
  run _overlap "${_deny}" "${_set}"
  assert_output dist/script/base/just-version.sh
}

# why: cycle 11, the xtrace channel's own check. A canary a host step
# sources (`source` / `.` in script/test/config_gen* or script/watch)
# must be in the xtrace lines alone, so a blind xtrace channel fails here
# even while the DEBUG channel still sees the canaries.
@test "config_gen_paths: every sourced canary is in the xtrace channel alone (base#1584)" {
  _require_readers
  local _c _b _n=0 _miss=""
  while IFS= read -r _c; do
    _b="${_c##*/}"
    grep -rqE "^[[:space:]]*(source|\.)[[:space:]].*${_b//./\\.}\"?[[:space:]]*(\|\||$)" \
      /source/script/test/config_gen* /source/script/watch 2>/dev/null || continue
    _n=$((_n + 1))
    grep -qxF -- "xtrace"$'\t'"${_c}" "${READERS}" || _miss+=" ${_c}"
  done <<<"${CANARIES}"
  [[ "${_n}" -ge 2 ]] || fail "expected log.sh and lib.sh to be sourced canaries, found ${_n}"
  [[ -z "${_miss}" ]] || fail "sourced canaries the xtrace channel missed:${_miss}"
}

# why: cycle 31. config_gen_redpath.sh must run in full: a run cut down to
# a subset of its cases (CONFIG_GEN_REDPATH_ONLY, a timeout) could miss a
# file one case reads. Every case of _RP_CASES, read from the script
# itself, must have an `_rp_case` record, and its main's last call,
# `_rp_retro` (main's order at base#1547's split), one too.
@test "config_gen_paths: the traced run ran every config_gen_redpath.sh case (base#1584)" {
  _require_readers
  local _c _miss=""
  local -a _cases
  mapfile -t _cases < <(bash -c 'source /source/script/test/config_gen_redpath.sh; printf "%s\n" "${_RP_CASES[@]%%:*}"')
  [[ "${#_cases[@]}" -ge 10 ]] || fail "read ${#_cases[@]} cases from _RP_CASES"
  for _c in "${_cases[@]}"; do
    grep -qxF -- "rp"$'\t'"_rp_case"$'\t'"${_c}" "${READERS}" || _miss+=" ${_c}"
  done
  grep -qE $'^rp\t_rp_retro\t' "${READERS}" || _miss+=" _rp_retro"
  [[ -z "${_miss}" ]] || fail "the traced run never reached:${_miss}"
}

# why: cycle 12, rule (d). An entry a config-gen input text names may be
# read through a path the tracer cannot see (a data read), so the name
# alone removes it.
@test "config_gen_paths: no config-gen input text names an entry (base#1584)" {
  local _deny="${BATS_TEST_TMPDIR}/deny"
  _deny_list >"${_deny}"
  run _named_entries /source "${_deny}"
  assert_success
  assert_output ""
}

# why: cycle 12's red, kept as a case: a scratch copy whose 30-watch-gosum
# step names dist/env.toml (an entry) must report it.
@test "config_gen_paths: an entry a config-gen step names is reported (base#1584)" {
  local _r="${BATS_TEST_TMPDIR}/r" _deny="${BATS_TEST_TMPDIR}/deny"
  mkdir -p "${_r}/.github/workflows" "${_r}/dockerfile" "${_r}/script/test"
  cp /source/.github/workflows/self-test.yaml "${_r}/.github/workflows/"
  cp /source/dockerfile/Dockerfile.config-gen "${_r}/dockerfile/"
  cp -R /source/script/test/config_gen_steps "${_r}/script/test/"
  printf '# reads dist/env.toml\n' >>"${_r}/script/test/config_gen_steps/30-watch-gosum.sh"
  _deny_list >"${_deny}"
  run _named_entries "${_r}" "${_deny}"
  assert_output dist/env.toml
}

# why: review round 2. base#1547 split the config-gen job in two, and a
# rule (d) that read the old job `config-gen` read no run block at all.
# A run block of either split job that names an entry must be reported:
# here config-gen-redpath's go-redpath line names dist/env.toml.
@test "config_gen_paths: an entry a config-gen-redpath run block names is reported (base#1584)" {
  local _r="${BATS_TEST_TMPDIR}/r" _deny="${BATS_TEST_TMPDIR}/deny"
  mkdir -p "${_r}/.github/workflows" "${_r}/dockerfile" "${_r}/script/test"
  cp /source/.github/workflows/self-test.yaml "${_r}/.github/workflows/"
  cp /source/dockerfile/Dockerfile.config-gen "${_r}/dockerfile/"
  cp -R /source/script/test/config_gen_steps "${_r}/script/test/"
  yq -i '(.jobs."config-gen-redpath".steps[] | select(.run == "just test go-redpath ${{ matrix.shard }}/5") | .run) += " # dist/env.toml"' \
    "${_r}/.github/workflows/self-test.yaml"
  grep -qF 'go-redpath ${{ matrix.shard }}/5 # dist/env.toml' "${_r}/.github/workflows/self-test.yaml"
  _deny_list >"${_deny}"
  run _named_entries "${_r}" "${_deny}"
  assert_output dist/env.toml
}

# why: review round 2. With no job that gates on select_config_gen, rule
# (d) has no run block to read; that fails rather than passing on an
# empty text.
@test "config_gen_paths: rule (d) fails when no config-gen job is found (base#1584)" {
  local _r="${BATS_TEST_TMPDIR}/r" _deny="${BATS_TEST_TMPDIR}/deny"
  mkdir -p "${_r}/.github/workflows" "${_r}/dockerfile" "${_r}/script/test"
  cp /source/.github/workflows/self-test.yaml "${_r}/.github/workflows/"
  cp /source/dockerfile/Dockerfile.config-gen "${_r}/dockerfile/"
  cp -R /source/script/test/config_gen_steps "${_r}/script/test/"
  yq -i 'del(.jobs."config-gen-gates") | del(.jobs."config-gen-redpath")' "${_r}/.github/workflows/self-test.yaml"
  _deny_list >"${_deny}"
  run _named_entries "${_r}" "${_deny}"
  assert_failure
}

# why: the tracer cannot fail open quietly: no host-side file may install
# a DEBUG trap, turn off functrace or xtrace, or move the xtrace fd or
# prompt. Any of these in a host step would blind a channel, so its mere
# presence in shell code under script/, dist/, dockerfile/ or a justfile
# fails here.
@test "config_gen_paths: no host-side shell code can blind the reader tracer (base#1584)" {
  local _f _hits=""
  while IFS= read -r _f; do
    _hits+="$(code_grep -nE 'trap [^#]*DEBUG|set [+]T|set [+]o functrace|set [+]x|set [+]o xtrace|BASH_XTRACEFD=|PS4=' "${_f}" \
      | sed "s|^|${_f#/source/}:|")"
  done < <(find /source/script /source/dist /source/dockerfile -type f \
             \( -name '*.sh' -o -name '*.bash' -o -name 'justfile*' \) \
             -not -path '/source/script/ci/config_gen_readers.sh' | LC_ALL=C sort; \
           find /source -maxdepth 1 -name 'justfile*' -type f)
  [[ -z "${_hits}" ]] || fail "host-side code that blinds the tracer:
${_hits}"
}
