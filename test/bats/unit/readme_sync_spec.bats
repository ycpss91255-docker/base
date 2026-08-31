#!/usr/bin/env bats
#
# Unit tests for the localized-README drift guard: the generator
# script/test/sync-readme-hashes.sh (_sync_readme_hashes -- stamps each
# translated section with the hash of the English section it was translated
# against) and its read-only twin script/test/drivers/readme_sync.sh
# (_run_readme_sync -- the lint that reports a translation section whose
# recorded hash no longer matches the English source).
#
# The English author changes nothing; the translator never types a hash. The
# guard therefore has to answer three questions per translated file: is this
# section stale, is it missing, and is it deliberately untranslated.
#
# A fourth block answers the question the guard could not: does a re-stamp
# mean anything. It performs the silencing case -- edit the English, run the
# generator, expect the gate to go quiet -- rather than asserting on the
# marker format, because the format was never the defect; the missing
# translation-side record was.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live READMEs; a final pair of cases drives the REAL
# tree to prove it is stamped and clean today.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # stale_setup_conf_lint_spec.bats / issueref_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/readme_sync.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/readme"
  REPO_ROOT="${SCRATCH}"

  # The live checkout, for the two cases at the bottom that assert on the
  # tracked READMEs. Held in a variable so the capture helper has a seam the
  # cases exercising IT can point at a planted tree instead.
  LIVE_README_ROOT=/source
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _en <line>... -- write the scratch English README.
_en() {
  printf '%s\n' "$@" > "${SCRATCH}/README.md"
}

# _tr <lang> <line>... -- write a scratch translation.
_tr() {
  local _lang="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/doc/readme/README.${_lang}.md"
}

# _en_default -- the three-section English fixture every case starts from.
_en_default() {
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body.'
}

# _tr_default -- a translation carrying an id-only marker per section (what a
# translator writes by hand; the hash is the generator's job).
_tr_default() {
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '前言。' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲' \
    '' \
    '甲本文。' \
    '' \
    '<!-- sync: beta -->' \
    '## 乙' \
    '' \
    '乙本文。'
}

# _stamped -- the default fixture pair, stamped by the real generator.
_stamped() {
  _en_default
  _tr_default
  _sync_readme_hashes "${SCRATCH}" >/dev/null
}

# _en_beta_rewritten -- the English fixture with Beta's body rewritten in
# place. The heading survives, so only a content fingerprint sees it.
_en_beta_rewritten() {
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
}

# _tr_edit <lang> <old> <new> -- edit translated prose in place, the way a
# translator does: the stamped markers around it survive untouched.
_tr_edit() {
  local _lang="${1}" _old="${2}" _new="${3}"
  sed -i "s/${_old}/${_new}/" "${SCRATCH}/doc/readme/README.${_lang}.md"
}

# _marker <id> -- the stamped marker line for <id> in the zh-TW fixture.
_marker() {
  grep -E "^<!-- sync: ${1} " "${SCRATCH}/doc/readme/README.zh-TW.md"
}

# ════════════════════════════════════════════════════════════════════
# _run_readme_sync: the failure that motivated the guard
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: FAILS when an English section is rewritten in place and the translation is untouched (#846)" {
  _stamped
  # The heading survives, the body is rewritten -- the exact shape of the
  # drift a structural (headings-only) check cannot see.
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.zh-TW.md"* ]]
}

@test "_run_readme_sync: names the drifted SECTION, not just the file (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"beta"* ]]
  # The untouched sections must NOT be reported.
  [[ "${output}" != *"'alpha'"* ]]
}

@test "_run_readme_sync: FAILS on an English section with no marker in a translation (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body.' \
    '' \
    '## Gamma' \
    '' \
    'Gamma body.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"gamma"* ]]
  [[ "${output}" == *"MISSING"* ]]
}

@test "_run_readme_sync: PASSES a tree the generator has just stamped (#846)" {
  _stamped
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: PASSES again after an English edit, a re-translation and a re-run of the generator (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, rewritten and then re-translated.'
  _tr_edit zh-TW '乙本文。' '乙本文，已重譯。'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_readme_sync: untranslated sections, marker hygiene
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: EXEMPTS a section declared untranslated with sync-skip (#846)" {
  _en_default
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '前言。' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲' \
    '' \
    '甲本文。' \
    '' \
    '<!-- sync-skip: beta -- English-only reference section -->'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: FAILS on an UNSTAMPED marker (id written, generator never run) (#846)" {
  _en_default
  _tr_default
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"UNSTAMPED"* ]]
}

