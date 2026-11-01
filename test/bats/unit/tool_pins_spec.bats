#!/usr/bin/env bats
#
# Unit tests for script/watch/lib.sh + script/watch/pins.sh -- the pin
# registry the upstream-release watch reads.
#
# What is under test is the DERIVATION, not a roster. There is no list of
# watched tools anywhere in this repo: every watched version carries a
# `tool-pin:` marker on the line that declares it, and the table is
# whatever those markers say today. So the cases below are about the
# reader's contract -- what is a marker, what is its target, what version
# does that target carry -- plus the one edit a bump consists of
# (`--set`), because the scheduled workflow performs it unattended and a
# rewrite that silently does not take would produce a green proposal that
# changed nothing.
#
# Shape mirrors self_hosted_guard_lint_spec.bats: a controlled scratch
# tree for the rules, and a final section that drives the REAL tree.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The suite container's host-computed handoff is left in place on
  # purpose. It is keyed to the root it describes (/source), so it cannot
  # reach a scratch tree -- and the real-tree cases at the bottom of this
  # file are the ones that read it, which is the only in-container
  # exercise the handoff gets.
  PINS="/source/script/watch/pins.sh"
  SCRATCH="$(mktemp -d)"
  # The reader's population is what the tree TRACKS, so the fixture is a
  # real repository. `_pins` stages it before every invocation.
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/dockerfile" "${SCRATCH}/dist/dockerfile" \
           "${SCRATCH}/.github/workflows"
  # The reader walks the whole tree by shape, so these paths are a
  # convenience that mirrors the real repo rather than a requirement. The
  # one thing that IS required is that the tree yield at least one file of
  # a scanned shape; a tree that yields none is the vacuity case below.
  printf 'FROM scratch\n' > "${SCRATCH}/dist/dockerfile/Dockerfile"
  printf 'name: x\non:\n  push:\n' > "${SCRATCH}/.github/workflows/x.yaml"
  # The TMPDIR _pins_json gives pins.sh: test-owned and empty, so the tree
  # snapshot sees anything pins.sh leaves in it (base#1440).
  PINS_TMPDIR="${BATS_TEST_TMPDIR}/pins-tmp"
  mkdir -p "${PINS_TMPDIR}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _dockerfile <line>... -- write the scratch test-tools Dockerfile.
_dockerfile() {
  printf '%s\n' "$@" > "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# _workflow <line>... -- write the scratch workflow.
_workflow() {
  printf '%s\n' "$@" > "${SCRATCH}/.github/workflows/x.yaml"
}

_pins() {
  git -C "${SCRATCH}" add -A
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" "$@"
}

# ════════════════════════════════════════════════════════════════════
# What is a marker
# ════════════════════════════════════════════════════════════════════

# why: The grammar's one structural rule -- comments and blanks are skipped, so a
# marker can be documented above the line it claims
@test "pins: a marker's target is the next non-comment, non-blank line" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    '# an intervening comment' \
    '' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_success
  assert_output --partial $'pinned\tfoo\tgithub-release\towner/foo'
  assert_output --partial $'1.2.3\tdockerfile/Dockerfile.test-tools\t4'
}

# why: The convention must be documentable inside the trees it scans, and a
# substring match would make every mention a marker with the wrong target
@test "pins: PROSE that merely mentions the marker token is not a marker" {
  # The convention has to be documentable inside the very trees it scans:
  # the Dockerfile header explains it, this file quotes it, and the lint's
  # failure message prints it. A substring match would turn every one of
  # those into a marker with the wrong target.
  _dockerfile \
    '# Every version below carries a `tool-pin:` marker naming its upstream.' \
    'ARG FOO_VERSION=1.2.3' \
    '# tool-pin: foo github-release owner/foo' \
    'ARG BAR_VERSION=4.5.6'
  _pins --list
  assert_success
  assert_output --partial $'pinned\tfoo\tgithub-release\towner/foo'
  refute_output --partial 'Every version below'
  # Exactly one record: the prose line produced none.
  [[ "$(printf '%s\n' "${output}" | grep -c 'pinned') " == "1 " ]]
}

# why: A marker claiming nothing is a pin its author believes is watched; that
# belief is the state the whole mechanism exists to remove
@test "pins: a marker with no target line after it FAILS" {
  _dockerfile \
    'ARG FOO_VERSION=1.2.3' \
    '# tool-pin: foo github-release owner/foo'
  _pins --list
  assert_failure
  assert_output --partial 'has no target line after it'
}

# why: Both would claim one line and only the first would ever be read -- a pin
# that looks declared and is not watched
@test "pins: two markers with no target between them FAIL" {
  # Both would otherwise claim one line and only the first would ever be
  # read -- a pin that looks declared and is not watched.
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    '# tool-pin: bar github-release owner/bar' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'marker follows another with no target between them'
}

# why: A pinned marker with no coordinate can never be compared, so accepting it
# would put an uncheckable row in the table
@test "pins: a pinned marker naming no coordinate FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'names no resolver and coordinate'
}

# why: An unknown option is a typo in the one line that says how to watch a pin,
# and a typo caught weeks later is weeks of not watching
@test "pins: a marker carrying an unknown option FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo latest=9' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'unknown option latest=9'
}

# why: A marker whose target holds no version is a declaration with nothing to
# compare, which reads as watched and is not
@test "pins: a pinned marker whose target carries no version FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'RUN echo hello'
  _pins --list
  assert_failure
  assert_output --partial 'no version for owner/foo on its target line'
}

# why: unpinned is a declaration that the dependency floats, not an off switch, so
# it must produce a record rather than nothing
@test "pins: an unpinned marker records the dependency and no version" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- bounded by the alpine pin' \
    'RUN apk add --no-cache bash git'
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tapk-packages'
}

# why: Where the target IS an assignment, an empty value column throws away the one
# fact the record could carry -- the generated-workflow lint needs it
@test "pins: an unpinned marker on an assignment records the value it declares" {
  # An `unpinned` marker says "this dependency floats", not "this line
  # holds nothing". Where the target IS an assignment the reader can
  # already extract the right-hand side from, leaving the value column
  # empty throws away the one fact the record could carry -- and the
  # generated-workflow lint needs exactly that fact to answer "what does
  # this variable hold" without re-deriving it from the file.
  _dockerfile \
    '# tool-pin: unpinned downstream-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'"
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tdownstream-checkout'
  assert_output --partial $'actions/checkout@v7\tdockerfile/Dockerfile.test-tools\t2'
}

# why: The other side of that rule: an unpinned marker carries no coordinate to
# anchor on, so guessing a token would put a fabricated version in the table
@test "pins: an unpinned marker on a NON-assignment still records no value" {
  # The other side of that rule. `RUN apk add ...` names no single value,
  # and an unpinned marker carries no coordinate to anchor an extraction
  # on, so guessing a token off the line would put a fabricated version in
  # the table. `-` is the honest column.
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- bounded by the alpine pin' \
    'RUN apk add --no-cache bash git'
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tapk-packages\t-\t-\t-\t-\t-\t'
}

# why: An unnamed floating dependency cannot be reported on, which is the whole
# point of recording it
@test "pins: an unpinned marker that names no dependency FAILS" {
  _dockerfile \
    '# tool-pin: unpinned -- no name at all' \
    'RUN apk add --no-cache bash'
  _pins --list
  assert_failure
  assert_output --partial 'names no dependency'
}

# why: These are per-pin properties of the upstream; dropped from the table they
# silently become "compare every tag, refuse nothing"
@test "pins: pattern= and skip= are carried through to the table" {
  _dockerfile \
    '# tool-pin: alp dockerhub library/alpine pattern=^[0-9]+\.[0-9]+$ skip=3.24' \
    'ARG ALPINE_VERSION=3.21'
  _pins --list
  assert_success
  assert_output --partial '^[0-9]+\.[0-9]+$'
  assert_output --partial $'\t3.24\t3.21\t'
}

# ════════════════════════════════════════════════════════════════════
# Version extraction: the two target shapes
# ════════════════════════════════════════════════════════════════════

# why: The ARG shape is the majority of this repo's pins, and quoting must not
# become part of the version a branch name and CI are built from
@test "pins: an ARG target yields its right-hand side, unquoted" {
  _dockerfile \
    '# tool-pin: base dockerhub library/ubuntu pattern=.' \
    'ARG BASE_IMAGE="ubuntu:24.04"'
  _pins --value base
  assert_success
  assert_output 'ubuntu:24.04'
}

