#!/usr/bin/env bats

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# ════════════════════════════════════════════════════════════════════
# Structure: required files exist
# ════════════════════════════════════════════════════════════════════

@test "build.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/build.sh ]
  assert [ -x /source/dist/script/docker/wrapper/build.sh ]
}

@test "run.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/run.sh ]
  assert [ -x /source/dist/script/docker/wrapper/run.sh ]
}

@test "exec.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/exec.sh ]
  assert [ -x /source/dist/script/docker/wrapper/exec.sh ]
}

@test "stop.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/stop.sh ]
  assert [ -x /source/dist/script/docker/wrapper/stop.sh ]
}

@test "setup.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/setup.sh ]
  assert [ -x /source/dist/script/docker/wrapper/setup.sh ]
}

# ════════════════════════════════════════════════════════════════════
# Structure: test.sh and justfile.test exist
# ════════════════════════════════════════════════════════════════════

@test "test.sh exists and is executable" {
  assert [ -f /source/script/test/test.sh ]
  assert [ -x /source/script/test/test.sh ]
}

@test "test.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/test/test.sh
  assert_success
}

# The container-ops Makefile was retired for `just`; its existence /
# build-target / upgrade-path checks live in justfile_spec.bats (static)
# + justfile_user_spec.bats (executable). The base-only CI gate
# `Makefile.ci` is likewise retired for `justfile.test`, so the repo
# carries a single runner (just); `just test <recipe>` mirrors
# the former `make -f Makefile.ci <target>`.

@test "justfile.test exists (template CI gate)" {
  assert [ -f /source/script/test/justfile.test ]
}

@test "Makefile.ci no longer exists (retired for justfile.test)" {
  assert [ ! -e /source/Makefile.ci ]
}

