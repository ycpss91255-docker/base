#!/usr/bin/env bats
#
# dockerfile_migrate_spec.bats - unit tests for the declarative
# Dockerfile-migration list (folds facet B).
#
# lib/dockerfile_migrate.sh exposes a small interface --
# `apply_migrations <dockerfile_path>` -- backed by an ordered, data-driven
# list of {detect, transform} migrations. Each migration heals one
# v0.41.0-fanout Dockerfile/entrypoint breakage. These tests drive each
# {detect, transform} unit in isolation via before/after fixtures, plus the
# dispatcher's apply/skip/idempotency contract.
#
# Apply policy (inherited from upgrade.sh's Step-5 convention):
#   - detect matches a known shape  -> transform auto-applies, idempotent
#   - structure absent / ambiguous  -> _log_warn + SKIP (never force-rewrite)

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
  DF="${TEMP_DIR}/Dockerfile"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _run_migrate <fn> [args...]
#   Source the lib in a fresh shell and invoke one of its functions, so
#   each test exercises the real function body (not a copy). _lib.sh
#   brings in _log_* for the warn/skip messaging.
_src() {
  printf 'source %s/_lib.sh; source %s/dockerfile_migrate.sh' "${LIB}" "${LIB}"
}

# _src_from <libdir>
#   As _src, but sourcing a COPY of the lib tree rather than the shipped
#   one. The template conf layer is located from the lib's OWN directory
#   (init.sh / upgrade.sh source the migration list with no
#   _SETUP_SCRIPT_DIR to point at it), so the only way a test can put a
#   template layer under the migration's nose is to run a copy that sits
#   inside a template root the test owns.
_src_from() {
  printf 'source %s/_lib.sh; source %s/dockerfile_migrate.sh' "${1}" "${1}"
}

# _stage_template_tree
#   Lay out the production shape around ${TEMP_DIR} (the repo root): a
#   vendored subtree at <repo>/.base whose dist/ carries both the template
#   .setup.conf and the lib the migration runs from. Echoes the copied lib
#   dir for _src_from.
_stage_template_tree() {
  local _tpl="${TEMP_DIR}/.base"
  mkdir -p "${_tpl}/dist/script/docker"
  cp -r "${LIB}" "${_tpl}/dist/script/docker/lib"
  printf '%s' "${_tpl}/dist/script/docker/lib"
}

# ── dispatcher contract: apply_migrations ───────────────────────────────────

@test "apply_migrations is the public dispatcher entry (#567)" {
  run bash -c "$(_src); declare -F apply_migrations"
  assert_success
}

@test "apply_migrations skips cleanly when path does not exist (#567)" {
  run bash -c "$(_src); apply_migrations '${TEMP_DIR}/nope'"
  assert_success
  assert_output --partial "no Dockerfile"
}

@test "_MIGRATIONS is a non-empty ordered list (#567)" {
  run bash -c "$(_src); printf '%s\n' \"\${_MIGRATIONS[@]}\""
  assert_success
  [ "${#lines[@]}" -ge 1 ]
}

# ── migration 0: shipped-tree dir rename .base/downstream/ -> .base/dist/ ────
# base's shipped tree was renamed downstream/ -> dist/. A consumer
# Dockerfile that hand-references the lint-stage lib/wrapper dir COPY under
# .base/downstream/ breaks with "COPY source not found" after the rename;
# every .base/downstream/ COPY source heals to .base/dist/.

@test "migration 0 (downstream-to-dist): rewrites lib/wrapper COPY sources to .base/dist/ (#714)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/downstream/script/docker/lib /lint/lib
COPY .base/downstream/script/docker/wrapper /lint/wrapper
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); _migrate_downstream_to_dist_detect '${DF}' && _migrate_downstream_to_dist_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${DF}"
  grep -Fq "COPY .base/dist/script/docker/wrapper /lint/wrapper" "${DF}"
  refute grep -q '\.base/downstream/' "${DF}"
}

@test "migration 0 (downstream-to-dist): detect false when no .base/downstream/ reference (#714)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src); _migrate_downstream_to_dist_detect '${DF}'"
  assert_failure
}

@test "migration 0 (downstream-to-dist): idempotent — second run is a no-op (#714)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/downstream/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${DF}" "${DF}.orig"
}

# ── migration 1: wrapper COPY shape A/B -> wrapper/*.sh ──────────────────────
# v0.41.0 moved the user-facing wrappers into .base/script/docker/wrapper/.
# Two pre-v0.41.0 lint-stage shapes break:
#   A  COPY *.sh /lint/                       (root-anchored, era)
#   B  COPY .base/script/docker/*.sh /lint/   (flat top-level glob)
# Both heal to the wrapper-glob shape COPY .base/script/docker/wrapper/*.sh.

