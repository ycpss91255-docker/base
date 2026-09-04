#!/usr/bin/env bash
#
# watch/lib.sh - the pin registry: it reads the declaration sites, it is
# not a list of them.
#
# Sourced library (no main). Provides the marker grammar, the reader that
# derives the watched-tool table from the files that declare each version,
# and the detector that finds a version declaration NOT covered by a
# marker. pins.sh (CLI), check.sh (upstream comparison) and
# script/test/drivers/pin_coverage.sh (the lint) all read this one file.
#
# ── Why derived rather than listed ──────────────────────────────────────────
#
# A hand-maintained roster of "tools we watch" decays the moment somebody
# adds a pin without opening it -- the same failure mode as the downstream
# roster, the release archive's path list and the lint-tool table, each of
# which this repo has already had to convert from a list into a derivation.
# So there is no roster. Every watched version is declared where it is
# USED, on a marker comment attached to the line that names the version,
# and the table is whatever those markers say today.
#
# That alone would still decay in the other direction -- a pin added with
# no marker is invisible, and invisible is exactly the state this whole
# mechanism exists to end. So the derivation is paired with a DETECTOR:
# every line in the scanned trees whose shape is "a third-party version
# this repo names" must be the target of a marker. The pin-coverage lint
# fails the build when one is not. Adding a pin without declaring how to
# watch it is therefore not something a reviewer has to notice.
#
# ── The marker grammar ──────────────────────────────────────────────────────
#
# A marker is a comment line. Its TARGET is the next line that is neither
# blank nor a comment, and the version lives on that target line:
#
#   # tool-pin: <name> <resolver> <coordinate> [pattern=<re>] [skip=<v>,...]
#   ARG FOO_VERSION=1.2.3
#
#   # tool-pin: unpinned <name> -- <why it cannot be pinned here>
#   RUN apk add --no-cache bash git
#
#   # tool-pin: ignore -- <why this is not a third-party version>
#   ARG OURS=1.0
#
# `unpinned` is not an off switch. It is a DECLARATION that this dependency
# floats, and `check.sh` prints every one of them on every run, under its
# own heading, forever. Silence is what the audit found; a floating
# dependency that nobody has to be reminded of is how it got there.
#
# `skip=<v>[,<v>...]` records a version this repo has deliberately refused.
# It exists because of the opposite defect: dependabot never re-raises a
# version pair whose PR was closed, so closing one PR opts the repo out of
# that bump permanently and NOTHING in the config says so. Here the refusal
# is a line in the file that declares the pin, next to the version it
# refuses, visible to the next reader and checked by the lint.
#
# ── Resolvers ───────────────────────────────────────────────────────────────
#
#   github-release <owner>/<repo>   the latest non-prerelease release's tag
#   dockerhub <namespace>/<repo>    the highest tag matching `pattern=`
#
# `pattern=` is a POSIX ERE anchored by the resolver against a whole tag.
# It is what makes "latest alpine" mean the latest 3.x SERIES tag rather
# than `edge` or `latest`, and it is per-pin because what counts as a
# comparable tag is a property of the upstream, not of this repo.

# Sourced more than once in one shell (pins.sh from a spec that has
# already sourced the lint driver, say), the `readonly` declarations below
# would abort the caller. Guard rather than drop the readonly: the
# constants being immutable is what stops a caller from redefining the
# grammar out from under the lint.
if [[ -n "${_PIN_LIB_SOURCED:-}" ]]; then
  return 0
fi
_PIN_LIB_SOURCED=1

# ── Marker vocabulary ───────────────────────────────────────────────────────

# The marker's opening token. One string, so the reader, the lint's
# failure message and the specs cannot spell it three ways.
readonly _PIN_MARKER='tool-pin:'

# A marker is a comment whose BODY OPENS with that token. Prose that
# merely mentions it -- this file, a Dockerfile header explaining the
# convention, a failure message quoting it -- is not a marker. Anchoring
# rather than substring-matching is what lets the mechanism be documented
# in the same trees it scans.
readonly _PIN_MARKER_RE="^[[:space:]]*#+[[:space:]]*${_PIN_MARKER}"

# The three declaration states. `pinned` is comparable against upstream;
# `unpinned` is reported as floating and never compared; `ignore` is "this
# line's shape matched the detector but it is not a third-party version".
readonly _PIN_STATE_PINNED='pinned'
readonly _PIN_STATE_UNPINNED='unpinned'
readonly _PIN_STATE_IGNORE='ignore'

# Every resolver `check.sh` implements. Named here rather than there
# because the LINT has to reject an unknown resolver at the declaration
# site: a typo caught weeks later by a scheduled run is a pin nobody was
# watching in the meantime. A unit spec asserts check.sh dispatches every
# entry.
readonly _PIN_RESOLVERS=(
  github-release
  dockerhub
)

