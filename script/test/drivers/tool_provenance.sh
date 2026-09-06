#!/usr/bin/env bash
# drivers/tool_provenance.sh - "a CI job may not run a tool this repo pins
# unless it obtains the pin" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_tool_provenance. Follows drivers/self_hosted_guard.sh /
# drivers/just_provenance.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# ── The hazard ──────────────────────────────────────────────────────────────
#
# The `shellcheck` job ran whatever `ubuntu-latest` shipped pre-installed
# (base#1080). One line of the workflow said so and that was the whole
# configuration. The local gate runs the pinned v0.11.0 out of the
# test-tools image, so the two could reach opposite verdicts on the same
# commit: a PR passed the gate and went red on SC2120 in CI. The cheap
# direction is that round trip. The expensive direction is silent -- CI
# green on a finding the pinned version would have caught -- and which
# direction a given rule falls in changed with GitHub's runner-image
# release schedule rather than with a commit in this repo.
#
# Nothing in the tree was looking. `pin-coverage` asks "is every version
# this tree NAMES declared", and that job named none, so the lint was
# working correctly and the value sat outside its reach. The job was found
# by accident, by a PR that happened to trip a rule two versions disagree
# about.
#
# ── Why this is a lint and not a list ───────────────────────────────────────
#
# The tempting shape is a roster of jobs allowed to use runner-provided
# tools. That roster is correct the day it is written and wrong the day
# the next job is added, and nothing notices -- the same decay that took
# the _LINT_TOOLS completeness gap, the downstream roster and the release
# archive's path list. So BOTH populations here are computed:
#
#   the TOOLS   every pin script/ci/test-tools-pins.sh's roster reports
#               whose own probe invokes it BY NAME. A pin added to
#               dockerfile/Dockerfile.test-tools joins this scan with this
#               file untouched. ALPINE_VERSION and the three bats helper
#               libraries fall out on their own: their probes read
#               /etc/alpine-release and ask `git describe`, so they are
#               not things a job can invoke. That derivation replaces the
#               table of "which pins are commands" this driver would
#               otherwise carry -- and a table is what goes stale.
#   the JOBS    every job of every workflow file under .github/workflows/.
#
# ── What counts as DEMAND ───────────────────────────────────────────────────
#
# Two sources, because the job that started this carries the second and
# not the first:
#
#   direct     a pinned tool in COMMAND POSITION in one of the job's `run:`
#              blocks. Command position, not a word match: ci-rollup echoes
#              `shellcheck:` as the name of the job whose result it
#              reports, the coverage jobs name a `coverage/kcov-merged/`
#              path, and every bats job is NAMED after the harness. None of
#              those runs anything, and a lint answered by muting it stops
#              being read.
#   selector   a HOST-DIRECT `script/test/test.sh` invocation demands
#              whatever the drivers it selects invoke. `--shellcheck-only`
#              contains the string `shellcheck` only as part of a FLAG, so
#              a command-position scan alone reads base#1080's job as
#              clean. The demand is resolved by reading the selected
#              driver's own source, so a driver that starts calling a
#              pinned binary is picked up with nothing here to update.
#
# Host-direct is `--<name>-only` and `--lint-group`, which is what those
# two spellings MEAN in test.sh: no compose, no test-tools image, the
# driver runs on the runner. Every other mode reaches its tools inside the
# pinned image, so it provisions itself by construction. That is the
# residual limit, stated rather than papered over: a compose-mode selector
# that started running a tool on the host would not be seen. It is bounded
# by the naming convention being test.sh's own, and by the same
# convention deciding which arm of its dispatcher runs.
#
# `--lint-group N/T` takes its index from a matrix expression this lint
# cannot evaluate, so the demand is the union over the whole partition --
# obtained by asking test.sh for the members of the SINGLE-group partition
# (`--lint-group-members 1/1`), which is every lint without a dedicated job
# of its own. Asking the dispatcher is the point: a list here of which
# driver lands in which group would be the roster this file refuses to be.
#
# A selector naming a driver file that does not exist is REFUSED, not
# skipped. An unresolvable demand read as no demand is the silent green
# this whole driver exists to close.
#
# ── What counts as PROVENANCE ───────────────────────────────────────────────
#
#   the image   a job that runs script/ci/obtain_test_tools.sh gets every
#               tool from the image whose every version this repo pins, so
#               no per-tool evidence is asked of it.
#   the pin     otherwise the job must name the DECLARATION for that tool:
#               an accessor of dockerfile/Dockerfile.test-tools
#               (script/ci/test-tools-pins.sh, dist/script/base/just-version.sh)
#               together with the tool's own pin key -- `<TOOL>_VERSION`,
#               or the `<tool>-version:` input a setup action takes.
#
# Both are evidence that the version came from the one place that declares
# it. Neither is satisfied by a literal, which is deliberate: a version
# typed into a workflow that agrees with the Dockerfile today is a second
# place to forget tomorrow, and just_provenance.sh already refuses that
# shape for its own tool.
#
# Provenance is NAMING the declaration, not a proven install, and the
# distinction is worth stating because it bounds what a green run means: a
# job that merely echoed `SHELLCHECK_VERSION` beside the accessor would
# satisfy this while still running the runner's binary. The reason it is
# not tightened into "the job must be seen installing it" is that the one
# job here obtaining a pinned tool from the declaration does so through a
# setup ACTION (`extractions/setup-just` with a `just-version:` input), and
# there is no install command in its shell to find. What the job then owes
# its readers is the assertion the shellcheck job carries: ask the binary
# on PATH its version and compare it to the pin. That is a property of the
# job, not of this scan.
#
# ── Scope ───────────────────────────────────────────────────────────────────
#
# .github/workflows/ only. This lint is about what a CI JOB runs; a
# developer host is not a job, and the Dockerfiles are where the pins are
# declared rather than places they are consumed unpinned.
#
# Within that scope, what a job RUNS is read from its `run:` shell and
# nowhere else. Three residual limits follow, stated rather than papered
# over, each a false negative:
#
#   an action     a step that is only `uses:` runs whatever that action
#                 runs, and its source is not in this tree. A marketplace
#                 action carrying its own copy of a pinned tool reads as no
#                 demand at all.
#   indirection   a tool reached through a variable (`TOOL=shellcheck;
#                 "${TOOL}" -x`) or from inside a quoted span (`eval "..."`,
#                 a `"$(...)"` substitution) is not in command position for
#                 the split below to find.
#   a repo script demand through a repo script that is NOT test.sh --
#                 `bash ./script/test/drivers/coverage_gate.sh` -- is not
#                 followed. The obvious generalisation, one-level closure
#                 into any repo script a job names, was tried and measured
#                 wrong: test.sh's own `_LINT_TOOLS` array holds bare
#                 `shellcheck` / `hadolint` elements, which read as command
#                 position, so every job calling test.sh would demand every
#                 tool. Demand has to be DECLARED per entry point for that
#                 to work, which is a separate change.

