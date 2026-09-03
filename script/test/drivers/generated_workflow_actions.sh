#!/usr/bin/env bash
# drivers/generated_workflow_actions.sh - "a generated workflow's action
# refs stay in lockstep with this repo's own" per-tool driver for the
# self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_generated_workflow_actions.
#
# Contract: pure bash over the checkout, so it runs host-direct as well as
# inside the ci (test-tools) container. References ${REPO_ROOT} (a global
# exported by test.sh) and the pin registry at script/watch/lib.sh.
#
# ── The gap ─────────────────────────────────────────────────────────────
#
# dependabot reads WORKFLOW FILES. `init.sh` writes a workflow into every
# downstream repo out of a heredoc, and a ref inside a shell script is not
# a workflow file, so dependabot cannot see it. Three other candidate
# owners do not have it either:
#
#   - no other mechanism in this tree compares a `uses:` version ref.
#     `action-ref-agreement` compares call sites WITHIN
#     `.github/workflows/`, so a ref in a shell script is outside its
#     population by construction;
#   - `init.sh` generates no dependabot config into the downstream repo,
#     so nothing bumps the copy where it lands;
#   - `init.sh` skips the generated file when it already exists, so the
#     subtree upgrade that refreshes everything else never refreshes it.
#
# That ref is watched by nothing. It is not a hypothetical: dependabot
# bumped actions/checkout 6 -> 7 across this repo's workflows on
# 2026-06-29 and the generated workflow was authored the day after, so it
# reads v7 by an accident of ordering. Nothing holds it there.
#
# ── Why a lint here rather than a lookup in init.sh ─────────────────────
#
# Reading the number out of the workflows at generation time would be the
# better shape -- it is what the e2e job does for the pinned `just`
# version -- but init.sh runs from the `.base` subtree inside a DOWNSTREAM
# repo, and that subtree carries no `.github/workflows/`. There is nothing
# to read there. In this repo both copies are present, so the agreement is
# checkable here and only here, and checking it is what drags the heredoc
# into dependabot's reach: its own bump PR turns this lint red until the
# heredoc moves with it.
#
# ── The contract, in one sentence ───────────────────────────────────────
#
#   A `uses:` ref a shell script writes must be either a literal
#   <owner>/<repo>@<ref>, or a variable whose value the PIN REGISTRY
#   declares IN THAT FILE -- anything else is a finding.
#
# The second half is where this driver used to keep a scanner of its own.
# A generator that hoists its ref into `readonly NAME='<owner>/<repo>@<ref>'`
# above the heredoc writes exactly the string it would have written
# inline, so excluding it would take a real pin out of the population --
# and it is the only one this lint has. But resolving it means answering
# "which assignment of NAME is live at this line", and that question was
# answered here by a scanner: function bodies tracked by brace
# indentation, compound commands counted by keyword at column 0, `local`
# refused by keyword, heredoc bodies skipped by delimiter. Four ways to be
# wrong were found in it and every one failed OPEN -- a bare `{` at column
# 0 inside a function, `for((i=0;...))` (the counter matched `for ` with a
# space), `if<TAB>`, and a `uses:` line inside `<<'QUOTED'` whose
# `${NAME}` the generator writes out verbatim. In each the lint reported
# lockstep over a value the generator never writes.
#
# The registry answers that question without deriving anything. Every
# version this repo names carries a `tool-pin:` marker on its declaration
# line, and `_pin_read` returns a record naming that file, that line, and
# the value read off it -- by `_pin_extract_value` for a `pinned` marker,
# by `_pin_assign_value` for an `unpinned` one, which is what the live
# `actions/checkout` ref is. The answer was written once, at the site, by a
# human, under a lint (`pin-coverage`) that fails when it is missing. This
# driver looks it up.
#
# ── The scope of a declaration: one file ────────────────────────────────
#
# A record names a FILE and a LINE, and resolution reads both. A
# `${NAME}` written in one file resolves only against a declaration in
# THAT file; a marker on a `NAME` somewhere else declares that other
# file's variable, which is a different variable that happens to be
# spelled the same. Keyed on the name alone the lookup threw away the
# half of the record that made it better than the scanner it replaced,
# and the cost was not theoretical: a generator computing its own `REF`
# at run time -- carrying no marker, because `$(...)` is neither a
# version nor an action ref and nothing asks it for one -- borrowed a
# marked `REF` from an unrelated file and was reported in lockstep with a
# value it may never write. The ambiguity test could not see it either:
# it compares MARKED sites, and the competing assignment has no marker.
#
# Nothing in this tree needs the cross-file form. The one generated ref
# there is declares and uses `_INIT_MONITOR_CHECKOUT_REF` in one file,
# dist/script/base/init.sh. If a second one ever needs a constant from a
# sibling, the rule to change is this one, in a commit that says which
# case forced it -- "any file may declare any name" is not a rule, it is
# the absence of one.
#
# ── The trade, stated rather than hidden ────────────────────────────────
#
# Within that file the registry proves a DECLARATION EXISTS AT A LINE. It
# does not prove that assignment is live at the use. A marker on a `local`
# inside a function nothing ever calls still yields a record, and this
# driver will resolve a `uses:` ref against it. That is a real loss of
# precision against the scanner's intent -- and the scanner did not
# deliver that intent either, in four ways, silently. What is gained is
# that the property is now DECLARED instead of inferred, by the person who
# wrote the line, and that a missing declaration is a lint failure rather
# than a resolution this driver quietly performs. It is the direction this
# tree has already taken twice: the downstream repo roster and the
# lint-tool table both stopped being derived-by-inspection for the same
# reason.
#
# One reader. `_PIN_ASSIGN_RE` in script/watch/lib.sh is now the only
# definition of "an assignment" either lint has, and `_PIN_ACTION_REF_RE`
# the only definition of "an action ref". They disagreed before: the
# registry's regex accepts `local`, the scanner here marked it unusable on
# sight, so one line could be a pin the watch reads and a finding this
# lint reports.
#
# ── What is asserted, and what is not ───────────────────────────────────
#
# Agreement, not currency. This driver holds no opinion about which
# version is right; dependabot owns that question and answers it well
# here. It asserts only that the generated copy names the same ref the
# real workflows do, so whatever dependabot decides propagates. That is
# also why the check is direction-agnostic: a generated ref AHEAD of the
# workflows is the same defect with the opposite sign, and it is the shape
# a well-meant hand-edit takes.
#
# Four cases have no single ref to inherit, and each fails with its own
# sentence rather than being guessed at:
#
#   - this repo pins the action at two different refs -- there is no
#     answer to "which one". It takes an `action-ref-agreement: allow`
#     comment to reach that state, since that lint holds every call site
#     of one action's repository across `.github/workflows/` at one ref;
#     no call site carries one today, so the case is reachable rather
#     than live, and it is spelled out here because the alternative is
#     picking one of the two;
#   - this repo never calls the action itself -- there is no dependabot PR
#     for the generated ref to follow, which is the bare form of the
#     defect;
#   - the scan matched nothing anywhere -- a renamed generator or a
#     matcher that stopped matching, where silence would otherwise read as
#     lockstep;
#   - a `uses:` value the reader cannot place at all. It is a hole in the
#     lint's population, so it is reported as one rather than skipped.
#
# Deliberately NOT a pin, each excluded BY NAME in _gwa_classify rather
# than by failing to match:
#
#   - a local `./` callee, which carries no ref: it is this tree, at this
#     commit;
#   - a `docker://` container action, an image reference rather than a
#     repository tag, with no `<owner>/<repo>` reading to compare;
#   - a call to a reusable workflow THIS repo ships, FROM this repo: a
#     generated `main.yaml` calling build-worker.yaml at the pinned subtree
#     version. That ref has an owner -- upgrade.sh rewrites
#     `<worker>.yaml@vX.Y.Z` in every downstream main.yaml on every upgrade
#     -- and it is not a marketplace action, so `.github/workflows/` holds
#     no comparable ref for it: this repo calls the same worker LOCALLY, as
#     `./`. BOTH halves of the callee are read: the file has to be one this
#     repo ships, and the `<owner>/<repo>` half has to be this repo's own
#     slug. Keyed on the file alone the exclusion was as wide as the
#     basenames this repo happens to ship -- nine of them, several generic
#     -- and somebody else's `build-worker.yaml` was exempted for being
#     spelled like one of ours.
#
# One case IS modelled here rather than in the registry, because it is a
# property of the USE site and not of the declaration: heredoc QUOTING. A
# `uses:` line inside `<<'QUOTED'` is written out with its `${NAME}`
# intact, so the generated workflow carries those characters and not a ref
# at all. Resolving it would compare a value the generator provably never
# writes.
#
# That is a model of bash written in bash, which is the class of thing the
# deleted scanner was, so it is built to fail the other way: it either
# walks a file's heredocs with a model it can defend, or it refuses every
# use in that file. Three things make it refuse -- a `<<` whose delimiter
# word it cannot name (`<<"${_D}"`, two openers on one line), a delimiter
# still open at end of file (proof it opened a body bash did not), and the
# use line sitting inside a body it read as quoted. Only a file it walked
# to EOF with every heredoc closed resolves.
#
# Four spellings used to slip through, each with a spec of its own:
# `<<\D`, which is quoted and was unrecognised, so the body was walked as
# ordinary lines; a terminator with leading space, which closed a heredoc
# bash had not left; `<<"${_D}"`, passed over as though the line held no
# redirection; and a `<<` inside a quoted string, which opened a body that
# never closed and hid the real `<<'QUOTED'` further down the file.
#
# What is still NOT attempted is proving a site DOES expand from the
# other side -- modelling every quoting context a `uses:` value can be
# written in. A line in no heredoc at all, in a file that walked clean,
# is treated as expanding.
#
# Nor is a ref quoted inside a shell or YAML COMMENT read: prose
# explaining what a step looks like is not a step, and a lint that fails
# on its own documentation gets muted. A ref in QUOTES is not an exclusion
# -- quoting is a YAML spelling of the same reference, and it is compared
# like any other.
#
# Style: Google Shell Style Guide.

