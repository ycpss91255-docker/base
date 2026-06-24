# base self-development entry (just). base maintainers run `just test`
# (bare = run the whole self-test; `just test lint / coverage / ...` for
# sub-actions) and `just release <recipe>` (release / publish tooling).
# Bare `just` lists the namespaces.
#
# This is base's OWN entry, distinct from the consumer-facing entry shipped
# at downstream/script/justfile (which downstream repos symlink as their
# root justfile via init.sh). base is consumed as a `.base/` subtree, so
# this file lands at `.base/justfile` in a consumer and is never invoked
# there (the consumer's own root justfile is the auto-discovered one).
#
# ADR-00000010/00000011: layered just entry, action-named namespaces
# (ci -> test, cd -> release). base's own tooling is namespaced here.

mod? test 'script/test/justfile.test'
mod? release 'script/release/justfile.release'

# Default: list available recipes / namespaces.
default:
    @just --list
