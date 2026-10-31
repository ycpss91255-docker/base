#!/usr/bin/env bash
#
# 20-gomod-oracle.sh -- hold the pin registry's go.mod scanner to Go itself
# (base#1463).
#
# A config-gen step: script/test/config_gen_gates.sh runs it before the
# gates, in every environment `just test go` reaches, and the redpath runs
# it again on each scratch copy. It reads everything relative to its own
# root (three directories up), never the caller's checkout.
#
# _pin_go_mod_scan (script/watch/lib.sh) is a bash port of Go's modfile
# lexer, and a port drifts silently. So this runs `go mod edit -json` over
# every test/fixtures/gomod/*.mod in the golang image pinned under
# `# tool-pin: golang` in dockerfile/Dockerfile.config-gen -- one
# `docker run`, --network none, GOTOOLCHAIN=local, as the caller's uid --
# and holds each fixture to the class its first line declares:
#
#   // class: supported                       Go rc 0, scanner rc 0, and
#                                             Go, the scanner and
#                                             <name>.requires agree;
#   // class: policy-refused <event> <reason> Go rc 0, and the scanner
#                                             refuses with exactly that
#                                             event and reason;
#   // class: go-invalid [<event> <reason>]   Go rc != 0, and the scanner
#                                             refuses (with that event and
#                                             reason, when named).
#
# Refusals: a fixture with no class header is go_mod_fixture_unclassified,
# before docker runs; a disagreement is go_mod_oracle_mismatch (file=
# class= reason=), every fixture reported before the step fails; a
# Dockerfile with no golang pin is go_mod_oracle_pin_missing, with no
# docker call.
#
# The container's answer, per fixture: `fixture<TAB><name>.mod<TAB><go rc>`,
# then the gomod-oracle/requires.go helper's `require` lines for it.
#
# Exit: 0 every fixture agrees; 1 otherwise.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_GMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _GMO_DIR
_GMO_ROOT="$(cd -- "${_GMO_DIR}/../../.." && pwd -P)"
readonly _GMO_ROOT
# shellcheck source=dist/script/docker/lib/log.sh
source "${_GMO_ROOT}/dist/script/docker/lib/log.sh"
# shellcheck source=script/watch/lib.sh
source "${_GMO_ROOT}/script/watch/lib.sh"

readonly _GMO_SERVICE='config-gen'
readonly _GMO_FIXTURES_REL='test/fixtures/gomod'
readonly _GMO_HELPER_REL='script/test/config_gen_steps/gomod-oracle'
readonly _GMO_HEADER_RE='^// class: (supported|policy-refused ([a-z_]+) ([a-z_0-9]+)|go-invalid( ([a-z_]+) ([a-z_0-9]+))?)$'

# What runs inside the golang image: build the helper, then one
# `go mod edit -json` per fixture. Go's own message goes to stderr.
# shellcheck disable=SC2016 # expanded by the container's shell, not here.
readonly _GMO_CONTAINER_SCRIPT='set -eu
mkdir -p /tmp/w
cd /tmp/w
tar -xf -
go build -o /tmp/requires "./'"${_GMO_HELPER_REL}"'/requires.go"
for f in ./'"${_GMO_FIXTURES_REL}"'/*.mod; do
  rc=0
  go mod edit -json "$f" >/tmp/mod.json 2>/tmp/mod.err || rc=$?
  printf "fixture\t%s\t%s\n" "${f##*/}" "$rc"
  if [ "$rc" -eq 0 ]; then /tmp/requires </tmp/mod.json; else sed "s|^|${f##*/}: |" /tmp/mod.err >&2; fi
done'