@test "_run_readme_sync: FAILS on a marker naming an id that is not an English section (#846)" {
  _stamped
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '## 甲' \
    '' \
    '<!-- sync: delta 000000000000 -->' \
    '## 丁' \
    '' \
    '<!-- sync-skip: beta -- untranslated -->'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"UNKNOWN"* ]]
  [[ "${output}" == *"delta"* ]]
}

@test "_run_readme_sync: FAILS on the same id claimed twice in one translation (#846)" {
  _stamped
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '## 甲' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '## 甲之二' \
    '' \
    '<!-- sync-skip: beta -- untranslated -->'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"DUPLICATE"* ]]
}

@test "_run_readme_sync: FAILS on a sync marker that is not followed by a heading (#846)" {
  _stamped
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '這不是標題。' \
    '' \
    '<!-- sync-skip: beta -- untranslated -->'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"MISPLACED"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Section identity and hash input
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: ignores ATX-looking lines inside fenced code blocks (#846)" {
  # README.md's TL;DR fences shell comments starting with '#'; treating them
  # as headings would invent sections that no translation can ever carry.
  _en \
    '# Title' \
    '' \
    '```bash' \
    '# Not a heading' \
    '## Also not a heading' \
    '```' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.'
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: trailing whitespace in the English body does not flip the hash (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.   ' \
    '' \
    '## Beta' \
    '' \
    'Beta body.' \
    ''
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: a nested subsection is its own section, the parent body stops at it (#846)" {
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '### Alpha detail' \
    '' \
    'Detail body.'
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲' \
    '' \
    '<!-- sync: alpha-detail -->' \
    '### 甲細節'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]

  # Editing ONLY the subsection must flag the subsection, not the parent.
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '### Alpha detail' \
    '' \
    'Detail body, rewritten.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"alpha-detail"* ]]
  [[ "${output}" != *"'alpha'"* ]]
}

@test "_run_readme_sync: FAILS when two English headings share one slug (ambiguous id) (#846)" {
  _en \
    '# Title' \
    '' \
    '## Alpha' \
    '' \
    'One.' \
    '' \
    '## alpha' \
    '' \
    'Two.'
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"AMBIGUOUS"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _sync_readme_hashes: the generator
# ════════════════════════════════════════════════════════════════════

@test "_sync_readme_hashes: stamps an id-only marker with the English section hash (#846)" {
  _en_default
  _tr_default
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -eq 0 ]
  run grep -E '^<!-- sync: alpha [0-9a-f]{12} [0-9a-f]{12} -->$' \
    "${SCRATCH}/doc/readme/README.zh-TW.md"
  [ "${status}" -eq 0 ]
}

@test "_sync_readme_hashes: re-stamps a stale hash (#846)" {
  _stamped
  before="$(_marker beta)"
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, rewritten.'
  _tr_edit zh-TW '乙本文。' '乙本文，已重譯。'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  [[ "$(_marker beta)" != "${before}" ]]
}

@test "_sync_readme_hashes: is idempotent on an already-stamped tree (#846)" {
  _stamped
  a="$(cat "${SCRATCH}/doc/readme/README.zh-TW.md")"
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  b="$(cat "${SCRATCH}/doc/readme/README.zh-TW.md")"
  [[ "${a}" == "${b}" ]]
}

@test "_sync_readme_hashes: leaves the translated prose untouched (stamps only markers) (#846)" {
  _stamped
  run grep -c '甲本文。' "${SCRATCH}/doc/readme/README.zh-TW.md"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "1" ]]
}

@test "_sync_readme_hashes: reports the sections a translation is still missing (#846)" {
  _en_default
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題'
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"alpha"* ]]
  [[ "${output}" == *"beta"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _sync_readme_hashes: a re-stamp has to mean something
#
# The generator records the ENGLISH hash. On its own that makes "I updated
# the translation, then synced" indistinguishable from "I synced so the gate
# would stop complaining". These cases PERFORM the silencing attempt and
# assert it does not end in a green tree.
# ════════════════════════════════════════════════════════════════════

@test "_sync_readme_hashes: REFUSES to re-stamp a section whose English moved while the translation did not (#873)" {
  _stamped
  before="$(_marker beta)"
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"beta"* ]]
  # The recorded hash must NOT have moved: a refusal that still wrote the
  # new hash would be the silencing case with extra steps.
  [[ "$(_marker beta)" == "${before}" ]]
}

