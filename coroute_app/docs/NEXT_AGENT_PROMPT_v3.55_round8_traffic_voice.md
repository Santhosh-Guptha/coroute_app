# CoRoute round 8: heavy traffic, clear voice, background workers (build 3.55.0+10027)

Builds on round 7 (also 3.55.0+10027, not yet released). Rounds 7 and 8 ship together as app build 3.55.0+10027 and
one gateway release. Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Rounds 4-6 are committed as build 3.55.0+10026. Rounds 7 and 8 are in the working tree,
uncommitted: ship them together as build 3.55.0+10027.
Use docs/NEXT_AGENT_PROMPT_v3.55_round7_speed_curves_home.md for round 7 and the round 6 prompt for the rules,
staging gate, deploy flow and safety gate. This prompt adds round 8. Report after each section. STOP at any failed
safety gate.

=== 0. RULES ===
- Same rules as rounds 6-7: no secrets or real IPs in git; never weaken SOS, crash detection, emergency texts,
  Medical ID, ride lock, lock-screen cockpit; policy scan 0 hits; fix code, not tests, unless a text changed on purpose.
- Read first: docs/infra/HIGH_TRAFFIC_PLAN_v3.57.md (the plan; status column per item), docs/quality/ROUND8_VOICE_NOTES.md,
  docs/quality/ROUND8_REALTIME_NOTES.md, docs/quality/ROUND8_JOBS_NOTES.md, docs/features_355/voice_clarity.md,
  docs/features_355/job_queue.md.
- If round 8 files are missing from the working tree, unpack coroute_v3.57_round8_files.zip with its R8_BASE_MD5.txt
  rule (repo md5 equal -> zip copy; different -> merge by hand; NONE -> new file). Do not commit R8_BASE_MD5.txt.

=== 1. WHAT IS NEW IN ROUND 8 ===
VOICE (app + gateway)
 - RNNoise noise suppression (BSD-3, Xiph; vendored C in android/app/src/main/cpp with CMake, called from Dart via
   dart:ffi) plus a 120 Hz high-pass and a wind-gust ducker. Lab results at 0 dB noise: highway mix clarity 0.87 -> 0.89
   (old cleanup: 0.71), engine +7.8 dB SNR; 25-38 dB less noise between words; 12.5 ms added delay. Falls back to the
   old Dart cleanup if the native library is missing. Siren detection keeps its own raw microphone path.
 - Intercom options: Noise reduction Strong (default) / Normal / Off, Wind-noise mode.
 - Opus codec (MediaCodec; encoder Android 10+, decoder Android 5+), 20 ms frames, adaptive jitter buffer 40-120 ms,
   loss concealment. Negotiated with VOICE_CAPS / VOICE_CODEC; if any old build is in the group everyone sends PCM.
 - Voice relay moved to gateway/src/voice_relay.js; voice is the LOWEST priority on a socket (dropped above 16 KB
   unsent; never ahead of an SOS); per-speaker caps, 20 s floor-hold fairness (lead and sweep exempt).
   VOICE_RELAY_MODE=process runs it as a separate process on /voice (Caddy snippet deploy/caddy/voice_relay.caddy).
 - Licences: Profile > Help > Privacy & terms > "Open-source licences" lists RNNoise (lib/core/native_licenses.dart).
