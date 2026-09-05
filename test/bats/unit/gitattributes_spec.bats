#!/usr/bin/env bats
#
# Unit tests for .gitattributes -- specifically the union merge driver the
# changelog split widened.
#
# `merge=union` is the one merge that CANNOT conflict: git keeps both sides
# of every overlapping hunk and marks nothing for a human to look at. That
# is exactly right for an append-only log, where two branches appending to
# `[Unreleased]` should both land, and exactly wrong for hand-written prose,
# where the same silence duplicates a rewritten paragraph with nothing to
# review and no conflict to notice.
#
# The pattern used to name doc/changelog/CHANGELOG.md, one file. The split
# widened it to a directory glob, and a gitattributes `*` does not cross
# `/` -- so the glob covers every file sitting DIRECTLY in doc/changelog/:
# the 43 series files it is for, and CONVENTIONS.md, which is prose.
# Nothing else in this repo reads CONVENTIONS.md outside its
# `changelog-categories` marker block, so a union-merged duplication in the
# rest of it would ship unremarked.
#
# Asserted through `git check-attr` in a throwaway repository rather than by
# reading the file, because the question is what GIT resolves for a path and
# the pattern language -- `*` versus `**`, a leading slash, a later line
# overriding an earlier one -- is precisely the part a reader gets wrong.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  ATTRS=/source/.gitattributes
  assert_spec_subject "${ATTRS}" \
      "the attributes file whose merge drivers this spec pins"

  SCRATCH="$(mktemp -d)"
  git init -q "${SCRATCH}"
  cp "${ATTRS}" "${SCRATCH}/.gitattributes"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _merge_attr <repo-relative-path> -- the merge driver git resolves for the
# path. `unspecified` when no pattern claims it.
_merge_attr() {
  git -C "${SCRATCH}" check-attr merge -- "${1}" | sed 's/.*: //'
}

# why: The reason the pattern was widened at all: [Unreleased] moved into the
# series file being written, so that -- not CHANGELOG.md -- is the file
# two branches both append to, and a pattern naming only the index leaves
# it on the default three-way merge.
@test ".gitattributes: a changelog series file merges by union (#926)" {
  # The reason the pattern exists: [Unreleased] lives in the series file
  # being written, so that is the file two branches both append to.
  [ "$(_merge_attr doc/changelog/v0.43.md)" = 'union' ]
}

# why: The original scope of the rule, kept rather than assumed: the index is
# derived and the layout lint re-derives it, so a union duplicate there is
# reported instead of shipped.
@test ".gitattributes: the generated changelog index merges by union (#926)" {
  # The original scope of the rule, kept: the index is derived, and the
  # layout lint re-derives it, so a union duplicate there is reported.
  [ "$(_merge_attr doc/changelog/CHANGELOG.md)" = 'union' ]
}

# why: The boundary the widened glob nearly crossed. A gitattributes `*` does
# not cross `/`, so `doc/changelog/*.md` would have covered hand-written
# prose -- where union merging keeps both copies of a rewritten paragraph
# in silence, and no gate in this repo reads that file outside its marker
# block.
@test ".gitattributes: CONVENTIONS.md is NOT union-merged (#926)" {
  # Prose, not a log. Two edits to the same paragraph would both be kept,
  # silently, and no gate in this repo reads that part of the file.
  [ "$(_merge_attr doc/changelog/CONVENTIONS.md)" != 'union' ]
}
