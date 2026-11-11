# CoRoute data model

Source of truth: `gateway/src/oracle/repo.js` (`C` collection map and `migrate()` indexes) and the
module-level collection constants in `gateway/src/*.js`. Written 11 Nov 2026.

## 1. Storage technology

- **Oracle Autonomous Database** (Always Free, Hyderabad region), JSON document collections reached
  through **ORDS SODA REST** (`gateway/src/oracle/soda.js`). Only the gateway talks to it, as the
  low-privilege schema user `COROUTE` (never ADMIN). The ADB network ACL allows only the two VMs.
- Tests and local runs use `MemorySoda` (`ORACLE_SODA_URL=memory`), which emulates queries, unique
  indexes and compare-and-replace.
- `repo.migrate()` creates collections and indexes on every boot (idempotent). Module collections
  (social, crews, push, operators, ...) are created on first use with their own indexes.
- Concurrency: compare-and-replace (`SodaClient.compareAndReplace`: JSON Patch `test` + `replace` in
  one PATCH) for leases, coupons, order claims and the access-mode document; per-key write chains in
  the repo for alerts (`_alertSerial`) and room snapshots (`_snapshotSerial`).
- Configuration-like documents share one collection, `subscription_config`, keyed by `k`
  (`pricing`, `membership_catalog`, `access_mode`, feature switches, `community_stats_config`,
  `audit`, marketing templates, all-time totals, `coupon_redemption`, `rzp_order`, ...).

## 2. Collections

### 2.1 Core accounts and rides

| Collection | One document per | Key fields | Indexes |
|---|---|---|---|
| `users` | account | `userId`, `email`, `name`, `role` (`RIDER`, `MASTER_ADMIN`, staff), `status` (`ACTIVE`, hold, blocked), `passwordHash` (`scrypt$N$r$p$salt$hash`, legacy bcrypt re-hashed on sign-in), `passwordChangedAt`, `phone`, `vehicleType`, `vehicleNo`, `emergencyContact`, `emergencyContactName`, `smsOptOut`, medical (`bloodGroup`, `allergies` ≤120, `medicalNotes` ≤200), `assistHelp`, `assistAsk`, bike summary (`bikeModel`, `bikeCc`, `bikeColour`, `bikeTankL`, `bikeMileageKmL`, `bikeCooling`, `bikeType`, `bikeFuel`), false-alarm times | `users_userid_ux` (unique), `users_email_ux` (unique) |
| `convoys` | ride | `groupId`, `joinCode`, `name`, `tripStatus` (`PLANNING`, `STARTED`, `PAUSED`, `ENDED`), owner, trip head, config (speed limit, distances, assistDefault...), route, stops, `meta.groupFeatures` (null = all), capacity, pending swap asks, `updatedAt` | `convoys_groupid_ux`, `convoys_joincode_ix` (joinCode, tripStatus), `convoys_status_ix` |
| `convoy_riders` | rider per ride | `groupId`, `userId`, role (`LEAD`/`MIDDLE`/`SWEEPER`), joined/left, vehicle, `vehicleKind`, `bikeComplete`, pillion link | `riders_group_user_ux`, `riders_user_ix` |
| `room_snapshots` | live room | every rider's live state (position, presence, telemetry) in one document, rewritten every `RIDER_PERSIST_INTERVAL_MS` (15 s) | `room_snapshots_group_ux` |
| `messages` | chat / quick card | `messageId`, `groupId`, `timestamp`, text, hidden/report flags | `messages_group_ts_ix`, `messages_id_ux` |
| `alerts` | SOS / crash / member alert | `alertId`, `groupId`, `resolved`, type, source, position, `liveLink` (hash, times), `nearestHospital`, medical copy while open | `alerts_group_ix`, `alerts_id_ux` |
| `trips` | finished journey (per rider) | `tripId`, `userId`, `endTimeEpochMs`, stats, start/end place names, `breadcrumbTrail` | `trips_user_ix`, `trips_id_ux` |
| `active_trips` | rider's current ride | `userId`, `groupId` | unique userId |
| `track_chunks` | uploaded GPS batch | `groupId`, `userId`, `seq`, `startTs`, `endTs`, points | `tracks_group_user_seq_ux`, `tracks_group_ts_ix` |
| `trip_events` | timeline entry | `eventId`, `groupId`, `userId`, kind, `startedAt`, place name, lat/lng | `events_id_ux`, `events_group_ts_ix`, `events_user_ix` |
| `voice_log` | talk session metadata | who, to whom, `startedAt`, duration (**no audio**) | `startedAt` |
| `broadcasts` | admin fleet announcement | timestamp, text | timestamp |
| `feedback` | trip review | `tripId`, `userId`, `status`, `submittedAt`, rating, text, photos refs, consent | `feedback_trip_user_ix`, `feedback_status_ix` |
| `engagement_feedback` | in-app feedback | topic, message, reply flag | — |
| `device_diagnostics` | older diagnostics submission | `diagnosticId`, `riderId`, `timestamp`, `lifecycleStatus` | `diag_id_ux`, `diag_user_ix`, `diag_status_ix` |
| `hosted_ride_counts` | host per IST month | key `<userId>:<YYYY-MM>`, count | — |

