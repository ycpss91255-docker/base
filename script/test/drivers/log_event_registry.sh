#!/usr/bin/env bash
# drivers/log_event_registry.sh - "every event id a shipped script EMITS is
# in the registry" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_log_event_registry.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/test_name_backtick.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# ── The asymmetry this closes ───────────────────────────────────────────────
#
# _log_* is STRICT: lib/log.sh refuses a body that log-events.txt does not
# carry and prints `FATAL: unregistered log body "<id>"` in place of the
# message. So an unregistered id is not a missing label, it is the message
# the operator was supposed to read being replaced by the registry's own
# refusal, at exactly the moment something went wrong.
#
# The tree already asserted the OTHER direction, one site at a time: a
# driver's spec asserts that the id ITS driver dies with is registered
# (action_ref_agreement, spec_repo_root, and others say so by name). That
# is a per-site habit, not a population, so it answers "is this id
# registered?" and never "is every id registered?". base#1220 found four
# that nothing asked about -- conf_write_failed on two branches of
# setup_cmd.sh, ci_invalid_jobs_policy and ci_no_fragile_files in
# drivers/bats.sh, and no_such_file in lib/toml_bridge.sh. Three of them
# predate the habit; all four were reachable and fatal.
#
# ── Both sides are derived; there is no roster and no exemption list ────────
#
# A hand-written list of "the ids we know about" is the declared-population
# smell base#1089, base#1090 and base#1113 each spent a PR removing: it is
# correct the day it is written and wrong the day the next emit site lands,
# with the gate still green. Nothing here is enumerated:
#
#   - the FILES are every *.sh under the shipped roots below, walked.
#   - the REGISTRY is found by reading the tree: the one file in that
#     population that assigns `_LOG_EVENTS_FILE=`, resolved against its own
#     directory. The path is never spelled here, so moving lib/log.sh moves
#     this lint with it instead of emptying it.
#   - the REGISTERED ids are that file's non-comment, non-blank lines, read
#     the way _log_is_registered reads them (`grep -Fxq`, so a whole line).
#   - the EMITTED ids are the literal body argument of every `_log_*
#     <service> <body>` call site, plus the first argument of every call to
#     a FORWARDING WRAPPER.
#   - a FORWARDING WRAPPER is itself derived, not named: a function whose
#     definition passes its own first positional into the body slot of a
#     `_log_*` call. That is what script/test/test.sh's `_die` does, and
#     resolving it is what makes the thirty-odd lint drivers' `_die
#     ci_<something>` call sites visible to this scan at all -- two of
#     base#1220's four hid in exactly that shape.
#
# A NAME IS NOT GLOBAL. Two other files define their own `_die` -- one
# prints to stderr and never logs, the other logs a FIXED id and puts its
# argument in the display attribute -- so a file that defines a wrapper
# name itself, non-forwardingly, shadows it for its own call sites. Without
# that, `_die "not a duration: ${_d}"` in script/ci/reclaim.sh would be
# read as an event id and reported as unregistered, which is the kind of
# false finding that gets a lint muted.
#
# There is no exemption list, deliberately. base#1113 had to add a hygiene
# guard over one, because an exemption outlives the reason it was granted
# and then excuses the next arrival. The question this lint asks has a
# right answer in every case -- register the id -- so there is nothing an
# exemption would be for.
#
# ── Scope, and what it does NOT see ─────────────────────────────────────────
#
# The population is *.sh under dist/ and script/: the shipped wrapper and
# library tree that a consumer runs, and the repo's own CI and test
# scripts. Both emit through the same strict _log_*. test/bats/** is NOT
# scanned -- a spec writes deliberately unregistered ids as fixtures (the
# `unregistered body causes fatal exit` case in log_spec.bats is exactly
# that), so scanning it would report the lint's own evidence as a defect.
#
# Five shapes are out of the scan's reach, named rather than implied,
# with the direction each errs in:
#
#   1. A body that is not a literal -- `_log_err conf "${_ev}"` at a site
#      whose value this driver would have to run a shell to know. Only the
#      forwarding-wrapper hop above is resolved; anything further is not.
#   2. An id emitted from a *.bats file, a justfile recipe or a workflow
#      step rather than from a *.sh.
#   3. The OTHER direction: a registered id that nothing emits any more.
#      That is a different finding (dead registry entry, not a broken
#      message) with a different fix, and it is out of base#1220's bound.
#   4. A forwarding wrapper whose definition spans more than one line.
#      Only the definition LINE is read. The tree's one wrapper is a
#      one-liner, and reading a whole multi-line body instead is what
#      makes the rule unsafe rather than wider: over a long function
#      "some _log_* call, and some local assigned from ${1}" is a
#      coincidence, not a forwarding contract, and a wrongly declared
#      wrapper turns every ordinary call of that function into a reported
#      id -- the noise that gets a lint muted. The empty-wrapper refusal
#      below is what keeps this bound visible: if the one-liner shape ever
#      goes away, the lint says so instead of shrinking quietly.
#
#   5. A HEREDOC body. The reader knows shell words, not shell
#      redirection, so a line of heredoc text that happens to read like a
#      call is read as one. That OVER-reports, which is the refusing
#      direction -- and it is the direction worth naming, because a
#      finding that is not a defect is what gets a gate muted. The tree
#      holds no such line today; if one lands, the fix is to register
#      nothing and teach the reader the redirection, not to mute it.
#
# ── Non-vacuity ─────────────────────────────────────────────────────────────
#
# SIX ways this could go green having checked nothing, each a _die with its
# own sentence: a walk that failed part way through, a walk that found no
# *.sh at all, a population with no `_LOG_EVENTS_FILE=` assignment (the
# registry's location is unknown, so nothing can be compared), more than
# one such assignment resolving to different files (ambiguous), a registry
# that carries no id, and a scan that read no `_log_*` call site anywhere.
#
# The last is the one that matters: 271 direct call sites exist today, so
# zero means the detector has gone blind -- a renamed helper, a changed
# argument order -- and a blind detector reports a clean tree.
#
# A seventh is the wrapper half, which is where two of the four hid: when
# the population defines no forwarding wrapper AT ALL, the `_die
# ci_<something>` family is out of reach and this lint silently shrinks to
# the direct call sites. That is refused too, by its own sentence.

