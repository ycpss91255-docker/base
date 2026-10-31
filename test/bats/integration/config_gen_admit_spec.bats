#!/usr/bin/env bats
#
# config_gen_admit_spec.bats -- the config-gen admission checker,
# script/test/config_gen_admit.sh (base#1465, slice S1e of base#1395).
#
# why: The Dockerfile's admit stage runs this checker before any Go, to
# hold the build context to the host mutation baseline the 00-manifest step
# wrote (base#1464). Whatever reaches the build after that baseline and is
# not bound by it -- by name and by sha256 -- is compiled and judged by
# gates that never saw it in the manifest. Every row writes a real baseline
# with script/test/config_gen_mutation_targets.sh on a Git fixture, changes
# the module or the baseline the way a later step could, and runs the
# checker on the result; no row reads the checker's source.
#
#   config_gen_admit.sh <mutation> <src>
#     admitted: rc 0, nothing on stdout or stderr
#     refused:  rc 1, exactly one stdout line
#               cg_event config_gen_manifest_stale file=<path> reason=<r>
#               and nothing on stderr

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ADMIT="/source/script/test/config_gen_admit.sh"
  CGM="/source/script/test/config_gen_mutation_targets.sh"
  S="${BATS_TEST_TMPDIR}"
  MOD="dockerfile/config-gen"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount, and every git call made from it dies with
  # "not a git repository".
  cd "${S}"
  unset CONFIG_GEN_MUTATION_CONTEXT CONFIG_GEN_MUTATION_BASE
  # A fixed Git identity and no user or system config, so a developer's
  # settings cannot change what a fixture records.
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="${S}/gitconfig"
  git config --file "${GIT_CONFIG_GLOBAL}" user.name t
  git config --file "${GIT_CONFIG_GLOBAL}" user.email t@t
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" commit.gpgsign false
}

# _baseline -- ${S}/w: one commit holding ${MOD}/a.go, origin/main at it;
# ${S}/m: the baseline config_gen_mutation_targets.sh writes for it
# (context pr).
_baseline() {
  W="${S}/w"
  git init -q "${W}"
  mkdir -p "${W}/${MOD}"
  printf 'package a\n' > "${W}/${MOD}/a.go"
  git -C "${W}" add -A
  git -C "${W}" commit -q --no-verify -m base
  git -C "${W}" update-ref refs/remotes/origin/main HEAD
  CONFIG_GEN_MUTATION_CONTEXT=pr bash "${CGM}" --repo "${W}" "${S}/m" \
    || fail "config_gen_mutation_targets.sh did not write the baseline"
}

_run_admit() {
  assert_spec_subject "${ADMIT}" "the config-gen admission checker (base#1465)"
  run --separate-stderr bash "${ADMIT}" "${S}/m" "${W}/${MOD}"
}

# why: A symlink is no regular file, so no sha256 in either list binds
# what the build would follow through it; admission must refuse it by
# name. (base#1465)
@test "config_gen_admit: a symlink added to the module after the baseline is refused as not_regular (base#1465)" {
  _baseline
  # The no-fire twin: the untouched module is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A later step adds a symlink. It is no regular file, so neither list
  # can bind it by sha256, and the build would follow it to a.go.
  ln -s a.go "${W}/${MOD}/zz.go"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/zz.go reason=not_regular"
  assert_equal "${stderr}" ""
}

# why: A file the baseline lists and the module no longer holds is a
# change the gates never see; the refusal must name the absence, not a
# sha256 mismatch. (base#1465)
@test "config_gen_admit: a listed file deleted from the module after the baseline is refused as missing (base#1465)" {
  _baseline
  # The no-fire twin: the untouched module is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A later step deletes a.go, which visible.sha256 lists. Nothing is left
  # to hash, so the refusal names the absence, not a differing sha256.
  rm "${W}/${MOD}/a.go"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/a.go reason=missing"
  assert_equal "${stderr}" ""
}

# why: S1d writes only the none marker or change records after the header;
# any other line means the manifest is not the one 00-manifest wrote.
# (base#1465)
@test "config_gen_admit: a manifest body line that is neither the none marker nor a change record is refused as record (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (header, then the none marker)
  # is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A later step keeps the header and replaces the body with a line S1d
  # never writes: no `none: no-go-change`, no `<status>\t<path>` record.
  local header
  IFS= read -r header < "${S}/m/manifest"
  printf '%s\ngarbage\n' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=record"
  assert_equal "${stderr}" ""
}

# why: git gives A, D, M and T one path and a rename or copy two; a record
# with the wrong count is not a git record. (base#1465)
@test "config_gen_admit: a change record whose path count does not match its status is refused as record (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # `git diff --name-status` gives A, D, M and T one path, and a rename or
  # copy (R<score>, C<score>) two. A later step writes M with two paths.
  printf '%s\nM\t%s/a.go\t%s/b.go\n' "${header}" "${MOD}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=record"
  assert_equal "${stderr}" ""
  # And R058 with one path, the other side of the same rule.
  printf '%s\nR058\t%s/a.go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=record"
  assert_equal "${stderr}" ""
}

