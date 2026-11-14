'use strict';
require('dotenv').config();

function required(name) {
  const v = process.env[name];
  if (!v || !v.trim()) {
    throw new Error(`[config] Missing required environment variable ${name}. See deploy/.env.example`);
  }
  return v.trim();
}

function int(name, def) {
  const v = process.env[name];
  if (v === undefined || v === '') return def;
  const n = parseInt(v, 10);
  if (Number.isNaN(n)) throw new Error(`[config] ${name} must be an integer`);
  return n;
}

function list(name, def = []) {
  const v = process.env[name];
  if (!v) return def;
  return v.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
}

const isTest = process.env.NODE_ENV === 'test';

function oneOf(name, allowed, def) {
  const v = String(process.env[name] || '').trim().toLowerCase();
  if (!v) return def;
  if (!allowed.includes(v)) throw new Error(`[config] ${name} must be one of ${allowed.join(', ')}`);
  return v;
}

/** SETTINGS_ENCRYPTION_KEY: 32 bytes, base64. Empty means "not configured" (legacy JWT-derived key only). */
function settingsKey(v) {
  const s = String(v || '').trim();
  if (!s) return null;
  const buf = Buffer.from(s, 'base64');
  if (buf.length !== 32 || buf.toString('base64').replace(/=+$/, '') !== s.replace(/=+$/, '')) {
    throw new Error('[config] SETTINGS_ENCRYPTION_KEY must be 32 random bytes, base64 encoded (openssl rand -base64 32)');
  }
  return buf;
}

/** TRUST_PROXY: comma list of IPs, CIDRs or Express keywords; default loopback only. */
function trustList(v) {
  const net = require('net');
  const items = String(v || 'loopback').split(',').map((x) => x.trim()).filter(Boolean);
  for (const it of items) {
    if (['loopback', 'linklocal', 'uniquelocal'].includes(it)) continue;
    const [ip, bits, extra] = it.split('/');
    const fam = net.isIP(ip);
    const okBits = bits === undefined || (/^\d+$/.test(bits) && Number(bits) <= (fam === 6 ? 128 : 32));
    if (!fam || !okBits || extra !== undefined) throw new Error(`[config] TRUST_PROXY entry "${it}" is not an IP, CIDR or loopback/linklocal/uniquelocal`);
  }
  return items.length ? items : ['loopback'];
}

/**
 * The one support / contact address (website legal pages, receipts, map-data providers): SUPPORT_EMAIL.
 * No built-in default: set it to a role address (for example support@<your domain>). When it is empty the
 * website points riders to Profile > Help > Send feedback in the app instead of an e-mail address.
 */
const SUPPORT_EMAIL = (process.env.SUPPORT_EMAIL || '').trim();
/** Security reports (/.well-known/security.txt, /security): SECURITY_CONTACT, else SUPPORT_EMAIL. */
const SECURITY_CONTACT = (process.env.SECURITY_CONTACT || SUPPORT_EMAIL).trim();

