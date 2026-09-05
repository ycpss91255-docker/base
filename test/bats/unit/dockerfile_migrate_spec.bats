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
#
# why: Unit tests for the declarative Dockerfile-migration list
# `lib/dockerfile_migrate.sh` (#567, folds #579 facet B). The lib exposes a
# small interface — `apply_migrations <dockerfile>` — over an ordered,
# data-driven `_MIGRATIONS` table of `{detect, transform}` units, each
# healing one v0.41.0-fanout Dockerfile/entrypoint breakage. upgrade.sh Step
# 5 sources the lib and calls the dispatcher (replacing the old one-off
# seds). Each migration is driven in isolation via before/after fixtures
# plus the dispatcher's apply / skip / idempotency contract: a detected
# shape auto-applies idempotently, a missing/ambiguous shape is skipped
# (warn, never force-rewrite).

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

# why: Small interface exists
@test "apply_migrations is the public dispatcher entry (#567)" {
  run bash -c "$(_src); declare -F apply_migrations"
  assert_success
}

# why: No-Dockerfile skip
@test "apply_migrations skips cleanly when path does not exist (#567)" {
  run bash -c "$(_src); apply_migrations '${TEMP_DIR}/nope'"
  assert_success
  assert_output --partial "no Dockerfile"
}

# why: Data-driven table is seeded
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
  # Root reads a mode-000 file, so the fixtures are an ELOOP symlink, a
  # path that is not there at all, and a DIRECTORY -- the same technique
  # the sibling cases above use, and none injects a seam.
  ln -s loop "${TEMP_DIR}/loop"
  run bash -c "$(_src); _dfm_pip_line_is_standalone '${TEMP_DIR}/loop'"
  assert_equal "${status}" 1
  run bash -c "$(_src); _dfm_pip_line_is_standalone '${TEMP_DIR}/gone'"
  assert_equal "${status}" 1
  # The directory is the leg the redirect probe does NOT answer, and the
  # one the function's own safety sentence claims it does. On Linux
  # open(2) on a directory for reading SUCCEEDS: `read` then fails with
  # EISDIR, the loop exits, and the loop's status is 0 -- so the probe
  # reports "standalone, safe to delete" for a path nothing read, which
  # is the defect this whole block exists to refuse.
  mkdir -p "${TEMP_DIR}/adir"
  run bash -c "$(_src); _dfm_pip_line_is_standalone '${TEMP_DIR}/adir'"
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

@test "migration (smoke-copy): an unresolvable per-stage path costs the stage its own COPY (#956)" {
  # A PINNED DEVIATION, not desired behaviour. The status block at the top
  # of lib/dockerfile_migrate.sh says that outside migration 2 an
  # unanswered question leaves the file alone. This apply asks one -- which
  # per-stage folders the freshly pulled subtree ships -- in its APPLY
  # rather than its detect, and answers it with a glob plus
  # `[[ -d ]] || continue`, which folds "this path could not be read" into
  # "this stage ships no folder". The Dockerfile is rewritten anyway and
  # the stage loses the specs it used to run.
  #
  # The case above proves the intended shape (a real devel-test folder
  # gives a per-stage COPY); this one differs from it in exactly one way,
  # the folder being unreachable rather than absent, so what it measures is
  # the fold and nothing else. A self-referential symlink, because this
  # suite reads as root and a mode cannot make anything unreadable there.
  #
  # It is a characterization test: when the follow-up teaches the apply to
  # refuse a path it could not read, this case is what has to change, and
  # the header claim it backs changes with it.
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  ln -s devel-test "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY .base/test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/ /smoke_test/" "${DF}"
  refute grep -q 'smoke/devel-test/' "${DF}"
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

# The same tree was also reached FILE BY FILE. Six of the org's consumer
# repos hand-list the specs instead of copying the directory -- four write one
# COPY per spec, two put every spec on a single COPY -- and those sources died
# in the same relocation.
# The migration resolves each named spec against the freshly pulled subtree
# by basename, so what heals them is where the tree says the spec now is.

@test "migration (smoke-copy): rewrites a hand-listed spec to where the subtree ships it (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/script_help.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/test_helper.bash /smoke_test/test_helper.bash
COPY .base/test/smoke/script_help.bats /smoke_test/script_help.bats
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  # Each spec lands where the subtree actually ships it -- the two are in
  # DIFFERENT folders, so a single blanket prefix could not have done this.
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/test_helper.bash /smoke_test/test_helper.bash" "${DF}"
  grep -Fq "COPY .base/dist/test/bats/smoke/devel-test/script_help.bats /smoke_test/script_help.bats" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
}

@test "migration (smoke-copy): rewrites every source of a multi-source hand-listed COPY (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/script_help.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/test_helper.bash .base/test/smoke/script_help.bats /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/test_helper.bash .base/dist/test/bats/smoke/devel-test/script_help.bats /smoke_test/" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
}

@test "migration (smoke-copy): declines a hand-listed spec the subtree no longer ships (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/retired.bats /smoke_test/retired.bats
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  # Left as written, and SAID so: a guessed destination would resolve to a
  # path the subtree does not ship, which is the failure this heals.
  grep -Fq "COPY .base/test/smoke/retired.bats /smoke_test/retired.bats" "${DF}"
  assert_output --partial "resolve it by hand"
}

@test "migration (smoke-copy): declines a hand-listed spec the subtree ships at two paths (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/ambiguous.bats"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/ambiguous.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/ambiguous.bats /smoke_test/ambiguous.bats
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/test/smoke/ambiguous.bats /smoke_test/ambiguous.bats" "${DF}"
  assert_output --partial "resolve it by hand"
}

# A COPY statement is not a line. Consumers wrap long hand-listed statements
# across backslash continuations, and Docker reads the whole thing as one
# statement -- so the migration has to as well. A line-oriented rewrite heals
# the sources on the first physical line, leaves the rest naming the deleted
# tree, and (because a continuation line does not start with COPY) does not
# even see them to warn about. The lib already ships
# _dfm_join_copy_statements for exactly this fold; these pin that the detect,
# the heal and the post-apply warning all reason about the folded statement.

@test "migration (smoke-copy): heals hand-listed sources on a continuation line (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/script_help.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/test_helper.bash \
     .base/test/smoke/script_help.bats \
     /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/test_helper.bash \\" "${DF}"
  grep -Fq "     .base/dist/test/bats/smoke/devel-test/script_help.bats \\" "${DF}"
  # The continuation line is the half a line-oriented rewrite left behind.
  ! grep -q '\.base/test/smoke/' "${DF}"
}

@test "migration (smoke-copy): detects a statement whose smoke sources are only on continuation lines (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY \
     .base/test/smoke/test_helper.bash \
     /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "     .base/dist/test/bats/smoke/shared/test_helper.bash \\" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
}

