#!/usr/bin/env bats
#
# Unit tests pinning the derived-artifact claim every setup surface makes.
#
# `setup.sh apply` regenerates THREE files: `.env` (the shipped container-env
# defaults), `.env.generated` (the derived interpolation cache, incl. the
# SETUP_* drift metadata) and `compose.yaml`. The one file apply never
# rewrites is `.env.local` -- the operator's overrides.
#
# The claim used to be the exact opposite: `.env` was the hand-authored
# overlay and every surface was corrected to say `.env.generated` alone. The
# naming rule reversed (the standard name is ours; a suffix marks a local
# variant), so these tests move with it -- and the cross-surface guard below
# flips too: what must never appear now is a surface still teaching that a
# bare `.env` is the user's hand-authored file, because a user who believes
# that will put a token in a file the next apply overwrites.
#
# All four locales are covered: a string fix that lands in one locale is not
# a fix.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HELP_SH="/source/dist/script/docker/lib/help.sh"
  SETUP_SH="/source/dist/script/docker/wrapper/setup.sh"
  JUSTFILE_DOCKER="/source/dist/script/docker/justfile.docker"
}

# ════════════════════════════════════════════════════════════════════
# `just docker help` -- the localized recipe listing (all four locales)
# ════════════════════════════════════════════════════════════════════

@test "just docker help: en setup summary names .env + .env.generated (#868)" {
  run bash "${HELP_SH}" docker --lang en
  assert_success
  assert_output --partial "Regenerate .env / .env.generated / compose.yaml from setup.conf"
}

@test "just docker help: zh-TW setup summary names .env + .env.generated (#868)" {
  run bash "${HELP_SH}" docker --lang zh-TW
  assert_success
  assert_output --partial "重新產生 .env / .env.generated 與 compose.yaml"
}

@test "just docker help: zh-CN setup summary names .env + .env.generated (#868)" {
  run bash "${HELP_SH}" docker --lang zh-CN
  assert_success
  assert_output --partial "重新生成 .env / .env.generated 与 compose.yaml"
}

@test "just docker help: ja setup summary names .env + .env.generated (#868)" {
  run bash "${HELP_SH}" docker --lang ja
  assert_success
  assert_output --partial ".env / .env.generated と compose.yaml を再生成"
}

# ════════════════════════════════════════════════════════════════════
# `just --list` doc comment (English-only; just cannot be intercepted)
# ════════════════════════════════════════════════════════════════════

@test "justfile.docker: the setup doc comment names .env + .env.generated (#868)" {
  run grep -n '^# Regenerate' "${JUSTFILE_DOCKER}"
  assert_success
  assert_output --partial ".env / .env.generated / compose.yaml from setup.conf"
}

# ════════════════════════════════════════════════════════════════════
# setup.sh usage + the post-mutation "next:" hint
# ════════════════════════════════════════════════════════════════════

@test "setup.sh --help: usage names .env + .env.generated (#868)" {
  run bash "${SETUP_SH}" --help
  assert_success
  assert_output --partial "Regenerate .env / .env.generated / compose.yaml"
}

@test "setup.sh set: the next hint names .env + .env.generated (#868)" {
  local _repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_repo}"
  run bash "${SETUP_SH}" set network.mode bridge --base-path "${_repo}"
  assert_success
  assert_output --partial "to regenerate .env / .env.generated / compose.yaml"
}

@test "setup.sh add: the next hint names .env + .env.generated (#868)" {
  local _repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_repo}"
  run bash "${SETUP_SH}" add environment.env FOO=bar --base-path "${_repo}"
  assert_success
  assert_output --partial "to regenerate .env / .env.generated / compose.yaml"
}

@test "setup.sh remove: the next hint names .env + .env.generated (#868)" {
  local _repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_repo}"
  run bash "${SETUP_SH}" set network.mode bridge --base-path "${_repo}"
  assert_success
  run bash "${SETUP_SH}" remove network.mode --base-path "${_repo}"
  assert_success
  assert_output --partial "to regenerate .env / .env.generated / compose.yaml"
}

# ════════════════════════════════════════════════════════════════════
# apply's completion line (_setup_msg env done) -- all four locales
# ════════════════════════════════════════════════════════════════════

@test "setup.sh env done message names .env.generated in all four locales (#868)" {
  local _lang
  for _lang in en zh-TW zh-CN ja; do
    run bash -c "_LANG='${_lang}'; source '${SETUP_SH}' 2>/dev/null; _LANG='${_lang}'; _setup_msg env done"
    assert_success
    assert_output --partial ".env.generated"
  done
}

# ════════════════════════════════════════════════════════════════════
# Cross-surface guard: no shipped surface calls a bare `.env` the user's
# ════════════════════════════════════════════════════════════════════

# The surfaces a user actually reads. Kept as an explicit list rather than a
# tree walk so a new surface is a deliberate addition, not an accident.
_claim_surfaces() {
  cat <<'EOF'
/source/dist/.setup.conf
/source/dist/script/docker/justfile.docker
/source/dist/script/docker/lib/help.sh
/source/dist/script/docker/lib/setup_cmd.sh
/source/dist/script/docker/lib/wrapper.sh
/source/dist/script/docker/lib/env_emit.sh
/source/dist/script/docker/lib/compose_emit.sh
/source/dist/script/docker/wrapper/build.sh
/source/dist/script/docker/wrapper/run.sh
/source/dist/script/docker/wrapper/setup.sh
/source/dist/script/docker/wrapper/setup_tui.sh
EOF
}

@test "no shipped surface calls a bare .env hand-authored or a workload overlay (#868)" {
  # The pre-#868 vocabulary for the user-owned file. Every one of these
  # phrases, applied to a bare `.env`, teaches a user to hand-edit a file
  # the next apply overwrites. `.env.local` is the file those words describe
  # now, so the patterns deliberately require a bare `.env` nearby or no
  # qualified name at all.
  local -a _bad=(
    'hand-authored .env([^.[:alnum:]]|$)'
    '\.env([^.[:alnum:]]|$)[^.]{0,20}workload overlay'
    'workload overlay[^.]{0,20}\.env([^.[:alnum:]]|$)'
    '\.env overlay'
    '手寫的 `?\.env([^.[:alnum:]]|$)'
  )
  local _file _pat _hits=""
  while IFS= read -r _file; do
    [[ -f "${_file}" ]] || continue
    for _pat in "${_bad[@]}"; do
      local _out=""
      _out="$(grep -nE "${_pat}" "${_file}" || true)"
      [[ -n "${_out}" ]] && _hits+="${_file}"$'\n'"${_out}"$'\n'
    done
  done < <(_claim_surfaces)
  [[ -z "${_hits}" ]] || {
    printf 'surfaces still teaching that a bare .env is the user'"'"'s file:\n%s\n' "${_hits}" >&2
    return 1
  }
}

@test "the shipped surfaces name .env.local as the override channel (#868)" {
  # The inverse of the guard above: removing the wrong claim is not enough
  # if nothing tells the user where their values go instead.
  local _file
  for _file in \
      /source/dist/script/docker/lib/env_emit.sh \
      /source/dist/script/docker/lib/compose_emit.sh \
      /source/dist/script/docker/wrapper/setup.sh \
      /source/dist/.setup.conf; do
    run grep -F '.env.local' "${_file}"
    assert_success
  done
}
