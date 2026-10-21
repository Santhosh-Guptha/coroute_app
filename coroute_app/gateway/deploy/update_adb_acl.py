import oci
import os
import sys

config = oci.config.from_file(os.path.expanduser('~/.oci/config'))
db_client = oci.database.DatabaseClient(config)
adb_id = 'ocid1.autonomousdatabase.oc1.ap-hyderabad-1.anuhsljr4ylewkaat3cu32stdgcpi7lfcoxzq3meuxgypqw4kxep3yanqvlq'

adb = db_client.get_autonomous_database(adb_id).data
current_ips = list(adb.whitelisted_ips or [])
vcn_id = 'ocid1.vcn.oc1.ap-hyderabad-1.amaaaaaa4ylewkaaj3nlmu5tgxnngmzvwg6gmswtckytfoprbbpeilipkxbq'
new_entries = [
    '152.67.181.198',
    '129.225.79.93',
    '140.245.196.191',
    f'{vcn_id};152.67.181.198/32',
    f'{vcn_id};129.225.79.93/32',
    f'{vcn_id};10.0.0.0/16',
]

updated_ips = list(set(current_ips + new_entries))
print(f'Current IPs: {current_ips}')
print(f'Updating to:  {updated_ips}')

details = oci.database.models.UpdateAutonomousDatabaseDetails(
    whitelisted_ips=updated_ips
)

res = db_client.update_autonomous_database(adb_id, details)
print(f'Success! Autonomous Database state: {res.data.lifecycle_state}')