@test "migration 1 (wrapper-copy): rewrites shape A 'COPY *.sh /lint/' (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY *.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); _migrate_wrapper_copy_detect '${DF}' && _migrate_wrapper_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/script/docker/wrapper/*.sh /lint/" "${DF}"
  refute grep -Eq '^[[:space:]]*COPY[[:space:]]+\*\.sh[[:space:]]+/lint/' "${DF}"
}

@test "migration 1 (wrapper-copy): rewrites shape B 'COPY .base/script/docker/*.sh /lint/' (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); _migrate_wrapper_copy_detect '${DF}' && _migrate_wrapper_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/script/docker/wrapper/*.sh /lint/" "${DF}"
  refute grep -Eq '^[[:space:]]*COPY[[:space:]]+\.base/script/docker/\*\.sh[[:space:]]+/lint/' "${DF}"
}

# The settled shape is the DIST one: wrapper_copy writes the flat
# .base/script/docker/wrapper/*.sh and flat_to_dist (which runs later in
# the list, by design) carries it the rest of the way. A Dockerfile already
# on the flat path is therefore not a fixed point of the dispatcher -- that
# path no longer exists -- so the no-op fixture is the dist spelling.
@test "migration 1 (wrapper-copy): idempotent — second run is a no-op (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/wrapper/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${DF}" "${DF}.orig"
}

@test "migration 1 (wrapper-copy): the dispatcher lands shape A on the dist wrapper glob (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY *.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/wrapper/*.sh /lint/" "${DF}"
}

@test "migration 1 (wrapper-copy): detect is false when no legacy wrapper COPY present (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/wrapper/*.sh /lint/
EOF
  run bash -c "$(_src); _migrate_wrapper_copy_detect '${DF}'"
  assert_failure
}

# ── migration 2: retired .base/dockerfile/setup pip helper ──────────────────
# v0.41.0 retired the .base/dockerfile/setup pip flow. The downstream line
#   RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
# (+ a preceding "# Setup pip packages" comment) installed base's empty
# placeholder — a no-op once the helper is gone. Drop both lines; the user
# re-adds an explicit pip step if they have a real requirements file.

@test "migration 2 (pip-helper): drops the retired CONFIG_DIR pip install line (#567)" {
  # The exact v0.41.0 breakage this migration exists for: the repo ships a
  # config/ overlay (so the migration can resolve what ${CONFIG_DIR} is
  # populated from) but no pip/requirements.txt inside it, which is what
  # makes the build hard-fail on the `-r` argument. An absent file is the
  # strongest possible proof the install is inert, so the line goes.
  mkdir -p "${TEMP_DIR}/config"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  refute grep -q 'CONFIG_DIR.*pip/requirements.txt' "${DF}"
  refute grep -q '# Setup pip packages' "${DF}"
  grep -Fq "RUN echo done" "${DF}"
}

@test "migration 2 (pip-helper): idempotent — no pip line means detect false (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
RUN echo done
EOF
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}'"
  assert_failure
}

# The delete's precondition is "this line installs nothing", and the line
# alone cannot say so: dist/dockerfile/Dockerfile's layer-2 overlay copies
# the repo's own `config/` (ARG CONFIG_SRC="config") onto ${CONFIG_DIR}, so
# the SAME byte-identical instruction installs base's placeholder in one
# repo and a real dependency list in the next. The precondition IS
# checkable -- the requirements file sits next to the Dockerfile -- so the
# migration reads it, and deletes only where it can prove the install is
# inert. Where it cannot, it warns and leaves the file alone; the apply
# policy at the top of this file already says a migration never
# force-rewrites a shape it does not recognise.

# _seed_requirements <content>
#   Write the repo-side config/pip/requirements.txt the Dockerfile's
#   ${CONFIG_DIR}/pip/requirements.txt resolves to at build time.
_seed_requirements() {
  mkdir -p "${TEMP_DIR}/config/pip"
  printf '%s\n' "$1" > "${TEMP_DIR}/config/pip/requirements.txt"
}

@test "migration 2 (pip-helper): keeps a pip line whose requirements file carries real requirements (#956)" {
  _seed_requirements "numpy==1.26.4"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): drops the line when the requirements file is comment/blank-only (#956)" {
  # The placeholder every repo on the remote actually ships today.
  _seed_requirements "# install python dep"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  refute grep -q 'CONFIG_DIR.*pip/requirements.txt' "${DF}"
  refute grep -q '# Setup pip packages' "${DF}"
}

