#!/usr/bin/env bats
#
# reclaim_wiring_spec.bats - the scoped reclaim runs by itself, at the
# verbs that END a compose project, and never changes their verdict.
#
# A chore that requires a human to remember it is not a handled chore: the
# collector this repo already shipped would have removed every one of the
# 417 orphaned networks measured on the development host, and it was never
# invoked. So the assertions here are about WIRING -- which verbs reclaim,
# which deliberately do not, and what a failing reclaim is allowed to do to
# the caller's exit status (nothing).
#
# `stop` is what a user reaches for when they are done with a project.
# `test` is where the litter is actually made: each throwaway copy of the
# tree mints a project of its own, and nobody runs `stop` in a copy they
# are about to delete. `system` and `smoke` drive compose directly rather
# than through test.sh's dispatcher, so they carry their own line.
#
# `build` / `run` / `start` / `exec` are NOT wired, and that is the whole
# point of the list: each of them BEGINS or CONTINUES a flow -- a build is
# followed by a run, an exec needs the container it attaches to -- so a
# reclaim there would be collecting a project that is about to be used.
#
# The other half of the wiring is the PRODUCER side. The collector proves
# ownership by reading the checkout path off the artifact, which only works
# if every path that creates one records it -- so the assertions below also
# pin that compose.yaml stamps the label, that the key it stamps is the key
# the collector reads, and that a compose invocation which cannot say which
# checkout it is gets refused rather than creating an artifact nobody can
# ever attribute.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TESTSH=/source/script/test/test.sh
  STOPSH=/source/dist/script/docker/wrapper/stop.sh
  PRUNESH=/source/dist/script/docker/wrapper/prune.sh
  JUSTTEST=/source/script/test/justfile.test
  JUSTDOCKER=/source/dist/script/docker/justfile.docker
  JUSTROOT=/source/justfile
  COMPOSE=/source/compose.yaml
  LIB=/source/dist/script/docker/lib/project_reclaim.sh
  SELFTEST=/source/.github/workflows/self-test.yaml
}

# ── the producer side: the artifact carries its own provenance ────────────

@test "compose.yaml records the checkout path on the network it creates" {
  run grep -nE '^ +base\.checkout\.path: ' "${COMPOSE}"
  assert_success
}

@test "the label compose writes is the label the collector reads" {
  # One key, two files. The day they drift, every artifact becomes
  # unattributable and the collector silently stops collecting -- which is
  # the safe direction, and therefore the direction nobody notices.
  local _key
  _key="$(bash -c "source ${LIB}; printf '%s' \"\${_RECLAIM_CHECKOUT_LABEL}\"")"
  [ -n "${_key}" ]
  run grep -F "${_key}:" "${COMPOSE}"
  assert_success
}

@test "a compose invocation that cannot say which checkout it is, is refused" {
  # `:?`, not a default. An artifact created without the label can never be
  # attributed to anything, so the failure has to land on the invocation
  # that would have created it -- the same rule HOST_UID and
  # TEST_TOOLS_IMAGE already follow in this file.
  run grep -E 'base\.checkout\.path: \$\{BASE_CHECKOUT_PATH:\?' "${COMPOSE}"
  assert_success
}

@test "every entry point that drives compose supplies the checkout path" {
  # The root justfile covers the whole `just` surface (a root export
  # reaches module recipes); test.sh covers the direct `./script/test`
  # invocations CI makes; self-test.yaml covers the one CI job that drives
  # compose itself.
  run grep -F 'export BASE_CHECKOUT_PATH' "${JUSTROOT}"
  assert_success
  run code_grep -F 'BASE_CHECKOUT_PATH' "${TESTSH}"
  assert_success
  run grep -F 'BASE_CHECKOUT_PATH' "${SELFTEST}"
  assert_success
}

@test "no caller hands the project sweep a repo root" {
  # The blocker this design closed: the sweep used to take the caller's
  # repo root, enumerate THAT repository's worktrees and delete everything
  # outside them, so the same call meant something destructive in a
  # downstream consumer. It now takes only a grace window, and a root
  # creeping back into any call site is the regression.
  local _f
  for _f in "${TESTSH}" "${STOPSH}" "${PRUNESH}"; do
    run code_grep -E '_reclaim_orphan_projects .*(FILE_PATH|REPO_ROOT)' "${_f}"
    assert_failure
  done
}