# why: Anchoring on the coordinate is what keeps extraction precise on a line
# carrying flags, paths and other colons
@test "pins: a non-ARG target yields the token after the coordinate" {
  # Anchoring on the coordinate is what keeps extraction precise on a line
  # that also carries flags, paths and other colons.
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - env:' \
    '          # tool-pin: actionlint dockerhub rhysd/actionlint pattern=.' \
    '          IMAGE: rhysd/actionlint:1.7.7'
  _pins --value actionlint
  assert_success
  assert_output '1.7.7'
}

# why: A name that declares no version has no answer to give, and an empty answer
# would be read by a caller as a version
@test "pins: --value refuses a name declared unpinned" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- no version to name' \
    'RUN apk add --no-cache bash'
  _pins --value apk-packages
  assert_failure
  assert_output --partial 'names no version'
}

# why: A typo in a pin name must fail rather than resolve to nothing, which a
# caller would substitute into a URL or a branch name
@test "pins: --value refuses a name nothing declares" {
  _dockerfile '# nothing here'
  _pins --value ghost
  assert_failure
  assert_output --partial 'no pin named ghost'
}

# ════════════════════════════════════════════════════════════════════
# --set: the one edit a bump consists of
# ════════════════════════════════════════════════════════════════════

# why: --set is the whole of a bump, and rebuilding the line would drop the quoting
# the Dockerfile relies on
@test "pins: --set rewrites an ARG and preserves its quoting" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION="v1.2.3"' \
    'RUN echo "${FOO_VERSION}"'
  _pins --set foo v2.0.0
  assert_success
  run grep -F 'ARG FOO_VERSION="v2.0.0"' \
    "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_success
}

# why: A blind file-wide substitution rewrites a URL that happens to carry the old
# version; the pin is a line, not a string
@test "pins: --set leaves every other line of the file alone" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3' \
    'RUN curl -o /x "https://example.invalid/1.2.3/x"'
  _pins --set foo 2.0.0
  assert_success
  # The URL happens to contain the old version. A blind file-wide
  # substitution would have rewritten it too.
  run grep -F 'https://example.invalid/1.2.3/x' \
    "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_success
}

# why: An image tag is the other target shape a bump must rewrite, and it lives on
# its own line inside a nested YAML block
@test "pins: --set rewrites an image tag in place, on its own line" {
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - env:' \
    '          # tool-pin: actionlint dockerhub rhysd/actionlint pattern=.' \
    '          IMAGE: rhysd/actionlint:1.7.7' \
    '        run: docker run --rm "${IMAGE}" -color'
  _pins --set actionlint 1.7.12
  assert_success
  run grep -F 'IMAGE: rhysd/actionlint:1.7.12' \
    "${SCRATCH}/.github/workflows/x.yaml"
  assert_success
}

# why: A bump run twice must not report a change it did not make, or the workflow
# opens a proposal with an empty diff
@test "pins: --set is a no-op when the pin already names that version" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  _pins --set foo 1.2.3
  assert_success
  assert_output --partial 'already 1.2.3'
}

# why: The from/to and the site are what a reviewer of a proposal reads first, and
# they are the only record of what the bump touched
@test "pins: --set reports the from/to and where it wrote" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  _pins --set foo 1.3.0
  assert_success
  assert_output --partial 'foo 1.2.3 -> 1.3.0'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:2'
}

# why: There is no version to set on a floating dependency, so a silent success
# would report a bump nobody performed
@test "pins: --set refuses a name declared unpinned" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- no version to set' \
    'RUN apk add --no-cache bash'
  _pins --set apk-packages 1.0
  assert_failure
  assert_output --partial 'there is no version to set'
}

# why: That trailing comment is where a "held at this version because" rationale
# lives -- the one sentence a reviewer of a bump most needs
@test "pins: --set keeps the trailing comment on the line it rewrites" {
  # That comment is where a "held at this version because ..." rationale
  # lives, and it is the one sentence a reviewer of a bump proposal most
  # needs to still be able to read. Rebuilding the line from the `NAME=`
  # prefix alone deletes it silently.
  _dockerfile \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=v2.12.0  # held: 2.13 rejects our DL3059 usage'
  _pins --set hadolint v2.15.1
  assert_success
  run grep -F \
    'ARG HADOLINT_VERSION=v2.15.1  # held: 2.13 rejects our DL3059 usage' \
    "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_success
}

# why: A stray space does not stay local: it flows into the reported from, into the
# branch name a bump builds, and into whatever CI feeds from --value
@test "pins: a trailing comment does not leak whitespace into the version" {
  # The stray space does not stay local: it flows into the reported
  # `from`, into the branch name a bump builds, and into whatever CI feeds
  # from `--value`.
  _dockerfile \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=v2.12.0  # held for now'
  _pins --value hadolint
  assert_success
  assert_output 'v2.12.0'
}

# why: mktemp creates 0600 and mv carries that mode onto the file -- invisible in
# CI and a permission denied on the next local just test
@test "pins: --set leaves the file's mode alone" {
  # `mktemp` creates 0600 and `mv` carries that mode onto whatever it
  # lands on. Invisible in the bump job (fresh checkout, git records
  # 100644) and a "permission denied" on the next `just test` for anyone
  # who runs the bump on their own machine.
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  chmod 664 "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _pins --set foo 1.3.0
  assert_success
  run stat -c '%a' "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_output '664'
}

# _gomod <line>... -- write the scratch config-gen go.mod.
_gomod() {
  mkdir -p "${SCRATCH}/dockerfile/config-gen"
  printf '%s\n' "$@" > "${SCRATCH}/dockerfile/config-gen/go.mod"
}

# why: The reader registers a go.mod require as a pin (base#1463), so a bump
# must be able to rewrite it; the assignment and coordinate:version rewrites
# never match `require <path> <version>` (review round 2). The version token
# the scanner read is replaced in place: spacing and comment kept.
@test "pins: --set rewrites a go.mod require, line form, keeping its comment (base#1463)" {
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0 // held: v0.21.0 is the last for go 1.22'
  _golang_pin
  _stub docker 0
  _pins_json --set xmod v0.22.0
  assert_success
  run sed -n 6p "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output 'require golang.org/x/mod v0.22.0 // held: v0.21.0 is the last for go 1.22'
  _pins --value xmod
  assert_output v0.22.0
}

# why: The block form is what `go get` writes; the entry has no verb on its
# line, so a rewrite keyed on `require` would miss it.
@test "pins: --set rewrites a go.mod require, block form (base#1463)" {
  _gomod 'module example.com/m' '' 'require (' \
    '	// tool-pin: xmod github-release golang/mod' \
    '	golang.org/x/mod v0.21.0' ')'
  _golang_pin
  _stub docker 0
  _pins_json --set xmod v0.22.0
  assert_success
  run sed -n 5p "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output $'\tgolang.org/x/mod v0.22.0'
}

# why: A quoted version is read without its quotes; the rewrite keeps them.
@test "pins: --set rewrites a quoted go.mod version and keeps the quotes (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require "golang.org/x/mod" "v0.21.0"'
  _golang_pin
  _stub docker 0
  _pins_json --set xmod v0.22.0
  assert_success
  run sed -n 3p "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output 'require "golang.org/x/mod" "v0.22.0"'
}

# why: A version Go would rewrite (`v0.22` -> `v0.22.0`) is refused before
# the file is touched, so a bump cannot write a pin the reader then refuses.
@test "pins: --set refuses a go.mod version Go would rewrite and leaves the file alone (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  chmod 664 "${_f}"
  _tree_snap
  _pins_json --set xmod v0.22
  assert_refusal 1 pin_set_refused "file=${_f}" line=3 reason=version_noncanonical
  _assert_tree_delta
}

# why: An empty quoted path once shifted the comment into the version column,
# so --list printed current=`// note` with rc 0 (review round 2, base#1463).
@test "pins: --list refuses a go.mod require with an empty path (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: x github-release golang/mod' \
    'require "" v1.0.0 // note'
  _pins_json --list
  assert_refusal 1 go_mod_unsupported_syntax \
    "file=${SCRATCH}/dockerfile/config-gen/go.mod" line=3 reason=path_empty
}

# _pins_json <arg>... -- _pins with JSON logs and stdout and stderr judged
# apart, for the refusal cases (assert_refusal). A command _stub put on
# ${STUB_BIN} is first on pins.sh's PATH, and on nothing else's: bats'
# own `run` needs a working mktemp.
_pins_json() {
  git -C "${SCRATCH}" add -A
  _pins_json_unstaged "$@"
}

