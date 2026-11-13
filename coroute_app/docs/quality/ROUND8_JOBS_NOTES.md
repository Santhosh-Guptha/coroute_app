# Round 8 jobs notes (for the lead)

Background job queue and capacity-aware workers (HIGH_TRAFFIC_PLAN_v3.57 item 6). Build stays 3.55.0+10027.
Feature doc: `docs/features_355/job_queue.md`. Default is **off** (`JOBS_QUEUE=off`): with the default every producer
works inline exactly as before, so this round is safe to deploy before it is switched on.

## 1. Files

| File | What |
|---|---|
| `gateway/src/jobs/queue.js` | durable queue on SODA (`job_queue`, `job_dead`): CAS claim, leases, backoff + jitter, dead letters, idempotent / rearm enqueue, sealed payloads, TTL clean-up, summary |
| `gateway/src/jobs/worker.js` | capacity-aware pull worker: per-family concurrency, idle backoff + wake-up, lease renewal, urgent lane, graceful drain |
| `gateway/src/jobs/capacity.js` | capacity factor from event-loop lag, load per core, available memory, DB in flight / queued |
| `gateway/src/jobs/index.js` | `attachJobs` (dispatch / urgent / routeLease / in-process plan / heartbeat / metrics) and the admin router |
| `gateway/src/jobs/producers.js` | the migrated producers and their handlers, `LEASE_ROUTES`, `NEVER_ROUTED` |
| `gateway/src/jobs/context.js`, `errors.js` | "inside a job" (AsyncLocalStorage); `RetryLater`, `Defer`, `PermanentError` |
| `gateway/worker.js` | separate worker process (same createApp, RegisterOnlyLease, no mirror, health server) |
| `gateway/deploy/worker/coroute-worker.service`, `worker.example.env` | systemd unit + worker settings |
| `gateway/test/jobs8_queue.test.js` (15), `jobs8_producers.test.js` (12), `jobs8_sos.test.js` (3), `jobs8_worker_entry.test.js` (4) | 34 tests |

Small edits outside `src/jobs/` (producers I own, each marked "round 8"):

| File | Change |
|---|---|
| `src/app.js` | one marked block "ROUND 8 jobs mount block" before the main router |
| `src/server.js` | `app.locals.jobs.start()` after `retention.start()`; `jobs.stop()` (drain, 5 s max) before `gw.shutdown()` on SIGTERM |
| `src/security_routes.js` | `onEvent` notices call `api.send` (the property), so the queue wrapper covers every security e-mail |
| `src/lifecycle_emails.js` | welcome / ride summary enqueue `email.lifecycle` when the queue is on |
| `src/purchase_email.js` | receipts / refunds through `_dispatch` (`dispatchReceipt` also used by the receipt-address route) |
| `src/road_cells.js` | queue on: request answers at once (stale / 202) and enqueues `roads.fetch`; `fetchForJob()` handler |
| `src/avatars.js` | replaced pictures removed by `photo.delete` (EXIF clean-up stays on the request); exports `deleteAvatarDoc`, `attachPhotoJobs` |
| `deploy/.env.example` | round 8 block (every new variable) |
| `deploy/route_split.md` | row `/api/admin/jobs/*` (WEB) |
| `deploy/host/apply.sh` | role notes for the job queue (printed, nothing set automatically) |

## 2. Environment variables (all in `deploy/.env.example`)

`JOBS_QUEUE` (off), `WORKER_INPROCESS` (auto), `JOBS_SEPARATE_WORKER` (off), `WORKER_TYPES` (all),
`WORKER_CONCURRENCY` (email:4,push:4,roads:1,photo:2,batch:1), `WORKER_MAX_CONCURRENCY` (16),
`WORKER_INPROCESS_SHARE` (0.5), `WORKER_DRAIN_MS` (25000), `WORKER_HEALTH_PORT` (8091), `WORKER_HEALTH_HOST`
(127.0.0.1), `JOBS_POLL_MIN_MS` (250), `JOBS_POLL_MAX_MS` (5000), `JOBS_CLAIM_BATCH` (4), `JOBS_MAX_PAYLOAD_BYTES`
(8192), `JOBS_DONE_TTL_HOURS` (24), `JOBS_DEAD_TTL_DAYS` (14), `JOBS_SECURITY_FALLBACK_MS` (10000), `JOBS_SEAL_KEY`
([Vault], optional; else derived from `JWT_SECRET`), `JOBS_LAG_WARN_MS` / `JOBS_LAG_HIGH_MS` (40 / 100),
`JOBS_LOAD_WARN` / `JOBS_LOAD_HIGH` (1.0 / 1.5), `JOBS_MEM_WARN_PCT` / `JOBS_MEM_LOW_PCT` (20 / 10),
`JOBS_ALERT_OLDEST_S` (300), `JOBS_ALERT_DEAD` (20).

