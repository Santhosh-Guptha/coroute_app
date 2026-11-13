#!/usr/bin/env python3
"""
CoRoute offsite encrypted backup (v3.56). Runs nightly on vm3 (tenancy 2) from coroute-backup.timer.

1. Export: runs the gateway's own exporter (scripts/backup_export.js --set full --out <dir>) against the production
   database (ORACLE_SODA_URL / ORACLE_USER / ORACLE_PASSWORD over the public endpoint, vm3's IP on the ADB ACL).
   Every collection, page by page; gzip'd JSON lines encrypted with AES-256-GCM (BACKUP_ENCRYPTION_KEY, fresh salt
   per file, header authenticated) plus a manifest with document counts and sha256. Nothing is ever written in clear.
2. Keep on vm3's disk, grandfather-father-son: 7 daily, 4 weekly (Sunday), 3 monthly (1st) under BACKUP_DIR
   (/var/backups/coroute/{daily,weekly,monthly}/<date>/). Weekly and monthly copies are hard links (no extra space).
3. Offsite copy #2: PUT both files to tenancy-2 Object Storage through OFFSITE_PAR_URL (a pre-authenticated request
   that allows object writes only; set a bucket lifecycle rule "delete after 100 days" for its retention).
4. Verify: decrypts the new file and restores it into an in-memory database (scripts/restore_drill.js), counts
   compared with the manifest. The result goes to /var/lib/coroute-backup/last.json (the watchdog's daily summary
   reports it) and, on failure, an alert e-mail (ALERT_TO via the gateway's SMTP settings).

Settings (no secrets in this file): /etc/coroute/backup.env (0600, root): OFFSITE_PAR_URL, BACKUP_DIR, ALERT_TO ...
The database password, BACKUP_ENCRYPTION_KEY and SMTP password come from /run/coroute/secrets.env (same secrets as
the standby gateway). Python standard library only.

  sudo python3 /opt/coroute/nightly_backup.py [--dry-run] [--skip-upload] [--skip-verify]
"""

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

GATEWAY_DIR = os.environ.get("COROUTE_GATEWAY_DIR", "/opt/coroute/gateway")
ENV_FILES = ["/etc/coroute/gateway.env", "/run/coroute/secrets.env", "/etc/coroute/backup.env"]
STATUS_FILE = "/var/lib/coroute-backup/last.json"
KEEP = {"daily": 7, "weekly": 4, "monthly": 3}


def load_env(files=ENV_FILES, base=None):
    env = dict(base if base is not None else os.environ)
    for path in files:
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                env[k.strip()] = v
    return env


def log(msg):
    print(f"[{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}] {msg}", flush=True)


def export(env, out_dir, dry=False):
    """Runs the gateway exporter. Returns (enc_path, manifest_path)."""
    for k in ("ORACLE_SODA_URL", "ORACLE_USER", "ORACLE_PASSWORD", "BACKUP_ENCRYPTION_KEY"):
        if not env.get(k):
            raise RuntimeError(f"{k} is not set (gateway.env / secrets)")
    cmd = ["node", os.path.join(GATEWAY_DIR, "scripts", "backup_export.js"), "--set", "full", "--out", out_dir]
    if dry:
        log("[dry-run] " + " ".join(cmd))
        return None, None
    child_env = {k: v for k, v in env.items() if k != "BACKUP_PAR_URL"}  # never the tenancy-1 bucket from here
    r = subprocess.run(cmd, cwd=GATEWAY_DIR, env=child_env, capture_output=True, text=True, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError(f"export failed: {(r.stderr or r.stdout).strip()[-400:]}")
    enc = [f for f in os.listdir(out_dir) if f.endswith(".json.gz.enc")]
    man = [f for f in os.listdir(out_dir) if f.endswith(".manifest.json")]
    if len(enc) != 1 or len(man) != 1:
        raise RuntimeError(f"unexpected export output: {os.listdir(out_dir)}")
    return os.path.join(out_dir, enc[0]), os.path.join(out_dir, man[0])


def place(enc, man, root, today, dry=False):
    """Stores the files under daily/<date>/ and hard-links weekly (Sunday) / monthly (1st) copies."""
    tiers = ["daily"]
    if today.weekday() == 6:
        tiers.append("weekly")
    if today.day == 1:
        tiers.append("monthly")
    placed = []
    first = None
    for tier in tiers:
        d = os.path.join(root, tier, today.isoformat())
        if dry:
            log(f"[dry-run] store in {d}")
            continue
        os.makedirs(d, mode=0o700, exist_ok=True)
        for src in (enc, man):
            dst = os.path.join(d, os.path.basename(src))
            if first is None:
                shutil.move(src, dst)
            else:
                try:
                    os.link(os.path.join(first, os.path.basename(src)), dst)
                except OSError:
                    shutil.copy2(os.path.join(first, os.path.basename(src)), dst)
            os.chmod(dst, 0o600)
        if first is None:
            first = d
        placed.append(tier)
    return (os.path.join(first, os.path.basename(enc)) if first else None), placed


def prune(root, keep=KEEP, dry=False):
    removed = []
    for tier, n in keep.items():
        d = os.path.join(root, tier)
        if not os.path.isdir(d):
            continue
        days = sorted([x for x in os.listdir(d) if len(x) == 10 and x[4] == "-"], reverse=True)
        for old in days[n:]:
            p = os.path.join(d, old)
            removed.append(f"{tier}/{old}")
            if not dry:
                shutil.rmtree(p, ignore_errors=True)
    return removed


def upload(par_url, files, dry=False):
    """PUT each file to <PAR>/<prefix><name>. The PAR must end with /o/ (bucket-level, object write)."""
    if not par_url:
        return "skipped (OFFSITE_PAR_URL not set)"
    if not par_url.endswith("/"):
        par_url += "/"
    host = os.uname().nodename
    done = []
    for path in files:
        name = f"coroute-offsite/{host}/{os.path.basename(os.path.dirname(path))}/{os.path.basename(path)}"
        url = par_url + urllib.parse.quote(name, safe="/")
        if dry:
            log(f"[dry-run] PUT <offsite PAR>/{name}")
            continue
        with open(path, "rb") as f:
            data = f.read()
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, data=data, method="PUT", headers={"Content-Type": "application/octet-stream"})
                with urllib.request.urlopen(req, timeout=300) as resp:
                    if resp.status not in (200, 201):
                        raise RuntimeError(f"HTTP {resp.status}")
                done.append(name)
                break
            except Exception as e:  # noqa: BLE001
                if attempt == 2:
                    raise RuntimeError(f"offsite upload of {os.path.basename(path)} failed: {e}") from e
                time.sleep(5 * (attempt + 1))
    return f"uploaded {len(done)} file(s)"


