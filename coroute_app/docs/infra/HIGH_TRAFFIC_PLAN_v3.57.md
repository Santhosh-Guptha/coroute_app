# CoRoute high-traffic plan v3.57: no slowness, safe, secure, low latency (13 Nov 2026)

Scope: how CoRoute grows from today's two 1 GB servers to tens of thousands of live riders without slowness, without
ever delaying an SOS, and without weakening security. Builds on `docs/infra/INFRASTRUCTURE_PLAN_v3.56.md` (current
setup, measured numbers) and `gateway/deploy/RUNBOOK.md` (how to run it). Hosts are `vm1`..`vm5`; no real addresses here.

**Correction to v3.56:** Oracle's Always Free Ampere allowance is **2 OCPU / 12 GB per account** (checked on Oracle's
Always Free resources page, 13 Nov 2026), not 4 / 24. Capacity numbers below use 2 / 12.

Contents: 1 targets · 2 where latency comes from · 3 the rule that decides capacity · 4 target architecture ·
5 growth stages · 6 realtime path · 7 voice · 8 database · 9 SOS under load · 10 security under load ·
11 app-side speed · 12 observability and alerts · 13 testing before each stage · 14 work items · 15 owner decisions.

---

## 1. Targets (service levels)

| What | Target | Measured where |
|---|---|---|
| SOS: server receives -> group phones get it | **p99 < 150 ms** server side, < 1 s end to end on 4G | gateway metrics + watchdog test ride |
| SOS never lost | **0 lost**, stored before acknowledged | test suite + failover drills |
| Group positions: one phone -> others | **p99 < 250 ms** server side at full load | `ws_load.js`, `/metrics` |
| API reads (profile, ride list) | p95 < 200 ms, p99 < 500 ms | `/metrics` |
| Website first byte (India) | p95 < 300 ms | watchdog from vm3 |
| Availability of live rides | 99.9 % per month (≈ 43 min) | watchdog |
| Failover (live server dies) | riders back in a ride within 10 s, no lost SOS | failover drill |

"Server side" = from the packet arriving at the gateway to the last frame leaving it. Mobile network time in India
(≈ 40-120 ms round trip to Hyderabad on 4G) comes on top and is not ours to control.

## 2. Where latency comes from (and what we do about each)

| Hop | Typical | Our lever |
|---|---|---|
| Phone radio + mobile network to Hyderabad | 40-120 ms (4G), 300 ms+ (weak 3G) | Hyderabad region (close to most riders); keep ONE persistent WebSocket open (no new TLS per message); small frames |
| TLS handshake | 1-2 round trips, only on (re)connect | TLS 1.3, session resumption at Caddy; reconnect with jitter so a failover is not a storm |
| Load balancer (OCI NLB, layer 4) | < 1 ms | keep the NLB; never the 10 Mbps flexible LB |
| Caddy proxy | ≈ 1 ms | keep-alive to the gateway; static files straight from disk |
| Gateway work per message | < 1 ms when not overloaded | stay below ~60 % CPU (section 3); no database call on the hot path |
| Fan-out to the group | ≈ 1-10 ms | per-group batching, priority lane for alerts |
| Database (ORDS over HTTPS) | 10-60 ms per call | never on the position path; SOS written once, in parallel with the fan-out start |

The slowest thing we control is **a busy CPU**: once a node passes ~70 % CPU, queueing makes p99 grow fast. The plan
therefore keeps every live node under **60 % CPU at peak** and adds capacity before that, not after.

## 3. The rule that decides capacity: what survives a failover

A live node is only "safe" up to the number of riders **its standby can take if it dies**. Today vm1 (live) fails
over to vm2 (a 1 GB micro, ≈ 2,500 riders at most). So even with a big Ampere server as the live node, **the safe
capacity is the smaller of the pair** unless the standby is just as big.

| Pair (live + standby) | Safe riders (N+1) |
|---|---|
| vm1 micro + vm2 micro (today) | ≈ 600 sustained, short peaks to ≈ 2,500 |
| A1 2 OCPU + vm2 micro | ≈ 2,500 (the micro limits it) |
| A1 2 OCPU + A1 2 OCPU | ≈ 6,000-7,000 |
| two A1 pairs, groups split between them | ≈ 12,000-14,000 |

