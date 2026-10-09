#!/usr/bin/env bats
#
# Unit tests for dist/test/bats/smoke/shared/test_helper.bash runtime
# assertion helpers.
# These helpers are intended to be load-ed by per-repo smoke specs inside
# the Docker `test` stage; here we exercise them in isolation under the
# template's own CI.
#
# why: Exercises the runtime assertion helpers shipped in
# `dist/test/bats/smoke/shared/test_helper.bash` (used by downstream-repo
# smoke specs via `load "${BATS_TEST_DIRNAME}/test_helper"`).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load "/source/dist/test/bats/smoke/shared/test_helper"

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# assert_cmd_installed
# ════════════════════════════════════════════════════════════════════

# why: Happy path
@test "assert_cmd_installed passes when cmd is on PATH" {
  mock_cmd "fakecmd" 'exit 0'
  run assert_cmd_installed fakecmd
  assert_success
}

# why: Missing cmd
@test "assert_cmd_installed fails with descriptive message when cmd missing" {
  run assert_cmd_installed no_such_cmd_xyzzy
  assert_failure
  assert_output --partial "command not found on PATH"
  assert_output --partial "no_such_cmd_xyzzy"
}

# why: Required arg check
@test "assert_cmd_installed errors when cmd arg missing" {
  run assert_cmd_installed
  assert_failure
  assert_output --partial "missing cmd"
}

# ════════════════════════════════════════════════════════════════════
# assert_cmd_runs
# ════════════════════════════════════════════════════════════════════

# why: Happy path
@test "assert_cmd_runs passes when cmd exits 0" {
  mock_cmd "fakecmd" 'echo "v1.2.3"; exit 0'
  run assert_cmd_runs fakecmd
  assert_success
}

# why: Custom flag
@test "assert_cmd_runs uses custom version flag when given" {
  mock_cmd "fakecmd" '
    if [[ "$1" == "-V" ]]; then exit 0; fi
    exit 99'
  run assert_cmd_runs fakecmd -V
  assert_success
}

# why: Broken binary
@test "assert_cmd_runs fails when cmd exits non-zero" {
  mock_cmd "fakecmd" 'echo "boom" >&2; exit 7'
  run assert_cmd_runs fakecmd
  assert_failure
  assert_output --partial "exited non-zero"
  assert_output --partial "status"
}

# why: Missing cmd
@test "assert_cmd_runs fails when cmd is not installed" {
  run assert_cmd_runs no_such_cmd_xyzzy
  assert_failure
  assert_output --partial "command not found on PATH"
}

# ════════════════════════════════════════════════════════════════════
# assert_file_exists
# ════════════════════════════════════════════════════════════════════

# why: Happy path
@test "assert_file_exists passes when file is a regular file" {
  local _file="${TEMP_DIR}/present.txt"
  : > "${_file}"
  run assert_file_exists "${_file}"
  assert_success
}

# why: Missing path
@test "assert_file_exists fails when path is missing" {
  run assert_file_exists "${TEMP_DIR}/missing.txt"
  assert_failure
  assert_output --partial "file does not exist"
}

# why: Type check
@test "assert_file_exists fails when path is a directory" {
  run assert_file_exists "${TEMP_DIR}"
  assert_failure
  assert_output --partial "file does not exist"
}

# ════════════════════════════════════════════════════════════════════
# assert_dir_exists
# ════════════════════════════════════════════════════════════════════

# why: Happy path
@test "assert_dir_exists passes when path is a directory" {
  run assert_dir_exists "${TEMP_DIR}"
  assert_success
}

# why: Missing path
@test "assert_dir_exists fails when path is missing" {
  run assert_dir_exists "${TEMP_DIR}/nodir"
  assert_failure
  assert_output --partial "directory does not exist"
}

# why: Type check
@test "assert_dir_exists fails when path is a file" {
  local _file="${TEMP_DIR}/a_file"
  : > "${_file}"
  run assert_dir_exists "${_file}"
  assert_failure
  assert_output --partial "directory does not exist"
}

