#!/usr/bin/env bats
#
# Executable tests for `assert_spec_subject` (test/bats/unit/test_helper.bash),
# the fail-closed replacement for the `[[ -f "${SUBJECT}" ]] || skip` opening
# that 54 guards across this suite used to carry.
#
# Why this file exists at all: those guards were never tested against their
# own failure mode, which is precisely how a renamed workflow could turn 52
# assertions into `ok ... # skip` and still exit 0. The helper now decides
# fail-vs-skip for every one of them, so the decision itself needs a test --
# otherwise the fix reproduces the defect it replaces, one level up.
#
# Strategy: the outcome under test is a bats OUTCOME (not-ok vs ok-with-skip),
# which cannot be observed from inside the test that produces it. So each case
# writes a one-test spec into BATS_TEST_TMPDIR and runs `bats` over it,
# asserting on the TAP the inner run emits.
#
# The generated `@test` line is INDENTED on purpose: bats accepts leading
# whitespace, and the doc-count sync counts `^@test` per file, so a
# column-0 heredoc line would be counted as a test of this file and would
# earn a phantom catalogue row in doc/test/unit.md.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  INNER="${BATS_TEST_TMPDIR}/inner_spec.bats"

  # The shape a fail-open existence guard takes, over five axes: the
  # bracket form (`[[ ]]`, `[ ]`, `test`), the negation (none, a `!` inside
  # the brackets, a `!` in front of them -- a negated check answers with
  # `&&` and says exactly the same thing), the OPERATOR, whether the answer
  # is bare or braced, and whether it sits on the same line as the test.
  #
  # The operator axis is NOT enumerated, and a review forced that: the
  # pattern used to name `-[defs]`, a hand-picked subset of a set bash
  # owns. `-L` -- the natural guard for this repo's init.sh-created wrapper
  # symlinks -- plus `-h`, `-x`, `-r`, `-w`, `-S` were each one keystroke
  # from unenforced, which is the same guard-narrower-than-its-name defect
  # this file exists to close. A one-letter unary operator in the position
  # a file test occupies is matched whichever letter it is. A two-letter
  # comparison (`-eq`, `-ne`) is excluded by the trailing space, and is not
  # an existence check anyway.
  #
  # The scan reads LOGICAL lines, not physical ones, which is why it is the
  # function below and not a bare `grep -rnE`. Every surviving `|| skip` in
  # this suite is written as a test, a trailing backslash, and the answer
  # on the next line (`grep -rn -B1 '^[[:space:]]*|| skip' test/bats/`), so
  # a line-anchored pattern was blind to the house spelling -- the one a
  # new guard is most likely to be written in.
  #
  # OVER-approximating on purpose, and NOT a closed set: an
  # `if ... then skip; fi` across three lines, a helper that hides the
  # test, and a test operator arriving through a variable are all outside
  # it. The cases below plant every combination of the five axes so the
  # coverage this pattern DOES claim is proven, and plant a sample of what
  # it misses so nothing claims the rest.
  #
  # Held in one variable so the scan and the two cases that prove what it
  # can and cannot see cannot drift apart.
  GUARD_RE='^[[:space:]]*!?[[:space:]]*(\[\[|\[|test)[[:space:]]+!?[[:space:]]*-[[:alpha:]][[:space:]].*(\|\||&&)[[:space:]]*(\{[[:space:]]*)?skip'

  # Where the scan looks, and the floor the population may not fall below.
  SPEC_TREE=/source/test/bats
  SPEC_TREE_FLOOR=60

  # A CALL to either subject guard, at the start of a line: the population
  # the changelog's figure is measured over. `assert_spec_subject` also
  # appears mid-line in a message this file asserts on, which is why the
  # anchor is not optional.
  GUARD_CALL_RE='^[[:space:]]*assert_spec_subject(_dir)?[[:space:]]'
}

