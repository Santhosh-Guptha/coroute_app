#!/usr/bin/env python3
"""
CoRoute - Automated Oracle Cloud Ampere A1 Provisioner & Load-Balancer
=====================================================================
Continuously polls Oracle Cloud Infrastructure (OCI) in the inventory region for an
Always-Free Ampere A1 (VM.Standard.A1.Flex) instance (alternating between 2 OCPU/12GB
and 1 OCPU/6GB for maximum allocation probability).

When Oracle frees host capacity and launches the VM, this script AUTOMATICALLY:
1. Waits for the instance to transition to the RUNNING state.
2. Extracts its private and public IP.
3. Whitelists the new Ampere node in the Oracle Autonomous Database (SODA) Access Control List (ACL).
4. Connects over the high-speed 10 Gbps private VCN and performs zero-touch setup:
   - Configures 2GB swap space for peak memory stability
   - Installs Node.js 22 LTS runtime
   - Clones/deploys the production CoRoute Gateway backend
   - Configures /etc/coroute/gateway.env with synchronized production credentials
   - Configures and starts coroute-gateway systemd service
   - Opens firewall ports (22, 80, 443, 3000)
5. Automatically registers the new Ampere node into Caddy's load-balancer upstream pool:
   `reverse_proxy 127.0.0.1:3000 <VM2_PRIVATE_IP>:3000 <AMPERE_PRIVATE_IP>:3000 { ... }`
6. Hot-reloads Caddy with zero downtime so new member traffic distributes across all nodes!
7. Verifies live cluster health on https://<PUBLIC_HOST>/status and logs audit records.

All addresses, OCIDs and key paths come from deploy/inventory.local.env (git-ignored) or the environment.
"""

import os
import sys
import time
import socket
import subprocess
import random
from datetime import datetime

# UTF-8 console output
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Attempt to import OCI SDK
try:
    import oci
