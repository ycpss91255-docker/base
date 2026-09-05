#!/usr/bin/env bats
#
# why: The self-test containers run as root over a bind-mounted checkout, so
# every run OWES the invoking user the files it wrote there. Two halves of
# that debt are covered here. The first is the handback itself: it used to
# sit on the success path, one line below the phase that produces the
# reports, so a suite with a single red test left `coverage/` owned by
# `nobody:nogroup` -- and the reports were already on disk, which is what
# makes running the chown on the failing path both safe and required. The
# second is the way back when no handback ever ran (an interrupt, a killed
# container, a lost machine): `just test clean` is the recipe for exactly
# that and could not do it, because a host-side `rm` needs write permission
# on a directory that now belongs to root. Both are base#1032.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  local _cmd _path
  # The name derivations short out without these once PATH is confined.
  for _cmd in grep date cat printf sha256sum cut id; do
    _path="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_path}" "${MOCK_DIR}/${_cmd}"
  done
  TESTSH=/source/script/test/test.sh
  JUSTFILE_TEST=/source/script/test/justfile.test
}

teardown() {
  cleanup_mock_dir
}

# ════════════════════════════════════════════════════════════════════
# (a) The handback runs whatever the run's verdict was
#
# The reports exist BEFORE the verdict does: kcov has written
# cobertura.xml by the time the driver returns the failing spec's status,
# and _run_coverage preserves that on purpose. So the chown on a red run
# is handing back files that are already there, not inventing an outcome.
# ════════════════════════════════════════════════════════════════════

# why: the observed failure -- one red test in 4489 left the checkout unwritable
@test "main --ci: a FAILING coverage phase still hands coverage/ back (base#1032)" {
  local _log="${BATS_TEST_TMPDIR}/handback.log"
  # A strict shell, because that is what the container entry point is: the
  # defect is invisible without errexit, since a sourced main runs on to
  # the next line and reaches the chown anyway.
  run bash -c '
    source /source/script/test/test.sh
    set -eo pipefail
    _run_coverage()    { return 1; }
    _fix_permissions() { printf "HANDBACK\n" >> "'"${_log}"'"; }
    trap _test_exit_reclaim EXIT
    COVERAGE=1 COVERAGE_PATH= COVERAGE_SHARD= main --ci
  '
  assert_failure
  assert [ -f "${_log}" ]
}

# why: the same hole on the other phase that writes into the mounted checkout
@test "main --ci --system: a FAILING system phase still hands the checkout back (base#1032)" {
  local _log="${BATS_TEST_TMPDIR}/handback.log"
  run bash -c '
    source /source/script/test/test.sh
    set -eo pipefail
    _run_system()      { return 1; }
    _fix_permissions() { printf "HANDBACK\n" >> "'"${_log}"'"; }
    trap _test_exit_reclaim EXIT
    main --ci --system
  '
  assert_failure
  assert [ -f "${_log}" ]
}

# why: a handback that could change the verdict would be reporting on the run
@test "the handback never changes the run's exit status (base#1032)" {
  # The status belongs to the code under test. A chown reporting on it --
  # in either direction -- is the collector deciding the verdict, which is
  # the rule the end-of-run project sweep already follows.
  run bash -c '
    source /source/script/test/test.sh
    _HANDBACK_ARMED=1
    _fix_permissions() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 7
  '
  [ "${status}" -eq 7 ]
}

# why: a silent chown failure is how the tree gets stuck with nobody told
@test "a handback that failed is reported, and names the repair (base#1032)" {
  run bash -c '
    source /source/script/test/test.sh
    _HANDBACK_ARMED=1
    _fix_permissions() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 0
  ' 2>&1
  [ "${status}" -eq 0 ]
  assert_output --partial "just test clean"
}

# why: a run that wrote nothing into the mount must not chown anything
@test "a dispatch that never entered the container arms no handback (base#1032)" {
  # The host-side dispatch (`_run_via_compose`) writes nothing itself; the
  # chown belongs to the process INSIDE the container, which is the one
  # running as root over the mount.
  run bash -c '
    source /source/script/test/test.sh
    _fix_permissions() { printf "HANDBACK\n"; }
    trap _test_exit_reclaim EXIT
    exit 0
  '
  [ "${status}" -eq 0 ]
  refute_output --partial "HANDBACK"
}

# ════════════════════════════════════════════════════════════════════
# (b) `just test clean` can reclaim a directory the host cannot touch
#
# Even with (a) in place, a Ctrl-C or a killed container lands in the same
# state, and the operator's only repair was raw docker or sudo -- both
# outside this project's control surface. The mechanism that made the
# directory root's is the mechanism that can take it back: a container
# running as root over the same bind mount.
# ════════════════════════════════════════════════════════════════════

# The two pins that keep a clean driven against a scratch tree from
# deriving names out of something that is not a checkout: TEST_TOOLS_IMAGE
# and COMPOSE_PROJECT_NAME each win verbatim over their derivation.
_PINS='export TEST_TOOLS_IMAGE=test-tools:spec; export COMPOSE_PROJECT_NAME=base-spec;'

# why: the ordinary case -- nothing to clean must not cost a container
@test "just test clean: a checkout with no coverage/ succeeds and starts nothing (base#1032)" {
  local _dir="${BATS_TEST_TMPDIR}/repo"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mkdir -p "${_dir}"
  mock_cmd "docker" 'printf "%s\n" "$*" >> "'"${_log}"'"; exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    '"${_PINS}"'
    _clean_coverage "'"${_dir}"'"
  '
  assert_success
  assert [ ! -f "${_log}" ]
}

