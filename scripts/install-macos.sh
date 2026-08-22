#!/usr/bin/env bash
# Sets up the Mac half of Crossover: Lan Mouse for input, the clipboard helper,
# and the pairing between them. Needs no Rust toolchain.
#
# Every download is pinned to an immutable tag and checked against a SHA-256
# published at that same tag, so what this installs is exactly what was
# reviewed. Nothing here follows a moving branch or a "latest" release.
#
# Safe to run piped:
#   curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/v0.4.0/scripts/install-macos.sh \
#     | bash -s -- 10.0.5.1
#   ...add --ssh you@10.0.5.1 to pair both machines automatically.
#
# Undo everything with scripts/uninstall-macos.sh, documented in the README.
set -euo pipefail

CROSSOVER_VERSION="v0.4.0"
LAN_MOUSE_VERSION="v0.11.0"
REPO="nwilkens/omarchy-crossover"
SELF_URL="https://raw.githubusercontent.com/$REPO/$CROSSOVER_VERSION/scripts/install-macos.sh"

# Pinned upstream artifacts. Recorded here so a tampered or swapped release
# fails loudly instead of installing.
LAN_MOUSE_SHA_ARM64="5ff9965d05be7f125b1d75b9e7259d874ec98aa086ce40012522bc25406500a9"
LAN_MOUSE_SHA_INTEL="d24c38ccf50061ab710826003c19d10e1243415ffa18f421d4498b2b858c8b64"

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
  # Not $0: piped through bash that reads "usage: bash", which helps nobody.
  cat >&2 <<USAGE
usage: install-macos.sh <omarchy-host-or-ip> [--ssh user@host] [--position left|right|top|bottom]
   or: curl -fsSL $SELF_URL | bash -s -- <omarchy-host-or-ip> [--ssh user@host]

  <omarchy-host-or-ip>  where the Omarchy machine is on your network
  --ssh                 pair both machines automatically over ssh
  --position            which side the Omarchy machine sits on, seen from this
                        Mac (default: left)

Removal: scripts/uninstall-macos.sh, or see the README's "Removing it".
USAGE
  exit 1
fi

if [[ -n $SSH_TARGET && $SSH_TARGET == -* ]]; then
  # ssh would read a leading-dash value as an option, and options like
  # -oProxyCommand=... execute locally.
  echo "--ssh target must not begin with '-': $SSH_TARGET" >&2
  exit 1
fi

case "$POSITION" in
  left|right|top|bottom) ;;
  *) echo "position must be left, right, top, or bottom" >&2; exit 1 ;;
esac

say() { printf '\n==> %s\n' "$1"; }

verify_sha256() {
  local file="$1" expected="$2" actual
  actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
  if [[ $actual != "$expected" ]]; then
    echo "checksum mismatch for $file" >&2
    echo "  expected $expected" >&2
    echo "  got      $actual" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- Lan Mouse
if [[ -d $APP ]]; then
  say "Lan Mouse is already installed"
else
  case "$(uname -m)" in
    arm64) ASSET="lan-mouse-macos-arm64.zip"; ASSET_SHA="$LAN_MOUSE_SHA_ARM64" ;;
    x86_64) ASSET="lan-mouse-macos-intel.zip"; ASSET_SHA="$LAN_MOUSE_SHA_INTEL" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  say "Downloading Lan Mouse $LAN_MOUSE_VERSION"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/lan-mouse.zip" \
    "https://github.com/feschber/lan-mouse/releases/download/$LAN_MOUSE_VERSION/$ASSET"
  verify_sha256 "$TMP/lan-mouse.zip" "$ASSET_SHA"
  unzip -q "$TMP/lan-mouse.zip" -d "$TMP"
  cp -R "$TMP/Lan Mouse.app" /Applications/
  # The upstream build is ad-hoc signed, so Gatekeeper refuses it until the
  # download flag is cleared. Doing it here avoids a dead end that looks like
  # a corrupted app.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
fi

