#!/usr/bin/env bats
#
# testtools_image_spec.bats -- the ONE source of the tooling image a worker
# build consumes, and the derived proof that no workflow names that image
# any other way.
#
# ── The question, and why it had two answers ─────────────────────────────
#
# `ghcr.io/ycpss91255-docker/test-tools:<tag>` is the build-arg a
# downstream Dockerfile's test stage is declared `FROM`, so it decides
# which shellcheck, which hadolint and which bats that repo's CI lints and
# tests with. Two things named it, and they were never the same string:
#
#   .version                      the base release a caller pinned
#                                 `uses: ...@vX.Y.Z` to, and the tag
#                                 release-test-tools.yaml publishes the
#                                 tooling image under
#   a test_tools_version input     defaulting to `latest`, the ROLLING tag
#                                 naming whatever release published last
#
# So the `@ref` pin covered the worker's code and not the tooling image it
# built with: one downstream commit linted against different binaries on
# different days, and during an RC window against whatever the last
# finished release had left on `:latest`. Exactly one caller in the org
# ever set the input, which is the shape of a knob whose purpose is to let
# the default be wrong quietly.
#
# What the suite had instead of a comparison was a case asserting the
# default equalled the literal `"latest"` -- so the two sources were
# PERMANENTLY in disagreement and the tree asserted the disagreement.
# Moving `.version` to another release left all 121 test-tools cases
# green.
#
# ── Why one source and not two kept in step ──────────────────────────────
#
# The repair that suggests itself is a literal in the worker that the
# release bump rewrites. That is the same two-sources defect one
# indirection further away, and the rewrite is the step nobody notices was
# skipped -- the shape base#1169 removed from the local content-hash tag
# and base#1171 from the CI change signal, both by DERIVING the set
# instead of listing it.
#
# So `.version` is the source, read out of the base checkout the worker
# already takes at its OWN ref (`github.job_workflow_sha`) for the
# cache-scope, runtime-stage and stage-name resolvers. The tag the image
# is published under and the tag a worker consumes become the same string
# from the same file, with no step keeping them in step.
#
# ── What this spec holds ─────────────────────────────────────────────────
#
# The first cases pin what script/ci/testtools_image.sh answers, including
# that every unreadable version REFUSES and never answers `latest` -- the
# rolling tag is the one reference a pinned worker must not build from, so
# it must not also be the fallback.
#
# The rest derive their population from `.github/workflows/`, never a list
# here: the site this guard exists for is tomorrow's addition. No workflow
# may spell a registry-qualified tooling-image tag at all (the registry
# path has one home too, so the package cannot be renamed in one place and
# missed in another), no reusable worker may declare a
# `test_tools_version` input again, and every `TEST_TOOLS_IMAGE` a worker
# passes must take its value from a step that runs the derivation -- the
# positive half, without which a worker could stop passing the arg
# entirely and the two negative scans would both report clean.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  DERIVATION=/source/script/ci/testtools_image.sh
  WF_DIR=/source/.github/workflows
  VERSION_FILE=/source/.version
  assert_spec_subject "${DERIVATION}" \
      "the one source of the tooling image a worker build consumes"
  assert_spec_subject "${VERSION_FILE}" \
      "the version file that source reads"
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow tree this spec derives its consuming sites from"
}

# _tree <version-file-content>... -- a synthetic base root whose `.version`
# holds the given lines, or no `.version` at all when called with no
# argument. Only that file comes from the fixture: the derivation resolves
# the version owner it asks next to ITSELF, so pointing it at a tree
# exercises the version reading and nothing else.
_tree() {
  local _root
  _root="$(mktemp -d "${BATS_TEST_TMPDIR}/base.XXXXXX")"
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@" > "${_root}/.version"
  fi
  printf '%s\n' "${_root}"
}