_GWA_DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _GWA_DRIVER_DIR

# The pin registry: the walk, the marker grammar, the reader, and the two
# regexes this driver shares with the pin-coverage lint. Sourced rather
# than re-implemented so the two cannot drift apart about what an
# assignment is, what an action ref is, or which files are scanned.
# shellcheck source=script/watch/lib.sh
source "${_GWA_DRIVER_DIR}/../../watch/lib.sh"

# Where this repo's own workflows live. A directory, not a file list, so a
# workflow added tomorrow is read without touching this driver.
readonly _GWA_WORKFLOW_DIR_REL='.github/workflows'

# One `uses:` line, with the whole value captured RAW. What the value is
# gets decided afterwards, by _gwa_classify.
#
# The two stages are separate because a single matcher that both finds the
# line and vets the value also decides, silently, what this lint stops
# covering: every value it declines leaves the population with no
# diagnostic. A matcher that anchored the action at `[A-Za-z0-9]` would
# decline every QUOTED value -- `"actions/checkout@v3"`,
# `'actions/setup-node@v1'`, legal YAML and legal Actions syntax, neither
# an exclusion nor an error -- and a generated ref disagreeing with the
# workflows would then pass green. Two specs hold the split rather than
# this paragraph: "a double-quoted generated ref is compared, not
# skipped" and its single-quoted twin.
readonly _GWA_USES_LINE_RE='uses:[[:space:]]+(.+)$'

