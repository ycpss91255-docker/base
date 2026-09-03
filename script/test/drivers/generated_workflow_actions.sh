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
#     `./`. BOTH halves of the callee are read, and both are derived from
#     the tree: the file has to be one this repo ships, and the
#     `<owner>/<repo>` half has to be this repo's own slug, which is read
#     off the tree rather than written down here. Keyed on the file alone
#     the exclusion was as wide as the basenames this repo happens to ship
#     -- nine of them, several generic -- and somebody else's
#     `build-worker.yaml` was exempted for being spelled like one of ours.
#     The reason above only holds when the owner is us, so the check now
#     says that.
#
# "Interpolated from a shell variable" is NOT on that list, and was: it is
# a different property from "cannot be known". A generator that hoists its
# ref into `readonly NAME='<owner>/<repo>@<ref>'` above the heredoc -- which
# is what init.sh does, so the generated line has a declaration site a
# `tool-pin:` marker can attach to -- writes the same string it would have
# written inline. Excluding it took a real pin out of the population, and
# took out the only one this lint had. _gwa_classify resolves that one
# indirection and refuses every other, case by case, at the function.
#
# "Above the heredoc" is load-bearing, and it is checked rather than
# assumed: the assignment has to PRECEDE the use and sit at file scope.
# Reading "assigned somewhere in this file" as "assigned before the use, in
# scope" is how a value that really arrives from the environment or from a
# caller gets resolved against a line that is not live at that point, and
# that direction ends in a green report on a ref the generator never
# writes.
#
# One thing the reader does not model, stated as a limit rather than left
# to be discovered: heredoc QUOTING at the USE site. A `uses:` line inside
# `<<'QUOTED'` is written out with its `${NAME}` intact, and this reader
# resolves it anyway. That errs toward checking rather than toward
# dropping -- the ref stays in the population and is compared -- and every
# `uses:` line this tree generates today sits in an UNQUOTED heredoc
# (init.sh:418), so no line is read that way here.
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

# One shell VARIABLE REFERENCE inside a `uses:` value: `${NAME}` or
# `$NAME`. Deliberately only the two plain spellings. `${NAME:-default}`,
# `${NAME#prefix}`, `$(command)` and GitHub's own `${{ expr }}` all fail to
# match, and a value still carrying a `$` after resolution is refused --
# so a spelling this matcher does not read becomes a finding rather than a
# value it guessed at.
# shellcheck disable=SC2016 # an ERE matching a `$`; nothing here expands.
readonly _GWA_VAR_RE='\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)'

# _gwa_assign_re <name-ere> -- an ERE matching an assignment to a variable
# whose name matches <name-ere>.
#
# The declaration keywords are optional and repeatable (`readonly`,
# `export`, `local`, `declare -r`, `typeset`). Which one is present is not
# what makes a value static -- but WHICH one it is still matters
# afterwards: `local`, `declare` and `typeset` declare a name whose life is
# one function call, so a line carrying one is RECORDED here and refused
# later, rather than never matching. The `(\+?)` before the `=` does the
# same job for an append: `NAME+=` builds a value instead of declaring one,
# and a matcher that only saw `NAME=` would resolve to a PREFIX of what the
# generator writes and compare a ref that never existed.
#
# Captures: 1 the indentation, 2 the declaration-keyword run, 5 the name,
# 6 the `+` of an append, 7 the right-hand side.
_gwa_assign_re() {
  printf '%s' \
    "^([[:space:]]*)((readonly|export|local|declare|typeset)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+)*(${1})(\+?)=(.*)$"
}

# A function definition's opening line, in the two spellings bash accepts,
# with the brace on the same line: `name() {`, `function name {`,
# `function name() {`. Capture 1 is the indentation, which is where the
# matching close brace is looked for.
readonly _GWA_FN_OPEN_RE='^([[:space:]]*)(function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*([[:space:]]*\(\))?|[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\))[[:space:]]*\{[[:space:]]*$'

# The same header with the brace on the NEXT line. Tracked separately so
# that spelling opens a function body too: missing it would read a function
# body as file scope, which is the fail-open direction.
readonly _GWA_FN_HEADER_RE='^([[:space:]]*)(function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*([[:space:]]*\(\))?|[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\))[[:space:]]*$'
readonly _GWA_FN_BRACE_RE='^([[:space:]]*)\{[[:space:]]*$'