# _derive_as_nobody <base-root> -- derive the reference in a shell with no
# privilege to override file modes, setting $output/$status the way `run`
# does. The suite runs as root inside the tooling container, where a
# mode-000 file is still readable, so "unreadable" can only be staged by
# dropping privilege -- and every directory from the test tmpdir down has
# to be traversable for that user, or the probe fails on the way in and
# proves nothing about the subject. Shape borrowed from
# testtools_paths_spec.bats's _paths_as_nobody, which stages the same
# condition for the sibling derivation.
_derive_as_nobody() {
  local _root="${1:?BUG: _derive_as_nobody requires <base-root>}"
  local _p="${BATS_TEST_TMPDIR}"
  while [[ "${_p}" == /* && "${_p}" != "/" ]]; do
    chmod o+rx "${_p}"
    _p="$(dirname "${_p}")"
  done
  if [[ "$(id -u)" -eq 0 ]]; then
    run --separate-stderr su -s /bin/bash nobody \
      -c "bash ${DERIVATION} ${_root}"
  else
    run --separate-stderr bash "${DERIVATION}" "${_root}"
  fi
}

# _consuming_tag_literals -- one `finding: <file>: <line>` per code line in
# the workflow tree that spells a registry-qualified tooling-image TAG,
# plus a trailing `scanned=<n>` so a scan that stopped matching the tree
# cannot report agreement forever.
#
# Comment-only lines are excluded by code_grep, deliberately: prose that
# QUOTES the reference it is explaining ("consumed via
# `ARG TEST_TOOLS_IMAGE=ghcr.io/.../test-tools:<ver>`") names no image to
# any build.
_consuming_tag_literals() {
  local _f _line _scanned=0
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _scanned=$(( _scanned + 1 ))
    while IFS= read -r _line; do
      printf 'finding: %s: %s\n' "${_f##*/}" \
          "${_line#"${_line%%[![:space:]]*}"}"
    done < <(code_grep -F 'ghcr.io/ycpss91255-docker/test-tools:' "${_f}" \
        || true)
  done < <(workflow_files "${WF_DIR}")
  printf 'scanned=%s\n' "${_scanned}"
}

# _test_tools_version_inputs -- one `finding: <file>` per reusable worker
# that declares a `test_tools_version` input, plus `scanned=<n>`.
_test_tools_version_inputs() {
  local _f _scanned=0
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    case "${_f}" in BUG:*) printf '%s\n' "${_f}"; continue ;; esac
    _scanned=$(( _scanned + 1 ))
    if code_grep -E '^[[:space:]]+test_tools_version:' "${_f}" \
        > /dev/null; then
      printf 'finding: %s\n' "${_f##*/}"
    fi
  done < <(reusable_workflow_files "${WF_DIR}")
  printf 'scanned=%s\n' "${_scanned}"
}

# _test_tools_image_values -- one `<file>: <line>` per code line in a
# reusable worker that gives TEST_TOOLS_IMAGE a value, plus `scanned=<n>`.
# Two spellings carry one: a `KEY=VALUE` build-arg inside a block scalar,
# and a `KEY: VALUE` step env entry.
#
# `TEST_TOOLS_IMAGE=${TEST_TOOLS_IMAGE}` is left out, and it is the one
# exclusion: that is a step's own shell READING the env entry it was
# given, not a value, and the env entry it reads is itself in this
# population and checked. Counting it would demand that a shell expansion
# name a GitHub step, which no shell line can.
_test_tools_image_values() {
  local _f _line _scanned=0
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    case "${_f}" in BUG:*) printf '%s\n' "${_f}"; continue ;; esac
    _scanned=$(( _scanned + 1 ))
    while IFS= read -r _line; do
      case "${_line}" in
        *'TEST_TOOLS_IMAGE=${TEST_TOOLS_IMAGE}'*) continue ;;
      esac
      printf '%s: %s\n' "${_f##*/}" \
          "${_line#"${_line%%[![:space:]]*}"}"
    done < <(code_grep -E 'TEST_TOOLS_IMAGE[=:]' "${_f}" || true)
  done < <(reusable_workflow_files "${WF_DIR}")
  printf 'scanned=%s\n' "${_scanned}"
}

# _scripts_naming_the_retired_input -- one `finding: <path>` per shipped or
# base-own shell script whose CODE names `test_tools_version`, plus
# `scanned=<n>`.
#
# upgrade.sh rewrites the `@vX.Y.Z` ref in a caller's main.yaml, and that
# ref is now the whole version the worker needs. A sed here writing a
# tooling version beside it would be the second source again, reached from
# the one place that edits every downstream repo at once. Comments are
# excluded by code_grep, which is what lets upgrade.sh SAY so at the site.
#
# The match is word-bounded, not a substring: build.sh's log event
# `build_test_tools_version_missing` is a message id about the LOCAL tag's
# version file and names no workflow input. `_` is a word character, so the
# id carries no boundary before `test` or after `version` and is not a hit.
_scripts_naming_the_retired_input() {
  local _f _scanned=0
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _scanned=$(( _scanned + 1 ))
    if code_grep -E '\btest_tools_version\b' "${_f}" > /dev/null; then
      printf 'finding: %s\n' "${_f#/source/}"
    fi
  done < <(find /source/dist /source/script -type f -name '*.sh' | sort)
  printf 'scanned=%s\n' "${_scanned}"
}

