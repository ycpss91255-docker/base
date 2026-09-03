#!/usr/bin/env bash
#
# spec-markers.sh - the ONE reader of the `# why:` description markers that
# a bats spec file carries beside its tests.
#
# A description of a test is authored WHERE THE TEST LIVES, on the lines
# immediately above it, and doc/test/*.md is rendered from what this reader
# returns. Before that, the description lived in the catalogue and the test
# lived in the spec, a person kept the two in agreement, and a rename lost
# the prose (doc/test/unit.md documented that loss as a rule).
#
# THE GRAMMAR, in full
# --------------------
#
#   # why: an empty scan root is how this lint silently stopped covering
#   # anything -- it must fail, not pass over nothing.
#   @test "just provenance: a missing scan root fails vacuously" {
#
# A marker is a comment run immediately above the `@test`, whose first
# marker line is `# why: <prose>`; every non-empty comment line between
# that line and the `@test` is a CONTINUATION, joined with a single space.
# The contiguous comment run is the block -- no closing sigil, exactly the
# way the file-header comment blocks in this tree already work. Comment
# lines ABOVE the `# why:` line (a section divider, say) are not part of
# it.
#
# Multi-line is allowed at the source and rendered as ONE row cell: the
# specs wrap at this tree's ~76-column norm, and a one-line-only rule buys
# either terse prose or 200-column lines.
#
# A bare `#` line inside a TEST's block is a finding (see `detached`). In
# the FILE-LEVEL block it is a PARAGRAPH BREAK, and the difference is not
# an inconsistency: the rule exists because a blank comment line is how a
# description detaches from the `@test` beneath it, and a file-level block
# has no `@test` beneath it to detach from. Twenty-one of this tree's
# section blurbs are two or more paragraphs, and flattening them would
# destroy structure the generator can reproduce exactly.
#
# One grammar, two sites. A `# why:` block in the file's OPENING comment
# run -- before `bats_require_minimum_version` / `setup()` -- is the
# SECTION BLURB for that spec. A `# why:` block attached to an `@test` is
# that test's description. They are told apart by position, which is why
# the opening run must be separated from the first `@test` by a blank
# line; a run that touches the first `@test` is that test's marker and the
# ambiguity is reported rather than guessed.
#
# WHAT IS A FINDING, and why each one is not merely tolerated
# ----------------------------------------------------------
#
#   noncanonical     A `^@test` line the canonical `@test "..." {` form
#                    does not accept -- a name spanning lines, most
#                    plausibly. The per-spec count is `grep -c '^@test'`,
#                    so a line this reader skipped but the counter counted
#                    would put the heading count and the row count out of
#                    step with every gate green. The reader therefore
#                    OPENS on exactly the counter's anchor and refuses
#                    what it cannot read, instead of passing over it.
#   detached         A bare `#` line inside a block. A blank comment line
#                    is how a description silently detaches from its test,
#                    which is the failure this whole mechanism exists to
#                    remove; it is not a paragraph break.
#   nested-marker    A second `# why:` inside one block. Two markers for
#                    one test are two answers.
#   orphan           A `# why:` line attached to no `@test` and not the
#                    file blurb. This is what a rename leaves behind, and
#                    it is the check that keeps the guard non-vacuous in
#                    the other direction: without it a description that
#                    will never render reads as a described test.
#   ambiguous-blurb  The opening comment run touches the first `@test`, so
#                    the file blurb and that test's description are the
#                    same lines.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# Nothing here is `readonly`, deliberately: this file is sourced by BOTH
# the catalogue generator (sync-doc-counts.sh) and the description lint
# (drivers/catalog_description.sh), and both are loaded into the one
# process a `just test` lint phase runs in. A second source has to be a
# no-op; re-assigning a readonly would abort the run instead.

# The canonical `@test` line, and the OPENING anchor the per-spec counts
# use (`grep -cE '^@test'`). Two patterns rather than one so a line that
# opens like a test but is not readable can be reported instead of
# skipped -- see `noncanonical` above.
_SPEC_MARKER_TEST_RE='^@test[[:space:]]+"(.*)"[[:space:]]*\{[[:space:]]*$'
_SPEC_MARKER_WHY_RE='^#[[:space:]]*why:[[:space:]]*(.*)$'
_SPEC_MARKER_BLANK_COMMENT_RE='^#[[:space:]]*$'