# why: the whole point -- the reclaim happens where root is, not on the host
@test "just test clean: the removal is done by the container over the mount (base#1032)" {
  local _dir="${BATS_TEST_TMPDIR}/repo"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mkdir -p "${_dir}/coverage"
  printf 'x\n' > "${_dir}/coverage/timings.tsv"
  # The stand-in for the container: it removes what /source/coverage names
  # on the far side of the bind mount.
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    /bin/rm -rf "'"${_dir}"'/coverage"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    '"${_PINS}"'
    _clean_coverage "'"${_dir}"'"
  '
  assert_success
  assert [ ! -e "${_dir}/coverage" ]

  run cat "${_log}"
  assert_success
  assert_output --partial "run --rm"
  assert_output --partial "rm -rf /source/coverage"
}

# why: the failure this closes is a host rm that cannot unlink root's files
@test "just test clean: no host-side rm decides the outcome (base#1032)" {
  # A host `rm` is exactly what could not do this job: unlinking a file
  # needs write permission on the DIRECTORY holding it, and that directory
  # belongs to root. A clean that still leaned on one would work on the
  # trees that never needed it and fail on the only tree that did.
  local _dir="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_dir}/coverage"
  printf 'x\n' > "${_dir}/coverage/timings.tsv"
  # A container that does nothing. If anything on the host removed the
  # tree, this passes and the mechanism under test is not the mechanism.
  mock_cmd "docker" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    '"${_PINS}"'
    _clean_coverage "'"${_dir}"'"
  '
  assert_failure
  assert [ -e "${_dir}/coverage/timings.tsv" ]
}

# why: a clean that half-works recreates the stuck state one run later
@test "just test clean: a coverage/ still standing afterwards is a loud failure (base#1032)" {
  local _dir="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_dir}/coverage"
  printf 'x\n' > "${_dir}/coverage/timings.tsv"
  mock_cmd "docker" 'exit 1'

  # JSON, so the assertion anchors on the EVENT NAME -- the stable half of
  # a log line -- rather than on the wording of the message.
  run env LOG_FORMAT=json bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    '"${_PINS}"'
    _clean_coverage "'"${_dir}"'"
  '
  assert_failure
  assert_output --partial "ci_coverage_not_reclaimed"
  assert_output --partial "${_dir}/coverage"
}

# why: `rm -rf` as root inside a mounted checkout must have no reachable variable
@test "just test clean: the target the container is given cannot be redirected (base#1032)" {
  # The command runs as root over a mount of the whole checkout, so the
  # distance between "remove the reports" and "remove the checkout" is one
  # variable that expanded to the wrong thing. There is no such variable:
  # the command is a single-quoted literal, and the path in it is the
  # container-side mount point, not anything derived from this host.
  run code_grep -F "readonly _COVERAGE_CLEAN_COMMAND='rm -rf /source/coverage'" \
    "${TESTSH}"
  assert_success

  # Nothing expandable anywhere in the definition -- no parameter, no
  # command substitution, no backtick.
  run code_grep -nE '_COVERAGE_CLEAN_COMMAND=.*[$`]' "${TESTSH}"
  assert_failure

  # And the function that drives it removes nothing itself and names that
  # constant exactly once: a second command string, or a `rm` on this side,
  # would each be a second target that the assertions above do not cover.
  run bash -c "
    sed -n '/^_clean_coverage()/,/^}/p' '${TESTSH}' \
      | grep -vE '^[[:space:]]*#' \
      | grep -cE '(^|[[:space:]])rm[[:space:]]'
  "
  assert_output "0"

  run bash -c "
    sed -n '/^_clean_coverage()/,/^}/p' '${TESTSH}' \
      | grep -vE '^[[:space:]]*#' \
      | grep -cF '_COVERAGE_CLEAN_COMMAND'
  "
  assert_output "1"
}

# why: the literal is only right while /source is where the checkout is mounted
@test "just test clean: /source is the checkout's mount point in the service it drives (base#1032)" {
  # The constant above is a container-side path. It is correct because the
  # `ci` service mounts the repo root there -- assert that rather than
  # trusting a string in another file to keep meaning the same thing.
  run bash -c "
    awk '/^  ci:/{f=1} f&&/^  [a-z]/&&!/^  ci:/{f=0} f' /source/compose.yaml \
      | grep -cF -- '- .:/source'
  "
  assert_output "1"
}

# why: the recipe is the operator's entry; a host rm there is the defect itself
@test "just test clean routes through the runner, not a host rm (base#1032)" {
  run code_grep -F -- '--clean-coverage' "${JUSTFILE_TEST}"
  assert_success

  run code_grep -nE '^[[:space:]]+rm -rf coverage/' "${JUSTFILE_TEST}"
  assert_failure
}

# why: a repair nothing reaches is not a repair
@test "just test clean: the runner exposes the reclaim as a flag of its own (base#1032)" {
  # The recipe forwards to the runner and the runner has to have somewhere
  # to forward TO. Asserted structurally because the behaviour above is
  # driven against a scratch root: `main` would drive it against the real
  # checkout, deleting the coverage/ of whatever run is in flight beside
  # this one.
  run bash -c "
    sed -n '/--clean-coverage)/,/;;/p' '${TESTSH}' \
      | grep -vE '^[[:space:]]*#' \
      | grep -cF '_clean_coverage'
  "
  assert_output "1"

  # And it is documented where `--help` prints it, not only in the case arm.
  run bash -c "
    sed -n '/^usage()/,/^}/p' '${TESTSH}' | grep -cF -- '--clean-coverage'
  "
  assert_output "1"
}
