#!/usr/bin/env bats
#
# config_gen_mutation_targets_spec.bats -- the host-side mutation baseline of
# the config generator (base#1464, slice S1d of base#1395).
#
# why: The build context has no Git history, and on main after a merge
# origin/main equals HEAD, so "which Go files changed" can only be decided on
# the host, from an explicit execution context. Each obvious choice of base
# is wrong in some checkout shape: HEAD^1 drops commits on a stale local
# main, merge-base gives HEAD (an empty diff, a false "none") on main after a
# merge, and in a --depth 1 clone merge-base exits 0 with HEAD. Every row
# below runs script/test/config_gen_mutation_targets.sh on a real Git
# fixture; no row reads the script's source.
#
#   CONFIG_GEN_MUTATION_CONTEXT  pr (default when unset) | main-push
#   CONFIG_GEN_MUTATION_BASE     optional override, verified + ancestor
#   [--repo <dir>] <out-dir>     writes manifest, visible.sha256,
#                                ignored.sha256; replaces <out-dir> whole
#
# Every refusal row holds the five points and names the script as the file
# that logged it (_assert_cgm_refusal). Every refusal row that names an
# existing <out-dir> -- a directory, a file or a symlink -- snapshots it
# first (_snapshot: entries, types, modes and sha256 of every file) and
# checks the snapshot is unchanged; the two usage rows that name no
# existing <out-dir> (missing_out, repo_value) have nothing to snapshot.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  CGM="/source/script/test/config_gen_mutation_targets.sh"
  S="${BATS_TEST_TMPDIR}"
  MOD="dockerfile/config-gen"
  mkdir -p "${S}/bin"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount, and every git call made from it dies with
  # "not a git repository".
  cd "${S}"
  unset CONFIG_GEN_MUTATION_CONTEXT CONFIG_GEN_MUTATION_BASE MV_FAIL_AT
  # A fixed Git identity and no user or system config, so a developer's
  # diff.renames, hooks or gpgsign cannot change what a fixture records.
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="${S}/gitconfig"
  git config --file "${GIT_CONFIG_GLOBAL}" user.name t
  git config --file "${GIT_CONFIG_GLOBAL}" user.email t@t
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" commit.gpgsign false
  git config --file "${GIT_CONFIG_GLOBAL}" protocol.file.allow always
}

# ── fixtures ────────────────────────────────────────────────────────────────

# _commit <repo> <msg> <path>... -- write "<path> <msg>" into each <path>
# (creating directories), stage everything and commit; prints the commit id.
_commit() {
  local _r="${1}" _m="${2}" _p
  shift 2
  for _p in "$@"; do
    mkdir -p "$(dirname -- "${_r}/${_p}")"
    printf '%s %s\n' "${_p}" "${_m}" > "${_r}/${_p}"
  done
  git -C "${_r}" add -A
  git -C "${_r}" commit -q --no-verify -m "${_m}"
  git -C "${_r}" rev-parse HEAD
}

# _rev <repo> <rev> -- the full commit id of <rev>.
_rev() {
  git -C "${1}" rev-parse --verify "${2}^{commit}"
}

# _stale_main -- ${S}/w: main at m0 (a.go), feat branched from m0 with f1
# (b.go) and f2 (c.go), checked out; origin/main moved on from m0 to m1
# (other.go), local main left at m0. Sets M0 M1 F1 F2.
_stale_main() {
  W="${S}/w"
  git init -q "${W}"
  M0="$(_commit "${W}" m0 "${MOD}/a.go" README.md)"
  git -C "${W}" checkout -q -b side
  M1="$(_commit "${W}" m1 "${MOD}/other.go")"
  git -C "${W}" update-ref refs/remotes/origin/main "${M1}"
  git -C "${W}" checkout -q -b feat "${M0}"
  git -C "${W}" branch -q -D side
  F1="$(_commit "${W}" f1 "${MOD}/b.go")"
  F2="$(_commit "${W}" f2 "${MOD}/c.go")"
}

# _seed_out <dir> -- a previous output at <dir>: manifest "old" plus a stale
# file, the directory at mode 750.
_seed_out() {
  mkdir -p "${1}"
  printf 'old\n' > "${1}/manifest"
  printf 'stale\n' > "${1}/stale"
  chmod 750 "${1}"
}