# ── `just test`: the verb that mints the litter ─────────────────────────────

@test "test.sh installs the reclaim as an EXIT handler on the direct-run path only" {
  # File scope, next to the `main "$@"` guard: a trap installed while the
  # specs have test.sh SOURCED would fire when the spec's own shell exits.
  run code_grep -E 'trap .*_test_exit_reclaim.* EXIT' "${TESTSH}"
  assert_success
}

@test "test.sh arms the reclaim where a compose project is actually minted" {
  run code_grep -F '_RECLAIM_ARMED=1' "${TESTSH}"
  assert_success
}

@test "a dispatch that refuses to start reclaims nothing" {
  # `--bats-integration` with no resolvable release tags dies in
  # _prepare_prev_release, before the first compose call and therefore
  # before any project exists. Arming above that line makes the refusal
  # open a daemon connection to sweep for litter the run never made -- and
  # the sweep no longer aborts on its own, since it needs no git. The arm
  # belongs below every step that can refuse.
  # Comments stripped first: the arm's own comment NAMES the step it must
  # sit below, and a line-number comparison that counts prose finds the
  # call twice and compares against nonsense.
  run bash -c "
    sed -n '/^_run_via_compose()/,/^}/p' '${TESTSH}' \
      | grep -vE '^[[:space:]]*#' \
      | grep -n -e '_RECLAIM_ARMED=1' -e '_prepare_prev_release'
  "
  assert_success
  local _prep _arm
  _prep="$(printf '%s\n' "${output}" | grep '_prepare_prev_release' | cut -d: -f1)"
  _arm="$(printf '%s\n' "${output}" | grep '_RECLAIM_ARMED=1' | cut -d: -f1)"
  [ -n "${_prep}" ] && [ -n "${_arm}" ]
  (( _arm > _prep )) || fail "the reclaim is armed at line ${_arm}, above _prepare_prev_release at ${_prep}"
}

@test "a reclaim failure does not change the suite's verdict" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { return 1; }
    _reclaim_tool_tags() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 7
  '
  [ "${status}" -eq 7 ]
}

@test "a reclaim failure does not turn a green run red" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { return 1; }
    _reclaim_tool_tags() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 0
  '
  [ "${status}" -eq 0 ]
}

@test "a reclaim failure is reported rather than swallowed" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { return 1; }
    _reclaim_tool_tags() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 0
  ' 2>&1
  assert_output --partial "reclaim"
}

@test "the reclaim still runs when the suite FAILED -- litter from a red run is litter" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { printf "ran-orphans\n"; }
    _reclaim_tool_tags() { printf "ran-tags\n"; }
    trap _test_exit_reclaim EXIT
    exit 3
  '
  [ "${status}" -eq 3 ]
  assert_output --partial "ran-orphans"
}

@test "retiring a tooling image is never automatic" {
  # The project sweep acts on a PROOF: the artifact records the checkout
  # that made it and that checkout is gone. Tag retention has no such
  # proof available -- the tooling tag is content-hash shared on purpose,
  # so no artifact can name all of a tag's users, and "no live checkout I
  # can see resolves it" is a measurement, not evidence that nothing needs
  # it. Measured on the shared host: the first automatic run retired one
  # tooling image nobody asked it to, and with the recency window out of
  # the way the same rule names the tag a live sibling worktree still
  # resolves. The cost is a rebuild rather than data, but an unprovable
  # removal must not run unasked -- the same rule --volumes and
  # --worktree-orphans already follow in prune.sh.
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { printf "ran-orphans\n"; }
    _reclaim_tool_tags() { printf "ran-tags\n"; }
    trap _test_exit_reclaim EXIT
    exit 0
  '
  assert_output --partial "ran-orphans"
  refute_output --partial "ran-tags"
}

@test "a run that minted no compose project reclaims nothing" {
  # `test.sh --test-tools-image` is a pure query the system / smoke recipes
  # call before they build; it must not open a daemon connection.
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _reclaim_orphan_projects() { printf "ran-orphans\n"; }
    _reclaim_tool_tags() { printf "ran-tags\n"; }
    trap _test_exit_reclaim EXIT
    exit 0
  '
  [ "${status}" -eq 0 ]
  refute_output --partial "ran-orphans"
}

