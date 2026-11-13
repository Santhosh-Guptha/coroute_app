#!/usr/bin/env bash
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_inventory.sh"
need VM2_PRIVATE_IP VM_SSH_PRIVATE_KEY_FILE
echo "=========================================================="
echo "         COROUTE INFRASTRUCTURE SECURITY AUDIT           "
echo "=========================================================="

echo -e "\n--- [NODE 1: coroute-server] ---"

echo "[1.1] Open Listening Ports:"
sudo ss -tulpn | grep LISTEN

echo -e "\n[1.2] SSH Security (Password Auth & Root Login):"
sudo grep -E -i '^(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || echo "Standard sshd defaults"

echo -e "\n[1.3] /etc/coroute/gateway.env Permissions & Ownership:"
ls -la /etc/coroute/gateway.env

echo -e "\n[1.4] Firewall (iptables INPUT rules):"
sudo iptables -L INPUT -n -v --line-numbers

echo -e "\n[1.5] UFW Status:"
sudo ufw status || true

echo -e "\n=========================================================="
echo "--- [NODE 2: coroute-relay-2] ---"

ssh -i "$VM_SSH_PRIVATE_KEY_FILE" -o StrictHostKeyChecking=accept-new "${REMOTE_USER:-ubuntu}@$VM2_PRIVATE_IP" '
  echo "[2.1] Open Listening Ports:"
  sudo ss -tulpn | grep LISTEN

  echo -e "\n[2.2] SSH Security (Password Auth & Root Login):"
  sudo grep -E -i "^(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || echo "Standard sshd defaults"

  echo -e "\n[2.3] /etc/coroute/gateway.env Permissions & Ownership:"
  ls -la /etc/coroute/gateway.env

  echo -e "\n[2.4] Firewall (iptables INPUT rules):"
  sudo iptables -L INPUT -n -v --line-numbers

  echo -e "\n[2.5] UFW Status:"
  sudo ufw status || true
'