# _snapshot <dir> -- every entry of <dir> (itself included) with its type
# and mode, then the sha256 of every file; the bytes, file list and mode a
# refusal must leave unchanged. busybox find in the test-tools image has
# no -printf, so each entry goes through stat.
_snapshot() {
  (cd "${1}" && find . | LC_ALL=C sort | while IFS= read -r _e; do
      stat -c '%n %F %a' "${_e}"
    done \
    && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2)
}

# _no_scratch_left <parent> -- fail when the script left a .cgm-* entry.
_no_scratch_left() {
  local _left
  _left="$(cd "${1}" && find . -maxdepth 1 -name '.cgm-*')"
  [[ -z "${_left}" ]] || fail "scratch left beside the output: ${_left}"
}

# _run_cgm [args...] -- the script with ${S}/bin first on PATH, JSON logging,
# stdout and stderr judged apart.
_run_cgm() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json bash "${CGM}" "$@"
}

# _assert_cgm_refusal <status> <id> [<attribution>...] -- assert_refusal's
# five points, plus code.filepath naming this script: a refusal logged by
# another file (a sourced helper, the logger itself) is not this script's.
_assert_cgm_refusal() {
  local _st="${1}" _id="${2}"
  shift 2
  assert_refusal "${_st}" "${_id}" "$@" "code.filepath=${CGM}"
}

# _manifest_want <header> [<line>...] -- the manifest bytes expected.
_manifest_want() {
  printf '%s\n' "$@"
}

# _assert_manifest <out> <header> [<line>...]
_assert_manifest() {
  local _out="${1}"
  shift
  [[ -f "${_out}/manifest" ]] || fail "no manifest at ${_out}: stderr: ${stderr:-}"
  assert_equal "$(cat "${_out}/manifest")" "$(_manifest_want "$@")"
}

# ── base selection ──────────────────────────────────────────────────────────

# why: The first red of the slice. On a stale local main HEAD^1 drops b.go
# and a two-dot diff against origin/main adds origin's other.go as a delete;
# only the merge-base names exactly the PR's two files.
@test "pr: on a stale local main the base is the merge-base, not HEAD^1 (base#1464)" {
  _stale_main
  CONFIG_GEN_MUTATION_CONTEXT=pr _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M0} head=${F2} dirty=no context=pr" \
    "A	${MOD}/b.go" "A	${MOD}/c.go"
}

# why: Local runs and the pre-PR mirror pass no context; unset must mean pr.
@test "context: unset defaults to pr (base#1464)" {
  _stale_main
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M0} head=${F2} dirty=no context=pr" \
    "A	${MOD}/b.go" "A	${MOD}/c.go"
}

# why: GitHub checks a PR out as a detached merge of its head into
# origin/main; the base is origin/main's tip, not the head's parent.
@test "pr: on a detached PR merge checkout the base is origin/main's tip (base#1464)" {
  _stale_main
  git -C "${W}" checkout -q --detach "${M1}"
  git -C "${W}" merge -q --no-ff --no-edit "${F2}"
  local _merge
  _merge="$(_rev "${W}" HEAD)"
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M1} head=${_merge} dirty=no context=pr" \
    "A	${MOD}/b.go" "A	${MOD}/c.go"
}

# why: After a merge to main origin/main equals HEAD, so the pr rule would
# give an empty diff; main-push takes HEAD^1, which lists the merged files.
@test "main-push: on main after a --no-ff merge the base is HEAD^1 (base#1464)" {
  _stale_main
  git -C "${W}" checkout -q -B main "${M1}"
  git -C "${W}" merge -q --no-ff --no-edit feat
  local _merge
  _merge="$(_rev "${W}" HEAD)"
  git -C "${W}" update-ref refs/remotes/origin/main "${_merge}"
  CONFIG_GEN_MUTATION_CONTEXT=main-push _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M1} head=${_merge} dirty=no context=main-push" \
    "A	${MOD}/b.go" "A	${MOD}/c.go"
}

# why: GitHub merges this repo by squash, so the main-push run that matters
# most sees a single-parent commit; HEAD^1 there must still list every
# file the squash carried.
@test "main-push: on main after a squash commit the base is HEAD^1 (base#1464)" {
  _stale_main
  git -C "${W}" checkout -q -B main "${M1}"
  local _sq
  _sq="$(_commit "${W}" squash "${MOD}/b.go" "${MOD}/c.go")"
  git -C "${W}" update-ref refs/remotes/origin/main "${_sq}"
  CONFIG_GEN_MUTATION_CONTEXT=main-push _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M1} head=${_sq} dirty=no context=main-push" \
    "A	${MOD}/b.go" "A	${MOD}/c.go"
}