@test "migration 2 (pip-helper): keeps the line when the requirements file cannot be READ (#956)" {
  # grep exits 2 when it could not read what it was pointed at, and 1 only
  # when it read the file end to end and matched nothing. A caller that
  # folds the two together turns an unreadable requirements file into
  # permission to delete a working install -- the destructive direction,
  # and the one that reaches every consumer repo through `just upgrade`.
  # The two sibling guards in this lib (_dfm_conf_declares_redirect, the
  # ARG CONFIG_SRC scan) already refuse anything but 0/1; this is the third.
  #
  # The unreadable file is injected at the seam rather than with a
  # mode-000 fixture: this suite's container reads as root, where mode 000
  # is still readable, so a permission fixture would prove nothing here.
  # The sibling case below pins the status the real function returns when
  # its own grep cannot read the file.
  _seed_requirements "numpy==1.26.4"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); \
    _dfm_pip_requirements_populated() { return 2; }; \
    _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): an unreadable requirements file answers 2, not 1 (#956)" {
  # The function's own contract, with grep's read failure injected: 0 is
  # populated, 1 is PROVABLY empty, and anything else is unprovable. An
  # absent file stays 1 -- that is the state the migration is repairing.
  _seed_requirements "numpy==1.26.4"
  run bash -c "$(_src); grep() { return 2; }; \
    _dfm_pip_requirements_populated '${TEMP_DIR}/config'"
  assert_equal "${status}" 2
}

# The file's ABSENCE is the other half of the same question, and
# `[[ -f ]]` answers it with the same single `false` whether the file is
# genuinely not there or the path could not be traversed at all. Only the
# first is proof, and status 1 -- the one that authorises the delete --
# must mean only the first.

@test "migration 2 (pip-helper): keeps the line when the pip directory cannot be traversed (#956)" {
  # An unreadable config/pip/ used to reach the delete as "the file is
  # absent, so this line installs nothing", which is exactly the silent
  # package loss the migration's own contract forbids: a directory this
  # migration never read is not a directory with nothing in it.
  #
  # The fixture is a self-referential symlink rather than a mode-000
  # directory because this suite's container reads as root, where a mode
  # cannot make anything unreadable. ELOOP stops root too, so the test
  # asserts the real code path with no seam injection at all.
  mkdir -p "${TEMP_DIR}/config"
  ln -s pip "${TEMP_DIR}/config/pip"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): an untraversable pip dir answers 2, an absent one 1 (#956)" {
  # Both halves of the contract in one place, because the fix is only
  # correct if it keeps BOTH. A config/ that was read and holds no pip/ is
  # status 1 -- proof, and the v0.41.0 breakage the migration exists to
  # repair. A pip/ that could not be resolved is status 2.
  mkdir -p "${TEMP_DIR}/config"
  run bash -c "$(_src); _dfm_pip_requirements_populated '${TEMP_DIR}/config'"
  assert_equal "${status}" 1
  ln -s pip "${TEMP_DIR}/config/pip"
  run bash -c "$(_src); _dfm_pip_requirements_populated '${TEMP_DIR}/config'"
  assert_equal "${status}" 2
}

