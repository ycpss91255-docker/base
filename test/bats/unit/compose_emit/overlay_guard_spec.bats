#!/usr/bin/env bats
#
# Forward-invariant guard (ADR-00000022): base's emitted compose.yaml must
# never bake a hardcoded per-instance literal over the known per-instance
# field set. Every field that can collide across co-located instances is
# emitted as an overlay-overridable compose interpolation (${VAR:-default}
# or ${VAR}), so a multi_run .env overlay can isolate an instance without a
# retroactive base change. This turns "base-generated stacks are
# multi_run-expandable" from discipline into a machine-enforced guarantee:
# a future change that hardcodes a per-instance field fails here immediately.
#
# The override channels differ by field kind (recorded in ADR-00000022):
#   - structural interpolation (${VAR}): project name, network_mode,
#     ports -- checked here.
#   - not emitted at all: container_name. A container name is namespaced by
#     the daemon rather than by the project, so no value of it is
#     per-instance safe and the guard asserts its absence.
#   - .env env_file overlay + baked ENV: workload env vars (ROS_DOMAIN_ID
#     and friends).
#   - compose-merge overlay: writable volume topology.
#   - host-bound / shared across co-located instances (NOT per-instance):
#     runtime, hostname, GPU.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS headless
EOF
  mkdir -p "${TEMP_DIR}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# A per-instance field value is overlay-overridable iff it carries a compose
# ${...} interpolation (an .env overlay can override it), not a fully-baked
# literal. This is the guard's discrimination predicate.
_is_overlay_overridable() {
  [[ "$1" == *'${'*'}'* ]]
}

# A scan that found nothing is not a pass. Every absence claim below runs
# through this: the emission must exist and be non-empty (an emitter that
# returned 0 having written no file is a failure, not a clean scan), and
# grep's status is pinned to exactly 1. `|| true` and `assert_failure` both
# let exit 2 -- "no such file, nothing scanned" -- read as "no match".
_require_emission() {
  [[ -s "${COMPOSE_OUT}" ]] || fail \
    "${COMPOSE_OUT} is absent or empty -- the emitter returned without writing it, so nothing below scanned anything"
}

