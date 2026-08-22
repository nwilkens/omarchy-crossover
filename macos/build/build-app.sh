#!/usr/bin/env bash
# Assembles Crossover.app: the Swift menu bar app, our clipboard daemon, and
# lan-mouse wrapped in a nested helper bundle so macOS has a name for it in
# Privacy & Security.
#
#   ./macos/build/build-app.sh                      # ad-hoc signed, for local use
#   CODESIGN_IDENTITY="Developer ID Application: …" ./macos/build/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/macos/build/out}"
APP="$OUT/Crossover.app"
HELPER="$APP/Contents/Helpers/Crossover Input.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/manifest.json'))['version'])")"
LAN_MOUSE_VERSION="${LAN_MOUSE_VERSION:-v0.11.0}"

say() { printf '\n==> %s\n' "$1"; }

: "${LAN_MOUSE_BIN:?set LAN_MOUSE_BIN to a lan-mouse binary built with --no-default-features (see build-lan-mouse.sh)}"
[ -x "$LAN_MOUSE_BIN" ] || { echo "not executable: $LAN_MOUSE_BIN" >&2; exit 1; }

say "Building the app"
swift build --package-path "$ROOT/macos" -c release
APP_BIN="$(swift build --package-path "$ROOT/macos" -c release --show-bin-path)/Crossover"

say "Building crossover-clipd"
cargo build --manifest-path "$ROOT/clipd/Cargo.toml" --release --locked
CLIPD_BIN="$ROOT/clipd/target/release/crossover-clipd"

say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS"

sed "s/__VERSION__/$VERSION/g" "$ROOT/macos/Resources/Info.plist" > "$APP/Contents/Info.plist"
sed "s/__LAN_MOUSE_VERSION__/${LAN_MOUSE_VERSION#v}/g" "$ROOT/macos/Resources/Helper-Info.plist" \
  > "$HELPER/Contents/Info.plist"

cp "$APP_BIN" "$APP/Contents/MacOS/Crossover"
cp "$CLIPD_BIN" "$APP/Contents/MacOS/crossover-clipd"
cp "$LAN_MOUSE_BIN" "$HELPER/Contents/MacOS/lan-mouse"
chmod +x "$APP/Contents/MacOS/"* "$HELPER/Contents/MacOS/lan-mouse"

# GPL-3.0 obliges us to ship the licence with the binary we convey, and to
# point at the corresponding source. build-lan-mouse.sh produces the tarball.
cp "$ROOT/macos/Resources/GPL-3.0.txt" "$APP/Contents/Resources/" 2>/dev/null || \
  curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o "$APP/Contents/Resources/GPL-3.0.txt"
cat > "$APP/Contents/Resources/LAN-MOUSE-SOURCE.txt" <<EOF
Crossover Input is lan-mouse $LAN_MOUSE_VERSION, unmodified, by Ferdinand Schober.
It is licensed GPL-3.0-or-later and runs as a separate process.

Source:  https://github.com/feschber/lan-mouse/tree/$LAN_MOUSE_VERSION
Built:   cargo build --release --locked --no-default-features
The corresponding source, including vendored dependencies, is attached to the
Crossover release that shipped this build.
EOF

say "Signing (identity: $IDENTITY)"
# Inside out: nested code first, container last, or the outer signature is
# invalidated by the time you get to it.
codesign --force --options runtime --timestamp=none \
  --identifier com.nwilkens.crossover.input \
  --sign "$IDENTITY" "$HELPER/Contents/MacOS/lan-mouse"
codesign --force --options runtime --timestamp=none \
  --identifier com.nwilkens.crossover.input \
  --sign "$IDENTITY" "$HELPER"
codesign --force --options runtime --timestamp=none \
  --identifier com.nwilkens.crossover.clipd \
  --sign "$IDENTITY" "$APP/Contents/MacOS/crossover-clipd"
codesign --force --options runtime --timestamp=none \
  --identifier com.nwilkens.crossover \
  --sign "$IDENTITY" "$APP"

say "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
echo
echo "Built $APP"
du -sh "$APP" | cut -f1 | sed 's/^/size: /'