@test "migration (smoke-copy): warns about an unresolvable spec on a continuation line (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/test_helper.bash \
     .base/test/smoke/retired.bats \
     /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "     .base/test/smoke/retired.bats \\" "${DF}"
  # Half-healing in silence is the outcome the contract rules out: what the
  # migration cannot resolve it declines OUT LOUD.
  assert_output --partial "resolve it by hand"
}

@test "migration (smoke-copy): duplicates a continued wholesale COPY into shared + the stage's own folder (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/ \
     /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  # Both physical lines of the statement are reproduced, twice.
  [ "$(grep -cF 'smoke_test/' "${DF}")" -eq 2 ]
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/ \\" "${DF}"
  grep -Fq "COPY .base/dist/test/bats/smoke/devel-test/ \\" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
}

# The detect is a path prefix, so it has to stop at a path boundary. A tree
# that merely STARTS with the retired name is not the retired tree, and
# firing on it makes the migration log a patch it did not make and a warning
# nobody can act on -- which is how an operator learns to ignore the warning
# that matters.

@test "migration (smoke-copy): a .base/test/smoke-prefixed sibling path is not the retired tree (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke_helpers/x.bash /smoke_test/x.bash
DOCKERFILE
  cp "${DF}" "${TEMP_DIR}/Dockerfile.before"
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}'"
  assert_failure
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  refute_output --partial "per-stage dist smoke COPYs"
  refute_output --partial "resolve it by hand"
  diff "${TEMP_DIR}/Dockerfile.before" "${DF}"
}

# ── migration (repo-smoke-copy): repo-owned test/smoke/ -> per-stage ────────
# The sibling of smoke-copy. That one heals the path into base's SHIPPED
# tree; this one heals the path into the repo's OWN. Both moved in the same
# v0.42.0 reorganisation, only the shipped half was migrated, so an upgraded
# repo kept a flat test/smoke/ that a fresh bootstrap never produces.
#
# A fresh repo emits the stage COPY even when that stage's folder holds only
# a .gitkeep, so matching it means emitting on folder existence, not on the
# folder having specs in it.

# why: Wholesale rewrite: shared baseline plus the enclosing stage folder
@test "migration (repo-smoke-copy): rewrites the flat COPY into shared + the stage's own folder (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared" \
    "${TEMP_DIR}/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_repo_smoke_copy_detect '${DF}' && _migrate_repo_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY test/bats/smoke/shared/ /smoke_test/" "${DF}"
  grep -Fq "COPY test/bats/smoke/devel-test/ /smoke_test/" "${DF}"
  refute grep -qE '^[[:space:]]*COPY[[:space:]]+test/smoke/' "${DF}"
}

# why: A stage the repo has no folder for gets no COPY of its own
@test "migration (repo-smoke-copy): emits only the shared baseline when the repo ships no stage folder (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  cat > "${DF}" <<'EOF'
FROM devel AS custom-test
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_repo_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY test/bats/smoke/shared/ /smoke_test/" "${DF}"
  refute grep -q 'smoke/custom-test/' "${DF}"
}

# why: The two smoke migrations stay disjoint over one Dockerfile
@test "migration (repo-smoke-copy): leaves base's own shipped path to smoke-copy (#1044)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/test/bats/smoke/shared"
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY .base/test/smoke/ /smoke_test/
EOF
  # Guard against a vacuous pass: a MISSING function also exits non-zero,
  # which would satisfy assert_failure for entirely the wrong reason.
  run bash -c "$(_src); declare -F _migrate_repo_smoke_copy_detect"
  assert_success
  run bash -c "$(_src); _migrate_repo_smoke_copy_detect '${DF}'"
  assert_failure
}

# why: Idempotent: a Dockerfile already per-stage is not detected
@test "migration (repo-smoke-copy): idempotent — detect false once already per-stage (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared" \
    "${TEMP_DIR}/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY test/bats/smoke/shared/ /smoke_test/
COPY test/bats/smoke/devel-test/ /smoke_test/
EOF
  cp "${DF}" "${TEMP_DIR}/Dockerfile.before"
  # Guard against a vacuous pass: a MISSING function also exits non-zero,
  # which would satisfy assert_failure for entirely the wrong reason.
  run bash -c "$(_src); declare -F _migrate_repo_smoke_copy_detect"
  assert_success
  run bash -c "$(_src); _migrate_repo_smoke_copy_detect '${DF}'"
  assert_failure
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${TEMP_DIR}/Dockerfile.before" "${DF}"
}

# why: A sibling merely prefixed by the retired name is not it
@test "migration (repo-smoke-copy): a test/smoke-prefixed sibling path is not the retired tree (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY test/smoke_helpers/x.bash /smoke_test/x.bash
DOCKERFILE
  cp "${DF}" "${TEMP_DIR}/Dockerfile.before"
  # Guard against a vacuous pass: a MISSING function also exits non-zero,
  # which would satisfy assert_failure for entirely the wrong reason.
  run bash -c "$(_src); declare -F _migrate_repo_smoke_copy_detect"
  assert_success
  run bash -c "$(_src); _migrate_repo_smoke_copy_detect '${DF}'"
  assert_failure
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${TEMP_DIR}/Dockerfile.before" "${DF}"
}

# why: A COPY is a statement, not a line: continuations count
@test "migration (repo-smoke-copy): detects a source only on a continuation line (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY \
  test/smoke/ /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_repo_smoke_copy_detect '${DF}'"
  assert_success
}

# why: Registered, and ordered after the migration whose path contains its own
@test "migration (repo-smoke-copy): is registered, and after smoke-copy (#1044)" {
  run bash -c "$(_src); printf '%s\n' \"\${_MIGRATIONS[@]}\""
  assert_success
  assert_line 'repo_smoke_copy'
  # Order is load-bearing. smoke-copy rewrites the SHIPPED path first, so
  # by the time this one runs no line still names the retired shipped
  # tree and the two cannot both claim the same statement.
  local _base_at _repo_at _i=0 _line
  while IFS= read -r _line; do
    [[ "${_line}" == 'smoke_copy' ]] && _base_at="${_i}"
    [[ "${_line}" == 'repo_smoke_copy' ]] && _repo_at="${_i}"
    _i=$((_i + 1))
  done <<< "${output}"
  assert [ -n "${_base_at}" ]
  assert [ -n "${_repo_at}" ]
  assert [ "${_base_at}" -lt "${_repo_at}" ]
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
# because ORDER is what decides whether the helper COPY is collapsed from an
# already-dist-rooted source or from the flat one -- and emitting a directory
# COPY of a path that no longer exists is a strictly worse outcome than
# leaving the Dockerfile alone.

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
  # Status pinned to grep's own no-match: assert_failure also accepts an
  # exit 2 (unreadable file), which would pass this with nothing read.
  run grep -nE '\.base/(config|script|test)/' "${DF}"
  [ "${status}" -eq 1 ]
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/" "${DF}"
}