# _step_run_by_id <file> <id> -- the `run:` script of the step carrying
# `id: <id>`, searched for across the file's jobs. The caller starts from
# an expression naming a STEP and never a job, which is also why no table
# here may pair the two.
_step_run_by_id() {
  local _file="${1}" _id="${2}" _jobs _job _run _status=0
  _jobs="$(yaml_job_names "${_file}")" || _status=$?
  if [[ "${_status}" -ne 0 ]]; then
    printf '%s\n' "${_jobs}" >&2
    return 1
  fi
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    _run="$(yaml_step_run "${_file}" "${_job}" "${_id}")" || continue
    if [[ -n "${_run}" ]]; then
      printf '%s\n' "${_run}"
      return 0
    fi
  done <<< "${_jobs}"
  return 1
}

# ── What the derivation answers ───────────────────────────────────────

# why: The reference is the published package at the release the checkout
# names, assembled here rather than by each consumer so the registry path
# has one home as well as the tag.
@test "testtools_image: the reference is the published package at the checkout's own release (closes #1122)" {
  local _root
  _root="$(_tree 'v0.40.3')"
  run bash "${DERIVATION}" "${_root}"
  assert_success
  assert_output 'ghcr.io/ycpss91255-docker/test-tools:v0.40.3'
}

# why: The pair that is the whole point: the consumed tag MOVES with the
# release the worker's checkout is at. Nothing noticed when it did not.
@test "testtools_image: a different release in the checkout consumes a different image (closes #1122)" {
  local _a _b
  _a="$(_tree 'v0.42.0')"
  _b="$(_tree 'v0.43.0')"
  run bash "${DERIVATION}" "${_a}"
  assert_success
  assert_output 'ghcr.io/ycpss91255-docker/test-tools:v0.42.0'
  run bash "${DERIVATION}" "${_b}"
  assert_success
  assert_output 'ghcr.io/ycpss91255-docker/test-tools:v0.43.0'
}

# why: An RC publishes `:<ver>` and leaves `:latest` where it was, so an
# RC worker must consume its OWN prerelease image -- the window during
# which `latest` was a different release entirely.
@test "testtools_image: a prerelease checkout consumes its own prerelease image (closes #1122)" {
  local _root
  _root="$(_tree 'v0.43.0-rc2')"
  run bash "${DERIVATION}" "${_root}"
  assert_success
  assert_output 'ghcr.io/ycpss91255-docker/test-tools:v0.43.0-rc2'
}

# why: Trailing whitespace is how a version file arrives from an editor; a
# tag with a newline in it names no image.
@test "testtools_image: surrounding whitespace in the version file is not part of the tag (closes #1122)" {
  local _root
  _root="$(mktemp -d "${BATS_TEST_TMPDIR}/base.XXXXXX")"
  printf '  v0.41.0  \n\n' > "${_root}/.version"
  run bash "${DERIVATION}" "${_root}"
  assert_success
  assert_output 'ghcr.io/ycpss91255-docker/test-tools:v0.41.0'
}

# why: The fallback that suggests itself for an unreadable version is
# `latest`, the one reference this exists to stop a pinned worker
# consuming. Refusing with nothing on stdout is the only direction that
# fails where it is used instead of linting against unchosen tools.
@test "testtools_image: an absent version file is refused, never answered latest (closes #1122)" {
  local _root
  _root="$(_tree)"
  run bash "${DERIVATION}" "${_root}"
  assert_failure
  refute_output --partial 'test-tools:'
  assert_output --partial "${_root}/.version"
}

# why: Present-but-unreadable is the state an existence check passes and a
# reader then answers with nothing. Here that nothing would reach the
# version owner as "no version was supplied to release", so the refusal has
# to come from the readability test and name this file.
@test "testtools_image: an unreadable version file is refused (closes #1122)" {
  local _root
  _root="$(_tree 'v0.42.0')"
  chmod -R o+rX "${_root}"
  chmod 000 "${_root}/.version"
  _derive_as_nobody "${_root}"
  assert_failure
  assert_output ''
  [[ "${stderr}" == *"${_root}/.version"* ]] || fail \
      "the refusal does not say which file could not be read: ${stderr}"
}

# why: An empty version reaching the version owner would be reported as
# "nothing was supplied to release", a message about a release that never
# names this file.
@test "testtools_image: an empty version file is refused, naming the file (closes #1122)" {
  local _root
  _root="$(mktemp -d "${BATS_TEST_TMPDIR}/base.XXXXXX")"
  : > "${_root}/.version"
  run bash "${DERIVATION}" "${_root}"
  assert_failure
  refute_output --partial 'test-tools:'
  assert_output --partial "${_root}/.version"
}

