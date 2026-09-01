#!/usr/bin/env bash

# Standard bats libraries (installed via apt in CI container)
bats_load_library "bats-support"
bats_load_library "bats-assert"

# bats-mock: for stubbing system commands (id, uname, docker, dpkg-query)
# Installed via git in compose.yaml
load "${BATS_LIB_PATH}/bats-mock/stub"

# bash_test_helper (via git subtree):
#   git subtree add --prefix test/bash_test_helper \
#       https://github.com/ycpss91255/bash_test_helper main --squash
_BTH="${BATS_TEST_DIRNAME}/bash_test_helper/src"
if [[ -f "${_BTH}/test_helper.bash" ]]; then
    # shellcheck disable=SC1090
    source "${_BTH}/test_helper.bash"
fi
unset _BTH

# ── Test utilities ────────────────────────────────────────────────────────────

# Create a temporary mock directory prepended to PATH
# Usage: mock_cmd <cmd_name> <script_body>
# Example: mock_cmd "uname" 'echo "aarch64"'
create_mock_dir() {
    MOCK_DIR="$(mktemp -d)"
    export PATH="${MOCK_DIR}:${PATH}"
}

mock_cmd() {
    local _cmd="${1}"; shift
    local _body="${1}"
    printf '#!/bin/bash\n%s\n' "${_body}" > "${MOCK_DIR}/${_cmd}"
    chmod +x "${MOCK_DIR}/${_cmd}"
}

cleanup_mock_dir() {
    [[ -n "${MOCK_DIR:-}" ]] && rm -rf "${MOCK_DIR}"
}

# ── early-closing-reader shims ────────────────────────────────────────────────
#
# A pipeline into a reader that stops reading is a race. `grep -q` leaves on
# its first match, `head -n1` after one line; a writer still writing then takes
# SIGPIPE and exits 141, `pipefail` makes 141 the PIPELINE's status, and an
# `if` reads that as false -- so a SUCCESSFUL match is reported as "not found".
# The status is not lost, it is inverted.
#
# Whether the race is lost depends on the libc and the scheduler: the same
# pipeline lost it 0 times in 20000 iterations on the host (glibc, bash 5.1)
# and 6.4% of the time inside the alpine test-tools image (musl, coreutils 9.5,
# bash 5.2). Repetition is therefore worthless as evidence -- it is a coin the
# platform weights.
#
# These two helpers pin the losing interleaving instead, so a reintroduced
# pipeline fails on EVERY run. Code that reads the whole stream never execs an
# early-closing reader and never leaves a writer without one, so both shims are
# inert against it. Same technique as the ADR-numbering min/max regression in
# adr_numbering_spec.bats.
#
# Note for callers: bats' own `run` clears errexit, and a sourced function
# inherits the harness's options rather than its production script's. Where the
# defect needs `set -euo pipefail` to show, drive the code from a strict shell
# that is a script FILE, never `bash -c '...'` -- under kcov the xtrace PS4
# expands ${BASH_SOURCE}, which is EMPTY at the top level of a `bash -c`
# string, so `set -u` aborts the harness before the code under test runs.

# shim_early_closing_reader <dir> <name>...
#   Install each <name> into <dir> as a reader that exits 0 -- "I have my
#   match" -- WITHOUT reading a byte, so the write end of the pipe has no
#   reader left from the instant the pipeline starts. Models `head -n1` /
#   `grep -q` at their most impatient.
shim_early_closing_reader() {
    local _dir="${1}"; shift
    mkdir -p "${_dir}"
    local _name
    for _name in "$@"; do
        cat > "${_dir}/${_name}" << 'EOF'
#!/bin/sh
# A reader that already has what it needs: leave at once.
exit 0
EOF
        chmod +x "${_dir}/${_name}"
    done
}

# shim_late_writer <dir> <name> <early> <late>
#   Install <name> into <dir> as a writer that prints <early> immediately and
#   <late> only after a delay -- the losing side of the race every time.
#
#   <early> carries whatever the real reader is looking for, so a real
#   `grep -q` genuinely matches and genuinely leaves; the <late> write then
#   finds no reader. The late half runs under `exec` so the SIGPIPE becomes the
#   shim's OWN exit status instead of being swallowed by a trailing `exit 0`.
shim_late_writer() {
    local _dir="${1}" _name="${2}" _early="${3}" _late="${4}"
    mkdir -p "${_dir}"
    printf '%s\n' "${_early}" > "${_dir}/${_name}.early"
    printf '%s\n' "${_late}" > "${_dir}/${_name}.late"
    cat > "${_dir}/${_name}" << EOF
#!/bin/sh
cat "${_dir}/${_name}.early"
sleep 0.2
exec cat "${_dir}/${_name}.late"
EOF
    chmod +x "${_dir}/${_name}"
}

