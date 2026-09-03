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
#   writes. Two of the three things base#928 measured as missing; the third
#   is the smoke tree, checked as a directory below.
_new_repo_only_paths() {
  cat <<'EOF'
.github/workflows/main.yaml
doc/changelog/CHANGELOG.md
EOF
}

# _hand_maintained_paths
#   Paths a repo of this family carries that NO scaffold writes -- hand-added
#   when the repo is created and maintained by its owner. They are the half
#   of the colliding population that scaffold output cannot reach: a template
#   snapshot ships everything a scaffold left behind PLUS these, and it was a
#   file in the union -- not a file in the scaffold's output -- that inverted
#   the `Dockerfile` proxy. Kept short and checked at use: each must exist in
#   base's own tree, and each must be absent from the scaffold's output.
_hand_maintained_paths() {
  cat <<'EOF'
LICENSE
CONTEXT.md
.gitattributes
.github/workflows/self-test.yaml
EOF
}

# why: The baseline base#928 broke: with no signal present the new-repo
# path must actually run, and the three artifacts it alone installs are
# the currency the outage was measured in.
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

# why: The anti-decay half. A published list nothing exercises is a second
# statement of the branch condition, and a second statement is what goes
# stale -- so every entry is run through a real init rather than trusted.
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

# why: The converse, without which the case above passes on a branch that
# treats ANY file as a signal: presence must not decide, the list must.
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