# ── The emitted-id registry lint ────────────────────────────────────────────

# The shipped roots. dist/ is what a consumer gets; script/ is what this
# repo runs in CI. Both load lib/log.sh and both emit through it.
readonly _LER_ROOTS=('dist' 'script')

# The assignment that says where the registry lives. lib/log.sh writes
# `readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"`; this reads
# the basename out of it and resolves it against the assigning file's own
# directory, so the registry's path is a fact about the tree rather than a
# literal in this driver.
readonly _LER_REGISTRY_ASSIGN_RE='_LOG_EVENTS_FILE=.*/([A-Za-z0-9_.-]+)"'

# The scan program, in two phases over the same population.
#
# PHASE=def prints one record per function definition: whether it FORWARDS
# its first positional into a `_log_*` body slot, the file, and the name.
# PHASE=emit prints one record per literal event id, and a trailing count
# of the call sites READ (direct and through a wrapper), which is what the
# blind-detector checks below read.
#
# A FILE-SCOPE constant and not a heredoc inside the function, the shape
# drivers/spec_repo_root.sh already uses for _SPEC_REPO_ROOT_AWK: the
# reader is one program either way, and a function carrying it is one
# function over the implementation-standard length.
#
# Written for POSIX awk: the ci image carries busybox awk, mawk and gawk,
# and the issueref lint is the standing reminder that a program here runs
# under more than one of them.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _LER_AWK='
# ── The reader ──────────────────────────────────────────────────────────────
#
# TOKENS, not a regex over the raw line. The first spelling matched
# `_log_<level> <service> <body>` and a wrapper name followed by a word
# anywhere in the text, and split what it found on whitespace. Four shapes
# broke that, two in each direction, and all four are pinned as cases:
#
#   - a body wrapped onto a continuation line was never seen, because the
#     backslash was read as the body and the real id had no call in front
#     of it. bash reads backslash-newline as nothing, so the lines are
#     FOLDED here before anything looks at them.
#   - a body an operator terminates -- `_log_err conf id; true` -- was
#     DISCARDED, because `id;` is not id-shaped. An argument ends where
#     the shell says it does.
#   - a call spelled out in a TRAILING comment was reported. Only a whole
#     line comment was skipped, and this driver is in the population it
#     scans.
#   - a wrapper name inside a STRING -- help text naming `_die` -- was
#     read as a call, and the next word reported as an event id.
#
# The last two are the direction that matters most: a finding that is not
# a defect is what gets a gate muted. Narrowing the pattern a fourth time
# is the move base#1090 refused; what the shapes have in common is that
# they are facts about SHELL WORDS, so the reader is a word splitter.
#
# It is a small one, and deliberately: enough of the grammar to say where
# a word starts and ends, which quotes make one word out of several, and
# where a command position is. It does not expand anything, and a
# substitution inside double quotes stays part of its word -- which is
# what makes a non-literal body fall out on its own rather than by a rule.
#
# Written for POSIX awk: the ci image carries busybox awk, mawk and gawk,
# and the issueref lint is the standing reminder that a program here runs
# under more than one of them. The whole program is ONE shell
# single-quoted string, so no apostrophe appears anywhere in it, comments
# included -- the single quote character is built with sprintf where the
# tokeniser needs it.
function _unquote(t,   q, a, z) {
  if (length(t) < 2) return t
  q = sprintf("%c", 39)
  a = substr(t, 1, 1); z = substr(t, length(t), 1)
  if ((a == "\"" && z == "\"") || (a == q && z == q))
    return substr(t, 2, length(t) - 2)
  return t
}
function _is_id(t) { return (t ~ /^[A-Za-z][A-Za-z0-9_]*$/) }
# Does <text>, the whole of a one-line function definition, hand its own
# first positional to a _log_* body slot? Either directly ("${1}") or
# through a name the same definition assigns "${1}" to, which is how
# test.sh spells it (`local _ev="${1}"; ... _log_err ci "${_ev}"`).
function _forwards(text,   seg, p, tok, alias) {
  if (!match(text, /_log_(debug|info|warn|err|fatal)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+/))
    return 0
  seg = substr(text, RSTART, RLENGTH)
  split(seg, p, /[[:space:]]+/)
  tok = _unquote(p[3])
  if (tok == "${1}" || tok == "$1") return 1
  if (match(tok, /^[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/)) {
    alias = tok
    gsub(/[$={}]/, "", alias)
    if (text ~ ("(^|[^A-Za-z0-9_])" alias "=\"?[$][{]?1[}]?\"?")) return 1
  }
  return 0
}
# _tokenize(<folded line>, kind[], text[]) -> count
#   Split one logical line into shell-ish tokens. kind[i] is "W" for a
#   word and "O" for an operator; text[i] is the word with one level of
#   quoting removed, so a quoted run is ONE word and a name inside a
#   message is part of that word rather than a command.
#
#   A bare `#` at a word boundary ends the line, which is what the shell
#   does and what makes a trailing comment inert here.
function _tokenize(line, kind, text,   n, i, c, cur, has, j, L, sq) {
  n = 0; cur = ""; has = 0; L = length(line); i = 1; sq = sprintf("%c", 39)
  while (i <= L) {
    c = substr(line, i, 1)
    if (c == " " || c == "\t") {
      if (has) { n++; kind[n] = "W"; text[n] = cur; cur = ""; has = 0 }
      i++
      continue
    }
    if (c == "#" && !has) break
    if (c == sq) {
      j = index(substr(line, i + 1), sq)
      if (j == 0) { cur = cur substr(line, i + 1); has = 1; break }
      cur = cur substr(line, i + 1, j - 1); has = 1; i = i + j + 1
      continue
    }
    if (c == "\"") {
      i++
      while (i <= L) {
        c = substr(line, i, 1)
        if (c == "\\" && i < L) { cur = cur substr(line, i + 1, 1); i += 2; continue }
        if (c == "\"") { i++; break }
        cur = cur c; i++
      }
      has = 1
      continue
    }
    if (c == "\\" && i < L) { cur = cur substr(line, i + 1, 1); has = 1; i += 2; continue }
    if (index(";&|()<>", c) > 0) {
      if (has) { n++; kind[n] = "W"; text[n] = cur; cur = ""; has = 0 }
      n++; kind[n] = "O"
      if (substr(line, i + 1, 1) == c) { text[n] = c c; i += 2 } else { text[n] = c; i++ }
      continue
    }
    cur = cur c; has = 1; i++
  }
  if (has) { n++; kind[n] = "W"; text[n] = cur }
  return n
}
# Is token i where a COMMAND name can stand? Start of the line, after an
# operator, or after one of the keywords that open one. Without this a
# wrapper name used as an ARGUMENT -- `grep _die file` -- would have the
# word after it reported as an event id.
function _cmd_pos(kind, text, i) {
  if (i == 1) return 1
  if (kind[i - 1] == "O") return 1
  return (text[i - 1] ~ /^(then|do|else|elif|\{|!|time|exec|eval)$/)
}
# One folded line: count the emit sites it holds and print the literal
# ids among them. <ln> is the FIRST physical line of the fold, which is
# the line a reader of the report opens.
function _scan(line, ln,   n, i, K, T) {
  n = _tokenize(line, K, T)
  for (i = 1; i <= n; i++) {
    if (K[i] != "W") continue
    if (T[i] ~ /^_log_(debug|info|warn|err|fatal)$/) {
      if (i + 2 <= n && K[i + 1] == "W" && K[i + 2] == "W") {
        direct++
        if (_is_id(T[i + 2])) printf "ID\t%s\t%s\t%d\n", T[i + 2], FILENAME, ln
      }
      continue
    }
    if (!(T[i] in fwd)) continue
    if ((FILENAME "|" T[i]) in shadow) continue
    if (!_cmd_pos(K, T, i)) continue
    if (i + 1 <= n && K[i + 1] == "W") {
      wrapped++
      if (_is_id(T[i + 1])) printf "ID\t%s\t%s\t%d\n", T[i + 1], FILENAME, ln
    }
  }
}
# Worth tokenising? Tokenising is per character, and all but a few
# thousand of the tree lines can hold no call at all. The names are the
# derived wrapper set, so this filter widens with it rather than being a
# second place a name is written down.
function _candidate(line) {
  if (line ~ /_log_(debug|info|warn|err|fatal)/) return 1
  return (fwdre != "" && line ~ fwdre)
}
BEGIN {
  n = split(FWDS, a, "\n")
  for (i = 1; i <= n; i++) if (a[i] != "") {
    fwd[a[i]] = 1
    fwdre = (fwdre == "" ? a[i] : fwdre "|" a[i])
  }
  if (fwdre != "") fwdre = "(^|[^A-Za-z0-9_])(" fwdre ")([^A-Za-z0-9_]|$)"
  n = split(SHADOWS, b, "\n")
  for (i = 1; i <= n; i++) if (b[i] != "") shadow[b[i]] = 1
}
PHASE == "def" {
  if ($0 !~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/) next
  match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)
  nm = substr($0, RSTART, RLENGTH)
  sub(/[[:space:]]*\(\)$/, "", nm)
  printf "%s\t%s\t%s\n", (_forwards($0) ? "FWD" : "PLAIN"), FILENAME, nm
  next
}
PHASE == "emit" {
  if (FNR == 1) { buf = ""; startln = 0 }
  if (buf == "") startln = FNR
  if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1) " "; next }
  line = buf $0
  buf = ""
  if (_candidate(line)) _scan(line, startln)
  next
}
END {
  if (PHASE == "emit") {
    if (buf != "" && _candidate(buf)) _scan(buf, startln)
    printf "SEEN\t%d\t%d\n", direct + 0, wrapped + 0
  }
}
'

