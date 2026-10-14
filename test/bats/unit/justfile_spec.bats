#!/usr/bin/env bats
#
# Static checks for the layered user-facing just entry (ADR-00000010):
# the entry at dist/script/justfile (symlinked into the consumer as
# script/justfile, with <repo>/justfile -> script/justfile) imports the
# docker recipes at dist/script/docker/justfile.docker as top-level
# verbs. ADR-00000005: `just` replaces the GNU make wrapper -- recipes
# forward 1:1 to ./script/<name>.sh with full passthrough, as `"$@"`
# since base#1284 / base#1289 rather than an interpolated `{{args}}`
# (no MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim).
#
# Most arms here are content assertions (grep). That used to be the whole
# file, with `just` absent from the test-tools image as the reason --
# which is also how two of those greps came to pin a DEFECTIVE body
# verbatim (base#1284's own guard, and the `base#545` body guard below).
# Since base#1173 the image carries `just`, so the arms that matter run
# the recipe against a recorder and skip where it is missing. Execution
# parity across namespaces lives in justfile_user_spec.bats.
#
# why: Static content checks for the layered just entry (ADR-00000005 /
# #545, ADR-00000010; ADR-00000011: docker + base are `mod?` namespaces, not
# a top-level import). The entry `dist/script/justfile` mods the docker +
# base modules; docker verbs forward 1:1 to `./script/<name>.sh` via
# `"$@"` (base#1289), base verbs to `./.base/upgrade.sh`. Asserted by
# grep where the claim is about the file's shape, and by running the
# recipe where it is about what reaches a wrapper.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # Verb recipes live in the docker module; the `default` recipe + the
  # import live in the entry.
  DOCKER_JUSTFILE=/source/dist/script/docker/justfile.docker
  ENTRY=/source/dist/script/justfile
}

teardown() {
  # Guarded with an if-block, not `[ ] && rm`: most tests here never set it,
  # and the `&&` chain's non-zero status would turn a passing test into a
  # teardown failure.
  if [[ -n "${JUST_TEST_SANDBOX:-}" ]]; then
    rm -rf "${JUST_TEST_SANDBOX}"
  fi
  if [[ -n "${JUST_DOCKER_SANDBOX:-}" ]]; then
    rm -rf "${JUST_DOCKER_SANDBOX}"
  fi
  if [[ -n "${JUST_RELEASE_SANDBOX:-}" ]]; then
    rm -rf "${JUST_RELEASE_SANDBOX}"
  fi
  if [[ -n "${JUST_TEMPLATE_SANDBOX:-}" ]]; then
    rm -rf "${JUST_TEMPLATE_SANDBOX}"
  fi
}

# why: both files present
@test "layered entry + docker module exist" {
  [ -f "${ENTRY}" ]
  [ -f "${DOCKER_JUSTFILE}" ]
}

# why: build/run/exec/stop/prune/setup/setup-tui `*args`
@test "docker module declares args-passthrough recipes for every wrapper verb (#545)" {
  local _v
  for _v in build run exec stop prune setup; do
    run grep -E "^${_v} \*args:" "${DOCKER_JUSTFILE}"
    assert_success
  done
  run grep -E '^setup-tui \*args:' "${DOCKER_JUSTFILE}"
  assert_success
}

# why: #652 -- upgrade is a .base op
@test "docker module no longer carries upgrade/upgrade-check (moved to base ns, #652)" {
  # upgrade is a .base-management op, not a docker op -- it lives in the
  # `base` namespace (just base upgrade / just base update), ADR-00000011.
  run grep -E '^upgrade |^upgrade-check:' "${DOCKER_JUSTFILE}"
  assert_failure
}

# why: forwarding bodies -- as "$@" since base#1289, not {{args}}
@test "docker module recipes forward to ./script/<wrapper>.sh (#545, base#1289)" {
  # This arm used to assert the literal `{{args}}` body. That body was the
  # defect: an unquoted interpolation hands the recipe's own shell a string
  # to re-split, so a flag carrying a space reached the wrapper as several
  # arguments and one carrying a `|` became a pipeline (base#1289). The
  # guarantee base#545 wanted -- each verb forwards 1:1 to its wrapper -- is
  # unchanged; only the spelling that delivers it is.
  #
  # base#1284 found its own static guard asserting ITS defective body the
  # same way, which is why this one is rewritten rather than trusted.
  local _v
  for _v in build run exec stop prune setup setup_tui; do
    run grep -F "./script/${_v}.sh \"\$@\"" "${DOCKER_JUSTFILE}"
    assert_success
    # And not the old shape anywhere, for any verb.
    run grep -F "./script/${_v}.sh {{args}}" "${DOCKER_JUSTFILE}"
    assert_failure
  done
}