# What is walked: THE FILES THIS REPO TRACKS. There is no list here, and
# that is the point -- see _pin_tracked.
#
# The population went through the same three corrections everything else
# in this file did. It was a roster of scan ROOTS (`dockerfile`,
# `dist/dockerfile`, `.github/workflows`) and two live pins sat outside
# it, both of them versions this repo BAKES INTO FILES IT SHIPS
# DOWNSTREAM. So it inverted: walk the whole checkout, and keep a PRUNE
# roster of trees not to read -- `.git`, `log`, `.prev-release`,
# `.claude` -- with a guard asserting each of them was gitignored and
# untracked, so the roster could not quietly grow to cover something the
# repo ships.
#
# That inversion was right about the direction and wrong about the
# artefact. A prune roster is still hand-kept, and hand-kept lists in this
# mechanism fail the same way every time: correct when written, with
# nothing to notice when the world moves. It moved. `just test coverage`
# writes kcov's HTML report into `coverage/` INSIDE the checkout, so on
# the CI coverage shard -- and on any machine that had run coverage
# locally -- the walk read kcov's own bundled jquery, handlebars and
# `bcov.css`, and reported jQuery's `m="2.1.1"` as an undeclared
# third-party version. Same for the generated-workflow lint, which shares
# this walk: it read a `uses:` line out of a kcov HTML rendering of one of
# this repo's scripts. Adding `coverage` to the roster would have passed,
# and the guard would have accepted it, and the NEXT generated directory
# would have reproduced it exactly.
#
# The roster's own justification says why that was never the fix. It
# exempted `.claude/` because "scanning it would make the lint's verdict
# depend on whose machine it ran on, which is the one thing a gate must
# not do" -- and a leftover `coverage/` is precisely that dependency,
# which the roster did not prevent and could not have.
#
# So the population is DERIVED and the roster is gone. A version in a file
# the repo does not track is not a version this repo declares: nothing
# ships it, nobody pulls it, and it is on this machine by accident.
# `git ls-files` answers that exactly. Both questions the prune guard
# existed to ask -- is this tree ignored, is anything in it tracked --
# dissolve with it, and the one it could not reach is now answered right:
# a force-added tracked file inside an ignored tree IS tracked, so it IS
# scanned.
#
# The failure mode still inverts the safe way. A tree added tomorrow is
# scanned the moment it is STAGED -- `git ls-files` reads the index, not
# a commit, so `just test` sees a new file as soon as `git add` does, one
# step before it could reach a PR -- and it is exempt for exactly as long
# as it is not. There is nothing to forget to edit, and nothing a person
# can edit to make a shipped file stop being read.

# What is NOT read -- and nothing else. This was a list of the shapes a
# declaration MAY live in (`Dockerfile*`, `*.y{a,}ml`, `*.sh`), which is
# the roster failure one level up from the scan roots, with the same
# tell: a justfile is this repo's control surface, 13 are tracked,
# `_pin_is_declaration` answers TRUE for a `docker run` line in one, and
# not one was ever walked. So this inverts too. Forgetting to touch this
# list when a shape arrives means the new shape IS read and the lint
# fires, rather than the new shape being quietly exempt.
#
# Two exemptions, each for a reason that is a property of the SHAPE
# rather than of what happens to sit in it today:
#
#   Prose (`*.md`, `*.adoc`, `README`, `LICENSE`). Nothing executes it. A
#   document QUOTES `docker run --rm alpine:3.21` -- that is what a
#   document is for -- and a version in one is stale the way a sentence
#   is stale, which is a doc-review problem and not a supply-chain one.
#
#   `*.bats`. A spec's heredoc IS the fixture the code under test parses,
#   and the marker grammar cannot reach inside one: a marker's target is
#   the next non-comment line, so declaring a fixture's `FROM` means
#   inserting a comment INTO the fixture and changing what the test feeds
#   its subject. That is the grammar, not a preference. Some 60 lines
#   here spell `FROM ubuntu:24.04` for a Dockerfile parser to read, and
#   demanding an `ignore` marker on each would teach every reader to
#   reach for `ignore` first.
#
#   What that second one costs is real and bounded, and is recorded here
#   because it is the next reader's question: two system specs really do
#   BUILD `FROM alpine:3.20` and `FROM ubuntu:24.04`, and neither is
#   watched. An image a TEST builds fails the test when it rots --
#   loudly, in the run that uses it. That is the opposite of the failure
#   this watch exists for, which is a version baked into a file this repo
#   SHIPS going stale in silence in somebody else's repo.
#
# The lint checks this list rather than trusting it: a `tool-pin:` marker
# in an exempt file is a failure, so "exempt the shape the awkward pin
# lives in" cannot quietly become a way to stop watching a pin.
#
# Globs matched against a path's BASENAME, by _pin_is_exempt_shape. They
# were `find` predicates while the population came from `find`; both
# halves of the walk now partition one list of tracked paths, so the
# predicate has to be answerable about a string rather than about a
# directory entry.
readonly _PIN_SCAN_EXEMPT_SHAPES=(
  '*.md' '*.adoc' 'README' 'LICENSE' '*.bats'
)

