#!/usr/bin/env bats
#
# config_gen_admit_spec.bats -- the config-gen admission checker,
# script/test/config_gen_admit.sh (base#1465, slice S1e of base#1395).
#
# why: The Dockerfile's admit stage runs this checker before any Go, to
# hold the build context to the host mutation baseline the 00-manifest step
# wrote (base#1464). The build-seam proof is config_gen_redpath.sh, which
# runs these cases through real docker builds; this spec runs the
# checker's own contract fast enough for the required-kill roster
# (script/test/mutation_required/s1e.tsv) to probe each of its guards.
# Every row writes a real baseline with config_gen_mutation_targets.sh on a
# Git fixture, changes the module or the baseline the way a later step
# could, and runs the checker on the result; no row reads the checker's
# source.
#
#   config_gen_admit.sh <mutation> <src>
#     admitted: rc 0, nothing on stdout or stderr
#     refused:  rc 1, nothing on stdout, exactly one stderr line
#               cg_event config_gen_manifest_stale file=<f> reason=<r>

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ADMIT="/source/script/test/config_gen_admit.sh"
  LANG_LIB="/source/script/test/config_gen_mutation_lang.sh"
  CGM="/source/script/test/config_gen_mutation_targets.sh"
  S="${BATS_TEST_TMPDIR}"
  MOD="dockerfile/config-gen"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount, and every git call made from it dies with
  # "not a git repository".
  cd "${S}"
  unset CONFIG_GEN_MUTATION_CONTEXT CONFIG_GEN_MUTATION_BASE
  # A fixed Git identity and no user or system config, so a developer's
  # settings cannot change what a fixture records.
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="${S}/gitconfig"
  git config --file "${GIT_CONFIG_GLOBAL}" user.name t
  git config --file "${GIT_CONFIG_GLOBAL}" user.email t@t
  git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main
  git config --file "${GIT_CONFIG_GLOBAL}" commit.gpgsign false
}

# _repo -- ${S}/w: one commit holding ${MOD}/a.go and ${MOD}/c.txt,
# origin/main at it.
_repo() {
  W="${S}/w"
  rm -rf "${W}" "${S}/m"
  git init -q "${W}"
  mkdir -p "${W}/${MOD}"
  printf 'package a\n' > "${W}/${MOD}/a.go"
  printf 'c\n' > "${W}/${MOD}/c.txt"
  git -C "${W}" add -A
  git -C "${W}" commit -q --no-verify -m base
  git -C "${W}" update-ref refs/remotes/origin/main HEAD
}

# _produce -- ${S}/m: the baseline the producer writes for ${W} (context
# pr), with the checker and its library installed beside it as 01-admit
# installs them.
_produce() {
  rm -rf "${S}/m"
  CONFIG_GEN_MUTATION_CONTEXT=pr bash "${CGM}" --repo "${W}" "${S}/m" \
    || fail "config_gen_mutation_targets.sh did not write the baseline"
  cp "${ADMIT}" "${S}/m/admit.sh"
  cp "${LANG_LIB}" "${S}/m/config_gen_mutation_lang.sh"
}

_run_admit() {
  assert_spec_subject "${ADMIT}" "the config-gen admission checker (base#1465)"
  run --separate-stderr bash "${S}/m/admit.sh" "${S}/m" "${W}/${MOD}"
}

# _admitted [label] -- the admitted shape.
_admitted() {
  assert_equal "${1:-}:${status}" "${1:-}:0"
  assert_equal "${1:-}:${output}" "${1:-}:"
  assert_equal "${1:-}:${stderr}" "${1:-}:"
}

# _refused <label> <file> <reason> -- the refused shape.
_refused() {
  assert_equal "${1}:${status}" "${1}:1"
  assert_equal "${1}:${output}" "${1}:"
  assert_equal "${1}:${stderr}" "${1}:cg_event config_gen_manifest_stale file=${2} reason=${3}"
}

# ── the producer's own outputs ──────────────────────────────────────────────

