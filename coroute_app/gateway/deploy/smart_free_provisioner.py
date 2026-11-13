import oci
import os
import sys
import time
import socket

print('=== COROUTE ALWAYS-FREE SMART PROVISIONER ===')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _inventory import inv, inv_file_text  # noqa: E402  (values from deploy/inventory.local.env or the environment)

config_path = os.path.expanduser(inv('OCI_CONFIG_FILE', default='~/.oci/config'))
if not os.path.exists(config_path):
    print(f'[!] Config not found at {config_path}')
    sys.exit(1)

config = oci.config.from_file(config_path)
compute = oci.core.ComputeClient(config)
net = oci.core.VirtualNetworkClient(config)

tenancy = config['tenancy']
ad = inv('OCI_AVAILABILITY_DOMAIN')
subnet_id = inv('OCI_SUBNET_OCID')
ssh_key = inv_file_text('VM_SSH_PUBLIC_KEY_FILE')
# ARM and x86_64 Ubuntu images of the region
arm_image_id = inv('OCI_ARM_IMAGE_OCID')
x86_image_id = inv('OCI_X86_IMAGE_OCID')

# Check existing non-terminated instances
current_instances = [i for i in compute.list_instances(compartment_id=tenancy).data if i.lifecycle_state != 'TERMINATED']
print(f'[*] Currently active instances in tenancy: {len(current_instances)}')
for i in current_instances:
    print(f'    - {i.display_name} ({i.shape}, {i.lifecycle_state})')

allocated_instance = None

# 1. Attempt 1: Try Ampere A1 (1 OCPU, 6 GB RAM - small slice)
print('\n[1/2] Testing Ampere A1 allocation (1 OCPU, 6 GB RAM - 100% Free Tier)...')
try:
    launch_details = oci.core.models.LaunchInstanceDetails(
        compartment_id=tenancy,
        availability_domain=ad,
        display_name='coroute-ampere-relay',
        shape='VM.Standard.A1.Flex',
        shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(ocpus=1.0, memory_in_gbs=6.0),
        create_vnic_details=oci.core.models.CreateVnicDetails(
            subnet_id=subnet_id,
            assign_public_ip=True,
            display_name='primary-vnic',
        ),
        source_details=oci.core.models.InstanceSourceViaImageDetails(
            source_type='image',
            image_id=arm_image_id,
            boot_volume_size_in_gbs=50,
        ),
        metadata={'ssh_authorized_keys': ssh_key},
    )
    res = compute.launch_instance(launch_details)
    allocated_instance = res.data
    print(f'>>> SUCCESS! Ampere A1 Allocated: {allocated_instance.id} <<<')
except oci.exceptions.ServiceError as e:
    print(f'[-] Ampere A1 not available: {e.message}')

# If Ampere is out of capacity, wait 10 seconds before attempting AMD Micro
if not allocated_instance:
    print('\n[*] Pausing 10s to ensure clean API rate limits...')
    time.sleep(10)
    print('\n[2/2] Provisioning 2nd Always-Free AMD Micro VM (VM.Standard.E2.1.Micro - 100% Free Tier)...')
    for retry in range(5):
        try:
            launch_details = oci.core.models.LaunchInstanceDetails(
                compartment_id=tenancy,
                availability_domain=ad,
                display_name='coroute-relay-2',
                shape='VM.Standard.E2.1.Micro',
                create_vnic_details=oci.core.models.CreateVnicDetails(
                    subnet_id=subnet_id,
                    assign_public_ip=True,
                    display_name='primary-vnic',
                ),
                source_details=oci.core.models.InstanceSourceViaImageDetails(
                    source_type='image',
                    image_id=x86_image_id,
                    boot_volume_size_in_gbs=50,
                ),
                metadata={'ssh_authorized_keys': ssh_key},
            )
            res = compute.launch_instance(launch_details)
            allocated_instance = res.data
            print(f'>>> SUCCESS! 2nd AMD Micro VM Allocated: {allocated_instance.id} <<<')
            break
        except oci.exceptions.ServiceError as e:
            if e.status == 429:
                print(f'[-] Rate limited (429). Retrying in 15s (attempt {retry+1}/5)...')
                time.sleep(15)
            else:
                print(f'[!] Service Error ({e.status}): {e.message}')
                break
        except Exception as e:
            print(f'[!] Failed to launch AMD Micro: {e}')
            break

# Wait for RUNNING and get public IP
inst_id = allocated_instance.id
print(f'\n[*] Waiting for instance {allocated_instance.display_name} ({inst_id}) to become RUNNING...')

for attempt in range(60):
    time.sleep(5)
    inst = compute.get_instance(inst_id).data
    if inst.lifecycle_state == 'RUNNING':
        print(f'[*] Instance state: RUNNING!')
        break
    print(f'    [{attempt+1}/60] State: {inst.lifecycle_state}...')

# Get Public IP
vnics = compute.list_vnic_attachments(compartment_id=tenancy, instance_id=inst_id).data
public_ip = None
if vnics:
    vnic_id = vnics[0].vnic_id
    vnic = net.get_vnic(vnic_id).data
    public_ip = vnic.public_ip
    print(f'[*] Public IP: {public_ip}')
    print(f'[*] Private IP: {vnic.private_ip}')

print('\n=== VM PROVISIONING COMPLETE ===')
print(f'Name:      {inst.display_name}')
print(f'Shape:     {inst.shape}')
print(f'Public IP: {public_ip}')
print(f'Billing:   Always-Free Tier (0.00 Cost)')
