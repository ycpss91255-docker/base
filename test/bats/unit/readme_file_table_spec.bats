#!/usr/bin/env bats
#
# readme_file_table_spec.bats -- the "What's included" table in README.md
# is a file INDEX, so every row names a real path. Nothing checked that.
#
# One such row went stale unnoticed: it still called the per-repo runtime
# config `setup.conf` after the rename to `setup.toml` and the move
# under `dist/`. The stale-path lint that would normally have caught it
# (script/test/drivers/stale_setup_conf.sh) scans `dist/**/*.sh` only, so
# prose in README.md was outside every gate -- the row could be edited back
# to the old name and the suite would stay green.
#
# The rows mix two vantage points on purpose: base-relative paths (the
# repo's own `dist/`, `script/`, `test/` trees) and CONSUMER-relative ones
# (`build.sh`, `setup.toml`, `config/`, `.hadolint.yaml` -- what a
# downstream repo sees once init.sh has symlinked the wrappers and the
# shipped `dist/` payload has landed at its root). A row is therefore
# satisfied if it resolves at the repo root, under `dist/` (the shipped
# consumer payload) or under `script/` (base's own wrapper copies), and a
# row that resolves nowhere is a stale path.
#
# why: The "What's included" table in `README.md` is a file INDEX, so every
# row names a real path -- and nothing checked that (#957). Item 3 of that
# issue was one such row: it still called the per-repo runtime config
# `setup.conf` long after the rename to `setup.toml`, and the stale-path
# lint that would normally catch it
# (`script/test/drivers/stale_setup_conf.sh`) scans `dist/**/*.sh` only, so
# the row could be edited back to the old name with the suite green. Rows
# mix two vantage points on purpose -- base-relative paths and
# CONSUMER-relative ones (`build.sh`, `setup.toml`, `config/`, what a
# downstream repo sees once init.sh has run) -- so a row counts as resolved
# under the repo root, `dist/` or `script/`.

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

# why: Every row resolves under one of the three roots; a stale path is
# reported by name
@test "README file table: every row names a path that exists (#957)" {
  run _unresolvable_file_table_paths
  assert_success
  assert_output ''
}

# why: Floor on the row count, so a renamed heading cannot silence the check
# above
@test "README file table: the scan actually finds the rows (#957)" {
  # The guard above is vacuous the moment the extractor matches nothing --
  # a renamed heading or a reformatted table would silence it while
  # reporting green. Pin a floor on the row count so the table has to be
  # findable for the check above to mean anything.
  run _file_table_paths
  assert_success
  [ "${#lines[@]}" -ge 40 ]
}

# ── The table has to be ONE table ────────────────────────────────────────────
#
# The guards above ask what the rows SAY. This one asks whether the renderer
# sees a table at all, which is the other way the index fails its reader.
#
# GFM decides where a table starts by shape: a run of consecutive lines
# beginning with `|` is a table only when the SECOND line of the run is the
# delimiter row (`|---|---|`). A paragraph dropped between two rows therefore
# does not split one table into two -- it ends the table and turns every row
# after it into a paragraph of literal pipe characters. GitHub's own markdown
# renderer and python-markdown agree, so the rows after the break are read
# by nobody.
#
# That is what happened to the "What's included" index: a paragraph about the
# tool-first test layout was inserted into the middle of the table, and the
# twelve rows below it -- `justfile`, the `docker` and `base` namespace rows,
# init.sh, upgrade.sh, the three namespace justfiles, the Dockerfile template,
# the tooling Dockerfile, the workflows directory and the shared Hadolint
# config, i.e. the entry-point half of the index -- rendered as one run of
# pipes for about three months. readme-sync kept all three translations
# faithfully broken the same way, because it fingerprints the English section
# against the translation and both sides were equally wrong.
#
# This is deliberately NOT a markdown linter. The repo has no markdown lint
# surface (shellcheck plus hadolint is the whole of it) and base#1075 closed
# on lint wall clock, so the scan is one shape question asked of the four
# README files readme-sync already holds in step -- the documents whose tables
# a maintainer navigates by -- and of nothing else in the tree.

# The four locales. A fix that lands in one is not a fix: readme-sync carries
# the English structure into the three translations, so a break in README.md
# is a break in all four and the guard has to see all four.
_readme_locales() {
  printf '%s\n' \
    /source/README.md \
    /source/doc/readme/README.zh-TW.md \
    /source/doc/readme/README.zh-CN.md \
    /source/doc/readme/README.ja.md
}

# Print `<file>:<line>: <row>` for every table run that opens without a
# delimiter row on its second line, plus any run of exactly one row (a lone
# `| ... |` line, which renders as pipes for the same reason). Fenced regions
# are skipped: inside a fence a pipe is literal text, which is the point.
_broken_table_runs() {
  awk '
    /^(```|~~~)/ { fence = !fence; next }
    fence        { next }
    /^\|/ {
      if (run == 0) { run = 1; open = FNR; open_text = $0; next }
      if (run == 1) {
        run = 2
        if ($0 !~ /^\|[[:space:]]*:?-+:?[[:space:]]*(\|[[:space:]]*:?-+:?[[:space:]]*)*\|?[[:space:]]*$/) {
          printf "%s:%d: %s\n", FILENAME, open, open_text
        }
      }
      next
    }
    {
      if (run == 1) { printf "%s:%d: %s\n", FILENAME, open, open_text }
      run = 0
    }
    END { if (run == 1) printf "%s:%d: %s\n", FILENAME, open, open_text }
  ' "$@"
}

# why: Every table in the four README files renders AS a table -- a run of
# rows whose second line is not the delimiter row is a paragraph of literal
# pipes, which is how twelve rows of the file index stopped being read
@test "README tables: no row block renders as literal pipes (base#1121)" {
  local -a _files=()
  mapfile -t _files < <(_readme_locales)
  local _f
  for _f in "${_files[@]}"; do
    assert_spec_subject "${_f}" "a README locale whose tables this spec pins"
  done

  run _broken_table_runs "${_files[@]}"
  assert_success
  assert_output ''
}

# why: Floor on the number of table runs the scan actually walks, so a
# reformat that leaves no recognisable table cannot silence the guard above
@test "README tables: the scan actually finds tables to check (base#1121)" {
  local -a _files=()
  mapfile -t _files < <(_readme_locales)
  run awk '
    /^(```|~~~)/ { fence = !fence; next }
    fence        { next }
    /^\|/ { if (run == 0) { run = 1; n++ } ; next }
    { run = 0 }
    END { print n + 0 }
  ' "${_files[@]}"
  assert_success
  [ "${output}" -ge 20 ]
}
