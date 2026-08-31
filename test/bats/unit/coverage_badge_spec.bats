#!/usr/bin/env bats
#
# Unit tests for script/release/coverage_badge.sh -- the release coverage
# badge generator (ADR-00000008, per-release figure amendment).
#
# The README used to draw a STATIC `Coverage-Kcov` shields.io badge: it
# looked like a measurement and carried none. The figure is computed by
# script/test/drivers/coverage_gate.sh on every coverage run and then
# discarded. This generator renders it into a self-contained SVG committed
# to the repo, stamped with the version it belongs to, regenerated as part
# of the release commit.
#
# The load-bearing behaviour is the REFUSAL: a release whose coverage never
# ran must not publish a stale or an invented number. The generator obtains
# the rate by re-running the gate's own merge math over the local kcov
# reports, and refuses when those reports cannot be shown to describe the
# commit being released.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Standalone-runnable, like the gate it reuses: the release bump invokes
  # it directly. Resolve it through the mounted /source tree.
  BADGE=/source/script/release/coverage_badge.sh
  REPO=/source

  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# A scratch git repo standing in for the release tree: one committed source
# file, a .version, and a kcov report set whose mtime is newer than HEAD.
#   $1 covered  $2 valid
_make_release_tree() {
  local _covered="${1}" _valid="${2}"
  local _root="${SCRATCH}/repo"
  mkdir -p "${_root}"
  git -C "${_root}" init --quiet
  git -C "${_root}" config user.email "spec@example.invalid"
  git -C "${_root}" config user.name "spec"
  printf '#!/usr/bin/env bash\ntrue\n' > "${_root}/thing.sh"
  printf 'v1.2.3\n' > "${_root}/.version"
  git -C "${_root}" add -A
  git -C "${_root}" commit --quiet -m "initial"
  _make_cobertura "${_root}/coverage/kcov-merged/cobertura.xml" \
    "${_covered}" "${_valid}"
  _stamp_head "${_root}"
  printf '%s\n' "${_root}"
}

# The provenance a real `just test coverage` leaves behind: the sha the
# reports under coverage/ were produced from, and the SCOPE they cover.
# Mtime alone only catches a report that is too OLD; it cannot tell that
# the tree moved somewhere else between the run and the release, and the
# sha alone cannot tell that only a quarter of the suite ran.
#   $1 root  [$2 scope, default full]
_stamp_head() {
  local _root="${1}" _scope="${2:-full}"
  mkdir -p "${_root}/coverage"
  {
    git -C "${_root}" rev-parse HEAD
    printf 'scope=%s\n' "${_scope}"
  } > "${_root}/coverage/.head-sha"
}

# A stand-in for the real `./script/test/test.sh <flag>` entry: a SCRIPT, so
# it runs under the strict mode test.sh turns on only when executed directly
# (and so ${BASH_SOURCE} is defined, which `bash -c` cannot offer). The
# container run and both halves of the provenance stamp are stubbed to
# markers, so what the test reads back is the ORDER the dispatch called them
# in and nothing about kcov.
#   $1 path  $2 body of the stubbed container run  $3 main invocation
_dispatch_script() {
  local _path="${1}" _run_body="${2}" _invocation="${3}"
  cat > "${_path}" <<EOS
#!/usr/bin/env bash
source /source/script/test/test.sh
set -euo pipefail
_invalidate_coverage_head() { printf 'INVALIDATE %s\\n' "\${1:-}"; }
_run_via_compose() { printf 'RUN\\n'; ${_run_body}; }
_stamp_coverage_head() { printf 'STAMP %s\\n' "\${2:-}"; }
${_invocation}
EOS
}