# ── the other two litter-minting test flows ────────────────────────────────

@test "just test system reclaims when it is done, pass or fail" {
  # --orphan-projects, not --reclaim: these recipes reclaim by themselves,
  # and the tag half is the half nothing may do unasked (see "retiring a
  # tooling image is never automatic" above).
  run grep -cF 'script/prune.sh --orphan-projects' "${JUSTTEST}"
  assert_output "2"
  run grep -F 'script/prune.sh --reclaim' "${JUSTTEST}"
  assert_failure
}

# ── `just stop`: what a user reaches for when they are done ────────────────

@test "stop.sh reclaims after the project comes down" {
  run code_grep -F '_reclaim_after_stop' "${STOPSH}"
  assert_success
}

@test "stop.sh's reclaim cannot fail the stop" {
  run code_grep -F '_reclaim_after_stop || true' "${STOPSH}"
  assert_success
}

# ── the verbs that are NOT wired, named so the omission is a decision ──────

@test "the verbs that BEGIN a flow do not reclaim" {
  local _v
  for _v in build run exec; do
    run code_grep -F '_reclaim_after' "/source/dist/script/docker/wrapper/${_v}.sh"
    assert_failure
  done
}

# ── the daemon-wide prune stays the explicit bigger hammer ─────────────────

@test "prune.sh exposes the scoped reclaim as its own mode" {
  run code_grep -F -- '--reclaim' "${PRUNESH}"
  assert_success
  run code_grep -F -- '--orphan-projects' "${PRUNESH}"
  assert_success
  run code_grep -F -- '--tool-tags' "${PRUNESH}"
  assert_success
}

@test "--all does not quietly acquire the scoped reclaim" {
  # --all is the daemon-wide hammer and stays exactly what it was:
  # networks + images + builder. Widening it here would make every
  # existing --all invocation start deleting on a different rule.
  run bash -c "sed -n '/--all)/,/;;/p' '${PRUNESH}' | grep -E 'DO_ORPHAN_PROJECTS|DO_TOOL_TAGS'"
  assert_failure
}

@test "the daemon-wide prune targets are untouched" {
  local _t
  for _t in DO_NETWORKS DO_IMAGES DO_VOLUMES DO_BUILDER; do
    run code_grep -F "${_t}=true" "${PRUNESH}"
    assert_success
  done
}

@test "the scoped reclaim is reachable through just, with no new namespace" {
  # ADR-00000011: docker is a namespace like the rest and prune is its
  # verb; the reclaim is a MODE of that verb, so `just docker prune
  # --reclaim` needs no new recipe, no new help table and no new
  # completion entry to be a first-class control surface.
  run grep -F './script/prune.sh {{args}}' "${JUSTDOCKER}"
  assert_success
}

# ── `just test stop`: the verb that ends what `just test` started ──────────
#
# base runs TWO compose projects out of one checkout, and only one of them
# had a stop. `just docker build` / `run` mint the `local-<dir>` project
# the shipped wrapper owns; `just test` mints `base-<sha256(path)[0:12]>`,
# a name derived from the checkout PATH so two worktrees cannot share one
# set of containers. Nothing in `just` ended the second: `just docker stop`
# resolves the FIRST name, and `just docker prune` says in its own help
# that it does not touch running containers. The only way to clear an
# interrupted run's container was raw `docker`, which is a gap in the
# control surface rather than a licence to reach past it.
#
# These run `just` for real. The recipe is a seam, and a seam is exactly
# what a grep cannot check: what matters is that the name reaching stop is
# the one the SINGLE producer printed, not a second derivation that agrees
# today.

_just_test_sandbox() {
  local _dir="${1:?_just_test_sandbox requires a dir}"
  mkdir -p "${_dir}/script/test"
  cp /source/justfile "${_dir}/justfile"
  cp /source/script/test/justfile.test "${_dir}/script/test/justfile.test"
  cat > "${_dir}/script/stop.sh" <<'STUB'
#!/usr/bin/env bash
printf 'stop project=%s image=%s args=%s\n' \
  "${PROJECT_NAME:-<unset>}" "${TEST_TOOLS_IMAGE:-<unset>}" "$*"
STUB
  chmod +x "${_dir}/script/stop.sh"
  # The one producer of the self-test project name, stubbed to print a
  # value nothing else could derive: a recipe that hashed the path itself
  # would print something else and the assertion would name it.
  cat > "${_dir}/script/test/test.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --compose-project-name) printf 'base-onlyproducer\n' ;;
  --test-tools-image) printf 'test-tools:onlyproducer\n' ;;
  *) printf 'test.sh stub: unexpected %s\n' "$*" >&2; exit 9 ;;
