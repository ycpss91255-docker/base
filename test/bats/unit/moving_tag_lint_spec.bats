#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/moving_tag.sh -- the "nothing internal
# consumes a moving test-tools tag" lint (base#1647).
#
# The release workflow publishes test-tools as :<ver> always, :latest for a
# non-prerelease tag and :main from main. :latest and :main are conveniences
# for humans and bootstrap; an internal build that resolves the tooling image
# by one of them gets whatever was pushed last, which is how base#1122
# happened. The lint refuses such a reference in base's own workflows,
# Dockerfiles, compose, justfile and scripts outside a per-line allow-list.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents. Shape mirrors
# arch_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/moving_tag.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_moving_tag: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_moving_tag: FAILS on a workflow that pulls test-tools:latest, naming file and line (base#1647)" {
  _write ".github/workflows/x.yaml" \
    'jobs:' \
    '  image: ghcr.io/ycpss91255-docker/test-tools:latest'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".github/workflows/x.yaml:2"* ]]
}

@test "_run_moving_tag: FAILS on a script naming test-tools:main under an unqualified registry prefix (base#1647)" {
  _write "script/ci/a.sh" \
    '#!/usr/bin/env bash' \
    'TEST_TOOLS_IMAGE=${ORG}/test-tools:main'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/ci/a.sh:2"* ]]
}

@test "_run_moving_tag: FAILS on a tag fed by a workflow input whose default is latest (the pre-base#1204 build-worker shape, base#1647)" {
  # The base#1122 regression, from git show a67636b3: no literal moving tag,
  # an input defaulting to "latest" feeding the image tag.
  _write ".github/workflows/build-worker.yaml" \
    'on:' \
    '  workflow_call:' \
    '    inputs:' \
    '      test_tools_version:' \
    '        required: false' \
    '        type: string' \
    '        default: "latest"' \
    'jobs:' \
    '  build:' \
    '    steps:' \
    '      - with:' \
    '          build-args: |' \
    '            TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:${{ inputs.test_tools_version }}'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".github/workflows/build-worker.yaml:13"* ]]
}

@test "_run_moving_tag: FAILS on an untagged qualified test-tools base that a later line suffixes with :latest, naming the base line (base#1647)" {
  # The tag line carries no test-tools text; only the base line does.
  _write ".github/workflows/publish.yaml" \
    'env:' \
    '  IMAGE: ghcr.io/ycpss91255-docker/test-tools' \
    'jobs:' \
    '  push:' \
    '    steps:' \
    '      - run: docker push "${IMAGE}:latest"'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".github/workflows/publish.yaml:2"* ]]
}

