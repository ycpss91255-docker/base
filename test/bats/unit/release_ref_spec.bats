#!/usr/bin/env bats
#
# release_ref_spec.bats -- the ONE classifier of a released ref, and the
# derived proof that every workflow site ASKS it instead of restating it.
#
# ── The question, and why it was asked three times ──────────────────────
#
# "Is this tag a prerelease?" decides two different things in this repo,
# and both of them are consumed org-wide:
#
#   release-worker.yaml    whether the GitHub Release it cuts for a
#                          downstream repo is marked prerelease
#   self-test.yaml         the same, for base's own release
#   release-test-tools.yaml whether the published image moves
#                          `test-tools:latest` -- the tag every repo that
#                          has not pinned `test_tools_version` builds its
#                          lint stage from, because that input's DEFAULT
#                          is "latest"
#
# The first two spelled the test `contains(github.ref_name, '-')`. The
# third did not ask at all, and moved `:latest` on v0.42.0-rc1 through
# -rc4. The repair that only fixed the third would have left three
# hand-kept copies of one rule, which is the same defect with a longer
# fuse: the next site is one commit away, and nothing in the tree would
# have noticed it disagreeing.
#
# So the rule has one home -- script/ci/release-ref.sh -- and this spec
# pins two things: what the classifier ANSWERS, and that the population
# of workflow sites asking the question is exactly the population calling
# it. The population is DERIVED from .github/workflows/, never listed
# here: a guard for "every site" that consulted a remembered list of
# three would pass on precisely the fourth site added tomorrow.
#
# ── Why a text test on the ref is not good enough ───────────────────────
#
# `contains(github.ref_name, '-')` is true of `feature/add-thing` and of
# `refs/heads/release-prep`. Those are not prereleases and are not
# versions at all; a predicate that answers a question about a ref it
# cannot parse is guessing, and the direction it guesses in is what moved
# `:latest`. The classifier therefore REFUSES a ref that is not a version
# tag rather than answering `false` for it -- `false` is the branch that
# publishes, and an unparseable input must never reach the destructive
# side of a decision (the same direction ghcr-cleanup.yaml's dry-run
# resolver takes an input it cannot read).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  RESOLVER=/source/script/ci/release-ref.sh
  WF_DIR=/source/.github/workflows
  assert_spec_subject "${RESOLVER}" \
      "the one classifier of a released ref"
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow tree this spec derives its prerelease sites from"
}

# _workflow_files -- every workflow in the tree, derived from the tree.
# `find`, not a list: the whole point of the scans below is that a file
# added tomorrow is scanned tomorrow.
_workflow_files() {
  find "${WF_DIR}" -maxdepth 1 -type f \
      \( -name '*.yaml' -o -name '*.yml' \) | sort
}

# _prerelease_inputs -- one `<file>: <line>` per `prerelease:` key in the
# workflow tree, code lines only (a `prerelease` in a comment paragraph
# declares nothing), plus a trailing `scanned=<n>` for non-vacuity.
_prerelease_inputs() {
  local _f _line _scanned=0
  while IFS= read -r _f; do
    _scanned=$(( _scanned + 1 ))
    while IFS= read -r _line; do
      printf '%s: %s\n' "${_f##*/}" \
          "${_line#"${_line%%[![:space:]]*}"}"
    done < <(code_grep -E '^[[:space:]]*prerelease:' "${_f}" || true)
  done < <(_workflow_files)
  printf 'scanned=%s\n' "${_scanned}"
}

# _restated_predicates -- one `finding: <file>: <line>` per site that
# spells the prerelease test itself instead of calling the classifier,
# plus `scanned=<n>`.
#
# The vocabulary is a fixed table (the two spellings this tree has ever
# used: the GitHub expression and the shell glob); the POPULATION it is
# applied to is the tree. That split is the same one
# script/test/drivers/just_provenance.sh draws, and for the same reason.
_restated_predicates() {
  local _f _line _scanned=0
  local -a _res=(
    "contains\\([[:space:]]*github\\.ref(_name)?[[:space:]]*,[[:space:]]*'-'"
    '==[[:space:]]*\*-\*'
  )
  local _re
  while IFS= read -r _f; do
    _scanned=$(( _scanned + 1 ))
    for _re in "${_res[@]}"; do
      while IFS= read -r _line; do
        printf 'finding: %s: %s\n' "${_f##*/}" \
            "${_line#"${_line%%[![:space:]]*}"}"
      done < <(code_grep -E "${_re}" "${_f}" || true)
    done
  done < <(_workflow_files)
  printf 'scanned=%s\n' "${_scanned}"
}

# ── The classifier's answers ─────────────────────────────────────────

