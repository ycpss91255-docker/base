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


_ARRAY_SPEC = {
    "rules": ("rule", lambda e: e.get("rule", "")),
    "args": ("arg", lambda e: "%s=%s" % (e["key"], e["value"]) if "key" in e else ""),
    "ports": ("port", lambda e: "%s:%s" % (e["host"], e["container"]) if "host" in e else ""),
    "cap_add": ("cap_add", lambda e: e.get("name", "")),
    "security_opt": ("security_opt", lambda e: e.get("name", "")),
    "volumes": ("mount", lambda e: ":".join(v for v in [e.get("source", ""), e.get("target", ""), e.get("mode", "")] if v)),
    "tmpfs": ("tmpfs", lambda e: e.get("path", "")),
    "devices": ("device", lambda e: e.get("path", "")),
    "additional_contexts": ("context", lambda e: "%s=%s" % (e["name"], e["source"]) if "name" in e else ""),
}


def _format_value(v):
    """Format a scalar TOML value for KV output."""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def _emit_array(section, key, items):
    """Emit array of tables as numbered-key KV lines."""
    spec = _ARRAY_SPEC.get(key)
    if not spec:
        return
    prefix, serializer = spec
    for i, elem in enumerate(items, 1):
        print(f"{section}\t{prefix}_{i}\t{serializer(elem)}")


def _emit_kv(data):
    """Emit section/key/value tab-separated lines for bash consumption.

    An array of tables goes through _emit_array, which numbers it
    (`rule_1`, `arg_2`, `device_1`) -- the `<prefix><digits>` shape
    `_conf_list_sorted` matches and every ordered-list reader on the shell
    side requires. Emitting one line per element key instead loses the
    order, and emitting the Python list loses the list.

    Both nestings are arrays: `[[devices]]` arrives as a list at the
    section, `[[build.args]]` as a list under a key of one.
    """
    for section, entries in data.items():
        if isinstance(entries, list):
            _emit_array(section, section, entries)
        elif isinstance(entries, dict):
            for key, value in entries.items():
                if isinstance(value, list):
                    _emit_array(section, key, value)
                else:
                    print(f"{section}\t{key}\t{value}")


def _merge_toml(paths):
    """Merge multiple TOML files with type-aware semantics.

    Files are read in increasing-precedence order (baseline first, the
    most local override last).

    Tables (dict): key-level merge -- the upper layer overrides only the
    keys it defines; unmentioned keys inherit from the lower layer.

    Arrays of tables (list): replace -- the entire array from the highest
    layer that defines it wins.

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
                merged[section].update(entries)
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
