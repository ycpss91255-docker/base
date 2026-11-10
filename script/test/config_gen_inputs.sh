#!/usr/bin/env bash
#
# config_gen_inputs.sh -- the digest of what a config-gen step reads
# (base#1547).
#
# Sourced, never run. config_gen_gates.sh and config_gen_redpath.sh both
# read it, so the runner and the redpath compute one digest the same way:
# the redpath hands a case's runner a step's verdict only while that digest,
# taken on the planted copy, is the one a pristine copy gives.
#
#   _cg_inputs_digest <step>...
#       run from a root, prints the digest D of the named steps: sha256 over
#       `<relpath>\0<sha256 of content>\n` for each file, C-sorted, the
#       files being each step's .sh, its .inputs and every path that .inputs
#       lists, a directory expanded to each file under it. A listed path
#       that does not exist is config_gen_usage_invalid, status 2.
#
# Requires log.sh to be sourced first.
#
# Style: Google Shell Style Guide.

_cg_inputs_digest() {
  local step dir='script/test/config_gen_steps' path found
  local -a files=()
  for step in "$@"; do
    files+=("${dir}/${step}.sh" "${dir}/${step}.inputs")
    while IFS= read -r path || [[ -n "${path}" ]]; do
      [[ -n "${path}" ]] || continue
      # A missing path would add nothing to D, so the declaration would
      # cover less than it says while D still matched (base#1547).
      if [[ ! -e "${path}" ]]; then
        _log_err config-gen config_gen_usage_invalid "step=${step}" "path=${path}" \
          "display=config_gen_gates.sh: ${step}.inputs lists ${path}, which does not exist"
        return 2
      fi
      found="$(find "${path}" -type f)" || return 1
      [[ -z "${found}" ]] || mapfile -t -O "${#files[@]}" files <<<"${found}"
    done <"${dir}/${step}.inputs"
  done
  local -a sorted=() sums=()
  local out sum i
  mapfile -t sorted < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort -u)
  # One sha256sum over every file, its lines in argument order, rather than
  # one sha256sum and one cut per file: the redpath takes D once per case,
  # and ~1000 forks a case made D most of a whole-table run's time
  # (base#1547). D is byte-for-byte the one the per-file loop gave.
  out="$(sha256sum -- "${sorted[@]}")" || return 1
  mapfile -t sums <<<"${out}"
  (( ${#sums[@]} == ${#sorted[@]} )) || return 1
  for i in "${!sorted[@]}"; do
    # A name holding a backslash is printed with a leading one (GNU).
    sum="${sums[i]%% *}"
    sum="${sum#\\}"
    printf '%s\0%s\n' "${sorted[i]}" "${sum}"
  done | sha256sum | cut -d' ' -f1
}