# Minimal kcov-style cobertura.xml at $1 with $2 covered of $3 valid
# per-line <line> elements (the gate merges by per-line union, so the
# elements -- not the root counters -- are what it reads).
#   $1 path  $2 covered  $3 valid  [$4 filename]
_make_cobertura() {
  local _path="${1}" _covered="${2}" _valid="${3}"
  local _fn="${4:-thing.sh}"
  mkdir -p "$(dirname "${_path}")"
  {
    echo '<?xml version="1.0" ?>'
    echo "<coverage lines-covered=\"${_covered}\" lines-valid=\"${_valid}\">"
    echo '  <packages><package name="p"><classes>'
    echo "  <class name=\"c\" filename=\"${_fn}\"><lines>"
    local _i
    for (( _i = 1; _i <= _valid; _i++ )); do
      if (( _i <= _covered )); then
        echo "    <line number=\"${_i}\" hits=\"1\"/>"
      else
        echo "    <line number=\"${_i}\" hits=\"0\"/>"
      fi
    done
    echo '  </lines></class>'
    echo '  </classes></package></packages>'
    echo '</coverage>'
  } > "${_path}"
}

# ── The figure and the version it belongs to ─────────────────────────────────

@test "coverage_badge: renders the measured rate into a self-contained SVG" {
  local _root
  _root="$(_make_release_tree 84 100)"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  [ -f "${_root}/badge.svg" ]
  run cat "${_root}/badge.svg"
  assert_output --partial '<svg'
  assert_output --partial '84.0%'
}

@test "coverage_badge: the SVG carries the version the figure belongs to" {
  local _root
  _root="$(_make_release_tree 84 100)"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  run cat "${_root}/badge.svg"
  assert_output --partial 'v1.2.3'
}

@test "coverage_badge: --version overrides the .version default" {
  local _root
  _root="$(_make_release_tree 84 100)"

  run bash "${BADGE}" --repo-root "${_root}" --version v9.9.9 \
    --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  run cat "${_root}/badge.svg"
  assert_output --partial 'v9.9.9'
  refute_output --partial 'v1.2.3'
}

@test "coverage_badge: the SVG references no external host" {
  local _root
  _root="$(_make_release_tree 84 100)"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  # The SVG namespace URI is an identifier, not a fetch; what must not
  # appear is anything a renderer would go to the network for.
  run cat "${_root}/badge.svg"
  refute_output --partial 'shields.io'
  refute_output --partial 'githubusercontent'
  refute_output --partial '<image'
  refute_output --partial 'xlink:href'
  refute_output --partial '@import'
}

@test "coverage_badge: the rate is the gate's own merge math, not a re-implementation" {
  local _root
  _root="$(_make_release_tree 1 4)"
  # Two shard reports over the SAME source file, the shape the gate's
  # per-line UNION exists for: shard 1 ran line 1, shard 2 ran lines 1-3.
  # The union is 3 of 4 distinct lines = 75%. Summing the root counters --
  # the merge the gate deliberately does NOT do -- would say 4/8 = 50%.
  rm -rf "${_root}/coverage"
  _make_cobertura "${_root}/coverage/shard-1/cobertura.xml" 1 4 thing.sh
  _make_cobertura "${_root}/coverage/shard-2/cobertura.xml" 3 4 thing.sh
  _stamp_head "${_root}"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  run cat "${_root}/badge.svg"
  assert_output --partial '75.0%'
  refute_output --partial '50.0%'
}

# ── Colour grading ───────────────────────────────────────────────────────────

@test "coverage_badge: a high rate grades green" {
  local _root
  _root="$(_make_release_tree 95 100)"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  run cat "${_root}/badge.svg"
  assert_output --partial '#4c1'
}

@test "coverage_badge: a low rate grades red" {
  local _root
  _root="$(_make_release_tree 20 100)"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  run cat "${_root}/badge.svg"
  assert_output --partial '#e05d44'
}

# ── Refusal: never a stale or an invented number ─────────────────────────────