# _scenario <name> -- change ${W} as one producer run observed in base#1465
# redesign r2 §1 did, before the baseline is written.
_scenario() {
  local m="${W}/${MOD}"
  case "${1}" in
    unchanged) ;;
    rename-recreate) git -C "${W}" mv "${MOD}/a.go" "${MOD}/d.go"; printf 'new\n' > "${m}/a.go" ;;
    untrack) git -C "${W}" rm -q --cached "${MOD}/a.go" ;;
    rename-move) git -C "${W}" mv "${MOD}/a.go" "${MOD}/d.go"; mv "${m}/c.txt" "${m}/a.go" ;;
    untrack-ignored)
      printf '%s/a.go\n' "${MOD}" > "${W}/.git/info/exclude"
      git -C "${W}" rm -q --cached "${MOD}/a.go"
      ;;
    copies)
      git -C "${W}" config diff.renames copies
      cp "${m}/a.go" "${m}/e.go"
      cp "${m}/a.go" "${m}/f.go"
      git -C "${W}" add -A
      ;;
    typechange) rm "${m}/a.go"; ln -s c.txt "${m}/a.go" ;;
    *) fail "_scenario: no scenario ${1}" ;;
  esac
}

# why: Every manifest the producer writes for a module, and the module it
# wrote it for, must be admitted: the record pairs below repeat an operand
# (R a d with A a, D a with A a, D c with R a d and A a), list a removed
# path as ignored, or list a symlink by its target's sha256, all observed
# from real producer runs (base#1465 redesign r2 §1). A presence rule
# guessed per record refuses one of them. (base#1465)
@test "config_gen_admit: the producer's baseline for each observed git state is admitted, and its manifest is the one observed (base#1465)" {
  local name want
  while IFS='|' read -r name want; do
    _repo
    _scenario "${name}"
    _produce
    assert_equal "${name}:$(tail -n +2 "${S}/m/manifest" | tr '\n' '|')" "${name}:$(printf '%b' "${want}")|"
    _run_admit
    _admitted "${name}"
  done <<ROWS
unchanged|none: no-go-change
rename-recreate|R100\t${MOD}/a.go\t${MOD}/d.go|A\t${MOD}/a.go
untrack|D\t${MOD}/a.go|A\t${MOD}/a.go
rename-move|D\t${MOD}/c.txt|R100\t${MOD}/a.go\t${MOD}/d.go|A\t${MOD}/a.go
untrack-ignored|D\t${MOD}/a.go
copies|A\t${MOD}/e.go|A\t${MOD}/f.go
typechange|T\t${MOD}/a.go
ROWS
  # untrack-ignored lists the removed a.go as ignored.
  _repo
  _scenario untrack-ignored
  _produce
  assert_equal "$(cut -f1 "${S}/m/ignored.sha256")" "${MOD}/a.go"
}

# why: Every name the producer writes, raw or C-quoted, is read back to the
# name on disk: a checker with a second spelling grammar refuses one of
# them, and a value it splits on a space names the wrong file. (base#1465)
@test "config_gen_admit: an unchanged baseline holding café.go, a b.go and one name per byte 0x01-0x7f but / is admitted (base#1465)" {
  _repo
  local name='' i
  for (( i = 1; i < 128; i++ )); do
    (( i == 0x2f )) && continue
    name+="$(printf "\\x$(printf '%02x' "${i}")")"
  done
  name+=$'\n'
  printf 'x\n' > "${W}/${MOD}/café.go"
  printf 'x\n' > "${W}/${MOD}/a b.go"
  printf 'x\n' > "${W}/${MOD}/${name}"
  git -C "${W}" add -A
  git -C "${W}" commit -q --no-verify -m names
  git -C "${W}" update-ref refs/remotes/origin/main HEAD
  printf 'y\n' > "${W}/${MOD}/zz${name}"
  _produce
  grep -q '^A	"' "${S}/m/manifest" || fail "no C-quoted record in the fixture's manifest"
  _run_admit
  _admitted
  printf 'edit\n' >> "${W}/${MOD}/a b.go"
  _run_admit
  _refused edit "${MOD}/a%20b.go" sha_mismatch
}

# ── the module after the baseline ───────────────────────────────────────────