# why: The override is the escape hatch for a checkout shape neither rule
# fits; once verified it must win over the context rule, or it is inert.
@test "override: a verified ancestor CONFIG_GEN_MUTATION_BASE is the base (base#1464)" {
  _stale_main
  CONFIG_GEN_MUTATION_BASE="${F1}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F1} head=${F2} dirty=no context=pr" \
    "A	${MOD}/c.go"
}

# ── base refusals: never "none" ─────────────────────────────────────────────

# why: Without origin/main the pr rule has nothing to diff against; falling
# back to HEAD would give an empty diff and a false "none".
@test "base: a missing origin/main is refused as base_unreachable, rc 1 (base#1464)" {
  _stale_main
  git -C "${W}" update-ref -d refs/remotes/origin/main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=origin/main reason=missing
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  _no_scratch_left "${S}"
}

# why: In a --depth 1 clone merge-base exits 0 and prints HEAD, which would
# be a false "none"; the shallow clone is refused by name before any rule.
@test "base: a --depth 1 clone is refused by name, in either context (base#1464)" {
  _stale_main
  git -C "${W}" checkout -q -B main "${F2}"
  git clone -q --depth 1 "file://${W}" "${S}/c"
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --repo "${S}/c" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=origin/main reason=shallow
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  CONFIG_GEN_MUTATION_CONTEXT=main-push _run_cgm --repo "${S}/c" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=HEAD^1 reason=shallow
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  _no_scratch_left "${S}"
}

