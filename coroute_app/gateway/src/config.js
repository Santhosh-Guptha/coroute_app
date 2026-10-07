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
  googleClientIds: list('GOOGLE_CLIENT_IDS'),
  // Seeds the first admin account(s) only; roles are then managed in the database.
  adminEmails: list('BOOTSTRAP_ADMIN_EMAILS', list('ADMIN_EMAILS')),
  // Account gate: how long a users document is trusted before it is read again (status, role, password change).
  userGateTtlMs: int('USER_GATE_TTL_MS', 30000),

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
  riderPersistIntervalMs: int('RIDER_PERSIST_INTERVAL_MS', 5000),
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
  stopRadiusM: int('STOP_RADIUS_M', 50),
  stopExitM: int('STOP_EXIT_M', 60),
  offRouteM: int('OFF_ROUTE_M', 300),
  offlineAlertMinutes: int('OFFLINE_ALERT_MIN', 5),
  // Group speed limit: over (limit + tolerance) for HOLD counts, under the limit for CLEAR ends it.
  overspeedToleranceKmh: int('OVERSPEED_TOLERANCE_KMH', 2),
  overspeedHoldMs: int('OVERSPEED_HOLD_MS', 10000),
  overspeedClearMs: int('OVERSPEED_CLEAR_MS', 20000),
  overspeedRenotifyMs: int('OVERSPEED_RENOTIFY_MS', 600000),
  stationaryAlertMinutes: int('STATIONARY_ALERT_MIN', 20),
  reachRadiusM: int('REACH_RADIUS_M', 150),
  timelineTickMs: int('TIMELINE_TICK_MS', 30000),
  // Phones get this long to upload their last points before the trip report is built,
  // and late uploads within the grace period rebuild it.
  reportDelayMs: int('REPORT_DELAY_MS', isTest ? 0 : 20000),
  reportRebuildMs: int('REPORT_REBUILD_MS', isTest ? 50 : 30000),
  trackUploadGraceMinutes: int('TRACK_UPLOAD_GRACE_MIN', 30),

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
  geoContact: (process.env.GEO_CONTACT || process.env.SUPPORT_EMAIL || 'santhoshbukka5@gmail.com').trim(),
  geoCacheDays: int('GEO_CACHE_DAYS', 30),
  geoMinIntervalMs: int('GEO_MIN_INTERVAL_MS', 1100),

  // Website: where the "Download" buttons send people. Play Store URL once the listing is live,
  // otherwise the APKs served by this gateway from public/ (see deploy/RUNBOOK.md section 4).
  // Empty APK_URL / APK_ARM32_URL mean <origin>/coroute.apk and <origin>/coroute-32bit.apk.
  playStoreUrl: (process.env.PLAY_STORE_URL || '').trim(),
  apkUrl: (process.env.APK_URL || '').trim(),
  apkArm32Url: (process.env.APK_ARM32_URL || '').trim(),
  apkPath: '/coroute.apk',
  apkArm32Path: '/coroute-32bit.apk',
  publicOrigin: (process.env.PUBLIC_ORIGIN || '').trim().replace(/\/+$/, ''),
  // App version gate: builds older than MIN_APP_BUILD are told to update (versionCode from pubspec "x.y.z+N").
  minAppBuild: int('MIN_APP_BUILD', 60),
  latestAppBuild: int('LATEST_APP_BUILD', 72),
  supportEmail: (process.env.SUPPORT_EMAIL || 'santhoshbukka5@gmail.com').trim(),

  // CORS: comma separated origins or empty for same-origin/mobile only
  corsOrigins: list('CORS_ORIGINS'),
};

if (!isTest && config.jwtSecret.length < 32) {
  throw new Error('[config] JWT_SECRET must be at least 32 characters');
}

module.exports = config;