@test "coverage_badge: refuses when no coverage report exists" {
  local _root
  _root="$(_make_release_tree 84 100)"
  rm -rf "${_root}/coverage"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "no coverage report"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: refuses when the reports predate the commit being released" {
  local _root
  _root="$(_make_release_tree 84 100)"
  touch -d '2001-01-01 00:00:00' \
    "${_root}/coverage/kcov-merged/cobertura.xml"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "older than"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: refuses when the reports were produced from a different commit" {
  local _root _first
  _root="$(_make_release_tree 84 100)"
  _first="$(git -C "${_root}" rev-parse HEAD)"

  # Measure the SECOND commit, then check the FIRST one back out. HEAD is
  # now OLDER than the reports, the worktree is clean, and every mtime
  # check passes -- yet the reports describe a tree that is not this one.
  printf 'echo more\n' >> "${_root}/thing.sh"
  git -C "${_root}" commit --quiet -am "second"
  _stamp_head "${_root}"
  git -C "${_root}" checkout --quiet "${_first}"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "different commit"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: refuses when the reports carry no provenance" {
  local _root
  _root="$(_make_release_tree 84 100)"
  rm -f "${_root}/coverage/.head-sha"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "provenance"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: the coverage run records the sha its reports describe" {
  local _root
  _root="$(_make_release_tree 84 100)"
  rm -f "${_root}/coverage/.head-sha"

  # The producer half of the provenance pair: without a writer in the
  # coverage path the reader above would refuse every real release.
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ -f "${_root}/coverage/.head-sha" ]
  [ "$(head -n 1 "${_root}/coverage/.head-sha")" = "$(git -C "${_root}" rev-parse HEAD)" ]

  # A sha alone says which TREE the reports describe and nothing about
  # WHETHER the whole suite produced them, so the scope is stamped too.
  run cat "${_root}/coverage/.head-sha"
  assert_output --partial "scope=full"
}

@test "coverage_badge: a shard run records the partition, not a whole-suite scope" {
  local _root
  _root="$(_make_release_tree 13 100)"
  rm -f "${_root}/coverage/.head-sha"

  # `just test coverage <n>/<total>` writes its slice into the SAME
  # coverage/ tree a full run uses. If it stamped the way a full run does,
  # the reports and the certificate would agree on the commit and disagree
  # with nothing, and the badge would publish a quarter of the suite as
  # the release rate.
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1" "$2"' \
    _ "${_root}" "1/4"
  [ "${status}" -eq 0 ]

  run cat "${_root}/coverage/.head-sha"
  assert_output --partial "scope=shard 1/4"
  refute_output --partial "scope=full"
}

@test "coverage_badge: a shard run overwrites an earlier full run's scope" {
  local _root
  _root="$(_make_release_tree 13 100)"

  # The tree already carries a full-suite stamp from an earlier run at the
  # same commit. Leaving it in place would let the shard's partial reports
  # inherit a certificate that says "whole suite".
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1" "$2"' \
    _ "${_root}" "2/4"
  [ "${status}" -eq 0 ]

  run cat "${_root}/coverage/.head-sha"
  refute_output --partial "scope=full"
  assert_output --partial "scope=shard 2/4"
}

@test "coverage_badge: the coverage run drops the old certificate before it starts" {
  local _root
  _root="$(_make_release_tree 84 100)"
  _stamp_head "${_root}" "full"

  # The eraser half of the pair. The reports in coverage/ are rewritten by
  # every run; the certificate next to them is not, so it has to be
  # removed at the start of a run rather than merely overwritten at the
  # end of one.
  run bash -c 'source /source/script/test/test.sh; _invalidate_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ ! -f "${_root}/coverage/.head-sha" ]

  # A tree that never carried a stamp is not an error: the writer is
  # best-effort by design and the eraser has to match it, or a repo with
  # no previous coverage run could not run one.
  run bash -c 'source /source/script/test/test.sh; _invalidate_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ ! -f "${_root}/coverage/.head-sha" ]
}