### 2.2 Safety and road data

| Collection | Purpose | Notes |
|---|---|---|
| `safety_audit` | safety-network audit, live link create/revoke/view, role changes | ids and short codes only, no coordinates; indexes on `at`, `actorId` |
| `guardian_grants`, `guardian_sessions`, `guardian_revocations`, `guardian_consents`, `guardian_subscriptions`, `guardian_jobs`, `guardian_pauses` | Ride Guardian pilot | token / session hashes (`guardian_token_ux`, `guardian_session_ux`), PIN hash, tier, expiry |
| `road_hazards` | saved potholes, speed breakers, rough road | **no rider ids**; merged with nearby; `expiresAt` (pothole 45 d, rough road 30 d, speed breaker 365 d) |
| `road_risk` | anonymous hard-brake cells (risky stretch) | removed after 180 days with no new report |
| `place_reviews` | CoRoute rider reviews of places | `reviewId`, `placeId`, `userId`, stars, text, photo (shown after admin check) |
| `public_ride` | public ride reports, contact log, blocks, suspensions | contact log kept 30 days |
| `geo_cache` | search / route / POI cache | key `k`; removed after `GEO_CACHE_DAYS` (30) |
| `sos_sms`, `sms_settings` | server SOS SMS rows and provider settings | row key `<alertId>:SOS:<sha256(number)>` (unique dedupe); numbers, names, links purged 48 h after last status change |

### 2.3 Plans and payments

| Collection | Purpose | Notes |
|---|---|---|
| `memberships` | real memberships (Small Group, Large Group; admin grants are ₹0 ledger orders) | `membershipId`, `ownerUserId`, `status`, `validUntil`, `orderId` |
| `coupons` | coupon records (caps, holds, uses) | atomic caps via compare-and-replace |
| `payment_events` | Razorpay webhook event ids | unique `eventId` (replay protection across both URLs and nodes) |
| `subscription_config` | config documents and admin audit (`k='audit'`) | see §1 |
| `mail_log` | receipt / refund mail outcomes and retries | — |
| `organizations` | legacy | `organizationId` |
| `pricing_rules` | minimum payable price etc. | — |

### 2.4 Social

| Collection | Purpose |
|---|---|
| `usernames` | unique usernames (`usernames_key_ux`) |
| `friend_edges` | friend requests and friendships (`friend_edges_pair_ux`) |
| `user_blocks` | silent blocks |
| `invite_codes` | personal friend invite codes |
| `avatars` | profile pictures |
| `crews`, `crew_members`, `crew_invites`, `crew_polls`, `crew_votes` | crews (club crews carry `club: {operatorId, type, maxMembers}`) |
| `ride_invites` | crew ride invites (one live invite per rider per ride) |
| `rider_scores` | private score and leaderboard entries (`rider_scores_user_ux`, `rider_scores_board_ix`) |

### 2.5 Operators

`operators` (application, status, limits, features, private contact), `operator_rides` (schedule,
slug, sign-ups, link to the convoy), `operator_broadcasts`, `operators_config` (per-type templates).

### 2.6 Messaging and marketing

| Collection | Purpose |
|---|---|
| `push_tokens` | FCM tokens (`token` unique, 5 newest per rider) |
| `push_prefs` | per-kind push opt-outs |
| `push_campaigns`, `push_images`, `push_news_caps` | admin campaigns, images, per-rider caps (`expiresAt`) |
| `marketing_consent` | offers e-mail opt-in with last 20 changes (time, source) |
| `email_suppression` | SHA-256 of suppressed addresses (unsubscribe, bounce, complaint, admin) |
| `offer_email_campaigns` | offer e-mail campaigns |
| `message_templates` | editable push / SMS / e-mail templates with history |
| `board_posts` | website offers board (`/updates`) |

