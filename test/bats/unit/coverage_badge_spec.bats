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

# The run manifest a real coverage run leaves next to its reports:
# `<seconds> <basename>`, one line per spec FILE bats actually ran
# (_junit_to_timings, drivers/bats.sh). It is the only local record of
# WHAT was measured, and the certificate's scope is derived from it rather
# than from the flag the operator typed.
#   $1 root  $2... spec basenames
_write_manifest() {
  local _root="${1}"; shift
  mkdir -p "${_root}/coverage"
  : > "${_root}/coverage/timings.tsv"
  local _b
  for _b in "$@"; do
    printf '1 %s\n' "${_b}" >> "${_root}/coverage/timings.tsv"
  done
}

# Give the scratch tree the spec inventory a manifest is measured against:
# the suite the run was supposed to cover.
#   $1 root  $2... paths relative to test/bats/
_make_specs() {
  local _root="${1}"; shift
  local _rel
  for _rel in "$@"; do
    mkdir -p "${_root}/test/bats/${_rel%/*}"
    printf '@test "t" { true; }\n' > "${_root}/test/bats/${_rel}"
  done
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
_stamp_coverage_head() { printf 'STAMP argc=%s\\n' "\$#"; }
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
  _make_specs "${_root}" unit/a_spec.bats unit/b_spec.bats integration/c_spec.bats
  _write_manifest "${_root}" a_spec.bats b_spec.bats c_spec.bats

  # The producer half of the provenance pair: without a writer in the
  # coverage path the reader above would refuse every real release.
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ -f "${_root}/coverage/.head-sha" ]
  [ "$(head -n 1 "${_root}/coverage/.head-sha")" = "$(git -C "${_root}" rev-parse HEAD)" ]

  # A sha alone says which TREE the reports describe and nothing about
  # WHETHER the whole suite produced them, so the scope is stamped too --
  # and it reads `full` because the run manifest names every spec in the
  # tree, not because the caller passed no shard flag.
  run cat "${_root}/coverage/.head-sha"
  assert_output --partial "scope=full"
}

@test "coverage_badge: a partial measurement is not certified whole, whatever the invocation said" {
  local _root
  _root="$(_make_release_tree 13 100)"
  rm -f "${_root}/coverage/.head-sha"
  _make_specs "${_root}" unit/a_spec.bats unit/b_spec.bats integration/c_spec.bats

  # One spec of three measured -- and the writer is called EXACTLY as a
  # bare `just test coverage` calls it: no shard argument, nothing in the
  # invocation that says "partition". A scope derived from the FLAG stamps
  # `full` here, and that combination is reachable rather than theoretical:
  # anything that narrows the CONTAINER's run without touching the flag
  # (an inherited COVERAGE_SHARD, an inherited COVERAGE_PATH, the next
  # selector nobody has thought of) produces exactly this pair of inputs.
  # Derived from the measurement, the scope cannot be fooled by an input
  # the writer never sees.
  _write_manifest "${_root}" a_spec.bats

  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]

  run cat "${_root}/coverage/.head-sha"
  assert_output --partial "scope=partial 1/3 specs"
  refute_output --partial "scope=full"
}

@test "coverage_badge: a run that recorded no measurement is certified as nothing" {
  local _root
  _root="$(_make_release_tree 13 100)"
  rm -f "${_root}/coverage/.head-sha"
  _make_specs "${_root}" unit/a_spec.bats
  rm -f "${_root}/coverage/timings.tsv"

  # No manifest is no evidence, and no evidence must not become a
  # certificate. `--coverage-path` writes nothing into coverage/, and a
  # run that dies before bats' report is converted writes nothing either.
  # The generator refuses on a MISSING stamp, so writing none is the safe
  # direction; inventing `full` is the failure this whole line of defence
  # exists for.
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ ! -f "${_root}/coverage/.head-sha" ]
}

@test "coverage_badge: a later partial measurement overwrites an earlier full one" {
  local _root
  _root="$(_make_release_tree 13 100)"
  _make_specs "${_root}" unit/a_spec.bats unit/b_spec.bats

  # The tree already carries a full-suite stamp from an earlier run at the
  # same commit. Leaving it in place would let the next run's partial
  # reports inherit a certificate that says "whole suite".
  _write_manifest "${_root}" a_spec.bats b_spec.bats
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  run cat "${_root}/coverage/.head-sha"
  assert_output --partial "scope=full"

  _write_manifest "${_root}" b_spec.bats
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]

  run cat "${_root}/coverage/.head-sha"
  refute_output --partial "scope=full"
  assert_output --partial "scope=partial 1/2 specs"
}