# _pins_json_unstaged <arg>... -- _pins_json without staging the tree.
_pins_json_unstaged() {
  run --separate-stderr env PATH="${STUB_BIN:+${STUB_BIN}:}${PATH}" \
    TMPDIR="${PINS_TMPDIR}" PIN_REPO_ROOT="${SCRATCH}" LOG_FORMAT=json "${PINS}" "$@"
}

# Rule L (base#1440): every observation of a file, the tree or docker is
# lossless. Bytes are compared with cmp (_assert_bytes) and the tree by a
# content snapshot (_tree_snap, _assert_tree_delta); entries are selected by
# public name only. `$(cat f)` drops trailing newlines, a per-directory
# listing drops every other directory and every file's contents, and a
# filter on a private name drops every leak under another name, so a defect
# in the dropped part would pass.

# _tree_list -- one record per entry under ${SCRATCH} (its .git aside) and
# under ${PINS_TMPDIR}: path, type, mode, link target (`-` for none), and
# the sha256 of a regular file's bytes (`-` for anything else), sorted
# bytewise.
# The suite image's find and awk are busybox (no `find -printf`, no `awk
# --`), so the type, mode, link and hash are read per entry.
_tree_list() {
  local _e _y _l _h
  find "${SCRATCH}" "${PINS_TMPDIR}" -path "${SCRATCH}/.git" -prune -o -print \
    | LC_ALL=C sort | while IFS= read -r _e; do
    _l=- _h=-
    if [[ -L "${_e}" ]]; then
      _y=l
      _l="$(readlink -- "${_e}")"
    elif [[ -f "${_e}" ]]; then
      _y=f
      _h="$(sha256sum < "${_e}")"
      _h="${_h%% *}"
    elif [[ -d "${_e}" ]]; then
      _y=d
    else
      _y=o
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${_e}" "${_y}" "$(stat -c '%a' -- "${_e}")" "${_l}" "${_h}"
  done
}

# _tree_snap -- record _tree_list. Called after the last fixture write,
# right before the run under test (`git add` touches only .git). A listing
# without the fixture's own Dockerfile is a broken helper, not a tree.
_tree_snap() {
  _tree_list > "${BATS_TEST_TMPDIR}/tree.before"
  grep -q "^${SCRATCH}/dist/dockerfile/Dockerfile"$'\t''f' "${BATS_TEST_TMPDIR}/tree.before" \
    || fail "_tree_snap listed no fixture: $(cat "${BATS_TEST_TMPDIR}/tree.before")"
}

# _assert_tree_delta [+<path>|-<path>|~<path>]... -- the tree equals the one
# _tree_snap recorded except for exactly the entries named: +<path> added,
# -<path> removed, ~<path> rewritten (other bytes; type, mode and link
# target unchanged). No pattern is matched. With no argument the tree is
# identical: every byte, every mode, and no entry added under any name.
_assert_tree_delta() {
  local _before="${BATS_TEST_TMPDIR}/tree.before"
  local _after="${BATS_TEST_TMPDIR}/tree.after"
  local _named="${BATS_TEST_TMPDIR}/tree.named" _d _p _b _a
  _tree_list > "${_after}"
  : > "${_named}"
  for _d; do
    _p="${_d:1}"
    printf '%s\n' "${_p}" >> "${_named}"
    _b="$(_tree_record "${_before}" "${_p}")"
    _a="$(_tree_record "${_after}" "${_p}")"
    case "${_d:0:1}" in
      +) [[ -z "${_b}" && -n "${_a}" ]] \
           || fail "${_p} was not added: before [${_b}] after [${_a}]" ;;
      -) [[ -n "${_b}" && -z "${_a}" ]] \
           || fail "${_p} was not removed: before [${_b}] after [${_a}]" ;;
      '~') [[ -n "${_b}" && -n "${_a}" && "${_b%$'\t'*}" == "${_a%$'\t'*}" \
              && "${_b}" != "${_a}" ]] \
           || fail "${_p} was not rewritten in place: before [${_b}] after [${_a}]" ;;
      *) fail "_assert_tree_delta: ${_d} is not +<path>, -<path> or ~<path>" ;;
    esac
  done
  diff <(_tree_unnamed "${_before}" "${_named}") \
          <(_tree_unnamed "${_after}" "${_named}") \
    || fail "the tree changed beyond [${*}]"
}

# _tree_record <list> <path> -- the record of <path> in <list>, if any.
_tree_record() {
  awk -F'\t' -v p="${2}" '$1 == p' "${1}"
}

# _tree_unnamed <list> <names> -- the records of <list> whose path is not a
# line of <names>.
_tree_unnamed() {
  awk -F'\t' 'FILENAME == ARGV[1] { n[$0]; next } !($1 in n)' "${2}" "${1}"
}

# _assert_bytes <file> [<line>...] -- <file> holds exactly the <line>s, each
# ending in a newline (none: an empty file), compared with cmp.
_assert_bytes() {
  local _f="${1}" _want="${BATS_TEST_TMPDIR}/bytes.want"
  shift
  if (( $# )); then printf '%s\n' "$@" > "${_want}"; else : > "${_want}"; fi
  cmp -- "${_want}" "${_f}" \
    || fail "$(printf 'the bytes of %s differ\nwant:\n%s\ngot:\n%s' "${_f}" \
         "$(od -c -- "${_want}")" "$(od -c -- "${_f}" 2>&1)")"
}

# _stub <command> <exit> -- a <command> on ${STUB_BIN} that prints nothing
# and exits <exit>, standing in for a step of the commit that fails.
_stub() {
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"
  printf '#!/bin/sh\nexit %s\n' "${2}" > "${STUB_BIN}/${1}"
  chmod +x "${STUB_BIN}/${1}"
}

# _foo_pin -- a Dockerfile pin with a line after it, mode 664, tree snapped.
_foo_pin() {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3' \
    'RUN true'
  chmod 664 "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _tree_snap
}

# why: The rewritten line once went through `awk -v repl=...`, which
# expands backslash escapes, so a preserved comment holding `\n` was split
# into two lines and the go.mod corrupted before the read-back ran (review
# round 3, base#1463). The line is written byte for byte.
@test "pins: --set keeps a literal backslash in a go.mod comment byte for byte (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0 // literal \n text \\ end' \
    'require golang.org/x/net v0.30.0'
  _golang_pin
  _stub docker 0
  _pins_json --set xmod v0.22.0
  assert_success
  run cat "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output "$(printf '%s\n' 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.22.0 // literal \n text \\ end' \
    'require golang.org/x/net v0.30.0')"
  assert_equal "$(wc -l < "${SCRATCH}/dockerfile/config-gen/go.mod")" 4
}

# why: The same awk carried every rewrite, so a Dockerfile comment with a
# backslash was mangled the same way (base#1463).
@test "pins: --set keeps a literal backslash in a Dockerfile comment byte for byte (base#1463)" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3  # held: C:\temp \t x' \
    'RUN true'
  _pins --set foo 1.3.0
  assert_success
  run cat "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_output "$(printf '%s\n' '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.3.0  # held: C:\temp \t x' 'RUN true')"
}

# why: The last line of a file with no final newline stays without one: the
# splice changes the version and nothing else (base#1463).
@test "pins: --set on a last line with no final newline adds none (base#1463)" {
  printf '# tool-pin: foo github-release owner/foo\nARG FOO_VERSION=1.2.3' \
    > "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _pins --set foo 1.3.0
  assert_success
  printf '# tool-pin: foo github-release owner/foo\nARG FOO_VERSION=1.3.0' \
    > "${BATS_TEST_TMPDIR}/want"
  cmp -- "${BATS_TEST_TMPDIR}/want" "${SCRATCH}/dockerfile/Dockerfile.test-tools" \
    || fail "the rewrite did not keep the missing final newline: $(od -c -- "${SCRATCH}/dockerfile/Dockerfile.test-tools")"
}

# why: A write through a symlink edits a file outside the tree the reader
# named; the bump refuses it by name and touches neither the link nor its
# target (base#1463). The reader takes only blobs from the index, so the
# link is the working-tree file under a path the index still records as
# a regular file -- staged first, then swapped for the link.
@test "pins: --set refuses a symlinked destination and leaves its target alone (base#1463)" {
  local _t="${BATS_TEST_TMPDIR}/ext/target"
  mkdir -p "${BATS_TEST_TMPDIR}/ext"
  _dockerfile '# tool-pin: foo github-release owner/foo' 'ARG FOO_VERSION=1.2.3'
  git -C "${SCRATCH}" add -A
  mv "${SCRATCH}/dockerfile/Dockerfile.test-tools" "${_t}"
  chmod 664 "${_t}"
  ln -s "${_t}" "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _tree_snap
  _pins_json_unstaged --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=symlink
  [[ -L "${SCRATCH}/dockerfile/Dockerfile.test-tools" ]] || fail "the symlink was replaced"
  _assert_tree_delta
  _assert_bytes "${_t}" '# tool-pin: foo github-release owner/foo' 'ARG FOO_VERSION=1.2.3'
  run stat -c '%a' -- "${_t}"
  assert_output 664
}

