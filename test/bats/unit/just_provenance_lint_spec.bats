#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/just_provenance.sh -- the "every site
# that obtains the `just` runner names the ONE pinned version" lint.
#
# `just` is the project's only control surface, and it reached a developer
# through four independent provenance paths that shared no version: a bare
# `apk add` in the tooling image, `extractions/setup-just` with no version
# input, the just.systems installer with no --tag, and a host package
# manager. Nothing in the tree compared any pair of them, and all three
# mechanisms that should have caught it were individually blind (DL3018 is
# ignored by policy, the release smoke check asserted only exit 0, and the
# image tag is a content hash that cannot see what `apk` resolved to).
#
# The lint COMPUTES the site set from the tree rather than listing it:
# every file under the scanned roots is read, and a site is any logical
# line carrying an acquisition marker. That is what makes it able to
# notice a fifth path added tomorrow -- a guard over a remembered list
# would pass on exactly the addition it exists to catch.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree; a final case drives the REAL tree to prove
# it passes today. Shape mirrors arch_literal_lint_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/just_provenance.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"

  # Every scan root must exist and hold a file, and at least one site must
  # be PINNED, or the lint refuses to pass vacuously. Seed a clean baseline
  # covering all three pinnable mechanisms; individual cases overwrite the
  # file they are about.
  _seed_clean
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

_seed_clean() {
  _write "dockerfile/Dockerfile.test-tools" \
    'ARG JUST_VERSION=1.58.0' \
    'RUN curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just.tar.gz" | tar -xz'
  _write ".github/workflows/self-test.yaml" \
    '      - uses: extractions/setup-just@v4' \
    '        with:' \
    '          just-version: ${{ steps.pin.outputs.version }}'
  _write "dist/script/base/init.sh" \
    '  curl -sSf https://just.systems/install.sh \' \
    '      | bash -s -- --to "${_bindir}" --tag "${_pin}"'
  _write "script/test/noop.sh" '# nothing to acquire here'
}

# ════════════════════════════════════════════════════════════════════
# _run_just_provenance: the clean baseline
# ════════════════════════════════════════════════════════════════════

@test "just provenance: a tree whose every site names the pin is clean (#948)" {
  run _run_just_provenance
  assert_success
  assert_output --partial "just provenance lint: clean"
}

# ════════════════════════════════════════════════════════════════════
# _run_just_provenance: violations
# ════════════════════════════════════════════════════════════════════

@test "just provenance: setup-just with no just-version input is a finding (#948)" {
  _write ".github/workflows/self-test.yaml" \
    '      - uses: extractions/setup-just@v4'
  run _run_just_provenance
  assert_failure
  assert_output --partial ".github/workflows/self-test.yaml:1"
  assert_output --partial "setup-just"
}

@test "just provenance: the just.systems installer with no --tag is a finding (#948)" {
  _write "dist/script/base/init.sh" \
    '  curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin'
  run _run_just_provenance
  assert_failure
  assert_output --partial "dist/script/base/init.sh:1"
}

@test "just provenance: a pinned release URL that drops the version arg is a finding (#948)" {
  _write "dockerfile/Dockerfile.test-tools" \
    'ARG JUST_VERSION=1.58.0' \
    'RUN curl -fsSL "https://github.com/casey/just/releases/download/1.37.0/just.tar.gz" | tar -xz'
  run _run_just_provenance
  assert_failure
  assert_output --partial "dockerfile/Dockerfile.test-tools:2"
}

@test "just provenance: a package-manager install of just needs an advisory marker (#948)" {
  _write "dockerfile/Dockerfile.test-tools" \
    'ARG JUST_VERSION=1.58.0' \
    'RUN curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just.tar.gz" | tar -xz' \
    'RUN apk add --no-cache bash just coreutils'
  run _run_just_provenance
  assert_failure
  assert_output --partial "dockerfile/Dockerfile.test-tools:3"
  assert_output --partial "advisory"
}

