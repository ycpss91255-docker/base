#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/canonical_ignore_sync.sh -- the
# "base's own .dockerignore covers every entry the shipped canonical set
# emits" lint. base's root .dockerignore carries a block headed as a copy
# of _canonical_gitignore_entries, and the copy had drifted by eight
# entries; the gate derives BOTH sides so the next entry added to the
# function fails until the file agrees. Driven over throwaway fixture
# trees -- a planted lib and a planted .dockerignore -- so the cases pin
# the rule rather than today's eighteen entries; the live tree is the
# lint job's assertion to make, not this spec's.
#
# why: Unit tests for `script/test/drivers/canonical_ignore_sync.sh`
# (`_run_canonical_ignore_sync`, refs base#1275), the "base's own
# `.dockerignore` covers every canonical entry" lint. The file's
# derived-artifact block is a hand-written copy of a shipped function's
# output and had drifted by eight entries, so machine-local names went to
# the daemon as build context under a header asserting they were handled.
# The rule is ONE-DIRECTIONAL -- every canonical entry present, extras
# allowed -- and presence is a WHOLE LINE, matching the `grep -qxF` the
# shipped `_sync_managed_entries` applies. Driven over throwaway fixture
# trees, with a case for each of the three ways the lint could go green
# having checked nothing.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # stale_setup_conf_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/canonical_ignore_sync.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"

  # The default fixture: a three-entry canonical set and a .dockerignore
  # that covers all three. Small on purpose -- a fixture mirroring today's
  # eighteen would be the declared population this lint exists to refuse,
  # restated in the test.
  _write_lib '.env' 'coverage/' '/deploy/'
  _write_target '.env' 'coverage/' '/deploy/'
}

# _write_lib <entry>... -- plant a shipped-lib stand-in at the path the
# driver reads, whose emitter prints <entry>..., one per line.
#
# The emitter's NAME comes from the driver's own constant rather than
# being typed here: a spec that spelled it independently would keep
# agreeing with itself after the driver started reading a different
# function, which is the drift this whole file is about.
_write_lib() {
  local _f="${SCRATCH}/${_CANONICAL_IGNORE_SYNC_LIB_REL}"
  mkdir -p "$(dirname "${_f}")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s() {\n' "${_CANONICAL_IGNORE_SYNC_FN}"
    printf "  cat <<'ENTRY_EOF'\n"
    (( $# > 0 )) && printf '%s\n' "$@"
    printf 'ENTRY_EOF\n}\n'
  } > "${_f}"
}

# _write_target <line>... -- plant a .dockerignore in the fixture tree
# holding exactly <line>....
_write_target() {
  local _f="${SCRATCH}/${_CANONICAL_IGNORE_SYNC_TARGET_REL}"
  mkdir -p "$(dirname "${_f}")"
  if (( $# > 0 )); then
    printf '%s\n' "$@" > "${_f}"
  else
    : > "${_f}"
  fi
}

# ── The control group ──────────────────────────────────────────────────────

# why: A covered file must not be reported
@test "_run_canonical_ignore_sync: passes when every canonical entry is a line of the file (base#1275)" {
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: The clean report states the derived count, not a remembered one
@test "_run_canonical_ignore_sync: the clean report names how many entries it checked (base#1275)" {
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"3 canonical entries"* ]]
}

# ── The defect ─────────────────────────────────────────────────────────────

# why: The drift itself -- an absent canonical entry
@test "_run_canonical_ignore_sync: FAILS on a canonical entry absent from the file, naming it (base#1275)" {
  _write_target '.env' 'coverage/'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: /deploy/"* ]]
}

# why: Every absence is reported, not just the first
@test "_run_canonical_ignore_sync: names EVERY absent entry, not only the first (base#1275)" {
  _write_target '.env'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: coverage/"* ]]
  [[ "${output}" == *"missing canonical entry: /deploy/"* ]]
  [[ "${output}" == *"2 of 3 canonical entries are absent"* ]]
}

# why: THE POINT OF THE ISSUE -- the set is derived, so a new entry fails
@test "_run_canonical_ignore_sync: an entry added to the emitter fails until the file agrees (base#1275)" {
  _write_lib '.env' 'coverage/' '/deploy/' '.newly.derived'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: .newly.derived"* ]]
  # And the same tree goes green once the file carries it -- the gate is
  # satisfiable by editing the FILE, which is what makes it a gate and not
  # a wall.
  _write_target '.env' 'coverage/' '/deploy/' '.newly.derived'
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
}

# ── One-directional: extras are allowed ────────────────────────────────────

# why: `.prev-release/` and the editor globs are legitimate extras
@test "_run_canonical_ignore_sync: a non-canonical line in the file is NOT a failure (base#1275)" {
  _write_target '.env' 'coverage/' '/deploy/' '.prev-release/' '*.swp'
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: A retired name left in the file is not this lint's business
@test "_run_canonical_ignore_sync: a line naming a retired artifact keeps the gate green (base#1275)" {
  _write_target '.env' 'coverage/' '/deploy/' 'runtime.env'
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
}

# ── Presence is a whole line ───────────────────────────────────────────────

# why: The rule chosen in base#1275 -- a covering glob is not the entry
@test "_run_canonical_ignore_sync: a glob that would cover an entry does not count as that entry (base#1275)" {
  _write_lib '.env.local.bak'
  _write_target '*.bak'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: .env.local.bak"* ]]
  # The refusal has to SAY which rule it applied: a reader who sees
  # `*.bak` sitting in the file needs to be told why it did not count,
  # or the only way to find out is to read the driver.
  [[ "${output}" == *"PRESENCE IS A WHOLE LINE"* ]]
}

# why: A substring reader would find `.env.generated` inside the `.env` line
@test "_run_canonical_ignore_sync: an entry is not satisfied by a line it is a prefix of (base#1275)" {
  _write_lib '.env' '.env.generated'
  _write_target '.env.generated'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: .env"* ]]
}

# why: Nor by a line that merely contains it
@test "_run_canonical_ignore_sync: an entry is not satisfied by a longer line containing it (base#1275)" {
  _write_lib '.env'
  _write_target 'doc/.env.sample'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: .env"* ]]
}

# why: The report must name the one file it holds the set to
@test "_run_canonical_ignore_sync: each reported absence names the target file (base#1275)" {
  _write_target '.env'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".dockerignore: missing canonical entry: coverage/"* ]]
}

# ── Non-vacuity: three ways to go green having checked nothing ─────────────

# why: An empty canonical set is covered by every file
@test "_run_canonical_ignore_sync: an emitter that yields nothing DIES rather than passing (base#1275)" {
  _write_lib
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"yielded no entries"* ]]
  [[ "${output}" == *"vacuously"* ]]
}

