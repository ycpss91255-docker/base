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

@test "config_gen_admit: a manifest whose lines end in CRLF is refused as bytes (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline (LF line ends) is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  # S1d writes the manifest with LF line ends and only TAB, LF and 0x20-0x7e
  # bytes (design §2 check 2, bytes|malformed). A later step that rewrites
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

@test "config_gen_admit: a change record whose path holds a double quote (a quoted name) is refused as path (base#1465)" {
  _baseline
  # The no-fire twin: the untouched baseline is admitted.
  _run_admit
  assert_equal "${status}" 0
  assert_equal "${output}" ""
  assert_equal "${stderr}" ""
  local header
  IFS= read -r header < "${S}/m/manifest"
  # Canonical P holds no `"` or `\` (design §2 check 5; design §4 cycle 8,
  # case "quoted name"): a path git would C-quote is not one S1d's
  # record language can carry. A later step writes a record whose path,
  # under the module prefix, holds the quote characters of a quoted name;
  # the record has the one-path M shape and no empty, `.` or `..`
  # segment, so only the quoted-name rule refuses it.
  printf '%s\nM\t%s/"a".go\n' "${header}" "${MOD}" > "${S}/m/manifest"
  _run_admit
  assert_equal "${status}" 1
  assert_equal "${output}" "cg_event config_gen_manifest_stale file=manifest reason=path"
  assert_equal "${stderr}" ""
}

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