const config = {
  env: process.env.NODE_ENV || 'production',
  port: int('PORT', 3000),
  host: process.env.HOST || '127.0.0.1',

  // Oracle Autonomous Database — ORDS SODA REST endpoint.
  // Example: https://<tenancy>-coroutedb.adb.ap-hyderabad-1.oraclecloudapps.com/ords/coroute/soda/latest
  sodaUrl: isTest ? 'http://mock' : required('ORACLE_SODA_URL'),
  // Dedicated low-privilege ORDS schema user (never ADMIN). See deploy/RUNBOOK.md §2.
  oracleUser: isTest ? 'test' : required('ORACLE_USER'),
  oraclePassword: isTest ? 'test' : required('ORACLE_PASSWORD'),
  oracleTimeoutMs: int('ORACLE_TIMEOUT_MS', 6000),

  // Auth
  jwtSecret: isTest ? 'test-secret-test-secret-test-secret-1234' : required('JWT_SECRET'),
  jwtTtlDays: int('JWT_TTL_DAYS', 30),
  tokenRefreshAfterHours: int('TOKEN_REFRESH_AFTER_HOURS', 24),
  // 3.56 website sign-in (src/web_shop.js): the OAuth "Web application" client id for the Google button on
  // /signin. Also accepted as an ID-token audience (added to GOOGLE_CLIENT_IDS below when missing).
  googleWebClientId: (process.env.GOOGLE_WEB_CLIENT_ID || '').trim(),
  googleClientIds: [...new Set([...list('GOOGLE_CLIENT_IDS'), ...list('GOOGLE_WEB_CLIENT_ID')])],
  // Seeds the first admin account(s) only; roles are then managed in the database.
  adminEmails: list('BOOTSTRAP_ADMIN_EMAILS', list('ADMIN_EMAILS')),
  // Extra staff accounts (comma list of emails) left out of rider counts and analytics, like admins.
  staffEmails: list('STAFF_EMAILS'),
  // Account gate: how long a users document is trusted before it is read again (status, role, password change).
  userGateTtlMs: int('USER_GATE_TTL_MS', 30000),
  // JWT_SECRET_PREVIOUS (optional, rotation grace): tokens signed with it are still ACCEPTED (never signed);
  // the response carries a fresh X-CoRoute-Token signed with JWT_SECRET. Remove it after the grace period.
  jwtSecretPrevious: (process.env.JWT_SECRET_PREVIOUS || '').trim(),
  // ---- 3.57 sessions & security (src/sessions.js, src/security_routes.js, docs/features_355/sessions_and_security.md) ----
  // Clients that opt in (app builds >= 10025 with X-CoRoute-Session: 2, the website, /admin, /operator) get a short
  // access token plus a rotating refresh token; older app builds keep a long sliding token bound to a session record.
  accessTokenTtlMin: int('ACCESS_TOKEN_TTL_MIN', 15),
  sessionAppAbsoluteDays: int('SESSION_APP_ABSOLUTE_DAYS', 60),
  sessionAppIdleDays: int('SESSION_APP_IDLE_DAYS', 30),
  sessionWebAbsoluteDays: int('SESSION_WEB_ABSOLUTE_DAYS', 7),
  sessionWebIdleMin: int('SESSION_WEB_IDLE_MIN', 60),
  sessionAdminAbsoluteHours: int('SESSION_ADMIN_ABSOLUTE_HOURS', 12),
  sessionAdminIdleMin: int('SESSION_ADMIN_IDLE_MIN', 30),
  // A refresh token presented again within this many seconds of its rotation is a lost reply or a second tab,
  // not theft (the session continues with a new token). Older reuse revokes the whole session.
  refreshReuseGraceSec: int('REFRESH_REUSE_GRACE_SEC', 60),
  // Recent re-authentication window for sensitive actions (password / e-mail change, account deletion, 2FA).
  reauthWindowMin: int('REAUTH_WINDOW_MIN', 10),
  // Failed sign-ins before an account is locked (progressive: 15 min, 30, 60 ... up to 24 h) and the step of the
  // progressive delay added to failed sign-ins after the third (ms; 0 in tests).
  loginLockThreshold: int('LOGIN_LOCK_THRESHOLD', 10),
  loginLockMinutes: int('LOGIN_LOCK_MINUTES', 15),
  loginDelayStepMs: int('LOGIN_DELAY_STEP_MS', isTest ? 0 : 400),
  passwordResetTtlMin: int('PASSWORD_RESET_TTL_MIN', 30),
  // 2-step verification (round 4: default 'all'):
  //   'web'    required for MASTER_ADMIN at the web admin sign-in only;
  //   'all'    'web' + every admin API call needs a 2-step session from clients that know codes: app builds >= 10025
  //            (session kind 'app'; the app asks for the code on MFA_REQUIRED), the web admin, the website and the
  //            operator console. Older app builds (session kind 'legacy') keep the 'web' behaviour so they are not
  //            locked out of their admin screens (retire with MIN_APP_BUILD=10025, then 'strict');
  //   'strict' every admin API call from every client needs a 2-step session; 'off'.
  adminMfaEnforce: oneOf('ADMIN_MFA_ENFORCE', ['off', 'web', 'all', 'strict'], 'all'),
  // ---- round 4: ride lock (src/ride_lock.js) ----
  // While a session's device is on a live ride (solo or group, or has an open SOS / crash alert) and was seen within
  // RIDE_LOCK_STALE_MIN minutes, a sign-in on another device answers 423 RIDE_ACTIVE_ELSEWHERE (e-mail code override).
  rideLockEnabled: String(process.env.RIDE_LOCK || 'on').trim().toLowerCase() !== 'off',
  rideLockStaleMin: Math.max(1, int('RIDE_LOCK_STALE_MIN', 10)),
  // E-mailed one-time codes (ride lock override, e-mail 2-step): lifetime and wrong tries per code.
  emailCodeTtlMin: Math.max(1, int('EMAIL_CODE_TTL_MIN', 10)),
  emailCodeMaxTries: Math.max(1, int('EMAIL_CODE_MAX_TRIES', 5)),
  // ---- round 4: e-mail verification at sign-up (no account enumeration) ----
  // Link lifetime (hours) and the purge of accounts never verified (days).
  registerVerifyTtlHours: Math.max(1, int('REGISTER_VERIFY_TTL_HOURS', 24)),
  registerPurgeDays: Math.max(1, int('REGISTER_PURGE_DAYS', 7)),
  // App builds below 10025 expect a token from /auth/register. 'verify' (production default, the safe option): they
  // get the same e-mail verification as everyone, answered with a readable message they show (no token, no 409);
  // 'allow': the old behaviour for them (201 + token, 409 for a taken address: the enumeration signal stays).
  registerVerifyLegacy: oneOf('REGISTER_VERIFY_LEGACY', ['verify', 'allow'], isTest ? 'allow' : 'verify'),
  // Builds below this one are "legacy" for the round 4 compatibility rules (register, delete, admin 2-step).
  modernAppBuild: int('MODERN_APP_BUILD', 10025),
  // Account deletion from builds before 10025 without a password: confirmation link lifetime (minutes).
  deleteConfirmTtlMin: Math.max(5, int('DELETE_CONFIRM_TTL_MIN', 30)),
  // ---- round 4: WebSocket authentication ----
  // New clients send { type: 'AUTH', token } as their first message (no token in the URL); the socket must
  // authenticate within this many ms. ?token= stays accepted for builds before 10025.
  wsAuthTimeoutMs: Math.max(500, int('WS_AUTH_TIMEOUT_MS', 5000)),
  // Field encryption at rest (src/field_crypto.js): AES-256-GCM key + id, older keys (read only), blind index key.
  dataEncKey: require('./field_crypto').parseKey(process.env.DATA_ENC_KEY, 'DATA_ENC_KEY'),
  dataEncKeyId: (process.env.DATA_ENC_KEY_ID || 'k1').trim(),
  dataEncKeysPrevious: require('./field_crypto').parseKeyList(process.env.DATA_ENC_KEYS_PREVIOUS),
  blindIndexKey: require('./field_crypto').parseKey(process.env.BLIND_INDEX_KEY, 'BLIND_INDEX_KEY'),
  // HSTS sent by the gateway (Caddy may send its own): max-age seconds, includeSubDomains always, preload opt-in.
  hstsMaxAge: int('HSTS_MAX_AGE', 31536000),
  hstsPreload: String(process.env.HSTS_PRELOAD || '').trim().toLowerCase() === 'true',
  // Password hashes (src/password_hash.js): scrypt on the libuv threadpool, scrypt$N$r$p$salt$hash.
  // N = 2^15, r = 8, p = 3 (OWASP scrypt equivalent of N=2^17,p=1): ~300 ms and 32 MiB per hash; the test suite
  // defaults to 2^10. Hashes at older parameters (p = 1) are upgraded at the next sign-in.
  // Legacy bcrypt hashes are verified in a worker thread and re-hashed to scrypt at the next sign-in.
  passwordScryptN: int('PASSWORD_SCRYPT_N', isTest ? 1024 : 32768),
  passwordScryptR: int('PASSWORD_SCRYPT_R', 8),
  passwordScryptP: int('PASSWORD_SCRYPT_P', isTest ? 1 : 3),
  // Concurrent scrypt jobs (each holds a threadpool thread and 128*N*r bytes); the rest queue.
  passwordHashConcurrency: int('PASSWORD_HASH_CONCURRENCY', 2),
  passwordBcryptWorkers: int('PASSWORD_BCRYPT_WORKERS', 1),
  // 32 random bytes, base64 (openssl rand -base64 32). Encrypts admin-saved Razorpay secrets and signs
  // web-checkout links, independent of JWT_SECRET. Legacy (JWT-derived) values are still read and migrated.
  settingsEncryptionKey: settingsKey(process.env.SETTINGS_ENCRYPTION_KEY),

  // Two-VM production: what this node is for. 'live' (VM1: rides, sockets), 'web' (VM2: website, payments,
  // admin), 'all' (single VM, default). Caddy decides routing; the role only decides which node prefers
  // to run scheduled jobs (src/job_lease.js).
  // v3.56 'standby' (DR node, vm3): boots and answers /api/health, never runs scheduled jobs, /api/health/live 503.
  // Promote it by setting GATEWAY_ROLE=all (single node) and restarting (deploy/dr/promote_vm3.sh).
  gatewayRole: oneOf('GATEWAY_ROLE', ['live', 'web', 'all', 'standby'], 'all'),
  // v3.56 performance and operations (docs/infra/INFRASTRUCTURE_PLAN_v3.56.md).
  metricsAllow: list('METRICS_ALLOW', ['loopback']),
  metricsToken: (process.env.METRICS_TOKEN || '').trim(),
  // Above Caddy's upstream keep-alive (60 s in deploy/caddy/*): Node never closes an idle connection Caddy reuses.
  httpKeepAliveMs: int('HTTP_KEEPALIVE_MS', 75000),
  // Graceful stop: answer 503 on /api/health/live for this long before telling sockets to reconnect, so the load
  // balancer has already moved new connections to the other node (0 = at once, the old behaviour).
  shutdownDrainMs: int('SHUTDOWN_DRAIN_MS', 0),
  // /api/health caches a good database ping this long (Caddy, the NLB and watchdogs poll it).
  healthDbCacheMs: int('HEALTH_DB_CACHE_MS', isTest ? 0 : 2000),
  // off behind Caddy (it compresses with zstd/gzip off the event loop); on for a bare node.
  nodeCompression: String(process.env.NODE_COMPRESSION || 'on').toLowerCase() !== 'off',
  // Two-node live mirror (src/mirror.js): off unless MIRROR_LISTEN_HOST or MIRROR_PEER_URL is set. MIRROR_KEY
  // (32+ chars, same on both nodes) authenticates and encrypts the link. LIVE_RIDER_CAP: distinct riders with a
  // live socket on both nodes before new riders get 503 SERVER_BUSY (0 = off).
  nodeName: (process.env.NODE_NAME || '').trim() || require('os').hostname(),
  mirrorListenHost: (process.env.MIRROR_LISTEN_HOST || '').trim(),
  mirrorListenPort: int('MIRROR_LISTEN_PORT', 3101),
  mirrorPeerUrl: (process.env.MIRROR_PEER_URL || '').trim(),
  mirrorKey: (process.env.MIRROR_KEY || '').trim(),
  mirrorAckTimeoutMs: int('MIRROR_ACK_TIMEOUT_MS', 400),
  mirrorHandbackDelayMs: int('MIRROR_HANDBACK_DELAY_MS', 15000),
  mirrorHandbackPerSec: int('MIRROR_HANDBACK_PER_SEC', 25),
  mirrorStartupWaitMs: int('MIRROR_STARTUP_WAIT_MS', 3000),
  mirrorSyncTimeoutMs: int('MIRROR_SYNC_TIMEOUT_MS', 30000),
  liveRiderCap: int('LIVE_RIDER_CAP', 0),
  // Job leases: lease life, renew/poll period, and how long a lease must have been expired before a node
  // of the non-preferred role takes it over.
  jobLeaseTtlMs: int('JOB_LEASE_TTL_MS', 60000),
  jobLeaseHeartbeatMs: int('JOB_LEASE_HEARTBEAT_MS', 15000),
  jobLeaseGraceMs: int('JOB_LEASE_GRACE_MS', 120000),
  // Proxies whose X-Forwarded-For is believed (comma list of IPs, CIDRs or loopback/linklocal/uniquelocal).
  // VM1: loopback (its own Caddy). VM2: loopback,10.0.0.70 (VM1's Caddy forwards web routes over the VCN).
  trustProxy: trustList(process.env.TRUST_PROXY),

  // Joining by code: failed attempts allowed per window, per rider and per network (brute-force guard).
  joinWindowMin: int('JOIN_WINDOW_MIN', 15),
  joinMaxFailures: int('JOIN_MAX_FAILURES', 10),
  joinMaxFailuresPerIp: int('JOIN_MAX_FAILURES_PER_IP', 30),
  // Riders in one convoy (live fan-out is per rider per second; this keeps the small VM healthy).
  maxConvoyRiders: int('MAX_CONVOY_RIDERS', 50),

  // Trip records sent by phones: trail points kept per trip, trips per rider, request size.
  tripMaxTrailPoints: int('TRIP_MAX_TRAIL_POINTS', 4000),
  maxTripsPerUser: int('MAX_TRIPS_PER_USER', 500),
  tripMaxBytes: int('TRIP_MAX_BYTES', 1048576),
  // Website analytics: referrer hosts kept per page per day (the rest are counted as "other").
  pvMaxReferrers: int('PV_MAX_REFERRERS', 50),
  // Socket actions: route, status and settings messages per second; WAIT and SOS per 10 seconds.
  wsActionsPerSec: int('WS_ACTIONS_PER_SEC', 10),
  wsAlarmsPer10s: int('WS_ALARMS_PER_10S', 3),

  // Persistence / retention (zero-maintenance housekeeping)
  // One room snapshot write per live room per interval (src/convoys.js flushRoom).
  riderPersistIntervalMs: int('RIDER_PERSIST_INTERVAL_MS', 15000),
  retentionVoiceLogDays: int('RETENTION_VOICE_LOG_DAYS', 7),
  retentionEndedConvoyDays: int('RETENTION_ENDED_CONVOY_DAYS', 90),
  retentionStaleConvoyHours: int('RETENTION_STALE_CONVOY_HOURS', 36),
  retentionRunEveryMinutes: int('RETENTION_RUN_EVERY_MINUTES', 360),
  keepAliveEveryMinutes: int('DB_KEEPALIVE_EVERY_MINUTES', 720),

  // Voice relay guards
  voiceMaxFrameBytes: int('VOICE_MAX_FRAME_BYTES', 16384),
  voiceStreamIdleMs: int('VOICE_STREAM_IDLE_MS', 1500),
  voiceMaxStreamMs: int('VOICE_MAX_STREAM_MS', 60000),

  // Group tracking and timeline (per-convoy values override these defaults)
  trackMaxPoints: int('TRACK_MAX_POINTS', 120),
  trackRetentionDays: int('TRACK_RETENTION_DAYS', 90),
  // Track chunks older than this are merged per rider into one simplified document (retention.js; 0 = never).
  trackDetailDays: int('TRACK_DETAIL_DAYS', 14),
  trackSimplifyToleranceM: int('TRACK_SIMPLIFY_TOLERANCE_M', 5),
  // Track uploads are written in batches: at most this long a chunk waits, or this many per bulk insert.
  trackBatchFlushMs: int('TRACK_BATCH_FLUSH_MS', 250),
  trackBatchMax: int('TRACK_BATCH_MAX', 50),
  stopRadiusM: int('STOP_RADIUS_M', 50),
  stopExitM: int('STOP_EXIT_M', 60),
  offRouteM: int('OFF_ROUTE_M', 300),
  offlineAlertMinutes: int('OFFLINE_ALERT_MIN', 5),
  // Group speed limit: over (limit + tolerance) for HOLD counts, under the limit for CLEAR ends it.
  overspeedToleranceKmh: int('OVERSPEED_TOLERANCE_KMH', 2),
  // 3.55 alert latency review: 2 s (was 3 s); with fixes every 1-2.5 s that is the second fix over.
  overspeedHoldMs: int('OVERSPEED_HOLD_MS', 2000),
  overspeedClearMs: int('OVERSPEED_CLEAR_MS', 20000),
  overspeedRenotifyMs: int('OVERSPEED_RENOTIFY_MS', 180000),
  stationaryAlertMinutes: int('STATIONARY_ALERT_MIN', 20),
  reachRadiusM: int('REACH_RADIUS_M', 150),
  // 3.55 alert latency review: 2 s (was 30 s). The tick judges what no fix can trigger (OFFLINE, a
  // stale rider, a parked rider's possible incident, sweeper distress, regroup arrival, the end of
  // an overspeed episode); it only compares timestamps, about 4 ms per 1,000 riders
  // (test/timeline_tick_load_355.test.js), and writes only on a change.
  timelineTickMs: int('TIMELINE_TICK_MS', 2000),
  // Phones get this long to upload their last points before the trip report is built,
  // and late uploads within the grace period rebuild it.
  reportDelayMs: int('REPORT_DELAY_MS', isTest ? 0 : 20000),
  reportRebuildMs: int('REPORT_REBUILD_MS', isTest ? 50 : 30000),
  trackUploadGraceMinutes: int('TRACK_UPLOAD_GRACE_MIN', 30),

  // Rider safety (3.14). Possible incident: a hard stop from INCIDENT_FROM_KMH to INCIDENT_STOP_KMH
  // within INCIDENT_STOP_WITHIN_S, then still (inside INCIDENT_STILL_RADIUS_M) for INCIDENT_STILL_S,
  // away (INCIDENT_STOP_NEAR_M) from planned stops: lead(s) and the INCIDENT_NEAREST nearest riders are asked to check.
  incidentFromKmh: int('INCIDENT_FROM_KMH', 40),
  incidentStopKmh: int('INCIDENT_STOP_KMH', 5),
  incidentStopWithinS: int('INCIDENT_STOP_WITHIN_S', 15),
  incidentStillS: int('INCIDENT_STILL_S', 120),
  incidentStillRadiusM: int('INCIDENT_STILL_RADIUS_M', 40),
  incidentStopNearM: int('INCIDENT_STOP_NEAR_M', 300),
  incidentNearest: int('INCIDENT_NEAREST', 2),
  // Stopped together with other riders (fresh, slow, within INCIDENT_GROUP_NEAR_M): a red light, a
  // toll queue or a jam, not a lone rider down. The still time is then INCIDENT_STILL_GROUP_S.
  incidentGroupNearM: int('INCIDENT_GROUP_NEAR_M', 150),
  incidentStillGroupS: int('INCIDENT_STILL_GROUP_S', 300),
  // No signal for NO_SIGNAL_ESCALATE_MIN after riding at NO_SIGNAL_MIN_KMH or more: escalated to the lead.
  noSignalEscalateMin: int('NO_SIGNAL_ESCALATE_MIN', 10),
  noSignalMinKmh: int('NO_SIGNAL_MIN_KMH', 30),
  // Emergency SMS roster (phone numbers for the phone's own SMS fallback).
  rosterPerMin: int('ROSTER_PER_MIN', 6),
  rosterValidH: int('ROSTER_VALID_H', 12),
  smsMaxRecipients: int('SMS_MAX_RECIPIENTS', 10),
  // Socket message dedupe (clientId) per convoy.
  clientIdCache: int('CLIENT_ID_CACHE', 1000),
  clientIdTtlH: int('CLIENT_ID_TTL_H', 6),
  sosRespondersMax: int('SOS_RESPONDERS_MAX', 50),
  medicalAllergiesMax: int('MEDICAL_ALLERGIES_MAX', 120),
  medicalNotesMax: int('MEDICAL_NOTES_MAX', 200),

  // Rider safety network and rider discovery (3.15). Distances in metres, times as named.
  safetyNetEnabled: int('SAFETY_NET_ENABLED', 1) === 1,
  discoveryEnabled: int('DISCOVERY_ENABLED', 1) === 1,
  // v3.58 Explore: admin-curated destinations (src/destinations.js). 0 = the public list is empty.
  destinationsEnabled: int('DESTINATIONS_ENABLED', 1) === 1,
  emergencyExpireMin: int('EMERGENCY_EXPIRE_MIN', 180),
  emergencyCancelGraceS: int('EMERGENCY_CANCEL_GRACE_S', 60),
  emergencyClusterM: int('EMERGENCY_CLUSTER_M', 150),
  emergencyClusterMin: int('EMERGENCY_CLUSTER_MIN', 10),
  netTickMs: int('NET_TICK_MS', 15000),
  netGridMillideg: int('NET_GRID_MILLIDEG', 50),
  netRadius1M: int('NET_RADIUS_1_M', 5000),
  netRadius2M: int('NET_RADIUS_2_M', 10000),
  netRouteAheadMax1M: int('NET_ROUTE_AHEAD_MAX_1_M', 15000),
  netRouteAheadMax2M: int('NET_ROUTE_AHEAD_MAX_2_M', 25000),
  netRouteLateralM: int('NET_ROUTE_LATERAL_M', 150),
  netRouteLateralMaxM: int('NET_ROUTE_LATERAL_MAX_M', 300),
  netOnRouteM: int('NET_ON_ROUTE_M', 300),
  netPassedTolM: int('NET_PASSED_TOL_M', 150),
  netHeadingTolDeg: int('NET_HEADING_TOL_DEG', 60),
  netMaxAccuracyM: int('NET_MAX_ACCURACY_M', 500),
  netFallbackRadiusPct: int('NET_FALLBACK_RADIUS_PCT', 60),
  netFallbackLateralM: int('NET_FALLBACK_LATERAL_M', 250),
  netFallbackMinKmh: int('NET_FALLBACK_MIN_KMH', 15),
  netDetourPct: int('NET_DETOUR_PCT', 140),
  netDefaultKmh: int('NET_DEFAULT_KMH', 40),
  netMinKmh: int('NET_MIN_KMH', 20),
  netMaxKmh: int('NET_MAX_KMH', 80),
  netStoppedPenaltyS: int('NET_STOPPED_PENALTY_S', 120),
  netUturnPenaltyS: int('NET_UTURN_PENALTY_S', 60),
  netEtaMarginS: int('NET_ETA_MARGIN_S', 60),
  netNotifyMax: int('NET_NOTIFY_MAX', 3),
  netPerGroup: int('NET_PER_GROUP', 2),
  netPendingMax: int('NET_PENDING_MAX', 3),
  netRequestTimeoutS: int('NET_REQUEST_TIMEOUT_S', 60),
  netEscalateAfterS: int('NET_ESCALATE_AFTER_S', 60),
  netFreshS: int('NET_FRESH_S', 120),
  netMaxIncidents: int('NET_MAX_INCIDENTS', 50),
  netMaxCandidatesEval: int('NET_MAX_CANDIDATES_EVAL', 200),
  netArrivingM: int('NET_ARRIVING_M', 500),
  netArriveM: int('NET_ARRIVE_M', 100),
  netSubjectUpdateMs: int('NET_SUBJECT_UPDATE_MS', 10000),
  netSubjectUpdateM: int('NET_SUBJECT_UPDATE_M', 30),
  netDriftPct: int('NET_DRIFT_PCT', 200),
  netDriftMinS: int('NET_DRIFT_MIN_S', 300),
  netOsrmPerIncident: int('NET_OSRM_PER_INCIDENT', 2),
  netOsrmSources: int('NET_OSRM_SOURCES', 3),
  netOsrmTimeoutMs: int('NET_OSRM_TIMEOUT_MS', 3000),
  netOsrmPerMin: int('NET_OSRM_PER_MIN', 6),
  netOsrmMaxWaitMs: int('NET_OSRM_MAX_WAIT_MS', 2000),
  netOsrmCache: int('NET_OSRM_CACHE', 500),
  netOsrmCacheMin: int('NET_OSRM_CACHE_MIN', 10),
  netRoadRatioPct: int('NET_ROAD_RATIO_PCT', 250),
  netFallbackNoOsrmM: int('NET_FALLBACK_NO_OSRM_M', 2000),
  netRouteSimplifyM: int('NET_ROUTE_SIMPLIFY_M', 15),
  netRouteMaxPoints: int('NET_ROUTE_MAX_POINTS', 3000),
  netReportMaxM: int('NET_REPORT_MAX_M', 2000),
  reportDownPer10Min: int('REPORT_DOWN_PER_10MIN', 2),
  reportFalsePerH: int('REPORT_FALSE_PER_H', 5),
  netFalseReportsFlag: int('NET_FALSE_REPORTS_FLAG', 2),
  hazardAheadM: int('HAZARD_AHEAD_M', 6000),
  hazardMaxRecipients: int('HAZARD_MAX_RECIPIENTS', 100),
  abuseFalseAlarms: int('ABUSE_FALSE_ALARMS', 3),
  abuseWindowD: int('ABUSE_WINDOW_D', 30),
  netAbuserNotify: int('NET_ABUSER_NOTIFY', 1),
  netAbuserDelayS: int('NET_ABUSER_DELAY_S', 60),
  discoveryTickMs: int('DISCOVERY_TICK_MS', 60000),
  discoveryRadiusM: int('DISCOVERY_RADIUS_M', 8000),
  discoveryMeetMaxS: int('DISCOVERY_MEET_MAX_S', 600),
  discoveryEndM: int('DISCOVERY_END_M', 15000),
  discoveryRenotifyMin: int('DISCOVERY_RENOTIFY_MIN', 60),
  discoveryWaveGapMin: int('DISCOVERY_WAVE_GAP_MIN', 5),
  discoveryLateralM: int('DISCOVERY_LATERAL_M', 300),
  discoveryCrossWindowS: int('DISCOVERY_CROSS_WINDOW_S', 180),
  // Public ride, safe contact and road warnings (src/public_ride.js). Every plan; off per ride by default.
  publicRideEnabled: int('PUBLIC_RIDE_ENABLED', 1) === 1,
  publicRideTickMs: int('PUBLIC_RIDE_TICK_MS', 30000),
  publicRideSnapM: int('PUBLIC_RIDE_SNAP_M', 500),
  publicRideParkMin: int('PUBLIC_RIDE_PARK_MIN', 10),
  publicRideRequestMin: int('PUBLIC_RIDE_REQUEST_MIN', 10),
  publicRideChannelMin: int('PUBLIC_RIDE_CHANNEL_MIN', 30),
  publicRideBlockDays: int('PUBLIC_RIDE_BLOCK_DAYS', 30),
  publicRideSuspendBlocks: int('PUBLIC_RIDE_SUSPEND_BLOCKS', 3),
  publicRideSuspendDays: int('PUBLIC_RIDE_SUSPEND_DAYS', 7),
  roadWarnConfirms: int('ROAD_WARN_CONFIRMS', 2),
  roadWarnNearM: int('ROAD_WARN_NEAR_M', 5000),
  roadWarnReachM: int('ROAD_WARN_REACH_M', 20000),
  roadWarnMergeM: int('ROAD_WARN_MERGE_M', 1000),
  auditRetentionDays: int('AUDIT_RETENTION_DAYS', 180),

  // 3.16 safety round. "Far by road": after escalation, the best candidate the road check rejected is
  // still asked when its road ETA is under NET_FAR_MAX_ETA_S.
  netFarMaxEtaS: int('NET_FAR_MAX_ETA_S', 900),
  // Stale rider: no fix for max(STALE_MIN_S, STALE_FACTOR x the group's typical gap) while moving.
  staleMinS: int('STALE_MIN_S', 90),
  staleFactor: int('STALE_FACTOR', 3),
  // Sweeper: a rider this far behind the sweeper (held 60 s) is reported to the sweeper and lead.
  sweeperBehindM: int('SWEEPER_BEHIND_M', 300),
  // Convoy sub-clustering & safety watchdog (REQ-11, REQ-12, REQ-13)
  convoySplitThresholdM: int('CONVOY_SPLIT_THRESHOLD_M', 1200),
  convoySplitHoldS: int('CONVOY_SPLIT_HOLD_S', 45),
  regroupReachRadiusM: int('REGROUP_REACH_RADIUS_M', 150),
  regroupTimeoutMin: int('REGROUP_TIMEOUT_MIN', 25),
  sweeperHaltKmh: int('SWEEPER_HALT_KMH', 5),
  sweeperPackMovingKmh: int('SWEEPER_PACK_MOVING_KMH', 35),
  sweeperDistressHoldS: int('SWEEPER_DISTRESS_HOLD_S', 90),
  // Low battery: alert at or under BATTERY_LOW_PCT (not charging), closed at BATTERY_OK_PCT or charging.
  batteryLowPct: int('BATTERY_LOW_PCT', 15),
  batteryOkPct: int('BATTERY_OK_PCT', 25),
  // Lower "town" speed limit applies within TOWN_RADIUS_M of the start, planned stops and the destination.
  townRadiusM: int('TOWN_RADIUS_M', 1000),
  // Live emergency links: life in minutes, links per alert.
  liveLinkMin: int('LIVE_LINK_MIN', 30),
  liveLinkPerAlert: int('LIVE_LINK_PER_ALERT', 3),
  // Nearest hospital lookup is skipped when the polite OSM queue would wait longer than this.
  hospitalMaxWaitMs: int('HOSPITAL_MAX_WAIT_MS', 5000),
  // Weather on the route (Open-Meteo, free, no key). Empty WEATHER_URL disables it. The only new outbound host of 3.16.
  weatherUrl: (process.env.WEATHER_URL ?? (isTest ? '' : 'https://api.open-meteo.com')).trim().replace(/\/+$/, ''),
  weatherCacheMin: int('WEATHER_CACHE_MIN', 30),
  weatherPerMin: int('WEATHER_PER_MIN', 20),
  weatherUserPerMin: int('WEATHER_USER_PER_MIN', 6),

  // Free OpenStreetMap services, proxied and cached by the gateway (empty = disabled).
  geoSearchUrl: (process.env.GEO_SEARCH_URL ?? (isTest ? '' : 'https://nominatim.openstreetmap.org')).trim().replace(/\/+$/, ''),
  geoRouteUrl: (process.env.GEO_ROUTE_URL ?? (isTest ? '' : 'https://router.project-osrm.org')).trim().replace(/\/+$/, ''),
  // Search-as-you-type: Photon (built for it). Nominatim stays for reverse lookups only.
  geoPhotonUrl: (process.env.GEO_PHOTON_URL ?? (isTest ? '' : 'https://photon.komoot.io')).trim().replace(/\/+$/, ''),
  geoCountry: (process.env.GEO_COUNTRY || 'in').trim().toLowerCase(),
  // minLon,minLat,maxLon,maxLat of the home country (India incl. all of J&K and Ladakh).
  geoCountryBbox: (process.env.GEO_COUNTRY_BBOX || '68.0,6.4,97.6,37.1').split(',').map(Number),
  geoPhotonMinIntervalMs: int('GEO_PHOTON_MIN_INTERVAL_MS', 250),
  geoReverseTimeoutMs: int('GEO_REVERSE_TIMEOUT_MS', 8000),
  geoContact: (process.env.GEO_CONTACT || SUPPORT_EMAIL).trim(),
  geoCacheDays: int('GEO_CACHE_DAYS', 30),
  geoMinIntervalMs: int('GEO_MIN_INTERVAL_MS', 1100),

  // Website: where the "Download" buttons send people. Play Store URL once the listing is live,
  // otherwise the APKs served by this gateway from public/ (see deploy/RUNBOOK.md section 4).
  // PLAY_STORE_URL (https only) also turns on the website's <!--play--> blocks: the "Rate CoRoute on Google Play"
  // button. Empty: those blocks are left out and the <!--no-play--> text shows instead (src/pages.js).
  // Empty APK_URL / APK_ARM32_URL mean <origin>/coroute.apk and <origin>/coroute-32bit.apk.
  playStoreUrl: (process.env.PLAY_STORE_URL || '').trim(),
  apkUrl: (process.env.APK_URL || '').trim(),
  apkArm32Url: (process.env.APK_ARM32_URL || '').trim(),
  apkPath: '/coroute.apk',
  apkArm32Path: '/coroute-32bit.apk',
  appStoreUrl: (process.env.APP_STORE_URL || '').trim(),
  iosTestFlightUrl: (process.env.IOS_TESTFLIGHT_URL || '').trim(),
  iosIpaUrl: (process.env.IOS_IPA_URL || '').trim(),
  iosIpaPath: '/coroute.ipa',
  publicOrigin: (process.env.PUBLIC_ORIGIN || '').trim().replace(/\/+$/, ''),
  // Domain move (src/domains.js, docs/DOMAIN_MIGRATION_devmonks.md): origins still served for installed apps
  // and old links (CORS / guardian Origin checks accept them), and the opt-in 301 of website pages on them.
  legacyOrigins: list('LEGACY_ORIGINS', ['https://coroute.duckdns.org']),
  redirectLegacyHost: process.env.REDIRECT_LEGACY_HOST === 'true',
  // App version gate: builds older than MIN_APP_BUILD are told to update (versionCode from pubspec "x.y.z+N").
  minAppBuild: int('MIN_APP_BUILD', 60),
  latestAppBuild: int('LATEST_APP_BUILD', 10019),
  supportEmail: SUPPORT_EMAIL,
  securityContact: SECURITY_CONTACT,

  // Payment Screen & Subscription Gating Toggle
  // When false: disables payment screens and unlocks plan-based features for all users.
  // When true (default): enables subscription plans, payment screens, and tier-based feature gating.
  paymentsEnabled: process.env.PAYMENTS_ENABLED === 'true' || (process.env.NODE_ENV !== 'test' && process.env.PAYMENTS_ENABLED !== 'false'),

  // CORS: comma separated origins or empty for same-origin/mobile only
  corsOrigins: list('CORS_ORIGINS'),

  // Telephony & Server Emergency Gateway (Twilio / AWS SNS / Infobip / Webhook / WhatsApp Business)
  telephonyPrimaryProvider: (process.env.TELEPHONY_PRIMARY_PROVIDER || 'twilio').trim().toLowerCase(),
  telephonySecondaryProvider: (process.env.TELEPHONY_SECONDARY_PROVIDER || 'webhook').trim().toLowerCase(),
  twilioAccountSid: (process.env.TWILIO_ACCOUNT_SID || '').trim(),
  twilioAuthToken: (process.env.TWILIO_AUTH_TOKEN || '').trim(),
  twilioFromNumber: (process.env.TWILIO_FROM_NUMBER || process.env.TWILIO_PHONE_NUMBER || '').trim(),
  awsSnsRegion: (process.env.AWS_SNS_REGION || 'ap-south-1').trim(),
  awsAccessKeyId: (process.env.AWS_ACCESS_KEY_ID || '').trim(),
  awsSecretAccessKey: (process.env.AWS_SECRET_ACCESS_KEY || '').trim(),
  awsSnsTopicArn: (process.env.AWS_SNS_TOPIC_ARN || '').trim(),
  infobipApiKey: (process.env.INFOBIP_API_KEY || '').trim(),
  infobipBaseUrl: (process.env.INFOBIP_BASE_URL || '').trim().replace(/\/+$/, ''),
  telephonyWebhookUrl: (process.env.TELEPHONY_WEBHOOK_URL || '').trim(),
  telephonyWebhookToken: (process.env.TELEPHONY_WEBHOOK_TOKEN || '').trim(),
  whatsappApiUrl: (process.env.WHATSAPP_API_URL || 'https://graph.facebook.com/v20.0').trim().replace(/\/+$/, ''),
  whatsappPhoneNumberId: (process.env.WHATSAPP_PHONE_NUMBER_ID || '').trim(),
  whatsappApiToken: (process.env.WHATSAPP_API_TOKEN || '').trim(),

  // Razorpay: keys, test/live mode and webhook secrets are resolved by
  // src/razorpay_gateway.js (admin settings in Oracle, else environment).
  // No credentials are hard-coded.
  // Payments go through Razorpay only (no direct VPA / UTR path). The name below is
  // only the display name shown in Razorpay Checkout.
  razorpayUpiOnly: true,
  upiMerchantName: 'CoRoute',

  // Photos riders attach to post-trip reviews. A private data folder OUTSIDE public/: nothing in it is
  // served as a static file; routes check consent and approval for every photo (src/review_photos.js).
  reviewPhotoDir: (process.env.REVIEW_PHOTO_DIR || '').trim()
    || (isTest ? require('path').join(require('os').tmpdir(), `coroute-review-photos-${process.pid}`)
      : require('path').join(__dirname, '..', 'data', 'review-photos')),
  // Review photo storage: 'disk' (reviewPhotoDir) or 'par' (OCI Object Storage via a bucket PAR; never sent to clients).
  reviewPhotoStore: (process.env.REVIEW_PHOTO_STORE || 'disk').trim().toLowerCase(),
  reviewPhotoParUrl: (process.env.REVIEW_PHOTO_PAR_URL || '').trim(),
};

// User-Agent for the map-data providers (Nominatim, Photon, Overpass ask for a contact): the gateway
// version, this site's origin and the contact address, in one place.
// Origin for links built outside a request: PUBLIC_ORIGIN, else the legacy host that is live today.
config.linkOrigin = require('./domains').linkOriginOf(config);
config.providerUserAgent = `CoRoute/${require('../package.json').version} (+${config.linkOrigin}${config.geoContact ? `; ${config.geoContact}` : ''})`;

if (!isTest && config.jwtSecret.length < 32) {
  throw new Error('[config] JWT_SECRET must be at least 32 characters');
}
if (config.jwtSecretPrevious && (config.jwtSecretPrevious.length < 32 || config.jwtSecretPrevious === config.jwtSecret)) {
  throw new Error('[config] JWT_SECRET_PREVIOUS must be at least 32 characters and differ from JWT_SECRET');
}

module.exports = config;
