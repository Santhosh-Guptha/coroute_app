# Background job queue and workers (round 8, build 3.55.0+10027)

Goal (HIGH_TRAFFIC_PLAN_v3.57 sections 4, 8, 14 item 6): live nodes do only live work. E-mails, push fan-out, ride
summary pictures, photo clean-up, road data fetches and nightly batches run on **worker processes that pull jobs
according to their own capacity**. No Redis or RabbitMQ: the queue is one collection in the existing Autonomous DB.

Code: `gateway/src/jobs/` (queue, worker, capacity, producers, admin API), `gateway/worker.js` (separate process),
`gateway/deploy/worker/coroute-worker.service`. Tests: `gateway/test/jobs8_*.test.js`.

## 1. What runs where

| Work | Before | Now (JOBS_QUEUE=on) | Job type |
|---|---|---|---|
| Security e-mails: ride sign-in code, 2-step code, password reset, sign-up link, e-mail change, notices | sent on the gateway that took the request | **priority 0**, sealed payload, worker sends it; **the gateway sends it itself if no worker claimed it within 10 s** | `email.security` |
| Welcome e-mail | gateway, background | worker | `email.lifecycle` |
| Ride summary e-mail + route picture (route_png) | gateway, background / leased sweep | worker (the picture is drawn there) | `email.lifecycle` |
| Receipts and refunds | gateway, background | worker | `email.receipt`, `email.refund` |
| Lifecycle sweep, receipt retries, offer e-mails, e-mail studio campaigns, weekly owner summary | leased job on a gateway | lease keeps the schedule, the work is one job | `email.*_tick`, `email.lifecycle_due`, `email.receipt_retry`, `email.business_summary` |
| Push fan-out (friend requests, invites, plan notices, news) | gateway | worker (the "has a live socket" check is done on the gateway first) | `push.fanout` |
| Admin push campaigns, news-cap cleanup | leased job | lease + job | `push.campaigns_tick`, `batch.push_caps_cleanup` |
| Road cell fetch from Overpass | on the rider's request (it waited) | the request answers at once (stale copy or 202), the worker fetches under its budget | `roads.fetch` |
| Removing replaced profile pictures | on the upload request | worker | `photo.delete` |
| Business nightly, intel aggregate / daily, rider score, diagnostics retention, backups | leased job on a gateway | lease + job | `batch.*` |

**Never moved** (unchanged, direct): SOS and alerts over the socket and the HTTP SOS lane, server SOS SMS and its
retry job (`sos-sms`), guardian push, convoy auto-end, retention, sessions, subscriptions, keep-alive. The EXIF / GPS
clean-up of an uploaded picture also stays on the request: raw bytes with a position are never stored anywhere, not
even in the queue. (The gateway has no image library; the phones resize before upload.)

## 2. The queue (src/jobs/queue.js)

One document per job in `job_queue`:
`jobId, key, type, family, payload, priority (0 urgent .. 9), runAt, state, attempts, maxAttempts, leaseOwner,
leaseUntil, leaseMs, deleteOnDone, lastError, createdAt, updatedAt, casRev`.

- **Claim exactly once.** A worker reads a few due rows (most urgent first) and claims each with one atomic
  compare-and-replace (JSON Patch `test` of every scalar, `casRev` included, then `replace`). Of two workers racing
  for a row exactly one wins. The queue writes a fresh `casRev` on every write itself.
- **Leases.** A claimed job has `leaseUntil`; the worker renews it every lease/3. A crashed worker's jobs are put
  back by any worker after the lease ends. The attempt was counted at the claim, so a job that kills its worker every
  time ends in the dead-letter queue.
- **Retries.** Exponential backoff with half jitter (5 s, 10 s, 20 s ... up to 15 min; per type). After
  `maxAttempts` the job moves to `job_dead`. A handler can say "not now, no attempt spent" (`Defer`: road budget) or
  "never retry" (`PermanentError`).