# why: Replacing one name of a hard-linked file splits the link and leaves
# the other name on the old version; refused by name (base#1463).
@test "pins: --set refuses a hard-linked destination and leaves it alone (base#1463)" {
  _foo_pin
  ln "${SCRATCH}/dockerfile/Dockerfile.test-tools" "${BATS_TEST_TMPDIR}/hardlink"
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=hard_link
  _assert_tree_delta
}

# why: The temp copy lives beside the destination so the final mv is one
# rename; a directory that cannot hold it refuses before anything is
# written (base#1463).
@test "pins: --set that cannot create its temp copy leaves the file alone (base#1463)" {
  _foo_pin
  _stub mktemp 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=temp_create
  _assert_tree_delta
}

# why: The injected write failure: a temp copy that could not be written is
# never moved over the destination (base#1463).
@test "pins: --set whose temp write fails leaves the file's bytes and mode alone (base#1463)" {
  _foo_pin
  _stub head 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=write_failed
  _assert_tree_delta
}

# why: The temp copy is held to the splice before it lands: everything but
# the target line byte-identical, the target line exactly the new one. A
# write that exited 0 but lost the lines after the target (a `tail` that
# printed nothing) is refused, not moved into place (base#1463).
@test "pins: --set whose temp copy is not the exact splice leaves the file alone (base#1463)" {
  _foo_pin
  _stub tail 0
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=check_failed
  _assert_tree_delta
}

# why: mktemp creates 0600; a copy whose mode could not be set to the
# destination's is not moved over it (base#1463).
@test "pins: --set that cannot carry the mode onto its temp copy leaves the file alone (base#1463)" {
  _foo_pin
  _stub chmod 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=mode_failed
  _assert_tree_delta
}

# why: The rename is the commit; one that fails leaves the old file and no
# temp copy behind (base#1463).
@test "pins: --set whose final rename fails leaves the file alone (base#1463)" {
  _foo_pin
  _stub mv 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=commit_failed
  _assert_tree_delta
}

# _golang_pin -- the scratch config-gen Dockerfile with the golang pin
# marker and the line under it, copied from dockerfile/Dockerfile.config-gen.
_golang_pin() {
  printf '%s\n' \
    '# tool-pin: golang dockerhub library/golang pattern=^1\.[0-9]+\.[0-9]+-trixie$' \
    'ARG GO_IMAGE=golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e' \
    > "${SCRATCH}/dockerfile/Dockerfile.config-gen"
}

# why: The tidy runs on a copy of the module and its go.mod is compared,
# by `go mod edit -json`, to the staged one before go.sum is taken; a tidy
# that would also rewrite go.mod (container exit 3) is its own refusal,
# not a failed tidy, and neither file is written (base#1440).
@test "pins: --set on a go.mod require whose tidy would rewrite go.mod is go_sum_semantic (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 3
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_f}" reason=go_sum_semantic
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
}

# why: go.sum is regenerated in the image the golang pin names; with no
# golang pin there is no image to run, and committing the go.mod bump alone
# would leave go.sum stale, so the bump is refused before docker is called
# and neither file is written (base#1440).
@test "pins: --set on a go.mod require with no golang pin is golang_pin_missing (base#1440)" {
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\necho "docker $*" >> %s\nexit 0\n' "${_log}" \
    > "${STUB_BIN}/docker"
  : > "${_log}"
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_f}" reason=golang_pin_missing
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
  _assert_bytes "${_log}"
}

# why: A module whose tidied go.sum would be empty has none: measured in the
# pinned golang image, `go mod tidy` on a dependency-free module exits 0 and
# leaves no go.sum. The container says so with exit 5 (`test -f go.sum ||
# exit 5`); the bump then commits go.mod and removes the go.sum that is
# there, rather than refusing or keeping a stale one (base#1440).
@test "pins: --set on a go.mod require whose tidy wants no go.sum removes go.sum (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0 // keep me'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  _stub docker 5
  _tree_snap
  _pins_json --set xmod v0.22.0
  assert_success
  _assert_tree_delta "~${_f}" "-${_sum}"
  _assert_bytes "${_f}" 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.22.0 // keep me'
}

# why: When the tidied module wants no go.sum, removing the old go.sum is
# part of the same commit as the go.mod bump: if that removal fails, go.mod
# is put back, so the tree never holds the bumped go.mod beside the go.sum
# of the old one. The rm and mv stubs fail the first call that names a file
# called go.sum (whichever of the two the commit removes it with) and pass
# every other call to the real command, so a rollback that renames go.sum
# back is let through. Both files keep their bytes and no temp or backup
# copy is left beside them (base#1440).
@test "pins: --set on a go.mod require whose tidy wants no go.sum and whose go.sum removal fails leaves go.mod and go.sum alone (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  local _log="${BATS_TEST_TMPDIR}/gosum.log" _cmd _real
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 5
  : > "${_log}"
  for _cmd in rm mv; do
    _real="$(command -v "${_cmd}")"
    cat > "${STUB_BIN}/${_cmd}" <<STUB
#!/bin/sh
for _a; do
  if [ "\${_a##*/}" = go.sum ] && ! grep -qx failed "${_log}"; then
    echo failed >> "${_log}"
    exit 1
  fi
done
exec "${_real}" "\$@"
STUB
    chmod +x "${STUB_BIN}/${_cmd}"
  done
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused reason=commit_failed
  grep -qx failed "${_log}" || fail "no rm or mv of go.sum was failed"
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
}

# why: The module goes to the container as a tar of paths relative to the
# module directory, and the container script checks `test -f go.mod ||
# exit 4` before it tidies. Exit 4 means the archive did not land as a
# module (no go.mod at the top of /tmp/w): a layout fault, its own refusal
# rather than a failed tidy, and neither file is written (base#1440).
@test "pins: --set on a go.mod require whose module archive has no go.mod is go_sum_layout (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 4
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_f}" reason=go_sum_layout
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
}

# _stub_go_container <verify-exit> -- a docker on ${STUB_BIN} that runs the
# container script pins.sh hands it (its `-c` argument) on this host with
# /bin/sh, every `/tmp/` in it moved under ${BATS_TEST_TMPDIR}/ctr, the
# module tar on its stdin, and a `go` first on its PATH. That go appends
# each call to ${BATS_TEST_TMPDIR}/go.log; `mod tidy` writes the one-line
# `h1:new=` go.sum, `mod edit -json [<file>]` prints <file> (or go.mod), and
# `mod verify` prints `all modules verified` and exits <verify-exit>. The
# script's own steps are what runs, so a step it drops is a step the log
# lacks (review round 2, base#1440).
_stub_go_container() {
  local _ctr="${BATS_TEST_TMPDIR}/ctr" _gobin="${BATS_TEST_TMPDIR}/gobin"
  local _log="${BATS_TEST_TMPDIR}/go.log"
  mkdir -p "${STUB_BIN}" "${_ctr}" "${_gobin}"
  : > "${_log}"
  cat > "${_gobin}/go" <<STUB
#!/bin/sh
echo "go \$*" >> "${_log}"
case "\$1 \$2" in
  'mod tidy') printf 'golang.org/x/mod v0.22.0 h1:new=\n' > go.sum ;;
  'mod edit') cat -- "\${4:-go.mod}" ;;
  'mod verify') echo 'all modules verified'; exit ${1} ;;
  *) exit 99 ;;
esac
STUB
  cat > "${STUB_BIN}/docker" <<STUB
#!/bin/sh
_script=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -c ]; then _script="\$2"; shift; fi
  shift
done
_script="\$(printf '%s' "\${_script}" | sed 's#/tmp/#${_ctr}/#g')"
PATH="${_gobin}:\${PATH}" exec /bin/sh -c "\${_script}"
STUB
  chmod +x "${_gobin}/go" "${STUB_BIN}/docker"
}

# why: The container script runs `go mod verify` after the tidy, before it
# hands go.sum back. Deleting that step once left every other spec green: the docker stubs print a go.sum
# and never run the script, and the real-image step only checks go.sum,
# go.mod and a build. Here the script itself runs: verify is called after
# the tidy, and its `all modules verified` stays off go.sum (review round
# 2, base#1440).
@test "pins: --set on a go.mod require runs go mod verify after the tidy and keeps its output off go.sum (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  _stub_go_container 0
  _tree_snap
  _pins_json --set xmod v0.22.0
  assert_success
  _assert_tree_delta "~${_f}" "~${_sum}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/go.log")" "go mod tidy