# ── every COPY source the dispatcher leaves behind must RESOLVE ────────────
#
# The tests above each pin one rewrite by name. This one pins the property
# those rewrites exist to deliver, and it is deliberately written so that a
# path added or moved LATER is covered without anyone editing it:
#
#   * the subtree under test is the real shipped tree (`.base/dist` is a
#     symlink to /source/dist), not a set of empty mkdir'd stand-ins, so
#     "resolves" means the file base actually ships is there;
#   * the population of paths checked is DERIVED from the migrated
#     Dockerfile -- every `.base/...` token in a COPY source position,
#     the collapsed helper directory the dispatcher itself writes included
#     -- never a list written out here. A migration that starts
#     emitting a new path is checked the moment it emits it, and a shipped
#     directory that moves fails this test without being named in it;
#   * the derived population is asserted NON-EMPTY before it is walked, so
#     a regex that stops matching fails loudly instead of passing with
#     nothing to check.
#
# The fixture is the shape the six hand-listing consumers carry
# (ai_agent / claude_code / codex_cli / gemini_cli, one spec per line;
# ros1_bridge / urg_node_humble, two sources on one line) folded together
# with the flat lint/config/logging COPYs every v0.41.0 consumer has.

@test "apply_migrations leaves every .base COPY source resolvable in the shipped tree (#969)" {
  assert_spec_subject "/source/dist/script/docker/lib/dockerfile_migrate.sh" \
    "the migration list this spec drives"
  # The subtree the upgrade just pulled, exactly as shipped.
  mkdir -p "${TEMP_DIR}/.base"
  ln -s /source/dist "${TEMP_DIR}/.base/dist"

  cat > "${DF}" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS devel
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"

FROM devel AS devel-test
COPY .base/script/docker/*.sh /lint/
COPY .base/script/docker/lib /lint/lib
COPY .base/test/smoke/test_helper.bash /smoke_test/test_helper.bash
COPY .base/test/smoke/script_help.bats /smoke_test/script_help.bats
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success

  local _tokens
  _tokens="$(grep -E '^[[:space:]]*COPY[[:space:]]' "${DF}" \
    | grep -oE '\.base/[A-Za-z0-9_.*/-]+')"
  local _n
  _n="$(printf '%s\n' "${_tokens}" | grep -c .)"
  # Population assertion: the COPY sources reachable from this fixture, a
  # figure that drops when the extraction stops matching rather than when
  # the Dockerfile gets cleaner. It fell by two when the per-file helper
  # COPYs collapsed into one directory COPY.
  [ "${_n}" -ge 6 ]

  local _tok
  while IFS= read -r _tok; do
    if [[ "${_tok}" == *'*'* ]]; then
      compgen -G "${TEMP_DIR}/${_tok}" > /dev/null \
        || fail "COPY source does not resolve in the shipped tree: ${_tok}"
    else
      [[ -e "${TEMP_DIR}/${_tok}" ]] \
        || fail "COPY source does not resolve in the shipped tree: ${_tok}"
    fi
  done <<< "${_tokens}"

  # And nothing may still name the pre-dist layout. Status pinned to grep's
  # own no-match: an exit 2 (unreadable file) is a broken assertion, not a
  # pass.
  run grep -nE '\.base/(config|script|test)/' "${DF}"
  [ "${status}" -eq 1 ]
}

# ── migration (runtime-moved-files): the two non-helpers leaving runtime/ ────
# entrypoint.sh (a seeded template) and smoke.sh (a runtime-test helper) left
# dist/script/docker/runtime/ so the directory could be COPY'd whole. A
# consumer Dockerfile that names either source -- the commented runtime-test
# scaffold names smoke.sh in every repo init.sh ever seeded -- resolves to
# nothing the moment it is uncommented.

@test "migration (runtime-moved-files): rewrites the smoke.sh source to the shipped test tree (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS runtime-test
# COPY .base/dist/script/docker/runtime/smoke.sh /usr/local/lib/base/smoke.sh
EOF
  run bash -c "$(_src); _migrate_runtime_moved_files_detect '${DF}' && _migrate_runtime_moved_files_apply '${DF}'"
  assert_success
  grep -Fq ".base/dist/test/bats/smoke/smoke.sh /usr/local/lib/base/smoke.sh" "${DF}"
  run grep -F 'script/docker/runtime/smoke.sh' "${DF}"
  assert_failure
}

@test "migration (runtime-moved-files): rewrites the entrypoint.sh source at the pre-dist path (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/runtime/entrypoint.sh /entrypoint.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/dockerfile/entrypoint.sh /entrypoint.sh" "${DF}"
}

@test "migration (runtime-moved-files): detect false once nothing names the old paths (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/
EOF
  run bash -c "$(_src); _migrate_runtime_moved_files_detect '${DF}'"
  assert_failure
}

# ── migration (runtime-dir-copy): per-file helper COPYs -> one dir COPY ──────
# Every consumer Dockerfile listed base's runtime helpers one COPY per file,
# so base adding a helper was a change to every consumer repo -- and the two
# migrations that existed only to close that gap (logrotate_copy,
# watchdog_copy) are what this replaces. Collapse any subset of the helper
# COPYs, in any order, at either the pre-dist or the dist path, into the one
# directory COPY that cannot fall out of agreement with what base ships.

@test "migration (runtime-dir-copy): collapses the three per-file COPYs into one dir COPY (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh
EOF
  run bash -c "$(_src); _migrate_runtime_dir_copy_detect '${DF}' && _migrate_runtime_dir_copy_apply '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF 'COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/' "${DF}")"
  [ "${_n}" -eq 1 ]
  # No per-file helper COPY survives.
  run grep -E 'runtime/(logging|logrotate|watchdog)\.sh' "${DF}"
  assert_failure
}

@test "migration (runtime-dir-copy): collapses a subset in any order at the pre-dist path (#971)" {
  # The shape a consumer that took the watchdog fanout but not the logrotate
  # one carries, written in the order the two migrations appended it.
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF 'COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/' "${DF}")"
  [ "${_n}" -eq 1 ]
}

@test "migration (runtime-dir-copy): one dir COPY per stage, not one for the file (#971)" {
  # omniverse_web_viewer carries the helper COPY in three stages
  # (runtime / devel / example) and ros1_bridge in two: a stage that does not
  # COPY the helpers must not acquire them, and a stage that does must keep
  # exactly one.
  cat > "${DF}" <<'EOF'
FROM busybox AS runtime
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh

FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh

FROM devel AS devel-test
RUN echo hi
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF 'COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/' "${DF}")"
  [ "${_n}" -eq 2 ]
}