# why: U has the record's shape but is no status 00-manifest emits, so a
# manifest carrying it was written by something else. (base#1465)
@test "config_gen_admit: a change record whose status is not one S1d writes (U) is refused as record (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d's records carry A, D, M or T with one path, or R<score> or
  # C<score> with two (design §2 body rule). U (unmerged) has the one-path
  # shape but is none of these statuses, so a later step writing it is
  # refused.
  printf '%s\nU\t%s/a.go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=record"
  assert_equal "${stderr}" ""
}

# why: S1d writes the none marker only when there is no change record, so
# the marker beside one is a contradiction. (base#1465)
@test "config_gen_admit: a manifest body holding the none marker beside a change record is refused as none_marker (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (header, then the marker
  # alone) is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d writes the marker only when no record exists (it refuses none
  # beside a Go diff as config_gen_mutation_none_beside_diff), so the body
  # is the one marker xor records (design §2, body_empty|none_marker|record).
  # Each line here is well formed alone; together they say both "no Go
  # changed" and "a.go changed".
  printf '%s\n%s\nM\t%s/a.go\n' "${header}" 'none: no-go-change' "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=none_marker"
  assert_equal "${stderr}" ""
  # The same pair with the record first.
  printf '%s\nM\t%s/a.go\n%s\n' "${header}" "${MOD}" 'none: no-go-change' > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=none_marker"
  assert_equal "${stderr}" ""
}

# why: S1d writes the none marker at most once; a second copy is no
# manifest it wrote. (base#1465)
@test "config_gen_admit: a manifest body holding the none marker twice is refused as none_marker (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (header, then the marker
  # once) is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d writes `none: no-go-change` as the one body line when no record
  # exists (config_gen_mutation_targets.sh header: "or, with no line,
  # `none: no-go-change`"), so the body is the one marker xor records
  # (design §2, body_empty|none_marker|record). A second marker line is
  # not a manifest S1d writes.
  printf '%s\n%s\n%s\n' "${header}" 'none: no-go-change' 'none: no-go-change' > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=none_marker"
  assert_equal "${stderr}" ""
}

# why: S1d always writes the marker or at least one record, so a header
# alone is a truncated manifest. (base#1465)
@test "config_gen_admit: a manifest holding the header and no body line is refused as body_empty (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (header, then the marker
  # alone) is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d writes the header, then the change records or, with no record,
  # `none: no-go-change` (config_gen_mutation_targets.sh header: "or, with
  # no line, `none: no-go-change`"), so it never writes a header alone
  # (design §2, body_empty|none_marker|record). A later step that drops the
  # body leaves a manifest that says neither "no Go changed" nor what did.
  printf '%s\n' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=body_empty"
  assert_equal "${stderr}" ""
}

# why: 00-manifest writes no control byte but TAB and LF; a CR from a
# CRLF rewrite is a byte it never writes. (base#1465)
@test "config_gen_admit: a manifest whose lines end in CRLF is refused as bytes (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (LF line ends) is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # S1d writes the manifest with LF line ends and no control byte but TAB
  # and LF (design §2 check 2, bytes|malformed). A later step that rewrites
  # every line end as CR LF puts a 0x0d byte on each line; the byte check
  # runs before the header check, so the refusal names the byte, not the
  # header that the CR also breaks.
  local crlf
  crlf="$(sed 's/$/\r/' "${S}/m/manifest")"
  printf '%s\n' "${crlf}" > "${S}/m/manifest"
  grep -q $'\r' "${S}/m/manifest" || fail "the fixture holds no CR byte"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=bytes"
  assert_equal "${stderr}" ""
}

# why: A record path is the path git printed under the module; a ..
# segment names a file outside what it describes. (base#1465)
@test "config_gen_admit: a change record whose path holds a .. segment is refused as path (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d writes each record path as `git diff --name-status` prints it: the
  # repo-relative path under dockerfile/config-gen/, with no empty, `.` or
  # `..` segment (design §2 check 5, canonical P). A later step writes a
  # record whose path climbs out of the module through `..`; the record has
  # the one-path M shape, so only the path rule refuses it.
  printf '%s\nM\t%s/../a.go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=path"
  assert_equal "${stderr}" ""
}

# why: git never prints a . segment, so a record holding one is not git's
# spelling of a path. (base#1465)
@test "config_gen_admit: a change record whose path holds a . segment is refused as path (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # `git diff --name-status` prints a repo-relative path with no `.`
  # segment, so S1d never writes `dockerfile/config-gen/./a.go` (design §2
  # check 5, canonical P; design §4 cycle 8, case "./"). A later step that
  # writes one names a.go under a spelling no list holds; the record has
  # the one-path M shape, so only the path rule refuses it.
  printf '%s\nM\t%s/./a.go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=path"
  assert_equal "${stderr}" ""
}