# why: Whatever reaches the build after the baseline and is not bound by
# it, by name and by sha256, is compiled by gates that never saw it in the
# manifest; each change below names its file. (base#1465)
@test "config_gen_admit: a module file edited, deleted, added or replaced after the baseline is refused naming it (base#1465)" {
  local name want
  while IFS='|' read -r name want; do
    _repo
    _produce
    case "${name}" in
      edit) printf '// e\n' >> "${W}/${MOD}/a.go" ;;
      delete) rm "${W}/${MOD}/a.go" ;;
      add) mkdir -p "${W}/${MOD}/zz"; printf 'package zz\n' > "${W}/${MOD}/zz/zz.go" ;;
      symlink) ln -s c.txt "${W}/${MOD}/zz.go" ;;
      dangling) ln -s nowhere "${W}/${MOD}/zz.go" ;;
      fifo) mkfifo "${W}/${MOD}/zz" ;;
      to-symlink) rm "${W}/${MOD}/a.go"; ln -s c.txt "${W}/${MOD}/a.go" ;;
    esac
    _run_admit
    _refused "${name}" "${want%%:*}" "${want#*:}"
  done <<ROWS
edit|${MOD}/a.go:sha_mismatch
delete|${MOD}/a.go:missing
add|${MOD}/zz/zz.go:unlisted
symlink|${MOD}/zz.go:unlisted
dangling|${MOD}/zz.go:not_regular
fifo|${MOD}/zz:not_regular
to-symlink|${MOD}/a.go:sha_mismatch
ROWS
}

# ── the baseline tampered ───────────────────────────────────────────────────