REALTIME (gateway + app)
 - Abuse limits (gateway/src/ws_limits.js): 50 sockets and 120 new sockets/min per IP, 30 new sockets/min per account,
   per-socket rate budgets per message type, join-flood, size/schema checks, idle and slow-reader closes.
   SOS is never limited (floor of 10 per 10 s per socket; beyond that the open alert is returned, never an error).
 - Adaptive position rate on the phone (about 1 s above 60 km/h, 2.5 s town, 5 s slow, 10 s stopped, 30 s parked;
   immediate on sharp turns/stops, SOS, lead/sweep change) and compact 'pos2' frames for apps that announce it
   (-81 % data to phones, -69 % from phones in the local test; CPU about the same).
 - Interest management for rides above 30 riders: nearest 20 + lead/sweep/owner + anyone in alert at full rate,
   others every 5 s; alerts always reach everyone.
 - SOS continuation: the live node sends an "SOS pending delivery" record to the twin before storing and fanning out;
   if the live node dies in between, the twin delivers it.
 - SOS probe (deploy/watchdog/sos_probe.js): staging-only test SOS every 15 min, mail if > 1 s or failed. Off until
   the probe accounts exist.
 - Stage 1 tooling: deploy/stage1_live_a1.sh and host/apply.sh --role live-a1 (Ampere A1 2 OCPU / 12 GB as the live
   node; heap 2 GB, MemoryMax 5 GB, LIVE_RIDER_CAP=2500 until the A1 twin exists).
 - Shard placement prepared and OFF (SHARDS=1): src/shards.js, Caddy matcher generator, GET /api/shard.
 - Load gates: tool/load/ws_load.js --preset gate2x|soak|failover|flood --gate (PASS/FAIL against the targets).
BACKGROUND WORKERS (gateway)
 - Durable job queue (src/jobs/, collections job_queue + job_dead) with casRev claims, retries, dead letters,
   idempotent enqueue; capacity-aware worker (event-loop lag, load, memory, DB budget); separate process
   gateway/worker.js (deploy/worker/coroute-worker.service). JOBS_QUEUE=off by default: deploying changes nothing.
 - Moved to the queue when on: all e-mails (security codes priority 0 with inline fallback after 10 s), ride summary
   maps, receipts, push fan-out, road-cell fetches, nightly batches. SOS paths never use the queue.
 - Admin API: GET /api/admin/jobs, dead letters with retry/discard (no admin page yet).

=== 2. COMMIT (after the round 7 commits) ===
 "feat(voice): RNNoise noise suppression, Opus codec, jitter buffer, low-priority voice relay",
 "feat(realtime): abuse limits, adaptive position rate, pos2 frames, interest management, SOS continuation",
 "feat(ops): SOS probe, stage 1 A1 live node tooling, load gates, shard placement (off)",
 "feat(gateway): durable job queue and capacity-aware workers (off by default)",
 "docs(v3.57): high traffic plan, round 8 notes". Push.

=== 3. TEST AND BUILD (in addition to round 7) ===
 1. cd gateway && npm test -> expect 1434 passing (flaky alone-reruns: public_ride_mirror, two_node_failover,
    job_lease, login performance, email_marketing_357).
 2. tool/voice_lab/run_lab.sh -> the SNR/clarity table matches docs/features_355/voice_clarity.md.
 3. flutter test: NEVER RUN BEFORE - test/voice_*, test/rt8_*, plus everything listed in the round 7 prompt.
 4. FIRST native build: flutter build apk/appbundle must compile android/app/src/main/cpp (CMake + RNNoise) for
    arm64-v8a and armeabi-v7a, and the Kotlin Opus code. Check the APK contains libcoroute_voice.so for both ABIs.
    Fix build errors carefully; never ship with noise suppression silently missing: on a test phone the intercom
    options must show "Strong" working (voice_clarity.md says how to confirm the native path is active).

=== 4. ENV (optional; defaults are safe; all in gateway/deploy/.env.example) ===
 Voice: VOICE_MAX_BYTES_PER_SEC, VOICE_DROP_BYTES, VOICE_FAIR_HOLD_MS, VOICE_CAPS_GRACE_MS, VOICE_RELAY_MODE=inprocess,
 VOICE_RELAY_PORT, VOICE_RELAY_HOST.
 Realtime: WS_MAX_CONN_PER_IP=50, WS_CONN_PER_MIN_PER_IP, WS_CONN_PER_MIN_PER_USER, WS_RL_*, WS_SOS_FLOOR_PER_10S,
 WS_IDLE_MS, WS_SLOW_READER_MS, WS_POS2=on, WS_INTEREST*, MIRROR_SOS_PENDING_TTL_MS, SHARDS=1.
 Jobs: JOBS_QUEUE=off (turn on per section 6), WORKER_INPROCESS=auto, JOBS_SEPARATE_WORKER=off, WORKER_TYPES,
 JOBS_SECURITY_FALLBACK_MS=10000, JOBS_SEAL_KEY (optional, Vault).
 Watchdog: WATCH_SOS_PROBE* in watchdog.env (staging only).
 Check Caddy timeouts against WS_IDLE_MS / WS_SLOW_READER_MS (ROUND8_REALTIME_NOTES.md section 8).