@test "migration (runtime-dir-copy): a statement hand-listing two helpers collapses to one source (#971)" {
  # ros1_bridge and urg_node_humble already hand-list two sources on one
  # COPY for their smoke specs, so the shape is one a consumer writes.
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fxq "COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/" "${DF}"
}

@test "migration (runtime-dir-copy): a hand-relocated destination is preserved (#971)" {
  # detect anchors on the SOURCE, so a consumer that bakes the helpers
  # somewhere other than /usr/local/lib/base/ still collapses -- into its own
  # destination, not into base's.
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /opt/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/ /opt/base/" "${DF}"
}

@test "migration (runtime-dir-copy): rewrites the commented runtime-stage example too (#971)" {
  # init.sh seeds the commented runtime-stage scaffold into every repo. Left
  # per-file it teaches the shape this change exists to remove, to a reader
  # who will uncomment it later.
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
RUN echo hi
# COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
# COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cE '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/ /usr/local/lib/base/$' "${DF}")"
  [ "${_n}" -eq 1 ]
}

@test "migration (runtime-dir-copy): an already-collapsed dir COPY is left alone (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/
EOF
  run bash -c "$(_src); _migrate_runtime_dir_copy_detect '${DF}'"
  assert_failure
}

@test "migration (runtime-dir-copy): dispatcher run twice collapses exactly once (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF 'COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/' "${DF}")"
  [ "${_n}" -eq 1 ]
}

@test "migration (runtime-dir-copy): detect false when no helper COPY is present (#971)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_runtime_dir_copy_detect '${DF}'"
  assert_failure
}

# ── the shape the REAL consumers carry ──────────────────────────────────────
#
# Not a synthesised fixture: base's own new-repo fixture is written by
# _create_new_repo, a shape base#928 showed no real consumer has. Every repo
# under the org whose Dockerfile names a runtime helper was read, and this
# is what they carry -- the FLAT pre-dist path, `logging.sh` alone (no repo
# took the logrotate / watchdog fanout), repeated once per stage that wants
# it, plus the commented runtime-test smoke.sh scaffold init.sh seeded:
#
#   jetson_sdk_manager   1 COPY  (devel)
#   omniverse_web_viewer 3 COPYs (runtime, devel, example)
#   ros1_bridge          2 COPYs (devel, runtime)
#
# The property asserted is the one an upgrade owes them: after the
# dispatcher, no COPY source names a path base no longer ships.

@test "apply_migrations heals the runtime COPYs every real consumer actually carries (#971)" {
  assert_spec_subject "/source/dist/script/docker/lib/dockerfile_migrate.sh" \
    "the migration list this spec drives"
  mkdir -p "${TEMP_DIR}/.base"
  ln -s /source/dist "${TEMP_DIR}/.base/dist"

  cat > "${DF}" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS runtime
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh

FROM ${BASE_IMAGE} AS devel
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh

FROM runtime AS runtime-test
# COPY .base/script/docker/runtime/smoke.sh /usr/local/lib/base/smoke.sh
# ARG RUNTIME_SMOKE_CMD='whoami && bash --version && bash /usr/local/lib/base/smoke.sh'

FROM devel-base AS example
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success

  # One dir COPY per stage that had a helper COPY -- three, not four.
  local _n
  _n="$(grep -cF 'COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/' "${DF}")"
  [ "${_n}" -eq 3 ]

  # Every `.base/...` COPY source left behind resolves in the shipped tree,
  # the commented smoke.sh scaffold included: it is inert today and a
  # "COPY source not found" the day a consumer uncomments it.
  local _tokens
  _tokens="$(grep -E '^[[:space:]]*#?[[:space:]]*COPY[[:space:]]' "${DF}" \
    | grep -oE '\.base/[A-Za-z0-9_.*/-]+')"
  local _count
  _count="$(printf '%s\n' "${_tokens}" | grep -c .)"
  [ "${_count}" -ge 4 ]
  local _tok
  while IFS= read -r _tok; do
    [[ -e "${TEMP_DIR}/${_tok}" ]] \
      || fail "COPY source does not resolve in the shipped tree: ${_tok}"
  done <<< "${_tokens}"
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

# The nounset the ROS source runs under is not always written in the file
# that runs it. base's orchestrator (ADR-00000032) SOURCES the bringup under
# its own `set -euo pipefail`, so a repo that flipped its ENTRYPOINT while
# carrying the bringup init.sh seeded BEFORE that release -- which has no
# `set` line at all -- runs its ROS source under nounset for the first time
# and the container dies on the unbound AMENT_TRACE_SETUP_FILES before the
# workload ever starts. Keying the guard on an in-file `set -u` alone leaves
# exactly the migration path README documents uncovered, and silently: the
# orchestrator notice does not fire on an already-flipped Dockerfile, and
# the bringup-residue notice does not fire on a correctly cleaned bringup.

# why: The gap the branch's own README migration opens. Keying the guard
# on an in-file `set -u` covers nothing here -- the bringup seeded before
# this release has no `set` line at all, and the orchestrator imposes
# nounset from outside it. This is the FAILS-at-HEAD case; without it the
# migration stays silent on exactly the path base tells people to take
@test "migration 8 (nounset-source): fires under the orchestrator when the bringup sets nothing (#945)" {
  mkdir -p "${TEMP_DIR}/script"
  printf 'ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]\n' > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
EOF
  run bash -c "$(_src); _migrate_nounset_source_detect '${DF}'"
  assert_success
}

# why: Detecting is half of it; the write has to be correct for a file
# that never set nounset itself. The trailing `set -u` must RESTORE the
# mode the orchestrator was already in, which is checked by re-running
# detect on the rewritten file rather than by eyeballing the diff
@test "migration 8 (nounset-source): brackets that bringup's source, directive and all (#945)" {
  mkdir -p "${TEMP_DIR}/script"
  printf 'ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]\n' > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  local plus src minus
  plus="$(grep -n '^set +u' "${TEMP_DIR}/script/entrypoint.sh" | head -1 | cut -d: -f1)"
  src="$(grep -n 'setup.bash' "${TEMP_DIR}/script/entrypoint.sh" | head -1 | cut -d: -f1)"
  minus="$(grep -n '^set -u' "${TEMP_DIR}/script/entrypoint.sh" | tail -1 | cut -d: -f1)"
  [ "${plus}" -lt "${src}" ]
  [ "${minus}" -gt "${src}" ]
  # The trailing `set -u` RESTORES the orchestrator's nounset rather than
  # introducing one: everything after the bracket runs exactly as the
  # orchestrator would have run it.
  run bash -c "$(_src); _migrate_nounset_source_detect '${DF}'"
  assert_failure
}

# why: Bounds the widened trigger. Now that an ENTRYPOINT can turn the
# migration on, the obvious over-reach is firing on the ENTRYPOINT alone --
# which would bracket nothing and warn on every orchestrator repo for ever
@test "migration 8 (nounset-source): silent under the orchestrator with no ROS source (#945)" {
  # The trigger is the unguarded source, never the ENTRYPOINT on its own:
  # a bringup that sources nothing has nothing to bracket.
  mkdir -p "${TEMP_DIR}/script"
  printf 'ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]\n' > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
EOF
  run bash -c "$(_src); _migrate_nounset_source_detect '${DF}'"
  assert_failure
}

# why: The direction that would do harm rather than nothing. Pre-flip the
# repo's own file is the ENTRYPOINT and no nounset is in force, so writing
# a trailing `set -u` would TURN IT ON for the rest of a file that never
# asked -- a migration breaking the repo it was meant to protect
@test "migration 8 (nounset-source): still silent pre-flip, where nothing imposes nounset (#945)" {
  # An un-migrated repo runs its own file as the ENTRYPOINT, under whatever
  # options that file sets -- none here. Inserting a trailing `set -u` would
  # turn nounset ON for the rest of a file that never asked for it.
  mkdir -p "${TEMP_DIR}/script"
  printf 'ENTRYPOINT ["/entrypoint.sh"]\n' > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "${@}"
EOF
  run bash -c "$(_src); _migrate_nounset_source_detect '${DF}'"
  assert_failure
}

# ── migration (entrypoint-orchestrator / bringup-residue): notice, no rewrite ─
#
# base's plumbing moved into an orchestrator that ships from .base/. The two
# per-repo edits that adopt it -- flip ENTRYPOINT, clean the bringup -- are
# the repo owner's, because only the owner can tell a bringup line from base
# plumbing in a file that has been hand-edited for a year. So base NOTICES.
#
# The hard half of "warn-only" is not the warning, it is the two claims
# either side of it: that nothing on disk moves, and that the notice is
# silent on every shape it does not name. An alarm that fires on a migrated
# repo, or on a repo whose ENTRYPOINT is some third file, is one a reader
# learns to ignore -- and it would fire on every upgrade of every repo.

# _write_old_model_repo -- a repo on the pre-orchestrator model: its own
# /entrypoint.sh as the ENTRYPOINT, and a bringup carrying base's plumbing
# and the exec. This is the shape every consumer repo is in today.
_write_old_model_repo() {
  cat > "${DF}" <<'EOF'
FROM ubuntu:24.04 AS devel
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
EOF
  mkdir -p "${TEMP_DIR}/script"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. /usr/local/lib/base/logging.sh
export MY_APP_HOME=/opt/app
exec "${@}"
EOF
}

# _write_migrated_repo <bringup-body> -- a repo that has flipped its
# ENTRYPOINT to the orchestrator, with the given bringup.
_write_migrated_repo() {
  cat > "${DF}" <<'EOF'
FROM ubuntu:24.04 AS devel
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chmod=0755 .base/dist/script/docker/runtime/ /usr/local/lib/base/
ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]
CMD ["bash"]
EOF
  mkdir -p "${TEMP_DIR}/script"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "${TEMP_DIR}/script/entrypoint.sh"
}