@test "migration 2 (pip-helper): keeps the line when a conf layer cannot be read (#956)" {
  # The same shape one function up. A conf layer that is not a readable
  # regular file was skipped outright, and the chain then reported "no
  # layer declares a redirect" for a chain it did not read end to end --
  # an unread layer counted as a layer that says nothing. It is an
  # unanswered question, and an unanswered question keeps the line.
  _seed_requirements "# install python dep"
  ln -s .setup.conf "${TEMP_DIR}/.setup.conf"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): keeps the line when a conf layer's DIRECTORY cannot be read (#956)" {
  # The last way a layer can read as absent without being absent: the
  # directory that would hold it could not be traversed, so the `-f` test
  # returns false having observed nothing. Today's derived chain cannot
  # reach this -- both its directories are ones this process has already
  # read (the template dist/ it was sourced from, and the Dockerfile's own
  # directory) -- so the chain, and only the chain, is injected; the
  # unreadable directory in it is real.
  _seed_requirements "# install python dep"
  ln -s loopdir "${TEMP_DIR}/loopdir"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); \
    _setup_conf_layers() { local -n _o=\"\${2}\"; \
      _o=(\"\${1}/.setup.conf\" \"\${1}/loopdir/.setup.conf\" \"\${1}/.setup.conf.local\"); }; \
    _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}


@test "migration 2 (pip-helper): keeps a pip line that closes a continued RUN (#956)" {
  # Deleting this physical line leaves `RUN apt-get update && \` dangling,
  # which swallows the next instruction into the same shell command.
  # The placeholder requirements file is seeded so the CONTINUATION is the
  # only thing keeping the line -- otherwise the spec would pass on the
  # unresolvable-config-source branch instead.
  _seed_requirements "# install python dep"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
RUN apt-get update && \
    pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): keeps a pip line that opens a continued RUN (#956)" {
  # Deleting this physical line orphans `    apt-get clean` as a bare
  # non-instruction line, which is a Dockerfile parse error. Placeholder
  # requirements seeded for the same reason as the spec above.
  _seed_requirements "# install python dep"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
RUN pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt && \
    apt-get clean
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): the standalone check refuses a Dockerfile it cannot READ (#956)" {
  # The last leg of this lib's own safety argument (the header's status
  # block names it): _dfm_pip_line_is_standalone is supposed to answer
  # "keep the line" when it cannot read the file at all. It did not. The
  # body is a `while ... done < "${_file}"` loop; when the redirect fails
  # the loop never runs and the unconditional `return 0` at the end of the
  # function -- "every matched line stands alone, delete it" -- was the
  # answer, for a file nothing read. Same defect this issue is about, in
  # the one guard whose job is to prevent it.
  #
  # Status 1 exactly, not merely non-zero: 1 is the "not standalone" the
  # caller keys off, and an unreadable file must land on it rather than on
  # some other number the caller does not test for.
  #
  # Root reads a mode-000 file, so the fixtures are an ELOOP symlink and a
  # path that is not there at all -- the same technique the sibling cases
  # above use, and neither injects a seam.
  ln -s loop "${TEMP_DIR}/loop"
  run bash -c "$(_src); _dfm_pip_line_is_standalone '${TEMP_DIR}/loop'"
  assert_equal "${status}" 1
  run bash -c "$(_src); _dfm_pip_line_is_standalone '${TEMP_DIR}/gone'"
  assert_equal "${status}" 1
}

# The requirements file the migration reads is <repo>/config/pip/... only
# while CONFIG_SRC still holds its default. It is a build ARG
# (dist/dockerfile/Dockerfile `ARG CONFIG_SRC="config"`, consumed by the
# layer-2 `COPY "${CONFIG_SRC}" "${CONFIG_DIR}"`), and a
# `[build] arg_N = CONFIG_SRC=...` entry in .setup.conf reaches the build as
# a compose build arg, so a repo can legitimately overlay ${CONFIG_DIR} from
# some other directory. Reading `config/` regardless would report "not
# populated" for a repo whose real dependency list lives elsewhere and delete
# a working install -- the same silent package loss, just narrowed. Where the
# source cannot be located, the install cannot be proven inert, so the line
# is kept.

@test "migration 2 (pip-helper): keeps the line when the Dockerfile redirects CONFIG_SRC (#956)" {
  mkdir -p "${TEMP_DIR}/myconfig/pip"
  printf 'numpy==1.26.4\n' > "${TEMP_DIR}/myconfig/pip/requirements.txt"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG CONFIG_SRC="myconfig"
COPY "${CONFIG_SRC}" "${CONFIG_DIR}"
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): keeps the line when .setup.conf redirects CONFIG_SRC (#956)" {
  # The Dockerfile still says `config`; the build arg overrides it, and the
  # placeholder under config/ would otherwise read as "prove it is inert".
  _seed_requirements "# install python dep"
  mkdir -p "${TEMP_DIR}/myconfig/pip"
  printf 'numpy==1.26.4\n' > "${TEMP_DIR}/myconfig/pip/requirements.txt"
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
arg_1 = TZ=Asia/Taipei
arg_2 = CONFIG_SRC=myconfig
EOF
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG CONFIG_SRC="config"
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

# The redirect can also arrive from the layer NOBODY in the repo wrote: the
# conf chain is three files, not two (lib/setup_conf.sh's
# _setup_conf_layers -- template, per-repo, per-worktree), and the build
# args are read through the whole chain (setup_cmd.sh -> _setup_conf_handle
# -> _setup_conf_layers). A guard that hand-listed the two per-repo files
# would report "no redirect" for a repo running on template defaults --
# `_gen_setup_conf` is opt-in, so those repos exist -- and delete a working
# install the moment base ships a CONFIG_SRC of its own. The chain is
# therefore DERIVED from the one function that owns it, never re-listed
# here, and the guard refuses to authorise a delete when it did not get the
# whole chain back or could not read a layer.

@test "migration 2 (pip-helper): keeps the line when the TEMPLATE conf layer redirects CONFIG_SRC (#956)" {
  local _lib
  _lib="$(_stage_template_tree)"
  cat > "${TEMP_DIR}/.base/dist/.setup.conf" <<'EOF'
[build]
arg_1 = TZ=Asia/Taipei
arg_2 = CONFIG_SRC=myconfig
EOF
  # The repo writes no .setup.conf at all -- template defaults for every
  # section, which is the state `setup.sh` warns about rather than forbids.
  _seed_requirements "# install python dep"
  mkdir -p "${TEMP_DIR}/myconfig/pip"
  printf 'numpy==1.26.4\n' > "${TEMP_DIR}/myconfig/pip/requirements.txt"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG CONFIG_SRC="config"
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src_from "${_lib}"); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): keeps the line when the conf chain comes back truncated (#956)" {
  # A chain shorter than the three layers _setup_conf_layers documents
  # means a layer dropped out of the resolution. Scanning what is left and
  # calling it "no redirect" is the failure this guard exists to refuse:
  # a scan that did not see the whole population is not a pass.
  _seed_requirements "# install python dep"
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); \
    _setup_conf_layers() { local -n _o=\"\${2}\"; _o=(\"\${1}/.setup.conf\"); }; \
    _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): keeps the line when a conf layer cannot be scanned (#956)" {
  # grep exits 2 when it could not read what it was pointed at. Reading
  # that as "no match" turns an unreadable layer into permission to delete.
  _seed_requirements "# install python dep"
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
arg_1 = TZ=Asia/Taipei
EOF
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); \
    grep() { if [[ \"\$*\" == *CONFIG_SRC=* ]]; then return 2; fi; command grep \"\$@\"; }; \
    _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

@test "migration 2 (pip-helper): keeps the line when no config source dir is next to the Dockerfile (#956)" {
  # No config/ at all: whatever ${CONFIG_DIR} is overlaid from, it is not
  # something this migration can read, so it cannot call the install inert.
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  assert_output --partial "kept"
  diff "${DF}.orig" "${DF}"
}

# ── migration 3: explicit hand-listed lib/wrapper COPYs ─────────────────────
# Multi-distro repos (ros_distro / ros2_distro / ros1_bridge) hand-listed the
# now-moved top-level files in their lint stage, e.g.
#   COPY .base/script/docker/_lib.sh .base/script/docker/i18n.sh /lint/
#   COPY .base/script/docker/build.sh .base/script/docker/run.sh ... /lint/
# These resolve to zero files post-v0.41.0. The stage already pulls
# 'COPY .base/script/docker/lib /lint/lib' + 'COPY script/*.sh /lint/', so
# the explicit COPYs are redundant and broken — drop them. Multi-line
# backslash-continued forms are handled too.

@test "migration 3 (explicit-copy): drops single-line explicit top-level .sh COPY (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/_lib.sh .base/script/docker/i18n.sh /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
EOF
  run bash -c "$(_src); _migrate_explicit_copy_detect '${DF}' && _migrate_explicit_copy_apply '${DF}'"
  assert_success
  refute grep -Eq 'COPY .*\.base/script/docker/[A-Za-z_]+\.sh' "${DF}"
  grep -Fq "COPY .base/script/docker/lib /lint/lib" "${DF}"
}

@test "migration 3 (explicit-copy): drops multi-line backslash-continued COPY block (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/_lib.sh \
     .base/script/docker/i18n.sh \
     .base/script/docker/_tui_conf.sh \
     /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
EOF
  run bash -c "$(_src); _migrate_explicit_copy_detect '${DF}' && _migrate_explicit_copy_apply '${DF}'"
  assert_success
  refute grep -Eq 'COPY .*\.base/script/docker/[A-Za-z_]+\.sh' "${DF}"
  refute grep -q '_tui_conf.sh' "${DF}"
  grep -Fq "COPY .base/script/docker/lib /lint/lib" "${DF}"
}

@test "migration 3 (explicit-copy): detect false when lint stage uses lib/wrapper dir COPYs only (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper/*.sh /lint/
EOF
  run bash -c "$(_src); _migrate_explicit_copy_detect '${DF}'"
  assert_failure
}

# ── migration 4: _entrypoint_logging.sh -> runtime/logging.sh rename ─────────
# The host-log helper was renamed _entrypoint_logging.sh -> logging.sh and
# relocated under runtime/. Two references break in a downstream:
#   - the Dockerfile COPY of the helper into /usr/local/lib/base/
#   - the entrypoint that sources /usr/local/lib/base/_entrypoint_logging.sh
# Migration heals the COPY in the Dockerfile AND (when a sibling
# script/entrypoint.sh exists) its source line.

@test "migration 4 (logging-rename): rewrites the Dockerfile COPY to runtime/logging.sh (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/_entrypoint_logging.sh /usr/local/lib/base/_entrypoint_logging.sh
EOF
  run bash -c "$(_src); _migrate_logging_rename_detect '${DF}' && _migrate_logging_rename_apply '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh" "${DF}"
  refute grep -q '_entrypoint_logging.sh' "${DF}"
}

@test "migration 4 (logging-rename): rewrites a sibling entrypoint source line (#567)" {
  mkdir -p "${TEMP_DIR}/script"
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/_entrypoint_logging.sh /usr/local/lib/base/_entrypoint_logging.sh
EOF
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
. /usr/local/lib/base/_entrypoint_logging.sh
exec "$@"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq ". /usr/local/lib/base/logging.sh" "${TEMP_DIR}/script/entrypoint.sh"
  refute grep -q '_entrypoint_logging.sh' "${TEMP_DIR}/script/entrypoint.sh"
}

@test "migration 4 (logging-rename): detect false when already on new name (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); _migrate_logging_rename_detect '${DF}'"
  assert_failure
}

