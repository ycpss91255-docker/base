#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/derived_figures.sh -- the "a figure a
# document repeats must match the code that defines it" lint.
#
# Two figures had drifted, each in more than one place, which is what makes
# a hand fix the wrong answer: the baseline stage blocklist was written as a
# five-element set including `devel-test` in the README, in two of
# stage.sh's own docstrings, in all three localized READMEs and in all four
# setup_tui.sh message tables, while `_validate_stage_name` blocklists four
# names plus two legacy aliases and deliberately lets `devel-test` through;
# and README.md's setup.conf overview announced seven sections while
# SCHEMA_SECTIONS declared fourteen.
#
# So the lint derives both figures from the code -- the baseline renderings
# by reading `_validate_stage_name`'s own `return 2` case arms and probing
# each name back through the predicate, the section list straight out of
# SCHEMA_SECTIONS -- and fails on any prose that disagrees.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL tree
# to prove it passes today. Shape mirrors stale_setup_conf_lint_spec.bats /
# home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die, and reads
  # _validate_stage_name / SCHEMA_SECTIONS out of the shipped lib; provide
  # all of them so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/derived_figures.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script/docker/lib" "${SCRATCH}/doc/readme" \
    "${SCRATCH}/script/test"
  REPO_ROOT="${SCRATCH}"

  # A tree that passes, so each case perturbs exactly one thing.
  _write_drift_libs
  _write_readme
  _write_runner
  _write_test_justfile
  printf '%s\n' '# CONTEXT' > "${SCRATCH}/CONTEXT.md"
  printf '%s\n' '#!/usr/bin/env bash' \
    > "${SCRATCH}/dist/script/docker/lib/sample.sh"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_readme [extra-line]... -- a scratch README.md whose setup.conf