# _gwa_heredoc_delim <line> -- the delimiter word <line> opens a heredoc
# with, or non-zero when it opens none.
#
# Herestrings are deleted first: `<<<'word'` otherwise reads as a heredoc
# opened on `word`, and the scan would then swallow the rest of the file
# looking for a terminator that never comes.
_gwa_heredoc_delim() {
  local _l="${1//<<</ }" _d
  [[ "${_l}" =~ \<\<-?[[:space:]]*(\'[A-Za-z_][A-Za-z0-9_]*\'|\"[A-Za-z_][A-Za-z0-9_]*\"|[A-Za-z_][A-Za-z0-9_]*) ]] || return 1
  _d="${BASH_REMATCH[1]}"
  _d="${_d//\'/}"
  _d="${_d//\"/}"
  printf '%s' "${_d}"
}

# _gwa_scan_assignments <file> <name-ere> -- one record per assignment in
# <file> to a variable matching <name-ere>:
#
#   <lineno>\t<name>\t<usable>\t<right-hand side>
#
# EVERY matching assignment is emitted, usable or not. The caller counts
# them all and then looks at the single survivor, so a second assignment
# the reader would not use cannot quietly leave the count at one.
#
# <usable> is 1 only for an assignment this reader can claim is live at a
# later point in the same file, and that means three things at once:
#
#   - FILE SCOPE. An assignment inside a function body runs when the
#     function is CALLED, which is control flow this reader does not
#     evaluate; the body may never run, or may run after the generation it
#     is supposed to feed. Function bodies are tracked by their opening
#     line and the close brace at the same indentation.
#   - UNCONDITIONAL. A `if` / `while` / `until` / `for` / `case` opened at
#     column 0 and not yet closed means the assignment below it runs only
#     when that test passes, which is control flow again. Counted rather
#     than inferred from indentation, so an unindented body is caught too.
#   - COLUMN 0. Indentation is a second, independent statement of the same
#     property: a file-scope declaration in this repo's style starts at
#     column 0, while anything nested is indented. Requiring it as well
#     means a mis-tracked brace cannot on its own promote a function-local
#     assignment to file scope.
#   - NOT `local` / `declare` / `typeset`. `local` is only legal inside a
#     function, so the keyword itself proves function scope no matter what
#     the brace tracking concluded.
#
# Three overlapping tests rather than one because each is a heuristic over
# text: what is claimed is that all four hold, not that a bash parser ran.
#
# Appends are marked unusable for the reason at _gwa_assign_re. Heredoc
# BODIES are skipped entirely: a `NAME='...'` inside a heredoc is text a
# generator writes into another file, not an assignment this one performs,
# and a `}` in one would otherwise close a function that is still open.
_gwa_scan_assignments() {
  local _file="${1}" _name_re="${2}"
  [[ -f "${_file}" ]] || return 0
  local _re _line _lineno=0 _delim='' _in_fn=0 _fn_indent='' _pending=''
  local _block=0
  local _usable _kw _indent _vname _plus _rhs
  _re="$(_gwa_assign_re "${_name_re}")"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if [[ -n "${_delim}" ]]; then
      [[ "${_line}" =~ ^[[:space:]]*"${_delim}"[[:space:]]*$ ]] && _delim=''
      continue
    fi
    _gwa_is_comment "${_line}" && continue
    if (( _in_fn )); then
      if [[ "${_line}" =~ ^"${_fn_indent}"\}[[:space:]]*$ ]]; then
        _in_fn=0
        _fn_indent=''
      fi
    elif [[ "${_line}" =~ ${_GWA_FN_OPEN_RE} ]]; then
      _in_fn=1
      _fn_indent="${BASH_REMATCH[1]}"
      _pending=''
    elif [[ -n "${_pending}" && "${_line}" =~ ${_GWA_FN_BRACE_RE} ]]; then
      _in_fn=1
      _fn_indent="${_pending}"
      _pending=''
    elif [[ "${_line}" =~ ${_GWA_FN_HEADER_RE} ]]; then
      _pending="${BASH_REMATCH[1]}"
    else
      _pending=''
    fi
    if (( _in_fn == 0 )); then
      # Compound commands opened at column 0, closed by their own keyword
      # at column 0. A nested one lives in an indented body, so neither its
      # opener nor its closer is counted and the pairing stays balanced.
      case "${_line}" in
        'if '*|'while '*|'until '*|'for '*|'case '*)
          _block=$(( _block + 1 )) ;;
        'fi'|'fi '*|'fi;'*|'done'|'done '*|'done;'*|'esac'|'esac '*|'esac;'*)
          (( _block > 0 )) && _block=$(( _block - 1 )) ;;
      esac
    fi
    if [[ "${_line}" =~ ${_re} ]]; then
      # Every capture is read out BEFORE the next regex runs: the keyword
      # test below matches inside its own pattern, and that is exactly what
      # would overwrite BASH_REMATCH under the printf's feet.
      _indent="${BASH_REMATCH[1]}"
      _kw=" ${BASH_REMATCH[2]}"
      _vname="${BASH_REMATCH[5]}"
      _plus="${BASH_REMATCH[6]}"
      _rhs="${BASH_REMATCH[7]}"
      _usable=1
      [[ -n "${_indent}" ]] && _usable=0
      (( _in_fn )) && _usable=0
      (( _block > 0 )) && _usable=0
      [[ -n "${_plus}" ]] && _usable=0
      [[ "${_kw}" =~ (^|[[:space:]])(local|declare|typeset)([[:space:]]|$) ]] && _usable=0
      printf '%s\t%s\t%s\t%s\n' \
        "${_lineno}" "${_vname}" "${_usable}" "${_rhs}"
    fi
    _delim="$(_gwa_heredoc_delim "${_line}")" || _delim=''
  done < "${_file}"
}