# One shell VARIABLE REFERENCE inside a `uses:` value: `${NAME}` or
# `$NAME`. Deliberately only the two plain spellings. `${NAME:-default}`,
# `${NAME#prefix}`, `$(command)` and GitHub's own `${{ expr }}` all fail to
# match, and a value still carrying a `$` after resolution is refused --
# so a spelling this matcher does not read becomes a finding rather than a
# value it guessed at.
# shellcheck disable=SC2016 # an ERE matching a `$`; nothing here expands.
readonly _GWA_VAR_RE='\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)'

# Where this repo declares the `<owner>/<repo>` it is served from, and the
# name it declares it under. base is its own upstream, so that slug is this
# repo's own name; upgrade.sh, init.sh and check-base-version.sh all source
# this file and read this name rather than repeating the literal, which
# makes the pair the file's published interface rather than a guess about
# its contents. Renaming the REPO moves the value and this follows it.
readonly _GWA_UPSTREAM_REL='dist/script/base/upstream.sh'
readonly _GWA_SLUG_VAR='BASE_UPSTREAM_SLUG'

# A bare GitHub `<owner>/<repo>`, which is what a slug looks like and what
# a clone URL, a path or a ref does not.
readonly _GWA_SLUG_RE='^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$'

# ── Per-run state ───────────────────────────────────────────────────────
#
# Both are rebuilt at the top of every _run_generated_workflow_actions
# rather than memoised across calls: REPO_ROOT is a global a caller can
# move between runs (the specs do), and a cache keyed on nothing would
# then answer for the previous tree.

# The scanned files, repo-root-relative, one per line -- the pin registry's
# own walk. See _gwa_load_files.
_GWA_FILES=''

# `<file>\t<variable name> -> <value>` for every declaration the registry
# holds whose target line is an assignment, and the keys two sites in ONE
# file declare differently. Keyed on the pair because a declaration is
# scoped to its file: see _gwa_key and _gwa_load_registry.
declare -gA _GWA_PIN_VALUE=()
declare -gA _GWA_PIN_AMBIGUOUS=()

# _gwa_is_comment <line> -- true when the line's first non-blank
# character opens a comment. The same test serves shell and YAML.
_gwa_is_comment() {
  local _l="${1}"
  _l="${_l#"${_l%%[![:space:]]*}"}"
  [[ "${_l}" == '#'* ]]
}

