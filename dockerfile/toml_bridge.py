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


def main():
    raw = sys.stdin.buffer.read()
    try:
        data = tomllib.loads(raw.decode())
    except Exception as exc:
        print(f"toml-bridge: {exc}", file=sys.stderr)
        raise SystemExit(1)
    json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
