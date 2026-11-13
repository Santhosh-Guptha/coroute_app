"""Adds the gateway VMs to the Autonomous Database network ACL.

Every real value comes from the environment or the git-ignored deploy/inventory.local.env (deploy/_inventory.py):
OCI_ADB_OCID, OCI_VCN_OCID, VM1_PUBLIC_IP, VM2_PUBLIC_IP, optional VM3..VM5_PUBLIC_IP, ADB_ACL_EXTRA_IPS,
VCN_CIDR (default 10.0.0.0/16) and OCI_CONFIG_FILE (default ~/.oci/config).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _inventory import inv, inv_list  # noqa: E402

adb_id = inv('OCI_ADB_OCID')
vcn_id = inv('OCI_VCN_OCID')
vm_public = [inv('VM1_PUBLIC_IP'), inv('VM2_PUBLIC_IP')]
for extra in ('VM3_PUBLIC_IP', 'VM4_PUBLIC_IP', 'VM5_PUBLIC_IP'):
    v = inv(extra, required=False)
    if v:
        vm_public.append(v)
vm_public += inv_list('ADB_ACL_EXTRA_IPS', required=False)
vcn_cidr = inv('VCN_CIDR', default='10.0.0.0/16')

import oci  # noqa: E402  (after the inventory check, so a missing value is reported first)

config = oci.config.from_file(os.path.expanduser(inv('OCI_CONFIG_FILE', default='~/.oci/config')))
db_client = oci.database.DatabaseClient(config)

adb = db_client.get_autonomous_database(adb_id).data
current_ips = list(adb.whitelisted_ips or [])
new_entries = list(vm_public) + [f'{vcn_id};{ip}/32' for ip in vm_public[:2]] + [f'{vcn_id};{vcn_cidr}']

updated_ips = sorted(set(current_ips + new_entries))
print(f'Current ACL entries: {len(current_ips)}; after update: {len(updated_ips)}')

details = oci.database.models.UpdateAutonomousDatabaseDetails(
    whitelisted_ips=updated_ips
)

res = db_client.update_autonomous_database(adb_id, details)
print(f'Success! Autonomous Database state: {res.data.lifecycle_state}')