# why: The positive case, on the shape every consumer repo is in today. A
# detect that never fires is a migration nobody is told about, and the
# adoption edits are the owner's to make
@test "migration (entrypoint-orchestrator): notices a repo still running its own entrypoint (#945)" {
  _write_old_model_repo
  run bash -c "$(_src); _migrate_entrypoint_orchestrator_detect '${DF}'"
  assert_success
}

# why: The load-bearing claim of the whole release -- an existing repo
# comes out of `just upgrade` byte-identical and goes on working. Only the
# owner can tell a bringup line from base plumbing in a file hand-edited
# for a year, so an apply that rewrote anything here would break repos base
# cannot see. Both files are diffed, not just the Dockerfile
@test "migration (entrypoint-orchestrator): the notice changes nothing on disk (#945)" {
  # The whole contract. A repo that has not migrated must come out of an
  # upgrade byte-identical -- Dockerfile AND bringup -- and go on working.
  _write_old_model_repo
  cp "${DF}" "${TEMP_DIR}/Dockerfile.orig"
  cp "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
  run bash -c "$(_src); _migrate_entrypoint_orchestrator_apply '${DF}'"
  assert_success
  assert_output --partial "orchestrator"
  diff "${DF}" "${TEMP_DIR}/Dockerfile.orig"
  diff "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
}

# why: The notice has to stop. It runs on every `just upgrade` of every
# repo, so one that kept firing after the migration is one readers learn to
# ignore -- which costs the next migration its only channel
@test "migration (entrypoint-orchestrator): silent once the ENTRYPOINT is the orchestrator (#945)" {
  _write_migrated_repo 'export MY_APP_HOME=/opt/app'
  run bash -c "$(_src); _migrate_entrypoint_orchestrator_detect '${DF}'"
  assert_failure
}

# why: Every repo generated from the shipped template carries a commented
# runtime-stage ENTRYPOINT, so a detect that read comments would fire on
# fully migrated repos for ever. The most likely wrong implementation is a
# plain grep, and this is the case that separates it from a correct one
@test "migration (entrypoint-orchestrator): a commented ENTRYPOINT is not the live model (#945)" {
  # The shipped Dockerfile carries a commented runtime-stage scaffold, and
  # so does every repo generated from it. A notice that read those would
  # fire on a fully migrated repo for ever.
  _write_migrated_repo 'export MY_APP_HOME=/opt/app'
  printf '# ENTRYPOINT ["/entrypoint.sh"]\n' >> "${DF}"
  run bash -c "$(_src); _migrate_entrypoint_orchestrator_detect '${DF}'"
  assert_failure
}

# why: A real repo in the org does this -- ros1_bridge's runtime stage runs
# the upstream image's /ros_entrypoint.sh. Detecting "an ENTRYPOINT that is
# not the orchestrator" instead of "the repo's own bringup" would nag that
# repo on every upgrade about a migration it has already made
@test "migration (entrypoint-orchestrator): an unrelated ENTRYPOINT is not this model (#945)" {
  # ros1_bridge's runtime stage runs the upstream image's
  # /ros_entrypoint.sh. Naming a different file is not being un-migrated.
  _write_migrated_repo 'export MY_APP_HOME=/opt/app'
  printf 'ENTRYPOINT ["/ros_entrypoint.sh"]\n' >> "${DF}"
  run bash -c "$(_src); _migrate_entrypoint_orchestrator_detect '${DF}'"
  assert_failure
}

