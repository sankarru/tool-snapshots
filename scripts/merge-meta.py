#!/usr/bin/env python3
"""Merge native-image tracing-agent output directories into one config dir.

The agent writes a complete set of JSON files per JVM run and will not write
into a directory that already holds a trace, so a multi-invocation trace (the
D8/R8 flag matrix) has to be unioned before native-image reads it. Entries
are deduplicated by value, never by name: reflect-config legitimately holds
several entries per class (different conditions, different queried methods)
and dropping all but one would lose reachability.

Usage: merge-meta.py OUT_DIR SRC_DIR [SRC_DIR ...]
"""
import json
import os
import sys

LIST_FILES = (
    "reflect-config.json",
    "jni-config.json",
    "proxy-config.json",
    "serialization-config.json",
    "resource-config.json",
    "preinitialize-classes-config.json",
)


def merge(out_dir, name, src_dirs):
    merged, seen = [], set()
    for src in src_dirs:
        path = os.path.join(src, name)
        if not os.path.exists(path):
            continue
        with open(path) as f:
            try:
                entries = json.load(f)
            except ValueError as e:
                print(f"  ! {path}: unparsable ({e}), skipped")
                continue
        for entry in entries:
            key = json.dumps(entry, sort_keys=True)
            if key not in seen:
                seen.add(key)
                merged.append(entry)
    if not merged:
        return 0
    with open(os.path.join(out_dir, name), "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")
    return len(merged)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    out_dir, src_dirs = sys.argv[1], sys.argv[2:]
    src_dirs = [d for d in src_dirs if os.path.abspath(d) != os.path.abspath(out_dir)]
    missing = [d for d in src_dirs if not os.path.isdir(d)]
    if not src_dirs or missing:
        for d in missing:
            print(f"  ! {d}: not a directory", file=sys.stderr)
        print(__doc__, file=sys.stderr)
        return 2
    os.makedirs(out_dir, exist_ok=True)
    for name in LIST_FILES:
        n = merge(out_dir, name, src_dirs)
        if n:
            print(f"  {name}: {n} entries")
    # Anything else the agent produced (future config kinds) is carried over
    # as-is; the first directory that has it wins.
    for src in src_dirs:
        for name in sorted(os.listdir(src)):
            if name in LIST_FILES:
                continue
            dst = os.path.join(out_dir, name)
            if not os.path.exists(dst):
                with open(os.path.join(src, name), "rb") as a, open(dst, "wb") as b:
                    b.write(a.read())
                print(f"  {name}: copied from {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main())