# why: A root commit has no HEAD^1; diffing against nothing would read as
# "none" instead of naming the missing parent.
@test "base: main-push on a root commit (no HEAD^1) is refused, rc 1 (base#1464)" {
  W="${S}/w"
  git init -q "${W}"
  local _root
  _root="$(_commit "${W}" root "${MOD}/a.go")"
  git -C "${W}" update-ref refs/remotes/origin/main "${_root}"
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  CONFIG_GEN_MUTATION_CONTEXT=main-push _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=HEAD^1 reason=missing
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: A mistyped override must not silently fall back to the context rule;
# the caller asked for a specific base and gets a refusal naming it.
@test "override: a CONFIG_GEN_MUTATION_BASE that is not a commit is refused, rc 1 (base#1464)" {
  _stale_main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  CONFIG_GEN_MUTATION_BASE=deadbeef _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=deadbeef reason=missing
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: A base off HEAD's history would diff in unrelated changes (origin's
# other.go here) as if the PR had made them.
@test "override: a CONFIG_GEN_MUTATION_BASE that is not an ancestor of HEAD is refused, rc 1 (base#1464)" {
  _stale_main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  CONFIG_GEN_MUTATION_BASE="${M1}" _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable "ref=${M1}" reason=not_ancestor
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: A repository with no commit has no HEAD to diff against; it is
# refused by name before any base rule runs, in either context.
@test "base: a repository with no commit (unborn HEAD) is refused as ref=HEAD, rc 1 (base#1464)" {
  W="${S}/w"
  git init -q "${W}"
  mkdir -p "${W}/${MOD}"
  printf 'new\n' > "${W}/${MOD}/a.go"
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=HEAD reason=missing
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  CONFIG_GEN_MUTATION_CONTEXT=main-push _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=HEAD reason=missing
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  _no_scratch_left "${S}"
}

# why: origin/main from an unrelated history (a re-created remote, a wrong
# fetch) has no merge-base with HEAD; merge-base exits 1 and printing an
# empty base would diff against nothing.
@test "base: an origin/main with no common ancestor is refused as no_merge_base, rc 1 (base#1464)" {
  _stale_main
  git -C "${W}" checkout -q --orphan other
  git -C "${W}" rm -rq --cached .
  local _o
  _o="$(_commit "${W}" orphan unrelated.txt)"
  git -C "${W}" checkout -q -f feat
  git -C "${W}" update-ref refs/remotes/origin/main "${_o}"
  git -C "${W}" branch -q -D other
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_base_unreachable ref=origin/main reason=no_merge_base
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  _no_scratch_left "${S}"
}

# ── context, repository and usage refusals ──────────────────────────────────

# why: A misspelled context in a workflow must fail loudly, not pick a rule;
# each rule gives a wrong base in the other's checkout shape.
@test "context: a value other than pr or main-push is refused, rc 2 (base#1464)" {
  _stale_main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  CONFIG_GEN_MUTATION_CONTEXT=push _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 2 config_gen_mutation_context_invalid context=push
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: Only an unset variable defaults; an empty one is a caller that meant
# to set something and did not, which ${X:-pr} would hide.
@test "context: an empty CONFIG_GEN_MUTATION_CONTEXT is refused, not defaulted (base#1464)" {
  _stale_main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  CONFIG_GEN_MUTATION_CONTEXT= _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 2 config_gen_mutation_context_invalid context=
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: Every base rule needs Git history; a non-repository is a caller error
# (rc 2), distinct from an unreachable base (rc 1).
@test "repo: a directory that is not a Git repository is refused, rc 2 (base#1464)" {
  mkdir -p "${S}/plain"
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --repo "${S}/plain" "${S}/out"
  _assert_cgm_refusal 2 config_gen_mutation_repo_invalid "repo=${S}/plain"
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: Without an <out-dir> there is nowhere to publish; refusing by name
# keeps a caller from mistaking an empty run for a clean one.
@test "usage: no <out-dir> is refused as missing_out, rc 2 (base#1464)" {
  _stale_main
  _run_cgm --repo "${W}"
  _assert_cgm_refusal 2 config_gen_mutation_usage_invalid reason=missing_out
}

# why: An extra argument is a caller that meant something else; it must be
# refused before anything is created at either path.
@test "usage: a second positional argument is refused as extra_arg, rc 2 (base#1464)" {
  _stale_main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --repo "${W}" "${S}/out" "${S}/out2"
  _assert_cgm_refusal 2 config_gen_mutation_usage_invalid reason=extra_arg
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  [[ ! -e "${S}/out2" ]] || fail "the extra argument was created"
}

# why: A bare --repo must not consume the <out-dir> as the repository or
# fall back to the current directory.
@test "usage: --repo without a value is refused as repo_value, rc 2 (base#1464)" {
  _run_cgm --repo
  _assert_cgm_refusal 2 config_gen_mutation_usage_invalid reason=repo_value
}

# why: A misspelled option must not be taken as the <out-dir>, which would
# then be replaced whole.
@test "usage: an unknown option is refused as unknown_option, rc 2 (base#1464)" {
  _stale_main
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  _run_cgm --bogus --repo "${W}" "${S}/out"
  _assert_cgm_refusal 2 config_gen_mutation_usage_invalid reason=unknown_option
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
}

# why: Publication replaces <out-dir> whole; through a file or a symlink that
# would destroy something the script never created, so both are refused.
@test "usage: an <out-dir> that is a file or a symlink is refused as out_not_dir, rc 2 (base#1464)" {
  _stale_main
  # No trailing newline and mode 640: a rewrite, a truncation or a chmod
  # each changes the snapshot of the directory holding the file.
  mkdir -p "${S}/fdir"
  printf 'a file' > "${S}/fdir/file"
  chmod 640 "${S}/fdir/file"
  local _fbefore
  _fbefore="$(_snapshot "${S}/fdir")"
  _run_cgm --repo "${W}" "${S}/fdir/file"
  _assert_cgm_refusal 2 config_gen_mutation_usage_invalid reason=out_not_dir
  assert_equal "$(_snapshot "${S}/fdir")" "${_fbefore}"
  _no_scratch_left "${S}/fdir"
  _seed_out "${S}/real"
  ln -s "${S}/real" "${S}/link"
  local _before
  _before="$(_snapshot "${S}/real")"
  _run_cgm --repo "${W}" "${S}/link"
  _assert_cgm_refusal 2 config_gen_mutation_usage_invalid reason=out_not_dir
  [[ -L "${S}/link" ]] || fail "the symlink was replaced"
  assert_equal "$(_snapshot "${S}/real")" "${_before}"
  _no_scratch_left "${S}"
}

# ── the none marker ─────────────────────────────────────────────────────────

# why: The positive none case: a PR that touches no Go file must say so
# explicitly, and untracked files outside the module must not count.
@test "manifest: a change outside the module gives exactly the header and none: no-go-change (base#1464)" {
  _stale_main
  git -C "${W}" checkout -q -B main "${M1}"
  git -C "${W}" update-ref refs/remotes/origin/main "${M1}"
  git -C "${W}" checkout -q -b docs
  local _d
  _d="$(_commit "${W}" docs README.md)"
  printf 'scratch\n' > "${W}/notes.txt"
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M1} head=${_d} dirty=no context=pr" \
    "none: no-go-change"
}

# why: The none marker is re-checked against the repository independently of
# the line builder, so a builder that drops lines is refused rather than
# written as none. The writer is called with an empty line set in a fixture
# whose module does differ from the base.
@test "manifest: a none marker beside a Go diff is refused as none_beside_diff, rc 1 (base#1464)" {
  _stale_main
  mkdir -p "${S}/dest"
  printf 'old\n' > "${S}/dest/manifest"
  chmod 640 "${S}/dest/manifest"
  local _before
  _before="$(_snapshot "${S}/dest")"
  # _cgm_write_manifest <repo> <base> <header> <dest> [<line>...]
  # Strict mode is turned on inside _w, not at the top of the bash -c
  # string: under kcov a top-level command run with nounset on died with
  # "BASH_SOURCE: unbound variable" before the writer was reached.
  run --separate-stderr env LOG_FORMAT=json bash -c \
    'source "$1"; shift; _w() { set -euo pipefail; _cgm_write_manifest "$@"; }; _w "$@"' _ \
    "${CGM}" "${W}" "${M0}" "base=${M0} head=${F2} dirty=no context=pr" "${S}/dest/manifest"
  _assert_cgm_refusal 1 config_gen_mutation_none_beside_diff "base=${M0}" "path=${MOD}/"
  assert_equal "$(_snapshot "${S}/dest")" "${_before}"
}

# why: The none re-check has two halves: a tracked diff and an untracked
# module file. Here the module equals the base and only an untracked file
# differs, so only the untracked half can refuse.
@test "manifest: a none marker beside an untracked module file is refused, rc 1 (base#1464)" {
  _stale_main
  printf 'new\n' > "${W}/${MOD}/u.go"
  mkdir -p "${S}/dest"
  printf 'old\n' > "${S}/dest/manifest"
  local _before
  _before="$(_snapshot "${S}/dest")"
  run --separate-stderr env LOG_FORMAT=json bash -c \
    'source "$1"; shift; _w() { set -euo pipefail; _cgm_write_manifest "$@"; }; _w "$@"' _ \
    "${CGM}" "${W}" "${F2}" "base=${F2} head=${F2} dirty=yes context=pr" "${S}/dest/manifest"
  _assert_cgm_refusal 1 config_gen_mutation_none_beside_diff "base=${F2}" "path=${MOD}/"
  assert_equal "$(_snapshot "${S}/dest")" "${_before}"
}

# ── manifest lines ──────────────────────────────────────────────────────────

# why: A user's diff.renames=false splits a rename into D and A unless -M is
# passed; the fixture sets it, so the row does not lean on Git's default.
@test "manifest: a rename keeps both paths as R100 under diff.renames=false (base#1464)" {
  _stale_main
  git -C "${W}" config diff.renames false
  git -C "${W}" mv "${MOD}/b.go" "${MOD}/d.go"
  git -C "${W}" commit -q --no-verify -m rename
  local _h
  _h="$(_rev "${W}" HEAD)"
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F2} head=${_h} dirty=no context=pr" \
    "R100	${MOD}/b.go	${MOD}/d.go"
}

# why: A deleted Go file still changes the generator; dropping D lines would
# turn a delete-only PR into a false "none".
@test "manifest: a delete is a D line (base#1464)" {
  _stale_main
  git -C "${W}" rm -q "${MOD}/a.go"
  git -C "${W}" commit -q --no-verify -m delete
  local _h
  _h="$(_rev "${W}" HEAD)"
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F2} head=${_h} dirty=no context=pr" \
    "D	${MOD}/a.go"
}

# why: Local runs test the working tree, not HEAD; a staged edit must reach
# the manifest and mark the run dirty.
@test "dirty: a staged edit is dirty=yes and an M line (base#1464)" {
  _stale_main
  printf 'edit\n' >> "${W}/${MOD}/a.go"
  git -C "${W}" add "${MOD}/a.go"
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F2} head=${F2} dirty=yes context=pr" \
    "M	${MOD}/a.go"
}

# why: An unstaged edit is the common local case; diffing the index alone
# would miss it and report the tree clean.
@test "dirty: an unstaged edit is dirty=yes and an M line (base#1464)" {
  _stale_main
  printf 'edit\n' >> "${W}/${MOD}/a.go"
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F2} head=${F2} dirty=yes context=pr" \
    "M	${MOD}/a.go"
}

# why: A staged new file is in neither HEAD nor the base; only a diff
# against the working tree lists it as an add.
@test "dirty: a staged new file is dirty=yes and an A line (base#1464)" {
  _stale_main
  printf 'new\n' > "${W}/${MOD}/n.go"
  git -C "${W}" add "${MOD}/n.go"
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F2} head=${F2} dirty=yes context=pr" \
    "A	${MOD}/n.go"
}