@test "release-ref: a finished release tag is not a prerelease (#1012)" {
  run bash "${RESOLVER}" prerelease v0.42.0
  assert_success
  assert_output 'false'
}

@test "release-ref: an RC tag is a prerelease (#1012)" {
  run bash "${RESOLVER}" prerelease v0.42.0-rc4
  assert_success
  assert_output 'true'
}

@test "release-ref: a full refs/tags/ ref answers the same as its bare tag (#1012)" {
  # GITHUB_REF carries the first spelling, github.ref_name the second, and
  # a caller passes whichever it happens to hold.
  run bash "${RESOLVER}" prerelease refs/tags/v0.42.0-rc4
  assert_success
  assert_output 'true'
  run bash "${RESOLVER}" prerelease refs/tags/v0.42.0
  assert_success
  assert_output 'false'
}

@test "release-ref: the leading v is optional (#1012)" {
  run bash "${RESOLVER}" prerelease 0.42.0-rc4
  assert_success
  assert_output 'true'
  run bash "${RESOLVER}" prerelease 0.42.0
  assert_success
  assert_output 'false'
}

@test "release-ref: build metadata is not a prerelease, a dotted prerelease id is (#1012)" {
  # SemVer 9 vs 10: `+build` says nothing about precedence, `-rc.1` does.
  run bash "${RESOLVER}" prerelease v1.0.0+build.5
  assert_success
  assert_output 'false'
  run bash "${RESOLVER}" prerelease v1.0.0-rc.1+build.5
  assert_success
  assert_output 'true'
}

@test "release-ref: a branch whose name merely contains a dash is refused, not answered (#1012)" {
  # The defect the one-line `contains(ref_name, '-')` carries: it is TRUE
  # of every such branch. Refusing is the only safe answer, because the
  # other one -- `false` -- is the branch that publishes.
  run bash "${RESOLVER}" prerelease refs/heads/feature/add-thing
  assert_failure
  refute_output 'false'
  assert_output --partial 'refs/heads/feature/add-thing'
}

@test "release-ref: a ref that is not a version tag at all is refused (#1012)" {
  run bash "${RESOLVER}" prerelease main
  assert_failure
  refute_output 'false'
  run bash "${RESOLVER}" prerelease refs/tags/v1.0
  assert_failure
  refute_output 'false'
}

@test "release-ref: a missing ref is refused rather than defaulted (#1012)" {
  run bash "${RESOLVER}" prerelease
  assert_failure
  refute_output 'false'
}

@test "release-ref: an unrecognised subcommand is refused and names what it does answer (#1012)" {
  run bash "${RESOLVER}" is-it-a-prerelease-maybe v0.42.0
  assert_failure
  assert_output --partial 'prerelease'
}

# ── The population of sites, derived from the workflow tree ──────────

@test "release-ref: every prerelease: input in the workflow tree is fed by a step output (#1012)" {
  local _line _sites=0 _scanned=0
  while IFS= read -r _line; do
    if [[ "${_line}" == 'scanned='* ]]; then
      _scanned="${_line#scanned=}"
      continue
    fi
    _sites=$(( _sites + 1 ))
    [[ "${_line}" =~ steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+ ]] || fail \
      "${_line} -- a prerelease: input must take its value from the step that ran script/ci/release-ref.sh, not from an expression written here."
  done < <(_prerelease_inputs)
  [[ "${_scanned}" -gt 0 ]] || fail \
    "no workflow was scanned at all -- the tree moved and this assertion is vacuous."
  [[ "${_sites}" -ge 2 ]] || fail \
    "only ${_sites} prerelease: input(s) found across ${_scanned} workflow(s); base cuts its own release and downstream releases, so at least two are expected. A scan that stopped matching reports agreement forever."
}

@test "release-ref: no workflow restates the prerelease test itself (#1012)" {
  run _restated_predicates
  assert_success
  refute_output --partial 'finding:'
  refute_output --partial 'scanned=0'
}

@test "release-ref: every workflow that declares a prerelease: input calls the classifier (#1012)" {
  local _f _sites=0
  # No `grep -q`: an early-closing reader on the far side of a pipe is the
  # SIGPIPE race the harness shims exist to catch. These read the whole
  # stream and discard it.
  while IFS= read -r _f; do
    code_grep -E '^[[:space:]]*prerelease:' "${_f}" > /dev/null || continue
    _sites=$(( _sites + 1 ))
    code_grep -F 'script/ci/release-ref.sh' "${_f}" > /dev/null || fail \
      "${_f##*/} declares a prerelease: input but never calls script/ci/release-ref.sh -- the answer is computed somewhere other than the one place that owns the rule."
  done < <(_workflow_files)
  [[ "${_sites}" -ge 2 ]] || fail \
    "only ${_sites} workflow(s) declare a prerelease: input; the derivation found nothing to check."
}