# why: git never prints an empty segment, so a record holding // is not
# git's spelling of a path. (base#1465)
@test "config_gen_admit: a change record whose path holds an empty segment (//) is refused as path (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # `git diff --name-status` prints a repo-relative path with single `/`
  # separators, so S1d never writes `dockerfile/config-gen//a.go` (design
  # §2 check 5, canonical P; design §4 cycle 8, case "//"). A later step
  # that writes one names a.go under a spelling no list holds; the record
  # has the one-path M shape and no `.` or `..` segment, so only the
  # empty-segment rule refuses it.
  printf '%s\nM\t%s//a.go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=path"
  assert_equal "${stderr}" ""
}

# why: S1d diffs only the module, so every record path starts with
# dockerfile/config-gen/; a sibling directory sharing the prefix's letters
# is outside it. (base#1465)
@test "config_gen_admit: a change record whose path is outside the dockerfile/config-gen/ prefix (config-genx/) is refused as path (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d runs `git diff --name-status -M <base> -- dockerfile/config-gen/`,
  # so every record path it writes starts with the `dockerfile/config-gen/`
  # prefix (design §2 check 5, canonical P; design §4 cycle 8, case
  # "config-genx/"). A later step writes a record for a sibling directory
  # whose name only begins with `config-gen`; the record has the one-path M
  # shape and no empty, `.` or `..` segment, so only the prefix rule
  # refuses it.
  printf '%s\nM\tdockerfile/config-genx/a.go\n' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=path"
  assert_equal "${stderr}" ""
}

# why: S1d C-quotes a name holding a double quote, so a raw one in a
# record path is a spelling S1d never writes. (base#1465)
@test "config_gen_admit: a change record whose path holds a double quote (a quoted name) is refused as path (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d C-quotes a name holding a `"` (design §4 cycle 8, case "quoted
  # name"), so a raw `"` in a record path is a spelling S1d never writes.
  # A later step writes a record whose path, under the module prefix,
  # holds a raw `"`; the record has the one-path M shape and no empty,
  # `.` or `..` segment, so only the spelling rule refuses it.
  printf '%s\nM\t%s/"a".go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=path"
  assert_equal "${stderr}" ""
}

# why: A list line is a path, a TAB and a 64-hex sha256; a shorter digest
# binds nothing and must be refused as the list's line. (base#1465)
@test "config_gen_admit: a visible.sha256 line whose sha256 is not 64 hex digits (short hex) is refused as record (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # A sha line is `P\t<64hex>` (design §2 check 5; design §4 cycle 8, case
  # "short hex"). A later step cuts the last hex digit off a.go's line in
  # visible.sha256. The line is checked as a line of the list, before the
  # disk walk, so the refusal names the list, not a sha256 mismatch on
  # a.go: 63 hex digits are no sha256 at all.
  local path sha
  IFS=$'\t' read -r path sha < "${S}/m/visible.sha256"
  assert_equal "${path}" "${MOD}/a.go"
  assert_equal "${#sha}" 64
  printf '%s\t%s\n' "${path}" "${sha:0:63}" > "${S}/m/visible.sha256"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=visible.sha256 reason=record"
  assert_equal "${stderr}" ""
}

# why: 00-manifest hashes each module file once, so a repeated path is a
# list it did not write. (base#1465)
@test "config_gen_admit: a visible.sha256 path listed twice is refused as duplicate (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # 00-manifest hashes each module file once, so a path repeated in one
  # list is `duplicate` (design §2 check 5; design §4 cycle 8, case
  # "duplicate"). A later step appends a second copy of a.go's line to
  # visible.sha256. Each line is a well-formed `P\t<64 hex>` record and its
  # sha256 still matches a.go on disk, so only the repeat rule refuses it,
  # and the refusal names the list that holds the repeat.
  local line
  IFS= read -r line < "${S}/m/visible.sha256"
  assert_equal "${line%%$'\t'*}" "${MOD}/a.go"
  printf '%s\n' "${line}" >> "${S}/m/visible.sha256"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=visible.sha256 reason=duplicate"
  assert_equal "${stderr}" ""
}