@test "base module declares upgrade + update (apt-aligned) forwarding to .base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)" {
  local _base=/source/dist/script/base/justfile.base
  [ -f "${_base}" ]
  run grep -E '^upgrade \*args:' "${_base}"
  assert_success
  # `update` takes *args purely as a --help shim: it still runs the check, so
  # the signature is `update *args:` not the old argless `update:`.
  run grep -E '^update \*args:' "${_base}"
  assert_success
  run grep -F './.base/dist/script/base/upgrade.sh {{args}}' "${_base}"
  assert_success
  run grep -F './.base/dist/script/base/upgrade.sh --check' "${_base}"
  assert_success
}

@test "base update recipe forwards -h|--help to upgrade.sh usage without the check (#789)" {
  # The --help shim: `just base update --help` must reach upgrade.sh --help
  # (usage) rather than running the network check or erroring on a dashed name.
  local _base=/source/dist/script/base/justfile.base
  run grep -F 'exec ./.base/dist/script/base/upgrade.sh --help' "${_base}"
  assert_success
  run grep -E '\-h\|--help' "${_base}"
  assert_success
}

@test "every shipped namespace module ships a help recipe + h alias (#789)" {
  # Namespace-level help within just's module limits: `just <ns> help` /
  # `just <ns> h` list the namespace (dashed `just <ns> --help` cannot be a
  # recipe; with `help` present just hints "Did you mean 'help'?").
  local _m
  for _m in /source/dist/script/docker/justfile.docker \
            /source/dist/script/base/justfile.base \
            /source/dist/script/template/justfile.template; do
    run grep -E '^help( |:)' "${_m}"
    assert_success
    run grep -F 'alias h := help' "${_m}"
    assert_success
  done
}

# why: #653 -- init -> .base/init.sh, completions ->
# script/base/completions.sh
@test "base module declares init + completions recipes (#653, ADR-00000011)" {
  local _base=/source/dist/script/base/justfile.base
  run grep -E '^init ' "${_base}"
  assert_success
  run grep -E '^completions ' "${_base}"
  assert_success
  run grep -F './.base/dist/script/base/init.sh {{args}}' "${_base}"
  assert_success
  run grep -F 'script/base/completions.sh {{args}}' "${_base}"
  assert_success
}

# why: #652 -- `mod? base`
@test "entry mods the base namespace (#652, ADR-00000011)" {
  run grep -F "mod? base 'script/base/justfile.base'" "${ENTRY}"
  assert_success
}

# why: #652 -- mod default + `set working-directory := '../..'`
@test "docker module owns a default recipe + pins cwd to repo root (#652, ADR-00000011)" {
  # As a mod? module (not a top-level import) it owns its own default
  # (`just docker` lists the verbs); module recipes default cwd to the
  # module dir, so `set working-directory := '../..'` pins them to the
  # repo root for the ./script/<wrapper>.sh calls.
  run grep -E '^default:' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F "set working-directory := '../..'" "${DOCKER_JUSTFILE}"
  assert_success
}

# why: #652 -- `mod? docker` + `default: @just --list`
@test "entry mods the docker namespace + default recipe lists recipes (#652, ADR-00000011)" {
  # docker is a namespace (zero special case): `just docker build`, not a
  # top-level `just build`. bare `just` still lists via the entry default.
  run grep -F "mod? docker 'script/docker/justfile.docker'" "${ENTRY}"
  assert_success
  run grep -E '^default:' "${ENTRY}"
  assert_success
  run grep -F 'just --list' "${ENTRY}"
  assert_success
}

# why: #655 -- bare `just test` / `just release`
@test "test / release namespaces own a default recipe (bare-namespace help, #655)" {
  # Every namespace must respond to a bare invocation (`just test` /
  # `just release`) with its English-baseline help -- the `default` recipe.
  run grep -E '^default:' /source/script/test/justfile.test
  assert_success
  run grep -E '^default:' /source/script/release/justfile.release
  assert_success
}

# why: Required spec argument (a defaulted one would kcov the whole suite on
# a typo)
@test "test namespace: coverage-path demands its spec, coverage keeps its optional shard (#887)" {
  # `just test coverage-path <spec>` is the one-spec-under-kcov entry. Its
  # argument is REQUIRED: an optional one (`spec=''`, the shape the sibling
  # `coverage` recipe uses for its shard) would turn a mistyped bare
  # invocation into a silent 8-12 minute full-suite kcov run instead of an
  # error naming the missing argument.
  local _test_justfile=/source/script/test/justfile.test
  run grep -E "^coverage-path spec \*args:$" "${_test_justfile}"
  assert_success
  run grep -E "^coverage-path spec=" "${_test_justfile}"
  assert_failure
  # The spec AND the trailing flags forward through quoted "$@". This arm
  # asserted `--coverage-path '{{spec}}'` until base#1284 -- i.e. it PINNED
  # the defect: `just` expands {{args}} as text, so the recipe's own shell
  # re-read it and a `--filter` carrying a space became two arguments while
  # one carrying a `|` became a pipeline (status 127). The refutation below
  # is the half that matters: no `{{` may return to the forwarding line, so
  # the next transliteration of this recipe cannot reintroduce it. The
  # executed proof is `just test coverage-path forwards a --filter ...`
  # below.
  run grep -F -- './script/test/test.sh --coverage-path "$@"' "${_test_justfile}"
  assert_success
  run grep -nE '^[[:space:]]+\./script/test/test\.sh --coverage-path .*\{\{' "${_test_justfile}"
  assert_failure
  # The shard argument of `coverage` stays optional (bare = full suite).
  run grep -E "^coverage shard='':$" "${_test_justfile}"
  assert_success
}

