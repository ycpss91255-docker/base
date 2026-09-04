#!/usr/bin/env bats
#
# system_paths_spec.bats -- "a diff that can change what the system specs
# observe classifies as system-relevant".
#
# why: `system_relevant` decides whether the docker.sock-mounted system
# job runs at all, and it was decided by a hand-kept list of seventeen
# paths that had drifted from the specs it is about. The list omitted
# `dockerfile/Dockerfile.smoke` -- the file `smoke_harness_spec.bats`
# BUILDS -- the shipped smoke specs that Dockerfile RUNs, the container
# runtime under `dist/script/docker/runtime/`, `setup_tui.sh` while
# listing `setup.sh`, and every justfile in the tree, in a repo whose
# stated position is that `just` is the only control surface. Editing any
# of them alone skipped the only job that exercises them.
#
# The classifier now reads its pathspecs from `script/ci/system_paths.sh`
# and this spec drives the REAL classify step against a synthetic PR per
# path, so each case asserts the OUTPUT the workflow writes rather than
# the presence of a line in a list. The last two cases are the opposite
# direction: the answer "everything is relevant" would pass every case
# above and delete the optimisation the output exists for.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SELF_WF=/source/.github/workflows/self-test.yaml
  PATHS_SH=/source/script/ci/system_paths.sh
  SYSTEM_SPEC_DIR=/source/test/bats/system
  assert_spec_subject "${SELF_WF}" \
      "the workflow whose classifier this spec drives"
  assert_spec_subject_dir "${SYSTEM_SPEC_DIR}" \
      "the system specs whose subjects the classifier has to cover"
}

# _classify <repo-relative-path>
#   Runs self-test's OWN classify step -- lifted out of the YAML, not a
#   copy of it -- against a synthetic pull request whose entire diff is
#   <path>. Prints the GITHUB_OUTPUT the step wrote.
#
#   The scratch repo carries `script` as a symlink into this checkout, so
#   the step reaches the same pathspec source the real run does. The base
#   ref is planted as `refs/remotes/origin/main` because that is the name
#   the step resolves; its own `git fetch` has no remote to reach and is
#   already tolerated by the step's `|| true`.
_classify() {
  local _p="${1:?BUG: _classify expects a path}"
  local _d="${BATS_TEST_TMPDIR}/cls"
  rm -rf "${_d}"
  mkdir -p "${_d}/$(dirname "${_p}")" "${_d}/doc"
  ln -s /source/script "${_d}/script"
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

# why: The reported case, asserted on what the classifier ANSWERS. The
# only spec that builds this Dockerfile is a system spec, and editing the
# Dockerfile alone skipped it -- so the file could stop building and the
# suite would still be green.
@test "classify: editing the Dockerfile a system spec builds is system-relevant (#1011)" {
  run _classify dockerfile/Dockerfile.smoke
  assert_success
  assert_line 'system_relevant=true'
}

# why: The justfiles. Every wrapper `.sh` was listed and none of the
# files that dispatch them were, in a repo whose position is that `just`
# is the only control surface -- so the one surface a user actually
# touches was the one surface the gate treated as unable to affect the
# system under test.
@test "classify: editing a justfile is system-relevant (#1011)" {
  run _classify justfile
  assert_success
  assert_line 'system_relevant=true'
  run _classify dist/script/docker/justfile.docker
  assert_success
  assert_line 'system_relevant=true'
}

# why: The shipped runtime -- entrypoint, smoke, watchdog, logrotate --
# is what runs INSIDE the container the system specs start. base's own
# `script/entrypoint.sh` was listed; the one that actually ships was not.
@test "classify: editing the shipped container runtime is system-relevant (#1011)" {
  run _classify dist/script/docker/runtime/entrypoint.sh
  assert_success
  assert_line 'system_relevant=true'
}

# why: The shipped smoke specs are the body of the image
# `Dockerfile.smoke` builds and `RUN bats`-es; a change to them changes
# what that build asserts.
@test "classify: editing the shipped smoke specs is system-relevant (#1011)" {
  run _classify dist/test/bats/smoke/smoke.sh
  assert_success
  assert_line 'system_relevant=true'
}

# why: `setup.sh` was listed and `setup_tui.sh` was not, though both emit
# the `.env` and `compose.yaml` the system job's compose run consumes.
# The pair is the shape of a hand-kept list: it names what somebody
# remembered.
@test "classify: editing the TUI half of setup is system-relevant (#1011)" {
  run _classify dist/script/docker/wrapper/setup_tui.sh
  assert_success
  assert_line 'system_relevant=true'
}

# why: The guard against buying every case above by answering "relevant"
# to everything. A doc-only PR must still classify as neither code nor
# system, or the classifier has stopped classifying.
@test "classify: a doc-only diff is neither code-changed nor system-relevant (#1011)" {
  run _classify doc/guide.md
  assert_success
  assert_line 'code_changed=false'
  assert_line 'system_relevant=false'
}

# why: The other half of that guard, and the reason `system_relevant`
# exists at all: a unit-spec-only PR is code, and it still skips the
# docker.sock-mounted system job.
@test "classify: a unit-spec-only diff is code, and still not system-relevant (#1011)" {
  run _classify test/bats/unit/example_spec.bats
  assert_success
  assert_line 'code_changed=true'
  assert_line 'system_relevant=false'
}

# ── the list, read against the specs it is about ──────────────────────

# _named_subjects
#   Every path under this checkout that a system spec's CODE names
#   through its `/source/` prefix -- the files those specs build, run and
#   read. Comments are stripped first: prose about a sibling spec names a
#   path the spec does not touch.
_named_subjects() {
    local _f _p
    for _f in "${SYSTEM_SPEC_DIR}"/*.bats; do
        [[ -f "${_f}" ]] || continue
        strip_comments "${_f}" \
            | grep -ohE '/source/[A-Za-z0-9_./-]+' \
            | sed -e 's|^/source/||' -e 's|[./]*$||'
    done | sort -u | while IFS= read -r _p; do
        [[ -n "${_p}" ]] || continue
        [[ -e "/source/${_p}" ]] || continue
        printf '%s\n' "${_p}"
    done
}

# _covered_by_pathspecs <path>
#   Does any emitted pathspec select <path>? `dir/**` selects everything
#   under dir; anything else has to name the path outright.
_covered_by_pathspecs() {
    local _path="${1}" _spec
    while IFS= read -r _spec; do
        [[ -n "${_spec}" ]] || continue
        case "${_spec}" in
            */\*\*)
                case "${_path}/" in "${_spec%\*\*}"*) return 0 ;; esac ;;
            *)
                [[ "${_path}" == "${_spec}" ]] && return 0 ;;
        esac
    done < <(bash "${PATHS_SH}")
    return 1
}