@test "migration 4 (logging-rename): heals a stale entrypoint when the Dockerfile is already migrated (#692)" {
  # Partial-migration state: a downstream repo hand-fixed the Dockerfile COPY
  # to runtime/logging.sh, but its sibling entrypoint still sources the old
  # baked /usr/local/lib/base/_entrypoint_logging.sh path. detect must still
  # fire (so apply runs and heals the entrypoint), otherwise the container
  # cannot source the renamed helper.
  mkdir -p "${TEMP_DIR}/script"
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
. /usr/local/lib/base/_entrypoint_logging.sh
exec "$@"
EOF
  run bash -c "$(_src); _migrate_logging_rename_detect '${DF}'"
  assert_success
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq ". /usr/local/lib/base/logging.sh" "${TEMP_DIR}/script/entrypoint.sh"
  refute grep -q '_entrypoint_logging.sh' "${TEMP_DIR}/script/entrypoint.sh"
}

# ── migration (smoke-copy): flat .base/test/smoke/ -> per-stage dist tree ────
# v0.41.0 shipped one flat smoke tree and the consumer Dockerfile copied it
# whole. The shipped specs now live under dist/test/bats/smoke/ split into
# shared/ + one folder per Dockerfile stage, so the flat COPY source is
# gone. The migration rewrites the single COPY into the shared baseline
# plus the enclosing stage's own folder, keeping the specs that stage used
# to run instead of quietly dropping them.

