# Round 8 realtime notes (CoRoute 3.55.0+10027, 13 Nov 2026)

Scope: `docs/infra/HIGH_TRAFFIC_PLAN_v3.57.md` items 1 (ops tooling), 4, 5, 7, 9, 10 (prepared) and the section 13
gates. Owner direction: "go with it", safe, secure, very low latency. Build number unchanged. Nothing here weakens or
delays an SOS: SOS and alert frames are exempt from every new limit, never compacted, and gain a second delivery path
(the twin).

## 1. What was built

| # | Item | Where | State |
|---|---|---|---|
| 5 | Abuse limits: per-IP concurrent and per-minute sockets (HTTP 429 at the upgrade), per-account connect rate, per-socket token buckets by class with a `RATE_LIMIT` warning frame then close 4429, JOIN flood close, schema / size check on every inbound type, idle and slow-reader timeouts, a metric per limit. SOS / alerts exempt; SOS budget floor 10 per 10 s and an SOS above it answered with the open alert (never an error). | `gateway/src/ws_limits.js`, `gateway/src/ws.js` | on by default |
| 4 | Adaptive position rate on the phone (1 s > 60 km/h, 2.5 s town, 5 s slow, 10 s stopped, 30 s parked; at once on a sharp turn / stop, moving off, own SOS, becoming lead / sweeper; data saver / battery rules kept). Compact frames `pos2`: P2 from the phone, RU2 batches to phones that announce the cap; versioned through HELLO.features, old apps keep JSON. | `lib/domain/tracking/adaptive_position_rate.dart`, `lib/data/services/pos2_codec.dart`, `realtime_service.dart`, `convoy_service.dart`, `gateway/src/pos2.js` | on (app + gateway) |
| 9 | Interest management in rooms above 30 sockets: nearest 20 + lead / sweeper / owner + anyone in alert at full rate, everyone else every 5 s; alerts always reach everyone. | `gateway/src/interest.js`, `ws.js _flushInterest` | on |
| 7a | Synthetic SOS probe every 15 min on STAGING between two dedicated test accounts; mail when > 1 s or failed, hourly while bad, recovery mail, daily summary line, status file. Refuses non-staging hosts and any group with other riders. | `gateway/deploy/watchdog/sos_probe.js`, `coroute_watchdog.js` | off until `WATCH_SOS_PROBE=1` |
| 7b | SOS fan-out continuation: an "SOS pending delivery" record (mirror `SP`, lane 0) goes to the twin before the live node stores and fans out a new alert; if the link dies first, the twin stores it if needed, delivers it to its sockets (and SNAPSHOTs) and starts the safety network / SMS round. | `gateway/src/mirror.js`, `gateway/src/convoys.js _storeAlert` | on with the mirror |
| 10 | Shard-ready placement (prepared, off): consistent (rendezvous) hash group id -> pair over 256 buckets, Caddy matcher generator for `/ws?g=`, convoy paths and `?shard=`, join-code lookup `GET /api/shard`. | `gateway/src/shards.js`, `gateway/deploy/gen_caddy_shards.js` | `SHARDS=1` = off |
| 1 | Stage 1 ops: guided script (A1 = live, NLB switch order, vm1 -> web), `host/apply.sh --role live-a1` (ARM 2 OCPU / 12 GB: heap 2048 MB, MemoryHigh 4 GB, MemoryMax 5 GB, `LIVE_RIDER_CAP` 2500 with the micro twin), RUNBOOK section, 4/24 corrected to 2/12 in docs/infra and the RUNBOOK. | `gateway/deploy/stage1_live_a1.sh`, `deploy/host/apply.sh`, RUNBOOK | ready to run |
| gates | `ws_load.js` presets `gate2x`, `soak`, `failover` (local drop or `--failover-cmd`), `flood` (one IP + one account), `--pos2`, app-like reconnect and SOS resend, PASS / FAIL summary, `--gate` exit code. | `gateway/tool/load/ws_load.js` | |