# overview agrees with SCHEMA_SECTIONS, plus any extra prose lines.
_write_readme() {
  {
    printf '# base\n\n### One conf, %s sections\n\n```\n' \
      "${#SCHEMA_SECTIONS[@]}"
    local _section
    for _section in "${SCHEMA_SECTIONS[@]}"; do
      printf '[%s]    key = value\n' "${_section}"
    done
    printf '```\n\n'
    if [[ $# -gt 0 ]]; then
      printf '%s\n' "$@"
    fi
    printf '\n%s\n' "$(_drift_sections)"
  } > "${SCRATCH}/README.md"
}

# _drift_sections [stored-keys-sentence] -- the two sections figure 4 pins,
# in the English original's shape (headings, no sync markers). The default
# body agrees with the scratch libs _write_drift_libs writes.
_drift_sections() {
  local _stored="${1:-Stores \`SETUP_CONF_HASH\` and \`SETUP_GUI_DETECTED\`.}"
  printf '%s\n' \
    '### When setup.sh runs' \
    '' \
    '- **Drift**: every build runs `setup.sh check-drift` first.' \
    '' \
    '### Drift detection' \
    '' \
    "${_stored}" \
    '' \
    '### Next section'
}

# _write_localized <locale> [stored-keys-sentence] -- a localized README in
# the shape readme-sync stamps: a `<!-- sync: <id> ... -->` marker above each
# translated heading, which is how figure 4 addresses a section in a language
# it cannot read.
_write_localized() {
  local _loc="${1}"
  local _stored="${2:-Stores \`SETUP_CONF_HASH\` and \`SETUP_GUI_DETECTED\`.}"
  printf '%s\n' \
    '<!-- sync: base aaaaaaaaaaaa bbbbbbbbbbbb -->' \
    '# base' \
    '' \
    '<!-- sync: when-setupsh-runs aaaaaaaaaaaa bbbbbbbbbbbb -->' \
    '### translated trigger list' \
    '' \
    '- **Drift**: `setup.sh check-drift`' \
    '' \
    '<!-- sync: drift-detection aaaaaaaaaaaa bbbbbbbbbbbb -->' \
    '### translated drift heading' \
    '' \
    "${_stored}" \
    '' \
    '<!-- sync: tests aaaaaaaaaaaa bbbbbbbbbbbb -->' \
    '## translated tests' \
    > "${SCRATCH}/doc/readme/README.${_loc}.md"
}

# _write_drift_libs -- the three shipped libs figure 4 derives from: the
# read-back patterns that decide the compared set, the SETUP_* writes that
# decide the inert candidates, and the wrapper's drift subcommand.
_write_drift_libs() {
  local _lib="${SCRATCH}/dist/script/docker/lib"
  {
    printf '%s\n' '#!/usr/bin/env bash' '_check_setup_drift() {'
    printf '%s\n' \
      '  _stored_hash="$(grep -oP '"'"'^SETUP_CONF_HASH=\K.*'"'"' "${_env}")"' \
      '  _stored_gui="$(grep -oP '"'"'^SETUP_GUI_DETECTED=\K.*'"'"' "${_env}")"' \
      '}'
  } > "${_lib}/drift.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'write_env() {' '  cat <<EOF' \
      'SETUP_CONF_HASH=${_h}' 'SETUP_GUI_DETECTED=${_g}' \
      'SETUP_TIMESTAMP=${_t}' 'EOF' '}'
  } > "${_lib}/env_emit.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    '  "${_setup}" check-drift --base-path "${_p}"' > "${_lib}/wrapper.sh"
}

# _write_runner [coverage-flag] -- a scratch script/test/test.sh carrying the
# two things figure 3 derives from it: the coverage argument every
# `_run_via_compose ci` call passes, and the _LINT_TOOLS table.
_write_runner() {
  local _cov="${1:-0}"
  local _lint_under_coverage="${2:-0}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'readonly _LINT_TOOLS=('
    printf '%s\n' '  shellcheck' '  hadolint' '  issueref' ')'
    printf '  _run_via_compose ci %s\n' "${_cov}"
    # The guard the coverage-entry rule reads: COVERAGE named in the
    # condition around the phase call is what makes a coverage run skip it.
    if [[ "${_lint_under_coverage}" == '1' ]]; then
      printf '%s\n' 'if [[ "${BATS_ONLY:-0}" != "1" ]]; then' \
        '  _run_all_lint_tools' 'fi'
    else
      printf '%s\n' \
        'if [[ "${BATS_ONLY:-0}" != "1" && "${COVERAGE:-0}" != "1" ]]; then' \
        '  _run_all_lint_tools' 'fi'
    fi
  } > "${SCRATCH}/script/test/test.sh"
}

# _write_test_justfile -- a scratch script/test/justfile.test whose recipe
# lines are the subcommand vocabulary figure 3 reads.
_write_test_justfile() {
  printf '%s\n' 'default:' '    ./script/test/test.sh' \
    'lint *args:' '    ./script/test/test.sh --lint' \
    "coverage shard='':" '    ./script/test/test.sh --coverage' \
    > "${SCRATCH}/script/test/justfile.test"
}

# _append <relative-path> <line>... -- add prose to a scratch file.
_append() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" >> "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _derived_baseline_renderings: the canonical set, read from the code
# ════════════════════════════════════════════════════════════════════

@test "_derived_baseline_renderings: derives the forward-looking and legacy sets from _validate_stage_name (#874)" {
  run _derived_baseline_renderings
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"{sys, devel-base, devel, runtime-test}"* ]]
  [[ "${output}" == *"{base, test}"* ]]
}

@test "_derived_baseline_renderings: does NOT include devel-test -- the predicate emits it as a service (#874)" {
  # The whole point of the drift: devel-test is emitted as the `test`
  # service, so a set that lists it tells a reader the service does not
  # exist.
  run _derived_baseline_renderings
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"devel-test"* ]]
}