# why: The case that closes the class rather than one file. base#928 was a
# file joining the branch condition without joining the list, and the
# population has to include what no scaffold writes -- `Dockerfile` came
# from exactly that half.
@test "no file a repo can carry, scaffold output or not, can quietly become a signal (#928)" {
  # The generalisation of the case above, over the population that actually
  # collides. A template repo IS a repo of this family, so every file it
  # ships is a file the next new repo arrives carrying; any one of them
  # silently joining the branch condition without joining the published list
  # reproduces the inversion exactly. The hardcoded README.md above catches
  # one such file, this catches the class.
  #
  # The population is scaffold output PLUS what no scaffold writes. Scaffold
  # output alone is a strict SUBSET of what a template ships, and the subset
  # is the wrong half: `Dockerfile` inverted the proxy precisely because a
  # repo can carry a file its own scaffold never wrote. LICENSE is the
  # cheapest witness -- no scaffold emits one, every template ships one --
  # and a population defined as scaffold output cannot see it.
  #
  # The population reaches below the root as well. The three artifacts
  # base#928 measured as missing -- `.github/workflows/main.yaml`,
  # `doc/changelog/CHANGELOG.md`, the smoke tree -- all live there.
  #
  # Each candidate is put to `_init_repo_is_existing`, the predicate `main`
  # branches on, rather than to a full init: the two are the same statement
  # (`if _init_repo_is_existing; then _init_existing_repo; else
  # _create_new_repo`), and the whole population is then read off the
  # artifacts in ONE init below. A real init per candidate said nothing more
  # and cost the suite a minute of wall clock for a single case.
  _seed_consumer
  cd "${CONSUMER}"
  run bash "${INIT}"
  assert_success

  local _scaffolded="${BATS_TEST_TMPDIR}/scaffolded"
  rm -rf "${_scaffolded}"
  cp -a "${CONSUMER}" "${_scaffolded}"

  local _signal_list="${BATS_TEST_TMPDIR}/signals2"
  _signals > "${_signal_list}"

  # Half one, derived from a real scaffold rather than listed: whatever
  # today's new-repo path writes, minus the vendored subtree and git's own
  # internals (neither is scaffold output), minus what the repo's own
  # .gitignore claims (a derived artifact is not in a template snapshot),
  # and minus the published signals (which are supposed to decide).
  local _scaffold_out="${BATS_TEST_TMPDIR}/scaffold-out"
  : > "${_scaffold_out}"
  local _name
  while IFS= read -r _name; do
    _name="${_name#./}"
    [[ -n "${_name}" ]] || continue
    if grep -qxF "${_name}" "${_signal_list}"; then
      continue
    fi
    if git -C "${_scaffolded}" check-ignore -q -- "${_name}"; then
      continue
    fi
    printf '%s\n' "${_name}" >> "${_scaffold_out}"
  done < <(cd "${_scaffolded}" \
    && find . -mindepth 1 \( -path ./.git -o -path ./.base \) -prune -o \
      \( -type f -o -type l \) -print | LC_ALL=C sort)

  assert [ -s "${_scaffold_out}" ]
  # And it really does reach below the root -- otherwise this case would
  # pass while covering none of the paths base#928 measured.
  grep -q '/' "${_scaffold_out}" \
    || fail "scaffold-output population is root-only: the artifacts base#928 is about all live below the root"

  # Half two: paths a repo of this family carries that no scaffold writes.
  # Named, not derived -- the template is a different repo, and git cannot
  # enumerate the mounted /source worktree from in here (its .git is a file
  # pointing at a path the container cannot see). The two guards below are
  # what keep the naming honest.
  local _hand="${BATS_TEST_TMPDIR}/hand-maintained"
  : > "${_hand}"
  while IFS= read -r _name; do
    [[ -n "${_name}" ]] || continue
    # It is a path a real repo of this family carries, not a hypothetical.
    assert [ -e "/source/${_name}" ]
    # A named path that has since JOINED the published list is not an
    # unpublished candidate any more, so it is filtered out here exactly as
    # half one filters scaffold output. Without this the probe below reports
    # a legitimately published signal as one that quietly became a signal --
    # a failure whose message states the opposite of the truth.
    if grep -qxF "${_name}" "${_signal_list}"; then
      continue
    fi
    # And it is genuinely outside scaffold output, so the population is a
    # strict superset of it. If the scaffold starts emitting one of these,
    # this fails and the entry moves rather than quietly narrowing the case
    # back to the subset that could not see `Dockerfile` coming.
    if grep -qxF "${_name}" "${_scaffold_out}"; then
      fail "'${_name}' is scaffold output now, so it no longer widens the population past it: name a file the scaffold does not write"
    fi
    printf '%s\n' "${_name}" >> "${_hand}"
  done < <(_hand_maintained_paths)
  # Every named path having become a published signal narrows the population
  # back to scaffold output alone -- the wrong half, the one that could not
  # see `Dockerfile` coming. Name a replacement rather than pass on a subset.
  assert [ -s "${_hand}" ]

  local _candidates="${BATS_TEST_TMPDIR}/candidates"
  cat "${_scaffold_out}" "${_hand}" | LC_ALL=C sort -u > "${_candidates}"

  # Every candidate, one at a time, put to the predicate. Cheap enough to be
  # exhaustive, and it names the offender.
  run bash -c '
    set -uo pipefail
    _init="$1" _cands="$2" _probe="$3"
    # shellcheck disable=SC1090
    source "${_init}"
    # The predicate is called BY NAME below. Renamed, that call is a
    # command-not-found (127), which the if reads as "not existing" for
    # EVERY candidate -- zero offenders reported, case green, nothing
    # tested. Exit 2 says the probe never reached the branch at all.
    if ! declare -F _init_repo_is_existing >/dev/null; then
      printf "  %s defines no _init_repo_is_existing\n" "${_init}"
      exit 2
    fi
    _rc=0
    while IFS= read -r _name; do
      [[ -n "${_name}" ]] || continue
      rm -rf "${_probe:?}/repo"
      mkdir -p "${_probe}/repo/$(dirname -- "${_name}")"
      : > "${_probe}/repo/${_name}"
      if ( cd "${_probe}/repo" && _init_repo_is_existing ); then
        printf "  %s\n" "${_name}"
        _rc=1
      fi
    done < "${_cands}"
    exit "${_rc}"
  ' _ "${CONSUMER}/.base/dist/script/base/init.sh" "${_candidates}" \
    "${BATS_TEST_TMPDIR}/probe"
  [[ "${status}" -ne 2 ]] || fail "the probe never reached the branch predicate, so this case exercised nothing:
${output}"
  [[ "${status}" -eq 0 ]] || fail "these are not published signals, yet a repo carrying one is classified as already set up:
${output}"

  # And the branch really is that predicate, read off the artifacts. The
  # predicate is an OR over the published list, so a repo carrying EVERY
  # candidate at once takes the new-repo path exactly when a repo carrying
  # any single one does -- one init makes the whole population's statement
  # in the currency base#928 was measured in. The two new-repo-only
  # artifacts are held back from the seed: seeded, their presence afterwards
  # would prove nothing.
  _seed_consumer
  local _p _hold
  while IFS= read -r _name; do
    [[ -n "${_name}" ]] || continue
    _hold=0
    while IFS= read -r _p; do
      [[ "${_name}" != "${_p}" ]] || _hold=1
    done < <(_new_repo_only_paths)
    (( _hold == 0 )) || continue
    mkdir -p "${CONSUMER}/$(dirname -- "${_name}")"
    if [[ -e "${_scaffolded}/${_name}" ]]; then
      cp -a "${_scaffolded}/${_name}" "${CONSUMER}/${_name}"
    else
      cp -a "/source/${_name}" "${CONSUMER}/${_name}"
    fi
  done < "${_candidates}"

  cd "${CONSUMER}"
  run bash "${INIT}"
  assert_success

  while IFS= read -r _p; do
    [[ -f "${CONSUMER}/${_p}" ]] \
      || fail "a repo carrying only unpublished files was treated as already set up: ${_p} was never scaffolded"
  done < <(_new_repo_only_paths)
}

# why: The other direction of the same proxy. A signal init never installs
# can only ever be supplied by somebody else, which is precisely how the
# template's shipped Dockerfile inverted it.
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
