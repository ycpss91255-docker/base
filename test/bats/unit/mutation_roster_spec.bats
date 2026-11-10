#!/usr/bin/env bats
#
# mutation_roster_spec.bats -- the committed required-kill roster,
# script/test/mutation_required/ (base#1461), read as data: every row is
# in the five-column contract, applies to exactly one region of its
# subject, passes the runner's own validation, and is dealt and weighed
# for the mutation-roster matrix (base#1571).
#
# why a spec of its own: every case here reads a committed row against its
# subject's bytes in /source. A probe of a row mutates that subject in its
# sandbox's /source, so under the row's mutant <old> is no longer in the
# subject and these cases go red whatever the row's own test does. Measured
# at 8c81f155, when they were cases of mutation_required_spec.bats: probing
# s1571.tsv's deal-by-index and slot-reset-hard rows there turned these
# four cases red beside the one behaviour test each row names, so either
# row read PINNED with that test gone (base#1571). Here no row can name
# them: the last case refuses a committed row whose spec is this file.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  MR="/source/script/test/drivers/mutation_required.sh"
  S="${BATS_TEST_TMPDIR}"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount.
  cd "${S}"
  unset COMPOSE_PROJECT_NAME MUTATION_REQUIRED_JOBS MUTATION_REQUIRED_PROBE \
    GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE PER_TEST_TIMEOUT
}

# ── fixtures ────────────────────────────────────────────────────────────────

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
      [[ "$(awk -F'\t' '{ print NF }' <<< "${_line}")" == [56] ]] \
        || fail "$(basename "${_f}"): row '${_id}' is not <id> TAB <subject> TAB <spec> TAB <old> TAB <new> [TAB <witness>]: ${_line}"
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
  (( _n >= 166 )) || fail "the roster has ${_n} rows; S1a's 2 seeds and the 164 of S1b, S1c, S1d, S1g and S1h are 166"
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
  for _c in s1b:24 s1c:117 s1d:38 s1g:2 s1h:12 s1a:2; do
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