# The scanned files, filled by _ler_collect and read by its caller.
# Meaningless before it has run. A GLOBAL rather than stdout for the
# reason drivers/spec_repo_root.sh states at length: a _die inside a
# process substitution refuses a subshell nobody is listening to.
_LER_FILES=()

# _ler_collect
#   Fill _LER_FILES with every *.sh under the shipped roots, sorted.
#   find's status is CAPTURED (the walk writes to a temp file rather than
#   into a pipeline, whose status would belong to `sort`), because a walk
#   that died half way through would otherwise hand the lint a short list
#   and read as "there is less to check". A root that does not exist is
#   skipped rather than fatal; the empty-population check is what refuses
#   a tree where none of them does.
_ler_collect() {
  _LER_FILES=()
  local -a _dirs=()
  local _root
  for _root in "${_LER_ROOTS[@]}"; do
    if [[ -d "${REPO_ROOT}/${_root}" ]]; then
      _dirs+=("${REPO_ROOT}/${_root}")
    fi
  done
  # Spelled as an `if` and not `[[ ... ]] && return 0`, here and below: a
  # false `[[ ]]` is the compound's status, and under the errexit the lint
  # phase runs its drivers with, a trailing `&&` that did not fire is a
  # function returning 1 -- which this caller reads as a FAILED WALK.
  if [[ "${#_dirs[@]}" -eq 0 ]]; then
    return 0
  fi

  local _tmp _st=0
  _tmp="$(mktemp)" || return 1
  find "${_dirs[@]}" -name '*.sh' -type f -print0 > "${_tmp}" || _st=$?
  if [[ "${_st}" -ne 0 ]]; then
    rm -f "${_tmp}"
    return "${_st}"
  fi

  local _file
  while IFS= read -r -d '' _file; do
    _LER_FILES+=("${_file}")
  done < <(sort -z < "${_tmp}")
  rm -f "${_tmp}"
}