# why: Required spec argument (a defaulted one would run the whole suite on a
# typo, base#1173)
@test "test namespace: bats-path demands its spec and forwards it (base#1173)" {
  # `just test bats-path <spec>` is the uninstrumented one-spec entry -- the
  # TDD inner loop. Its argument is REQUIRED for the same reason
  # `coverage-path`'s is: an optional one (`spec=''`, the shape the sibling
  # `coverage` recipe uses for its shard) would turn a mistyped bare
  # invocation into a silent full-suite run instead of an error naming the
  # missing argument. This is the static half; the executed half is below.
  local _test_justfile=/source/script/test/justfile.test
  run grep -E "^bats-path spec \*args:$" "${_test_justfile}"
  assert_success
  run grep -E "^bats-path spec=" "${_test_justfile}"
  assert_failure
  # The body forwards through quoted "$@", which keeps a `--filter` regex one
  # argument. An interpolated {{args}} hands the recipe's own shell the
  # expression to re-split, which is what `set positional-arguments` is set
  # at the top of that file to avoid; the executed proof is the test below.
  run grep -F -- './script/test/test.sh --bats-path "$@"' "${_test_justfile}"
  assert_success
  run grep -nE '^[[:space:]]+\./script/test/test\.sh --bats-path .*\{\{' "${_test_justfile}"
  assert_failure
}

# _just_test_sandbox <dir> -- base's own root entry plus the `test` namespace,
# with the runner replaced by a recorder that writes one argument per line to
# <dir>/.dispatch_log and starts no container. base#1173; shared with
# base#1284's coverage-path arm, which needs the identical tree.
_just_test_sandbox() {
  local _dir="${1}"
  mkdir -p "${_dir}/script/test"
  cp /source/justfile "${_dir}/justfile"
  cp /source/script/test/justfile.test "${_dir}/script/test/justfile.test"
  cat > "${_dir}/script/test/test.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> '${_dir}/.dispatch_log'
STUB
  chmod +x "${_dir}/script/test/test.sh"
}

# _just_test_dispatch <dir> <recipe> <arg>... -- run
# `just test <recipe> <arg>...` in the sandbox. Leaves the recorded dispatch
# in _dispatched (one argument per line, empty when the runner was never
# reached), just's exit status in _dispatch_status and its own output in
# _dispatch_output. base#1173; the recipe is a parameter since base#1284.
_just_test_dispatch() {
  local _dir="${1}" _recipe="${2}"; shift 2
  rm -f "${_dir}/.dispatch_log"
  local _out='' _st=0
  _out="$(just --justfile "${_dir}/justfile" --working-directory "${_dir}" \
    test "${_recipe}" "$@" 2>&1)" || _st="$?"
  _dispatch_output="${_out}"
  _dispatch_status="${_st}"
  _dispatched=''
  if [[ -f "${_dir}/.dispatch_log" ]]; then
    _dispatched="$(cat "${_dir}/.dispatch_log")"
  fi
}

