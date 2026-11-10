#!/usr/bin/env bash
#
# config_gen_readers.sh -- the files config-gen's host side reads, as a
# set of repo-relative paths, base#1584.
#
# Usage:
#   config_gen_readers.sh [--root <checkout>] [--by-channel]
#   config_gen_readers.sh [--root <checkout>] --jobs        # the config-gen jobs
#   config_gen_readers.sh [--root <checkout>] --run-blocks  # their run blocks
#
# The config-gen deny list (config_gen_paths.sh) may name a path only when
# this set does not hold it. The deny-list spec computes the set and fails
# on any overlap, so a file that becomes a config-gen reader cannot stay a
# reason to skip config-gen.
#
# What runs. The commands come from the parsed workflow, not from a hand
# list:
#   1. every `run:` block of every config-gen job of
#      .github/workflows/self-test.yaml, as the job runs it, except the one
#      whose only `./` command is script/ci/install-just.sh (it downloads a
#      binary). The config-gen jobs are the jobs whose `if:` reads
#      classify's select_config_gen key (config-gen-gates and the
#      config-gen-redpath matrix since base#1547). A `${{ matrix.<key> }}`
#      in a block runs it once per value of that matrix key, so the five
#      redpath shards together run every case (a subset would be a hand
#      list); any other expression is refused. No config-gen job, or one
#      with no run step, is refused too, so the set is never read from
#      nothing. --jobs and --run-blocks print the jobs and the expanded
#      blocks (the deny-list spec reads its rule (d) text from the latter);
#   2. every script/test/config_gen_steps/*.sh, with CONFIG_GEN_CTX set;
#   3. config_gen_redpath.sh's `_rp_copy`, whose copy is added file by file.
# The redpath's shared pass (its runner --steps-only on its own scratch
# copy) exits non-zero against the docker stub (20-gomod-oracle needs Go,
# measured at base#1584), and the redpath then runs no case. So each block
# runs with CONFIG_GEN_STEPS_VERDICT naming a verdict this script writes
# with the redpath's own _rp_copy and _rp_digest and checks with its own
# _rp_verdict_reusable, which is how `just test go` hands the gates'
# verdict on. Nothing traced is lost: the shared pass reads its scratch
# copy, outside <checkout>, and step 2 traces each step on the checkout.
# Everything runs in a scratch git copy of <checkout>, with a `docker` stub
# first on PATH and under `timeout`, so nothing is written to <checkout>. A
# step that fails against the stub is expected: only its trace is used.
#
# How a read is seen. Every bash process starts with BASH_ENV pointing at a
# tracer that writes to its own fd on two channels:
#   - DEBUG (`set -T`): the file each command ran from;
#   - xtrace (`BASH_XTRACEFD`, PS4 carrying $PWD): each `source` / `.`
#     command after expansion and before it runs, so a sourced file that
#     only defines functions, or does not parse, is still seen.
# Each path goes in twice, logical (`realpath -s -m`) and physical
# (`realpath -m`), made relative to the copy; a path outside it is
# dropped. --by-channel prints `<channel>\t<path>` lines (debug, xtrace,
# copy) instead of the bare set.
#
# xtrace sets `x` in `$-` for every traced script. No host-side file tests
# `$-` for `x` (only for `i` and `m`, measured at base#1584), so that
# changes no step's behaviour.
#
# A data read (`cat`, `<`) through a path built at runtime, a read inside
# the config-gen container and a daemon-side COPY are outside this set.
# Those are caught on main, which runs every job (base#1584).

set -euo pipefail

_CGR_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _CGR_SELF_DIR
# Per-command limit. config_gen_redpath.sh must run every case, and with
# docker stubbed it did not finish inside 300 s (r3's per-step limit)
# untraced; the whole traced run took 8m47s on a developer host
# (base#1584). The spec checks that the last case ran.
readonly _CGR_TIMEOUT=1800

_cgr_die() {
  printf 'config_gen_readers: %s\n' "$1" >&2
  exit 1
}

# _cgr_write_tracer <file> -- the BASH_ENV tracer.
_cgr_write_tracer() {
  cat >"$1" <<'TRACER'
if [[ -n "${CGR_TRACE_LOG:-}" ]]; then
  exec {__cgr_fd}>>"${CGR_TRACE_LOG}"
  __cgr_last=""
  set -T
  trap '[[ "${BASH_SOURCE[0]:-}" == "${__cgr_last}" ]] || { __cgr_last="${BASH_SOURCE[0]:-}"; printf "D\t%s\t%s\n" "${PWD}" "${__cgr_last}" >&"${__cgr_fd}"; }' DEBUG
  BASH_XTRACEFD=${__cgr_fd}
  PS4='+X	${PWD}	'
  set -x
fi
TRACER
}