# _ler_registry_path <outvar>
#   Resolve the registry file from the population: a scanned file that
#   assigns `_LOG_EVENTS_FILE=<dir>/<name>` names a registry at <name>
#   next to itself. Each distinct resolution THAT EXISTS goes into
#   <outvar>, so the caller can refuse zero and refuse two.
#
#   EXISTENCE IS PART OF THE RULE, not a convenience. The naive rule --
#   every file carrying the assignment names the registry -- resolved to
#   two files the first time it ran, because THIS DRIVER spells
#   `_LOG_EVENTS_FILE=` in the pattern it matches with and is itself in
#   the population. Narrowing the pattern until it stopped seeing itself
#   is the move base#1090 refused twice before changing the rule instead:
#   a registry is a file that is there, so a resolution pointing at
#   nothing is not a candidate. Self-exclusion by name would have been the
#   roster this driver exists to avoid.
_ler_registry_path() {
  local -n _lerrp_out="${1}"
  _lerrp_out=()
  local _file _line _dir _cand
  for _file in "${_LER_FILES[@]}"; do
    while IFS= read -r _line; do
      [[ "${_line}" =~ ${_LER_REGISTRY_ASSIGN_RE} ]] || continue
      _dir="$(dirname -- "${_file}")"
      _cand="${_dir}/${BASH_REMATCH[1]}"
      if [[ -f "${_cand}" ]]; then
        _lerrp_out+=("${_cand}")
      fi
    done < <(grep -h '_LOG_EVENTS_FILE=' "${_file}" 2>/dev/null || true)
  done
  if [[ "${#_lerrp_out[@]}" -gt 1 ]]; then
    mapfile -t _lerrp_out < <(printf '%s\n' "${_lerrp_out[@]}" | sort -u)
  fi
}

