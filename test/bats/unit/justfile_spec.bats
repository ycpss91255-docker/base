#!/usr/bin/env bats
#
# Static checks for the layered user-facing just entry (ADR-00000010):
# the entry at dist/script/justfile (symlinked into the consumer as
# script/justfile, with <repo>/justfile -> script/justfile) imports the
# docker recipes at dist/script/docker/justfile.docker as top-level
# verbs. ADR-00000005: `just` replaces the GNU make wrapper -- recipes
# forward 1:1 to ./script/<name>.sh with full `{{args}}` passthrough (no
# MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim).
#
# These are content assertions (grep), not execution: `just` is not
# installed in the test-tools image, so the files are verified statically
# here; downstream installs `just` to run them. Execution parity lives in
# justfile_user_spec.bats.
#
# why: Static content checks for the layered just entry (ADR-00000005 /
# #545, ADR-00000010; ADR-00000011: docker + base are `mod?` namespaces, not
# a top-level import). The entry `dist/script/justfile` mods the docker +
# base modules; docker verbs forward 1:1 to `./script/<name>.sh` via
# `{{args}}`, base verbs to `./.base/upgrade.sh`. Asserted by grep, not
# execution -- `just` is not in the test-tools image; downstream installs
# it.

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

# why: forwarding bodies
@test "docker module recipes forward to ./script/<wrapper>.sh with {{args}} (#545)" {
  run grep -F './script/build.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/run.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/exec.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/setup_tui.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
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
