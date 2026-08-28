#!/usr/bin/env bats
#
# readme_file_table_spec.bats -- the "What's included" table in README.md
# is a file INDEX, so every row names a real path. Nothing checked that.
#
# #957 item 3 was one such row: it still called the per-repo runtime config
# `setup.conf` after the file had been renamed to `.setup.conf` and moved
# under `dist/`. The stale-path lint that would normally have caught it
# (script/test/drivers/stale_setup_conf.sh) scans `dist/**/*.sh` only, so
# prose in README.md was outside every gate -- the row could be edited back
# to the old name and the suite would stay green.
#
# The rows mix two vantage points on purpose: base-relative paths (the
# repo's own `dist/`, `script/`, `test/` trees) and CONSUMER-relative ones
# (`build.sh`, `.setup.conf`, `config/`, `.hadolint.yaml` -- what a
# downstream repo sees once init.sh has symlinked the wrappers and the
# shipped `dist/` payload has landed at its root). A row is therefore
# satisfied if it resolves at the repo root, under `dist/` (the shipped
# consumer payload) or under `script/` (base's own wrapper copies), and a
# row that resolves nowhere is a stale path.

bats_require_minimum_version 1.5.0

README="/source/README.md"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject "${README}" "the file index this spec pins"
}

# Print the path each row of the "What's included" table names -- the first
# backticked token of the row. The table is interrupted mid-way by prose,
# so the scan runs to the next `###` heading and picks only table rows.
_file_table_paths() {
  awk '
    /^### What.s included/ { in_table = 1; next }
    in_table && /^### /    { in_table = 0 }
    !in_table              { next }
    /^\| `/ {
      line = $0
      sub(/^\| `/, "", line)
      sub(/`.*/, "", line)
      print line
    }
  ' "${README}"
}

# Print every table path that resolves under none of the three roots.
_unresolvable_file_table_paths() {
  local _path
  while read -r _path; do
    [[ -e "/source/${_path}" ]] && continue
    [[ -e "/source/dist/${_path}" ]] && continue
    [[ -e "/source/script/${_path}" ]] && continue
    printf '%s\n' "${_path}"
  done < <(_file_table_paths)
}

@test "README file table: every row names a path that exists (#957)" {
  run _unresolvable_file_table_paths
  assert_success
  assert_output ''
}

@test "README file table: the scan actually finds the rows (#957)" {
  # The guard above is vacuous the moment the extractor matches nothing --
  # a renamed heading or a reformatted table would silence it while
  # reporting green. Pin a floor on the row count so the table has to be
  # findable for the check above to mean anything.
  run _file_table_paths
  assert_success
  [ "${#lines[@]}" -ge 40 ]
}