# why: The list has to be answerable against the specs rather than kept
# in agreement with them by hand. Every subject a system spec names is
# read off the specs themselves, so the spec added tomorrow brings its own
# coverage requirement with it -- which is what stops the next omission
# from being noticed only when the job it gates stops running.
@test "system paths: every subject a system spec names is covered (#1011)" {
  [ -x "${PATHS_SH}" ] || fail \
      "expected the pathspec source at ${PATHS_SH}; the classifier restates its list without it"
  local _n
  _n="$(_named_subjects | awk 'END { print NR }')"
  [[ "${_n}" -ge 5 ]] || fail \
      "expected the system specs to name their subjects, derived ${_n} -- the loop below would have certified the list against nothing"
  local _p _missing=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    _covered_by_pathspecs "${_p}" || _missing="${_missing}${_p}"$'\n'
  done < <(_named_subjects)
  [[ -z "${_missing}" ]] || fail \
      "system specs name these paths, and no pathspec selects them:"$'\n'"${_missing}"
}

# why: The opposite direction. A pathspec naming something the tree no
# longer has is a filter that can never match, and it reads as coverage:
# the list stays long, the gate stays narrow, and nothing says so.
@test "system paths: every pathspec names something that exists (#1011)" {
  [ -x "${PATHS_SH}" ] || fail "expected the pathspec source at ${PATHS_SH}"
  local _spec _target _dead=""
  while IFS= read -r _spec; do
    [[ -n "${_spec}" ]] || continue
    _target="/source/${_spec%/\*\*}"
    [[ -e "${_target}" ]] || _dead="${_dead}${_spec}"$'\n'
  done < <(bash "${PATHS_SH}")
  [[ -z "${_dead}" ]] || fail \
      "these pathspecs select nothing in the tree:"$'\n'"${_dead}"
}