## 3. Routes

| Method | Path | Policy | Split |
|---|---|---|---|
| GET | `/api/admin/jobs` | admin | WEB |
| GET | `/api/admin/jobs/dead` | admin | WEB |
| POST | `/api/admin/jobs/dead/:jobId/retry` | admin | WEB |
| POST | `/api/admin/jobs/dead/:jobId/discard` | admin | WEB |
| DELETE | `/api/admin/jobs/dead/:jobId` | admin | WEB |

Worker process only (not the gateway, not public): `GET /health`, `GET /health/queue`, `GET /metrics` on
`WORKER_HEALTH_HOST:WORKER_HEALTH_PORT`.

## 4. How to run a worker

**vm2 (next to the web gateway, 1 GB micro).** `coroute-worker` shares the box with the web gateway, so first set
`WORKER_INPROCESS=off` in vm2's gateway.env (otherwise both work jobs: harmless, but it doubles memory use).

    sudo install -m 0644 /opt/coroute/gateway/deploy/worker/coroute-worker.service /etc/systemd/system/
    sudo install -m 0640 -o root -g coroute /opt/coroute/gateway/deploy/worker/worker.example.env /etc/coroute/worker.env
    sudo systemctl daemon-reload && sudo systemctl enable --now coroute-worker
    curl -s http://127.0.0.1:8091/health ; curl -s http://127.0.0.1:8091/health/queue
    journalctl -u coroute-worker -n 50

**vm5 (A1 worker, another tenancy).** Same unit. It needs the gateway release tree, `/etc/coroute/gateway.env` and
the secrets (database, SMTP, FCM, backup keys) like a gateway, and its egress address on the Autonomous DB ACL
(`deploy/update_adb_acl.py`). Drop-in: `MemoryMax=2G`, `NODE_OPTIONS=--max-old-space-size=1024`; worker.env:
`WORKER_CONCURRENCY=email:8,push:8,roads:2,photo:4,batch:2`. Keep `ORACLE_MAX_INFLIGHT` at 6-8 on the worker: the
database sessions are shared with the gateways, and the capacity factor already backs off when they are busy.

**vm3 (DR, low priority).** Drop-in `Nice=15`, `CPUWeight=20`; worker.env `WORKER_TYPES=batch`,
`WORKER_CONCURRENCY=batch:1`. It must stop before vm3 is promoted (the promote script restarts the gateway as `all`).

## 5. Rollout order