- **Idempotent enqueue.** `key` is unique. Enqueueing an existing key returns the existing job. Leased ticks use
  `rearm`: a finished job with that key is queued again, a pending one is never doubled (no backlog when workers are
  down). E-mails keep their own `mail_log` once-only rows as well.
- **Bounded payloads** (8 KB): ids and small values only. Security e-mails are **sealed** (AES-256-GCM, key
  `JOBS_SEAL_KEY` or derived from `JWT_SECRET`) and their row is deleted when done.
- **Clean-up.** Done rows lose their payload and are removed after 24 h; dead letters after 14 days (leased hourly
  job `jobs-cleanup`).

## 3. The worker (src/jobs/worker.js, capacity.js)

- Concurrency per family (`WORKER_CONCURRENCY`, default `email:4,push:4,roads:1,photo:2,batch:1`), capped by
  `WORKER_MAX_CONCURRENCY`, multiplied by a **capacity factor** measured every poll:
  event-loop lag p99 (40 / 100 ms), 1-minute load per core (1.0 / 1.5), available memory (20 % / 10 %), database
  calls in flight vs `ORACLE_MAX_INFLIGHT` (50 % / 80 %, or any call waiting). Below the first number: full speed;
  between: half; above the second: **no new work** (running jobs finish). One urgent job (security code) is still
  taken when busy.
- Polling: 250 ms while there is work, doubling to 5 s when idle; a job enqueued on the same node wakes the worker
  at once. One small query per poll (`JOBS_CLAIM_BATCH` = 4 rows) keeps the free database's 20 sessions free.
- Graceful drain: on SIGTERM it claims nothing more, waits `WORKER_DRAIN_MS` (25 s; 5 s inside a gateway), then
  hands unfinished jobs back to the queue (attempt not spent).
- Heartbeat row per active worker in `job_workers` every 15 s (admin page, live-node yield).

## 4. Where workers run

| Setting | Effect |
|---|---|
| `JOBS_QUEUE=off` (default) | Nothing changes: every producer works inline exactly as before round 8 |
| `JOBS_QUEUE=on`, `WORKER_INPROCESS=auto` | Producers enqueue. Gateways with `GATEWAY_ROLE` all / web work jobs (half of the concurrency). A **live** node works jobs only while no other worker has a heartbeat |
| `JOBS_SEPARATE_WORKER=on` (on the live node) | The live node never works jobs |
| `coroute-worker` service | `node worker.js` from the same release: same handlers, no port 3000, no leases, no mirror |

## 5. Admin and monitoring

- `GET /api/admin/jobs` (MASTER_ADMIN): per type queued / due / running / retrying / oldest age, dead letters,
  workers seen in the last 45 s, this node's worker status, counters, `alert` + `alerts`
  (`OLDEST_JOB_<n>S` over `JOBS_ALERT_OLDEST_S`, `DEAD_LETTERS_<n>` at `JOBS_ALERT_DEAD`, `NO_ACTIVE_WORKER`).
- `GET /api/admin/jobs/dead?type=&limit=`, `POST /api/admin/jobs/dead/:jobId/retry`,
  `POST /api/admin/jobs/dead/:jobId/discard` (also `DELETE /api/admin/jobs/dead/:jobId`). Audited.
- Worker process: `GET /health` (200 / 503 draining), `GET /health/queue` (503 when an alert is on: a watchdog
  target), `GET /metrics`.
- Metrics: `coroute_jobs_enabled`, `coroute_jobs_enqueued_total{type}`, `coroute_jobs_dispatch_total{kind}`
  (inline, fallbackInline ...), `coroute_jobs_queue_ops_total{op}`, `coroute_jobs_running{family}`,
  `coroute_jobs_capacity_factor{reason}`, `coroute_jobs_poll_delay_ms`, `coroute_jobs_processed_total{type,outcome}`.

## 6. Delivery guarantee

At least once, with idempotent handlers: e-mails are guarded by `mail_log` (one row per message, claimed before
sending), receipts by the order key, road cells and photo deletes are naturally idempotent, leased batches are the
same functions the lease ran before (they were already safe to re-run). A job finished after its lease was taken over
is logged and not written back.