# _cgr_traced <dir> <cmd>... -- runs <cmd> from <dir> under the tracer.
_cgr_traced() {
  local _dir="$1"
  shift
  (cd "${_dir}" && env -u CONFIG_GEN_REDPATH_ACTIVE BASH_ENV="${_cgr_tracer}" CGR_TRACE_LOG="${_cgr_fifo}" \
    PATH="${_cgr_bin}:${PATH}" GITHUB_OUTPUT=/dev/null CONFIG_GEN_STEPS_VERDICT="${_cgr_verdict}" \
    timeout "${_CGR_TIMEOUT}" "$@" </dev/null >/dev/null 2>&1) || true
}

# _cgr_jobs <workflow> -- the config-gen jobs, one per line: every job
# whose `if:` reads needs.classify.outputs.select_config_gen.
_cgr_jobs() {
  local _jobs
  _jobs="$(yq -o json '.jobs' "$1" | jq -r 'to_entries[]
      | select((.value.if // "") | tostring | test("needs\\.classify\\.outputs\\.select_config_gen\\b"))
      | .key')" || _cgr_die "cannot read the jobs of $1"
  [[ -n "${_jobs}" ]] || _cgr_die "no job of $1 gates on select_config_gen"
  printf '%s\n' "${_jobs}"
}

# _cgr_expand <block> <matrix-json> -- prints <block> base64-encoded, once
# per value of the one matrix key its `${{ matrix.<key> }}` names, or once
# when it holds no expression. Any other expression is refused.
_cgr_expand() {
  local _block="$1" _matrix="$2" _e _key="" _v _out
  local -a _exprs=() _vals=()
  while IFS= read -r _e; do
    [[ -n "${_e}" ]] || continue
    if [[ "${_e}" =~ ^\$\{\{[[:space:]]*matrix\.([A-Za-z0-9_-]+)[[:space:]]*\}\}$ ]] \
      && [[ -z "${_key}" || "${_key}" == "${BASH_REMATCH[1]}" ]]; then
      _key="${BASH_REMATCH[1]}"
      _exprs+=("${_e}")
    else
      _cgr_die "run block holds an expression this script cannot evaluate: ${_e}"
    fi
  done < <(grep -oE '\$\{\{[^}]*\}\}' <<<"${_block}" | sort -u || true)
  if [[ -z "${_key}" ]]; then
    printf '%s' "${_block}" | base64 -w0
    printf '\n'
    return 0
  fi
  mapfile -t _vals < <(jq -r --arg k "${_key}" '.[$k]
      | if type == "array" and all(.[]; type != "object" and type != "array")
        then .[] | tostring else empty end' <<<"${_matrix}")
  ((${#_vals[@]} > 0)) || _cgr_die "matrix.${_key} is not a list of values"
  for _v in "${_vals[@]}"; do
    _out="${_block}"
    for _e in "${_exprs[@]}"; do _out="${_out//"${_e}"/${_v}}"; done
    printf '%s' "${_out}" | base64 -w0
    printf '\n'
  done
}

# _cgr_blocks <workflow> -- every config-gen job's run blocks, expanded,
# one base64 line each.
_cgr_blocks() {
  local _wf="$1" _job _json _matrix _n _b
  local _jobs
  _jobs="$(_cgr_jobs "${_wf}")" || exit 1
  while IFS= read -r _job; do
    _json="$(CGR_JOB="${_job}" yq -o json '.jobs[strenv(CGR_JOB)]' "${_wf}")" \
      || _cgr_die "cannot read job ${_job}"
    _matrix="$(jq -c '.strategy.matrix // {}' <<<"${_json}")"
    _n="$(jq '[.steps[]? | select(has("run"))] | length' <<<"${_json}")"
    ((_n > 0)) || _cgr_die "config-gen job ${_job} has no run step"
    while IFS= read -r _b; do
      _cgr_expand "$(printf '%s' "${_b}" | base64 -d)" "${_matrix}" || exit 1
    done < <(jq -r '.steps[] | select(has("run")) | .run | @base64' <<<"${_json}")
  done <<<"${_jobs}"
}

# _cgr_run_blocks <copy> <workflow> -- step 1.
_cgr_run_blocks() {
  local _copy="$1" _wf="$2" _b _text _cmds _all
  _all="$(_cgr_blocks "${_wf}")" || exit 1
  while IFS= read -r _b; do
    _text="$(printf '%s' "${_b}" | base64 -d)"
    _cmds="$(grep -oE '(^|[^A-Za-z0-9_./-])\./[A-Za-z0-9_./-]+' <<<"${_text}" \
      | sed -E 's/^[^.]//' | sort -u)" || true
    [[ "${_cmds}" != "./script/ci/install-just.sh" ]] || continue
    printf '%s\n' "${_text}" >"${_cgr_work}/block.sh"
    _cgr_traced "${_copy}" bash "${_cgr_work}/block.sh"
  done <<<"${_all}"
}

# _cgr_run_steps <copy> -- step 2: every step in C-locale glob order,
# sharing one fresh CONFIG_GEN_CTX as config_gen_gates.sh runs them, but
# going on past a red step so each one is traced.
_cgr_run_steps() {
  local _copy="$1" _s
  rm -rf "${_cgr_work}/ctx"
  mkdir -p "${_cgr_work}/ctx"
  while IFS= read -r _s; do
    [[ -f "${_s}" ]] || continue
    _cgr_traced "${_copy}" env CONFIG_GEN_CTX="${_cgr_work}/ctx" bash "${_s}"
  done < <(LC_ALL=C compgen -G "${_copy}/script/test/config_gen_steps/*.sh" | LC_ALL=C sort)
}

# _cgr_rp_copy <copy> -- step 3: what _rp_copy copies, as paths.
_cgr_rp_copy() {
  local _copy="$1" _dst
  mkdir -p "${_cgr_work}/rp"
  # shellcheck disable=SC2016 # $1 is the child shell's own argument
  _dst="$(cd "${_copy}" && env -u CONFIG_GEN_REDPATH_ACTIVE bash -c \
    'source ./script/test/config_gen_redpath.sh && _rp_copy "$1"' _ "${_cgr_work}/rp" 2>/dev/null)" \
    || _cgr_die "_rp_copy failed"
  git -C "${_dst}" ls-files | sed 's/^/copy\t/'
}

# _cgr_write_verdict <copy> -- writes ${_cgr_verdict}: the steps verdict
# the redpath reuses in place of its shared pass, held to the redpath's
# own _rp_verdict_reusable so a change of its format fails here.
_cgr_write_verdict() {
  local _copy="$1"
  mkdir -p "${_cgr_work}/vd"
  # shellcheck disable=SC2016 # $1 and $2 are the child shell's own arguments
  (cd "${_copy}" && env -u CONFIG_GEN_REDPATH_ACTIVE bash -c '
    source ./script/test/config_gen_redpath.sh || exit 1
    p="$(_rp_copy "$1")" || exit 1
    _RP_PRISTINE_DIGEST="$(_rp_digest "${p}")" || exit 1
    printf "digest=%s steps=%s status=0\n" "${_RP_PRISTINE_DIGEST}" \
      "$(IFS=,; printf "%s" "${_RP_REUSED_STEPS[*]}")" >"$2"
    _rp_verdict_reusable "$2"' _ "${_cgr_work}/vd" "${_cgr_verdict}" >/dev/null 2>&1) \
    || _cgr_die "cannot write a steps verdict config_gen_redpath.sh reuses"
}

# _cgr_paths <copy> -- the filtered trace log as `<channel>\t<path>`,
# each path logical and physical, relative to <copy>, plus one
# `rp\t<function>\t<case>` line per config_gen_redpath.sh `_rp_*` call
# the trace saw, the evidence that its main ran every case.
_cgr_paths() {
  local _copy="$1" _tag _pwd _p _a
  local -a _w
  LC_ALL=C sort -u "${_cgr_log}" | while IFS=$'\t' read -r _tag _pwd _p; do
    case "${_tag}" in
      D) _tag=debug ;;
      R)
        read -r -a _w <<<"${_p}"
        printf 'rp\t%s\t%s\n' "${_w[0]}" "${_w[2]:-}"
        continue
        ;;
      X)
        _tag=xtrace
        _p="${_p#source }"
        _p="${_p#. }"
        _p="${_p%% *}"
        _p="${_p#\'}"
        _p="${_p%\'}"
        ;;
      *) continue ;;
    esac
    [[ -n "${_p}" && "${_p}" != "${_cgr_tracer}" ]] || continue
    [[ "${_p}" == /* ]] || _p="${_pwd}/${_p}"
    for _a in "$(realpath -s -m -- "${_p}")" "$(realpath -m -- "${_p}")"; do
      case "${_a}" in
        "${_copy}"/*) printf '%s\t%s\n' "${_tag}" "${_a#"${_copy}"/}" ;;
      esac
    done
  done
}

# _cgr_filter <fifo> <log> -- keeps only the tracer's DEBUG records, its
# xtrace `source` / `.` records and its xtrace `_rp_*` calls. Every traced
# bash writes to one FIFO and this one reader keeps the few lines that
# matter: the unfiltered trace of a full run was 13.5 million lines
# (1.8 GB, measured, base#1584). The match is not anchored to a line
# start: a write longer than PIPE_BUF from one process can split around a
# short record from another, and an unanchored match still finds the
# record. It can only find more, never fewer.
_cgr_filter() {
  grep -aoE $'(D\t/[^\t]*\t[^\t]+|\+X\t/[^\t]*\t((source|\\.) [^\t]+|_rp_[a-z_]+( [^\t]*)?))$' <"$1" \
    | sed -E $'s/^\\+X\t([^\t]*)\t(_rp_)/R\t\\1\t\\2/; s/^\\+X\t/X\t/' >"$2" || true
}

# _cgr_copy_checkout <root> <dst> -- a one-commit git copy of <root>.
_cgr_copy_checkout() {
  cp -R "$1/." "$2/"
  rm -rf "$2/.git"
  git -C "$2" init -q
  git -C "$2" add -A
  git -C "$2" -c user.name=config-gen-readers -c user.email=config-gen-readers@localhost \
    commit -q --no-verify --no-gpg-sign -m "config-gen readers copy"
  git -C "$2" update-ref refs/remotes/origin/main HEAD
}

main() {
  local _root="" _by_channel=0 _mode=trace
  while (($# > 0)); do
    case "$1" in
      --jobs | --run-blocks) _mode="${1#--}"; shift ;;
      --root) (($# >= 2)) || _cgr_die "--root needs a directory"; _root="$2"; shift 2 ;;
      --by-channel) _by_channel=1; shift ;;
      *) _cgr_die "unknown argument: $1" ;;
    esac
  done
  [[ -n "${_root}" ]] || _root="${_CGR_SELF_DIR}/../.."
  _root="$(cd -- "${_root}" && pwd -P)" || _cgr_die "no such checkout: ${_root}"
  local _wf="${_root}/.github/workflows/self-test.yaml"
  case "${_mode}" in
    jobs) _cgr_jobs "${_wf}"; return 0 ;;
    run-blocks)
      local _all _b
      _all="$(_cgr_blocks "${_wf}")" || exit 1
      while IFS= read -r _b; do printf '%s\n' "$(printf '%s' "${_b}" | base64 -d)"; done <<<"${_all}"
      return 0
      ;;
  esac

  _cgr_work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now; the dir is local to this run
  trap "rm -rf '${_cgr_work}'" EXIT
  local _copy="${_cgr_work}/root"
  mkdir -p "${_copy}" "${_cgr_work}/bin"
  _cgr_copy_checkout "${_root}" "${_copy}"
  _copy="$(cd -- "${_copy}" && pwd -P)"
  _cgr_tracer="${_cgr_work}/tracer.sh"
  _cgr_fifo="${_cgr_work}/trace.fifo"
  _cgr_log="${_cgr_work}/trace.log"
  _cgr_bin="${_cgr_work}/bin"
  _cgr_verdict="${_cgr_work}/steps.verdict"
  _cgr_write_tracer "${_cgr_tracer}"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${_cgr_bin}/docker"
  chmod +x "${_cgr_bin}/docker"
  mkfifo "${_cgr_fifo}"
  _cgr_filter "${_cgr_fifo}" "${_cgr_log}" &
  local _reader=$! _keep
  # Held open so the reader sees no end of file between two traced runs.
  exec {_keep}>"${_cgr_fifo}"

  _cgr_write_verdict "${_copy}"
  local _rc=0
  {
    _cgr_run_blocks "${_copy}" "${_copy}/.github/workflows/self-test.yaml"
    _cgr_run_steps "${_copy}"
  } || _rc=$?
  exec {_keep}>&-
  wait "${_reader}" || true
  ((_rc == 0)) || exit "${_rc}"

  local _out
  _out="$(_cgr_paths "${_copy}"; _cgr_rp_copy "${_copy}")" || exit 1
  if [[ "${_by_channel}" -eq 1 ]]; then
    LC_ALL=C sort -u <<<"${_out}"
  else
    grep -v $'^rp\t' <<<"${_out}" | cut -f2 | LC_ALL=C sort -u
  fi
}

main "$@"
