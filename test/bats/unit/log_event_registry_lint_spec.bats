#!/usr/bin/env bats
#
# why: The guard over the direction the registry check never covered.
# lib/log.sh is STRICT -- it refuses a body log-events.txt does not carry
# and prints 'FATAL: unregistered log body' INSTEAD of the message -- so an
# unregistered id is not a missing label but the diagnostic being replaced
# by the registry's own complaint, at the moment something had already gone
# wrong. The tree asserted only the other direction, one site at a time: a
# driver's spec says the id ITS driver dies with is registered. That is a
# per-site habit and not a population, so four unregistered ids accumulated
# unseen (base#1220).
#
# Unit tests for script/test/drivers/log_event_registry.sh -- the "every
# event id a shipped script EMITS is registered" lint.
#
# Two properties drive the case list. FIRST, the emitted set is not just
# the direct '_log_<level> <service> <body>' sites: two of base#1220's four
# were emitted as the first argument of script/test/test.sh's one-line
# _die, which hands that argument to _log_err's body slot. A scan without
# that hop sees thirty-odd lint drivers emit nothing at all, so the
# forwarding wrapper is derived from the tree and the case list pins both
# the hop and its shadowing rule.
#
# SECOND, nothing here is a roster: the registry's own path is read out of
# the _LOG_EVENTS_FILE assignment in the scanned tree, and a resolution
# that points at no file is not a candidate. That existence rule is not a
# convenience -- this driver spells '_LOG_EVENTS_FILE=' in the pattern it
# matches with and is itself in the population, so the naive rule resolved
# to two registries on its first run.
#
# Detection runs against a controlled temp REPO_ROOT, never the live
# checkout: the tree is asserted by the 'lint-static' group that runs this
# driver, which is where a whole-tree scan belongs (base#1075).
#
# THIRD, the reader is a word splitter and not a regex over the raw line,
# and four cases are the reason. Two are MISSES -- a body wrapped onto a
# continuation line, and a body an operator terminates without a space --
# and two are FALSE FINDINGS: a call spelled out in a trailing comment,
# and a wrapper name inside a message. The false findings are the half
# that decides whether the gate survives, because an author told to
# register an id no shell will ever log is an author who mutes the lint,
# and this driver spells several such calls in its own header while
# sitting in the population it scans.


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
  source /source/script/test/drivers/log_event_registry.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
# Every line is written verbatim, so a '${1}' in one reaches the file
# unexpanded and the fixture reads the way the shipped source does.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# _seed <registered-id>... -- lay down the minimum tree every non-vacuity
# check wants: a library that says where the registry is, the registry
# itself carrying <registered-id>..., one direct call site, and one
# forwarding wrapper with one call site. Cases then add the file under
# test on top, so a failure names the shape the case is about rather than
# one of the seven refusals.
_seed() {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "# registry" "$@" "seed_ok" \
    > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  _write "dist/script/docker/wrapper/seed.sh" \
    '_log_info seed seed_ok "display=hello"'
  _write "script/test/seed_die.sh" \
    '_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }' \
    '_die seed_ok "boom"'
}

# ════════════════════════════════════════════════════════════════════
# _run_log_event_registry: violations
# ════════════════════════════════════════════════════════════════════

# why: The plain shape base#1220 found in setup_cmd.sh and toml_bridge.sh. The
# report has to name the file, the line and the id, because the author is
# looking for one argument among hundreds of call sites
@test "_run_log_event_registry: FAILS on a direct _log_ body the registry does not carry" {
  _seed
  _write "dist/script/docker/lib/setup_cmd.sh" \
    '  _log_err setup conf_write_failed "display=could not write"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/setup_cmd.sh:1: conf_write_failed"* ]]
}

# why: The load-bearing case. Two of base#1220's four were emitted as the first
# argument of test.sh's _die, not at a _log_ call site at all, so a scan
# that read only the direct sites would have reported the lint drivers
# clean while thirty-odd of them die with ids nothing checks
@test "_run_log_event_registry: FAILS on an id emitted through a forwarding wrapper" {
  _seed
  _write "script/test/drivers/bats.sh" \
    '    *) _die ci_invalid_jobs_policy \' \
    '         "BUG: unreadable jobs policy." ;;'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/test/drivers/bats.sh:1: ci_invalid_jobs_policy"* ]]
}

