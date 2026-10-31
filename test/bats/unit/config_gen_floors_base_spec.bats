#!/usr/bin/env bats
#
# config_gen_floors_base_spec.bats -- the 05-floors-base config-gen step,
# script/test/config_gen_steps/05-floors-base.sh (base#1465, slice S1e of
# base#1395).
#
# why: The coverage ratchet refuses a floor lower than the base's, and it
# can only know the base's floors from floors.base, which this step writes
# on the host from the commit 00-manifest diffed against. A floors.base
# that says `absent` while the base has floors, or that drops one of its
# fragments, lets a lowered floor through. Each row runs the real step on
# a Git fixture; a refusal must leave the old floors.base's bytes and mode
# as they were and no scratch file beside it.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  STEP_SRC="/source/script/test/config_gen_steps/05-floors-base.sh"
  S="${BATS_TEST_TMPDIR}"
  cd "${S}"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="${S}/gitconfig"
  git config --file "${GIT_CONFIG_GLOBAL}" user.name t
  git config --file "${GIT_CONFIG_GLOBAL}" user.email t@t
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" commit.gpgsign false
  R="${S}/r"
  D="dockerfile/config-gen/coverage-floors.d"
  mkdir -p "${R}/script/test/config_gen_steps" "${R}/dist/script/docker/lib" "${R}/dockerfile/config-gen" "${S}/bin"
  assert_spec_subject "${STEP_SRC}" "the config-gen 05-floors-base step (base#1465)"
  cp "${STEP_SRC}" "${R}/script/test/config_gen_steps/"
  cp /source/dist/script/docker/lib/log.sh /source/dist/script/docker/lib/log-events.txt "${R}/dist/script/docker/lib/"
  printf 'x\n' > "${R}/dockerfile/config-gen/go.mod"
  git init -q "${R}"
}

# _commit -- commit everything in ${R}; BASE is the new commit.
_commit() {
  git -C "${R}" add -A
  git -C "${R}" commit -q --no-verify --allow-empty -m c
  BASE="$(git -C "${R}" rev-parse HEAD)"
}

# _ctx [<header>] -- ${S}/ctx/mutation with a manifest whose header names
# BASE (or <header>), and an old floors.base, mode 0640, to be kept on a
# refusal.
_ctx() {
  rm -rf "${S}/ctx"
  mkdir -p "${S}/ctx/mutation"
  printf '%s\nnone: no-go-change\n' "${1:-base=${BASE} head=${BASE} dirty=no context=pr}" > "${S}/ctx/mutation/manifest"
  printf 'old\n' > "${S}/ctx/mutation/floors.base"
  chmod 0640 "${S}/ctx/mutation/floors.base"
}

_run_step() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" CONFIG_GEN_CTX="${S}/ctx" LOG_FORMAT=json \
    bash "${R}/script/test/config_gen_steps/05-floors-base.sh"
}

# _kept -- the old floors.base is untouched and no scratch is left.
_kept() {
  assert_equal "$(cat "${S}/ctx/mutation/floors.base")" old
  assert_equal "$(stat -c %a "${S}/ctx/mutation/floors.base")" 640
  assert_equal "$(find "${S}/ctx/mutation" -name '.floors.base.*' | wc -l)" 0
}

# why: A base with no coverage-floors.d is the one case the ratchet may
# judge with no base floors; any other base must be read. (base#1465)
@test "05-floors-base: a base with no coverage-floors.d writes absent (base#1465)" {
  _commit
  _ctx
  _run_step
  assert_success
  assert_equal "${output}" ""
  assert_equal "$(cat "${S}/ctx/mutation/floors.base")" absent
  assert_equal "$(find "${S}/ctx/mutation" -name '.floors.base.*' | wc -l)" 0
}