=== 5. STAGING CHECKS (add to rounds 6-7) ===
 - Load gates on staging: ws_load.js --preset gate2x --gate, --preset failover --gate, --preset flood --gate,
   --preset soak (30 min+). All PASS; record numbers.
 - Mixed builds: a 10026 phone and a 10027 phone in one ride see each other; voice falls back to PCM while the old
   build is there and switches to Opus when it leaves.
 - SOS probe: create two staging test accounts + one test group (never real riders), set WATCH_SOS_PROBE* on vm3,
   confirm the first probe result mail / daily summary.
 - Jobs: JOBS_QUEUE=on on staging, run QA J1-J13 (ROUND8_JOBS_NOTES.md section 6), including a stopped worker:
   sign-in codes still arrive within ~10 s (inline fallback).

=== 6. PRODUCTION ROLLOUT ORDER ===
 1. Deploy (release.sh staging -> vm2 -> vm1) with JOBS_QUEUE=off, VOICE_RELAY_MODE=inprocess, SHARDS=1.
 2. After 2 days healthy: JOBS_QUEUE=on on vm1 and vm2 (in-process workers; vm2 does the work).
 3. Install coroute-worker on vm2 (WORKER_INPROCESS=off there) or on vm5 when it exists; then JOBS_SEPARATE_WORKER=on
    on the live node.
 4. When the Ampere A1 in account 1 exists: deploy/stage1_live_a1.sh (stage 1). Run the load gates on it first and
    update the numbers in HIGH_TRAFFIC_PLAN section 3.
 5. VOICE_RELAY_MODE=process only after stage 1 (paste deploy/caddy/voice_relay.caddy into the live site block).

=== 7. DEVICE QA (release build; report each with phone model + Android version) ===
 - Voice A0-A14 (ROUND8_VOICE_NOTES.md): native library loads, helmet headset at 80 km/h, wind, rain, engine idle,
   two riders talking, old build in the group, data saver, weak signal, siren detection while talking, Opus on
   Android 10+ and PCM on Android 8-9, CPU/battery per hour of talking, SOS during heavy voice.
 - Realtime T1-T12 (ROUND8_REALTIME_NOTES.md): mixed builds, send cadence by speed, 20+ phones on one Wi-Fi with no
   rate-limit closes, big ride far-rider cadence, failover drill during an SOS (delivered exactly once), less mobile
   data per ride than 10026.
 - SAFETY GATE additions (any failure = STOP): an SOS during continuous group voice reaches every phone within 2 s;
   an SOS from a phone that is being rate-limited for chat still goes through; killing vm1 right after an SOS still
   delivers it (twin continuation).

=== 8. OWNER DECISIONS ===
 - Provision the Ampere A1 in account 1 (stage 1).
 - SOS probe test accounts on staging.
 - When to turn on JOBS_QUEUE in production and where the separate worker runs (vm2 now, vm5 later).
 - Admin UI for jobs (a "Jobs" card on the Servers page + dead letters list) and the probe result on the Servers
   page: next round (APIs exist; see the requests in the notes).
 - Play listing: add "Noise suppression by RNNoise (BSD licence)" to the open-source notice if the store text has one.

=== 9. REPORT ===
 As in round 7, plus: load gate numbers on staging (and on the A1 if done), voice lab table, native build result
 (both ABIs), device voice results (clarity notes from riders), probe result, queue rollout status.
```
