#!/usr/bin/env python3
"""TOML to JSON bridge for the base container toolchain.

Reads TOML from stdin, writes JSON to stdout. Uses tomllib (stdlib 3.11+)
with vendored tomli as fallback (Python 3.6+). ADR-37 sec. Containerised
parsing.

--merge mode: reads multiple TOML files by path (not stdin), merges with
type-aware semantics (table key-level merge, array-of-tables replace),
outputs merged result.  ADR-37 sec. Merge semantics.
"""
import json
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib


# Every field read here goes through _field, never `e.get` / `e[...]`
# directly. The shell view of an array entry is one string -- the halves
# are glued back with `:` or `=` -- so a field is string-typed whatever
# the file spelled it as, and a file is free to spell one as a number or
# a boolean: the shipped template's own port example writes
# `host = 8080`, and a numeric named volume (`123:/data`) reads back as
# an int. Handing that int to `":".join` raised TypeError, which does not
# degrade one key -- it aborts `--kv` mid-stream and the entire
# configuration stops loading. `%s` survived but rendered a boolean as
# Python's `True`, which every `== true` on the shell side reads as
# false. _field answers _format_value's spelling in both cases.
_ARRAY_SPEC = {
    "rules": ("rule", lambda e: _field(e, "rule")),
    "args": ("arg", lambda e: "%s=%s" % (_field(e, "key"), _field(e, "value")) if "key" in e else ""),
    "ports": ("port", lambda e: "%s:%s" % (_field(e, "host"), _field(e, "container")) if "host" in e else ""),
    "cap_add": ("cap_add", lambda e: _field(e, "cap")),
    "security_opt": ("security_opt", lambda e: _field(e, "opt")),
    "volumes": ("mount", lambda e: ":".join(v for v in [_field(e, "source"), _field(e, "target"), _field(e, "mode")] if v)),
    "tmpfs": ("tmpfs", lambda e: _field(e, "path")),
    # `devices` is a namespace of two independently replaceable lists,
    # not one list: host bindings under `[[devices.bindings]]` and cgroup
    # rules under `[[devices.cgroup_rules]]`. Both number into the
    # `devices` section on the shell side, under the `device_N` /
    # `cgroup_rule_N` names every ordered-list reader there matches.
    # The bare `devices` key stays readable for a repo whose file still
    # carries the one-array `[[devices]]` spelling; the two cannot
    # collide, because TOML will not let one name be an array and a table
    # in the same document.
    "devices": ("device", lambda e: _field(e, "path")),
    "bindings": ("device", lambda e: _field(e, "path")),
    "cgroup_rules": ("cgroup_rule", lambda e: _field(e, "rule")),
    "additional_contexts": ("context", lambda e: "%s=%s" % (_field(e, "name"), _field(e, "source")) if "name" in e else ""),
}


# Deprecated key spellings kept working behind a permanent alias (the W3
# strategy doc/deprecations.md states). Each entry names the tables it
# applies to and the (canonical, legacy) pair inside them. A name ending
# in ":" matches any table whose name starts with it, which is how the
# per-stage `[stage:<name>]` family is spelled; anything else is exact.
#
# Removing a deprecation at the next major version means deleting its
# entry here as well as the reader-side fallback branch -- the removal
# checklist in doc/deprecations.md names both.
_LEGACY_ALIASES = (
    ("deploy", "gpu_runtime", "runtime"),
    ("stage:", "deploy.gpu_runtime", "deploy.runtime"),
)


def _aliases_for(table):
    """Yield the (canonical, legacy) pairs that apply inside <table>."""
    for name, canonical, legacy in _LEGACY_ALIASES:
        if name.endswith(":"):
            if table.startswith(name):
                yield canonical, legacy
        elif table == name:
            yield canonical, legacy


def _format_value(v):
    """Format a scalar TOML value for KV output."""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def _field(elem, name):
    """One array-of-tables field of <elem> as the string the shell reads.

    The single reader for every _ARRAY_SPEC field, so no serializer can
    bypass _format_value -- which is what one of them did, and the cost
    is in the _ARRAY_SPEC comment above. An absent field is the empty
    string, the same answer `e.get(name, "")` gave.
    """
    if name not in elem:
        return ""
    return _format_value(elem[name])


def _emit_array(section, key, items):
    """Emit array of tables as numbered-key KV lines."""
    spec = _ARRAY_SPEC.get(key)
    if not spec:
        return
    prefix, serializer = spec
    for i, elem in enumerate(items, 1):
        print(f"{section}\t{prefix}_{i}\t{serializer(elem)}")


def _emit_table(section, entries):
    """Emit one table's keys under <section>, recursing into a sub-table.

    The shell view has no nesting: a section is one flat name, and the
    name a nested table is known by there is the dotted path
    (`[logging.web]` -> section `logging.web`), which is exactly what
    conf.sh's _conf_toml_header writes and _load_setup_conf reads back.
    Printing the dict instead hands the shell a Python repr as the value
    of a key named after the sub-table: the section never exists, and the
    parent gains a key no reader can use.

    An array value goes through _emit_array whatever the depth, so
    `[[build.args]]` numbers under `build` and a nested one would number
    under its own dotted section.
    """
    for key, value in entries.items():
        if isinstance(value, list):
            _emit_array(section, key, value)
        elif isinstance(value, dict):
            _emit_table(f"{section}.{key}", value)
        else:
            print(f"{section}\t{key}\t{_format_value(value)}")