# ── The tool provenance lint ────────────────────────────────────────────────

# Where the workflows live. A directory, not a file list, so a workflow
# added tomorrow is scanned without touching this driver.
readonly _TP_WORKFLOW_DIR_REL='.github/workflows'

# The roster accessor: the population of pinned tools, derived from
# dockerfile/Dockerfile.test-tools.
readonly _TP_ROSTER_REL='script/ci/test-tools-pins.sh'

# The dispatcher, asked to resolve a lint-group spec into its members.
readonly _TP_TEST_SH_REL='script/test/test.sh'

# Where a lint driver's source lives. A `--<name>-only` selector names the
# driver `<name>` with dashes turned into underscores.
readonly _TP_DRIVER_DIR_REL='script/test/drivers'

# The repo this driver is PART of, derived from its own location
# (<root>/script/test/drivers/tool_provenance.sh) rather than from a cwd
# walk. It is what the demand floor below is asked about: scanning the
# tree this file ships in is the run whose zero-demand answer means the
# reader broke, while a scratch tree of one fixture legitimately has none.
#
# ${BASH_SOURCE[0]:-$0} rather than the bare indexed read: the array is not
# populated in every context (the kcov-instrumented shell most of all) and
# the bare form aborts under nounset.
_TP_LIVE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
readonly _TP_LIVE_ROOT

# The one obtain path every image-consuming job reaches: a job that runs
# it has the tooling image, and that image carries every pin.
readonly _TP_IMAGE_RE='script/ci/obtain_test_tools\.sh'

