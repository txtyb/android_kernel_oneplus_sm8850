#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Append/refresh .config fragment lines in a defconfig file, idempotently.

Why this exists: on this device the image that actually boots is the GKI kernel
from //common:kernel_aarch64, which is built from arch/arm64/configs/gki_defconfig.
The Qualcomm/CLO defconfig dict (configs/canoe_perf.bzl) only drives the vendor
DDK modules and the device trees -- it never reaches that kernel binary. So a
kernel option like CONFIG_TMPFS_XATTR has to be set in gki_defconfig itself.

gki_defconfig is a *defconfig*: Kbuild applies it via `make <name>_defconfig`, so
a plain line in the file has exactly the same effect as a fragment merged after
it, without touching kleaf's target definitions.

Usage: patch-defconfig.py <defconfig> <fragment.config> [--dry-run]
Exit:  0 changed, 2 nothing to do, 1 error.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys

ASSIGN_RE = re.compile(r'^(?P<key>CONFIG_[A-Za-z0-9_]+)=')
UNSET_RE = re.compile(r'^#\s*(?P<key>CONFIG_[A-Za-z0-9_]+) is not set\s*$')


def parse_fragment(path: str) -> "dict[str, str]":
    """Return {symbol: rendered line} for every option in the fragment."""
    out: "dict[str, str]" = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if ASSIGN_RE.match(line):
                out[line.split("=", 1)[0]] = line
                continue
            m = UNSET_RE.match(line)
            if m:
                out[m.group("key")] = "# %s is not set" % m.group("key")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("defconfig")
    ap.add_argument("fragment")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    wanted = parse_fragment(args.fragment)
    if not wanted:
        print("patch-defconfig: %s has no CONFIG_ lines" % args.fragment, file=sys.stderr)
        return 1

    raw = open(args.defconfig, encoding="utf-8", newline="").read()
    crlf = raw.count("\r\n") > raw.count("\n") - raw.count("\r\n")
    text = raw.replace("\r\n", "\n")
    lines = text.split("\n")

    changed = []
    for key, rendered in wanted.items():
        found = False
        for i, line in enumerate(lines):
            m = ASSIGN_RE.match(line) or UNSET_RE.match(line)
            if m and m.group("key") == key:
                found = True
                if line.strip() != rendered:
                    changed.append("%s: %r -> %r" % (key, line.strip(), rendered))
                    lines[i] = rendered
                break
        if not found:
            if lines and lines[-1] == "":
                lines.insert(len(lines) - 1, rendered)
            else:
                lines.append(rendered)
            changed.append("%s: (new)" % key)

    if not changed:
        print("patch-defconfig: %s already has %s" % (args.defconfig, ", ".join(sorted(wanted))))
        return 2

    updated = "\n".join(lines)
    if args.dry_run:
        sys.stdout.writelines(difflib.unified_diff(
            text.splitlines(keepends=True), updated.splitlines(keepends=True),
            fromfile=args.defconfig, tofile=args.defconfig + " (patched)"))
        for c in changed:
            print(c, file=sys.stderr)
        return 0

    if crlf:
        updated = updated.replace("\n", "\r\n")
    with open(args.defconfig, "w", encoding="utf-8", newline="") as fh:
        fh.write(updated)

    for c in changed:
        print("patch-defconfig: " + c)
    print("patch-defconfig: wrote %s" % args.defconfig)
    return 0


if __name__ == "__main__":
    sys.exit(main())
