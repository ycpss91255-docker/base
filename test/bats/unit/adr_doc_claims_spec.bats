#!/usr/bin/env bats
#
# adr_doc_claims_spec.bats -- an ADR's claims about THIS repo are checked
# against this repo.
#
# An ADR is a record, and the half of it that rots is the mechanism
# description: the decision stays true while the file it names moves,
# changes trigger, or hands its work to another file. Nothing in the gate
# reads prose, so the rot is found by whoever next traces the record --
# which is the one moment the record is supposed to save them.
#
# ADR-00000027 shipped exactly that defect and it is the reason this spec
# exists. Its Context said a base tag triggers "the `release` job in
# `.github/workflows/self-test.yaml` plus `release-worker.yaml`, assembling
# the payload declared in `script/ci/release/archive.manifest`". Both halves
# were false: `release-worker.yaml` is `on: workflow_call` only, so no base
# tag reaches it (a DOWNSTREAM repo's tag calls it, through the `uses:` line
# `init.sh` writes into that repo's `main.yaml`), and the tag-triggered
# `release` job in `self-test.yaml` still assembles its archive from a
# hardcoded `cp -r` operand list -- it never reads the manifest. A reader
# tracing base's own release from the ADR landed on a manifest base does not
# use.
#
# Three rules, all DERIVED from the tree rather than restated from it, so a
# migration lifts the constraint instead of breaking the test:
#
#   R1 -- trigger. A block that makes a TRIGGER claim ("trigger", "tag
#         push") and names a workflow this repo has must not leave a
#         workflow with NO tag trigger looking tag-triggered: such a block
#         has to state the real trigger, as a code span that IS that
#         trigger (`workflow_dispatch`, `on: workflow_call`). Both the
#         accepted triggers and the tag question are derived from the
#         workflow's own `on:` block.
#   R2 -- payload. A block that names an assembler or a payload manifest
#         attributes it to every workflow the same block names, so each of
#         those workflows must actually reference it. Derived by reading
#         the workflow file.
#   R3 -- quotation. A block that claims a VERBATIM quotation must name a
#         path that exists in this repo. A verbatim claim about a file the
#         gate cannot open is unfalsifiable here, and ADR-00000027 shipped
#         one over a table with a row silently dropped.
#
# The unit is a BLOCK -- a paragraph, or one top-level `- ` bullet and its
# continuations -- because that is the span a reader takes as one claim.
# Fenced code is inert: inside a fence a workflow name is an example.
#
# Measured before it was built, which is this repo's bar for a new rule.
# Run over all of doc/adr/*.md, an R1 keyed on the word "tag" flagged
# ADR-00000027's Context (true) and ADR-00000002's (false: it names both
# worker workflows while describing the `@vX.Y.Z` ref a downstream pins,
# which is not a trigger claim at all). Keyed on the claim instead --
# "trigger" / "tag push" -- the three rules flag ADR-00000027's two
# defective blocks and NOTHING else across every record. The other ADRs
# that name a workflow (00000026 build-worker.yaml, 00000017 / 00000016 /
# 00000012 self-test.yaml) make no trigger claim in the naming block; the
# four other ADRs using the word "verbatim" do not introduce a quotation
# with it, so R3 never considers them either.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  REPO=/source
  ADR_DIR="${REPO}/doc/adr"
  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# ── the checker ──────────────────────────────────────────────────────────────

# _adr_wf_tag_triggered <workflow-file> -- does a tag push reach it? Read
# off the workflow's own `on:` block (to the next column-0 key), never a
# list kept here: a workflow that gains or loses a tag trigger must move
# this answer by itself.
#
# No pipeline: the answer is captured and compared in-shell, so no exit
# status here depends on how two processes were scheduled -- the
# early-closing-reader class this repo has already had to fix once.
_adr_wf_tag_triggered() {
  local _on
  _on="$(awk '/^on:/ { o = 1; next } /^[^[:space:]#]/ { o = 0 } o' "${1}")"
  [[ "${_on}" == *"tags:"* ]]
}