# _fail_open_guard_scan <tree>
#   Every fail-open existence guard under <tree>, one per line as
#   `<file>:<line>: <logical line>`. LOGICAL: a statement continued with a
#   trailing backslash is rejoined before it is matched, so the two-line
#   form every surviving skip in this suite uses is one statement here too.
#
#   It answers like grep ON PURPOSE, because the invariant turns on the
#   difference: 0 = guards found, 1 = scanned and found none, 2 = COULD NOT
#   SCAN. A missing tree, or one holding no spec files, reports "found
#   nothing" exactly like a clean tree and `assert_failure` accepts both --
#   pointing the old scan at a path that does not exist left this spec
#   passing 5/5. Both of those are 2 here, and a case reaches each.
_fail_open_guard_scan() {
  local _tree="${1:?BUG: _fail_open_guard_scan expects a tree}"
  [[ -d "${_tree}" ]] || return 2

  local -a _files=()
  local _f
  while IFS= read -r _f; do
    if [[ -n "${_f}" ]]; then _files+=("${_f}"); fi
  done < <(find "${_tree}" -type f -name '*.bats' | sort)
  [[ "${#_files[@]}" -gt 0 ]] || return 2

  # The pattern travels in the ENVIRONMENT, not in `awk -v`: a -v
  # assignment processes escape sequences, so `\[` would reach the regex
  # engine as a bare `[` and the whole pattern would stop compiling.
  local _hits
  _hits="$(GUARD_RE="${GUARD_RE}" awk '
    BEGIN { _re = ENVIRON["GUARD_RE"] }
    FNR == 1 { _buf = ""; _start = 0 }
    {
      _line = $0
      if (_buf == "") { _start = FNR; _buf = _line }
      else { sub(/^[[:space:]]+/, "", _line); _buf = _buf " " _line }
      if (_buf ~ /\\$/) { sub(/[[:space:]]*\\$/, "", _buf); next }
      if (_buf ~ _re) { print FILENAME ":" _start ": " _buf }
      _buf = ""
    }
  ' "${_files[@]}")"

  [[ -n "${_hits}" ]] || return 1
  printf '%s\n' "${_hits}"
}

# _write_inner <path-argument-literal> [assertion-function]
#   Emit a one-test spec whose body is a single subject assertion on the
#   given (already-quoted) path expression. The function defaults to the
#   file guard; the directory guard is driven through the same generator so
#   both are proved against the same bats OUTCOME, not against two shapes.
_write_inner() {
  local _arg="${1:?BUG: _write_inner expects a path expression}"
  local _fn="${2:-assert_spec_subject}"
  cat > "${INNER}" <<INNER_EOF
#!/usr/bin/env bats
setup() {
  load "/source/test/bats/unit/test_helper"
}

  @test "inner: subject present" {
    ${_fn} ${_arg} "the artifact the inner spec asserts on"
  }
INNER_EOF
}

@test "assert_spec_subject: a present subject lets the test run to completion" {
  local _subject="${BATS_TEST_TMPDIR}/present.yaml"
  printf 'name: anything\n' > "${_subject}"
  _write_inner "\"${_subject}\""

  run bats "${INNER}"
  assert_success
  assert_output --partial "ok 1 inner: subject present"
  refute_output --partial "# skip"
}

@test "assert_spec_subject: a missing subject FAILS the test, it does not skip it" {
  # The whole point. A skip here is the defect: it reports a green run for a
  # spec that asserted nothing, which is indistinguishable from the artifact
  # having been deleted or renamed with nobody noticing.
  _write_inner "\"${BATS_TEST_TMPDIR}/absent.yaml\""

  run bats "${INNER}"
  assert_failure
  assert_output --partial "not ok 1 inner: subject present"
  refute_output --partial "# skip"
}

@test "assert_spec_subject: the failure names the missing path and what it was" {
  _write_inner "\"${BATS_TEST_TMPDIR}/absent.yaml\""

  run bats "${INNER}"
  assert_failure
  assert_output --partial "${BATS_TEST_TMPDIR}/absent.yaml"
  assert_output --partial "the artifact the inner spec asserts on"
}

@test "assert_spec_subject: refuses an empty path rather than passing vacuously" {
  # A guard called with an unset variable must be a loud bug, not a silent
  # pass -- `[[ -f "" ]]` is false, so an unguarded version would have
  # reported a missing subject for a caller typo instead of naming it.
  _write_inner '""'

  run bats "${INNER}"
  assert_failure
  assert_output --partial "BUG: assert_spec_subject expects a path"
}