# why: Reporting the first offender and stopping makes the lint take as many
# runs to clear as the tree has emit sites; base#1220's own tree had
# thirteen sites over five ids, in four files
@test "_run_log_event_registry: reports EVERY offending site, not the first" {
  _seed
  _write "dist/script/docker/lib/a.sh" \
    '_log_err conf alpha_missing "display=a"' \
    '_log_warn conf beta_missing "display=b"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/a.sh:1: alpha_missing"* ]]
  [[ "${output}" == *"dist/script/docker/lib/a.sh:2: beta_missing"* ]]
}

# why: A body is a literal whether bash reads it through double quotes, single
# quotes or none, and lib/log.sh compares what the shell hands it -- so
# `_log_err ci 'missing' ...` is exactly as fatal as the double-quoted
# spelling. The first unquoting rule stripped only the double quote, which
# left the single-quoted token starting with a character no id starts
# with, so the shape was DISCARDED rather than reported and a tree holding
# it read clean. A reader of that clean line cannot tell a quoting style
# the scan does not see from a tree that has none of it
@test "_run_log_event_registry: FAILS on a single-quoted body the registry does not carry" {
  _seed
  _write "dist/script/docker/lib/q.sh" \
    "_log_err conf squote_missing \"display=a\"" \
    "_log_err conf 'squote_literal' \"display=b\""
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/q.sh:2: squote_literal"* ]]
}

# why: A wrapper call is a command, and a command sits wherever bash allows one
# -- after `then`, after `do`, after `&&`. The wrapper scan walked the line
# token pair by token pair and, on a pair whose first half was NOT a
# wrapper, skipped past BOTH halves; `then _die` therefore consumed the
# `_die` that followed it and the id after that was never looked at. The
# shipped tree hides the bug because its wrapper calls open their own
# lines, so only a fixture can hold the rule still: a non-wrapper match now
# advances past its own name alone, leaving the next token free to be read
# as the command it is
@test "_run_log_event_registry: FAILS on a wrapper call that is not the first word of its line" {
  _seed
  _write "dist/script/docker/lib/inline.sh" \
    'if true; then _die inline_missing "boom"; fi'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/inline.sh:1: inline_missing"* ]]
}

# why: bash reads a backslash-newline as nothing at all, so a call wrapped over
# two physical lines is one command and its body is as fatal as any other.
# A per-physical-line scan sees `_log_err conf \` -- service `\`, no body --
# and the real id on the line below with no call in front of it, so the
# site is skipped and the lint says clean. A reader cannot tell that from
# a tree with no such site, which is the vacuity this driver refuses
# everywhere else
@test "_run_log_event_registry: FAILS on a body on a continuation line" {
  _seed
  _write "dist/script/docker/lib/cont.sh" \
    '_log_err conf \' \
    '  continued_missing "display=boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/cont.sh:1: continued_missing"* ]]
}

# why: An argument ends where the shell says it does, and `;` `&&` `|` `)` end
# one without a space. Splitting the line on whitespace alone made
# `missing;` the body, which is not id-shaped, so the site was DISCARDED
# rather than reported -- a miss produced by the scan being coarser than
# the language it reads, and the shape every one-line `then ... ; fi`
# guard in this tree is written in
@test "_run_log_event_registry: FAILS on a body a shell operator terminates" {
  _seed
  _write "dist/script/docker/lib/op.sh" \
    '_log_err conf semi_missing; true' \
    '(_die amp_missing "boom") &'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/op.sh:1: semi_missing"* ]]
  [[ "${output}" == *"dist/script/docker/lib/op.sh:2: amp_missing"* ]]
}

