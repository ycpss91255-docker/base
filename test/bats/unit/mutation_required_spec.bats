#!/usr/bin/env bats
#
# mutation_required_spec.bats -- script/test/drivers/mutation_required.sh,
# the required-kill roster runner (base#1461).
#
# why: Every shell refusal guard a config-gen slice adds is listed, with the
# mutation that disables it, in script/test/mutation_required/<slice>.tsv.
# Before this runner nothing read those files: a pinning test could be
# deleted with every gate green, because the only proof that the guard was
# pinned was a probe someone once ran by hand. The runner reads every row,
# validates ALL of them before any baseline runs, probes each row in a
# private sandbox copy through its own fixed --apply, and exits 0 only when
# every row is PINNED.
#
# Row contract, one for every roster file:
#   <id> TAB <subject> TAB <spec> TAB <old> TAB <new>
# `#` lines and blank lines are skipped. <old> and <new> are decoded with
# exactly three escapes, `\\` `\t` `\n`; any other `\x` or a trailing `\`
# is reason=bad_escape. <old> must occur exactly once in <subject>; <new>
# may be empty (a deletion) and must differ from <old>.
#
# Seams the cases use: --root <dir> names the checkout whose roster is read
# (default: this checkout); MUTATION_PROBE_RUNNER is the probe's own runner
# override, so no case builds an image; MUTATION_REQUIRED_PROBE replaces the
# probe itself where a case needs a probe that lies; `docker` is a PATH stub
# that logs its argv and answers `ps` from MR_DOCKER_PS. --check validates
# the roster and runs nothing.
#
# Every refusal holds assert_refusal's five points.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  MR="/source/script/test/drivers/mutation_required.sh"
  S="${BATS_TEST_TMPDIR}"
  LIVE="${S}/live"
  ROSTER="${LIVE}/script/test/mutation_required"
  mkdir -p "${S}/bin" "${S}/tmp" "${S}/diffs"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount.
  cd "${S}"
  unset COMPOSE_PROJECT_NAME MUTATION_REQUIRED_JOBS MUTATION_REQUIRED_PROBE \
    GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MR_DOCKER_PS MR_RUNNER_SLEEP
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="${S}/gitconfig"
  git config --file "${GIT_CONFIG_GLOBAL}" user.name t
  git config --file "${GIT_CONFIG_GLOBAL}" user.email t@t
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" commit.gpgsign false
  export MR_DOCKER_LOG="${S}/docker.log"
  export MR_RUNNER_LOG="${S}/runner.log"
  export MR_DIFF_DIR="${S}/diffs"
  : > "${MR_DOCKER_LOG}"
  _docker_stub
  _runner
  _live
}

# ── fixtures ────────────────────────────────────────────────────────────────

# _docker_stub -- `docker` logs its argv; `ps` prints MR_DOCKER_PS (a
# container still running) and nothing otherwise.
_docker_stub() {
  cat > "${S}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MR_DOCKER_LOG:?}"
if [[ "${1:-}" == ps && -n "${MR_DOCKER_PS:-}" ]]; then
  printf '%s\n' "${MR_DOCKER_PS}"
fi
exit 0
STUB
  chmod +x "${S}/bin/docker"
}

# _runner -- the MUTATION_PROBE_RUNNER stub. It is called with the root and
# the spec as its last two arguments. Red (rc 1, one `not ok`) only while
# lib/guard.sh differs from the sandbox's commit, so it goes red on mutated
# bytes and nothing else; it records its pid, its COMPOSE_PROJECT_NAME, its
# root, the root's mode and its start and end times, and the diff it saw.
_runner() {
  cat > "${S}/runner" <<'STUB'
#!/usr/bin/env bash
root="${@: -2:1}"
printf 'start %s %s %s %s %s\n' "${EPOCHREALTIME}" "$$" "${root}" \
  "${COMPOSE_PROJECT_NAME:-}" "$(stat -c %a -- "${root}")" >> "${MR_RUNNER_LOG:?}"
[[ -z "${MR_RUNNER_SLEEP:-}" ]] || sleep "${MR_RUNNER_SLEEP}"
git -C "${root}" ls-files | LC_ALL=C sort > "${MR_DIFF_DIR}/files.$$"
if git -C "${root}" diff --quiet -- lib/guard.sh; then
  printf 'ok 1 the guard holds\n'
  rc=0
else
  git -C "${root}" diff -U0 -- lib/guard.sh > "${MR_DIFF_DIR}/diff.$$"
  printf 'not ok 1 the guard noticed\n'
  rc=1
fi
printf 'end %s %s\n' "${EPOCHREALTIME}" "$$" >> "${MR_RUNNER_LOG}"
exit "${rc}"
STUB
  chmod +x "${S}/runner"
}