@test "coverage_badge: a failed coverage run leaves no certificate behind" {
  # The stamp is written only AFTER the container run returns 0, and a
  # coverage run fails for the most ordinary reason there is: a red spec.
  # kcov has already written its report by then (the driver preserves
  # bats' exit code on purpose), so coverage/ holds fresh, partial numbers
  # while the writer is never reached. If the previous run's certificate
  # were still sitting there, those numbers would inherit it -- matching
  # sha, clean worktree, `scope=full` -- and the badge would publish a
  # shard's rate under the release's name. Ctrl-C has the same shape.
  #
  # So the dispatch erases the certificate BEFORE the run and writes it
  # only on success: the failure mode becomes "no evidence", which the
  # generator refuses on, instead of "stale evidence", which it trusts.
  _dispatch_script "${SCRATCH}/failing.sh" 'return 1' 'main --coverage-shard 1/4'
  run bash "${SCRATCH}/failing.sh"
  [ "${status}" -ne 0 ]
  assert_output --partial "INVALIDATE /source"

  # Presence, order and absence in one reading: the erase precedes the
  # run (erasing after it would be no erasure at all) and no certificate
  # is written for a run that failed.
  local _order
  _order="$(printf '%s\n' "${output}" \
    | grep -E '^(INVALIDATE|RUN|STAMP)' | cut -d' ' -f1 | tr '\n' ',')"
  [ "${_order}" = "INVALIDATE,RUN," ]
}

@test "coverage_badge: a coverage run that succeeds still writes its certificate" {
  # The other side of the same rule: invalidation must not cost the
  # successful path its stamp, or every release would refuse.
  _dispatch_script "${SCRATCH}/passing.sh" 'return 0' 'main --coverage'
  run bash "${SCRATCH}/passing.sh"
  [ "${status}" -eq 0 ]

  local _order
  _order="$(printf '%s\n' "${output}" \
    | grep -E '^(INVALIDATE|RUN|STAMP)' | cut -d' ' -f1 | tr '\n' ',')"
  [ "${_order}" = "INVALIDATE,RUN,STAMP," ]
}

@test "coverage_badge: a sourced dispatch withholds the certificate too" {
  # main is sourceable, and this suite is the caller that sources it, so
  # errexit is the caller's business rather than test.sh's. The dispatch
  # reads the run's status explicitly and returns it, which is what makes
  # the rule hold with strict mode off as well -- and what stops the
  # reading from being written as `|| rc=$?`, which suspends errexit
  # INSIDE _run_via_compose and swallows the fatal steps in it.
  run bash -c '
    source /source/script/test/test.sh
    _invalidate_coverage_head() { printf "INVALIDATE\n"; }
    _run_via_compose() { printf "RUN\n"; return 1; }
    _stamp_coverage_head() { printf "STAMP\n"; }
    main --coverage
  '
  [ "${status}" -ne 0 ]
  assert_output --partial "INVALIDATE"
  assert_output --partial "RUN"
  refute_output --partial "STAMP"
}

@test "coverage_badge: --coverage-shard tells the stamp which partition ran" {
  # The joint between the two halves: the writer can only record a
  # partition if the dispatch passes it one. Stub the container run and
  # the writer, and read back what the dispatch handed over.
  run bash -c '
    source /source/script/test/test.sh
    _run_via_compose() { :; }
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { printf "root=[%s] shard=[%s]\n" "${1:-}" "${2:-}"; }
    main --coverage-shard 1/4
  '
  [ "${status}" -eq 0 ]
  assert_output --partial "root=[/source] shard=[1/4]"
}

@test "coverage_badge: a full --coverage run hands the stamp no partition" {
  # The dispatch passes the spec on BOTH branches -- empty here -- rather
  # than branching twice; an empty partition is what makes the stamp read
  # `full`.
  run bash -c '
    source /source/script/test/test.sh
    _run_via_compose() { :; }
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { printf "root=[%s] shard=[%s]\n" "${1:-}" "${2:-}"; }
    main --coverage
  '
  [ "${status}" -eq 0 ]
  assert_output --partial "root=[/source] shard=[]"
}

