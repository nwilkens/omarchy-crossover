#!/usr/bin/env bash
# Builds lan-mouse from a pinned tag without its GTK frontend, and produces the
# corresponding source archive GPL-3.0 requires us to offer alongside it.
set -euo pipefail

TAG="${LAN_MOUSE_VERSION:-v0.11.0}"
OUT="${OUT:-$(cd "$(dirname "$0")" && pwd)/out}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
git clone --depth 1 --branch "$TAG" https://github.com/feschber/lan-mouse.git "$WORK/lan-mouse"
cd "$WORK/lan-mouse"

# No GTK: the frontend pulls 40 MB of Homebrew dylibs we would have to bundle
# and re-sign. The daemon and its IPC socket are all Crossover drives.
cargo build --release --locked --no-default-features
cp target/release/lan-mouse "$OUT/lan-mouse"

# Corresponding Source: the tree plus every crate compiled into that binary.
cargo vendor "$WORK/lan-mouse/vendor" >/dev/null
tar -czf "$OUT/lan-mouse-$TAG-source.tar.gz" \
  --exclude target -C "$WORK" lan-mouse

echo "binary: $OUT/lan-mouse"
echo "source: $OUT/lan-mouse-$TAG-source.tar.gz"