# ── Comment-stripped views of a file ──────────────────────────────────────────
#
# A structural spec greps a file for the shape it wants to pin. Grepping the
# WHOLE file makes a string that appears only in a COMMENT satisfy an
# assertion about CODE -- and the comments in this repo name, in prose,
# exactly the things the specs assert about: the header of a workflow spells
# out the action it must never use, a `run:` block explains why `docker tag`
# is the wrong tool, a script's header lists the helpers it calls. A guard
# written that way stays green while the property it names is deleted, which
# is the failure mode these helpers exist to remove.
#
# The rule is deliberately narrow: a line is a comment when its first
# non-blank character is `#`. That is the one form a YAML comment, a shell
# comment inside a `run: |` block scalar, and a Dockerfile comment all share,
# and it is the only form that can be recognised without parsing the host
# language.
#
# What is NOT stripped, on purpose -- the over-strict failure is the same
# defect with the sign flipped, a spec that stops matching real code:
#   * a `#` that follows anything else on the line (`uses: a/b@sha # v1.2.2`,
#     `run: echo "count: 3 # not a comment"`) -- that line IS code, and a
#     naive `s/#.*//` would silently shorten it;
#   * a `#` inside a quoted string, for the same reason;
#   * any line of a block scalar that is not itself comment-only.

# strip_comments
#   Filter form: read stdin, drop comment-only and blank lines. Use where the
#   source is a pipeline (an extracted block) rather than a file.
strip_comments() {
    grep -vE '^[[:space:]]*(#|$)'
}

# only_comments
#   The mirror of strip_comments: keep ONLY the comment-only lines. A few
#   assertions are genuinely about what a file SAYS -- "the job documents
#   setup-tui as out of scope" -- and those belong here, so that asserting
#   against a comment is a visible choice rather than the accident this
#   whole section exists to remove.
only_comments() {
    grep -E '^[[:space:]]*#'
}

# code_lines <file>
#   <file> with its comment-only and blank lines dropped.
#
#   The STATUS separates the two readings a caller must never merge:
#     0  code lines were emitted;
#     1  the file was READ and nothing survived the strip (grep's own
#        no-match status) -- an all-comment or empty file;
#     2  the file was not read at all -- missing, a directory, unreadable.
#   Without the split the redirection's own failure arrives as 1, which is
#   the status every guard in this tree reads as "the subject simply does
#   not contain that string". A subject that was renamed away would then be
#   reported as a clean subject. The `BUG:` line goes to stdout, the way
#   every other derivation here reports one, because the scans that consume
#   these helpers read stdout inside a pipeline where a status is invisible.
code_lines() {
    local _file="${1}"
    if [[ ! -f "${_file}" || ! -r "${_file}" ]]; then
        printf 'BUG: code_lines cannot read %s\n' "${_file}"
        return 2
    fi
    strip_comments < "${_file}"
}

# code_grep <grep-arg>... <file>
#   `grep <arg>... <file>` restricted to the code lines of <file>. Argument
#   order mirrors grep's own, file last.
#
#   Statuses are code_lines' plus grep's, and they do not collide: 0 match,
#   1 no match over a file that WAS read, 2 a file that was not. The read is
#   therefore done into a variable rather than piped -- a pipeline's status
#   is its LAST command's, so an unreadable subject would reach grep as
#   empty stdin and come back as a plain no-match. Empty code is still fed
#   to grep rather than short-circuited, so counting flags keep answering
#   (`-c` over an all-comment file prints 0, exit 1).
code_grep() {
    local _file="${*: -1}" _code _status=0
    _code="$(code_lines "${_file}")" || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
        printf '%s\n' "${_code}"
        return "${_status}"
    fi
    if [[ -n "${_code}" ]]; then
        printf '%s\n' "${_code}" | grep "${@:1:$#-1}"
    else
        printf '' | grep "${@:1:$#-1}"
    fi
}

