#!/usr/bin/env bats
#
# config_gen_gitignore_golden_spec.bats -- the s82 corpus of the shell
# gitignore helpers against testdata/golden/s82 (base#2064, slice S82a of
# base#1818 / base#1754 under base#1395).
#
# why: Before any Go code replaces the gitignore parsing, today's shell
# behaviour is pinned as goldens. The shell function is the oracle: this
# spec re-runs it on every input in a scratch directory and fails on any
# byte difference from the stored golden. One golden per input:
#
#   rc=<exit code>
#   mode=<octal mode of the target file after the call, or absent>
#   --- file
#   <exact bytes of the target file after the call>
#   --- stdout
#   <stdout of the call>
#   --- stderr
#   <one event per line: SEVERITY body key=value ...>
#
# The scratch directory path is written as TMP. Names carry the s82_
# prefix, since corpus basenames are unique across slices. The cases here
# emit no event, so stderr is empty and no event field needs dropping;
# later children that pin events add that normalisation.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TESTDATA="/source/dockerfile/config-gen/testdata"
  S="${BATS_TEST_TMPDIR}"
}

# Golden names with no corpus input: the case calls the function on a path
# that does not exist.
_S82_INPUTLESS=(s82_prune_absent)

# _partition_violations -- print one line per corpus input with no golden
# and per golden with neither an input nor a listed inputless name.
_partition_violations() {
  local _f _stem _n _ok
  for _f in "${TESTDATA}"/corpus/s82/*.gitignore; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .gitignore)"
    [[ -f "${TESTDATA}/golden/s82/${_stem}.golden" ]] \
      || printf 'corpus input with no golden: %s\n' "${_stem}"
  done
  for _f in "${TESTDATA}"/golden/s82/*.golden; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .golden)"
    _ok=0
    [[ -f "${TESTDATA}/corpus/s82/${_stem}.gitignore" ]] && _ok=1
    for _n in "${_S82_INPUTLESS[@]}"; do
      [[ "${_n}" == "${_stem}" ]] && _ok=1
    done
    (( _ok == 1 )) || printf 'golden with no corpus input: %s\n' "${_stem}"
  done
  return 0
}

# _run_case <name> <target-mode|-> <override-retired:yes|no> <input|->
# -- run _prune_retired_entries in ${S}/w and write the actual golden to
# ${S}/actual/<name>.golden. <input> is a corpus file copied to the target
# (given <target-mode> when not `-`); `-` calls the function on a missing
# path. <override-retired> yes replaces _retired_gitignore_entries with
# `old1` and `old2`; no keeps the production function.
_run_case() {
  local _name="${1}" _mode="${2}" _override="${3}" _input="${4}"
  local _tgt="${S}/w/.gitignore" _rc=0 _m
  rm -rf -- "${S}/w"
  mkdir -p "${S}/w" "${S}/actual"
  if [[ "${_input}" != - ]]; then
    cp -- "${TESTDATA}/corpus/s82/${_input}" "${_tgt}"
    [[ "${_mode}" == - ]] || chmod "${_mode}" "${_tgt}"
  fi
  (
    # shellcheck source=dist/script/docker/lib/gitignore.sh
    source /source/dist/script/docker/lib/gitignore.sh
    if [[ "${_override}" == yes ]]; then
      _retired_gitignore_entries() { printf 'old1\nold2\n'; }
    fi
    _prune_retired_entries "${_tgt}"
  ) > "${S}/stdout" 2> "${S}/stderr" || _rc=$?
  if [[ -e "${_tgt}" ]]; then
    _m="$(stat -c %a -- "${_tgt}")"
  else
    _m=absent
  fi
  {
    printf 'rc=%d\nmode=%s\n--- file\n' "${_rc}" "${_m}"
    if [[ -e "${_tgt}" ]]; then cat -- "${_tgt}"; fi
    printf -- '--- stdout\n'
    sed "s|${S}/w|TMP|g" "${S}/stdout"
    printf -- '--- stderr\n'
    sed "s|${S}/w|TMP|g" "${S}/stderr"
  } > "${S}/actual/${_name}.golden"
}

# _assert_golden <name> -- the stored golden exists and equals the actual
# one byte for byte. cmp, never $(...), which drops trailing LFs.
_assert_golden() {
  local _gold="${TESTDATA}/golden/s82/${1}.golden"
  [[ -f "${_gold}" ]] || fail "no golden for ${1}: ${_gold}"
  cmp -- "${_gold}" "${S}/actual/${1}.golden" \
    || fail "$(diff -u "${_gold}" "${S}/actual/${1}.golden")"
}

# why: a fixture with no golden would be read against nothing, and a stale
# golden would stand for a case no longer run.
@test "s82 corpus: every input has a golden and every golden an input" {
  run _partition_violations
  assert_success
  assert_output ""
}

# why: the managed half is the lines below the marker; the entry above it
# is the user's own and stays, both retired entries below go, the missing
# final newline is added, and the file keeps mode 640 (base#1356).
@test "s82 prune: retired entries go below the marker only" {
  _run_case s82_prune_below 640 yes s82_prune_below.gitignore
  _assert_golden s82_prune_below
}

# why: with no marker nothing is claimed as managed, so nothing is pruned.
@test "s82 prune: a file with no marker is unchanged" {
  _run_case s82_prune_no_marker - yes s82_prune_no_marker.gitignore
  _assert_golden s82_prune_no_marker
}

# why: an absent target is a no-op: rc 0 and no file is created.
@test "s82 prune: an absent target is a no-op and creates no file" {
  _run_case s82_prune_absent - yes -
  _assert_golden s82_prune_absent
}

# why: the production retired list is empty today, so a marker alone prunes
# nothing; this case keeps the production function.
@test "s82 prune: the empty production retired list leaves the file unchanged" {
  _run_case s82_prune_empty_list - no s82_prune_empty_list.gitignore
  _assert_golden s82_prune_empty_list
}
