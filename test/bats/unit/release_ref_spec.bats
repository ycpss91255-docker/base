#!/usr/bin/env bats
#
# release_ref_spec.bats -- the ONE classifier of a released ref, and the
# derived proof that no workflow site restates the prerelease rule
# instead of asking whichever script owns it.
#
# ── The question, and why it was asked three times ──────────────────────
#
# "Is this a prerelease?" decides two different things in this repo, and
# both of them are consumed org-wide:
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
# ── One home per classified THING, not one home overall ─────────────────
#
# The three sites do not all classify the same kind of value, and the
# rule has to be stated at the level where that is true.
#
#   a git REF          self-test.yaml, release-test-tools.yaml -- both run
#                      on a tag push and hold `github.ref_name`. Owner:
#                      script/ci/release-ref.sh.
#   a release VERSION  release-worker.yaml -- it now takes a
#                      `version` input, because an event created with the
#                      default GITHUB_TOKEN starts no workflow run, so a
#                      repo auto-releasing a merged change cannot get here
#                      by pushing a tag and its ref is a BRANCH that names
#                      no version. Owner: script/ci/release-version.sh,
#                      which resolves the version and its prerelease flag
#                      in one step.
#
# Both owners refuse an input they cannot read rather than answering
# `false` for it, which is the whole point; what would break the rule is a
# workflow spelling the test in an expression of its own, from either
# side. So: a `prerelease:` input must take its value from the step that
# ran the classifier owning ITS OWN input, and no workflow may write the
# predicate inline. Asking release-ref.sh about a branch ref would be the
# original defect wearing the fix's clothes -- it is not "call this one
# script", it is "do not be the third copy of the rule".
#
# The population of sites is DERIVED from .github/workflows/, never listed
# here: a guard for "every site" that consulted a remembered list of three
# would pass on precisely the fourth site added tomorrow. The classifier
# behind each site is derived too -- read out of the step the input names,
# not out of a table here -- so the scan cannot go on approving a step
# that stopped running a script at all.
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
#
# why: "Is this tag a prerelease?" decides whether a GitHub Release is
# marked prerelease (`release-worker.yaml` for downstream repos,
# `self-test.yaml` for base) and whether `release-test-tools.yaml` moves
# `test-tools:latest` -- the image every repo that has not pinned
# `test_tools_version` builds its lint stage from, that input's default
# being `latest`. Two sites spelled the test themselves and the third did
# not ask, which is how `v0.42.0-rc1` through `-rc4` each moved `:latest`.
#
# `script/ci/release-ref.sh` is the one home for that rule ON A GIT REF;
# `release-worker.yaml` now classifies a VERSION input instead, and
# `script/ci/release-version.sh` owns it there. The first nine cases pin
# what release-ref.sh answers -- including that it REFUSES a ref it cannot
# read as a version tag, because the alternative answer (`false`) is the
# branch that publishes. The last three derive the population of asking
# sites from `.github/workflows/` rather than listing it, and the
# classifier behind each site from the step that input names, so neither a
# fourth site nor a second owner can be the one nobody checks.

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

# _step_run_by_id <file> <id> -- the `run:` script of the step carrying
# `id: <id>`, wherever in <file> it lives. The job is searched for rather
# than named, because the caller starts from an expression
# (`steps.<id>.outputs.…`) that names a step and never a job -- which is
# also why a spec must not carry the pairing: GitHub resolves `steps.<id>`
# within the job, and a table here would go on naming a job the workflow
# renamed.
#
# Nothing on stdout when no such step exists, or when the file cannot be
# read as YAML at all: both leave the caller's `[ -n ... ]` guard to fail
# the assertion loudly, rather than an empty script passing a scan for
# what a step does not contain.
_step_run_by_id() {
  local _file="${1}" _id="${2}" _jobs _job _run _status=0
  _jobs="$(yaml_job_names "${_file}")" || _status=$?
  if [[ "${_status}" -ne 0 ]]; then
    printf '%s\n' "${_jobs}" >&2
    return 1
  fi
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    _run="$(yaml_step_run "${_file}" "${_job}" "${_id}")" || continue
    if [[ -n "${_run}" ]]; then
      printf '%s\n' "${_run}"
      return 0
    fi
  done <<< "${_jobs}"
  return 1
}