@test "coverage_badge: refuses when the reports cover one shard, not the suite" {
  local _root
  _root="$(_make_release_tree 13 100)"
  _stamp_head "${_root}" "shard 1/4"

  # Every identity check passes here: the sha IS HEAD, the worktree is
  # clean, the reports are newer than the commit. What is wrong is the
  # coverage, not the tree -- 13 lines of 100 is one partition's slice.
  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "shard 1/4"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: refuses when the stamp records no scope at all" {
  local _root
  _root="$(_make_release_tree 84 100)"
  # A stamp carrying only a sha -- what a hand-assembled report set or an
  # older writer leaves. It proves the tree and says nothing about how
  # much of the suite ran, so it is not evidence of a release figure.
  git -C "${_root}" rev-parse HEAD > "${_root}/coverage/.head-sha"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "scope"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: the operator sequence shard-then-badge publishes nothing" {
  local _root
  _root="$(_make_release_tree 13 100)"
  rm -f "${_root}/coverage/.head-sha"

  # End to end over the real writer and the real reader, at ONE commit:
  # `just test coverage 1/4` to check the sharded path, then
  # `just release coverage-badge`. The figure that must not be published
  # is 13% -- a quarter of the suite wearing the release's name.
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1" "$2"' \
    _ "${_root}" "1/4"
  [ "${status}" -eq 0 ]

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  [ ! -f "${_root}/badge.svg" ]
  refute_output --partial "13.0%"
}

@test "coverage_badge: refuses when instrumented sources are modified in the worktree" {
  local _root
  _root="$(_make_release_tree 84 100)"
  printf 'echo drift\n' >> "${_root}/thing.sh"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "modified"
  [ ! -f "${_root}/badge.svg" ]
}

@test "coverage_badge: a release-bump edit is not a source change" {
  local _root
  _root="$(_make_release_tree 84 100)"
  printf 'v1.2.4\n' > "${_root}/.version"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]
}

@test "coverage_badge: refuses to overwrite an existing badge when it cannot measure" {
  local _root
  _root="$(_make_release_tree 84 100)"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]
  local _before
  _before="$(cat "${_root}/badge.svg")"

  rm -rf "${_root}/coverage"
  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  [ "$(cat "${_root}/badge.svg")" = "${_before}" ]
}

@test "coverage_badge: --unmeasured states the absence instead of inventing a figure" {
  local _root
  _root="$(_make_release_tree 84 100)"
  rm -rf "${_root}/coverage"

  run bash "${BADGE}" --repo-root "${_root}" --unmeasured \
    --out "${_root}/badge.svg"
  [ "${status}" -eq 0 ]

  run cat "${_root}/badge.svg"
  assert_output --partial 'not measured'
  assert_output --partial 'v1.2.3'
  refute_output --partial '%'
}

@test "coverage_badge: rejects an unknown option" {
  run bash "${BADGE}" --repo-root "${SCRATCH}" --nonsense
  [ "${status}" -eq 2 ]
}

@test "coverage_badge: a missing option value is an arg error, not a refusal" {
  # 1 means "no usable measurement -- re-run just test coverage", the
  # sentence the caller prints to the operator. A typo'd flag is a caller
  # bug and must not wear that costume.
  local _flag
  for _flag in --repo-root --version --out --report; do
    run bash "${BADGE}" "${_flag}"
    [ "${status}" -eq 2 ]
    assert_output --partial "${_flag}"
  done
}

@test "coverage_badge: --help states the once-per-release cadence" {
  # The title used to be satisfied by the word "release" appearing
  # anywhere in the usage block; assert the claim itself.
  run bash "${BADGE}" --help
  [ "${status}" -eq 0 ]
  assert_output --partial "once per release"
}

@test "coverage_badge: the un-wired release step is recorded as pending, with its issue" {
  # The generator has no automatic caller: the release bump lives in the
  # harness repo, not this one. A decision record that describes that
  # wiring in the present tense is a false record of what shipped.
  #
  # A bare `grep docker_harness#` was too weak for the title it wears: it
  # proves a tracking ref appears SOMEWHERE, so the rejected present-tense
  # text can come back with the ref still sitting four lines below it.
  # Anchor on the claim itself -- the two sentences that state the wiring
  # has not happened -- and forbid the shipped-fact phrasings.
  local _adr="${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"

  # The amendment's Status paragraph: what shipped, and what did not.
  run grep -F 'the automatic caller has NOT' "${_adr}"
  [ "${status}" -eq 0 ]

  # Decision 4's heading, which names the end state and its absence in the
  # same breath.
  run grep -F 'is not one yet' "${_adr}"
  [ "${status}" -eq 0 ]

  # The future tense in the body of decision 4.
  run grep -F 'is to become' "${_adr}"
  [ "${status}" -eq 0 ]

  # And no formulation that reads as already done.
  run grep -nEi 'already wired|is a step of the release bump|the bump calls it' \
    "${_adr}"
  [ "${status}" -ne 0 ]

  # The recipe doc carries the same pair: the hand-run reality and the ref.
  run grep -F 'HAND-RUN STEP' "${REPO}/script/release/justfile.release"
  [ "${status}" -eq 0 ]

  run grep -F 'docker_harness#289' "${REPO}/script/release/justfile.release"
  [ "${status}" -eq 0 ]

  run grep -F 'docker_harness#289' "${_adr}"
  [ "${status}" -eq 0 ]
}

