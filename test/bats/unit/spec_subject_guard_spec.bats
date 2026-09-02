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

  # The spelling variants a fail-open existence guard can take, over three
  # axes: the bracket form (`[[ ]]`, `[ ]`, `test`), the negation (none, a
  # `!` inside the brackets, a `!` in front of them -- a negated check
  # answers with `&&` and says exactly the same thing), and the existence
  # predicate (`-f`, `-e`, `-s`, `-d`). All of them ask "is the subject
  # there", so a scan that knows only `[[ -f X ]] || skip` leaves the
  # invariant one keystroke from being unenforced.
  #
  # OVER-approximating on purpose, and not a closed set: `[[ -f x ]] || {
  # skip; }`, an `if ... then skip; fi` across three lines, or a helper
  # that hides the test are all outside it. The case below plants every
  # combination of the three axes so the coverage this pattern DOES claim
  # is proven rather than asserted here; nothing claims the rest.
  #
  # Held in one variable so the scan below and the case that proves what
  # the scan can see cannot drift apart.
  GUARD_RE='^[[:space:]]*!?[[:space:]]*(\[\[|\[|test)[[:space:]]+!?[[:space:]]*-[defs][[:space:]].*(\|\||&&)[[:space:]]*skip'

  # Where the scan looks, and the floor the population may not fall below.
  SPEC_TREE=/source/test/bats
  SPEC_TREE_FLOOR=60
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
  # there: a scan of nothing reports "no matches" exactly like a clean tree,
  # and `assert_failure` on the grep would have accepted it.
  run bash -c "find ${SPEC_TREE} -type f -name '*.bats' | wc -l | tr -d ' '"
  assert_success
  assert [ "${output}" -ge "${SPEC_TREE_FLOOR}" ]

  # SECOND that the scan itself ran. grep answers 1 for "scanned, matched
  # nothing" and 2 for "could not scan" (path gone, unreadable); only the
  # first is this invariant holding, and `assert_failure` cannot tell them
  # apart -- pointing the scan at a path that does not exist left this spec
  # passing 5/5.
  # `assert_output` first so a failure prints the guards it found, file and
  # line; the status pin still runs, and neither is weakened by the order.
  run grep -rnE "${GUARD_RE}" "${SPEC_TREE}/"
  assert_output ""
  assert_equal "${status}" 1
}

# _guard_spelling <bracket> <negation> <operator>
#   Render ONE fail-open existence guard, in the spelling named by the three
#   axes, as a line of bats source. Rendered rather than listed so the case
#   below cannot fall behind the pattern one variant at a time.
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
  local _open _close _outer='' _inner='' _joiner='||'

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

  printf '  %s%s %s-%s "${WF}"%s %s skip "gone"\n' \
    "${_outer}" "${_open}" "${_inner}" "${_operator}" "${_close}" "${_joiner}"
}

@test "the fail-open guard scan sees each spelling of the check it claims to cover" {
  # The other way the invariant above goes quietly blind: it holds because
  # its PATTERN misses the guard, not because no guard exists. Reintroducing
  # a real fail-open guard as `[ -f "${WF}" ] || skip "gone"` left it green,
  # and so does a negated form or an existence test that is not `-f` --
  # `[[ -d "${WF_DIR}" ]] || skip` was sitting in this suite, unseen, while
  # the invariant reported clean.
  #
  # The spellings are GENERATED from three axes -- bracket form, negation,
  # operator -- rather than listed, so a spelling this scan is claimed to
  # cover cannot go untested by being left off a list.
  #
  # NOT exhaustive, and this case does not claim to be: bash spells a
  # conditional in ways no cross-product enumerates (an `if ... then skip;
  # fi` across three lines, `[[ -f x ]] || { skip; }`, a helper function
  # that hides the test entirely). The scan over-approximates the shapes it
  # knows and this case pins exactly those; a guard written outside the
  # three axes is NOT covered, and saying so here is the point -- an
  # invariant that claimed a closed set would be making the same promise
  # the `-f`-only pattern made.
  local _planted="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "${_planted}"

  local _bracket _negation _operator _name _planted_count=0
  for _bracket in double single builtin; do
    for _negation in plain inner outer; do
      # The existence predicates a guard on a tracked artifact can use.
      # `-f` was the only one the pattern knew.
      for _operator in f e s d; do
        _name="${_bracket}_${_negation}_${_operator}"
        _guard_spelling "${_bracket}" "${_negation}" "${_operator}" \
          > "${_planted}/${_name}.bats"
        _planted_count=$(( _planted_count + 1 ))

        run grep -nE "${GUARD_RE}" "${_planted}/${_name}.bats"
        [[ "${status}" -eq 0 ]] || fail \
          "the fail-open guard scan does not match the ${_name} spelling ($(cat "${_planted}/${_name}.bats")), so the repo-wide invariant would stay green with that guard in the tree"
      done
    done
  done

  # Non-vacuity: a loop that planted nothing would report every spelling
  # covered, which is this file's own subject matter one level up.
  [ "${_planted_count}" -eq 36 ] || fail \
    "planted ${_planted_count} spellings, expected 36 (3 bracket forms x 3 negations x 4 operators)"
}