# _require_emitted_population
#   A non-empty file is not yet a population. An absence claim is only worth
#   as much as the emission it scanned, so before ANY such claim this proves
#   the emission actually CARRIES the thing being judged: the services: map,
#   and a service block for every stage the fixture Dockerfile declares that
#   the emitter is contracted to emit.
#
#   The expected set is DERIVED from the fixture this file itself wrote, and
#   derived by an INDEPENDENT parser -- the awk below -- never by the
#   emitter's own `_parse_dockerfile_stages`. A drift in that parser that
#   enumerated nothing is precisely the failure this floor exists to catch,
#   and a floor computed by the subject would go quiet in step with it: with
#   the parser stubbed to emit no stages AND `container_name:` re-added to
#   the stage emitter, the absence claims below passed while the shipped
#   emitter baked the directive.
_require_emitted_population() {
  _require_emission
  grep -qE '^services:' "${COMPOSE_OUT}" || fail \
    "no services: map in ${COMPOSE_OUT} -- the emitter wrote a header and nothing else, so every absence claim over it is vacuous"

  # Every `FROM <x> AS <name>` in the fixture, by an independent parser.
  local -a _stages=()
  local _s
  while IFS= read -r _s; do
    _stages+=("${_s}")
  done < <(awk 'tolower($1) == "from" {
                  for (i = 2; i < NF; i++)
                    if (tolower($i) == "as") print $(i + 1)
                }' "${TEMP_DIR}/Dockerfile")

  # The floor on the floor: the parser above must have found every stage the
  # fixture declares. Derived by counting the fixture's own AS lines, so
  # there is no threshold here to fall out of date.
  local _declared
  _declared="$(grep -cE '^FROM .+ [Aa][Ss] .+$' "${TEMP_DIR}/Dockerfile")"
  (( ${#_stages[@]} == _declared && _declared > 0 )) || fail \
    "the fixture Dockerfile declares ${_declared} named stage(s) but this floor's own parser found ${#_stages[@]}: the floor cannot be trusted"

  # sys and devel-base are build intermediates the emitter contractually
  # never turns into services; devel-test is emitted under the legacy
  # service name `test`. That mapping is the emitter's published contract
  # (ADR-00000022), not a re-derivation of its internals.
  local -a _expected=()
  for _s in "${_stages[@]}"; do
    case "${_s}" in
      sys|devel-base) continue ;;
      devel-test) _s="test" ;;
    esac
    _expected+=("${_s}")
  done
  (( ${#_expected[@]} > 0 )) || fail \
    "the fixture declares no emittable stage: the exercised emission has no service population to judge"

  for _s in "${_expected[@]}"; do
    grep -qE "^  ${_s}:\$" "${COMPOSE_OUT}" || fail \
      "no '  ${_s}:' block in the emitted compose, though the fixture Dockerfile declares that stage -- the emitter enumerated no service for it, so an absence claim over this emission observed nothing"
  done
}

# _assert_emitted_without <extended-regex> <what>
#   Assert the emitted compose carries no line matching the pattern, over an
#   emission proven to carry the service population the claim is about, with
#   grep's status pinned to 1 (no match).
_assert_emitted_without() {
  local _pattern="${1:?}" _what="${2:?}"
  _require_emitted_population
  local _found _rc=0
  _found="$(grep -nE "${_pattern}" "${COMPOSE_OUT}")" || _rc=$?
  if (( _rc == 0 )); then
    echo "${_what} present in the emitted compose:"
    echo "${_found}"
    return 1
  fi
  (( _rc == 1 )) || fail \
    "grep exited ${_rc} scanning ${COMPOSE_OUT} for ${_what}: nothing was scanned, so absence was never observed"
}

# _every_claim_states_the_exemption <file>
#   True iff EVERY paragraph of <file> that states the invariant names the
#   field-deploy emitter -- in that paragraph or in the one immediately
#   after it. Proximity, not co-occurrence: a document may name the deploy
#   recipe elsewhere for unrelated reasons.
#
#   The accumulator fails on the first UNQUALIFIED paragraph. Its
#   predecessor set a found-flag on the first QUALIFIED one, which answers
#   "does SOME statement in this file name the deploy emitter" -- so a
#   second, unqualified statement appended anywhere in an already-qualified
#   file was invisible, and the guard's own name and failure message
#   promised the every-statement property it did not check.
#
#   A file selected into the roster whose paragraph pass finds no statement
#   at all is a failure, not a pass: the two scans disagree about the file,
#   so nothing was judged.
#
#   Population boundary, stated rather than left implied. A statement of
#   this invariant is a claim about a KEY the emitter writes into YAML, and
#   every one of them in this tree quotes that key with its colon. The bare
#   noun `container_name` is how the docs discuss the field as a concept --
#   "removable", "while any container_name is present", "dropping it is
#   what makes that dangerous" -- and those paragraphs assert nothing about
#   what base emits, so requiring the exemption of them would demand the
#   deploy recipe be named in prose that makes no claim about it. The cost
#   of the boundary: a statement of the invariant phrased with the bare
#   noun is outside this population and is not guarded.
_every_claim_states_the_exemption() {
  awk '
    BEGIN { RS = "" }
    { _para[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (index(_para[i], "container_name:") == 0) continue
        _seen = 1
        _win = _para[i] "\n" (i < NR ? _para[i + 1] : "")
        if (index(_win, "just docker setup deploy") == 0 &&
            index(_win, "_generate_resolved_compose") == 0) {
          printf "unqualified statement of the invariant, paragraph %d:\n%s\n", i, _para[i]
          _bad = 1
        }
      }
      if (!_seen)
        print "no paragraph states the invariant, though the roster scan selected this file"
      exit((_bad || !_seen) ? 1 : 0)
    }' "${1:?}"
}

# Emit a compose that exercises the interpolation-channel per-instance
# fields on both the devel service and a per-stage standalone block:
# bridge network (-> network_mode: line + ports honoured), devel ports,
# and a [stage:headless] with its own ports override.
_emit_exercised_compose() {
  cat > "${TEMP_DIR}/.setup.conf" <<'CONF'
[stage:headless]
network.mode = bridge
network.port_inherit = false
network.port_1 = 5000:5000
network.port_2 = 6000:6000
CONF
  local _extras=('/home/u/repo:/home/u/repo:rw')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" $'8080:80\n9090:90' \
    "" "bridge" "host"
}

# ── Predicate self-check: proves the guard FAILS on a baked literal ─────

@test "overlay guard predicate rejects a baked literal, accepts an interpolation" {
  # A hardcoded per-instance literal (what a regression would emit).
  run _is_overlay_overridable '8080:80'
  assert_failure
  # The overlay-overridable form the emitter must produce.
  run _is_overlay_overridable '${PORT_1:-8080:80}'
  assert_success
  run _is_overlay_overridable '${NETWORK_MODE}'
  assert_success
}

# ── Forward invariant over the interpolation-channel field set ──────────

@test "overlay guard: project name: is an overlay interpolation" {
  _emit_exercised_compose
  _require_emitted_population
  local _val
  _val="$(grep -E '^name:' "${COMPOSE_OUT}" | head -1 | sed -E 's/^name:[[:space:]]*//')"
  [[ -n "${_val}" ]] || fail "no name: line in ${COMPOSE_OUT} -- nothing was checked"
  _is_overlay_overridable "${_val}"
}

@test "overlay guard: the dev-stack emitter emits no container_name at all (#920)" {
  # The weaker predicate this replaces asked only that the value carry SOME
  # interpolation, and `${USER_NAME}-myrepo-headless` satisfied it -- yet
  # ${USER_NAME} is one string for all of a user's instances, so the name it
  # produces is as global as a literal. A container name is namespaced by the
  # daemon, not by the project, so no value of it can be per-instance safe;
  # the only overlay-compatible container_name is an absent one, which lets
  # compose derive <project>-<service>-<n>.
  _emit_exercised_compose
  _assert_emitted_without '^[[:space:]]*container_name:' 'a container_name: key'
}

@test "the field-deploy emitter's baked container_name is a STATED exemption (#920)" {
  # The guard above scans `generate_compose_yaml` -- the dev stack, the
  # only emission a multi_run overlay ever expands. It is not the only
  # emitter base ships: `_generate_resolved_compose` (just setup deploy)
  # writes a fully-resolved single-device bundle and DOES bake a
  # container_name, deliberately, so an operator has a stable name to
  # `docker logs`. Two emitters, two rules.
  #
  # A guard whose name overstates its reach is how a documented invariant
  # comes to be believed of a bundle it never looked at, so the exemption
  # is asserted here, next to the invariant, in both directions: the
  # deploy emitter still bakes one, and every document that states the
  # invariant states the exemption with it.
  local _deploy="/source/dist/script/docker/lib/deploy.sh"
  assert_spec_subject "${_deploy}" \
      "the field-deploy compose emitter this exemption is about"
  run grep -F "printf '    container_name: %s" "${_deploy}"
  assert_success

  # The prose population is DERIVED FROM THE REPOSITORY, not listed at any
  # granularity. A predecessor listed two FILES and missed a third
  # (CONTEXT.md). Its successor listed four ROOTS -- README.md, CONTEXT.md,
  # doc/readme, doc/adr -- and silently exempted everything outside them:
  # an unqualified statement of the invariant appended to doc/PRD.md, false
  # for the deploy bundle, left the guard green. So the scan starts at the
  # repository root and states its boundary by subtraction instead:
  #
  #   doc/changelog/  a historical record. Its released sections describe
  #                   emitters that no longer exist, and rewriting a shipped
  #                   entry to satisfy a present-tense invariant would
  #                   falsify it.
  #   doc/test/       generated count tables, no prose.
  #   .prev-release/  vendored copies of shipped tags; the same argument as
  #                   the changelog, one directory up.
  #   .git/ coverage/ not documents.
  #
  # Everything else in the tree is in scope, so a new document anywhere --
  # doc/PRD.md, doc/deprecations.md, one not written yet -- is caught the
  # day it states the invariant.
  local -a _docs=()
  local _d
  while IFS= read -r _d; do
    _docs+=("${_d}")
  done < <(find /source -name '*.md' \
                -not -path '/source/.git/*' \
                -not -path '/source/doc/changelog/*' \
                -not -path '/source/doc/test/*' \
                -not -path '/source/.prev-release/*' \
                -not -path '/source/coverage/*' \
                -print0 \
             | xargs -0 grep -lF 'container_name:' | sort)

  # A derived roster that came back empty would certify every document at
  # once. The floor is derived too: the English README, CONTEXT.md and
  # ADR-00000022 state the invariant, and so does every localized README --
  # each is a translation of the English section, so the set is read off
  # doc/readme/ rather than spelled out.
  local _readme="/source/README.md" _adr
  _adr="/source/doc/adr/00000022-compose-multirun-overlay-contract.md"
  local -a _floors=("${_readme}" "/source/CONTEXT.md" "${_adr}")
  local _l
  while IFS= read -r _l; do
    _floors+=("${_l}")
  done < <(find /source/doc/readme -maxdepth 1 -name 'README.*.md' | sort)
  (( ${#_floors[@]} > 3 )) || fail \
    "doc/readme/ yielded no localized README: the floor derived nothing and cannot bound the roster"

  local _joined
  _joined="$(printf '%s\n' "${_docs[@]}")"
  local _floor
  for _floor in "${_floors[@]}"; do
    grep -qxF -- "${_floor}" <<< "${_joined}" || fail \
      "${_floor} states the container_name invariant but the derived roster missed it: the scan found ${#_docs[@]} document(s) and cannot be trusted"
  done

  # Every document in the roster must name the deploy emitter -- by its
  # user-facing entry point or by the function that writes the bundle. The
  # token is the SUBJECT of the exemption, so deleting the exemption
  # sentence deletes it; a predecessor asked only that the 6-letter string
  # "deploy" appear somewhere in a 17-line window, which prose that states
  # no exemption at all ("nothing in that deploy path depends on...")
  # satisfies unchanged.
  #
  # The entry point is spelled the way the CLI accepts it. A predecessor
  # matched the bare `just setup deploy`, which base has no recipe for --
  # so the guard's power came from the prose being WRONG, and correcting
  # the six sentences to the namespaced form falsified it.
  #
  # The token is required NEXT TO the claim, not anywhere in the file, and
  # of EVERY claim, not of one of them. README.md names `just docker setup
  # deploy` nine times: seven inside its own field-deployment section, one
  # in an unrelated cross-reference, and exactly one in the exemption
  # sentence -- so a file-wide match would stay green with the exemption
  # paragraph deleted. And a file-wide match is not the only way to be too
  # generous: asking whether SOME statement is qualified certifies a
  # document the moment one of its statements is, which leaves a second
  # statement appended to the same file unjudged.
  for _d in "${_docs[@]}"; do
    _every_claim_states_the_exemption "${_d}" || fail \
      "${_d} states the container_name invariant in a paragraph that does not name the deploy bundle it does not hold for, in that paragraph or the one after it (printed above)"
  done

  # The two English statements carry the exemption's PREDICATE as well: the
  # deploy bundle still BAKES a name. Naming the emitter is not the same
  # claim as saying what it does, and the translations phrase the predicate
  # in their own language (the readme-sync lint is what keeps those in step
  # with the English section they were translated from).
  local _s
  for _s in "${_readme}" "${_adr}"; do
    grep -qE -- '(does|still) bakes? (a |one)' "${_s}" || fail \
      "${_s} names the deploy bundle but no longer says it bakes a container_name: the exemption is not stated, only alluded to"
  done
}

@test "overlay guard: network_mode: is an env interpolation, never a baked literal" {
  _emit_exercised_compose
  _require_emitted_population
  grep -qE '^[[:space:]]*network_mode:' "${COMPOSE_OUT}" \
    || fail "the exercised emission carries no network_mode: line -- the loop below would iterate nothing and pass vacuously"
  local _line _val
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _val="$(sed -E 's/^[[:space:]]*network_mode:[[:space:]]*//' <<< "${_line}")"
    _is_overlay_overridable "${_val}" \
      || { echo "baked network_mode literal: ${_val}"; return 1; }
  done < <(grep -E '^[[:space:]]*network_mode:' "${COMPOSE_OUT}")
}

@test "overlay guard: no baked published-port literal anywhere (forward invariant)" {
  _emit_exercised_compose
  # A baked port entry is a quoted list item beginning with a digit under a
  # ports: block (host:container[/proto], optionally IP-prefixed). After the
  # fix every port is emitted as ${PORT_N:-<default>}, so a numeric-leading
  # quoted entry means a per-instance literal leaked back in.
  _assert_emitted_without '^[[:space:]]+- "[0-9][0-9.]*:' 'a baked published-port literal'
}

@test "overlay guard: published ports are emitted as \${PORT_N:-default} on devel and stages" {
  _emit_exercised_compose
  # devel ports (from the top-level list) and the headless stage's ports
  # (from [stage:headless] override) are all overlay interpolations, with the
  # setup.conf value preserved as the :- default (single-run behaviour). The
  # index is 1-based (PORT_1 = first port) to match base's indexed-key
  # convention (port_1 / mount_1 / arg_1).
  run grep -F -- '- "${PORT_1:-8080:80}"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "${PORT_2:-9090:90}"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "${PORT_1:-5000:5000}"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "${PORT_2:-6000:6000}"' "${COMPOSE_OUT}"
  assert_success
}