# why: The ratchet compares per package across the base's union, so every
# fragment must be in it, each line whole: one without a final LF would
# fuse with the next fragment's first line. The expected bytes are git
# show's, worked by hand. (base#1465)
@test "05-floors-base: a base with fragments writes their concatenation in lexical order, each ending in LF (base#1465)" {
  mkdir -p "${R}/${D}"
  printf 'internal/b 91.0' > "${R}/${D}/s1g.txt"
  printf 'cmd/a 95.0\n' > "${R}/${D}/s1e.txt"
  _commit
  # The head's own fragments are not the base's: a later edit is not read.
  printf 'cmd/a 90.0\n' > "${R}/${D}/s1e.txt"
  _ctx
  _run_step
  assert_success
  assert_equal "${output}" ""
  assert_equal "$(od -An -c "${S}/ctx/mutation/floors.base" | tr -s ' ')" \
    "$(printf 'cmd/a 95.0\ninternal/b 91.0\n' | od -An -c | tr -s ' ')"
  assert_equal "$(git -C "${R}" show "${BASE}:${D}/s1e.txt")" "cmd/a 95.0"
}

# why: Each refusal is a base the step could not read faithfully; writing
# anything, or `absent`, would let the ratchet judge without the base's
# floors. (base#1465)
@test "05-floors-base: a base it cannot read is refused by reason, the old floors.base kept (base#1465)" {
  local row reason
  for row in header-garbage:base_missing header-unknown:base_missing header-ref:base_missing not-tree:not_tree \
      bad-name:fragment_invalid subdir:fragment_invalid ls-tree-fails:git_failed \
      list-ls-tree-fails:git_failed mktemp-fails:git_failed mv-fails:git_failed \
      second-show-fails:git_failed; do
    reason="${row#*:}"
    rm -rf "${R}/${D}" "${S}/bin/git" "${S}/bin/mktemp" "${S}/bin/mv"
    mkdir -p "${R}/${D}"
    printf 'a 95.0\n' > "${R}/${D}/s1e.txt"
    printf 'b 95.0\n' > "${R}/${D}/s1g.txt"
    case "${row%%:*}" in
      not-tree) rm -rf "${R}/${D}"; printf 'x\n' > "${R}/${D}" ;;
      bad-name) printf 'c 95.0\n' > "${R}/${D}/S1H.txt" ;;
      subdir) mkdir -p "${R}/${D}/s1h.txt"; printf 'c\n' > "${R}/${D}/s1h.txt/x" ;;
    esac
    _commit
    case "${row%%:*}" in
      header-garbage) _ctx 'garbage' ;;
      header-unknown) _ctx "base=$(printf 'c%.0s' {1..40}) head=${BASE} dirty=no context=pr" ;;
      # A ref name git resolves, but no commit id the producer writes.
      header-ref) _ctx "base=HEAD head=${BASE} dirty=no context=pr" ;;
      ls-tree-fails)
        _ctx
        printf '#!%s\n[[ "$*" == *ls-tree* ]] && exit 128\nexec %s "$@"\n' "$(command -v bash)" "$(command -v git)" > "${S}/bin/git"
        chmod +x "${S}/bin/git"
        ;;
      # Only the second ls-tree, the listing of coverage-floors.d, fails:
      # the first, which finds the tree, succeeds. (base#1465)
      list-ls-tree-fails)
        _ctx
        printf '#!%s\n[[ "$*" == *ls-tree*:dockerfile/* ]] && exit 128\nexec %s "$@"\n' "$(command -v bash)" "$(command -v git)" > "${S}/bin/git"
        chmod +x "${S}/bin/git"
        ;;
      # mktemp makes and prints the scratch directory, then exits 1: a step
      # that ignored the exit status would go on and publish. (base#1465)
      mktemp-fails)
        _ctx
        printf '#!%s\n%s "$@"\nexit 1\n' "$(command -v bash)" "$(command -v mktemp)" > "${S}/bin/mktemp"
        chmod +x "${S}/bin/mktemp"
        ;;
      # Only the rename over floors.base fails. (base#1465)
      mv-fails)
        _ctx
        printf '#!%s\n[[ "$*" == *floors.base* ]] && exit 1\nexec %s "$@"\n' "$(command -v bash)" "$(command -v mv)" > "${S}/bin/mv"
        chmod +x "${S}/bin/mv"
        ;;
      second-show-fails)
        _ctx
        printf '#!%s\n[[ "$*" == *show*s1g.txt* ]] && exit 128\nexec %s "$@"\n' "$(command -v bash)" "$(command -v git)" > "${S}/bin/git"
        chmod +x "${S}/bin/git"
        ;;
      *) _ctx ;;
    esac
    _run_step
    assert_refusal 1 config_gen_floors_base_failed "reason=${reason}"
    _kept
  done
}
