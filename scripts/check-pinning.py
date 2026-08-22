#!/usr/bin/env python3
"""Keep every documented install path bound to the current release tag.

manifest.json holds the version. Everything else derives from it: the tag in
each raw.githubusercontent URL, the release download URLs, the marker in each
script, and Panel.qml's releaseTag. Run with --write on release day to update
them all; CI runs it with no arguments and fails on a mismatch.

Grepping for literal strings was not enough, because Panel.qml assembles its
URL from a variable, so a marker left on an old version still read as pinned.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SELF = pathlib.Path(__file__).resolve()
SUFFIXES = {".md", ".sh", ".qml"}
SKIP_DIRS = {".git", "docs", ".github", "target"}
# Release notes legitimately name older versions.
SKIP_FILES = {"CHANGELOG.md"}

REPO = "omarchy-crossover"
TAG_IN_URL = re.compile(rf"{REPO}/(?:releases/download/)?(v\d+\.\d+\.\d+)")
RAW_PATH = re.compile(rf"raw\.githubusercontent\.com/[^/]+/{REPO}/v\d+\.\d+\.\d+/(\S+?)(?=[\s\\`\)]|$)")

MARKERS = [
    ("Panel.qml", re.compile(r'(releaseTag:\s*")([^"]+)(")')),
    ("scripts/install-macos.sh", re.compile(r'(CROSSOVER_VERSION=")([^"]+)(")')),
    ("scripts/open-firewall.sh", re.compile(r'(CROSSOVER_VERSION=")([^"]+)(")')),
]
# Cargo.toml carries the bare version, and it is what `--version` prints.
CARGO = ("clipd/Cargo.toml", re.compile(r'(?m)^(version\s*=\s*")([^"]+)(")'))
# Cargo.lock records the package's own version too, and `cargo build --locked`
# refuses to run when the two disagree.
CARGO_LOCK = (
    "clipd/Cargo.lock",
    re.compile(r'(?ms)(\[\[package\]\]\nname = "crossover-clipd"\nversion = ")([^"]+)(")'),
)


def tracked_files():
    for path in sorted(ROOT.rglob("*")):
        if path.suffix not in SUFFIXES or path.resolve() == SELF:
            continue
        rel = path.relative_to(ROOT)
        if SKIP_DIRS & set(rel.parts) or rel.name in SKIP_FILES:
            continue
        yield path, rel


def main() -> int:
    write = "--write" in sys.argv[1:]
    version = json.loads((ROOT / "manifest.json").read_text())["version"]
    tag = f"v{version}"
    problems = []
    changed = []

    for path, rel in tracked_files():
        text = path.read_text(errors="replace")

        for n, line in enumerate(text.splitlines(), 1):
            if f"{REPO}/main/" in line or "releases/latest" in line:
                problems.append(f"{rel}:{n}: mutable reference: {line.strip()}")

        # A documented raw URL must point at a file that exists in this tree,
        # which catches a 404 install link offline, before anyone runs it.
        for target in RAW_PATH.findall(text):
            if not (ROOT / target).is_file():
                problems.append(f"{rel}: documented URL points at missing file: {target}")

        if write:
            new = TAG_IN_URL.sub(lambda m: m.group(0).replace(m.group(1), tag), text)
            if new != text:
                path.write_text(new)
                changed.append(str(rel))
                text = new

        for found in TAG_IN_URL.findall(text):
            if found != tag:
                problems.append(f"{rel}: pinned to {found}, expected {tag}")

    for name, pattern in MARKERS + [CARGO, CARGO_LOCK]:
        path = ROOT / name
        if not path.is_file():
            problems.append(f"{name}: file is missing")
            continue
        want = version if ("Cargo.toml" in name or "Cargo.lock" in name) else tag
        text = path.read_text()
        match = pattern.search(text)
        if not match:
            problems.append(f"{name}: no version marker found")
            continue
        if match.group(2) == want:
            continue
        if write:
            path.write_text(pattern.sub(lambda m: m.group(1) + want + m.group(3), text, count=1))
            changed.append(name)
        else:
            problems.append(f"{name}: version marker {match.group(2)}, expected {want}")

    if changed:
        print("updated: " + ", ".join(sorted(set(changed))))
    if problems:
        print("\n".join(problems))
        return 1
    print(f"all documented install paths pinned to {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
