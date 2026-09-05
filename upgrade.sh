#!/usr/bin/env bash
# upgrade.sh - compatibility forwarder to dist/script/base/upgrade.sh
#
# THIS IS NOT THE IMPLEMENTATION. The implementation is
# dist/script/base/upgrade.sh; this file exists only so that callers which
# have ALREADY SHIPPED can still find it.
#
# base is consumed as a `.base/` subtree, so this file lands at
# `<repo>/.base/upgrade.sh`. Nothing in base EXECS that path -- which is
# what makes it different from the init.sh forwarder beside it, and what
# let it go missing unnoticed. The callers are the ones no code change can
# reach:
#
#   - the PERSON at the terminal. Every release up to v0.41.0 documented
#     `./.base/upgrade.sh [VERSION]` as the upgrade command, in its README
#     and in the usage text upgrade.sh itself prints. That copy is vendored
#     in the consumer's repo and still says so today.
#   - this repo's own `enforce_wrapper_first_upgrade.sh` hook, which names
#     `.base/upgrade.sh` as the raw form it intercepts and redirects to
#     `just upgrade`.
#   - any downstream doc, runbook or CI step written against a release in
#     that window.
#
# The `dist/` reorganisation moved upgrade.sh to dist/script/base/ and left
# nothing here, so an upgrade REMOVED THE COMMAND THAT PERFORMED IT: the
# first `./.base/upgrade.sh vX.Y.Z` succeeded, and the second exited 127
# with "No such file or directory" against a repo that was otherwise fine.
# The failure is one release late, which is why no run of the upgrade ever
# reported it.
#
# So the forwarder is deliberately the most boring thing that can work --
# resolve the sibling path, exec, done. It holds no logic of its own and
# therefore cannot drift from the implementation. Removing it means
# knowingly stranding every consumer still on a release that names it; the
# guard is behavioural, in
# test/bats/integration/prev_release_upgrade_spec.bats, which upgrades
# twice and re-runs the command the first upgrade was driven by.
#
# See doc/adr/00000006-upgrade-sh-path-contract.md.

set -euo pipefail

main() {
  local _here
  _here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  exec "${_here}/dist/script/base/upgrade.sh" "$@"
}

main "$@"
