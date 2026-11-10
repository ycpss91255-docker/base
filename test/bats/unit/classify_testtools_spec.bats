#!/usr/bin/env bats
#
# classify_testtools_spec.bats -- does the classifier know when the
# tooling image is stale?
#
# why: `testtools_changed` tells every image-consuming job whether to
# rebuild the tooling image from source instead of pulling the rolling
# `:main`. On a pull request it is computed from the diff; on every other
# event it was the literal `false`, including the one event that can
# answer it -- a push to main whose commit is what makes `:main` stale in
# the first place. So the merge that added a tool to the Dockerfile ran
# the whole post-merge suite inside the image from before it. The probe
# was supposed to compensate and was itself too narrow to notice; both
# halves are the same incident, and this is the half that can be
# answered from the diff.
#
# The cases drive the REAL classify step against a synthetic push, so
# each reads the output the step writes.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SELF_WF=/source/.github/workflows/self-test.yaml
  assert_spec_subject "${SELF_WF}" \
      "the workflow whose classifier this spec drives"
}

# _classify_event <event> <repo-relative-path> [--root]
#   Runs self-test's OWN classify step against a synthetic history whose
#   head commit changes <path> and nothing else, reported to the step as
#   <event>. With `--root` the history is ONE commit, so `HEAD^` does not
#   resolve and the diff cannot be taken at all. Prints the GITHUB_OUTPUT
#   the step wrote.
_classify_event() {
  local _e="${1:?BUG: _classify_event expects an event}"
  local _p="${2:?BUG: _classify_event expects a path}"
  local _root="${3:-}"
  local _d="${BATS_TEST_TMPDIR}/push"
  rm -rf "${_d}"
  mkdir -p "${_d}/$(dirname "${_p}")"
  ln -s /source/script "${_d}/script"
  printf 'a\n' > "${_d}/${_p}"
  git -C "${_d}" init -q -b main
  git -C "${_d}" config user.email ci@example.invalid
  git -C "${_d}" config user.name ci
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m base
  if [[ "${_root}" != "--root" ]]; then
    printf 'b\n' >> "${_d}/${_p}"
    git -C "${_d}" commit -q -a -m change
  fi
  yaml_step_run "${SELF_WF}" classify diff > "${_d}/step.sh"
  [ -s "${_d}/step.sh" ] || return 2
  : > "${_d}/out"
  (
    cd "${_d}" || return 2
    env EVENT_NAME="${_e}" BASE_REF= GITHUB_OUTPUT="${_d}/out" bash step.sh
  ) >/dev/null 2>&1
  cat "${_d}/out"
}

# _classify_push <repo-relative-path>
#   The push case of the above, which is the only event that can answer
#   `testtools_changed` from a diff.
_classify_push() {
  _classify_event push "${1:?BUG: _classify_push expects a path}"
}

# _classify_pr <repo-relative-path>
#   The pull-request arm of the same step, which is the arm every PR's
#   image jobs read. The base ref is planted as `refs/remotes/origin/main`
#   because that is the name the step resolves; its own `git fetch` has no
#   remote to reach and is already tolerated by the step's `|| true`.
#
#   The base commit holds a real copy of /source/script, not a link to it:
#   base#1584 judges a PR with the map read from the BASE side through
#   `git show <base>:script/ci/...`, and git cannot read a file through a
#   committed symlink (`git show HEAD:script/ci/a.sh` exits 128 when
#   `script` is a link). dist/ and dockerfile/ are copied beside it because
#   script/ci/testtools_paths.sh reads them relative to its own location
#   (`../../dist/script/docker/lib/project_reclaim.sh` and the Dockerfile),
#   which the link used to resolve into /source.
_classify_pr() {
  local _p="${1:?BUG: _classify_pr expects a path}"
  local _d="${BATS_TEST_TMPDIR}/pr" _t
  rm -rf "${_d}"
  mkdir -p "${_d}"
  for _t in script dist dockerfile; do
    cp -a "/source/${_t}" "${_d}/${_t}"
  done
  mkdir -p "${_d}/$(dirname "${_p}")" "${_d}/doc"
  printf 'seed\n' > "${_d}/doc/seed.md"
  printf 'a\n' > "${_d}/${_p}"
  git -C "${_d}" init -q -b main
  git -C "${_d}" config user.email ci@example.invalid
  git -C "${_d}" config user.name ci
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m base
  git -C "${_d}" update-ref refs/remotes/origin/main HEAD
  printf 'b\n' >> "${_d}/${_p}"
  git -C "${_d}" commit -q -a -m change
  yaml_step_run "${SELF_WF}" classify diff > "${_d}/step.sh"
  [ -s "${_d}/step.sh" ] || return 2
  : > "${_d}/out"
  (
    cd "${_d}" || return 2
    env EVENT_NAME=pull_request BASE_REF=main GITHUB_OUTPUT="${_d}/out" \
        bash step.sh
  ) >/dev/null 2>&1
  cat "${_d}/out"
}

