#!/usr/bin/env bash
# Sets up the Mac half of Crossover end to end: Lan Mouse for input, the
# clipboard helper, and the pairing between them. Needs no Rust toolchain.
#
# Safe to run piped:
#   curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/main/scripts/install-macos.sh \
#     | bash -s -- 10.0.5.1
#   ...add --ssh you@10.0.5.1 to pair both machines automatically.
set -euo pipefail

LAN_MOUSE_VERSION="v0.11.0"
CLIPD_REPO="nwilkens/omarchy-crossover"
APP="/Applications/Lan Mouse.app"
CLIPD="$HOME/.local/bin/crossover-clipd"
AGENTS="$HOME/Library/LaunchAgents"
LABEL_CLIP="com.nwilkens.crossover.clipd"

PEER_HOST="${1:-}"
SSH_TARGET=""
POSITION="left"

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh) SSH_TARGET="${2:-}"; shift 2 ;;
    --position) POSITION="${2:-left}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z $PEER_HOST ]]; then
  cat >&2 <<USAGE
usage: $0 <omarchy-host-or-ip> [--ssh user@host] [--position left|right|top|bottom]

  <omarchy-host-or-ip>  where the Omarchy machine is on your network
  --ssh                 pair both machines automatically over ssh
  --position            which side the Omarchy machine sits on, seen from this
                        Mac (default: left)
USAGE
  exit 1
fi

case "$POSITION" in
  left|right|top|bottom) ;;
  *) echo "position must be left, right, top, or bottom" >&2; exit 1 ;;
esac

say() { printf '\n==> %s\n' "$1"; }

# ---------------------------------------------------------------- Lan Mouse
if [[ -d $APP ]]; then
  say "Lan Mouse is already installed"
else
  case "$(uname -m)" in
    arm64) ASSET="lan-mouse-macos-arm64.zip" ;;
    x86_64) ASSET="lan-mouse-macos-intel.zip" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  say "Downloading Lan Mouse $LAN_MOUSE_VERSION"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/lan-mouse.zip" \
    "https://github.com/feschber/lan-mouse/releases/download/$LAN_MOUSE_VERSION/$ASSET"
  unzip -q "$TMP/lan-mouse.zip" -d "$TMP"
  cp -R "$TMP/Lan Mouse.app" /Applications/
  # The upstream build is ad-hoc signed, so Gatekeeper refuses it until the
  # download flag is cleared. Doing it here avoids a dead end that looks like
  # a corrupted app.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
fi

LAN_MOUSE_BIN="$APP/Contents/MacOS/lan-mouse"

# ------------------------------------------------------------ clipboard helper
if [[ -x $CLIPD ]]; then
  say "Clipboard helper is already installed"
else
  say "Installing the clipboard helper"
  mkdir -p "$(dirname "$CLIPD")"
  case "$(uname -m)" in
    arm64) CLIPD_ASSET="crossover-clipd-aarch64-macos" ;;
    *) CLIPD_ASSET="crossover-clipd-x86_64-macos" ;;
  esac
  URL="https://github.com/$CLIPD_REPO/releases/latest/download/$CLIPD_ASSET"
  if curl -fsSL -o "$CLIPD" "$URL"; then
    chmod +x "$CLIPD"
    xattr -dr com.apple.quarantine "$CLIPD" 2>/dev/null || true
  elif command -v cargo >/dev/null; then
    # Piped through bash there is no script directory to build from, so the
    # source is fetched rather than assumed to be next to us.
    echo "No release build available, compiling from source."
    SRC=$(mktemp -d)
    git clone --depth 1 "https://github.com/$CLIPD_REPO.git" "$SRC/repo"
    cargo install --path "$SRC/repo/clipd" --root "$HOME/.local"
    rm -rf "$SRC"
  else
    echo "Could not download $URL and cargo is not installed." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------------- config