@test "_derived_baseline_renderings: every derived name probes back as a baseline collision (#874)" {
  # The extractor reads case arms; the probe is what proves it read them
  # right. A name that does not return 2 means the extraction is wrong,
  # and the driver must say so rather than pin prose to a bad set.
  local _name _rc
  while read -r _name; do
    _rc=0
    _validate_stage_name "${_name}" || _rc=$?
    [ "${_rc}" -eq 2 ]
  done < <(_derived_baseline_names)
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: the baseline stage set
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: FAILS on a README baseline set that lists devel-test, naming file and line (#874)" {
  _write_readme 'Any stage outside the blocklist' \
    '{sys, devel-base, devel, devel-test, runtime-test} is auto-emitted.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md:"* ]]
  [[ "${output}" == *"devel-test"* ]]
  [[ "${output}" == *"{sys, devel-base, devel, runtime-test}"* ]]
}

@test "_run_derived_figures: PASSES on the canonical forward-looking and legacy renderings (#874)" {
  _write_readme 'Outside `{sys, devel-base, devel, runtime-test}` (legacy' \
    '`{base, test}` also accepted) a stage is auto-emitted.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_derived_figures: ignores a brace set that names no baseline stage (#874)" {
  _write_readme 'Isaac Sim adds `{headless, gui}` on top of devel.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_derived_figures: catches a stale set wrapped across markdown lines (#874)" {
  # The live drift was wrapped in all four READMEs, so a line-at-a-time
  # matcher would have reported none of them.
  _write_readme 'Outside the blocklist `{sys, devel-base, devel, devel-test,' \
    'runtime-test}` a stage is auto-emitted.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md:"* ]]
}

@test "_run_derived_figures: catches a stale set split by an escaped newline in a shell string (#874)" {
  # setup_tui.sh's four message tables wrap the set with a literal \n
  # inside a $'...' string -- the same drift, in the surface a user
  # actually reads at the TUI.
  _append "dist/script/docker/lib/sample.sh" \
    "_MSG[per_stage.empty]=\$'baseline {sys, devel-base, devel, devel-test,\\nruntime-test} is reserved.'"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:"* ]]
}

@test "_run_derived_figures: catches a stale set wrapped across two shell comment lines (#874)" {
  # stage.sh's own docstring wraps the set over a `#` continuation, so the
  # comment marker has to be dropped before the join or it lands inside
  # the set and the whole literal reads as prose.
  _append "dist/script/docker/lib/sample.sh" \
    '# filters out the baseline blocklist {sys, devel-base, devel,' \
    '# devel-test, runtime-test} and echoes the rest.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:"* ]]
}

@test "_run_derived_figures: ignores a brace EXPANSION glued to a path (#874)" {
  # `test/bats/smoke/{shared,devel-test,runtime-test}/` is a real directory
  # layout, not a prose set -- rewriting it to the baseline would be
  # nonsense.
  _append "dist/script/docker/lib/sample.sh" \
    'Specs live under test/bats/smoke/{shared,devel-test,runtime-test}/.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_derived_figures: scans CONTEXT.md and the localized READMEs too (#874)" {
  printf '%s\n' '# CONTEXT' 'A baseline stage is `{devel, devel-test}`.' \
    > "${SCRATCH}/CONTEXT.md"
  _append "doc/readme/README.zh-TW.md" \
    'baseline blocklist `{sys, devel-base, devel, devel-test, runtime-test}`'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CONTEXT.md:"* ]]
  [[ "${output}" == *"doc/readme/README.zh-TW.md:"* ]]
}

@test "_run_derived_figures: ignores a \${VAR} expansion that is not a stage set (#874)" {
  _append "dist/script/docker/lib/sample.sh" \
    '_conf="${_root}/.setup.conf"' \
    'printf "%s" "${_stage}"'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: the setup.conf section list
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: FAILS when the README section count disagrees with SCHEMA_SECTIONS (#874)" {
  sed -i "s/^### One conf, .* sections$/### One conf, seven sections/" \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"One conf"* ]]
}

@test "_run_derived_figures: FAILS when the count is a number but the wrong one (#874)" {
  sed -i "s/^### One conf, .* sections$/### One conf, 7 sections/" \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${#SCHEMA_SECTIONS[@]}"* ]]
}

@test "_run_derived_figures: FAILS when the listed sections differ from SCHEMA_SECTIONS (#874)" {
  # The count is only the list's length; a block that drops [security] and
  # invents [extras] keeps the length and is still wrong.
  sed -i 's/^\[security\]    key = value$/[extras]    key = value/' \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"security"* ]]
}

