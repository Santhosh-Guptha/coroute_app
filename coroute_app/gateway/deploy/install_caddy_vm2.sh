#!/usr/bin/env bash
set -euo pipefail

echo "[*] Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -qq
apt-get install -y -qq caddy >/dev/null

cat > /etc/caddy/Caddyfile << 'EOF'
:80 {
    reverse_proxy 127.0.0.1:3000 {
        flush_interval -1
    }
}
EOF

systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy
sleep 2
systemctl is-active caddy
echo "[*] Caddy installed and active!"
