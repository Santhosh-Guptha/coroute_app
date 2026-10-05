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
  geoContact: (process.env.GEO_CONTACT || process.env.SUPPORT_EMAIL || 'santhoshbukka5@gmail.com').trim(),
  geoCacheDays: int('GEO_CACHE_DAYS', 30),
  geoMinIntervalMs: int('GEO_MIN_INTERVAL_MS', 1100),

  // Website: where the "Download" button sends people. Play Store URL once the listing is live,
  // otherwise the GitHub release page. Changing these needs no rebuild of the site.
  playStoreUrl: (process.env.PLAY_STORE_URL || '').trim(),
  apkUrl: (process.env.APK_URL || 'https://github.com/Santhosh-Guptha/coroute_app/releases/latest').trim(),
  publicOrigin: (process.env.PUBLIC_ORIGIN || '').trim().replace(/\/+$/, ''),
  // App version gate: builds older than MIN_APP_BUILD are told to update (versionCode from pubspec "x.y.z+N").
  minAppBuild: int('MIN_APP_BUILD', 60),
  latestAppBuild: int('LATEST_APP_BUILD', 63),
  supportEmail: (process.env.SUPPORT_EMAIL || 'santhoshbukka5@gmail.com').trim(),

  // CORS: comma separated origins or empty for same-origin/mobile only
  corsOrigins: list('CORS_ORIGINS'),
};

if (!isTest && config.jwtSecret.length < 32) {
  throw new Error('[config] JWT_SECRET must be at least 32 characters');
}

module.exports = config;
