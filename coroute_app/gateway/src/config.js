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

  // CORS: comma separated origins or empty for same-origin/mobile only
  corsOrigins: list('CORS_ORIGINS'),
};

if (!isTest && config.jwtSecret.length < 32) {
  throw new Error('[config] JWT_SECRET must be at least 32 characters');
}

module.exports = config;