@test "coverage_badge: the measured-scope inventory is this repo's real spec tree" {
  # The derivation is only as good as the inventory it compares the
  # manifest against. An inventory that enumerated NOTHING would make
  # every manifest look complete -- nothing missing -- which is the
  # vacuous-scan failure the instrumented-source guard below also has to
  # defend against. So it is anchored on THIS tree, and read the way the
  # full coverage run reads it: every pool of the run's roster,
  # recursively, so the test/bats/unit/<lib>/ subfolders (ADR-00000015)
  # count.
  #
  # The expectation is NOT a second copy of the implementation's find: the
  # pools and the file shape are read out of the roster the RUN uses
  # (_COVERAGE_FULL_SUITE_POOLS / _COVERAGE_SPEC_GLOB, drivers/bats.sh),
  # and only the enumeration is redone here. A pool added to the run
  # therefore changes both sides, and a pool added to the inventory alone
  # changes neither.
  run bash -c 'source /source/script/test/test.sh; _coverage_spec_inventory /source'
  [ "${status}" -eq 0 ]

  local _n _expected _roster _glob _p
  _n="$(printf '%s\n' "${output}" | grep -c .)"

  _roster="$(bash -c '
    source /source/script/test/test.sh
    printf "%s\n" "${_COVERAGE_FULL_SUITE_POOLS[@]}"')"
  _glob="$(bash -c '
    source /source/script/test/test.sh
    printf "%s\n" "${_COVERAGE_SPEC_GLOB}"')"
  [ "$(printf '%s\n' "${_roster}" | grep -c .)" -ge 2 ]

  local -a _dirs=()
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] && _dirs+=("/source/${_p}")
  done <<< "${_roster}"
  _expected="$(find "${_dirs[@]}" -name "${_glob}" \
    | sed 's#.*/##' | sort -u | grep -c .)"
  [ "${_n}" -eq "${_expected}" ]
  [ "${_n}" -gt 100 ]
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

@test "coverage_badge: the eraser drops the manifest the scope is derived from" {
  local _root
  _root="$(_make_release_tree 84 100)"
  _stamp_head "${_root}" "full"
  _write_manifest "${_root}" a_spec.bats

  # The certificate is DERIVED from the run manifest, so the manifest is
  # part of the certificate and inherits its rule: it must never outlive
  # the run it describes. Erasing one and leaving the other is how a run
  # that measures nothing -- or dies before its report is converted --
  # gets certified by the PREVIOUS run's record of what was measured.
  run bash -c 'source /source/script/test/test.sh; _invalidate_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ ! -f "${_root}/coverage/.head-sha" ]
  [ ! -f "${_root}/coverage/timings.tsv" ]
}

@test "coverage_badge: a manifest that outlives its erasure fails the run" {
  local _root
  _root="$(_make_release_tree 84 100)"

  # Same asymmetry as the stamp, for the same reason: a MISSING manifest
  # makes the writer stamp nothing and the generator refuse (safe), while
  # a SURVIVING one is a complete record of somebody else's run sitting
  # where this run's record belongs. An occupied path stands in for the
  # root-owned coverage/ that CI shard artifacts leave behind.
  rm -f "${_root}/coverage/timings.tsv"
  mkdir -p "${_root}/coverage/timings.tsv/occupied"

  run bash -c 'source /source/script/test/test.sh; _invalidate_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -ne 0 ]
  assert_output --partial "timings.tsv"
  [ -e "${_root}/coverage/timings.tsv" ]
}