@test "assert_spec_subject_dir: a present directory lets the test run to completion" {
  local _subject="${BATS_TEST_TMPDIR}/present_tree"
  mkdir -p "${_subject}"
  _write_inner "\"${_subject}\"" assert_spec_subject_dir

  run bats "${INNER}"
  assert_success
  assert_output --partial "ok 1 inner: subject present"
  refute_output --partial "# skip"
}

@test "assert_spec_subject_dir: a missing directory FAILS the test, it does not skip it" {
  # Same contract as the file guard, and the same reason: a tracked tree
  # (`.github/workflows/`) is present in every mode this suite has, so its
  # absence is the rename nobody noticed, never a context. The two live
  # `[[ -d "${WF_DIR}" ]] || skip` guards this replaces answered that with
  # a green run over an empty spec.
  _write_inner "\"${BATS_TEST_TMPDIR}/absent_tree\"" assert_spec_subject_dir

  run bats "${INNER}"
  assert_failure
  assert_output --partial "not ok 1 inner: subject present"
  refute_output --partial "# skip"
}

@test "assert_spec_subject_dir: a FILE at the path is not the directory it asked for" {
  # Why the guard is `-d` and not a widened `-e`: a path that turned from a
  # directory into a file is itself one of the moves these guards exist to
  # catch, and `-e` would answer it with a pass.
  local _subject="${BATS_TEST_TMPDIR}/tree_became_a_file"
  printf 'not a directory\n' > "${_subject}"
  _write_inner "\"${_subject}\"" assert_spec_subject_dir

  run bats "${INNER}"
  assert_failure
  assert_output --partial "${_subject}"
}

@test "no spec opens with a fail-open '|| skip' existence guard" {
  # The repo-wide invariant this helper exists to hold. An existence check
  # answered with `skip` cannot tell "absent by design" from "renamed and
  # nobody noticed"; the remaining skips in the suite guard host / image
  # CAPABILITIES (command -v ...) or a mode-gated fixture, never the presence
  # of a tracked artifact, and each states its reason at the guard.
  #
  # An invariant that scans a tree has the very failure mode it is looking
  # for, so both halves are pinned. FIRST that the population is really
  # there: a scan of nothing reports "no matches" exactly like a clean tree.
  run bash -c "set -o pipefail; find ${SPEC_TREE} -type f -name '*.bats' | wc -l | tr -d ' '"
  assert_success
  assert [ "${output}" -ge "${SPEC_TREE_FLOOR}" ]

  # SECOND that the scan itself ran: 1 is "scanned, matched nothing" and 2
  # is "could not scan", and only the first is this invariant holding.
  # `assert_output` first so a failure prints the guards it found, file and
  # line; the status pin still runs, and neither is weakened by the order.
  run _fail_open_guard_scan "${SPEC_TREE}"
  assert_output ""
  assert_equal "${status}" 1
}

@test "a scan that examined nothing answers 2, not 1" {
  # What keeps the invariant above from passing vacuously, reached rather
  # than argued. Both shapes below produce the same empty output as a clean
  # tree, and `assert_failure` would have accepted either.
  run _fail_open_guard_scan "${SPEC_TREE}-does-not-exist"
  assert_equal "${status}" 2

  # The second shape is the one a path typo actually produces once the tree
  # exists: a directory that is there and holds no spec file.
  local _empty="${BATS_TEST_TMPDIR}/empty_tree"
  mkdir -p "${_empty}"
  run _fail_open_guard_scan "${_empty}"
  assert_equal "${status}" 2
}

