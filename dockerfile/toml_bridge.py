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
    "args": ("arg", lambda e: _joined(e, "=", ("key", "value")) if "key" in e else ""),
    "ports": ("port", lambda e: _joined(e, ":", ("host", "container")) if "host" in e else ""),
    "cap_add": ("cap_add", lambda e: _field(e, "cap")),
    "cap_drop": ("cap_drop", lambda e: _field(e, "cap")),
    "security_opt": ("security_opt", lambda e: _field(e, "opt")),
    "volumes": ("mount", lambda e: _joined(e, ":", ("source", "target", "mode"))),
    "tmpfs": ("tmpfs", lambda e: _tmpfs_mount(e)),
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
    "additional_contexts": ("context", lambda e: _joined(e, "=", ("name", "source")) if "name" in e else ""),
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


def _tmpfs_mount(elem):
    """One `[[tmpfs]]` entry as the single string the shell view reads.

    The INI contract this family migrated from was ONE string,
    `tmpfs_N = /path[:size=N]`, and that is still what consumes it:
    `_emit_tmpfs_block` writes each entry straight into compose's
    `tmpfs:` list. The template documents the TOML entry as two fields --
    `path = "/tmp"` with `size = "64m"` under it -- and reading only
    `path` dropped the size, so an operator who followed the template got
    Docker's default limit instead of the 64 MB they asked for, with
    nothing said.

    Both spellings answer the same string, which is the property that
    matters: a converted repo carries `path = "/tmp:size=64m"` because
    the converter had one INI string to render, and the template teaches
    the two-field form.

    An ABSENT size is no suffix at all, not a bare separator -- the trap
    the one-sided array entry was fixed for (base#1234). An EMPTY one is
    treated the same: `size = ""` is not a limit, and `/tmp:size=` is not
    an option compose accepts.
    """
    path = _field(elem, "path")
    size = _field(elem, "size")
    if not path or not size:
        return path
    return f"{path}:size={size}"


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


def _joined(elem, sep, names):
    """<sep>-joined <names> of <elem>, skipping each one it does not have.

    PRESENCE, not truthiness. An entry is one string on the shell side,
    the writer splits it textually, and a half the value did not have is
    a field the writer leaves out -- so joining the fields a block HAS is
    what reads that back as what was written. Joining unconditionally
    manufactured a separator nothing wrote: `HTTP_PROXY` came back
    `HTTP_PROXY=`, which is the OTHER build argument (one inherits from
    the build environment, the other sets it empty), and a port `80` came
    back `80:`, which compose does not accept as a mapping at all.

    Truthiness is not the same test and is wrong for a three-field entry,
    because it loses POSITION as well: `/srv/data::ro` writes an empty
    `target` to hold the middle slot, and filtering it out read the mount
    back as `/srv/data:ro` -- the mode slid into the target and the host
    directory mounts at the path `ro`.

    A block whose present fields are ALL empty is an empty entry, not a
    bare separator. That is the operator's opt-out: clearing the
    workspace mount is published as emptying `mount_1` (README, v0.9
    "setup.sh does not re-populate it"), and in a `[[volumes]]` block
    that is emptying the fields in place. `_conf_list_sorted` skips an
    empty value but NOT a `":"`, so joining those blanks would turn the
    opt-out into a bogus mount of `:` -- the same trap spelled `"="` for
    `build.args`. A field-less block, which is how the converter emits a
    cleared slot, is this same case with nothing present at all. An entry
    with any content keeps every separator its positions need, so
    `HTTP_PROXY=` stays distinct from `HTTP_PROXY`.

    The one shell value this does not return unchanged is a
    SEPARATOR-ONLY one -- `=` for an arg, `:` or `::` for a port or a
    mount -- which writes all-empty fields and so reads back empty.
    Deliberate: those are exactly the bogus entries no validator accepts
    and that `_conf_list_sorted` would NOT skip if they came back whole,
    which is the reachability 82d24aba measured. Reading them as the
    nothing they are is the same answer an operator clearing the slot
    gets, and there is no third state for the one-string shell view to
    hold them in.
    """
    present = [_field(elem, n) for n in names if n in elem]
    if not any(present):
        return ""
    return sep.join(present)


