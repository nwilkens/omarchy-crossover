#!/usr/bin/env python3
"""Fail if any documented install path is not bound to the current release tag.

Grepping for literal strings was not enough: URLs are also assembled by
concatenation (Panel.qml builds one from `releaseTag`), so a marker left on an
old version would still read as "pinned". This checks that every version marker
and every pinned URL agrees with manifest.json.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SELF = pathlib.Path(__file__).resolve()
SUFFIXES = {".md", ".sh", ".qml"}
# Workflow files reference git refs for CI, not for users installing anything.
SKIP_DIRS = {".git", "docs", ".github", "target"}

MARKERS = [
    ("Panel.qml", r'releaseTag:\s*"([^"]+)"'),
    ("scripts/install-macos.sh", r'CROSSOVER_VERSION="([^"]+)"'),
    ("scripts/open-firewall.sh", r'CROSSOVER_VERSION="([^"]+)"'),
]


def main() -> int:
    tag = "v" + json.loads((ROOT / "manifest.json").read_text())["version"]
    problems = []

    for path in ROOT.rglob("*"):
        if path.suffix not in SUFFIXES or path.resolve() == SELF:
            continue
        if SKIP_DIRS & set(path.relative_to(ROOT).parts):
            continue
        rel = path.relative_to(ROOT)
        for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if "omarchy-crossover/main/" in line or "releases/latest" in line:
                problems.append(f"{rel}:{n}: mutable reference: {line.strip()}")
            for found in re.findall(
                r"omarchy-crossover/(?:releases/download/)?(v\d+\.\d+\.\d+)", line
            ):
                if found != tag:
                    problems.append(f"{rel}:{n}: pinned to {found}, expected {tag}")

    for name, pattern in MARKERS:
        match = re.search(pattern, (ROOT / name).read_text())
        if not match:
            problems.append(f"{name}: no version marker found")
        elif match.group(1) != tag:
            problems.append(f"{name}: version marker {match.group(1)}, expected {tag}")

    if problems:
        print("\n".join(problems))
        return 1
    print(f"all documented install paths pinned to {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
