#!/usr/bin/env bats
#
# kcov_merge_union_spec.bats -- `kcov --merge` unions its inputs.
#
# why: the in-job parallel coverage mode (base#726) runs the suite as N
# independent kcov processes over disjoint slices and merges their reports
# with `kcov --merge`. The merged report is then read as the PROJECT's
# figure -- the release badge publishes it, and `just release
# coverage-badge` accepts it because the run stamps `scope=full`.
#
# Everything about that rests on one property of a tool this repo does not
# own: a line covered in ONE slice and not another must be covered in the
# merge. Union is the only correct reading. A sum inflates a shared
# library's lines with the slice count; an intersection or a
# last-writer-wins would report a whole-suite run as a fraction of itself.
# base#730 closed exactly that class of defect on the OTHER merge -- the
# coverage-gate's per-line union over the CI matrix's shard artifacts --
# and that fix says nothing about this one, because this one is kcov's.
#
# The unit spec for the mode (test/bats/unit/coverage_local_spec.bats)
# mocks kcov, which is right for pinning what the runner CALLS and wrong
# for pinning what kcov DOES. This spec runs the real binary from the
# test-tools image over a subject with two disjoint branches, so a kcov
# upgrade that changed the merge is a red test here rather than a quiet
# drop in the published rate.
#
# Deliberately NOT asserted: hit COUNTS. Cobertura carries a per-line
# `hits`, and whether a merge adds them or takes the maximum is kcov's
# business -- nothing in this repo reads the number, only `hits > 0`.
# Asserting the arithmetic would pin an implementation detail and fail on
# a change that costs this repo nothing.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  SUBJ_DIR="${BATS_TEST_TMPDIR}/subject"
  mkdir -p "${SUBJ_DIR}"
  _write_subject
}

# _write_subject -- a script whose two branches share nothing. Each slice
# below runs exactly one of them, so the two coverage sets are disjoint on
# the branch bodies and identical everywhere else; that is what makes the
# union assertion non-vacuous.
_write_subject() {
  cat > "${SUBJ_DIR}/subject.sh" << 'EOF'
#!/usr/bin/env bash
branch_a() {
  echo "this line runs only in slice A"
}
branch_b() {
  echo "this line runs only in slice B"
}
case "${1:-}" in
  a) branch_a ;;
  b) branch_b ;;
esac
EOF
  chmod +x "${SUBJ_DIR}/subject.sh"
}

# _slice <outdir> <arg> -- one kcov process over the subject, the shape
# _coverage_parallel_launch uses: `kcov --include-path=<root> <out> <cmd>`.
#
# The command is the SCRIPT, not `bash <script>`. kcov picks its engine off
# the file it is asked to run: handed the script it reads the shebang and
# uses the bash engine, handed the `bash` ELF it uses the ptrace engine and
# reports an empty tree with a zero exit status -- which is how this spec
# first "passed" kcov and measured nothing. The production runner is in the
# first shape too: it traces `bats`, itself a bash script.
_slice() {
  kcov --include-path="${SUBJ_DIR}" "${1}" \
    "${SUBJ_DIR}/subject.sh" "${2}" > "${1}.log" 2>&1
}

# _report <outdir> -- the cobertura report kcov left, found rather than
# assumed: kcov names the per-run directory after the traced binary and
# only the merged view is at a fixed path.
_report() {
  find "${1}" -type f -name cobertura.xml | LC_ALL=C sort | head -n 1
}

# _lines <outdir> <covered|valid> -- the sorted line numbers of the subject
# in that report. `valid` is every instrumented line; `covered` is the
# subset with a non-zero hit count.
_lines() {
  local _rep
  _rep="$(_report "${1}")"
  [[ -n "${_rep}" ]] || return 1
  awk -v want="${2}" '
    match($0, /<line number="[0-9]+" hits="[0-9]+"/) {
      s = substr($0, RSTART, RLENGTH)
      n = s; sub(/.*number="/, "", n); sub(/".*/, "", n)
      h = s; sub(/.*hits="/, "", h); sub(/".*/, "", h)
      if (want == "valid" || h + 0 > 0) { print n + 0 }
    }
  ' "${_rep}" | LC_ALL=C sort -n -u
}

# _union <a> <b> -- the sorted union of two newline-separated line lists.
_union() {
  printf '%s\n%s\n' "${1}" "${2}" | grep -v '^$' | LC_ALL=C sort -n -u
}