# _spec_marker_trim_into <outvar> <string> -- <string> with leading and
# trailing whitespace removed.
_spec_marker_trim_into() {
  local -n _smt_out="$1"
  local _smt_s="$2"
  _smt_s="${_smt_s#"${_smt_s%%[![:space:]]*}"}"
  _smt_s="${_smt_s%"${_smt_s##*[![:space:]]}"}"
  _smt_out="${_smt_s}"
}

# _spec_marker_unescape_into <outvar> <raw> -- bash double-quote unescaping
# of <raw> into <outvar>: `\X` collapses to `X` for the four characters
# bash treats specially inside "...", every other backslash is literal.
# This is what bats does to the `@test "..."` name before printing it, so
# applying it here keeps a row's identity equal to the name in the TAP
# output -- a row can be pasted straight into `--filter`.
_spec_marker_unescape_into() {
  local -n _spec_marker_unescape_out="$1"
  local _raw="$2" _res='' _i _ch _next
  local _bs=$'\\'
  local _len="${#_raw}"
  for (( _i = 0; _i < _len; _i++ )); do
    _ch="${_raw:_i:1}"
    if [[ "${_ch}" == "${_bs}" && $(( _i + 1 )) -lt "${_len}" ]]; then
      _next="${_raw:_i+1:1}"
      if [[ "${_next}" == '"' || "${_next}" == "${_bs}" \
        || "${_next}" == '$' || "${_next}" == '`' ]]; then
        _res+="${_next}"
        (( _i++ ))
        continue
      fi
    fi
    _res+="${_ch}"
  done
  _spec_marker_unescape_out="${_res}"
}

# _spec_marker_join_into <desc-outvar> <lines-arrayvar> <first> <last>
# <findings-arrayvar> <mode> -- the block running from the `# why:` line
# <first> to line <last> inclusive, joined. Findings raised on the way
# through are appended to <findings-arrayvar>; the block is still joined,
# so the caller reports AND renders rather than choosing.
#
# <mode> is `attached` for a test's marker, where a bare `#` line is a
# finding and the answer is one line, or `paragraphs` for the file-level
# blurb, where a bare `#` separates paragraphs and the answer carries a
# newline between them.
#
# Line numbers are 1-based; <lines-arrayvar> is 0-based, as mapfile fills
# it.
_spec_marker_join_into() {
  local -n _smj_out="$1"
  local -n _smj_lines="$2"
  local _smj_first="$3" _smj_last="$4"
  local -n _smj_findings="$5"
  local _smj_mode="${6:-attached}"
  local _smj_res='' _smj_m _smj_part _smj_break=0
  if [[ "${_smj_lines[_smj_first-1]}" =~ ${_SPEC_MARKER_WHY_RE} ]]; then
    _smj_res="${BASH_REMATCH[1]}"
  fi
  _spec_marker_trim_into _smj_res "${_smj_res}"
  for (( _smj_m = _smj_first + 1; _smj_m <= _smj_last; _smj_m++ )); do
    _smj_part="${_smj_lines[_smj_m-1]}"
    if [[ "${_smj_part}" =~ ${_SPEC_MARKER_BLANK_COMMENT_RE} ]]; then
      if [[ "${_smj_mode}" == 'paragraphs' ]]; then
        [[ -n "${_smj_res}" ]] && _smj_break=1
        continue
      fi
      _smj_findings+=( "${_smj_m}"$'\t'detached$'\t'"a bare '#' line inside a '# why:' block -- a blank comment line detaches the description from what it describes" )
      continue
    fi
    if [[ "${_smj_part}" =~ ${_SPEC_MARKER_WHY_RE} ]]; then
      _smj_findings+=( "${_smj_m}"$'\t'nested-marker$'\t'"a second '# why:' inside one block -- two markers for one site are two answers" )
    fi
    _smj_part="${_smj_part#\#}"
    _spec_marker_trim_into _smj_part "${_smj_part}"
    [[ -n "${_smj_part}" ]] || continue
    if [[ -z "${_smj_res}" ]]; then
      _smj_res="${_smj_part}"
    elif (( _smj_break )); then
      _smj_res+=$'\n'"${_smj_part}"
      _smj_break=0
    else
      _smj_res+=" ${_smj_part}"
    fi
  done
  _smj_out="${_smj_res}"
}

# _spec_markers_scan <file> <tests-outvar> <findings-outvar> <blurb-outvar>
#
# Read <file> once and answer everything the generator and the lint need:
#
#   <tests-outvar>     one record per canonical `@test`, in file order,
#                      as `<line> TAB <marked> TAB <name> TAB <description>`.
#                      <marked> is 1 when a `# why:` block was attached and
#                      0 when there was none -- an EMPTY description with
#                      <marked>=1 is a marker that says nothing, which is a
#                      different fact from having no marker, and only the
#                      lint may collapse them.
#   <findings-outvar>  `<line> TAB <code> TAB <detail>`, in line order.
#   <blurb-outvar>     the file-level `# why:` block; paragraphs separated
#                      by a newline, empty when the file has none.
#
# A missing file yields three empty answers rather than a failure: the
# CALLER decides whether an empty scan is vacuous, because only the caller
# knows whether it asked for a tree or for one path.
_spec_markers_scan() {
  local _file="$1"
  local -n _sm_tests="$2"
  local -n _sm_findings="$3"
  local -n _sm_blurb="$4"
  _sm_tests=()
  _sm_findings=()
  _sm_blurb=''
  [[ -f "${_file}" ]] || return 0

  local -a _sm_lines=()
  mapfile -t _sm_lines < "${_file}"
  local _n="${#_sm_lines[@]}"
  local _i

  # The file's OPENING comment run: lines 1.._open_end, every one a
  # comment. The shebang is a comment line, so the run is the whole header
  # block a spec file opens with.
  local _open_end=0
  for (( _i = 1; _i <= _n; _i++ )); do
    [[ "${_sm_lines[_i-1]}" == '#'* ]] || break
    _open_end="${_i}"
  done

  # Which `# why:` lines have been claimed, so the orphan sweep below can
  # ask "claimed by nothing?" rather than re-deriving attachment.
  local -A _sm_claimed=()
  local _name _desc _marked _w _j _m _run_start
  for (( _i = 1; _i <= _n; _i++ )); do
    [[ "${_sm_lines[_i-1]}" == '@test'* ]] || continue
    if [[ ! "${_sm_lines[_i-1]}" =~ ${_SPEC_MARKER_TEST_RE} ]]; then
      _sm_findings+=( "${_i}"$'\t'noncanonical$'\t'"a '@test' line the canonical '@test \"...\" {' form does not accept -- the per-spec count matches it, so a line only the count can read puts the heading and the rows out of step" )
      continue
    fi
    _spec_marker_unescape_into _name "${BASH_REMATCH[1]}"

    # The contiguous comment run immediately above, then the FIRST `# why:`
    # inside it. A blank line, or any non-comment line, ends the run -- so
    # a block separated from its test by a blank line is not attached, and
    # falls to the orphan sweep.
    _j=$(( _i - 1 ))
    while (( _j >= 1 )) && [[ "${_sm_lines[_j-1]}" == '#'* ]]; do
      _j=$(( _j - 1 ))
    done
    _run_start=$(( _j + 1 ))
    _w=0
    for (( _m = _run_start; _m < _i; _m++ )); do
      if [[ "${_sm_lines[_m-1]}" =~ ${_SPEC_MARKER_WHY_RE} ]]; then
        _w="${_m}"
        break
      fi
    done

    _marked=0
    _desc=''
    if (( _w > 0 )); then
      _marked=1
      _sm_claimed["${_w}"]=1
      _spec_marker_join_into _desc _sm_lines "${_w}" $(( _i - 1 )) _sm_findings
    fi
    _sm_tests+=( "${_i}"$'\t'"${_marked}"$'\t'"${_name}"$'\t'"${_desc}" )
  done

  # The file-level blurb: the FIRST `# why:` in the opening run, unless
  # that run turned out to be the first test's marker.
  if (( _open_end > 0 )); then
    _w=0
    for (( _m = 1; _m <= _open_end; _m++ )); do
      if [[ "${_sm_lines[_m-1]}" =~ ${_SPEC_MARKER_WHY_RE} ]]; then
        _w="${_m}"
        break
      fi
    done
    if (( _w > 0 )); then
      if [[ -n "${_sm_claimed[${_w}]:-}" ]]; then
        _sm_findings+=( "${_w}"$'\t'ambiguous-blurb$'\t'"the opening comment run touches the first '@test', so this block is that test's description and the file has no section blurb -- separate them with a blank line" )
      else
        _sm_claimed["${_w}"]=1
        _spec_marker_join_into _sm_blurb _sm_lines "${_w}" "${_open_end}" \
          _sm_findings paragraphs
      fi
    fi
  fi

  # Every `# why:` nothing claimed. Reported in line order, which is why
  # this is a sweep over the file rather than an accumulation above.
  for (( _i = 1; _i <= _n; _i++ )); do
    [[ "${_sm_lines[_i-1]}" =~ ${_SPEC_MARKER_WHY_RE} ]] || continue
    [[ -n "${_sm_claimed[${_i}]:-}" ]] && continue
    _sm_findings+=( "${_i}"$'\t'orphan$'\t'"a '# why:' block attached to no '@test' -- a renamed or deleted test leaves one behind, and it would read as a description of something" )
  done

  # Line order across both passes, so a reader walks the file downwards.
  if (( ${#_sm_findings[@]} > 1 )); then
    mapfile -t _sm_findings < <(
      printf '%s\n' "${_sm_findings[@]}" | LC_ALL=C sort -t$'\t' -k1,1n -s
    )
  fi
  return 0
}