@test "_run_derived_figures: FAILS when the listed sections are out of template order (#874)" {
  # Swap the first two entries through a sentinel, so the second
  # expression cannot undo the first.
  sed -i 's/^\[image\]/[swap]/; s/^\[build\]/[image]/; s/^\[swap\]/[build]/' \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
}

@test "_run_derived_figures: FAILS when the section heading is absent (no vacuous pass) (#874)" {
  sed -i '/^### One conf, /d' "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"One conf"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: scan-surface guard
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: FAILS when a required doc file is missing (no vacuous pass) (#874)" {
  rm -f "${SCRATCH}/CONTEXT.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CONTEXT.md"* ]]
}

@test "_run_derived_figures: FAILS when the dist/ scan root is missing (no vacuous pass) (#874)" {
  rm -rf "${SCRATCH}/dist"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: what the DEFAULT self-test runs (figure 3)
# ════════════════════════════════════════════════════════════════════

# why: The figure itself. Read it wrong and every rule built on it is wrong in
#       the same direction, silently -- so the derivation is pinned in both
#       states of the code, not just the one the tree is in today
@test "_derived_default_coverage: reads the flag off the _run_via_compose ci calls (base#1121)" {
  local _cov=''
  _derived_default_coverage _cov
  [ "${_cov}" = "0" ]
  _write_runner 1
  _derived_default_coverage _cov
  [ "${_cov}" = "1" ]
}

# why: An ambiguous figure must refuse. Picking a side would hold prose to a
#       guess, which is worse than holding it to nothing
@test "_derived_default_coverage: REFUSES when the calls disagree (base#1121)" {
  # An ambiguous figure must refuse rather than pick a side -- prose held to
  # a guess is worse than prose held to nothing.
  printf '  _run_via_compose ci 1\n' >> "${SCRATCH}/script/test/test.sh"
  local _cov=''
  run _derived_default_coverage _cov
  [ "${status}" -ne 0 ]
}

# why: The vocabulary decides which examples are ABOUT the default run; a
#       recipe the parser misses turns a narrowed example into a false positive
@test "_derived_test_subcommands: derives the vocabulary from the recipe lines (base#1121)" {
  run _derived_test_subcommands
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"default"* ]]
  [[ "${output}" == *"lint"* ]]
  [[ "${output}" == *"coverage"* ]]
}

# why: The defect this figure exists for -- eight annotations on the repo's
#       most-read page claimed a coverage run the dispatch cannot reach
@test "_run_derived_figures: FAILS when a bare just test is documented as running kcov (base#1121)" {
  _write_readme '```bash' 'just test   # ShellCheck + Bats + Kcov' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md:"* ]]
  [[ "${output}" == *"coverage 0"* ]]
}