1. Deploy (queue off). Nothing changes. Check `/api/admin/jobs` answers `enabled: false`.
2. Staging (vm4): `JOBS_QUEUE=on`, `WORKER_INPROCESS=auto`. Run QA J1-J12.
3. Production, **in-process first**: `JOBS_QUEUE=on` on vm1 and vm2. vm2 (web) works jobs; vm1 (live) works them
   only while no other worker heartbeats (vm2's in-process worker is "another worker", so vm1 yields at once).
4. Separate worker: install `coroute-worker` on vm2 (with `WORKER_INPROCESS=off` there) or vm5. Check
   `/api/admin/jobs` lists it under `workers`.
5. `JOBS_SEPARATE_WORKER=on` on the live node: live nodes do only live work.
Rollback at any step: `JOBS_QUEUE=off` and restart. Jobs already in the queue stay; a later `on` works them (security
e-mails older than their code lifetime are harmless: the code has expired).

## 6. QA items

| # | Check | Expected |
|---|---|---|
| J1 | Sign up on staging with the queue on | Welcome e-mail arrives within seconds; `mail_log` row SENT; `job_queue` row done, no payload |
| J2 | Stop the worker (`WORKER_INPROCESS=off` everywhere, no coroute-worker), ask for a password reset | Mail arrives after about 10 s (inline fallback); `coroute_jobs_dispatch_total{kind="fallbackInline"}` +1 |
| J3 | Same with a worker running | Mail within 1 s; no fallback counted |
| J4 | Ride lock "Use e-mail code" and 2-step e-mail code | Code arrives; the `job_queue` row is sealed (no address, no code) and gone after sending |
| J5 | Finish a ride of 2 km / 10 min+ | Ride summary e-mail with the route picture, sent by the worker (`journalctl -u coroute-worker`) |
| J6 | Test payment (Razorpay test mode) | One receipt; a webhook retry sends no second one |
| J7 | Friend request to a rider whose app is closed | Push arrives; with the app open no push (socket check on the gateway) |
| J8 | Open the map in a new area | Roads appear after the 202 retry; one Overpass call per cell |
| J9 | Change the profile picture twice | Old picture gone from Object Storage within seconds |
| J10 | Raise an SOS with the worker stopped and with the queue's DB calls failing | Group gets the ALERT at once; nothing in `job_queue` |
| J11 | `systemctl restart coroute-worker` during a campaign send | Log says "N finished, M handed back"; the campaign continues on the next poll; no double e-mail |
| J12 | Load the gateway (staging quick_load.sh) while a campaign runs with an in-process worker | `coroute_jobs_capacity_factor` drops to 0.5 / 0 with reason lag / cpu / db; live p99 stays in target |
| J13 | Make a job fail (wrong SMTP password on staging) | Retries with growing gaps, then a dead letter; Retry in the admin API re-queues it; `/health/queue` 503 at `JOBS_ALERT_DEAD` |

## 7. Requests for other agents and the lead

**Agent R (watchdog, metrics):**
- R1 Watchdog target for the queue: add `worker-queue|http|http://<worker private ip>:8091/health/queue` to
  `watchdog.env` (503 = `OLDEST_JOB_*`, `DEAD_LETTERS_*` or `NO_ACTIVE_WORKER`). This needs `WORKER_HEALTH_HOST` set
  to the worker's private address and port 8091 opened to vm3 only. There is no watchdog status document today, so
  the thresholds live in the worker (`JOBS_ALERT_OLDEST_S`, `JOBS_ALERT_DEAD`).
- R2 Optional: the load shedder could read `coroute_jobs_running` to explain CPU on a node with an in-process worker.
  Not required: the worker already backs off on lag / CPU / DB budget, and never on SOS paths.
- No ws.js / convoys.js / mirror.js / metrics.js changes were made or are needed. Job metrics use `metrics.source()`.

**Lead (web admin UI):**
- U1 A "Jobs" card on the Servers page: per type queued / due / running / retrying / oldest age (from
  `GET /api/admin/jobs` `types`), workers table (`workers`: node, role, families, running, capacity, age), an alert
  banner when `alert` is true (`alerts` list), counters (`counters`).
- U2 Dead letters list (`GET /api/admin/jobs/dead`): type, attempts, last error, dates, payload (sealed rows show
  `[sealed]`), with **Retry** (`POST .../retry`) and **Discard** (`POST .../discard`) buttons; refresh after each.
- U3 Business "Servers" page could show the `jobs-cleanup` lease and the worker heartbeat age next to the job runs.

**Plan section 9 (SOS):** the "dedicated SOS worker queue on the twin node" was not built here on purpose: SOS stays on
its direct paths. If it is built, it must be an extra lane next to the socket + HTTP + SMS paths (for example a
`sos.continue` job that only the twin node claims, enqueued after the alert is stored), never a replacement.

## 8. Known limits

- Delivery is at least once. Handlers are idempotent (mail_log, order keys, natural idempotency); a job that finishes
  after its lease was taken over is not written back but may already have acted.
- `intel-aggregate` on a worker flushes the worker's own raw queue (empty); gateways keep flushing theirs every 30 s.
  The intel "last daily run" in the admin overview comes from the status document, not the live node's memory.
- The push per-user throttle is per worker process (it was per gateway node before).
- Not migrated (low volume, admin- or operator-initiated, already fire-and-forget): operator console notices
  (`operator_routes.js` mail), the admin's 1:1 rider e-mail and the studio "send test" (the admin waits for the result).
  Campaign sending itself runs on the worker (`email.studio_tick`, `email.offers_tick`).
- Road cells: with the queue on, the first request for a never-fetched cell answers 202 instead of waiting for
  Overpass (the app already retries after `Retry-After`).