# why: 00-manifest puts each module file in exactly one list, so a path in
# both is a list it did not write. (base#1465)
@test "config_gen_admit: a path listed in both visible.sha256 and ignored.sha256 is refused as dual (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # 00-manifest puts each module file in exactly one list: visible.sha256
  # for a file Git tracks or sees, ignored.sha256 for a file .gitignore
  # hides. A path in both lists is `dual` (design §2 check 5; design §4
  # cycle 8, case "dual"). A later step copies a.go's visible line into
  # ignored.sha256. Each list is well-formed, holds the path once, and its
  # sha256 still matches a.go on disk, so only the one-list rule refuses
  # it, and the refusal names the list read second, which holds the repeat.
  local line
  IFS= read -r line < "${S}/m/visible.sha256"
  assert_equal "${line%%$'\t'*}" "${MOD}/a.go"
  if grep -q "^${MOD}/a.go"$'\t' "${S}/m/ignored.sha256"; then
    fail "the baseline already lists a.go in ignored.sha256"
  fi
  printf '%s\n' "${line}" >> "${S}/m/ignored.sha256"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=ignored.sha256 reason=dual"
  assert_equal "${stderr}" ""
}

# why: A text read drops a NUL, so a line holding one would look
# untouched; only a byte check on the list refuses it. (base#1465)
@test "config_gen_admit: a visible.sha256 line holding a NUL byte is refused as bytes (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # 00-manifest writes every mutation file with no control byte but TAB
  # and LF; any other control byte is `bytes` (design §4 cycle 8, case "NUL"). A
  # later step puts a NUL between a.go's path and its TAB. Read as text,
  # the NUL is dropped and the line looks like the untouched one, so only
  # a byte check on the list itself refuses it, naming the list.
  local line
  IFS= read -r line < "${S}/m/visible.sha256"
  assert_equal "${line%%$'\t'*}" "${MOD}/a.go"
  { printf '%s\0' "${line%%$'\t'*}"; printf '\t%s\n' "${line#*$'\t'}"; } \
    > "${S}/m/visible.sha256"
  [[ "$(tr -d '\0' < "${S}/m/visible.sha256")" == "${line}" ]] \
    || fail "the fixture is not the untouched line plus one NUL"
  if ! od -An -c "${S}/m/visible.sha256" | grep -q '\\0'; then
    fail "the fixture holds no NUL byte"
  fi
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=visible.sha256 reason=bytes"
  assert_equal "${stderr}" ""
}

# _rename_baseline -- ${S}/w with ${MOD}/a.go committed and then renamed to
# ${MOD}/b.go in the work tree; ${S}/m: the baseline
# config_gen_mutation_targets.sh writes for that (context pr), whose body
# is git's own rename record, R<score>.
_rename_baseline() {
  _baseline
  git -C "${W}" mv "${MOD}/a.go" "${MOD}/b.go"
  rm -rf "${S}/m"
  CONFIG_GEN_MUTATION_CONTEXT=pr bash "${CGM}" --repo "${W}" "${S}/m" \
    || fail "config_gen_mutation_targets.sh did not write the rename baseline"
}

# why: git prints a rename or copy as R or C and a three-digit similarity
# score; any other status word is not git's record. (base#1465)
@test "config_gen_admit: a rename or copy record whose score is not three digits is refused as record (base#1465)" {
  _rename_baseline
  # The no-fire twin: S1d's own rename record is admitted. Its status is
  # git's, `R` and a three-digit similarity score: git 2.x prints R088 for
  # an 18-of-20-line rename and R100 for this one.
  local header
  IFS= read -r header < "${S}/m/manifest"
  assert_equal "$(sed -n 2p "${S}/m/manifest")" "R100"$'\t'"${MOD}/a.go"$'\t'"${MOD}/b.go"
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # The same record with any other status word after R or C: no score,
  # letters, too few or too many digits. Each keeps the two-path shape, so
  # only the score grammar refuses it.
  local st
  for st in Rgarbage R R1 R58 R0580 Cxyz C C10 R10a; do
    printf '%s\n%s\t%s/a.go\t%s/b.go\n' "${header}" "${st}" "${MOD}" "${MOD}" > "${S}/m/manifest"
    _run_admit
    assert_equal "${status}" 1
    assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=record"
    assert_equal "${stderr}" ""
  done
}

# why: Every check after the byte check reads line by line, and a line-at-
# a-time read hands an unterminated last line to no loop, so a garbage
# line without LF would pass unread. (base#1465)
@test "config_gen_admit: a manifest whose last line has no LF is refused as malformed (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline ends in LF and is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  [[ "$(tail -c1 "${S}/m/manifest" | od -An -c | tr -d ' ')" == '\n' ]] \
    || fail "the untouched manifest does not end in LF"
  local header
  IFS= read -r header < "${S}/m/manifest"
  # S1d ends every line in LF. A line with no LF after it is a line a
  # line-at-a-time read can drop, so the file is refused before any line
  # is judged: an unterminated garbage line after the marker, and the
  # untouched body with only its final LF removed.
  printf '%s\nnone: no-go-change\ngarbage' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=malformed"
  assert_equal "${stderr}" ""
  printf '%s\nnone: no-go-change' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=malformed"
  assert_equal "${stderr}" ""
  # An empty line is no line S1d writes either.
  printf '%s\n\nnone: no-go-change\n' "${header}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=malformed"
  assert_equal "${stderr}" ""
}