# why: The corrected wording has to be expressible. A rule that banned the word
#       would force the docs to drop the one fact a reader wants
@test "_run_derived_figures: PASSES when the annotation says the default has no kcov (base#1121)" {
  _write_readme '```bash' 'just test   # ShellCheck + Hadolint + Bats (no kcov)' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: The rule is the figure, not a ban on a word: flipping the code must flip
#       which prose is wrong, or this is a hardcoded string check wearing a
#       derivation
@test "_run_derived_figures: FAILS when the default DOES measure coverage and the annotation omits it (base#1121)" {
  # The rule is the figure, not a ban on the word: flip the code and the
  # same prose becomes the violation.
  _write_runner 1
  _write_readme '```bash' 'just test   # ShellCheck + Hadolint + Bats' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not say so"* ]]
}

# why: The load-bearing exclusion. `just test coverage` SHOULD say Kcov, and a
#       rule that flagged it would be reverted within a day
@test "_run_derived_figures: a documented subcommand is not the default run (base#1121)" {
  _write_readme '```bash' 'just test coverage   # Full run, under Kcov' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: Same exclusion through the other channel the runner is narrowed by, so
#       the dispatcher's own --coverage examples stay legal
@test "_run_derived_figures: a flag is not the default run either (base#1121)" {
  # Named without a linter, because the coverage-entry rule below has its own
  # case: this one is only about the default-run question.
  _write_readme '```bash' './test.sh --coverage   # Bats under kcov' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: The second shape the repo documents commands with. Covering only the
#       fenced-example shape would leave every `just --list` description ungated
@test "_run_derived_figures: reads the recipe-comment shape too (base#1121)" {
  _append 'script/test/justfile.test' \
    '# just test -> run the whole self-test (ShellCheck + Bats + Kcov)'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"justfile.test:"* ]]
}

# why: The anchor, and the reason there is one: the dispatcher's --jobs refusal
#       names kcov and `just test` in one sentence while claiming neither
@test "_run_derived_figures: a mention inside running prose is not an annotation (base#1121)" {
  # The anchor is what keeps the rule off sentences that merely talk about
  # the command -- the dispatcher's own --jobs refusal is one.
  _write_readme \
    'The kcov process count means nothing on its own: bare `just test`' \
    'already runs bats in parallel.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: The second half of the same drift -- the lint phase runs the whole table,
#       and an annotation naming one binary describes a narrowed run
@test "_run_derived_figures: FAILS when the bare lint phase is documented as ShellCheck alone (base#1121)" {
  _write_readme '```bash' 'just test lint   # ShellCheck only' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"shellcheck alone"* ]]
}

# why: The corrected wording again, so the rule cannot be satisfied only by
#       deleting the tool names
@test "_run_derived_figures: PASSES when the lint annotation names both binaries (base#1121)" {
  _write_readme '```bash' 'just test lint   # Every linter (ShellCheck + Hadolint + the rest)' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: `just test lint --shellcheck` legitimately IS ShellCheck only; flagging
#       it would make the rule wrong about the one case it is right about
@test "_run_derived_figures: a narrowed lint run may name one linter (base#1121)" {
  _write_readme '```bash' 'just test lint --shellcheck   # ShellCheck only' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: Without the recipe file the vocabulary is empty and every documented
#       subcommand reads as the default run -- the lint must refuse, not scan
@test "_run_derived_figures: FAILS when the recipe file is missing (no vacuous pass) (base#1121)" {
  rm -f "${SCRATCH}/script/test/justfile.test"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"justfile.test"* ]]
}

# why: An unparsed table makes the lint-phase rule inert while reporting clean,
#       which is how a guard quietly stops guarding
@test "_run_derived_figures: FAILS when the _LINT_TOOLS table cannot be read (no vacuous pass) (base#1121)" {
  printf '%s\n' '#!/usr/bin/env bash' '  _run_via_compose ci 0' \
    > "${SCRATCH}/script/test/test.sh"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"_LINT_TOOLS"* ]]
}