# _guard_spelling <bracket> <negation> <operator> <answer> <continuation>
#   Render ONE fail-open existence guard, in the spelling named by the five
#   axes, as bats source. Rendered rather than listed so the case below
#   cannot fall behind the pattern one variant at a time.
#
#   `printf` rather than a heredoc, and assembled from pieces rather than
#   written out: a literal guard line in THIS file would sit under the tree
#   the invariant above scans, and that invariant would then fail on its own
#   fixture. Every line here opens with `printf`, a case label or a quote,
#   so no line of the generator can match the pattern the generator feeds.
_guard_spelling() {
  local _bracket="${1:?BUG: _guard_spelling expects a bracket form}"
  local _negation="${2:?BUG: _guard_spelling expects a negation form}"
  local _operator="${3:?BUG: _guard_spelling expects an operator}"
  local _answer="${4:?BUG: _guard_spelling expects an answer form}"
  local _continuation="${5:?BUG: _guard_spelling expects a continuation form}"
  local _open _close _outer='' _inner='' _joiner='||' _skip _fmt

  case "${_bracket}" in
    double) _open='[['   ; _close=' ]]' ;;
    single) _open='['    ; _close=' ]'  ;;
    builtin) _open='test'; _close=''    ;;
    *) fail "BUG: unknown bracket form ${_bracket}" ;;
  esac

  # A negated existence check answers with `&&` instead of `||`; both say
  # "skip when the subject is missing", which is the defect either way.
  case "${_negation}" in
    plain) : ;;
    inner) _inner='! '; _joiner='&&' ;;
    outer) _outer='! '; _joiner='&&' ;;
    *) fail "BUG: unknown negation form ${_negation}" ;;
  esac

  # A brace group is the same answer with a place to put a second
  # statement, and reviewers write it whenever a message is built first.
  case "${_answer}" in
    bare)   _skip='skip "gone"' ;;
    braced) _skip='{ skip "gone"; }' ;;
    *) fail "BUG: unknown answer form ${_answer}" ;;
  esac

  # Where the answer sits relative to the test. `wrapped` is not an exotic
  # variant: it is the spelling EVERY surviving skip in this suite uses, so
  # a scan that cannot see it cannot see the house style.
  case "${_continuation}" in
    inline)  _fmt='  %s%s %s-%s "${WF}"%s %s %s\n' ;;
    wrapped) _fmt='  %s%s %s-%s "${WF}"%s \\\n    %s %s\n' ;;
    *) fail "BUG: unknown continuation form ${_continuation}" ;;
  esac

  # shellcheck disable=SC2059  # _fmt is this function's own literal
  printf "${_fmt}" "${_outer}" "${_open}" "${_inner}" "${_operator}" \
    "${_close}" "${_joiner}" "${_skip}"
}

@test "the fail-open guard scan sees each spelling of the check it claims to cover" {
  # The other way the invariant above goes quietly blind: it holds because
  # its PATTERN misses the guard, not because no guard exists. Reintroducing
  # a real fail-open guard as `[ -f "${WF}" ] || skip "gone"` left it green,
  # and so did a negated form, a `-L` on a wrapper symlink, and the two-line
  # form every surviving skip in this suite is written in.
  #
  # The spellings are GENERATED from five axes -- bracket form, negation,
  # operator, answer form, continuation -- rather than listed, so a spelling
  # this scan is claimed to cover cannot go untested by being left off a
  # list. The OPERATOR axis is the whole alphabet in both cases rather than
  # a chosen handful of file tests: bash owns that set, so any subset kept
  # here is a roster that decays, and the pattern accepts a one-letter unary
  # operator without asking which letter it got.
  #
  # NOT exhaustive, and this case does not claim to be. What the scan misses
  # is planted in the case below rather than described here.
  local _planted="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "${_planted}"
  local _expected="${BATS_TEST_TMPDIR}/expected.txt"
  : > "${_expected}"

  local _bracket _negation _operator _answer _continuation _name
  local _planted_count=0
  for _bracket in double single builtin; do
    for _negation in plain inner outer; do
      for _operator in {a..z} {A..Z}; do
        for _answer in bare braced; do
          for _continuation in inline wrapped; do
            _name="${_bracket}_${_negation}_${_operator}_${_answer}_${_continuation}"
            _guard_spelling "${_bracket}" "${_negation}" "${_operator}" \
              "${_answer}" "${_continuation}" > "${_planted}/${_name}.bats"
            printf '%s\n' "${_planted}/${_name}.bats" >> "${_expected}"
            _planted_count=$(( _planted_count + 1 ))
          done
        done
      done
    done
  done

  # Non-vacuity: a loop that planted nothing would report every spelling
  # covered, which is this file's own subject matter one level up.
  [ "${_planted_count}" -eq 1872 ] || fail \
    "planted ${_planted_count} spellings, expected 1872 (3 bracket forms x 3 negations x 52 operators x 2 answer forms x 2 continuations)"

  # ONE scan over the whole planted tree, compared as a SET. A per-file loop
  # stops at the first spelling that escapes and says nothing about the
  # rest, and "which spellings escape" is the answer this case exists to
  # give -- the widening it forced was found 900 spellings at a time.
  run _fail_open_guard_scan "${_planted}"
  assert_equal "${status}" 0
  local _seen="${BATS_TEST_TMPDIR}/seen.txt"
  printf '%s\n' "${output}" | cut -d: -f1 | sort -u > "${_seen}"

  local _missed_count _missed
  _missed_count="$(comm -23 <(sort "${_expected}") "${_seen}" | wc -l)"
  _missed="$(comm -23 <(sort "${_expected}") "${_seen}" | head -20)"
  [ "${_missed_count}" -eq 0 ] || fail \
    "the scan misses ${_missed_count} of the ${_planted_count} spellings it claims to cover, so the repo-wide invariant would stay green with one of those guards in the tree. First 20:
${_missed}"
}