@test "_run_moving_tag: FAILS on a variable test-tools tag in a Dockerfile, compose.yaml and the justfile, one violation each (base#1647)" {
  # Not only workflows: every scanned root counts, and a tag taken from a
  # variable (:${ver}) is mutable, not a pin.
  _write "dist/dockerfile/Dockerfile" \
    'ARG ver' \
    'FROM ghcr.io/ycpss91255-docker/test-tools:${ver} AS tools'
  _write "compose.yaml" \
    'services:' \
    '  devel:' \
    '    image: ghcr.io/ycpss91255-docker/test-tools:${ver}'
  _write "justfile" \
    'lint:' \
    '    docker run --rm ghcr.io/ycpss91255-docker/test-tools:${ver} lint'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
  [[ "${output}" == *"compose.yaml:3"* ]]
  [[ "${output}" == *"justfile:2"* ]]
  [[ "${output}" == *"3 internal reference(s)"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_moving_tag: scan scope
# ════════════════════════════════════════════════════════════════════

@test "_run_moving_tag: PASSES when a moving tag sits only in git-ignored or unscanned paths (base#1647)" {
  # The lint scans fixed roots, never the whole tree: a local-only ignored
  # copy (.prev-release/, .env, log/ ...) would fail it locally and pass on
  # CI. Every unanchored .gitignore name inside a root is skipped, and
  # doc/, test/ and Markdown are out of scope.
  local _hit='image: ghcr.io/ycpss91255-docker/test-tools:latest'
  _write ".github/workflows/clean.yaml" 'name: clean'
  _write ".prev-release/v0.41.0/.github/workflows/build-worker.yaml" "${_hit}"
  _write ".env" "TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:latest"
  _write "dist/.env" "TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:latest"
  _write "dist/.env.local" "TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:latest"
  _write "dist/.setup.conf.local" "${_hit}"
  _write "script/log/x.sh" "${_hit}"
  _write "script/coverage/x.sh" "${_hit}"
  _write "script/coverage-shards/x.sh" "${_hit}"
  _write "script/multi_run/x.sh" "${_hit}"
  _write "script/.config-gen-bin/x.sh" "${_hit}"
  _write "script/__pycache__/x.sh" "${_hit}"
  _write "dist/.prev-release/v0.41.0/x.yaml" "${_hit}"
  _write "doc/guide/x.sh" "${_hit}"
  _write "test/bats/x.bats" "${_hit}"
  _write "README.md" "${_hit}"
  _write "dist/README.md" "${_hit}"
  run _run_moving_tag
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"moving test-tools tag lint: clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_moving_tag: allow-list
# ════════════════════════════════════════════════════════════════════

@test "_run_moving_tag: an allow-list entry suppresses only its own path, kind, token and anchored line (base#1647)" {
  # The table is read through _moving_tag_allowlist (one entry per line,
  # '<path>|<kind>|<scope>|<count>|<token>|<reason>'); the spec overrides it.
  _moving_tag_allowlist() {
    printf '%s\n' 'script/ci/a.sh|indirect|line:ANCH|1|test-tools:${v}|fixture'
  }
  _write "script/ci/a.sh" 'echo "ANCH test-tools:${v}"'
  run _run_moving_tag
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"moving test-tools tag lint: clean"* ]]

  # Another token in the same file, and the same anchored line in another
  # file, are not covered by the entry.
  _write "script/ci/a.sh" 'echo "ANCH test-tools:${v}"' 'X=test-tools:${w}'
  _write "script/ci/b.sh" 'echo "ANCH test-tools:${v}"'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/ci/a.sh:2: indirect"* ]]
  [[ "${output}" == *"script/ci/b.sh:1: indirect"* ]]
  [[ "${output}" != *"script/ci/a.sh:1:"* ]]
}

@test "_run_moving_tag: FAILS when an entry's anchored occurrences outnumber its count, naming every matched line (base#1647)" {
  # An entry pins how many occurrences it covers: a copy of the sanctioned
  # hint is a new consumer, not a second exception.
  _moving_tag_allowlist() {
    printf '%s\n' 'script/ci/a.sh|moving|line:HINT|1|ghcr.io/ycpss91255-docker/test-tools:main|fixture'
  }
  _write "script/ci/a.sh" \
    'echo "HINT ghcr.io/ycpss91255-docker/test-tools:main"' \
    'echo "HINT ghcr.io/ycpss91255-docker/test-tools:main"'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pins 1, saw 2"* ]]
  [[ "${output}" == *"script/ci/a.sh:1"* ]]
  [[ "${output}" == *"script/ci/a.sh:2"* ]]
}

@test "_run_moving_tag: a comment-scoped entry suppresses only a comment line, never code carrying its token (base#1647)" {
  # Scope 'comment': the line starts with optional blanks then '#'. Code
  # under a comment entry is a new consumer.
  _moving_tag_allowlist() {
    printf '%s\n' '.github/workflows/w.yaml|moving|comment|1|test-tools:latest|fixture'
  }
  _write ".github/workflows/w.yaml" \
    'jobs:' \
    '  # moved test-tools:latest'
  run _run_moving_tag
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"moving test-tools tag lint: clean"* ]]

  _write ".github/workflows/w.yaml" \
    'jobs:' \
    '  # moved test-tools:latest' \
    '  image: ${REGISTRY}/test-tools:latest'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".github/workflows/w.yaml:3: moving"* ]]
  [[ "${output}" != *".github/workflows/w.yaml:2:"* ]]
}