@test "_sync_readme_hashes: an English-only edit plus a sync run leaves the lint RED (#873)" {
  _stamped
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -ne 0 ]
  # The whole point: running the generator did not buy a green tree.
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"beta"* ]]
}

@test "_sync_readme_hashes: refusing one section still stamps the untouched ones (#873)" {
  _en_default
  _tr_default
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -ne 0 ]
  # alpha never drifted, so it stays stamped and is not named.
  [[ "${output}" != *"'alpha'"* ]]
  run _run_readme_sync
  [[ "${output}" != *"'alpha'"* ]]
}

@test "_sync_readme_hashes: re-stamps when the translation moved together with the English (#873)" {
  _stamped
  _en_beta_rewritten
  _tr_edit zh-TW '乙本文。' '乙本文，已重寫。'
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -eq 0 ]
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_sync_readme_hashes: --accept records a reviewed no-op and clears the lint (#873)" {
  # The accepted cost from the guard's introduction: an English typo fix
  # marks the translations stale and the human confirms nothing needs
  # re-translating. That must stay one command -- an EXPLICIT one.
  _stamped
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}" beta
  [ "${status}" -eq 0 ]
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_sync_readme_hashes: --accept clears only the section it names (#873)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body, rewritten too.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
  run _sync_readme_hashes "${SCRATCH}" beta
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"alpha"* ]]
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"alpha"* ]]
}

@test "_sync_readme_hashes: records the translation's own hash beside the English one (#873)" {
  _stamped
  run grep -E '^<!-- sync: beta [0-9a-f]{12} [0-9a-f]{12} -->$' \
    "${SCRATCH}/doc/readme/README.zh-TW.md"
  [ "${status}" -eq 0 ]
}