# ════════════════════════════════════════════════════════════════════
# assert_file_owned_by
# ════════════════════════════════════════════════════════════════════

# why: Happy path
@test "assert_file_owned_by passes when owner matches" {
  local _file="${TEMP_DIR}/owned.txt"
  : > "${_file}"
  local _user
  _user="$(stat -c '%U' "${_file}")"
  run assert_file_owned_by "${_user}" "${_file}"
  assert_success
}

# why: Owner mismatch
@test "assert_file_owned_by fails with owner diff when user mismatches" {
  local _file="${TEMP_DIR}/owned.txt"
  : > "${_file}"
  run assert_file_owned_by definitely_not_a_real_user "${_file}"
  assert_failure
  assert_output --partial "owner mismatch"
  assert_output --partial "expected"
  assert_output --partial "actual"
}

# why: Missing path
@test "assert_file_owned_by fails when path missing" {
  run assert_file_owned_by root "${TEMP_DIR}/missing"
  assert_failure
  assert_output --partial "path does not exist"
}

# ════════════════════════════════════════════════════════════════════
# assert_pip_pkg
# ════════════════════════════════════════════════════════════════════

# why: Package installed
@test "assert_pip_pkg passes when pip show returns 0" {
  mock_cmd "pip" '
    if [[ "$1" == "show" ]]; then exit 0; fi
    exit 0'
  run assert_pip_pkg somepkg
  assert_success
}

# why: Package missing
@test "assert_pip_pkg fails when pip show returns non-zero" {
  mock_cmd "pip" '
    if [[ "$1" == "show" ]]; then exit 1; fi
    exit 0'
  run assert_pip_pkg missingpkg
  assert_failure
  assert_output --partial "pip package not installed"
  assert_output --partial "missingpkg"
}

# why: pip itself missing
@test "assert_pip_pkg fails when pip is not installed" {
  run assert_pip_pkg any
  assert_failure
  assert_output --partial "command not found on PATH"
  assert_output --partial "pip"
}

# ════════════════════════════════════════════════════════════════════
# run_wrapper_xhost
#
# The shipped smoke spec dist/test/bats/smoke/devel-test/display_env.bats
# calls this against /lint/run.sh, which only exists inside a downstream
# `-test` image. Driving the same helper against the wrapper at its source
# path puts the real xhost branch under base's own gate, so a deletion or
# an inversion goes red here and not only in a consumer's build.
#
# These four tests are now base's whole unit-side gate on that branch. The
# three `template_spec` greps over run.sh and a run_sh_spec test named for
# the Wayland ACL were deleted (base#1117), measured: inverting the branch
# left all four of them green and turned tests 20-22 here red; emptying the
# branch entirely (`grep -c xhost run.sh` == 0) left the run_sh_spec test
# green and turned 20-23 here red; and a behaviour-preserving hoist of the
# ACL into a variable kept these green while two of the greps went red, so
# they were anti-correlated with the property as well as weaker than it.
# ════════════════════════════════════════════════════════════════════

_WRAPPER_UNDER_TEST=/source/dist/script/docker/wrapper/run.sh

@test "run_wrapper_xhost: wayland session grants +SI:localuser to the .env user" {
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_output "+SI:localuser:smokeuser"
}

@test "run_wrapper_xhost: x11 session grants +local:" {
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}" XDG_SESSION_TYPE=x11
  assert_success
  assert_output "+local:"
}

@test "run_wrapper_xhost: an unset XDG_SESSION_TYPE falls back to the X11 grant" {
  # env -u inside the helper, so this holds even when the CI container
  # exports a session type of its own.
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}"
  assert_success
  assert_output "+local:"
}

@test "run_wrapper_xhost: reports every xhost call, one per line" {
  # The count is what makes 'exactly one host ACL per invocation' assertable
  # downstream; a helper that collapsed or deduplicated calls would hide a
  # both-branches regression.
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_equal "${#lines[@]}" 1
}