# why: git diff never shows an untracked file, so it is appended separately,
# after the diff lines, keeping the line order stable.
@test "dirty: an untracked file is dirty=yes and an A line after the diff lines (base#1464)" {
  _stale_main
  printf 'new\n' > "${W}/${MOD}/u.go"
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${M0} head=${F2} dirty=yes context=pr" \
    "A	${MOD}/b.go" "A	${MOD}/c.go" "A	${MOD}/u.go"
}

# ── the hash files ──────────────────────────────────────────────────────────

# _hash_line <repo> <path> -- "<path>\t<sha256>" for a file under <repo>.
_hash_line() {
  printf '%s\t%s\n' "${2}" "$(sha256sum "${1}/${2}" | cut -d' ' -f1)"
}

# why: The hash files let the container check it sees the host's tree; an
# ignored file left out of both would hide a difference the build reads.
@test "hashes: visible.sha256 covers tracked and untracked module files, ignored.sha256 the ignored ones (base#1464)" {
  _stale_main
  printf '*.out\n' > "${W}/${MOD}/.gitignore"
  git -C "${W}" add "${MOD}/.gitignore"
  git -C "${W}" commit -q --no-verify -m ignore
  printf 'untracked\n' > "${W}/${MOD}/u.go"
  printf 'ignored\n' > "${W}/${MOD}/x.out"
  printf 'outside\n' > "${W}/outside.out"
  rm "${W}/${MOD}/a.go"
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  local _want
  _want="$(for _p in .gitignore b.go c.go u.go; do _hash_line "${W}" "${MOD}/${_p}"; done | LC_ALL=C sort)"
  assert_equal "$(LC_ALL=C sort "${S}/out/visible.sha256")" "${_want}"
  assert_equal "$(cat "${S}/out/ignored.sha256")" "$(_hash_line "${W}" "${MOD}/x.out")"
}