@test "coverage_badge: the generator header records the bump wiring as pending" {
  # The same false record, in the one place the reword did not reach. The
  # header's property list is what a reader stops at; the Cadence block 50
  # lines below it already says the wiring is tracked, so an unqualified
  # "regenerated by the release bump" up top contradicts the same file.
  #
  # The assertions anchor on the CLAIM, not on a blacklist of phrasings.
  # A guard that only demanded the issue ref and forbade two spellings was
  # satisfiable by the record it exists to reject: "The release bump
  # regenerates it ... see `docker_harness#289` for the release-bump
  # caller" carries the ref, dodges both spellings, and states as fact the
  # exact thing that has not happened. The three sentences below cannot
  # survive that rewrite.
  #
  # Read flattened, so re-wrapping the comment block -- which changes
  # where every phrase breaks -- is not a way to lose an anchor either.
  local _flat
  _flat="$(sed -n '/^# The three properties/,/^# WHERE THE NUMBER COMES FROM/p' \
    "${REPO}/script/release/coverage_badge.sh" \
    | sed 's/^#[[:space:]]*//' | tr '\n' ' ' | tr -s ' ')"
  [ -n "${_flat}" ]

  # Future tense on the caller ...
  run grep -F 'is TO BE regenerated by the release bump' <<< "${_flat}"
  [ "${status}" -eq 0 ]

  # ... its absence, stated outright ...
  run grep -F 'That caller does not exist yet' <<< "${_flat}"
  [ "${status}" -eq 0 ]

  # ... what the release does until it lands ...
  run grep -F 'Until it lands this is a hand-run step' <<< "${_flat}"
  [ "${status}" -eq 0 ]

  # ... and the issue that will change all three.
  run grep -F 'docker_harness#289' <<< "${_flat}"
  [ "${status}" -eq 0 ]

  # A backstop, not the property: the anchors above are what makes the
  # rejected record impossible to restate.
  run grep -nEi 'REGENERATED IN THE RELEASE COMMIT, by the release bump|already wired' \
    "${REPO}/script/release/coverage_badge.sh"
  [ "${status}" -ne 0 ]
}