# _context_copy_paths
#   Every build-context path the tooling Dockerfile COPYs, read off the
#   DOCKERFILE through the shared reader rather than through the signal
#   under test: a population computed by the subject would certify the
#   subject against itself.
#
#   Filtered to paths that exist in this checkout, because each one is
#   driven by committing a change to it. The shapes the reader cannot
#   resolve -- a glob, a variable, a line continuation -- are the
#   derivation's own business and are asserted where it lives, in
#   testtools_paths_spec.bats.
_context_copy_paths() {
  local _p
  dockerfile_context_copy_srcs /source/dockerfile/Dockerfile.test-tools \
    | while IFS= read -r _p; do
        [[ -n "${_p}" && -e "/source/${_p}" ]] && printf '%s\n' "${_p}"
      done
}

# why: The reported case. A push to main that changes the test-tools
# Dockerfile is exactly the push for which the rolling tag is stale --
# the republish that would refresh it is racing this very run -- and it
# was the push that reported the image unchanged.
@test "classify: a push that changes the test-tools Dockerfile rebuilds it (#1010)" {
  run _classify_push dockerfile/Dockerfile.test-tools
  assert_success
  assert_line 'testtools_changed=true'
}

# why: The guard against answering true to every push, which would put a
# full multi-arch tooling build in front of every merge. A push that
# leaves the Dockerfile alone takes the pull path, where the probe is now
# the thing that catches a stale image.
@test "classify: a push that leaves it alone still pulls (#1010)" {
  run _classify_push doc/guide.md
  assert_success
  assert_line 'testtools_changed=false'
}

# why: A non-PR event still runs the full suite. The flag being
# computable now must not narrow what a push runs.
@test "classify: a push is still code-changed and system-relevant (#1010)" {
  run _classify_push doc/guide.md
  assert_success
  assert_line 'code_changed=true'
  assert_line 'system_relevant=true'
}

# why: The fail-safe direction the step's own comment promises and did not
# take. `workflow_dispatch` has no previous commit to diff against, so the
# classifier cannot know whether the rolling tag corresponds to this ref --
# and it answered `false`, which is the side that USES an image it could
# not check. The path here is deliberately not the Dockerfile, so a `true`
# can only come from the default and never from a diff.
@test "classify: an event that cannot be diffed still rebuilds (#1010)" {
  run _classify_event workflow_dispatch doc/guide.md
  assert_success
  assert_line 'testtools_changed=true'
}

# why: The other half of the same promise, and the half that already held:
# a push whose `HEAD^` does not resolve is a diff that cannot be taken, not
# an answer of "unchanged". Pinned because the fix above rewrites the
# branch that decides it, and a rewrite that inverted this one would look
# green against the dispatch case alone.
@test "classify: a push with no parent to diff still rebuilds (#1010)" {
  run _classify_event push doc/guide.md --root
  assert_success
  assert_line 'testtools_changed=true'
}

# ── the inputs that are not the Dockerfile ────────────────────────────

