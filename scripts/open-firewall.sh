#!/usr/bin/env bash
# Opens the ports Crossover needs, scoped to one subnet rather than to the
# world. Omarchy ships ufw enabled, and a blocked port looks exactly like a
# peer that is simply not answering, so this is worth doing up front.
set -euo pipefail

CROSSOVER_VERSION="v0.3.0"
SELF_URL="https://raw.githubusercontent.com/nwilkens/omarchy-crossover/$CROSSOVER_VERSION/scripts/open-firewall.sh"

# Strict parsing on purpose: this script edits a firewall. A mistyped
# "-remove" that silently fell through to the open path would re-expose the
# ports of someone who was trying to close them.
SUBNET=""
REMOVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) REMOVE=1; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -n $SUBNET ]]; then
        echo "unexpected extra argument: $1" >&2
        exit 1
      fi
      SUBNET="$1"; shift ;;
  esac
done

if [[ -z $SUBNET ]]; then
  cat >&2 <<USAGE
usage: open-firewall.sh <subnet> [--remove]
   or: curl -fsSL $SELF_URL | bash -s -- <subnet>

  open-firewall.sh 192.168.1.0/24            # open the ports
  open-firewall.sh 192.168.1.0/24 --remove   # take the rules back out

Find yours with: ip -4 -o addr show | awk '{print $2, $4}'
USAGE
  exit 1
fi

if ! [[ $SUBNET =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]{1,2}$ ]]; then
  echo "not a CIDR subnet: $SUBNET" >&2
  exit 1
fi

open_ufw() {
  sudo ufw allow from "$SUBNET" to any port 4242 proto udp comment "lan-mouse input"
  sudo ufw allow from "$SUBNET" to any port 4242 proto tcp comment "lan-mouse input"
  sudo ufw allow from "$SUBNET" to any port 4243 proto tcp comment "crossover clipboard"
  sudo ufw status | grep -E "4242|4243" || true
}

close_ufw() {
  sudo ufw delete allow from "$SUBNET" to any port 4242 proto udp || true
  sudo ufw delete allow from "$SUBNET" to any port 4242 proto tcp || true
  sudo ufw delete allow from "$SUBNET" to any port 4243 proto tcp || true
  sudo ufw status | grep -E "4242|4243" || echo "No Crossover rules remain."
}

firewalld_rules() {
  local action="$1"
  for rule in \
    "port port=4242 protocol=udp accept" \
    "port port=4242 protocol=tcp accept" \
    "port port=4243 protocol=tcp accept"; do
    sudo firewall-cmd --permanent "--$action-rich-rule=rule family=ipv4 source address=$SUBNET $rule" || true
  done
  sudo firewall-cmd --reload
}

if systemctl is-active --quiet ufw; then
  echo "==> ufw"
  if [[ $REMOVE -eq 1 ]]; then close_ufw; else open_ufw; fi
elif systemctl is-active --quiet firewalld; then
  echo "==> firewalld"
  if [[ $REMOVE -eq 1 ]]; then firewalld_rules remove; else firewalld_rules add; fi
else
  echo "No active ufw or firewalld found. Nothing to change."
fi
