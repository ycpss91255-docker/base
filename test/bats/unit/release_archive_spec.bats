#!/usr/bin/env bats
#
# release_archive_spec.bats -- unit tests for script/ci/release-archive.sh,
# the payload assembler the reusable release worker runs at tag time.
#
# WHY THE ENGINE EXISTS. The archive step used to name every standard path
# as an operand of one `cp -r`. `cp` exits non-zero on a missing operand and
# the `run:` step is `bash -e`, so a consumer that legitimately lacked ONE
# path lost its whole release -- at tag push, the worst moment to find out.
# It was fixed twice by editing the operand list to match base's own current
# layout, which is exactly what makes a base layout change a breaking change
# for every consumer whose tree is shaped differently.
#
# WHAT THESE TESTS DRIVE. Every test builds a SYNTHETIC repo tree in a
# temp dir and runs the engine against a SYNTHETIC manifest. base's own
# checkout is never the subject: base has no `.base/` subtree (it is the
# template source) and no `test/bats/smoke/` (the shipped smoke templates
# live under dist/), so a test driving `/source` would exercise neither a
# satisfied payload nor a realistic consumer -- it is precisely the vacuous
# shape that let this class through twice. The absence cases are the point,
# so the fixture must be able to LACK a path on purpose.
#
# Pure filesystem, no docker, no network: Unit level (ADR-00000018).
# The real shipped manifest is driven separately, at Integration level, by
# release_archive_contract_spec.bats.

bats_require_minimum_version 1.5.0

ARCHIVE="/source/script/ci/release-archive.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP_DIR="$(mktemp -d)"
  REPO="${TMP_DIR}/repo"
  MANIFEST="${TMP_DIR}/archive.manifest"
  DEST="out"
  mkdir -p "${REPO}"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ── fixture helpers ──────────────────────────────────────────────────────────

# _seed <path>... -- materialise paths in the fixture repo. A trailing slash
# makes a directory (with one file inside, so an empty-dir copy cannot pass
# for a real one); anything else makes a regular file.
_seed() {
  local _p
  for _p in "$@"; do
    case "${_p}" in
      */)
        mkdir -p "${REPO}/${_p}"
        printf 'content of %s\n' "${_p}" > "${REPO}/${_p}payload.txt"
        ;;
      *)
        mkdir -p "$(dirname "${REPO}/${_p}")"
        printf 'content of %s\n' "${_p}" > "${REPO}/${_p}"
        ;;
    esac
  done
}

# _manifest <line>... -- write the synthetic payload manifest.
_manifest() {
  printf '%s\n' "$@" > "${MANIFEST}"
}

# Run the engine with the fixture repo as the working directory, the way the
# workflow runs it from the consumer's checkout root.
_archive() {
  cd "${REPO}" || return 1
  bash "${ARCHIVE}" "${MANIFEST}" "${DEST}"
}

_archive_list() {
  cd "${REPO}" || return 1
  bash "${ARCHIVE}" --list "${MANIFEST}"
}

# ── required paths ───────────────────────────────────────────────────────────

@test "release-archive: archives a required path that exists" {
  _seed 'Dockerfile'
  _manifest 'required|dockerfile|Dockerfile|the image definition|nothing to build without it'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/Dockerfile" ]
}

@test "release-archive: a missing required path fails naming that path, not a bare cp error (#914)" {
  # The whole point of the mandatory half: an archive without it is not a
  # release, it is a broken artifact someone discovers later. It must fail,
  # and it must say WHICH path and WHY -- `cp: cannot stat` on one of seven
  # operands is what made the last two instances expensive to diagnose.
  _seed 'README.md'
  _manifest 'required|dockerfile|Dockerfile|the image definition|the archive would build nothing'
  run _archive
  assert_failure
  assert_output --partial 'Dockerfile'
  assert_output --partial 'dockerfile'
  assert_output --partial 'the archive would build nothing'
  refute_output --partial 'cannot stat'
}

@test "release-archive: a missing required path leaves no half-built archive (#914)" {
  # A tarball of a partial payload is worse than no tarball: it uploads
  # clean and breaks at the consumer. The step must not hand `tar` a
  # directory it started filling before the gap was found.
  _seed 'README.md'
  _manifest \
    'optional|readme|README.md|the readme|docs lost' \
    'required|base|.base/|the vendored base toolchain|nothing runs without it'
  run _archive
  assert_failure
  [ ! -e "${REPO}/${DEST}" ]
}

