#!/usr/bin/env bats
#
# config_gen_admit_spec.bats -- the config-gen admission checker,
# script/test/config_gen_admit.sh (base#1465, slice S1e of base#1395).
#
# why: The Dockerfile's admit stage runs this checker before any Go, to
# hold the build context to the host mutation baseline the 00-manifest step
# wrote (base#1464). Whatever reaches the build after that baseline and is
# not bound by it -- by name and by sha256 -- is compiled and judged by
# gates that never saw it in the manifest. Every row writes a real baseline
# with script/test/config_gen_mutation_targets.sh on a Git fixture, changes
# the module or the baseline the way a later step could, and runs the
# checker on the result; no row reads the checker's source.
#
#   config_gen_admit.sh <mutation> <src>
#     admitted: rc 0, nothing on stdout or stderr
#     refused:  rc 1, exactly one stdout line
#               cg_event config_gen_manifest_stale file=<path> reason=<r>
#               and nothing on stderr

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ADMIT="/source/script/test/config_gen_admit.sh"
  CGM="/source/script/test/config_gen_mutation_targets.sh"
  S="${BATS_TEST_TMPDIR}"
  MOD="dockerfile/config-gen"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount, and every git call made from it dies with
  # "not a git repository".
  cd "${S}"
  unset CONFIG_GEN_MUTATION_CONTEXT CONFIG_GEN_MUTATION_BASE
  # A fixed Git identity and no user or system config, so a developer's
  # settings cannot change what a fixture records.
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="${S}/gitconfig"
  git config --file "${GIT_CONFIG_GLOBAL}" user.name t
  git config --file "${GIT_CONFIG_GLOBAL}" user.email t@t
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" commit.gpgsign false
}

# _baseline -- ${S}/w: one commit holding ${MOD}/a.go, origin/main at it;
# ${S}/m: the baseline config_gen_mutation_targets.sh writes for it
# (context pr).
_baseline() {
  W="${S}/w"
  git init -q "${W}"
  mkdir -p "${W}/${MOD}"
  printf 'package a\n' > "${W}/${MOD}/a.go"
  git -C "${W}" add -A
  git -C "${W}" commit -q --no-verify -m base
  git -C "${W}" update-ref refs/remotes/origin/main HEAD
  CONFIG_GEN_MUTATION_CONTEXT=pr bash "${CGM}" --repo "${W}" "${S}/m" \
    || fail "config_gen_mutation_targets.sh did not write the baseline"
}

_run_admit() {
  assert_spec_subject "${ADMIT}" "the config-gen admission checker (base#1465)"
  run --separate-stderr bash "${ADMIT}" "${S}/m" "${W}/${MOD}"
}

@test "config_gen_admit: a symlink added to the module after the baseline is refused as not_regular (base#1465)" {
  _baseline
  # The no-fire twin: the untouched module is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A later step adds a symlink. It is no regular file, so neither list
  # can bind it by sha256, and the build would follow it to a.go.
  ln -s a.go "${W}/${MOD}/zz.go"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/zz.go reason=not_regular"
  assert_equal "${stderr}" ""
}

@test "config_gen_admit: a listed file deleted from the module after the baseline is refused as missing (base#1465)" {
  _baseline
  # The no-fire twin: the untouched module is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A later step deletes a.go, which visible.sha256 lists. Nothing is left
  # to hash, so the refusal names the absence, not a differing sha256.
  rm "${W}/${MOD}/a.go"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/a.go reason=missing"
  assert_equal "${stderr}" ""
}

@test "config_gen_admit: a manifest body line that is neither the none marker nor a change record is refused as record (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (header, then the none marker)
  # is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A later step keeps the header and replaces the body with a line S1d
  # never writes: no `none: no-go-change`, no `<status>\t<path>` record.
  local header
  IFS= read -r header < "${S}/m/manifest"
  printf '%s\ngarbage\n' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=record"
  assert_equal "${stderr}" ""
}
