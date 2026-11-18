#!/usr/bin/env bats
#
# triage_label_yaml_spec.bats -- the labels this repo's workflows APPLY are
# labels its own vocabulary defines.
#
# `doc/agents/triage-labels.md` is the authority for the label vocabulary,
# and it is prose. A workflow that applies a label is the one place the
# vocabulary is written as CODE, so it is the one place the two can disagree
# without anybody noticing -- and they did. `triage` was renamed in place to
# `needs-triage` when the tracker was migrated, the doc recorded that "no
# label named `triage` remains", and `.github/workflows/triage-label.yaml`
# went on applying `triage` to every externally-filed unlabeled issue. The
# GitHub API CREATES a label named in `addLabels` when the repo has none, so
# each such issue silently recreated the label the rename had retired, under
# GitHub's default grey and with no description. Two open issues were
# carrying it, and deleting the label by hand fixes nothing: the next
# unlabeled issue brings it back (base#1182).
#
# So the subject is DERIVED and not declared. A workflow belongs to the
# population if, on a code line, it applies a label -- `addLabels`, or
# `gh issue edit --add-label`. Keying on the OPERATION rather than on a
# filename is what `ghcr_publish_surface_spec.bats` does for publishers and
# `ghcr_cleanup_yaml_spec.bats` for deletions, and the reason is the same: a
# second workflow that grew the same call would inherit a gate nobody
# applied to it, and a declared path would still be reporting clean.
#
# The expected set is DERIVED too, out of the doc's own table rather than
# listed here. A roster copied into a spec is a second place to update, and
# the whole defect being gated is two places disagreeing.
#
# ZERO workflows in the population is a REFUSAL, not a pass. A gate over an
# empty population is not a passing gate, it is no gate: the labelling
# workflow being deleted or its call renamed is exactly the move that would
# otherwise turn every case here green.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  REPO=/source
  WF_DIR="${REPO}/.github/workflows"
  LABEL_DOC="${REPO}/doc/agents/triage-labels.md"
}

# _state_roles -- the state labels doc/agents/triage-labels.md defines, one
# per line, read out of the role table at the top of the file. The table
# rows are '| `<role>` | `<colour>` | <description> |'; the colour cell is
# what tells a role row from any other two-pipe line in the document.
_state_roles() {
  sed -n 's/^| *`\([a-z-][a-z-]*\)` *| *`[0-9a-fA-F]\{6\}` *|.*/\1/p' \
    "${LABEL_DOC}"
}

# _label_appliers -- the workflows that APPLY a label, derived from the
# tree. Comment lines are dropped first: this spec's own subject is named in
# prose inside those workflows, and a commented example is not a call.
_label_appliers() {
  local _f
  for _f in "${WF_DIR}"/*.y*ml; do
    [[ -f "${_f}" ]] || continue
    if sed -e 's/^[[:space:]]*#.*$//' "${_f}" \
      | grep -qE 'addLabels|--add-label'; then
      printf '%s\n' "${_f##*/}"
    fi
  done
}

# _applied_labels <workflow> -- every label literal the workflow hands to a
# label-applying call, one per line. Reads the quoted strings out of a
# `labels: [...]` array and the operands of `--add-label`.
#
# Comment LINES go first and the rest is then joined into ONE line. Both
# halves are load-bearing. A `labels: [...]` array is routinely written
# across several lines, and reading line by line found neither the opening
# bracket nor the strings inside it; joining first is what makes the array
# readable at all. But joining also drags comment prose into the same line
# as code, so a commented-out example would read as a call -- hence the
# comment strip before, not after.
#
# The operand of `--add-label` is matched with its quotes INTACT and
# unquoted afterwards. Matching the opening quote and not the closing one
# produced a span the second pass could not read, so a workflow spelling it
# `--add-label "triage"` was discovered as an applier and then yielded no
# labels at all -- which the vocabulary case below would have passed. That
# is the reason _extraction_ is asserted separately and not inferred from a
# clean comparison.
_applied_labels() {
  local _f="${WF_DIR}/${1}" _flat
  _flat="$(grep -vE '^[[:space:]]*#' "${_f}" | tr '\n' ' ')"
  {
    printf '%s\n' "${_flat}" \
      | grep -oE 'labels:[[:space:]]*\[[^]]*\]' \
      | grep -oE "'[^']+'|\"[^\"]+\"" \
      | sed -e "s/^['\"]//" -e "s/['\"]\$//"
    printf '%s\n' "${_flat}" \
      | grep -oE -- "--add-label[=[:space:]]+('[^']+'|\"[^\"]+\"|[A-Za-z][A-Za-z0-9:_.-]*)" \
      | sed -e 's/^--add-label[=[:space:]]*//' -e "s/^['\"]//" -e "s/['\"]\$//"
  } | grep -vE '^[[:space:]]*$'
}