# why: The same framing rule holds for the lists: an unterminated last
# record is never read, and the disk walk would then blame the file it
# should have bound. (base#1465)
@test "config_gen_admit: a sha256 list whose last record has no LF is refused as malformed (base#1465)" {
  _baseline
  # The no-fire twin: the untouched lists are admitted. ignored.sha256 is
  # empty here (zero bytes, no line), which is S1d's spelling of no
  # ignored file, so an empty list is not an unterminated one.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  assert_equal "$(wc -c < "${S}/m/ignored.sha256" | tr -d ' ')" 0
  local line vis
  IFS= read -r line < "${S}/m/visible.sha256"
  vis="$(cat "${S}/m/visible.sha256")"
  # visible.sha256 with its last record's LF removed.
  printf '%s' "${vis}" > "${S}/m/visible.sha256"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=visible.sha256 reason=malformed"
  assert_equal "${stderr}" ""
  # visible.sha256 untouched, and ignored.sha256 holding one unterminated
  # record for a file no list names -- a line-at-a-time read never sees it,
  # and the disk walk would then refuse b.go as unlisted, naming the wrong
  # cause.
  printf '%s\n' "${vis}" > "${S}/m/visible.sha256"
  printf 'package a\n' > "${W}/${MOD}/b.go"
  printf '%s/b.go\t%s' "${MOD}" "$(sha256sum < "${W}/${MOD}/b.go" | cut -d' ' -f1)" > "${S}/m/ignored.sha256"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=ignored.sha256 reason=malformed"
  assert_equal "${stderr}" ""
}

# why: The refusal line is read as space-separated key=value words, so a
# value holding a space, a LF or a non-ASCII byte would be cut or end the
# line; %XX keeps it one word and unambiguous. (base#1465)
@test "config_gen_admit: an attribute value is one word, each byte outside ! to ~ and the % itself written as %XX (base#1465)" {
  _baseline
  # The no-fire twin: the untouched module is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  # The refusal line is read as space-separated key=value words, so a value
  # holding a space, a LF or a byte past 0x7e would be cut or would end the
  # line. Each name below is added after the baseline, so it is unlisted;
  # the expected value is the name with those bytes, and the %, as %XX
  # (uppercase hex), so no two names share a spelling.
  local name want
  while IFS='|' read -r name want; do
    rm -f "${W}/${MOD}"/zz*
    printf 'package a\n' > "${W}/${MOD}/$(printf '%b' "${name}")"
    _run_admit
    assert_equal "${status}" 1
    assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/${want} reason=unlisted"
    assert_equal "${stderr}" ""
  done <<'ROWS'
zz a b.go|zz%20a%20b.go
zz%20.go|zz%2520.go
zz\nb.go|zz%0Ab.go
zz\xc3\xa9.go|zz%C3%A9.go
zz\tb.go|zz%09b.go
ROWS
}

# ── each refusal through the runner ─────────────────────────────────────────
#
# The checker's line is not the contract a caller reads. The admit
# RUN prints it into the BuildKit log, config_gen_gates.sh re-emits it as
# a JSON record, and the redpath, CI and a reader all act on that record.
# So every refusal the checker has is also run the whole way: the real
# checker on the tampered fixture, its stdout placed in the log exactly as
# the admit RUN prints it (observed from a real stale-header build on
# golang:1.27.2-trixie: BuildKit's step number, `0.170`, the line; then
# the same prefix and config_gen_gate_admission_failed), a docker stub that
# prints that log and exits 1, and the real runner. Each row must give:
# rc 1; nothing on stdout (admission is the first verdict, so no ok line
# precedes it); exactly one JSON config_gen_manifest_stale record whose
# .attributes.file and .attributes.reason are the row's; one JSON
# config_gen_gate_admission_failed record with gate=admission; and no
# "unregistered log body".