# yaml_job_text <file> <job>
#   One top-level `jobs:` entry of <file>, VERBATIM -- from `  <job>:` up to
#   the next two-space-indented key. Comments included, so pair it with
#   only_comments where the assertion is about the prose.
#
#   The terminator is ANY two-space-indented key, not a lowercase-initial
#   one. `Sign:` and `_pub:` are legal GitHub job ids, and while the
#   terminator only recognised `[a-z]` neither of them ended the job above
#   it -- so that job's text, and every grant read out of it, was really
#   the NEXT job's. A two-space comment line still does not terminate: a
#   comment paragraph between two jobs belongs to the job it documents.
yaml_job_text() {
    awk -v _key="^  ${2}:" \
        '$0 ~ _key {flag=1; next} /^  [^ #]/{flag=0} flag' "${1}"
}

# yaml_job_lines <file> <job>
#   The code lines of one top-level `jobs:` entry. Replaces the hand-rolled
#   awk block extractor the workflow specs each carried, which kept the
#   comment paragraphs sitting inside the job -- and those paragraphs are
#   long: they are where a workflow explains the mechanism the spec is
#   trying to pin.
yaml_job_lines() {
    yaml_job_text "${1}" "${2}" | strip_comments
}

# yaml_top_text <file> <key>
#   One TOP-level mapping of <file> (`on`, `env`, `permissions`,
#   `concurrency`), VERBATIM -- from `<key>:` up to the next unindented key.
yaml_top_text() {
    awk -v _key="^${2}:" \
        '$0 ~ _key {flag=1; next} /^[a-zA-Z]/{flag=0} flag' "${1}"
}

# yaml_top_lines <file> <key>
#   The code lines of one TOP-level mapping. The stripping matters more here
#   than anywhere: a comment paragraph between two top-level keys is not
#   indented out by the terminator, so an unstripped block carries the prose
#   that follows it.
yaml_top_lines() {
    yaml_top_text "${1}" "${2}" | strip_comments
}

# ── derived job / permission surfaces ────────────────────────────────────────
#
# A guard named for a SET ("every job", "every reusable worker") has to
# compute that set from the tree at run time. A literal roster inside the
# spec is the defect even while today's roster is complete, because the job
# the guard exists for is tomorrow's addition: a five-name loop over
# build-worker.yaml stayed green when a sixth job asking `contents: write`
# was appended to the file. These helpers are the derivation the specs share
# so that no spec has to keep a roster.
#
# They ask a YAML PARSER (`yq`, baked into the tooling image), not a regex.
# The previous shape built the derivation out of awk over indentation, and
# every YAML spelling that awk did not model made a job or a grant
# INVISIBLE rather than loud -- which is the fail-open direction for a
# guard whose entire assertion is "the scan came back empty":
#
#   * `sign-artifacts: # signs the images` -- a job key with a trailing
#     comment did not match a pattern anchored at end of line, so the job
#     was not a job and its `packages: write` was scanned by nothing;
#   * `packages: write # cache push`, `packages: "write"` -- an entry the
#     pattern rejected was read as the END of the permissions block, so it
#     and every entry after it disappeared (and whether the elevation was
#     seen depended on where in the block it sat);
#   * `Sign:`, `_pub:` -- legal job ids that did not terminate the previous
#     job, which then reported the NEXT job's grants as its own;
#   * `"on":`, `on: {workflow_call: null}` -- a reusable worker the `^on:`
#     text anchor did not recognise as reusable at all.
#
# A parser also buys two properties no grep can state: the key is at the
# RIGHT LEVEL of the document (a `permissions:` under `jobs.x.steps` is not
# a job's grant), and the value is the WHOLE value rather than a substring
# of it. And it fails CLOSED: a file yq cannot parse is an error, where the
# awk simply produced a shorter answer. Every helper below turns such an
# error into a `BUG:` line on stdout AND a non-zero status, because the
# scans that consume them read stdout inside a pipeline where a status is
# invisible.
#
# yaml_job_text / yaml_job_lines / yaml_top_text / yaml_top_lines stay
# textual on purpose: those return a block VERBATIM (comments included) and
# the specs match raw strings against them, which a re-serialising parser
# would reformat.

# _yaml_eval <file> <expr>
#   One yq expression over <file>. On any yq failure -- an unparsable
#   document, an expression this yq cannot run -- print a single `BUG:`
#   line carrying yq's own message and return 1. Nothing is printed for an
#   expression that legitimately selects nothing, so a caller can tell
#   "no entries" from "could not read".
_yaml_eval() {
    local _file="${1}" _expr="${2}" _out _status=0
    _out="$(yq "${_expr}" "${_file}" 2>&1)" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
        printf 'BUG: yq exited %s on %s: %s\n' "${_status}" "${_file}" \
            "$(printf '%s' "${_out}" | tr '\n' ' ')"
        return 1
    fi
    if [[ -n "${_out}" ]]; then
        printf '%s\n' "${_out}"
    fi
}