Numbers come from the v3.56 load tests (≈ 0.016 % of a core per rider at the app's cadence, gateway + Caddy) with
40 % headroom. They must be re-measured on the real Ampere server before relying on them (section 13).

## 4. Target architecture

```
Phones / browsers
   │  one WebSocket per riding phone (rides, SOS, voice) + HTTPS (API, website)
   ▼
OCI Network Load Balancer (layer 4, health check every 5 s)
   │
   ├─► LIVE tier  (rides, SOS, positions, voice relay)       ── stateful, in memory, mirrored in pairs
   │      live pair A: A1 (account 1) ⇄ A1 (account 2, via local peering)
   │      live pair B: added at stage 4; groups assigned by groupId (consistent hash)
   │
   ├─► WEB/API tier (website, admin, payments, sign-in)       ── stateless, any node can answer
   │      vm2 (+ vm1 once live moves to the A1)
   │
   ├─► WORKER tier (emails, push fan-out, ride maps, photos, road data, analytics, backups)
   │      pull jobs from a queue by their own capacity; never on live nodes
   │
   ▼
Data: Autonomous DB (system of record) · in-memory ride state (live tier, mirrored) · Object Storage (photos, backups)
Static website files: Caddy from disk (optionally a free CDN in front, section 11)
```

Design rules:

1. **Live work is separated from everything else.** A burst of sign-ins, an email campaign or a nightly report must
   never take CPU from a live node. Web and workers run elsewhere.
2. **Ride state lives in memory**, mirrored to a twin node. The database is written for durable events (SOS, alerts,
   chat, ride summaries) and snapshots, never per position.
3. **Every live node has a twin of the same size** (section 3).
4. **Groups are the unit of scale.** All riders of one group are on the same live pair, so a group's fan-out never
   crosses servers. More groups -> more pairs.
5. **Safety traffic has its own lane everywhere**: socket priority, an HTTP fallback route, never shed, never queued
   behind positions or voice.

## 5. Growth stages

Move to the next stage when **any** trigger fires for 3 days at peak, or before an event you expect to be big.

| Stage | Riders at once (safe) | Setup | Trigger to move on | Cost |
|---|---|---|---|---|
| **0 (today)** | ≈ 600 | vm1 live + vm2 web/mirror, micros | > 400 riders at peak, CPU > 60 %, lag p99 > 100 ms | €0 |
| **1** | ≈ 2,500 | **A1 in account 1 = live**, vm2 = web + mirror, vm1 = web; workers on vm5 | > 2,000 riders, or voice egress > 3 TB/month | €0 |
| **2** | ≈ 6,000 | **A1 (account 2, vm5) becomes the live twin** over cross-account local peering (same region, free); workers move to the account 3 A1 if that account is legitimate (otherwise a small paid A1) | > 5,000 riders, DB > 300 calls/s | €0-low |
| **3** | ≈ 6,000, DB relieved | **paid Autonomous DB tier** or move hot reads to the in-memory store with an append log; keep backups as now | DB CPU > 70 % or sessions exhausted | paid DB |
| **4** | ≈ 12,000+ | **second live pair** (paid Ampere), groups assigned by consistent hash of groupId in Caddy; join codes carry the shard | each pair > 70 % | paid compute |

Notes:
- Stage 1 alone fixes today's biggest weakness: vm1 has only 1/8 of a core sustained.
- Stage 2 needs the local peering between account 1 and account 2 checked in the console first (the NLB must reach
  the account 2 server as a backend). If that does not work, the twin must be a second A1 in account 1, which needs
  paid Ampere hours beyond the free 2 OCPU.
- Paid Ampere and Autonomous DB prices change; check the current OCI price list before stage 3-4.

## 6. Realtime path (positions, alerts, chat)

Already done in v3.56/round 7: per-rider throttle (800 ms), batched `RIDER_UPDATES` frames, alert lane, stale
positions dropped first under backpressure, alert frames handled before positions on the phone, cached account checks.

Next:

| Item | Why | Effect |
|---|---|---|
| **Adaptive send rate on the phone**: every 1 s above 60 km/h, 2.5 s in town, 10 s when stopped | today a fixed 2.5 s; stopped bikes send for nothing | ≈ 30-50 % fewer messages |
| **Compact position frames** (short keys or a small binary format, deltas against the last fix) | JSON per fix is ~150-250 bytes | ≈ 60 % less bandwidth and CPU for parsing |
| **Interest management for big public rides**: riders get full-rate updates for the nearest 20 and the lead/sweep, reduced rate for the rest | a 100-rider ride is O(n²) frames | keeps big rides flat |
| **Message size and rate caps per socket** (already 256 KB max frame): add per-socket message rate limits | protects against a broken or hostile client | no single phone can slow a node |
| **Reconnect storm control**: keep the full-jitter backoff; server answers `RECONNECT` with a spread-out delay after a failover | 6,000 phones reconnecting in the same second | smooth failover |
| **Group placement** (stage 4): Caddy routes `/ws?g=<groupId>` by consistent hash to the right pair | groups never cross servers | linear scaling |

## 7. Voice (the biggest load risk today)

Finding: the intercom sends **raw PCM16 audio (16 kHz mono ≈ 32 KB/s, 8 kHz in data saver)** through the gateway to
every listener (`lib/data/services/intercom_service.dart`). One person talking to a group of 10 costs ≈ 1 GB per hour
of egress and real CPU on the live node, and it shares the live node with SOS.

| Step | What | Effect |
|---|---|---|
| 1 | **Opus codec** at 16-24 kbit/s (2-3 KB/s) on the phone (Android has a built-in Opus encoder/decoder via MediaCodec since Android 10; older phones keep PCM) | ≈ 90 % less voice traffic, same or better quality, lower latency |
| 2 | **Voice off the live node**: a separate voice relay process (or node) at stage 1-2, so voice can never slow an SOS | safety isolation |
| 3 | At scale: a self-hosted **SFU** (LiveKit, Apache-2.0, or mediasoup, ISC) on an Ampere server with **WebRTC** (UDP, built-in jitter buffer, echo cancellation), plus coturn (BSD) for phones behind strict NATs | ≈ 150-300 ms mouth-to-ear, scales to many groups |

Voice keeps its current rules: never recorded, group-only.

## 8. Database

The free Autonomous DB has **1 OCPU, 20 GB and 20 simultaneous sessions**. After v3.56 a live rider costs
≈ 0.035 database calls/s; 6,000 riders ≈ 210 calls/s.

1. **Hot path stays off the database** (positions, typing, presence): keep it that way in every new feature
   (code review rule + a test that counts DB calls per position).
2. **Write-behind batching** for non-critical writes (ride track points, counters), already partly in place; extend
   to every write that is not an SOS/alert/payment.
3. **Caches with short TTLs** for read-mostly data (capabilities, feature switches, plans, road cells), already in
   place; add a per-node LRU for profiles shown in rides.
4. **Connection budget** per node (`ORACLE_MAX_INFLIGHT`, 10 on micros): SOS, alerts, sessions and leases bypass it.
5. **Second free database** (account 2): disaster recovery copy restored nightly; **never** split live data across
   two databases without a design for it.
6. Stage 3: when DB CPU > 70 % or sessions run out, move to a paid Autonomous DB tier (more OCPU, more sessions) -
   the cheapest real fix at that point.

## 9. SOS under heavy load (must hold at every stage)

| Rule | Status |
|---|---|
| SOS sent at once with the last known position, before any other work on the phone | done (round 7) |
| Sent over the socket AND an HTTP route in parallel, de-duplicated by clientId | done (round 7) |
| Server stores the SOS, then fans out; acknowledgement only after storage | done |
| SOS never shed by the load shedder, never behind positions or voice | done |
| Phone texts emergency contacts from its own SIM even if every server is down | done |
| `LIVE_RIDER_CAP` refuses NEW ride joins before a node runs out of memory; riders already in a ride are never cut off | done (set the value per stage) |
| **New:** a dedicated SOS worker queue on the twin node, so an SOS fan-out continues even if the live node is mid-crash | **built (round 8)**: "SOS pending delivery" record replicated before the store and fan-out; the twin delivers it if the link dies first |
| **New:** watchdog sends a test SOS on staging every 15 min and alerts if delivery > 1 s | **built (round 8)**: `deploy/watchdog/sos_probe.js`, off until `WATCH_SOS_PROBE=1` and the staging probe accounts exist |

## 10. Security under heavy load

| Threat | Protection |
|---|---|
| Flood of connections (DDoS, broken app loop) | per-IP connection limits and per-socket message rate limits at the gateway; Caddy timeouts against slow connections; OCI's built-in network protection; optional free CDN for the website only (section 11) |
| Sign-in brute force | existing account lock + progressive delays + per-IP limits; password hashing is deliberately slow, so sign-ins run on the web tier, never the live tier |
| Expensive endpoints abused | load shedder for non-essential reads (done); rate limits per user and per IP on search, road data, exports |
| Data in transit | TLS 1.3 everywhere public; mirror link AES-256-GCM over the private network; cross-account links over TLS with IP allowlists |
| Secrets | Vault -> memory-only folder (done); separate keys per stage and per account; staging never holds production keys |
| A compromised worker | workers get only the database rights and secrets their jobs need; no worker on a live node |
| Noisy failure during a release | release order staging -> web -> live with automatic rollback (done) |

## 11. App-side speed (perceived latency)

Done in round 7: instant safety screens, skeleton loaders, cached data shown at once, parallel start-up, optimistic
actions. Next:

- **One persistent connection** for everything while riding (no polling); HTTP/2 keep-alive for API calls.
- **Prefetch** what the next screen needs (route corridor, group members, road cells) at ride start.
- **Website**: static files already served by Caddy with long cache times and pre-compression. Optional: put the
  **website only** behind a free CDN (e.g. Cloudflare's free plan) for faster first loads across India and DDoS
  absorption; keep `/ws` and `/api` going straight to the NLB so ride traffic never depends on a third party.

## 12. Observability and alerts

| Signal | Alert when | Action |
|---|---|---|
| Live node CPU | > 60 % for 10 min at peak | next stage (section 5) |
| Event-loop lag p99 | > 100 ms for 5 min | find the hot path; shed non-essential |
| Position fan-out p99 | > 250 ms | check CPU, batching, voice load |
| SOS test delivery | > 1 s or failed | page the owner immediately |
| DB calls/s, queue length | > 300/s, queue > 0 for minutes | caches / stage 3 |
| WebSocket count per node | > 80 % of `LIVE_RIDER_CAP` | scale or raise the cap after a test |
| Egress per month | > 6 TB of 10 TB free | voice step 1-2 |

All read from the existing `/metrics` and the admin Servers page; alerts by the vm3 watchdog over SMTP. No paid tools.

## 13. Testing before each stage (gate)

1. **Load test on staging** with `ws_load.js` at **2x the stage's target riders** for 30 min: SOS p99 < 150 ms,
   position p99 < 250 ms, CPU < 60 % at 1x.
2. **Soak test**: 1x target for 24 h: no memory growth, no lag growth.
3. **Failover drill under load**: kill the live node at 1x target: all riders back within 10 s, every SOS delivered,
   nothing duplicated.
4. **Voice test**: 20 groups with one continuous speaker each: SOS latency unchanged.
5. **Database test**: stop the database for 5 min during load: rides and SOS continue in memory, no mass sign-out.
6. **Security test**: connection flood from one IP and one account: limits kick in, other riders unaffected.

Results go in `docs/infra/` with the date; a stage is only "live" after its gate passes.

## 14. Work items (in order)

| # | Item | Where | Size | Status |
|---|---|---|---|---|
| 1 | Provision the A1 in account 1; make it the live node (stage 1); vm1 -> web | ops | 1 day | **ready to run (round 8)**: `gateway/deploy/stage1_live_a1.sh` + RUNBOOK "Stage 1"; `host/apply.sh --role live-a1` |
| 2 | Opus voice (phones on Android 10+), PCM fallback | app + gateway | 1-2 weeks | round 8 voice agent (see its notes) |
| 3 | Voice relay as its own process/node | gateway + ops | 1 week | round 8 voice agent (see its notes) |
| 4 | Adaptive position rate + compact frames (versioned, old apps keep JSON) | app + gateway | 1 week | **built (round 8)**: app adaptive rate + `pos2` (P2 / RU2), old apps keep JSON; device QA open |
| 5 | Per-socket message rate limits, per-IP connection limits | gateway | 2-3 days | **built (round 8)**: per-IP / per-user / per-socket limits, JOIN flood, schema, timeouts, metrics; SOS exempt |
| 6 | Worker tier with a capacity-pull job queue (emails, push, ride maps, photos, road data, analytics) | gateway | 1-2 weeks · **built in round 8** (off by default; rollout in `docs/quality/ROUND8_JOBS_NOTES.md`) | built (round 8, off by default) |
| 7 | SOS test probe every 15 min + alert; SOS fan-out continuation on the twin | gateway + watchdog | 3-4 days | **built (round 8)**: `deploy/watchdog/sos_probe.js` (staging) + SOS pending record drained by the twin |
| 8 | Cross-account local peering check; A1 twin (stage 2) | ops | 2-3 days | open (ops) |
| 9 | Interest management for big public rides | gateway + app | 1 week | **built (round 8)**: gateway side (`src/interest.js`); the app needs no change |
| 10 | Consistent-hash group placement + second live pair (stage 4, only when needed) | gateway + Caddy | 2 weeks | **prepared, off (round 8)**: `src/shards.js`, `deploy/gen_caddy_shards.js`, `GET /api/shard`; second pair not built |
| 11 | Re-run section 13 gates on the real Ampere hardware; update numbers in this document | ops | 1 day per stage | open: local numbers in `docs/quality/ROUND8_REALTIME_NOTES.md`; real A1 pending |

**Item 6 status (round 8, 13 Nov 2026):** built in `gateway/src/jobs/` with `gateway/worker.js` and
`deploy/worker/coroute-worker.service`. Queue = SODA collection `job_queue` (compare-and-replace claim, leases,
backoff with jitter, dead letters, idempotent enqueue); workers pull by measured capacity (event-loop lag, load per
core, free memory, `ORACLE_MAX_INFLIGHT`). Migrated: all e-mails (security codes at priority 0 with a 10 s inline
fallback), push fan-out, ride summary pictures, photo clean-up, road cell fetches, nightly / campaign batches (lease
keeps the schedule). SOS and alert paths are unchanged. Switch: `JOBS_QUEUE=on`; rollout in-process first, then a
separate worker on vm2 / vm5, then `JOBS_SEPARATE_WORKER=on` on the live node. Design: `docs/features_355/job_queue.md`.

**Round 8 realtime status (13 Nov 2026):** items 1 (tooling), 4, 5, 7, 9 built and 10 prepared; files, settings, measured
numbers and device checks in `docs/quality/ROUND8_REALTIME_NOTES.md`. Measured locally (2-core test machine, in-memory
gateway): pos2 cuts bytes to phones by ~81 % and from phones by ~69 % at the same CPU; interest management halves the
position entries in a 60-rider room; every gate preset passed at 1,000-2,000 riders. Real A1 numbers are still owed (item 11).

Items 1, 5 and 7 are the most valuable first: they fix today's CPU limit, protect against abuse, and prove SOS speed
continuously.

## 15. Owner decisions

1. Provision the Ampere server in account 1 now (stage 1) - recommended.
2. Is the third Oracle account in a different real person's name with their own details? Only then use it
   (workers / second free database). Oracle allows one free account per person.
3. Opus voice for Android 10+ phones (older phones keep today's audio) - recommended.
4. Optional free CDN in front of the website only (not rides) - yes/no.
5. Budget ceiling for stage 3-4 (paid database and paid Ampere hours) when traffic justifies it.
6. Target service levels in section 1 - confirm or adjust.