# _tamper <case> -- change the fresh baseline (${S}/m, ${W}) the way <case>
# says; print the expected `<file>|<reason>`.
_tamper() {
  local header vis sum
  IFS= read -r header < "${S}/m/manifest"
  IFS= read -r vis < "${S}/m/visible.sha256"
  case "${1}" in
    manifest-absent) rm "${S}/m/manifest"; echo 'manifest|absent' ;;
    visible-absent) rm "${S}/m/visible.sha256"; echo 'visible.sha256|absent' ;;
    ignored-absent) rm "${S}/m/ignored.sha256"; echo 'ignored.sha256|absent' ;;
    manifest-bytes) printf '%s\r\nnone: no-go-change\r\n' "${header}" > "${S}/m/manifest"; echo 'manifest|bytes' ;;
    manifest-malformed) printf '%s\nnone: no-go-change' "${header}" > "${S}/m/manifest"; echo 'manifest|malformed' ;;
    manifest-header) printf '%s\nnone: no-go-change\n' "${header% context=*}" > "${S}/m/manifest"; echo 'manifest|header' ;;
    manifest-record) printf '%s\nRgarbage\t%s/a.go\t%s/b.go\n' "${header}" "${MOD}" "${MOD}" > "${S}/m/manifest"; echo 'manifest|record' ;;
    manifest-none-marker) printf '%s\nnone: no-go-change\nnone: no-go-change\n' "${header}" > "${S}/m/manifest"; echo 'manifest|none_marker' ;;
    manifest-body-empty) printf '%s\n' "${header}" > "${S}/m/manifest"; echo 'manifest|body_empty' ;;
    manifest-path) printf '%s\nM\t%s/../a.go\n' "${header}" "${MOD}" > "${S}/m/manifest"; echo 'manifest|path' ;;
    visible-bytes) printf '%s\r\n' "${vis}" > "${S}/m/visible.sha256"; echo 'visible.sha256|bytes' ;;
    visible-malformed) printf '%s' "${vis}" > "${S}/m/visible.sha256"; echo 'visible.sha256|malformed' ;;
    visible-record) printf '%s\n' "${vis:0:${#vis}-1}" > "${S}/m/visible.sha256"; echo 'visible.sha256|record' ;;
    visible-duplicate) printf '%s\n%s\n' "${vis}" "${vis}" > "${S}/m/visible.sha256"; echo 'visible.sha256|duplicate' ;;
    ignored-dual) printf '%s\n' "${vis}" > "${S}/m/ignored.sha256"; echo 'ignored.sha256|dual' ;;
    sha-mismatch) printf '// edited\n' >> "${W}/${MOD}/a.go"; echo "${MOD}/a.go|sha_mismatch" ;;
    missing) rm "${W}/${MOD}/a.go"; echo "${MOD}/a.go|missing" ;;
    not-regular) ln -s a.go "${W}/${MOD}/zz.go"; echo "${MOD}/zz.go|not_regular" ;;
    unlisted) printf 'package a\n' > "${W}/${MOD}/zz.go"; echo "${MOD}/zz.go|unlisted" ;;
    unlisted-space) printf 'package a\n' > "${W}/${MOD}/a b.go"; echo "${MOD}/a%20b.go|unlisted" ;;
    *) fail "_tamper: no case ${1}" ;;
  esac
}

# _admit_log <checker stdout> -- the admit RUN's plain-progress lines for a
# refusal, as BuildKit printed them in the observed build.
_admit_log() {
  local line
  printf '#10 [admit 1/1] RUN --mount=type=bind,from=mutation,target=/mutation     --mount=type=bind,target=/src     e=manifest_missing; g=admission;\n'
  while IFS= read -r line; do
    printf '#10 0.170 %s\n' "${line}"
  done <<<"${1}"
  printf '#10 0.170 config_gen_gate_admission_failed\n'
  printf '#10 ERROR: process "/bin/bash -euo pipefail -c e=manifest_missing; g=admission;" did not complete successfully: exit code: 1\n'
}

# _runner_root -- ${S}/root, a tree the runner accepts, and a docker stub
# first on PATH whose `build --target test` prints ${S}/build.log on
# stderr and exits 1.
_runner_root() {
  mkdir -p "${S}/root/dockerfile/config-gen" "${S}/bin"
  printf 'FROM scratch\n' > "${S}/root/dockerfile/Dockerfile.config-gen"
  cat > "${S}/bin/docker" <<STUB
#!$(command -v bash)
cat "${S}/build.log" >&2
exit 1
STUB
  chmod +x "${S}/bin/docker"
}

# why: The checker's line is not the contract a caller reads: the admit
# RUN prints it into the BuildKit log and config_gen_gates.sh re-emits it
# as JSON, which the redpath, CI and a reader act on. So every refusal is
# also run through the real runner, from a log shaped as a real stale-
# header build printed it. (base#1465)
@test "config_gen_admit: every refusal reaches the runner as rc 1, no stdout, and JSON stale and admission records naming its file and reason (base#1465)" {
  assert_spec_subject "${ADMIT}" "the config-gen admission checker (base#1465)"
  local runner="/source/script/test/config_gen_gates.sh"
  _runner_root
  local c want got
  for c in manifest-absent visible-absent ignored-absent manifest-bytes \
    manifest-malformed manifest-header manifest-record manifest-none-marker \
    manifest-body-empty manifest-path visible-bytes visible-malformed \
    visible-record visible-duplicate ignored-dual sha-mismatch missing \
    not-regular unlisted unlisted-space; do
    rm -rf "${S}/w" "${S}/m"
    _baseline
    want="$(_tamper "${c}")"
    run --separate-stderr bash "${ADMIT}" "${S}/m" "${W}/${MOD}"
    assert_equal "${c}:${status}" "${c}:1"
    assert_equal "${c}:${stderr}" "${c}:"
    _admit_log "${output}" > "${S}/build.log"
    run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      bash "${runner}" --root "${S}/root"
    assert_equal "${c}:${status}" "${c}:1"
    assert_equal "${c}:${output}" "${c}:"
    [[ "${stderr}" != *"unregistered log body"* ]] || fail "${c}: unregistered log body: ${stderr}"
    got="$(jq -rR 'fromjson? | select(.body == "config_gen_manifest_stale")
      | .attributes.file + "|" + .attributes.reason' <<<"${stderr}")"
    assert_equal "${c}:${got}" "${c}:${want}"
    got="$(jq -rR 'fromjson? | select(.body == "config_gen_gate_admission_failed")
      | .attributes.gate + "|" + .attributes.status' <<<"${stderr}")"
    assert_equal "${c}:${got}" "${c}:admission|1"
  done
}