go mod edit -json ${BATS_TEST_TMPDIR}/ctr/go.mod.staged
go mod edit -json
go mod verify"
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.22.0 h1:new='
  _assert_bytes "${_f}" 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.22.0'
}

# why: A `go mod verify` that fails refuses the bump: go_sum_tidy, go.mod
# and go.sum byte for byte as they were, no temp copy beside them. The log
# shows verify was the step that failed, after a tidy that passed (review
# round 2, base#1440).
@test "pins: --set on a go.mod require whose go mod verify fails is go_sum_tidy and changes no byte (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  _stub_go_container 1
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_f}" reason=go_sum_tidy
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
  assert_equal "$(tail -n 1 "${BATS_TEST_TMPDIR}/go.log")" 'go mod verify'
}

# _stub_chmod_fails_on_go_sum_copy -- a chmod on ${STUB_BIN} that fails
# when it names a file holding the go.sum the docker stub produced (the
# `h1:new=` checksum line) and runs the real chmod on anything else, so
# only the mode step of the new go.sum fails, whatever its temp copy is
# called (review round 1, base#1440).
_stub_chmod_fails_on_go_sum_copy() {
  local _real
  _real="$(command -v chmod)"
  mkdir -p "${STUB_BIN}"
  cat > "${STUB_BIN}/chmod" <<STUB
#!/bin/sh
for _a; do
  [ -f "\${_a}" ] && grep -q 'h1:new=' -- "\${_a}" && exit 1
done
exec "${_real}" "\$@"
STUB
  "${_real}" +x "${STUB_BIN}/chmod"
}

# why: mktemp creates the go.sum copy 0600, and the bump gives it go.sum's
# mode (or 644 for a new go.sum) before it is renamed. A chmod that fails
# there was once unchecked, so the bump committed a 0600 go.sum; it is
# mode_failed for go.sum, before either file is written, and no temp copy
# is left beside them (review round 2, base#1440).
@test "pins: --set on a go.mod require whose go.sum copy cannot take go.sum's mode is mode_failed and changes no byte (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}" "${_sum}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\ncat > /dev/null\nprintf "golang.org/x/mod v0.22.0 h1:new=\\n"\n' \
    > "${STUB_BIN}/docker"
  _stub_chmod_fails_on_go_sum_copy
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_sum}" reason=mode_failed
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
  assert_equal "$(stat -c '%a' -- "${_sum}")" 664
}

# why: The same mode step for a module that has no go.sum yet: the new
# go.sum would be committed 0600, so the bump is mode_failed and no go.sum
# appears (review round 2, base#1440).
@test "pins: --set on a go.mod require with no go.sum whose new go.sum cannot be given a mode is mode_failed and changes no byte (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\ncat > /dev/null\nprintf "golang.org/x/mod v0.22.0 h1:new=\\n"\n' \
    > "${STUB_BIN}/docker"
  _stub_chmod_fails_on_go_sum_copy
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_sum}" reason=mode_failed
  _assert_tree_delta
  [[ ! -e "${_sum}" ]] || fail "a go.sum appeared: $(cat "${_sum}")"
}

# _assert_set_refused_untouched <event> <line> <reason> <go.mod line>...
#
# `--set xmod v0.22.0` on a config-gen go.mod of those lines, under the
# golang pin, with a go.sum beside it and a docker stub that logs every
# call: refused by <event> at <line> for <reason>, docker never called,
# go.mod and go.sum byte for byte as they were, and nothing left beside
# them. A scanner refusal alone cannot show this: a bump path that went
# around the reader would edit the requirement anyway.
_assert_set_refused_untouched() {
  local _event="${1}" _line="${2}" _reason="${3}"
  shift 3
  _golang_pin
  _gomod "$@"
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\necho "docker $*" >> %s\nexit 0\n' "${_log}" \
    > "${STUB_BIN}/docker"
  : > "${_log}"
  _pins_json --set xmod v0.22.0
  assert_refusal 1 "${_event}" "file=${_f}" "line=${_line}" "reason=${_reason}"
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
  _assert_bytes "${_log}"
}

# why: An indirect requirement is not a declaration this repo makes, so the
# reader refuses it (base#1463); a bump of a marker on one is refused the
# same way, before docker runs, and go.mod and go.sum keep every byte
# (base#1440).
@test "pins: --set on an indirect go.mod requirement is refused and changes no byte (base#1440)" {
  _assert_set_refused_untouched go_mod_indirect_requirement 6 indirect \
    'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0 // indirect'
}

# why: A replace directive decides which version builds, so bumping the
# require it overrides would change nothing Go uses; refused by name, no
# byte changed (base#1440).
@test "pins: --set on a go.mod with a replace directive is refused and changes no byte (base#1440)" {
  _assert_set_refused_untouched go_mod_unsupported_syntax 8 replace \
    'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0' '' \
    'replace golang.org/x/mod => golang.org/x/mod v0.20.0'
}

# why: A require block with no closing paren is a go.mod Go rejects; a bump
# of an entry inside it is refused at the line that opens the block, no
# byte changed (base#1440).
@test "pins: --set on a go.mod with an unterminated require block is refused and changes no byte (base#1440)" {
  _assert_set_refused_untouched go_mod_unsupported_syntax 5 unterminated_block \
    'module example.com/m' '' 'go 1.27' '' 'require (' \
    '	// tool-pin: xmod github-release golang/mod' \
    '	golang.org/x/mod v0.21.0'
}

# why: A hard-linked go.mod is refused by name, like any hard-linked
# destination (base#1463), and the refusal comes before the module is sent
# to the golang image: a link check that ran only after staging would pay
# for a tidy whose go.sum is then thrown away. Docker is never called,
# neither file is written and no temp copy is left beside them (base#1440).
@test "pins: --set on a hard-linked go.mod is hard_link before docker is called (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  ln "${_f}" "${BATS_TEST_TMPDIR}/hardlink"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\necho "docker $*" >> %s\nexit 0\n' "${_log}" \
    > "${STUB_BIN}/docker"
  : > "${_log}"
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused "file=${_f}" reason=hard_link
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
  _assert_bytes "${_log}"
}

# why: go.mod and go.sum are committed as one: when the rename of the
# second of the two fails, the first is rolled back, so the tree never
# holds the bumped go.mod beside the old go.sum (or the new go.sum beside
# the old go.mod). The mv stub passes every rename through to the real mv
# except the first rename onto the go.mod/go.sum name not yet renamed onto,
# so the failure lands on the second whichever order the commit uses, and
# a rollback rename back onto the first name is let through. Both files
# keep their bytes and no temp or backup copy is left (base#1440).
@test "pins: --set on a go.mod require whose second rename fails leaves go.mod and go.sum alone (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  local _log="${BATS_TEST_TMPDIR}/mv.log" _real_mv
  _real_mv="$(command -v mv)"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  chmod 664 "${_f}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\ncat > /dev/null\nprintf "golang.org/x/mod v0.22.0 h1:new=\\n"\n' \
    > "${STUB_BIN}/docker"
  : > "${_log}"
  cat > "${STUB_BIN}/mv" <<STUB
#!/bin/sh
for _d; do :; done
_b="\${_d##*/}"
case "\${_b}" in
  go.mod|go.sum)
    if ! grep -qx failed "${_log}" && [ -s "${_log}" ] \\
        && ! grep -qx "\${_b}" "${_log}"; then
      echo failed >> "${_log}"
      exit 1
    fi
    "${_real_mv}" "\$@" || exit \$?
    grep -qx failed "${_log}" || echo "\${_b}" >> "${_log}"
    exit 0 ;;
esac
exec "${_real_mv}" "\$@"
STUB
  chmod +x "${STUB_BIN}/mv"
  _pins_json --set xmod v0.22.0
  assert_refusal 1 pin_set_refused reason=commit_failed
  grep -qx failed "${_log}" || fail "no rename onto go.mod/go.sum was failed: $(cat "${_log}")"
  _assert_tree_delta
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
}

