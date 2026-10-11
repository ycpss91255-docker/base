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
  assert_spec_subject "${WF_DIR}/${_wf}" "the safety net that labels externally-filed unlabeled issues"
  run _applied_labels "${_wf}"
  assert_success
  assert_line 'needs-triage'
  refute_line 'triage'
}