# ── the producer's path spelling ─────────────────────────────────────────────
#
# S1d spells every path one way in all three files (base#1464): as is --
# UTF-8 or any other byte past 0x7e included -- unless it holds a control
# byte, a double quote or a backslash, and then C-quoted as git does with
# core.quotePath=false. Admission reads that spelling back to the name on
# disk; it must neither refuse a name S1d keeps raw nor read a quoted
# spelling as a literal path.

# _names_baseline -- ${S}/w: a commit holding ${MOD}/a.go, ${MOD}/q"t.go
# and ${MOD}/é1.go; then, in the work tree, q"t.go edited, é1.go renamed
# to "é2.go, and untracked café.go, b\s.go, t<TAB>b.go, n<LF>l.go,
# d<DEL>.go and x<0xff>.go; ${S}/m: the baseline S1d writes for that.
_names_baseline() {
  W="${S}/w"
  git init -q "${W}"
  mkdir -p "${W}/${MOD}"
  printf 'package a\n' > "${W}/${MOD}/a.go"
  printf 'package a // q\n' > "${W}/${MOD}/q\"t.go"
  printf 'package a // e1\n' > "${W}/${MOD}/é1.go"
  git -C "${W}" add -A
  git -C "${W}" commit -q --no-verify -m base
  git -C "${W}" update-ref refs/remotes/origin/main HEAD
  printf '// edited\n' >> "${W}/${MOD}/q\"t.go"
  git -C "${W}" mv "${MOD}/é1.go" "${MOD}/\"é2.go"
  local n
  for n in 'café.go' 'b\s.go' $'t\tb.go' $'n\nl.go' $'d\x7f.go' $'x\xff.go'; do
    printf 'package a // %s\n' "${#n}" > "${W}/${MOD}/${n}"
  done
  CONFIG_GEN_MUTATION_CONTEXT=pr bash "${CGM}" --repo "${W}" "${S}/m" \
    || fail "config_gen_mutation_targets.sh did not write the names baseline"
}

# why: S1d keeps a UTF-8 name raw and C-quotes a name holding a quote, a
# backslash or a control byte; an unchanged module whose baseline holds
# both spellings, in the manifest and in visible.sha256, must be admitted.
# A checker that refuses a byte past 0x7e, or reads a quoted spelling as a
# literal path, refuses it as bytes, path, missing or unlisted. (base#1465)
@test "config_gen_admit: an unchanged baseline holding names S1d keeps raw (UTF-8, 0xff) or C-quotes (quote, backslash, TAB, LF, DEL) is admitted (base#1465)" {
  _names_baseline
  # The fixture holds each spelling, as S1d wrote it, in the manifest and
  # in visible.sha256; otherwise the row proves nothing about it.
  local sp
  for sp in "M"$'\t'"\"${MOD}/q\\\"t.go\"" \
    "R100"$'\t'"${MOD}/é1.go"$'\t'"\"${MOD}/\\\"é2.go\"" \
    "A"$'\t'"${MOD}/café.go" "A"$'\t'"\"${MOD}/b\\\\s.go\"" \
    "A"$'\t'"\"${MOD}/t\\tb.go\"" "A"$'\t'"\"${MOD}/n\\nl.go\"" \
    "A"$'\t'"\"${MOD}/d\\177.go\"" "A"$'\t'"${MOD}/x"$'\xff'".go"; do
    grep -qxF -- "${sp}" "${S}/m/manifest" || fail "manifest lacks: ${sp}"
    grep -qF -- "${sp##*$'\t'}"$'\t' "${S}/m/visible.sha256" \
      || fail "visible.sha256 lacks: ${sp##*$'\t'}"
  done
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
}

