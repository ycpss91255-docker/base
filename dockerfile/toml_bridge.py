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

    Tables (dict values) emit one line per key.  Arrays of tables (list
    values) emit one line per key of each element dict, preserving the
    element order -- the same shape a reopened INI section produces.
    """
    for section, entries in data.items():
        if isinstance(entries, dict):
            for key, value in entries.items():
                print(f"{section}\t{key}\t{value}")
        elif isinstance(entries, list):
            for item in entries:
                if isinstance(item, dict):
                    for key, value in item.items():
                        print(f"{section}\t{key}\t{value}")


def _merge_toml(files):
    """Merge multiple TOML files with type-aware semantics.

    Files are read in increasing-precedence order (baseline first, the
    most local override last).

    Tables (dict): key-level merge -- the upper layer overrides only the
    keys it defines; unmentioned keys inherit from the lower layer.

    Arrays of tables (list): replace -- the entire array from the highest
    layer that defines it wins.

    ADR-37 sec. Merge semantics.
    """
    merged = {}
    for path in files:
        with open(path, "rb") as f:
            data = tomllib.load(f)
        for key, value in data.items():
            if isinstance(value, list):
                # Array of tables: replace entirely.
                merged[key] = value
            elif isinstance(value, dict):
                # Table: key-level merge.
                if key not in merged or not isinstance(merged[key], dict):
                    merged[key] = {}
                merged[key].update(value)
            else:
                # Top-level scalar: override.
                merged[key] = value
        if isinstance(entries, list):
            _emit_array(section, section, entries)
        elif isinstance(entries, dict):
            for key, value in entries.items():
                if isinstance(value, list):
                    _emit_array(section, key, value)
                else:
                    print(f"{section}\t{key}\t{_format_value(value)}")


def _merge_layers(paths):
    """Type-aware merge of TOML layers (lowest precedence first).

    Tables: key-level merge (upper overrides only keys it defines).
    Arrays: replace (upper replaces entire array).
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
                if section not in merged or not isinstance(merged[section], dict):
                    merged[section] = {}
                merged[section].update(entries)
            else:
                merged[section] = entries
    return merged


def main():
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
        try:
            data = _merge_toml(args)
        except Exception as exc:
            print(f"toml-bridge: {exc}", file=sys.stderr)
            raise SystemExit(1)
    argv = [a for a in sys.argv[1:] if not a.startswith("-")]
    kv_mode = "--kv" in sys.argv
    merge_mode = "--merge" in sys.argv

    if merge_mode:
        data = _merge_layers(argv)
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