@test "migration (smoke-copy): rewrites the flat COPY into shared + the stage's own folder (#915)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/ /smoke_test/" "${DF}"
  grep -Fq "COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/" "${DF}"
  refute grep -q '\.base/test/smoke/' "${DF}"
  # The repo's OWN smoke COPY is not a base path and is left alone.
  grep -Fq "COPY test/smoke/ /smoke_test/" "${DF}"
}

@test "migration (smoke-copy): emits only the shared baseline when the stage ships no folder (#915)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  cat > "${DF}" <<'EOF'
FROM devel AS custom-test
COPY .base/test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/ /smoke_test/" "${DF}"
  refute grep -q 'smoke/custom-test/' "${DF}"
}

@test "migration (smoke-copy): idempotent — detect false once already on the dist tree (#915)" {
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY .base/dist/test/bats/smoke/shared/ /smoke_test/
COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}'"
  assert_failure
}

# ── migration (flat-to-dist): v0.41.0 flat .base/ layout -> .base/dist/ ──────
# The stable layout deployed on every consumer is the FLAT one: .base/config,
# .base/script/... . The dist relocation deleted both. downstream_to_dist
# only ever matched .base/downstream/, a layout that shipped as a
# prerelease and that no stable consumer is on -- so nothing migrated the
# layout that is actually out there, and the upgrade completed cleanly onto
# a Dockerfile whose every base COPY source had just been deleted.

@test "migration (flat-to-dist): rewrites the flat lint-stage lib/wrapper COPYs (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper /lint/wrapper
EOF
  run bash -c "$(_src); _migrate_flat_to_dist_detect '${DF}' && _migrate_flat_to_dist_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${DF}"
  grep -Fq "COPY .base/dist/script/docker/wrapper /lint/wrapper" "${DF}"
  refute grep -q '\.base/script/' "${DF}"
}

@test "migration (flat-to-dist): rewrites the flat config COPY (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
EOF
  run bash -c "$(_src); _migrate_flat_to_dist_apply '${DF}'"
  assert_success
  grep -Fq '.base/dist/config "${CONFIG_DIR}"' "${DF}"
}

@test "migration (flat-to-dist): idempotent — detect false on an already-dist Dockerfile (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
COPY .base/dist/config /tmp/config
EOF
  run bash -c "$(_src); _migrate_flat_to_dist_detect '${DF}'"
  assert_failure
}

@test "migration (flat-to-dist): dispatcher run twice rewrites exactly once (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${DF}"
  refute grep -q '\.base/dist/dist/' "${DF}"
}

# ── dispatcher over the whole v0.41.0 shape ─────────────────────────────────
# The unit tests above drive one {detect, transform} pair each. This one
# drives the dispatcher over the shape a real v0.41.0 consumer carries,
# because ORDER is what decides whether the logrotate / watchdog twins are
# generated from an already-dist-rooted logging COPY or from the flat one --
# and appending two more COPYs of paths that no longer exist is a strictly
# worse outcome than leaving the Dockerfile alone.

@test "apply_migrations leaves no .base COPY source behind on the v0.41.0 shape (#915)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM ${BASE_IMAGE} AS devel
# hadolint ignore=DL3006
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"

FROM devel AS devel-test
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper /lint/wrapper
RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  # Nothing may still name the deleted flat layout -- including the
  # logrotate / watchdog COPYs the dispatcher itself appends.
  run grep -nE '\.base/(config|script|test)/' "${DF}"
  assert_failure
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh" "${DF}"
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh" "${DF}"
}