def _check_transportable(section, key, value):
    """Refuse a row the tab-separated shell view cannot carry faithfully.

    THE KV STREAM IS THE INTERFACE, and it is line- and tab-delimited:
    conf.sh's `_toml_tokenize` reads each row with `IFS=$'\t' read -r
    section key value`. Three characters therefore mean something to the
    transport, and a TOML value may legally contain all three -- `"echo
    first\necho second"` is an ordinary basic string, and a quoted key or
    section name may carry a tab.

    Measured, before this guard existed:

      [lifecycle]
      watchdog_check = "echo first\necho second"

    emitted a row whose value held a real newline, so the shell read
    `watchdog_check = echo first` and then took `echo second` as a
    SECTION of its own. The watchdog ran a truncated command and no
    parse failed. A tab inside a quoted key shifted the split the same
    way: `"a\tb" = "v"` arrived as key `a` with value `b<TAB>v`.

    WHY REFUSE RATHER THAN ESCAPE. The writers already refuse a
    newline-bearing value at the other end of the same pipe
    (`conf_upsert_newline_rejected`), for the same reason and in the same
    direction, so refusing here makes the two ends agree instead of
    giving the format a second, decoded dialect that every reader of the
    stream -- including every assertion written against it -- would have
    to learn. Nothing this project writes can produce such a file: the
    shipped template has none, and both writers escape what they emit.
    So the only way to meet one is to hand-write it, and a refusal names
    it. An unreadable configuration is recoverable; a silently truncated
    watchdog command is not.

    A tab in a VALUE is NOT refused. The value is the last field, so
    `read` hands it the rest of the line intact -- measured: `"a\tb"`
    comes back as `a<TAB>b`. Refusing it would reject a file the
    transport carries correctly.

    Rows are collected before any is printed, so a refusal leaves stdout
    empty rather than a prefix of the configuration.
    """
    for _what, _text in (("section", section), ("key", key)):
        for _name, _ch in (("tab", "\t"), ("newline", "\n"),
                           ("carriage return", "\r")):
            if _ch in str(_text):
                print(f"toml-bridge: a {_what} name contains a {_name}, "
                      f"which the tab-separated shell view cannot carry: "
                      f"{_text!r}", file=sys.stderr)
                raise SystemExit(1)
    for _name, _ch in (("newline", "\n"), ("carriage return", "\r")):
        if _ch in str(value):
            print(f"toml-bridge: the value of {section}.{key} contains a "
                  f"{_name}, which the tab-separated shell view cannot "
                  f"carry: {value!r}", file=sys.stderr)
            raise SystemExit(1)


def _emit_array(section, key, items, out):
    """Collect an array of tables as numbered-key KV rows."""
    spec = _ARRAY_SPEC.get(key)
    if not spec:
        return
    prefix, serializer = spec
    for i, elem in enumerate(items, 1):
        out.append((section, f"{prefix}_{i}", serializer(elem)))


def _emit_table(section, entries, out):
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
            _emit_array(section, key, value, out)
        elif isinstance(value, dict):
            _emit_table(f"{section}.{key}", value, out)
        else:
            out.append((section, key, _format_value(value)))


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
    rows = []
    for section, entries in data.items():
        if isinstance(entries, list):
            _emit_array(section, section, entries, rows)
        elif isinstance(entries, dict):
            _emit_table(section, entries, rows)
    for section, key, value in rows:
        _check_transportable(section, key, value)
    for section, key, value in rows:
        print(f"{section}\t{key}\t{value}")


def _emit_empty_arrays(data):
    """Emit `<section>\t<path>` for every array declared with NO entries.

    An empty array is a DECLARATION that replaces the layer below with
    nothing (ADR-37's zero-entry amendment), and it is the one
    declaration the KV view cannot carry: that view emits a row per
    ENTRY, and this has none. So the shell asks for it separately rather
    than inferring it from the file's lines.

    Inferring it from the lines is what `_conf_toml_empty_array_decl`
    does for the WRITERS, which is correct there -- they rewrite lines --
    and wrong for a reader. TOML spells the same declaration several
    ways: `args = []`, `args = [` on one line and `]` on the next, and
    the inline `build = { args = [] }`. A line matcher sees the first and
    misses the rest, so a `setup.local.toml` whose only content was one
    of the others reported no local sections at all -- and
    `_setup_deploy`, whose answer is a REFUSAL, let a field bundle be
    built from gitignored configuration with nothing recording it.

    The SECTION is the path's first component, which is how every reader
    on the shell side names the table a numbered family belongs to:
    `build.args` is `[build]`'s, `devices.cgroup_rules` is `[devices]`'s,
    and a root-level `volumes` is its own.
    """
    def walk(prefix, node):
        for key, value in node.items():
            path = f"{prefix}.{key}" if prefix else key
            if isinstance(value, list):
                if not value:
                    print(f"{path.split('.')[0]}\t{path}")
            elif isinstance(value, dict):
                walk(path, value)

    walk("", data)


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
    empty_arrays_mode = "--empty-arrays" in args

    if kv_mode:
        args.remove("--kv")
    if merge_mode:
        args.remove("--merge")
    if empty_arrays_mode:
        args.remove("--empty-arrays")

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

    if empty_arrays_mode:
        _emit_empty_arrays(data)
    elif kv_mode:
        _emit_kv(data)
    else:
        json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