# why: A row with a witness runs its unmutated baseline and its mutated
# pass under that filter alone, so its cost is its own tests and no other
# row's (base#1582). That holds only if every committed row has a witness,
# and a witness that selects all of its spec's tests (empty, '.*') or none
# of them (a renamed @test) brings the whole-spec pass back. So every row's
# sixth column, read as the bats name regex it is, matches at least one and
# fewer than all of the @test names grepped from its spec's own lines.
@test "roster: every committed row carries a witness that selects some but not all of its spec's tests (base#1582)" {
  local _f _line _id _spec _wit _name _hit _all _bad=""
  for _f in /source/script/test/mutation_required/*.tsv; do
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      [[ -z "${_line}" || "${_line}" == '#'* ]] && continue
      _id="$(basename "${_f}" .tsv):$(cut -f1 <<< "${_line}")"
      _spec="$(cut -f3 <<< "${_line}")"
      _wit="$(awk -F'\t' '{ print $6 }' <<< "${_line}")"
      if [[ -z "${_wit}" ]]; then
        _bad+="${_id}: no witness"$'\n'
        continue
      fi
      _hit=0 _all=0
      while IFS= read -r _name; do
        _all=$(( _all + 1 ))
        [[ "${_name}" =~ ${_wit} ]] && _hit=$(( _hit + 1 ))
      done < <(sed -nE 's/^@test "(.*)" \{$/\1/p' "/source/${_spec}")
      (( _hit >= 1 && _hit < _all )) \
        || _bad+="${_id}: witness '${_wit}' selects ${_hit} of ${_all} tests of ${_spec}"$'\n'
    done < "${_f}"
  done
  [[ -z "${_bad}" ]] || fail "rows without a narrowing witness:"$'\n'"$(head -n 5 <<< "${_bad}")"$'\n'"($(grep -c . <<< "${_bad}") rows)"
}

# ── the committed roster's shards ───────────────────────────────────────────

# why: The roster leaves lint-static for the mutation-roster matrix, and
# its rows are dealt by recorded seconds, not by index (base#1571). The set
# of rows a PR run probes must still be the whole roster, each row once,
# and a spec has to compare the union of the shard row lists with the full
# roster to show it. `--check --shard <n>/<total>` validates every row,
# probes nothing, and logs one mutation_required_row_dealt line per row of
# shard <n> (row=<file>:<line>). Over the committed roster, with the shard
# count of self-test.yaml's mutation-roster matrix, the union of those
# lists is every non-blank, non-`#` line of every roster file, read here
# straight from the TSVs, and no row is in two shards.
@test "shards: over the committed roster the mutation-roster shards' row lists are every row, each once (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _wf=/source/.github/workflows/self-test.yaml _t _k _want _got
  _t="$(yq '.jobs.mutation-roster.strategy.matrix.shard | length' "${_wf}")"
  [[ "${_t}" =~ ^[1-9][0-9]*$ ]] && (( _t >= 2 )) \
    || fail "self-test.yaml's mutation-roster matrix has '${_t}' shards"
  _want="$(cd /source && LC_ALL=C awk '
    FNR == 1 { f = FILENAME }
    $0 != "" && substr($0, 1, 1) != "#" { print f ":" FNR }
  ' script/test/mutation_required/*.tsv | LC_ALL=C sort)"
  [[ -n "${_want}" ]] || fail "the committed roster holds no row"
  _got=""
  for (( _k = 1; _k <= _t; _k++ )); do
    run --separate-stderr env LOG_FORMAT=json bash "${MR}" --check --root /source --shard "${_k}/${_t}"
    assert_success
    _got+="$(grep -F '"body":"mutation_required_row_dealt"' <<< "${stderr}" \
      | sed -n 's/.*"row":"\([^"]*\)".*/\1/p')"$'\n'
  done
  _got="$(grep -v '^$' <<< "${_got}" | LC_ALL=C sort || true)"
  [[ -n "${_got}" ]] || fail "--check --shard logged no mutation_required_row_dealt line for any of the ${_t} shards"
  local _dups
  _dups="$(uniq -d <<< "${_got}")"
  [[ -z "${_dups}" ]] || fail "rows dealt to more than one shard:"$'\n'"${_dups}"
  assert_equal "${_got}" "${_want}"
}

# why: --shard deals by script/test/mutation_required/seconds.txt, and a
# row the file does not name weighs 0 (base#1571), so a shard balanced on
# a file that misses rows is balanced on a guess, not on a measurement.
# The committed file must name every committed roster row -- the pair
# <roster file basename> TAB <id>, read here straight from the TSVs --
# exactly once, each with a positive number of seconds, and no row that
# the roster does not hold.
@test "shards: the committed seconds.txt weighs every committed roster row once, each with positive seconds (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _sec=/source/script/test/mutation_required/seconds.txt _want _got _bad _dups
  [[ -f "${_sec}" ]] \
    || fail "the committed roster has no seconds.txt, so --shard deals every row at weight 0"
  _want="$(cd /source/script/test/mutation_required && LC_ALL=C awk -F '\t' '
    $0 != "" && substr($0, 1, 1) != "#" { print FILENAME "\t" $1 }
  ' ./*.tsv | sed 's|^\./||' | LC_ALL=C sort)"
  [[ -n "${_want}" ]] || fail "the committed roster holds no row"
  _bad="$(LC_ALL=C awk -F '\t' 'NF != 3 || $3 !~ /^[0-9]+(\.[0-9]+)?$/ || $3 + 0 <= 0' "${_sec}")"
  [[ -z "${_bad}" ]] || fail "seconds.txt lines that are not <file> TAB <id> TAB <positive seconds>:"$'\n'"${_bad}"
  _got="$(cut -f1,2 "${_sec}" | LC_ALL=C sort)"
  _dups="$(uniq -d <<< "${_got}")"
  [[ -z "${_dups}" ]] || fail "seconds.txt weighs these rows more than once:"$'\n'"${_dups}"
  assert_equal "${_got}" "${_want}"
}

