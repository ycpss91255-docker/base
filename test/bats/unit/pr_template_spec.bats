#!/usr/bin/env bats
#
# pr_template_spec.bats - the PR checklist template exists and carries its
# section headings (base#1641). GitHub auto-loads
# `.github/pull_request_template.md` for every PR opened in the web UI, so a
# missing file or a missing section means authors lose part of the checklist.

setup() {
  TEMPLATE="${BATS_TEST_DIRNAME}/../../../.github/pull_request_template.md"
}

# why: Without the file GitHub has nothing to auto-load, so authors lose
# the whole checklist
@test "the PR template file exists" {
  [[ -f "${TEMPLATE}" ]]
}

# why: A heading that is gone drops its checklist items from every new PR
@test "the PR template has every section heading" {
  [[ -f "${TEMPLATE}" ]]
  local heading
  for heading in \
    "## Linked issue" \
    "## Single concern and atomic commits" \
    "## Control flow" \
    "## Test and build" \
    "## Security and boundaries"; do
    grep -qxF "${heading}" "${TEMPLATE}" || {
      echo "missing heading: ${heading}" >&2
      return 1
    }
  done
}
