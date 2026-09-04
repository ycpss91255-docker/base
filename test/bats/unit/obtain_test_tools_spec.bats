#!/usr/bin/env bats
#
# obtain_test_tools_spec.bats -- unit tests for the one path by which a
# CI job gets the tooling image it runs inside.
#
# why: Six jobs of self-test.yaml consume
# `ghcr.io/ycpss91255-docker/test-tools:main`. Five pulled it, probed it
# and rebuilt from source when the probe refused; the sixth -- the
# `acceptance` job, which scaffolds a downstream repo and runs
# `just docker build test` against a lint stage that is
# `FROM ${TEST_TOOLS_IMAGE}` -- pulled it and exited 0. It is precisely
# the job the mitigation was written for, and it is the one that did not
# get it, because the mitigation was a block of shell pasted into each
# job and a paste is something a person has to remember to do.
#
# So the decision is a script and the jobs call it. What the script
# decides is asserted here through a docker seam, with no daemon; that
# no job reaches past it is asserted at the bottom, over the workflow
# tree rather than over a list of job names.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  OBTAIN=/source/script/ci/obtain_test_tools.sh
  WF_DIR=/source/.github/workflows
  assert_spec_subject "${OBTAIN}" \
      "the CI-side obtain path this spec drives"
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow directory whose jobs must reach the image through it"
  OUT="${BATS_TEST_TMPDIR}/github_output"
  : > "${OUT}"
}

# _src -- source the script so a test drives the REAL function bodies.
_src() {
  printf 'source %s' "${OBTAIN}"
}

# _seams <pull-status> <probe-status>
#   Stand-ins for the four docker / probe seams, so the decision is
#   exercised with no daemon and every side effect is observable as a
#   line on stdout.
_seams() {
  printf '
_obtain_pull() { printf "pull %%s\\n" "$1"; return %s; }
_obtain_retag() { printf "retag %%s\\n" "$2"; }
_obtain_probe() { printf "probe %%s\\n" "$1"; return %s; }
_obtain_build() { printf "build %%s\\n" "$1"; }
' "${1}" "${2}"
}

# why: The hot path. A `:main` that corresponds to this checkout is used
# as it is, and the local rebuild is skipped -- which is the whole reason
# the pull exists.
@test "obtain: a pulled image that passes the probe is used as-is (#1010)" {
  run bash -c "$(_src); $(_seams 0 0); TESTTOOLS_CHANGED=false CI_RUN_KEY=k \
      GITHUB_OUTPUT='${OUT}' _obtain_decide img linux/amd64"
  assert_success
  assert_line --partial 'probe img'
  run cat "${OUT}"
  assert_line 'build_local=false'
}

# why: The reported defect, as behaviour. A pulled image the probe
# refuses must fall back to the source build -- the strict side, which
# self-corrects against a stale, racing or old `:main` whatever the
# cause -- and it must say why, because a silent rebuild is a five-minute
# cost nobody can attribute.
@test "obtain: a pulled image the probe refuses is rebuilt, loudly (#1010)" {
  run bash -c "$(_src); $(_seams 0 1); TESTTOOLS_CHANGED=false CI_RUN_KEY=k \
      GITHUB_OUTPUT='${OUT}' _obtain_decide img linux/amd64"
  assert_success
  assert_output --partial '::warning::'
  run cat "${OUT}"
  assert_line 'build_local=true'
}

# why: No image to probe is not a passing probe. A registry that cannot
# be reached leaves the run with nothing, and nothing must resolve to the
# source build rather than to an empty comparison.
@test "obtain: a pull that fails resolves to the source build (#1010)" {
  run bash -c "$(_src); $(_seams 1 0); TESTTOOLS_CHANGED=false CI_RUN_KEY=k \
      GITHUB_OUTPUT='${OUT}' _obtain_decide img linux/amd64"
  assert_success
  refute_output --partial 'probe img'
  run cat "${OUT}"
  assert_line 'build_local=true'
}

# why: When the PR itself changes the Dockerfile, `:main` is stale for it
# by definition -- so the pull is not attempted at all. Asserted on the
# ABSENCE of the pull rather than on the verdict alone: the verdict is
# the same either way, and pulling first would spend the minute anyway.
@test "obtain: a PR that changes the Dockerfile does not pull at all (#1010)" {
  run bash -c "$(_src); $(_seams 0 0); TESTTOOLS_CHANGED=true CI_RUN_KEY=k \
      GITHUB_OUTPUT='${OUT}' _obtain_decide img linux/amd64"
  assert_success
  refute_output --partial 'pull '
  refute_output --partial 'probe '
  run cat "${OUT}"
  assert_line 'build_local=true'
}

# why: The two jobs that cannot use the cached buildx action -- they run
# the docker driver so `docker compose build`'s `FROM ${TEST_TOOLS_IMAGE}`
# resolves against the host daemon -- need the fallback build to happen
# HERE rather than in a following step. One flag, so the difference
# between the two callers is one word rather than two copies.
@test "obtain: inline mode performs the fallback build itself (#1010)" {
  run bash -c "$(_src); $(_seams 1 0); TESTTOOLS_CHANGED=false CI_RUN_KEY=k \
      GITHUB_OUTPUT='${OUT}' main img --platform linux/amd64 --local-build inline"
  assert_success
  assert_output --partial 'build img'
}

# why: The mirror. In delegate mode the build is a later workflow step
# gated on the output, so performing it here would build the image twice.
@test "obtain: delegate mode leaves the build to its caller (#1010)" {
  run bash -c "$(_src); $(_seams 1 0); TESTTOOLS_CHANGED=false CI_RUN_KEY=k \
      GITHUB_OUTPUT='${OUT}' main img --platform linux/amd64 --local-build delegate"
  assert_success
  refute_output --partial 'build img'
  run cat "${OUT}"
  assert_line 'build_local=true'
}

# ── no job reaches past it ────────────────────────────────────────────

# _hand_rolled_obtains
#   One `<file>: <line>` for every workflow run-block CODE line that names
#   the rolling tag directly. Every such line is a copy of the obtain
#   decision, and a copy is what the acceptance job's missing probe was.
_hand_rolled_obtains() {
    local _f _blocks _code _line _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        _status=0
        _blocks="$(yaml_run_blocks "${_f}")" || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf 'BUG: could not read the run blocks of %s\n' "${_f}"
            continue
        fi
        _code="$(printf '%s\n' "${_blocks}" | grep -v '^[[:space:]]*#')" || :
        while IFS= read -r _line; do
            case "${_line}" in
                *test-tools:main*) printf '%s: %s\n' "${_f}" "${_line}" ;;
            esac
        done <<< "${_code}"
    done < <(workflow_files "${WF_DIR}")
}

# why: The structural half of the same defect, and the half that stops it
# recurring. While the decision was shell pasted into each consuming job,
# nothing could tell a job that probes from a job that does not -- no
# single copy looked wrong, and the one without a probe read like the
# others. A job that reaches the rolling tag without going through the
# script is that copy, whoever writes it next.
@test "workflows: no job obtains the rolling test-tools tag by hand (#1010)" {
  local _n
  _n="$(workflow_files "${WF_DIR}" | awk 'END { print NR }')"
  [[ "${_n}" -ge 8 ]] || fail \
      "expected the tree's workflows, derived ${_n} -- the scan below would have read an empty set as a clean one"
  run _hand_rolled_obtains
  assert_success
  assert_output ''
}