## 2. Files

New: `gateway/src/ws_limits.js`, `gateway/src/pos2.js`, `gateway/src/interest.js`, `gateway/src/shards.js`,
`gateway/deploy/gen_caddy_shards.js`, `gateway/deploy/stage1_live_a1.sh`, `gateway/deploy/watchdog/sos_probe.js`,
`lib/domain/tracking/adaptive_position_rate.dart`, `lib/data/services/pos2_codec.dart`,
tests `gateway/test/rt8_limits.test.js`, `rt8_pos2.test.js`, `rt8_interest.test.js`, `rt8_sos_continuation.test.js`,
`rt8_shards.test.js`, `rt8_sos_probe.test.js`, `test/rt8_adaptive_position_rate_test.dart`, `test/rt8_pos2_codec_test.dart`.

Changed: `gateway/src/ws.js` (limits, P2 in, RU2 / interest fan-out; the voice blocks untouched), `gateway/src/mirror.js`
(SP record, drain), `gateway/src/convoys.js` (one hook in `_storeAlert`), `gateway/src/app.js` (one line: shard router),
`gateway/deploy/route_split.md` (+1 WEB row), `gateway/deploy/.env.example`, `gateway/deploy/watchdog/coroute_watchdog.js`
and `watchdog.example.env`, `gateway/deploy/host/apply.sh`, `gateway/tool/load/ws_load.js` and `README.md`,
`gateway/deploy/RUNBOOK.md`, `docs/infra/HIGH_TRAFFIC_PLAN_v3.57.md` (status column, section 9 rows),
`docs/infra/INFRASTRUCTURE_PLAN_v3.56.md` and `CoRoute_Infrastructure_v3.56.html` (2 OCPU / 12 GB),
`lib/data/services/realtime_service.dart` and `convoy_service.dart` (rate / frames only),
`gateway/test/outbox.test.js` (one test: the old "4th SOS in 10 s gets 429" contract is replaced by the SOS floor).

## 3. Settings (all in `gateway/deploy/.env.example`)

| Variable | Default | Meaning |
|---|---|---|
| `WS_MAX_CONN_PER_IP` | 50 | open sockets per client IP (0 = off); over it HTTP 429 + Retry-After at the upgrade |
| `WS_CONN_PER_MIN_PER_IP` | 120 | new sockets per minute per IP |
| `WS_CONN_PER_MIN_PER_USER` | 30 | new sockets per minute per account (close 4429 `TOO_MANY_CONNECTS`) |
| `WS_RL_POS` / `WS_RL_CHAT` / `WS_RL_JOIN` / `WS_RL_PING` / `WS_RL_OTHER` | 5/20, 2/10, 0.2/6, 1/10, 10/40 | per-socket buckets "rate per second / burst" |
| `WS_RL_KICK_DROPS` | 60 | drops per 10 s before close 4429 `RATE_LIMIT_<CLASS>` |
| `WS_JOIN_FAIL_MAX` | 8 | refused JOINs per minute before close 4429 `JOIN_FLOOD` |
| `WS_SOS_FLOOR_PER_10S` | 10 | the per-socket SOS budget never goes below this |
| `WS_IDLE_MS` | 7200000 | socket outside a ride with no inbound message: close 4408 (0 = off) |
| `WS_SLOW_READER_MS` | 60000 | send buffer above `WS_OUT_SOFT_BYTES` this long: close 1013 |
| `WS_POS2` | on | advertise `pos2` |
| `WS_INTEREST`, `WS_INTEREST_ABOVE`, `WS_INTEREST_NEAR_K`, `WS_INTEREST_FAR_MS`, `WS_INTEREST_RECOMPUTE_MS` | on, 30, 20, 5000, 2000 | interest management |
| `MIRROR_SOS_PENDING_TTL_MS` | 600000 | an announced SOS not delivered within this while the link is up is forgotten |
| `SHARDS`, `SHARD_PAIRS`, `SHARD_SELF` | 1, a,b,..., first | stage 4 placement (prepared; 1 = off) |
| watchdog `WATCH_SOS_PROBE*` | off | `watchdog.example.env`; password from the secrets file |

