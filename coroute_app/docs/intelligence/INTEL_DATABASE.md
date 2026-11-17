# Own database for the intelligence (v3.62)

Code: `gateway/src/oracle/intel_store.js`, wired in `gateway/src/app.js`. Tests: `gateway/test/intel_362_store.test.js`.

## What moves

`intel_raw`, `intel_cells`, `intel_meta`, `intel_crash_train`, `intel_consent`, `intel_insights`, `business_agg`,
`business_riders`, `business_obs`, `road_risk` (override with `INTEL_DB_COLLECTIONS`). Everything else (accounts, rides,
SOS alerts, sessions, payments) always stays in the main database.

## How it works

`INTEL_SODA_URL` empty: nothing changes. Set: a routing layer sits under field encryption, so every module keeps one
`soda`. The switch state lives in the MAIN database (`intel_db_state`, `k = 'state'`), each node re-reads it every 15 s
and before serving at boot:

| State | Reads | Writes |
|---|---|---|
| `main` (default) | main | main |
| `dual` (copying) | main | main, and mirrored to the intel DB (`_mk` = main key) |
| `intel` | intel DB | intel DB (main keys from just before the switch are translated for 10 minutes; `_mk` is never returned) |

Account erase and "delete my contributions" go through the same layer, so they reach whichever store holds the data
(and both while copying). Backups read through it too. `/api/health` → `intel.database` and the web admin
**Insights** page show the state, the copy progress and mirror errors.

## Owner steps

1. Create the second Autonomous Database (or schema), an ORDS-enabled low-privilege user, and enable SODA (same as the
   main one, `deploy/RUNBOOK.md` §2).
2. On BOTH nodes set `INTEL_SODA_URL`, `INTEL_ORACLE_USER`, `INTEL_ORACLE_PASSWORD` (never in git) and restart. The
   state stays `main`; collections and indexes are created in the new database.
3. On ONE node set `INTEL_DB_MIGRATE=1` and restart. Within a minute the state becomes `dual`; after about 65 s both
   nodes mirror writes and the copy runs (`INTEL_DB_MIGRATE_BATCH` documents a minute, resumable after restarts). When
   a full pass copies nothing, the state becomes `intel`.
4. Check web admin > Road & safety intelligence > Insights: "Own database". Remove `INTEL_DB_MIGRATE`.
5. Later (optional): drop the old intelligence collections from the main database after a backup.

To go back: set the state document to `{ k: 'state', mode: 'main' }` (data written after the switch is only in the
intel DB; copy it back first if needed).

## v3.62b additions (17 Nov 2026)

**Is DB 2 in use?** Web admin > Configuration > "Intelligence database" card, or Insights, or `/api/health` ->
`intel.database`: `separate: false, mode: main` = DB 1 only (today). `dual` = copying. `intel` = DB 2 in use.

**Readiness check before switching** (on a VM, prints no secrets, leaves no data):

    cd gateway && node scripts/intel_db_check.js

It checks that DB 2 answers, the user / password work, it can write / read / delete a test document, that it is a
different database from DB 1, and the round-trip times. Exit 0 = ready.

**What moves to DB 2**

| Profile | Collections |
|---|---|
| default | intel_raw, intel_cells, intel_meta, intel_crash_train, intel_consent, intel_insights, business_agg, business_riders, business_obs, road_risk |
| `INTEL_DB_PROFILE=extended` | default + pageviews, mail_log, rider_scores, device_diagnostics, track_chunks (trip history) |
| never (refused even in INTEL_DB_COLLECTIONS) | users, convoys, convoy_riders, messages, alerts, active_trips, auth_sessions, leases, guardian_*, safety_audit, memberships, subscription_config, payment_events, coupons, room_snapshots, push_tokens, geo_cache |

So an outage of DB 2 can only slow intelligence, analytics, page views and trip history; SOS, rides, sign-in,
guardians and payments run on DB 1 alone.

**Adding collections later** (for example turning on the extended profile after the first switch): set the profile on
both VMs, restart, set `INTEL_DB_MIGRATE=1` on one VM again. The new collections go pending (written to both) ->
copied -> migrated, one group at a time, with no downtime; the ones already moved keep running on DB 2. A collection
that was moved keeps answering from DB 2 even if it is later removed from the list (its data never "disappears").