_run_log_event_registry() {
  echo "--- Running log event registry lint ---"

  local _find_st=0
  _ler_collect || _find_st=$?
  if [[ "${_find_st}" -ne 0 ]]; then
    _die ci_log_event_registry \
      "the walk for *.sh under ${REPO_ROOT} failed (exit ${_find_st}) -- a scan that could not finish is not a scan that found nothing."
    return 1
  fi
  if [[ "${#_LER_FILES[@]}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "no *.sh under ${_LER_ROOTS[*]} in ${REPO_ROOT} -- a scan with no population is not a pass. This lint derives its population from the tree; an empty one means the shipped scripts moved, not that they emit nothing."
    return 1
  fi

  local -a _registries=()
  _ler_registry_path _registries
  if [[ "${#_registries[@]}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "no file among the ${#_LER_FILES[@]} scanned assigns _LOG_EVENTS_FILE to a path that exists -- the registry's location is read from the tree rather than written down here, so without that assignment there is nothing to compare the emitted ids against and every id would pass."
    return 1
  fi
  if [[ "${#_registries[@]}" -gt 1 ]]; then
    _die ci_log_event_registry \
      "${#_registries[@]} different registry files are implied by _LOG_EVENTS_FILE assignments (${_registries[*]}) -- this lint compares against ONE registry, and picking either would make the other's ids look unregistered."
    return 1
  fi
  local _registry="${_registries[0]}"

  # The allowed set, read the way _log_is_registered reads it: a whole
  # non-comment, non-blank line. Kept as an ASSOCIATIVE ARRAY and not
  # re-grepped per emit site -- the membership test runs once per call
  # site, and `printf '%s\n' "${_registered[@]}" | grep -Fxq` is the
  # early-closing-reader shape this repo has a lint for. That spelling
  # was written here first and the lint caught it: `-q` exits on the
  # match, printf takes SIGPIPE, pipefail promotes the 141 over grep's
  # 0, and a SUCCESSFUL lookup reads as "not registered". Host-direct,
  # with no pipefail, it reported a clean tree; inside the lint phase
  # the same scan reported 29 registered ids as findings.
  # No -f guard: the resolution above only yields a file that exists, so
  # one here would be a branch nothing can take.
  local -a _registered=()
  mapfile -t _registered < <(
    grep -vE '^[[:space:]]*(#|$)' "${_registry}" 2>/dev/null | sort -u
  )
  if [[ "${#_registered[@]}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "the registry ${_registry#"${REPO_ROOT}"/} carries no event id -- an empty registry makes every emitted id unregistered at runtime, so reading it as the allowed set would be reading nothing."
    return 1
  fi
  local -A _registered_set=()
  local _rid
  for _rid in "${_registered[@]}"; do
    _registered_set["${_rid}"]=1
  done

  # Pass one: which function names forward their first positional into a
  # _log_* body slot, and which files define one of those names WITHOUT
  # forwarding (so their own call sites of it mean something else).
  local _defs
  _defs="$(awk -v PHASE=def -v FWDS= -v SHADOWS= "${_LER_AWK}" \
             "${_LER_FILES[@]}")"

  local _fwds _shadows
  _fwds="$(printf '%s\n' "${_defs}" | awk -F'\t' '$1=="FWD"{print $3}' | sort -u)"
  _shadows="$(printf '%s\n' "${_defs}" \
    | awk -F'\t' -v W="${_fwds}" '
        BEGIN { n = split(W, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
        $1 == "PLAIN" && ($3 in w) { print $2 "|" $3 }
      ' | sort -u)"

  # Pass two: the emitted ids, with the call-site counts that say whether
  # the detector read anything at all.
  local _emit
  _emit="$(awk -v PHASE=emit -v FWDS="${_fwds}" -v SHADOWS="${_shadows}" \
             "${_LER_AWK}" "${_LER_FILES[@]}")"

  local _seen_line _direct=0 _wrapped=0
  _seen_line="$(printf '%s\n' "${_emit}" | awk -F'\t' '$1=="SEEN"{print $2" "$3}')"
  read -r _direct _wrapped <<<"${_seen_line:-0 0}"
  if [[ "${_direct:-0}" -eq 0 ]]; then
    _die ci_log_event_registry \
      "no '_log_<level> <service> <body>' call site in any of the ${#_LER_FILES[@]} scanned file(s) -- the detector read nothing, so every id would be registered vacuously. The scan, not the tree, is what to look at: a renamed helper or a changed argument order blinds it exactly this way."
    return 1
  fi

  # The wrapper half, checked AFTER the direct count and not before it: a
  # forwarding definition spells a _log_* call on its own line, so a tree
  # with a wrapper always has at least one direct site and this refusal
  # placed first would make the blind-detector one above unreachable.
  if [[ -z "${_fwds}" ]]; then
    _die ci_log_event_registry \
      "no function in the ${#_LER_FILES[@]} scanned file(s) forwards its first argument into a _log_* body slot -- that shape (script/test/test.sh's _die) is how the lint drivers name their events, and two of base#1220's four unregistered ids were emitted through it. With none found, this lint silently shrinks to the direct call sites."
    return 1
  fi

  local -a _rows=()
  local _kind _id _loc _lineno _ids_total=0
  while IFS=$'\t' read -r _kind _id _loc _lineno; do
    [[ "${_kind}" == "ID" && -n "${_id}" ]] || continue
    _ids_total=$(( _ids_total + 1 ))
    if [[ -z "${_registered_set[${_id}]:-}" ]]; then
      _rows+=("${_loc#"${REPO_ROOT}"/}:${_lineno}: ${_id}")
    fi
  done < <(printf '%s\n' "${_emit}")

  if [[ "${#_rows[@]}" -gt 0 ]]; then
    printf '%s\n' "${_rows[@]}" | sort -u
    local _distinct
    _distinct="$(printf '%s\n' "${_rows[@]}" | awk '{print $NF}' | sort -u \
                 | paste -sd' ' -)"
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_log_event_registry \
      "${#_rows[@]} emit site(s) name an id the registry does not carry: ${_distinct}. lib/log.sh is STRICT -- it refuses an unregistered body and prints 'FATAL: unregistered log body' INSTEAD of the message, so each of these replaces the diagnostic a user was meant to read with the registry's own complaint, at the moment something had already gone wrong. Add the id to ${_registry#"${REPO_ROOT}"/}, under the section for the file that emits it."
    return 1
  fi

  echo "log event registry lint: clean (${_ids_total} emit site(s)," \
       "${_direct} direct + ${_wrapped} through a wrapper, across" \
       "${#_LER_FILES[@]} *.sh file(s); ${#_registered[@]} id(s) registered)"
}
