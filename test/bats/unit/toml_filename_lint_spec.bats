#!/usr/bin/env bats
#
# Lint: dist/ must not reference the retired `.setup.conf` INI filename.
#
# ADR-37 renamed the config file from `.setup.conf` (INI dotfile) to
# `setup.toml`. Any surviving `.setup.conf` string literal in dist/
# runtime code reads or names a path that no longer exists. Two files
# are excluded:
#
#   setup_tui.sh            frozen per ADR-37 (migrated separately)
#   setup_conf_migrate.sh   migration code that must read the old name
#   ini_to_toml_migrate.sh  INI-to-TOML converter (references old name)
#   gitignore.sh            keeps legacy entries so old .setup.conf.bak /
#                           .setup.conf.local files stay gitignored
#
# The test drives a real-tree scan of /source/dist/ so a reintroduced
# reference breaks CI immediately.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject_dir "/source/dist"
}

# ════════════════════════════════════════════════════════════════════
# Real-tree guard
# ════════════════════════════════════════════════════════════════════

# why: no stale `.setup.conf` in dist/ runtime code 
@test "dist/ has zero .setup.conf references outside migration + TUI + gitignore (#1136)" {
  # Grep for the retired INI dotfile name in all shell scripts under
  # dist/, excluding the four files that legitimately reference it.
  # grep -r exits 1 (no match) on a clean tree.
  local _hits
  _hits="$(grep -rn '\.setup\.conf' /source/dist/ --include='*.sh' \
    | grep -v 'setup_tui\.sh:' \
    | grep -v 'setup_conf_migrate\.sh:' \
    | grep -v 'ini_to_toml_migrate\.sh:' \
    | grep -v 'gitignore\.sh:' \
    || true)"

  if [[ -n "${_hits}" ]]; then
    echo "Stale .setup.conf references found (should be setup.toml):"
    echo "${_hits}"
    echo ""
    echo "Replace .setup.conf with setup.toml (or setup.local.toml / setup.toml.bak)."
    return 1
  fi
}