# Accessors of the declaration. A job that names one of these is reading
# the pinned version rather than restating it.
readonly _TP_ACCESSOR_RE='(test-tools-pins\.sh|just-version\.sh)'

# Command prefixes a real invocation may hide behind. `xargs -0 shellcheck`
# and `sudo install` both put the tool one token to the right of the
# command word, and an option or an assignment between them moves it
# further. This is the detector's vocabulary, not its population -- the
# same split just_provenance.sh draws between its marker table and the
# tree it scans.
readonly _TP_PREFIX_RE='^(sudo|env|command|exec|time|nice|nohup|xargs|builtin|!)$'

# The separator the command split normalises onto. A control character no
# text file this lint reads can carry, so it cannot collide with the text
# being split.
readonly _TP_SEP=$'\x01'

# ── The workflow reader ─────────────────────────────────────────────────────
#
# Flattens one workflow file into a tagged record stream, one record per
# line, tab-separated:
#
#   JOB   <name>   a job block starts
#   RUN   <line>   one line of shell a step actually executes
#   TEXT  <line>   any non-comment line inside the job, `uses:` and `with:`
#                  included -- the surface provenance evidence is read from
#
# Comment lines are dropped from both: a comment installs nothing and runs
# nothing, and the prose of this repo -- this header included -- names
# every tool it reasons about.
#
# Written for busybox-awk / mawk / gawk alike (the three the test-tools
# image carries): no gensub, no three-argument match, no non-POSIX
# character classes.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _TP_AWK='
function indent_of(s,   n) { match(s, /^[ \t]*/); return RLENGTH }
BEGIN { injobs = 0; inrun = 0; runind = 0 }
/^jobs:[ \t]*(#.*)?$/ { injobs = 1; inrun = 0; next }
/^[^ \t#]/      { injobs = 0; inrun = 0; next }
injobs != 1     { next }
{
  if (inrun == 1) {
    if ($0 ~ /^[ \t]*$/) { next }
    if (indent_of($0) > runind) {
      if ($0 !~ /^[ \t]*#/) { print "RUN\t" $0; print "TEXT\t" $0 }
      next
    }
    inrun = 0
  }
  if ($0 ~ /^[ \t]*#/) { next }
  if ($0 ~ /^[ \t]*$/) { next }
  if ($0 ~ /^  [A-Za-z0-9_.-]+:[ \t]*(#.*)?$/) {
    name = $0; sub(/^  /, "", name); sub(/:[ \t]*(#.*)?$/, "", name)
    print "JOB\t" name
    next
  }
  if ($0 ~ /^[ \t]*-?[ \t]*run:/) {
    rest = $0; sub(/^[ \t]*-?[ \t]*run:[ \t]*/, "", rest)
    runind = indent_of($0)
    if (rest == "" || rest == "|" || rest == ">" || rest == "|-" \
        || rest == ">-" || rest == "|+" || rest == ">+") { inrun = 1 }
    else { print "RUN\t" rest }
    print "TEXT\t" $0
    next
  }
  print "TEXT\t" $0
}
'

# The quote stripper.
#
# A command name is never inside a string. PROSE is: this repo's failure
# messages are long sentences that carry semicolons and the names of the
# tools they reason about, and a textual split reads
# `"...; bats is not reliable on such a body either."` as a command called
# `bats`. So every quoted span is blanked before the split, and an
# unterminated quote blanks the rest of its line -- a string continued onto
# the next line is string all the way to the end of this one.
#
# The residual limit, stated rather than papered over: a command hidden
# inside a quoted span (`eval "shellcheck ..."`, a `"$(...)"` substitution)
# is not seen. That is a false NEGATIVE, which is the direction this stripper
# adds; the false positives it removes are the ones that get a lint muted,
# and a muted lint sees nothing at all.
#
# Written for busybox-awk / mawk / gawk alike: no gensub, no three-argument
# match.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _TP_STRIP_AWK='
{
  line = $0; out = ""; q = ""; n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (q != "") { if (c == q) { q = "" } ; continue }
    if (c == "\047" || c == "\042") { q = c; out = out " "; continue }
    out = out c
  }
  print out
}
'

# ── Counters ────────────────────────────────────────────────────────────────

_TP_JOBS=0
_TP_FILE_JOBS=0
_TP_DEMANDS=0
_TP_PROVIDED=0
_TP_FINDINGS=0

_tp_reset() {
  _TP_JOBS=0
  _TP_FILE_JOBS=0
  _TP_DEMANDS=0
  _TP_PROVIDED=0
  _TP_FINDINGS=0
}

# The roster, as parallel arrays. Filled by _tp_load_roster.
_TP_TOOLS=()

# A cache of driver-source scans, so a driver named by several jobs is read
# once. `-g` because this file is SOURCED: a bare `declare -A` inside a
# caller's function body would make the map local to that call.
declare -gA _TP_DRIVER_CACHE=()

# Where each demand came from, keyed by tool, reset per job. A finding that
# says only "this job runs shellcheck" sends its reader looking for the
# word `shellcheck` in a job whose shell says `--shellcheck-only`; the
# origin is what turns the report into somewhere to go.
declare -gA _TP_ORIGIN=()

# ── The roster ──────────────────────────────────────────────────────────────

# _tp_load_roster -- fill _TP_TOOLS with the pins that are INVOCABLE.
#
# A roster row is `<ARG>\t<pin>\t<probe>`. The tool's name is the ARG with
# its `_VERSION` suffix dropped, lower-cased, underscores turned into the
# dashes a command name uses. It is invocable when the probe's own first
# word IS that name -- which is the roster saying "this pin is a program
# you run", in its own words rather than in a table kept here.
_tp_load_roster() {
  local _accessor="${REPO_ROOT}/${_TP_ROSTER_REL}"
  _TP_TOOLS=()
  if [[ ! -x "${_accessor}" && ! -f "${_accessor}" ]]; then
    return 2
  fi
  local _arg _pin _probe _name _first
  while IFS=$'\t' read -r _arg _pin _probe; do
    [[ -n "${_arg}" ]] || continue
    _name="${_arg%_VERSION}"
    _name="$(printf '%s' "${_name}" | tr 'A-Z_' 'a-z-')"
    _first="${_probe%% *}"
    [[ "${_first}" == "${_name}" ]] || continue
    _TP_TOOLS+=("${_name}")
  done < <(bash "${_accessor}" roster 2>/dev/null)
  [[ "${#_TP_TOOLS[@]}" -gt 0 ]]
}

# ── Command-position detection ──────────────────────────────────────────────

# _tp_commands <outarray> <shell-line> -- the command words of one line.
#
# The line is cut at every operator that ENDS one command and begins the
# next, and at the openers of a substitution, then each piece is stripped
# of the prefixes and options that can stand in front of the real command
# name. What is left is the word the shell would execute.
#
# The split is textual, so an operator inside a quoted string cuts where
# the shell would not. That direction only ever invents a command word out
# of quoted text; it cannot hide one, so it fails toward a finding to be
# answered rather than toward a silent pass.
_tp_commands() {
  local -n _tpc_out="${1}"
  local _s="${2}" _piece _rest _tok
  _tpc_out=()
  local _op
  # shellcheck disable=SC2016 # the literal operators being split ON, not expansions.
  for _op in '&&' '||' ';' '|' '$(' '`' '(' '{' ' then ' ' do ' ' else '; do
    _s="${_s//"${_op}"/${_TP_SEP}}"
  done
  _rest="${_s}"
  while :; do
    if [[ "${_rest}" == *"${_TP_SEP}"* ]]; then
      _piece="${_rest%%"${_TP_SEP}"*}"
      _rest="${_rest#*"${_TP_SEP}"}"
    else
      _piece="${_rest}"
      _rest=""
    fi
    # Drop the prefixes, options and assignments standing in front of the
    # command word, then take what is left. Globbing is off across the
    # split: a `*.sh` argument would otherwise be expanded against the
    # scanning host's cwd, so what the lint reads would depend on where it
    # was run from.
    set -f
    # shellcheck disable=SC2086 # deliberate word split of a shell fragment.
    set -- ${_piece}
    set +f
    while [[ "$#" -gt 0 ]]; do
      _tok="${1}"
      if [[ "${_tok}" =~ ${_TP_PREFIX_RE} || "${_tok}" == -* || "${_tok}" == *=* ]]; then
        shift
        continue
      fi
      break
    done
    if [[ "$#" -gt 0 ]]; then
      _tpc_out+=("${1}")
    fi
    [[ -n "${_rest}" ]] || break
  done
}

# _tp_fold <outarray> <line>... -- join backslash continuations.
#
# A wrapped command is ONE command, and every reader below works a line at
# a time. Unfolded, both directions are wrong: `./script/test/test.sh \`
# with its `--<lint>-only` on the next physical line loses the selector
# entirely -- the demand base#1080 is made of -- and the second line of any
# continued command reads as a command of its own, so a wrapped ARGUMENT
# that spells a pinned tool reports a demand nothing makes.
#
# The fold is on the trailing backslash, which is shell syntax rather than
# anything this repo chose, so it needs nothing kept in step. Its one
# residual: a line ending in an ESCAPED backslash (`\\`) is not a
# continuation and is folded anyway. That direction merges two commands
# into one line, where the first word still wins -- a false negative on the
# second, never a false positive.
_tp_fold() {
  local -n _tpf_out="${1}"; shift
  _tpf_out=()
  local _acc="" _line
  for _line in "$@"; do
    if [[ "${_line}" == *\\ ]]; then
      _acc+="${_line%\\} "
      continue
    fi
    _tpf_out+=("${_acc}${_line}")
    _acc=""
  done
  # A trailing continuation with nothing after it is still a line of shell.
  [[ -z "${_acc}" ]] || _tpf_out+=("${_acc}")
}

# _tp_tools_in_shell <outvar> <origin> <line>... -- the pinned tools
# invoked by the given shell lines, as a space-delimited set in <outvar>.
# <origin> is recorded for each tool this call is the first to find.
_tp_tools_in_shell() {
  local -n _tpt_out="${1}"; shift
  local _origin="${1}"; shift
  local _line _cmd _tool
  local -a _cmds=() _stripped=()
  [[ "$#" -gt 0 ]] || return 0
  mapfile -t _stripped < <(printf '%s\n' "$@" | awk "${_TP_STRIP_AWK}")
  for _line in "${_stripped[@]}"; do
    _tp_commands _cmds "${_line}"
    for _cmd in "${_cmds[@]}"; do
      _cmd="${_cmd##*/}"
      for _tool in "${_TP_TOOLS[@]}"; do
        if [[ "${_cmd}" == "${_tool}" && " ${_tpt_out} " != *" ${_tool} "* ]]; then
          _tpt_out+="${_tool} "
          _TP_ORIGIN["${_tool}"]="${_origin}"
        fi
      done
    done
  done
}

# ── Driver resolution ───────────────────────────────────────────────────────

# _tp_driver_tools <lint-name> <toolsvar> <missingvar> -- add the tools
# driver <lint-name> invokes to <toolsvar>. A driver whose source is not
# there to be read is named in <missingvar> instead: what it runs cannot
# be resolved, and an unresolvable demand must never read as an absent one.
_tp_driver_tools() {
  local _lint="${1}"
  local -n _tpd_out="${2}"
  local -n _tpd_missing="${3}"
  local _file="${_TP_DRIVER_DIR_REL}/${_lint//-/_}.sh"
  local _abs="${REPO_ROOT}/${_file}"
  if [[ ! -f "${_abs}" ]]; then
    if [[ " ${_tpd_missing} " != *" ${_file} "* ]]; then
      _tpd_missing+="${_file} "
    fi
    return 1
  fi
  if [[ -z "${_TP_DRIVER_CACHE["${_file}"]+set}" ]]; then
    local -a _lines=() _folded=()
    local _found=""
    mapfile -t _lines < <(grep -v '^[[:space:]]*#' "${_abs}" || true)
    if [[ "${#_lines[@]}" -gt 0 ]]; then
      _tp_fold _folded "${_lines[@]}"
      _tp_tools_in_shell _found "${_file}" "${_folded[@]}"
    fi
    _TP_DRIVER_CACHE["${_file}"]="${_found}"
  fi
  local _tool
  for _tool in ${_TP_DRIVER_CACHE["${_file}"]}; do
    if [[ " ${_tpd_out} " != *" ${_tool} "* ]]; then
      _tpd_out+="${_tool} "
      _TP_ORIGIN["${_tool}"]="${_file}, which the job's selector names"
    fi
  done
  return 0
}

# _tp_group_members -- the lints a `--lint-group` invocation can select,
# asked of the dispatcher rather than listed here. `1/1` is the whole
# partition, which is the union over every index a matrix could supply.
_tp_group_members() {
  local _abs="${REPO_ROOT}/${_TP_TEST_SH_REL}"
  [[ -f "${_abs}" ]] || return 1
  bash "${_abs}" --lint-group-members 1/1 2>/dev/null
}

# ── Per-job classification ──────────────────────────────────────────────────

# _tp_job_demand <outvar> <missing-var> <run-line>...
#
# The pinned tools the job reaches: those in command position, plus those
# the drivers its host-direct selectors name invoke. Driver files that are
# not there land in <missing-var> rather than being skipped.
_tp_job_demand() {
  local -n _tpj_out="${1}"
  local -n _tpj_missing="${2}"
  shift 2
  local _line _lint
  local -a _raw=("$@") _runs=()
  [[ "${#_raw[@]}" -gt 0 ]] || return 0
  # Folded first, and once: both scans below read a LOGICAL line, so the
  # selector and the `test.sh` that carries it cannot be split apart by a
  # line wrap, and a wrapped argument cannot pose as a command.
  _tp_fold _runs "${_raw[@]}"

  _tp_tools_in_shell _tpj_out "the job's own shell" "${_runs[@]}"

  for _line in "${_runs[@]}"; do
    [[ "${_line}" == *"${_TP_TEST_SH_REL}"* || "${_line}" == *'test.sh'* ]] || continue
    if [[ "${_line}" =~ --([a-z0-9-]+)-only([^a-z0-9-]|$) ]]; then
      _tp_driver_tools "${BASH_REMATCH[1]}" _tpj_out _tpj_missing || true
    fi
    if [[ "${_line}" == *'--lint-group'* ]]; then
      while IFS= read -r _lint; do
        [[ -n "${_lint}" ]] || continue
        _tp_driver_tools "${_lint}" _tpj_out _tpj_missing || true
      done < <(_tp_group_members)
    fi
  done
  return 0
}

# _tp_provides <tool> <job-text> -- does the job obtain <tool> from the
# declaration?
_tp_provides() {
  local _tool="${1}" _text="${2}" _key
  if [[ "${_text}" =~ ${_TP_IMAGE_RE} ]]; then
    return 0
  fi
  [[ "${_text}" =~ ${_TP_ACCESSOR_RE} ]] || return 1
  _key="$(printf '%s' "${_tool}" | tr 'a-z-' 'A-Z_')_VERSION"
  [[ "${_text}" == *"${_key}"* || "${_text}" == *"${_tool}-version:"* ]]
}

# ── The lint ────────────────────────────────────────────────────────────────

_run_tool_provenance() {
  echo "--- Running CI tool provenance lint ---"

  local _dir="${REPO_ROOT}/${_TP_WORKFLOW_DIR_REL}"
  if [[ ! -d "${_dir}" ]]; then
    _die ci_tool_provenance \
      "workflow directory '${_TP_WORKFLOW_DIR_REL}/' not found under ${REPO_ROOT} -- there is nothing to scan, so the lint would pass vacuously."
    return 1
  fi

  local -a _files=()
  local _file
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_dir}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
             -print0 2>/dev/null | sort -z)
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_tool_provenance \
      "no workflow under '${_TP_WORKFLOW_DIR_REL}/' -- nothing was scanned, so the lint would pass vacuously."
    return 1
  fi

  _tp_reset
  _TP_DRIVER_CACHE=()
  if ! _tp_load_roster; then
    _die ci_tool_provenance \
      "'${_TP_ROSTER_REL} roster' named no invocable pin. The population of tools is READ from it, so an empty answer is a scan with nothing to look for -- which passes having checked nothing. The accessor, or the declaration it reads, is what to look at."
    return 1
  fi

  local _report="" _rel _tag _payload _job="" _text="" _demand="" _missing=""
  local -a _runs=()

  # _flush -- score the job the reader has just finished.
  _tp_flush_job() {
    [[ -n "${_job}" ]] || return 0
    _TP_JOBS=$(( _TP_JOBS + 1 ))
    _TP_FILE_JOBS=$(( _TP_FILE_JOBS + 1 ))
    _demand=""
    _missing=""
    _TP_ORIGIN=()
    _tp_job_demand _demand _missing "${_runs[@]}"
    local _entry _tool
    for _entry in ${_missing}; do
      _report+="${_rel}: job ${_job}: selects a lint whose driver '${_entry}' is not there to be read, so what it runs cannot be resolved. An unresolvable demand is not an absent one."$'\n'
      _TP_FINDINGS=$(( _TP_FINDINGS + 1 ))
    done
    for _tool in ${_demand}; do
      _TP_DEMANDS=$(( _TP_DEMANDS + 1 ))
      if _tp_provides "${_tool}" "${_text}"; then
        _TP_PROVIDED=$(( _TP_PROVIDED + 1 ))
      else
        _report+="${_rel}: job ${_job}: runs '${_tool}' (from ${_TP_ORIGIN["${_tool}"]:-an unrecorded origin}), which this repo pins, but obtains it from nowhere -- so it runs whatever the runner image happens to carry."$'\n'
        _TP_FINDINGS=$(( _TP_FINDINGS + 1 ))
      fi
    done
    _job=""
  }

  local _unreadable=""
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _job=""
    _text=""
    _runs=()
    _TP_FILE_JOBS=0
    while IFS=$'\t' read -r _tag _payload; do
      case "${_tag}" in
        JOB)
          _tp_flush_job
          _job="${_payload}"
          _text=""
          _runs=()
          ;;
        RUN)  _runs+=("${_payload}") ;;
        TEXT) _text+="${_payload}"$'\n' ;;
      esac
    done < <(awk "${_TP_AWK}" "${_file}")
    _tp_flush_job
    [[ "${_TP_FILE_JOBS}" -gt 0 ]] || _unreadable+="${_rel} "
  done
  unset -f _tp_flush_job

  # Non-vacuity, asked of EVERY FILE rather than of the tree.
  #
  # A whole-tree floor only fires when no file at all yielded a job, so one
  # file the reader cannot see is skipped in silence beside nine it can --
  # and the clean line still counts that file among the workflows scanned,
  # which reads as coverage it does not have. `jobs:` is required of every
  # GitHub workflow, so a file that yielded none is a reader that stopped
  # reading, not a workflow without work.
  if [[ -n "${_unreadable}" ]]; then
    _die ci_tool_provenance \
      "no job could be read out of: ${_unreadable}-- nothing in those file(s) was classified, so the lint would pass vacuously over them while counting them as scanned. Every GitHub workflow declares 'jobs:', so the record reader, not the workflows, is what to look at: a job key it recognises is two spaces of indent, a name, a colon and nothing else but a comment."
    return 1
  fi

  if [[ -n "${_report}" ]]; then
    _die ci_tool_provenance \
      "a CI job runs a pinned tool it does not obtain:
${_report}One declaration (the ARG lines of dockerfile/Dockerfile.test-tools) is what every path must read, through ${_TP_ROSTER_REL} or dist/script/base/just-version.sh; nothing restates the number. A job satisfies this either by obtaining the pinned tooling image (script/ci/obtain_test_tools.sh), or by installing the tool itself from that declaration -- naming the accessor and the tool's own pin key (<TOOL>_VERSION, or a <tool>-version: input)."
    return 1
  fi

  # The demand floor guards THIS repo, whose lint jobs demonstrably run
  # pinned binaries: zero demands here means the reader stopped reading,
  # not that the workflows changed. It is asked only of the live tree,
  # because a scratch tree of one fixture legitimately has none and a floor
  # that fired there would make every negative case untestable.
  if [[ "${_TP_DEMANDS}" -eq 0 && "${REPO_ROOT}" == "${_TP_LIVE_ROOT}" ]]; then
    _die ci_tool_provenance \
      "${_TP_JOBS} job(s) scanned and not one of them was found to reach ANY of the ${#_TP_TOOLS[@]} pinned tool(s) -- 'every job obtains what it runs' is an empty statement here. The demand reader, not the workflows, is what to look at: the lint phase's own CI jobs run pinned binaries."
    return 1
  fi

  echo "CI tool provenance lint: clean (${_TP_JOBS} job(s) across ${#_files[@]} workflow(s); ${_TP_DEMANDS} demand(s) on ${#_TP_TOOLS[@]} pinned tool(s), all obtained)"
}