def verify(env, enc, dry=False):
    if dry:
        log(f"[dry-run] node scripts/restore_drill.js --file {enc}")
        return {"ok": True, "dryRun": True}
    r = subprocess.run(["node", os.path.join(GATEWAY_DIR, "scripts", "restore_drill.js"), "--file", enc], cwd=GATEWAY_DIR,
                       env=env, capture_output=True, text=True, timeout=1800)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:  # noqa: BLE001
        return {"ok": False, "error": (r.stderr or r.stdout).strip()[-300:]}


def mail_failure(env, text):
    """Alert e-mail through the gateway's mailer (nodemailer); silent when SMTP is not configured."""
    if not env.get("ALERT_TO") or not env.get("SMTP_HOST"):
        return
    js = ("const n=require('nodemailer');const e=process.env;const p=Number(e.SMTP_PORT||587);"
          "n.createTransport({host:e.SMTP_HOST,port:p,secure:p===465,auth:e.SMTP_USER?{user:e.SMTP_USER,pass:e.SMTP_PASS||e.SMTP_PASSWORD}:undefined})"
          ".sendMail({from:e.MAIL_FROM||e.SMTP_USER,to:e.ALERT_TO,subject:'[CoRoute] offsite backup FAILED',text:process.argv[1]})"
          ".then(()=>process.exit(0),(x)=>{console.error(x.message);process.exit(1)})")
    subprocess.run(["node", "-e", js, text], cwd=GATEWAY_DIR, env=env, timeout=60)


def write_status(status, dry=False):
    if dry:
        return
    os.makedirs(os.path.dirname(STATUS_FILE), mode=0o750, exist_ok=True)
    with open(STATUS_FILE, "w", encoding="utf-8") as f:
        json.dump(status, f)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--skip-upload", action="store_true")
    ap.add_argument("--skip-verify", action="store_true")
    a = ap.parse_args(argv)
    env = load_env()
    root = env.get("BACKUP_DIR", "/var/backups/coroute")
    started = time.time()
    status = {"ok": False, "at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), "host": os.uname().nodename}
    tmp = tempfile.mkdtemp(prefix="coroute-backup-")
    os.chmod(tmp, 0o700)
    try:
        log("export (encrypted) ...")
        enc, man = export(env, tmp, a.dry_run)
        stored, tiers = place(enc, man, root, dt.datetime.now(dt.timezone.utc).date(), a.dry_run) if enc else (None, [])
        if stored:
            status["file"] = os.path.relpath(stored, root)
            status["bytes"] = os.path.getsize(stored)
            with open(stored.replace(".json.gz.enc", ".manifest.json"), encoding="utf-8") as f:
                m = json.load(f)
            status["documents"] = m.get("total")
            status["collections"] = len(m.get("counts", {}))
        status["tiers"] = tiers
        status["pruned"] = prune(root, dry=a.dry_run)
        if not a.skip_upload and stored:
            status["offsite"] = upload(env.get("OFFSITE_PAR_URL", ""), [stored, stored.replace(".json.gz.enc", ".manifest.json")], a.dry_run)
        if not a.skip_verify and (stored or a.dry_run):
            status["verify"] = verify(env, stored or "<new file>", a.dry_run)
            if not status["verify"].get("ok"):
                raise RuntimeError(f"verification failed: {status['verify']}")
        status["ok"] = True
    except Exception as e:  # noqa: BLE001
        status["error"] = str(e)[:500]
        log(f"FAILED: {status['error']}")
        if not a.dry_run:
            mail_failure(env, json.dumps(status, indent=2))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        status["seconds"] = round(time.time() - started, 1)
        write_status(status, a.dry_run)
        log(json.dumps(status))
    return 0 if status["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
