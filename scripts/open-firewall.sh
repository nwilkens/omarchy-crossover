#!/usr/bin/env bash
# Opens the ports Crossover needs, scoped to one subnet rather than to the
# world. Omarchy ships ufw enabled, and a blocked port looks exactly like a
# peer that is simply not answering, so this is worth doing up front.
set -euo pipefail

SUBNET="${1:-}"
if [[ -z $SUBNET ]]; then
  cat >&2 <<USAGE
usage: $0 <subnet>

  $0 192.168.1.0/24

Find yours with: ip -4 -o addr show | awk '{print \$2, \$4}'
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
  sudo ufw status | grep -E "4242|4243"
}

open_firewalld() {
  for rule in \
    "port port=4242 protocol=udp accept" \
    "port port=4242 protocol=tcp accept" \
    "port port=4243 protocol=tcp accept"; do
    sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$SUBNET $rule"
  done
  sudo firewall-cmd --reload
}

if systemctl is-active --quiet ufw; then
  echo "==> ufw"
  open_ufw
elif systemctl is-active --quiet firewalld; then
  echo "==> firewalld"
  open_firewalld
else
  echo "No active ufw or firewalld found. Nothing to open."
fi