# ── Declaration shapes the detector recognises ──────────────────────────────
#
# Deliberately NOT "every version-shaped token anywhere". The boundary is
# a third-party version THIS REPO NAMES THAT DEPENDABOT CANNOT BUMP:
# dependabot reads `uses:` version refs in WORKFLOW FILES and does that job
# well (its login-action PR is open and current), so duplicating it would
# produce two mechanisms disagreeing about one dependency. What it provably
# cannot see is an assignment whose value is a version -- a Dockerfile
# `ARG` or a shell `local` / `readonly` / `declare` / `export` alike -- a
# FROM tag, an image reference wherever it is written, a release-download
# URL, a `git clone -b <tag>`, a `uses:` ref that is a BRANCH rather than
# a version, and ANY of those written inside a shell script that generates
# a file.
#
# Every shape below is decided by what the LINE says. Only one consults
# the file at all, and only to locate DEPENDABOT'S OWN SCOPE.
#
# That is this detector's fourth correction and all four are the same
# correction. The first version listed the DIRECTORIES to look in and two
# live pins sat outside them. The second listed the FILE SHAPES and the
# repo's own control surface was not among them. The third listed the
# CONTEXTS an image may be named in -- a `docker run|pull|create|build`
# on the same line -- and a compose `image:`, a workflow `container:` and
# the `sed` that rewrites a downstream `FROM` line were all outside it,
# including the very line this change hoisted. The fourth listed one
# KEYWORD, `ARG`, while the reader below already extracted a version from
# five, and while this file's own advice is to hoist a literal onto a line
# of its own -- which produces `local` / `readonly` / `export`, none of
# which the detector could see. Each list was complete when it was written
# and each one went QUIET rather than red when the world moved past it.
# There is no fifth-context-proof list, so there is no list: an image
# reference is recognised by being one, and an assignment by assigning a
# version.
#
# The three shapes after the original four were not additions of scope.
# They were the forms the staleness this whole mechanism was built for was
# ACTUALLY written in: hadolint and shellcheck were release-download URLs
# and the three bats helpers were `clone -b` tags, all of which this change
# hoisted into ARGs -- while the guard meant to stop them coming back could
# not see any of them. A guard blind to the shape of the defect it exists
# to prevent is worth very little.

# A value that IS a version number: `1.2.3`, `v0.10.0`, `3.21`, `v43`.
#
# Two forms, and the split is the whole content of the rule. A `v` prefix
# is a version marker on its own, however few components follow it --
# nobody writes `v1000` for a UID -- so `v43` (kcov's real pin) and `v7`
# (a major action ref) are versions. Without that prefix at least one DOT
# is required, because nothing else separates a release from `ARG
# USER_UID=1000`, `PORT=8080` or a year.
#
# The cost of that second clause is stated rather than hidden: a bare
# `2024` is accepted as not-a-version, and a single-component upstream
# release written without its `v` is the one shape this cannot see. The
# alternative -- treating every bare integer as a release -- flags every
# count, port and UID in the tree, and a guard nobody can leave on guards
# nothing.
#
# The dot-only form was the previous rule in full, and it made this
# repo's OWN `ARG KCOV_VERSION=v43` invisible to the lint that exists to
# prove every pin is watched.
readonly _PIN_VERSION_RE='^(v[0-9]+(\.[0-9]+)*|[0-9]+(\.[0-9]+)+)([+~.-][A-Za-z0-9.]+)?$'

# An image reference with an explicit, version-shaped tag, WHEREVER it is
# written: `alpine:3.21`, `bats/bats:1.13.0`, `ghcr.io/ns/img:1.2.3`. One
# shape for the namespaced and the namespace-less form, and no context
# test -- the token is the declaration, and the places one can be written
# (a Dockerfile `FROM`, an `ARG` default, a compose `image:`, a workflow
# `container:`, a `docker run`, a justfile recipe, a `sed` expression that
# writes any of those into a file this repo ships) do not enumerate.
#
# Group 2 is the name, group 3 the tag. A digit-leading tag is required:
# `alpine:latest` and `${TEST_TOOLS_IMAGE}` name no version this can
# compare, and the second is our own image anyway.
readonly _PIN_IMAGE_REF_RE='(^|[[:space:]"'"'"'|=(,<[])([a-z0-9][a-z0-9._/-]*):([0-9][A-Za-z0-9._-]*)'

# What that shape matches and which is NOT an upstream version. Each is a
# property of the TOKEN, or of the flag that introduces it -- never of the
# rest of the line, because a test on the rest of the line is the thing
# that just failed three times.
#
# A name that is entirely digits: `-p 8080:8080`, `--user 1000:1000`,
# `12:30`. No image is named by a number, and port publishing and UID:GID
# plumbing are core idiom in this repo, so this is the difference between
# a guard and a nuisance.
readonly _PIN_IMAGE_NUMERIC_NAME_RE='^[0-9]+$'

# A digest: `sha256:0123abcd...`. Already immutable, so there is no newer
# one to propose.
readonly _PIN_IMAGE_DIGEST_RE='^[0-9a-f]{32,}$'

# A name introduced by `-t` / `--tag`: `docker build -t base:0.1 .`. That
# names an image this repo PRODUCES, and you cannot depend on a version
# you are creating. A rule about the flag, not a list of our own image
# names -- which is why it keeps working when we invent another one.
readonly _PIN_IMAGE_BUILT_RE='(^|[[:space:]])(-t|--tag)[[:space:]=]+["'"'"']?'

# A `uses:` ref that is neither a version tag nor a 40-hex commit --
# i.e. a branch, which dependabot has no way to advance.
readonly _PIN_USES_RE='uses:[[:space:]]*[A-Za-z0-9][A-Za-z0-9._-]*/[^[:space:]@]+@([^[:space:]#]+)'
readonly _PIN_USES_VERSION_RE='^(v?[0-9]+([._][0-9A-Za-z.-]*)?|[0-9a-f]{40})$'