# _stub_fail_go_sum_then_go_mod <cmd>... -- each <cmd> (rm, mv) on
# ${STUB_BIN}: the first call that names a file called go.sum fails, every
# mv onto go.mod after that fails too, and any other call runs the real
# command. So the go.sum step of a go.mod bump fails and so does the
# rollback rename that would put go.mod back, whatever the backup is called.
_stub_fail_go_sum_then_go_mod() {
  local _log="${BATS_TEST_TMPDIR}/fail.log" _cmd _real
  : > "${_log}"
  for _cmd in "$@"; do
    _real="$(command -v "${_cmd}")"
    cat > "${STUB_BIN}/${_cmd}" <<STUB
#!/bin/sh
for _a; do
  if [ "\${_a##*/}" = go.sum ] && ! grep -qx failed "${_log}"; then
    echo failed >> "${_log}"
    exit 1
  fi
done
if [ "${_cmd}" = mv ] && grep -qx failed "${_log}"; then
  for _d; do :; done
  if [ "\${_d##*/}" = go.mod ]; then
    echo go.mod >> "${_log}"
    exit 1
  fi
fi
exec "${_real}" "\$@"
STUB
    chmod +x "${STUB_BIN}/${_cmd}"
  done
}

# _rollback_copy <file> -- the copy= attribute of the rollback_failed
# refusal for <file> in ${stderr}, the public name of the kept copy; fails
# when no such refusal carries one.
_rollback_copy() {
  local _line _re='"copy":"([^"\\]*)"'
  while IFS= read -r _line; do
    [[ "${_line}" == *'"reason":"rollback_failed"'* \
       && "${_line}" == *"\"file\":\"${1}\""* && "${_line}" =~ ${_re} ]] || continue
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  done <<< "${stderr}"
  fail "no rollback_failed refusal for ${1} names its copy: ${stderr}"
}

# _assert_rollback_failed_kept <go.mod> -- after a go.mod bump whose go.sum
# step and go.mod rollback both failed: the refusal is rollback_failed for
# go.mod, never a commit_failed claiming go.mod was put back. The tree
# differs from the snapshot by exactly the copy the refusal names (added,
# holding go.mod's old bytes) and go.mod (rewritten, holding the bump).
_assert_rollback_failed_kept() {
  local _f="${1}" _copy
  assert_refusal 1 pin_set_refused "file=${_f}" reason=rollback_failed
  grep -qx go.mod "${BATS_TEST_TMPDIR}/fail.log" \
    || fail "no rollback rename onto go.mod was failed: $(cat "${BATS_TEST_TMPDIR}/fail.log")"
  [[ "${stderr}" != *'was put back'* ]] || fail "a refusal claims a file was put back: ${stderr}"
  _copy="$(_rollback_copy "${_f}")"
  [[ -n "${_copy}" ]] || fail "the rollback_failed refusal names no copy: ${stderr}"
  _assert_tree_delta "+${_copy}" "~${_f}"
  _assert_bytes "${_copy}" 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  _assert_bytes "${_f}" 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.22.0'
}

# why: When the go.sum rename of a go.mod bump fails, go.mod is put back
# from a copy; when that rename fails too, the tree holds the bumped go.mod
# beside the old go.sum, and a refusal saying go.mod was put back is false.
# The refusal is rollback_failed, it names the copy that still holds the old
# go.mod, and that copy is kept (review round 1, base#1440).
@test "pins: --set on a go.mod require whose go.sum rename and go.mod rollback fail is rollback_failed and keeps the copy (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  _tree_snap
  _stub docker 0
  printf '#!/bin/sh\ncat > /dev/null\nprintf "golang.org/x/mod v0.22.0 h1:new=\\n"\n' \
    > "${STUB_BIN}/docker"
  _stub_fail_go_sum_then_go_mod mv
  _pins_json --set xmod v0.22.0
  _assert_rollback_failed_kept "${_f}"
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
}

# why: The same rollback on the other go.sum step: the tidied module wants
# no go.sum (container exit 5), the old go.sum cannot be removed, and the
# rename that would put go.mod back fails. rollback_failed, the copy named
# and kept (review round 1, base#1440).
@test "pins: --set on a go.mod require whose go.sum removal and go.mod rollback fail is rollback_failed and keeps the copy (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  local _sum="${SCRATCH}/dockerfile/config-gen/go.sum"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_sum}"
  _tree_snap
  _stub docker 5
  _stub_fail_go_sum_then_go_mod rm mv
  _pins_json --set xmod v0.22.0
  _assert_rollback_failed_kept "${_f}"
  _assert_bytes "${_sum}" 'golang.org/x/mod v0.21.0 h1:old='
}

# why: A golang minor bump moves the Go that builds every module, so the
# `go` directive of each tracked go.mod moves with it, and each go.sum is
# regenerated in the PROPOSED image, not the one being replaced: rewriting
# the Dockerfile alone leaves every go.mod naming the old minor, which the
# directive check then refuses. The docker stub stands in for the image: it
# logs each call as one line (newlines in its arguments folded to spaces, so
# the log counts calls), answers a module that requires golang.org/x/mod
# with one go.sum line, and a dependency-free module with exit 5 (tidy
# leaves no go.sum, as measured in the pinned image). Both go.mod files end up with
# `go 1.28`, m keeps a go.sum of the stub's line, m2 still has none, and
# docker ran exactly twice, both times in golang:1.28.0-trixie (base#1440).
@test "pins: --set golang to another minor rewrites every go.mod go line and go.sum in the proposed image (base#1440)" {
  _golang_pin
  local _m="${SCRATCH}/m" _m2="${SCRATCH}/m2"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mkdir -p "${_m}" "${_m2}"
  printf '%s\n' 'module example.com/m' '' 'go 1.27' '' \
    'require golang.org/x/mod v0.21.0' > "${_m}/go.mod"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_m}/go.sum"
  printf '%s\n' 'module example.com/m2' '' 'go 1.27' > "${_m2}/go.mod"
  _stub docker 0
  cat > "${STUB_BIN}/docker" <<STUB
#!/bin/sh
printf 'docker %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "${_log}"
cat > "${BATS_TEST_TMPDIR}/docker.in"
if grep -aq 'golang.org/x/mod' "${BATS_TEST_TMPDIR}/docker.in"; then
  printf 'golang.org/x/mod v0.21.0 h1:new=\n'
  exit 0
fi
exit 5
STUB
  chmod +x "${STUB_BIN}/docker"
  : > "${_log}"
  _tree_snap
  _pins_json --set golang golang:1.28.0-trixie
  assert_success
  _assert_tree_delta "~${SCRATCH}/dockerfile/Dockerfile.config-gen" \
    "~${_m}/go.mod" "~${_m}/go.sum" "~${_m2}/go.mod"
  _assert_bytes "${SCRATCH}/dockerfile/Dockerfile.config-gen" \
    '# tool-pin: golang dockerhub library/golang pattern=^1\.[0-9]+\.[0-9]+-trixie$' \
    'ARG GO_IMAGE=golang:1.28.0-trixie'
  _assert_bytes "${_m}/go.mod" 'module example.com/m' '' 'go 1.28' '' \
    'require golang.org/x/mod v0.21.0'
  _assert_bytes "${_m}/go.sum" 'golang.org/x/mod v0.21.0 h1:new='
  _assert_bytes "${_m2}/go.mod" 'module example.com/m2' '' 'go 1.28'
  assert_equal "$(wc -l < "${_log}")" 2
  assert_equal "$(grep -c ' golang:1.28.0-trixie ' "${_log}")" 2
  run grep -c '1\.27\.2' "${_log}"
  assert_output 0
}

# _minor_modules -- two tracked modules beside the golang pin, each with a
# go.sum: ${SCRATCH}/m requires golang.org/x/mod, ${SCRATCH}/m2
# golang.org/x/text, both at `go 1.27`.
_minor_modules() {
  mkdir -p "${SCRATCH}/m" "${SCRATCH}/m2"
  printf '%s\n' 'module example.com/m' '' 'go 1.27' '' \
    'require golang.org/x/mod v0.21.0' > "${SCRATCH}/m/go.mod"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${SCRATCH}/m/go.sum"
  printf '%s\n' 'module example.com/m2' '' 'go 1.27' '' \
    'require golang.org/x/text v0.20.0' > "${SCRATCH}/m2/go.mod"
  printf 'golang.org/x/text v0.20.0 h1:old=\n' > "${SCRATCH}/m2/go.sum"
}

