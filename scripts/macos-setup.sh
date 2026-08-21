#!/usr/bin/env bash
# Sets up the Mac half of Crossover: lan-mouse for input, crossover-clipd for
# the clipboard, and a LaunchAgent so both come back after a reboot.
set -euo pipefail

PEER_HOST="${1:-}"
if [[ -z $PEER_HOST ]]; then
  echo "usage: $0 <omarchy-host-or-ip>" >&2
  exit 1
fi

LABEL_CLIP="com.nwilkens.crossover.clipd"
AGENTS="$HOME/Library/LaunchAgents"
CLIPD="$HOME/.cargo/bin/crossover-clipd"

command -v cargo >/dev/null || { echo "cargo is required: https://rustup.rs" >&2; exit 1; }

if ! command -v lan-mouse >/dev/null; then
  echo "==> installing lan-mouse"
  # default features pull in the GTK frontend, which does not build on macOS
  cargo install lan-mouse --no-default-features
fi

if [[ ! -x $CLIPD ]]; then
  echo "==> installing crossover-clipd"
  cargo install --path "$(dirname "$0")/../clipd"
fi

echo "==> pairing clipboard with $PEER_HOST"
"$CLIPD" add-peer "$PEER_HOST" >/dev/null
echo
echo "This Mac's clipboard fingerprint:"
"$CLIPD" fingerprint
echo
echo "Run this on the Omarchy machine, then paste its fingerprint back here:"
echo "    crossover-clipd pair <the fingerprint above>"
echo "    crossover-clipd fingerprint"
echo
read -r -p "Omarchy clipboard fingerprint: " REMOTE_FP
"$CLIPD" pair "$REMOTE_FP"

mkdir -p "$AGENTS"
cat > "$AGENTS/$LABEL_CLIP.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_CLIP</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CLIPD</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/crossover-clipd.log</string>
</dict>
</plist>
PLIST

launchctl unload "$AGENTS/$LABEL_CLIP.plist" 2>/dev/null || true
launchctl load "$AGENTS/$LABEL_CLIP.plist"

cat <<'DONE'

==> Clipboard agent installed.

Two things still need a human:

1. Grant lan-mouse Accessibility and Input Monitoring permission.
   System Settings > Privacy & Security > Accessibility, and again under
   Input Monitoring. macOS will not let it read your mouse otherwise.

2. Start lan-mouse and add the Omarchy machine as a client on the side of
   the screen it physically sits on:

     lan-mouse

   Then approve the fingerprint on both ends.
DONE