# ── migration (logrotate-copy): logging.sh's logrotate.sh sibling ────────────
# runtime/logging.sh now sources a sibling logrotate.sh from the in-image
# helper dir. A downstream Dockerfile that COPYs logging.sh but predates the
# split lacks the logrotate.sh COPY, so the container tee degrades. This
# migration inserts the sibling COPY after the logging.sh COPY.

@test "migration (logrotate-copy): inserts logrotate.sh COPY after the logging.sh COPY (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); _migrate_logrotate_copy_detect '${DF}' && _migrate_logrotate_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh" "${DF}"
  # The original logging.sh COPY is preserved.
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh" "${DF}"
}

@test "migration (logrotate-copy): detect false when logrotate COPY already present (idempotent) (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh
EOF
  run bash -c "$(_src); _migrate_logrotate_copy_detect '${DF}'"
  assert_failure
}

@test "migration (logrotate-copy): detect false when no logging.sh COPY present (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_logrotate_copy_detect '${DF}'"
  assert_failure
}

@test "migration (logrotate-copy): dispatcher run twice inserts the COPY exactly once (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF '/usr/local/lib/base/logrotate.sh' "${DF}")"
  [ "${_n}" -eq 1 ]
}

# ── migration (watchdog-copy): watchdog.sh runtime helper sibling ────────────
# The generic watchdog ships runtime/watchdog.sh, COPY'd next to
# logging.sh at /usr/local/lib/base/. A downstream Dockerfile that COPYs
# logging.sh but predates the watchdog lacks the watchdog.sh COPY; this
# migration inserts the sibling COPY after the logging.sh COPY.

@test "migration (watchdog-copy): inserts watchdog.sh COPY after the logging.sh COPY (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); _migrate_watchdog_copy_detect '${DF}' && _migrate_watchdog_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh" "${DF}"
  # The original logging.sh COPY is preserved.
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh" "${DF}"
}

@test "migration (watchdog-copy): detect false when watchdog COPY already present (idempotent) (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh
EOF
  run bash -c "$(_src); _migrate_watchdog_copy_detect '${DF}'"
  assert_failure
}

@test "migration (watchdog-copy): detect false when no logging.sh COPY present (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_watchdog_copy_detect '${DF}'"
  assert_failure
}

@test "migration (watchdog-copy): dispatcher run twice inserts the COPY exactly once (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF '/usr/local/lib/base/watchdog.sh' "${DF}")"
  [ "${_n}" -eq 1 ]
}

# ── migration 5: hadolint rules surfaced by the slimmed .hadolint.yaml ───────
# v0.41.0 slimmed .hadolint.yaml, no longer ignoring a batch of rules.
# Heal the mechanical violations the fanout fixed by hand:
#   DL3007  FROM bats/bats:latest / alpine:latest -> pinned tags
#   DL3046  useradd -u -> useradd -l -u
#   DL3003  RUN cd /lint && hadolint -> WORKDIR /lint + RUN hadolint
#   DL3042  pip install -r -> pip install --no-cache-dir -r
#   DL4006  alpine lint-tools stage gains SHELL ash -o pipefail
#   DL3006  parameterized FROM ${BASE_IMAGE} gains an inline ignore

@test "migration 5 (hadolint): DL3007 pins bats/alpine :latest tags (#567)" {
  cat > "${DF}" <<'EOF'
FROM bats/bats:latest AS bats-helper
FROM alpine:latest AS lint-tools
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}' && _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Eq '^FROM bats/bats:[0-9]' "${DF}"
  grep -Eq '^FROM alpine:[0-9]' "${DF}"
  refute grep -Eq '^FROM (bats/bats|alpine):latest' "${DF}"
}

@test "migration 5 (hadolint): DL3046 adds useradd -l (#567)" {
  cat > "${DF}" <<'EOF'
RUN useradd -u "${UID}" -g "${GID}" "${USER}"
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'useradd -l -u "${UID}"' "${DF}"
}

@test "migration 5 (hadolint): DL3003 cd /lint -> WORKDIR /lint + RUN (#567)" {
  cat > "${DF}" <<'EOF'
RUN cd /lint && hadolint Dockerfile
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fxq 'WORKDIR /lint' "${DF}"
  grep -Fxq 'RUN hadolint Dockerfile' "${DF}"
  refute grep -q 'cd /lint &&' "${DF}"
}

@test "migration 5 (hadolint): DL3042 adds pip --no-cache-dir (#567)" {
  cat > "${DF}" <<'EOF'
RUN pip install -r requirements.txt
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'pip install --no-cache-dir -r requirements.txt' "${DF}"
}

@test "migration 5 (hadolint): DL4006 adds SHELL pipefail to alpine lint-tools (#567)" {
  cat > "${DF}" <<'EOF'
FROM alpine:3.21 AS lint-tools
RUN curl x | tar y
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'SHELL ["/bin/ash", "-o", "pipefail", "-c"]' "${DF}"
}