# _live -- a checkout with a roster directory, one subject with every shape
# the escape rules need (an ambiguous line, a literal TAB, a literal
# backslash-n, a line to delete), a second subject the runner never reads,
# a spec, and a test.sh that answers --compose-project-name the way the real
# one does: the inherited COMPOSE_PROJECT_NAME verbatim when set, otherwise
# a name derived from its own path.
_live() {
  mkdir -p "${ROSTER}" "${LIVE}/lib" "${LIVE}/test/bats/unit" "${LIVE}/script/test"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'guard() {' \
    '  if [[ -z "${1:-}" ]]; then' \
    '    return 1' \
    '  fi' \
    '  return 1' \
    '}' \
    $'\ttabbed=1' \
    "fold='a\\nb'" \
    'drop_me=1' \
    'tail=1' > "${LIVE}/lib/guard.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'other() {' '  return 7' '}' \
    > "${LIVE}/lib/other.sh"
  printf '%s\n' '@test "guard" { :; }' > "${LIVE}/test/bats/unit/guard_spec.bats"
  cat > "${LIVE}/script/test/test.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --compose-project-name ]]; then
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    printf '%s\n' "${COMPOSE_PROJECT_NAME}"
  else
    here="$(cd "$(dirname "$0")/../.." && pwd -P)"
    printf 'fx-%s\n' "$(printf '%s' "${here}" | cksum | cut -d' ' -f1)"
  fi
  exit 0
fi
exit 2
STUB
  chmod +x "${LIVE}/script/test/test.sh"
}

# _commit_live -- make ${LIVE} a committed git work tree.
_commit_live() {
  git -C "${LIVE}" init -q
  git -C "${LIVE}" add -A
  git -C "${LIVE}" commit -q --no-verify -m live
}

# _row <file> <field>... -- append one TAB-joined row to the roster file.
_row() {
  local _f="${1}" _line
  shift
  _line="$(IFS=$'\t'; printf '%s' "$*")"
  printf '%s\n' "${_line}" >> "${ROSTER}/${_f}"
}

# _pin_row <file> <id> -- a row the runner observes: the if-guard disabled.
_pin_row() {
  _row "${1}" "${2}" lib/guard.sh test/bats/unit/guard_spec.bats \
    '  if [[ -z "${1:-}" ]]; then' '  if false; then'
}

# _run_mr [args...] -- the driver against ${LIVE}, JSON logging, the stub
# docker first on PATH, stdout and stderr judged apart.
_run_mr() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
    TMPDIR="${S}/tmp" MUTATION_PROBE_RUNNER="${S}/runner" \
    bash "${MR}" --root "${LIVE}" "$@"
}

# _assert_mr_refusal <status> <id> [<attribution>...]
_assert_mr_refusal() {
  local _st="${1}" _id="${2}"
  shift 2
  assert_refusal "${_st}" "${_id}" "$@" "code.filepath=${MR}"
}

# _runner_never_ran -- validation came before every baseline.
_runner_never_ran() {
  [[ ! -s "${MR_RUNNER_LOG}" ]] \
    || fail "the probe's runner ran before every row was validated: $(cat "${MR_RUNNER_LOG}")"
}

# _no_probe_lines -- the driver relays no line that reads as a probe verdict.
_no_probe_lines() {
  local _l
  while IFS= read -r _l; do
    [[ "${_l}" != "mutation probe:"* ]] \
      || fail "a line reads as a probe verdict: ${_l}"
  done <<< "${output}"$'\n'"${stderr:-}"
}

# _max_concurrent -- the most runner invocations alive at once, read off the
# start / end records.
_max_concurrent() {
  awk '{ print $2, ($1 == "start" ? 1 : -1) }' "${MR_RUNNER_LOG}" \
    | LC_ALL=C sort -n -k1,1 \
    | awk '{ n += $2; if (n > m) m = n } END { print m + 0 }'
}