# ── path spelling ───────────────────────────────────────────────────────────

# _odd_names -- on top of _stale_main, commit module files whose names need
# quoting (control bytes, a quote, a backslash) or carry non-ASCII and a
# space, and leave two such files untracked. The repository sets
# core.quotePath=true, Git's default, so a script that let Git's own
# quoting through would spell 測試 as octal escapes. Sets H.
_odd_names() {
  _stale_main
  git -C "${W}" config core.quotePath true
  local _n
  for _n in $'t\tab.go' 'q"b\.go' $'n\nl.go' $'c\001.go' $'d\177.go' 'sp ace.go' '測試.go'; do
    printf '%s\n' "${_n}" > "${W}/${MOD}/${_n}"
  done
  git -C "${W}" add -A
  git -C "${W}" commit -q --no-verify -m odd
  H="$(_rev "${W}" HEAD)"
  printf 'u\n' > "${W}/${MOD}/"$'u\tv.go'
  printf 'w\n' > "${W}/${MOD}/未.go"
}

# why: The review's finding: under Git's default quoting a non-ASCII name
# came out of ls-files as an octal-escaped, double-quoted string, which is
# no file on disk, so the hash files silently left it out while the run
# succeeded. Paths are enumerated NUL-delimited and every path in all three
# files is spelled one way: as is, unless it holds a control byte, a quote
# or a backslash, which are C-quoted the way Git does with
# core.quotePath=false. The expected lines are written out literally.
@test "paths: names with control bytes, quotes, backslashes and non-ASCII are listed and hashed (base#1464)" {
  _odd_names
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/out"
  assert_success
  _assert_manifest "${S}/out" "base=${F2} head=${H} dirty=yes context=pr" \
    "A	\"${MOD}/c\\001.go\"" \
    "A	\"${MOD}/d\\177.go\"" \
    "A	\"${MOD}/n\\nl.go\"" \
    "A	\"${MOD}/q\\\"b\\\\.go\"" \
    "A	${MOD}/sp ace.go" \
    "A	\"${MOD}/t\\tab.go\"" \
    "A	${MOD}/測試.go" \
    "A	\"${MOD}/u\\tv.go\"" \
    "A	${MOD}/未.go"
  # Raw name -> spelling, for every present module file.
  local -a _raw=(a.go b.go c.go $'c\001.go' $'d\177.go' $'n\nl.go' 'q"b\.go' 'sp ace.go' $'t\tab.go' $'u\tv.go' '未.go' '測試.go')
  local -a _say=(a.go b.go c.go '"c\001.go"' '"d\177.go"' '"n\nl.go"' '"q\"b\\.go"' 'sp ace.go' '"t\tab.go"' '"u\tv.go"' '未.go' '測試.go')
  local _i _want=""
  for _i in "${!_raw[@]}"; do
    local _p="${MOD}/${_raw[_i]}" _q
    case "${_say[_i]}" in
      \"*) _q="\"${MOD}/${_say[_i]#\"}" ;;
      *) _q="${MOD}/${_say[_i]}" ;;
    esac
    _want+="$(printf '%s\t%s' "${_q}" "$(sha256sum < "${W}/${_p}" | cut -d' ' -f1)")"$'\n'
  done
  assert_equal "$(LC_ALL=C sort "${S}/out/visible.sha256")" "$(printf '%s' "${_want}" | LC_ALL=C sort)"
  assert_equal "$(wc -l < "${S}/out/visible.sha256" | tr -d ' ')" 12
}