# _adr_wf_statable_triggers <workflow-file> -- the trigger names a block may
# state ABOUT this workflow to satisfy R1, one per line, read off the same
# `on:` block as above rather than from a list kept here.
#
# `push` is deliberately not among them, and it is the only exclusion. A tag
# push IS a push, so "push" said about a workflow whose `on: push:` carries
# no `tags:` filter leaves the reader exactly where R1 found them -- it does
# not distinguish the tag case from the branch case. Every other event name
# (`workflow_call`, `workflow_dispatch`, `schedule`, `issues`, ...) settles
# the question by being said.
#
# Only keys at the indentation of the FIRST key inside the block are events.
# That first key is necessarily a top-level one, and anchoring to it is what
# keeps a FILTER from being read as an event: `tags:` and `branches:` sit
# under `push:`, and admitting `tags` here would let the word "tag" -- the
# very word R1 is triggered by -- excuse every block it is about.
#
# The inline forms (`on: [push]`, `on: push`) yield no keys and therefore no
# escape, so a block naming such a workflow is reported rather than waved
# through. This tree writes none, and failing closed is the right direction
# for a reader that meets one.
_adr_wf_statable_triggers() {
  awk '
    /^on:/ { o = 1; next }
    /^[^[:space:]#]/ { o = 0 }
    o && $0 ~ /^[[:space:]]+[a-z_]+:/ {
      match($0, /^[[:space:]]+/)
      ind = RLENGTH
      k = $0
      sub(/^[[:space:]]+/, "", k)
      sub(/:.*$/, "", k)
      if (first == 0) { first = ind }
      if (ind == first && k != "push") { print k }
    }
  ' "${1}" | LC_ALL=C sort -u
}

# _adr_stated_triggers <block-text> -- the trigger names the block STATES,
# one per line: every code span in it, reduced to the bare event name it
# would be if the span were a trigger statement, and to something else if
# it is not.
#
# A span that merely CONTAINS an event name states nothing. Event names are
# ordinary words and this tree names its scripts after what they do, so a
# substring reading opens the hatch on `script/ci/schedule.sh` (`schedule`)
# and on `gh issues list` (`issues`) -- and the block around either can be
# saying the opposite of the truth about the workflow it names. Excluding
# `.yaml` spans catches one shape of that and leaves the rest.
#
# What a trigger statement looks like in this tree is the whole span: both
# shipped forms are `on: <event>` or the bare `<event>`, so the span is
# reduced (drop a leading `on:`, drop a trailing `:`) and matched WHOLE by
# the caller. Anything with other words in it -- a path, a command, a
# sentence fragment -- reduces to itself and matches no event.
_adr_stated_triggers() {
  local _span _norm
  while read -r _span; do
    [[ -n "${_span}" ]] || continue
    _norm="${_span//\`/}"
    _norm="${_norm#on:}"
    _norm="${_norm%:}"
    # `read` has already stripped the outer whitespace; this is the space
    # the `on:` prefix leaves behind.
    _norm="${_norm#"${_norm%%[![:space:]]*}"}"
    _norm="${_norm%"${_norm##*[![:space:]]}"}"
    printf '%s\n' "${_norm}"
  done <<< "$(grep -oE '`[^`]+`' <<< "${1}" || true)"
}

# _adr_claims_block <file> <line-no> <repo> <text> -- apply R1/R2/R3 to one
# block. Prints one line per violation; returns non-zero if any.
_adr_claims_block() {
  local _file="${1}" _lineno="${2}" _repo="${3}" _text="${4}"
  local _v=0 _wf _tok _name _hit
  local -a _named=()

  # Which workflows the block names AND this repo actually has. A name this
  # repo does not carry (`main.yaml`, generated downstream;
  # `base-version-monitor.yaml`, generated by init.sh; `compose.yaml`) is
  # not a claim about a workflow file and is skipped rather than guessed at.
  _hit="$(grep -oE '[A-Za-z0-9_.-]+\.yaml' <<< "${_text}" || true)"
  while read -r _name; do
    [[ -n "${_name}" ]] || continue
    [[ -f "${_repo}/.github/workflows/${_name}" ]] || continue
    case " ${_named[*]-} " in
      *" ${_name} "*) continue ;;
    esac
    _named+=("${_name}")
  done <<< "${_hit}"

  # R1 -- trigger. Only blocks that make a TRIGGER claim are considered.
  # "tag" alone is far too wide: ADR-00000002 names both worker workflows
  # while describing the `@vX.Y.Z` refs a downstream pins them at, which
  # says nothing about what starts them, and the word "tag" is all over
  # that paragraph. Requiring the claim itself ("trigger", "tag push")
  # takes that block -- the one measured false positive -- back out while
  # still catching the shipped defect, whose sentence is "what the tag then
  # *triggers*".
  #
  # The escape hatch is STATING THE REAL TRIGGER, and the trigger is read
  # off the workflow (`_adr_wf_statable_triggers`) rather than being the
  # literal `workflow_call` this rule was born with. `workflow_call` was
  # simply the only non-tag trigger any ADR block named at the time, and the
  # first block to describe a `workflow_dispatch`-only workflow got reported
  # for saying something true -- by a message demanding a trigger that
  # workflow does not have. A rule that cannot be satisfied by telling the
  # truth teaches people to reword around it. What "stating" means is
  # narrowed just below, because a hatch opened by any prose word is a
  # hatch a workflow's own subject holds open.
  if grep -qiE 'trigger|tag push|push.*tags' <<< "${_text}"; then
    local _real _t _stated _spans
    # The hatch is opened by STATING the trigger, and an event name is an
    # ordinary English word -- `issues`, `schedule`, `push`. Matched against
    # the block's whole prose, a workflow's own SUBJECT excuses a false
    # claim about it: "which is how this repo labels issues" would wave
    # through a tag claim over `triage-label.yaml`, whose only statable
    # trigger is `issues`. So the name must appear AS CODE, which is how
    # both shipped forms are written (`on: workflow_call`,
    # `workflow_dispatch`) and how R3 below already reads a claim's
    # subject.
    #
    # And the span must BE the trigger, not contain it -- see
    # _adr_stated_triggers. A span naming a file
    # (`.github/workflows/schedule.yaml`) or a script (`script/ci/schedule.sh`)
    # or a command (`gh issues list`) says what the block is about, not what
    # starts it, and admitting any of them reopens the same hole one layer
    # down.
    _spans="$(_adr_stated_triggers "${_text}")"
    for _wf in ${_named[*]-}; do
      _adr_wf_tag_triggered "${_repo}/.github/workflows/${_wf}" && continue
      _real="$(_adr_wf_statable_triggers "${_repo}/.github/workflows/${_wf}")"
      _stated=0
      while read -r _t; do
        [[ -n "${_t}" ]] || continue
        grep -qxF -- "${_t}" <<< "${_spans}" && _stated=1
      done <<< "${_real}"
      [[ "${_stated}" -eq 1 ]] && continue
      # The message names the trigger the block SHOULD have stated, so the
      # reader is told what to write rather than only that they are wrong.
      # An `on:` this reader could not decompose says so instead of naming
      # an empty list.
      local _want="none this reader could name from its on: block"
      [[ -n "${_real}" ]] && _want="$(printf '%s' "${_real}" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
      printf '%s:%d: names %s in a tag claim, but %s has no tag trigger and the block does not state its real trigger (%s)\n' \
        "${_file}" "${_lineno}" "${_wf}" "${_wf}" "${_want}"
      _v=$(( _v + 1 ))
    done
  fi

  # R2 -- payload. Naming an assembler or a manifest beside a workflow
  # attributes one to the other; the workflow has to reference it.
  #
  # The workflow side is matched against its CODE, not its prose. A comment
  # saying a workflow does NOT use the manifest contains the manifest path,
  # and a plain grep reads that as the reference it is denying -- which is
  # exactly how self-test.yaml's "do not re-add one" note made this rule
  # certify the claim it exists to refuse. Stripping from an unquoted `#`
  # can also cut a `#` inside a quoted value; that direction is safe,
  # because it can only make the rule fire when it should not, never stay
  # silent when it should speak.
  for _tok in script/ci/release-archive.sh script/ci/release/archive.manifest; do
    grep -qF "${_tok}" <<< "${_text}" || continue
    for _wf in ${_named[*]-}; do
      sed 's/#.*//' "${_repo}/.github/workflows/${_wf}" \
        | grep -qF "${_tok}" && continue
      printf '%s:%d: attributes %s to %s, which does not reference it\n' \
        "${_file}" "${_lineno}" "${_tok}" "${_wf}"
      _v=$(( _v + 1 ))
    done
  done

  # R3 -- quotation. "verbatim" plus a block that INTRODUCES the quotation
  # (it ends on a colon) is a completeness claim; it has to be about a file
  # this gate can open.
  if grep -q 'verbatim' <<< "${_text}" && [[ "${_text}" == *: ]]; then
    local _found=0 _p
    _hit="$(grep -oE '`[^`]+`' <<< "${_text}" || true)"
    while read -r _p; do
      _p="${_p//\`/}"
      [[ -n "${_p}" ]] || continue
      [[ -e "${_repo}/${_p}" ]] && _found=1
    done <<< "${_hit}"
    if [[ "${_found}" -eq 0 ]]; then
      printf '%s:%d: claims a verbatim quotation of something outside this repo -- no gate can check it, so do not claim it\n' \
        "${_file}" "${_lineno}"
      _v=$(( _v + 1 ))
    fi
  fi

  [[ "${_v}" -eq 0 ]]
}

# _adr_claims <adr-file> [repo-root] -- split the ADR into blocks and check
# each. Prints every violation; returns non-zero if any.
_adr_claims() {
  local _file="${1}" _repo="${2:-${REPO}}"
  local -a _lines=() _block=()
  local _i _line _trim _in_fence=0 _start=0 _v=0 _boundary

  mapfile -t _lines < "${_file}"

  for (( _i = 0; _i <= ${#_lines[@]}; _i++ )); do
    _boundary=0
    if [[ "${_i}" -ge "${#_lines[@]}" ]]; then
      _boundary=1
    else
      _line="${_lines[_i]}"
      _trim="${_line#"${_line%%[![:space:]]*}"}"
      if [[ "${_trim}" == '```'* || "${_trim}" == '~~~'* ]]; then
        _in_fence=$(( 1 - _in_fence ))
        _boundary=1
      elif [[ "${_in_fence}" -eq 1 ]]; then
        # Fenced content: inert, and it cannot join the block around it.
        _boundary=1
      elif [[ -z "${_line// }" ]]; then
        _boundary=1
      elif [[ "${_line}" == '#'* ]]; then
        _boundary=1
      elif [[ "${_line}" == '- '* && "${#_block[@]}" -gt 0 ]]; then
        # A new top-level bullet ends the previous block and opens one.
        _boundary=2
      fi
    fi

    if [[ "${_boundary}" -ne 0 && "${#_block[@]}" -gt 0 ]]; then
      _adr_claims_block "${_file}" "$(( _start + 1 ))" "${_repo}" \
        "$(printf '%s\n' "${_block[@]}")" || _v=$(( _v + 1 ))
      _block=()
    fi
    [[ "${_i}" -ge "${#_lines[@]}" ]] && break
    if [[ "${_boundary}" -eq 0 || "${_boundary}" -eq 2 ]]; then
      [[ "${#_block[@]}" -eq 0 ]] && _start="${_i}"
      _block+=("${_line}")
    fi
  done

  [[ "${_v}" -eq 0 ]]
}

# _write_adr <name> <line>... -- a scratch ADR fixture.
_write_adr() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/${_name}"
  printf '%s' "${SCRATCH}/${_name}"
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "doc/adr: every record's workflow and quotation claims hold against the tree (#927)" {
  local _f _bad=0
  for _f in "${ADR_DIR}"/*.md; do
    if ! _adr_claims "${_f}" "${REPO}"; then
      _bad=$(( _bad + 1 ))
    fi
  done
  [ "${_bad}" -eq 0 ]
}

@test "doc/adr: the scan is not vacuous -- ADR-00000027 is read and holds blocks (#927)" {
  # A checker that silently reads nothing reports every tree clean. Pin
  # that the record this spec was written for is actually opened, and that
  # the block walk produces the blocks the rules are applied to.
  local _adr="${ADR_DIR}/00000027-release-cadence-and-fanout-trigger.md"
  [ -f "${_adr}" ]
  run grep -c 'self-test.yaml' "${_adr}"
  assert_success
  # The Context describes base's own release path, so the tag-triggered
  # workflow is named there.
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The facts the ADR's Context rests on
# ════════════════════════════════════════════════════════════════════

@test "release-worker.yaml is workflow_call-only, so no base tag reaches it (#927)" {
  local _wf="${REPO}/.github/workflows/release-worker.yaml"
  run grep -qE '^[[:space:]]+workflow_call:' "${_wf}"
  assert_success
  run _adr_wf_tag_triggered "${_wf}"
  assert_failure
}

@test "self-test.yaml IS tag-triggered, so it is what a base tag runs (#927)" {
  run _adr_wf_tag_triggered "${REPO}/.github/workflows/self-test.yaml"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# R1 -- trigger
# ════════════════════════════════════════════════════════════════════

@test "R1: FAILS a tag claim that names a workflow with no tag trigger (#927)" {
  # ADR-00000027's shipped Context, verbatim in shape: one paragraph, both
  # workflows, one tag claim covering them.
  local _adr
  _adr="$(_write_adr defect.md \
    '## Context' \
    '' \
    'What the tag then triggers is in this repo -- the `release` job in' \
    '`.github/workflows/self-test.yaml` plus `release-worker.yaml`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'release-worker.yaml'
  assert_output --partial 'no tag trigger'
}

@test "R1: PASSES the same claim once the block states the real trigger (#927)" {
  local _adr
  _adr="$(_write_adr fixed.md \
    '## Context' \
    '' \
    '- `.github/workflows/release-worker.yaml` is `on: workflow_call` only,' \
    '  so no base tag reaches it; a downstream repo'"'"'s tag calls it.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

# why: R1's escape hatch was the literal `workflow_call`, which was the only
# non-tag trigger any ADR block named when the rule was written. The first
# block to name a `workflow_dispatch`-only workflow therefore stated its real
# trigger, correctly, and was reported anyway -- with a message demanding a
# trigger that workflow does not have. A rule that cannot be satisfied by
# telling the truth teaches people to reword around it.
@test "R1: PASSES a trigger claim that states a real trigger other than workflow_call (#726)" {
  local _adr
  _adr="$(_write_adr dispatch.md \
    '## Context' \
    '' \
    '- `.github/workflows/coverage-local.yaml` is `workflow_dispatch` only,' \
    '  so no push and no tag triggers it -- someone asks for the run.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

# why: the third way widening the hatch can go wrong, and the one that
# empties the rule quietly. An event name is an ordinary English word --
# `issues`, `schedule`, `push` -- so a substring reading lets a workflow's
# own SUBJECT excuse a false claim about it: the sentence "which is how
# this repo labels issues" states nothing about a trigger, and would have
# waved through a tag claim over `triage-label.yaml`, whose only statable
# trigger happens to be `issues`. A trigger has to be STATED AS ONE, which
# in this repo's prose means naming it as code.
@test "R1: a workflow's own subject word does not state its trigger (#726)" {
  local _adr
  _adr="$(_write_adr subject_word.md \
    '## Context' \
    '' \
    'A tag push triggers `.github/workflows/triage-label.yaml`, which is' \
    'how this repo labels issues.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'triage-label.yaml'
  assert_output --partial 'no tag trigger'
  # And the message still names what the block should have said, so the
  # remedy is the same one sentence away.
  assert_output --partial 'issues'
}

# why: the other side of that tightening: the hatch has to stay openable,
# and the way an ADR in this tree states a trigger is in a code span --
# both shipped forms (`on: workflow_call`, `workflow_dispatch`) are
# written that way, and R3's quotation rule already reads the same spans.
@test "R1: a trigger stated inside a code span opens the hatch (#726)" {
  local _adr
  _adr="$(_write_adr subject_word_fixed.md \
    '## Context' \
    '' \
    'A tag push does not reach `.github/workflows/triage-label.yaml`,' \
    'which runs `on: issues` when one is opened.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

# why: the same hole one layer down, and the reason a code span alone is
# not the rule. A FILE NAME is written as code too, so a workflow whose
# name contains its own event -- `schedule.yaml` on `on: schedule` -- would
# state its trigger merely by being named. Built here rather than found in
# the tree, because the tree happens to carry no such workflow and the rule
# must hold for the one somebody adds.
@test "R1: a code span naming a file does not state a trigger (#726)" {
  mkdir -p "${SCRATCH}/.github/workflows"
  printf '%s\n' 'on:' '  schedule:' '    - cron: "0 0 * * *"' \
    > "${SCRATCH}/.github/workflows/schedule.yaml"
  local _adr
  _adr="$(_write_adr filename_span.md \
    '## Context' \
    '' \
    'A tag push triggers `.github/workflows/schedule.yaml`.')"
  run _adr_claims "${_adr}" "${SCRATCH}"
  assert_failure
  assert_output --partial 'schedule.yaml'
  assert_output --partial 'no tag trigger'
}

# why: dropping `.yaml` spans covered the case above and left the property
# the case NAMES uncovered -- a span naming a file is only one of the spans
# that say nothing about a trigger. Any code span whose text merely
# CONTAINS an event name opened the hatch, and a repo's scripts are named
# after what they do: `script/ci/schedule.sh` beside a workflow whose
# statable trigger is `schedule` waved a false tag claim about it straight
# through, with no `.yaml` anywhere for the exclusion to catch.
@test "R1: a code span naming a script does not state a trigger (#726)" {
  local _adr
  _adr="$(_write_adr script_span.md \
    '## Context' \
    '' \
    'A tag push triggers `.github/workflows/ghcr-cleanup.yaml`, which runs' \
    'the retention pass in `script/ci/schedule.sh`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'ghcr-cleanup.yaml'
  assert_output --partial 'no tag trigger'
}

# why: the same hole with a command rather than a path, which is the form
# an ADR reaches for most often. `gh issues list` is a code span that
# states nothing about what starts anything, and it contains the only
# statable trigger `triage-label.yaml` has -- so it excused a tag claim
# about that workflow exactly as the block's own subject word would have,
# which is the failure the case above this one was written to close.
@test "R1: a code span quoting a command does not state a trigger (#726)" {
  local _adr
  _adr="$(_write_adr command_span.md \
    '## Context' \
    '' \
    'A tag push triggers `.github/workflows/triage-label.yaml`; see' \
    '`gh issues list` for what it labels.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'triage-label.yaml'
  assert_output --partial 'no tag trigger'
}

# why: the other half of that change, and the reason it does not weaken the
# rule: naming the workflow in a trigger claim and saying nothing about what
# actually starts it is still the ADR-00000027 defect, whichever trigger the
# workflow has.
@test "R1: still FAILS a trigger claim that names the same workflow and states nothing (#726)" {
  local _adr
  _adr="$(_write_adr dispatch_silent.md \
    '## Context' \
    '' \
    'What the tag then triggers includes' \
    '`.github/workflows/coverage-local.yaml`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'coverage-local.yaml'
  assert_output --partial 'workflow_dispatch'
}

# why: reading the escape hatch off the workflow instead of off a literal
# creates one new way to be wrong -- reading a FILTER as an event. `tags:`
# and `branches:` are keys inside the `on:` block too, and admitting `tags`
# would let the word "tag", the very word R1 is triggered by, excuse every
# block R1 exists to read. Pinned on the real self-test.yaml, whose `on:`
# has both a nested `tags:` and a nested `branches:`.
@test "R1: a workflow's statable triggers are its events, never its filters (#726)" {
  run _adr_wf_statable_triggers "${REPO}/.github/workflows/self-test.yaml"
  assert_success
  assert_output 'pull_request
workflow_dispatch'
}

# why: the unfixed half of that same reading. Anchoring the EVENTS on the
# first key's indentation was done precisely so a nested key is not read as
# a top-level event -- while the tag question beside it stayed a substring
# search over the whole `on:` block. `tags:` is not only a push filter: it
# is a legal name for a `workflow_dispatch` input, a `workflow_call` input
# or a job-level key, and any of them made the workflow read as
# tag-triggered. The two readings have to agree, or the block's structure
# means one thing to one line and another to the next.
@test "R1: a nested tags key that is not a push filter is not a tag trigger (#726)" {
  mkdir -p "${SCRATCH}/.github/workflows"
  printf '%s\n' 'name: x' 'on:' '  workflow_dispatch:' '    inputs:' \
    '      tags:' '        required: false' 'jobs:' '  a:' \
    '    runs-on: ubuntu-latest' \
    > "${SCRATCH}/.github/workflows/tagsinput.yaml"
  run _adr_wf_tag_triggered "${SCRATCH}/.github/workflows/tagsinput.yaml"
  assert_failure
}

# why: and what that costs R1, which is worse than a wrong answer to one
# question. A workflow that reads as tag-triggered is `continue`d past
# before the rule looks at the block at all, so a false tag claim about it
# is not merely under-checked -- it is waved through with no check. The
# report has to name the trigger the block should have stated instead.
@test "R1: FAILS a tag claim about a workflow whose only tags key is an input (#726)" {
  mkdir -p "${SCRATCH}/.github/workflows"
  printf '%s\n' 'name: x' 'on:' '  workflow_dispatch:' '    inputs:' \
    '      tags:' '        required: false' 'jobs:' '  a:' \
    '    runs-on: ubuntu-latest' \
    > "${SCRATCH}/.github/workflows/tagsinput.yaml"
  local _adr
  _adr="$(_write_adr taginput.md \
    '## Context' \
    '' \
    'A base tag push triggers `tagsinput.yaml`.')"
  run _adr_claims "${_adr}" "${SCRATCH}"
  assert_failure
  assert_output --partial 'tagsinput.yaml'
  assert_output --partial 'no tag trigger'
  assert_output --partial 'workflow_dispatch'
}

# why: the second new way to be wrong, and the reason `push` is the one
# event excluded: a tag push IS a push, so "push" said about a workflow
# whose `on: push:` carries no `tags:` filter answers nothing the rule
# asked. Such a block must still be reported -- and with nothing truthful
# left to name, the message says so rather than offering an empty list.
@test "R1: saying 'push' does not excuse a claim about a tag-less push workflow (#726)" {
  mkdir -p "${SCRATCH}/.github/workflows"
  printf '%s\n' 'on:' '  push:' '    branches: [main]' \
    > "${SCRATCH}/.github/workflows/branchy.yaml"
  local _adr
  _adr="$(_write_adr push_only.md \
    '## Context' \
    '' \
    'A tag push triggers `branchy.yaml`, which runs on every push.')"
  run _adr_claims "${_adr}" "${SCRATCH}"
  assert_failure
  assert_output --partial 'branchy.yaml'
  assert_output --partial 'no tag trigger'
  assert_output --partial 'none this reader could name from its on: block'
}

@test "R1: PASSES a tag claim about a workflow that IS tag-triggered (#927)" {
  local _adr
  _adr="$(_write_adr tagged.md \
    '## Context' \
    '' \
    'A base tag push runs the `release` job in' \
    '`.github/workflows/self-test.yaml`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

@test "R1: IGNORES a workflow named with no trigger claim in the block (#927)" {
  # The rule is about trigger claims, not about naming a file. ADR-00000026
  # names build-worker.yaml while discussing a guarded skip; that is not a
  # claim this rule may have an opinion about.
  local _adr
  _adr="$(_write_adr notrigger.md \
    '## Context' \
    '' \
    '`worker-selftest` calls `build-worker.yaml`, whose `build` job now' \
    'carries the guard.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

@test "R1: IGNORES a name this repo has no workflow for (#927)" {
  # `main.yaml` is generated into a downstream repo by init.sh; base has no
  # such workflow, so the block claims nothing about a file here -- even
  # though it IS a trigger claim and the rule therefore runs.
  local _adr
  _adr="$(_write_adr downstream.md \
    '## Context' \
    '' \
    'A downstream repo'"'"'s tag triggers it through the `uses:` line' \
    'init.sh writes into that repo'"'"'s `main.yaml`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

@test "R1: a workflow named inside a fenced example is inert (#927)" {
  local _adr
  _adr="$(_write_adr fenced.md \
    '## Context' \
    '' \
    'The trigger is spelled:' \
    '' \
    '```yaml' \
    '# release-worker.yaml, on a tag' \
    'on: { push: { tags: ["v*"] } }' \
    '```')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# R2 -- payload
# ════════════════════════════════════════════════════════════════════

@test "R2: FAILS attributing the payload manifest to a workflow that never reads it (#927)" {
  local _adr
  _adr="$(_write_adr payload.md \
    '## Context' \
    '' \
    'The `release` job in `.github/workflows/self-test.yaml` assembles the' \
    'payload declared in `script/ci/release/archive.manifest` through' \
    '`script/ci/release-archive.sh`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'script/ci/release/archive.manifest'
  assert_output --partial 'self-test.yaml'
}

@test "R2: a workflow that only MENTIONS the manifest in a comment does not count (#927)" {
  # The live shape this was found on: self-test.yaml carries a comment
  # explaining that it does NOT assemble the curated payload, and names the
  # manifest while saying so. Matching the file as prose reads that denial
  # as the reference it denies, so the rule passed the exact attribution it
  # exists to refuse.
  #
  # The fixture workflow is the SUBJECT here, so it has to sit under the
  # tree the checker scans -- but that tree does not have to be the live
  # checkout, and must not be. Written into ${REPO}/.github/workflows/ it
  # was never removed: every gate run left an untracked workflow behind, in
  # the one directory the workflow specs and the self-hosted-runner lint
  # both scan, which is how a spec makes every OTHER spec's read of that
  # tree racy. The residue was also owned by the container's root, so the
  # next reader could not see where it came from. A scratch root answers
  # the same question and owns what it writes.
  mkdir -p "${SCRATCH}/.github/workflows"
  local _wf="${SCRATCH}/.github/workflows/commented.yaml"
  cat > "${_wf}" <<'YAML'
on: push
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      # The downstream archive is a different artifact (a curated payload,
      # declared in script/ci/release/archive.manifest), not this one.
      - run: echo no payload assembly here
YAML
  local _adr
  _adr="$(_write_adr commented.md \
    '## Context' \
    '' \
    'The `release` job in `.github/workflows/commented.yaml` assembles the' \
    'payload declared in `script/ci/release/archive.manifest`.')"
  run _adr_claims "${_adr}" "${SCRATCH}"
  assert_failure
  assert_output --partial 'script/ci/release/archive.manifest'
  assert_output --partial 'commented.yaml'
}

@test "R2: PASSES the attribution against the workflow that does read it (#927)" {
  local _adr
  _adr="$(_write_adr payload_ok.md \
    '## Context' \
    '' \
    '- `.github/workflows/release-worker.yaml` (`on: workflow_call`)' \
    '  assembles the payload declared in' \
    '  `script/ci/release/archive.manifest` through' \
    '  `script/ci/release-archive.sh`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

@test "R2: a separate bullet is a separate claim (#927)" {
  # The block walk is what makes the fix expressible: one bullet per path,
  # each true of the workflow it names. Joined into one paragraph the same
  # two sentences are one claim about both workflows, and fail.
  local _adr
  _adr="$(_write_adr bullets.md \
    '## Context' \
    '' \
    '- A base tag runs the `release` job in' \
    '  `.github/workflows/self-test.yaml`, which assembles its archive' \
    '  itself.' \
    '- `.github/workflows/release-worker.yaml` is `on: workflow_call` only;' \
    '  it assembles the payload declared in' \
    '  `script/ci/release/archive.manifest`.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# R3 -- quotation
# ════════════════════════════════════════════════════════════════════

@test "R3: FAILS a verbatim claim about a file outside this repo (#927)" {
  # The shipped defect: "reads, verbatim:" over a four-row table quoted
  # with three rows, from a harness-side skill no in-repo gate can open.
  local _adr
  _adr="$(_write_adr quote.md \
    '## Context' \
    '' \
    '`semver-bump`'"'"'s bump-classification table reads, verbatim:' \
    '' \
    '| Tag shape | Bump |' \
    '|---|---|' \
    '| `vX.Y.Z` | Z |')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_failure
  assert_output --partial 'verbatim'
}

@test "R3: PASSES a verbatim claim about a file this repo carries (#927)" {
  local _adr
  _adr="$(_write_adr quote_ok.md \
    '## Context' \
    '' \
    '`script/ci/release/archive.manifest` reads, verbatim:' \
    '' \
    '```text' \
    'Dockerfile' \
    '```')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}

@test "R3: IGNORES verbatim used about behaviour rather than a quotation (#927)" {
  # ADR-00000005 says `just` forwards its arguments verbatim; nothing is
  # being quoted, and the block does not introduce a quotation.
  local _adr
  _adr="$(_write_adr behaviour.md \
    '## Context' \
    '' \
    'It forwards `just run -t headless --gpus all` verbatim -- no' \
    'rewriting, no re-quoting.')"
  run _adr_claims "${_adr}" "${REPO}"
  assert_success
}