# _decode <text> -- the contract's three escapes, decoded independently of
# the driver; non-zero on any other escape.
_decode() {
  local _in="${1}" _out="" _c _i
  for (( _i = 0; _i < ${#_in}; _i++ )); do
    _c="${_in:_i:1}"
    if [[ "${_c}" == '\' ]]; then
      _i=$(( _i + 1 ))
      case "${_in:_i:1}" in
        '\') _out+='\' ;;
        t) _out+=$'\t' ;;
        n) _out+=$'\n' ;;
        *) return 1 ;;
      esac
    else
      _out+="${_c}"
    fi
  done
  printf '%s' "${_out}"
}

# ── the committed roster ────────────────────────────────────────────────────

# why: The roster already holds 166 rows from S1b, S1c, S1d, S1g and S1h in a
# four-column `sed -i` form, and the runner's contract is the declarative
# five-column one. Adopting them means every committed row is in that
# contract, applies through the runner's own --apply to exactly one changed
# region, and survives the runner's validation pass -- a contract that
# rejects or mis-splits the committed rows fails here, as does a roster that
# lost one of them on the way.
@test "roster: every committed row is a five-column row that --apply changes in exactly one region (base#1461)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _f _line _n=0 _id _subj _spec _old _new _work _hunks
  local -A _ids=()
  for _f in /source/script/test/mutation_required/*.tsv; do
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      [[ -z "${_line}" || "${_line}" == '#'* ]] && continue
      _n=$(( _n + 1 ))
      # cut, not `read`: TAB is IFS whitespace, so `read` folds an empty
      # <new> into its neighbour.
      _id="$(cut -f1 <<< "${_line}")"
      _subj="$(cut -f2 <<< "${_line}")"
      _spec="$(cut -f3 <<< "${_line}")"
      _old="$(cut -f4 <<< "${_line}")"
      _new="$(cut -f5 <<< "${_line}")"
      [[ "$(awk -F'\t' '{ print NF }' <<< "${_line}")" == 5 ]] \
        || fail "$(basename "${_f}"): row '${_id}' is not <id> TAB <subject> TAB <spec> TAB <old> TAB <new>: ${_line}"
      _ids["$(basename "${_f}" .tsv):${_id}"]=1
      _work="${S}/adopt/${_n}"
      mkdir -p "${_work}/$(dirname "${_subj}")"
      cp -p "/source/${_subj}" "${_work}/${_subj}"
      # The pristine copy is the diff baseline, not /source: a concurrent
      # writer to the live tree must not supply half the verdict (base#965).
      cp -p "${_work}/${_subj}" "${_work}/.orig"
      _decode "${_old}" > "${_work}/.old" || fail "row '${_id}': old carries an escape outside \\\\ \\t \\n"
      _decode "${_new}" > "${_work}/.new" || fail "row '${_id}': new carries an escape outside \\\\ \\t \\n"
      ( cd "${_work}" && bash "${MR}" --apply "${_subj}" .old .new ) \
        || fail "row '${_id}': --apply refused against /source/${_subj}"
      _hunks="$(diff -U0 "${_work}/.orig" "${_work}/${_subj}" | grep -c '^@@' || true)"
      [[ "${_hunks}" == 1 ]] \
        || fail "row '${_id}': --apply changed ${_hunks} regions of ${_subj}, not one"
    done < "${_f}"
  done
  (( _n >= 168 )) || fail "the roster has ${_n} rows; S1a's 2 seeds and the 166 of S1b, S1c, S1d, S1g and S1h are 168"
  local _want
  for _want in \
    s1b:runner-step-status s1b:runner-usage-unknown s1b:redpath-control \
    s1b:coverage-profile-missing s1b:spec-workflow-env-keys \
    s1c:scan-unsupported-byte s1c:oracle-pin-missing s1c:read-gomod-target \
    s1c:pins-commit-final-newline s1c:reader-marker-target-event \
    s1d:base-pr-mergebase s1d:base-origin-missing s1d:base-main-push-missing \
    s1d:usage-unknown-option s1d:publish-restore-failed-keep \
    s1d:logger-caller-frame s1d:redpath-git-copy \
    s1g:corpus-root-guard s1g:corpus-root-forward \
    s1h:override-verbatim s1h:build-exit s1h:build-fold s1h:digest-content \
    s1h:digest-failure-status; do
    [[ -n "${_ids[${_want}]:-}" ]] || fail "the roster lost row ${_want}"
  done
  local _c
  for _c in s1b:26 s1c:88 s1d:38 s1g:2 s1h:12 s1a:2; do
    [[ "$(grep -cvE '^(#|$)' "/source/script/test/mutation_required/${_c%%:*}.tsv")" == "${_c##*:}" ]] \
      || fail "${_c%%:*}.tsv does not hold its ${_c##*:} rows"
  done
}

# why: A seed row names its subject, but what it must disable is one guard:
# setup_cmd.sh's refusal of a non-regular-file apply output and
# setup_conf.sh's refusal of a local layer not named *.toml. A row that
# mutated any other line of either file would still go red somewhere in the
# spec and read PINNED. So each seed's decoded <old> must be the `if` whose
# body logs that guard's refusal event, holding the guard's own test, and
# its decoded <new> must be the same `if` made never-true.
@test "roster: each S1a seed row disables the guard it is named for (base#1461)" {
  local _id _subj _test _event _line _old _new _ind _after _rows=0
  local _tsv=/source/script/test/mutation_required/s1a.tsv
  while IFS='|' read -r _id _subj _test _event; do
    _line="$(awk -F'\t' -v id="${_id}" '!/^#/ && $1 == id' "${_tsv}")"
    [[ -n "${_line}" ]] || fail "s1a.tsv has no row ${_id}"
    [[ "$(cut -f2 <<< "${_line}")" == "${_subj}" ]] \
      || fail "row ${_id} does not mutate ${_subj}"
    _old="$(_decode "$(cut -f4 <<< "${_line}")")" || fail "row ${_id}: bad escape in old"
    _new="$(_decode "$(cut -f5 <<< "${_line}")")" || fail "row ${_id}: bad escape in new"
    [[ "${_old}" =~ ^([[:space:]]*)if\ .*\;\ then$ ]] \
      || fail "row ${_id}: old is not one if-guard line: ${_old}"
    _ind="${BASH_REMATCH[1]}"
    [[ "${_old}" == *"${_test}"* ]] \
      || fail "row ${_id}: old does not carry the guard's test '${_test}': ${_old}"
    assert_equal "${_new}" "${_ind}if false; then"
    # The line right after <old> in the subject is the guard's body: it has
    # to be the refusal this row is named for.
    _after="$(awk -v o="${_old}" 'f { print; exit } $0 == o { f = 1 }' "/source/${_subj}")"
    [[ "${_after}" == *"_log_err "*" ${_event}"* ]] \
      || fail "row ${_id}: the guard after old does not log ${_event}: ${_after}"
    _rows=$(( _rows + 1 ))
  done <<'SEEDS'
setup-cmd-non-regular-file|dist/script/docker/lib/setup_cmd.sh|[[ ! -f "${_d}" ]]|apply_output_unusable
setup-conf-toml-suffix|dist/script/docker/lib/setup_conf.sh|"${_p}" != *.toml|conf_local_override_unusable
SEEDS
  assert_equal "${_rows}" 2
}

# why: The runner's own validation over the committed roster, not the
# spec's re-reading of it: a contract the runner reads differently from the
# documented one (a lost empty <new>, a decoder that is not the three
# escapes) refuses a committed row here.
@test "roster: the runner's validation pass accepts every committed row (base#1461)" {
  run --separate-stderr env LOG_FORMAT=json bash "${MR}" --check --root /source
  assert_success
  [[ "${stderr}" != *mutation_required_row_invalid* ]] \
    || fail "the runner refused a committed row: ${stderr}"
  [[ "${stderr}" != *mutation_required_roster_empty* ]] \
    || fail "the runner saw no rows in the committed roster: ${stderr}"
}

# ── validation before any baseline ──────────────────────────────────────────

# why: A roster directory with no roster file is a gate that checks nothing;
# reading it as "every row PINNED" is the false green this runner exists to
# remove.
@test "validation: an empty roster directory is refused (base#1461)" {
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_roster_empty
  _runner_never_ran
}

# why: The same false green one step later: roster files that carry only
# comments are zero rows.
@test "validation: roster files with no rows are refused (base#1461)" {
  printf '# nothing yet\n\n' > "${ROSTER}/a.tsv"
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_roster_empty
  _runner_never_ran
}

# why: The committed rows are four columns wide in the sed form; a runner
# that took a four-field row would read the sed command as <old>.
@test "validation: a four-field row is refused before any baseline (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv short lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" reason=field_count
  _runner_never_ran
}

# why: A sixth field is a row whose fields are not where the reader thinks.
@test "validation: a six-field row is refused before any baseline (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv long lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2' extra
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=long reason=field_count
  _runner_never_ran
}

# why: A row naming a subject that is not there would probe nothing.
@test "validation: a row whose subject does not exist is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv gone lib/nope.sh test/bats/unit/guard_spec.bats 'x' 'y'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=gone reason=subject_missing
  _runner_never_ran
}

# why: A row naming a spec that is not there is a pinning test that was
# deleted -- the exact event the roster exists to catch.
@test "validation: a row whose spec does not exist is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv nospec lib/guard.sh test/bats/unit/gone_spec.bats 'tail=1' 'tail=2'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=nospec reason=spec_missing
  _runner_never_ran
}

# why: A spec path outside test/bats is not a spec the suite runs.
@test "validation: a spec outside test/bats is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv badspec lib/guard.sh lib/other.sh 'tail=1' 'tail=2'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=badspec reason=spec_not_under_test_bats
  _runner_never_ran
}

# why: A subject that walks out of the root is one the sandbox does not
# hold and the probe must not write.
@test "validation: a subject path with .. is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv escape ../live/lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=escape reason=path_dotdot
  _runner_never_ran
}

# why: <old> that is not in the subject changes no byte: the probe would
# refuse at run time, after every earlier row's baseline.
@test "validation: an old that does not occur in the subject is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv absent lib/guard.sh test/bats/unit/guard_spec.bats 'no such line' 'x'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=absent reason=old_not_found
  _runner_never_ran
}

# why: <old> that occurs twice is a row whose target is a guess.
@test "validation: an old that occurs twice is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv twice lib/guard.sh test/bats/unit/guard_spec.bats '  return 1' '  return 0'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=twice reason=old_ambiguous
  _runner_never_ran
}

# why: Occurrences that overlap are occurrences too: in `aaa` the old `aa`
# starts at two offsets, so which bytes the mutant changes is a guess. A
# count that resumes after the whole first match sees one.
@test "validation: an old whose occurrences overlap is refused as ambiguous (base#1461)" {
  printf 'aaa\n' > "${LIVE}/lib/overlap.sh"
  _pin_row a.tsv good
  _row a.tsv overlap lib/overlap.sh test/bats/unit/guard_spec.bats 'aa' 'b'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=overlap reason=old_ambiguous
  _runner_never_ran
}

# why: A subject that carries a NUL byte cannot be edited byte-exactly by a
# shell (a command substitution drops the NUL), so the mutant would differ
# from the subject in bytes the row never named and could be read PINNED
# for a change nobody wrote. Refused before any baseline.
@test "validation: a subject that carries a NUL byte is refused (base#1461)" {
  printf 'guard=1\0tail\n' > "${LIVE}/lib/nul.sh"
  _pin_row a.tsv good
  _row a.tsv nul lib/nul.sh test/bats/unit/guard_spec.bats 'guard=1' 'guard=0'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=nul reason=subject_has_nul
  _runner_never_ran
}

# why: <new> equal to <old> changes no byte.
@test "validation: a new equal to old is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv same lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=1'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=same reason=new_equals_old
  _runner_never_ran
}

# why: An empty <old> is everywhere and nowhere.
@test "validation: an empty old is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv blank lib/guard.sh test/bats/unit/guard_spec.bats '' 'x'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=blank reason=empty_field
  _runner_never_ran
}

# why: Two rows with one id make a report that cannot say which row failed.
@test "validation: a duplicate id in one file is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv good lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=good reason=duplicate_row
  _runner_never_ran
}

# why: The same mutation under two ids, in two files, counts one kill twice.
@test "validation: the same mutation in two roster files is refused (base#1461)" {
  _pin_row a.tsv first
  _pin_row b.tsv second
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/b.tsv:1" id=second reason=duplicate_row
  _runner_never_ran
}

# why: Ids are the names the PR verdict tables and the reports use.
@test "validation: an id outside [a-z0-9-] is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv 'Bad_Id' lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" reason=id_invalid
  _runner_never_ran
}

# why: Only three escapes exist. A decoder that kept `\q` raw, or ran
# printf %b over it, would apply a different byte string than the row says.
@test "validation: an escape outside the three is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv esc lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1\q' 'tail=2'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=esc reason=bad_escape
  _runner_never_ran
}

# why: A trailing backslash escapes nothing.
@test "validation: a trailing backslash is refused (base#1461)" {
  _pin_row a.tsv good
  _row a.tsv trail lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2\'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:2" id=trail reason=bad_escape
  _runner_never_ran
}

# why: Every invalid row is reported, not only the first, so one run names
# the whole repair.
@test "validation: two invalid rows are both reported (base#1461)" {
  _row a.tsv absent lib/guard.sh test/bats/unit/guard_spec.bats 'no such line' 'x'
  _row a.tsv same lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=1'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_row_invalid \
    "row=script/test/mutation_required/a.tsv:1" reason=old_not_found
  [[ "${stderr}" == *'"row":"script/test/mutation_required/a.tsv:2"'* ]] \
    || fail "the second invalid row was not reported: ${stderr}"
  _runner_never_ran
}

# ── escapes, applied ────────────────────────────────────────────────────────

# _only_diff -- the one diff the mutated run recorded.
_only_diff() {
  local -a _d=( "${MR_DIFF_DIR}"/diff.* )
  (( ${#_d[@]} == 1 )) && [[ -f "${_d[0]}" ]] \
    || fail "want one mutated run, have: ${_d[*]}"
  grep -E '^[-+][^-+]' "${_d[0]}" || true
}

# why: `\n` joins two lines into one <old>: the shape S1d's
# base-origin-missing and S1h's build-exit need, because their one line
# occurs more than once.
@test "escapes: a two-line old written with \\n is applied as two lines (base#1461)" {
  _row a.tsv two lib/guard.sh test/bats/unit/guard_spec.bats '  fi\n  return 1' '  fi\n  return 0'
  _commit_live
  _run_mr
  assert_success
  assert_equal "$(_only_diff)" "-  return 1
+  return 0"
}

# why: `\t` is a TAB byte; the column separator cannot appear raw.
@test "escapes: \\t is a TAB byte (base#1461)" {
  _row a.tsv tab lib/guard.sh test/bats/unit/guard_spec.bats '\ttabbed=1' '\ttabbed=0'
  _commit_live
  _run_mr
  assert_success
  assert_equal "$(_only_diff)" "-"$'\t'"tabbed=1
+"$'\t'"tabbed=0"
}

# why: `\\n` is a backslash then n -- S1h's build-fold line carries a literal
# backslash-n. A raw-literal reader looks for two backslashes.
@test "escapes: \\\\n is a literal backslash then n (base#1461)" {
  _row a.tsv fold lib/guard.sh test/bats/unit/guard_spec.bats "fold='a\\\\nb'" "fold=''"
  _commit_live
  _run_mr
  assert_success
  assert_equal "$(_only_diff)" "-fold='a\\nb'
+fold=''"
}

# why: An empty <new> deletes: S1d's redpath-git-copy removes a line.
@test "escapes: an empty new deletes old (base#1461)" {
  _row a.tsv drop lib/guard.sh test/bats/unit/guard_spec.bats 'drop_me=1\n' ''
  _commit_live
  _run_mr
  assert_success
  assert_equal "$(_only_diff)" "-drop_me=1"
}

# ── verdicts ────────────────────────────────────────────────────────────────

# why: The one green: every row PINNED, each reported with its row and id.
@test "verdict: a row the spec notices is reported pinned and the run passes (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  _run_mr
  assert_success
  assert_logged_event mutation_required_pinned \
    "row=script/test/mutation_required/a.tsv:1" id=kill
  _no_probe_lines
}

# why: A row whose mutation the spec does not notice is a guard nothing
# pins. The probe calls a narrow green INCONCLUSIVE, and here that is a
# failure, never a pass.
@test "verdict: a row the spec does not notice fails as survived (base#1461)" {
  _row a.tsv miss lib/other.sh test/bats/unit/guard_spec.bats '  return 7' '  return 0'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_survived \
    "row=script/test/mutation_required/a.tsv:1" id=miss verdict=INCONCLUSIVE
  _no_probe_lines
}

# why: A probe that exits 0 without its PINNED line is not a PINNED probe; a
# check on the status alone would pass it.
@test "verdict: a probe that exits 0 without its PINNED line is refused (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${S}/probe-silent"
  chmod +x "${S}/probe-silent"
  MUTATION_REQUIRED_PROBE="${S}/probe-silent" _run_mr
  _assert_mr_refusal 1 mutation_required_probe_refused \
    "row=script/test/mutation_required/a.tsv:1" id=kill rc=0
}

# why: The PINNED line over zero `not ok` is a verdict with no witness; a
# grep for the bare word would pass it.
@test "verdict: a PINNED line over zero not ok is refused (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  cat > "${S}/probe-liar" <<'STUB'
#!/usr/bin/env bash
spec=''
while (( $# )); do [[ "$1" == --spec ]] && spec="$2"; shift; done
printf 'mutation probe: 1 executed / 0 not ok / 0 skipped at scope=spec:%s\n' "${spec}"
printf 'mutation probe: PINNED. The assertions that noticed, at scope=spec:%s:\n' "${spec}"
exit 0
STUB
  chmod +x "${S}/probe-liar"
  MUTATION_REQUIRED_PROBE="${S}/probe-liar" _run_mr
  _assert_mr_refusal 1 mutation_required_probe_refused \
    "row=script/test/mutation_required/a.tsv:1" id=kill
}

# why: Verdicts are published only after every row finished, and a failing
# run publishes no pass: a pinned row 1 inside a run whose row 2 survived
# says nothing that reads as green.
@test "verdict: one survivor fails the run and no row is reported pinned (base#1461)" {
  _pin_row a.tsv kill
  _row a.tsv miss lib/other.sh test/bats/unit/guard_spec.bats '  return 7' '  return 0'
  _commit_live
  _run_mr
  _assert_mr_refusal 1 mutation_required_survived \
    "row=script/test/mutation_required/a.tsv:2" id=miss
  [[ "${stderr}" != *mutation_required_pinned* ]] \
    || fail "a failing run reported a row pinned: ${stderr}"
  _no_probe_lines
}

# ── parallel rows ───────────────────────────────────────────────────────────

# why: 168 rows at about 10 s each are run MUTATION_REQUIRED_JOBS at a time
# (default 4); a runner that only runs serially costs every gate the sum.
@test "parallel: two rows under MUTATION_REQUIRED_JOBS=2 overlap (base#1461)" {
  _pin_row a.tsv one
  _row a.tsv two lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2'
  _commit_live
  MUTATION_REQUIRED_JOBS=2 MR_RUNNER_SLEEP=1 _run_mr
  assert_success
  [[ "$(_max_concurrent)" -ge 2 ]] \
    || fail "the rows did not overlap under JOBS=2: $(cat "${MR_RUNNER_LOG}")"
}

# why: The bound holds: JOBS=1 is one row at a time.
@test "parallel: MUTATION_REQUIRED_JOBS=1 runs one row at a time (base#1461)" {
  _pin_row a.tsv one
  _row a.tsv two lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2'
  _commit_live
  MUTATION_REQUIRED_JOBS=1 MR_RUNNER_SLEEP=1 _run_mr
  assert_success
  assert_equal "$(_max_concurrent)" 1
}

# why: A job count that is not 1..99 is refused before anything runs: 0
# would run nothing and report the empty run.
@test "parallel: MUTATION_REQUIRED_JOBS=0 is refused (base#1461)" {
  _pin_row a.tsv one
  _commit_live
  MUTATION_REQUIRED_JOBS=0 _run_mr
  _assert_mr_refusal 2 mutation_required_jobs_invalid jobs=0
  _runner_never_ran
}

# why: The same for a value that is not a number.
@test "parallel: MUTATION_REQUIRED_JOBS=abc is refused (base#1461)" {
  _pin_row a.tsv one
  _commit_live
  MUTATION_REQUIRED_JOBS=abc _run_mr
  _assert_mr_refusal 2 mutation_required_jobs_invalid jobs=abc
  _runner_never_ran
}

# ── the sandbox ─────────────────────────────────────────────────────────────

# why: The probe edits files and runs compose; in the live checkout that
# would race the developer's tree and its compose project. Each row runs in
# its own copy under its own project, derived from the copy's path by the
# copy's test.sh -- an inherited COMPOSE_PROJECT_NAME (the live checkout's)
# is not used, and teardown asks docker about the project the probe used.
@test "sandbox: an inherited COMPOSE_PROJECT_NAME is not the sandbox's project (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  COMPOSE_PROJECT_NAME=live-project _run_mr
  assert_success
  local _seen
  _seen="$(awk '$1 == "start" { print $5 }' "${MR_RUNNER_LOG}" | sort -u)"
  [[ -n "${_seen}" && "${_seen}" != *$'\n'* ]] \
    || fail "the probe's runs did not see one project name: '${_seen}'"
  [[ "${_seen}" != live-project ]] \
    || fail "the sandbox ran under the inherited live project name"
  grep -qF -- "label=com.docker.compose.project=${_seen}" "${MR_DOCKER_LOG}" \
    || fail "teardown did not ask docker about ${_seen}: $(cat "${MR_DOCKER_LOG}")"
  awk '$1 == "start" { print $4 }' "${MR_RUNNER_LOG}" | grep -qvF "${LIVE}" \
    || fail "the probe ran in the live checkout"
}

# why: The probe mounts the sandbox as the container's /source, and a spec
# that drops from root to nobody (an unreadable-file case) must still reach
# the files under it. mktemp -d makes the sandbox 0700, so every such spec
# went red at its baseline and the row was refused.
@test "sandbox: the sandbox directory the probe runs in is mode 755 (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  _run_mr
  assert_success
  assert_equal "$(awk '$1 == "start" { print $6 }' "${MR_RUNNER_LOG}" | sort -u)" 755
}

# why: Two rows in flight at once are two sandboxes and two projects.
@test "sandbox: two rows run under two distinct projects (base#1461)" {
  _pin_row a.tsv one
  _row a.tsv two lib/guard.sh test/bats/unit/guard_spec.bats 'tail=1' 'tail=2'
  _commit_live
  MUTATION_REQUIRED_JOBS=2 _run_mr
  assert_success
  assert_equal "$(awk '$1 == "start" { print $5 }' "${MR_RUNNER_LOG}" | sort -u | wc -l)" 2
}

# why: GIT_DIR / GIT_INDEX_FILE exported by a hook or a wrapper point every
# git call at another repository; the sandbox list must be the live one and
# the other repository must be left alone.
@test "sandbox: an exported GIT_DIR and GIT_INDEX_FILE are not followed (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  git init -q "${S}/decoy"
  printf 'decoy\n' > "${S}/decoy/d"
  git -C "${S}/decoy" add -A
  git -C "${S}/decoy" commit -q --no-verify -m decoy
  local _before
  _before="$(git -C "${S}/decoy" rev-parse HEAD; git -C "${S}/decoy" status --porcelain)"
  GIT_DIR="${S}/decoy/.git" GIT_INDEX_FILE="${S}/decoy/.git/index" _run_mr
  assert_success
  assert_equal "$(git -C "${S}/decoy" rev-parse HEAD; git -C "${S}/decoy" status --porcelain)" "${_before}"
  local -a _lists=( "${MR_DIFF_DIR}"/files.* )
  assert_equal "$(cat "${_lists[0]}")" "$(git -C "${LIVE}" ls-files | LC_ALL=C sort)"
}

# why: A sandbox build step that fails leaves a partial copy; probing it
# would measure a different tree. Every step fails closed.
@test "sandbox: a failing archive step fails the row and runs no probe (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "${S}/bin/tar"
  chmod +x "${S}/bin/tar"
  _run_mr
  _assert_mr_refusal 1 mutation_required_sandbox_failed \
    "row=script/test/mutation_required/a.tsv:1" step=archive
  _runner_never_ran
}

# why: A container of the sandbox's project still running after the probe
# is a run that may still write; the sandbox is kept, named, and the row
# fails rather than passes.
@test "sandbox: a container still running at teardown holds the sandbox and fails the row (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  MR_DOCKER_PS=c0ffee _run_mr
  _assert_mr_refusal 1 mutation_required_sandbox_held
  local _path
  _path="$(log_event_line mutation_required_sandbox_held "${stderr}" \
    | grep -oE '"path":"[^"]*"' | cut -d'"' -f4)"
  [[ -n "${_path}" && -d "${_path}" ]] \
    || fail "the held sandbox is not kept: '${_path}'"
  [[ "${stderr}" != *mutation_required_pinned* ]] || fail "a held row was reported pinned"
  _no_probe_lines
}

# ── signals ─────────────────────────────────────────────────────────────────

# _signal_while_running <signal> -- start the driver under job control (a
# background job of a non-interactive shell otherwise starts with INT
# ignored), wait until the runner is in flight, signal the DRIVER only, and
# reap it. Sets SIG_RC.
_signal_while_running() {
  local _sig="${1}" _pid _i
  set -m
  env PATH="${S}/bin:${PATH}" LOG_FORMAT=json TMPDIR="${S}/tmp" \
    MUTATION_PROBE_RUNNER="${S}/runner" MR_RUNNER_SLEEP=30 \
    bash "${MR}" --root "${LIVE}" > "${S}/out" 2> "${S}/err" &
  _pid=$!
  set +m
  for (( _i = 0; _i < 300; _i++ )); do
    grep -q '^start' "${MR_RUNNER_LOG}" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^start' "${MR_RUNNER_LOG}" 2>/dev/null \
    || { kill -KILL "${_pid}" 2>/dev/null; fail "the runner never started: $(cat "${S}/err")"; }
  kill -s "${_sig}" "${_pid}"
  SIG_RC=0
  wait "${_pid}" || SIG_RC=$?
}

# why: Ctrl-C mid-run must stop the probe and its runner, not leave a suite
# running in a sandbox, and must publish no verdict.
@test "signals: INT during a probe stops every child and publishes no verdict (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  local _status_before
  _status_before="$(git -C "${LIVE}" status --porcelain)"
  _signal_while_running INT
  assert_equal "${SIG_RC}" 130
  stderr="$(cat "${S}/err")"
  assert_logged_event mutation_required_interrupted signal=INT
  [[ "${stderr}" != *mutation_required_pinned* && "${stderr}" != *mutation_required_survived* ]] \
    || fail "an interrupted run published a verdict: ${stderr}"
  local _rp
  _rp="$(awk '$1 == "start" { print $3 }' "${MR_RUNNER_LOG}")"
  sleep 1
  run kill -0 "${_rp}"
  assert_failure
  assert_equal "$(git -C "${LIVE}" status --porcelain)" "${_status_before}"
}

# why: TERM, as a CI cancel sends it, is the same stop with status 143.
@test "signals: TERM during a probe stops every child and exits 143 (base#1461)" {
  _pin_row a.tsv kill
  _commit_live
  _signal_while_running TERM
  assert_equal "${SIG_RC}" 143
  stderr="$(cat "${S}/err")"
  assert_logged_event mutation_required_interrupted signal=TERM
  local _rp
  _rp="$(awk '$1 == "start" { print $3 }' "${MR_RUNNER_LOG}")"
  sleep 1
  run kill -0 "${_rp}"
  assert_failure
}

# ── --apply, the one way a row edits its subject ────────────────────────────

# why: A row is data, applied only by this fixed command; an <old> that is
# absent changes nothing and says so.
@test "--apply: an old that does not occur leaves the file unchanged and fails (base#1461)" {
  cp "${LIVE}/lib/guard.sh" "${S}/g.sh"
  printf 'nope' > "${S}/old"
  printf 'x' > "${S}/new"
  run bash -c "cd '${S}' && bash '${MR}' --apply g.sh old new"
  assert_equal "${status}" 1
  cmp -s "${LIVE}/lib/guard.sh" "${S}/g.sh" || fail "--apply changed the file"
}

# why: Two occurrences are a guess, refused the same way.
@test "--apply: an old that occurs twice leaves the file unchanged and fails (base#1461)" {
  cp "${LIVE}/lib/guard.sh" "${S}/g.sh"
  printf '  return 1' > "${S}/old"
  printf '  return 0' > "${S}/new"
  run bash -c "cd '${S}' && bash '${MR}' --apply g.sh old new"
  assert_equal "${status}" 1
  cmp -s "${LIVE}/lib/guard.sh" "${S}/g.sh" || fail "--apply changed the file"
}

# why: Overlapping occurrences are two occurrences: --apply refuses them the
# way validation does, so neither path picks one.
@test "--apply: an old whose occurrences overlap leaves the file unchanged and fails (base#1461)" {
  printf 'aaa\n' > "${S}/f"
  cp "${S}/f" "${S}/want"
  printf 'aa' > "${S}/old"
  printf 'b' > "${S}/new"
  run bash -c "cd '${S}' && bash '${MR}' --apply f old new"
  assert_equal "${status}" 1
  cmp -s "${S}/want" "${S}/f" || fail "--apply changed the file"
}

# why: --apply is the one edit path; it refuses a NUL-bearing subject itself
# rather than rewriting it without the NUL.
@test "--apply: a subject that carries a NUL byte is left unchanged and fails (base#1461)" {
  printf 'guard=1\0tail\n' > "${S}/f"
  cp "${S}/f" "${S}/want"
  printf 'guard=1' > "${S}/old"
  printf 'guard=0' > "${S}/new"
  run bash -c "cd '${S}' && bash '${MR}' --apply f old new"
  assert_equal "${status}" 1
  cmp -s "${S}/want" "${S}/f" || fail "--apply changed the file"
}

# why: The edit is byte-exact -- quotes, $( ), backslashes and a missing
# final newline survive -- and the file keeps its mode.
@test "--apply: the replacement is byte-exact and keeps the mode (base#1461)" {
  printf '%s\n%s\n%s' 'a="$(x)" \\ '"'q'"'' 'KEEP \t me' 'last-no-newline' > "${S}/f"
  chmod 751 "${S}/f"
  printf '%s' 'KEEP \t me' > "${S}/old"
  printf '%s' 'kept "$(y)" \\n' > "${S}/new"
  run bash -c "cd '${S}' && bash '${MR}' --apply f old new"
  assert_success
  printf '%s\n%s\n%s' 'a="$(x)" \\ '"'q'"'' 'kept "$(y)" \\n' 'last-no-newline' > "${S}/want"
  cmp "${S}/want" "${S}/f" || fail "--apply did not produce the exact bytes"
  assert_equal "$(stat -c %a "${S}/f")" 751
}
