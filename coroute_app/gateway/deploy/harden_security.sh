#!/usr/bin/env bash
set -euo pipefail

echo "[*] Hardening Node 1 (152.67.181.198)..."

# 1. Disable PasswordAuthentication on Node 1
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/50-password-auth.conf
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
echo "  ✓ SSH password authentication disabled (Key-only login enforced)"

# 2. Disable rpcbind on Node 1
systemctl disable --now rpcbind rpcbind.socket 2>/dev/null || true
echo "  ✓ rpcbind disabled"

# 3. Harden Node 2 over private network
echo "[*] Hardening Node 2 (10.0.0.99 / 129.225.79.93)..."
ssh -i /home/ubuntu/.ssh/vm_provision_ssh.key -o StrictHostKeyChecking=no ubuntu@10.0.0.99 '
  sudo bash -c "
    systemctl disable --now rpcbind rpcbind.socket 2>/dev/null || true
    echo PasswordAuthentication no > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

    # Update Caddyfile with full security headers
    cat > /etc/caddy/Caddyfile << \"CADDYEOF\"
:80 {
    encode zstd gzip
    header {
        Strict-Transport-Security \"max-age=31536000; includeSubDomains\"
        X-Content-Type-Options \"nosniff\"
        X-Frame-Options \"DENY\"
        Referrer-Policy \"no-referrer\"
        -Server
    }
    reverse_proxy 127.0.0.1:3000 {
        flush_interval -1
        transport http {
            read_timeout 0
            write_timeout 0
        }
    }
}
CADDYEOF
    systemctl reload caddy
    echo \"  ✓ Caddy security headers applied & reloaded\"

    # Clean up iptables rule for 3000 (Node is bound to 127.0.0.1)
    iptables -D INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
    netfilter-persistent save >/dev/null 2>&1 || true
    echo \"  ✓ iptables tightened\"
  "
'

echo "=========================================================="
echo "          SECURITY HARDENING COMPLETED SUCCESSFULLY        "
echo "=========================================================="