# why: The rule must not be steppable-out-of: adding a word justfile.test does
#       not define dispatches nowhere, so the example still describes the bare run
@test "_run_derived_figures: a token that is not a recipe is still the default run (base#1121)" {
  # The vocabulary is what stops the rule from being stepped out from under:
  # `just test` plus a word justfile.test does not define dispatches
  # nowhere, so the example is still describing the bare run.
  _write_readme '```bash' 'just test nosuchrecipe   # ShellCheck + Bats + Kcov' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"coverage 0"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: the drift-detection key set (figure 4)
# ════════════════════════════════════════════════════════════════════

# why: The set the completeness rule is built on, including the negative half --
#       a key written but never read back must not come through as compared
@test "_derived_drift_keys: derives the compared set from the read-back patterns (base#1121)" {
  run _derived_drift_keys
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SETUP_CONF_HASH"* ]]
  [[ "${output}" == *"SETUP_GUI_DETECTED"* ]]
  [[ "${output}" != *"SETUP_TIMESTAMP"* ]]
}

# why: The candidate set for the soundness rule; empty, and naming an inert key
#       in a section about comparison would go unreported
@test "_derived_setup_metadata_keys: derives the written namespace from env_emit (base#1121)" {
  run _derived_setup_metadata_keys
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SETUP_TIMESTAMP"* ]]
}

# why: The name is read, not stored, so renaming the subcommand moves what the
#       trigger list has to say instead of leaving a stale word behind
@test "_derived_wrapper_drift_subcommand: reads the name out of the wrapper (base#1121)" {
  local _sub=''
  _derived_wrapper_drift_subcommand _sub
  [ "${_sub}" = "check-drift" ]
}

# why: Two candidates means the name to document is undecidable, and a guess
#       would pin prose to the wrong one
@test "_derived_wrapper_drift_subcommand: REFUSES when the wrapper names two (base#1121)" {
  printf '%s\n' '  "${_setup}" probe-drift' \
    >> "${SCRATCH}/dist/script/docker/lib/wrapper.sh"
  local _sub=''
  run _derived_wrapper_drift_subcommand _sub
  [ "${status}" -ne 0 ]
}

# why: The defect: the section named three of five, so the trigger a maintainer
#       adding a stage comes looking for was not there
@test "_run_derived_figures: FAILS when the drift section omits a compared key (base#1121)" {
  _write_readme
  sed -i 's/^Stores `SETUP_CONF_HASH` and `SETUP_GUI_DETECTED`\.$/Stores `SETUP_CONF_HASH`./' \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"SETUP_GUI_DETECTED"* ]]
  [[ "${output}" == *"reads back and compares"* ]]
}

# why: The soundness half. An inert key listed among the compared ones is read
#       as compared, which is how the section claimed a timestamp was a trigger
@test "_run_derived_figures: FAILS when the drift section names a key nothing compares (base#1121)" {
  # SETUP_TIMESTAMP is written and never read back; in a section about
  # comparison it reads as compared.
  _write_readme
  sed -i 's/^Stores `SETUP_CONF_HASH` and `SETUP_GUI_DETECTED`\.$/Stores `SETUP_CONF_HASH`, `SETUP_GUI_DETECTED` and `SETUP_TIMESTAMP`./' \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nothing compares"* ]]
}

# why: Proves the rule follows the code rather than a transcription of it:
#       teaching drift.sh a sixth key makes clean prose the violation
@test "_run_derived_figures: a key added to the comparison moves the requirement (base#1121)" {
  # The rule follows the code: teach drift.sh to read a third key and the
  # prose that was clean becomes the violation.
  printf '%s\n' \
    '  _stored_uid="$(grep -oP '"'"'^USER_UID=\K.*'"'"' "${_env}")"' \
    >> "${SCRATCH}/dist/script/docker/lib/drift.sh"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"USER_UID"* ]]
}

# why: The section next door listed four triggers and left out the one that
#       fires with nobody typing anything
@test "_run_derived_figures: FAILS when the trigger list omits the drift path (base#1121)" {
  _write_readme
  sed -i '/check-drift/d' "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"check-drift"* ]]
}

# why: The rule must retire itself. If the wrappers stop drift-checking the old
#       claim is true again, and a lint still demanding the bullet is the bug
@test "_run_derived_figures: the trigger-list rule goes inert when the wrapper stops drift-checking (base#1121)" {
  # If the wrappers no longer drift-check, "setup.sh runs only when you ask"
  # is true again, and a lint that still demanded the bullet would be wrong.
  printf '%s\n' '#!/usr/bin/env bash' > "${SCRATCH}/dist/script/docker/lib/wrapper.sh"
  _write_readme
  sed -i '/check-drift/d' "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: A renamed heading would otherwise silence both rules at once, over every
#       locale, while reporting clean
@test "_run_derived_figures: FAILS when the drift section is absent (no vacuous pass) (base#1121)" {
  _write_readme
  sed -i '/^### Drift detection$/d' "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Drift detection"* ]]
}