# why: a grep proves the recipe LINE exists, not that it runs one spec
# (base#1173)
@test "just test bats-path dispatches ONE spec and refuses a bare invocation (base#1173)" {
  # The grep-only gate is the failure family this repo names most often:
  # base#1115 / base#1117 / base#1175 were three greps claiming to pin
  # `xhost` behaviour that passed against a run.sh carrying no `xhost` at
  # all. So the forwarding and the bare-invocation refusal are EXECUTED
  # here, against a stubbed runner that records what it was handed and
  # starts no container.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE); the static half above still runs"
  local _dispatched='' _dispatch_status=0 _dispatch_output=''
  JUST_TEST_SANDBOX="$(mktemp -d)"
  _just_test_sandbox "${JUST_TEST_SANDBOX}"

  # The spec named on the command line reaches the runner behind the
  # NARROWING flag, and is the WHOLE dispatch -- not a full-suite run with
  # the path somewhere in it.
  _just_test_dispatch "${JUST_TEST_SANDBOX}" bats-path \
    test/bats/unit/justfile_spec.bats
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "the recipe failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == "--bats-path"$'\n'"test/bats/unit/justfile_spec.bats" ]] \
    || fail "dispatched [${_dispatched}], not --bats-path with the spec it was given"

  # A filter carrying a SPACE, and one carrying a regex alternation. Each is
  # ONE `bats -f` argument and has to arrive as one: an unquoted {{args}}
  # interpolation hands the recipe's own shell the expression to re-split,
  # so the first becomes two arguments the runner rejects by name and the
  # second becomes a shell pipeline (`bar: not found`, status 127). That is
  # the defect `set positional-arguments` exists to avoid in this file.
  _just_test_dispatch "${JUST_TEST_SANDBOX}" bats-path \
    test/bats/unit/schema_spec.bats --filter 'gpu_count under nounset'
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "a filter with spaces failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == "--bats-path"$'\n'"test/bats/unit/schema_spec.bats"$'\n'"--filter"$'\n'"gpu_count under nounset" ]] \
    || fail "the filter did not arrive as one argument: [${_dispatched}]"

  _just_test_dispatch "${JUST_TEST_SANDBOX}" bats-path \
    test/bats/unit/schema_spec.bats --filter 'gpu_count|nounset'
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "a filter with an alternation failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == *$'\n'"--filter"$'\n'"gpu_count|nounset" ]] \
    || fail "the alternation was read by the recipe shell: [${_dispatched}]"

  # Bare invocation: a refusal naming the missing argument, and NOTHING
  # dispatched. A defaulted `spec=` would make this the whole suite instead.
  _just_test_dispatch "${JUST_TEST_SANDBOX}" bats-path
  [[ "${_dispatch_status}" -ne 0 ]] \
    || fail "a bare 'just test bats-path' succeeded: [${_dispatch_output}]"
  [[ "${_dispatch_output}" == *'bats-path'* && "${_dispatch_output}" == *'spec'* ]] \
    || fail "the refusal names neither the recipe nor its missing argument: [${_dispatch_output}]"
  [[ -z "${_dispatched}" ]] \
    || fail "a bare 'just test bats-path' reached the runner with [${_dispatched}], so a typo would start a suite"
}

# why: a grep proves the recipe LINE exists, not that a flag survives the
# recipe's own shell (base#1284)
@test "just test coverage-path forwards a --filter as ONE argument (base#1284)" {
  # Until base#1284 the body was `--coverage-path '{{spec}}' {{args}}`, and
  # the static arm above asserted exactly that -- a guard that pinned the
  # defect instead of observing the property it names, which is this repo's
  # most frequent failure family (base#1115 / base#1117 / base#1175). So
  # the forwarding is EXECUTED here, against a stubbed runner that records
  # one argument per line and starts no container.
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE); the static half above still runs"
  local _dispatched='' _dispatch_status=0 _dispatch_output=''
  JUST_TEST_SANDBOX="$(mktemp -d)"
  _just_test_sandbox "${JUST_TEST_SANDBOX}"

  # A filter carrying a regex ALTERNATION. `just` expands {{args}} as TEXT,
  # so the recipe's own shell read the `|` as a pipeline: the runner got
  # `--filter foo` and `bar` was run as a command, `bar: not found`, exit
  # 127. That is why what is asserted is an EQUALITY on the recorded
  # argument list plus the message, and never a bare non-zero -- a 127 has
  # satisfied an exit-status check in this repo before.
  _just_test_dispatch "${JUST_TEST_SANDBOX}" coverage-path \
    test/bats/unit/lib_spec.bats --filter 'nounset|coverage'
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "a filter with an alternation failed (${_dispatch_status}): [${_dispatch_output}]"
  [[ "${_dispatch_output}" != *'not found'* ]] \
    || fail "the recipe shell ran part of the filter as a command: [${_dispatch_output}]"
  [[ "${_dispatched}" == "--coverage-path"$'\n'"test/bats/unit/lib_spec.bats"$'\n'"--filter"$'\n'"nounset|coverage" ]] \
    || fail "dispatched [${_dispatched}], not the spec with the alternation as one argument"

  # A filter carrying a SPACE: ONE `bats -f` argument, which the
  # interpolation split into two the runner then reads as a stray path.
  _just_test_dispatch "${JUST_TEST_SANDBOX}" coverage-path \
    test/bats/unit/lib_spec.bats --filter 'bare invocation'
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "a filter with spaces failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == "--coverage-path"$'\n'"test/bats/unit/lib_spec.bats"$'\n'"--filter"$'\n'"bare invocation" ]] \
    || fail "the filter did not arrive as one argument: [${_dispatched}]"
}

# why: #655 -- ADR-00000011 i18n scope (machine/CI namespaces)
@test "test / release namespaces are English-only -- no --lang plumbing (#655)" {
  # ADR-00000011 i18n scope: test / release are machine/CI namespaces, so
  # they ship no --lang flag (only docker / base / template are localised).
  run grep -F -- '--lang' /source/script/test/justfile.test
  assert_failure
  run grep -F -- '--lang' /source/script/release/justfile.release
  assert_failure
}