# why: The published tooling tag IS the git tag, so a value that could not
# become a tag names no image. The shape rule has one owner and is not
# re-answered here.
@test "testtools_image: content that is not a release version is refused, naming it (closes #1122)" {
  local _root _case
  for _case in 'main' 'latest' 'v1.0' '0.43.0'; do
    _root="$(_tree "${_case}")"
    run bash "${DERIVATION}" "${_root}"
    assert_failure
    refute_output --partial 'test-tools:'
    assert_output --partial "${_case}"
  done
}

# why: CI passes no argument and must get the checkout the script lives in
# -- the base source at the worker's own ref. The expectation is read from
# the version file by a second reader, so it is the FILE CHOSEN that is
# under test and not the format.
@test "testtools_image: with no argument it reads the checkout it lives in (closes #1122)" {
  local _tracked
  _tracked="$(tr -d '[:space:]' < "${VERSION_FILE}")"
  [[ -n "${_tracked}" ]] || fail \
      "${VERSION_FILE} is empty -- this case has nothing to compare against."
  run bash "${DERIVATION}"
  assert_success
  assert_output "ghcr.io/ycpss91255-docker/test-tools:${_tracked}"
}

# ── The population of consuming sites, derived from the tree ──────────

# why: A second spelling of the reference is a second source of it. The
# population is the workflow tree rather than the three files that carried
# one, so the fourth site is covered the day it lands.
@test "testtools_image: no workflow spells a registry-qualified tooling image tag (closes #1122)" {
  run _consuming_tag_literals
  assert_success
  refute_output --partial 'finding:'
  refute_output --partial 'scanned=0'
}

# why: The input is the second source this removed. Declared again -- with
# any default, `latest` or not -- it is a value a caller can set to
# something the `@ref` pin does not name, which is the whole defect.
@test "testtools_image: no reusable worker declares a test_tools_version input (closes #1122)" {
  run _test_tools_version_inputs
  assert_success
  refute_output --partial 'finding:'
  refute_output --partial 'BUG:'
  refute_output --partial 'scanned=0'
}

# why: The upgrade is the one place that edits every downstream repo, so a
# tooling version written into a caller's workflow from there would
# reintroduce the second source across the whole org at once.
@test "testtools_image: no shipped script writes a tooling version into a caller's workflow (closes #1122)" {
  run _scripts_naming_the_retired_input
  assert_success
  refute_output --partial 'finding:'
  refute_output --partial 'scanned=0'
}

# why: The load-bearing positive half. Without it a worker could stop
# passing the arg at all and both negative scans above would report clean.
# Every hop is derived: the workers from the tree, the step from the
# expression the value is, the script from that step's own body.
@test "testtools_image: every TEST_TOOLS_IMAGE a reusable worker passes comes from the derivation (closes #1122)" {
  local _line _file _value _id _run _sites=0 _scanned=0
  while IFS= read -r _line; do
    case "${_line}" in
      scanned=*) _scanned="${_line#scanned=}"; continue ;;
      BUG:*) fail "${_line}" ;;
    esac
    _file="${_line%%: *}"
    _value="${_line#*: }"
    [[ "${_value}" =~ steps\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_-]+ ]] \
        || fail "${_line} -- a TEST_TOOLS_IMAGE value must come from the step that ran script/ci/testtools_image.sh, not from an input or a literal written here."
    _id="${BASH_REMATCH[1]}"
    _run="$(_step_run_by_id "${WF_DIR}/${_file}" "${_id}")" || fail \
        "${_file}: no step with id '${_id}' carries a run: script, so nothing in it can have derived the tooling image."
    printf '%s\n' "${_run}" | grep -F 'script/ci/testtools_image.sh' \
        > /dev/null || fail \
        "${_file}: step '${_id}' feeds TEST_TOOLS_IMAGE but its run: script does not call script/ci/testtools_image.sh, so the reference comes from somewhere this spec cannot vouch for."
    _sites=$(( _sites + 1 ))
  done < <(_test_tools_image_values)
  [[ "${_scanned}" -gt 0 ]] || fail \
      "no reusable worker was scanned at all -- the tree moved and this assertion is vacuous."
  [[ "${_sites}" -ge 2 ]] || fail \
      "only ${_sites} TEST_TOOLS_IMAGE site(s) found across ${_scanned} reusable worker(s); the build worker passes it to the devel-test, runtime-test and extra-stage builds and the publish worker to its own, so a scan finding fewer has stopped matching."
}