# why: The id is how a section is found in a language the driver cannot read;
#       without it the three translations are outside the gate
@test "_run_derived_figures: addresses a translated section by its sync id (base#1121)" {
  _write_localized 'zh-TW'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: A fix that lands in one locale is not a fix -- the three translations
#       carried the same three names for as long as the English did
@test "_run_derived_figures: FAILS on a translation whose drift section omits a key (base#1121)" {
  _write_localized 'zh-TW' 'Stores `SETUP_CONF_HASH`.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.zh-TW.md"* ]]
  [[ "${output}" == *"SETUP_GUI_DETECTED"* ]]
}

# why: An empty compared set passes the completeness rule over every locale at
#       once, which is the failure mode this spec is most exposed to
@test "_run_derived_figures: FAILS when the drift lib yields no keys (no vacuous pass) (base#1121)" {
  printf '%s\n' '#!/usr/bin/env bash' > "${SCRATCH}/dist/script/docker/lib/drift.sh"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"read no read-back keys"* ]]
}

# why: A recipe doc comment wraps, and a per-line scan inspects only the
# first line -- the tool list and the negation on the continuation sit
# outside the guard, which is where the real justfile.test annotation lives
@test "_run_derived_figures: folds a wrapped recipe comment into one annotation (base#1121)" {
  _append 'script/test/justfile.test' \
    '# just test -> run the whole self-test: every linter of the' \
    '# _LINT_TOOLS table and then Bats + Kcov.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"justfile.test:"* ]]
  [[ "${output}" == *"coverage 0"* ]]
}

# why: The negation may live on the continuation too, so the fold has to
# carry it or the corrected wording reads as a bare claim
@test "_run_derived_figures: a negation on the continuation line still counts (base#1121)" {
  _append 'script/test/justfile.test' \
    '# just test -> run the whole self-test: every linter of the' \
    '# _LINT_TOOLS table and then Bats, no kcov.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: Folding must stop somewhere or an unrelated paragraph below an
# example gets read as part of its claim; a bare comment line is the
# separator this repo already uses for exactly that
@test "_run_derived_figures: a bare comment line detaches the continuation (base#1121)" {
  _append 'script/test/justfile.test' \
    '# just test -> run the whole self-test, no kcov.' \
    '#' \
    '# Kcov is reached through the coverage recipes instead.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: With coverage ENABLED, an annotation that explicitly denies kcov is
# the contradiction -- reading the negation only in the disabled branch let
# the corrected wording survive a coverage migration unchanged
@test "_run_derived_figures: FAILS on a denied kcov claim when coverage is enabled (base#1121)" {
  _write_runner 1
  _write_readme '```bash' 'just test   # ShellCheck + Hadolint + Bats (no kcov)' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not say so"* ]]
}

# why: The other spelling of the same negation, so the enabled branch is not
# fixed for one word and broken for the next
@test "_run_derived_figures: the without-kcov spelling is denied too when coverage is enabled (base#1121)" {
  _write_runner 1
  _write_readme '```bash' 'just test   # ShellCheck + Hadolint + Bats, without kcov' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not say so"* ]]
}

# why: The predicate behind the coverage-entry rule, in both states of the
# guard -- read it wrong and the rule either never fires or fires on prose
# that is correct
@test "_derived_coverage_skips_lint: reads the guard around the lint phase call (base#1121)" {
  local _skip=''
  _derived_coverage_skips_lint _skip
  [ "${_skip}" = "1" ]
  _write_runner 0 1
  _derived_coverage_skips_lint _skip
  [ "${_skip}" = "0" ]
}

# why: With no call site the question is unanswerable, and a lint that
# answers it anyway would hold prose to an assumption
@test "_derived_coverage_skips_lint: REFUSES when no guarded call site exists (base#1121)" {
  printf '%s\n' '#!/usr/bin/env bash' '  _run_via_compose ci 0' \
    > "${SCRATCH}/script/test/test.sh"
  local _skip=''
  run _derived_coverage_skips_lint _skip
  [ "${status}" -ne 0 ]
}

# why: A coverage run sets the one flag the lint phase guard excludes, so an
# annotation naming a linter there reports checks nothing performed -- the
# dispatcher's own help had said "ShellCheck + Hadolint + Bats + Kcov"
@test "_run_derived_figures: FAILS when a coverage entry is documented as running a linter (base#1121)" {
  _write_readme '```bash' 'just test coverage   # ShellCheck + Hadolint + Bats + Kcov' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no linter runs"* ]]
}

# why: The flag spelling reaches the same dispatch, so it must be the same
# question -- otherwise the rule covers the README and misses the help text
@test "_run_derived_figures: the coverage FLAG spelling is the same claim (base#1121)" {
  _write_readme '```bash' './test.sh --coverage-shard N/T   # kcov plus ShellCheck' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no linter runs"* ]]
}

# why: The corrected wording has to pass, and the rule has to retire itself if
# the guard ever stops excluding coverage
@test "_run_derived_figures: a coverage annotation that claims no linter is clean (base#1121)" {
  _write_readme '```bash' 'just test coverage   # Bats under kcov (the lint phase is skipped)' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  _write_runner 0 1
  _write_readme '```bash' 'just test coverage   # ShellCheck + Hadolint + Bats + Kcov' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}

# why: A worked example in a header block is indented under its own comment
# marker; an invocation that has to reach the first character of the body
# would leave every such block folded into the prose line above it and
# entirely unjudged
@test "_run_derived_figures: an indented example in a comment block is judged (base#1121)" {
  _append 'script/test/justfile.test' \
    '# Examples:' \
    '#   just test   # ShellCheck + Bats + Kcov' \
    '#   just test lint   # ShellCheck only'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"coverage 0"* ]]
  [[ "${output}" == *"shellcheck alone"* ]]
}