# _assert_minor_modules_untouched -- after a refused golang minor bump over
# _minor_modules: the Dockerfile and all four module files hold their
# literal fixture bytes, and the tree equals the one _tree_snap recorded.
_assert_minor_modules_untouched() {
  _assert_bytes "${SCRATCH}/dockerfile/Dockerfile.config-gen" \
    '# tool-pin: golang dockerhub library/golang pattern=^1\.[0-9]+\.[0-9]+-trixie$' \
    'ARG GO_IMAGE=golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e'
  _assert_bytes "${SCRATCH}/m/go.mod" 'module example.com/m' '' \
    'go 1.27' '' 'require golang.org/x/mod v0.21.0'
  _assert_bytes "${SCRATCH}/m/go.sum" 'golang.org/x/mod v0.21.0 h1:old='
  _assert_bytes "${SCRATCH}/m2/go.mod" 'module example.com/m2' '' \
    'go 1.27' '' 'require golang.org/x/text v0.20.0'
  _assert_bytes "${SCRATCH}/m2/go.sum" 'golang.org/x/text v0.20.0 h1:old='
  _assert_tree_delta
}

# why: A golang minor bump is one change to the Dockerfile and every go.mod
# and go.sum it moves. Committing module m and then failing on m2 leaves m
# saying `go 1.28` under a golang:1.27.2 pin. A tidy that fails on the
# second module (the stub exits 1 for m2) is go_sum_tidy, and all five
# files keep their literal bytes, with no temp or backup copy left beside
# any of them (base#1440).
@test "pins: --set golang to another minor whose second module's tidy fails leaves every file alone (base#1440)" {
  _golang_pin
  _minor_modules
  _stub docker 0
  cat > "${STUB_BIN}/docker" <<STUB
#!/bin/sh
cat > "${BATS_TEST_TMPDIR}/docker.in"
if grep -aq 'example.com/m2' "${BATS_TEST_TMPDIR}/docker.in"; then
  exit 1
fi
printf 'golang.org/x/mod v0.21.0 h1:new=\n'
STUB
  chmod +x "${STUB_BIN}/docker"
  _tree_snap
  _pins_json --set golang golang:1.28.0-trixie
  assert_refusal 1 pin_set_refused reason=go_sum_tidy
  _assert_minor_modules_untouched
}

# why: A golang minor bump rewrites the `go` directive of every tracked
# go.mod; a tracked go.mod with no `go` directive has no line to move, and
# skipping it would commit a Dockerfile the directive check then refuses
# for that module (go=-). The bump is refused as go_directive_missing
# before docker is called, and the Dockerfile and both modules keep their
# literal bytes (base#1440).
@test "pins: --set golang to another minor with a tracked go.mod that has no go line is go_directive_missing (base#1440)" {
  _golang_pin
  local _m="${SCRATCH}/m" _m2="${SCRATCH}/m2"
  local _df="${SCRATCH}/dockerfile/Dockerfile.config-gen"
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mkdir -p "${_m}" "${_m2}"
  printf '%s\n' 'module example.com/m' '' 'go 1.27' '' \
    'require golang.org/x/mod v0.21.0' > "${_m}/go.mod"
  printf 'golang.org/x/mod v0.21.0 h1:old=\n' > "${_m}/go.sum"
  printf '%s\n' 'module example.com/m2' > "${_m2}/go.mod"
  _stub docker 0
  printf '#!/bin/sh\necho "docker $*" >> %s\ncat > /dev/null\nprintf "golang.org/x/mod v0.21.0 h1:new=\\n"\n' \
    "${_log}" > "${STUB_BIN}/docker"
  : > "${_log}"
  _tree_snap
  _pins_json --set golang golang:1.28.0-trixie
  assert_refusal 1 pin_set_refused "file=${_m2}/go.mod" reason=go_directive_missing
  _assert_bytes "${_log}"
  _assert_bytes "${_df}" \
    '# tool-pin: golang dockerhub library/golang pattern=^1\.[0-9]+\.[0-9]+-trixie$' \
    'ARG GO_IMAGE=golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e'
  _assert_bytes "${_m}/go.mod" 'module example.com/m' '' \
    'go 1.27' '' 'require golang.org/x/mod v0.21.0'
  _assert_bytes "${_m}/go.sum" 'golang.org/x/mod v0.21.0 h1:old='
  _assert_bytes "${_m2}/go.mod" 'module example.com/m2'
  _assert_tree_delta
}

# why: A golang minor bump commits every go.mod, every go.sum and the
# Dockerfile as one change. The Dockerfile is the last file renamed; when
# that rename fails, a commit that has already put `go 1.28` and the new
# go.sum into each module leaves them under a golang:1.27.2 pin, which the
# directive check then refuses. The mv stub fails only the rename onto
# Dockerfile.config-gen and passes every other rename to the real mv. The
# bump is commit_failed, all five files keep their literal bytes, and no
# temp or backup copy is left beside any of them (base#1440).
@test "pins: --set golang to another minor whose Dockerfile rename fails leaves every file alone (base#1440)" {
  _golang_pin
  local _real_mv
  _real_mv="$(command -v mv)"
  _minor_modules
  _stub docker 0
  cat > "${STUB_BIN}/docker" <<STUB
#!/bin/sh
cat > "${BATS_TEST_TMPDIR}/docker.in"
if grep -aq 'example.com/m2' "${BATS_TEST_TMPDIR}/docker.in"; then
  printf 'golang.org/x/text v0.20.0 h1:new=\n'
  exit 0
fi
printf 'golang.org/x/mod v0.21.0 h1:new=\n'
STUB
  chmod +x "${STUB_BIN}/docker"
  cat > "${STUB_BIN}/mv" <<STUB
#!/bin/sh
for _d; do :; done
case "\${_d##*/}" in
  Dockerfile.config-gen) exit 1 ;;
esac
exec "${_real_mv}" "\$@"
STUB
  chmod +x "${STUB_BIN}/mv"
  _tree_snap
  _pins_json --set golang golang:1.28.0-trixie
  assert_refusal 1 pin_set_refused reason=commit_failed
  _assert_minor_modules_untouched
}

# why: A golang minor bump whose last rename fails puts every module back
# from the copies it took before the first commit. When one of those
# restores fails too, the tree holds `go 1.28` in m2 under the old golang
# pin and the copy is the only record of m2's go.mod as it was, so it must
# stay, and the refusal must say the tree was NOT put back rather than
# report an ordinary commit_failed. The mv stub fails the rename onto
# Dockerfile.config-gen and, after it, every rename onto m2/go.mod (the
# restore), and passes every other rename to the real mv. The bump is
# rollback_failed, and a copy beside m2/go.mod still holds its literal
# old bytes (base#1440).
@test "pins: --set golang to another minor whose rollback fails is rollback_failed and keeps the backup (base#1440)" {
  _golang_pin
  local _m2="${SCRATCH}/m2" _real_mv _bak
  _real_mv="$(command -v mv)"
  _minor_modules
  _stub docker 0
  cat > "${STUB_BIN}/docker" <<STUB
#!/bin/sh
cat > "${BATS_TEST_TMPDIR}/docker.in"
if grep -aq 'example.com/m2' "${BATS_TEST_TMPDIR}/docker.in"; then
  printf 'golang.org/x/text v0.20.0 h1:new=\n'
  exit 0
fi
printf 'golang.org/x/mod v0.21.0 h1:new=\n'
STUB
  chmod +x "${STUB_BIN}/docker"
  cat > "${STUB_BIN}/mv" <<STUB
#!/bin/sh
for _d; do :; done
case "\${_d##*/}" in
  Dockerfile.config-gen) : > "${BATS_TEST_TMPDIR}/df.failed"; exit 1 ;;
esac
if [ "\${_d}" = "${_m2}/go.mod" ] && [ -e "${BATS_TEST_TMPDIR}/df.failed" ]; then
  exit 1
fi
exec "${_real_mv}" "\$@"
STUB
  chmod +x "${STUB_BIN}/mv"
  _tree_snap
  _pins_json --set golang golang:1.28.0-trixie
  assert_refusal 1 pin_set_refused "file=${_m2}/go.mod" reason=rollback_failed
  _bak="$(_rollback_copy "${_m2}/go.mod")"
  [[ -n "${_bak}" ]] || fail "the rollback_failed refusal names no copy: ${stderr}"
  _assert_tree_delta "+${_bak}" "~${_m2}/go.mod"
  _assert_bytes "${_bak}" 'module example.com/m2' '' \
    'go 1.27' '' 'require golang.org/x/text v0.20.0'
  _assert_bytes "${_m2}/go.mod" 'module example.com/m2' '' \
    'go 1.28' '' 'require golang.org/x/text v0.20.0'
}