### 2.7 Platform

| Collection | Purpose |
|---|---|
| `leases` | job leases (`name`, `holder`, `role`, `expiresAt`, `version`, `lastRunAt`) |
| `diag_logs`, `diag_log_chunks`, `diag_log_requests` | uploaded diagnostics logs (or Object Storage when `DIAG_LOG_STORE=par`), admin requests |
| `pageviews` | website page counts per day and path (`pageviews_day_path_ux`), referrers capped per page/day |

## 3. Retention and purge jobs

All run under job leases (exactly once across nodes). Defaults from `config.js` and module constants.

| Data | Rule | Where |
|---|---|---|
| Recorded routes (`track_chunks`) | simplified per rider after `TRACK_DETAIL_DAYS` (14); deleted after `TRACK_RETENTION_DAYS` (**90**) | `retention.js` |
| `breadcrumbTrail` in trips, room snapshots and `convoy_riders` of ended rides | removed `RETENTION_ENDED_CONVOY_DAYS` (**90**) after the ride ended | `retention.js` |
| Coordinates on `trip_events` and SOS alerts | removed after 90 days (entry, who, when, type kept) | `retention.js` |
| Medical info on alerts | removed on resolve and at trip end; retention removes leftovers | `retention.js` |
| Stale rides | auto-ended after `RETENTION_STALE_CONVOY_HOURS` (36) | `convoy-auto-end` job |
| `voice_log` | `RETENTION_VOICE_LOG_DAYS` (**7**) | `retention.js` |
| `geo_cache` | `GEO_CACHE_DAYS` (30) | `retention.js` |
| `safety_audit` | `AUDIT_RETENTION_DAYS` (**180**) | `retention.js` |
| Road hazards | own expiry per kind (45 / 30 / 365 days), renewed by confirmations | `retention.js` |
| Road risk cells | 180 days without a new report | `retention.js` |
| Guardian access | expired grants/sessions purged | `retention.js` |
| Orphan memberships | owner gone: removed (guard refuses mass deletion on a bad read) | `retention.js` |
| Uploaded diagnostics logs | **30 days**; admin requests 7 days | `diag-log-retention` |
| Server SOS SMS rows | numbers, names, links purged **48 h** after last status change | `sos-sms` |
| Push news caps | expire after 3 days (perk window 7+1 days) | `push-news-caps` |
| Public ride contact log | 30 days | `public_ride.js` |
| Encrypted backups | `BACKUP_RETENTION_DAYS` (30): deleted through the PAR when it can list, else an Object Storage lifecycle rule | `backup_jobs.js` |
| Account deletion | immediate erase cascade (`DELETE /api/me`); shared rides keep "Former rider" (`anonymise.js`); suppression entry for e-mail stays so an erased address is not mailed again | `auth.js`, module erase hooks |

Phone-side retention (not in the database): diagnostics log on the phone at most 7 days / 20 MB;
saved offline route maps 7 days after the trip ends, 30 days if the trip never ended, 300 MB LRU cap;
emergency SMS roster on the phone deleted at ride end / leave / sign out; coupon from a QR link kept
7 days. See [../compliance/consent_and_retention_register.md](../compliance/consent_and_retention_register.md).

## 4. Replication and backup

- **Live state** is replicated between the two gateway nodes by the mirror (`mirror.js`), not by the
  database: room events, positions, voice, presence lists and the `pr`, `ff`, `am` extensions.
  Durable events are written to the database first. See [architecture.md §1.2](architecture.md#12-mirror-live-replication-between-nodes).
- **Database**: a single Autonomous DB shared by both nodes (Oracle manages its own storage
  redundancy and automatic backups).
- **Application backups** (`backups.js`, `backup_jobs.js`): `backup-critical` every
  `BACKUP_CRITICAL_EVERY_MINUTES` (critical collections: accounts, memberships, payments ...) and
  `backup-full` daily after `BACKUP_FULL_HOUR_UTC`, gzip + encrypted with `BACKUP_ENCRYPTION_KEY`,
  written to Object Storage through `BACKUP_PAR_URL` under `coroute/`. Restore with
  `gateway/scripts/backup_restore.js` into a second database first (runbook:
  [deployment_and_operations.md §6](deployment_and_operations.md#6-backups-and-restore)).
- `gateway/deploy/nightly_backup.py` is an older host-side helper; the leased jobs are the supported
  path.