@test "the fail-open guard scan is an over-approximation, not a closed set" {
  # The disclosure, made executable, because a comment saying "not a closed
  # set" is exactly what the `-[defs]` pattern carried while a reviewer read
  # the operator axis as derived. What is planted here is a SAMPLE of an
  # open set, and each sample is a decision rather than an oversight:
  #
  #   - THE THREE-LINE `if`. Eight legitimate mode gates in this suite are
  #     written that way -- `command -v docker`, `[[ ! -S ... docker.sock ]]`
  #     -- and no shape separates a capability gate from a fail-open
  #     artifact guard once both are spelled as an `if`. Scanning it would
  #     cry wolf on correct code, which is the one failure mode that gets a
  #     scan deleted instead of widened.
  #   - A HELPER THAT HIDES THE TEST. The test and the skip move inside a
  #     function, and nothing at the call site names either. No pattern over
  #     this tree reaches that; only reading the helper does.
  #   - THE OPERATOR THROUGH A VARIABLE, which is the general form of the
  #     axis widened above: the pattern matches a literal `-x`, so a test
  #     assembled at runtime is invisible however wide the letter class is.
  #
  # What stands behind the gap is not this scan: it is `assert_spec_subject`
  # being the only idiom in the tree for a tracked subject, so a guard in
  # any of these shapes is a new idiom in review, not a variant of an
  # existing one.
  #
  # Widening the pattern to catch one of these is a decision to state here,
  # not a silent regex edit -- and the samples are examples drawn from an
  # open set, never the set.
  local _planted="${BATS_TEST_TMPDIR}/planted_blind"
  mkdir -p "${_planted}"

  local _spelling _fmt
  while IFS='|' read -r _spelling _fmt; do
    [[ -n "${_spelling}" ]] || continue
    # shellcheck disable=SC2059  # the fixture text is the format on purpose
    printf "${_fmt}\n" > "${_planted}/${_spelling}.bats"
  done <<'BLIND'
three_line_if|  if [ ! -f "${WF}" ]; then\n    skip "gone"\n  fi
helper_hides_the_test|  _skip_unless_present "${WF}"
operator_in_a_variable|  [ "${_op}" "${WF}" ] || skip "gone"
BLIND

  run _fail_open_guard_scan "${_planted}"
  assert_output ""
  assert_equal "${status}" 1
}

# _guarded_test_count
#   How many tests in the spec tree cannot pass when the artifact they
#   assert on is missing: a test whose body calls one of the two subject
#   guards, plus EVERY test in a file whose setup() calls one, since the
#   guard then runs before each of them.
#
#   DERIVED from the tree on every run rather than kept as a number next to
#   the claim -- a spec file added tomorrow is counted without editing
#   anything here, which is the whole reason the figure is checkable at all.
_guarded_test_count() {
  local _file _total=0 _n
  while read -r _file; do
    [[ -n "${_file}" ]] || continue
    _n="$(awk '
      /^setup\(\)/ { in_setup = 1 }
      in_setup && /^}/ { in_setup = 0 }
      in_setup && /^[[:space:]]*assert_spec_subject(_dir)?[[:space:]]/ { setup_guard = 1 }
      /^@test/ { in_test = 1; hit = 0; tests += 1 }
      in_test && /^[[:space:]]*assert_spec_subject(_dir)?[[:space:]]/ { hit = 1 }
      in_test && /^}/ { in_test = 0; if (hit) guarded += 1 }
      END { if (setup_guard) print tests + 0; else print guarded + 0 }
    ' "${_file}")"
    _total=$(( _total + _n ))
  done < <(grep -rlE "${GUARD_CALL_RE}" --include='*.bats' "${SPEC_TREE}")
  printf '%s\n' "${_total}"
}