# why: An annotation that spells out WHICH checks coverage skips is the most
# useful one a reader can get, and rejecting it for containing the tool name
# would push the docs back to saying less than they know
@test "_run_derived_figures: a coverage annotation may name the linters it denies (base#1121)" {
  _write_readme '```bash' \
    'just test coverage   # Bats under kcov; no ShellCheck or Hadolint' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: The negation reaches one clause, not the whole annotation -- a tool
# named after the clause break is a claim again, which is what keeps the
# allowance from being a way to wave the rule through
@test "_run_derived_figures: a negation does not carry past the clause break (base#1121)" {
  _write_readme '```bash' \
    'just test coverage   # kcov, no ShellCheck, Hadolint runs too' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no linter runs"* ]]
}

# why: `just test default` dispatches to the very recipe bare `just test`
# dispatches to, so reading the name as a narrowing subcommand exempts the
# default run from the rule about the default run
@test "_run_derived_figures: naming the default recipe is still the default run (base#1121)" {
  _write_readme '```bash' 'just test default   # ShellCheck + Bats + Kcov' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"coverage 0"* ]]
}

# why: Which recipe a bare invocation runs is just's rule, not the word
# "default" -- a file with no `default` recipe hands it to the first one, and
# the guard has to follow that or it exempts the bare run under another name
@test "_run_derived_figures: the bare target is derived, not the literal word default (base#1121)" {
  printf '%s\n' 'everything:' '    ./script/test/test.sh' \
    'lint *args:' '    ./script/test/test.sh --lint' \
    > "${SCRATCH}/script/test/justfile.test"
  _write_readme '```bash' 'just test everything   # ShellCheck + Bats + Kcov' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"coverage 0"* ]]
}

# why: The lint phase runs both binaries, so "Hadolint only" is exactly as
# wrong as "ShellCheck only"; catching one spelling and not the other enforces
# the invariant in one direction and invites the other
@test "_run_derived_figures: FAILS on a hadolint-only lint annotation too (base#1121)" {
  _write_readme '```bash' 'just test lint   # Hadolint only' '```'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"hadolint"* ]]
}

# why: A negated mention is not a claim here either, or the rule would refuse
# an annotation that correctly says which binary a narrowed phase leaves out
@test "_run_derived_figures: a lint annotation naming both, one negated, is clean (base#1121)" {
  _write_readme '```bash' \
    'just test lint   # Every linter, ShellCheck and Hadolint included' '```'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
}