# why: The name a list line binds is the one its spelling decodes to; an
# edit or a deletion of a raw-kept or C-quoted name after the baseline is
# refused naming that file, not the spelling and not another reason.
# (base#1465)
@test "config_gen_admit: a raw-kept or C-quoted name edited or deleted after the baseline is refused as sha_mismatch or missing naming the file (base#1465)" {
  _names_baseline
  # The no-fire twin: the untouched module is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  local name want keep
  while IFS='|' read -r name want; do
    name="$(printf '%b' "${name}")"
    keep="$(cat "${W}/${MOD}/${name}"; printf x)"
    printf '// edited\n' >> "${W}/${MOD}/${name}"
    _run_admit
    assert_equal "${name}:${status}" "${name}:1"
    assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/${want} reason=sha_mismatch"
    rm -- "${W}/${MOD}/${name}"
    _run_admit
    assert_equal "${name}:${status}" "${name}:1"
    assert_equal "${output}" "cg_event config_gen_manifest_stale file=${MOD}/${want} reason=missing"
    printf '%s' "${keep%x}" > "${W}/${MOD}/${name}"
    _run_admit
    assert_equal "${name}:${status}" "${name}:0"
  done <<'ROWS'
caf\xc3\xa9.go|caf%C3%A9.go
x\xff.go|x%FF.go
q"t.go|q"t.go
b\\s.go|b\s.go
t\tb.go|t%09b.go
n\nl.go|n%0Al.go
d\x7f.go|d%7F.go
"\xc3\xa92.go|"%C3%A92.go
ROWS
}

# why: S1d spells each name one way; a list line in any other spelling of
# the same name -- quoted when S1d keeps it raw, an octal escape where S1d
# writes a named one, a raw byte S1d quotes -- is not S1d's line.
# (base#1465)
@test "config_gen_admit: a list or manifest path in a spelling S1d does not write is refused as record or path (base#1465)" {
  _names_baseline
  _run_admit
  assert_equal "${status}" 0
  local vis man from to file reason LC_ALL=C
  vis="$(cat "${S}/m/visible.sha256"; printf x)"
  man="$(cat "${S}/m/manifest"; printf x)"
  while IFS='|' read -r file from to reason; do
    from="$(printf '%b' "${from}")"
    to="$(printf '%b' "${to}")"
    printf '%s' "${vis%x}" > "${S}/m/visible.sha256"
    printf '%s' "${man%x}" > "${S}/m/manifest"
    local t="${S}/m/${file}" body
    body="$(cat "${t}"; printf x)"
    [[ "${body}" == *"${from}"* ]] || fail "${file} lacks ${from}"
    body="${body%x}"
    printf '%s' "${body/"${from}"/"${to}"}" > "${t}"
    _run_admit
    assert_equal "${from}:${status}" "${from}:1"
    assert_equal "${from}:${output}" "${from}:cg_event config_gen_manifest_stale file=${file} reason=${reason}"
  done <<'ROWS'
visible.sha256|dockerfile/config-gen/caf\xc3\xa9.go\t|"dockerfile/config-gen/caf\xc3\xa9.go"\t|record
visible.sha256|"dockerfile/config-gen/t\\tb.go"|"dockerfile/config-gen/t\\011b.go"|record
visible.sha256|"dockerfile/config-gen/q\\"t.go"|dockerfile/config-gen/q"t.go|record
visible.sha256|"dockerfile/config-gen/d\\177.go"|"dockerfile/config-gen/d\x7f.go"|bytes
visible.sha256|"dockerfile/config-gen/b\\\\s.go"|"dockerfile/config-gen/b\\s.go"|record
manifest|"dockerfile/config-gen/n\\nl.go"|"dockerfile/config-gen/n\\012l.go"|path
manifest|"dockerfile/config-gen/q\\"t.go"|"dockerfile/config-gen/q\\042t.go"|path
ROWS
}

# why: S1d's quoting rule and admission's reading of it must agree on
# every byte, not only on the few names a fixture picks: a byte the two
# class differently (quoted by one, raw to the other) refuses an unchanged
# module. One untracked file per byte 0x01-0xff but `/` runs every byte
# through both. (base#1465)
@test "config_gen_admit: an unchanged baseline holding one untracked name per byte 0x01-0xff but / is admitted (base#1465)" {
  _baseline
  local i b
  for ((i = 1; i < 256; i++)); do
    ((i != 0x2f)) || continue
    printf -v b '%03o' "${i}"
    printf -v b "\\${b}"
    printf 'package a // %d\n' "${i}" > "${W}/${MOD}/b${b}.go"
  done
  rm -rf "${S}/m"
  CONFIG_GEN_MUTATION_CONTEXT=pr bash "${CGM}" --repo "${W}" "${S}/m" \
    || fail "config_gen_mutation_targets.sh did not write the baseline"
  assert_equal "$(wc -l < "${S}/m/visible.sha256")" 255
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
}