@test "justfile.test default recipe runs the suite (bare just test)" {
  # min->max (ADR-00000011 #3): bare `just test` runs the whole self-test,
  # so the namespace default recipe invokes test.sh.
  run grep -E '^default:' /source/script/test/justfile.test
  assert_success
  run grep -F './script/test/test.sh' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test has lint recipe" {
  # lint takes *args so it can forward --shellcheck / --hadolint
  # narrowing flags (`lint *args:`), so match the recipe name, not `lint:`.
  run grep -E '^lint( |:|\b)' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test lint recipe forwards args + runs all linters by default (#650)" {
  # `just test lint` (no flag) runs --lint (all linters: shellcheck +
  # hadolint via the test-tools container); `--shellcheck` / `--hadolint`
  # narrow. The recipe forwards {{args}} so the narrowing flags reach
  # test.sh (ADR-00000011 #3 min->max).
  run grep -E '^lint \*args:' /source/script/test/justfile.test
  assert_success
  run grep -F './script/test/test.sh --lint {{args}}' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test has coverage recipe" {
  # the recipe takes an optional shard arg (`just test coverage 1/4`)
  # for the sharded kcov path; bare `just test coverage` still runs the
  # full suite. Match the recipe header with or without the param.
  run grep -E "^coverage( shard='')?:" /source/script/test/justfile.test
  assert_success
  # bare path still drives the full-suite --coverage flag.
  run grep -F './script/test/test.sh --coverage' /source/script/test/justfile.test
  assert_success
  # shard path drives the new --coverage-shard flag.
  run grep -F './script/test/test.sh --coverage-shard' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test carries no stale init/upgrade recipes at nonexistent root scripts (#779)" {
  # ADR-00000011 §8 relocated init.sh / upgrade.sh from the repo root to
  # dist/script/base/, and the `base` namespace (`just base init` /
  # `just base upgrade` / `just base update`) supersedes the former
  # `test init` / `test upgrade` / `test upgrade-check` recipes. Those
  # recipes still pointed at the vanished root ./init.sh / ./upgrade.sh,
  # so they failed immediately if invoked. Guard: justfile.test must not
  # reference the relocated root scripts (self recipes resolve to real
  # targets).
  run grep -E '\./(init|upgrade)\.sh' /source/script/test/justfile.test
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Structure: test directory layout
# ════════════════════════════════════════════════════════════════════

@test "dist smoke test_helper.bash exists under shared/" {
  assert [ -f /source/dist/test/bats/smoke/shared/test_helper.bash ]
}

@test "dist smoke shared entrypoint spec exists under shared/" {
  assert [ -f /source/dist/test/bats/smoke/shared/entrypoint.bats ]
}

@test "dist smoke script_help.bats exists under devel-test/" {
  assert [ -f /source/dist/test/bats/smoke/devel-test/script_help.bats ]
}

@test "dist smoke display_env.bats exists under devel-test/" {
  assert [ -f /source/dist/test/bats/smoke/devel-test/display_env.bats ]
}

@test "old flat dist/test/smoke/ layout is gone" {
  assert [ ! -d /source/dist/test/smoke ]
}

@test "test/bats/unit/ directory exists" {
  assert [ -d /source/test/bats/unit ]
}

# ════════════════════════════════════════════════════════════════════
# Structure: doc directory layout
# ════════════════════════════════════════════════════════════════════

@test "doc/readme/ directory exists" {
  assert [ -d /source/doc/readme ]
}

@test "doc/test/ directory exists" {
  assert [ -d /source/doc/test ]
}

@test "doc/changelog/ directory exists" {
  assert [ -d /source/doc/changelog ]
}

# ════════════════════════════════════════════════════════════════════
# Path reference: scripts call .base/dist/script/docker/wrapper/setup.sh
# ════════════════════════════════════════════════════════════════════

# the setup.sh reference moved out of build.sh / run.sh into the
# shared setup/drift orchestration in lib/wrapper.sh (_wrapper_setup_sync),
# which build.sh and run.sh both call. Assert the reference lives at its
# new home; the per-wrapper behaviour is proven by the setup-sync unit
# specs (wrapper_lib_spec.bats) and the dispatch integration spec.
@test "lib/wrapper.sh references .base/dist/script/docker/wrapper/setup.sh (#565)" {
  run grep ".base/dist/script/docker/wrapper/setup.sh" /source/dist/script/docker/lib/wrapper.sh
  assert_success
}

@test "build.sh + run.sh route setup/drift through _wrapper_setup_sync (#565)" {
  run grep -E '_wrapper_setup_sync (build|run)' /source/dist/script/docker/wrapper/build.sh
  assert_success
  run grep -E '_wrapper_setup_sync (build|run)' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Shell conventions: set -euo pipefail
# ════════════════════════════════════════════════════════════════════

@test "build.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh supports --no-cache flag" {
  run grep -E '\-\-no-cache' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh passes --no-cache to docker compose build when set" {
  run grep -E 'NO_CACHE.*=.*true' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)" {
  # Default behavior: do NOT auto-remove test-tools:local
  # cleanup must be conditional on CLEAN_TOOLS
  run grep -E 'CLEAN_TOOLS.*==.*true' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh supports --clean-tools flag" {
  run grep -E '\-\-clean-tools' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh removes test-tools image when --clean-tools is set" {
  run grep -E 'CLEAN_TOOLS.*=.*true' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "run.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "exec.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Docker compose project name (-p)
# ════════════════════════════════════════════════════════════════════

@test "lib/compose.sh is the ONLY producer of a project name (#893)" {
  # One question, one answerer. Every project name in the product comes out
  # of _resolve_project_name in lib/compose.sh: setup's apply calls it to
  # record PROJECT_NAME in .env.generated, and the wrapper calls it only
  # when there is no .env.generated to read at all. A second place that
  # assembles `<hub>-<image>` is the shape this replaces, so no other
  # shipped file may build one.
  run grep -E '^_resolve_project_name\(\)' /source/dist/script/docker/lib/compose.sh
  assert_success

  # The shape being outlawed is the JOIN itself -- `${...HUB...}-${...IMAGE...}`
  # in either order. An image TAG (`${HUB}/${IMAGE}`) is a different figure
  # and stays where it is.
  local _hit
  _hit="$(grep -rlE '(DOCKER_HUB_USER[^}]*\}-\$\{[^}]*IMAGE_NAME)|(IMAGE_NAME[^}]*\}-\$\{[^}]*DOCKER_HUB_USER)' \
            /source/dist --include='*.sh' --include='*.yaml' \
          | grep -v '/lib/compose\.sh$' || true)"
  [[ -z "${_hit}" ]] || {
    echo "a second place assembles a project name: ${_hit}"
    false
  }
}

# Wrapper -> compose dispatch is asserted by observed behaviour in
# test/integration/wrapper_compose_dispatch_spec.bats: each wrapper
# is run with --dry-run and the planned `docker compose -p <project> <verb>`
# is checked (incl. the -p flag, catching a raw-`docker compose` bypass).
# The old name-coupled greps for `_compose_project` here were removed —
# they broke on every internal rename (shim, rename) and could
# not catch a bypass.

@test "exec.sh loads .env via _load_env helper" {
  run grep -E '_load_env .*\.env' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh loads .env via _load_env helper" {
  run grep -E '_load_env .*\.env' /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

@test "lib/env.sh defines _load_env helper" {
  run grep -E '^_load_env\(\)' /source/dist/script/docker/lib/env.sh
  assert_success
}

@test "lib/compose.sh defines _compute_project_name helper" {
  run grep -E '^_compute_project_name\(\)' /source/dist/script/docker/lib/compose.sh
  assert_success
}

@test "lib/compose.sh defines _compose wrapper" {
  run grep -E '^_compose\(\)' /source/dist/script/docker/lib/compose.sh
  assert_success
}

@test "stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)" {
  # v0.6.6: run.sh devel switched to compose up + exec, so no more orphan
  # containers from `compose run --name`. The orphan cleanup line is removed.
  run grep -E 'docker rm.*-f.*IMAGE_NAME' /source/dist/script/docker/wrapper/stop.sh
  assert_failure
}

@test "run.sh devel target uses compose up -d (not compose run --name)" {
  # Regression: foreground devel previously used `compose run --name` which
  # created a one-off container that `./exec.sh` (compose exec) couldn't see,
  # producing "service devel is not running". Switched to up + exec.
  run grep -E 'up -d' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh devel branch uses compose exec to enter shell" {
  run grep -E '_compose_project exec' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

# run.sh foreground EXIT-trap cleanup (auto compose-down with
# --remove-orphans -t 0) is asserted by observed behaviour in
# wrapper_compose_dispatch_spec.bats via the dry-run output, instead
# of grepping the `_app_cleanup` identifier (renamed in).

@test "run.sh non-devel TARGET: foreground 'up', CMD-override 'run --rm' (#458/#679)" {
  # non-devel + no CMD uses foreground `compose up` so the Dockerfile CMD
  # runs.
  run grep -E 'up "?\$\{TARGET\}"?' /source/dist/script/docker/wrapper/run.sh
  assert_success
  # non-devel + CMD uses `compose run --rm` so the ENTRYPOINT runs
  # (env/ROS sourced) and the override REPLACES the default CMD. The
  # `up -d` + `exec` pair bypassed the ENTRYPOINT and
  # double-launched the default CMD.
  run grep -E '_compose_project run --rm "\$\{TARGET\}"' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh devel branch does not use 'compose run --name'" {
  # The old buggy pattern must be gone for devel; only run --rm for one-shots
  run grep -E 'run .*--name' /source/dist/script/docker/wrapper/run.sh
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# single-instance container naming
# ════════════════════════════════════════════════════════════════════

@test "run.sh refuses when the default container is already running" {
  # The refusal is the GUARD, not the wording. The old assertion greped
  # the whole file for `already running|already exists`, which the i18n
  # message table satisfies on its own -- deleting the entire
  # `if [[ "${DETACH}" != true ... ]]` / _wrapper_container_running /
  # `exit 1` block left this spec green.
  #
  # So: pin the enclosing condition, pin the running-service probe, and
  # read the refusal out of the probe's OWN block -- a bare `exit 1`
  # appears all over the file and proves nothing on its own.
  #
  # The probe is `_wrapper_service_running "${TARGET}"` and not the
  # `_wrapper_container_running "${CONTAINER_NAME}"` this guard used to
  # name: there is no CONTAINER_NAME any more, because nothing
  # emits `container_name:` for a wrapper to rebuild and look up. The
  # question the refusal asks is now "is this SERVICE up inside THIS
  # project", which is the only form that stays true when two stacks of
  # one repo share a host.
  run code_grep -F 'if [[ "${DETACH}" != true' \
    /source/dist/script/docker/wrapper/run.sh
  assert_success
  run code_grep -A12 -F 'if _wrapper_service_running "${TARGET}"; then' \
    /source/dist/script/docker/wrapper/run.sh
  assert_success
  assert_output --partial '_log_err run run_already_running'
  assert_output --partial 'exit 1'
}

@test "base is single-instance: no --instance flag remains (#600)" {
  run grep -E '\-\-instance' /source/dist/script/docker/wrapper/run.sh
  assert_failure
  run grep -E '\-\-instance' /source/dist/script/docker/wrapper/exec.sh
  assert_failure
  run grep -E '\-\-instance' /source/dist/script/docker/wrapper/stop.sh
  assert_failure
}

@test "base is single-instance: no INSTANCE_SUFFIX remains (#600)" {
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/run.sh
  assert_failure
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/exec.sh
  assert_failure
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/stop.sh
  assert_failure
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/setup.sh
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# --dry-run flag (PR B)
# ════════════════════════════════════════════════════════════════════

@test "build.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "run.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "exec.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

@test "build.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/build.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "run.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/run.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "exec.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/exec.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "stop.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/stop.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

# ════════════════════════════════════════════════════════════════════
# exec.sh container precheck (PR B)
# ════════════════════════════════════════════════════════════════════

@test "exec.sh checks the service is running before exec (#920)" {
  # The precheck asks the shared probe rather than spelling the query
  # inline: run.sh asks the identical question, and the two inline copies
  # were identical down to the `| grep -qx` that made both of them answer
  # backwards. Assert the seam from both ends -- exec.sh calls the probe,
  # and the probe is the thing that asks compose -- so this stays a check
  # that the precheck EXISTS rather than a pin on the exact query.
  #
  # The question is asked of the PROJECT now, not of the daemon's global
  # container-name namespace: with no container_name emitted, a derived name
  # is compose's to compute, and `compose ps` is where it is already known.
  #
  # Over CODE lines, not the whole file. A plain grep for the identifier
  # passed with the precheck deleted outright, so long as the name survived
  # in a comment -- and exec.sh carries several comment paragraphs
  # discussing the probe it replaced, which makes a leftover mention the
  # likely shape of a real deletion rather than a contrived one. The
  # assertion is the CALL, in the refusal's own condition, not the bare
  # identifier.
  run code_grep -F '&& ! _wrapper_service_running "${TARGET}"; then' \
    /source/dist/script/docker/wrapper/exec.sh
  assert_success
  run code_grep -E '_compose_project ps' /source/dist/script/docker/lib/wrapper.sh
  assert_success
}

@test "no wrapper or wrapper library reconstructs a container name from USER_NAME (#920)" {
  # The derived-name reconstruction is what made the precheck a second
  # answerer to "what is this container called". Compose owns that name now;
  # nothing a wrapper runs may assemble one to compare against.
  #
  # The population is DERIVED, never listed, and it is as wide as the name
  # claims. A predecessor listed three files. Its successor derived the
  # wrapper directory but appended `lib/wrapper.sh` as one literal path --
  # and the reconstruction being removed lived partly in lib/, which makes
  # lib/ a demonstrated home for it: appending `_legacy_container_name()`
  # to lib/compose.sh, the file that owns project naming and which every
  # wrapper sources, left that guard green. So BOTH halves are read off the
  # tree: the wrappers, and the library they dispatch through. Symlinks are
  # included -- `-type f` alone exempted any wrapper added as one.
  local _wrapper_dir="/source/dist/script/docker/wrapper"
  local _lib_dir="/source/dist/script/docker/lib"
  local _dir
  for _dir in "${_wrapper_dir}" "${_lib_dir}"; do
    [[ -d "${_dir}" ]] \
      || fail "missing ${_dir} -- a tree this guard derives its population from"
  done

  local -a _files=()
  local _f
  while IFS= read -r _f; do
    _files+=("${_f}")
  done < <(find "${_wrapper_dir}" "${_lib_dir}" -name '*.sh' \
                \( -type f -o -type l \) | sort)

  # A derived population that came back empty is the vacuous pass this guard
  # exists to refuse, so the roster asserts a floor before it is scanned:
  # both halves non-empty, and every entry a real file. The allowlist below
  # is the second, much harder floor -- every entry is anchored to the file
  # its read was reviewed in, and each of those files is asserted to be in
  # the roster, so a roster that lost any of them fails there. The floor is
  # the anchor set itself rather than a count restated in prose: an earlier
  # version of this comment claimed six files where the entries resolve to
  # eight.
  local _n_wrappers=0 _n_libs=0
  for _f in "${_files[@]}"; do
    case "${_f}" in
      "${_wrapper_dir}"/*) (( ++_n_wrappers )) ;;
      "${_lib_dir}"/*)     (( ++_n_libs )) ;;
    esac
    assert_spec_subject "${_f}" \
        "a wrapper-runtime script this guard scans for a rebuilt container name"
  done
  (( _n_wrappers > 0 )) \
    || fail "${_wrapper_dir} holds no *.sh: the roster derived nothing to scan"
  (( _n_libs > 0 )) \
    || fail "${_lib_dir} holds no *.sh: the roster derived nothing to scan"

  # grep exit 2 (unreadable path) must never read as "no match". A
  # predecessor captured stdout with `|| true`, so a renamed scan root --
  # nothing scanned -- passed as clean.
  local _out _rc=0
  _out="$(grep -Hn 'USER_NAME' "${_files[@]}")" || _rc=$?
  (( _rc <= 1 )) || fail "grep exited ${_rc} scanning the wrapper-runtime roster"

  # Comment lines are prose ABOUT the removed reconstruction; keep only
  # code, but keep each hit's file:line prefix so a failure names a place.
  local _code
  _code="$(printf '%s\n' "${_out}" \
    | awk '{ _l = $0; sub(/^[^:]*:[0-9]+:/, "", _l)
             if (_l !~ /^[[:space:]]*#/ && _l != "") print $0 }')"

  # Every reviewed read of the OS user in the wrapper runtime. None is a
  # container lookup; each is the user as an identity, a build arg, an
  # emitted env line, or message text.
  #
  # Each entry is `<file>|<the exact reviewed LINE>`: a scanned line is
  # exempt only when it comes from that file AND is that line, byte for
  # byte. Two weaker anchors were tried here and each exempted a
  # reconstruction:
  #
  #   - dropping the whole line a token matched exempts whatever shares it,
  #     so `; _legacy="${USER_NAME}-${IMAGE_NAME}"` appended to the xhost
  #     line walked past untouched. An exact line stops matching the moment
  #     anything is appended to it.
  #   - stripping the TOKEN from the lines of its own file exempted a
  #     SECOND use of a reviewed spelling inside that file. Appending
  #     `_legacy_container_name() { printf %s "${USER_NAME:--}-${IMAGE_NAME}"; }`
  #     to config_summary.sh -- the file that owns `${USER_NAME:--}` -- left
  #     the guard at 159 ok / 0 not ok. That text is neither reviewed line
  #     of that file, so it is now residue.
  #
  # The anchor is the line CONTENT, never a line NUMBER: a number would
  # redden for every edit above a token. The cost of content is that a
  # reworded read, or a fifth setup_tui locale adding a fifth mount-spec
  # example, reddens once -- which is the correct signal, because a changed
  # or new read has not been reviewed. Counting occurrences instead was
  # rejected for exactly the case content handles: a new locale is a
  # legitimate new line, and a count cannot tell one from a reconstruction.
  #
  # Fed from a quoted heredoc rather than an array literal: these are
  # verbatim source lines carrying single quotes, `$`, backslashes and `|`,
  # and a quoted heredoc is the one form that needs no escaping. The `|`
  # separator is unambiguous because it is the FIRST one and no file name
  # contains it (dockerfile_migrate.sh's sed expression contains several).
  #
  # Every entry must still MATCH a scanned line -- an entry that stopped
  # matching would widen the guard into "nothing is checked", the same
  # vacuous pass it exists to refuse.
  local -a _allowed=()
  local _entry
  while IFS= read -r _entry; do
    [[ -n "${_entry}" ]] && _allowed+=("${_entry}")
  done <<'ALLOWED'
lib/compose_emit.sh|        USER_NAME: \${USER_NAME}
lib/config_summary.sh|    "$(_lib_msg user)" "${USER_NAME:--}" "${USER_UID:--}" \
lib/config_summary.sh|  printf "[%s]   \${USER_NAME} = %s\n"  "${_tag}" "${USER_NAME:--}"
lib/dockerfile_migrate.sh|  _log_info upgrade upgrade_started "display=  Dockerfile patched: ARG USER -> ARG USER=\${USER_NAME} (#567 m7 / #579)"
lib/dockerfile_migrate.sh|  sed -i -E 's|^([[:space:]]*)ARG[[:space:]]+USER[[:space:]]*$|\1ARG USER="${USER_NAME}"|' "${_file}"
lib/env_emit.sh|USER_NAME=${_user_name}
lib/setup_cmd.sh|    printf 'USER_NAME=%s\n' "${user_name}"
lib/setup_detect.sh|  local _ws_portable_form='${WS_PATH}:/home/${USER_NAME}/work'
lib/setup_detect.sh|      _log_warn setup conf_mount_stale_path "display=[volumes] mount_1 host path '${_mount_1_host}' does not exist on this machine. This is usually a stale absolute path committed from a different machine. Rewriting mount_1 to the portable '\${WS_PATH}:/home/\${USER_NAME}/work' form and re-detecting WS_PATH locally. Commit the updated setup.conf to share." "path=${_mount_1_host}"
wrapper/run.sh|    xhost "+SI:localuser:${USER_NAME}" >/dev/null 2>&1 || true
wrapper/setup_tui.sh|_TUI_MSG_EN[volumes.edit.prompt]=$'Mount spec\n  - Format: <host>:<container>[:ro|rw]\n  - Empty = delete this entry\n  - Example: /data:/home/${USER_NAME}/data:rw'
wrapper/setup_tui.sh|_TUI_MSG_JA[volumes.edit.prompt]=$'マウント指定\n  - 形式: <host>:<container>[:ro|rw]\n  - 空 = この項目を削除\n  - 例: /data:/home/${USER_NAME}/data:rw'
wrapper/setup_tui.sh|_TUI_MSG_ZH_CN[volumes.edit.prompt]=$'挂载规格\n  - 格式：<host>:<container>[:ro|rw]\n  - 留空 = 删除此项目\n  - 示例：/data:/home/${USER_NAME}/data:rw'
wrapper/setup_tui.sh|_TUI_MSG_ZH_TW[volumes.edit.prompt]=$'掛載規格\n  - 格式：<host>:<container>[:ro|rw]\n  - 留空 = 刪除此項目\n  - 範例：/data:/home/${USER_NAME}/data:rw'
ALLOWED

  # The anchors are the harder floor: each names a file that must be in the
  # derived roster, so a roster that lost one fails here instead of passing
  # with less to scan.
  local _a _anchor _anchored
  for _a in "${_allowed[@]}"; do
    _anchor="${_a%%|*}"
    _anchored=0
    for _f in "${_files[@]}"; do
      [[ "${_f}" == */"${_anchor}" ]] && { _anchored=1; break; }
    done
    (( _anchored )) || fail \
      "allowlist anchor ${_anchor} is absent from the derived roster: the roster lost a file this guard's floor names"
  done

  local -a _hit=()
  local _i
  for (( _i = 0; _i < ${#_allowed[@]}; _i++ )); do _hit[_i]=0; done

  # Exempt a scanned line only when its FILE and its whole CONTENT are the
  # reviewed pair. `_code` lines are `<path>:<lineno>:<content>`; neither a
  # path nor a line number contains a colon, so the content is what follows
  # the second one -- kept byte for byte, indentation included.
  local _residue="" _line _path _content _af _at _exempt
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _path="${_line%%:*}"
    _content="${_line#*:}"
    _content="${_content#*:}"
    _exempt=0
    for (( _i = 0; _i < ${#_allowed[@]}; _i++ )); do
      _af="${_allowed[_i]%%|*}"
      _at="${_allowed[_i]#*|}"
      [[ "${_path}" == */"${_af}" ]] || continue
      [[ "${_content}" == "${_at}" ]] || continue
      _hit[_i]=1
      _exempt=1
      break
    done
    (( _exempt )) || _residue+="${_line}"$'\n'
  done <<< "${_code}"

  for (( _i = 0; _i < ${#_allowed[@]}; _i++ )); do
    (( _hit[_i] )) || fail \
      "allowlisted USER_NAME read is gone: ${_allowed[_i]} -- the roster scanned nothing, or the allowlist went stale"
  done

  local _left _rc2=0
  _left="$(grep 'USER_NAME' <<< "${_residue}")" || _rc2=$?
  (( _rc2 <= 1 )) || fail "grep exited ${_rc2} over the filtered residue"
  [[ -z "${_left}" ]] || {
    echo "unreviewed USER_NAME read in the wrapper runtime (name reconstruction?):"
    echo "${_left}"
    return 1
  }
}

@test "exec.sh precheck error mentions run.sh hint" {
  # Friendly error pointing user at ./run.sh
  run grep -E 'run\.sh' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "exec.sh exits non-zero with friendly hint when container not running" {
  # Simulate a tmp repo with .env so exec.sh gets past _load_env, then call
  # without docker on PATH so the precheck fails (no container can be found).
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/.env.generated" <<EOF
USER_NAME=alice
DOCKER_HUB_USER=alice
IMAGE_NAME=missing-image-$$
EOF
  mkdir -p "${_tmp}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${_tmp}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${_tmp}/.base/dist/script/docker/lib/i18n.sh" 2>/dev/null || true
  # _lib.sh is an umbrella that sources lib/*.sh sub-libs.
  cp /source/dist/script/docker/lib/* "${_tmp}/.base/dist/script/docker/lib/"
  cp /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"

  run bash "${_tmp}/exec.sh"
  assert_failure
  assert_output --partial "is not running"
  assert_output --partial "run.sh"
  rm -rf "${_tmp}"
}

@test "exec.sh --dry-run skips precheck and prints compose command" {
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/.env.generated" <<EOF
USER_NAME=alice
DOCKER_HUB_USER=alice
IMAGE_NAME=ghost-$$
EOF
  mkdir -p "${_tmp}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${_tmp}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${_tmp}/.base/dist/script/docker/lib/i18n.sh" 2>/dev/null || true
  # _lib.sh is an umbrella that sources lib/*.sh sub-libs.
  cp /source/dist/script/docker/lib/* "${_tmp}/.base/dist/script/docker/lib/"
  cp /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"

  run bash "${_tmp}/exec.sh" --dry-run
  assert_success
  assert_output --partial "[dry-run] docker compose"
  assert_output --partial "exec"
  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# i18n.sh shared module
# ════════════════════════════════════════════════════════════════════

@test "dist/script/docker/lib/i18n.sh exists" {
  assert [ -f /source/dist/script/docker/lib/i18n.sh ]
}

@test "Dockerfile.test-tools includes bats-mock" {
  run grep 'bats-mock' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools installs just (justfile entry-point execution in CI)" {
  # The test-tools image must carry `just` so justfile_user_spec /
  # upgrade-check can exercise the entry point for real.
  run grep -E 'apk add .*\bjust\b' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools installs the docker compose plugin (docker-cli-compose)" {
  # The runtime counterpart of this assertion
  # (test/bats/integration/compose_host_identity_spec.bats, which drives
  # `docker compose config` to observe how HOST_UID / HOST_GID resolve)
  # can only SKIP when the plugin is absent, so losing the package from
  # the image has to be caught statically here -- exactly as the
  # shellcheck / hadolint COPYs are below. Without this, deleting
  # docker-cli-compose from the apk line leaves that spec reporting a
  # green run of three skipped tests.
  #
  # Scoped to the FINAL stage's apk line (the one that also installs
  # bash), for the same reason the make guard below is: an earlier
  # builder stage is discarded and installing it there would not put it
  # in the image the suite runs in.
  run grep -E 'apk add .*\bbash\b.*\bdocker-cli-compose\b' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools COPYs shellcheck + hadolint into the final image" {
  # The runtime counterpart of this assertion (deploy_spec's generated
  # launcher being ShellCheck-clean) can only skip when the binary is
  # absent, so losing it from the image has to be caught statically here.
  run grep -E '^COPY --from=lint-tools /usr/local/bin/shellcheck ' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
  run grep -E '^COPY --from=lint-tools /usr/local/bin/hadolint ' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools source-builds kcov in a builder stage (#686)" {
  # kcov is not packaged in any alpine repo, so it is compiled from source
  # in a discardable builder stage and COPY'd into the final image. This
  # lets the coverage matrix run on the same one-pull test-tools image as
  # the rest of the suite (no debian kcov/kcov, no per-shard apt-install).
  run grep -E '^FROM alpine:\$\{ALPINE_VERSION\} AS kcov-builder' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools COPYs the kcov binary into the final image (#686)" {
  run grep -E '^COPY --from=kcov-builder .*kcov' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools installs kcov's runtime shared libs in the final stage (#686)" {
  # The source-built kcov binary links against these runtime libs; without
  # them it fails to load (verified via ldd in the spike). Pin them so
  # a refactor that drops one surfaces as a test failure, not a runtime
  # crash on the first coverage shard.
  run grep -E '^[[:space:]]+libstdc\+\+ libcurl libdw libelf zlib libgcc' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools no longer installs make into the final image (single runner: just)" {
  # make was retired with Makefile.ci; the integration tests now exercise
  # the downstream justfile (`just upgrade-check`), so the dead make
  # dependency must not creep back into the FINAL image. The kcov-builder
  # stage legitimately apk-adds make to compile kcov, but that
  # stage is discarded — only its /usr/local/bin/kcov is COPY'd out — so
  # scope this guard to the final-stage apk add line (the one that also
  # installs bash + parallel), not the whole file.
  run grep -E 'apk add .*\bbash\b.*\bmake\b|apk add .*\bmake\b.*\bbash\b' \
    /source/dockerfile/Dockerfile.test-tools
  assert_failure
}

@test "Dockerfile.test-tools declares ARG TARGETARCH" {
  run grep -E '^ARG TARGETARCH' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools ARG TARGETARCH has no default value (must not shadow BuildKit auto-inject)" {
  # Regression guard: `ARG TARGETARCH=amd64` with a default shadows
  # BuildKit's per-platform auto-inject (moby/buildkit#3403), which
  # caused every multi-arch build to fall back to amd64 — arm64 image
  # variants shipped x86_64 shellcheck / hadolint binaries. Symptom
  # downstream: `shellcheck: Exec format error` on arm64 CI.
  run grep -E '^ARG TARGETARCH=' /source/dockerfile/Dockerfile.test-tools
  assert_failure
  # But the bare declaration must still be there so the stage can
  # consume the BuildKit-injected value.
  run grep -E '^ARG TARGETARCH$' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools curl release downloads retry on transient failure (#550)" {
  # The shellcheck + hadolint binaries are fetched from github.com release
  # CDN at build time; a transient 504 there used to fail the whole build
  # first-hit (no retry). Every curl that pulls a release must use
  # --retry-all-errors so a 504/timeout retries transparently instead of
  # blocking every code PR's CI on a release-CDN hiccup.
  local _n
  _n="$(grep -cE 'curl .*--retry-all-errors' /source/dockerfile/Dockerfile.test-tools)"
  # both the shellcheck tarball and the hadolint binary downloads
  [ "${_n}" -ge 2 ]
}

@test "Dockerfile.test-tools branches case for amd64 and arm64" {
  # Must handle both common arches; amd64 → x86_64 binaries,
  # arm64 → aarch64 (shellcheck) + arm64 (hadolint) binaries.
  run grep -E 'amd64\)' /source/dockerfile/Dockerfile.test-tools
  assert_success
  run grep -E 'arm64\)' /source/dockerfile/Dockerfile.test-tools
  assert_success
  run grep -E 'aarch64' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools fails loud on unsupported TARGETARCH" {
  run grep -E 'Unsupported TARGETARCH' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "i18n.sh defines _detect_lang function" {
  run grep -E '^_detect_lang\(\)' /source/dist/script/docker/lib/i18n.sh
  assert_success
}

@test "build.sh sources lib/bootstrap.sh (which sources _lib.sh)" {
  # The wrapper does not source _lib.sh itself. It searches the
  # candidate paths for lib/bootstrap.sh and sources THAT; bootstrap.sh
  # is what sources _lib.sh (pinned by its own spec below). Both
  # assertions name an expansion no comment and no error string in this
  # file carries -- greping the whole file for `source.*_lib.sh` matched
  # only the header comment and the not-found message, so the specs
  # stayed green with the dispatch deleted.
  run code_grep -F 'for _bootstrap_cand in' \
    /source/dist/script/docker/wrapper/build.sh
  assert_success
  run code_grep -F 'source "${_bootstrap_cand}"' \
    /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "run.sh sources lib/bootstrap.sh (which sources _lib.sh)" {
  # See build.sh above for why the dispatch is what is pinned.
  run code_grep -F 'for _bootstrap_cand in' \
    /source/dist/script/docker/wrapper/run.sh
  assert_success
  run code_grep -F 'source "${_bootstrap_cand}"' \
    /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "exec.sh sources lib/bootstrap.sh (which sources _lib.sh)" {
  # See build.sh above for why the dispatch is what is pinned.
  run code_grep -F 'for _bootstrap_cand in' \
    /source/dist/script/docker/wrapper/exec.sh
  assert_success
  run code_grep -F 'source "${_bootstrap_cand}"' \
    /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh sources lib/bootstrap.sh (which sources _lib.sh)" {
  # See build.sh above for why the dispatch is what is pinned.
  run code_grep -F 'for _bootstrap_cand in' \
    /source/dist/script/docker/wrapper/stop.sh
  assert_success
  run code_grep -F 'source "${_bootstrap_cand}"' \
    /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

@test "lib/bootstrap.sh sources _lib.sh (the claim the wrappers delegate)" {
  # The wrapper-side half of this claim lives in the four specs above,
  # which pin the bootstrap dispatch. This is the other half, asserted
  # against the file where it is true, and anchored to a leading
  # `source` / `.` so the prose that names _lib.sh cannot satisfy it.
  run code_grep -E '^[[:space:]]*(source|\.)[[:space:]].*_lib\.sh' \
    /source/dist/script/docker/lib/bootstrap.sh
  assert_success
}

@test "_lib.sh sources i18n.sh (delegates language detection)" {
  run code_grep -E '^[[:space:]]*(source|\.)[[:space:]].*i18n\.sh' \
    /source/dist/script/docker/lib/_lib.sh
  assert_success
}

@test "setup.sh sources i18n.sh" {
  # Anchored for the same reason as the bootstrap specs above: the
  # unanchored whole-file grep was also satisfied by the header comment
  # ("so sibling sources (i18n.sh / _tui_conf.sh) are located in the"),
  # so deleting the real source line left the spec green.
  run code_grep -E '^[[:space:]]*(source|\.)[[:space:]].*i18n\.sh' \
    /source/dist/script/docker/wrapper/setup.sh
  assert_success
}

_stage_lint_layout() {
  local _dest="${1:?}" _script="${2:?}"
  mkdir -p "${_dest}/wrapper" "${_dest}/lib"
  cp "/source/dist/script/docker/wrapper/${_script}" "${_dest}/wrapper/${_script}"
  cp /source/dist/script/docker/lib/* "${_dest}/lib/"
}

@test "build.sh -h works in /lint/ layout (flat dir with _lib.sh + i18n.sh, issue #104)" {
  # After we no longer carry inline _detect_lang fallbacks; the
  # /lint/ stage COPY must include _lib.sh and i18n.sh alongside.
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" build.sh
  run bash "${_tmp}/wrapper/build.sh" -h
  assert_success
  assert_output --partial "Usage"
  rm -rf "${_tmp}"
}

@test "run.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" run.sh
  run bash "${_tmp}/wrapper/run.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "exec.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" exec.sh
  run bash "${_tmp}/wrapper/exec.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "stop.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" stop.sh
  run bash "${_tmp}/wrapper/stop.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "build.sh errors with a clear diagnostic when bootstrap/_lib.sh missing (issue #104, #408)" {
  # build.sh copied alone (no lib/bootstrap.sh, no _lib.sh) -> explicit
  # non-zero exit + a clear broken-install diagnostic. the
  # shared preamble lives in lib/bootstrap.sh (which in turn sources
  # _lib.sh), so the first missing dependency reported is bootstrap.sh.
  # Better UX than a cryptic `_bootstrap: command not found`.
  local _tmp
  _tmp="$(mktemp -d)"
  cp /source/dist/script/docker/wrapper/build.sh "${_tmp}/build.sh"
  run bash "${_tmp}/build.sh" -h
  assert_failure
  assert_output --partial "cannot find lib/bootstrap.sh"
  rm -rf "${_tmp}"
}

@test "Dockerfile.example copies lib/ and wrapper/ into /lint/ (#406)" {
  run grep -F '.base/dist/script/docker/lib /lint/lib' /source/dist/dockerfile/Dockerfile
  assert_success
  run grep -F '.base/dist/script/docker/wrapper /lint/wrapper' /source/dist/dockerfile/Dockerfile
  assert_success
}

@test "Dockerfile.example copies logging.sh to /usr/local/lib/base/ in devel stage (#368)" {
  # PR documented the source-line example as
  # `. /home/${USER}/work/.base/dist/script/docker/runtime/logging.sh`,
  # which has two failure modes that broke every v0.30.0 adopter:
  # (1) $USER is unset/empty in the Dockerfile test stage, crashing
  # `set -u` entrypoints; (2) on multi-repo workspaces WS_PATH is the
  # workspace parent, not the repo root, so .base/ is never at the
  # documented path. Path A: COPY the helper into a stable in-image
  # location so downstream entrypoints can source it unconditionally
  # without $USER deref or path arithmetic.
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}"
  assert_success
  # COPY must sit in devel stage (between `FROM ... AS devel` and the
  # devel-test FROM line); a placement inside the commented runtime
  # block is also documented but devel is the canonical site.
  local _devel_line _test_line _copy_line
  _devel_line="$(grep -nE '^FROM devel-base AS devel$' "${_df}" | head -1 | cut -d: -f1)"
  _test_line="$(grep -nE '^FROM \$\{TEST_TOOLS_IMAGE\} AS test-tools-stage' "${_df}" | head -1 | cut -d: -f1)"
  _copy_line="$(grep -nF 'COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}" | head -1 | cut -d: -f1)"
  [[ -n "${_devel_line}" && -n "${_test_line}" && -n "${_copy_line}" ]]
  (( _devel_line < _copy_line ))
  (( _copy_line < _test_line ))
}

@test "Dockerfile.example commented runtime stage shows logging.sh COPY example (#368)" {
  # The optional runtime stage starts from a fresh BASE_IMAGE, not
  # FROM devel, so the helper is NOT inherited. Repos that ship a
  # runtime image and want host-side log tee must opt in via a
  # second COPY in the runtime stage. The commented-out scaffold
  # documents it so downstream maintainers see the requirement at
  # the moment they uncomment the runtime block.
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The example line must be commented (leading '# ') so it doesn't
  # accidentally activate in repos that haven't enabled the runtime
  # stage. Either inside the runtime-base/runtime block or the
  # documentation block above it.
  run grep -E '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}"
  assert_success
}

@test "runtime/logging.sh header documents in-image source-line (no \$USER, no work/.base) (#368)" {
  # The helper's own Usage block is the canonical reference downstream
  # entrypoint authors copy from. the example was
  # `. /home/${USER}/work/.base/dist/script/docker/runtime/logging.sh`
  # which only works on a single-repo workspace AND only at runtime
  # AFTER the compose bind mount lands -- failing at build-time smoke
  # and on multi-repo workspace layouts. Header must show the
  # in-image path instead, with no $USER deref and no work/.base
  # prefix.
  local _h="/source/dist/script/docker/runtime/logging.sh"
  # Positive: header documents the stable in-image path.
  run grep -F '#   . /usr/local/lib/base/logging.sh' "${_h}"
  assert_success
  # Negative regression guards: the broken patterns must not
  # reappear anywhere in the helper file (header, comments, or code).
  run grep -F '${USER}/work/.base/dist/script/docker/runtime/logging.sh' "${_h}"
  assert_failure
  run grep -F '/home/${USER}/work/.base' "${_h}"
  assert_failure
}

@test "Dockerfile.example copies logrotate.sh to /usr/local/lib/base/ in devel stage (#805)" {
  # runtime/logging.sh sources its sibling logrotate.sh from the same
  # in-image dir, so the shared rotate/symlink/prune helper must be COPY'd
  # alongside logging.sh (same devel-stage window) or the container tee
  # degrades to no rotation/prune.
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh' "${_df}"
  assert_success
  local _devel_line _test_line _copy_line
  _devel_line="$(grep -nE '^FROM devel-base AS devel$' "${_df}" | head -1 | cut -d: -f1)"
  _test_line="$(grep -nE '^FROM \$\{TEST_TOOLS_IMAGE\} AS test-tools-stage' "${_df}" | head -1 | cut -d: -f1)"
  _copy_line="$(grep -nF 'COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh' "${_df}" | head -1 | cut -d: -f1)"
  [[ -n "${_devel_line}" && -n "${_test_line}" && -n "${_copy_line}" ]]
  (( _devel_line < _copy_line ))
  (( _copy_line < _test_line ))
}

@test "Dockerfile.example copies watchdog.sh to /usr/local/lib/base/ in devel stage (#797)" {
  # The generic watchdog ships runtime/watchdog.sh, sourced from the
  # repo entrypoint alongside logging.sh. It must be COPY'd into the same
  # in-image dir (devel stage, before devel-test) so the source line
  # resolves at build + run time.
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh' "${_df}"
  assert_success
  local _devel_line _test_line _copy_line
  _devel_line="$(grep -nE '^FROM devel-base AS devel$' "${_df}" | head -1 | cut -d: -f1)"
  _test_line="$(grep -nE '^FROM \$\{TEST_TOOLS_IMAGE\} AS test-tools-stage' "${_df}" | head -1 | cut -d: -f1)"
  _copy_line="$(grep -nF 'COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh' "${_df}" | head -1 | cut -d: -f1)"
  [[ -n "${_devel_line}" && -n "${_test_line}" && -n "${_copy_line}" ]]
  (( _devel_line < _copy_line ))
  (( _copy_line < _test_line ))
}

@test "Dockerfile.example commented runtime stage shows watchdog.sh COPY example (#797)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -E '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh' "${_df}"
  assert_success
}

@test "runtime/entrypoint.sh sources the watchdog helper after logging (#797)" {
  # The template entrypoint sources logging.sh then watchdog.sh; both are
  # no-ops when their feature is off, so the source lines are safe. Order
  # matters: watchdog logs should ride the logging tee.
  local _ep="/source/dist/script/docker/runtime/entrypoint.sh"
  run grep -F '. /usr/local/lib/base/watchdog.sh' "${_ep}"
  assert_success
  local _log_line _wd_line
  _log_line="$(grep -nF '. /usr/local/lib/base/logging.sh' "${_ep}" | head -1 | cut -d: -f1)"
  _wd_line="$(grep -nF '. /usr/local/lib/base/watchdog.sh' "${_ep}" | head -1 | cut -d: -f1)"
  [[ -n "${_log_line}" && -n "${_wd_line}" ]]
  (( _log_line < _wd_line ))
}

@test "runtime/entrypoint.sh guards both lib sources with a readability test (#842)" {
  # The runtime stage's logging/watchdog COPYs are opt-in and init.sh seeds
  # this entrypoint verbatim into every repo, so an image that skipped them
  # must not source a missing file on every start. Same `[[ -r ]]` shape the
  # libs already use for their own sibling logrotate.sh source.
  local _ep="/source/dist/script/docker/runtime/entrypoint.sh"
  run grep -F 'if [[ -r /usr/local/lib/base/logging.sh ]]; then' "${_ep}"
  assert_success
  run grep -F 'if [[ -r /usr/local/lib/base/watchdog.sh ]]; then' "${_ep}"
  assert_success
}

@test "runtime/entrypoint.sh execs cleanly under set -euo pipefail with the libs absent (#842)" {
  # The observable half of the guard: with neither helper installed the
  # entrypoint must still reach `exec` -- no missing-file stderr, and no
  # abort for a consumer running the documented strict-mode entrypoint.
  local _ep="/source/dist/script/docker/runtime/entrypoint.sh"
  if [[ -e /usr/local/lib/base/logging.sh || -e /usr/local/lib/base/watchdog.sh ]]; then
    skip "runtime libs installed in this image -- absent-lib path not observable"
  fi
  local _err="${BATS_TEST_TMPDIR}/entrypoint.err"
  run bash -c 'bash -euo pipefail "$1" printf ok 2>"$2"' _ "${_ep}" "${_err}"
  assert_success
  assert_output "ok"
  assert_equal "$(cat "${_err}")" ""
}

@test "Dockerfile.example commented runtime stage shows logrotate.sh COPY example (#805)" {
  # The optional runtime stage is a fresh BASE_IMAGE (no devel inherit), so
  # a repo enabling host-side log tee there must COPY BOTH logging.sh and
  # its logrotate.sh sibling; the commented scaffold documents both.
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -E '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh' "${_df}"
  assert_success
}

@test "no inline _detect_lang fallbacks remain after dedupe (issue #104)" {
  # Lock in: only i18n.sh defines _detect_lang. build.sh / run.sh /
  # exec.sh / stop.sh / _lib.sh previously shipped their own copies,
  # which drifted ('s zh→zh-TW typo) — a single-source
  # definition prevents further drift.
  local _count
  _count="$(grep -cE '^_detect_lang\(\)' \
    /source/dist/script/docker/wrapper/build.sh \
    /source/dist/script/docker/wrapper/run.sh \
    /source/dist/script/docker/wrapper/exec.sh \
    /source/dist/script/docker/wrapper/stop.sh \
    /source/dist/script/docker/lib/_lib.sh \
    /source/dist/script/docker/wrapper/setup.sh \
    | awk -F: '{sum += $2} END {print sum}')"
  [ "${_count}" = "0" ]

  # i18n.sh must still have exactly one definition.
  run grep -cE '^_detect_lang\(\)' /source/dist/script/docker/lib/i18n.sh
  assert_output "1"
}

@test "setup.sh does not redefine _detect_lang" {
  # setup.sh is not COPY'd into consumer /lint stage, so no fallback needed
  run grep -cE '^_detect_lang\(\)' /source/dist/script/docker/wrapper/setup.sh
  assert_output "0"
}

@test "setup.sh defines _setup_msg, not _msg (closes #101)" {
  # Regression forbuild.sh / run.sh source setup.sh to obtain
  # `_check_setup_drift`. setup.sh used to define a top-level `_msg`
  # with a smaller key set than the caller's, silently shadowing it
  # post-source. Subsequent `_msg drift_regen` returned empty and
  # `printf "%s\n" ""` ate the drift-regen status line on every fresh-
  # host / setup.conf-changed run. Defensive namespacing fix: rename
  # to `_setup_msg`. Future helpers in setup.sh should follow the
  # `_setup_*` prefix convention to keep this immune.
  run grep -cE '^_msg\(\) \{' /source/dist/script/docker/wrapper/setup.sh
  assert_output "0"
  run grep -cE '^_setup_msg\(\) \{' /source/dist/script/docker/wrapper/setup.sh
  assert_output "1"
}

@test "build.sh _msg keys survive sourcing setup.sh (#101 behavioral)" {
  # Behavioral guard: source setup.sh in a subshell that already has a
  # top-level _msg with rich keys (mirrors what build.sh / run.sh used
  # to do in the drift-check branch pre-B-1) and assert the rich keys
  # still resolve afterward. Prior to fix, setup.sh's _msg shadowed
  # the caller's _msg and `_msg drift_regen` returned empty. Even though
  # B-1 dropped the `source` callsite, this guard stays so future helpers
  # added to setup.sh can't reintroduce the bug class.
  run bash -c '
    _msg() {
      case "$1" in
        drift_regen) echo "regenerating" ;;
        env_done)    echo "REAL CALLER env_done — should NOT be returned" ;;
      esac
    }
    # shellcheck source=/dev/null
    source /source/dist/script/docker/wrapper/setup.sh </dev/null >/dev/null 2>&1 || true
    _msg drift_regen
  '
  assert_success
  assert_output "regenerating"
}

@test "build.sh does not source setup.sh (#49 Phase B-1)" {
  # Structural guard for the fix: B-1 replaced build.sh's
  # `source "${_setup}"` + `_check_setup_drift "${FILE_PATH}"` with a
  # subprocess call (`bash setup.sh check-drift --base-path ... --lang ...`).
  # No future change should put `source` back — that would reopen the
  # entire shadow-bug class even if _msg vs _setup_msg stays clean.
  run grep -cE '^[[:space:]]*source[[:space:]]+"\$\{_setup\}"' /source/dist/script/docker/wrapper/build.sh
  assert_output "0"
}

@test "run.sh does not source setup.sh (#49 Phase B-1)" {
  # Mirror of build.sh structural guard above.
  run grep -cE '^[[:space:]]*source[[:space:]]+"\$\{_setup\}"' /source/dist/script/docker/wrapper/run.sh
  assert_output "0"
}

# the subprocess check-drift invocation moved into the shared
# _wrapper_setup_sync (lib/wrapper.sh), which build.sh + run.sh both call.
# Positive guard: it must invoke setup.sh via subprocess with the
# check-drift subcommand instead of sourcing it.
@test "lib/wrapper.sh uses subprocess check-drift (#49 Phase B-1, #565)" {
  run grep -cE '"\$\{_setup\}"[[:space:]]+check-drift' /source/dist/script/docker/lib/wrapper.sh
  assert_success
  refute_output "0"
}

# ════════════════════════════════════════════════════════════════════
# upgrade.sh
# ════════════════════════════════════════════════════════════════════

@test ".version file exists in template root" {
  # Semver with optional pre-release (e.g. v0.10.0-rc1). Accepts plain
  # `vX.Y.Z` and `vX.Y.Z-<identifiers>` per semver §9 so the RC release
  # workflow doesn't fail on the CHANGELOG self-check.
  assert [ -f /source/.version ]
  run cat /source/.version
  assert_output --regexp '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

@test "upgrade.sh reads version from <subtree-prefix>/.version" {
  # Post-v0.25.0 the subtree prefix is parameterised (TEMPLATE_REL) so
  # the rename `.base/` -> `.base/` works without code change. Assert
  # the parameterised form rather than the literal `.base/` prefix.
  run grep -F '${TEMPLATE_REL}/.version' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh does not reference legacy VERSION or .template_version" {
  # After the .version rename, upgrade.sh must not mention either
  # legacy filename — no backward-compat fallback is carried.
  run grep -cE '.base/VERSION|\.template_version' /source/dist/script/base/upgrade.sh
  assert_failure
  assert_output "0"
}

@test "upgrade.sh runs init.sh after subtree pull" {
  run grep -E 'init\.sh' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh supports --gen-conf flag" {
  run grep -E '\-\-gen-conf' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh --gen-conf delegates to init.sh --gen-conf" {
  run grep -E 'init\.sh.*--gen-conf' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh --help mentions --gen-conf" {
  run bash -c "bash /source/dist/script/base/upgrade.sh --help 2>&1"
  assert_success
  assert_output --partial "--gen-conf"
}

@test "upgrade.sh updates main.yaml @tag without clobbering release-worker.yaml" {
  # Regression: a greedy sed pattern .*@v[0-9.]* matched both build-worker
  # and release-worker references, replacing both with build-worker.yaml@<ver>
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  mkdir -p "${_tmp}/.base" "${_tmp}/.github/workflows"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.5.0
  call-release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.5.0
EOF
  # Source upgrade.sh and exercise just the sed block by inlining the
  # production sed commands here, mirroring what upgrade.sh does.
  # We do this by extracting and running the sed commands from upgrade.sh.
  local _seds
  # Narrow the sed extract to main_yaml-targeted lines. upgrade.sh also
  # only mutates main_yaml directly via sed (Step-5 Dockerfile healing now
  # lives in lib/dockerfile_migrate.sh,); the substitution
  # below only knows how to fill in main_yaml + target_ver, so feeding it
  # a Dockerfile sed would `eval sed -i ... ""` with an empty filename.
  _seds="$(grep -E '^[[:space:]]*sed -i.*main_yaml' /source/dist/script/base/upgrade.sh)"
  while IFS= read -r _line; do
    # shellcheck disable=SC2001
    _line="$(echo "${_line}" | sed "s|\${main_yaml}|${_yaml}|g; s|\${target_ver}|v0.6.4|g")"
    eval "${_line}"
  done <<< "${_seds}"

  run grep "build-worker.yaml@v0.6.4" "${_yaml}"
  assert_success
  run grep "release-worker.yaml@v0.6.4" "${_yaml}"
  assert_success
  # Critical: release-worker must NOT be replaced by build-worker
  run grep -c "build-worker.yaml" "${_yaml}"
  assert_output "1"

  rm -rf "${_tmp}"
}

@test "upgrade.sh main.yaml sed handles semver pre-release tags (RC → RC)" {
  # Regression: the previous `[0-9.]*` character class stopped at the
  # first `-`, so upgrading from an existing RC tag left the old
  # `-rcN` suffix in place and the new version got appended after it
  # (e.g. @v0.10.0-rc1 → -rc2 produced `@v0.10.0-rc2-rc1`).
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.10.0-rc1
  call-release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.10.0-rc1
EOF
  local _seds
  # Narrow the sed extract to main_yaml-targeted lines. upgrade.sh also
  # only mutates main_yaml directly via sed (Step-5 Dockerfile healing now
  # lives in lib/dockerfile_migrate.sh,); the substitution
  # below only knows how to fill in main_yaml + target_ver, so feeding it
  # a Dockerfile sed would `eval sed -i ... ""` with an empty filename.
  _seds="$(grep -E '^[[:space:]]*sed -i.*main_yaml' /source/dist/script/base/upgrade.sh)"
  while IFS= read -r _line; do
    # shellcheck disable=SC2001
    _line="$(echo "${_line}" | sed "s|\${main_yaml}|${_yaml}|g; s|\${target_ver}|v0.10.0-rc2|g")"
    eval "${_line}"
  done <<< "${_seds}"

  # Must produce the clean new tag — no leftover `-rc1` suffix.
  run grep -c 'build-worker.yaml@v0.10.0-rc2$' "${_yaml}"
  assert_output "1"
  run grep -c 'release-worker.yaml@v0.10.0-rc2$' "${_yaml}"
  assert_output "1"
  # And no double suffix anywhere.
  run grep -c '@v0.10.0-rc2-rc' "${_yaml}"
  assert_output "0"

  rm -rf "${_tmp}"
}

@test "upgrade.sh main.yaml sed handles stable → stable + RC → stable transitions" {
  # Edge cases around the pre-release group: from plain semver to plain,
  # and from RC back to plain stable (e.g. v0.10.0-rc2 → v0.10.0).
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.10.0-rc2
  call-release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.9.9
EOF
  local _seds
  # Narrow the sed extract to main_yaml-targeted lines. upgrade.sh also
  # only mutates main_yaml directly via sed (Step-5 Dockerfile healing now
  # lives in lib/dockerfile_migrate.sh,); the substitution
  # below only knows how to fill in main_yaml + target_ver, so feeding it
  # a Dockerfile sed would `eval sed -i ... ""` with an empty filename.
  _seds="$(grep -E '^[[:space:]]*sed -i.*main_yaml' /source/dist/script/base/upgrade.sh)"
  while IFS= read -r _line; do
    # shellcheck disable=SC2001
    _line="$(echo "${_line}" | sed "s|\${main_yaml}|${_yaml}|g; s|\${target_ver}|v0.10.0|g")"
    eval "${_line}"
  done <<< "${_seds}"

  run grep -c 'build-worker.yaml@v0.10.0$' "${_yaml}"
  assert_output "1"
  run grep -c 'release-worker.yaml@v0.10.0$' "${_yaml}"
  assert_output "1"
  # Must not leave stale -rc2 anywhere in the file.
  run grep -c 'rc2' "${_yaml}"
  assert_output "0"

  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# build-worker.yaml: GHCR test-tools migration (D plan)
# ════════════════════════════════════════════════════════════════════

@test "build-worker.yaml: no legacy in-job test-tools build step" {
  # The old `Build test-tools image` step is replaced by GHCR pull
  # via the TEST_TOOLS_IMAGE build-arg. If it reappears, CI will hit
  # the cross-step buildx image-store isolation again (v0.9.12 regression).
  local _yaml="/source/.github/workflows/build-worker.yaml"
  assert_spec_subject "${_yaml}" \
      "the reusable build worker this spec pins"
  run grep -c 'Build test-tools image' "${_yaml}"
  assert_output "0"
}

@test "build-worker.yaml: declares test_tools_version input" {
  # Replaces the v0.10.0 GITHUB_WORKFLOW_REF auto-parse, which read the
  # caller's own tag ref (e.g. a downstream repo's v1.5.0) rather than
  # template's pinned @tag, so downstream tag pushes tried to pull
  # `ghcr.io/.../test-tools:<downstream-tag>` and failed 404.
  local _yaml="/source/.github/workflows/build-worker.yaml"
  assert_spec_subject "${_yaml}" \
      "the reusable build worker this spec pins"
  run grep -F 'test_tools_version:' "${_yaml}"
  assert_success
  # Default must be `latest` so unpinned callers still work.
  run awk '
    /test_tools_version:/ { inside = 1 }
    inside && /^[[:space:]]+default:/ { print; exit }
  ' "${_yaml}"
  assert_success
  assert_output --partial '"latest"'
}

@test "build-worker.yaml: does not resurrect the GITHUB_WORKFLOW_REF parse step" {
  # Regression guard: the legacy auto-parse step must not come back.
  # Comments referencing it are fine (they explain the deprecation).
  local _yaml="/source/.github/workflows/build-worker.yaml"
  assert_spec_subject "${_yaml}" \
      "the reusable build worker this spec pins"
  run grep -Fc 'Resolve template version for test-tools image' "${_yaml}"
  assert_output "0"
}

@test "build-worker.yaml: devel-test build passes TEST_TOOLS_IMAGE from inputs" {
  local _yaml="/source/.github/workflows/build-worker.yaml"
  assert_spec_subject "${_yaml}" \
      "the reusable build worker this spec pins"
  # the step was named "Build test stage"; renamed to
  # "Build devel-test stage" for symmetry with the new runtime-test
  # stage. The TEST_TOOLS_IMAGE plumbing didn't move.
  run awk '
    /- name: Build devel-test stage/ { inside = 1 }
    inside && /^[[:space:]]*- name:/ && !/Build devel-test stage/ { inside = 0 }
    inside { print }
  ' "${_yaml}"
  assert_success
  # build-arg must wire inputs.test_tools_version into the ghcr tag
  assert_output --partial 'TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:${{ inputs.test_tools_version }}'
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: TEST_TOOLS_IMAGE ARG + named stage
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example has ARG TEST_TOOLS_IMAGE with no bare test-tools:local default" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # No bare, version-agnostic default: build.sh (local) and CI both pass
  # a version-scoped TEST_TOOLS_IMAGE explicitly, so an unset value fails
  # the build loudly instead of silently reusing a stale test-tools:local.
  run grep -E '^ARG TEST_TOOLS_IMAGE$' "${_df}"
  assert_success
  run grep -E '^ARG TEST_TOOLS_IMAGE=' "${_df}"
  assert_failure
}

@test "Dockerfile.example FROM \${TEST_TOOLS_IMAGE} AS test-tools-stage" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -F 'FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage' "${_df}"
  assert_success
}

@test "Dockerfile.example test stage copies from test-tools-stage, not test-tools:local" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # All ACTIVE COPY --from referring to the test-tools image must use
  # the named stage alias. Count only uncommented lines -- added a
  # commented-out runtime-test Bats COPY example (style (b)) which would
  # otherwise inflate the count.
  run grep -cE '^COPY --from=test-tools-stage' "${_df}"
  # 4 active copies expected (all in devel-test): shellcheck, hadolint,
  # /opt/bats, /usr/lib/bats.
  assert_output "4"
  # Legacy tag reference must be gone:
  run grep -c 'COPY --from=test-tools:local' "${_df}"
  assert_output "0"
}

# ──generalized -test toolchain pattern ────────────────────────

@test "Dockerfile.example runtime-test shows commented Bats COPY from test-tools-stage (#647)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The generalized rule: runtime-test gains an opt-in Bats smoke
  # via the SAME COPY --from=test-tools-stage devel-test uses, staying
  # FROM runtime. The example must be commented (leading '# ') so it
  # doesn't activate in repos that haven't opted in.
  run grep -E '^# COPY --from=test-tools-stage /opt/bats /opt/bats$' "${_df}"
  assert_success
  run grep -E '^# COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats$' "${_df}"
  assert_success
  # Anti-pattern guard: NO -test stage may be FROM ${TEST_TOOLS_IMAGE};
  # only the test-tools-stage alias itself is (one line).
  run grep -cE '^FROM \$\{TEST_TOOLS_IMAGE\}' "${_df}"
  assert_output "1"
}

@test "Dockerfile.example documents -test stages stay FROM the real stage + heavier-is-fine (#647)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The header must state the generalized rule and the anti-pattern.
  run grep -F 'Do NOT' "${_df}"
  assert_success
  run grep -F 'make any `-test` stage `FROM ${TEST_TOOLS_IMAGE}`' "${_df}"
  assert_success
  # -test stages may be heavier than shipped stages (never reach users).
  run grep -F 'never reach users' "${_df}"
  assert_success
  # Flavour tooling is the consumer's responsibility, not a base image.
  run grep -F "CONSUMER's responsibility" "${_df}"
  assert_success
}

# ── baked artifacts live at /opt, not under $HOME ──────────────

@test "Dockerfile.example states the /opt-not-\$HOME baking convention (#799)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The convention has to be stated where a downstream author meets it --
  # the file they edit to bake a workspace -- not only in base's own docs.
  run grep -F 'bake self-built artifacts at an ABSOLUTE /opt/' "${_df}"
  assert_success
  # Rule 2: the SOURCE line must name the absolute path, never ~ / $HOME.
  run grep -F 'source the ABSOLUTE path' "${_df}"
  assert_success
  # A ~/x -> /opt/x symlink is allowed for discoverability but must not be
  # what anything sources.
  run grep -F 'convenience symlink' "${_df}"
  assert_success
  # Rule 3 plus its enforcement handle, so the reader can run the gate.
  run grep -F 'just test lint --home-literal' "${_df}"
  assert_success
  # The recorded rationale, so the WHY does not have to live in the comment.
  run grep -F 'ADR-00000024' "${_df}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: BASE_IMAGE reproducibility
#
# The shipped template builds from a moving tag and installs unversioned
# apt packages on top of it, so two consumers building the same template
# version a month apart do not get the same image. The decision (see the
# note above `ARG BASE_IMAGE`) is to keep the moving default -- almost
# every consumer overrides BASE_IMAGE anyway, and a dev image that cannot
# take a security update without a template release is worse than one
# that drifts -- and to make the drift RECORDED rather than silent. These
# specs lock the record, since a manifest nothing asserts is a manifest
# that quietly stops being written.
#
# Several of them read a WINDOW of the file rather than the whole of it.
# The commented builder / runtime-base scaffold repeats the same apt and
# manifest lines the live stages carry, so a whole-file `grep` for one of
# them is satisfied by any of three occurrences: the assertion a test
# NAMES then is not the assertion it makes, and deleting the line the
# name is about leaves it green.
# ════════════════════════════════════════════════════════════════════

# _df_runtime_base_block -- the commented `runtime-base` stage of the
# shipped template, bounded by its own `FROM` marker and the next stage's.
# Printed as-is (comment markers included) so a caller greps the literal
# commented text.
# _df_sys_block -- the LIVE `sys` stage of the shipped template, bounded
# by its own `FROM` and the next live stage's. The commented builder /
# runtime-base scaffold carries a copy of every line the sys record is
# made of, so a whole-file grep for one of them is satisfied by the
# comment and the record itself can be deleted with the grep still green.
# The commented `# FROM ...` markers do not close the window (they never
# match `^FROM `), which is what keeps the window the STAGE and not the
# text between two FROM-shaped strings.
_df_sys_block() {
  awk '
    /^FROM \$\{BASE_IMAGE\} AS sys$/ { in_b = 1; next }
    in_b && /^FROM /                  { in_b = 0 }
    in_b
  ' "${1:?_df_sys_block: missing file}"
}

# _df_base_image_note <file> -- the contiguous run of comment lines
# immediately above `ARG BASE_IMAGE=`, i.e. the note a downstream author
# reads before deciding whether to pin. Scoped rather than whole-file for
# the same reason _df_sys_block is: every path, key and flag the note
# names is ALSO spelled somewhere in the RUN that implements it (the live
# sys stage) and again in the commented runtime-base scaffold, so a
# whole-file grep for them stays green with the entire note deleted --
# which is the one thing these tests exist to prevent.
_df_base_image_note() {
  awk '
    /^ARG BASE_IMAGE=/ { print buf; found = 1; exit }
    /^#/               { buf = buf $0 "\n"; next }
                       { buf = "" }
    END { if (!found) exit 1 }
  ' "${1:?_df_base_image_note: missing file}"
}

# _df_apt_run_blocks <file> <live|commented> -- every logical RUN block of
# the template that installs apt packages, one per output line with
# backslash continuations folded, so a caller can ask what a single block
# does rather than what the file contains somewhere.
#
# "Installs apt packages" is the SHAPE, not one literal. `apt-get install`
# and the `apt install` a consumer writes from muscle memory both count,
# and so does `rosdep install`, which resolves its dependencies straight
# into apt. Keying on a single literal is how the template's own rosdep
# example stayed exempt from a relation whose name is "every apt layer".
# Options before the subcommand are part of that shape too:
# `apt-get -y install foo` is an install layer, and a pattern demanding
# `apt-get` immediately followed by `install` makes one invisible. An
# option that takes a SEPARATE argument counts as one option, not as an
# option and then something unrecognised: `-o Dpkg::Options::="..."` is
# the spelling this template itself writes in devel-base, and a pattern
# that can only cross glued `-x` / `--x=y` tokens stops at its value --
# so moving those two words ahead of the subcommand, which apt-get
# accepts, turned the guard off for that layer while the block still
# counted toward the floor. The argument is matched as one non-option
# word, which is what keeps the pattern from walking over a `&&` into an
# `install` belonging to something else.
#
# Leading whitespace is tolerated because Docker tolerates it: `  RUN ...`
# is a RUN, and a guard that only sees column 0 is a guard a consumer's
# indentation turns off. The same goes for a comment marker: `  # RUN ...`
# is a legal Docker comment, so `commented` anchors on the first non-blank
# character, not on column 0.
#
# A BuildKit HEREDOC layer -- `RUN <<EOF` / body / `EOF` -- is a block
# too. Its body carries no backslash continuations, so the trailing-`\`
# rule alone closed such a RUN on its first line and left the apt-get
# calls under it invisible: not asked for a refresh, and not counted
# toward the floors either, so nothing went red over a layer that was
# never seen. The delimiter is read off the `<<`, `<<-` and quoted
# spellings alike (the quoting only changes whether the SHELL expands the
# body, which is nothing to do with what installs), and the block ends on
# the line that is exactly the delimiter. `<<<` opens nothing: a
# here-string is not a heredoc, and reading one as a delimiter swallows
# every layer below it into a single block -- which the first spelling of
# this rule did, because awk's `match` is LEFTMOST and found a `<<` inside
# a `<<<` by starting at its second `<`. The `<<` is required to follow a
# non-`<` for that reason.
#
# Comment lines INSIDE a block are dropped rather than folded in, in both
# modes, because that is what Docker does with them -- a continuation line
# the parser removes cannot run. Folding them in is how a refresh that had
# been commented out ("#    dpkg-query -W > ... && \\") still read as
# present: the broken layer and the correct one produced the same text for
# an assertion to search.
#
# `commented` strips one leading comment marker first and reads the result
# as the RUN it becomes when a consumer uncomments it. A doubly-commented
# illustration nested inside such a block (`# #   RUN ...`) is still a
# comment after that strip and so is dropped by the rule above, which is
# also what makes it correctly NOT a block of its own: the only one the
# template ships sits in `runtime-test`, an ephemeral stage whose image is
# discarded after the build, so nothing it installs is ever shipped for a
# manifest to describe.
#
# One definition of the install shape, shared with the callers that have
# to ask the same question about part of a block (see the ordering
# assertion below) -- two spellings of it is how a relation ends up
# holding for one of them only.
_DF_APT_INSTALL_RE='(apt(-get)?|rosdep)([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+install'

_df_apt_run_blocks() {
  awk -v mode="${2:?_df_apt_run_blocks: missing mode}" \
      -v install_re="${_DF_APT_INSTALL_RE}" '
    function flush() { if (buf ~ install_re) print buf; buf = ""; in_r = 0; hd = "" }
    {
      line = $0
      if (mode == "commented") {
        if (line !~ /^[[:space:]]*#/) { if (in_r) flush(); next }
        sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      }
      # Inside a heredoc body the delimiter line closes the layer and
      # everything else joins it -- including a `RUN` word, which is
      # shell text here and not a new instruction.
      if (hd != "") {
        term = line
        sub(/^[[:space:]]+/, "", term)
        sub(/[[:space:]]+$/, "", term)
        if (term == hd) { flush(); next }
        if (line ~ /^[[:space:]]*#/) next
        buf = buf " " line
        next
      }
      # A comment line neither joins the block nor ends it: the parser
      # removes it, and the continuation it sits inside carries on.
      if (line ~ /^[[:space:]]*#/) next
      if (!in_r) {
        if (line !~ /^[[:space:]]*RUN[[:space:]]/) next
        in_r = 1
        buf = line
      } else {
        buf = buf " " line
      }
      # The `<<` has to be preceded by a NON-`<`, or the leftmost match awk
      # takes finds one inside a `<<<` by starting at its second `<`: `grep -q x
      # <<<"${y}"` then opens a heredoc delimited by `y` and swallows every
      # layer below it into that block. A space is prepended so the guard
      # still has a character to look at when the `<<` opens the line.
      # The delimiter is whatever is left after the `<<`, the `-` and the
      # quoting are stripped, and it has to look like a word --
      # `$((1<<2))` leaves `2`, which does not.
      probe = " " line
      if (match(probe, /[^<]<<-?[^<[:space:]][^[:space:]]*/)) {
        delim = substr(probe, RSTART + 1, RLENGTH - 1)
        sub(/^<<-?/, "", delim)
        gsub(/[^A-Za-z0-9_]/, "", delim)
        if (delim ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { hd = delim; next }
      }
      if (line !~ /\\[[:space:]]*$/) flush()
    }
    END { if (in_r) flush() }
  ' "${1:?_df_apt_run_blocks: missing file}"
}

# The one line that rewrites the manifest. Spelled once, next to the shape
# it has to follow.
_DF_APT_REFRESH='dpkg-query -W > /usr/local/share/base/packages.txt'

# _df_assert_refresh_last <block> <what> -- <block> rewrites the manifest,
# and rewrites it AFTER everything it installs. The ORDER is half the
# property: a refresh that runs before the install records the pre-install
# package set and leaves the added packages out, which is the very defect
# this relation is named for, and which reads identically to any assertion
# that only asks whether the literal appears somewhere in the block.
#
# `fail` is followed by an explicit `return 1` rather than left to abort
# through errexit: `run _df_assert_refresh_last ...` -- the only way to
# assert that this helper REJECTS a block -- runs with errexit off, and
# `fail`'s own `return 1` returns from `fail`, not from here, so without
# it the function printed the rejection and then returned 0.
_df_assert_refresh_last() {
  local _blk="${1}" _what="${2}" _tail
  if [[ "${_blk}" != *"${_DF_APT_REFRESH}"* ]]; then
    fail "${_what} installs without refreshing the manifest: ${_blk}"
    return 1
  fi
  _tail="${_blk##*"${_DF_APT_REFRESH}"}"
  if [[ "${_tail}" =~ ${_DF_APT_INSTALL_RE} ]]; then
    fail "${_what} installs AFTER its last manifest refresh: ${_blk}"
    return 1
  fi
  return 0
}

# _df_assert_no_herestring_fusion <file> <mode> -- <file> holds a here-string
# RUN, then a DEFECTIVE apt layer (refresh, then install), then a correct
# one. Asserts the scanner read three RUNs as two apt blocks rather than
# fusing them into one.
#
# THREE observations, because none of them discriminates alone. The COUNT
# separates the readings only over a fixture with two layers under the
# here-string -- over one layer, the correct reading and the fused reading
# both yield a single block, which is a positive and a negative case with
# the identical observation. The CONTENT says the here-string RUN's own
# text is inside no block, which is the fusion itself. The CONSEQUENCE
# says the defective layer is still REJECTED, and names the rejection: a
# fused block hides that defect specifically, because the defective
# install lands ahead of the fused tail's last refresh and so reads as
# ordered.
_df_assert_no_herestring_fusion() {
  local _file="${1:?_df_assert_no_herestring_fusion: missing file}"
  local _mode="${2:?_df_assert_no_herestring_fusion: missing mode}"
  local _blk _n=0 _first="" _last=""
  while IFS= read -r _blk; do
    _n=$(( _n + 1 ))
    [[ "${_blk}" != *'grep -q x'* ]] \
      || fail "${_mode}: the here-string RUN opened a heredoc and swallowed the layers below it: ${_blk}"
    [[ -n "${_first}" ]] || _first="${_blk}"
    _last="${_blk}"
  done < <(_df_apt_run_blocks "${_file}" "${_mode}")
  [[ "${_n}" == "2" ]] \
    || fail "${_mode}: expected 2 apt blocks below the here-string RUN, found ${_n}"
  run _df_assert_refresh_last "${_first}" "${_mode} layer below a here-string"
  assert_failure
  assert_output --partial 'installs AFTER its last manifest refresh'
  _df_assert_refresh_last "${_last}" "${_mode} correct layer below a here-string"
}

_df_runtime_base_block() {
  awk '
    /^# FROM \$\{BASE_IMAGE\} AS runtime-base$/ { in_b = 1; next }
    in_b && /^# FROM runtime-base/              { in_b = 0 }
    in_b
  ' "${1:?_df_runtime_base_block: missing file}"
}

# _hadolint_ignore_rationale <file> <rule> -- the run of comment lines
# immediately preceding `- <rule>` in the ignore list. An ignore's
# rationale is the block attached to it; text describing a compensating
# control somewhere else in the file does not excuse THIS rule.
_hadolint_ignore_rationale() {
  awk -v rule="${2:?_hadolint_ignore_rationale: missing rule}" '
    $0 ~ "^[[:space:]]*-[[:space:]]*" rule "([[:space:]]|$)" { print buf; found = 1; exit }
    /^[[:space:]]*#/ { buf = buf $0 "\n"; next }
    { buf = "" }
    END { if (!found) exit 1 }
  ' "${1:?_hadolint_ignore_rationale: missing file}"
}

# disproven-claim vocabulary: begin
#
# Everything between this marker and its `end` twin is EXCISED before the
# sweep below reads a file. It has to be: a guard that bans a sentence
# cannot state it, and this block's whole job is to state it -- once as
# the patterns themselves, once as the examples that explain what shape
# they match. Excising by marker rather than exempting this FILE is what
# lets the sweep read the spec tree at all, which is where the claim was
# last found justifying an assertion.
#
# Every claim about a LABEL that this template, its harness, its shipped
# specs and its READMEs are allowed to make. A LABEL CAN read a digest out
# of a reference: build this repo's smoke harness with
# `--build-arg BASE_IMAGE=ubuntu@sha256:<hex>` and a
# `LABEL probe="${BASE_IMAGE##*@}"` comes back from `docker inspect` as
# `sha256:<hex>`. What a LABEL cannot do is BRANCH -- the same expression
# comes back as `ubuntu:24.04` for an unpinned reference -- which is a
# narrower constraint with a different consequence: it rules out deriving
# the annotation, it does not rule out reading the digest. The categorical
# version was once the sole stated reason for REFUSING a build, so it is
# swept for by pattern across every file that carried it, including the
# error text an operator would have been handed.
#
# EXTENDED REGEXES, not literals. The categorical claim is a SHAPE -- "the
# digest arg is the only value the annotation can carry" -- and the round
# that retracted it left the sentence standing in the changelog by
# rewording "the only value a label can carry" into "the one value the
# annotation can carry". A sweep keyed on the exact sentence a file used
# to hold goes green on the paraphrase, which is a report about the
# wording rather than about the claim.
_DF_DISPROVEN_CLAIMS=(
  'LABEL cannot read'
  'LABEL cannot run a case statement'
  'a LABEL cannot run that stage'
  '(only|one) value ([^ ]+ ){0,4}can carry'
  'two routes this note offers'
)
# disproven-claim vocabulary: end

# _df_swept_files -- every shipped or published text file the sweep reads:
# the whole template tree, base's own Dockerfiles, the doc tree (changelog,
# ADRs, the localized READMEs) and every file at the top of the checkout.
#
# DERIVED, not enumerated. The five files that had carried the claim were
# named by hand, so the sweep's reach was a property of that list and not
# of the repo: a sixth shipped file stating the claim tomorrow was exempt
# by construction -- the same hole one level up from the literal wording
# the patterns above now match by shape.
#
# TWO derivations, because directory roots only derive one level down. A
# root that is itself a FILE still had to be named, and README.md was the
# only one named: `init.sh` (the one file a consumer executes on every
# upgrade), `justfile`, `compose.yaml` and `CONTEXT.md` ship at the top
# level and were exempt by exactly the construction the roots list had
# just retired. So the top level is swept as a level -- `-maxdepth 1
# -type f`, which reaches a fifth such file the day it lands -- and
# README.md is dropped from the roots because that derivation now covers
# it. Directories at the top level that are not roots (`log/`, the git
# dir) stay out: `-type f` does not descend.
#
# The spec tree, the tooling tree and the workflows are IN it. They were
# left out on the theory that the claims are spelled there as data -- but
# only one block of one file spells them, and outside that block the spec
# tree is prose like any other, which is where the claim was last found
# still justifying an assertion. The vocabulary markers carve out the
# block; nothing carves out a file.
#
# The roots are a variable, not an argument list, because a root that has
# been renamed makes `find` print to stderr and carry on: the roster comes
# back shorter and the sweep reports a clean repo it never read. The
# caller asserts every root contributed.
_DF_SWEPT_ROOTS=(
  /source/dist
  /source/dockerfile
  /source/doc
  /source/script
  /source/test
  /source/.github
)

_df_swept_files() {
  {
    find "${_DF_SWEPT_ROOTS[@]}" -type f
    find /source -maxdepth 1 -type f
  } | sort -u
}

# _df_vocabulary_unbalanced <file> -- prints the file, and why, when its
# `begin` / `end` markers do not NEST: a `begin` left open at EOF, an
# `end` with no `begin` above it, or a second `begin` inside one. A
# `begin` that never closes excises everything after it, which is a sweep
# that read nothing wearing the report of a sweep that found nothing.
#
# ORDER, not counts. Comparing a count of `begin` against a count of `end`
# calls an INVERTED pair balanced -- 1 == 1 -- while `_df_flatten` opens
# at the `begin` and never closes, so the file tail is excised anyway:
# the same failure the guard is named for, wearing a clean report. Reading
# the markers in order is also what retires the `|| true` the counting
# spelling needed, under which a file grep could not read at all came
# back as a count of zero.
_df_vocabulary_unbalanced() {
  local _f="${1:?_df_vocabulary_unbalanced: missing file}" _why
  _why="$(awk '
    /disproven-claim vocabulary: begin/ {
      if (open) {
        bad = "a second begin at line " NR " inside the one at line " at
        exit
      }
      open = 1; at = NR; next
    }
    /disproven-claim vocabulary: end/ {
      if (!open) { bad = "an end at line " NR " with no begin above it"; exit }
      open = 0; next
    }
    END {
      if (bad == "" && open) bad = "a begin at line " at " with no end below it"
      if (bad != "") print bad
    }
  ' "${_f}")"
  [[ -z "${_why}" ]] || printf '%s (%s)\n' "${_f}" "${_why}"
}

# _df_flatten <file> -- the file as ONE line of prose: comment markers,
# quotes, backticks and line continuations blanked, whitespace squeezed.
#
# Searching line by line is why a sweep like this would have found one of
# the nine occurrences and reported the other eight as clean. Every claim
# below is WRAPPED where it ships -- across two comment lines in the
# note, across two `echo` arguments in the RUN that printed it, across a
# markdown wrap in the README -- so the string a reader sees exists on no
# single line of any of these files.
_df_flatten() {
  awk '
    /disproven-claim vocabulary: begin/ { skip = 1 }
    /disproven-claim vocabulary: end/   { skip = 0; next }
    !skip
  ' "${1:?_df_flatten: missing file}" \
    | sed 's/[#\\"`]/ /g' | tr '\n' ' ' | tr -s '[:space:]' ' '
}

# _df_claim_hits <prose> <claim> -- 0 when the prose states the claim, 1
# when it does not, 2 when grep could not evaluate the pattern at all.
#
# THREE answers, because an `if` around grep has only two branches and
# reads exit 2 the way it reads exit 1: a sweep that could not run comes
# back as a file that is clean. The caller has to see the difference, so
# the status is returned rather than collapsed, and the reason is printed
# where a failing gate will show it.
_df_claim_hits() {
  local _prose="${1?_df_claim_hits: missing prose}" \
        _claim="${2?_df_claim_hits: missing claim}" _st=0
  grep -qiE -- "${_claim}" <<< "${_prose}" || _st=$?
  case "${_st}" in
    0 | 1) return "${_st}" ;;
    *)
      printf 'grep could not evaluate the pattern %s (exit %s)\n' \
          "${_claim}" "${_st}"
      return 2
      ;;
  esac
}

@test "no shipped text repeats the claim a build disproves (#951)" {
  local _f _claim _flat _roster _hit _why
  _roster="$(_df_swept_files)"

  # The derivation has to REACH the files that carried the claim. A `find`
  # over roots that were renamed returns a shorter list, not an error, so
  # a shrinking roster reads exactly like a repo that got clean. Named
  # here as a floor, and fail-closed the way every other subject in this
  # file is, never as the roster.
  for _f in \
      /source/dist/dockerfile/Dockerfile \
      /source/dockerfile/Dockerfile.smoke \
      /source/dist/test/bats/smoke/shared/reproducibility.bats \
      /source/README.md \
      /source/doc/changelog/CHANGELOG.md; do
    assert_spec_subject "${_f}" "a file this spec sweeps for disproven claims"
    grep -qxF -- "${_f}" <<< "${_roster}" \
      || fail "${_f} carried the claim and the derived roster misses it"
  done

  # ... and the shipped TOP-LEVEL files. A `find` over directory roots is
  # derived one level down only: a root that is itself a FILE still has to
  # be named, and four shipped ones were not -- `init.sh` (the bootstrap a
  # consumer executes on every upgrade), `justfile`, `compose.yaml` and
  # `CONTEXT.md`. Named here as a floor, not as the roster: the derivation
  # reads the whole top level, so a fifth top-level file added tomorrow is
  # swept without an edit to this list.
  for _f in \
      /source/init.sh \
      /source/justfile \
      /source/compose.yaml \
      /source/CONTEXT.md; do
    assert_spec_subject "${_f}" "a shipped top-level file this spec sweeps"
    grep -qxF -- "${_f}" <<< "${_roster}" \
      || fail "${_f} ships at the top level and the derived roster misses it"
  done

  # Every root contributed something. Without this a renamed root is a
  # shorter list, not an error, and this test's report becomes "the files
  # I could still find are clean".
  local _root
  for _root in "${_DF_SWEPT_ROOTS[@]}"; do
    grep -q "^${_root}" <<< "${_roster}" \
      || fail "the sweep root ${_root} contributed no file to the roster"
  done
  # ... and so did the top-level derivation, which has no root name to
  # check: a `find` whose -maxdepth walk returned nothing is the same
  # shorter list wearing the same clean report.
  grep -qE '^/source/[^/]+$' <<< "${_roster}" \
    || fail "the top-level sweep contributed no file to the roster"

  local _unbalanced
  while IFS= read -r _f; do
    _unbalanced="$(_df_vocabulary_unbalanced "${_f}")"
    [[ -z "${_unbalanced}" ]] \
      || fail "unbalanced vocabulary markers: ${_unbalanced}"
    _flat="$(_df_flatten "${_f}")"
    for _claim in "${_DF_DISPROVEN_CLAIMS[@]}"; do
      _hit=0
      _why="$(_df_claim_hits "${_flat}" "${_claim}")" || _hit=$?
      case "${_hit}" in
        0) fail "${_f} states '${_claim}', which building this repo disproves" ;;
        1) ;;
        *) fail "the sweep could not read ${_f} for '${_claim}': ${_why}" ;;
      esac
    done
  done <<< "${_roster}"

  # The localized READMEs are inside the roster, but only their English
  # fragments can match: drivers/readme_sync.sh stamps each translated
  # section with the hash of the English section it was translated
  # against, so an English fix that leaves a translation stating the old
  # claim in zh-TW / zh-CN / ja fails that lint instead.
  # ... and the narrower constraint that survives has to be STATED where
  # the decision rests on it, or the next reader re-derives the wide one.
  local _df="/source/dist/dockerfile/Dockerfile"
  run grep -F 'cannot BRANCH' "${_df}"
  assert_success
}

@test "the vocabulary marker guard reads order, not counts (#951)" {
  # `_df_flatten` excises from a `begin` to the `end` that follows it, so
  # a marker pair that does not nest deletes the rest of the file from
  # the sweep: a sweep that read nothing wearing the report of a sweep
  # that found nothing. `_df_vocabulary_unbalanced` is the guard against
  # that, and COUNTING the two markers cannot be it -- an INVERTED pair
  # (the `end` above its `begin`) counts 1 == 1 and reports the file
  # balanced while the excision happens anyway.
  #
  # The marker literals are assembled from a variable rather than written
  # out, because this spec is itself one of the files the sweep reads:
  # a fixture spelling the markers in an order of its own would be an
  # inverted pair IN THIS FILE. The text below the `begin` is a sentinel
  # for the same reason -- a real claim here would trip the sweep.
  local _tmp _m='disproven-claim vocabulary' _report _flat
  _tmp="$(mktemp -d)"

  # An INVERTED pair: what counting calls balanced.
  {
    printf '%s\n' 'ABOVE-THE-MARKERS'
    printf '# %s: end\n' "${_m}"
    printf '# %s: begin\n' "${_m}"
    printf '%s\n' 'BELOW-THE-BEGIN'
  } > "${_tmp}/inverted"

  # The consequence first, so the guard is asserted against a real
  # excision and not against a rule someone wrote down.
  _flat="$(_df_flatten "${_tmp}/inverted")"
  run grep -cF 'ABOVE-THE-MARKERS' <<< "${_flat}"
  assert_success
  assert_output '1'
  run grep -F 'BELOW-THE-BEGIN' <<< "${_flat}"
  assert_equal "${status}" "1"

  _report="$(_df_vocabulary_unbalanced "${_tmp}/inverted")"
  [[ -n "${_report}" ]] \
    || fail "an inverted marker pair was reported balanced: ${_tmp}/inverted"

  # The siblings: the two spellings a count DOES catch have to keep being
  # caught, and a properly nested pair must stay silent -- a guard that
  # reports every file is a guard nobody can act on.
  {
    printf '# %s: begin\n' "${_m}"
    printf '%s\n' 'BELOW-THE-BEGIN'
  } > "${_tmp}/unclosed"
  _report="$(_df_vocabulary_unbalanced "${_tmp}/unclosed")"
  [[ -n "${_report}" ]] \
    || fail "an unclosed begin was reported balanced: ${_tmp}/unclosed"

  {
    printf '%s\n' 'ABOVE-THE-MARKERS'
    printf '# %s: end\n' "${_m}"
  } > "${_tmp}/stray-end"
  _report="$(_df_vocabulary_unbalanced "${_tmp}/stray-end")"
  [[ -n "${_report}" ]] \
    || fail "a stray end was reported balanced: ${_tmp}/stray-end"

  {
    printf '%s\n' 'ABOVE-THE-MARKERS'
    printf '# %s: begin\n' "${_m}"
    printf '%s\n' 'INSIDE-THE-BLOCK'
    printf '# %s: end\n' "${_m}"
    printf '%s\n' 'BELOW-THE-END'
  } > "${_tmp}/nested"
  _report="$(_df_vocabulary_unbalanced "${_tmp}/nested")"
  [[ -z "${_report}" ]] \
    || fail "a properly nested marker pair was reported unbalanced: ${_report}"
  _flat="$(_df_flatten "${_tmp}/nested")"
  run grep -cF 'BELOW-THE-END' <<< "${_flat}"
  assert_success
  assert_output '1'

  rm -rf "${_tmp}"
}

@test "the claim sweep refuses a pattern it could not read (#951)" {
  # `grep` answers three things, and the sweep read two of them as one:
  # 0 states the claim, 1 does not, and 2 is "I could not evaluate this
  # pattern at all". An `if` around grep takes the SAME branch for 1 and
  # 2, so a sweep that never ran reports the file clean -- the shape this
  # round exists to remove, one level below the patterns themselves.
  #
  # The claim strings here are sentinels: this spec is one of the files
  # the sweep reads, so a real claim written as a fixture would trip it.
  local _seen

  # Control: the shape the sweep used cannot tell 1 from 2.
  if grep -qiE -- '[' <<< 'a sentinel phrase' 2>/dev/null; then
    _seen='stated'
  else
    _seen='clean'
  fi
  assert_equal "${_seen}" "clean"

  # So the answer has to carry the third case. A pattern grep cannot
  # compile is an error that says so, never a silent "no".
  run _df_claim_hits 'a sentinel phrase' '['
  assert_equal "${status}" "2"
  assert_output --partial 'could not evaluate'

  # ... and the two it CAN answer are still answered, both ways: a guard
  # that errors on everything is as unusable as one that never errors.
  run _df_claim_hits 'this prose holds a sentinel phrase' 'sentinel phrase'
  assert_equal "${status}" "0"
  run _df_claim_hits 'this prose holds nothing of the kind' 'sentinel phrase'
  assert_equal "${status}" "1"
}

@test "the note gives one [build] arg slot per key (#951)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The note spells its routes as `arg_N = KEY=value` lines a reader
  # pastes into `.setup.conf`. Two paragraphs handing the same N to
  # different keys is not a typo a reader can absorb: a `[build]` section
  # written in `.setup.conf.local` REPLACES the section (the note says so
  # itself), so the second paste silently displaces the first. Derived
  # from the note rather than spelled as literals -- a literal pair goes
  # green the moment either paragraph is renumbered.
  local _note _line _n _key
  _note="$(_df_base_image_note "${_df}")"
  [[ -n "${_note}" ]] || fail "no comment run found above 'ARG BASE_IMAGE=' in ${_df}"
  local -A _by_slot=() _by_key=()
  while IFS= read -r _line; do
    _n="${_line%%|*}"
    _key="${_line#*|}"
    if [[ -n "${_by_slot[${_n}]:-}" && "${_by_slot[${_n}]}" != "${_key}" ]]; then
      fail "arg_${_n} is given to both ${_by_slot[${_n}]} and ${_key}"
    fi
    if [[ -n "${_by_key[${_key}]:-}" && "${_by_key[${_key}]}" != "${_n}" ]]; then
      fail "${_key} is given both arg_${_by_key[${_key}]} and arg_${_n}"
    fi
    _by_slot["${_n}"]="${_key}"
    _by_key["${_key}"]="${_n}"
  done < <(sed -n 's/.*arg_\([0-9][0-9]*\)[[:space:]]*=[[:space:]]*\([A-Z_][A-Z_0-9]*\)=.*/\1|\2/p' <<< "${_note}")
  # A note that stopped spelling any slot would satisfy the relation
  # vacuously, and the local route is the one this repo drives builds
  # through.
  (( ${#_by_slot[@]} >= 2 )) \
    || fail "expected the note to spell >= 2 '[build] arg_N = KEY=' routes, found ${#_by_slot[@]}"
}

@test "the apt-layer guard sees the install shapes this template writes (#951)" {
  # The guard's REACH is the property "every apt layer refreshes the
  # manifest": a shape _DF_APT_INSTALL_RE does not match is a layer the
  # relation is never asked about, while the block still counts toward
  # the `>= 2` floor -- so the suite stays green over exactly the drift
  # this spec is named for. The template already writes
  # `-o Dpkg::Options::="--force-confdef"` (devel-base); positioned
  # BEFORE the subcommand, which apt-get accepts, an option that takes a
  # separate argument is what a glued-token-only pattern cannot cross.
  local _shape
  for _shape in \
      'apt-get install -y foo' \
      'apt-get -y install foo' \
      'apt install --no-install-recommends foo' \
      'rosdep install --from-paths src' \
      'apt-get -o Dpkg::Options::="--force-confdef" install cowsay' \
      'apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install cowsay'; do
    [[ "${_shape}" =~ ${_DF_APT_INSTALL_RE} ]] \
      || fail "apt-layer guard cannot see this install layer: ${_shape}"
  done
  # ... and reach is only half of it. Widened until it matches a block
  # that installs nothing, the same guard demands a manifest refresh from
  # `apt-get clean` and reports "installs AFTER its last refresh" for a
  # tail that installs nothing.
  for _shape in \
      'apt-get update && apt-get clean && rm -rf /var/lib/apt/lists/*' \
      'apt-get -y update && echo install' \
      'pip install foo'; do
    if [[ "${_shape}" =~ ${_DF_APT_INSTALL_RE} ]]; then
      fail "apt-layer guard reads a non-install layer as one: ${_shape}"
    fi
  done
}

@test "Dockerfile.example states the moving-BASE_IMAGE reproducibility trade-off (#951)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # A downstream author meets this trade in the file they edit, not in
  # base's docs, so the file has to name the drift, the compensating
  # record, and the escape hatch -- in the NOTE, which is where that
  # author reads it. Read from the note's own window, not the file: both
  # manifest paths below are also spelled in the live sys RUN and again
  # in the commented runtime-base scaffold, so a whole-file grep is
  # satisfied by the implementation with the explanation deleted.
  local _note
  _note="$(_df_base_image_note "${_df}")"
  [[ -n "${_note}" ]] || fail "no comment run found above 'ARG BASE_IMAGE=' in ${_df}"

  run grep -F 'MOVING tag' <<< "${_note}"
  assert_success
  run grep -F '/usr/local/share/base/base-image.env' <<< "${_note}"
  assert_success
  run grep -F '/usr/local/share/base/packages.txt' <<< "${_note}"
  assert_success
  # The escape hatch is a build arg, so pinning costs a consumer no edit
  # to this file and no divergence from the template.
  run grep -F 'BASE_IMAGE=ubuntu@sha256:' <<< "${_note}"
  assert_success
  # ... and the route it names first has to be the one this repo actually
  # drives builds through. `[build] arg_N` in .setup.conf reaches the
  # build via `just setup` + `just build`; a note that offers only
  # `--build-arg` sends a local reader to the one surface the repo's
  # convention refuses, and offering only an `ARG` default edit sends
  # them to a template-owned line a later migration may rewrite.
  run grep -F '.setup.conf' <<< "${_note}"
  assert_success
  run grep -F 'just setup' <<< "${_note}"
  assert_success
}

@test "Dockerfile.example states what the UNPINNED default does not record (#951)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The half of the reproducibility question the shipped default does NOT
  # answer. With `ubuntu:24.04` and no BASE_IMAGE_DIGEST the manifest
  # records the reference as given and `base_image_pin=none` -- it cannot
  # say WHICH image that tag resolved to, which is precisely the case the
  # moving tag is a problem in. A note that describes only the record and
  # not its blind spot reads as a stronger guarantee than the file gives,
  # so the limitation is asserted, not left to the reader.
  # Read from the note's own window for the same reason as the test
  # above: `base_image_digest` and `BASE_IMAGE_DIGEST` are both spelled
  # in the live sys stage that emits them, so a whole-file grep passes
  # with the note's statement of the blind spot deleted.
  local _note
  _note="$(_df_base_image_note "${_df}")"
  [[ -n "${_note}" ]] || fail "no comment run found above 'ARG BASE_IMAGE=' in ${_df}"

  run grep -F 'base_image_digest' <<< "${_note}"
  assert_success
  run grep -F 'does NOT record which digest' <<< "${_note}"
  assert_success
  # ... and the one-argument way out of it, for a consumer who wants the
  # digest recorded without pinning to it.
  run grep -F 'BASE_IMAGE_DIGEST' <<< "${_note}"
  assert_success
  # Spelled as the config entry a reader can paste, not as prose about a
  # config file: the `[build] arg_N` list is the local control surface,
  # and `arg_4` is the next free slot after the three the template ships.
  run grep -F 'arg_4 = BASE_IMAGE_DIGEST=sha256:' <<< "${_note}"
  assert_success
  # The recipe the note gives for OBTAINING that value has to produce
  # that shape. `docker image inspect --format '{{index .RepoDigests 0}}'`
  # prints a REFERENCE (`ubuntu@sha256:<hex>`), not a digest, and the
  # value is emitted verbatim into base_image_digest and into the OCI
  # `base.digest` annotation -- where OCI defines a digest, not a
  # reference. Following the note as written therefore produced a record
  # of a different shape than the pin route produces for the same image.
  # The strip is what makes the two routes comparable, so it is asserted
  # next to the storage line it has to agree with.
  run grep -F '${BASE_IMAGE_DIGEST##*@}' <<< "${_note}"
  assert_success
  # The layering caveat travels with it. `.setup.conf.local` merges
  # section-REPLACE, so adding one arg there silently drops the
  # APT_MIRROR_* / TZ args the repo already had.
  run grep -F 'replaces the whole' <<< "${_note}"
  assert_success
}

@test "Dockerfile.example sys stage records the base ref it resolved (#951)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Read the LIVE sys stage's own window, not the file. Every line below
  # also exists, commented, in the runtime-base scaffold, so a whole-file
  # grep is satisfied by the comment: the primary deliverable of this
  # change could be deleted outright with each assertion still green.
  local _block
  _block="$(_df_sys_block "${_df}")"
  [[ -n "${_block}" ]] || fail "sys stage window not found in ${_df}"

  # The pre-FROM ARG is FROM-scope only. Without a bare re-declaration
  # inside the stage, ${BASE_IMAGE} expands to the empty string in the
  # RUN that records it and the manifest records nothing, silently.
  run grep -cE '^ARG BASE_IMAGE$' <<< "${_block}"
  assert_output "1"
  run grep -F 'echo "base_image_ref=${BASE_IMAGE}"' <<< "${_block}"
  assert_success
  # ... written to the file a consumer and the runtime smoke both read.
  run grep -F '} > /usr/local/share/base/base-image.env' <<< "${_block}"
  assert_success
  # Whether the reference was digest-pinned is part of the record: an
  # unpinned reference names an image that may already have moved.
  run grep -F 'base_image_pin=digest' <<< "${_block}"
  assert_success
  run grep -cE '^ARG BASE_IMAGE_DIGEST=' <<< "${_block}"
  assert_output "1"
  # OCI annotations too, so `docker inspect` answers without unpacking.
  run grep -F 'LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"' <<< "${_block}"
  assert_success

  # The digest is recorded ONCE, by one expression, into both sinks. A
  # LABEL cannot BRANCH, so an expression whose answer DEPENDS on the
  # reference's shape gives the file one value and the label another --
  # in the one field this record exists to make comparable. (Reading a
  # digest is well within a label: `${BASE_IMAGE##*@}` in one comes back
  # as `sha256:<hex>`, which a probe build of this repo's harness proves.
  # The same expression comes back as `ubuntu:24.04` for an unpinned
  # reference, and that is the half a label has no way to tell apart.)
  # Read out of the stage and COMPARED rather than spelled as two
  # literals: a pair of literals goes green the moment either side moves,
  # which is exactly how the two answers got there.
  local _file_digest _label_digest
  _file_digest="$(sed -n 's/.*base_image_digest=\([^"]*\)".*/\1/p' <<< "${_block}")"
  _label_digest="$(sed -n 's/.*image\.base\.digest="\([^"]*\)".*/\1/p' <<< "${_block}")"
  assert [ -n "${_file_digest}" ]
  assert [ -n "${_label_digest}" ]
  assert_equal "${_file_digest}" "${_label_digest}"

  # ... and the stage does not STOP over the half a label cannot derive.
  # A digest-carrying BASE_IMAGE with no build arg is a configuration
  # this same file documents; refusing it makes every consumer who
  # digest-pins re-pass a value they already gave, to fill a field whose
  # emptiness was already truthful. The record answers it instead:
  # `base_image_pin=digest` next to an empty digest is "pinned, digest
  # not separately recorded". Asserted as the ABSENCE of a build-stopping
  # exit in the recording window, because that is the shape a refusal
  # takes here and the one a reader of this stage would meet.
  run grep -c 'exit 1' <<< "${_block}"
  assert_output "0"
}

@test "Dockerfile.example rewrites the package manifest after every apt layer (#951)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The property is a RELATION over the apt layers, not a tally of
  # refreshes. A hand-kept count ("2 live, 3 commented") is green for a
  # template that grew a fourth apt layer and no fourth refresh -- the
  # exact defect this test is named for -- because the number it checks
  # is not derived from the thing it is about.
  local _blk _n

  # sys and devel-base each install packages. A manifest written only in
  # sys would omit the devel-base set (sudo / git / curl / ...) -- the
  # larger half of what floats -- while reading as complete.
  _n=0
  while IFS= read -r _blk; do
    _n=$(( _n + 1 ))
    _df_assert_refresh_last "${_blk}" "live apt RUN block"
  done < <(_df_apt_run_blocks "${_df}" live)
  # ... and a template that lost its apt layers would satisfy the
  # relation vacuously, so the two known live installers are a floor.
  (( _n >= 2 )) || fail "expected >= 2 live apt RUN blocks in ${_df}, found ${_n}"

  # Every commented-out apt block a consumer is invited to uncomment
  # (devel's application packages, builder's build deps, runtime-base's
  # runtime deps) carries the refresh too, so following the template does
  # not silently produce an image whose manifest omits the packages the
  # consumer added.
  _n=0
  while IFS= read -r _blk; do
    _n=$(( _n + 1 ))
    _df_assert_refresh_last "${_blk}" "commented apt RUN example"
  done < <(_df_apt_run_blocks "${_df}" commented)
  (( _n >= 3 )) || fail "expected >= 3 commented apt RUN examples in ${_df}, found ${_n}"
}

@test "_df_apt_run_blocks sees a BuildKit heredoc apt layer (#951)" {
  # `RUN <<EOF` ... `EOF` is one layer whose body carries no backslash
  # continuations, so a scanner that opens on `RUN ` and closes on the
  # first line without a trailing `\` sees a one-line RUN and stops: the
  # apt-get lines are invisible, the layer is never asked for a manifest
  # refresh, and it does not count toward the `>= 2` / `>= 3` floors
  # either -- so every assertion in the relation above stays green over a
  # template that grew one. Same class as the option-before-subcommand
  # hole: a shape the helper never claimed not to handle, silently
  # exempting a real layer.
  #
  # The shipped template writes no heredocs today, so this pins the
  # HELPER against a fixture rather than the file -- the only way to
  # state the contract before the shape arrives, and the reason the
  # fixture is written into a scratch dir instead of into the checkout.
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/Dockerfile" <<'FIXTURE'
FROM alpine AS live
RUN <<EOF
apt-get update
apt-get install -y cowsay
dpkg-query -W > /usr/local/share/base/packages.txt
EOF

# FROM alpine AS commented
# RUN <<-'EOF'
# apt-get update
# apt-get install -y cowsay
# dpkg-query -W > /usr/local/share/base/packages.txt
# EOF
FIXTURE

  local _n _blk
  _n=0
  while IFS= read -r _blk; do
    _n=$(( _n + 1 ))
    _df_assert_refresh_last "${_blk}" "heredoc live apt RUN block"
  done < <(_df_apt_run_blocks "${_tmp}/Dockerfile" live)
  assert_equal "${_n}" "1"

  # ... and the commented mirror, which is the copy a consumer uncomments.
  _n=0
  while IFS= read -r _blk; do
    _n=$(( _n + 1 ))
    _df_assert_refresh_last "${_blk}" "heredoc commented apt RUN example"
  done < <(_df_apt_run_blocks "${_tmp}/Dockerfile" commented)
  assert_equal "${_n}" "1"

  # Seeing the block is only half of it: the ORDER property has to hold
  # inside a heredoc too, or the helper reports a layer it cannot judge.
  cat > "${_tmp}/Dockerfile.bad" <<'FIXTURE'
FROM alpine AS live
RUN <<EOF
dpkg-query -W > /usr/local/share/base/packages.txt
apt-get install -y cowsay
EOF
FIXTURE
  _blk="$(_df_apt_run_blocks "${_tmp}/Dockerfile.bad" live)"
  [[ -n "${_blk}" ]] || fail "the out-of-order heredoc block was not seen at all"
  run _df_assert_refresh_last "${_blk}" "heredoc out-of-order"
  assert_failure

  # A here-STRING is not a heredoc: `<<<` opens nothing, and reading it as
  # a delimiter swallows every layer below it into one block.
  #
  # COUNTING the blocks cannot see that happen. The correct reading of a
  # here-string RUN followed by one apt layer is one block; the fused
  # reading of the same two lines is also one block, so the positive and
  # the negative case produce the identical observation. What separates
  # them is the CONTENT -- whether the here-string RUN's own text is
  # inside a block -- and the CONSEQUENCE: the fixture puts a DEFECTIVE
  # layer (refresh, then install) under the here-string, because fusing
  # hides exactly that defect. Its install lands before the fused tail's
  # last refresh, so the relation reports the layer clean.
  cat > "${_tmp}/Dockerfile.herestring" <<'FIXTURE'
FROM alpine AS live
RUN grep -q x <<<"${y}"
RUN dpkg-query -W > /usr/local/share/base/packages.txt && \
    apt-get install -y baddefect
RUN apt-get install -y cowsay && \
    dpkg-query -W > /usr/local/share/base/packages.txt
FIXTURE
  _df_assert_no_herestring_fusion "${_tmp}/Dockerfile.herestring" live

  # ... and the commented mirror, the copy a consumer uncomments: the same
  # awk reads both modes, so a shape the live mode mistakes for a heredoc
  # the commented mode mistakes for one too.
  sed 's/^/# /' "${_tmp}/Dockerfile.herestring" > "${_tmp}/Dockerfile.herestring.commented"
  _df_assert_no_herestring_fusion "${_tmp}/Dockerfile.herestring.commented" commented
  rm -rf "${_tmp}"
}

@test "Dockerfile.example commented runtime-base records its own manifest (#951)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # runtime-base is a FRESH ${BASE_IMAGE}, so it inherits nothing the sys
  # stage wrote. Uncommenting the optional builder/runtime split must not
  # produce the one image in the graph that cannot say what built it.
  #
  # Read the stage's own window: every line asserted here also appears in
  # devel's or builder's commented apt block, so a whole-file grep would
  # stay green with runtime-base's copy deleted.
  local _block
  _block="$(_df_runtime_base_block "${_df}")"
  [[ -n "${_block}" ]] || fail "runtime-base stage window not found in ${_df}"

  run grep -xF '# ARG BASE_IMAGE' <<< "${_block}"
  assert_success
  run grep -xF '# ARG BASE_IMAGE_DIGEST' <<< "${_block}"
  assert_success
  run grep -F '#     dpkg-query -W > /usr/local/share/base/packages.txt' <<< "${_block}"
  assert_success
  run grep -F '#       echo "base_image_ref=${BASE_IMAGE}"' <<< "${_block}"
  assert_success
  run grep -F '# LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"' <<< "${_block}"
  assert_success
  # One expression into both sinks here too. runtime-base is the copy a
  # consumer uncomments, so a divergence left in it ships to every repo
  # that turns the runtime split on.
  local _file_digest _label_digest
  _file_digest="$(sed -n 's/.*base_image_digest=\([^"]*\)".*/\1/p' <<< "${_block}")"
  _label_digest="$(sed -n 's/.*image\.base\.digest="\([^"]*\)".*/\1/p' <<< "${_block}")"
  assert [ -n "${_file_digest}" ]
  assert [ -n "${_label_digest}" ]
  assert_equal "${_file_digest}" "${_label_digest}"

  # ... and this stage does not STOP the build either, for the same
  # reason the sys window above does not. This scaffold is the copy the
  # shipped hadolint rationale tells a consumer to paste ("the sys stage
  # RUN and, if the runtime split is enabled, runtime-base's"), so a
  # refusal surviving HERE refuses exactly the reference-only pin the
  # note beside `ARG BASE_IMAGE` recommends -- in the one image of this
  # graph that ships. Asserted on the same shape as sys, in this stage's
  # own window, because one window demanding the guard while the other
  # forbids it is how the refusal outlived its removal.
  run grep -c 'exit 1' <<< "${_block}"
  assert_output "0"
}

@test ".hadolint.yaml DL3008 ignore names its compensating control (#951)" {
  local _cfg="/source/dist/.hadolint.yaml"
  assert_spec_subject "${_cfg}" \
      "the shipped hadolint config this spec pins"
  # DL3008 is the one rule that exists for the unpinned apt lines this
  # template ships. Ignoring it with no compensating control is what
  # makes the template lint clean while being non-reproducible, so the
  # ignore has to name what compensates for it -- in ITS OWN rationale
  # block, not somewhere else in the file under an unrelated rule.
  local _why
  _why="$(_hadolint_ignore_rationale "${_cfg}" DL3008)" \
    || fail "no '- DL3008' entry found in ${_cfg}"
  [[ -n "${_why}" ]] || fail "DL3008 is ignored with no rationale block above it"

  run grep -F '/usr/local/share/base/packages.txt' <<< "${_why}"
  assert_success
  # This config is symlinked into every downstream repo by init.sh, where
  # it lints that repo's OWN hand-edited Dockerfile -- which carries the
  # manifest only once the repo has adopted this template revision. A
  # rationale that says "every image built from this template records its
  # packages" is read there as a claim about the reader's image, so it
  # has to name the condition and how to meet it.
  run grep -F 'Dockerfile predates' <<< "${_why}"
  assert_success
  run grep -F 'just upgrade' <<< "${_why}"
  assert_success
  # And it has to say WHY the upgrade does not close the gap on its own.
  # `just upgrade` can rewrite a consumer Dockerfile (init.sh and
  # upgrade.sh both call apply_migrations over the `_MIGRATIONS` list in
  # dist/script/docker/lib/dockerfile_migrate.sh), so "the upgrade does
  # not rewrite it" is not the reason; "no
  # migration was written for this record, because it splices into the
  # middle of a hand-shaped RUN chain" is. Naming the mechanism is what
  # stops the false reason coming back.
  run grep -F 'dockerfile_migrate.sh' <<< "${_why}"
  assert_success
}

@test "the shipped smoke spec demands the manifest's VALUE and fails closed on half of one (#951)" {
  local _spec="/source/dist/test/bats/smoke/shared/reproducibility.bats"
  # This test is TEXT about a spec, and it is named for what text can
  # actually establish. Whether that spec RUNS rather than skipping where
  # base itself runs it is a property of base's harness, asserted in
  # test/bats/unit/smoke_harness_spec.bats against
  # dockerfile/Dockerfile.smoke -- a grep of this file cannot tell a spec
  # that ran from one that skipped, and a name claiming otherwise is a
  # guarantee nothing checks.
  #
  # What the shipped spec is for: text cannot catch a manifest that IS
  # written and records nothing -- the exact failure an out-of-scope
  # ${BASE_IMAGE} produces. That assertion has to run inside a built
  # image, which is what the shared smoke tree is: COPYed into every
  # `-test` stage and executed by `RUN bats`.
  assert [ -f "${_spec}" ]
  # The load-bearing half is the non-empty VALUE. A spec that only checks
  # the file exists passes on the empty record.
  run grep -F 'base_image_ref=[^[:space:]]+' "${_spec}"
  assert_success
  # ... and the digest, when the record carries one, has to be a DIGEST.
  # The one expression that supplies it (the BASE_IMAGE_DIGEST build arg
  # the note tells a reader how to compute) is copied verbatim into the
  # OCI base.digest annotation as well, so a reference pasted into it
  # lands in both sinks at once.
  run grep -F 'base_image_digest=(sha256:[0-9a-f]' "${_spec}"
  assert_success
  # ... and where the record states the digest TWICE -- once inside
  # `base_image_ref`, once in `base_image_digest` -- the two have to
  # agree. That check lives here, in the spec that runs inside the built
  # image, and not in a build refusal: refusing was indiscriminate (it
  # stopped the honest digest-pinned build that simply omits the arg),
  # while a record answering one field two ways is false whoever built
  # it. It is the `-test` stage's job to say so.
  run grep -F 'does not contradict' "${_spec}"
  assert_success
  # The skip is narrow by construction: it fires only when NEITHER file
  # exists, so a repo that writes one and not the other, or writes an
  # empty record, has adopted the manifest and broken it -- and that
  # fails. A guard widened to "either is missing" would turn every real
  # regression this file exists for into a green skip.
  run grep -F '[[ ! -e "${REPRO_ENV}" && ! -e "${REPRO_PKGS}" ]]' "${_spec}"
  assert_success
  # The skip's stated REASON has to match the wiring. `just upgrade` does
  # rewrite a consumer Dockerfile -- init.sh and upgrade.sh both call
  # apply_migrations -- so "the consumer's Dockerfile is not rewritten by
  # the upgrade" was false where this file ships it to 17 repos. The true
  # reason is that no migration was written for this record, which means
  # the header has to name the mechanism it is declining or the next
  # reader re-derives the wrong one.
  run grep -F 'dockerfile_migrate.sh' "${_spec}"
  assert_success
}

@test "build-worker.yaml: runtime-test build forwards TEST_TOOLS_IMAGE (#647 prerequisite)" {
  # When runtime-test does COPY --from=test-tools-stage, test-tools
  # enters its build graph, so its build must receive the pinned
  # TEST_TOOLS_IMAGE just like devel-test (else FROM ${TEST_TOOLS_IMAGE}
  # falls back to test-tools:local and CI fails with pull-access-denied).
  local _wf="/source/.github/workflows/build-worker.yaml"
  assert_spec_subject "${_wf}" \
      "the reusable build worker this spec pins"
  # Two forwards expected: devel-test and runtime-test build steps.
  run grep -cE '^            TEST_TOOLS_IMAGE=ghcr\.io/ycpss91255-docker/test-tools:\$\{\{ inputs\.test_tools_version \}\}$' "${_wf}"
  assert_output "2"
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: runtime-test stage syntax (v0.21.1 fix /
# v0.23.1 follow-up)
#
# v0.21.0 shipped the runtime-test block with `RUN ${RUNTIME_SMOKE_CMD}`
# and `USER root`. Both were buggy:
#   1. Bare `RUN ${ARG}` word-splits the substituted value: shell
#      operators (&&, ||) and nested quotes get treated as literal
#      args to the first command. Concrete failure: with default
#      ARG `bash -lc "whoami && bash --version && exit 0"`, bash
#      tokenized as `whoami '&&' bash '--version'` and whoami saw
#      `--version` as an arg, printing its own version info instead
#      of running the chain. Discovered during sick_humble's manual
#      v0.21.0 rollout.
#   2. `USER root` triggered hadolint DL3002 (last USER should not
#      be root). runtime-test is ephemeral, but hadolint can't
#      know that; the lint failure was real.
#
# v0.21.1 fix: drop USER root (inherit non-root from runtime), and
# wrap the ARG in `sh -c "..."` so the value is passed as a single
# string for the shell to parse.
#
# v0.23.1 follow-up: `sh -c` (dash) doesn't support `source` or
# bash parameter expansion, blocking any override that sourced
# bash-syntax files (e.g. `. /opt/ros/$DISTRO/setup.bash`). Switched
# to `bash -c` -- bash is present in every Ubuntu/Debian runtime
# image the template targets, the dependency is safe, and downstream
# overrides can now use natural shell semantics. Discovered during
# the v0.21.1 runtime-test framework's downstream rollout
# (ycpss91255-docker/docker_harness#57); see also
# ycpss91255-docker/template#249.
#
# The grep tests below lock all three invariants (positive: bash -c
# wrapper present; negative: no bare ARG substitution; negative:
# no stale sh -c wrapper) so the bug can't regress.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example runtime-test uses bash -c wrapper (regression: #243 word-split + #57 dash-source bugs)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The runtime-test block is commented out (opt-in for repos with a
  # runtime stage). The RUN line in the comment must use bash -c so
  # downstream RUNTIME_SMOKE_CMD overrides can use bash semantics
  # (source / . of bash-syntax files, parameter expansion, etc.).
  run grep -E '^# RUN bash -c "\$\{RUNTIME_SMOKE_CMD\}"$' "${_df}"
  assert_success
}

@test "Dockerfile.example runtime-test does NOT use bare RUN \${RUNTIME_SMOKE_CMD} (v0.21.0 word-split regression guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Regression guard: bare form word-splits operators / nested quotes.
  run grep -E '^# RUN \$\{RUNTIME_SMOKE_CMD\}$' "${_df}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "Dockerfile.example runtime-test does NOT use sh -c wrapper (v0.21.1 -> v0.23.1 dash-source regression guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Regression guard: sh -c (dash) cannot parse bash-syntax files in
  # `source` / `.` overrides. Blocks all ROS-style smoke commands.
  # See ycpss91255-docker/docker_harness#57 + for context.
  run grep -E '^# RUN sh -c "\$\{RUNTIME_SMOKE_CMD\}"$' "${_df}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "Dockerfile.example runtime-test does NOT set USER root (DL3002 regression guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Hadolint DL3002 fires on `USER root` if it ends up the last USER
  # in the Dockerfile. runtime-test inherits non-root from runtime;
  # leave it that way. Downstream override via sudo if privileged
  # smoke is genuinely needed.
  #
  # Match the commented-out form in Dockerfile.example.
  run grep -E '^# USER root$' "${_df}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: builder + runtime split pattern
#
# Lifts the three lessons proven empirically in
# ycpss91255-docker/ros1_bridge#60 (saved ~1.1 GB/arch on runtime):
#   1. runtime MUST NOT be FROM devel -- forces devel to delete its
#      own source to avoid runtime bloat, breaking the dev workflow.
#   2. Runtime apt: install only the ldd-identified missing libs.
#      Bulk-installing builder deps defeats the runtime/devel split.
#   3. `source FILE` in entrypoints needs trailing `--` (ROS 1 catkin
#      / _setup_util.py argparse pitfall when CMD has --flag args).
#
# Tests below grep for marker text proving each lesson is documented
# inline so the commented-out reference pattern can't silently lose
# them.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example top stage-list documents builder stage (#239)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The top-of-file "Stages:" comment is the first thing a user
  # reading the template sees. builder must appear there or the
  # downstream pattern is invisible.
  run grep -E '^#   builder ' "${_df}"
  assert_success
}

@test "Dockerfile.example documents 3 builder/runtime split lessons (#239)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Three explicit lesson markers (text must persist verbatim in
  # the commented-out reference block so the lift from ros1_bridge#60
  # stays load-bearing).
  run grep -F 'runtime` MUST NOT be `FROM devel`' "${_df}"
  assert_success
  run grep -F 'install only the libs `ldd` proves are missing' "${_df}"
  assert_success
  run grep -F 'source FILE` in entrypoints needs a trailing `--`' "${_df}"
  assert_success
}

@test "Dockerfile.example has commented-out builder + runtime + COPY --from=builder reference (#239)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The concrete commented-out skeleton downstream can uncomment.
  # All three lines must be commented (#-prefixed) so the example
  # doesn't try to build by default; downstream uncomments when
  # opting in via main.yaml build_runtime: true.
  run grep -E '^# FROM devel-base AS builder$' "${_df}"
  assert_success
  run grep -E '^# FROM \$\{BASE_IMAGE\} AS runtime-base$' "${_df}"
  assert_success
  run grep -E '^# COPY --from=builder ' "${_df}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: runtime interactive-shell env source
#
# The minimal runtime stage does NOT inherit devel's ~/.bashrc +
# ~/.bashrc.d/ wiring, so `docker exec -it <runtime> bash`
# (`just exec -t runtime bash`) gets none of the repo env (e.g. ROS
# `ros2`). The runtime block must document, as an OPTIONAL opt-in, the
# lightweight one-line /etc/bash.bashrc source so interactive exec
# shells in runtime pick up the env -- WITHOUT dragging the full config/
# COPY into the minimal runtime, and WITHOUT baking env into Dockerfile
# ENV. The ROS-specific source line belongs downstream (base is
# ROS-agnostic). Tests below grep for the documented marker + example
# line so the pattern can't silently disappear.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example runtime documents 3-process-kinds env rationale (#657)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The rationale must explain why entrypoint (PID 1) and bashrc
  # (interactive) are complementary, both needed -- so a future edit
  # doesn't collapse the runtime gap into a wrong "fix the entrypoint".
  run grep -F 'Interactive-shell env source for `docker exec`' "${_df}"
  assert_success
}

@test "Dockerfile.example runtime shows commented /etc/bash.bashrc source example (#657)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # The example must be commented (leading '# ') so the minimal runtime
  # stays minimal by default -- it is an opt-in snippet, not a mandatory
  # layer. The ROS source line is the consumer's (base is ROS-agnostic).
  run grep -E "^# #   RUN echo 'source /opt/ros/\\\$ROS_DISTRO/setup.bash' >> /etc/bash.bashrc$" "${_df}"
  assert_success
}

@test "Dockerfile.example runtime does NOT bake ROS env into ENV (#657 fragility guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Guard the rejected alternative: no ENV LD_LIBRARY_PATH / PYTHONPATH
  # baked for ROS (arch- and python-version-dependent -- fragile).
  run grep -E '^ENV (LD_LIBRARY_PATH|PYTHONPATH)=' "${_df}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# pip scaffolding removed (reverses)
#
# dockerfile/setup/ and all pip-related Dockerfile.example patterns
# have been removed. Downstream repos that need pip handle it
# independently in their own Dockerfiles.
# ════════════════════════════════════════════════════════════════════

@test "template no longer ships dockerfile/setup/ (#407, reverses #261)" {
  [[ ! -e /source/dockerfile/setup ]]
}

@test "template no longer ships config/pip/ (#261 relocation regression guard)" {
  [[ ! -e /source/dist/config/pip ]]
}

@test "Dockerfile.example has no SETUP_DIR or pip references (#407)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  run grep -E 'SETUP_DIR|python3-pip|pip/setup|pip install' "${_df}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: ENV alignment with downstream fleet
#
# All 17 hand-written downstream Dockerfiles declare ENV TZ +
# ENV LANGUAGE alongside ENV LC_ALL / ENV LANG. the seed
# Dockerfile.example only had LC_ALL / LANG; downstream-derived images
# from `/new-repo` therefore silently differed from the fleet on
# runtime $TZ and $LANGUAGE. The gap surfaces only for consumers that
# read the env directly (Python tzlocal, gettext fallback, some JVM
# tz resolution paths), but new repos should match the fleet.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example declares ENV TZ (matches downstream fleet, #210)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Forwards the build-time ARG TZ value into a runtime env. ENV without
  # an explicit value would inherit the ARG, which is what we want — the
  # exact spelling the test locks is `ENV TZ="${TZ}"` to mirror how the
  # 17 downstream Dockerfiles spell it.
  run grep -E '^ENV TZ="\$\{TZ\}"$' "${_df}"
  assert_success
}

@test "Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  assert_spec_subject "${_df}" \
      "the shipped template Dockerfile this spec pins"
  # Same value the 17 downstream Dockerfiles use; gettext fallback uses
  # $LANGUAGE in addition to $LANG so unset means the fallback chain
  # collapses to en_US only.
  run grep -E '^ENV LANGUAGE="en_US:en"$' "${_df}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# release-test-tools.yaml: GHCR publisher workflow
# ════════════════════════════════════════════════════════════════════

@test "release-test-tools.yaml exists and pushes to ghcr.io/ycpss91255-docker/test-tools" {
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${_yaml}" \
      "the test-tools release workflow this spec pins"
  run grep -F 'ghcr.io/ycpss91255-docker/test-tools' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml declares packages:write permission" {
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${_yaml}" \
      "the test-tools release workflow this spec pins"
  run grep -F 'packages: write' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml builds multi-arch (amd64 + arm64)" {
  # arches build on their native runners (not one QEMU runner),
  # then a merge job assembles the manifest list. Assert both native
  # runners are present rather than the old single combined
  # `platforms: linux/amd64,linux/arm64` string. Detailed structure is
  # covered by release_test_tools_yaml_spec.bats.
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${_yaml}" \
      "the test-tools release workflow this spec pins"
  run grep -F 'ubuntu-latest' "${_yaml}"
  assert_success
  run grep -F 'ubuntu-24.04-arm' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml uses template-repo-local Dockerfile path" {
  # Regression: this workflow runs in the template repo, so Dockerfile.test-tools
  # path must be `dockerfile/...` (not `.base/dockerfile/...` which is the
  # downstream subtree path used by build-worker.yaml).
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${_yaml}" \
      "the test-tools release workflow this spec pins"
  run grep -E '^\s*file: dockerfile/Dockerfile\.test-tools$' "${_yaml}"
  assert_success
  # And must NOT have the subtree-prefixed path:
  run grep -c 'file: .base/dockerfile/Dockerfile.test-tools' "${_yaml}"
  assert_output "0"
}

# ════════════════════════════════════════════════════════════════════
# release-worker.yaml: archive composition
# ════════════════════════════════════════════════════════════════════

@test "release archive payload declares no derived per-host artifact" {
  # compose.yaml has been gitignored since v0.9.0 (setup.sh-generated
  # derived artifact). An earlier release-worker.yaml listed it as a `cp`
  # operand, so every tag push hit
  # `cp: cannot stat 'compose.yaml': No such file or directory` and
  # action-gh-release never ran -- the ros1_bridge v1.5.0 release surfaced
  # it. The payload is a declared manifest now, so that is where a derived
  # artifact could creep back in; the same guard applies to the per-host
  # .setup.conf.
  local _manifest="/source/script/ci/release/archive.manifest"
  assert_spec_subject "${_manifest}" \
      "the release-archive payload manifest this spec pins"
  run grep -E '^(required|optional)\|[^|]*\|[^|]*(compose\.yaml|\.setup\.conf)' \
    "${_manifest}"
  assert_failure
}

# _manifest_declares <manifest> <path> -- succeed when <manifest> declares
# <path> as a candidate of some payload entry.
#
# Reads the assembler's own `--list` view of the parsed entries and compares
# whole candidate tokens, so ONLY the paths column can satisfy it. Matching
# anywhere in a declaration line also matches the description column, where
# the wrappers entry names `.base/` and the hadolint entry names
# `Dockerfile` -- one entry's prose then stands in for another entry's
# payload.
_manifest_declares() {
  local _manifest="$1" _want="$2" _line _candidate
  while IFS= read -r _line; do
    [[ "${_line}" =~ ^[[:space:]]+paths:[[:space:]](.*)$ ]] || continue
    for _candidate in ${BASH_REMATCH[1]}; do
      if [[ "${_candidate}" == "${_want}" ]]; then
        return 0
      fi
    done
  done < <(bash /source/script/ci/release-archive.sh --list "${_manifest}")
  return 1
}

@test "release archive payload still declares Dockerfile + script/ + .base/" {
  # Positive guard: making the payload tolerant of absence must not become
  # an excuse to drop entries from it. The user-facing wrappers ship via
  # `script/` (symlinks into .base/), not as root-level operands, so this
  # asserts `script/` rather than the removed root `build.sh`.
  local _manifest="/source/script/ci/release/archive.manifest"
  assert_spec_subject "${_manifest}" \
      "the release-archive payload manifest this spec pins"
  local _path
  for _path in 'Dockerfile' 'script/' '.base/'; do
    run _manifest_declares "${_manifest}" "${_path}"
    assert_success
  done
}

@test "release archive payload guard is not satisfied by another entry's description" {
  # A manifest line is <kind>|<key>|<paths>|<description>|<consequence>, so a
  # reader that matches anywhere in the line also matches the prose in the
  # description column. `.base/` and `Dockerfile` both appear there (the
  # wrappers entry describes itself as symlinks into `.base/`; the hadolint
  # entry describes the `Dockerfile` lint config), so the guard above would
  # keep answering "declared" for an entry that has been deleted -- satisfied
  # by another entry's description rather than by the payload it names.
  local _manifest="/source/script/ci/release/archive.manifest"
  assert_spec_subject "${_manifest}" \
      "the release-archive payload manifest this spec pins"
  local _tmp
  _tmp="$(mktemp -d)"
  grep -v '^required|base-subtree|' "${_manifest}" > "${_tmp}/pruned.manifest"
  run _manifest_declares "${_tmp}/pruned.manifest" '.base/'
  rm -rf "${_tmp}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# run.sh: XDG_SESSION_TYPE branching
# ════════════════════════════════════════════════════════════════════

@test "run.sh contains XDG_SESSION_TYPE check" {
  run grep "XDG_SESSION_TYPE" /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh contains xhost +SI:localuser for wayland" {
  run grep 'xhost "+SI:localuser' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh contains xhost +local: for X11" {
  run grep 'xhost +local:' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# setup.sh: default _base_path goes up 1 level (not 2)
# ════════════════════════════════════════════════════════════════════

@test "setup.sh default _base_path uses /.." {
  # In template, setup.sh is at .base/dist/script/docker/wrapper/setup.sh
  # So it should go up 1 level (..) to reach repo root
  run grep -E '\.\./\.\.' /source/dist/script/docker/wrapper/setup.sh
  assert_success  # Should have ../../ ../../ (that was old docker_setup_helper/src/ pattern)
}

@test "setup.sh default _base_path uses double parent traversal" {
  # setup.sh resolves the script directory once via readlink -f into
  # _SETUP_SCRIPT_DIR (so invocation through the root-level symlink works),
  # then walks up `../../..` to reach the repo root. The base_path-default
  # resolution moved with the subcommands into lib/setup_cmd.sh during the
  # setup.sh decomposition (ADR-00000014); the traversal still keys off the
  # same _SETUP_SCRIPT_DIR global setup.sh exports. Accept either the
  # original inline BASH_SOURCE form or the _SETUP_SCRIPT_DIR indirection.
  run grep -E "(dirname.*BASH_SOURCE|_SETUP_SCRIPT_DIR).*\.\..*\.\." \
    /source/dist/script/docker/lib/setup_cmd.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# pre/post hook wiring presence across all 7 wrappers
# ════════════════════════════════════════════════════════════════════

@test "all 7 wrappers call _run_pre_hook with their own name (#440)" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    run grep -E "_run_pre_hook ${_w}\b" "/source/dist/script/docker/wrapper/${_w}.sh"
    [[ "${status}" -eq 0 ]] \
      || { echo "missing _run_pre_hook ${_w} in ${_w}.sh"; return 1; }
  done
}

@test "all 7 wrappers call _run_post_hook with their own name (#440)" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    run grep -E "_run_post_hook ${_w}\b" "/source/dist/script/docker/wrapper/${_w}.sh"
    [[ "${status}" -eq 0 ]] \
      || { echo "missing _run_post_hook ${_w} in ${_w}.sh"; return 1; }
  done
}

@test "run.sh _app_cleanup runs post-hook before compose down (#440)" {
  # Order matters: container must still be alive when post-hook runs
  # so the hook can `docker exec` for final reporting.
  run bash -c "
    awk '
      /_app_cleanup\\(\\) \\{/ { in_func = 1; next }
      in_func && /_run_post_hook run/ { print \"POST_LINE=\" NR; post_seen = 1 }
      in_func && /_compose_(project|dispatch) down/ { print \"DOWN_LINE=\" NR; down_seen = 1 }
      in_func && /^\\}/ { exit }
    ' /source/dist/script/docker/wrapper/run.sh
  "
  assert_output --partial "POST_LINE="
  assert_output --partial "DOWN_LINE="
  local _post_line _down_line
  _post_line="$(echo "${output}" | grep POST_LINE | cut -d= -f2 | head -1)"
  _down_line="$(echo "${output}" | grep DOWN_LINE | cut -d= -f2 | head -1)"
  (( _post_line < _down_line )) \
    || { echo "post-hook should run before compose down: post=${_post_line} down=${_down_line}"; return 1; }
}

@test "lib/hook.sh skips both helpers under DRY_RUN (#440, #13)" {
  # Regression guard for Q13: dry-run contract requires no side effects.
  #
  # Over the code lines, and against the guard itself rather than the two
  # words near each other. hook.sh's header lists `DRY_RUN=true -> both pre
  # and post silently skipped` as part of its contract, so deleting the
  # actual early return left the whole-file regex matching that sentence
  # and this guard green. Both helpers route through __hook_run, so the one
  # early return is the whole property.
  run code_grep -F '[[ "${DRY_RUN:-false}" == "true" ]]' \
    /source/dist/script/docker/lib/hook.sh
  assert_success
}

@test "lib/hook.sh hard-fails on present-but-not-executable hook (#440, #11)" {
  run code_grep -E 'not executable.*chmod' /source/dist/script/docker/lib/hook.sh
  assert_success
}