@test "release-archive: reports every missing required path in one pass (#914)" {
  _seed 'README.md'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'required|base|.base/|the vendored base toolchain|nothing to run'
  run _archive
  assert_failure
  assert_output --partial 'Dockerfile'
  assert_output --partial '.base/'
  assert_output --partial '2 required'
}

# ── optional paths: the class the two instances belong to ────────────────────

@test "release-archive: a consumer tree lacking an optional path still archives (#914)" {
  # The regression both instances were: one absent standard path took down
  # the entire release. Absence of an optional path is now a note, not a
  # failure.
  _seed 'Dockerfile' 'README.md'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|readme|README.md|the readme|the archive ships undocumented' \
    'optional|smoke|test/bats/smoke/|the smoke specs|no build-time assertions'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/Dockerfile" ]
  [ -f "${REPO}/${DEST}/README.md" ]
  [ ! -e "${REPO}/${DEST}/test" ]
}

@test "release-archive: an absent optional path is reported by name, never silently dropped (#914)" {
  # Tolerance must not become silence: the tag log has to show what the
  # archive does NOT contain, or a payload path that quietly stopped being
  # copied is invisible until someone unpacks the tarball.
  _seed 'Dockerfile'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|docs|doc/|the documentation tree|the archive ships undocumented'
  run _archive
  assert_success
  assert_output --partial 'doc/'
  assert_output --partial 'the documentation tree'
}

@test "release-archive: names every archived path so the tag log shows the payload" {
  _seed 'Dockerfile' 'doc/'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|docs|doc/|the documentation tree|undocumented'
  run _archive
  assert_success
  assert_output --partial 'Dockerfile'
  assert_output --partial 'doc/'
}

# ── layout alternatives: both historical smoke trees ─────────────────────────

@test "release-archive: an entry archives whichever candidate layout the consumer has (old) (#914)" {
  _seed 'Dockerfile' 'test/smoke/'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|smoke|test/bats/smoke/ test/smoke/|the smoke specs|no assertions'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/test/smoke/payload.txt" ]
}

@test "release-archive: an entry archives whichever candidate layout the consumer has (new) (#914)" {
  _seed 'Dockerfile' 'test/bats/smoke/'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|smoke|test/bats/smoke/ test/smoke/|the smoke specs|no assertions'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/test/bats/smoke/payload.txt" ]
}

@test "release-archive: a tree carrying both candidate layouts archives both (#914)" {
  # Mid-migration trees exist. Copying every candidate that is present --
  # each at its own relative path -- means neither layout is dropped and
  # neither collides with the other.
  _seed 'Dockerfile' 'test/bats/smoke/' 'test/smoke/'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|smoke|test/bats/smoke/ test/smoke/|the smoke specs|no assertions'
  run _archive
  assert_success
  [ -f "${REPO}/${DEST}/test/bats/smoke/payload.txt" ]
  [ -f "${REPO}/${DEST}/test/smoke/payload.txt" ]
}

@test "release-archive: a required entry with no candidate present names all of them (#914)" {
  _seed 'Dockerfile'
  _manifest 'required|smoke|test/bats/smoke/ test/smoke/|the smoke specs|no assertions'
  run _archive
  assert_failure
  assert_output --partial 'test/bats/smoke/'
  assert_output --partial 'test/smoke/'
}

# ── copy semantics ───────────────────────────────────────────────────────────

@test "release-archive: a nested path keeps its relative position in the archive (#914)" {
  # `cp -r test/bats/smoke/ dest/` flattens to `dest/smoke/`, which makes
  # the two historical layouts collide on one destination and loses the
  # information about which layout the consumer actually has.
  _seed 'Dockerfile' 'test/bats/smoke/'
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|smoke|test/bats/smoke/|the smoke specs|no assertions'
  run _archive
  assert_success
  [ -d "${REPO}/${DEST}/test/bats/smoke" ]
  [ ! -e "${REPO}/${DEST}/smoke" ]
}