# _ci_scripts_run_by <run-script> -- every `script/ci/…` path the given
# step body names, one per line, as a path relative to the checkout. A step
# may check the worker source out under a prefix of its own
# (`.release-base/`), so the match starts at `script/ci/` and the prefix is
# discarded: what the assertion is about is WHICH script answered, not
# where that step happened to put it.
_ci_scripts_run_by() {
  printf '%s\n' "${1}" \
    | grep -oE 'script/ci/[A-Za-z0-9_./-]+\.sh' \
    | sort -u
}

# _answers_prerelease <relpath> -- true when <relpath> is a script in this
# tree that COMPUTES a prerelease verdict, judged by its own code and not
# by a list here.
#
# `script/ci/` holds release-named scripts that answer something else
# entirely -- release-archive.sh assembles a payload -- so "the step runs a
# release-*.sh" is not the property; naming the two owners outright is not
# either, because the day a third classification is added the guard would
# still be checking for the two it remembers. Comments do not count:
# abi-gate.sh explains in prose why it refuses a prerelease version and
# computes no verdict at all.
_answers_prerelease() {
  local _abs="/source/${1}"
  [[ -f "${_abs}" ]] || return 1
  code_grep -E 'prerelease' "${_abs}" > /dev/null
}

# ── The classifier's answers ─────────────────────────────────────────

# why: `v0.42.0` -> `false`. The one answer that lets `:latest` move, so it
# is the case a wrong rule fails open on.
@test "release-ref: a finished release tag is not a prerelease (#1012)" {
  run bash "${RESOLVER}" prerelease v0.42.0
  assert_success
  assert_output 'false'
}

# why: `v0.42.0-rc4` -> `true`. The four tags that each moved `:latest`, for
# the length of an RC window.
@test "release-ref: an RC tag is a prerelease (#1012)" {
  run bash "${RESOLVER}" prerelease v0.42.0-rc4
  assert_success
  assert_output 'true'
}

# why: `GITHUB_REF` and `github.ref_name` are both accepted, so a caller
# passes whichever it holds instead of trimming one into the other and
# getting it wrong.
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

# why: The `v` this project's tags carry is stripped, not required: the rule
# is SemVer's, not this repo's tag style.
@test "release-ref: the leading v is optional (#1012)" {
  run bash "${RESOLVER}" prerelease 0.42.0-rc4
  assert_success
  assert_output 'true'
  run bash "${RESOLVER}" prerelease 0.42.0
  assert_success
  assert_output 'false'
}

# why: SemVer 10 (`+build.5`) says nothing about precedence; SemVer 9
# (`-rc.1`) does. The pair is what separates the rule from a dash test.
@test "release-ref: build metadata is not a prerelease, a dotted prerelease id is (#1012)" {
  # SemVer 9 vs 10: `+build` says nothing about precedence, `-rc.1` does.
  run bash "${RESOLVER}" prerelease v1.0.0+build.5
  assert_success
  assert_output 'false'
  run bash "${RESOLVER}" prerelease v1.0.0-rc.1+build.5
  assert_success
  assert_output 'true'
}

# why: The defect the inline `contains(ref_name, '-')` carries: it is true
# of `feature/add-thing`, and it is the reason the rule has one home.
@test "release-ref: a branch whose name merely contains a dash is refused, not answered (#1012)" {
  # The defect the one-line `contains(ref_name, '-')` carries: it is TRUE
  # of every such branch. Refusing is the only safe answer, because the
  # other one -- `false` -- is the branch that publishes.
  run bash "${RESOLVER}" prerelease refs/heads/feature/add-thing
  assert_failure
  refute_output 'false'
  assert_output --partial 'refs/heads/feature/add-thing'
}

# why: `main`, `v1.0`. Refusing is the only safe answer, because the other
# one (`false`) is the arm that moves `:latest`.
@test "release-ref: a ref that is not a version tag at all is refused (#1012)" {
  run bash "${RESOLVER}" prerelease main
  assert_failure
  refute_output 'false'
  run bash "${RESOLVER}" prerelease refs/tags/v1.0
  assert_failure
  refute_output 'false'
}