@test "coverage_badge: the dirty check covers every source kcov instruments" {
  # SOURCE_PATHSPEC decides which worktree modifications refuse a badge,
  # and it names its scope "instrumented sources". What kcov actually
  # instruments is defined in the other file and by subtraction:
  # --include-path=<root> minus _coverage_exclude_path. Two rosters kept
  # by hand drift -- an extensionless entrypoint, a .py or .awk helper, a
  # dist/ script under a new extension -- and the drift is silent in the
  # dangerous direction: the file becomes instrumented AND exempt from the
  # refusal, so a release can publish a figure for a tree that has since
  # moved. This is the test that fails on the day they diverge.
  #
  # Both lists are read from their own definitions -- no third copy here.
  # The enumeration is `find`, not `git ls-files`: /source is a mounted
  # worktree whose .git is a file pointing at a path the container cannot
  # see, so git is unusable in here (it exits 128 and prints nothing,
  # which would make this test pass by scanning nothing).
  run bash -c '
    set -uo pipefail
    _root=/source

    # What kcov is told not to instrument, from the driver that tells it.
    _excluded_csv="$(source "${_root}/script/test/test.sh"; _coverage_exclude_path)"
    IFS="," read -r -a _excluded <<< "${_excluded_csv}"

    # What the badge refuses on, from the generator that refuses. Each file
    # is sourced in its own subshell: both own a readonly SCRIPT_DIR.
    mapfile -t _pathspec < <(source "${_root}/script/release/coverage_badge.sh"
                             printf "%s\n" "${SOURCE_PATHSPEC[@]}")

    _scanned=0
    _flagged=0
    while IFS= read -r -d "" _abs; do
      for _e in "${_excluded[@]}"; do
        [[ "${_abs}" == "${_e}"* ]] && continue 2
      done
      # What kcov instruments is what bash executes, and the shebang is
      # what says so -- the extension does not.
      read -r _first < "${_abs}" 2>/dev/null || continue
      case "${_first}" in
        "#!"*bash*|"#!"*sh|"#!"*sh\ *|"#!"*bats*) ;;
        *) continue ;;
      esac
      _scanned=$(( _scanned + 1 ))
      _rel="${_abs#"${_root}/"}"
      for _g in "${_pathspec[@]}"; do
        [[ "${_rel}" == ${_g} ]] && continue 2
      done
      printf "UNGUARDED %s\n" "${_rel}"
      _flagged=$(( _flagged + 1 ))
    done < <(find "${_root}" \
      -path "${_root}/.git" -prune -o \
      -path "${_root}/coverage" -prune -o \
      -path "${_root}/log" -prune -o \
      -type f -print0)
    printf "SCANNED %s\n" "${_scanned}"
    (( _flagged == 0 ))
  '
  [ "${status}" -eq 0 ]
  refute_output --partial "UNGUARDED"

  # "nothing scanned" must not read as "nothing unguarded". This repo
  # carries scores of instrumented scripts; an enumeration that returned
  # none would satisfy every assertion above, which is precisely how the
  # first draft of this test passed over a tree it never read.
  local _scanned
  _scanned="$(printf '%s\n' "${output}" | sed -n 's/^SCANNED //p')"
  [ "${_scanned}" -gt 50 ]
}

# ── The repo's own published figure ──────────────────────────────────────────

@test "coverage_badge: the README shows the committed badge, not a static one" {
  run grep -c 'Coverage-Kcov' "${REPO}/README.md"
  [ "${output}" -eq 0 ]

  run grep -F 'doc/badge/coverage.svg' "${REPO}/README.md"
  [ "${status}" -eq 0 ]
}

@test "coverage_badge: every localized README shows the committed badge" {
  local _f
  for _f in "${REPO}"/doc/readme/README.*.md; do
    run grep -c 'Coverage-Kcov' "${_f}"
    [ "${output}" -eq 0 ]
    run grep -F '../badge/coverage.svg' "${_f}"
    [ "${status}" -eq 0 ]
  done
}

@test "coverage_badge: the committed badge names the released version" {
  [ -f "${REPO}/doc/badge/coverage.svg" ]

  local _version
  _version="$(cat "${REPO}/.version")"
  run grep -F "${_version}" "${REPO}/doc/badge/coverage.svg"
  [ "${status}" -eq 0 ]
}

@test "coverage_badge: every README records the release step as hand-run, not the bump's" {
  # The directory tree in README.md and its three translations carries a
  # doc/badge/ line, and it said the badge is regenerated by the release
  # bump. There is no such caller: `release-bump.sh` lives in
  # `docker_harness` and the wiring is docker_harness#289. The ADR, the
  # recipe and the generator header were corrected for exactly that; the
  # four documents a reader opens FIRST were not.
  #
  # Anchor on the claim, not on a blacklist of phrasings: the line has to
  # say the step is hand-run and name the issue that will change that, so
  # a rewrite back to a shipped-fact reading goes red in any language.
  local _f
  for _f in "${REPO}/README.md" "${REPO}"/doc/readme/README.*.md; do
    run grep -c -- '── badge/' "${_f}"
    [ "${output}" -eq 1 ]

    run grep -- '── badge/' "${_f}"
    [ "${status}" -eq 0 ]
    assert_output --partial 'hand-run'
    assert_output --partial 'docker_harness#289'

    run grep -nEi 'regenerated by the release bump|the release bump regenerates' \
      "${_f}"
    [ "${status}" -ne 0 ]
  done
}
