#!/usr/bin/env bats
#
# testtools_paths_spec.bats -- "the paths CI treats as inputs of the tooling
# image are the paths the image is actually built from".
#
# why: Two CI decisions -- `testtools_changed` in self-test.yaml's classify
# job, and whether a push to main republishes the rolling `:main` tag --
# answered that question with one quoted literal, the Dockerfile's own path.
# A stage that COPYs a file out of the build context bakes that file's
# CONTENT into the image while the Dockerfile does not move, so a commit
# touching only that file left both decisions answering "unchanged": the PR
# ran its whole suite inside an image built before the edit, and the merge
# that followed did not refresh the tag it had fallen back to.
#
# `script/ci/testtools_paths.sh` answers it by DERIVATION instead, through
# the same code that decides which files the local content-hash tag hashes.
# The cases below are mostly synthetic trees, because the property is about
# Dockerfiles this repo does not have yet: the second context COPY someone
# adds, the glob nobody can resolve, the `--from=` stage path that is not a
# checkout path at all. Two cases read the real Dockerfile, in both
# directions, so the derivation cannot drift away from the tree it is about.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  PATHS_SH=/source/script/ci/testtools_paths.sh
  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${PATHS_SH}" \
      "the derivation of the tooling image's input paths"
  assert_spec_subject "${DOCKERFILE}" \
      "the tooling Dockerfile the derivation reads"
}

# _tree <relative-dockerfile-body-path>... -- build a synthetic checkout
#   whose tooling Dockerfile is written by the caller afterwards, and print
#   its root. Every named path is created as a one-line file first, so a
#   COPY of it resolves.
_tree() {
  local _root="${BATS_TEST_TMPDIR}/tree.${BATS_SUITE_TEST_NUMBER}"
  rm -rf "${_root}"
  mkdir -p "${_root}/dockerfile"
  local _p
  for _p in "$@"; do
    mkdir -p "${_root}/$(dirname "${_p}")"
    printf 'one\n' > "${_root}/${_p}"
  done
  printf '%s\n' "${_root}"
}

# _copy_srcs_of <dockerfile>
#   The build-context sources of <dockerfile>, read HERE with a four-line
#   grep rather than through the derivation under test: an expected value
#   the subject computed is an expected value that can never disagree with
#   it. Understands only the plain `COPY <src> <dst>` form, which is what
#   the real Dockerfile uses; the forms it cannot read are refused by the
#   derivation and asserted as refusals below.
_copy_srcs_of() {
  grep -E '^[[:space:]]*COPY[[:space:]]' "${1}" \
    | grep -v -- '--from=' \
    | awk '{ for (i = 2; i < NF; i++) if (substr($i, 1, 2) != "--") print $i }'
}

# ── the real tree, both directions ─────────────────────────────────────