# why: The spelling is the script's, not the caller's Git configuration:
# the same tree under core.quotePath=false gives byte-identical files.
@test "paths: the spelling does not depend on core.quotePath (base#1464)" {
  _odd_names
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/q1"
  assert_success
  git -C "${W}" config core.quotePath false
  CONFIG_GEN_MUTATION_BASE="${F2}" _run_cgm --repo "${W}" "${S}/q0"
  assert_success
  local _f
  for _f in manifest visible.sha256 ignored.sha256; do
    cmp "${S}/q1/${_f}" "${S}/q0/${_f}" || fail "${_f} differs with core.quotePath"
  done
}

# why: An ignored file with an odd name is hashed into ignored.sha256 under
# the same spelling, not dropped.
@test "paths: an ignored file with a non-ASCII or tab name is hashed into ignored.sha256 (base#1464)" {
  _stale_main
  git -C "${W}" config core.quotePath true
  printf '*.out\n' > "${W}/${MOD}/.gitignore"
  git -C "${W}" add "${MOD}/.gitignore"
  git -C "${W}" commit -q --no-verify -m ignore
  printf 'i\n' > "${W}/${MOD}/忽略.out"
  printf 'j\n' > "${W}/${MOD}/"$'x\ty.out'
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  local _want
  _want="$(printf '%s\t%s\n' \
    "\"${MOD}/x\\ty.out\"" "$(sha256sum < "${W}/${MOD}/"$'x\ty.out' | cut -d' ' -f1)" \
    "${MOD}/忽略.out" "$(sha256sum < "${W}/${MOD}/忽略.out" | cut -d' ' -f1)" | LC_ALL=C sort)"
  assert_equal "$(LC_ALL=C sort "${S}/out/ignored.sha256")" "${_want}"
}

# ── publication ─────────────────────────────────────────────────────────────

# why: A plain mv into an existing directory nests the new output inside the
# old one, and writing only the script's own files leaves stale ones beside
# them; the directory is replaced whole.
@test "publish: a second invocation replaces the output directory whole (base#1464)" {
  _stale_main
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  printf 'stale\n' > "${S}/out/stale"
  mkdir -p "${S}/out/sub"
  printf 'x\n' > "${S}/out/sub/x"
  local _g
  _g="$(_commit "${W}" g "${MOD}/g.go")"
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  assert_equal "$(cd "${S}/out" && find . -mindepth 1 | LC_ALL=C sort)" \
    "$(printf './%s\n' ignored.sha256 manifest visible.sha256)"
  _assert_manifest "${S}/out" "base=${M0} head=${_g} dirty=no context=pr" \
    "A	${MOD}/b.go" "A	${MOD}/c.go" "A	${MOD}/g.go"
  _no_scratch_left "${S}"
}