# why: A renamed or deleted emitter is the same vacuous pass
@test "_run_canonical_ignore_sync: a lib with no such emitter DIES rather than passing (base#1275)" {
  local _f="${SCRATCH}/${_CANONICAL_IGNORE_SYNC_LIB_REL}"
  printf '%s\n' '#!/usr/bin/env bash' '_something_else() { :; }' > "${_f}"
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"yielded no entries"* ]]
}

# why: A lib that cannot be read at all must not read as an empty set quietly
@test "_run_canonical_ignore_sync: a missing shipped lib DIES rather than passing (base#1275)" {
  rm -f "${SCRATCH}/${_CANONICAL_IGNORE_SYNC_LIB_REL}"
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"yielded no entries"* ]]
  [[ "${output}" == *"${_CANONICAL_IGNORE_SYNC_LIB_REL}"* ]]
}

# why: No target file means the question was asked of nothing
@test "_run_canonical_ignore_sync: a missing target file DIES rather than passing (base#1275)" {
  rm -f "${SCRATCH}/${_CANONICAL_IGNORE_SYNC_TARGET_REL}"
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not found"* ]]
  [[ "${output}" == *"vacuously"* ]]
  # Distinct from the emptied-emitter refusal above: both end in
  # "vacuously", so a case asserting only the shared word would pass with
  # the guard it names deleted.
  [[ "${output}" != *"yielded no entries"* ]]
}

# why: An empty target file is a real file, so it reports absences not vacuity
@test "_run_canonical_ignore_sync: an EMPTY target file reports every entry absent (base#1275)" {
  _write_target
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"3 of 3 canonical entries are absent"* ]]
  [[ "${output}" != *"vacuously"* ]]
}

# ── Reading the shipped lib safely ─────────────────────────────────────────

# why: A lib that prints while loading must not be read as an entry
@test "_run_canonical_ignore_sync: output a lib writes while loading is not an entry (base#1275)" {
  local _f="${SCRATCH}/${_CANONICAL_IGNORE_SYNC_LIB_REL}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "a banner the lib prints at source time"'
    printf '%s() {\n' "${_CANONICAL_IGNORE_SYNC_FN}"
    printf "  cat <<'ENTRY_EOF'\n.env\ncoverage/\n/deploy/\nENTRY_EOF\n}\n"
  } > "${_f}"
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"3 canonical entries"* ]]
  [[ "${output}" != *"banner"* ]]
}

# why: A lib defining its own `_die` must not replace the dispatcher's
@test "_run_canonical_ignore_sync: a lib that redefines _die cannot disarm the refusal (base#1275)" {
  local _f="${SCRATCH}/${_CANONICAL_IGNORE_SYNC_LIB_REL}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '_die() { return 0; }'
    printf '%s() {\n' "${_CANONICAL_IGNORE_SYNC_FN}"
    printf "  cat <<'ENTRY_EOF'\n.env\n.absent.entry\nENTRY_EOF\n}\n"
  } > "${_f}"
  _write_target '.env'
  run _run_canonical_ignore_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing canonical entry: .absent.entry"* ]]
}

# why: Blank lines in the emitter are not entries no file can satisfy
@test "_run_canonical_ignore_sync: a blank line from the emitter is not counted as an entry (base#1275)" {
  local _f="${SCRATCH}/${_CANONICAL_IGNORE_SYNC_LIB_REL}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s() {\n' "${_CANONICAL_IGNORE_SYNC_FN}"
    printf "  cat <<'ENTRY_EOF'\n.env\n\ncoverage/\nENTRY_EOF\n}\n"
  } > "${_f}"
  _write_target '.env' 'coverage/'
  run _run_canonical_ignore_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 canonical entries"* ]]
}