say "Pointing Lan Mouse at $PEER_HOST (on the $POSITION)"
mkdir -p "$HOME/.config/lan-mouse"
CONFIG="$HOME/.config/lan-mouse/config.toml"
if [[ -f $CONFIG ]] && ! grep -q "written by crossover" "$CONFIG"; then
  cp "$CONFIG" "$CONFIG.bak-crossover"
  echo "Kept your previous config at $CONFIG.bak-crossover"
fi
cat > "$CONFIG" <<CONF
# written by crossover
port = 4242

[[clients]]
position = "$POSITION"
ips = ["$PEER_HOST"]
activate_on_startup = true
CONF

# ---------------------------------------------------------------- launchagent
say "Installing the clipboard agent"
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

# ------------------------------------------------------------------- pairing
"$CLIPD" add-peer "$PEER_HOST" >/dev/null
MAC_FP=$("$CLIPD" fingerprint)

if [[ -n $SSH_TARGET ]]; then
  say "Pairing the clipboard over ssh"

  # The helper may sit in PATH or in either of the two places our installers
  # use, so the remote side reports back whichever it actually has.
  FIND_REMOTE='c=$(command -v crossover-clipd 2>/dev/null || true);
    for f in "$HOME/.local/bin/crossover-clipd" "$HOME/.cargo/bin/crossover-clipd"; do
      [ -n "$c" ] && break
      [ -x "$f" ] && c="$f"
    done
    [ -n "$c" ] && printf %s "$c"'
  REMOTE_BIN=$(ssh "$SSH_TARGET" "$FIND_REMOTE" 2>/dev/null | tr -d '\r')

  if [[ -z $REMOTE_BIN ]]; then
    echo "crossover-clipd is not installed on $SSH_TARGET yet." >&2
    echo "Install it there, then re-run with --ssh." >&2
    exit 1
  fi

  REMOTE_FP=$(ssh "$SSH_TARGET" "'$REMOTE_BIN' fingerprint" | tr -d '\r')
  if [[ -z $REMOTE_FP ]]; then
    echo "Could not read the fingerprint from $SSH_TARGET." >&2
    exit 1
  fi

  MAC_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  ssh "$SSH_TARGET" "'$REMOTE_BIN' pair '$MAC_FP'" >/dev/null
  if [[ -n $MAC_IP ]]; then
    ssh "$SSH_TARGET" "'$REMOTE_BIN' add-peer '$MAC_IP'" >/dev/null
  else
    echo "Could not determine this Mac's IP; add it on the Omarchy side with:"
    echo "  crossover-clipd add-peer <this-mac-ip>"
  fi
  "$CLIPD" pair "$REMOTE_FP" >/dev/null
  echo "Paired both directions."
else
  cat <<MANUAL

This Mac's clipboard fingerprint:

  $MAC_FP

Run on the Omarchy machine:

  crossover-clipd pair $MAC_FP
  crossover-clipd add-peer <this-mac-ip>
  crossover-clipd fingerprint

then pair that fingerprint back here:

  $CLIPD pair <omarchy-fingerprint>
MANUAL
fi

launchctl unload "$AGENTS/$LABEL_CLIP.plist" 2>/dev/null || true
launchctl load "$AGENTS/$LABEL_CLIP.plist"

# ------------------------------------------------------------------ handover
say "Opening Lan Mouse"
open -a "$APP" || true

cat <<'DONE'

One thing left, and only you can do it.

macOS will not let anything read your mouse and keyboard until you say so.
Lan Mouse should be asking now; if it is not:

  System Settings > Privacy & Security > Accessibility     -> enable Lan Mouse
  System Settings > Privacy & Security > Input Monitoring   -> enable Lan Mouse

Then, in the Lan Mouse window, approve the Omarchy machine's fingerprint when
it appears, and approve this Mac's fingerprint in the Crossover panel on the
Omarchy side. Push your cursor off that edge and it should land on Omarchy.

To start Lan Mouse at login: System Settings > General > Login Items > add
Lan Mouse.
DONE