# _gwa_static_literal <rhs> -- the literal <rhs> declares, or non-zero when
# it declares none.
#
# A single-quoted string with no `$` in it, and nothing else. A
# double-quoted right-hand side, a command substitution or another variable
# is a value that is not visible in one place, and following the hop would
# mean re-deciding what is in scope at every step. A literal that itself
# contains `$` would re-enter resolution, and a single-quoted `$FOO` is a
# literal dollar sign rather than a reference.
_gwa_static_literal() {
  local _v="${1}" _lit
  _v="${_v%"${_v##*[![:space:]]}"}"
  [[ "${_v}" =~ ^\'([^\']*)\'$ ]] || return 1
  _lit="${BASH_REMATCH[1]}"
  [[ "${_lit}" == *'$'* ]] && return 1
  printf '%s' "${_lit}"
}

# _gwa_var_literal <name> <file> <use-lineno> -- print the static literal
# <name> holds at line <use-lineno> of <file>; return non-zero when this
# reader cannot say that it holds one.
#
# "Static" is the narrowest reading that still covers the shape a generator
# uses: exactly ONE assignment in this file, of a single-quoted literal,
# at FILE SCOPE, on a line BEFORE the use. Order and scope are not
# decoration -- without them "assigned somewhere in the file" gets read as
# "assigned before the use, in scope", and a ref whose value at generation
# time comes from the environment or from a caller is compared against an
# assignment that is not live at that point. Every other shape returns
# non-zero and ends up a finding upstream:
#
#   - assigned more than once: which assignment is live at the heredoc
#     depends on control flow this reader does not evaluate;
#   - assigned only AFTER the use: at the use the name still holds whatever
#     the environment or the caller put there, which is not in this file;
#   - assigned inside a function body, or with `local` / `declare` /
#     `typeset`: it is live for one call this reader cannot place, not for
#     the file;
#   - assigned indented: nested in a function, an `if` or a loop, so it is
#     conditional rather than static;
#   - assigned with `+=`: the value is built, so any one line is a fragment;
#   - a double-quoted right-hand side, a command substitution, or another
#     variable: see _gwa_static_literal;
#   - not assigned in this file at all: it comes from a sourced file, the
#     environment, or a caller, and which one is a guess about what is in
#     scope at generation time.
#
# Refusing is the safe direction in all of them: an unresolved value is
# REPORTED with its raw text, so the hole stays visible and a reader
# decides. Guessing removes the ref from the lint silently, which is the
# defect this function exists to close.
_gwa_var_literal() {
  local _name="${1}" _file="${2}" _use_lineno="${3}"
  local _lineno _nm _usable _rhs _count=0
  local _hit_lineno='' _hit_usable='' _hit_rhs=''
  while IFS=$'\t' read -r _lineno _nm _usable _rhs; do
    _count=$(( _count + 1 ))
    _hit_lineno="${_lineno}"
    _hit_usable="${_usable}"
    _hit_rhs="${_rhs}"
  done < <(_gwa_scan_assignments "${_file}" "${_name}")
  (( _count == 1 )) || return 1
  (( _hit_usable == 1 )) || return 1
  (( _hit_lineno < _use_lineno )) || return 1
  _gwa_static_literal "${_hit_rhs}"
}

# _gwa_resolve <value> <file> <lineno> -- <value> with every variable
# reference replaced by the static literal <file> holds for it at <lineno>;
# non-zero if any one of them is not resolvable that way.
#
# Termination is not an assumption: a resolved literal can never contain
# `$` (_gwa_static_literal refuses one that does), so each pass strictly
# reduces the number of `$` in the value.
_gwa_resolve() {
  local _v="${1}" _file="${2}" _lineno="${3}" _ref _name _lit
  while [[ "${_v}" =~ ${_GWA_VAR_RE} ]]; do
    # Both halves of the match are read BEFORE anything else runs. The
    # braced spelling fills capture 1 and the bare one capture 2, so the
    # name is whichever is non-empty; and the next statement re-matches
    # inside its own regex, which is exactly what would overwrite these.
    _ref="${BASH_REMATCH[0]}"
    _name="${BASH_REMATCH[1]:-${BASH_REMATCH[2]}}"
    _lit="$(_gwa_var_literal "${_name}" "${_file}" "${_lineno}")" || return 1
    _v="${_v//"${_ref}"/${_lit}}"
  done
  # A `$` the reference matcher could not read at all -- `${{ }}`,
  # `${NAME:-x}`, `$(cmd)` -- survives the loop. Refuse it rather than
  # comparing a value still carrying an unexpanded fragment.
  [[ "${_v}" == *'$'* ]] && return 1
  printf '%s' "${_v}"
}

# Where this repo declares the `<owner>/<repo>` it is served from. base is
# its own upstream, so the slug this file names is this repo's own, and it
# is the tree's single definition of it -- upgrade.sh, init.sh and
# check-base-version.sh all read it rather than repeating the literal.
readonly _GWA_UPSTREAM_REL='dist/script/base/upstream.sh'

# A bare GitHub `<owner>/<repo>`, which is what a slug looks like and what
# a clone URL, a path or a ref does not.
readonly _GWA_SLUG_RE='^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$'

# _gwa_repo_slug -- `<variable name>\t<slug>` for this repo's own
# `<owner>/<repo>`, read off the tree; non-zero when the tree does not say
# it exactly once.
#
# Derived, not hardcoded: the one file-scope static assignment in
# _GWA_UPSTREAM_REL whose literal is slug-shaped. A rename of the repo
# moves this with it, and an upstream file that declares two slugs (or
# none, or one built at runtime) yields nothing -- which switches the
# exclusion that depends on it OFF, so every call becomes a finding rather
# than every call being exempt.
_gwa_repo_slug() {
  local _lineno _nm _usable _rhs _lit _n=0 _name='' _slug=''
  while IFS=$'\t' read -r _lineno _nm _usable _rhs; do
    (( _usable == 1 )) || continue
    _lit="$(_gwa_static_literal "${_rhs}")" || continue
    [[ "${_lit}" =~ ${_GWA_SLUG_RE} ]] || continue
    _n=$(( _n + 1 ))
    _name="${_nm}"
    _slug="${_lit}"
  done < <(_gwa_scan_assignments \
    "${REPO_ROOT}/${_GWA_UPSTREAM_REL}" '[A-Za-z_][A-Za-z0-9_]*')
  (( _n == 1 )) || return 1
  printf '%s\t%s' "${_name}" "${_slug}"
}

# _gwa_assign_files <name> -- every `*.sh` under REPO_ROOT that assigns
# <name>, as repo-relative paths. A pre-filter for _gwa_tree_literal so the
# scan reads only files that mention the name at all.
_gwa_assign_files() {
  local _name="${1}" _p
  local -a _prune=()
  for _p in "${_GWA_SCAN_PRUNE[@]}"; do
    _prune+=("--exclude-dir=${_p}")
  done
  local _out _status=0
  _out="$(grep -rlE --include='*.sh' "${_prune[@]}" \
    "(^|[[:space:]])${_name}[+]?=" "${REPO_ROOT}")" || _status=$?
  if (( _status > 1 )); then
    return "${_status}"
  fi
  [[ -n "${_out}" ]] || return 0
  printf '%s\n' "${_out}" | sed "s|^${REPO_ROOT}/||"
}

# _gwa_tree_literal <name> -- the one literal every assignment of <name>
# anywhere in this tree agrees on; non-zero when they do not agree, when
# one of them is not static, or when none of them is at file scope.
#
# This is a different question from _gwa_var_literal's, and the difference
# is why crossing files is sound here and not there. _gwa_var_literal asks
# "what does this name hold at THIS line", which a value assigned in
# another file cannot answer without guessing what is in scope. This asks
# "is there ANY assignment in the tree under which this name is not the
# constant it claims to be" -- a question every assignment contributes to,
# and one that a disagreement, a runtime value, or a name only ever
# declared inside some function all answer with "yes, refuse".
_gwa_tree_literal() {
  local _name="${1}" _file _lineno _nm _usable _rhs _lit
  local _n=0 _usable_seen=0 _found=''
  while IFS= read -r _file; do
    while IFS=$'\t' read -r _lineno _nm _usable _rhs; do
      _n=$(( _n + 1 ))
      _lit="$(_gwa_static_literal "${_rhs}")" || return 1
      if (( _n == 1 )); then
        _found="${_lit}"
      elif [[ "${_found}" != "${_lit}" ]]; then
        return 1
      fi
      (( _usable == 1 )) && _usable_seen=1
    done < <(_gwa_scan_assignments "${REPO_ROOT}/${_file}" "${_name}")
  done < <(_gwa_assign_files "${_name}")
  (( _n > 0 && _usable_seen == 1 )) || return 1
  printf '%s' "${_found}"
}

# _gwa_owner_is_self <owner> -- true when the `<owner>/<repo>` half of a
# reusable-workflow callee names THIS repo.
#
# Two spellings, and no third. The slug written out, which is compared
# against the one derived from the tree; or the very variable the tree
# declares that slug in, which init.sh has to use because the value it
# needs lives in a file it sources at runtime and cannot be spelled inline.
# The variable is accepted only after _gwa_tree_literal confirms that no
# assignment anywhere in the tree gives that name a different value, so
# `${SOMEBODY_ELSE}` -- a name the tree never assigns -- is not a stand-in
# for us, and neither is our own name if some other file reassigns it.
_gwa_owner_is_self() {
  local _owner="${1}" _pair _name _slug _tree
  _pair="$(_gwa_repo_slug)" || return 1
  _name="${_pair%%$'\t'*}"
  _slug="${_pair#*$'\t'}"
  [[ "${_owner}" == "${_slug}" ]] && return 0
  [[ "${_owner}" == "\${${_name}}" || "${_owner}" == "\$${_name}" ]] || return 1
  _tree="$(_gwa_tree_literal "${_name}")" || return 1
  [[ "${_tree}" == "${_slug}" ]]
}

# _gwa_ships_workflow <value> -- true when <value> calls a reusable
# workflow THIS repo ships, whatever its ref looks like.
#
# Both halves of the callee are read, and both are derived from the tree.
# The FILE half has to name a workflow present under `.github/workflows/`
# here, as one path segment -- `<owner>/<repo>/.github/workflows/<file>` is
# the only shape GitHub accepts, so a deeper path is not this call at all.
# The OWNER half has to name this repo. Keying on the file alone was a hole
# exactly the width of the basenames this repo happens to ship: nine
# generic names, several of them ones anybody would pick, and a call to
# somebody else's `build-worker.yaml` was exempted because ours is spelled
# the same. The reason for the exclusion -- upgrade.sh rewrites
# `<worker>.yaml@vX.Y.Z` in every downstream main.yaml on every upgrade, so
# the ref has an owner -- only holds when that owner is us.
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

# _gwa_classify <value> [<file> <lineno>] -- decide what one `uses:` value is.
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
  # One static indirection is read, not excluded. Everything the resolver
  # declines is a finding -- see _gwa_var_literal for what each shape is
  # and why refusing is the direction that keeps the hole visible.
  if [[ "${_v}" == *'$'* ]]; then
    _v="$(_gwa_resolve "${_v}" "${_file}" "${_lineno}")" || return 2
  fi
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
    _pair="$(_gwa_classify "${_value}" "${REPO_ROOT}/${_GWA_FILE}" \
      "${_GWA_LINENO}")" || continue
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
    _pair="$(_gwa_classify "${_value}" "${REPO_ROOT}/${_GWA_FILE}" \
      "${_GWA_LINENO}")" || _status=$?
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
      printf '%s:%s: %s -- not a versioned action reference, and not one of the documented exclusions (a local ./ callee, a docker:// image, a call to a reusable workflow this repo ships, from this repo, by its own name). A variable is read only where the same file assigns it exactly once, above the use, at file scope, as a single-quoted literal; assigned twice, assigned below the use, assigned inside a function body or with local/declare/typeset, indented, appended to, double-quoted, taken from a command substitution or another variable, or declared in another file, it is not static and lands here. This lint cannot say whether that is in lockstep, so it refuses rather than skipping it: spell it <owner>/<repo>[/<path>]@<ref>, hoist it into one single-quoted assignment in the same file, or add the exclusion to _gwa_classify with the reason it is not a pin.\n' \
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
