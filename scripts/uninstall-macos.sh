#!/usr/bin/env bash
# Removes everything scripts/install-macos.sh put on this Mac: the LaunchAgent,
# the app, the helper binary, and the configuration it wrote.
#
#   ./uninstall-macos.sh          # asks before each group
#   ./uninstall-macos.sh --yes    # no prompts, for piping through curl
set -euo pipefail

APP="/Applications/Lan Mouse.app"
AGENTS="$HOME/Library/LaunchAgents"
LABEL_CLIP="com.nwilkens.crossover.clipd"
# Not created by the current installer, which runs Lan Mouse as a normal app.
# Still unloaded here so machines set up by an earlier version come clean.
LABEL_MOUSE="com.nwilkens.crossover.lan-mouse"
CONFIG_LM="$HOME/.config/lan-mouse/config.toml"
CONFIG_XO="$HOME/.config/crossover"

ASSUME_YES=0
KEEP_APP=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --keep-lan-mouse) KEEP_APP=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Piped through curl, stdin is the script itself, so prompts have to come from
# the terminal directly or not at all.
confirm() {
  local prompt="$1"
  [[ $ASSUME_YES -eq 1 ]] && return 0
  if [[ -r /dev/tty ]]; then
    local reply
    read -r -p "$prompt [y/N] " reply < /dev/tty
    [[ $reply == [yY]* ]]
  else
    echo "Not a terminal and --yes was not given; skipping: $prompt" >&2
    return 1
  fi
}

say() { printf '\n==> %s\n' "$1"; }

say "Stopping agents and processes"
for label in "$LABEL_CLIP" "$LABEL_MOUSE"; do
  launchctl unload "$AGENTS/$label.plist" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist"
done
pkill -x crossover-clipd 2>/dev/null || true
pkill -x lan-mouse 2>/dev/null || true
echo "LaunchAgents removed."

say "Removing the clipboard helper"
for bin in "$HOME/.local/bin/crossover-clipd" "$HOME/.cargo/bin/crossover-clipd"; do
  [[ -e $bin ]] && rm -f "$bin" && echo "removed $bin"
  # A download that failed verification leaves this behind.
  [[ -e "$bin.part" ]] && rm -f "$bin.part" && echo "removed $bin.part"
done

if [[ $KEEP_APP -eq 0 && -d $APP ]]; then
  if confirm "Remove $APP?"; then
    rm -rf "$APP"
    echo "removed $APP"
  fi
fi

# The identity is what the other machine has paired with. Removing it means
# re-pairing later, so it is never deleted silently.
if [[ -d $CONFIG_XO ]]; then
  if confirm "Remove $CONFIG_XO (identity and paired fingerprints)?"; then
    rm -rf "$CONFIG_XO"
    echo "removed $CONFIG_XO"
  else
    echo "kept $CONFIG_XO"
  fi
fi

# Only reclaim the lan-mouse config if this project wrote it.
if [[ -f $CONFIG_LM ]] && grep -q "written by crossover" "$CONFIG_LM"; then
  if [[ -f "$CONFIG_LM.bak-crossover" ]]; then
    mv "$CONFIG_LM.bak-crossover" "$CONFIG_LM"
    echo "restored your previous lan-mouse config"
  elif confirm "Remove $CONFIG_LM (written by this installer)?"; then
    rm -f "$CONFIG_LM"
    echo "removed $CONFIG_LM"
  fi
else
  echo "Left $CONFIG_LM alone; it was not written by this installer."
fi

rm -f "$HOME/Library/Logs/crossover-clipd.log" "$HOME/Library/Logs/lan-mouse.log"

cat <<'DONE'

Done. Two things this script cannot do for you:

  - macOS keeps the Accessibility and Input Monitoring entries after an app is
    deleted. Remove "Lan Mouse" by hand under
    System Settings > Privacy & Security.
  - If you added Lan Mouse to Login Items, remove it under
    System Settings > General > Login Items.

On the Omarchy side, see "Removing it" in the README.
DONE