@test "run_wrapper_xhost: fails loudly when the wrapper makes no xhost call" {
  # Without this guard an empty capture would satisfy every refute_output
  # assertion in the shipped spec, so deleting the branch would read green.
  local _w="${TEMP_DIR}/wrapper"
  mkdir -p "${_w}" "${TEMP_DIR}/lib"
  : > "${TEMP_DIR}/lib/bootstrap.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${_w}/run.sh"
  run run_wrapper_xhost "${_w}/run.sh"
  assert_failure
  assert_output --partial "wrapper made no xhost call at all"
}

@test "run_wrapper_xhost: fails when the wrapper exits non-zero" {
  local _w="${TEMP_DIR}/wrapper"
  mkdir -p "${_w}" "${TEMP_DIR}/lib"
  : > "${TEMP_DIR}/lib/bootstrap.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' > "${_w}/run.sh"
  run run_wrapper_xhost "${_w}/run.sh"
  assert_failure
  assert_output --partial "wrapper exited non-zero"
  assert_output --partial "3"
}

@test "run_wrapper_xhost: fails when the wrapper path does not exist" {
  run run_wrapper_xhost "${TEMP_DIR}/no_such_wrapper.sh"
  assert_failure
  assert_output --partial "wrapper script does not exist"
}

@test "run_wrapper_xhost: fails when the wrapper's lib/ cannot be located" {
  local _w="${TEMP_DIR}/orphan"
  mkdir -p "${_w}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${_w}/run.sh"
  run run_wrapper_xhost "${_w}/run.sh"
  assert_failure
  assert_output --partial "cannot locate the wrapper's lib/ directory"
}

@test "run_wrapper_xhost: errors when the wrapper path arg is missing" {
  run run_wrapper_xhost
  assert_failure
  assert_output --partial "missing wrapper path"
}

# ════════════════════════════════════════════════════════════════════
# entrypoint_is_single_file
# ════════════════════════════════════════════════════════════════════
#
# The probe the shared smoke baseline uses to tell the two entry-point
# models apart from INSIDE an image, where the Dockerfile's ENTRYPOINT line
# is not readable. A pre-ADR-00000032 repo runs its own /entrypoint.sh and
# never installs the orchestrator; asserting the orchestrator unconditionally
# turns that repo's next `just upgrade` into a red build over a model it
# never adopted.

# why: The pre-ADR-00000032 model, which is what the guard exists for. A
# false answer here makes the shared baseline assert the orchestrator on a
# repo that never installed one, turning its next `just upgrade` into a red
# build over a model it did not adopt
@test "entrypoint_is_single_file: true for a file that execs the workload" {
  printf '#!/usr/bin/env bash\n. /usr/local/lib/base/logging.sh\nexec "${@}"\n' \
    > "${TEMP_DIR}/entrypoint.sh"
  run entrypoint_is_single_file "${TEMP_DIR}/entrypoint.sh"
  assert_success
}

# why: The other direction, and the one that keeps the guard non-vacuous:
# a probe that answered true for everything would skip the orchestrator
# assertion everywhere and report green over an unchecked suite
@test "entrypoint_is_single_file: false for a bringup that only sets env" {
  printf '#!/usr/bin/env bash\nexport ROS_DOMAIN_ID=0\n' \
    > "${TEMP_DIR}/entrypoint.sh"
  run entrypoint_is_single_file "${TEMP_DIR}/entrypoint.sh"
  assert_failure
}

# why: The seeded bringup template TALKS about the exec it must not have,
# and a repo that migrated by commenting the line out has migrated. A
# substring match on `exec` reads both as the old model and would skip the
# assertion on every correctly migrated repo -- the same code-versus-comment
# distinction dockerfile_migrate.sh's notice makes
@test "entrypoint_is_single_file: a commented exec is not an exec" {
  # The seeded bringup template TALKS about the exec it must not have, and
  # a repo that migrated by commenting the line out has migrated.
  printf '#!/usr/bin/env bash\n# NO exec -- the orchestrator owns it.\n#exec "${@}"\n' \
    > "${TEMP_DIR}/entrypoint.sh"
  run entrypoint_is_single_file "${TEMP_DIR}/entrypoint.sh"
  assert_failure
}