# why: The defect this spec was extended for. The signal named one path,
# and the tooling image has more inputs than that: a plain build-context
# COPY bakes a file of the checkout into the image, so editing that file
# alone leaves a `:main` that no longer describes the tree while the
# classifier reports the image unchanged. The population is read off the
# Dockerfile, so the next COPY anyone adds brings its own case with it
# instead of waiting for someone to remember this list.
@test "classify: a push that changes a file the Dockerfile COPYs rebuilds it (#1171)" {
  local _p _missed=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    run _classify_push "${_p}"
    assert_success
    grep -qx 'testtools_changed=true' <<< "${output}" \
      || _missed="${_missed}${_p}"$'\n'
  done < <(_context_copy_paths)
  [[ -z "${_missed}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context, and a push that changes one reports the image unchanged:"$'\n'"${_missed}"
}

# why: The same miss on the arm every pull request takes, which is the
# expensive one: the PR arm's `false` sends `obtain_test_tools.sh` down its
# layer-2 path, so the whole suite runs inside the rolling `:main` -- an
# image built before the edit, and one nothing on the PR path refreshes.
@test "classify: a PR that changes a file the Dockerfile COPYs rebuilds it (#1171)" {
  local _p _missed=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    run _classify_pr "${_p}"
    assert_success
    grep -qx 'testtools_changed=true' <<< "${output}" \
      || _missed="${_missed}${_p}"$'\n'
  done < <(_context_copy_paths)
  [[ -z "${_missed}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context, and a PR that changes one runs inside the stale rolling tag:"$'\n'"${_missed}"
}

# why: The guard that keeps the two cases above from being bought by
# answering `true` to everything. "Anything changed" would rebuild the
# tooling image on every pull request and throw away the pull path the
# rolling tag exists for.
@test "classify: a PR that changes nothing the image reads still pulls (#1171)" {
  run _classify_pr doc/guide.md
  assert_success
  assert_line 'testtools_changed=false'
}

# why: The Dockerfile's own case on the PR arm, pinned alongside the two
# above so a rewrite that reaches for the derivation cannot drop the one
# input the signal already had.
@test "classify: a PR that changes the test-tools Dockerfile rebuilds it (#1171)" {
  run _classify_pr dockerfile/Dockerfile.test-tools
  assert_success
  assert_line 'testtools_changed=true'
}

# why: base#1584 lets a pull request skip a heavy job its diff cannot
# affect, and main must keep running everything (owner decision). The
# rollup reads one select_<job> output per heavy job (config-gen,
# mutation-roster, coverage, acceptance, system, as the issue names
# them), and an empty output fails it. So the push arm, which is what
# main runs, has to write every one of them as `true`.
@test "classify: a push writes every heavy job's selection as true (base#1584)" {
  run _classify_push doc/guide.md
  assert_success
  local _job _missed=""
  for _job in select_config_gen select_mutation_roster select_coverage \
              select_acceptance select_system; do
    grep -qx "${_job}=true" <<< "${output}" \
      || _missed="${_missed} ${_job}"
  done
  [[ -z "${_missed}" ]] || fail \
      "a push run left these selections unset or false:${_missed}"$'\n'"output:"$'\n'"${output}"
}

# why: base#1584 says a pull request touching a path the map does not
# know runs every heavy job (fail closed). The map's own CLI already
# answers that (check_selection_spec.bats), but the rollup and the job
# gates read what classify's diff step WRITES, so the pull-request arm
# of the real step has to carry the answer through. `zz-new/thing.txt`
# names no directory the repo has, so no exclusion can apply to it.
@test "classify: a pull request touching an unknown path writes every heavy job's selection as true (base#1584)" {
  run _classify_pr zz-new/thing.txt
  assert_success
  local _job _missed=""
  for _job in select_config_gen select_mutation_roster select_coverage \
              select_acceptance select_system; do
    grep -qx "${_job}=true" <<< "${output}" \
      || _missed="${_missed} ${_job}"
  done
  [[ -z "${_missed}" ]] || fail \
      "a pull request touching an unknown path left these selections unset or false:${_missed}"$'\n'"output:"$'\n'"${output}"
}

# _chain_results <classify-output>
#   Prints `<job> <success|skipped>` for every job of the workflow, in file
#   order, for a pull_request run whose classify diff step wrote
#   <classify-output> (GITHUB_OUTPUT lines) and in which every job that runs
#   succeeds. Composes the step's output through the classify job's own
#   `outputs:` map and each job's parsed `if:`, so a key the step writes but
#   the job does not export reads empty, as it does on GitHub. A job runs
#   when its `if:` holds and every job it needs succeeded (the implicit
#   `success() &&` of a job-level `if:`); `always()` runs it whatever its
#   needs did. Any other `if:` shape returns 2, so a gate this reader cannot
#   evaluate fails the case instead of being guessed.
_chain_results() {
  local _step_out="${1}" _k _v _j _if _n _ok
  local -A _cls=() _res=()
  while read -r _k _v; do
    [[ -n "${_k}" ]] || continue
    if [[ "${_v}" =~ ^\$\{\{\ steps\.diff\.outputs\.([a-z_]+)\ \}\}$ ]]; then
      _cls["${_k}"]="$(sed -n "s/^${BASH_REMATCH[1]}=//p" <<< "${_step_out}" | tail -n 1)"
    else
      _cls["${_k}"]=""
    fi
  done < <(yq '.jobs.classify.outputs | to_entries[] | .key + " " + .value' "${SELF_WF}")
  while IFS= read -r _j; do
    [[ -n "${_j}" ]] || continue
    _if="$(LP_J="${_j}" yq '.jobs[strenv(LP_J)].if // ""' "${SELF_WF}")"
    _ok=1
    while IFS= read -r _n; do
      [[ -n "${_n}" ]] || continue
      [[ -n "${_res[${_n}]:-}" ]] || { echo "BUG: ${_j} needs ${_n}, which comes later"; return 2; }
      [[ "${_res[${_n}]}" == "success" ]] || _ok=0
    done < <(LP_J="${_j}" yq '.jobs[strenv(LP_J)].needs // [] | (select(tag == "!!seq") | .[]), select(tag == "!!str")' "${SELF_WF}")
    if [[ "${_j}" == "classify" ]]; then
      _ok=1
    elif [[ -z "${_if}" ]]; then
      :
    elif [[ "${_if}" =~ ^needs\.classify\.outputs\.([a-z_]+)\ ==\ \'true\'$ ]]; then
      [[ "${_cls[${BASH_REMATCH[1]}]:-}" == "true" ]] || _ok=0
    elif [[ "${_if}" == "always()" ]]; then
      _ok=1
    elif [[ "${_if}" == "startsWith(github.ref, 'refs/tags/')" ]]; then
      _ok=0
    else
      echo "BUG: ${_j} has an if: this reader cannot evaluate: ${_if}"
      return 2
    fi
    if [[ "${_ok}" -eq 1 ]]; then _res["${_j}"]=success; else _res["${_j}"]=skipped; fi
    printf '%s %s\n' "${_j}" "${_res[${_j}]}"
  done < <(yaml_job_names "${SELF_WF}")
}

# _chain_rollup <classify-output> <chain-results>
#   Runs ci-rollup's OWN `Verify upstream jobs` step, lifted from the YAML,
#   with every env key bound from the expression it declares: a
#   `needs.<job>.result` from <chain-results>, a `needs.classify.outputs.<k>`
#   through classify's `outputs:` map from <classify-output>, `toJSON(needs)`
#   as the JSON of the same two, and IS_FORK_PR as a same-repo PR. A key
#   bound any other way returns 2.
_chain_rollup() {
  local _step_out="${1}" _results="${2}" _k _v _j _r _json="" _o
  local -A _cls=() _res=()
  local -a _env=()
  while read -r _k _v; do
    [[ -n "${_k}" ]] || continue
    _cls["${_k}"]=""
    if [[ "${_v}" =~ ^\$\{\{\ steps\.diff\.outputs\.([a-z_]+)\ \}\}$ ]]; then
      _cls["${_k}"]="$(sed -n "s/^${BASH_REMATCH[1]}=//p" <<< "${_step_out}" | tail -n 1)"
    fi
  done < <(yq '.jobs.classify.outputs | to_entries[] | .key + " " + .value' "${SELF_WF}")
  while read -r _j _r; do
    [[ -n "${_j}" ]] && _res["${_j}"]="${_r}"
  done <<< "${_results}"
  while IFS= read -r _j; do
    [[ -n "${_j}" ]] || continue
    _o="{}"
    if [[ "${_j}" == "classify" ]]; then
      _o=""
      for _k in "${!_cls[@]}"; do
        _o+="${_o:+,}\"${_k}\":\"${_cls[${_k}]}\""
      done
      _o="{${_o}}"
    fi
    _json+="${_json:+,}\"${_j}\":{\"result\":\"${_res[${_j}]:-}\",\"outputs\":${_o}}"
  done < <(yq '.jobs."ci-rollup".needs[]' "${SELF_WF}")
  _json="{${_json}}"
  while read -r _k _v; do
    [[ -n "${_k}" ]] || continue
    if [[ "${_k}" == "IS_FORK_PR" ]]; then
      _env+=("IS_FORK_PR=false")
    elif [[ "${_v}" =~ ^\$\{\{\ needs\.([a-z-]+)\.result\ \}\}$ ]]; then
      _env+=("${_k}=${_res[${BASH_REMATCH[1]}]:-}")
    elif [[ "${_v}" =~ ^\$\{\{\ needs\.classify\.outputs\.([a-z_]+)\ \}\}$ ]]; then
      _env+=("${_k}=${_cls[${BASH_REMATCH[1]}]:-}")
    elif [[ "${_v}" =~ ^\$\{\{\ toJSON\(needs\)\ \}\}$ ]]; then
      _env+=("${_k}=${_json}")
    else
      echo "BUG: rollup env ${_k} is bound in a way this reader does not know: ${_v}"
      return 2
    fi
  done < <(yq '.jobs."ci-rollup".steps[]
      | select(.name == "Verify upstream jobs") | .env | to_entries[]
      | .key + " " + .value' "${SELF_WF}")
  yaml_step_run "${SELF_WF}" ci-rollup 'Verify upstream jobs' \
      > "${BATS_TEST_TMPDIR}/chain-rollup.sh"
  [ -s "${BATS_TEST_TMPDIR}/chain-rollup.sh" ] || return 2
  env "${_env[@]}" bash "${BATS_TEST_TMPDIR}/chain-rollup.sh"
}

# why: base#1584 redesign r7, cycle 1, end to end on a PR that changes one
# unit spec in no roster TSV. The expected set comes from the issue and the
# design, not from the map: a unit spec cannot affect config-gen,
# acceptance, system or worker-selftest, so those four skip; it is code,
# so shellcheck, hadolint, bats-fragile, coverage and coverage-gate run;
# and mutation-roster keeps main's form, no `if:` (roster row selection
# belongs to base#1604), so it runs on every PR. Read through classify's
# real step, its `outputs:` map, every job's parsed `if:` and the real
# rollup step, so a gate that reads the wrong output, an output classify
# does not export, or a classify that never carries a `false` all change
# the set, and the rollup must pass the run that results.
@test "chain: a PR changing one unit spec runs the code checks and mutation-roster, skips the other gated jobs, and the rollup passes (base#1584)" {
  local _out _results _j _want _got _bad=""
  _out="$(_classify_pr test/bats/unit/ci_spec.bats)"
  run _chain_results "${_out}"
  assert_success
  _results="${output}"
  for _want in shellcheck=success hadolint=success bats-fragile=success \
               coverage=success coverage-gate=success \
               mutation-roster=success \
               config-gen=skipped acceptance=skipped system=skipped \
               worker-selftest=skipped; do
    _j="${_want%%=*}"
    _got="$(awk -v j="${_j}" '$1 == j {print $2}' <<< "${_results}")"
    [[ "${_got}" == "${_want#*=}" ]] || _bad+="${_j}: want ${_want#*=}, got ${_got:-<none>}"$'\n'
  done
  [[ -z "${_bad}" ]] || fail "the run set differs:
${_bad}classify wrote:
${_out}"
  run _chain_rollup "${_out}" "${_results}"
  assert_success
}