# _gwa_value <line> -- the `uses:` value on <line>, normalised.
#
# Returns non-zero when the line carries no `uses:` value at all. Quotes
# are stripped because quoting a scalar is a YAML spelling, not a
# different reference, and a trailing ` # ...` annotation is prose: the
# space before the `#` is required, so a `#` inside a value is not
# mistaken for one.
_gwa_value() {
  local _l="${1}" _v
  [[ "${_l}" =~ ${_GWA_USES_LINE_RE} ]] || return 1
  _v="${BASH_REMATCH[1]}"
  _v="${_v%% #*}"
  _v="${_v//\"/}"
  _v="${_v//\'/}"
  # Trim both ends.
  _v="${_v#"${_v%%[![:space:]]*}"}"
  _v="${_v%"${_v##*[![:space:]]}"}"
  [[ -n "${_v}" ]] || return 1
  printf '%s' "${_v}"
}

# ── The population: the registry's walk, split at dependabot's border ───

# _gwa_load_files -- fill _GWA_FILES; non-zero when the walk yields nothing.
#
# The roster this replaced was `*.sh`, which is a list of the file shapes a
# generator may take -- and this repo has retired that exact list twice
# already, once in the pin registry's scan roots and once in its file
# shapes, both times because the thing it stopped covering went SILENT
# rather than red. An extensionless script, a `.bash`, a justfile recipe
# writing a workflow: each was invisible here, and the non-vacuity backstop
# below could not notice, because the one generator that does end in `.sh`
# kept the count at 1.
#
# So there is no roster. The walk is the pin registry's: the whole
# repository, minus the machine-local trees it prunes and the prose and
# specs it exempts, both of which it CHECKS rather than trusts (a pruned
# tree must be gitignored and untracked; a marker in an exempt file is a
# failure). `.claude/` comes with it, for the reason the registry states:
# scanning it makes the verdict depend on whose machine the lint ran on.
_gwa_load_files() {
  _GWA_FILES="$(_pin_files "${REPO_ROOT}")"
}

# _gwa_hits <scope> -- every candidate line in one half of the walk, as
# `<relative-path>:<lineno>:<content>`.
#
# `dependabot` is `.github/workflows/*.ya?ml`, the files dependabot reads;
# `generated` is everything else, i.e. every file whose `uses:` refs are
# nobody's job but this lint's. The border is _PIN_DEPENDABOT_SCOPE_RE,
# the registry's own statement of where the division of labour sits, so
# the two mechanisms cannot disagree about which file is whose.
#
# grep pre-filters so only files that mention `uses:` are read at all. A
# scope with no match is not an error here -- the callers decide what an
# empty result means, and they mean different things.
_gwa_hits() {
  local _scope="${1}" _f
  local -a _abs=()
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    if [[ "${_f}" =~ ${_PIN_DEPENDABOT_SCOPE_RE} ]]; then
      [[ "${_scope}" == 'dependabot' ]] || continue
    else
      [[ "${_scope}" == 'generated' ]] || continue
    fi
    _abs+=("${REPO_ROOT}/${_f}")
  done <<< "${_GWA_FILES}"
  [[ "${#_abs[@]}" -eq 0 ]] && return 0
  # grep exits 1 for "matched nothing", which is an ordinary answer here.
  # Under the dispatcher's `pipefail` + ERR trap that ordinary answer was
  # logged as `ci_lint_driver_failed ... stopped at sed, status 1` on every
  # run, INCLUDING a green one: an ERROR line in a passing log, naming this
  # driver as having stopped when it had not. Exit 2 and above is a real
  # grep failure and still propagates, so tolerating no-match does not
  # turn a broken scan into a silent pass.
  local _out _status=0
  _out="$(grep -nHI -E 'uses:[[:space:]]' -- "${_abs[@]}")" || _status=$?
  if (( _status > 1 )); then
    return "${_status}"
  fi
  [[ -n "${_out}" ]] || return 0
  printf '%s\n' "${_out}" | sed "s|^${REPO_ROOT}/||"
}

# _gwa_split <hit> -- set _GWA_FILE / _GWA_LINENO / _GWA_TEXT from one
# `<path>:<lineno>:<content>` record. Split by hand rather than by IFS
# because the content half routinely contains colons of its own.
_gwa_split() {
  local _hit="${1}" _rest
  _GWA_FILE="${_hit%%:*}"
  _rest="${_hit#*:}"
  _GWA_LINENO="${_rest%%:*}"
  _GWA_TEXT="${_rest#*:}"
}

# ── Resolution: what the registry declares, and nothing else ────────────

# _gwa_key <file> <name> -- the map key for one variable IN one file.
#
# A tab joins them because `_pin_read`'s own table is tab-separated, so a
# path holding one is already outside what the registry can express; and
# a variable name can hold neither a tab nor a `/`, so the two halves
# cannot be confused for one another.
_gwa_key() {
  printf '%s\t%s' "${1}" "${2}"
}

# _gwa_load_registry -- fill _GWA_PIN_VALUE / _GWA_PIN_AMBIGUOUS from the
# pin registry; non-zero when the markers do not parse.
#
# One entry per declaration site whose TARGET LINE is an assignment: the
# FILE and the variable it assigns, mapped to the value the registry read
# off it. The registry supplies the line, so nothing here decides which
# assignment is live -- that is the whole job the deleted scanner was
# doing -- and it supplies the file, so nothing here has to guess whose
# `NAME` a `${NAME}` is.
#
# `ignore` records contribute nothing, and that is deliberate rather than
# incidental: `tool-pin: ignore` asserts the line names no third-party
# version, so a `uses:` ref resolved from one would be a ref nobody
# watches -- the defect this lint exists to report. It carries no value
# either, so it is dropped by the empty-value test below.
#
# Two sites IN ONE FILE declaring one name DIFFERENTLY is refused rather
# than resolved: which one reaches a given use is exactly the question
# this driver no longer answers. Two sites in different files are not
# that question -- they are two variables -- and each answers only for
# its own file.
_gwa_load_registry() {
  _GWA_PIN_VALUE=()
  _GWA_PIN_AMBIGUOUS=()
  local _table _decl _var _key
  local _state _name _resolver _coord _pattern _skip _current _file _line
  # Command substitution, not a process substitution feeding the loop: a
  # `< <(...)` redirection discards the producer's exit status, and a
  # registry that could not be read would then look like a registry that
  # declares nothing -- which resolves nothing and reports every ref as a
  # finding, in a sentence about the wrong defect.
  _table="$(_pin_read "${REPO_ROOT}")" || return 1
  while IFS=$'\t' read -r _state _name _resolver _coord _pattern _skip \
      _current _file _line; do
    [[ -z "${_state}" ]] && continue
    [[ -z "${_current}" || "${_current}" == '-' ]] && continue
    _decl="$(awk -v n="${_line}" 'NR == n' "${REPO_ROOT}/${_file}")" || continue
    _var="$(_pin_assign_name "${_decl}")" || continue
    _key="$(_gwa_key "${_file}" "${_var}")"
    if [[ -n "${_GWA_PIN_VALUE[${_key}]:-}" \
          && "${_GWA_PIN_VALUE[${_key}]}" != "${_current}" ]]; then
      _GWA_PIN_AMBIGUOUS["${_key}"]=1
      continue
    fi
    _GWA_PIN_VALUE["${_key}"]="${_current}"
  done <<< "${_table}"
}

# _gwa_registry_literal <file> <name> -- the value the registry declares
# for <name> IN <file>; non-zero when that file declares none, or more
# than one. A declaration in some other file is not an answer here: it
# declares that file's variable.
_gwa_registry_literal() {
  local _key _v
  _key="$(_gwa_key "${1}" "${2}")"
  [[ -n "${_GWA_PIN_AMBIGUOUS[${_key}]:-}" ]] && return 1
  _v="${_GWA_PIN_VALUE[${_key}]:-}"
  [[ -n "${_v}" ]] || return 1
  # A declared value that itself carries a `$` would re-enter resolution
  # and could substitute itself; refusing it here is what keeps
  # _gwa_resolve's termination an argument rather than a hope.
  [[ "${_v}" == *'$'* ]] && return 1
  printf '%s' "${_v}"
}

# _gwa_resolve <value> <file> -- <value> with every variable reference
# replaced by the literal the pin registry declares for it IN <file>;
# non-zero if any one of them is not declared there.
#
# Termination is not an assumption: a resolved literal can never contain
# `$` (_gwa_registry_literal refuses one that does), so each pass strictly
# reduces the number of `$` in the value.
_gwa_resolve() {
  local _v="${1}" _file="${2}" _ref _name _lit
  while [[ "${_v}" =~ ${_GWA_VAR_RE} ]]; do
    # Both halves of the match are read BEFORE anything else runs. The
    # braced spelling fills capture 1 and the bare one capture 2, so the
    # name is whichever is non-empty; and the next statement re-matches
    # inside its own regex, which is exactly what would overwrite these.
    _ref="${BASH_REMATCH[0]}"
    _name="${BASH_REMATCH[1]:-${BASH_REMATCH[2]}}"
    _lit="$(_gwa_registry_literal "${_file}" "${_name}")" || return 1
    _v="${_v//"${_ref}"/${_lit}}"
  done
  # A `$` the reference matcher could not read at all -- `${{ }}`,
  # `${NAME:-x}`, `$(cmd)` -- survives the loop. Refuse it rather than
  # comparing a value still carrying an unexpanded fragment.
  [[ "${_v}" == *'$'* ]] && return 1
  printf '%s' "${_v}"
}

# ── The one thing the registry cannot answer: the USE site ──────────────

# _gwa_heredoc_open <line> -- what heredoc <line> opens.
#
# Prints `<quoted>\t<dash>\t<delimiter>` and returns 0 when it opens one
# this reader can name; 1 when it opens none; 2 when it carries a heredoc
# operator this reader CANNOT read. The third answer is the point: a
# spelling the model does not cover must not look like a line with no
# redirection on it, which is how every hole in the deleted scanner
# worked.
#
# <quoted> is 1 when the delimiter word carries any quoting -- `'D'`,
# `"D"`, `\D`, `D\ 1`, `'D'ELIM` are one rule in bash and one rule here:
# ANY quoted character turns the whole body non-expanding. <dash> is 1
# for `<<-`, which is the only form whose terminator may be indented, and
# then by TABS only.
#
# Herestrings are deleted first: `<<<'word'` otherwise reads as a heredoc
# opened on `word`, and the walk would then swallow the rest of the file
# looking for a terminator that never comes.
_gwa_heredoc_open() {
  local _l="${1//<<</ }" _tail _tok _d _q=0 _dash=0
  [[ "${_l}" == *'<<'* ]] || return 1
  _tail="${_l#*<<}"
  # Two heredocs on one line. bash opens both, in order; this reader
  # tracks one, so it can place neither body.
  [[ "${_tail}" == *'<<'* ]] && return 2
  if [[ "${_tail}" == -* ]]; then
    _dash=1
    _tail="${_tail#-}"
  fi
  # The delimiter WORD: blanks may follow the operator, and the word ends
  # at the first blank or at an operator that can follow a redirection.
  _tail="${_tail#"${_tail%%[![:space:]]*}"}"
  _tok="${_tail%%[[:space:];|&<>()]*}"
  [[ "${_tok}" == *[\'\"\\]* ]] && _q=1
  _d="${_tok//[\'\"\\]/}"
  # What is left has to be a word a later line can be compared against.
  # A delimiter built at run time -- `<<"${_D}"` -- is one bash reads and
  # this does not, and so is an empty one.
  [[ "${_d}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || return 2
  printf '%s\t%s\t%s' "${_q}" "${_dash}" "${_d}"
}

# _gwa_use_expands <file> <lineno> -- true only when this reader walked
# <file> to EOF with a model it can defend AND line <lineno> sits in no
# quoted heredoc body.
#
# The registry says what a variable holds. It cannot say whether the
# generator interpolates it HERE, and that is a property of the use site:
# `<<'YAML'` turns expansion off, so `${NAME}` reaches the generated
# workflow as those characters. Resolving such a line compares a value the
# generator provably never writes -- and reports lockstep.
#
# So this is a model of bash's heredoc grammar written in bash, which is
# exactly what was just deleted from this file for failing open in four
# places. It is built to fail the other way instead. It refuses -- says
# "I cannot show this expands" -- on all of:
#
#   - a heredoc operator _gwa_heredoc_open cannot name. Passing it over
#     is what let `<<\YAML` be walked as ordinary lines;
#   - a delimiter still open at end of file. bash closes what it opens
#     here, so an unclosed one is proof this reader opened a body bash
#     did not -- a `<<` inside a quoted string, an arithmetic `1 << 2` --
#     and everything it swallowed was mis-modelled, including any real
#     opener further down;
#   - a <lineno> past the end of the file, or a file it cannot read;
#   - and the case it exists for: <lineno> inside a QUOTED body.
#
# The close test is bash's: the terminator is the delimiter alone on its
# line, at column 0, with `<<-` the single exception that allows leading
# TABS (not spaces). A test that tolerated leading whitespace ended a
# heredoc bash had not left, and modelled every line after it as outside
# a body it was still inside.
#
# What is NOT attempted is the converse -- proving a site expands by
# modelling every quoting context a `uses:` value can be written in. A
# line in no heredoc, in a file that walked clean, is treated as
# expanding.
_gwa_use_expands() {
  local _file="${1}" _want="${2}"
  [[ -f "${_file}" ]] || return 1
  local _lineno=0 _delim='' _quoted=0 _dash=0 _line _open _status _term
  local _answer=1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if (( _lineno == _want )); then
      if [[ -n "${_delim}" ]] && (( _quoted )); then
        _answer=1
      else
        _answer=0
      fi
    fi
    if [[ -n "${_delim}" ]]; then
      _term="${_line}"
      # `<<-` strips leading TABS from the terminator; nothing strips
      # spaces, and the plain form strips nothing at all.
      (( _dash )) && _term="${_term#"${_term%%[!$'\t']*}"}"
      if [[ "${_term}" == "${_delim}" ]]; then
        _delim=''
        _quoted=0
        _dash=0
      fi
      continue
    fi
    _gwa_is_comment "${_line}" && continue
    _status=0
    _open="$(_gwa_heredoc_open "${_line}")" || _status=$?
    (( _status > 1 )) && return 1
    if (( _status == 0 )); then
      _quoted="${_open%%$'\t'*}"
      _open="${_open#*$'\t'}"
      _dash="${_open%%$'\t'*}"
      _delim="${_open#*$'\t'}"
    fi
  done < "${_file}"
  [[ -n "${_delim}" ]] && return 1
  return "${_answer}"
}

# ── This repo's own name, and the calls home it excludes ────────────────

# _gwa_repo_slug -- this repo's own `<owner>/<repo>`, read by SOURCING the
# one file that declares it; non-zero when that file does not yield a
# slug-shaped value.
#
# Sourced rather than pattern-matched. The file is a two-assignment
# constants file that upgrade.sh, init.sh and check-base-version.sh all
# source and read `BASE_UPSTREAM_SLUG` out of, so asking it the same way
# they do is exact where a text scan was a heuristic -- and it is the
# heuristic, not the value, that this change is retiring. A repo RENAME
# moves the value and this follows it; a file that stops defining the name
# yields nothing, which switches the exclusion that depends on it OFF, so
# every call home becomes a finding rather than every call being exempt.
#
# In a subshell, with the guard variable cleared, so a caller that has
# already sourced it still gets this file's answer and not a stale one --
# and so sourcing has no effect on the lint's own shell.
_gwa_repo_slug() {
  local _upstream="${REPO_ROOT}/${_GWA_UPSTREAM_REL}" _slug
  [[ -f "${_upstream}" ]] || return 1
  _slug="$(
    unset _BASE_UPSTREAM_SOURCED "${_GWA_SLUG_VAR}"
    # shellcheck source=dist/script/base/upstream.sh
    source "${_upstream}" >/dev/null 2>&1 || exit 1
    printf '%s' "${!_GWA_SLUG_VAR:-}"
  )" || return 1
  [[ "${_slug}" =~ ${_GWA_SLUG_RE} ]] || return 1
  printf '%s' "${_slug}"
}

# _gwa_owner_is_self <owner> -- true when the `<owner>/<repo>` half of a
# reusable-workflow callee names THIS repo.
#
# Two spellings, and no third. The slug written out, compared against the
# one the upstream file yields; or the very variable that file declares it
# in, which init.sh has to use because the value it needs lives in a file
# it sources at runtime and cannot be spelled inline. `${SOMEBODY_ELSE}`
# is not a stand-in for us: an unresolved variable that is not that name
# is not this repo, and the tree never says it is.
_gwa_owner_is_self() {
  local _owner="${1}" _slug
  _slug="$(_gwa_repo_slug)" || return 1
  [[ "${_owner}" == "${_slug}" ]] && return 0
  [[ "${_owner}" == "\${${_GWA_SLUG_VAR}}" \
     || "${_owner}" == "\$${_GWA_SLUG_VAR}" ]]
}

# _gwa_ships_workflow <value> -- true when <value> calls a reusable
# workflow THIS repo ships, whatever its ref looks like.
#
# Both halves of the callee are read. The FILE half has to name a workflow
# present under `.github/workflows/` here, as one path segment --
# `<owner>/<repo>/.github/workflows/<file>` is the only shape GitHub
# accepts, so a deeper path is not this call at all. The OWNER half has to
# name this repo. Keying on the file alone was a hole exactly the width of
# the basenames this repo happens to ship: nine generic names, several of
# them ones anybody would pick, and a call to somebody else's
# `build-worker.yaml` was exempted because ours is spelled the same. The
# reason for the exclusion -- upgrade.sh rewrites `<worker>.yaml@vX.Y.Z`
# in every downstream main.yaml on every upgrade, so the ref has an owner
# -- only holds when that owner is us.
_gwa_ships_workflow() {
  local _callee="${1%%@*}" _owner _base
  [[ "${_callee}" == */.github/workflows/* ]] || return 1
  _owner="${_callee%%/.github/workflows/*}"
  _base="${_callee##*/.github/workflows/}"
  [[ "${_base}" == */* ]] && return 1
  [[ "${_base}" == *.yaml || "${_base}" == *.yml ]] || return 1
  [[ -f "${REPO_ROOT}/${_GWA_WORKFLOW_DIR_REL}/${_base}" ]] || return 1
  _gwa_owner_is_self "${_owner}"
}

# _gwa_classify <value> [<file> <lineno>] -- decide what one `uses:` value
# is. <file> is REPO-ROOT-RELATIVE, because that is the spelling the pin
# registry's records use, and both things this function asks about a use
# site -- whose declaration of a name applies, and whether the site
# expands -- are keyed on it.
#
# Prints `<action>\t<ref>` and returns 0 for a versioned action this lint
# can compare; returns 1 for a value EXCLUDED BY NAME; returns 2 for one
# it cannot read at all.
#
# Three outcomes rather than two, because the safe default for the last
# two is OPPOSITE: an exclusion must pass, an unreadable value must fail.
# A matcher answering only "matched / did not match" collapses them and
# has to pick one default for both, and picking "pass" is how a lint
# quietly stops covering whatever its author did not foresee.
_gwa_classify() {
  local _v="${1}" _file="${2:-}" _lineno="${3:-0}"
  case "${_v}" in
    # A local callee carries no ref: it is this tree, at this commit.
    ./*|/*) return 1 ;;
    # A container action is an image reference, not a repository tag; it
    # has no `<owner>/<repo>` reading for a workflow ref to agree with.
    docker://*) return 1 ;;
  esac
  # A call home to one of this repo's own worker workflows: pinned to the
  # subtree version, rewritten by upgrade.sh on every upgrade, and not a
  # marketplace action this repo also calls by ref.
  _gwa_ships_workflow "${_v}" && return 1
  if [[ "${_v}" == *'$'* ]]; then
    # A quoted heredoc writes the reference out verbatim, so there is no
    # ref here to be in lockstep with anything.
    if [[ -n "${_file}" ]] \
       && ! _gwa_use_expands "${REPO_ROOT}/${_file}" "${_lineno}"; then
      return 2
    fi
    _v="$(_gwa_resolve "${_v}" "${_file}")" || return 2
  fi
  [[ "${_v}" =~ ${_PIN_ACTION_REF_RE} ]] || return 2
  printf '%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
}

# _gwa_workflow_refs -- `<action>\t<ref>` for every literal `uses:` this
# repo's own workflows declare. Duplicates are left in; the caller folds
# them, because "the same ref at forty call sites" and "two different
# refs" are different facts and only the second is a problem.
_gwa_workflow_refs() {
  local _hit _value _pair
  while IFS= read -r _hit; do
    _gwa_split "${_hit}"
    _gwa_is_comment "${_GWA_TEXT}" && continue
    _value="$(_gwa_value "${_GWA_TEXT}")" || continue
    # A value unreadable HERE is dropped rather than reported, and that
    # direction is safe: this side only builds the set of refs a generated
    # copy may inherit, so a missing entry can turn a comparison into
    # "this repo never uses that action" -- itself a violation -- and can
    # never turn one into a pass. `.github/workflows/` is the
    # action-ref-agreement lint's population, and this lint does not
    # re-judge what that one already owns.
    _pair="$(_gwa_classify "${_value}" "${_GWA_FILE}" \
      "${_GWA_LINENO}")" || continue
    printf '%s\n' "${_pair}"
  done < <(_gwa_hits 'dependabot')
}

# _gwa_generated_refs -- one record per `uses:` written outside
# dependabot's scope, i.e. every ref that ends up in a workflow dependabot
# will never read here. Two record shapes:
#
#   <file>\t<lineno>\t<action>\t<ref>   a ref to compare
#   <file>\t<lineno>\t\t<value>         a value nothing could read
#
# The second shape is what keeps an unrecognised value a FINDING instead
# of a silent omission. The raw value is the last field, so a tab inside
# it cannot shift another.
_gwa_generated_refs() {
  local _hit _value _pair _status
  while IFS= read -r _hit; do
    _gwa_split "${_hit}"
    _gwa_is_comment "${_GWA_TEXT}" && continue
    _value="$(_gwa_value "${_GWA_TEXT}")" || continue
    _status=0
    _pair="$(_gwa_classify "${_value}" "${_GWA_FILE}" \
      "${_GWA_LINENO}")" || _status=$?
    if (( _status == 0 )); then
      printf '%s\t%s\t%s\n' "${_GWA_FILE}" "${_GWA_LINENO}" "${_pair}"
    elif (( _status > 1 )); then
      printf '%s\t%s\t\t%s\n' "${_GWA_FILE}" "${_GWA_LINENO}" "${_value}"
    fi
  done < <(_gwa_hits 'generated')
}

# _run_generated_workflow_actions -- the lint.
_run_generated_workflow_actions() {
  echo "--- Running generated-workflow action ref lockstep lint ---"

  if ! _gwa_load_files; then
    _die ci_generated_workflow_actions \
      "the walk yielded no scannable file at all under ${REPO_ROOT} -- nothing was read, so this lint would pass vacuously. script/watch/lib.sh's prune list and exempt shapes, not the tree, are what to look at."
    return 1
  fi
  if ! _gwa_load_registry; then
    _die ci_generated_workflow_actions \
      "the tool-pin markers did not parse (the registry's complaint is above), so no generated ref could be resolved against a declared value. Every interpolated ref would be reported as unreadable, which is a sentence about the wrong defect -- so this stops here instead. The pin-coverage lint owns the marker grammar."
    return 1
  fi

  local -A _own=()
  local _action _ref
  while IFS=$'\t' read -r _action _ref; do
    [[ -n "${_action}" ]] || continue
    case " ${_own[${_action}]:-} " in
      *" ${_ref} "*) ;;
      *) _own["${_action}"]="${_own[${_action}]:-}${_own[${_action}]:+ }${_ref}" ;;
    esac
  done < <(_gwa_workflow_refs)

  local _file _lineno _record _rest _checked=0 _violations=0 _expected
  # Split each record by hand rather than with `IFS=$'\t' read`. A tab is
  # IFS WHITESPACE, so bash folds a run of tabs into ONE delimiter and
  # drops the empty field between them -- and the unreadable-value record
  # is defined by an EMPTY action field. Under that reader the raw value
  # slid into the action column, the `[[ -z "${_action}" ]]` branch below
  # never ran, and the finding came out as a sentence about a different
  # defect: an action named with no ref was reported as `actions/checkout@`
  # disagreeing with the workflows, which is false about a tree that does
  # use that action. Splitting by hand also makes the last field the whole
  # remainder, so a tab inside a raw value shifts nothing -- what the
  # record shape already promised.
  while IFS= read -r _record; do
    _file="${_record%%$'\t'*}"
    _rest="${_record#*$'\t'}"
    _lineno="${_rest%%$'\t'*}"
    _rest="${_rest#*$'\t'}"
    _action="${_rest%%$'\t'*}"
    _ref="${_rest#*$'\t'}"
    # An empty action field is the "could not read this value" record. It
    # is reported, not skipped: the whole population of this lint is
    # decided by what the reader recognises, so a value it cannot place is
    # a hole in the lint, and a hole must be visible.
    if [[ -z "${_action}" ]]; then
      [[ -n "${_ref}" ]] || continue
      # The value is printed bare, with no `uses:` prefix. This driver is
      # itself one of the files the walk reads: a `uses:` followed by a
      # space in an emitted message is read as a generated ref on the next
      # run, and the lint fails on its own error text.
      printf '%s:%s: %s -- not a versioned action reference, and not one of the documented exclusions (a local ./ callee, a docker:// image, a call to a reusable workflow this repo ships, from this repo, by its own name). A variable is read only where the pin registry DECLARES its value IN THIS FILE: a tool-pin: marker on an assignment here that gives it that value. A marker on the same name in another file declares the variable OF THAT FILE and is not an answer here. Undeclared in this file, declared here at two sites that disagree, holding a value that is itself interpolated, or written into a heredoc this reader could not walk or read as quoted, it lands here. This lint cannot say whether that is in lockstep, so it refuses rather than skipping it: spell it <owner>/<repo>[/<path>]@<ref>, or hoist it into an assignment and put a tool-pin: marker on that line -- which is what makes the ref watched as well as checked.\n' \
        "${_file}" "${_lineno}" "${_ref}"
      _violations=$(( _violations + 1 ))
      continue
    fi
    _checked=$(( _checked + 1 ))
    _expected="${_own[${_action}]:-}"

    if [[ -z "${_expected}" ]]; then
      printf '%s:%s: %s@%s -- this repo never uses %s itself, so no dependabot PR ever bumps this ref\n' \
        "${_file}" "${_lineno}" "${_action}" "${_ref}" "${_action}"
      _violations=$(( _violations + 1 ))
      continue
    fi
    if [[ "${_expected}" == *' '* ]]; then
      printf '%s:%s: %s@%s -- this repo pins %s at more than one ref (%s), so there is no single ref for the generated copy to follow\n' \
        "${_file}" "${_lineno}" "${_action}" "${_ref}" "${_action}" "${_expected}"
      _violations=$(( _violations + 1 ))
      continue
    fi
    if [[ "${_ref}" != "${_expected}" ]]; then
      printf '%s:%s: %s@%s -- %s/ pins %s@%s; the generated copy disagrees\n' \
        "${_file}" "${_lineno}" "${_action}" "${_ref}" \
        "${_GWA_WORKFLOW_DIR_REL}" "${_action}" "${_expected}"
      _violations=$(( _violations + 1 ))
    fi
  done < <(_gwa_generated_refs)

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_generated_workflow_actions \
      "${_violations} generated workflow action ref(s) out of lockstep with ${_GWA_WORKFLOW_DIR_REL}/. A shell script that writes a workflow puts its \`uses:\` refs outside dependabot, which reads workflow FILES, and outside \`action-ref-agreement\`, which compares call sites within ${_GWA_WORKFLOW_DIR_REL}/ only. Holding the generated copy equal to this repo's own is what makes dependabot's bump reach it: bump both in the same commit."
    return 1
  fi

  if [[ "${_checked}" -eq 0 ]]; then
    # A clean line over a scan that read nothing is how a lint silently
    # stops covering anything -- a renamed generator, a moved directory, a
    # matcher that no longer matches. Silence must not read as lockstep.
    _die ci_generated_workflow_actions \
      "no generated workflow action ref found anywhere under ${REPO_ROOT}. This lint exists because a script that writes a workflow hides its \`uses:\` refs from dependabot; finding none means the scan stopped matching, not that the repo is clean."
    return 1
  fi

  echo "generated-workflow action ref lockstep lint: clean (${_checked} generated ref(s) checked against ${_GWA_WORKFLOW_DIR_REL}/)"
}