@test "coverage_badge: a certificate that outlives its erasure fails the run" {
  local _root
  _root="$(_make_release_tree 84 100)"

  # The eraser used to be best-effort, justified as "a checkout with no
  # coverage/ has nothing to invalidate". But `rm -f` on a missing path
  # already succeeds, so the swallow bought nothing for the case it
  # named. The only statuses it could swallow -- EACCES, EISDIR, EIO --
  # are precisely the ones where the certificate SURVIVES, and best-effort
  # points the wrong way here: a missing stamp makes the generator refuse
  # (safe), a surviving one makes it publish (not).
  #
  # The state is reachable through the workflow the generator header
  # documents: CI shard artifacts unpacked locally as root, a `scope=full`
  # stamp written alongside them by hand, then `just test coverage`. An
  # occupied stamp path stands in for it, and stands in for the
  # write-protected coverage/ too -- both are a stamp that is still there
  # when the run starts.
  rm -f "${_root}/coverage/.head-sha"
  mkdir -p "${_root}/coverage/.head-sha/occupied"

  run bash -c 'source /source/script/test/test.sh; _invalidate_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -ne 0 ]
  [ -e "${_root}/coverage/.head-sha" ]

  # And the dispatch stops there. Running on would produce exactly the
  # state the erasure exists to prevent: fresh partial reports under a
  # certificate written before them.
  #
  # The eraser is stubbed rather than pointed at the tree above, because
  # REPO_ROOT is readonly -- a caller cannot redirect the dispatch at
  # another checkout, and a test that assigned it would have proved
  # nothing while appearing to. Stubbing also states the stronger rule:
  # the dispatch stops on a NON-ZERO RETURN, not merely on the `_die`
  # that today's eraser happens to use, so it holds for a sourced main
  # (this suite) with errexit off as much as for the strict-mode entry.
  run bash -c '
    source /source/script/test/test.sh
    _invalidate_coverage_head() { return 3; }
    _run_via_compose() { printf "RUN\n"; }
    _stamp_coverage_head() { printf "STAMP\n"; }
    main --coverage
  '
  [ "${status}" -eq 3 ]
  refute_output --partial "RUN"
  refute_output --partial "STAMP"
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

@test "coverage_badge: --coverage-shard partitions the CONTAINER, and tells the writer nothing" {
  # The partition is an instruction to the CONTAINER and to nobody else.
  # The writer used to be handed it as well, and that second copy is what
  # made the certificate a statement about the INVOCATION: a run narrowed
  # by anything the writer could not see was certified by the flag it
  # could. So the writer is handed the root and NOTHING else -- argc is
  # read, not just the values -- and derives the scope from the reports.
  #
  # A DIFFERENT partition sits in the ambient environment here, so the
  # container-side reading cannot be satisfied by an inherited value --
  # and an ambient COVERAGE_PATH sits beside it, because the in-container
  # dispatch reads THAT one first: a shard run under an inherited path
  # instruments one spec and writes no report, whatever the shard flag
  # said. Both halves of the selector pair are read, not just the one
  # this branch names.
  run env COVERAGE_SHARD=3/4 COVERAGE_PATH=test/bats/unit/lib_spec.bats bash -c '
    source /source/script/test/test.sh
    _run_via_compose() {
      printf "CONTAINER path=[%s] shard=[%s]\n" "${COVERAGE_PATH:-}" "${COVERAGE_SHARD:-}"
    }
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { printf "STAMP root=[%s] argc=[%s]\n" "${1:-}" "$#"; }
    main --coverage-shard 1/4
  '
  [ "${status}" -eq 0 ]
  assert_output --partial "STAMP root=[/source] argc=[1]"
  assert_output --partial "CONTAINER path=[] shard=[1/4]"
}

@test "coverage_badge: a full --coverage run hands the writer only the root" {
  # Same rule on the branch that reports the release figure. There is no
  # argument here that could say "full", and that is the point: `full` has
  # to be earned from the manifest the run left behind.
  run bash -c '
    source /source/script/test/test.sh
    _run_via_compose() { :; }
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { printf "STAMP root=[%s] argc=[%s]\n" "${1:-}" "$#"; }
    main --coverage
  '
  [ "${status}" -eq 0 ]
  assert_output --partial "STAMP root=[/source] argc=[1]"
}

@test "coverage_badge: a full --coverage run tells the CONTAINER no selector at all" {
  # The certificate can no longer be fooled -- it is derived from what the
  # run measured -- but a run narrowed by an inherited selector is still
  # the WRONG RUN: `just test coverage` before a release would silently
  # instrument a quarter of the suite, or one spec, and then refuse to
  # publish, which is a confusing way to spend twelve minutes.
  #
  # What kcov walks is decided by the environment, not by the flag:
  # _run_via_compose forwards `-e COVERAGE_SHARD="${COVERAGE_SHARD:-}"`
  # and `-e COVERAGE_PATH="${COVERAGE_PATH:-}"` from the AMBIENT
  # environment, and the in-container dispatch reads COVERAGE_PATH FIRST,
  # so the path out-ranks the partition. The caller that carries either is
  # this suite itself, run under `just test coverage` / `just test
  # coverage-path`. Both are cleared, and both are read here.
  run env COVERAGE_SHARD=1/4 COVERAGE_PATH=test/bats/unit/lib_spec.bats bash -c '
    source /source/script/test/test.sh
    _run_via_compose() {
      printf "CONTAINER path=[%s] shard=[%s]\n" "${COVERAGE_PATH:-}" "${COVERAGE_SHARD:-}"
    }
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { printf "STAMP argc=[%s]\n" "$#"; }
    main --coverage
  '
  [ "${status}" -eq 0 ]
  assert_output --partial "CONTAINER path=[] shard=[]"
  assert_output --partial "STAMP argc=[1]"
}

@test "coverage_badge: the coverage dispatch pins every selector the container reads" {
  # This is the part that stays enumerable, and the reason it is bounded.
  # The scope on the certificate is derived from the measurement, so no
  # forgotten variable can make a partial run look whole; what a forgotten
  # variable can still do is make the run itself wrong. That set is not
  # "every environment variable" -- it is the intersection of two lists
  # that both live in this repo's source:
  #
  #   - what _run_via_compose forwards FROM THE AMBIENT ENVIRONMENT, on
  #     BOTH of its channels: its `-e NAME="${NAME:-}"` flags, and
  #     compose.yaml's own `environment:` entries, which compose
  #     interpolates from this process's environment with no `-e` line at
  #     all (HOST_UID / HOST_GID reach the container that way today). The
  #     same-named read is the giveaway on either channel;
  #     `-e COVERAGE="${_coverage}"` is a positional and is not in this
  #     set. A roster stated as the `-e` lines alone would exempt a
  #     selector plumbed through the compose file, and
  #   - what the in-container COVERAGE branch actually reads.
  #
  # Both are read out of the source here rather than transcribed, so a
  # third selector added to the forwarder and consulted by the container
  # arrives with its clearing already demanded. Four review rounds found
  # the members of this set one at a time; this test enumerates it.
  #
  # COMMENT LINES ARE STRIPPED from both sides. This file explains in prose
  # exactly what it pins -- the dispatch comment names both selectors --
  # so a whole-block match is satisfied by the explanation instead of the
  # assignment -- the failure the structural specs were fixed for.
  # Deleting `COVERAGE_PATH=""` from the command prefix must fail this
  # test even though the paragraph above it still says the words.
  local _forwarded _container _pinned _name _n=0
  local _strip='/^[[:space:]]*#/d' 
  _forwarded="$(sed -n '/docker compose -p/,/^}/p' "${REPO}/script/test/test.sh" \
    | sed "${_strip}" \
    | sed -n 's/.*-e \([A-Z][A-Z_]*\)="\${\1:-}".*/\1/p' | sort -u)"
  [ -n "${_forwarded}" ]

  # Both channels are actually read: the compose file's is the one a
  # roster stated as the `-e` lines alone would miss, and HOST_UID is
  # its only member today.
  printf '%s\n' "${_forwarded}" | grep -qx 'COVERAGE_SHARD'
  printf '%s\n' "${_forwarded}" | grep -qx 'HOST_UID'

  # The in-container coverage branch: from the COVERAGE guard to the arm
  # that ends it. `sed -n` ranges include their closing line, and that
  # line is the NEXT branch's condition, so it is dropped -- keeping it
  # would enrol the whole if/elif chain's variables in a guard about one
  # branch.
  _container="$(sed -n '/if \[\[ "\${COVERAGE:-0}" == "1" \]\]; then/,/^      elif/p' \
    "${REPO}/script/test/test.sh" | sed '$d' | sed "${_strip}")"
  [ -n "${_container}" ]

  # The host-side dispatch that has to pin them.
  _pinned="$(sed -n '/^    coverage)/,/^    compose)/p' "${REPO}/script/test/test.sh" \
    | sed "${_strip}")"
  [ -n "${_pinned}" ]

  for _name in ${_forwarded}; do
    [[ "${_container}" == *"${_name}"* ]] || continue
    _n=$(( _n + 1 ))
    printf 'SELECTOR %s\n' "${_name}"
    # Assigned by the dispatch, at any value: `NAME=` on a command
    # prefix. Inheriting it is what the four rounds were about.
    [[ "${_pinned}" =~ (^|[[:space:]])"${_name}"= ]]
  done

  # An intersection that came out empty would satisfy the loop above
  # without checking anything, which is how a guard over a list becomes a
  # guard over nothing. Both known selectors must be in it.
  [ "${_n}" -ge 2 ]
}

@test "coverage_badge: refuses when the reports cover one shard, not the suite" {
  local _root
  _root="$(_make_release_tree 13 100)"
  # The scope string a REAL writer emits for a partition: `partial <m>/<n>
  # specs`, derived from the manifest. `shard 1/4` was the invocation-era
  # wording and no writer produces it any more, so a reader pinned on it
  # would be reading a string this repo cannot generate.
  _stamp_head "${_root}" "partial 1/4 specs"

  # Every identity check passes here: the sha IS HEAD, the worktree is
  # clean, the reports are newer than the commit. What is wrong is the
  # coverage, not the tree -- 13 lines of 100 is one partition's slice.
  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "partial 1/4 specs"
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
  _make_specs "${_root}" unit/a_spec.bats unit/b_spec.bats \
    unit/sub/c_spec.bats integration/d_spec.bats
  _write_manifest "${_root}" a_spec.bats

  # End to end over the real writer and the real reader, at ONE commit:
  # `just test coverage 1/4` leaves reports covering a QUARTER of the
  # suite, then `just release coverage-badge` is asked to publish them.
  # The figure that must not be published is 13% -- a quarter of the suite
  # wearing the release's name.
  #
  # The refusal has to rest on a certificate the writer ACTUALLY WROTE,
  # naming the partial measurement. A tree with no manifest makes the
  # writer stamp nothing at all, and the generator then refuses on the
  # missing-provenance path -- which is the subject of another test above,
  # and would leave this sequence's real failure mode (a stamped partial
  # scope reaching the badge) untested.
  # One argument: the writer takes the root and reads the scope off the
  # measurement. The `1/4` a caller used to pass here described the
  # INVOCATION, and that is exactly the input the scope stopped being
  # derived from.
  run bash -c 'source /source/script/test/test.sh; _stamp_coverage_head "$1"' \
    _ "${_root}"
  [ "${status}" -eq 0 ]
  [ -f "${_root}/coverage/.head-sha" ]
  run cat "${_root}/coverage/.head-sha"
  assert_output --partial "scope=partial 1/4 specs"

  run bash "${BADGE}" --repo-root "${_root}" --out "${_root}/badge.svg"
  [ "${status}" -eq 1 ]
  assert_output --partial "partial 1/4 specs"
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
  # by hand drift -- an extensionless entrypoint, a dist/ script under a
  # new extension -- and the drift is silent in the
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

@test "coverage_badge: the roster's drift note promises only the guard it has" {
  # The guard above defines "instrumented" operationally, and narrowly: a
  # file counts when its SHEBANG says bash runs it. That is the right
  # definition -- kcov picks its engine from the executable the suite
  # launches (bats, bash) and traces that process's bash children -- but
  # it means a helper written in another language is skipped before it is
  # ever compared against SOURCE_PATHSPEC.
  #
  # The roster's header used to list such helpers among the drift cases
  # "the dirty check covers every source kcov instruments" catches. It
  # cannot: those files are `continue`d, so the header promised a guard
  # that does not exist and a reader checking the roster against it would
  # have been told a divergence was already covered.
  #
  # Read flattened, so re-wrapping the block is not a way to lose an
  # anchor. Comment lines only -- the roster literal names extensions of
  # its own.
  local _flat
  _flat="$(sed -n '/^# Paths whose content the coverage run measures/,/^readonly SOURCE_PATHSPEC=/p' \
    "${REPO}/script/release/coverage_badge.sh" \
    | grep '^#' | sed 's/^#[[:space:]]*//' | tr '\n' ' ' | tr -s ' ')"
  [ -n "${_flat}" ]

  # No drift case named in a language the shebang scan skips.
  #
  # BARE language names, not only dotted extensions. The rejected claim
  # reads "a Python helper" or "an awk script" as readily as "a .py
  # helper", so a roster of eight extensions each requiring a leading dot
  # exempted every obvious rewording of the very sentence it was written
  # to keep out -- the same hand-kept-roster shape the note it polices is
  # about. The list is deliberately eager and carries no word boundary:
  # bash's regex engine is musl's inside this container and `\b` is a GNU
  # extension there, and a false positive costs a reword while a false
  # negative costs the guard.
  #
  # Matched with bash's own [[ =~ ]] rather than `run grep`: grep exits 2
  # on an error and 1 on no-match, so a status test reading "not 0" as
  # "clean" would pass on a pattern that never ran.
  local _re='(python|ruby|perl|awk|node|javascript|typescript|rust|golang|lua|php|\.(py|rb|pl|js|ts|go|rs|lua|php|awk))'
  local _hit=0
  shopt -s nocasematch
  [[ "${_flat}" =~ ${_re} ]] && _hit=1
  shopt -u nocasematch
  [ "${_hit}" -eq 0 ]

  # And the reach the guard does have, stated where the promise is made.
  [[ "${_flat}" == *"what bash executes"* ]]
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