# why: The coupling between the two adoption edits, and the failure that
# hides. The orchestrator SOURCES the bringup, so a surviving exec fires
# mid-source: the watchdog never arms and the container looks healthy until
# the day it needed restarting
@test "migration (bringup-residue): notices an exec left in a migrated repo's bringup (#945)" {
  # The coupling the two edits have: the orchestrator SOURCES the bringup,
  # so a surviving exec fires mid-source, the watchdog never arms, and the
  # container looks fine until the day it needed restarting.
  _write_migrated_repo 'exec "${@}"'
  run bash -c "$(_src); _migrate_bringup_residue_detect '${DF}'"
  assert_success
  run bash -c "$(_src); _migrate_bringup_residue_apply '${DF}'"
  assert_success
  assert_output --partial "exec"
}

# why: The quieter half of the same residue. Sourced twice, logging.sh
# opens a SECOND per-start file and re-tees and watchdog.sh arms a second
# supervisor -- neither of which fails a build or a start, so nothing but
# this notice would ever surface it
@test "migration (bringup-residue): notices a helper the orchestrator already sources (#945)" {
  # Sourced twice, logging.sh opens a SECOND per-start file and re-tees;
  # watchdog.sh arms a second supervisor.
  _write_migrated_repo '. /usr/local/lib/base/logging.sh'
  run bash -c "$(_src); _migrate_bringup_residue_detect '${DF}'"
  assert_success
  run bash -c "$(_src); _migrate_bringup_residue_apply '${DF}'"
  assert_success
  assert_output --partial "twice"
}

# why: The warn-only claim for the residue pair specifically. This one is
# the more tempting to auto-fix -- deleting an exec line looks safe -- and
# it is not: the line may be the repo's own workload launch
@test "migration (bringup-residue): changes nothing on disk (#945)" {
  _write_migrated_repo 'exec "${@}"'
  cp "${DF}" "${TEMP_DIR}/Dockerfile.orig"
  cp "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
  run bash -c "$(_src); _migrate_bringup_residue_apply '${DF}'"
  assert_success
  diff "${DF}" "${TEMP_DIR}/Dockerfile.orig"
  diff "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
}

# why: Pre-flip the exec is CORRECT and the helper sources are the
# documented wiring, so this notice must be gated on the OTHER migration
# having happened. Ungated it would add a second warning to every upgrade
# of every un-migrated repo, about a file doing exactly what it should
@test "migration (bringup-residue): silent while the repo still owns the ENTRYPOINT (#945)" {
  # Before the flip the exec is CORRECT and the helper sources are the
  # documented pre-migration wiring. Warning there would put a second
  # notice on every upgrade of every un-migrated repo, about a file that
  # is doing exactly what its Dockerfile asks of it.
  _write_old_model_repo
  run bash -c "$(_src); _migrate_bringup_residue_detect '${DF}'"
  assert_failure
}

# why: The steady state after both edits. This is the shape every migrated
# repo upgrades in from then on, so a false positive here is a permanent
# notice on the correct outcome
@test "migration (bringup-residue): silent for a clean bringup (#945)" {
  _write_migrated_repo 'export MY_APP_HOME=/opt/app'
  run bash -c "$(_src); _migrate_bringup_residue_detect '${DF}'"
  assert_failure
}

# why: A bringup is optional under the orchestrator, so the absent file is
# a supported shape and not an error. It is also the case a naive
# implementation turns into a stray grep diagnostic on stderr during an
# otherwise clean upgrade
@test "migration (bringup-residue): silent when the repo has no bringup at all (#945)" {
  _write_migrated_repo 'export MY_APP_HOME=/opt/app'
  rm -f "${TEMP_DIR}/script/entrypoint.sh"
  run bash -c "$(_src); _migrate_bringup_residue_detect '${DF}'"
  assert_failure
}

# why: The claim a consumer actually cares about, asserted through the real
# dispatcher rather than the detect/apply pair: `just upgrade` as a whole
# leaves a repo running the model it was running. The pair-level tests
# cannot see a SIBLING migration rewriting the same files -- the sc1090 one
# does, which is why the entrypoint is compared over its code lines and the
# three surviving lines are named individually so an emptied file cannot pass
@test "apply_migrations: an un-migrated repo keeps the entrypoint model it runs (#945)" {
  # Through the real dispatcher rather than the pair directly, because the
  # claim a consumer cares about is about `just upgrade` as a whole: the
  # repo it has been running for a year still runs the same way afterwards.
  #
  # Stated as "what the two files DO", not "the bytes", and the difference
  # is measured rather than assumed: the sc1090 migration normalises the
  # shellcheck DIRECTIVE on this same sibling file (SC1091 ->
  # SC1090,SC1091), so a byte comparison of the entrypoint is false today
  # for a reason that has nothing to do with the entrypoint model. The
  # Dockerfile is still compared byte-for-byte -- nothing in the list may
  # touch it here -- and the entrypoint is compared over its code lines,
  # which is where the model lives.
  _write_old_model_repo
  cp "${DF}" "${TEMP_DIR}/Dockerfile.orig"
  grep -vE '^[[:space:]]*#' "${TEMP_DIR}/script/entrypoint.sh" \
    > "${TEMP_DIR}/ep.code.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  assert_output --partial "orchestrator"
  diff "${DF}" "${TEMP_DIR}/Dockerfile.orig"
  grep -vE '^[[:space:]]*#' "${TEMP_DIR}/script/entrypoint.sh" \
    > "${TEMP_DIR}/ep.code.new"
  diff "${TEMP_DIR}/ep.code.new" "${TEMP_DIR}/ep.code.orig"
  # Named individually so a future rewrite that empties the file cannot
  # pass by making both sides equally empty.
  grep -Fq 'exec "${@}"' "${TEMP_DIR}/script/entrypoint.sh"
  grep -Fq '. /usr/local/lib/base/logging.sh' "${TEMP_DIR}/script/entrypoint.sh"
  grep -Fq 'export MY_APP_HOME=/opt/app' "${TEMP_DIR}/script/entrypoint.sh"
}
# ── DL3007: the series this migration WRITES is a series we still support ───
#
# The DL3007 migration replaces a consumer's floating `FROM alpine:latest`
# with a pinned series. Pinning is the point, but a literal in a sed is a
# pin nobody ever re-reads: it wrote 3.21 -- a series reaching end-of-life
# on 2026-11-01 -- into every Dockerfile it healed, which is the same silent
# expiry the test-tools image had, with a longer blast radius because the
# result lands in a downstream repo.
#
# So the migration's literal is tied to the one series this repo builds,
# tests and dates: the ALPINE_VERSION pinned in
# dockerfile/Dockerfile.test-tools, which alpine_eol_spec.bats already
# fails the suite over 180 days before its recorded expiry. One series, one
# place to bump, one expiry that is already being counted down. The
# alternative -- a second literal with its own date -- is a second thing to
# forget.
#
# Derived on both sides: neither test below names a version.

