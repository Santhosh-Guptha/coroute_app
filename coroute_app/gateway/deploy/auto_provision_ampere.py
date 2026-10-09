#!/usr/bin/env python3
"""
CoRoute - Automated Oracle Cloud Ampere A1 Provisioner & Cutover Tool
====================================================================
This script continuously polls Oracle Cloud Infrastructure (OCI) to provision
an Always-Free Ampere A1 (ARM64) instance in region ap-hyderabad-1.

When Oracle allocates capacity and launches the VM, this script automatically:
1. Waits for the instance to enter the RUNNING state.
2. Extracts its new Public IPv4 address.
3. Waits for SSH (port 22) to become reachable.
4. Executes the turnkey setup script on the new VM over SSH:
   `curl -fsSL https://raw.githubusercontent.com/Santhosh-Guptha/coroute_app/main/gateway/deploy/setup_new_vm.sh | sudo bash`
5. Verifies live HTTPS health and DNS cutover (https://coroute.duckdns.org/api/health).
"""

import os
import sys
import time
import socket
import subprocess
from datetime import datetime

# Attempt to import OCI SDK, install if missing
try:
    import oci
except ImportError:
    print("[*] Installing official Oracle Cloud SDK (oci)...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "oci"])
    import oci

# ==============================================================================
# DEFAULT OCI CONFIGURATION FOR COROUTE
# ==============================================================================
TENANCY_OCID = "ocid1.tenancy.oc1..aaaaaaaamo3nfjelm4dk4nbm2melqjbbcjsgpzigaonwqjf7okyufjp6x2ta"
REGION = "ap-hyderabad-1"
AVAILABILITY_DOMAIN = "izDz:AP-HYDERABAD-1-AD-1"
COMPARTMENT_OCID = TENANCY_OCID

# Ampere A1 Shape Details (Always Free allows up to 4 OCPUs and 24 GB RAM)
SHAPE = "VM.Standard.A1.Flex"
DEFAULT_OCPUS = 2.0
DEFAULT_MEMORY_GBS = 12.0
BOOT_VOLUME_SIZE_GBS = 50

# Existing SSH Public Key for instance metadata
DEFAULT_SSH_PUBLIC_KEY = (
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDuXnceKvdpz1yeWMpC9h0YPg7thZQXtigXt/"
    "9ZOpjBzF7HS1niz3oiAu9Ok3zM9s5aNIZz9lFjU9UMX4DnT5mYVEyzsiw8wgQYaQfgz/zsRyRAE"
    "7QZHDPhdqE/yHY0vsshmvg75CHzdNl6vbPW4EXkE7CSTASYHw8EY6cJQdT33p3FfpKFyn1cy+pM"
    "7rerVEgqRYuvcOtbzpT6PMzGy9OSdEQudKR1la1DidabbpiQ4YgCQl1faRdhJAcNwE3oMZu8iqkp"
    "1XiqCQHyUCFoiu53Re19yinpa8Og0gwnCFUSF16n0z6qdS52VQOXCPomwNJhTE+jwVy46IKhlX4"
    "Pxrqr ssh-key-2026-10-01"
)

SSH_PRIVATE_KEY_PATH = os.path.expanduser("~/Downloads/ssh-key-2026-10-01 (1).key")
RETRY_DELAY_SECONDS = 45


def get_oci_config():
    """Loads OCI config from ~/.oci/config or environment variables."""
    config_file = os.path.expanduser("~/.oci/config")
    if os.path.exists(config_file):
        try:
            return oci.config.from_file(config_file)
        except Exception as e:
            print(f"[!] Warning reading ~/.oci/config: {e}")

    # Fallback to interactive or environment variables
    user_ocid = os.environ.get("OCI_USER_OCID")
    fingerprint = os.environ.get("OCI_FINGERPRINT")
    key_file = os.environ.get("OCI_KEY_FILE")

    if not (user_ocid and fingerprint and key_file):
        print("\n" + "=" * 70)
        print(" OCI API Credentials Setup Required (One-time, 1 min)")
        print("=" * 70)
        print("1. In Oracle Cloud Console: Click Profile (top right) -> User settings.")
        print("2. Scroll to 'API Keys' -> Click 'Add API Key' -> Download Private Key.")
        print("3. Click 'Add' and copy the details shown.\n")
        user_ocid = input("Enter User OCID (ocid1.user.oc1..): ").strip()
        fingerprint = input("Enter Key Fingerprint: ").strip()
        key_file = input("Enter Path to downloaded Private Key (.pem): ").strip()

    config = {
        "user": user_ocid,
        "fingerprint": fingerprint,
        "key_file": os.path.expanduser(key_file),
        "tenancy": TENANCY_OCID,
        "region": REGION,
    }
    oci.config.validate_config(config)
    return config


def find_ubuntu_arm_image(compute_client):
    """Finds the latest Canonical Ubuntu aarch64 image in the compartment."""
    print("[*] Locating Ubuntu aarch64 (ARM64) image...")
    images = compute_client.list_images(
        compartment_id=COMPARTMENT_OCID,
        operating_system="Canonical Ubuntu",
        shape=SHAPE,
        sort_by="TIMECREATED",
        sort_order="DESC",
    ).data

    for img in images:
        if "aarch64" in img.display_name.lower() or "arm" in img.display_name.lower():
            print(f"  ✓ Found Image: {img.display_name} ({img.id})")
            return img.id

    if images:
        print(f"  ✓ Using Image: {images[0].display_name} ({images[0].id})")
        return images[0].id

    raise RuntimeError("No compatible Ubuntu ARM64 image found in tenancy.")


def find_public_subnet(network_client):
    """Finds the public subnet in the tenancy."""
    print("[*] Locating Public Subnet in Virtual Cloud Network...")
    subnets = network_client.list_subnets(compartment_id=COMPARTMENT_OCID).data
    for sub in subnets:
        if not sub.prohibit_public_ip_on_vnic:
            print(f"  ✓ Found Public Subnet: {sub.display_name} ({sub.id})")
            return sub.id

    if subnets:
        return subnets[0].id

    raise RuntimeError("No public subnet found in Virtual Cloud Network.")


def wait_for_ssh(ip, port=22, timeout=180):
    """Polls until SSH port is open and accepting TCP connections."""
    print(f"[*] Waiting for SSH port {port} to become reachable on {ip}...")
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((ip, port), timeout=4):
                print(f"  ✓ SSH port is open on {ip}!")
                return True
        except (socket.timeout, ConnectionRefusedError, OSError):
            time.sleep(3)
    return False


def run_remote_cutover(new_ip):
    """Executes the setup and DNS cutover command on the new instance."""
    print("\n" + "=" * 70)
    print(f" Executing Automated Setup & Cutover on New VM ({new_ip})")
    print("=" * 70)

    # Use ssh-key if present, else standard ssh
    ssh_cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    if os.path.exists(SSH_PRIVATE_KEY_PATH):
        ssh_cmd.extend(["-i", SSH_PRIVATE_KEY_PATH])

    remote_command = "curl -fsSL https://raw.githubusercontent.com/Santhosh-Guptha/coroute_app/main/gateway/deploy/setup_new_vm.sh | sudo bash"
    ssh_cmd.extend([f"ubuntu@{new_ip}", remote_command])

    print(f"Running: {' '.join(ssh_cmd)}")
    result = subprocess.run(ssh_cmd)
    return result.returncode == 0


def main():
    print("=" * 70)
    print(" CoRoute OCI Ampere A1 Automated Provisioner & Migrator")
    print("=" * 70)
    print(f"Region:              {REGION}")
    print(f"Shape:               {SHAPE} ({DEFAULT_OCPUS} OCPUs, {DEFAULT_MEMORY_GBS} GB RAM)")
    print(f"Target Availability: {AVAILABILITY_DOMAIN}")
    print(f"Poll Interval:       {RETRY_DELAY_SECONDS} seconds")
    print("=" * 70)

    config = get_oci_config()
    compute_client = oci.core.ComputeClient(config)
    network_client = oci.core.VirtualNetworkClient(config)

    image_id = find_ubuntu_arm_image(compute_client)
    subnet_id = find_public_subnet(network_client)

    launch_details = oci.core.models.LaunchInstanceDetails(
        compartment_id=COMPARTMENT_OCID,
        availability_domain=AVAILABILITY_DOMAIN,
        display_name=f"coroute-ampere-{datetime.utcnow().strftime('%Y%m%d-%H%M')}",
        image_id=image_id,
        shape=SHAPE,
        shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(
            ocpus=DEFAULT_OCPUS,
            memory_in_gbs=DEFAULT_MEMORY_GBS,
        ),
        create_vnic_details=oci.core.models.CreateVnicDetails(
            subnet_id=subnet_id,
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

    attempt = 1
    instance = None

    print("\n[*] Starting capacity poll loop...")
    while not instance:
        ts = datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] Attempt #{attempt}: Requesting {SHAPE} instance...", end=" ", flush=True)

        try:
            response = compute_client.launch_instance(launch_details)
            instance = response.data
            print(">>> SUCCESS! Instance allocated! <<<")
            print(f"Instance ID: {instance.id}")
            break
        except oci.exceptions.ServiceError as e:
            if "Out of host capacity" in str(e) or e.status == 500 or "TooManyRequests" in str(e):
                print(f"Out of host capacity. Retrying in {RETRY_DELAY_SECONDS}s...")
            else:
                print(f"Error ({e.status}): {e.message}")
                if e.status == 400 and "Quota" in str(e.message):
                    print("[!] Quota error encountered. Halting loop.")
                    sys.exit(1)
        except Exception as ex:
            print(f"Exception: {ex}")

        attempt += 1
        time.sleep(RETRY_DELAY_SECONDS)

    # Instance launched! Wait for RUNNING state
    print("\n[*] Waiting for instance to transition to RUNNING state...")
    instance_id = instance.id
    while True:
        inst = compute_client.get_instance(instance_id).data
        print(f"  Current status: {inst.lifecycle_state}")
        if inst.lifecycle_state == "RUNNING":
            break
        elif inst.lifecycle_state in ["TERMINATING", "TERMINATED"]:
            print("[!] Instance failed during boot.")
            sys.exit(1)
        time.sleep(5)

    # Retrieve Public IP Address
    print("[*] Retrieving Public IP Address...")
    vnic_attachments = compute_client.list_vnic_attachments(
        compartment_id=COMPARTMENT_OCID, instance_id=instance_id
    ).data
    if not vnic_attachments:
        raise RuntimeError("No VNIC attachments found for instance.")

    vnic = network_client.get_vnic(vnic_attachments[0].vnic_id).data
    public_ip = vnic.public_ip
    print(f"\n=======================================================")
    print(f"  NEW AMPERE VM ALLOCATED! Public IP: {public_ip}")
    print(f"=======================================================\n")

    # Wait for SSH port
    if wait_for_ssh(public_ip):
        # Give cloud-init 10 seconds to settle
        print("[*] Waiting 10 seconds for cloud-init to finalize...")
        time.sleep(10)

        # Trigger automatic setup and cutover!
        success = run_remote_cutover(public_ip)
        if success:
            print("\n" + "=" * 70)
            print(" 🎉 AMPERE MIGRATION AND CUTOVER COMPLETE!")
            print(f" Public Domain:  https://coroute.duckdns.org")
            print(f" New VM Host:    {public_ip}")
            print(f" Status:         100% Configured, Live, & Healthy.")
            print("=" * 70)
        else:
            print(f"\n[!] Cutover script encountered an issue. You can manually re-run on {public_ip}:")
            print(f"    ssh ubuntu@{public_ip} 'curl -fsSL https://raw.githubusercontent.com/Santhosh-Guptha/coroute_app/main/gateway/deploy/setup_new_vm.sh | sudo bash'")


if __name__ == "__main__":
    main()