## 4. Routes

| Route | Class | Notes |
|---|---|---|
| `GET /api/shard?g=<groupId>` / `?code=<join code>` | WEB (`route_split.md`) | signed in; `{ shard, shards, self, here }`; never returns a group id for a code; wrong codes limited per account and per IP like wrong join codes |

## 5. Wire protocol additions (versioned; older apps see none of it)

* HELLO.features gains `pos2`. Phone -> gateway `{ "t":"P2", "q", "a":lat*1e5, "o":lng*1e5, "v":dm/s, "h":deg, "b", "c"?,
  "sr"?, "sm"?, "ss":s stopped?, "fu":[km, confirmedAt s]?, "fl"? }` (optional delta form `k`/`da`/`do` accepted; the
  app sends full fixes because deltas save nothing in JSON). Gateway -> phone (cap `pos2` in JOIN):
  `{ "type":"RU2", "ts", "r":[{ "u", "a", "o", "v", "h", "b", "c"?, "sr"?, "sm"?, "ss"?, "t":last seen (server ms), "fu"?, "fl"? }] }`.
  The app merges RU2 entries into the riders it knows (SNAPSHOT / full updates) and hands them on as RIDER_UPDATE.
* `{ "type":"RATE_LIMIT", "class", "retryMs" }` warning (at most every 5 s per class); old apps ignore it.
* Close codes: 4429 `RATE_LIMIT_<CLASS>` / `JOIN_FLOOD` / `TOO_MANY_CONNECTS`, 4400 `INVALID_FRAMES`, 4408 `IDLE_TIMEOUT`,
  1013 `SLOW_LINK`. The app reconnects on all of them (only 4403 / 4401 change its behaviour, unchanged).
* Mirror: `SP` (SOS pending delivery), inside the existing encrypted link.

## 6. Results (this machine: 2 cores, 8 GB; in-memory gateway forked by `ws_load.js`, generator on the other core)

Frame sizes: RIDER_UPDATE 698 B -> RU2 entry ~85 B (one-rider RU2 frame ~125 B); app TELEMETRY 241 B -> P2 65 B.

**Before / after (same build, legacy JSON vs pos2):**

| Run | CPU (one core) | lag p99 | to phones | from phones | bytes per position received | pos p99 | SOS p99, delivered |
|---|---|---|---|---|---|---|---|
| 2000 riders x 8, 1 Hz, JSON (old apps) | 36.3 % | 10.7 ms | 9,258 KB/s | 478 KB/s | 701 | 10 ms | 10 ms, 98/98 |
| 2000 riders x 8, 1 Hz, pos2 (new apps) | 37.6 % | 4.3 ms | **1,744 KB/s (-81 %)** | **149 KB/s (-69 %)** | 132 | 6 ms | 34 ms, 98/98 |

CPU stays the same: at this size the gateway's cost is per frame (syscalls, WebSocket framing, TLS on the real node), not
JSON size; the win is bandwidth (egress, phone data, radio time) and phone-side parsing. The plan's "60 % less CPU" did
not materialise locally; the adaptive rate (fewer frames) is what lowers CPU.

**Interest management (600 riders in 10 rooms of 60, 1 Hz):**

| Run | CPU | positions delivered / s | to phones | pos p50 / p99 | SOS p99 |
|---|---|---|---|---|---|
| JSON, interest off | 14.3 % | 34,212 | 21,884 KB/s | 260 / 507 ms | 12 ms, 826/826 |
| JSON, interest on | 15.8 % | **17,815 (-48 %)** | 11,472 KB/s | 310 / 978 ms (far riders 5 s by design) | 8 ms, 826/826 |
| pos2, interest off | 13.6 % | 34,220 | 3,218 KB/s | 260 / 502 ms | 11 ms, 826/826 |
| pos2, interest on | 15.2 % | 17,824 | **1,744 KB/s (-92 % vs JSON off)** | 310 / 979 ms | 7 ms, 826/826 |