# why: The series written into a consumer's Dockerfile is the one this repo
# builds, tests and dates
@test "migration 5 (hadolint): DL3007 pins alpine to the series this repo pins (#567)" {
  local _pinned _written
  _pinned="$(sed -n 's|^ARG ALPINE_VERSION=\(.*\)$|\1|p' \
    /source/dockerfile/Dockerfile.test-tools)"
  [[ -n "${_pinned}" ]] || fail \
    "could not read ARG ALPINE_VERSION from dockerfile/Dockerfile.test-tools -- the migration's target series is derived from it, and an unreadable source must not be compared against as an empty string."

  printf 'FROM alpine:latest AS lint-tools\n' > "${DF}"
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  _written="$(sed -n 's|^FROM alpine:\([^[:space:]]*\).*|\1|p' "${DF}")"
  [[ "${_written}" == "${_pinned}" ]] || fail \
    "the DL3007 migration writes alpine:${_written} into a consumer's Dockerfile while this repo pins alpine:${_pinned}. A literal in a sed is a pin nobody re-reads: it would keep installing an end-of-life base into downstream repos long after this repo moved off it. Bump the sed in _migrate_hadolint_apply to match, and the dated expiry beside ARG ALPINE_VERSION covers both."
}

# why: Healing `:latest` is a lint fix; retagging a deliberate pin is not
@test "migration 5 (hadolint): DL3007 leaves an already-pinned alpine alone (#567)" {
  printf 'FROM alpine:3.19 AS lint-tools\n' > "${DF}"
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  # The migration heals `:latest`, it does not overwrite a deliberate pin --
  # a consumer on an older series has a reason, and silently retagging their
  # base image is not a lint fix.
  grep -Fq 'FROM alpine:3.19' "${DF}"
}

# ── DL3066: the rule the 2022 hadolint could not report ─────────────────────
#
# hadolint 2.15.1, this repo's current pin, reports DL3066 "non-numeric
# user-id may not be resolvable by host system" on a literal `USER root`.
# The rule postdates the 2.12.0 that stood here for three and a half years,
# so no consumer Dockerfile carries a pragma for it -- and every consumer
# Dockerfile has the line: it is the build-time hop the template's
# devel-test stage takes so its COPYs can write into /usr/local/bin and
# /lint.
#
# That matters because a consumer lints ITSELF -- `WORKDIR /lint` + `RUN
# hadolint Dockerfile` -- inside the very image `just base upgrade`
# re-pins. Without this migration the first `just build test` after an
# upgrade fails on a rule the consumer never chose, while base's own gate
# stays green: the "CI green, just build broken" shape v0.41.0 already
# produced once. base's own template silences DL3066 inline with its
# reason; upgrade.sh HEALS a consumer's Dockerfile and never overwrites it,
# so the silencing has to be carried there by a migration, exactly as
# DL3006's is.
#
# Only the literal `root` is silenced. DL3066's actual case -- a name the
# host may not resolve -- is real for any other literal user, and
# `USER "${USER}"`, the identity these images ship with, is left alone.

# why: hadolint binds an ignore to the next LINE, so the pragma must sit
# directly above the instruction
@test "migration 5 (hadolint): DL3066 inline ignore before a literal USER root (#946)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel-test
USER root
COPY x /y
USER "${USER}"
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}' && _migrate_hadolint_apply '${DF}'"
  assert_success
  # hadolint binds an ignore to the NEXT LINE, so "present in the file" is
  # not the assertion -- "immediately above the instruction" is.
  run grep -A1 -Fx '# hadolint ignore=DL3066' "${DF}"
  assert_success
  assert_line --index 1 'USER root'
}

# why: The real downstream shape already has `# hadolint ignore=DL3002`
# there; inserting between would re-arm it
@test "migration 5 (hadolint): DL3066 extends an existing pragma rather than displacing it (#946)" {
  cat > "${DF}" <<'EOF'
# hadolint ignore=DL3002
USER root
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  # Inserting a second pragma line BETWEEN the two would push DL3002 off its
  # instruction and silently re-arm a rule the consumer had already
  # answered. The real downstream shape (isaac's Dockerfile:38-39) is
  # exactly this one, so the merge path is the common case, not the corner.
  grep -Fxq '# hadolint ignore=DL3002,DL3066' "${DF}"
  [ "$(grep -c 'hadolint ignore=' "${DF}")" = "1" ]
}

# why: The migration pass runs on every upgrade, not once
@test "migration 5 (hadolint): DL3066 idempotent — does not double-insert (#946)" {
  cat > "${DF}" <<'EOF'
# hadolint ignore=DL3066
USER root
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  [ "$(grep -c 'hadolint ignore=DL3066' "${DF}")" = "1" ]
}

# why: The merge path needs its own proof; the insert path's says nothing
# about it
@test "migration 5 (hadolint): DL3066 idempotent when merged into a sibling pragma (#946)" {
  cat > "${DF}" <<'EOF'
# hadolint ignore=DL3002
USER root
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  grep -Fxq '# hadolint ignore=DL3002,DL3066' "${DF}"
}

# why: `root` resolves in every image by definition; any other literal name
# is the case the rule is worth having
@test "migration 5 (hadolint): DL3066 leaves every non-root USER alone (#946)" {
  cat > "${DF}" <<'EOF'
USER "${USER}"
USER someoperator
USER 1000
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  # Silencing DL3066 on a name that is NOT root would switch off the case
  # the rule is worth having, in the file the consumer actually ships.
  ! grep -q 'hadolint ignore=DL3066' "${DF}"
}

# why: Detect and apply must agree about which file is a candidate
@test "migration 5 (hadolint): DL3066 detect fires on an unguarded USER root (#946)" {
  printf 'FROM busybox\nUSER root\n' > "${DF}"
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}'"
  assert_success
}

# why: A healed file must stop reporting as needing the migration
@test "migration 5 (hadolint): DL3066 detect is quiet once the pragma is there (#946)" {
  cat > "${DF}" <<'EOF'
FROM busybox
# hadolint ignore=DL3002,DL3066
USER root
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}'"
  assert_failure
}

# ── DL3046: -u is not always the first flag ─────────────────────────────────
#
# The DL3046 heal matched `useradd` followed IMMEDIATELY by `-u`, which is
# how base's own template writes it. No downstream repo has to: the shape
# actually shipped in the org is
#   useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"
# and the anchored match walks straight past it. The migration then reports
# a patched Dockerfile while DL3046 is still live in it, so the consumer's
# self-lint fails on the first `just build test` after the upgrade -- the
# same end state the missing DL3066 heal produced, reached a different way.
#
# `-l` is inserted directly after the `useradd` token rather than before
# `-u`, so the position of the flag being answered stops mattering.

# why: The shape downstream repos actually ship; the anchored match walked
# straight past it
@test "migration 5 (hadolint): DL3046 adds -l when -u is not the first flag (#946)" {
  cat > "${DF}" <<'EOF'
RUN useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}' && _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'useradd -l -m -s /bin/bash -u "${USER_UID}"' "${DF}"
}

