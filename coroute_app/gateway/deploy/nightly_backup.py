#!/usr/bin/env python3
"""
CoRoute - Automated SODA Database Backup to OCI Object Storage
==============================================================
Runs nightly via cron on VM 1.
1. Connects to production Oracle Autonomous Database (SODA REST).
2. Exports all collections (users, convoys, trips, reviews, hazards, guardians).
3. Compresses export as gzip (coroute_db_backup_YYYYMMDD_HHMMSS.json.gz).
4. Uploads to private Always-Free Object Storage bucket: 'coroute-backups'.
5. Prunes backups older than 30 days.
"""

import os
import sys
import json
import gzip
import time
import urllib.request
import urllib.error
import base64
from datetime import datetime

# Ensure oci package in ubuntu home is discovered
for p in ["/home/ubuntu/.local/lib/python3.8/site-packages", "/home/ubuntu/.local/lib/python3.10/site-packages", "/home/ubuntu/.local/lib/python3.12/site-packages"]:
    if os.path.exists(p) and p not in sys.path:
        sys.path.insert(0, p)

import oci

BUCKET_NAME = "coroute-backups"
ENV_PATH = "/etc/coroute/gateway.env"
FALLBACK_ENV_PATH = os.path.expanduser("~/gateway/.env")

COLLECTIONS = [
    "users",
    "convoys",
    "trips",
    "trip_reviews",
    "road_hazards",
    "guardians",
    "community_stats",
    "feature_analytics",
    "admin_audit_log"
]


def load_env():
    """Loads environment variables from gateway.env."""
    env = {}
    path = ENV_PATH if os.path.exists(ENV_PATH) else FALLBACK_ENV_PATH
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip("'\"")
    return env


def fetch_soda_collection(base_url, user, password, col_name):
    """Exports all documents from a SODA collection with pagination."""
    url = f"{base_url.rstrip('/')}/{col_name}?limit=1000"
    auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    headers = {
        "Authorization": f"Basic {auth}",
        "Accept": "application/json"
    }

    docs = []
    has_more = True

    while has_more and url:
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                items = data.get("items", [])
                docs.extend(items)
                has_more = data.get("hasMore", False)
                # Next link if available
                links = data.get("links", [])
                next_links = [l["href"] for l in links if l.get("rel") == "next"]
                url = next_links[0] if next_links else None
        except urllib.error.HTTPError as e:
            if e.code == 404:
                # Collection does not exist yet
                break
            print(f"[!] Warning fetching collection {col_name}: HTTP {e.code}")
            break
        except Exception as e:
            print(f"[!] Error fetching collection {col_name}: {e}")
            break

    return docs


def main():
    print(f"[{datetime.utcnow().isoformat()}] Starting CoRoute SODA Database Backup...")
    env = load_env()
    soda_url = env.get("ORACLE_SODA_URL")
    db_user = env.get("ORACLE_SODA_USER", "COROUTE")
    db_pass = env.get("ORACLE_SODA_PASSWORD")

    if not soda_url or not db_pass:
        print("[!] Missing ORACLE_SODA_URL or ORACLE_SODA_PASSWORD in environment. Exiting.")
        sys.exit(1)

    backup_data = {
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "service": "CoRoute Autonomous Database Backup",
        "collections": {}
    }

    for col in COLLECTIONS:
        docs = fetch_soda_collection(soda_url, db_user, db_pass, col)
        backup_data["collections"][col] = docs
        print(f"  - {col}: {len(docs)} documents exported")

    # Compress to gzip
    ts_str = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    filename = f"coroute_db_backup_{ts_str}.json.gz"
    local_path = f"/tmp/{filename}"

    with gzip.open(local_path, "wt", encoding="utf-8") as gz:
        json.dump(backup_data, gz)

    file_size_kb = os.path.getsize(local_path) / 1024
    print(f"[*] Compressed backup file created: {filename} ({file_size_kb:.1f} KB)")

    # Upload to OCI Object Storage
    cfg_path = os.path.expanduser("~/.oci/config")
    if not os.path.exists(cfg_path) and os.path.exists("/home/ubuntu/.oci/config"):
        cfg_path = "/home/ubuntu/.oci/config"
    config = oci.config.from_file(cfg_path)
    os_client = oci.object_storage.ObjectStorageClient(config)
    ns = os_client.get_namespace().data

    with open(local_path, "rb") as f:
        os_client.put_object(
            namespace_name=ns,
            bucket_name=BUCKET_NAME,
            object_name=filename,
            put_object_body=f,
            content_type="application/gzip"
        )
    print(f"  [OK] Uploaded {filename} to bucket '{BUCKET_NAME}' in namespace '{ns}'")

    # Clean up local file
    os.remove(local_path)

    # Prune old backups (> 30 days)
    print("[*] Checking backup retention in Object Storage...")
    objects = os_client.list_objects(ns, BUCKET_NAME, prefix="coroute_db_backup_").data.objects
    now = time.time()
    for obj in objects:
        age_days = (now - obj.time_created.timestamp()) / 86400
        if age_days > 30:
            print(f"  - Pruning expired backup ({age_days:.1f} days old): {obj.name}")
            os_client.delete_object(ns, BUCKET_NAME, obj.name)

    print(f"[{datetime.utcnow().isoformat()}] Backup completed successfully.")


if __name__ == "__main__":
    main()
