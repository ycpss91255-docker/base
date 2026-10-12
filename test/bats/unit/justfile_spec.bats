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
  run grep -F -- "--coverage-path '{{spec}}'" "${_test_justfile}"
  assert_success
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
  run grep -F -- "--bats-path '{{spec}}'" "${_test_justfile}"
  assert_success
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
  local _tmp
  _tmp="$(mktemp -d)"
  mkdir -p "${_tmp}/script/test"
  cp /source/justfile "${_tmp}/justfile"
  cp /source/script/test/justfile.test "${_tmp}/script/test/justfile.test"
  # The runner as a recorder: one argument per line, to an absolute path, so
  # what the recipe dispatched is observable whatever the recipe's cwd is.
  cat > "${_tmp}/script/test/test.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> '${_tmp}/.dispatch_log'
STUB
  chmod +x "${_tmp}/script/test/test.sh"

  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" \
    test bats-path test/bats/unit/justfile_spec.bats --filter 'nounset'
  local _s="${status}" _o="${output}" _dispatched=''
  [[ -f "${_tmp}/.dispatch_log" ]] && _dispatched="$(cat "${_tmp}/.dispatch_log")"
  status="${_s}"; output="${_o}"
  assert_success
  # The spec named on the command line reaches the runner behind the NARROWING
  # flag, not as a bare full-suite dispatch, and trailing flags ride along.
  [[ "${_dispatched}" == *"--bats-path"$'\n'"test/bats/unit/justfile_spec.bats"* ]] \
    || fail "the recipe dispatched [${_dispatched}], not --bats-path with the spec it was given"
  [[ "${_dispatched}" == *"--filter"$'\n'"nounset"* ]] \
    || fail "the recipe dropped the trailing flags: [${_dispatched}]"

  # Bare invocation: a refusal, and NOTHING dispatched. A defaulted `spec=`
  # would make this the whole suite instead.
  rm -f "${_tmp}/.dispatch_log"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" test bats-path
  _s="${status}"; _o="${output}"
  local _ran_anything=0
  [[ -f "${_tmp}/.dispatch_log" ]] && _ran_anything=1
  rm -rf "${_tmp}"
  status="${_s}"; output="${_o}"
  assert_failure
  assert_output --partial 'bats-path'
  (( _ran_anything == 0 )) \
    || fail "a bare 'just test bats-path' reached the runner, so a typo would start a suite"
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