# why: An image with no bringup at all is not on the old model, so the
# orchestrator assertion must still run there. Answering true on a missing
# path would silently exempt exactly the image most likely to be missing
# the orchestrator too
@test "entrypoint_is_single_file: false when the path does not exist" {
  run entrypoint_is_single_file "${TEMP_DIR}/no_such_entrypoint.sh"
  assert_failure
}

# why: The caller-error case, separated from the honest false above: a
# no-argument call must say so rather than answer "not the old model",
# which is the answer that turns a typo in a spec into a silent skip
@test "entrypoint_is_single_file: errors when the path arg is missing" {
  run entrypoint_is_single_file
  assert_failure
  assert_output --partial "missing path"
}

# ── the probe against the two halves base actually ships ─────────────
#
# The five cases above drive the probe over FIXTURES, which is the only way
# to write a shape a correct tree does not have. What no fixture can say is
# whether the probe still answers correctly about the two REAL files the
# split put it between, and that is the only question the shared baseline
# ever asks it: once per downstream image, about a file nobody here wrote.
#
# Both directions are read, because either one alone is satisfiable by
# accident. A probe that answered false for everything would pass the
# refutation below while skipping the orchestrator assertion in every
# consumer; one that answered true for everything would pass the positive
# while asserting the retired model everywhere.
#
# The positive half is the one the fixtures cannot reach. The orchestrator's
# exec is INDENTED, inside _base_entrypoint_main, while every fixture above
# writes its exec at column zero -- so a probe narrowed to a column-zero
# exec passes all five of them and then reads a real indented exec as "not
# an exec", which is the direction that costs a consumer a broken build.
#
# The shipped bringup is also pinned by template_spec.bats, which asserts
# the FILE carries no exec with a wider pattern than the probe's. That is a
# different reading of a different subject: this one is the probe, and the
# two can disagree without either file noticing.

_SHIPPED_BRINGUP=/source/dist/dockerfile/entrypoint.sh
_SHIPPED_ORCHESTRATOR=/source/dist/script/docker/runtime/entrypoint.sh

# why: The exec the two-file model moved into base's half, read off the real
# file rather than a fixture. It sits indented inside a function, a shape no
# fixture above has, so a probe narrowed to a column-zero exec passes every
# one of them and still misreads a real bringup that execs
@test "entrypoint_is_single_file: the indented exec in base's orchestrator is an exec (#945)" {
  assert_spec_subject "${_SHIPPED_ORCHESTRATOR}" \
    "base's entry-point orchestrator, the half the two-file model gives the exec to"
  run entrypoint_is_single_file "${_SHIPPED_ORCHESTRATOR}"
  assert_success
}

