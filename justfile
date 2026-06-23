# base self-development entry (just). base maintainers run `just ci
# <recipe>` (self-test: test / lint / coverage / ...) and `just cd
# <recipe>` (release / publish tooling). Bare `just` lists the namespaces.
#
# This is base's OWN entry, distinct from the consumer-facing entry shipped
# at downstream/script/justfile (which downstream repos symlink as their
# root justfile via init.sh). base is consumed as a `.base/` subtree, so
# this file lands at `.base/justfile` in a consumer and is never invoked
# there (the consumer's own root justfile is the auto-discovered one).
#
# ADR-00000010: layered just entry. docker recipes are top-level only in
# the consumer entry; base's own tooling (ci / cd) is namespaced here.

mod? ci 'script/ci/justfile.ci'
mod? cd 'script/cd/justfile.cd'

# Default: list available recipes / namespaces.
default:
    @just --list