# yaml_job_names <file>
#   Every top-level `jobs:` key of <file>, in document order. A file whose
#   `jobs:` is missing or is not a mapping is a `BUG:` line and a non-zero
#   status, never an empty list: an empty list satisfies every "the scan
#   came back empty" assertion in the repo.
yaml_job_names() {
    local _file="${1}" _kind _status=0
    _kind="$(yq '.jobs | tag' "${_file}" 2>&1)" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
        printf 'BUG: yq exited %s reading the jobs mapping of %s: %s\n' \
            "${_status}" "${_file}" "$(printf '%s' "${_kind}" | tr '\n' ' ')"
        return 1
    fi
    if [[ "${_kind}" != '!!map' ]]; then
        printf 'BUG: %s has no jobs: mapping (its jobs key reads as %s)\n' \
            "${_file}" "${_kind}"
        return 1
    fi
    _yaml_eval "${_file}" '.jobs | keys | .[]'
}

# yaml_job_permission_entries <file> <job>
#   The `<scope>: <level>` entries of one job's own `permissions:` mapping,
#   in document order. A job that declares no block, or an inline one
#   (`permissions: read-all`, `permissions: {}`) that names no scope,
#   yields nothing. A job that is not in the file yields a `BUG:` line --
#   the caller named a job that was renamed, which is a defect and not an
#   absence.
#
#   ENTRIES -- not the block -- are what make an EXACT-set assertion
#   possible: a caller-facing `permissions:` may only NARROW the grant it
#   was handed, so any extra scope is an elevation that fails the caller's
#   run, and a presence check plus one `refute` of a known-bad scope cannot
#   see it.
yaml_job_permission_entries() {
    local _file="${1}" _job="${2}" _kind _status=0
    _kind="$(YAML_JOB="${_job}" yq '.jobs[strenv(YAML_JOB)] | tag' \
        "${_file}" 2>&1)" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
        printf 'BUG: yq exited %s reading job %s of %s: %s\n' \
            "${_status}" "${_job}" "${_file}" \
            "$(printf '%s' "${_kind}" | tr '\n' ' ')"
        return 1
    fi
    if [[ "${_kind}" != '!!map' ]]; then
        printf 'BUG: %s declares no job %s (that key reads as %s)\n' \
            "${_file}" "${_job}" "${_kind}"
        return 1
    fi
    YAML_JOB="${_job}" _yaml_eval "${_file}" \
        '.jobs[strenv(YAML_JOB)].permissions
           | select(tag == "!!map")
           | to_entries | .[]
           | (.key | tostring) + ": " + (.value | tostring)'
}

# yaml_permission_surface <file>
#   `<job>: <scope>: <level>` for every job DERIVED from <file>, in
#   document order -- and `<job>: <no entries>` for a job that declares no
#   block at all, or an inline one that yields no entry. The placeholder is
#   load-bearing: without it a job with no grants would drop out of the
#   listing, and an assertion over the listing would read "unbounded" as
#   "nothing to see".
#
#   A read that fails anywhere aborts the whole surface with the `BUG:`
#   line that caused it, rather than returning the jobs it managed to read
#   -- a partial surface is exactly the under-reported grant set every
#   assertion here exists to catch.
yaml_permission_surface() {
    local _file="${1}" _names _job _entries _status=0
    _names="$(yaml_job_names "${_file}")" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
        printf '%s\n' "${_names}"
        return 1
    fi
    while IFS= read -r _job; do
        [[ -n "${_job}" ]] || continue
        _status=0
        _entries="$(yaml_job_permission_entries "${_file}" "${_job}")" \
            || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf '%s\n' "${_entries}"
            return 1
        fi
        if [[ -z "${_entries}" ]]; then
            printf '%s: <no entries>\n' "${_job}"
        else
            printf '%s\n' "${_entries}" | sed "s|^|${_job}: |"
        fi
    done <<< "${_names}"
}

# yaml_trigger_keys <file>
#   The keys of <file>'s `on:` mapping. Read as a KEY at the top level of
#   the document, which is what makes every legal spelling of it one case:
#   bare `on:`, `"on":` (the standard quoting workaround for YAML 1.1
#   reading a bare `on` as a boolean, and what several formatters emit),
#   and a flow-style mapping. The boolean spelling is matched too, for a
#   parser that resolves the bare key to `true`.
yaml_trigger_keys() {
    _yaml_eval "${1}" '
        to_entries
          | map(select((.key | tostring) == "on"
                       or (.key | tostring) == "true"))
          | .[0].value
          | select(tag == "!!map")
          | keys | .[]'
}

