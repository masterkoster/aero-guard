#!/usr/bin/env python3
"""Report the Jac share of AERO-GUARD's source.

JacHacks requires >=40% Jac.  This counts non-blank, non-comment lines across
every tracked source file, split by language, so the number in the README and
the number on Devpost come from the same place instead of being retyped.

    python3 scripts/jac_ratio.py            # summary
    python3 scripts/jac_ratio.py --verbose # per-file breakdown
"""

import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Directories that hold build output, not source.
SKIP_DIRS = {".git", ".jac", ".venv", "venv", "node_modules", "__pycache__",
             ".idea", ".vscode", "data", "web"}

JAC_EXT = {".jac"}
PY_EXT = {".py"}
WEB_EXT = {".html", ".css", ".js"}


def tracked_files() -> list[str]:
    """Ask git, so untracked scratch files never inflate the ratio."""
    try:
        out = subprocess.run(
            ["git", "-C", ROOT, "ls-files"],
            capture_output=True, text=True, check=True,
        ).stdout
        return [f for f in out.splitlines() if f]
    except subprocess.CalledProcessError:
        # No git (fresh zip): walk the tree instead.
        found = []
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                rel = os.path.relpath(os.path.join(dirpath, name), ROOT)
                found.append(rel)
        return found


def count_lines(path: str) -> tuple[int, int]:
    """Return (total_lines, code_lines) for one file.

    Blank lines and comment-only lines are excluded: a Jac file padded with
    docstrings should not read as more implementation than it is.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.readlines()
    except OSError:
        return (0, 0)

    total = 0
    code = 0
    in_block = False
    for line in raw:
        total += 1
        stripped = line.strip()

        if in_block:
            if "*/" in stripped:
                in_block = False
            continue
        if not stripped:
            continue
        if stripped.startswith("/*"):
            if "*/" not in stripped:
                in_block = True
            continue
        if stripped.startswith("//") or stripped.startswith("#!"):
            continue
        # Trailing comment on a code line still counts as code.
        code += 1
    return (total, code)


def classify(rel: str) -> str | None:
    ext = os.path.splitext(rel)[1].lower()
    if ext in JAC_EXT:
        return "jac"
    if ext in PY_EXT:
        return "python"
    if ext in WEB_EXT:
        return "web"
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    buckets: dict[str, list[tuple[str, int, int]]] = {
        "jac": [], "python": [], "web": [],
    }
    for rel in tracked_files():
        kind = classify(rel)
        if kind is None:
            continue
        total, code = count_lines(os.path.join(ROOT, rel))
        if code:
            buckets[kind].append((rel, total, code))

    print(f"{'file':<44} {'lines':>7} {'code':>7}")
    print("-" * 60)
    totals = {}
    for kind in ("jac", "python", "web"):
        subtotal = 0
        for rel, total, code in sorted(buckets[kind]):
            if args.verbose or kind == "jac":
                print(f"{rel:<44} {total:>7} {code:>7}")
            subtotal += code
        totals[kind] = subtotal

    counted = sum(totals.values())
    print("-" * 60)
    for kind in ("jac", "python", "web"):
        if totals[kind]:
            print(f"{kind + ' total':<44} {'':>7} {totals[kind]:>7}")
    print(f"{'all source':<44} {'':>7} {counted:>7}")

    if not counted:
        print("no source files found")
        return 1

    pct = 100.0 * totals["jac"] / counted
    print()
    print(f"Jac share: {pct:.1f}%  (JacHacks floor 40%)")
    if pct >= 40.0:
        print("PASS")
        return 0
    print(f"SHORT BY {40.0 - pct:.1f} points -- port logic from .py to .jac")
    return 1


if __name__ == "__main__":
    sys.exit(main())
