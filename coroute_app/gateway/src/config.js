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
  auditRetentionDays: int('AUDIT_RETENTION_DAYS', 180),

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
  latestAppBuild: int('LATEST_APP_BUILD', 75),
  supportEmail: (process.env.SUPPORT_EMAIL || 'santhoshbukka5@gmail.com').trim(),

  // CORS: comma separated origins or empty for same-origin/mobile only
  corsOrigins: list('CORS_ORIGINS'),
};

if (!isTest && config.jwtSecret.length < 32) {
  throw new Error('[config] JWT_SECRET must be at least 32 characters');
}

module.exports = config;