# why: The population this file's cases read. A declared filename was the
# first half of base#1089 and base#1115: the hazard belongs to the
# operation, so a second workflow growing an addLabels call must join
# the population rather than inherit a gate nobody applied to it. Zero
# is refused because a gate over an empty population is no gate -- it
# is the state that would turn every case below green for free
@test "triage-label: at least one workflow applies a label, and the scan finds it" {
  assert_spec_subject_dir "${WF_DIR}" "the workflow tree this spec derives its population from"
  assert_spec_subject "${LABEL_DOC}" "the label vocabulary this spec checks workflows against"
  run _label_appliers
  assert_success
  [ -n "${output}" ]
}

# why: The doc's table is the authority and this spec must read it, not a
# copy of it. If the derivation stops matching the table's shape it
# returns nothing, every label compares against an empty set, and the
# cases below fail open -- so the roster is asserted to be the six
# states the vocabulary documents before anything is compared to it
@test "triage-label: the state roles are derived from the label doc, not copied" {
  assert_spec_subject "${LABEL_DOC}" "the label vocabulary this spec reads its roster out of"
  run _state_roles
  assert_success
  assert_line 'needs-triage'
  assert_line 'needs-info'
  assert_line 'ready-for-agent'
  assert_line 'ready-for-human'
  assert_line 'wontfix'
  assert_line 'needs-decision'
  [ "${#lines[@]}" -eq 6 ]
}

