# CoRoute Gateway

Single Node.js service that fronts the Oracle Autonomous Database for the CoRoute
mobile app and relays real-time telemetry, chat, alerts and **voice** between the
riders of one convoy.

```
Flutter app  ──HTTPS /api/*──▶  Caddy (TLS)  ──▶  gateway :3000  ──SODA REST──▶  Oracle ADB (Always Free)
             ──WSS   /ws   ──▶             ──▶   (rooms, voice relay, write-behind persistence)
```

* **Auth**: register / login (scrypt, off the event loop) or Google Sign-In (ID token verified server-side) → JWT.
* **Rooms**: a socket is bound to exactly one convoy after a membership-checked `JOIN`;
  every broadcast is room-scoped, so one group can never hear or see another.
* **Voice**: PCM16 frames relayed as binary WebSocket messages to the room or to one
  chosen rider (`to`). Floor control for group talk. No audio is ever stored.
* **Persistence**: per-rider documents (no whole-convoy overwrites), write-behind for
  telemetry, immediate for messages/alerts/config.
* **Housekeeping**: stale convoys auto-end, GPS traces are stripped after
  `RETENTION_ENDED_CONVOY_DAYS`, accounts and trip records are kept forever,
  and a keep-alive ping stops the Always-Free DB from being paused.

## Run locally without a database
```
ORACLE_SODA_URL=memory ORACLE_USER=x ORACLE_PASSWORD=x JWT_SECRET=$(openssl rand -base64 48) npm start
```

## Tests
```
npm test
```

See `deploy/RUNBOOK.md` for a single OCI VM and `../docs/PRODUCTION_TWO_VM_RUNBOOK.md` for the two-VM
production setup (VM1 live, VM2 web + mirror, NLB, Vault, Object Storage backups).

## Deploy notes
* Every setting is an environment variable read by `src/config.js`; `deploy/.env.example` lists
  them all (secrets left empty). Copy it to `/etc/coroute/gateway.env` (chmod 600) and fill it in.
* `REVIEW_PHOTO_DIR`: private folder for photos riders attach to trip reviews. It must be outside
  `public/`, persistent and backed up. Unset, it is `<gateway>/data/review-photos`, which is inside
  the service's `ReadWritePaths`; a folder elsewhere must be added to `ReadWritePaths=` in
  `deploy/coroute-gateway.service` (the unit runs with `ProtectSystem=strict`). Deleting an account
  deletes that rider's review photo files too.
* Emergency SMS providers (`TELEPHONY_*`, `TWILIO_*`, `WHATSAPP_*`, `INFOBIP_*`, `AWS_SNS_*`) stay
  disabled while their keys are empty.
* `PAYMENTS_ENABLED` defaults to on in production; set it to `false` only on a staging box.
* Coupons: the launch coupons `WELCOME50`, `CAPTAIN100` and `RIDERFREE` are created once in the
  coupon store on first start (bound to plans, once per rider, with a total limit and an end date)
  and are then managed like any other coupon in the admin console; pausing, editing or archiving
  one is never undone by a restart.
* Passwords (`src/password_hash.js`): new hashes are `scrypt$N$r$p$salt$hash` (N=2^15, r=8, p=1, ~100 ms,
  computed on the libuv threadpool, at most `PASSWORD_HASH_CONCURRENCY` at once). Legacy bcrypt hashes are
  verified in a `worker_threads` worker (the event loop never runs bcrypt) and re-hashed to scrypt at the
  rider's next sign-in, without ending other sessions. Unknown accounts cost the same dummy verify.
* Keys: `SETTINGS_ENCRYPTION_KEY` (32 bytes, base64) encrypts admin-saved Razorpay secrets (`v2:`) and signs
  web-checkout links, so rotating `JWT_SECRET` no longer loses them; older `v1:` values (JWT-derived key) are
  read and re-encrypted on first use. `JWT_SECRET_PREVIOUS` (optional, rotation grace) is accepted for
  verification only; such requests get a fresh token in `X-CoRoute-Token`.
* Behind proxies: `TRUST_PROXY` lists the proxies whose `X-Forwarded-For` is believed (default `loopback`;
  VM2 adds VM1's private IP). `req.ip` and every IP rate limit use the real client address.

## Two-VM production (summary)
* `GATEWAY_ROLE` = `live` (VM1) / `web` (VM2) / `all` (single VM, default), shown in `/api/health` with
  `node` and the job `leases` this node holds. Caddy decides routing (`deploy/caddy/Caddyfile.vm1|vm2`);
  the LIVE route list is audited in `deploy/route_split.md` and turned into the VM1 matcher by
  `node deploy/gen_caddy_routes.js` (`--check` fails when a route in `src/` is in neither list).
* Scheduled jobs run exactly once across both VMs (`src/job_lease.js`): a lease document per job in the
  `leases` collection (unique insert + compare-and-replace). Jobs: `retention`, `convoy-auto-end` (prefers
  live), `db-keepalive`, `subscriptions`, `guardian-push` (prefers live), `coupon-seed` (once at boot),
  `backup-critical`, `backup-full`. A node of the preferred role takes a free lease at once; the other role
  only after the lease has been expired for `JOB_LEASE_GRACE_MS` (120 s), and hands it back when asked.
* `deploy/setup_node.sh` provisions a node (Node 22, Caddy + DuckDNS DNS module, OCI CLI, swap, firewall,
  units); `deploy/coroute-secrets.service` + `deploy/fetch_secrets.sh` load secrets from OCI Vault into
  `/run/coroute` (tmpfs) with the instance principal; `deploy/coroute-gateway.service` runs the gateway.
