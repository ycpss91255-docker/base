#!/usr/bin/env bats
#
# check_selection_spec.bats -- "a pull request runs only the heavy jobs
# its diff can affect, and a path nobody classified runs every one of
# them", base#1584.
#
# why: classify gave every heavy job one answer, code_changed, so a PR
# that touched one config-gen spec and two docs ran config-gen and all
# twelve coverage shards (112 min wall). script/ci/check_selection.sh
# maps a diff to a per-job selection. The map is subtractive: every path
# starts by selecting every job and only an exclusion row takes a job
# away, so a path the map has never heard of fails CLOSED.
#
# The CLI under test reads the PR's changed paths NUL-separated from
# stdin (`--paths`, the shape `git diff -z --name-only` prints) and
# prints one `<job>=<true|false>` line per heavy job.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SELECTION_SH=/source/script/ci/check_selection.sh
}

# _select <event> <path>...
#   Runs the map with <path>... as the whole diff of a <event> run.
_select() {
  local _event="${1:?BUG: _select expects an event}"
  shift
  printf '%s\0' "$@" | bash "${SELECTION_SH}" --event "${_event}" --paths
}

@test "check_selection: a pull request touching only a path no row names selects every heavy job (base#1584)" {
  # Expected: the issue's fail-closed rule -- "An unknown path selects
  # every job" -- for each of the five heavy jobs the issue lists.
  run _select pull_request zz-new/thing.txt
  assert_success
  assert_output "config-gen=true
mutation-roster=true
coverage=true
acceptance=true
system=true"
}

@test "check_selection: a pull request touching only docs selects no heavy job (base#1584)" {
  # Expected: the docs rule today's classify code_changed gate already
  # applies (doc/** is not code), and the issue's acceptance probe "a
  # docs-only PR" -- a docs-only diff can affect none of the five.
  run _select pull_request doc/x.md
  assert_success
  assert_output "config-gen=false
mutation-roster=false
coverage=false
acceptance=false
system=false"
}

@test "check_selection: a pull request touching only dist/script/base/init.sh drops config-gen and keeps the other four (base#1584)" {
  # Expected, from what each job reads, not from the map:
  # - config-gen=false: its host side, traced under strace -f, opened
  #   only dist/script/base/just-version.sh under dist/, and the redpath's
  #   _rp_copy (script/test/config_gen_redpath.sh) copies only
  #   dist/script/docker/lib/log.sh and log-events.txt from dist/.
  #   init.sh is in neither.
  # - acceptance=true: acceptance.sh copies the whole checkout into the
  #   consumer (`cp -a "${_ACCEPTANCE_ROOT}/." ...`), init.sh included.
  # - coverage=true: no exclusion ever drops coverage.
  # - mutation-roster=true: init.sh is not a spec, and only a spec outside
  #   every roster TSV drops the roster.
  # - system=true: script/ci/system_paths.sh lists `dist/**`.
  run _select pull_request dist/script/base/init.sh
  assert_success
  assert_output "config-gen=false
mutation-roster=true
coverage=true
acceptance=true
system=true"
}

@test "check_selection: a pull request touching only a script/ file outside script/watch drops config-gen and keeps the other four (base#1584)" {
  # Expected, from what each job reads, not from the map:
  # - config-gen=false: under script/, the redpath's _rp_copy
  #   (script/test/config_gen_redpath.sh) copies only script/watch and
  #   script/test files, and the strace -f trace of the job's host side
  #   opened no script/release/ file. changelog_index.sh is run only by
  #   justfile.release's changelog recipe and the changelog_layout driver.
  # - acceptance=true: acceptance.sh copies the whole checkout into the
  #   consumer (`cp -a "${_ACCEPTANCE_ROOT}/." ...`).
  # - coverage=true: no exclusion ever drops coverage.
  # - mutation-roster=true: changelog_index.sh is not a spec.
  # - system=true: script/ci/system_paths.sh lists `script/**`.
  run _select pull_request script/release/changelog_index.sh
  assert_success
  assert_output "config-gen=false
mutation-roster=true
coverage=true
acceptance=true
system=true"
}