esac
STUB
  chmod +x "${_dir}/script/test/test.sh"
}

@test "just test stop ends this checkout's self-test project" {
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _tmp
  _tmp="$(mktemp -d)"
  _just_test_sandbox "${_tmp}"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" test stop
  local _s="${status}" _o="${output}"
  rm -rf "${_tmp}"
  status="${_s}"; output="${_o}"
  assert_success
  assert_output --partial "project=base-onlyproducer"
}

@test "just test stop asks the single producer for the name instead of deriving a second" {
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _tmp
  _tmp="$(mktemp -d)"
  _just_test_sandbox "${_tmp}"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" test stop
  local _s="${status}" _o="${output}"
  rm -rf "${_tmp}"
  status="${_s}"; output="${_o}"
  assert_success
  # `base-<12 hex>` is what the real derivation prints. Seeing it here
  # would mean the recipe hashed the sandbox path itself.
  refute_output --regexp 'project=base-[0-9a-f]{12}( |$)'
}

@test "just test stop forwards its arguments to the wrapper" {
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _tmp
  _tmp="$(mktemp -d)"
  _just_test_sandbox "${_tmp}"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" test stop -v --dry-run
  local _s="${status}" _o="${output}"
  rm -rf "${_tmp}"
  status="${_s}"; output="${_o}"
  assert_success
  assert_output --partial "args=-v --dry-run"
}

@test "just test stop hands compose every value compose.yaml demands" {
  # compose interpolates the WHOLE file for any command, `down` included,
  # and base's compose.yaml takes TEST_TOOLS_IMAGE with `:?` and no
  # default on four services. A stop that supplies only the project name
  # never reaches the teardown: compose refuses to read the file and the
  # recipe dies naming four services, which is the failure this verb
  # exists to end rather than reproduce. `--dry-run` cannot see it -- it
  # never calls compose -- so the assertion is on what the recipe hands
  # the wrapper.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _tmp
  _tmp="$(mktemp -d)"
  _just_test_sandbox "${_tmp}"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" test stop
  local _s="${status}" _o="${output}"
  rm -rf "${_tmp}"
  status="${_s}"; output="${_o}"
  assert_success
  assert_output --partial "image=test-tools:onlyproducer"
}

# ── the per-checkout build image records its provenance too ───────────────
#
# `just test smoke` is the one verb whose product is an IMAGE rather than a
# container: compose tags the harness build `<project>-smoke`, one per
# checkout. Nothing reclaimed it -- not the orphan sweep, which removes
# networks, and not the tooling-tag retention, which matches
# `test-tools:<12hex>` by name. Stamping the same label the network carries
# is what lets the same sweep collect it on the same proof.

@test "compose.yaml records the checkout path on the image it builds" {
  run grep -nE '^ +base\.checkout\.path: ' "${COMPOSE}"
  assert_success
  # Two stamps now, not one: the network compose creates and the image the
  # smoke harness builds.
  run grep -cE '^ +base\.checkout\.path: ' "${COMPOSE}"
  assert_output "2"
}

@test "the image stamp is refused rather than defaulted, like every other" {
  run bash -c "grep -A4 -E '^ {6}labels:' '${COMPOSE}' | grep -E 'base\.checkout\.path: \\\$\\{BASE_CHECKOUT_PATH:\\?'"
  assert_success
}

@test "the tooling image is NOT stamped, because it is shared on purpose" {
  # test-tools is content-hash tagged so ONE image serves every checkout
  # whose tooling inputs hash alike. A checkout-path label there would name
  # whichever invocation happened to build it, and collecting on that would
  # delete an image live checkouts still resolve.
  run bash -c "sed -n '/^  test-tools:/,/^  [a-z]/p' '${COMPOSE}' | grep -F 'base.checkout.path'"
  assert_failure
}