# _gmo_image -- the value of the line under `# tool-pin: golang` in
# Dockerfile.config-gen; empty when there is no such pin.
_gmo_image() {
  local line marked=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if (( marked )); then
      _pin_assign_value "${line}" || true
      return 0
    fi
    [[ "${line}" =~ ^#[[:space:]]*tool-pin:[[:space:]]+golang[[:space:]] ]] && marked=1
  done < "${_GMO_ROOT}/dockerfile/Dockerfile.config-gen"
  return 0
}

# _gmo_mismatch <file> <class> <reason> <text> -- one disagreement.
_gmo_mismatch() {
  _log_err "${_GMO_SERVICE}" go_mod_oracle_mismatch "file=${1}" "class=${2}" "reason=${3}" \
    "display=go_mod_oracle_mismatch: ${1} (${2}): ${4}"
}

main() {
  local image fx f name header tmp go_rc rc=0 failed=0
  local kind a b c cur="" scan scan_rc event reason want got got_go got_scan
  local -a fixtures=()
  local -A class=() want_event=() want_reason=() go_status=() go_req=()

  image="$(_gmo_image)"
  if [[ -z "${image}" ]]; then
    _log_err "${_GMO_SERVICE}" go_mod_oracle_pin_missing \
      "file=dockerfile/Dockerfile.config-gen" \
      "display=go_mod_oracle_pin_missing: dockerfile/Dockerfile.config-gen has no value under '# tool-pin: golang'; there is no pinned Go to hold the scanner to"
    return 1
  fi

  fx="${_GMO_ROOT}/${_GMO_FIXTURES_REL}"
  mapfile -t fixtures < <(LC_ALL=C compgen -G "${fx}/*.mod" | LC_ALL=C sort)
  if (( ${#fixtures[@]} == 0 )); then
    _gmo_mismatch "${_GMO_FIXTURES_REL}" - no_fixtures "no fixture to hold the scanner to"
    return 1
  fi

  # Every fixture carries Go's verdict in its first line; one that does not
  # would be skipped by every comparison below, so it fails first.
  for f in "${fixtures[@]}"; do
    name="${f##*/}"
    header="$(head -n1 -- "${f}")"
    if [[ ! "${header}" =~ ${_GMO_HEADER_RE} ]]; then
      _log_err "${_GMO_SERVICE}" go_mod_fixture_unclassified "file=${_GMO_FIXTURES_REL}/${name}" \
        "display=go_mod_fixture_unclassified: ${_GMO_FIXTURES_REL}/${name} does not open with '// class: supported|policy-refused <event> <reason>|go-invalid [<event> <reason>]'"
      failed=1
      continue
    fi
    class["${name}"]="${BASH_REMATCH[1]%% *}"
    want_event["${name}"]="${BASH_REMATCH[2]}${BASH_REMATCH[5]}"
    want_reason["${name}"]="${BASH_REMATCH[3]}${BASH_REMATCH[6]}"
  done
  (( failed == 0 )) || return 1

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${tmp} now; it is local to main
  trap "rm -rf '${tmp}'" EXIT
  tar -C "${_GMO_ROOT}" -cf "${tmp}/in.tar" "${_GMO_FIXTURES_REL}" "${_GMO_HELPER_REL}"
  docker run --rm -i --network none --user "$(id -u):$(id -g)" \
    -e GOTOOLCHAIN=local -e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOFLAGS= \
    --entrypoint /bin/sh "${image}" -c "${_GMO_CONTAINER_SCRIPT}" \
    < "${tmp}/in.tar" > "${tmp}/go.out" 2> "${tmp}/go.err" || rc=$?
  if (( rc != 0 )); then
    cat "${tmp}/go.err" >&2
    _gmo_mismatch "${_GMO_FIXTURES_REL}" - go_run_status "the golang container exited ${rc} before answering for every fixture"
    return 1
  fi

  while IFS=$'\t' read -r kind a b c; do
    case "${kind}" in
      fixture)
        cur="${a}"
        go_status["${cur}"]="${b}"
        go_req["${cur}"]=""
        ;;
      require)
        [[ -n "${cur}" ]] && go_req["${cur}"]+="${a}"$'\t'"${b}"$'\t'"${c}"$'\n'
        ;;
    esac
  done < "${tmp}/go.out"

  # One verdict per class, each a single condition, so a fixture either
  # agrees with its header on every point or is reported with what each
  # side answered. A fixture Go did not answer for agrees with no class.
  for f in "${fixtures[@]}"; do
    name="${f##*/}"
    go_rc="${go_status["${name}"]:-none}"
    scan_rc=0
    scan="$(LOG_FORMAT=json _pin_go_mod_scan "${f}" 2> "${tmp}/scan.err")" || scan_rc=$?
    event="$(sed -n '/"body":"/{s/.*"body":"\([^"]*\)".*/\1/p;q}' "${tmp}/scan.err")"
    reason="$(sed -n '/"reason":"/{s/.*"reason":"\([^"]*\)".*/\1/p;q}' "${tmp}/scan.err")"
    got="Go rc ${go_rc}, scanner rc ${scan_rc}${event:+ (${event} ${reason})}"
    case "${class["${name}"]}" in
      supported)
        want="$(cat -- "${f%.mod}.requires" 2>/dev/null)" || want="(no ${name%.mod}.requires)"
        got_go="$(printf '%s' "${go_req["${name}"]:-}" | awk -F'\t' '$3 == "false" {print $1 "\t" $2} $3 != "false" {print "indirect:" $1}')"
        got_scan="$(cut -f2,3 <<< "${scan}")"
        if [[ "${go_rc}" != 0 || "${scan_rc}" != 0 || "${got_go}" != "${want}" || "${got_scan}" != "${want}" ]]; then
          _gmo_mismatch "${_GMO_FIXTURES_REL}/${name}" supported requires \
            "${got}; Go read [${got_go//$'\n'/; }], the scanner read [${got_scan//$'\n'/; }], ${name%.mod}.requires holds [${want//$'\n'/; }]"
          failed=1
        fi
        ;;
      policy-refused)
        if [[ "${go_rc}" != 0 || "${scan_rc}" != 1 || "${event}" != "${want_event["${name}"]}" || "${reason}" != "${want_reason["${name}"]}" ]]; then
          _gmo_mismatch "${_GMO_FIXTURES_REL}/${name}" policy-refused verdict \
            "${got}; the header wants Go rc 0 and a refusal as ${want_event["${name}"]} ${want_reason["${name}"]}"
          failed=1
        fi
        ;;
      go-invalid)
        if [[ ! "${go_rc}" =~ ^[1-9][0-9]*$ || "${scan_rc}" != 1 \
              || ( -n "${want_event["${name}"]}" && ( "${event}" != "${want_event["${name}"]}" || "${reason}" != "${want_reason["${name}"]}" ) ) ]]; then
          _gmo_mismatch "${_GMO_FIXTURES_REL}/${name}" go-invalid verdict \
            "${got}; the header wants Go to reject it and the scanner to refuse it${want_event["${name}"]:+ as ${want_event["${name}"]} ${want_reason["${name}"]}}"
          failed=1
        fi
        ;;
    esac
  done
  (( failed == 0 )) || return 1
  printf 'gomod-oracle: %d fixture(s) agree with %s\n' "${#fixtures[@]}" "${image%%@*}"
}

main "$@"
