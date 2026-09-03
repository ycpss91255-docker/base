#!/usr/bin/env bats
#
# Integration test: the signals init.sh PRINTS must be the signals it
# BRANCHES on, and they must be files init.sh itself creates.
#
# This is the anti-decay half of `--list-existing-repo-signals`. A published
# discriminator that nothing exercises is a second statement of the branch
# condition, and a second statement is the thing that goes stale -- which is
# the failure this whole mechanism exists to prevent, reproduced one layer
# down. So the list is not trusted: for every path it names, a real repo
# carrying that path and nothing else is run through a real init, and the
# branch it took is read off the files that came out.
#
# The artifacts are the evidence rather than a log line, because they are
# what ycpss91255-docker/base#928 was actually about: `.github/workflows/
# main.yaml`, `doc/changelog/CHANGELOG.md` and the smoke tree reach a repo
# through the new-repo path and through nothing else, so their presence and
# their absence say which branch ran.
#
# Level-1 (file generation): no Docker daemon, no image build.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  # The consumer's OWN vendored copy, not /source: base's checkout carries
  # .git, which the self-run guard reads as "this is the template source"
  # and refuses. The vendored copy is also what a real bootstrap and a real
  # upgrade execute.
  INIT="./.base/dist/script/base/init.sh"
}

# _seed_consumer [path...]
#   A git repo with a vendored `.base/` carrying the real dist payload, plus
#   exactly the named repo-root files and nothing else. With no arguments it
#   is the shape a freshly bootstrapped repo has: the subtree is in, no
#   scaffold has run yet.
_seed_consumer() {
  cd "${BATS_TEST_TMPDIR}"
  rm -rf "${CONSUMER}"
  mkdir -p "${CONSUMER}/.base"
  git -C "${CONSUMER}" init -q -b main
  git -C "${CONSUMER}" config user.email t@t
  git -C "${CONSUMER}" config user.name t

  cp -a /source/dist "${CONSUMER}/.base/dist"
  echo "v0.0.0-test" > "${CONSUMER}/.base/.version"

  local _p
  for _p in "$@"; do
    mkdir -p "${CONSUMER}/$(dirname -- "${_p}")"
    printf '%s\n' "# seeded by the fixture" > "${CONSUMER}/${_p}"
  done

  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer before init"
}

# _signals
#   The published discriminator, straight from the installer. Asked of
#   /source because it is a QUERY: it prints before the self-run guard and
#   before any mutation, so the base checkout answers it without being
#   touched.
_signals() {
  bash /source/dist/script/base/init.sh --list-existing-repo-signals
}

# _new_repo_only_paths
#   Files the NEW-repo path installs and the existing-repo path never
#   writes. Two of the three things #928 measured as missing; the third is
#   the smoke tree, checked as a directory below.
_new_repo_only_paths() {
  cat <<'EOF'
.github/workflows/main.yaml
doc/changelog/CHANGELOG.md
EOF
}

@test "a repo carrying none of the published signals is scaffolded as new (#928)" {
  _seed_consumer

  cd "${CONSUMER}"
  run bash "${INIT}"
  assert_success

  local _p
  while IFS= read -r _p; do
    assert [ -f "${CONSUMER}/${_p}" ]
  done < <(_new_repo_only_paths)
  assert [ -d "${CONSUMER}/test/bats/smoke/shared" ]
  assert [ -d "${CONSUMER}/test/bats/smoke/devel-test" ]
  assert [ -d "${CONSUMER}/test/bats/smoke/runtime-test" ]
}

@test "each published signal, on its own, sends init down the existing-repo path (#928)" {
  local _sig _p _signal_list="${BATS_TEST_TMPDIR}/signals"
  _signals > "${_signal_list}"
  assert [ -s "${_signal_list}" ]

  while IFS= read -r _sig; do
    [[ -n "${_sig}" ]] || continue

    _seed_consumer "${_sig}"
    cd "${CONSUMER}"
    run bash "${INIT}"
    assert_success

    while IFS= read -r _p; do
      [[ ! -e "${CONSUMER}/${_p}" ]] \
        || fail "signal '${_sig}' is published but did not select the existing-repo path: ${_p} was scaffolded"
    done < <(_new_repo_only_paths)
  done < "${_signal_list}"
}

@test "a repo carrying a file the list does NOT publish is still scaffolded as new (#928)" {
  # The complement of the case above: presence alone must not decide, or the
  # published list would describe one file rather than state the rule.
  _seed_consumer "README.md"

  cd "${CONSUMER}"
  run bash "${INIT}"
  assert_success

  local _p
  while IFS= read -r _p; do
    assert [ -f "${CONSUMER}/${_p}" ]
  done < <(_new_repo_only_paths)
}

@test "the new-repo scaffold creates every published signal (#928)" {
  # A signal init does not itself install can never flip a repo from new to
  # existing, so it would have to be supplied by someone else -- which is
  # exactly how the template's shipped Dockerfile inverted the proxy.
  _seed_consumer

  cd "${CONSUMER}"
  run bash "${INIT}"
  assert_success

  local _sig
  while IFS= read -r _sig; do
    [[ -n "${_sig}" ]] || continue
    assert [ -f "${CONSUMER}/${_sig}" ]
  done < <(_signals)
}
