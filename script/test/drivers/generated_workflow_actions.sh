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
# exported by test.sh).
#
# ── The gap ─────────────────────────────────────────────────────────────
#
# dependabot reads WORKFLOW FILES. `init.sh` writes a workflow into every
# downstream repo out of a heredoc, and a ref inside a shell script is not
# a workflow file, so dependabot cannot see it. Three other candidate
# owners do not have it either:
#
#   - no other mechanism in this tree reads a `uses:` version ref.
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
# Three cases have no single ref to inherit, and each fails with its own
# sentence rather than being guessed at:
#
#   - this repo pins the action at two different refs (it does today, for
#     docker/build-push-action) -- there is no answer to "which one";
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
#   - an interpolated ref, e.g. this repo calling its own reusable
#     workflow at the pinned subtree version. Both halves are shell
#     variables, there is no literal to compare, and upgrade.sh already
#     rewrites that ref on every upgrade;
#   - a local `./` callee, which carries no ref: it is this tree, at this
#     commit;
#   - a `docker://` container action, an image reference rather than a
#     repository tag, with no `<owner>/<repo>` reading to compare.
#
# Nor is a ref quoted inside a shell or YAML COMMENT: prose explaining
# what a step looks like is not a step, and a lint that fails on its own
# documentation gets muted. A ref in QUOTES is not an exclusion -- quoting
# is a YAML spelling of the same reference, and it is compared like any
# other.
#
# Style: Google Shell Style Guide.

# Where this repo's own workflows live. A directory, not a file list, so a
# workflow added tomorrow is read without touching this driver.
readonly _GWA_WORKFLOW_DIR_REL='.github/workflows'

# One `uses:` line, with the whole value captured RAW. What the value is
# gets decided afterwards, by _gwa_classify.
#
# The two stages are separate because a single matcher that both finds the
# line and vets the value also decides, silently, what this lint stops
# covering: every value it declines leaves the population with no
# diagnostic. That is not hypothetical -- the first version of this file
# anchored the action at `[A-Za-z0-9]`, so `uses: "actions/checkout@v3"`
# and `uses: 'actions/setup-node@v1'` -- legal YAML, legal Actions syntax,
# and neither an exclusion nor an error -- were dropped, and a generated
# ref disagreeing with the workflows passed green.
readonly _GWA_USES_LINE_RE='uses:[[:space:]]+(.+)$'

# A value that names a versioned action: `<owner>/<repo>[/<sub>...]@<ref>`.
# Capture 1 is the action, capture 3 the ref. The required `/` keeps a
# bare word ahead of an `@` from being read as an action.
readonly _GWA_ACTION_RE='^([A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)+)@([A-Za-z0-9._-]+)$'

# Generated trees the walk must not descend into, by directory basename.
#
# The walk is the whole repository, so this is a PRUNE list rather than a
# roster of scanned directories: a generator added tomorrow at any depth
# is covered without editing this file, and forgetting to prune a new
# generated tree makes the lint fire rather than quietly exempting
# something. Every entry is gitignored.
#
# `.prev-release/` is the one that matters. The self-test materialises
# PAST releases into it, and their refs are stale BY DEFINITION -- a
# release cannot be re-pinned. Scanning it means the first dependabot bump
# after a release fails a lint no edit can satisfy.
readonly _GWA_SCAN_PRUNE=('.git' 'log' '.prev-release')

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

# _gwa_classify <value> -- decide what one `uses:` value is.
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
  local _v="${1}"
  # An interpolated ref -- this repo calling its OWN reusable workflow at
  # the pinned subtree version. Both halves are shell variables, there is
  # no literal to compare, and upgrade.sh rewrites that ref on every
  # upgrade.
  [[ "${_v}" == *'$'* ]] && return 1
  case "${_v}" in
    # A local callee carries no ref: it is this tree, at this commit.
    ./*|/*) return 1 ;;
    # A container action is an image reference, not a repository tag; it
    # has no `<owner>/<repo>` reading for a workflow ref to agree with.
    docker://*) return 1 ;;
  esac
  [[ "${_v}" =~ ${_GWA_ACTION_RE} ]] || return 2
  printf '%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
}

# _gwa_hits <glob> -- every candidate line under REPO_ROOT in files
# matching <glob>, as `<relative-path>:<lineno>:<content>`.
#
# grep pre-filters so only files that mention `uses:` are read at all;
# without it this walks every line of every script in the tree on each
# lint run. A tree with no match is not an error here -- the callers
# decide what an empty result means, and they mean different things.
_gwa_hits() {
  local _glob="${1}" _dir="${2}" _p
  [[ -d "${_dir}" ]] || return 0
  local -a _prune=()
  for _p in "${_GWA_SCAN_PRUNE[@]}"; do
    _prune+=("--exclude-dir=${_p}")
  done
  # grep exits 1 for "matched nothing", which is an ordinary answer here --
  # this repo has no `.yml` workflow, so the `.yml` pass always takes it.
  # Under the dispatcher's `pipefail` + ERR trap that ordinary answer was
  # logged as `ci_lint_driver_failed ... stopped at sed, status 1` on every
  # run, INCLUDING a green one: an ERROR line in a passing log, naming this
  # driver as having stopped when it had not. Exit 2 and above is a real
  # grep failure and still propagates, so tolerating no-match does not
  # turn a broken scan into a silent pass.
  local _out _status=0
  _out="$(grep -rn --include="${_glob}" "${_prune[@]}" \
    -E 'uses:[[:space:]]' "${_dir}")" || _status=$?
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
    _pair="$(_gwa_classify "${_value}")" || continue
    printf '%s\n' "${_pair}"
  done < <(_gwa_hits '*.yaml' "${REPO_ROOT}/${_GWA_WORKFLOW_DIR_REL}"
           _gwa_hits '*.yml' "${REPO_ROOT}/${_GWA_WORKFLOW_DIR_REL}")
}

# _gwa_generated_refs -- one record per `uses:` written by a shell script,
# i.e. every ref that ends up in a workflow dependabot will never read
# here. Two record shapes:
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
    _pair="$(_gwa_classify "${_value}")" || _status=$?
    if (( _status == 0 )); then
      printf '%s\t%s\t%s\n' "${_GWA_FILE}" "${_GWA_LINENO}" "${_pair}"
    elif (( _status > 1 )); then
      printf '%s\t%s\t\t%s\n' "${_GWA_FILE}" "${_GWA_LINENO}" "${_value}"
    fi
  done < <(_gwa_hits '*.sh' "${REPO_ROOT}")
}

# _run_generated_workflow_actions -- the lint.
_run_generated_workflow_actions() {
  echo "--- Running generated-workflow action ref lockstep lint ---"

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
  # defect: `uses: actions/checkout` (no ref) was reported as
  # `actions/checkout@` disagreeing with the workflows, which is false
  # about a tree that does use that action. Splitting by hand also makes
  # the last field the whole remainder, so a tab inside a raw value
  # shifts nothing -- what the record shape already promised.
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
      # a `*.sh` under REPO_ROOT and so is scanned by its own walk: a
      # literal `uses: ` in an emitted message is read as a generated ref
      # on the next run, and the lint fails on its own error text.
      printf '%s:%s: %s -- not a versioned action reference, and not one of the documented exclusions (a ref interpolated from a shell variable, a local ./ callee, a docker:// image). This lint cannot say whether that is in lockstep, so it refuses rather than skipping it: spell it <owner>/<repo>[/<path>]@<ref>, or add the exclusion to _gwa_classify with the reason it is not a pin.\n' \
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