# ------------------------------------------------------------ clipboard helper
# Compare versions rather than testing for the file: an -x test made every
# re-run a silent no-op, which is exactly how a Mac ends up running an old
# helper against a freshly updated plugin.
HAVE_CLIPD=""
[[ -x $CLIPD ]] && HAVE_CLIPD=$("$CLIPD" --version 2>/dev/null | awk 'NR==1{print $NF}' || true)
if [[ -n $HAVE_CLIPD && $HAVE_CLIPD == "${CROSSOVER_VERSION#v}" ]]; then
  say "Clipboard helper is already at $HAVE_CLIPD"
else
  say "Installing the clipboard helper $CROSSOVER_VERSION${HAVE_CLIPD:+ (replacing $HAVE_CLIPD)}"
  mkdir -p "$(dirname "$CLIPD")"
  case "$(uname -m)" in
    arm64) CLIPD_ASSET="crossover-clipd-aarch64-macos" ;;
    *) CLIPD_ASSET="crossover-clipd-x86_64-macos" ;;
  esac
  BASE="https://github.com/$REPO/releases/download/$CROSSOVER_VERSION"

  rm -f "$CLIPD.part"
  if curl -fsSL -o "$CLIPD.part" "$BASE/$CLIPD_ASSET"; then
    # The checksums live at the same immutable tag as the binary.
    SUMS=$(curl -fsSL "$BASE/SHA256SUMS")
    EXPECTED=$(printf '%s\n' "$SUMS" | awk -v a="$CLIPD_ASSET" '$2 == a || $2 == "*"a {print $1}')
    if [[ -z $EXPECTED ]]; then
      rm -f "$CLIPD.part"
      echo "no checksum published for $CLIPD_ASSET at $CROSSOVER_VERSION" >&2
      exit 1
    fi
    verify_sha256 "$CLIPD.part" "$EXPECTED"
    mv "$CLIPD.part" "$CLIPD"
    chmod +x "$CLIPD"
    xattr -dr com.apple.quarantine "$CLIPD" 2>/dev/null || true
  elif command -v cargo >/dev/null; then
    # Piped through bash there is no script directory to build from, so the
    # source is fetched at the same pinned tag rather than a moving branch.
    rm -f "$CLIPD.part"
    echo "No release build available, compiling from source."
    SRC=$(mktemp -d)
    git clone --depth 1 --branch "$CROSSOVER_VERSION" "https://github.com/$REPO.git" "$SRC/repo"
    cargo install --path "$SRC/repo/clipd" --root "$HOME/.local" --locked
    rm -rf "$SRC"
  else
    rm -f "$CLIPD.part"
    echo "Could not download $BASE/$CLIPD_ASSET and cargo is not installed." >&2
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
  # shellcheck disable=SC2016  # deliberate: this expands on the remote host
  FIND_REMOTE='c=$(command -v crossover-clipd 2>/dev/null || true);
    for f in "$HOME/.local/bin/crossover-clipd" "$HOME/.cargo/bin/crossover-clipd"; do
      [ -n "$c" ] && break
      [ -x "$f" ] && c="$f"
    done
    [ -n "$c" ] && printf %s "$c"'
  REMOTE_BIN=$(ssh -- "$SSH_TARGET" "$FIND_REMOTE" 2>/dev/null | tr -d '\r')

  if [[ -z $REMOTE_BIN ]]; then
    echo "crossover-clipd is not installed on $SSH_TARGET yet." >&2
    echo "Install it there, then re-run with --ssh." >&2
    exit 1
  fi

  REMOTE_FP=$(ssh -- "$SSH_TARGET" "'$REMOTE_BIN' fingerprint" | tr -d '\r')
  if [[ -z $REMOTE_FP ]]; then
    echo "Could not read the fingerprint from $SSH_TARGET." >&2
    exit 1
  fi

  MAC_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  ssh -- "$SSH_TARGET" "'$REMOTE_BIN' pair '$MAC_FP'" >/dev/null
  if [[ -n $MAC_IP ]]; then
    ssh -- "$SSH_TARGET" "'$REMOTE_BIN' add-peer '$MAC_IP'" >/dev/null
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

cat <<DONE

Installed:
  $APP
  $CLIPD
  $AGENTS/$LABEL_CLIP.plist
  ~/.config/lan-mouse/config.toml
  ~/.config/crossover/  (identity and paired fingerprints)

To remove all of it later:
  curl -fsSL https://raw.githubusercontent.com/$REPO/$CROSSOVER_VERSION/scripts/uninstall-macos.sh | bash

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
