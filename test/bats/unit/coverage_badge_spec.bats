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
# reports under coverage/ were produced from. Mtime alone only catches a
# report that is too OLD; it cannot tell that the tree moved somewhere
# else between the run and the release.
_stamp_head() {
  local _root="${1}"
  mkdir -p "${_root}/coverage"
  git -C "${_root}" rev-parse HEAD > "${_root}/coverage/.head-sha"
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
  [ "$(cat "${_root}/coverage/.head-sha")" = "$(git -C "${_root}" rev-parse HEAD)" ]
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
  # wiring in the present tense is a false record of what shipped, so the
  # ADR and the recipe doc must name the tracking issue instead.
  run grep -F 'docker_harness#' \
    "${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"
  [ "${status}" -eq 0 ]

  run grep -F 'docker_harness#' "${REPO}/script/release/justfile.release"
  [ "${status}" -eq 0 ]
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