# The only place a file's IDENTITY still decides anything, and it is not
# this repo's roster to keep: dependabot reads `uses:` refs out of
# .github/workflows/, so that is exactly and only where a VERSION ref is
# somebody else's job. In a heredoc a generator writes, in a justfile, in
# a manifest, nothing but this watch can ever advance one.
readonly _PIN_DEPENDABOT_SCOPE_RE='^\.github/workflows/[^/]+\.ya?ml$'

# A release asset URL that names the version in its PATH:
# `.../releases/download/v2.12.0/hadolint-Linux-x86_64`. This is not a
# fifth shape bolted on -- it is the shape three of this repo's four
# staleness cases were actually written in before they were hoisted into
# ARGs, and the guard that is supposed to stop them coming back could not
# see it. Only a LITERAL counts: `releases/download/${FOO_VERSION}/` is
# the ARG's version, already covered by the ARG's own marker.
readonly _PIN_RELEASE_URL_RE='releases/download/v?[0-9][A-Za-z0-9._-]*/'

# `git clone --depth 1 -b v2.1.0 ...` -- the other pre-hoist shape, and
# the one the three bats helper libraries were pinned in. Anchored on the
# word `clone` by the caller so a `-b` flag to some other command cannot
# masquerade as a tag.
readonly _PIN_CLONE_REF_RE='(^|[[:space:]])(-b|--branch)[[:space:]]+["'"'"']?v?[0-9][A-Za-z0-9._-]*'

# The assignment shapes whose version is the WHOLE right-hand side: a
# Dockerfile `ARG`, and a shell assignment with or without a declaration
# keyword. Both DECOUPLE the version from the marker's coordinate, which
# is what lets a marker name `library/alpine` upstream while the line
# spells `3.21`. That decoupling is why hoisting a literal onto a line of
# its own is the standard fix for a version the reader cannot address.
#
# ONE regex, read by both halves. The reader used it to EXTRACT a pin's
# current value from all five keywords; the detector had a separate,
# narrower test that recognised `ARG` alone. So the convention this file
# recommends -- hoist the literal onto its own line -- produced the exact
# shape the completeness guard was blind to, and two versions this repo
# writes into every downstream Dockerfile it migrates lost their cover
# without the lint noticing. A shared regex is what makes "the lint and
# the watch cannot disagree about what a pin is" true rather than
# intended.
readonly _PIN_ASSIGN_RE='^([[:space:]]*(ARG|local|readonly|declare|export)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=)(.*)$'

# A versioned ACTION reference as a whole value: `<owner>/<repo>@<ref>`,
# with any number of path segments in between. Capture 1 is the action,
# capture 3 the ref. The required `/` is what keeps a bare word ahead of an
# `@` -- an email address, a `user@host` -- from reading as an action.
#
# It is here rather than in the lint that compares refs for the reason
# `_PIN_ASSIGN_RE` is here: an assignment of one is a DECLARATION SITE (the
# shape below), and it is also the value that lint resolves a variable to.
# Two spellings of "what an action ref is" would let the guard and the
# reader disagree about which lines are pins.
readonly _PIN_ACTION_REF_RE='^([A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)+)@([A-Za-z0-9._-]+)$'

# ── Reader ──────────────────────────────────────────────────────────────────

# _pin_is_exempt_shape <repo-root-relative-path>
#
# TRUE when the path's BASENAME matches one of the exempt shapes. Both
# halves of the walk partition one list of paths through this, so a file
# is read by exactly one of them and neither can drift.
_pin_is_exempt_shape() {
  local _base="${1##*/}" _glob
  for _glob in "${_PIN_SCAN_EXEMPT_SHAPES[@]}"; do
    # Deliberately unquoted: _glob IS a pattern.
    # shellcheck disable=SC2053
    [[ "${_base}" == ${_glob} ]] && return 0
  done
  return 1
}

