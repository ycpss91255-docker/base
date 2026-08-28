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
  printf '%s\n' "${_root}"
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

@test "coverage_badge: --help documents the release cadence" {
  run bash "${BADGE}" --help
  [ "${status}" -eq 0 ]
  assert_output --partial "release"
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