Rooms above 20 already flush every 500 ms (v3.56), so big-room position p99 is ~500 ms by design; interest management
halves what each phone receives at +1-1.5 CPU points (per-socket frames instead of one shared frame).

**Adaptive rate (pure rule, `test/rt8_adaptive_position_rate_test.dart`):** a 10 min mix (3 highway, 4 town, 1 slow, 2
stopped) sends ~300 positions; the 3.55 cadence (1 / 1.5 / 2 s by band, 30 s parked) ~330; the plan's "fixed 2.5 s"
baseline 240 (highway at 1 s costs more on purpose). The large saving is at stops (10 s instead of a fix every
GPS update when the rider was "moving" at walking pace) and in data saver.

**Gates (`--preset`, pos2, group size 8):**

| Preset | Riders | Result |
|---|---|---|
| `gate2x --target-riders 1000` (120 s) | 2000 | PASS: SOS p99 88 ms (p50 3), positions p99 3 ms, 413/413 SOS, CPU 25 %, lag p99 3.5 ms |
| `failover --target-riders 1000` (60 s, all sockets dropped at 30 s) | 1000 | PASS: 1000/1000 back within 10 s (p50 1.5 s, p99 2.7 s), 210/210 SOS (6 pressed into the drop, delivered after reconnect, p99 2.4 s) |
| `flood --target-riders 1000` (40 s) | 1000 + flood | PASS: 150 of 200 upgrades from one IP refused 429, chat flooder closed 4429 after 61 drops, no regular socket closed, SOS 140/140 p99 5 ms |
| `soak --target-riders 1000` (300 s, sampled every 30 s) | 1000 | PASS: heap 38.8 -> 39.8 MB after warm-up (+1 MB), RSS 147 -> 160 MB, 1043/1043 SOS p99 29 ms, positions p99 3 ms, CPU 15 % (a 24 h soak is the staging gate) |

Local numbers are a regression gate, not capacity: the real stage gates run on staging / the A1 (plan item 11). The load
tool found and fixed two of its own gaps (no SOS resend after a drop, SNAPSHOT alerts not counted) and one gateway
counting bug (frames buffered behind a kick were re-counted as kicks).

## 7. Tests

* Gateway: `node --test test/rt8_*.test.js` (6 files, 33 tests): limits (per IP 429, per user, chat flood -> warning ->
  4429, JOIN flood, invalid frames, idle / slow timeouts, metrics), **SOS never limited** (25 presses after every bucket is
  spent: no error, no close, every press answered; a 60 KB SOS passes the schema check; the floor), pos2 codec + old /
  new apps in one room + batches, interest management with an SOS lifting a far rider to full rate, SOS continuation on
  the twin (crash after the store, crash before the store, normal path never delivers twice), shard hash stability
  (pinned values) / consistency / Caddy matchers / lookup route, probe logic with a fake clock + one real probe run.
* App (pure Dart, `tool/pure_dart_test/run.sh`): `test/rt8_adaptive_position_rate_test.dart` (11),
  `test/rt8_pos2_codec_test.dart` (5).
* Full `npm test`: 1434 tests, 1430 pass on the single run; the 4 failures were fixed and pass alone (net_compat HELLO
  list, rider_patch: the TELEMETRY size cap was raised to the 16 KB default so junk fields are coerced as before,
  two_node_failover "durable SOS" expectation, "hand-back" timing-only, passes alone). Baseline was 1355.
* `dart analyze lib test`: clean. `dart tool/play_policy_scan.dart`: 0 hits.

## 8. Requests (shared files / other owners)