# why: The property ADR-00000032 shipped, asked of the file that shipped it:
# the bringup init.sh seeds does not exec, so the shared baseline must not
# read a repo on the new model as being on the retired one. Putting
# exec "${@}" back in that file turns this red
@test "entrypoint_is_single_file: the bringup template base seeds is not the retired model (#945)" {
  assert_spec_subject "${_SHIPPED_BRINGUP}" \
    "the bringup template init.sh seeds as a repo's own /entrypoint.sh"
  run entrypoint_is_single_file "${_SHIPPED_BRINGUP}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# reproducibility_manifest_state
#
# The adoption question smoke/shared/reproducibility.bats gates on. It used
# to be answered by the absence of that spec's own subject, which made "this
# repo has not ported the record yet" and "this repo ported it and has lost
# it" one state -- so the second one, the live regression, reported four
# green skips and a zero exit.
#
# What answers it now is the record's own DIRECTORY in the image under test,
# created by the one instruction that writes the two files. The reading in
# between -- scanning the consumer's Dockerfile for a redirection into one of
# the paths -- is recorded in the helper's header and was given up for a
# reason: a shell question answered in awk, and codex review found a false
# positive in it twice (a redirection inside quoted text, and a write in a
# stage the image under test does not descend from). Every miss of that kind
# falls the wrong way, costing an un-ported repo the skip and handing it a
# broken build. The directory asks nothing about shell and nothing about
# stages.
# ════════════════════════════════════════════════════════════════════

# why: One half present is enough to put every assertion about the record in
# scope -- including the one about the half that is missing, which is the
# "adopted and broken" case the spec must not skip past
@test "reproducibility_manifest_state: one half present reads as adopted" {
  mkdir -p "${TEMP_DIR}/share"
  : > "${TEMP_DIR}/share/base-image.env"
  run reproducibility_manifest_state \
    "${TEMP_DIR}/share/base-image.env" "${TEMP_DIR}/share/packages.txt" \
    "${TEMP_DIR}/share"
  assert_success
  assert_output "adopted"
}

# why: EITHER half, not a named one. A half-written record is the "adopted
# and broken" case whichever half survived, so the reading must not key on
# the first path alone -- that would send the other half's loss to the skip
# the directory check exists to prevent
@test "reproducibility_manifest_state: the other half present also reads as adopted" {
  mkdir -p "${TEMP_DIR}/share"
  : > "${TEMP_DIR}/share/packages.txt"
  run reproducibility_manifest_state \
    "${TEMP_DIR}/share/base-image.env" "${TEMP_DIR}/share/packages.txt" \
    "${TEMP_DIR}/share"
  assert_success
  assert_output "adopted"
}

# why: The regression the old precondition could not see. The directory the
# writing instruction creates is in the image and the record is not, so the
# record was adopted and is gone -- a failure, not a skip
@test "reproducibility_manifest_state: the directory without the record is missing, not unported" {
  mkdir -p "${TEMP_DIR}/share"
  run reproducibility_manifest_state \
    "${TEMP_DIR}/share/base-image.env" "${TEMP_DIR}/share/packages.txt" \
    "${TEMP_DIR}/share"
  assert_success
  assert_output "missing"
}

# why: The case the skip exists for, and the one that must survive: an image
# with no footprint of the record never claimed to keep it, and failing there
# turns a consumer's upgrade into a broken build
@test "reproducibility_manifest_state: no directory at all is unported" {
  run reproducibility_manifest_state \
    "${TEMP_DIR}/share/base-image.env" "${TEMP_DIR}/share/packages.txt" \
    "${TEMP_DIR}/share"
  assert_success
  assert_output "unported"
}

# why: A FILE where the directory belongs is not the record's directory. `-d`
# rather than `-e` keeps a path that changed type from reading as the
# footprint it is not -- the same distinction assert_spec_subject_dir makes
@test "reproducibility_manifest_state: a file at the directory's path is unported" {
  : > "${TEMP_DIR}/share"
  run reproducibility_manifest_state \
    "${TEMP_DIR}/share/base-image.env" "${TEMP_DIR}/share/packages.txt" \
    "${TEMP_DIR}/share"
  assert_success
  assert_output "unported"
}

# why: The caller-error case, separated from the honest answers above: a
# missing argument must say so rather than resolve to a verdict
@test "reproducibility_manifest_state: errors when an argument is missing" {
  run reproducibility_manifest_state "${TEMP_DIR}/base-image.env"
  assert_failure
  assert_output --partial "missing pkgs path"
}

# why: The third argument is as load-bearing as the other two -- it is what
# separates "adopted and lost" from "never ported" -- so a call that omits it
# says so rather than defaulting to one of those answers
@test "reproducibility_manifest_state: errors when the directory arg is missing" {
  run reproducibility_manifest_state \
    "${TEMP_DIR}/base-image.env" "${TEMP_DIR}/packages.txt"
  assert_failure
  assert_output --partial "missing dir path"
}