# why: The over-reporting half, and the one that decides whether this lint
# survives. A `#` after code opens a comment exactly as one at column 0
# does, so prose that spells a call out to explain it emits nothing --
# and this driver, whose own header spells several, is in the population
# it scans. Only WHOLE-line comments were excluded, so a trailing one was
# read as code and the author was told to register an id no shell will
# ever log. A finding that is not a defect is what gets a gate muted
@test "_run_log_event_registry: PASSES a _log_ call in a trailing comment" {
  _seed
  _write "dist/script/docker/lib/trail.sh" \
    'true # _log_err conf trailing_prose "display=boom"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: The other over-report. A wrapper name inside a STRING is a word in a
# message, not a command -- `printf "use _die <id> for failures"` is help
# text -- and the scan read the token after it as an event id. The fix is
# the same one tokenising gives the case above: a quote that opens a word
# makes the whole quoted run ONE argument, so a name buried inside it is
# never at a command position and never consulted
@test "_run_log_event_registry: PASSES a wrapper name inside a quoted string" {
  _seed
  _write "dist/script/docker/lib/prose.sh" \
    'printf "%s\n" "use _die quoted_prose for failures"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_log_event_registry: what it leaves alone
# ════════════════════════════════════════════════════════════════════

# why: The boundary of the rule and the whole of the fix base#1220 took: an id
# the registry carries is a message the operator actually reads, so there
# is nothing to report
@test "_run_log_event_registry: PASSES an id the registry carries" {
  _seed conf_write_failed
  _write "dist/script/docker/lib/setup_cmd.sh" \
    '  _log_err setup conf_write_failed "display=could not write"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: A name is not global. script/ci/reclaim.sh defines its own _die that
# prints to stderr and never logs, so 'not a duration: 5x' is a MESSAGE,
# not an event id. Without the shadowing rule every such argument would be
# reported unregistered, which is the false finding that gets a lint muted
@test "_run_log_event_registry: PASSES a same-named function a file defines without forwarding" {
  _seed
  _write "script/ci/reclaim.sh" \
    '_die() { printf "[reclaim] ERROR: %s\n" "$*" >&2; exit 2; }' \
    '_die not_a_duration "bad input"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: The stated blind spot, pinned so it cannot change shape unnoticed. A
# body this driver would have to run a shell to know is not resolved:
# exactly one hop -- the forwarding wrapper -- is, and anything further is
# out of reach rather than quietly guessed at
@test "_run_log_event_registry: PASSES a body that is not a literal" {
  _seed
  _write "dist/script/docker/lib/b.sh" \
    '_log_err conf "${_ev}" "display=indirect"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: Half the prose in these drivers spells a _log_ call out to explain one,
# and this driver's own header names four unregistered ids verbatim. A scan
# that read commented-out code would report its own documentation
@test "_run_log_event_registry: PASSES a _log_ call inside a whole-line comment" {
  _seed
  _write "dist/script/docker/lib/c.sh" \
    '# _log_err setup conf_write_failed "display=what the old code did"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
}

# why: The registry's path is read out of the tree's own _LOG_EVENTS_FILE
# assignment rather than written down in the driver, so moving or renaming
# the registry moves this lint with it instead of emptying it. A literal
# path here would keep agreeing with itself after lib/log.sh stopped
@test "_run_log_event_registry: reads the registry the tree names, not a path of its own" {
  _write "dist/script/docker/lib/elsewhere/logging.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/events.list"'
  printf '%s\n' "seed_ok" "renamed_ok" \
    > "${SCRATCH}/dist/script/docker/lib/elsewhere/events.list"
  _write "dist/script/docker/wrapper/seed.sh" \
    '_log_info seed renamed_ok "display=hello"'
  _write "script/test/seed_die.sh" \
    '_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }' \
    '_die seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dist/script/docker/lib/elsewhere/events.list"* ]] \
    || [[ "${output}" == *"2 id(s) registered"* ]]
}

# why: The lint phase runs its drivers under `set -o pipefail`, and the first
# spelling of the membership test was `printf '%s\n' "${registered[@]}" |
# grep -Fxq`. grep -q exits on the match, printf takes SIGPIPE, pipefail
# promotes that 141 over grep's 0, and a SUCCESSFUL lookup reads as "not
# registered" -- host-direct, with no pipefail, the same scan called the tree
# clean while the lint phase reported 29 registered ids as findings. The ids
# here are seeded so a match lands before the last line, which is what makes
# the early close happen at all
@test "_run_log_event_registry: a registered id stays registered under pipefail" {
  _seed early_hit middle_hit late_hit
  _write "dist/script/docker/lib/d.sh" \
    '_log_err conf early_hit "display=a"' \
    '_log_warn conf middle_hit "display=b"'
  set -o pipefail
  run _run_log_event_registry
  set +o pipefail
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
}

# why: The clean line is the audit trail: it says how many emit sites were read,
# how many came through a wrapper and how many ids the registry carries, so
# a reader of a green CI log can tell a scan that checked the tree from one
# that checked nothing
@test "_run_log_event_registry: a clean tree passes and the counts print" {
  _seed
  run _run_log_event_registry
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"log event registry lint: clean"* ]]
  [[ "${output}" == *"through a wrapper"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_log_event_registry: the refusals
#
# Seven ways this lint could report a clean tree having checked nothing.
# Each case asserts the sentence only ITS refusal prints: several of them
# end in the same words, so a case that asserted the shared phrase would
# pass with the guard it names deleted.
# ════════════════════════════════════════════════════════════════════

# why: A walk that died part way through hands the lint a short list, which
# reads exactly like a tree with less in it. Captured rather than piped,
# because a status read through `| sort` belongs to sort
@test "_run_log_event_registry: DIES when the walk for *.sh fails" {
  _seed
  mktemp() { return 1; }
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not finish"* ]]
}

# why: An empty population is the shape that goes green by construction: the
# shipped scripts moved, the lint reads nothing and reports that every id
# is registered
@test "_run_log_event_registry: DIES when the tree holds no *.sh at all" {
  mkdir -p "${SCRATCH}/dist" "${SCRATCH}/script"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a scan with no population is not a pass"* ]]
}

# why: Without the assignment the registry's location is unknown, and an
# unknown allowed set accepts everything. It is also the existence half of
# the rule: this driver spells the assignment in its own matching pattern,
# so a resolution that points at no file has to be no candidate
@test "_run_log_event_registry: DIES when nothing names a registry that exists" {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  _write "script/test/seed_die.sh" \
    '_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }' \
    '_die seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"to a path that exists"* ]]
}

# why: Two registries is not two allowed sets to union: picking either would
# make the other's ids look unregistered, so the lint would report findings
# that are not defects and hide the ones that are
@test "_run_log_event_registry: DIES when two different registries are implied" {
  _seed
  _write "script/test/other_log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "seed_ok" > "${SCRATCH}/script/test/log-events.txt"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"different registry files are implied"* ]]
}

# why: An empty registry makes EVERY emitted id unregistered at runtime, so
# reading it as the allowed set is reading nothing. A comment-only file is
# the shape that matters: the header is still there, so the file looks
# populated to anything that only checks its size
@test "_run_log_event_registry: DIES when the registry carries no id" {
  _seed
  printf '%s\n' "# log-events.txt" "#" \
    > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"carries no event id"* ]]
}

# why: The blind-detector case, and the one that matters most: 271 direct call
# sites exist today, so zero means the detector stopped matching -- a
# renamed helper, a changed argument order -- and a blind detector reports
# every id registered
@test "_run_log_event_registry: DIES when no _log_ call site is read anywhere" {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "seed_ok" > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  _write "script/test/plain.sh" \
    '_emit() { local _ev="${1}"; shift; _report ci "${_ev}"; }' \
    '_emit seed_ok "boom"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"the detector read nothing"* ]]
}

# why: The wrapper half is where two of base#1220's four hid, and it is the
# half that can vanish silently: with no forwarding wrapper found the scan
# shrinks to the direct call sites and the thirty-odd lint drivers' events
# leave the population without anything saying so
@test "_run_log_event_registry: DIES when nothing forwards its first argument into a body slot" {
  _write "dist/script/docker/lib/log.sh" \
    'readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"'
  printf '%s\n' "seed_ok" > "${SCRATCH}/dist/script/docker/lib/log-events.txt"
  _write "dist/script/docker/wrapper/seed.sh" \
    '_log_info seed seed_ok "display=hello"'
  run _run_log_event_registry
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"forwards its first argument"* ]]
}