# why: The first direction, and the defect itself: a file the real
# Dockerfile COPYs out of the build context is an input of the image, and
# the signal has to name it. Read off the Dockerfile independently, so the
# COPY somebody adds tomorrow brings its own requirement with it instead of
# waiting for this spec to be edited.
@test "testtools paths: every context COPY of the real Dockerfile is an input (#1171)" {
  run bash "${PATHS_SH}"
  assert_success
  local _s _missing=""
  while IFS= read -r _s; do
    [[ -n "${_s}" ]] || continue
    grep -qxF "${_s}" <<< "${output}" || _missing="${_missing}${_s}"$'\n'
  done < <(_copy_srcs_of "${DOCKERFILE}")
  [[ -z "${_missing}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context and the derivation leaves them out:"$'\n'"${_missing}"
  grep -qxF 'dockerfile/Dockerfile.test-tools' <<< "${output}" || fail \
      "the derivation does not name the Dockerfile itself, which is the one input it always had"
}

# why: The opposite direction, and the reason this is a derivation rather
# than "hash the checkout": a signal that answers "everything is an input"
# passes every case above, rebuilds the tooling image on every pull request
# and throws away the pull path the rolling tag exists for. Every path it
# emits has to be one the Dockerfile actually reads.
@test "testtools paths: it emits nothing the real Dockerfile does not read (#1171)" {
  run bash "${PATHS_SH}"
  assert_success
  local _expected
  _expected="$( { printf 'dockerfile/Dockerfile.test-tools\n'; \
                  _copy_srcs_of "${DOCKERFILE}"; } | sort -u)"
  local _p _extra=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    grep -qxF "${_p}" <<< "${_expected}" || _extra="${_extra}${_p}"$'\n'
  done <<< "${output}"
  [[ -z "${_extra}" ]] || fail \
      "the derivation treats these as inputs of the tooling image and the Dockerfile neither is nor reads them:"$'\n'"${_extra}"
}

# ── the COPY nobody has added yet ──────────────────────────────────────

# why: The load-bearing case. The alternative to deriving was a second
# literal in each filter, which is correct on the day it is written and
# wrong the next time somebody adds a COPY -- with nothing that notices,
# which is how this defect existed at all. A SECOND context COPY has to be
# covered without anything being edited anywhere.
@test "testtools paths: a second context COPY is covered with no list edited (#1171)" {
  local _root
  _root="$(_tree dockerfile/first.py tools/second.sh)"
  printf 'FROM alpine:3.21\nCOPY dockerfile/first.py /usr/local/bin/first\nCOPY tools/second.sh /usr/local/bin/second\n' \
    > "${_root}/dockerfile/Dockerfile.test-tools"

  run bash "${PATHS_SH}" "${_root}"
  assert_success
  assert_line 'dockerfile/Dockerfile.test-tools'
  assert_line 'dockerfile/first.py'
  assert_line 'tools/second.sh'
}

# why: A COPY of a DIRECTORY is one pathspec covering a subtree that may
# grow files after this runs. Emitting the directory keeps the signal honest
# about the file added under it tomorrow; expanding it to today's members
# would be a list again, one indirection further in.
@test "testtools paths: a directory COPY is emitted as the directory (#1171)" {
  local _root
  _root="$(_tree dockerfile/tools/a.py dockerfile/tools/b.py)"
  printf 'FROM alpine:3.21\nCOPY dockerfile/tools /opt/tools\n' \
    > "${_root}/dockerfile/Dockerfile.test-tools"

  run bash "${PATHS_SH}" "${_root}"
  assert_success
  assert_line 'dockerfile/tools'
  refute_line 'dockerfile/tools/a.py'
}

# why: Every other COPY in the real Dockerfile is one of these. A
# `--from=<stage>` source is a path inside an earlier STAGE, not in the
# checkout, so emitting it would hand `git diff` a pathspec matching
# nothing -- and, worse, read as coverage while covering nothing.
@test "testtools paths: a COPY --from= source is not a checkout path (#1171)" {
  local _root
  _root="$(_tree)"
  printf 'FROM alpine:3.21 AS builder\nFROM alpine:3.21\nCOPY --from=builder /usr/local/bin/kcov /usr/local/bin/kcov\n' \
    > "${_root}/dockerfile/Dockerfile.test-tools"

  run bash "${PATHS_SH}" "${_root}"
  assert_success
  assert_output 'dockerfile/Dockerfile.test-tools'
}

# ── the refusals, and what reaches stdout ─────────────────────────────

# why: A COPY source needing docker's own parser cannot be resolved to a
# definite set of paths, and a guess is how a file silently leaves the
# signal. The refusal has to name the line, and it has to leave stdout
# EMPTY: a partial list is the one answer that looks like an answer, and the
# consumer would diff against it and report the image unchanged.
@test "testtools paths: a COPY it cannot resolve refuses, naming the line (#1171)" {
  local _root
  _root="$(_tree dockerfile/first.py)"
  printf 'FROM alpine:3.21\nCOPY dockerfile/*.py /usr/local/bin/\n' \
    > "${_root}/dockerfile/Dockerfile.test-tools"

  run --separate-stderr bash "${PATHS_SH}" "${_root}"
  assert_failure
  assert_output ''
  [[ "${stderr}" == *'Dockerfile.test-tools:2'* ]] || fail \
      "the refusal does not name the line it could not read: ${stderr}"
}

# why: ADD reads the build context and ONBUILD can defer a COPY into it.
# Both are verbs this derivation does not model, and passing over either is
# exactly the silent omission it exists to stop -- so each is a refusal the
# consumer turns into a rebuild, not a shorter list.
@test "testtools paths: a verb it does not model refuses rather than skips (#1171)" {
  local _root _verb
  for _verb in 'ADD dockerfile/first.py /usr/local/bin/first' \
               'ONBUILD COPY dockerfile/first.py /usr/local/bin/first'; do
    _root="$(_tree dockerfile/first.py)"
    printf 'FROM alpine:3.21\n%s\n' "${_verb}" \
      > "${_root}/dockerfile/Dockerfile.test-tools"
    run --separate-stderr bash "${PATHS_SH}" "${_root}"
    assert_failure
    assert_output ''
  done
}

# why: A tree with no tooling Dockerfile has no derivable input set, and the
# empty list is the one thing it must not print: an empty pathspec list
# handed to `git diff` compares the WHOLE diff, so "there is no tooling
# Dockerfile" would read as "every path is an input of it". Refusing lets
# the consumer fail open on purpose instead of by accident.
@test "testtools paths: an absent tooling Dockerfile refuses, printing nothing (#1171)" {
  local _root
  _root="$(_tree)"
  rm -f "${_root}/dockerfile/Dockerfile.test-tools"

  run --separate-stderr bash "${PATHS_SH}" "${_root}"
  assert_failure
  assert_output ''
  [[ "${stderr}" == *'Dockerfile.test-tools'* ]] || fail \
      "the refusal does not say which file was missing: ${stderr}"
}

# ── agreement with the local content-hash tag ─────────────────────────

# why: The criterion the shared derivation exists for: the set CI treats as
# inputs has to be the set the LOCAL tag hashes. Asserted behaviourally
# rather than by both calling the same function -- every path the signal
# emits moves the tag when its bytes change, and a path it does not emit
# leaves the tag alone. Two rules for one question is how they come to
# disagree, and the disagreement is a CI run that pulls an image the local
# derivation would have rebuilt.
@test "testtools paths: its set is the set the local tag hashes (#1171)" {
  local _root
  _root="$(_tree dockerfile/first.py tools/second.sh script/unrelated.sh)"
  printf 'FROM alpine:3.21\nCOPY dockerfile/first.py /usr/local/bin/first\nCOPY tools/second.sh /usr/local/bin/second\n' \
    > "${_root}/dockerfile/Dockerfile.test-tools"

  local _df="${_root}/dockerfile/Dockerfile.test-tools"
  local _tag _before _p _still=""
  _tag='source /source/script/test/test.sh; unset TEST_TOOLS_IMAGE;
        _resolve_test_tools_image "'"${_df}"'"'
  run bash -c "${_tag}"
  assert_success
  _before="${output}"

  while IFS= read -r _p; do
    [[ -n "${_p}" && "${_p}" != 'dockerfile/Dockerfile.test-tools' ]] \
      || continue
    printf 'two\n' > "${_root}/${_p}"
    run bash -c "${_tag}"
    assert_success
    [[ "${output}" != "${_before}" ]] || _still="${_still}${_p}"$'\n'
    _before="${output}"
    printf 'one\n' > "${_root}/${_p}"
    run bash -c "${_tag}"
    assert_success
    _before="${output}"
  done < <(bash "${PATHS_SH}" "${_root}")
  [[ -z "${_still}" ]] || fail \
      "the signal calls these inputs of the tooling image and the local tag does not hash them:"$'\n'"${_still}"

  printf 'echo two\n' > "${_root}/script/unrelated.sh"
  run bash -c "${_tag}"
  assert_success
  assert_output "${_before}"
  run bash "${PATHS_SH}" "${_root}"
  assert_success
  refute_line 'script/unrelated.sh'
}