# why: The flag can already be anywhere in the invocation, not only where
# the migration would put it
@test "migration 5 (hadolint): DL3046 idempotent when -l already sits among the flags (#946)" {
  cat > "${DF}" <<'EOF'
RUN useradd -m -l -s /bin/bash -u "${USER_UID}" "${USER_NAME}"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  [ "$(grep -co -- '-l' "${DF}")" = "1" ]
}

# why: The conflict-handling branch beside it is a different command;
# rewriting it would corrupt it
@test "migration 5 (hadolint): DL3046 leaves usermod -l alone (#946)" {
  # The conflict-handling branch every downstream Dockerfile carries renames
  # an existing account with `usermod -l`. It is not a useradd, it already
  # has the flag, and rewriting it would corrupt the command.
  cat > "${DF}" <<'EOF'
RUN usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m "$(id -nu 1000)"
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fxq 'RUN usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m "$(id -nu 1000)"' "${DF}"
}

# why: A detect blind to the shipped shape logs a patched Dockerfile with
# the finding still live
@test "migration 5 (hadolint): DL3046 detect sees the flags-before--u shape (#946)" {
  printf 'RUN useradd -m -u "${USER_UID}" "${USER_NAME}"\n' > "${DF}"
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}'"
  assert_success
}

# why: A sibling flag after `&&` is not this command's flag; scanning to end
# of line left the finding live
@test "migration 5 (hadolint): DL3046 heals a useradd whose own line also runs usermod -l (#946)" {
  # A sibling `usermod -l` after `&&` sits in the text that follows the
  # `useradd` token, so scanning to end of line reads the useradd as
  # already carrying the flag and the heal never fires -- DL3046 left live
  # in a Dockerfile the migration reports as patched, which is the exact
  # failure the flags-before--u case above was opened for. The scan window
  # is the useradd's OWN command segment, up to the first `&&`, `||`, `;`
  # or `|`.
  cat > "${DF}" <<'EOF'
RUN useradd -m -s /bin/bash -u "${USER_UID}" "${USER_NAME}" && usermod -l "${USER_NAME}" "$(id -nu 1000)"
EOF
  run bash -c "$(_src); _dfm_needs_dl3046 '${DF}'"
  assert_success
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'; _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'useradd -l -m -s /bin/bash -u "${USER_UID}"' "${DF}"
  grep -Fq 'usermod -l "${USER_NAME}"' "${DF}"
}

# ── what the run rewrote: the record its caller stages from ─────────────────
#
# A cross-version upgrade is driven by the CONSUMER'S OWN vendored
# upgrade.sh, and the copy a consumer is sitting on stages a pair of
# filenames hardcoded when it shipped -- v0.41.0's stages the Dockerfile
# only down a branch these migrations never reach, so the file this
# dispatcher had just rewritten was left uncommitted while the same run
# told the user to push. The dispatcher is the only party that knows what
# its migrations actually rewrote, so it keeps the record and the caller
# stages what the record names. A list of filenames in the caller is what
# that replaces: it decays the first time a migration touches one more
# file, which is how the entrypoint arrived and how the next one will.

# why: The caller cannot name the files itself -- it stages what the
# record names, so the record has to name every file the run rewrote
@test "migrated_files names the Dockerfile the run rewrote (#1036)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/config /tmp/config
EOF
  run bash -c "$(_src); apply_migrations '${DF}' >/dev/null 2>&1; migrated_files"
  assert_success
  assert_output "${DF}"
}

# why: The sibling entrypoint is rewritten by migrations of its own, so a
# record that knows only about the Dockerfile leaves it behind
@test "migrated_files names the entrypoint the run rewrote (#1036)" {
  mkdir -p "${TEMP_DIR}/script"
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source /usr/local/lib/base/_entrypoint_logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}' >/dev/null 2>&1; migrated_files"
  assert_success
  assert_line "${TEMP_DIR}/script/entrypoint.sh"
}

# why: A run that rewrote nothing must hand its caller nothing to stage,
# and the record may not survive into the next run
@test "migrated_files is empty on a second, idempotent run (#1036)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/config /tmp/config
EOF
  run bash -c "$(_src); apply_migrations '${DF}' >/dev/null 2>&1; apply_migrations '${DF}' >/dev/null 2>&1; migrated_files"
  assert_success
  assert_output ""
}

# ── the record is closed by the dispatcher, not by house style ──────────────
#
# The first attempt at this guarantee was a grep over the lib: every write
# had to be `sed -i` or `mv` as the first token of its line, carrying a
# marker comment, and a spec failed the suite on anything else. That
# recognises the shapes whoever wrote the grep had in mind and passes on
# every other one -- `sed -E -i`, `sed --in-place`, a write after a `&&`,
# a `cp`, a `>` redirect -- so a migration could rewrite a file the record
# never named while the suite stayed green. Modelling shell syntax in a
# grep is the wrong instrument: the question is not how a migration wrote,
# it is whether the file changed. So the dispatcher answers it directly --
# it compares each file the migration list may write before and after the
# run -- and the tests below drive migrations that write in shapes no grep
# was written for.

# why: A migration is free to write however it likes, so the record has to
# be closed by the dispatcher rather than by every author remembering a
# house-style helper
@test "a raw in-place write no helper made is still reported (#1036)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src)
_migrate_zz_raw_detect() { return 0; }
_migrate_zz_raw_apply() { sed -E -i 's#busybox#alpine#' \"\$1\"; }
_MIGRATIONS+=(zz_raw)
apply_migrations '${DF}' >/dev/null 2>&1
migrated_files"
  assert_success
  assert_output "${DF}"
}

# why: The sibling entrypoint is written by migrations too, so a raw write
# there is the same unstaged rewrite one file over
@test "a raw write to the entrypoint is still reported (#1036)" {
  mkdir -p "${TEMP_DIR}/script"
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
echo hi
EOF
  run bash -c "$(_src)
_migrate_zz_entry_detect() { return 0; }
_migrate_zz_entry_apply() {
  printf 'rewritten\n' > \"\$(_dfm_entrypoint_path \"\$1\")\"
}
_MIGRATIONS+=(zz_entry)
apply_migrations '${DF}' >/dev/null 2>&1
migrated_files"
  assert_success
  assert_output "${TEMP_DIR}/script/entrypoint.sh"
}

# why: "The dispatcher checks the files itself" must mean their CONTENT --
# a check on mtime would report every file a migration merely opened and
# hand the caller a commit of files nothing changed
@test "a migration that opens a file without changing it reports nothing (#1036)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src)
_migrate_zz_touch_detect() { return 0; }
_migrate_zz_touch_apply() { touch \"\$1\"; }
_MIGRATIONS+=(zz_touch)
apply_migrations '${DF}' >/dev/null 2>&1
migrated_files"
  assert_success
  assert_output ""
}