# why: No default: an absent ref would otherwise read as a finished release,
# which is the fail-open direction.
@test "release-ref: a missing ref is refused rather than defaulted (#1012)" {
  run bash "${RESOLVER}" prerelease
  assert_failure
  refute_output 'false'
}

# why: A caller that asked for something else asked for a reason; it must
# not fall through to the one question that exists.
@test "release-ref: an unrecognised subcommand is refused and names what it does answer (#1012)" {
  run bash "${RESOLVER}" is-it-a-prerelease-maybe v0.42.0
  assert_failure
  assert_output --partial 'prerelease'
}

# ── The population of sites, derived from the workflow tree ──────────

# why: The population is derived from `.github/workflows/` rather than
# remembered, so a fourth asking site added tomorrow is covered tomorrow.
@test "release-ref: every prerelease: input in the workflow tree is fed by a step output (#1012)" {
  local _line _sites=0 _scanned=0
  while IFS= read -r _line; do
    if [[ "${_line}" == 'scanned='* ]]; then
      _scanned="${_line#scanned=}"
      continue
    fi
    _sites=$(( _sites + 1 ))
    [[ "${_line}" =~ steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+ ]] || fail \
      "${_line} -- a prerelease: input must take its value from the step that ran the classifier owning its own input (script/ci/release-ref.sh for a git ref, script/ci/release-version.sh for a resolved version), not from an expression written here."
  done < <(_prerelease_inputs)
  [[ "${_scanned}" -gt 0 ]] || fail \
    "no workflow was scanned at all -- the tree moved and this assertion is vacuous."
  [[ "${_sites}" -ge 2 ]] || fail \
    "only ${_sites} prerelease: input(s) found across ${_scanned} workflow(s); base cuts its own release and downstream releases, so at least two are expected. A scan that stopped matching reports agreement forever."
}

# why: Neither spelling this tree has used -- the GitHub expression nor the
# shell glob -- may survive anywhere, or there are two rules again.
@test "release-ref: no workflow restates the prerelease test itself (#1012)" {
  run _restated_predicates
  assert_success
  refute_output --partial 'finding:'
  refute_output --partial 'scanned=0'
}

# why: The load-bearing half of "one rule, one home per classified thing":
# every asking site is followed back to the step it names, and that step
# must run a script that computes the answer. All three hops are derived --
# the sites from the workflow tree, the step from the expression, the
# classifier from the step and from script/ci/ -- because the one thing
# that cannot go stale is a table nobody wrote.
@test "release-ref: every prerelease: input is answered by a classifier under script/ci (#1012)" {
  local _f _line _id _run _path _owner _sites=0
  # No `grep -q`: an early-closing reader on the far side of a pipe is the
  # SIGPIPE race the harness shims exist to catch. These read the whole
  # stream and discard it.
  while IFS= read -r _f; do
    while IFS= read -r _line; do
      _sites=$(( _sites + 1 ))
      [[ "${_line}" =~ steps\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_-]+ ]] || fail \
        "${_f##*/}: ${_line} -- names no step to follow back, so nothing here can say what computed the answer."
      _id="${BASH_REMATCH[1]}"
      _run="$(_step_run_by_id "${_f}" "${_id}")" || true
      [[ -n "${_run}" ]] || fail \
        "${_f##*/}: the prerelease: input reads steps.${_id}.outputs.*, but no step carrying that id runs anything -- a value from a step that executes no script was computed by an expression."
      _owner=''
      while IFS= read -r _path; do
        [[ -n "${_path}" ]] || continue
        if _answers_prerelease "${_path}"; then
          _owner="${_path}"
        fi
      done < <(_ci_scripts_run_by "${_run}")
      [[ -n "${_owner}" ]] || fail \
        "${_f##*/}: step '${_id}' feeds the prerelease: input but runs nothing under script/ci/ that computes a prerelease answer -- the rule is being restated in the workflow instead of asked of the script that owns the classification of this site's own input (release-ref.sh owns a git ref, release-version.sh a resolved version)."
    done < <(code_grep -E '^[[:space:]]*prerelease:' "${_f}" || true)
  done < <(_workflow_files)
  [[ "${_sites}" -ge 2 ]] || fail \
    "only ${_sites} prerelease: input(s) found across the workflow tree; base cuts its own release and downstream releases, so at least two are expected. The derivation found nothing to check."
}