# _shim_mv -- an `mv` first on ${S}/bin that counts its calls in ${S}/mv.n
# and fails (exit 1, nothing moved) on each call index listed in the
# comma-separated MV_FAIL_AT; every other call runs the real mv.
_shim_mv() {
  local _real
  _real="$(command -v mv)"
  cat > "${S}/bin/mv" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/mv.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/mv.n"
case ",\${MV_FAIL_AT:-}," in *",\${n},"*) exit 1 ;; esac
exec "${_real}" "\$@"
EOF
  chmod +x "${S}/bin/mv"
}

# why: Without the sanity row a green failure row could be a shim the
# script never reached. Over an existing output a successful publication is
# exactly two renames, aside and install, and gives the same manifest as an
# unshimmed run.
@test "publish: the mv shim is on the script's path; a success over an existing output is two renames (base#1464)" {
  _stale_main
  _run_cgm --repo "${W}" "${S}/plain-out"
  assert_success
  _shim_mv
  _seed_out "${S}/out"
  _run_cgm --repo "${W}" "${S}/out"
  assert_success
  assert_equal "$(cat "${S}/mv.n" 2>/dev/null || echo 0)" 2
  assert_equal "$(cat "${S}/out/manifest")" "$(cat "${S}/plain-out/manifest")"
  [[ ! -e "${S}/out/stale" ]] || fail "the old output survived the publication"
  _no_scratch_left "${S}"
}

# why: The review's blocking point. With the old output moved aside and the
# install rename failing, set -e alone exits with the destination gone and
# its bytes only in an anonymous .cgm-old.* directory. The backup must be
# put back: same bytes, same file list, same mode.
@test "publish: an install that fails after the aside restores the destination (base#1464)" {
  _stale_main
  _shim_mv
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  MV_FAIL_AT=2 _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_publish_failed stage=install restored=yes
  [[ -d "${S}/out" ]] || fail "the destination is gone"
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  assert_equal "$(stat -c %a "${S}/out")" 750
  _no_scratch_left "${S}"
}

# why: If the first rename fails nothing has moved yet; the refusal must name
# that stage and leave the destination exactly as it was.
@test "publish: an aside that fails leaves the destination untouched (base#1464)" {
  _stale_main
  _shim_mv
  _seed_out "${S}/out"
  local _before
  _before="$(_snapshot "${S}/out")"
  MV_FAIL_AT=1 _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_publish_failed stage=aside restored=n/a
  assert_equal "$(_snapshot "${S}/out")" "${_before}"
  _no_scratch_left "${S}"
}

# why: With no previous output there is nothing to restore; a failed
# install must still refuse by name and leave neither the destination nor
# any scratch behind.
@test "publish: an install that fails with no previous output refuses and leaves nothing (base#1464)" {
  _stale_main
  _shim_mv
  MV_FAIL_AT=1 _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_publish_failed stage=install restored=n/a "out=${S}/out"
  [[ ! -e "${S}/out" ]] || fail "a destination appeared: $(ls -la "${S}/out")"
  _no_scratch_left "${S}"
}

# why: When the restore fails too, the bytes must survive somewhere named:
# the backup is kept and the event says where.
@test "publish: an install and a restore that both fail keep the backup and name it (base#1464)" {
  _stale_main
  _shim_mv
  _seed_out "${S}/out"
  local _before _line _backup
  _before="$(_snapshot "${S}/out")"
  MV_FAIL_AT=2,3 _run_cgm --repo "${W}" "${S}/out"
  _assert_cgm_refusal 1 config_gen_mutation_publish_failed stage=install restored=no
  _line="$(log_event_line config_gen_mutation_publish_failed "${stderr}")"
  [[ "${_line}" =~ \"backup\":\"([^\"]+)\" ]] || fail "the event names no backup: ${_line}"
  _backup="${BASH_REMATCH[1]}"
  [[ -d "${_backup}" ]] || fail "the named backup ${_backup} does not exist"
  assert_equal "$(_snapshot "${_backup}")" "${_before}"
}