@test "_run_moving_tag: an allow-list entry cannot suppress a tag fed by an input defaulting to latest (base#1647)" {
  # The base#1122 shape is never a sanctioned exception: an entry naming its
  # path, kind, scope and token leaves it a violation.
  _moving_tag_allowlist() {
    printf '%s\n' '.github/workflows/build-worker.yaml|input-default|line:TEST_TOOLS_IMAGE=|1|test-tools:${{ inputs.test_tools_version }}|fixture'
  }
  _write ".github/workflows/build-worker.yaml" \
    'on:' \
    '  workflow_call:' \
    '    inputs:' \
    '      test_tools_version:' \
    '        default: "latest"' \
    'jobs:' \
    '  build:' \
    '    steps:' \
    '      - run: echo TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:${{ inputs.test_tools_version }}'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".github/workflows/build-worker.yaml:9: input-default"* ]]
}

@test "_run_moving_tag: an allow-list entry cannot suppress a tag whose variable defaults to latest (base#1647)" {
  # ${TAG:-latest} resolves to the moving tag whenever TAG is unset: it is
  # never a sanctioned exception, whichever kind an entry names for it.
  _moving_tag_allowlist() {
    printf '%s\n' \
      'dockerfile/Dockerfile.x|indirect|line:FROM|1|test-tools:${TAG:-latest}|fixture' \
      'dockerfile/Dockerfile.x|moving-default|line:FROM|1|test-tools:${TAG:-latest}|fixture'
  }
  _write "dockerfile/Dockerfile.x" 'FROM ${T}/test-tools:${TAG:-latest}'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dockerfile/Dockerfile.x:1: moving-default"* ]]
}

@test "_run_moving_tag: FAILS as stale when an entry matches fewer occurrences than its count (base#1647)" {
  # A removed or reworded exception leaves its entry behind: the table must
  # not keep a slot a new consumer could later fill unnoticed.
  _moving_tag_allowlist() {
    printf '%s\n' 'script/ci/a.sh|moving|line:HINT|2|ghcr.io/ycpss91255-docker/test-tools:main|fixture'
  }
  _write "script/ci/a.sh" 'echo "HINT ghcr.io/ycpss91255-docker/test-tools:main"'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/ci/a.sh"*"stale"* ]]
  [[ "${output}" != *"moving test-tools tag lint: clean"* ]]
}

@test "_run_moving_tag: FAILS on an allow-list entry whose count is 0 (base#1647)" {
  # A count-0 entry sanctions nothing and is never stale: it would sit in
  # the table forever. A count must be a positive integer.
  _moving_tag_allowlist() {
    printf '%s\n' 'script/ci/a.sh|moving|line:HINT|0|ghcr.io/ycpss91255-docker/test-tools:main|fixture'
  }
  _write "script/ci/a.sh" 'echo "no image here"'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/ci/a.sh"*"count"* ]]
  [[ "${output}" != *"moving test-tools tag lint: clean"* ]]
}

@test "_run_moving_tag: FAILS on an allow-list entry with an empty reason (base#1647)" {
  # An exception nobody can explain is an exception nobody can retire:
  # every entry must say why the moving reference is sanctioned.
  _moving_tag_allowlist() {
    printf '%s\n' 'script/ci/a.sh|moving|line:HINT|1|ghcr.io/ycpss91255-docker/test-tools:main|'
  }
  _write "script/ci/a.sh" 'echo "HINT ghcr.io/ycpss91255-docker/test-tools:main"'
  run _run_moving_tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/ci/a.sh"*"reason"* ]]
  [[ "${output}" != *"moving test-tools tag lint: clean"* ]]
}