def _emit_kv(data):
    """Emit section/key/value tab-separated lines for bash consumption.

    An array of tables goes through _emit_array, which numbers it
    (`rule_1`, `arg_2`, `device_1`) -- the `<prefix><digits>` shape
    `_conf_list_sorted` matches and every ordered-list reader on the shell
    side requires. Emitting one line per element key instead loses the
    order, and emitting the Python list loses the list.

    Both nestings are arrays: `[[devices]]` arrives as a list at the
    section, `[[build.args]]` as a list under a key of one.

    A scalar goes through _format_value, which is what keeps a TOML
    boolean spelled the way the shell compares it -- `true`, not Python's
    `True`, which every `== true` on the other side reads as false.

    A table goes through _emit_table, which flattens a nested one into
    its own dotted section.
    """
    for section, entries in data.items():
        if isinstance(entries, list):
            _emit_array(section, section, entries)
        elif isinstance(entries, dict):
            _emit_table(section, entries)


def _merge_tables(base, layer):
    """Merge <layer> into <base> in place: key-level, recursive, arrays atomic.

    A key whose value is a table on BOTH sides recurses, because
    ADR-37's table rule is unqualified and a nested table is a table:
    `[logging.web]` merges key by key across layers exactly as
    `[logging]` does. A shallow update instead replaces the sub-table,
    so a setup.local.toml naming one key of `[logging.web]` dropped
    every other key the repo set for that service.

    Everything else is assignment, which is what keeps an ARRAY atomic
    at every depth: the list from the highest layer that defines it
    wins whole, never element by element. An array has no key to merge
    on, and index-merging one would offer no way to remove an entry.
    """
    for key, value in layer.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _merge_tables(base[key], value)
        else:
            base[key] = value


def _merge_toml(paths):
    """Merge multiple TOML files with type-aware semantics.

    Files are read in increasing-precedence order (baseline first, the
    most local override last).

    Tables (dict): key-level merge, at every depth -- the upper layer
    overrides only the keys it defines; unmentioned keys inherit from the
    lower layer, and a nested table merges the same way rather than being
    replaced wholesale.

    Arrays of tables (list): replace -- the entire array from the highest
    layer that defines it wins.

    Deprecated aliases (_LEGACY_ALIASES): a layer supplying only the
    legacy spelling of a pair un-inherits the canonical one, so absence
    of the canonical key is decided per layer rather than on the merged
    result.  doc/deprecations.md sec. Precedence across layers.

    A path that does not exist contributes nothing rather than failing:
    callers pass the whole layer chain unconditionally, which is the rule
    conf.sh's _conf_load_layers documents on the other side.

    ADR-37 sec. Merge semantics.
    """
    merged = {}
    for path in paths:
        try:
            with open(path, "rb") as fh:
                layer = tomllib.loads(fh.read().decode())
        except FileNotFoundError:
            continue
        except Exception as exc:
            print(f"toml-bridge: {path}: {exc}", file=sys.stderr)
            raise SystemExit(1)
        for section, entries in layer.items():
            if isinstance(entries, dict):
                # Table: key-level merge.
                if section not in merged or not isinstance(merged[section], dict):
                    merged[section] = {}
                # A deprecated alias is resolved per LAYER, never on the
                # merged result. A layer that supplies ONLY the legacy
                # spelling drops the canonical value it would otherwise
                # have inherited, so the highest layer that spells the
                # setting out is the layer that decides it. Without this
                # the template's canonical default (`gpu_runtime = "auto"`,
                # which it always ships) masks the legacy key a consumer
                # wrote one layer up: the published "canonical absent ->
                # consume the legacy value" branch could never fire, and
                # `runtime = "runc"` resolved silently to `auto`.
                # A canonical key the layer supplies ITSELF is kept --
                # canonical wins over legacy within one layer.
                # doc/deprecations.md sec. Precedence across layers.
                for canonical, legacy in _aliases_for(section):
                    if legacy in entries and canonical not in entries:
                        merged[section].pop(canonical, None)
                _merge_tables(merged[section], entries)
            else:
                # Array of tables, or a top-level scalar: replace.
                merged[section] = entries
    return merged


def main():
    # The flags are REMOVED from the argument list rather than filtered by
    # a leading dash, so a file path is never mistaken for a flag and a
    # flag is never mistaken for a file.
    args = list(sys.argv[1:])
    kv_mode = "--kv" in args
    merge_mode = "--merge" in args

    if kv_mode:
        args.remove("--kv")
    if merge_mode:
        args.remove("--merge")

    if merge_mode:
        if not args:
            print("toml-bridge: --merge requires at least one file",
                  file=sys.stderr)
            raise SystemExit(1)
        data = _merge_toml(args)
    else:
        raw = sys.stdin.buffer.read()
        try:
            data = tomllib.loads(raw.decode())
        except Exception as exc:
            print(f"toml-bridge: {exc}", file=sys.stderr)
            raise SystemExit(1)

    if kv_mode:
        _emit_kv(data)
    else:
        json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