@test "migration 5 (hadolint): DL3006 inline ignore before parameterized FROM (#567)" {
  cat > "${DF}" <<'EOF'
FROM ${BASE_IMAGE} AS sys
FROM ${TEST_TOOLS_IMAGE} AS devel-test
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  [ "$(grep -c '# hadolint ignore=DL3006' "${DF}")" = "2" ]
}

@test "migration 5 (hadolint): DL3006 idempotent — does not double-insert (#567)" {
  cat > "${DF}" <<'EOF'
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS sys
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  [ "$(grep -c '# hadolint ignore=DL3006' "${DF}")" = "1" ]
}

@test "migration 5 (hadolint): detect false on a clean Dockerfile (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}'"
  assert_failure
}

# ── migration 6: noetic entrypoint SC1090 directive ─────────────────────────
# The noetic sensor entrypoints `source "/opt/ros/${ROS_DISTRO}/setup.bash"`
# with a stale `# shellcheck disable=SC1091` directive; the non-constant path
# triggers SC1090 (not SC1091), failing the v0.41.0 lint stage. Broaden the
# directive to SC1090,SC1091 on the sibling script/entrypoint.sh.

@test "migration 6 (sc1090): broadens the entrypoint directive to SC1090,SC1091 (#567)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"  # presence-only; the dispatcher needs a Dockerfile to run
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq '# shellcheck disable=SC1090,SC1091' "${TEMP_DIR}/script/entrypoint.sh"
}

@test "migration 6 (sc1090): idempotent when already SC1090,SC1091 (#567)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
EOF
  cp "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
}

@test "migration 6 (sc1090): detect false when no sibling entrypoint (#567)" {
  : > "${DF}"
  run bash -c "$(_src); _migrate_sc1090_detect '${DF}'"
  assert_failure
}

# ── migration 7 (facet B): ARG USER -> ARG USER="${USER_NAME}" ─────────
# v0.41.0 compose/CI pass USER_NAME (not USER) as the build arg; a Dockerfile
# still declaring a bare `ARG USER` builds the default `initial` user, which
# mismatches the compose /home/${USER_NAME}/work mount. Re-declare the arg to
# default from USER_NAME so the existing user-creation block keeps working.

@test "migration 7 (arg-user): rewrites bare 'ARG USER' to default from USER_NAME (#579)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG USER
RUN useradd "${USER}"
EOF
  run bash -c "$(_src); _migrate_arg_user_detect '${DF}' && _migrate_arg_user_apply '${DF}'"
  assert_success
  grep -Fxq 'ARG USER="${USER_NAME}"' "${DF}"
}

@test "migration 7 (arg-user): idempotent — already defaulted is not detected (#579)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG USER="${USER_NAME}"
EOF
  run bash -c "$(_src); _migrate_arg_user_detect '${DF}'"
  assert_failure
}

@test "migration 7 (arg-user): does not touch an unrelated ARG (#579)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG USERLAND
ARG USER_NAME
EOF
  run bash -c "$(_src); _migrate_arg_user_detect '${DF}'"
  assert_failure
}

# ── migration 8 (facet B): entrypoint nounset-guard the ROS source ─────
# Under `set -u`, sourcing /opt/ros/$ROS_DISTRO/setup.bash dies on the
# unbound AMENT_TRACE_SETUP_FILES, so the container exits at start and
# `just run` fails (CI never catches it — smoke runs at build time, never
# starts the container). Bracket the source with `set +u` / `set -u` so the
# unbound vars inside setup.bash do not abort the entrypoint.

@test "migration 8 (nounset-source): brackets the ROS source with set +u/-u (#579)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  # The source line is now wrapped: set +u immediately before, set -u after.
  run grep -n -E 'set \+u|setup\.bash|set -u' "${TEMP_DIR}/script/entrypoint.sh"
  assert_output --partial "set +u"
  # Ordering: +u line precedes the source, -u line follows it.
  local plus src minus
  plus="$(grep -n '^set +u' "${TEMP_DIR}/script/entrypoint.sh" | head -1 | cut -d: -f1)"
  src="$(grep -n 'setup.bash' "${TEMP_DIR}/script/entrypoint.sh" | head -1 | cut -d: -f1)"
  minus="$(grep -n '^set -u' "${TEMP_DIR}/script/entrypoint.sh" | tail -1 | cut -d: -f1)"
  [ "${plus}" -lt "${src}" ]
  [ "${minus}" -gt "${src}" ]
}

@test "migration 8 (nounset-source): idempotent — already-guarded source untouched (#579)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set +u
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
set -u
exec "$@"
EOF
  cp "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
}

@test "migration 8 (nounset-source): detect false when no set -u in entrypoint (#579)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
source "/opt/ros/${ROS_DISTRO}/setup.bash"
EOF
  run bash -c "$(_src); _migrate_nounset_source_detect '${DF}'"
  assert_failure
}