# `just --list` uses the comment IMMEDIATELY above a `mod?` (no blank gap) as
# the module's description, and only the LAST line of a contiguous block. A
# blank gap yields NO description; a multi-line block yields a mid-sentence
# fragment. Enforce one clean one-liner per mod?: line above is a `#` comment,
# line two-above is NOT (single, adjacent).
_assert_mod_doc_comments() {
  awk '
    BEGIN { bad=0 }
    /^mod\? / {
      if (prev !~ /^#/)      { print "no adjacent doc comment: " $0; bad=1 }
      else if (prev2 ~ /^#/) { print "multi-line comment block (fragment risk): " $0; bad=1 }
    }
    { prev2=prev; prev=$0 }
    END { exit bad }
  ' "$1"
}

# why: #720 -- guards `just --list` descriptions (no blank-gap empty, no
# multi-line fragment)
@test "consumer entry: every top-level mod? has one adjacent one-line doc comment (#720)" {
  run _assert_mod_doc_comments "${ENTRY}"
  assert_success
}

# why: #720 -- same invariant for base's self-dev entry
@test "base root justfile: every top-level mod? has one adjacent one-line doc comment (#720)" {
  run _assert_mod_doc_comments /source/justfile
  assert_success
}

# _just_docker_sandbox <dir> -- base's own root entry plus the `docker`
# namespace, with every wrapper replaced by a recorder that writes one
# argument per line to <dir>/.dispatch_log and starts no container. The
# twin of _just_test_sandbox above (base#1173/base#1284), for the module
# base SHIPS rather than the one it tests itself with (base#1289).
#
# The layout is load-bearing. justfile.docker carries
# `set working-directory := '../..'`, so the recipes run two levels up
# from the module file and reach their wrappers as `./script/<verb>.sh`.
# A flat sandbox runs them somewhere else and every invocation dies with
# `./script/exec.sh: not found` -- an error that has nothing to do with
# what these arms assert.
_just_docker_sandbox() {
  local _dir="${1}"
  mkdir -p "${_dir}/script/docker"
  cp /source/justfile "${_dir}/justfile"
  cp /source/dist/script/docker/justfile.docker "${_dir}/script/docker/justfile.docker"
  local _verb
  for _verb in build run exec stop prune setup setup_tui; do
    cat > "${_dir}/script/${_verb}.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> '${_dir}/.dispatch_log'
STUB
    chmod +x "${_dir}/script/${_verb}.sh"
  done
}

# _just_docker_dispatch <dir> <recipe> <arg>... -- as _just_test_dispatch,
# for the `docker` namespace.
_just_docker_dispatch() {
  local _dir="${1}" _recipe="${2}"; shift 2
  rm -f "${_dir}/.dispatch_log"
  local _out='' _st=0
  _out="$(just --justfile "${_dir}/justfile" --working-directory "${_dir}" \
    docker "${_recipe}" "$@" 2>&1)" || _st="$?"
  _dispatch_output="${_out}"
  _dispatch_status="${_st}"
  _dispatched=''
  if [[ -f "${_dir}/.dispatch_log" ]]; then
    _dispatched="$(cat "${_dir}/.dispatch_log")"
  fi
}

# why: the consumer's own interface re-read every flag it forwarded
# (base#1289)
@test "just docker: a forwarded flag arrives as ONE argument, space or pipe (base#1289)" {
  # EXECUTED, not grepped. base#1284 found its own static guard was
  # asserting the defective body verbatim, so a grep here would prove the
  # recipe line exists and nothing about what reaches the wrapper.
  #
  # Measured on this file before the change: `--filter 'bare invocation'`
  # arrived as THREE arguments and the command exited 0 -- silently wrong
  # -- and `--filter 'foo|bar'` became a shell pipeline that died with
  # `bar: not found` at status 127.
  command -v just > /dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _dispatched='' _dispatch_status=0 _dispatch_output=''
  JUST_DOCKER_SANDBOX="$(mktemp -d)"
  _just_docker_sandbox "${JUST_DOCKER_SANDBOX}"

  local _verb
  for _verb in exec stop prune setup; do
    _just_docker_dispatch "${JUST_DOCKER_SANDBOX}" "${_verb}" \
      --filter 'bare invocation'
    [[ "${_dispatch_status}" -eq 0 ]] \
      || fail "${_verb}: a flag with a space failed: [${_dispatch_output}]"
    # Equality, never --partial: three arguments CONTAIN two.
    [[ "${_dispatched}" == "--filter"$'\n'"bare invocation" ]] \
      || fail "${_verb}: dispatched [${_dispatched}], not one --filter argument"

    _just_docker_dispatch "${JUST_DOCKER_SANDBOX}" "${_verb}" \
      --filter 'foo|bar'
    [[ "${_dispatch_status}" -eq 0 ]] \
      || fail "${_verb}: an alternation failed: [${_dispatch_output}]"
    [[ "${_dispatched}" == "--filter"$'\n'"foo|bar" ]] \
      || fail "${_verb}: the alternation was read by the recipe shell: [${_dispatched}]"
    # The 127 shape specifically: a bare non-zero check would have passed
    # for it, and that is how this class has survived before.
    [[ "${_dispatch_output}" != *'not found'* ]] \
      || fail "${_verb}: the recipe shell ran part of the argument: [${_dispatch_output}]"
  done
}

# why: converting the -h scan by accident is the regression this invites
# (base#1289)
@test "just docker start --help still prints usage and starts nothing (base#1289)" {
  # `start` scans its arguments as TEXT (`case " {{args}} " in`) and must
  # keep doing so. `set positional-arguments` is additive -- interpolation
  # still works beside "$@" -- so the scan is correct under it, and this
  # arm is what says so rather than the setting's documentation.
  command -v just > /dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _dispatched='' _dispatch_status=0 _dispatch_output=''
  JUST_DOCKER_SANDBOX="$(mktemp -d)"
  _just_docker_sandbox "${JUST_DOCKER_SANDBOX}"

  _just_docker_dispatch "${JUST_DOCKER_SANDBOX}" start --help
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "start --help failed: [${_dispatch_output}]"
  [[ "${_dispatch_output}" == *'Usage: just docker start'* ]] \
    || fail "start --help printed no usage: [${_dispatch_output}]"
  [[ -z "${_dispatched}" ]] \
    || fail "start --help reached a wrapper with [${_dispatched}], so --help built an image"
}

# why: a transliteration that reintroduces {{ on a forwarding line is the
# way this comes back (base#1289)
@test "no forwarding line in justfile.docker interpolates {{ (base#1289)" {
  # The static half, kept BESIDE the executed arms rather than instead of
  # them. It cannot prove what reaches a wrapper -- base#1284's guard
  # proved that by passing against the defective body -- but it does catch
  # the one thing the executed arms cannot: a NEW recipe added later with
  # the old shape.
  #
  # The one deliberate text use in THIS file -- `start`'s `-h` scan -- is
  # exempted by name, not by pattern: an exemption matching "any line
  # with a case statement" would quietly cover a future mistake.
  # (justfile.base has a second such scan; it is not this file and not
  # this slice.)
  #
  # `[[:space:]]*` inside the braces because `{{ args }}` is valid just
  # and interpolates identically -- a regex pinned to the tight spelling
  # is one space away from passing the thing it exists to catch.
  local _jf=/source/dist/script/docker/justfile.docker
  run grep -nE '^[[:space:]]+[^#]*\{\{[[:space:]]*args[[:space:]]*\}\}' "${_jf}"
  assert_success
  # Exactly one line, and it is the scan.
  assert_equal "$(printf '%s\n' "${output}" | wc -l)" "1"
  assert_output --partial 'case " {{args}} " in'

  # And the setting that makes "$@" mean anything is there.
  run grep -c '^set positional-arguments := true$' "${_jf}"
  assert_output "1"
}

# _just_release_sandbox <dir> -- the `release` namespace with both of its
# backing scripts replaced by recorders. The fourth of these, after
# base#1173's `test`, base#1289's `docker` and base#1299's `template`;
# the count line is recorded first for the same reason as there.
_just_release_sandbox() {
  local _dir="${1}"
  mkdir -p "${_dir}/script/release"
  cp /source/justfile "${_dir}/justfile"
  cp /source/script/release/justfile.release "${_dir}/script/release/justfile.release"
  local _s
  for _s in coverage_badge changelog_index; do
    cat > "${_dir}/script/release/${_s}.sh" <<STUB
#!/usr/bin/env bash
printf 'n=%s\n' "\$#" >> '${_dir}/.dispatch_log'
printf 'ARG[%s]\n' "\$@" >> '${_dir}/.dispatch_log'
STUB
    chmod +x "${_dir}/script/release/${_s}.sh"
  done
}

# _just_release_dispatch <dir> <recipe> <arg>... -- as the siblings above.
_just_release_dispatch() {
  local _dir="${1}" _recipe="${2}"; shift 2
  rm -f "${_dir}/.dispatch_log"
  local _out='' _st=0
  _out="$(just --justfile "${_dir}/justfile" --working-directory "${_dir}" \
    release "${_recipe}" "$@" 2>&1)" || _st="$?"
  _dispatch_output="${_out}"
  _dispatch_status="${_st}"
  _dispatched=''
  if [[ -f "${_dir}/.dispatch_log" ]]; then
    _dispatched="$(cat "${_dir}/.dispatch_log")"
  fi
}

# why: the release namespace re-read the flags it forwarded, same shape
# as base#1284 and base#1289's docker slice
@test "just release forwards a flag as ONE argument (base#1289)" {
  # Measured on this file before the change: `coverage-badge --note 'two
  # words'` reached the script as THREE arguments and exited 0, and
  # `changelog-index 'foo|bar'` became a shell pipeline that died with
  # `bar: not found` at 127.
  #
  # Equality, never --partial: three arguments contain two.
  command -v just > /dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _dispatched='' _dispatch_status=0 _dispatch_output=''
  JUST_RELEASE_SANDBOX="$(mktemp -d)"
  _just_release_sandbox "${JUST_RELEASE_SANDBOX}"

  _just_release_dispatch "${JUST_RELEASE_SANDBOX}" coverage-badge \
    --note 'two words'
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "coverage-badge with a spaced flag failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == "n=2"$'\n'"ARG[--note]"$'\n'"ARG[two words]" ]] \
    || fail "coverage-badge dispatched [${_dispatched}]"

  # changelog-index prepends --write, so this also pins that the recipe's
  # OWN argument still arrives first and is not re-ordered by the change.
  _just_release_dispatch "${JUST_RELEASE_SANDBOX}" changelog-index 'foo|bar'
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "changelog-index with an alternation failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == "n=2"$'\n'"ARG[--write]"$'\n'"ARG[foo|bar]" ]] \
    || fail "changelog-index dispatched [${_dispatched}]"
  [[ "${_dispatch_output}" != *'not found'* ]] \
    || fail "the recipe shell ran part of the argument: [${_dispatch_output}]"

  # A bare invocation still reaches the script with nothing, which is
  # what both recipes are for: `just release changelog-index` is the
  # whole re-render.
  _just_release_dispatch "${JUST_RELEASE_SANDBOX}" coverage-badge
  [[ "${_dispatched}" == "n=0"$'\n'"ARG[]" ]] \
    || fail "a bare coverage-badge dispatched [${_dispatched}]"
}

# why: a transliteration that reintroduces {{ is how this comes back
@test "no forwarding line in justfile.release interpolates {{ (base#1289)" {
  # Comment lines are stripped first: the header above the setting names
  # `{{args}}` while explaining why it is gone, and a grep over the whole
  # file would match its own documentation.
  local _body="${BATS_TEST_TMPDIR}/justfile.release.body"
  grep -vE '^[[:space:]]*#' /source/script/release/justfile.release > "${_body}"

  run grep -nE '\{\{[[:space:]]*args[[:space:]]*\}\}' "${_body}"
  assert_failure

  run grep -c '^set positional-arguments := true$' "${_body}"
  assert_output "1"
}

# _just_template_sandbox <dir> -- the `template` namespace with its
# scaffolder replaced by a recorder. The third of these (base#1173's
# `test`, base#1289's `docker`); this one needs no nesting, because
# justfile.template sets no working-directory and the recipe `cd`s to
# `{{justfile_directory()}}` itself.
_just_template_sandbox() {
  local _dir="${1}"
  mkdir -p "${_dir}/script/template"
  cp /source/dist/script/template/justfile.template "${_dir}/justfile"
  # The count is recorded FIRST and separately, because the argument
  # lines alone cannot tell ONE EMPTY argument from NONE: bash's
  # `printf 'ARG[%s]\n'` writes `ARG[]` for both. The bare interpolation
  # produces the second, so that is a distinction this file has to make.
  cat > "${_dir}/script/template/new.sh" <<STUB
#!/usr/bin/env bash
printf 'n=%s\n' "\$#" >> '${_dir}/.dispatch_log'
printf 'ARG[%s]\n' "\$@" >> '${_dir}/.dispatch_log'
STUB
  chmod +x "${_dir}/script/template/new.sh"
}

# _just_template_dispatch <dir> <arg>... -- run `just template new <arg>...`
# in the sandbox, leaving the recorded dispatch in _dispatched.
_just_template_dispatch() {
  local _dir="${1}"; shift
  rm -f "${_dir}/.dispatch_log"
  local _out='' _st=0
  _out="$(just --justfile "${_dir}/justfile" --working-directory "${_dir}" \
    new "$@" 2>&1)" || _st="$?"
  _dispatch_output="${_out}"
  _dispatch_status="${_st}"
  _dispatched=''
  if [[ -f "${_dir}/.dispatch_log" ]]; then
    _dispatched="$(cat "${_dir}/.dispatch_log")"
  fi
}

# why: an unquoted single interpolation re-split the group name, and
# new.sh's own validator could not see it (base#1299)
@test "just template new hands the scaffolder ONE argument (base#1299)" {
  # The validator in new.sh (`^[a-z][a-z0-9_-]*$`) does not catch this and
  # makes it worse: `two words` re-split reaches it as two arguments, the
  # LAST of which is a legal name, so it created a group called `words`,
  # registered it in script/local/justfile.local and exited 0 saying so.
  # The user asked for neither.
  #
  # Equality, not --partial: two arguments contain one.
  command -v just > /dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _dispatched='' _dispatch_status=0 _dispatch_output=''
  JUST_TEMPLATE_SANDBOX="$(mktemp -d)"
  _just_template_sandbox "${JUST_TEMPLATE_SANDBOX}"

  # Every shape a hand-written quote gets wrong, plus the ordinary one.
  # Review built this list, and each entry is here because some other
  # form of the fix gets it wrong. A hand-written `'{{name}}'` turns
  # `two'words` into a shell syntax error, silently reduces `a''b` to
  # `ab`, and lets `' --help #` close the quote the recipe wrote and hand
  # new.sh a FLAG -- which that script answers by printing its help and
  # exiting 0. The last two entries are for wrong fixes the others do
  # not catch: `{{quote(trim(name))}}` passes every other one and drops a
  # trailing NEWLINE, and an `exec` wrapper that strips a trailing SPACE
  # passes every one including that. Only `{{quote(name)}}` is right for
  # all of them.
  _assert_one_arg() {
    local _name="${1}"
    _just_template_dispatch "${JUST_TEMPLATE_SANDBOX}" "${_name}"
    [[ "${_dispatch_status}" -eq 0 ]] \
      || fail "[${_name}] failed: [${_dispatch_output}]"
    [[ "${_dispatched}" == "n=1"$'\n'"ARG[${_name}]" ]] \
      || fail "[${_name}] dispatched [${_dispatched}], not one argument"
    # The recipe shell must have run none of it. Refuted by name because
    # the bad shapes exit 127 and a bare non-zero check has been satisfied
    # by a 127 in this repo before.
    [[ "${_dispatch_output}" != *'not found'* ]] \
      || fail "[${_name}]: the recipe shell ran part of the name: [${_dispatch_output}]"
    [[ "${_dispatch_output}" != *'Syntax error'* ]] \
      || fail "[${_name}]: the recipe shell could not parse the body: [${_dispatch_output}]"
  }

  _assert_one_arg 'two words'
  _assert_one_arg 'foo|bar'
  _assert_one_arg "two'words"
  _assert_one_arg "a''b"
  _assert_one_arg "' --help #"
  _assert_one_arg '$USER'
  _assert_one_arg 'deploy-aws'
  _assert_one_arg 'back\\slash'
  _assert_one_arg 'trailing-space '
  _assert_one_arg 'trailing-newline
'

  # An EMPTY name is still exactly one argument, and the count line is
  # what proves it. Not because of any newline stripping -- `printf
  # 'ARG[%s]\n'` emits `ARG[]` for an empty argument AND for no arguments
  # at all, so those two are the pair the argument lines cannot tell
  # apart. The bare interpolation produces the second (`n=0`), which is
  # one of the shapes this arm exists to reject.
  _just_template_dispatch "${JUST_TEMPLATE_SANDBOX}" ''
  [[ "${_dispatch_status}" -eq 0 ]] \
    || fail "an empty name failed: [${_dispatch_output}]"
  [[ "${_dispatched}" == "n=1"$'\n'"ARG[]" ]] \
    || fail "an empty name dispatched [${_dispatched}], not one empty argument"
}

# why: the quote is one character and a later edit can drop it (base#1299)
@test "justfile.template forwards the name through quote() (base#1299)" {
  # The static half. It cannot prove what reaches the scaffolder -- the
  # arm above does that -- but it catches the edit that replaces
  # `quote()` with a hand-written quote, which is the way this comes
  # back, and the one a reviewer is most likely to make.
  #
  # Comment lines are stripped FIRST, into a file the greps read. An
  # earlier version matched the whole file and passed against a body
  # using double quotes while the correct form survived in a comment
  # three lines above -- a guard its own documentation satisfies, which
  # is the failure family base#1115 / base#1117 / base#1175 name.
  local _body="${BATS_TEST_TMPDIR}/justfile.template.body"
  grep -vE '^[[:space:]]*#' /source/dist/script/template/justfile.template \
    > "${_body}"

  # The WHOLE command is anchored, start of line to end. Review reached
  # past a tail-only match twice: `... {{quote(name)}}x` is a different
  # program, and an `exec` wrapper around the same tail ends in exactly
  # the right characters while stripping a trailing space from the name.
  # Matching the line and nothing else is the only form that rules both
  # out.
  run grep -nxE '[[:space:]]*@cd \{\{justfile_directory\(\)\}\} && script/template/new[.]sh \{\{quote\(name\)\}\}' "${_body}"
  assert_success

  # The positive grep is already exclusive: a live line carrying
  # `"{{name}}"` or `'{{name}}'` does not carry `{{quote(name)}}`, so it
  # fails above. What that cannot distinguish is the bare interpolation
  # appearing on a SECOND live line, so it is refuted on its own below.
  run grep -nF 'script/template/new.sh {{name}}' "${_body}"
  assert_failure
}
