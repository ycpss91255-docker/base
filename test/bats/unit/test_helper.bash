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
#
#   The unreadable-subject report goes to STDERR here, which is the one
#   place this tree's `BUG:` convention is inverted, and deliberately.
#   code_grep's stdout is grep's: lines, or a count under `-c`. Every call
#   site reads it as that -- `assert_output '2'`, an arithmetic comparison,
#   a `| head -1` -- so a `BUG:` line printed there is a match that is not
#   a match and a count that is not a number. code_lines keeps its report
#   on stdout because ITS stdout is the report: its callers capture it and
#   print what they captured when the status says the file was not read.
code_grep() {
    local _file="${*: -1}" _code _status=0
    _code="$(code_lines "${_file}")" || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
        printf '%s\n' "${_code}" >&2
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

# yaml_step_id_for <file> <job> <ere>
#   The `id:` of the FIRST step inside <job> whose OWN body matches <ere> --
#   the value an assertion needs when it wants to say "the consumer reads
#   THAT step", rather than the weaker "some step output reaches the
#   consumer". The id is derived from the file, so renaming the step in the
#   workflow moves the assertion with it instead of leaving it pinned to a
#   remembered string.
#
#   Reads the job's CODE lines, so a mention of <ere> in a comment paragraph
#   cannot name a step.
#
#   It answers with an id only where it can PLACE one: the match sits inside
#   the job's `steps:` list, in a step that declared its own `id:` on a line
#   of its own ahead of the matching line. Nothing else assigns the id, and
#   every step boundary and every exit from the list clears it, so the
#   remaining shapes -- the matching step carries no `id:`; the `id:` is an
#   action input under `with:` rather than the step's own key; the `id:`
#   comes only AFTER the matching line; the match sits above the first step
#   or below the last one; the pattern matches nowhere; the job has no
#   `steps:` key; the job does not exist -- print an empty line. Callers
#   guard with `[ -n ... ]`, so a match it cannot place fails the assertion
#   loud rather than passing it an id this function guessed.
#
#   One legal shape is refused rather than read: a step whose `id:` shares
#   the dash line (`- id: foo`), or that opens with a bare `-`. Neither is
#   attributed, because neither can be told from a nested key by indent
#   alone -- and refusing is the direction that fails an assertion loudly.
yaml_step_id_for() {
    yaml_job_lines "${1}" "${2}" \
        | _pat="${3}" awk '
            function _indent(_s) {
                if (match(_s, /[^[:space:]]/)) { return RSTART - 1 }
                return -1
            }
            BEGIN { _skey = -1; _ref = -1; _key = -1; _left = 0; _id = "" }
            /^[[:space:]]*$/ { next }
            {
                _ind = _indent($0)

                # The steps LIST is the anchor. Reading the boundary off
                # "the shallowest dash the job has shown" instead took it
                # from whichever list the job wrote first -- a block-style
                # `needs:`, a `strategy.matrix` sequence -- and when that
                # dash sat shallower than the step dashes, no step dash
                # ever counted as a boundary and one id was carried across
                # the whole job. So: skip everything above `steps:`,
                # where there is no step to name yet.
                if (_skey < 0) {
                    if ($0 ~ /^[[:space:]]*steps:[[:space:]]*$/) { _skey = _ind }
                    next
                }

                # The list ends at the next key of the job -- a
                # non-dash line no deeper than the `steps:` key.
                # Attribution ends with it, so the id of the last step
                # cannot follow the scan out.
                if (_ind <= _skey && $1 != "-") { _left = 1; _id = "" }

                if (!_left) {
                    if ($1 == "-") {
                        # The reference indent is the FIRST dash after
                        # `steps:`. A dash at exactly it starts the next
                        # step; a deeper one is inside the current step (a
                        # `with:` list, a `- ` in a block scalar) and must
                        # leave its id alone; a shallower one means the
                        # scan has left the list for good.
                        if (_ref < 0) { _ref = _ind }
                        if (_ind < _ref) { _left = 1; _id = "" }
                        else if (_ind == _ref) {
                            _id = ""
                            _key = (match($0, /-[[:space:]]+/) ? _ind + RLENGTH : -1)
                        }
                    } else if (_key >= 0 && _ind == _key && $1 == "id:") {
                        # The OWN key of the step, at the indent its
                        # boundary dash set. `id` is an ordinary action
                        # input name too, and a `with:` one sits deeper.
                        _id = $2
                    }
                }

                if ($0 ~ ENVIRON["_pat"]) { print _id; exit }
            }
        '
}

# yaml_step_run <file> <job> <step>
#   The `run:` script of ONE step of <job>, as the shell that step actually
#   executes: the block scalar already folded, `${{ }}` template tokens left
#   as the literal text they are in the file. A spec whose subject is what an
#   inline step DOES -- not what its text looks like -- feeds this to `bash`
#   with the step's `env:` supplied and reads the exit status, so the
#   assertion survives a rewrite of the same behaviour and fails on a rewrite
#   of the behaviour itself.
#
#   <step> names the step by its `id:` OR by its `name:`. Both are read
#   because a step is only obliged to carry the second: requiring an `id:`
#   would mean editing the workflow to make a step testable, and a step
#   edited to be tested is no longer quite the step that runs.
#
#   A job, step or `run:` that does not exist yields NOTHING, so a caller's
#   `[ -n ... ]` guard fails the assertion loudly rather than executing an
#   empty script and reading its success as the step's.
yaml_step_run() {
    _yaml_eval "${1}" \
        ".jobs.\"${2}\".steps[] | select(.id == \"${3}\" or .name == \"${3}\") | .run"
}

# yaml_run_blocks <file>
#   Every step `run:` script in <file>, in document order, one block after
#   another -- the shell a workflow actually executes, separated from the
#   YAML that carries it. A scan whose subject is what workflow shell DOES
#   has to read it here: shellcheck never sees these blocks (they are not
#   shell FILES), so nothing else in the tree reads them as code.
#
#   A job with no `steps:` contributes nothing rather than an error, so a
#   workflow whose jobs are pure `uses:` calls is scanned like any other.
yaml_run_blocks() {
    _yaml_eval "${1}" \
        '.jobs | to_entries | .[] | .value.steps // [] | .[] | select(has("run")) | .run'
}

# yaml_job_names <file>
#   The top-level `jobs:` keys of <file>, one per line -- the workflow's own
#   job roster, DERIVED from the file rather than remembered by the spec. A
#   test whose subject is "every job that ..." has to compute its population
#   here: a roster typed into the spec is green on exactly the job somebody
#   adds tomorrow, which is the event the test exists to notice.
yaml_job_names() {
    awk '/^jobs:/{f=1; next}
         f && /^[^[:space:]]/{f=0}
         f && /^  [A-Za-z][A-Za-z0-9_.-]*:[[:space:]]*$/{
             sub(/:[[:space:]]*$/, ""); sub(/^  /, ""); print
         }' "${1}"
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

# workflow_files [dir]
#   Every workflow FILE in <dir> (default: this checkout's workflow
#   directory): `*.yaml` first, then `*.yml`, each in the shell's glob
#   order, skipping anything that is not a regular file.
#
#   Which extensions a workflow file may carry is written HERE and nowhere
#   else. It used to be written twice -- once as this glob inside
#   reusable_workflow_files, once inline in the cross-check that re-reads
#   the same directory raw, the reading that exists to catch a worker the
#   trigger derivation stopped seeing. A directory that grew a third
#   spelling would have been enumerated by one of them and not the other,
#   which makes the two readings disagree in exactly the direction the
#   second one is there to detect.
workflow_files() {
    local _dir="${1:-/source/.github/workflows}" _f
    for _f in "${_dir}"/*.yaml "${_dir}"/*.yml; do
        [[ -f "${_f}" ]] || continue
        printf '%s\n' "${_f}"
    done
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
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
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
    done < <(workflow_files "${_dir}")
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

# ── reading a spec the way a shell reads it ───────────────────────────────────
#
# `spec_permission_surface_subjects` below asks which workflow a spec's
# `yaml_permission_surface` CALL is applied to. Asked of the raw text, that
# question is also answered by text which is not a call at all: a path
# inside a quoted string (`"usage: yaml_permission_surface /a/b.yaml"`), a
# path inside a heredoc BODY -- the shape this tree's own fixtures are
# written in -- and a path after a trailing `#` all read as
# `<name> <token>` on a code line, and each of them certified a worker
# whose surface no spec reads.
#
# So the text is LEXED rather than matched, with the few shell rules that
# decide the question: single quotes quote everything up to the next `'`;
# double quotes quote everything up to the next `"` except a `$(`, which
# opens a command context that is code again; a `\` escapes the next
# character outside single quotes; `$(( ))` and a word-initial `(( ))` are
# arithmetic, where `<<` is a shift and not a redirection; `<<WORD` opens a
# heredoc whose body is DATA until a line that is EXACTLY WORD -- column 0,
# nothing trailing -- where WORD is any of bash's spellings of it (`WORD`,
# `'WORD'`, `"WORD"`, `\WORD`, and any mix, all read literally, since bash
# expands nothing in a terminator), `<<-WORD` is the same with leading TABS
# stripped from the closing line, and `<<<` is a here-string that opens
# nothing; and a `#` that starts a word opens a comment that runs to end of
# line.
#
# It is not a shell parser and does not try to be. It does not know `eval`,
# an alias, a terminator carried onto the next line by a `\`, or a
# different function that happens to carry the same name. Everything it
# cannot read resolves to "not a call site", which reads downstream as
# UNPINNED and fails loudly -- the direction that costs a spec author one
# line, rather than the one that certifies a worker nothing reads. A `<<`
# it cannot finish reading is the same choice made explicitly: it opens a
# heredoc whose terminator no line matches, spending the rest of the file
# rather than handing a fixture body back as code.

# _shell_text_scan <mode> [name]
#   Read shell CODE LINES on stdin (comment-only lines already dropped by
#   `code_lines`) and report what a shell would see:
#     code            -- every line that is shell code, i.e. every line
#                        outside a heredoc BODY, verbatim;
#     calls <name>    -- one record per CALL-SHAPED occurrence of <name>:
#                        `ARG <token>` for the whitespace-delimited token
#                        after it, `NOARG` when the name ends the line.
#                        An occurrence inside quotes, inside a heredoc
#                        body or after a comment `#` is not a call and
#                        yields no record.
#   Both modes run the same lexer, so "which lines are code" is decided
#   once: a heredoc body that is data to one reading cannot be code to the
#   other.
_shell_text_scan() {
    awk -v _mode="${1}" -v _name="${2:-}" '
    # The terminator word of a heredoc redirection at position p of s,
    # with its quoting removed: bash accepts it bare, `\`-escaped,
    # single- or double-quoted, in any mix, and expands none of it. The
    # empty string means "there is no word here this can read" -- an
    # unfinished quote, or a `\` continuation carrying the word onto the
    # next line -- which the caller turns into a terminator no line
    # matches. `_hd_next` reports where the word ended.
    function _hd_term(s, p, n2,   c, q, w, seen) {
        w = ""; seen = 0
        while (p <= n2) {
            c = substr(s, p, 1)
            if (c == " " || c == "\t" || c == ";" || c == "&" || c == "|" \
                || c == "<" || c == ">" || c == "(" || c == ")") { break }
            if (c == "\\") {
                p++
                if (p > n2) { _hd_next = p; return "" }
                w = w substr(s, p, 1); p++; seen = 1; continue
            }
            if (c == "\047" || c == "\"") {
                q = c; p++
                while (p <= n2 && substr(s, p, 1) != q) { w = w substr(s, p, 1); p++ }
                if (p > n2) { _hd_next = p; return "" }
                p++; seen = 1; continue
            }
            w = w c; p++; seen = 1
        }
        _hd_next = p
        return seen ? w : ""
    }
    # One past the `))` closing the arithmetic expansion or command whose
    # first `(` sits at position p, or one past the end of the line when
    # it does not close there.
    function _arith_end(s, p, n2,   d, c) {
        d = 0
        while (p <= n2) {
            c = substr(s, p, 1)
            if (c == "(") { d++ }
            else if (c == ")") { d--; if (d == 0) { return p + 1 } }
            p++
        }
        return n2 + 1
    }
    BEGIN {
        _len = length(_name); _in_hd = 0; _term = ""; _dash = 0
        # A terminator for a `<<` this reader could not finish: no line of
        # a body can equal it, so the heredoc runs to end of file.
        _unmatchable = sprintf("%c<unreadable heredoc terminator>", 1)
    }
    {
        line = $0
        if (_in_hd) {
            t = line
            if (_dash) { sub(/^\t+/, "", t) }
            if (t == _term) { _in_hd = 0 }
            next
        }
        if (_mode == "code") { print line }
        n = length(line); i = 1; stack = ""; pend = 0
        while (i <= n) {
            ch = substr(line, i, 1)
            top = (length(stack) > 0) ? substr(stack, length(stack), 1) : "-"
            if (top == "q") {
                if (ch == "\047") { stack = substr(stack, 1, length(stack) - 1) }
                i++; continue
            }
            if (ch == "\\") { i += 2; continue }
            if (top == "d") {
                if (ch == "\"") { stack = substr(stack, 1, length(stack) - 1); i++; continue }
                if (ch == "$" && substr(line, i + 1, 2) == "((") { i = _arith_end(line, i + 1, n); continue }
                if (ch == "$" && substr(line, i + 1, 1) == "(") { stack = stack "c"; i += 2; continue }
                i++; continue
            }
            if (ch == "\047") { stack = stack "q"; i++; continue }
            if (ch == "\"") { stack = stack "d"; i++; continue }
            if (ch == "$" && substr(line, i + 1, 2) == "((") { i = _arith_end(line, i + 1, n); continue }
            if (ch == "$" && substr(line, i + 1, 1) == "(") { stack = stack "c"; i += 2; continue }
            if (ch == "(" && substr(line, i + 1, 1) == "(") {
                pre = (i == 1) ? "" : substr(line, i - 1, 1)
                if (pre == "" || pre == " " || pre == "\t" || pre == ";" \
                    || pre == "|" || pre == "&" || pre == "(") {
                    i = _arith_end(line, i, n); continue
                }
            }
            if (ch == ")" && top == "c") { stack = substr(stack, 1, length(stack) - 1); i++; continue }
            if (ch == "#") {
                p = (i == 1) ? "" : substr(line, i - 1, 1)
                if (p == "" || p == " " || p == "\t" || p == ";" || p == "|" || p == "&" || p == "(") { break }
                i++; continue
            }
            if (ch == "<" && substr(line, i + 1, 1) == "<") {
                if (substr(line, i + 2, 1) == "<") { i += 3; continue }
                j = i + 2
                _dash = 0
                if (substr(line, j, 1) == "-") { _dash = 1; j++ }
                while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") { j++ }
                word = _hd_term(line, j, n)
                _term = (word == "") ? _unmatchable : word
                pend = 1
                i = _hd_next; continue
            }
            if (_len > 0 && substr(line, i, _len) == _name) {
                pre = (i == 1) ? "" : substr(line, i - 1, 1)
                post = substr(line, i + _len, 1)
                if ((pre == "" || pre !~ /[A-Za-z0-9_]/) \
                    && (post == "" || post == " " || post == "\t")) {
                    if (_mode == "calls") {
                        rest = substr(line, i + _len)
                        sub(/^[ \t]+/, "", rest)
                        sub(/[ \t].*$/, "", rest)
                        if (rest == "") { print "NOARG" } else { print "ARG " rest }
                    }
                }
                i += _len; continue
            }
            i++
        }
        if (pend) { _in_hd = 1 }
    }'
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
#   A call site is decided by `_shell_text_scan` above rather than by
#   matching the name in the text, so an occurrence sitting in a quoted
#   string, in a heredoc body or after a comment `#` is what it is -- text
#   -- and pins nothing.
#
#   The resolution of the argument is textual and deliberately timid. A
#   call whose argument is a literal path resolves to it; one whose
#   argument is `${VAR}` (or `$VAR`) resolves only when the spec's own
#   shell code assigns that name exactly one literal; anything else is
#   `UNRESOLVED: <argument>`. Both readings -- the call sites and the
#   assignments they resolve against -- run over the same heredoc-free
#   view, so a fixture that assigns `WF` inside a heredoc cannot decide a
#   real call site.
#
#   What that buys, stated as what the code guarantees rather than as an
#   absolute: nothing certifies a worker except a call-shaped, unquoted
#   occurrence of the name whose argument resolves to that worker's path.
#   It is not proof that such an occurrence CALLS this helper -- a
#   same-named function, or an `echo yaml_permission_surface <path>`, would
#   read as one -- and it is not proof that the caller ASSERTS anything on
#   what it reads. What it does rule out is the failure that made it
#   necessary: a spec that merely mentions the path, in prose, in a string
#   or in a fixture it writes, certifying a worker it never reads. Timid is
#   the safe direction for the rest: a call written in a shape this cannot
#   read reads as UNPINNED and fails loudly, which is fixed by naming the
#   path.
#
#   Status: 0 at least one call site; 1 the spec was READ and calls it
#   nowhere; 2 the spec could not be read, or a call site carries no
#   argument this can see -- both `BUG:` lines, because a call site that
#   goes unseen is exactly how a spec that pins a worker stops counting as
#   its pin.
spec_permission_surface_subjects() {
    local _spec="${1}" _raw _code _calls _call _arg
    local _status=0
    _raw="$(code_lines "${_spec}")" || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
        printf '%s\n' "${_raw}"
        return 2
    fi
    _code="$(printf '%s\n' "${_raw}" | _shell_text_scan code)"
    _status=0
    _calls="$(printf '%s\n' "${_raw}" \
        | _shell_text_scan calls yaml_permission_surface)" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
        printf 'BUG: the call-site scan of %s exited %s\n' "${_spec}" "${_status}"
        return 2
    fi
    [[ -n "${_calls}" ]] || return 1
    while IFS= read -r _call; do
        [[ -n "${_call}" ]] || continue
        if [[ "${_call}" == 'NOARG' ]]; then
            printf 'BUG: %s names yaml_permission_surface with no argument this can read\n' \
                "${_spec}"
            return 2
        fi
        _arg="${_call#ARG }"
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

# assert_spec_subject_dir <path> [what_it_is]
#   The directory form, for a spec whose subject is a tracked TREE
#   (`.github/workflows/`, `doc/adr/`) rather than one file. Same contract,
#   same reasoning: the tree is present in every mode this suite has, so its
#   absence is a rename nobody noticed and has to fail.
#
#   Deliberately `-d` and not a widened `-e` shared with the file form: a
#   path that turned from a directory into a file, or back, is itself one of
#   the moves these guards exist to catch, and `-e` would answer it with a
#   pass.
assert_spec_subject_dir() {
    local _path="${1:?BUG: assert_spec_subject_dir expects a path}"
    local _what="${2:-the directory this spec asserts on}"
    [[ -d "${_path}" ]] || fail \
        "missing ${_path} -- ${_what}. It is tracked, so it was deleted, renamed or moved: restore it or update the path here. Failing rather than skipping is deliberate; a spec that quietly shrinks to zero cases is the defect this guard exists to catch."
}