@test "the changelog's count of tests behind this guard is the measured one" {
  # "N tests no longer pass when the artifact they assert on is deleted" is
  # a claim in the present tense about THIS tree, so it is checked against
  # this tree -- the posture adr_doc_claims_spec takes for an ADR's
  # mechanism claims. The entry shipped 260, measured 309: nobody could
  # reproduce it, which makes it worse than no figure at all.
  #
  # ONLY [Unreleased] is read. A released section is a historical record and
  # rewriting a shipped entry falsifies it (the changelog-entry lint draws
  # the same line), so once this entry ships its claim freezes and this case
  # has nothing left to check -- a scanned zero over a section proven
  # non-empty, not an unscanned one.
  #
  # An entry is checked when it names the guard AND quotes a test count.
  # Naming the guard without a count (this very change's entry) claims no
  # population and is not held to one; a claim that drops both the
  # identifier and the figure is outside this check, which is the limit of
  # reading prose by shape and is stated rather than papered over.
  local _changelog=/source/doc/changelog/CHANGELOG.md
  assert_spec_subject "${_changelog}" \
      "the changelog whose [Unreleased] entry quotes this invariant's population"

  # The population the count is derived from. grep answers 0 for "matched",
  # 1 for "scanned, matched nothing" and 2 for "could not scan"; only the
  # first can produce a real figure, and the other two would both arrive
  # here as a total of 0.
  run grep -rlE "${GUARD_CALL_RE}" --include='*.bats' "${SPEC_TREE}"
  assert_equal "${status}" 0
  [ "${#lines[@]}" -ge 10 ] \
    || fail "only ${#lines[@]} spec files call a subject guard; the reader, not the suite, is what to look at"

  local _measured
  _measured="$(_guarded_test_count)"

  # The [Unreleased] section, entry by entry. An entry is one top-level
  # `- ` bullet and its continuation lines, the same unit the changelog
  # lint measures.
  local _line _current='' _in_unreleased=0
  local -a _entries=()
  while IFS= read -r _line; do
    if [[ "${_line}" == '## ['*']'* ]]; then
      if [[ "${_line}" == '## [Unreleased]'* ]]; then
        _in_unreleased=1
      else
        _in_unreleased=0
      fi
      continue
    fi
    [[ "${_in_unreleased}" -eq 1 ]] || continue
    if [[ "${_line}" == '- '* ]]; then
      if [[ -n "${_current}" ]]; then _entries+=("${_current}"); fi
      _current="${_line}"
    elif [[ -n "${_current}" ]]; then
      # Joined with a space: an entry wraps at 79 columns, so a figure and
      # its noun can sit on two lines, and gluing them would hide the claim.
      _current+=" ${_line}"
    fi
  done < "${_changelog}"
  if [[ -n "${_current}" ]]; then _entries+=("${_current}"); fi

  # Non-vacuity: with no entries at all every check below is skipped in
  # silence, which is this file's own subject matter one level up.
  [ "${#_entries[@]}" -ge 1 ] \
    || fail "the [Unreleased] section holds no entries; the reader stopped recognising the changelog's structure"

  local _entry _quoted
  for _entry in "${_entries[@]}"; do
    [[ "${_entry}" == *assert_spec_subject* ]] || continue
    [[ "${_entry}" =~ ([0-9]+)[[:space:]]tests ]] || continue
    _quoted="${BASH_REMATCH[1]}"
    [ "${_quoted}" -eq "${_measured}" ] \
      || fail "the [Unreleased] changelog entry says ${_quoted} tests are held by the subject guard; the tree measures ${_measured}. Re-measure and correct the entry (or drop the figure) -- a number nobody can reproduce is worse than no number."
  done
}
