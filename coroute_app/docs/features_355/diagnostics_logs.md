# Diagnostics logs (3.55)

Owner request: "Maintain logs in the application and save them so that we can analyse the issues
later." Motivated by real-ride reports: late alerts, music volume not lowering, false SOS while
riding, siren detection, friend requests not showing.

The app keeps a persistent, privacy-safe technical log on the phone. A rider (or tester) can send
it to CoRoute in one tap, share it as a file, or view it on the phone. Admins list, view and
download sent logs in the console and can ask a rider for a log.

## What is logged

One JSON line per entry (`lib/domain/diag/diag_entry.dart`):

```json
{"t":1731234567890,"m":123456,"l":"W","c":"sos","e":"raise","f":{"src":"manual","sent":true},"b":"3.55.0+10020","s":"k3f9a2","r":"G-1234","n":42}
```

`t` wall clock ms, `m` monotonic ms since app start, `l` level (D/I/W/E), `c` category, `e` event,
`f` small key/value fields, `b` build, `s` session (one per app start), `r` ride id (only in a
ride), `n` sequence.

Categories: `safety sos crash alerts speed location audio siren intercom network realtime push
social ride battery permissions lifecycle errors diag`.

| Area | Events (category.event) | Where |
|---|---|---|
| Ride | `ride.ride_start` (group/solo, rider count), `ride.ride_end` (minutes), `battery.battery` (%, charging, saver at start/end), `permissions.permissions` (each permission granted or not at ride start) | `DiagRideObserver` (main.dart) |
| GPS | `location.gps_summary` every 30 s: fixes, fixes/s, longest gap, accuracy p50/max, rejected fixes, max speed, rounded position; `speed.speed_outlier` (sampled) | `ConvoyService._onPosition` |
| Overspeed | `speed.overspeed_warn` (speed, limit, limit source personal/group/town, fix age at decision); `overspeed_hide/clear` (debug) | `SafetyService._checkSpeedLimit` |
| Alert pipeline / audio | `audio.audio` lines from `AudioDiagLog` (P1..P4 `decision->audio Nms`, `to engine: waited Nms`, `speech start +Nms`, native focus results, MediaVolumeGuard / TtsChannel music volume changes, speed music policy) | main.dart bridges `AudioDiagLog.sink` |
| Crash detection | `crash.impact_candidate` (scenario, peak g, dynamic g, gyro, tilt, duration, jerk, speed, severe, repeats), `crash.candidate_dropped` (why + evidence counters), `crash.alarm_open` (scenario, g, speed, confidence, rider-down, detection delay), `crash.alarm_refused`, `crash.alarm_cancel` (I'm OK), `crash.alarm_ride_on`, `crash.alarm_send` (source) | `CrashDetector`, `SafetyService` |
| SOS | `sos.raise` (type, source, auto, sent or queued, connected, accuracy, rounded position), `sos.send` (each (re)send), `sos.ack` (time from raise and from send to the server echo), `sos.cancel` (reason), `sos.solo_sos`, `sos.sms_fallback` (state, sent/total, contact reached) | `ConvoyService`, `SafetyService` |
| Siren | `siren.detected` (pattern, kind, confidence, SNR, Hz, seconds heard before sure, trend, nearness, music/call), `siren.alert` (reason, spoken/tone, close), `siren.episode_end`, `siren.candidate_rejected` (why; detailed logs only, sampled every 30 s), `siren.mic_error` | `SirenAcousticDetector` |
| Intercom | `intercom.talk_start` (mode, channel, lead, direct), `talk_end` (ms, frames), `mic_open_failed`, `mic_claim_refused`, `mic_error`, `player_setup_failed` | `IntercomService` |
| Socket | `realtime.connected` (connect ms), `closed` (code, before HELLO, in ride, time up), `connect_failed` (no network / server unreachable), `stale_link`, `server_move`, `socket_error`, `connect_start` / `reconnect_wait` (debug) | `RealtimeService` |
| Push | `push.token_registered`, `token_register_failed`, `token_refreshed`, `received` (type, event id), `opened` | `PushService` |
| Friends / invites | `social.friend_event` (type, request id, event id, parsed, switch on, foreground), `friends_loaded` (counts), `friends_refresh_failed`, `friends_unparsed`, `ride_invite_event` | `FriendsService`, `RideInvitesService` |
| API | `network.api_error` (method, path template, status, ms, server request id), `api_timeout`, `api_offline`, `api_slow` (> 5 s) | `ApiClient._send` |
| Lifecycle | `lifecycle.app_start`, `resumed`, `inactive`, `hidden`, `paused`, `detached` | `DiagLogService` |
| Errors | `errors.flutter_error`, `uncaught_async`, `uncaught_zone`, `isolate_error` (type, scrubbed message, top 5 frames as `Class.method file.dart:line`), `native_crash` and `native_main_stall` (merged from Kotlin at next start) | main.dart, `CrashLog.kt` |
| Diagnostics itself | `diag.upload_start/ok/failed`, `share`, `cleared`, `detailed_on/off`, `auto_send_safety`, `admin_request`, `safety_prompt_dismissed`, `queue_dropped` | `DiagLogService` |

Levels: info, warn and error are always written. Debug only while **Detailed logs** is on
(Profile › Help › Send feedback › View diagnostics; shown to admins, or after seven taps on the screen subtitle). It
switches itself off 24 h after it was turned on.

## Privacy

Enforced in one place, `lib/domain/diag/diag_redact.dart` (tests: `test/diag_log_355_test.dart`),
and again on the server (`gateway/src/diag_logs.js`, tests: `gateway/test/diagnostics_355.test.js`).

- Never written: message text, names, usernames, phone numbers, e-mails, medical info, tokens /
  passwords, addresses, contacts. A field whose key contains such a word (`riderName`, `phone_no`,
  `bloodGroup`, `fcmToken`, `homeAddress`, `emergencyContact`, `messageText`...) is dropped whatever
  its value; `...Len`, `...Count`, `...Ok`, `...Kind`, `...Type`, `...Ms` keys are allowed.
- Free text values (error messages, audio lines) are scrubbed: e-mails, JWTs, `token=` / `Bearer`
  secrets, long mixed-case tokens, long hex runs, phone numbers (9-15 digits), digit runs of 7+,
  URL query strings; precise coordinates in text are rounded. Strings are cut to 120 characters.
- Location: `lat` / `lng` rounded to 3 decimals (about 100 m) and only during a ride (removed
  otherwise).
- User ids: only as a 10-hex salted hash (`DiagLog.userHash`, random salt per install). The app
  instrumentation logs request / invite / event ids, never usernames.
- API paths as templates: `/friends/raj_rides/accept?x=1` becomes `/friends/:id/accept`.
- Nested values are reduced to a count; at most 16 fields per entry.
- Native crashes: exception class, scrubbed 160-character message, thread name, top 8 frames.
- The server parses every line again, keeps only the known keys, re-applies the key word list and
  the text scrub (an old or modified app is not trusted), and drops lines that are not entries.

## Where it is stored

Phone: `<filesDir>/diag/` (Android `context.filesDir`, private to the app, removed on uninstall;
`allowBackup=false`).

- `diag-YYYYMMDD-NN.jsonl`: one file per day, a new part at 2 MB. Closed files are gzipped
  (`.jsonl.gz`, `dart:io` gzip in a background isolate).
- Kept: the last 7 days and at most 20 MB in all (oldest out first). Policy: `DiagFiles` in
  `lib/domain/diag/diag_policy.dart`.
- Writes: `DiagLog.*` only appends to a list (never awaits, never throws: safe on alert and SOS
  paths). `DiagLogService` writes batches every 2 s with append + flush; warn / error and
  `safety` / `sos` / `crash` entries are written at once; the queue is also written when the app
  goes to the background. A torn last line after a crash is skipped by every reader.
- `native_crashes.jsonl`: written by Kotlin `CrashLog` (uncaught exceptions; 5 s+ main-thread
  stalls while the app is in front), merged into the log and deleted at the next start.
- The last 500 entries are also kept in memory for the viewer.

Server (when sent): collection `diag_logs` (metadata: rider id, username at upload time, build,
device, Android version, reason, ride id, request id, sizes, counts, summary) and the cleaned,
re-gzipped body in Object Storage (`DIAG_LOG_STORE=par`, `DIAG_LOG_PAR_URL` or the review photo
bucket PAR, objects `diag-logs/<id>.jsonl.gz`) or in the database (`diag_log_chunks`, 512 KB
base64 chunks). Requests: `diag_log_requests`.

## Retention

- Phone: 7 days / 20 MB, "Clear logs" deletes everything at once.
- Server: 30 days (`expiresAt`), removed by the leased job `diag-log-retention` every 6 h (one node
  of the two-VM deployment); admin requests expire after 7 days. Deleting the account deletes the
  rider's logs, bodies and requests at once (erase cascade). Admins can delete a single log.

## How testers and the owner send logs

1. Profile › Help › Send feedback › **View diagnostics** (its only entry since Nov 11; Send feedback also has an "Attach diagnostics log" switch that runs the same upload) shows log size, days kept, last error and last send.
2. **Send logs to CoRoute**: uploads the last days (newest first, 5 MB gzip at most). Reason `manual`.
3. **Share log file**: the same bundle as `coroute-logs-YYYYMMDD-HHMM.jsonl.gz` through the share
   sheet (WhatsApp, Drive, e-mail...).
4. **View log**: the last 500 entries, newest first, with a category filter and "Problems" (warn
   and error only). Text can be selected.
5. After a ride with an SOS, a crash alarm or a false-alarm cancel, the app asks once, after the
   ride (never during it): "Help us improve safety: send the log of this ride?" (window: 15 min
   before the first safety moment to 2 min after the ride). One tap sends; "Not now" forgets it.
   With **Send safety logs automatically** on (default off) it is sent without asking.
6. Admin **Ask for logs** on a rider (Riders › rider › Ask for logs): the rider gets a socket
   message (or a push `DIAG_LOG_REQUEST` when the app is closed; also picked up from
   `GET /api/me/diagnostics/requests` at the next start) and a sheet "CoRoute support asked for
   your app log" with Send / Not now. Nothing is sent without the tap.

Limit: 5 uploads per rider per 24 h (the app says so on 429).

## Gateway API

| Method | Path | Who | Notes |
|---|---|---|---|
| POST | `/api/me/diagnostics?reason=&build=&device=&os=&rideId=&requestId=` | rider | Raw gzip body (magic bytes checked), 5 MB max, 64 MB unpacked max, 500k lines max. `reason` = `manual`, `safety_prompt` or `admin_request`. A `requestId` must be an open request of this rider (then fulfilled). 201 `{ok,id,lines,dropped,expiresAt}`; 400 / 413 / 415 / 429 with `code`; 403 `FEATURE_OFF` when the switch is off. |
| GET | `/api/me/diagnostics/requests` | rider | Open admin requests `{requests:[{requestId,at}]}`. |
| GET | `/api/admin/diag-logs?userId=&username=&build=&reason=&days=` | admin | Newest first, `days` 1..30, `build` is a prefix. |
| GET | `/api/admin/diag-logs/:id` | admin | Metadata + summary (counts by category and level). Audited `diag.view`. |
| GET | `/api/admin/diag-logs/:id/lines?cat=&level=&offset=&limit=` | admin | Parsed lines; `level=W` = warnings and errors. |
| GET | `/api/admin/diag-logs/:id/download` | admin | The gzip bundle. Audited `diag.download`. |
| DELETE | `/api/admin/diag-logs/:id` | admin | Audited `diag.delete`. |
| POST | `/api/admin/diag-logs/request` `{userId}` or `{username}` | admin | One open request per rider (reused). Socket + push `DIAG_LOG_REQUEST`. Audited `diag.request`. |

Admin switch: `diagnosticsUpload` (Platform, default on) gates the upload only.

Admin console: System › **Diagnostics** (filters: username, build, reason, last 24 h / 7 / 30
days) and Riders › rider › **App logs** / **Ask for logs**. The viewer shows the level counts,
category chips, "Problems", paged lines, **Download** (share the gzip) and **Delete**. The audit
log (Settings › Audit log) records views, downloads, deletes and requests.

## How to analyse a log

1. Admin console › System › Diagnostics › open the log: start with "Problems", then the category
   of the reported issue (e.g. `audio` for a late alert, `crash` for a false SOS, `siren`,
   `social` for missing friend requests, `realtime` for drops).
2. Download it and run the summary tool (plain Node, no dependencies):

   ```
   node tool/diag/analyze_logs.js coroute-diag-dl_xxx.jsonl.gz          # text report
   node tool/diag/analyze_logs.js coroute-diag-dl_xxx.jsonl.gz --json   # for scripts
   node tool/diag/analyze_logs.js bundle.jsonl.gz --ride G-ABC123       # one ride
   ```

   It prints: builds and app starts, entries by level / category, errors and warnings by count,
   alert latency per priority (decision -> audio p50/p90/max, queue wait, speak call -> first
   audio, dropped / refused, audio focus results), overspeed decisions by limit source with fix
   age, crash candidates and why they were dropped, alarms, cancels (I'm OK / rode on) and sends,
   SOS delivery (queued, resends, ack time, SMS fallback), socket drops by close code, connect
   failures, stale links, connect time, GPS rate / accuracy / gaps, API errors by path and status,
   siren detections and alerts, intercom talks and problems, push and friend events, native
   crashes and stalls, and the rides in the bundle.

Typical questions:

- **Late alert**: `audio` lines `P2 ... decision->audio 2400ms` vs `to engine: waited` (queue) and
  `speech start +Nms` (engine). `speed.overspeed_warn.fixAgeMs` shows how old the GPS fix was.
- **Music not lowered**: `audio` lines `native focus ...` and `speed music lower/restore ...`.
- **False SOS while riding**: `crash.impact_candidate` numbers, `crash.alarm_open` (scenario,
  confidence), then `alarm_ride_on` / `alarm_cancel` / `alarm_send`; `location.gps_summary` around it.
- **Siren**: `siren.detected` (seconds heard before sure, confidence, kind) and `siren.alert`;
  turn on Detailed logs for `candidate_rejected` reasons.
- **Friend request not showing**: `social.friend_event` (did the socket event arrive? parsed?
  switch on?) and `social.friends_loaded` counts; `push.received` for the push path.

## Server logs

- The gateway writes plain lines with an ISO timestamp to stdout / stderr (`src/server.js`).
- 3.55: every request gets a request id (`X-Request-Id` from Caddy or the client when it is 8-64
  safe characters, else a new random id), echoed in the response header. Every 5xx is logged as
  `[http] METHOD /route/template 500 req=<id>: <first line of the error>`: no bodies, no query, no
  username or e-mail. Diagnostics routes log `[diag-logs] stored <id> reason=.. lines=.. bytes=..
  req=<id>` and failures with the request id only. The app records the server's request id of a
  failed API call (`network.api_error.reqId`), so a phone log and a server log line can be matched.
- Where they live on the VMs (current deployment, `deploy/setup_node.sh` +
  `deploy/coroute-gateway.service`): systemd journal (`StandardOutput=journal`), capped at 200 MB
  by `/etc/systemd/journald.conf.d/coroute.conf` and rotated by journald.

  ```
  journalctl -u coroute-gateway -f                                  # follow
  journalctl -u coroute-gateway --since '-2 h' | grep 'req=3f2a'     # one request id
  journalctl -u coroute-gateway --since today | grep -E '\[http\]|error'  # errors today
  journalctl -u coroute-gateway --since '2026-11-10 08:00' --until '2026-11-10 10:00' > gw.log
  scp <vm>:gw.log .                                                  # pull to a laptop
  journalctl -u caddy --since '-1 h'                                 # proxy side
  ```

  Run it on both VMs (VM1 `live`, VM2 `web`; the `X-CoRoute-Node` response header tells which
  node answered).
- Older single-VM installs made by `deploy/setup_vm2.sh` append to `/var/log/coroute/gateway.log`
  and `gateway-err.log` without rotation. Move them to the journal (re-run `setup_node.sh`) or add
  `/etc/logrotate.d/coroute` (`/var/log/coroute/*.log { daily rotate 14 compress copytruncate missingok }`).

## Device checks (cannot be done here)

1. Fresh install: Profile › Help › Send feedback › View diagnostics shows a small size, "Today", Last error "None".
   View log shows `lifecycle.app_start` and `resumed`.
2. Ride 10 minutes: `ride_start`, `battery`, `permissions`, `gps_summary` every 30 s, `ride_end`.
3. Overspeed in a test zone: `overspeed_warn` followed by `audio` `decision->audio` lines.
4. Crash alarm test (developer impact, then I'm OK): `alarm_open`, `alarm_cancel`; after the ride
   the safety prompt appears once; Send works; the log appears in the admin console with reason
   "After a safety moment".
5. Airplane mode mid-ride, then back: `realtime.closed`, `connect_failed`, `connected` with
   connect time.
6. Force a native crash (debug build) or a 6 s main-thread block: after restart
   `errors.native_crash` / `native_main_stall` appear and `native_crashes.jsonl` is gone.
7. Admin › rider › Ask for logs with the app open (sheet appears) and closed (push, then the sheet
   on open). Send and confirm the request is fulfilled.
8. Share log file opens the share sheet with a `.jsonl.gz`; `node tool/diag/analyze_logs.js` reads it.
9. Detailed logs on: `siren.candidate_rejected` and `realtime.connect_start` appear; the switch
   shows "On until ..." and is off the next day.
10. Leave the phone for 8 days: only 7 days of files remain; total stays under 20 MB.
11. Check a sent log for any name, phone number or message: there must be none.