# why: A go.mod `go` directive names the Go a module needs; the golang pin
# names the Go that builds it. Nothing compared the two, so `go 1.26` under
# golang:1.27.2 passed the watch unseen. _pin_go_directive_check compares
# them by major.minor and refuses a mismatch by name, with both sides and
# the directive's line (base#1440).
@test "_pin_go_directive_check: go 1.26 under golang:1.27.2-trixie is go_mod_go_directive_mismatch (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m' '' 'go 1.26'
  git -C "${SCRATCH}" add -A
  # shellcheck disable=SC1091
  source /source/script/watch/lib.sh
  export LOG_FORMAT=json
  run --separate-stderr _pin_go_directive_check "${SCRATCH}"
  assert_refusal 1 go_mod_go_directive_mismatch \
    dockerfile/config-gen/go.mod go=1.26 golang=1.27 line=3
}

# why: A go.mod with no `go` directive is not "nothing to compare": Go then
# assumes go 1.16 for the module, which no golang pin of this repo builds.
# Skipping the file let such a module pass the watch unseen, so it is a
# mismatch named with go=- and line=0 (base#1440).
@test "_pin_go_directive_check: a go.mod with no go directive is go_mod_go_directive_mismatch go=- (base#1440)" {
  _golang_pin
  _gomod 'module example.com/m'
  git -C "${SCRATCH}" add -A
  # shellcheck disable=SC1091
  source /source/script/watch/lib.sh
  export LOG_FORMAT=json
  run --separate-stderr _pin_go_directive_check "${SCRATCH}"
  assert_refusal 1 go_mod_go_directive_mismatch \
    dockerfile/config-gen/go.mod go=- golang=1.27 line=0
}

# why: With no golang pin there is no Go to compare a `go` directive with.
# Skipping the compare let a tree that dropped its golang pin pass the
# watch with every go.mod unchecked, so a tracked go.mod under no pinned
# golang image is go_mod_golang_pin_missing, named by file (base#1440).
@test "_pin_go_directive_check: a go.mod with no golang pin is go_mod_golang_pin_missing (base#1440)" {
  _foo_pin
  _gomod 'module example.com/m' '' 'go 1.27'
  git -C "${SCRATCH}" add -A
  # shellcheck disable=SC1091
  source /source/script/watch/lib.sh
  export LOG_FORMAT=json
  run --separate-stderr _pin_go_directive_check "${SCRATCH}"
  assert_refusal 1 go_mod_golang_pin_missing dockerfile/config-gen/go.mod
}

# ════════════════════════════════════════════════════════════════════
# Scan roots
# ════════════════════════════════════════════════════════════════════

# why: An empty table read as "this repo declares no pins" is indistinguishable
# from a clean week, which is the one answer the watch must never guess
@test "pins: a tree yielding no scannable file at all FAILS" {
  # An empty table read as "this repo declares no pins" is the one answer
  # the watch must never give by accident: it is indistinguishable from a
  # clean week.
  rm -rf "${SCRATCH:?}"
  mkdir -p "${SCRATCH}/doc"
  git -C "${SCRATCH}" init -q
  printf 'hello\n' > "${SCRATCH}/doc/a.md"
  _pins --list
  assert_failure
  assert_output --partial 'no scannable file'
}

# why: The walk is every tracked file minus the exempt shapes, so what it actually
# opens is the claim worth checking rather than trusting
@test "pins: --files lists every file it walks, prose and specs aside" {
  _dockerfile 'FROM scratch'
  _pins --files
  assert_success
  assert_output --partial 'dockerfile/Dockerfile.test-tools'
  assert_output --partial 'dist/dockerfile/Dockerfile'
  assert_output --partial '.github/workflows/x.yaml'
}

# why: The scan surface is not a roster of directories; it decayed once already,
# with two live pins sitting outside the three original roots
@test "pins: a Dockerfile at a path nothing anticipated is still scanned" {
  # The scan surface is NOT a roster of directories. A hand-kept list of
  # places to look decays exactly the way a hand-kept list of tools does,
  # and it decayed here: two live third-party versions sat outside the
  # original three roots, one of them two minors behind this repo's own
  # pin, written into every downstream repo, with nothing reporting it.
  mkdir -p "${SCRATCH}/somewhere/new/deep"
  printf '%s\n' \
    '# tool-pin: newthing github-release owner/newthing' \
    'ARG NEWTHING_VERSION=1.0.0' \
    > "${SCRATCH}/somewhere/new/deep/Dockerfile.other"
  _pins --value newthing
  assert_success
  assert_output '1.0.0'
}

# why: A uses: ref inside a heredoc is not a workflow file, so nothing but this
# watch can ever see the versions a generator writes
@test "pins: a shell script that generates a file is a declaration site" {
  # dist/script/base/init.sh writes a workflow and dockerfile_migrate.sh
  # seds a downstream Dockerfile. dependabot reads workflow files, and a
  # `uses:` ref inside a heredoc is not one -- so nothing but this watch
  # can ever see those versions.
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    '# tool-pin: gen-bats dockerhub bats/bats pattern=.' \
    "local _bats_tag='1.13.0'" \
    > "${SCRATCH}/dist/script/gen.sh"
  _pins --value gen-bats
  assert_success
  assert_output '1.13.0'
  _pins --set gen-bats 1.14.0
  assert_success
  run grep -F "local _bats_tag='1.14.0'" "${SCRATCH}/dist/script/gen.sh"
  assert_success
}

# why: Every version in a shipped release is supposed to be stale, so a bump inside
# .prev-release/ would be meaningless -- and nothing tracks it
@test "pins: an untracked tree contributes nothing" {
  # `.prev-release/` is `git archive` of PAST releases, materialised for a
  # spec. Every version in it is supposed to be stale, and a bump inside
  # it would be meaningless. It used to be named in a prune roster; it is
  # absent now because nothing tracks it, which is the same verdict with
  # nothing to keep up to date.
  _dockerfile 'FROM scratch'
  _pins --files
  assert_success
  mkdir -p "${SCRATCH}/.prev-release/v0.1.0/dockerfile"
  printf '%s\n' \
    '# tool-pin: ancient github-release owner/ancient' \
    'ARG ANCIENT_VERSION=0.0.1' \
    > "${SCRATCH}/.prev-release/v0.1.0/dockerfile/Dockerfile"
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" --files
  assert_success
  refute_output --partial '.prev-release'
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" --value ancient
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# The resolvers the lint accepts are the resolvers check.sh implements
# ════════════════════════════════════════════════════════════════════

# why: A resolver the lint accepts and check.sh does not implement blesses a pin
# that then fails weeks later, unattended
@test "pins: check.sh dispatches every resolver the registry declares" {
  # The lint rejects an unknown resolver at the declaration site, using
  # _PIN_RESOLVERS. If that table listed a resolver check.sh does not
  # implement, the lint would bless a pin the watch then fails on weeks
  # later, unattended.
  # shellcheck disable=SC1091
  source /source/script/watch/lib.sh
  local _r
  for _r in "${_PIN_RESOLVERS[@]}"; do
    run grep -F "    ${_r})" /source/script/watch/check.sh
    assert_success
  done
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

# why: Otherwise the workflow carries a fourth copy, and a bump moving only the
# Dockerfile leaves CI testing a different just than the image ships
@test "pins: the CI just install reads the pin instead of repeating it" {
  # Without this the workflow would carry a fourth copy of the number, and
  # a bump PR that moved the Dockerfile alone would leave CI testing a
  # different just than the image ships.
  #
  # The reader is the shipped accessor, not pins.sh: both read the
  # SAME line -- the `ARG JUST_VERSION` that the `tool-pin: just` marker
  # sits on is the marker's TARGET, so it is where the pin's value comes
  # from as well. CI resolving the number twice is therefore two chances
  # to disagree about one declaration, not two declarations. base#1075
  # removed the case this paragraph used to point at, which compared the
  # pin against that same ARG line and so asserted one line against
  # itself. What this test is about is that the workflow READS the number
  # rather than repeating it; which of the two readers it uses is not.
  run grep -F 'dist/script/base/just-version.sh' \
    /source/.github/workflows/self-test.yaml
  assert_success
  run grep -F 'just-version: ${{ steps.just-pin.outputs.version }}' \
    /source/.github/workflows/self-test.yaml
  assert_success
}

# why: An unversioned setup-just installs whatever released most recently, so the
# e2e job turns red on a day nobody touched the repo
@test "pins: setup-just is no longer invoked without a just-version" {
  # An unversioned setup-just installs whatever released most recently, so
  # the e2e job turns red on a day nobody touched the repo and the diff
  # that appears to have caused it is unrelated.
  run awk '/uses: extractions\/setup-just/{found=1; next}
           found && /just-version:/{print "pinned"; exit}
           found && /^ *- /{print "unpinned"; exit}' \
    /source/.github/workflows/self-test.yaml
  assert_success
  assert_output 'pinned'
}