@test "release-archive: symlinked wrappers still resolve inside the archive (#914)" {
  # `script/*.sh` are relative symlinks into `.base/dist/script/docker/`.
  # `cp -r` copies a symlink AS a symlink (measured: GNU coreutils 8.32
  # does not dereference under -r), so the wrappers only resolve because
  # the subtree they point into travels with them -- which is the concrete
  # reason `.base/` is a REQUIRED entry rather than a nice-to-have.
  _seed '.base/dist/script/docker/wrapper/build.sh'
  mkdir -p "${REPO}/script"
  ln -s '../.base/dist/script/docker/wrapper/build.sh' "${REPO}/script/build.sh"
  _manifest \
    'required|base|.base/|the vendored base subtree|entry points lead nowhere' \
    'optional|wrappers|script/|the wrapper entry points|no entry points'
  run _archive
  assert_success
  # -e follows the link: a dangling wrapper fails here.
  [ -e "${REPO}/${DEST}/script/build.sh" ]
  run cat "${REPO}/${DEST}/script/build.sh"
  assert_success
  assert_output --partial 'content of .base/dist/script/docker/wrapper/build.sh'
}

@test "release-archive: creates the archive directory when it does not exist" {
  _seed 'Dockerfile'
  _manifest 'required|dockerfile|Dockerfile|the image definition|nothing to build'
  [ ! -e "${REPO}/${DEST}" ]
  run _archive
  assert_success
  [ -d "${REPO}/${DEST}" ]
}

# ── caller-supplied extras ───────────────────────────────────────────────────

@test "release-archive: archives extra_files that exist" {
  _seed 'Dockerfile' 'config/' 'entrypoint.sh'
  _manifest 'required|dockerfile|Dockerfile|the image definition|nothing to build'
  RELEASE_EXTRA_FILES='config/ entrypoint.sh' run _archive
  assert_success
  [ -f "${REPO}/${DEST}/config/payload.txt" ]
  [ -f "${REPO}/${DEST}/entrypoint.sh" ]
}

@test "release-archive: an absent extra_file is tolerated, as it always was" {
  _seed 'Dockerfile'
  _manifest 'required|dockerfile|Dockerfile|the image definition|nothing to build'
  RELEASE_EXTRA_FILES='nope/ also-missing.txt' run _archive
  assert_success
  [ -d "${REPO}/${DEST}" ]
}

@test "release-archive: an extra_file escaping the repo root is refused, not copied out (#914)" {
  # `..` in a caller-supplied path resolves OUTSIDE the archive directory,
  # so a `cp` would write into the checkout instead of the payload and the
  # tarball would silently not contain it.
  _seed 'Dockerfile'
  _manifest 'required|dockerfile|Dockerfile|the image definition|nothing to build'
  RELEASE_EXTRA_FILES='../escape' run _archive
  assert_failure
  assert_output --partial '../escape'
}

@test "release-archive: an absolute extra_file path is refused (#914)" {
  _seed 'Dockerfile'
  _manifest 'required|dockerfile|Dockerfile|the image definition|nothing to build'
  RELEASE_EXTRA_FILES='/etc/hostname' run _archive
  assert_failure
  assert_output --partial '/etc/hostname'
}

# ── malformed input never archives silently ──────────────────────────────────

@test "release-archive: an unknown manifest kind fails loudly, naming it (#914)" {
  # Fail closed: a typo'd kind column must never mean "copy it if you feel
  # like it". Same class as preflight.sh's unknown-kind guard.
  _seed 'Dockerfile'
  _manifest 'requried|dockerfile|Dockerfile|the image definition|nothing to build'
  run _archive
  [ "${status}" -eq 2 ]
  assert_output --partial 'requried'
}

@test "release-archive: a manifest declaring nothing is a config error, not an empty archive (#914)" {
  _seed 'Dockerfile'
  _manifest '# only a comment' ''
  run _archive
  [ "${status}" -eq 2 ]
  assert_output --partial 'no payload'
}

@test "release-archive: a missing manifest file is a config error" {
  _seed 'Dockerfile'
  rm -f "${MANIFEST}"
  run _archive
  [ "${status}" -eq 2 ]
  assert_output --partial 'manifest'
}

@test "release-archive: refuses a manifest path that escapes the repo root (#914)" {
  _seed 'Dockerfile'
  _manifest 'optional|escape|../outside|a path outside the checkout|nothing'
  run _archive
  assert_failure
  assert_output --partial '../outside'
}

# ── the payload contract is readable ─────────────────────────────────────────

@test "release-archive: --list prints the declared payload with its required/optional split" {
  _manifest \
    'required|dockerfile|Dockerfile|the image definition|nothing to build' \
    'optional|docs|doc/|the documentation tree|undocumented'
  run _archive_list
  assert_success
  assert_output --partial 'required'
  assert_output --partial 'Dockerfile'
  assert_output --partial 'optional'
  assert_output --partial 'doc/'
}