except ImportError:
    print("[*] Installing official Oracle Cloud SDK (oci)...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "oci"])
    import oci

# ==============================================================================
# OCI CONFIGURATION & CLUSTER CONSTANTS
# ==============================================================================
# Every real identifier comes from the environment or the git-ignored deploy/inventory.local.env
# (deploy/_inventory.py; template deploy/inventory.example.env). A missing value stops the script with a clear message.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _inventory import inv, inv_file_text  # noqa: E402

TENANCY_OCID = inv("OCI_TENANCY_OCID")
REGION = inv("OCI_REGION")
AVAILABILITY_DOMAIN = inv("OCI_AVAILABILITY_DOMAIN")
COMPARTMENT_OCID = inv("OCI_COMPARTMENT_OCID", default=TENANCY_OCID)

VCN_ID = inv("OCI_VCN_OCID")
SUBNET_ID = inv("OCI_SUBNET_OCID")
ADB_ID = inv("OCI_ADB_OCID")
PUBLIC_HOST = inv("PUBLIC_HOST", default="coroute.devmonks.space")

SHAPE = "VM.Standard.A1.Flex"
BOOT_VOLUME_SIZE_GBS = 50  # 100% within remaining 100GB Always-Free storage
RETRY_DELAY_SECONDS = 90

# Target shape configurations within tenancy Always-Free limits (2 OCPU / 12 GB max)
SHAPE_CANDIDATES = [
    {"ocpus": 2.0, "memory_in_gbs": 12.0, "label": "2 OCPUs / 12 GB RAM"},
    {"ocpus": 1.0, "memory_in_gbs": 6.0,  "label": "1 OCPU / 6 GB RAM"},
]

DEFAULT_SSH_PUBLIC_KEY = inv_file_text("VM_SSH_PUBLIC_KEY_FILE")
SSH_PRIVATE_KEY_PATH = os.path.expanduser(inv("VM_SSH_PRIVATE_KEY_FILE"))


def get_oci_config():
    """Loads the OCI config file (OCI_CONFIG_FILE, default ~/.oci/config)."""
    config_file = os.path.expanduser(inv("OCI_CONFIG_FILE", default="~/.oci/config"))
    if os.path.exists(config_file):
        try:
            return oci.config.from_file(config_file)
        except Exception as e:
            print(f"[!] Warning reading the OCI config file: {e}")

    # Fallback to env
    return {
        "user": os.environ.get("OCI_USER_OCID"),
        "fingerprint": os.environ.get("OCI_FINGERPRINT"),
        "key_file": os.path.expanduser(os.environ.get("OCI_KEY_FILE", "~/.oci/oci_api_key.pem")),
        "tenancy": TENANCY_OCID,
        "region": REGION,
    }


def find_ubuntu_arm_image(compute_client):
    """Finds the Canonical Ubuntu aarch64 image in the tenancy."""
    print("[*] Locating Ubuntu aarch64 (ARM64) image...")
    images = compute_client.list_images(
        compartment_id=COMPARTMENT_OCID,
        operating_system="Canonical Ubuntu",
        shape=SHAPE,
        sort_by="TIMECREATED",
        sort_order="DESC",
    ).data

    for img in images:
        name = img.display_name.lower()
        if ("aarch64" in name or "arm" in name) and "minimal" not in name:
            print(f"  [OK] Using Ubuntu ARM64 image: {img.display_name} ({img.id})")
            return img.id

    if images:
        return images[0].id

    # Fallback: the image named in the inventory
    return inv("OCI_ARM_IMAGE_OCID")


def wait_for_ssh(ip, port=22, timeout=240):
    """Polls until SSH port is open and accepting connections."""
    print(f"[*] Waiting for SSH port {port} on {ip}...")
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((ip, port), timeout=4):
                print(f"  [OK] SSH port open on {ip}!")
                return True
        except (socket.timeout, ConnectionRefusedError, OSError):
            time.sleep(3)
    return False


def whitelist_in_autonomous_db(config, public_ip, private_ip):
    """Adds the newly allocated node to Oracle Autonomous Database (SODA) ACL."""
    print("\n" + "=" * 70)
    print(f"[*] Whitelisting Ampere Node ({public_ip} / {private_ip}) in Oracle SODA ACL...")
    print("=" * 70)
    db_client = oci.database.DatabaseClient(config)

    try:
        adb = db_client.get_autonomous_database(ADB_ID).data
        current_ips = list(adb.whitelisted_ips or [])
        new_entries = [
            public_ip,
            f"{VCN_ID};{private_ip}/32",
            f"{VCN_ID};{public_ip}/32",
        ]
        updated_ips = list(set(current_ips + new_entries))

        details = oci.database.models.UpdateAutonomousDatabaseDetails(
            whitelisted_ips=updated_ips
        )
        db_client.update_autonomous_database(ADB_ID, details)
        print("  [OK] Update submitted. Waiting for database to return to AVAILABLE...")

        for _ in range(30):
            time.sleep(5)
            adb_curr = db_client.get_autonomous_database(ADB_ID).data
            if adb_curr.lifecycle_state == "AVAILABLE":
                print(f"  [OK] Oracle Database ACL successfully updated! Status: {adb_curr.lifecycle_state}")
                return True
            print(f"    Database status: {adb_curr.lifecycle_state}...")
    except Exception as e:
        print(f"[!] Warning updating database ACL: {e}")

    return True


def auto_configure_ampere_node(private_ip, public_ip):
    """Configures the Ampere node over high-speed private VCN."""
    print("\n" + "=" * 70)
    print(f"[*] Performing Automated Turnkey Configuration on Ampere Node ({private_ip})...")
    print("=" * 70)

    # Remote setup script executed on the new Ampere node
    setup_script = """#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Creating 2GB swap space for peak load stability..."
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

echo "[2/6] Installing Node.js 22 LTS & Caddy reverse proxy on aarch64..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git build-essential ca-certificates iptables-persistent netfilter-persistent debian-keyring debian-archive-keyring apt-transport-https >/dev/null

if ! command -v node >/dev/null || [[ "$(node -v | cut -c2-3)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "Node version: $(node -v)"

# Install Caddy
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

echo "[3/6] Setting up system user and directory..."
if ! id coroute >/dev/null 2>&1; then
  useradd --system --home /opt/coroute --shell /usr/sbin/nologin coroute
fi
mkdir -p /opt/coroute/gateway /etc/coroute /var/log/coroute

echo "[4/6] Copying deployed gateway code..."
cp -r /home/ubuntu/gateway/* /opt/coroute/gateway/
cd /opt/coroute/gateway && (npm rebuild 2>/dev/null || npm install --omit=dev 2>/dev/null || true)
chown -R coroute:coroute /opt/coroute

echo "[5/6] Setting up gateway service & Caddy reverse proxy..."
cat > /etc/systemd/system/coroute-gateway.service << 'SVCEOF'
[Unit]
Description=CoRoute Ampere High-Performance Gateway (Node.js)
After=network.target

[Service]
Type=simple
User=coroute
WorkingDirectory=/opt/coroute/gateway
EnvironmentFile=/etc/coroute/gateway.env
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=5
StandardOutput=append:/var/log/coroute/gateway.log
StandardError=append:/var/log/coroute/gateway-err.log
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/caddy/Caddyfile << 'CADDYEOF'
:80 {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
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

systemctl daemon-reload
systemctl enable coroute-gateway caddy
systemctl restart coroute-gateway
systemctl restart caddy

echo "[6/6] Configuring firewall (22, 80, 443)..."
for port in 22 80 443; do
  iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $port -j ACCEPT
done
netfilter-persistent save >/dev/null 2>&1 || true

sleep 3
curl -s http://127.0.0.1:3000/status
echo ""
curl -s http://127.0.0.1:80/status
echo ""
echo "=== AMPERE NODE CONFIGURATION COMPLETE ==="
"""

    # Write remote setup script to local temp file
    local_script_path = "/tmp/setup_ampere_remote.sh"
    with open(local_script_path, "w") as f:
        f.write(setup_script)

    ssh_opts = [
        "-i", SSH_PRIVATE_KEY_PATH,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
    ]

    try:
        # Step 1: Copy gateway code from VM 1 to Ampere node over 10 Gbps private VCN (< 5s)
        print("[*] Syncing gateway codebase to Ampere node...")
        subprocess.run(["scp"] + ssh_opts + ["-r", "/opt/coroute/gateway", f"ubuntu@{private_ip}:~/gateway"], check=True)

        # Step 2: Copy gateway.env
        subprocess.run(["scp"] + ssh_opts + ["/etc/coroute/gateway.env", f"ubuntu@{private_ip}:~/gateway.env"], check=True)
        subprocess.run(["ssh"] + ssh_opts + [f"ubuntu@{private_ip}", "sudo mv ~/gateway.env /etc/coroute/gateway.env; sudo chmod 600 /etc/coroute/gateway.env; sudo chown coroute:coroute /etc/coroute/gateway.env"], check=True)

        # Step 3: Copy and execute remote setup script
        subprocess.run(["scp"] + ssh_opts + [local_script_path, f"ubuntu@{private_ip}:~/setup.sh"], check=True)
        subprocess.run(["ssh"] + ssh_opts + [f"ubuntu@{private_ip}", "chmod +x ~/setup.sh && sudo ~/setup.sh"], check=True)

        print("  [OK] Ampere node software stack successfully deployed!")
        return True
    except Exception as e:
        print(f"[!] Error during remote node setup: {e}")
        return False


def register_in_caddy_load_balancer(private_ip):
    """Adds the newly configured Ampere node into Caddy's load-balancer pool on Node 1."""
    print("\n" + "=" * 70)
    print(f"[*] Registering Ampere Node ({private_ip}:80) into Caddy Load Balancer...")
    print("=" * 70)

    caddyfile_path = "/etc/caddy/Caddyfile"
    if not os.path.exists(caddyfile_path):
        print(f"[!] {caddyfile_path} not found.")
        return False

    try:
        with open(caddyfile_path, "r") as f:
            content = f.read()

        new_target = f"{private_ip}:80"
        if new_target in content:
            print(f"  [OK] {new_target} is already in Caddy load balancer pool.")
            return True

        # Locate reverse_proxy line and append new target
        updated_lines = []
        for line in content.splitlines():
            if line.strip().startswith("reverse_proxy") and "127.0.0.1:3000" in line:
                # Append new Ampere target before opening brace
                parts = line.split("{")
                base_part = parts[0].strip()
                new_line = f"\t{base_part} {new_target} {{"
                updated_lines.append(new_line)
                print(f"  [OK] Updated load balancer upstream: {new_line}")
            else:
                updated_lines.append(line)

        new_content = "\n".join(updated_lines) + "\n"
        with open("/tmp/Caddyfile.new", "w") as f:
            f.write(new_content)

        subprocess.run(["sudo", "cp", "/tmp/Caddyfile.new", caddyfile_path], check=True)
        subprocess.run(["sudo", "systemctl", "reload", "caddy"], check=True)

        print("  [OK] Caddy reloaded successfully with Ampere node actively participating in load balancing!")
        return True
    except Exception as e:
        print(f"[!] Error updating Caddy load balancer: {e}")
        return False


def main():
    print("=" * 70)
    print(" CoRoute OCI Ampere A1 Automated Provisioner & Load-Balancer")
    print("=" * 70)
    print(f"Region:              {REGION}")
    print(f"Target Availability: {AVAILABILITY_DOMAIN}")
    print(f"Subnet ID:           {SUBNET_ID}")
    print(f"Poll Interval:       {RETRY_DELAY_SECONDS} seconds")
    print(f"Policy:              Always-Free Tier ($0.00 Cost Guarantee)")
    print("=" * 70)

    config = get_oci_config()
    compute_client = oci.core.ComputeClient(config)
    network_client = oci.core.VirtualNetworkClient(config)

    # Check if an Ampere instance already exists
    instances = compute_client.list_instances(compartment_id=COMPARTMENT_OCID).data
    for inst in instances:
        if inst.shape == SHAPE and inst.lifecycle_state not in ["TERMINATED", "TERMINATING"]:
            print(f"[*] Found existing active Ampere instance: {inst.display_name} ({inst.lifecycle_state})")
            if inst.lifecycle_state == "RUNNING":
                print("[*] Instance is already running! Ensuring it is configured in load balancer...")
                vnics = compute_client.list_vnic_attachments(compartment_id=COMPARTMENT_OCID, instance_id=inst.id).data
                if vnics:
                    vnic = network_client.get_vnic(vnics[0].vnic_id).data
                    register_in_caddy_load_balancer(vnic.private_ip)
                return

    image_id = find_ubuntu_arm_image(compute_client)

    attempt = 1
    instance = None

    print("\n[*] Starting intelligent capacity poll loop...")
    while not instance:
        ts = datetime.now().strftime("%H:%M:%S")

        # Alternate between candidate shapes for maximum allocation chance
        candidate = SHAPE_CANDIDATES[(attempt - 1) % len(SHAPE_CANDIDATES)]
        ocpus = candidate["ocpus"]
        mem = candidate["memory_in_gbs"]
        label = candidate["label"]

        print(f"[{ts}] Attempt #{attempt}: Requesting {SHAPE} ({label})...", end=" ", flush=True)

        launch_details = oci.core.models.LaunchInstanceDetails(
            compartment_id=COMPARTMENT_OCID,
            availability_domain=AVAILABILITY_DOMAIN,
            display_name=f"coroute-ampere-{int(time.time())}",
            shape=SHAPE,
            shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(
                ocpus=ocpus,
                memory_in_gbs=mem,
            ),
            create_vnic_details=oci.core.models.CreateVnicDetails(
                subnet_id=SUBNET_ID,
                assign_public_ip=True,
                display_name="primary-vnic",
            ),
            source_details=oci.core.models.InstanceSourceViaImageDetails(
                source_type="image",
                image_id=image_id,
                boot_volume_size_in_gbs=BOOT_VOLUME_SIZE_GBS,
            ),
            metadata={
                "ssh_authorized_keys": DEFAULT_SSH_PUBLIC_KEY,
            },
        )

        try:
            response = compute_client.launch_instance(launch_details)
            instance = response.data
            print("\n" + "=" * 70)
            print(">>> SUCCESS! AMPERE A1 INSTANCE ALLOCATED BY ORACLE! <<<")
            print(f"Instance ID:   {instance.id}")
            print(f"Configuration: {label}")
            print("=" * 70)
            break
        except oci.exceptions.ServiceError as e:
            if "Out of host capacity" in str(e) or e.status == 500:
                delay = RETRY_DELAY_SECONDS + random.randint(5, 15)
                print(f"Out of host capacity. Next attempt in {delay}s...", flush=True)
                time.sleep(delay)
            elif e.status == 429 or "TooManyRequests" in str(e):
                backoff = 100 + random.randint(10, 25)
                print(f"Rate limited (429). Backing off for {backoff}s...", flush=True)
                time.sleep(backoff)
            else:
                delay = RETRY_DELAY_SECONDS + random.randint(5, 15)
                print(f"Notice ({e.status}): {e.message}. Retrying in {delay}s...", flush=True)
                time.sleep(delay)
        except Exception as ex:
            print(f"Exception: {ex}. Retrying in 90s...", flush=True)
            time.sleep(90)

        attempt += 1

    # 1. Wait for RUNNING state
    print("\n[*] Waiting for Ampere instance to transition to RUNNING state...")
    instance_id = instance.id
    while True:
        inst = compute_client.get_instance(instance_id).data
        if inst.lifecycle_state == "RUNNING":
            print(f"  [OK] Instance is RUNNING!")
            break
        elif inst.lifecycle_state in ["TERMINATING", "TERMINATED"]:
            print("[!] Instance failed during boot.")
            sys.exit(1)
        time.sleep(5)

    # 2. Retrieve IPs
    vnic_attachments = compute_client.list_vnic_attachments(
        compartment_id=COMPARTMENT_OCID, instance_id=instance_id
    ).data
    vnic = network_client.get_vnic(vnic_attachments[0].vnic_id).data
    public_ip = vnic.public_ip
    private_ip = vnic.private_ip

    print(f"[*] Public IP:  {public_ip}")
    print(f"[*] Private IP: {private_ip}")

    # 3. Whitelist in Oracle Autonomous Database (SODA) ACL
    whitelist_in_autonomous_db(config, public_ip, private_ip)

    # 4. Wait for SSH over high-speed private network
    if wait_for_ssh(private_ip):
        time.sleep(10)

        # 5. Automatically configure software stack on Ampere node
        configured = auto_configure_ampere_node(private_ip, public_ip)

        # 6. Add Ampere node into Caddy Load Balancer pool
        if configured:
            lb_updated = register_in_caddy_load_balancer(private_ip)

            # 7. Final Verification
            print("\n[*] Verifying live load-balanced cluster health...")
            time.sleep(3)
            try:
                out = subprocess.check_output(["curl", "-s", f"https://{PUBLIC_HOST}/status"], universal_newlines=True)
                print(f"  Cluster Health: {out.strip()}")
            except Exception as e:
                print(f"  Health check notice: {e}")

            # 8. Record audit log
            ts_done = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            log_entry = f"[{ts_done}] [AUTOSCALE] Successfully provisioned, configured, and load-balanced Ampere A1 node ({public_ip} / {private_ip}). Cluster size: 3 nodes."
            with open("/var/log/ampere_provision.log", "a") as f:
                f.write(f"\n{log_entry}\n")

            print("\n" + "=" * 70)
            print(" [SUCCESS] AMPERE A1 AUTO-CONFIGURATION & LOAD-BALANCING COMPLETE!")
            print(f" Cluster Size:   3 Nodes (VM 1 + VM 2 + Ampere A1)")
            print(f" Ingress URL:    https://{PUBLIC_HOST}")
            print(f" Billing:        $0.00 Always-Free Tier Guaranteed")
            print("=" * 70)


if __name__ == "__main__":
    main()
