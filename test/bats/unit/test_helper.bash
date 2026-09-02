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
#   <file> with its comment-only and blank lines dropped. Exits non-zero when
#   nothing survives (grep's own no-match status), so a spec that asserts
#   success also learns that the file has no code at all.
code_lines() {
    strip_comments < "${1}"
}

# code_grep <grep-arg>... <file>
#   `grep <arg>... <file>` restricted to the code lines of <file>. Argument
#   order mirrors grep's own, file last.
code_grep() {
    local _file="${*: -1}"
    code_lines "${_file}" | grep "${@:1:$#-1}"
}

# yaml_job_text <file> <job>
#   One top-level `jobs:` entry of <file>, VERBATIM -- from `  <job>:` up to
#   the next two-space-indented key. Comments included, so pair it with
#   only_comments where the assertion is about the prose.
yaml_job_text() {
    awk -v _key="^  ${2}:" \
        '$0 ~ _key {flag=1; next} /^  [a-z]/{flag=0} flag' "${1}"
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