@test "just provenance: a package-manager install inside a justified advisory region is allowed (#948)" {
  _write "dist/script/base/init.sh" \
    '  curl -sSf https://just.systems/install.sh \' \
    '      | bash -s -- --to "${_bindir}" --tag "${_pin}"' \
    '  # just-provenance: advisory-begin -- a host package manager ships' \
    '  #   whatever its registry carries and cannot be pointed at the pin;' \
    '  #   the printed text says so.' \
    "  cat <<'EOF'" \
    '    apt install just' \
    '    brew install just' \
    'EOF' \
    '  # just-provenance: advisory-end'
  run _run_just_provenance
  assert_success
  assert_output --partial "just provenance lint: clean"
}

@test "just provenance: an advisory region with no stated reason is a finding (#948)" {
  _write "dist/script/base/init.sh" \
    '  curl -sSf https://just.systems/install.sh \' \
    '      | bash -s -- --to "${_bindir}" --tag "${_pin}"' \
    '  # just-provenance: advisory-begin' \
    '  apt install just' \
    '  # just-provenance: advisory-end'
  run _run_just_provenance
  assert_failure
  assert_output --partial "no stated reason"
}

@test "just provenance: an unterminated advisory region is a finding (#948)" {
  _write "dist/script/base/init.sh" \
    '  curl -sSf https://just.systems/install.sh \' \
    '      | bash -s -- --to "${_bindir}" --tag "${_pin}"' \
    '  # just-provenance: advisory-begin -- reason enough' \
    '  apt install just'
  run _run_just_provenance
  assert_failure
  assert_output --partial "unterminated advisory-begin"
}

@test "just provenance: an unmatched advisory-end is a finding (#948)" {
  _write "script/test/noop.sh" \
    '  # just-provenance: advisory-end'
  run _run_just_provenance
  assert_failure
  assert_output --partial "unmatched advisory-end"
}

# ════════════════════════════════════════════════════════════════════
# _run_just_provenance: non-vacuity
# ════════════════════════════════════════════════════════════════════

@test "just provenance: a missing scan root fails rather than passing vacuously (#948)" {
  rm -rf "${SCRATCH}/dockerfile"
  run _run_just_provenance
  assert_failure
  assert_output --partial "not found"
}

@test "just provenance: an empty scan root fails rather than passing vacuously (#948)" {
  rm -f "${SCRATCH}/script/test/noop.sh"
  run _run_just_provenance
  assert_failure
  assert_output --partial "holds no file"
}

@test "just provenance: a tree with no provenance site at all fails vacuously-closed (#948)" {
  _write "dockerfile/Dockerfile.test-tools" 'FROM alpine:3.21'
  _write ".github/workflows/self-test.yaml" 'name: self-test'
  _write "dist/script/base/init.sh" 'echo hi'
  run _run_just_provenance
  assert_failure
  assert_output --partial "no site that obtains"
}

@test "just provenance: a tree where nothing is pinned fails vacuously-closed (#948)" {
  # Only advisory sites left: the scan found something, but no path
  # actually names the pin, so "everything agrees" would be empty.
  _write "dockerfile/Dockerfile.test-tools" 'FROM alpine:3.21'
  _write ".github/workflows/self-test.yaml" 'name: self-test'
  _write "dist/script/base/init.sh" \
    '  # just-provenance: advisory-begin -- reason enough' \
    '  apt install just' \
    '  # just-provenance: advisory-end'
  run _run_just_provenance
  assert_failure
  assert_output --partial "no PINNED site"
}

# ════════════════════════════════════════════════════════════════════
# Logical lines
# ════════════════════════════════════════════════════════════════════

@test "just provenance: pin evidence on a backslash continuation still counts (#948)" {
  # The shipped bootstrap writes the marker and its --tag on two physical
  # lines; a per-physical-line reader would call the correct code a finding.
  _write "dist/script/base/init.sh" \
    '  if ! curl -sSf https://just.systems/install.sh \' \
    '      | bash -s -- --to "${_bindir}" \' \
    '            --tag "${_pin}"; then' \
    '    exit 1' \
    '  fi'
  run _run_just_provenance
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "just provenance: the live tree passes its own lint (#948)" {
  REPO_ROOT=/source run _run_just_provenance
  assert_success
  assert_output --partial "just provenance lint: clean"
}
