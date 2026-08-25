#!/usr/bin/env bash
# init.sh - compatibility forwarder to dist/script/base/init.sh
#
# THIS IS NOT THE IMPLEMENTATION. The implementation is
# dist/script/base/init.sh; this file exists only so that callers which
# have ALREADY SHIPPED can still find it.
#
# base is consumed as a `.base/` subtree, so this file lands at
# `<repo>/.base/init.sh`. Two callers name exactly that path and neither
# can be fixed retroactively:
#
#   - every released upgrade.sh up to v0.41.0, which runs
#     `"./${TEMPLATE_REL}/init.sh"` from the repo root as its post-pull
#     resync step. It is the CONSUMER'S vendored copy that drives an
#     upgrade, so the path it names is frozen in every downstream tree
#     that exists today.
#   - the template repo's bootstrap.sh, which names the same path when it
#     scaffolds a new repo.
#
# The dist/ reorganisation moved init.sh to dist/script/base/ and left
# nothing here, which broke both: the upgrade died AFTER the subtree pull
# had committed, leaving a repo whose .version claimed the new release
# while its justfile and every script/*.sh wrapper dangled.
#
# So the forwarder is deliberately the most boring thing that can work --
# resolve the sibling path, exec, done. It holds no logic of its own and
# therefore cannot drift from the implementation, and it re-exposes ONE
# name rather than the flat layout dist/ replaced. Removing it means
# knowingly stranding every consumer still on a release that names it.
#
# See doc/adr/00000006-upgrade-sh-path-contract.md.

set -euo pipefail

main() {
  local _here
  _here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  exec "${_here}/dist/script/base/init.sh" "$@"
}

main "$@"