# why: the guard that keeps every other case in this file from being
# vacuous. If both slices covered the same lines, a merge that dropped one
# input entirely -- or that intersected rather than unioned -- would still
# produce the right answer, and the union assertion would prove nothing.
# So: the two slices must genuinely disagree, in both directions.
@test "kcov: two slices of one subject cover different lines (#726)" {
  _slice "${BATS_TEST_TMPDIR}/a" a
  _slice "${BATS_TEST_TMPDIR}/b" b
  local _a _b
  _a="$(_lines "${BATS_TEST_TMPDIR}/a" covered)"
  _b="$(_lines "${BATS_TEST_TMPDIR}/b" covered)"
  [ -n "${_a}" ]
  [ -n "${_b}" ]
  # Each slice has at least one line the other does not. Written to files
  # and differenced with `grep -Fxv -f`: no pipeline whose exit status
  # depends on two processes' scheduling, and no `bash -c`, whose empty
  # BASH_SOURCE this repo has already been bitten by under kcov.
  printf '%s\n' "${_a}" > "${BATS_TEST_TMPDIR}/a.lines"
  printf '%s\n' "${_b}" > "${BATS_TEST_TMPDIR}/b.lines"
  local _only_a _only_b
  _only_a="$(grep -Fxv -f "${BATS_TEST_TMPDIR}/b.lines" "${BATS_TEST_TMPDIR}/a.lines" || true)"
  _only_b="$(grep -Fxv -f "${BATS_TEST_TMPDIR}/a.lines" "${BATS_TEST_TMPDIR}/b.lines" || true)"
  [ -n "${_only_a}" ]
  [ -n "${_only_b}" ]
}

# why: the property the whole mode rests on. A line covered in ONE slice is
# covered in the merge -- exactly the union, neither more nor less. Asserted
# as set EQUALITY rather than as a count or a rate, because a merge that
# lost one slice's lines and gained an equal number of another's would match
# on any percentage and be wrong.
@test "kcov --merge: the merged covered set is the UNION of the slices' (#726)" {
  _slice "${BATS_TEST_TMPDIR}/a" a
  _slice "${BATS_TEST_TMPDIR}/b" b
  run kcov --merge "${BATS_TEST_TMPDIR}/m" \
    "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
  [ "${status}" -eq 0 ]

  local _merged _expected
  _merged="$(_lines "${BATS_TEST_TMPDIR}/m" covered)"
  _expected="$(_union "$(_lines "${BATS_TEST_TMPDIR}/a" covered)" \
                      "$(_lines "${BATS_TEST_TMPDIR}/b" covered)")"
  [ -n "${_merged}" ]
  [ "${_merged}" = "${_expected}" ]
}

# why: the denominator half, and the one a SUM would break first. Each
# slice's kcov runs with the same `--include-path`, so both reports carry
# the whole instrumented file; adding their `lines-valid` would count every
# shared line once per slice and drive the rate down as the slice count
# rose. That is base#730's defect, on the other merge. The merged
# denominator must be the union -- here, identical to either slice's.
@test "kcov --merge: the merged instrumented set is the union, not a sum (#726)" {
  _slice "${BATS_TEST_TMPDIR}/a" a
  _slice "${BATS_TEST_TMPDIR}/b" b
  run kcov --merge "${BATS_TEST_TMPDIR}/m" \
    "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
  [ "${status}" -eq 0 ]

  local _merged _expected _n_merged _n_a
  _merged="$(_lines "${BATS_TEST_TMPDIR}/m" valid)"
  _expected="$(_union "$(_lines "${BATS_TEST_TMPDIR}/a" valid)" \
                      "$(_lines "${BATS_TEST_TMPDIR}/b" valid)")"
  [ "${_merged}" = "${_expected}" ]
  # And the sum is a DIFFERENT number, so the assertion above discriminates:
  # two reports of one file would sum to twice the file's instrumented lines.
  _n_merged="$(printf '%s\n' "${_merged}" | grep -c .)"
  _n_a="$(_lines "${BATS_TEST_TMPDIR}/a" valid | grep -c .)"
  [ "${_n_merged}" -eq "${_n_a}" ]
  [ "${_n_merged}" -lt $(( _n_a * 2 )) ]
}