# reusable_workflow_files [dir]
#   Every workflow file under <dir> (default: this checkout's workflow
#   directory) that declares `on: workflow_call`, i.e. every workflow whose
#   jobs run under a CALLING repo's token unless they say otherwise.
#   Derived from each file's parsed trigger keys, so a reusable worker
#   added to the directory is covered the day it lands however its author
#   spelled `on`.
#
#   A file that cannot be read contributes a `BUG:` line to the listing
#   instead of being skipped: a worker the derivation cannot parse is a
#   worker nothing downstream scans.
reusable_workflow_files() {
    local _dir="${1:-/source/.github/workflows}" _f _keys _status
    for _f in "${_dir}"/*.yaml "${_dir}"/*.yml; do
        [[ -f "${_f}" ]] || continue
        _status=0
        _keys="$(yaml_trigger_keys "${_f}")" || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf '%s\n' "${_keys}"
            continue
        fi
        _status=0
        # `grep -E ... >/dev/null` rather than `grep -q`: -q exits at the
        # first match, and the SIGPIPE that gives the writer upstream of it
        # becomes the pipeline's status under `pipefail` (141), which no
        # `case` arm below should have to know about.
        printf '%s\n' "${_keys}" \
            | grep -Fx -- 'workflow_call' >/dev/null || _status=$?
        case "${_status}" in
            0) printf '%s\n' "${_f}" ;;
            1) ;;
            *) printf 'BUG: grep exited %s reading %s\n' "${_status}" "${_f}" ;;
        esac
    done
}

# _spec_path_word <code> <word>
#   Resolve one call-site ARGUMENT to the path it names, reading only
#   <code> (the calling spec's own code lines). Prints the literal path, or
#   `UNRESOLVED: <word>` when the text cannot decide it. Never guesses: a
#   guess here certifies a workflow on the strength of a coin flip.
_spec_path_word() {
    local _code="${1}" _word="${2}" _var _hits _count
    case "${_word}" in
        '${'*'}') _var="${_word#'${'}"; _var="${_var%\}}" ;;
        '$'*'$'*) printf 'UNRESOLVED: %s\n' "${_word}"; return 0 ;;
        '$'*)     _var="${_word#\$}" ;;
        *'$'*)    printf 'UNRESOLVED: %s\n' "${_word}"; return 0 ;;
        *)        printf '%s\n' "${_word}"; return 0 ;;
    esac
    if [[ ! "${_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'UNRESOLVED: %s\n' "${_word}"
        return 0
    fi
    # Every assignment of that name to a bare or singly-quoted literal, with
    # duplicates collapsed. Two DIFFERENT literals leave the call site
    # undecidable, and so does a value that is itself an expansion.
    _hits="$(printf '%s\n' "${_code}" | sed -nE \
        "s/^[[:space:]]*(local[[:space:]]+|declare[[:space:]]+|export[[:space:]]+)?${_var}=[\"']?([^\"'[:space:]]*)[\"']?[[:space:]]*\$/\2/p" \
        | sort -u)"
    _count="$(printf '%s\n' "${_hits}" | awk 'NF { n++ } END { print n + 0 }')"
    if [[ "${_count}" -ne 1 || "${_hits}" == *'$'* ]]; then
        printf 'UNRESOLVED: %s\n' "${_word}"
        return 0
    fi
    printf '%s\n' "${_hits}"
}

# spec_permission_surface_subjects <spec>
#   The workflow file each `yaml_permission_surface` call in <spec> is
#   applied TO -- one line per CALL SITE, in file order, resolved from the
#   call's own argument.
#
#   This exists because "does this spec pin that worker's grants" was asked
#   as two independent substring questions of the same file: does its text
#   contain `yaml_permission_surface`, and does its text contain the
#   worker's path. A spec answering both certifies the worker even when the
#   surface call is applied to a different workflow -- and a spec that names
#   two workers while pinning one answers both for the one it does not pin.
#   Binding the subject to the ARGUMENT is what makes the question single.
#
#   The resolution is textual and deliberately timid. A call whose argument
#   is a literal path resolves to it; one whose argument is `${VAR}` (or
#   `$VAR`) resolves only when the file assigns that name exactly one
#   literal; anything else is `UNRESOLVED: <argument>`. Timid is the safe
#   direction here: an unresolved call pins nothing, so a worker whose only
#   pin is written in a shape this cannot read reads as UNPINNED and fails
#   loudly, which is fixed by naming the path. It can never pass a worker
#   that nothing pins.
#
#   Status: 0 at least one call site; 1 the spec was READ and calls it
#   nowhere; 2 the spec could not be read, or it names the function more
#   times than this could find arguments for -- both `BUG:` lines, because
#   a call site that goes unseen is exactly how a spec that pins a worker
#   stops counting as its pin.
spec_permission_surface_subjects() {
    local _spec="${1}" _code _calls _call _arg
    local _status=0 _mentions _found
    _code="$(code_lines "${_spec}")" || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
        printf '%s\n' "${_code}"
        return 2
    fi
    # A CALL-shaped mention: the name, as a whole word, with whitespace or
    # end of line after it. `yaml_permission_surface:` opening a @test's
    # own name is a mention and not a call, and counting it would make
    # every spec that documents the helper report a missing argument.
    _mentions="$(printf '%s\n' "${_code}" | grep -oE \
        '(^|[^A-Za-z0-9_])yaml_permission_surface([[:space:]]|$)' | wc -l)"
    _status=0
    _calls="$(printf '%s\n' "${_code}" | grep -oE \
        '(^|[^A-Za-z0-9_])yaml_permission_surface[[:space:]]+[^[:space:]]+')" \
        || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
        printf 'BUG: grep exited %s scanning %s for call sites\n' \
            "${_status}" "${_spec}"
        return 2
    fi
    _found="$(printf '%s\n' "${_calls}" | awk 'NF { n++ } END { print n + 0 }')"
    if [[ "${_mentions}" -ne "${_found}" ]]; then
        printf 'BUG: %s names yaml_permission_surface %s time(s) but %s carry an argument this can read\n' \
            "${_spec}" "${_mentions}" "${_found}"
        return 2
    fi
    [[ "${_found}" -gt 0 ]] || return 1
    while IFS= read -r _call; do
        [[ -n "${_call}" ]] || continue
        _arg="${_call##*yaml_permission_surface}"
        _arg="${_arg#"${_arg%%[![:space:]]*}"}"
        # A call site carries the punctuation that follows it -- a process
        # substitution's `)`, a `;`, a line continuation.
        while [[ "${_arg}" == *[\)\;\\] ]]; do
            _arg="${_arg%?}"
        done
        _arg="${_arg#[\"\']}"
        _arg="${_arg%[\"\']}"
        _spec_path_word "${_code}" "${_arg}"
    done <<< "${_calls}"
}

# ── spec subject presence ─────────────────────────────────────────────────────
#
# Many specs assert on the CONTENT of one tracked artifact -- a workflow
# file, a shipped template, a CI script. Those specs used to open with
# `[[ -f "${SUBJECT}" ]] || skip "... not at expected path"`, which is a
# guard that fails open: it cannot tell "absent by design in this run mode"
# from "renamed and nobody noticed", and it answers the second case with a
# green run. Since the artifact moving is exactly the regression the spec
# exists to catch, the guard was silent about the only event it was there
# for -- renaming one workflow turned 52 assertions into `ok ... # skip`
# and the suite still exited 0.
#
# `assert_spec_subject` is the fail-closed replacement. `/source` is the
# repo checkout itself (compose.yaml bind-mounts `.:/source` for every
# service), and base's spec tree runs nowhere else -- downstream repos get
# no `test` namespace -- so a tracked path under `/source` is present in
# every mode the suite has. Its absence is a defect, never a context.
#
# Skips remain correct for a subject that genuinely varies: a host or image
# capability the spec needs in order to observe anything (`command -v`), or
# a fixture only some dispatch mode produces. Each of those states its
# reason at the guard.
#
# Same idiom, same reasoning, as `_release_tag` in
# test/bats/integration/prev_release_upgrade_spec.bats.

# assert_spec_subject <path> [what_it_is]
#   Assert the tracked artifact this spec asserts on is present, failing
#   with the path and what it was when it is not.
assert_spec_subject() {
    local _path="${1:?BUG: assert_spec_subject expects a path}"
    local _what="${2:-the artifact this spec asserts on}"
    [[ -f "${_path}" ]] || fail \
        "missing ${_path} -- ${_what}. It is tracked, so it was deleted, renamed or moved: restore it or update the path here. Failing rather than skipping is deliberate; a spec that quietly shrinks to zero cases is the defect this guard exists to catch."
}