1. **Agent V (voice):** voice binary frames are not counted by the new per-socket buckets (your `VOICE_MAX_FPS` stays the
   limit); your new JSON types (e.g. voice caps) fall in class `other` (10/s, burst 40). If the voice relay moves to its
   own process, SOS / alert frames must stay on the main socket path (they are exempt here).
2. **Agent J (jobs) / business owner:** the admin Servers page cannot show the SOS probe yet: the watchdog runs on vm3 /
   vm4 without production database access. Proposal: a tiny `POST /api/ops/status` (Bearer `METRICS_TOKEN`) that writes
   `ops_status { kind: 'sos_probe', at, runs, fails, p50Ms, p95Ms, maxMs, last }` (the probe already writes exactly this
   JSON to `WATCH_SOS_PROBE_STATUS`), shown by `src/business/servers.js`. Also: `host/apply.sh --role live-a1` (new) should
   print your `JOBS_SEPARATE_WORKER=on` hint like `realtime`.
3. **App constants owner:** `NetworkConstants.clientCaps` can gain `pos2` later; today `realtime_service.dart` adds it to
   JOIN only when the gateway advertises it. Stage 4 app work (not built): open `/ws?g=<groupId>` for a ride and resolve a
   join code with `GET /api/shard?code=` before joining.
4. **Owner / ops:** create the two staging probe accounts and the `SOS probe staging` group (RUNBOOK "SOS probe"); run
   `stage1_live_a1.sh` when the A1 exists; set the NLB health check as in the RUNBOOK; run the gates on staging and record
   them in `docs/infra/` (plan item 11). Confirm Caddy keeps its read / idle timeouts on the public site (slow
   connections before the upgrade are Caddy's to cut; after the upgrade the gateway's limits apply).
5. **Shared test changed:** `gateway/test/outbox.test.js` "CHECK_IN has its own budget": the 11th SOS in 10 s now gets the
   open alert back instead of ERROR 429 (task rule: SOS never rate-limited below a generous floor).
6. **Other shared tests updated:** `test/net_compat.test.js` (HELLO list ends `pos2`, `voice2`, at Agent V's request);
   `test/two_node_failover.test.js` "durable SOS" (the twin now delivers the SOS from the pending record, so the lead
   finds it in its SNAPSHOT instead of hearing it only on the phone's resend; still exactly one alert).

## 9. Device QA (T-items)

| # | Check | Pass when |
|---|---|---|
| T1 | New app + a 3.55 build in the same ride | both see each other's markers move; names, bikes, roles right on both; last-seen ages right |
| T2 | Adaptive rate on the road (diag log `telemetry` or a second phone watching) | ~1 s on a highway, ~2.5 s in town, ~5 s at walking pace, ~10 s stopped, 30 s parked |
| T3 | Sharp turn, hard stop, moving off | the group's marker updates at once (within ~1 s) |
| T4 | Raise an SOS while riding | own position every second to the group while the SOS is open; alert at once on every phone |
| T5 | Lead / sweeper | their markers never slower than 2.5 s while moving |
| T6 | Data saver and battery saver | cadence doubles (never while the group has an alert) |
| T7 | 20+ phones on one office Wi-Fi / one carrier | all connect (per-IP limit 50); no `RATE_LIMIT`, 4429 or 4408 in a normal ride's diag log |
| T8 | Big ride (30+ phones, or 4 phones with `WS_INTEREST_ABOVE=3` on staging) | far riders move every ~5 s, near ones and the lead at full rate; a far rider's SOS reaches all at once and that rider is then full rate |
| T9 | Failover drill on staging during an SOS | the SOS reaches every phone exactly once; phones back in the ride within 10 s |
| T10 | SOS probe on staging | probe mails arrive for a forced slow / failed run, recovery mail, summary line next morning |
| T11 | Home screen idle for 2 h+ | the app reconnects after the 4408 close; personal notices still arrive |
| T12 | One-hour ride, data used vs the 3.55 build | clearly lower mobile data with pos2 |
