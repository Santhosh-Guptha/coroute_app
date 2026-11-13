# Git history clean-up (round 6)

The working tree no longer holds real addresses, OCIDs, personal e-mail addresses or key material in tracked
deploy files and docs (`gateway/test/deploy_inventory_356.test.js` keeps it that way). The values are still in
the **git history**. This page lists what to rotate and how to remove them from history. Removing history is
**optional and disruptive** (every clone must be re-cloned); rotating is not optional for items marked "Rotate".

Nothing on this page has been run.

## What was in tracked files

| What | Where it was | Now | Action for the owner |
|---|---|---|---|
| Two OS account passwords (`chpasswd`) | history of `gateway/deploy/setup_new_vm.sh` | removed earlier; accounts are key-only | **Rotate**: make sure both accounts have no password (`sudo passwd -l <user>`) on every VM and that the old passwords are used nowhere else |
| DuckDNS token | owner's earlier history of `setup_new_vm.sh` (not in this copy's history) | read from the environment / Vault | **Rotate** at duckdns.org, store in OCI Vault as `DUCKDNS_TOKEN` |
| SSH public key of the provisioning key pair | `auto_provision_ampere.py`, `smart_free_provisioner.py` | read from `VM_SSH_PUBLIC_KEY_FILE` | A public key is not a secret. Replace the key pair if the private key ever lived on VM1 (see the deploy prompt: move `vm_provision_ssh.key` off VM1) |
| Tenancy, VCN, subnet, Autonomous Database and image OCIDs | `auto_provision_ampere.py`, `smart_free_provisioner.py`, `update_adb_acl.py` | `OCI_*` in `deploy/inventory.local.env` | Not secrets, but they map the tenancy. No rotation possible; remove from history if the repository will be shared |
| Public IP addresses of vm1, vm2 and an admin machine | `update_adb_acl.py`, `setup_vm2.sh`, `harden_security.sh`, `audit_security.sh`, `VM_OPERATIONS_LOG.md`, `DAILY_LOG_ANALYSIS_REPORT.md`, `UX_QA_AUDIT_REPORT.md`, `docs/MASTER_AGENT_PROMPT_v3.55.md` | placeholders; `VM*_PUBLIC_IP` in the inventory | None needed if SSH is key-only and the database ACL is in place. Remove the admin machine's address from the database ACL if it is no longer used |
| Private VCN addresses of vm1 / vm2 | Caddyfiles, `setup_node.sh`, runbooks, `.env.example` | `VM2_PRIVATE_IP` placeholder filled by `setup_node.sh` from `PEER_IP` | None |
| Autonomous Database host name | `setup_new_vm.sh`, `setup_vm2.sh` | `ORACLE_SODA_URL` from the environment / inventory | None (the database is protected by its ACL and credentials) |
| Owner's personal e-mail address | `setup_vm2.sh`, `setup_new_vm.sh`, `.env.example`, `PLAY_STORE_CHECKLIST.md`, `VM_OPERATIONS_LOG.md`, `PLAY_STORE_RELEASE_CHECKLIST.md` | `<owner-email>` / `BOOTSTRAP_ADMIN_EMAILS` from the inventory | Decide whether to use a role address for the Play listing and `BOOTSTRAP_ADMIN_EMAILS` |
| Windows user folder name in paths | several docs, `design/figma/export_showcase.js` | `<you>` / `SHOWCASE_OUT_DIR` | None |
| Razorpay live key **id** | `DAILY_LOG_ANALYSIS_REPORT.md` | masked | None: the key id is public by design (it is sent to browsers). The key secret was never in the repository |

**Still in the tree, left for the owner / the app agent:** the personal e-mail address in `store/LISTING.md` (the
public Play contact) and in three Flutter test files under `test/`; the OS login names in
`gateway/deploy/VM_OPERATIONS_LOG.md`; the Google OAuth client id in `gateway/deploy/RUNBOOK.md` (public by design).

## Check before and after

```bash
# values that must not appear (run from the repository root; expect no output after the clean-up)
git log --all -p | grep -nE 'ocid1\.(tenancy|vcn|subnet|autonomousdatabase)\.oc1\.[a-z0-9-]*\.[a-z0-9]{30,}|chpasswd' | head
```

## Removing the values from history (optional)

Needs `git-filter-repo` (MIT, `pip install git-filter-repo`). Work on a fresh clone, never on your working copy.

```bash
# 1. a fresh mirror clone
git clone --mirror <your-remote-url> coroute-clean.git
cd coroute-clean.git

# 2. the literal values to replace, one per line, as  old==>new  (create this file OUTSIDE the repository;
#    copy the real values from your password manager / OCI console, do not commit this file)
cat > ../replacements.txt <<'TXT'
<tenancy OCID>==><oci-tenancy-ocid>
<vcn OCID>==><oci-vcn-ocid>
<subnet OCID>==><oci-subnet-ocid>
<autonomous database OCID>==><oci-adb-ocid>
<arm image OCID>==><oci-arm-image-ocid>
<x86 image OCID>==><oci-x86-image-ocid>
<vm1 public IP>==><vm1-public-ip>
<vm2 public IP>==><vm2-public-ip>
<admin machine public IP>==><admin-public-ip>
<database host prefix>==><your-adb-host>
<owner e-mail address>==><owner-email>
regex:echo "[a-z_]+:[^"]+" \| chpasswd==>echo "<user>:<removed>" | chpasswd
regex:ssh-rsa AAAA[A-Za-z0-9+/=]{100,}==>ssh-rsa <removed>
TXT

# 3. rewrite every commit
git filter-repo --replace-text ../replacements.txt

# 4. check (expect no output), then push the rewritten history
git log --all -p | grep -nE 'chpasswd|ocid1\.tenancy\.oc1\.\.[a-z0-9]{30,}' | head
git push --force --mirror <your-remote-url>

# 5. delete replacements.txt; every other clone must be deleted and cloned again
```

After a rewrite: ask the Git host to expire cached views of old commits (GitHub: contact support to remove
dangling commits and cached pull request diffs), and re-create open pull requests.