# _tamper <case> -- rewrite the fresh baseline in ${S}/m as <case> says.
_tamper() {
  local h vis m="${S}/m" P="${MOD}" H40 H64
  IFS= read -r h < "${m}/manifest"
  IFS= read -r vis < "${m}/visible.sha256"
  H40="$(printf 'a%.0s' {1..40})"
  H64="$(printf 'b%.0s' {1..64})"
  case "${1}" in
    manifest-absent) rm "${m}/manifest" ;;
    visible-absent) rm "${m}/visible.sha256" ;;
    ignored-absent) rm "${m}/ignored.sha256" ;;
    lib-absent) rm "${m}/config_gen_mutation_lang.sh" ;;
    r-garbage) printf '%s\nRgarbage\t%s/a.go\t%s/d.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    r999) printf '%s\nR999\t%s/x.go\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    r101) printf '%s\nR101\t%s/x.go\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    copy) printf '%s\nC100\t%s/c.txt\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    arity) printf '%s\nM\t%s/a.go\t%s/c.txt\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    empty-field) printf '%s\nM\t\t%s/a.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    quoted-plain) printf '%s\nM\t"%s/a.go"\n' "${h}" "${P}" > "${m}/manifest" ;;
    octal-for-tab) printf '%s\nM\t"%s/a\\011.go"\n' "${h}" "${P}" > "${m}/manifest" ;;
    nul) printf '%s\nM\t%s/a\0.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    rename-self) printf '%s\nR100\t%s/a.go\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    ghost) printf '%s\nM\t%s/ghost.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    delete-listed) printf '%s\nD\t%s/a.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    add-twice) printf '%s\nA\t%s/a.go\nA\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    src-twice) printf '%s\nD\t%s/x.go\nR100\t%s/x.go\t%s/a.go\n' "${h}" "${P}" "${P}" "${P}" > "${m}/manifest" ;;
    tgt-twice) printf '%s\nM\t%s/a.go\nA\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    src-twice-d) printf '%s\nR100\t%s/x.go\t%s/a.go\nD\t%s/x.go\n' "${h}" "${P}" "${P}" "${P}" > "${m}/manifest" ;;
    tgt-twice-r) printf '%s\nM\t%s/a.go\nR100\t%s/x.go\t%s/a.go\n' "${h}" "${P}" "${P}" "${P}" > "${m}/manifest" ;;
    modify-over-src) printf '%s\nD\t%s/a.go\nM\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    add-over-src) printf '%s\nD\t%s/a.go\nA\t%s/a.go\n' "${h}" "${P}" "${P}" > "${m}/manifest" ;;
    header-mixed) printf 'base=%s head=%s dirty=no context=pr\nnone: no-go-change\n' "${H40}" "${H64}" > "${m}/manifest" ;;
    header-dirty) printf '%s\nnone: no-go-change\n' "${h/dirty=no/dirty=maybe}" > "${m}/manifest" ;;
    header-context) printf '%s\nnone: no-go-change\n' "${h/context=pr/context=x}" > "${m}/manifest" ;;
    header-order) printf 'head=%s base=%s dirty=no context=pr\nnone: no-go-change\n' "${H40}" "${H40}" > "${m}/manifest" ;;
    header-short) printf '%s\nnone: no-go-change\n' "${h% context=*}" > "${m}/manifest" ;;
    header-double-space) printf '%s\nnone: no-go-change\n' "${h/ head=/  head=}" > "${m}/manifest" ;;
    marker-twice) printf '%s\nnone: no-go-change\nnone: no-go-change\n' "${h}" > "${m}/manifest" ;;
    marker-after-record) printf '%s\nM\t%s/a.go\nnone: no-go-change\n' "${h}" "${P}" > "${m}/manifest" ;;
    marker-before-record) printf '%s\nnone: no-go-change\nM\t%s/a.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    header-only) printf '%s\n' "${h}" > "${m}/manifest" ;;
    manifest-empty) : > "${m}/manifest" ;;
    manifest-unterminated) printf '%s\nnone: no-go-change' "${h}" > "${m}/manifest" ;;
    visible-unterminated) printf '%s' "$(cat "${m}/visible.sha256")" > "${m}/v" && mv "${m}/v" "${m}/visible.sha256" ;;
    ignored-unterminated) printf '%s' "${vis}" > "${m}/ignored.sha256" ;;
    crlf) printf '%s\r\nnone: no-go-change\r\n' "${h}" > "${m}/manifest" ;;
    dotdot) printf '%s\nM\t%s/../a.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    outside) printf '%s\nM\t%sx/a.go\n' "${h}" "${P}" > "${m}/manifest" ;;
    visible-dup) printf '%s\n' "${vis}" >> "${m}/visible.sha256" ;;
    ignored-dup) printf '%s/zz\t%s\n%s/zz\t%s\n' "${P}" "${H64}" "${P}" "${H64}" > "${m}/ignored.sha256" ;;
    dual) printf '%s\n' "${vis}" > "${m}/ignored.sha256" ;;
    short-hex) { printf '%s\n' "${vis:0:${#vis}-1}"; tail -n +2 "${m}/visible.sha256"; } > "${m}/v" && mv "${m}/v" "${m}/visible.sha256" ;;
    list-nul) { printf '%s\0\n' "${vis}"; tail -n +2 "${m}/visible.sha256"; } > "${m}/v" && mv "${m}/v" "${m}/visible.sha256" ;;
    # A visible entry: an ignored one the context lacks is the build's
    # dockerignore at work and is admitted (base#1467).
    list-ghost) printf '%s/ghost\t%s\n' "${P}" "${H64}" >> "${m}/visible.sha256" ;;
    *) fail "_tamper: no case ${1}" ;;
  esac
}

# why: Each row is bytes the producer cannot write for the module on disk:
# a value its constructors refuse, a spelling it does not write, a record
# set no git state yields, or a list that is not its listing of the disk.
# Each was let through or wrongly refused by an earlier checker
# (base#1465 redesign r1 §1, r2 §1); add-over-src is the green twin of
# modify-over-src. (base#1465)
@test "config_gen_admit: a baseline the producer cannot write for the module on disk is refused with the rule's file and reason (base#1465)" {
  local name want
  while IFS='|' read -r name want; do
    _repo
    _produce
    _tamper "${name}"
    _run_admit
    if [[ "${want}" == admitted ]]; then
      _admitted "${name}"
    else
      _refused "${name}" "${want%%:*}" "${want#*:}"
    fi
  done <<ROWS
manifest-absent|manifest:absent
visible-absent|visible.sha256:absent
ignored-absent|ignored.sha256:absent
lib-absent|config_gen_mutation_lang.sh:absent
r-garbage|manifest:record
r999|manifest:record
r101|manifest:record
copy|manifest:record
arity|manifest:record
empty-field|manifest:record
quoted-plain|manifest:record
octal-for-tab|manifest:record
nul|manifest:record
rename-self|manifest:presence
ghost|manifest:presence
delete-listed|manifest:presence
add-twice|manifest:duplicate
src-twice|manifest:presence
tgt-twice|manifest:presence
src-twice-d|manifest:presence
tgt-twice-r|manifest:presence
modify-over-src|manifest:presence
add-over-src|admitted
header-mixed|manifest:header
header-dirty|manifest:header
header-context|manifest:header
header-order|manifest:header
header-short|manifest:header
header-double-space|manifest:header
marker-twice|manifest:none_marker
marker-after-record|manifest:none_marker
marker-before-record|manifest:none_marker
header-only|manifest:body_empty
manifest-empty|manifest:malformed
manifest-unterminated|manifest:malformed
visible-unterminated|visible.sha256:malformed
ignored-unterminated|ignored.sha256:malformed
crlf|manifest:header
dotdot|manifest:path
outside|manifest:path
visible-dup|visible.sha256:duplicate
ignored-dup|ignored.sha256:duplicate
dual|ignored.sha256:dual
short-hex|${MOD}/a.go:sha_mismatch
list-nul|${MOD}/a.go:sha_mismatch
list-ghost|${MOD}/ghost:missing
ROWS
}