# why: The gate's fail-closed half, and the one it was missing. A workflow
# is discovered by the call it makes and read by a separate pattern, so
# the two can disagree: discovered, then unreadable, yields an empty
# label set, and an empty set compares clean against any vocabulary. A
# workflow spelling the operand `--add-label "triage"` passed exactly
# that way. Unreadable is a REFUSAL, so the next spelling nobody
# anticipated fails loudly instead of being waved through
@test "triage-label: every discovered applier yields at least one label" {
  local _wf _n _bad=()
  while read -r _wf; do
    [[ -n "${_wf}" ]] || continue
    _n="$(_applied_labels "${_wf}" | grep -c . || true)"
    (( _n > 0 )) && continue
    _bad+=( "${_wf}" )
  done < <(_label_appliers)
  if (( ${#_bad[@]} > 0 )); then
    printf 'applies a label the extractor cannot read:\n' >&2
    printf '  %s\n' "${_bad[@]}" >&2
  fi
  [ "${#_bad[@]}" -eq 0 ]
}

# why: The two spellings the first extractor silently dropped, pinned as
# data rather than left to the live tree -- neither is in this repo
# today, so nothing here would fail if the patterns regressed. A quoted
# operand and a multi-line array are both ordinary YAML, and both read
# as zero labels, which the vocabulary case passes
@test "triage-label: a quoted operand and a multi-line array are both read" {
  local _dir="${BATS_TEST_TMPDIR}/wf"
  mkdir -p "${_dir}"
  WF_DIR="${_dir}"
  printf '%s\n' 'run: gh issue edit 1 --add-label "triage"' > "${_dir}/q.yaml"
  printf '%s\n' 'run: gh issue edit 1 --add-label triage' > "${_dir}/u.yaml"
  printf '%s\n' 'labels: [' "  'triage'," '  "other"' ']' > "${_dir}/m.yaml"
  run _applied_labels q.yaml
  assert_success
  assert_line 'triage'
  run _applied_labels u.yaml
  assert_success
  assert_line 'triage'
  run _applied_labels m.yaml
  assert_success
  assert_line 'triage'
  assert_line 'other'
}

# why: The defect itself, stated as the invariant it broke. The API CREATES
# a label an addLabels call names when the repo has none, so a workflow
# applying a string outside the vocabulary does not fail -- it mints a
# label the doc says does not exist, on GitHub's default grey, once per
# issue. Deleting the label by hand cannot fix that; this is the only
# place the recurrence can be closed (base#1182)
@test "triage-label: every label a workflow applies is one the vocabulary defines" {
  local _wf _label _roles _bad=()
  _roles="$(_state_roles)"
  [ -n "${_roles}" ]
  while read -r _wf; do
    [[ -n "${_wf}" ]] || continue
    while read -r _label; do
      [[ -n "${_label}" ]] || continue
      grep -qxF -- "${_label}" <<< "${_roles}" && continue
      _bad+=( "${_wf} applies '${_label}'" )
    done < <(_applied_labels "${_wf}")
  done < <(_label_appliers)
  if (( ${#_bad[@]} > 0 )); then
    printf 'label(s) outside doc/agents/triage-labels.md:\n' >&2
    printf '  %s\n' "${_bad[@]}" >&2
  fi
  [ "${#_bad[@]}" -eq 0 ]
}

# why: The intake role has one spelling and the rename chose it. Naming the
# label positively, and not merely "something in the table", is what
# keeps a later edit from swapping the safety net onto ready-for-agent
# or wontfix -- both of which are in the table and neither of which is
# what an unlabeled externally-filed issue is waiting for
@test "triage-label: the unlabeled-issue safety net applies the intake role" {
  local _wf="triage-label.yaml"
  assert_spec_subject "${WF_DIR}/${_wf}" "the safety net that keeps a state label on every issue"
  run _applied_labels "${_wf}"
  assert_success
  assert_line 'needs-triage'
  refute_line 'triage'
}

# why: The rule is "exactly one state label", and a label set changes on
# three events, not one. Triggering on `opened` alone never sees a state
# label being removed, so an issue whose last state label is taken off
# stays stateless for good; `labeled` alone misses that same removal.
# Only all three keep the net in front of every change (base#1713)
@test "triage-label: the safety net runs on opened, labeled and unlabeled" {
  local _wf="${WF_DIR}/triage-label.yaml"
  assert_spec_subject "${_wf}" "the safety net that keeps a state label on every issue"
  run yq '.on.issues.types[]' "${_wf}"
  assert_success
  assert_line 'opened'
  assert_line 'labeled'
  assert_line 'unlabeled'
  [ "${#lines[@]}" -eq 3 ]
}

# why: The old gate asked "any label at all?" while the rule is about STATE
# labels, so a kind label alone (`enhancement`, set by the to-issues flow
# at creation) skipped the job and left the issue stateless. Which labels
# count is the step's business, read at run time; the job itself may only
# refuse a closed issue. Asserted positively, so `!labels[0]`,
# `labels.length == 0`, `toJSON(...) == '[]'` and a step-level gate all
# fail it, not just today's spelling (base#1713)
@test "triage-label: the job is gated only on the issue being open" {
  local _wf="${WF_DIR}/triage-label.yaml"
  assert_spec_subject "${_wf}" "the safety net that keeps a state label on every issue"
  run yq '.jobs | length' "${_wf}"
  assert_success
  assert_output '1'
  run yq '.jobs.label.if' "${_wf}"
  assert_success
  assert_output "github.event.issue.state == 'open'"
  run yq '[.jobs.label.steps[] | select(has("if"))] | length' "${_wf}"
  assert_success
  assert_output '0'
}

# _triage_step_for <labels-json> -- run the workflow's own labelling step
# against one label set, with `gh` stubbed on PATH. The stub serves
# <labels-json> to `gh api` and appends every argv it is given, one call per
# line, to ${BATS_TEST_TMPDIR}/gh.log. The fixture reaches the step ONLY
# through that `gh api` answer, never the event payload. Exit 2 when the
# workflow declares no such step: an empty body is not a passing step.
_TRIAGE_STEP='Add needs-triage when no state label is set'
_triage_step_for() {
  local _labels="${1}" _body _dir="${BATS_TEST_TMPDIR}/triage"
  _body="$(yaml_step_run "${WF_DIR}/triage-label.yaml" label "${_TRIAGE_STEP}")" || {
    printf 'BUG: yq could not read the labelling step\n'
    return 2
  }
  if [[ -z "${_body}" || "${_body}" == 'null' ]]; then
    printf 'BUG: triage-label.yaml declares no step named %s in its label job\n' \
      "${_TRIAGE_STEP}"
    return 2
  fi
  rm -rf "${_dir}"
  mkdir -p "${_dir}/bin"
  printf '%s\n' "${_body}" > "${_dir}/step.sh"
  printf '%s\n' "${_labels}" > "${_dir}/labels.json"
  : > "${BATS_TEST_TMPDIR}/gh.log"
  cat > "${_dir}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GH_LOG}"
if [[ "${1:-}" == 'api' ]]; then
  [[ -z "${STUB_GH_API_FAIL:-}" ]] || exit 1
  cat "${STUB_LABELS}"
fi
exit 0
STUB
  chmod +x "${_dir}/bin/gh"
  PATH="${_dir}/bin:${PATH}" \
  STUB_GH_LOG="${BATS_TEST_TMPDIR}/gh.log" \
  STUB_LABELS="${_dir}/labels.json" \
  GH_TOKEN=stub REPO=ycpss91255-docker/base ISSUE=4242 \
    bash "${_dir}/step.sh" 2>&1
}

# why: The rule is "exactly one state label" and the roster is the doc's
# table, so the predicate is a count of roster names in the label set the
# issue carries NOW. No state label, whatever else is there (a kind label
# set at creation, or the last state just removed), gets the intake role;
# any one role from the doc -- read here, not from the step's own copy --
# gets nothing. An unconditional add, an inverted gate, a counter that only
# looks for needs-triage and a hand-copied roster missing a role all fail
# one half of this (base#1713)
@test "triage-label: a label set with no state label gets needs-triage, one with a state label does not" {
  assert_spec_subject "${WF_DIR}/triage-label.yaml" "the safety net that keeps a state label on every issue"
  local _fx _role _roles
  for _fx in '[]' '[{"name":"enhancement"}]'; do
    run _triage_step_for "${_fx}"
    assert_success
    run grep -c '^issue edit' "${BATS_TEST_TMPDIR}/gh.log"
    assert_output '1'
    run grep -cxF 'issue edit 4242 --repo ycpss91255-docker/base --add-label needs-triage' \
      "${BATS_TEST_TMPDIR}/gh.log"
    assert_output '1'
  done
  _roles="$(_state_roles)"
  [ -n "${_roles}" ]
  while IFS= read -r _role; do
    run _triage_step_for "[{\"name\":\"enhancement\"},{\"name\":\"${_role}\"}]"
    assert_success
    run grep -c '^issue edit' "${BATS_TEST_TMPDIR}/gh.log"
    assert_output '0'
  done <<< "${_roles}"
}

# why: The rule is "exactly one state label", and the common way to break
# it is moving an issue on without taking the intake role off: adding
# ready-for-agent while needs-triage is still set leaves two states, and an
# agent picking ready-for-agent work is handed an issue that is also still
# untriaged. needs-triage next to ANY other role from the doc's table --
# read here, not from the step's own copy -- is the leftover, so the step
# removes it and makes no other edit; the later role is the decision
# (base#1713)
@test "triage-label: needs-triage left beside another state label is removed" {
  assert_spec_subject "${WF_DIR}/triage-label.yaml" "the safety net that keeps a state label on every issue"
  local _role _roles _n=0
  _roles="$(_state_roles)"
  [ -n "${_roles}" ]
  while IFS= read -r _role; do
    [[ "${_role}" == 'needs-triage' ]] && continue
    _n=$((_n + 1))
    run _triage_step_for "[{\"name\":\"enhancement\"},{\"name\":\"needs-triage\"},{\"name\":\"${_role}\"}]"
    assert_success
    run grep -c '^issue edit' "${BATS_TEST_TMPDIR}/gh.log"
    assert_output '1'
    run grep -cxF 'issue edit 4242 --repo ycpss91255-docker/base --remove-label needs-triage' \
      "${BATS_TEST_TMPDIR}/gh.log"
    assert_output '1'
  done <<< "${_roles}"
  [ "${_n}" -eq 5 ]
}

# why: The step decides from a label read, and an API error is not an
# answer. Reading a failed `gh api` as an empty set (`|| true`,
# `|| echo '[]'`) would see "no state label" on an issue that carries
# ready-for-agent and add needs-triage to it, breaking the very rule this
# net enforces. A failed read fails the step and edits nothing (base#1713)
@test "triage-label: a failed label read adds nothing" {
  assert_spec_subject "${WF_DIR}/triage-label.yaml" "the safety net that keeps a state label on every issue"
  STUB_GH_API_FAIL=1 run _triage_step_for '[{"name":"ready-for-agent"}]'
  assert_failure
  [ "${status}" -ne 2 ]
  run grep -c '^issue edit' "${BATS_TEST_TMPDIR}/gh.log"
  assert_output '0'
}