# _pin_tracked <repo-root>
#
# Print every file this repo TRACKS at <repo-root>, repo-root-relative,
# one per line, LC_ALL=C sorted. This is the whole population both walks
# partition -- see the section head above for why it is `git ls-files`
# and not a roster.
#
# Returns 2, printing what to supply, when tracked-ness cannot be
# established. "Nothing is tracked" and "nobody could look" are the two
# answers a caller must never confuse, and only one of them is allowed to
# read as a clean tree.
#
# ── Only blobs ──────────────────────────────────────────────────────────
#
# Index modes 100644 and 100755 and nothing else. A 120000 entry is a
# SYMLINK, and this repo tracks eight of them -- `script/run.sh` and its
# siblings point into `dist/script/docker/wrapper/`. Reading through one
# reads a file already in the population under a second name, which does
# not just duplicate work: every marker in it yields a second record with
# a different `file`, and the lint's duplicate-NAME check would fire on
# the repo's own pins. A symlink is a pointer to content, not content.
# 160000 (a submodule) is excluded by the same rule and for the same
# reason -- it is another repository's content, tracked here as a commit
# id.
#
# The rule is held on BOTH roads into this function, not only on the one
# that can read modes: the carried list is filtered against the tree
# instead. A rule enforced on one road is a verdict that depends on which
# road the environment took.
#
# ── Where the answer comes from, and why it is never absent ─────────────
#
# The check needs git, and the suite's own container bind-mounts the
# checkout WITHOUT a resolvable `.git`: a worktree's `.git` is a FILE
# naming a path outside the mount, so `git -C /source rev-parse
# --git-dir` answers `fatal: not a git repository:
# <host-path>/.git/worktrees/<name>`. git is installed there; the
# repository is what is missing.
#
# So the answer is computed where git works and carried to where it does
# not: script/test/test.sh sets PIN_TRACKED_ROOT and PIN_TRACKED_FILES on
# the HOST before the compose run. (It is the same handoff the removed
# prune roster used, one question earlier. `PIN_PRUNE_TRACKED` carried
# that guard's VERDICT and no longer exists anywhere; nothing reads it,
# and setting it does nothing.) git WINS when it is readable, so a stale or
# hand-set list can never silence a file git can see. The handoff is
# keyed to the root it describes and is ignored for any other, because a
# list of one tree's tracked files is not an answer about a different
# tree -- a fixture root would otherwise inherit the repository's.
#
# When neither source can answer, this refuses. A guard whose default on
# an environment it cannot inspect is "clean" is fail-open, and this one
# decides which files every check downstream of it reads.
_pin_tracked() {
  local _root="${1}"
  local _rec _mode _path
  local -a _found=()
  if git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r -d '' _rec; do
      _mode="${_rec%% *}"
      [[ "${_mode}" == '100644' || "${_mode}" == '100755' ]] || continue
      _path="${_rec#*$'\t'}"
      _found+=("${_path}")
    done < <(git -C "${_root}" ls-files -s -z)
  elif [[ "${PIN_TRACKED_ROOT:-}" == "${_root}" \
       && -n "${PIN_TRACKED_FILES:-}" ]]; then
    while IFS= read -r _path; do
      # The blobs-only rule again, asked of the TREE because a carried
      # list has no index modes to read. Without this the rule would hold
      # on one of the two roads into this function, and the same checkout
      # would answer differently depending on which one an environment
      # took -- a verdict that depends on how you got here is the defect
      # the derived population exists to end, not a detail of the
      # handoff. The failure it produces is not subtle: a symlink to a
      # file that declares a pin yields a second record for that pin
      # under a second name, and the lint's duplicate-NAME check fails on
      # the repo's own declarations.
      if [[ -n "${_path}" && ! -L "${_root}/${_path}" ]]; then
        _found+=("${_path}")
      fi
    done <<< "${PIN_TRACKED_FILES}"
  else
    printf 'pin registry: cannot tell what %s tracks -- it is not a readable git repository and no host-computed list arrived for it in PIN_TRACKED_FILES. The tracked set IS the scan population, so an unanswered one is not a detail to skip. Run the lint on the host, or set PIN_TRACKED_ROOT=%s and PIN_TRACKED_FILES the way script/test/test.sh does for the compose run.\n' \
      "${_root}" "${_root}" >&2
    return 2
  fi
  [[ "${#_found[@]}" -eq 0 ]] && return 0
  printf '%s\n' "${_found[@]}" | LC_ALL=C sort -u
}

# _pin_files <repo-root>
#
# Print every scanned file, repo-root-relative, one per line, sorted:
# every TRACKED file that is not of an exempt shape. A Dockerfile,
# workflow, script, justfile or config committed tomorrow, at any depth,
# under any name, is scanned without touching this file -- and an
# untracked one is not scanned on anybody's machine.
#
# A tree that yields nothing at all is an error rather than an empty
# table: every caller would read "no pins declared" as a clean repo, which
# is the one answer this mechanism must never give by accident. It is
# distinct from "could not look", which _pin_tracked reports as 2 and this
# passes straight through.
_pin_files() {
  local _root="${1}"
  local _path _tracked _rc=0
  local -a _found=()
  _tracked="$(_pin_tracked "${_root}")" || _rc=$?
  if [[ "${_rc}" -ne 0 ]]; then
    return "${_rc}"
  fi
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    if ! _pin_is_exempt_shape "${_path}"; then
      _found+=("${_path}")
    fi
  done <<< "${_tracked}"
  if [[ "${#_found[@]}" -eq 0 ]]; then
    printf 'pin registry: no scannable file under %s\n' \
      "${_root}" >&2
    return 1
  fi
  printf '%s\n' "${_found[@]}"
}

# _pin_exempt_files <repo-root>
#
# The other half of that partition: every TRACKED file the scan EXEMPTS,
# repo-root-relative and sorted. The lint reads it to prove no `tool-pin:`
# marker was written where nothing reads it -- which is how the exemption
# list is CHECKED rather than trusted.
#
# Empty is a normal answer here, unlike _pin_files: a tree with no prose
# and no specs in it is a tree, not a broken walk. "Could not look" is
# still not empty -- it propagates as 2.
_pin_exempt_files() {
  local _root="${1}"
  local _path _tracked _rc=0
  local -a _found=()
  _tracked="$(_pin_tracked "${_root}")" || _rc=$?
  if [[ "${_rc}" -ne 0 ]]; then
    return "${_rc}"
  fi
  while IFS= read -r _path; do
    [[ -n "${_path}" ]] || continue
    if _pin_is_exempt_shape "${_path}"; then
      _found+=("${_path}")
    fi
  done <<< "${_tracked}"
  [[ "${#_found[@]}" -eq 0 ]] && return 0
  printf '%s\n' "${_found[@]}"
}