@test "_run_readme_sync: FAILS when the translated prose changed since it was stamped (#873)" {
  # Without this the recorded translation hash goes stale, and a later
  # English edit would read the un-stamped translation edit as evidence of
  # a re-translation it never was.
  _stamped
  _tr_edit zh-TW '乙本文。' '乙本文，微調過。'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"UNRECORDED"* ]]
  [[ "${output}" == *"beta"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Fail-loud guards: never pass vacuously
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: FAILS when the English README is missing (#846)" {
  _tr_default
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md"* ]]
}

@test "_run_readme_sync: FAILS when no translation files are found (#846)" {
  _en_default
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/readme"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: the REAL doc/readme/ tree is stamped and clean today (#846)" {
  REPO_ROOT="/source"
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ── the real tree, captured as a snapshot the spec owns ──────────────
#
# The two cases below are the only ones that read the tracked READMEs, and
# they used to let the live tree settle their verdict directly:
# `diff -r /source/doc/readme "${SCRATCH}/doc/readme"`. This suite runs
# 32-way parallel, often beside another checkout's gate, so anything that
# wrote under doc/readme/ in the window changed the answer on a generator
# that had done nothing wrong -- one of the two races this file was changed
# for.
#
# Copying first fixed the diff but not the capture. Four sequential reads
# of a tree nobody here owns can return a README.md the translations beside
# it were never stamped against, and the generator does exactly the right
# thing with that input: it REFUSES to re-stamp an English section whose
# translation did not follow, because that is the drift it exists to catch.
# The spec then reports a defect in the subject that was really a defect in
# the capture. (Reading the four files out of the git object store would be
# race-free by construction and was rejected on evidence: this checkout is
# a worktree, so /source/.git is a FILE pointing at a gitdir that is not
# mounted into the container, and `git show HEAD:README.md` would work in
# CI and fail locally.)

# _copy_readme_set <src-root> <dst-root> -- one pass over the four tracked
# README files.
_copy_readme_set() {
  local _src="${1:?BUG: _copy_readme_set expects a source root}"
  local _dst="${2:?BUG: _copy_readme_set expects a destination root}"
  mkdir -p "${_dst}/doc/readme"
  cp "${_src}/README.md" "${_dst}/README.md"
  local _lang
  for _lang in zh-TW zh-CN ja; do
    cp "${_src}/doc/readme/README.${_lang}.md" \
       "${_dst}/doc/readme/README.${_lang}.md"
  done
}

# _capture_readme_baseline <dst-root> [src-root] -- capture the live README
# set as a CONSISTENT snapshot the spec owns.
#
# Two passes, and the capture is only accepted when they agree. A writer
# landing inside the first pass leaves it holding some files from before
# the write and some from after; the second pass, made entirely after that
# write, cannot reproduce the same mixture, so the two disagree and the
# capture is retried. Agreement is therefore evidence that nothing wrote
# across either pass, which is what makes the accepted set a snapshot.
#
# Both operands of that comparison are the spec's own copies -- never the
# live tree -- which is the invariant spec_source_isolation_spec.bats pins
# repo-wide, and it holds here for the same reason it exists: a check that
# consults the live tree cannot tell a torn read from a real change.
#
# A source that never settles is a loud failure, not a skip and not a
# guess: three disagreeing pairs means something is actively rewriting the
# checkout, and the honest answer is that this spec has nothing to assert
# on today.
_capture_readme_baseline() {
  local _dst="${1:?BUG: _capture_readme_baseline expects a destination root}"
  local _src="${2:-${LIVE_README_ROOT}}"
  local _probe="${_dst}.probe"
  local _attempt
  for _attempt in 1 2 3; do
    _copy_readme_set "${_src}" "${_dst}"
    _copy_readme_set "${_src}" "${_probe}"
    if diff -r "${_dst}" "${_probe}" >/dev/null 2>&1; then
      return 0
    fi
  done
  fail "the README set under ${_src} changed across three consecutive captures; there is no snapshot to assert on, and guessing which read was the real one is how a correct generator gets reported as broken"
}

# _assert_generator_is_a_noop_on <baseline-dir> -- give the generator bytes
# it has already stamped, and require the same bytes back.
#
# Both sides of the comparison are the spec's own: the baseline it captured
# and the copy it stamped. The live tree supplies the INPUT and nothing
# else.
_assert_generator_is_a_noop_on() {
  local _baseline="${1:?BUG: _assert_generator_is_a_noop_on expects a directory}"
  cp "${_baseline}/README.md" "${SCRATCH}/README.md"
  local _lang
  for _lang in zh-TW zh-CN ja; do
    cp "${_baseline}/doc/readme/README.${_lang}.md" \
       "${SCRATCH}/doc/readme/README.${_lang}.md"
  done

  _sync_readme_hashes "${SCRATCH}" >/dev/null
  _assert_same_tree "${_baseline}/doc/readme" "${SCRATCH}/doc/readme"
}

# _assert_same_tree <expected> <actual> -- equal, and SAY WHAT DIFFERED.
#
# The comparison used to be `run diff ...` followed by `[ "${status}" -eq 0
# ]`, which threw ${output} away. When it failed, bats printed
# `[ "${status}" -eq 0 ]' failed and nothing else -- which is verbatim the
# symptom quoted in issue #965, and the reason its reader concluded "flake"
# and re-ran rather than read. The diff itself named a sync stamp whose
# second hash differed, i.e. a verdict about the generator.
#
# A failure that does not carry its evidence teaches re-running. That is the
# habit this whole issue exists to break, so it costs one line to close.
_assert_same_tree() {
  local _expected="${1:?BUG: _assert_same_tree expects an expected tree}"
  local _actual="${2:?BUG: _assert_same_tree expects an actual tree}"
  local _diff
  _diff="$(diff -r "${_expected}" "${_actual}" 2>&1)" && return 0
  fail "the generator did not return the bytes it was given:
${_diff}"
}

# _plant_readme_source <dir> -- a four-file stand-in for the tracked set.
# The capture helper does not read the CONTENT, so the cases that drive it
# do not need the real READMEs and do not pay for copying them.
_plant_readme_source() {
  local _dir="${1:?BUG: _plant_readme_source expects a directory}"
  mkdir -p "${_dir}/doc/readme"
  printf 'english v1\n' > "${_dir}/README.md"
  local _lang
  for _lang in zh-TW zh-CN ja; do
    printf 'translation v1\n' > "${_dir}/doc/readme/README.${_lang}.md"
  done
}

@test "_assert_same_tree: a failure names WHAT differed, not just that something did (#965)" {
  # The oracle the no-op assertion below settles its verdict with. Its
  # earlier spelling captured the diff and discarded it, so the failure read
  # `[ "${status}" -eq 0 ]' failed and nothing else -- the exact line issue
  # #965 quotes from the run that sent its reader down the flake path.
  #
  # Both directions, because a helper that always fails would satisfy the
  # first half on its own.
  local _a="${BATS_TEST_TMPDIR}/same_a" _b="${BATS_TEST_TMPDIR}/same_b"
  mkdir -p "${_a}" "${_b}"
  printf '<!-- sync: directory-structure aaaaaaa -->\n' > "${_a}/README.zh-TW.md"
  printf '<!-- sync: directory-structure bbbbbbb -->\n' > "${_b}/README.zh-TW.md"
  run _assert_same_tree "${_a}" "${_b}"
  assert_failure
  assert_output --partial "README.zh-TW.md"
  assert_output --partial "aaaaaaa"
  assert_output --partial "bbbbbbb"
  cp "${_a}/README.zh-TW.md" "${_b}/README.zh-TW.md"
  run _assert_same_tree "${_a}" "${_b}"
  assert_success
}

@test "_sync_readme_hashes: is a no-op on the REAL tree (already stamped) (#846)" {
  # Run the generator against a copy so the live tree is never mutated by a
  # test; an already-stamped tree must come back byte-identical.
  local _baseline="${BATS_TEST_TMPDIR}/baseline"
  _capture_readme_baseline "${_baseline}"
  _assert_generator_is_a_noop_on "${_baseline}"
}

@test "_capture_readme_baseline: a capture the source changed under is DISCARDED, not used (#965)" {
  # The race, made deterministic: `cp` is shadowed so the write lands at a
  # fixed point -- immediately after the first pass has read README.md and
  # before it reads the translations -- instead of being waited for.
  local _src="${BATS_TEST_TMPDIR}/src"
  _plant_readme_source "${_src}"

  local _tear_armed=1
  cp() {
    command cp "$@"
    if [[ "${_tear_armed}" == 1 && "${1}" == "${_src}/README.md" ]]; then
      _tear_armed=0
      printf 'english v2\n' > "${_src}/README.md"
    fi
  }

  local _baseline="${BATS_TEST_TMPDIR}/baseline"
  _capture_readme_baseline "${_baseline}" "${_src}"
  unset -f cp

  # v1 is the torn read: README.md from before the write, translations from
  # after it. Accepting it is the defect; the capture has to come back with
  # the set as it stands.
  run cat "${_baseline}/README.md"
  assert_output "english v2"
}

@test "_capture_readme_baseline: a source that never settles FAILS loudly, it does not hand back a torn set (#965)" {
  # The other outcome, and the reason the retry is bounded. A checkout being
  # rewritten continuously cannot produce a snapshot, and a spec that
  # quietly picks one of the reads reports the generator as broken. Three
  # tries, then say so.
  local _src="${BATS_TEST_TMPDIR}/src"
  _plant_readme_source "${_src}"

  # Starts at 1, not 0: the planted source already says v1, so a counter
  # starting there would "rewrite" it with its own contents and the two
  # passes would agree on a tree that never actually settled.
  local _n=1
  cp() {
    command cp "$@"
    if [[ "${1}" == "${_src}/README.md" ]]; then
      _n=$(( _n + 1 ))
      printf 'english v%s\n' "${_n}" > "${_src}/README.md"
    fi
  }

  run _capture_readme_baseline "${BATS_TEST_TMPDIR}/baseline" "${_src}"
  unset -f cp

  assert_failure
  assert_output --partial "changed across three consecutive captures"
}