# ── each refusal through the runner ─────────────────────────────────────────
#
# config_gen_gates.sh re-emits the checker's line from the build log as a
# JSON record. The real builds are config_gen_redpath.sh's; here the
# runner reads a log shaped as a real stale build printed it (observed on
# golang:1.27.2-trixie: BuildKit's step number, `0.170`, the line; then
# config_gen_gate_admission_failed), so its re-emission of a value the
# checker writes is pinned in the fast tier the roster probes.

# _admit_log <checker stderr> -- the admit RUN's plain-progress lines for a
# refusal.
_admit_log() {
  printf '#10 [admit 1/1] RUN --mount=type=bind,from=mutation,target=/mutation     --mount=type=bind,target=/src     e=manifest_missing; g=admission;\n'
  printf '#10 0.170 %s\n' "${1}"
  printf '#10 0.170 config_gen_gate_admission_failed\n'
  printf '#10 ERROR: process "/bin/bash -euo pipefail -c e=manifest_missing; g=admission;" did not complete successfully: exit code: 1\n'
}

# why: The checker's line is not the contract a caller reads; the runner's
# JSON record is, and its file attribute must survive a name holding a
# space, a % or a byte past 0x7e intact. (base#1465)
@test "config_gen_admit: a refusal reaches the runner as rc 1, no stdout, and JSON stale and admission records naming its file and reason (base#1465)" {
  local runner="/source/script/test/config_gen_gates.sh"
  mkdir -p "${S}/root/dockerfile/config-gen" "${S}/bin"
  printf 'FROM scratch\n' > "${S}/root/dockerfile/Dockerfile.config-gen"
  printf '#!%s\ncat "%s/build.log" >&2\nexit 1\n' "$(command -v bash)" "${S}" > "${S}/bin/docker"
  chmod +x "${S}/bin/docker"
  local name want got
  while IFS='|' read -r name want; do
    _repo
    _produce
    case "${name}" in
      header) _tamper header-short ;;
      space) printf 'x\n' > "${W}/${MOD}/a b%é.go" ;;
    esac
    _run_admit
    assert_equal "${name}:${status}" "${name}:1"
    _admit_log "${stderr}" > "${S}/build.log"
    run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      bash "${runner}" --root "${S}/root"
    assert_equal "${name}:${status}" "${name}:1"
    assert_equal "${name}:${output}" "${name}:"
    [[ "${stderr}" != *"unregistered log body"* ]] || fail "${name}: unregistered log body: ${stderr}"
    got="$(jq -rR 'fromjson? | select(.body == "config_gen_manifest_stale")
      | .attributes.file + "|" + .attributes.reason' <<<"${stderr}")"
    assert_equal "${name}:${got}" "${name}:${want}"
    got="$(jq -rR 'fromjson? | select(.body == "config_gen_gate_admission_failed")
      | .attributes.gate + "|" + .attributes.status' <<<"${stderr}")"
    assert_equal "${name}:${got}" "${name}:admission|1"
  done <<ROWS
header|manifest|header
space|${MOD}/a%20b%25%C3%A9.go|unlisted
ROWS
}