# _pin_unquote <value> -- strip one layer of matching quotes.
_pin_unquote() {
  local _v="${1}"
  if [[ "${_v}" == \"*\" || "${_v}" == \'*\' ]]; then
    _v="${_v:1:${#_v}-2}"
  fi
  printf '%s' "${_v}"
}

# _pin_rhs_value <rhs> -- the value on an assignment's right-hand side,
# with any trailing comment AND the whitespace in front of it removed.
# Dropping the comment alone leaves that whitespace attached to the
# version, and it does not stay local: it flows into the reported
# `from` field, into the branch name a bump builds and into whatever CI
# feeds from `pins.sh --value`.
_pin_rhs_value() {
  local _v="${1%%[[:space:]]#*}"
  _v="${_v%"${_v##*[![:space:]]}"}"
  printf '%s' "${_v}"
}

# _pin_rhs_tail <rhs> -- everything _pin_rhs_value dropped: the spacing
# and the trailing comment. `--set` puts it back verbatim, because the
# comment on a pin's line is where a "held at this version because ..."
# rationale lives -- the one line a reviewer of a bump proposal most needs
# to still be there.
_pin_rhs_tail() {
  local _v
  _v="$(_pin_rhs_value "${1}")"
  printf '%s' "${1#"${_v}"}"
}

# _pin_assign_value <line> -- the value <line> assigns, unquoted and with
# any trailing comment removed; non-zero when <line> assigns nothing.
#
# The assignment half of _pin_extract_value, split out because two callers
# need it WITHOUT a coordinate: _pin_read, filling the value column of an
# `unpinned` record (which carries no coordinate at all), and the
# generated-workflow lint, asking what one variable the registry declares
# holds. Anchoring on the shared regex is what keeps all three agreeing
# about which lines are assignments.
_pin_assign_value() {
  local _line="${1}"
  [[ "${_line}" =~ ${_PIN_ASSIGN_RE} ]] || return 1
  _pin_unquote "$(_pin_rhs_value "${BASH_REMATCH[3]}")"
}

# _pin_assign_name <line> -- the variable name <line> assigns to; non-zero
# when <line> assigns nothing.
#
# Read off the shared regex's first capture -- the whole `[<keyword> ]NAME=`
# head -- rather than by adding a capture group to it: every caller of
# `${_PIN_ASSIGN_RE}` addresses the right-hand side as `BASH_REMATCH[3]`,
# so a new group in the middle would silently re-point all of them.
_pin_assign_name() {
  local _line="${1}" _head
  [[ "${_line}" =~ ${_PIN_ASSIGN_RE} ]] || return 1
  _head="${BASH_REMATCH[1]%=}"
  _head="${_head%"${_head##*[![:space:]]}"}"
  printf '%s' "${_head##*[[:space:]]}"
}

# _pin_extract_value <target-line> <coordinate>
#
# The version the target line currently carries.
#
#   ARG <NAME>=<value>   ->  <value>, unquoted, comment stripped
#   <NAME>=<value>       ->  the same, for a shell declaration site
#   anything else        ->  the token following <coordinate>, separated by
#                            `:` (an image tag) or `@` (a ref)
#
# Anchoring the second form on the coordinate is what keeps extraction
# precise on a line that also carries flags, paths and other colons.
_pin_extract_value() {
  local _line="${1}" _coord="${2}"
  if _pin_assign_value "${_line}"; then
    return 0
  fi
  local _re="${_coord}[:@]([A-Za-z0-9][A-Za-z0-9._-]*)"
  if [[ "${_line}" =~ ${_re} ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# _pin_read <repo-root>
#
# THE table. One TSV record per marker:
#
#   <state> <name> <resolver> <coordinate> <pattern> <skip> <current> <file> <line>
#
# Empty fields are written as `-` so the record always has nine columns and
# `read` never collapses two of them. <line> is the TARGET line's number,
# because that is the line a bump rewrites.
_pin_read() {
  local _root="${1}"
  local _file _abs _lineno _line _target _target_no _rest _list
  local _state _name _resolver _coord _pattern _skip _current
  local -a _fields=()

  # Command substitution, not a process substitution feeding the loop: a
  # `< <(...)` redirection discards the producer's exit status, so a
  # missing scan root would end the loop quietly and this would return a
  # table of nothing with status 0 -- which every caller would read as
  # "the repo declares no pins" rather than "the reader could not look".
  _list="$(_pin_files "${_root}")" || return 1

  while IFS= read -r _file; do
    _abs="${_root}/${_file}"
    _lineno=0
    _state=""
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))
      if [[ -z "${_state}" ]]; then
        [[ "${_line}" =~ ${_PIN_MARKER_RE} ]] || continue
        _rest="${_line#*"${_PIN_MARKER}"}"
        # shellcheck disable=SC2206 # deliberate word-split of the marker body.
        _fields=(${_rest%%--*})
        if [[ "${#_fields[@]}" -eq 0 ]]; then
          printf '%s:%d: %s marker carries no body\n' \
            "${_file}" "${_lineno}" "${_PIN_MARKER}" >&2
          return 1
        fi
        _pattern=""
        _skip=""
        case "${_fields[0]}" in
          "${_PIN_STATE_IGNORE}")
            _state="${_PIN_STATE_IGNORE}"
            _name="${_file}:${_lineno}"
            _resolver=""
            _coord=""
            ;;
          "${_PIN_STATE_UNPINNED}")
            _state="${_PIN_STATE_UNPINNED}"
            _name="${_fields[1]:-}"
            _resolver=""
            _coord=""
            if [[ -z "${_name}" ]]; then
              printf '%s:%d: unpinned marker names no dependency\n' \
                "${_file}" "${_lineno}" >&2
              return 1
            fi
            ;;
          *)
            _state="${_PIN_STATE_PINNED}"
            _name="${_fields[0]}"
            _resolver="${_fields[1]:-}"
            _coord="${_fields[2]:-}"
            if [[ -z "${_resolver}" || -z "${_coord}" ]]; then
              printf '%s:%d: pin %s names no resolver and coordinate\n' \
                "${_file}" "${_lineno}" "${_name}" >&2
              return 1
            fi
            local _kv
            for _kv in "${_fields[@]:3}"; do
              case "${_kv}" in
                pattern=*) _pattern="${_kv#pattern=}" ;;
                skip=*)    _skip="${_kv#skip=}" ;;
                *)
                  printf '%s:%d: pin %s carries unknown option %s\n' \
                    "${_file}" "${_lineno}" "${_name}" "${_kv}" >&2
                  return 1
                  ;;
              esac
            done
            ;;
        esac
        _target=""
        _target_no=0
        continue
      fi
      # Looking for the marker's target: the next line that is neither
      # blank nor another comment. A SECOND marker before that line is an
      # error, not a silent loss: both would otherwise claim one target
      # and only the first would ever be read.
      if [[ "${_line}" =~ ${_PIN_MARKER_RE} ]]; then
        printf '%s:%d: %s marker follows another with no target between them\n' \
          "${_file}" "${_lineno}" "${_PIN_MARKER}" >&2
        return 1
      fi
      [[ -z "${_line//[[:space:]]/}" ]] && continue
      [[ "${_line}" =~ ^[[:space:]]*# ]] && continue
      _target="${_line}"
      _target_no="${_lineno}"
      _current=""
      if [[ "${_state}" == "${_PIN_STATE_PINNED}" ]]; then
        if ! _current="$(_pin_extract_value "${_target}" "${_coord}")"; then
          printf '%s:%d: pin %s: no version for %s on its target line\n' \
            "${_file}" "${_target_no}" "${_name}" "${_coord}" >&2
          return 1
        fi
      elif [[ "${_state}" == "${_PIN_STATE_UNPINNED}" ]]; then
        # `unpinned` says the dependency FLOATS, not that the line holds
        # nothing: where the target is an assignment the record can carry
        # the value it declares, and a caller that would otherwise re-derive
        # it by reading the file reads the table instead.
        #
        # The assignment form only. An unpinned marker carries no
        # coordinate, so the token-after-coordinate branch has nothing to
        # anchor on and would put a fabricated version in the table -- `-`
        # is the honest column for `RUN apk add ...`.
        _current="$(_pin_assign_value "${_target}")" || _current=""
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' \
        "${_state}" "${_name}" "${_resolver:--}" "${_coord:--}" \
        "${_pattern:--}" "${_skip:--}" "${_current:--}" "${_file}" "${_target_no}"
      _state=""
    done < "${_abs}"
    if [[ -n "${_state}" ]]; then
      printf '%s: %s marker for %s has no target line after it\n' \
        "${_file}" "${_PIN_MARKER}" "${_name}" >&2
      return 1
    fi
  done <<< "${_list}"
}

# ── Detector ────────────────────────────────────────────────────────────────

# _pin_has_image_ref <line>
#
# True when the line names an image at a version-shaped tag that is NOT
# one of the three things that shape also matches (a numeric name, a
# digest, a `-t`-assigned output). Every token on the line is considered,
# so `docker build -t base:0.1 -f - alpine:3.21` still answers TRUE for
# the one that is somebody else's release.
_pin_has_image_ref() {
  local _line="${1}" _rest="${1}" _name _tag
  while [[ "${_rest}" =~ ${_PIN_IMAGE_REF_RE} ]]; do
    _name="${BASH_REMATCH[2]}"
    _tag="${BASH_REMATCH[3]}"
    # Consume through the match so the next iteration cannot rematch it.
    # BASH_REMATCH[0] is never empty here, so the loop always advances.
    _rest="${_rest#*"${BASH_REMATCH[0]}"}"
    [[ "${_name}" =~ ${_PIN_IMAGE_NUMERIC_NAME_RE} ]] && continue
    [[ "${_tag}" =~ ${_PIN_IMAGE_DIGEST_RE} ]] && continue
    _pin_image_is_built "${_line}" "${_name}:${_tag}" && continue
    return 0
  done
  return 1
}

# _pin_image_is_built <line> <name:tag> -- is that token the argument of a
# `-t` / `--tag`, i.e. an image this repo produces rather than consumes?
# The token is matched LITERALLY (quoted on the right-hand side of `=~`),
# so a `.` or `-` in an image name cannot act as a metacharacter.
_pin_image_is_built() {
  local _line="${1}" _tok="${2}"
  [[ "${_line}" =~ ${_PIN_IMAGE_BUILT_RE}"${_tok}" ]]
}

# _pin_is_declaration <file> <line>
#
# True when the line declares a third-party version this repo names and
# dependabot cannot bump. See the shape table above for the forms and why
# the boundary sits where it does.
#
# Every test but the last is on the LINE. The last consults <file> for one
# question only -- is this a workflow file, i.e. inside dependabot's own
# scope -- because that is where the division of labour is real. Nothing
# here asks what KIND of file it is otherwise: that question is what
# quietly exempted the shapes and the contexts this detector kept missing.
_pin_is_declaration() {
  local _file="${1}" _line="${2}"
  local _value _ref

  [[ "${_line}" =~ ${_PIN_RELEASE_URL_RE} ]] && return 0
  if [[ "${_line}" == *clone* && "${_line}" =~ ${_PIN_CLONE_REF_RE} ]]; then
    return 0
  fi
  _pin_has_image_ref "${_line}" && return 0

  # An assignment whose whole right-hand side is a version: a Dockerfile
  # `ARG`, a `local` / `readonly` / `declare` / `export`, or a bare
  # `NAME=<version>`. `ARG` is Dockerfile syntax wherever it is written --
  # a heredoc in a generator included -- and a shell assignment is a
  # declaration site wherever it is written for the same reason: the VALUE
  # decides, not the keyword and not the file.
  #
  # `${_PIN_ASSIGN_RE}` is the reader's own regex, so a shape the reader
  # can extract a version from is a shape this can require a marker on.
  # A non-version value falls THROUGH rather than returning: narrowing the
  # answer to "not a declaration" on the strength of one shape not
  # matching is how a guard stops seeing the next one.
  if [[ "${_line}" =~ ${_PIN_ASSIGN_RE} ]]; then
    _value="$(_pin_unquote "$(_pin_rhs_value "${BASH_REMATCH[3]}")")"
    [[ "${_value}" =~ ${_PIN_VERSION_RE} ]] && return 0
    # An action REF assigned whole -- `readonly REF='actions/checkout@v7'`.
    # This file's advice for a version no marker can address is to hoist it
    # onto a line of its own, and for a `uses:` ref inside a heredoc that
    # advice produces exactly this line. Recognising the version shape but
    # not this one made the marker on every hoisted ref VOLUNTARY: deleting
    # it left both this lint and the generated-workflow lint green over a
    # ref nothing watches, which is the state the hoist was performed to
    # end. Same correction as the four before it -- the guard could not see
    # the shape of its own recommended fix.
    [[ "${_value}" =~ ${_PIN_ACTION_REF_RE} ]] && return 0
  fi

  if [[ "${_line}" =~ ${_PIN_USES_RE} ]]; then
    _ref="${BASH_REMATCH[1]}"
    # shellcheck disable=SC2016 # the literal expression opener, not an expansion.
    [[ "${_ref}" == *'${'* ]] && return 1
    [[ "${_ref}" == './'* ]] && return 1
    # `@<tag>` in a help string is a placeholder telling a reader what to
    # write, not a ref anything resolves.
    [[ "${_ref}" == *'<'* ]] && return 1
    if [[ "${_file}" =~ ${_PIN_DEPENDABOT_SCOPE_RE} ]]; then
      # Dependabot's file, so a VERSION ref is its job and a BRANCH ref --
      # which it bumps to nothing, ever -- is still ours.
      [[ "${_ref}" =~ ${_PIN_USES_VERSION_RE} ]] && return 1
    fi
    return 0
  fi
  return 1
}

# _pin_uncovered <repo-root>
#
# Print `<file>:<line>: <text>` for every declaration that is not some
# marker's target. Prints nothing when the trees are fully declared.
#
# It re-walks the files rather than reusing _pin_read's records because
# the question is different: the reader asks "what did the markers say",
# and this asks "what did they NOT say". A shared walk would answer the
# second question with the first one's blind spots.
_pin_uncovered() {
  local _root="${1}"
  local _file _abs _lineno _line _key _covered_list _list
  local -A _covered=()

  # Both producers run in a command substitution for the reason spelled
  # out in _pin_read: a redirection would swallow their exit status.
  _covered_list="$(_pin_read "${_root}" | awk -F'\t' '{print $8 ":" $9}')" \
    || return 1
  _list="$(_pin_files "${_root}")" || return 1

  while IFS= read -r _key; do
    [[ -n "${_key}" ]] && _covered["${_key}"]=1
  done <<< "${_covered_list}"

  while IFS= read -r _file; do
    _abs="${_root}/${_file}"
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))
      [[ "${_line}" =~ ^[[:space:]]*# ]] && continue
      if _pin_is_declaration "${_file}" "${_line}" \
         && [[ -z "${_covered["${_file}:${_lineno}"]:-}" ]]; then
        printf '%s:%d: %s\n' "${_file}" "${_lineno}" \
          "${_line#"${_line%%[![:space:]]*}"}"
      fi
    done < "${_abs}"
  done <<< "${_list}"
}
