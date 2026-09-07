#!/usr/bin/env python3
"""TOML to JSON bridge for the base container toolchain.

Reads TOML from stdin, writes JSON to stdout. Uses tomllib (stdlib 3.11+)
with vendored tomli as fallback (Python 3.6+). ADR-37 sec. Containerised
parsing.
"""
import json
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib


def _emit_kv(data):
    """Emit section/key/value tab-separated lines for bash consumption."""
    for section, entries in data.items():
        if not isinstance(entries, dict):
            continue
        for key, value in entries.items():
            print(f"{section}\t{key}\t{value}")


def main():
    kv_mode = "--kv" in sys.argv
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