# why: The owner's target is at most 5 minutes per CI job (base#1571), and
# the roster's matrix is to be balanced by the measured per-row times so
# that each mutation-roster leg fits it. For every leg k/N of
# self-test.yaml's mutation-roster matrix, the rows `--check --shard k/N`
# deals are looked up in the committed seconds.txt (each row=<file>:<line>
# is read back from its TSV line to its <file> TAB <id>), summed, and
# spread over the leg's worker slots (MUTATION_REQUIRED_JOBS on the job,
# else the driver's documented default of 4). That leg budget must be at
# most 300 seconds; a matrix too small for the measured roster fails here.
@test "shards: every mutation-roster leg's measured seconds over its worker slots fit 300 s (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _wf=/source/.github/workflows/self-test.yaml
  local _sec=/source/script/test/mutation_required/seconds.txt _t _k _jobs _rows _budget _over=""
  [[ -f "${_sec}" ]] || fail "the committed roster has no seconds.txt"
  _t="$(yq '.jobs.mutation-roster.strategy.matrix.shard | length' "${_wf}")"
  [[ "${_t}" =~ ^[1-9][0-9]*$ ]] && (( _t >= 2 )) \
    || fail "self-test.yaml's mutation-roster matrix has '${_t}' shards"
  _jobs="$(yq '.jobs.mutation-roster.env.MUTATION_REQUIRED_JOBS // 4' "${_wf}")"
  [[ "${_jobs}" =~ ^[1-9][0-9]*$ ]] || fail "mutation-roster sets MUTATION_REQUIRED_JOBS to '${_jobs}'"
  for (( _k = 1; _k <= _t; _k++ )); do
    run --separate-stderr env LOG_FORMAT=json bash "${MR}" --check --root /source --shard "${_k}/${_t}"
    assert_success
    _rows="$(grep -F '"body":"mutation_required_row_dealt"' <<< "${stderr}" \
      | sed -n 's/.*"row":"\([^"]*\)".*/\1/p')"
    [[ -n "${_rows}" ]] || fail "--check --shard ${_k}/${_t} dealt no row"
    printf '%s\n' "${_rows}" > "${BATS_TEST_TMPDIR}/dealt"
    _budget="$(cd /source && LC_ALL=C awk -F '\t' -v jobs="${_jobs}" '
      FILENAME ~ /dealt$/ { split($0, r, ":"); want[r[1] FS r[2]] = 1; next }
      FILENAME ~ /seconds\.txt$/ { sec[$1 FS $2] = $3 + 0; next }
      (FILENAME FS FNR) in want { n = FILENAME; sub(/.*\//, "", n); s += sec[n FS $1] }
      END { printf "%.1f\n", s / jobs }
    ' "${BATS_TEST_TMPDIR}/dealt" "${_sec}" script/test/mutation_required/*.tsv)"
    awk -v b="${_budget}" 'BEGIN { exit !(b + 0 <= 300) }' \
      || _over+="leg ${_k}/${_t}: ${_budget} s over ${_jobs} worker slots"$'\n'
  done
  [[ -z "${_over}" ]] \
    || fail "mutation-roster legs whose measured roster time exceeds 300 s:"$'\n'"${_over}"
}

# why: A row's spec is what the probe runs against that row's mutant, and
# every other case in this file reads the committed roster against its
# subject's bytes, so a row naming this file would read PINNED from those
# cases whatever its own test does. Read straight from the TSVs.
@test "roster: no committed row names this spec, which reads every row against its subject (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _self _bad
  _self="test/bats/unit/$(basename "${BATS_TEST_FILENAME}")"
  _bad="$(cd /source/script/test/mutation_required && LC_ALL=C awk -F '\t' -v self="${_self}" '
    $0 != "" && substr($0, 1, 1) != "#" && $3 == self { print FILENAME ": " $1 }
  ' ./*.tsv)"
  [[ -z "${_bad}" ]] || fail "rows probed under ${_self}:"$'\n'"${_bad}"
}
