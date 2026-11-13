'use strict';
/**
 * HTTP surface of the road & safety intelligence (docs/handbook/technical/api_reference.md §Road & safety intelligence).
 *
 * Rider (signed in):
 *   GET  /api/intel/info                    what is collected, k-min, retention (also public)
 *   GET  /api/intel/consent                 { on, at, promptedAt }
 *   PUT  /api/intel/consent                 { on, prompted? }  "Help make roads safer" (opt-in)
 *   POST /api/intel/events                  { events: [{type, gh, hb, sb, ts, conf}] }  consenting riders only
 *   POST /api/intel/crash                   { id, features, outcome }   crash alarm features (crash brain)
 *   POST /api/intel/crash/feedback          { id, real }                "Was this a real crash?"
 *   GET  /api/intel/crash-params?model=     approved crash brain params (or none), version + checksum
 *   GET  /api/intel/hazards|road-quality|stops|twisty?bbox=s,w,n,e | ?tiles=tdr1,tdr4
 *   GET  /api/intel/ride-tip?lat=&lng=      pre-ride tip for the region and hour, or { tip: null }
 *   POST /api/intel/fuel-gaps               { polyline | points, fuel?, gapKm? }
 *   GET  /api/intel/me/contributions        export my contributions (raw rows ≤ 90 days)
 *   DELETE /api/intel/me/contributions      delete my contributions
 * Admin (MASTER_ADMIN): /api/admin/intel/* (overview, layers with filters and CSV, crash brain, purge, rider requests).
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth, requireAdmin } = require('../auth');
const { IntelEngine } = require('./engine');
const { intelConfig } = require('./config');
const gh = require('./geohash');
const { decodePolyline } = require('../geo_math');

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function areaOf(q) {
  if (q.tiles) return { tiles: String(q.tiles).split(',').map((s) => s.trim()).filter(Boolean) };
  const p = String(q.bbox || '').split(',').map(Number);
  if (p.length !== 4 || !p.every(Number.isFinite)) throw Object.assign(new Error('bbox=s,w,n,e or tiles= is required.'), { status: 400, code: 'INVALID_BBOX' });
  const [s, w, n, e] = p;
  if (Math.abs(s) > 90 || Math.abs(n) > 90 || Math.abs(w) > 180 || Math.abs(e) > 180 || s > n || w > e) throw Object.assign(new Error('Invalid bbox.'), { status: 400, code: 'INVALID_BBOX' });
  return { bbox: { s, w, n, e } };
}

function lineOf(body) {
  if (typeof body?.polyline === 'string' && body.polyline.length <= 200000) return decodePolyline(body.polyline, 20000);
  if (Array.isArray(body?.points)) return body.points.slice(0, 20000).map((p) => ({ lat: Number(p?.lat), lng: Number(p?.lng) })).filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng));
  return [];
}

const INFO = (cfg) => ({
  collecting: cfg.enabled && !cfg.killed,
  consent: 'opt-in ("Help make roads safer"); off by default',
  kMin: cfg.kMin, rawDays: cfg.rawDays, halfLifeDays: cfg.halfLifeDays, trimM: cfg.trimM,
  collected: ['hard braking, swerve, skid, pothole and rough-road events (cell of about 150 m, direction, speed band, hour)',
    'SOS and crash alerts you raise (cell only)', 'crash alarm sensor numbers and their outcome (no position)',
    'per-ride road counters (cells of about 1 km: distance, moving time, turning, stops of 4-90 min)'],
  never: ['full tracks', 'medical data', 'phone numbers', 'the first and last 300 m of a ride', 'your name or rider id (a monthly one-way hash only)'],
  weather: 'not used (no unrestricted free source)',
});

function csvOf(rows, cols) {
  const esc = (v) => { const s = v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  return [cols.join(','), ...rows.map((r) => cols.map((c) => esc(r[c])).join(','))].join('\n') + '\n';
}

/** Our own errors carry a status and a code: answer them as { error, code }; anything else goes to the app's handler. */
function codedErrors(err, req, res, next) {
  if (res.headersSent || !err || !err.code || !(err.status >= 400 && err.status < 500)) return next(err);
  res.status(err.status).json({ error: err.message, code: err.code });
}

function attachIntel({ app, soda, repo, gate, lease, convoys, mirror, poiCells = null, logger = console, jwtSecret, clock, audit = null }) {
  const intel = new IntelEngine({ soda, repo, logger, jwtSecret, poiCells, ...(clock ? { clock } : {}) });
  if (mirror) mirror.register('ic', intel.consent);
  if (convoys) {
    convoys.on('telemetry', (gid, rider) => intel.onTelemetry(gid, rider));
    convoys.on('roomEnded', (gid) => intel.onRoomEnded(gid));
    convoys.on('emergency', (gid, alert, kind) => intel.onEmergency(gid, alert, kind));
    convoys.intel = intel;
  }
  // Account erase: consent record and raw rows go with the account (anonymous decayed totals cannot be split).
  if (repo && !repo.__intelCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__intelCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) {
        await intel.deleteContributions(user.userId).catch(() => {});
        await intel.consent.forget(user.userId).catch(() => {});
      }
      return out;
    };
  }

  const per = (windowMs, limit) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, validate: false,
    keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many requests. Try again in a moment.', code: 'RATE_LIMITED' } });
  const readLimiter = per(60000, 60);
  const postLimiter = per(60 * 60000, 120);

  const r = express.Router();
  r.get('/info', (req, res) => res.set('Cache-Control', 'public, max-age=300').json(INFO(intelConfig())));
  r.use(requireAuth(gate));

  r.get('/consent', wrap(async (req, res) => res.json(await intel.consent.view(req.user.userId))));
  r.put('/consent', postLimiter, wrap(async (req, res) => {
    if (typeof req.body?.on !== 'boolean') return res.status(400).json({ error: 'on must be true or false.', code: 'INVALID' });
    const source = req.body.source === 'web' ? 'web' : req.body.prompted ? 'prompt' : 'app';
    const out = await intel.consent.set(req.user.userId, req.body.on, { source, prompted: !!req.body.prompted });
    // Turning it off stops collection at once (open ride counters are thrown away).
    if (!req.body.on) for (const [k, a] of [...intel.acc.entries()]) if (a.uid === req.user.userId) intel._closeAcc(k, { discard: true });
    res.json(out);
  }));
  r.post('/events', postLimiter, wrap(async (req, res) => res.status(202).json(await intel.ingestEvents(req.user.userId, req.body?.events))));
  r.post('/crash', postLimiter, wrap(async (req, res) => res.status(202).json(await intel.ingestCrash(req.user.userId, req.body))));
  r.post('/crash/feedback', postLimiter, wrap(async (req, res) => res.json(await intel.crashFeedback(req.user.userId, req.body))));
  r.get('/crash-params', readLimiter, wrap(async (req, res) => res.set('Cache-Control', 'private, max-age=3600').json(await intel.crashParams(String(req.query.model || '').slice(0, 60)))));

  const layer = (fn) => wrap(async (req, res) => {
    const area = areaOf(req.query);
    const cells = await fn(area);
    IntelEngine.sendJson(req, res, { version: 1, kMin: intelConfig().kMin, cells, attribution: 'CoRoute riders (anonymous, k-anonymous cells)' });
  });
  r.get('/hazards', readLimiter, layer((a) => intel.hazards(a)));
  r.get('/road-quality', readLimiter, layer((a) => intel.roadQuality(a)));
  r.get('/stops', readLimiter, layer((a) => intel.stops(a)));
  r.get('/twisty', readLimiter, layer((a) => intel.twisty(a)));
  r.get('/ride-tip', readLimiter, wrap(async (req, res) => {
    const lat = Number(req.query.lat), lng = Number(req.query.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return res.status(400).json({ error: 'lat and lng are required.', code: 'INVALID' });
    res.set('Cache-Control', 'private, max-age=900').json((await intel.rideTip(lat, lng)) || { tip: null });
  }));
  r.post('/fuel-gaps', readLimiter, wrap(async (req, res) => {
    const line = lineOf(req.body);
    if (line.length < 2) return res.status(400).json({ error: 'A route line is required.', code: 'INVALID' });
    const gapKm = Number(req.body?.gapKm);
    res.json(await intel.fuelGaps(line, { fuel: req.body?.fuel, ...(Number.isFinite(gapKm) && gapKm >= 20 && gapKm <= 400 ? { gapKm } : {}) }));
  }));
  r.get('/me/contributions', readLimiter, wrap(async (req, res) => {
    res.set('Content-Disposition', 'attachment; filename="coroute-road-contributions.json"').json({ exportedAt: Date.now(), rows: await intel.exportContributions(req.user.userId),
      note: 'Rows from the last 90 days. Older contributions exist only inside anonymous, decayed totals.' });
  }));
  r.delete('/me/contributions', postLimiter, wrap(async (req, res) => {
    const out = await intel.deleteContributions(req.user.userId);
    res.json({ ...out, message: 'Your road and safety contributions from the last 90 days are being removed (within a few minutes). Older ones exist only as anonymous totals that cannot be traced to you or split out.' });
  }));
  r.use(codedErrors);
  app.use('/api/intel', r);

  // ------------------------------------------------------------------ admin
  const a = express.Router();
  a.use(requireAuth(gate), requireAdmin);
  a.get('/overview', wrap(async (req, res) => {
    const cfg = intelConfig();
    res.json({ health: await intel.health(), consent: await intel.consent.counts().catch(() => null),
      settings: { enabled: cfg.enabled, killed: cfg.killed, kMin: cfg.kMin, rawDays: cfg.rawDays, halfLifeDays: cfg.halfLifeDays, trimM: cfg.trimM,
        crashBrainMode: cfg.crashBrainMode, routerKind: cfg.routerKind, fuelGapKm: cfg.fuelGapKm, hashKey: cfg.hashKey ? 'set' : 'derived' },
      stats: intel.stats, leases: lease ? Object.fromEntries(Object.entries(lease.status()).filter(([k]) => k.startsWith('intel-'))) : {} });
  }));
  const adminLayer = (name, fn, cols) => a.get(`/${name}`, wrap(async (req, res) => {
    // No area: the India-wide view (the layer is walked in pages; admin only, low volume).
    const area = req.query.bbox || req.query.tiles ? areaOf(req.query) : { all: true, bbox: { s: 5, w: 67, n: 38, e: 99 } };
    let cells = await fn(area);
    const type = String(req.query.type || '');
    if (type) cells = cells.filter((c) => c.kind === type || (c.counts && c.counts[type] > 0));
    const sinceDays = Number(req.query.sinceDays);
    if (Number.isFinite(sinceDays) && sinceDays > 0) cells = cells.filter((c) => !c.updatedAt || c.updatedAt >= Date.now() - sinceDays * 86400000);
    if (req.query.format === 'csv') {
      return res.type('text/csv').set('Content-Disposition', `attachment; filename="coroute-${name}.csv"`).send(csvOf(cells, cols));
    }
    res.json({ cells, kMin: intelConfig().kMin });
  }));
  adminLayer('hazards', (ar) => intel.hazards(ar, { admin: true, minScore: 0 }), ['gh', 'lat', 'lng', 'kind', 'level', 'score', 'rawScore', 'riders', 'counts', 'dirs', 'updatedAt']);
  adminLayer('road-quality', (ar) => intel.roadQuality(ar, { admin: true, minScore: 0 }), ['gh', 'lat', 'lng', 'kind', 'score', 'riders', 'counts', 'dirs']);
  adminLayer('stops', (ar) => intel.stops(ar, { admin: true }), ['gh', 'lat', 'lng', 'typicalMin', 'popularity', 'riders', 'stops', 'place', 'fuel']);
  adminLayer('twisty', (ar) => intel.twisty(ar, { admin: true, minScore: 0 }), ['gh', 'lat', 'lng', 'score', 'ghat', 'degPerKm', 'km', 'riders']);
  a.get('/dangerous-times', wrap(async (req, res) => {
    const list = await intel.dangerousTimes({ limit: 100 });
    if (req.query.format === 'csv') return res.type('text/csv').set('Content-Disposition', 'attachment; filename="coroute-dangerous-times.csv"').send(csvOf(list.map((x) => ({ ...x, window: `${x.window.dayType} ${x.window.from}:00-${x.window.to}:00 (${x.window.share}%)` })), ['region', 'lat', 'lng', 'score', 'topType', 'window']));
    res.json({ regions: list, kMin: intelConfig().kMin, weather: 'excluded: needs a licensed weather source' });
  }));
  a.get('/crash-brain', wrap(async (req, res) => {
    const meta = await intel._meta('crash_brain').catch(() => null);
    res.json({ mode: intelConfig().crashBrainMode, minLabels: intelConfig().crashBrainMinLabels, scaleMax: require('./crash_brain').SCALE_MAX, brain: meta });
  }));
  a.post('/crash-brain/train', wrap(async (req, res) => {
    const out = await intel.trainCrashBrain();
    res.json({ total: out.total, version: (await intel._meta('crash_brain'))?.version || 0 });
  }));
  a.post('/crash-brain/approve', wrap(async (req, res) => {
    const by = req.user.email || req.user.userId;
    const out = await intel.approveCrashBrain({ version: req.body?.version, by });
    try { audit?.record?.('INTEL_CRASH_BRAIN_APPROVE', { by, version: out.version }); } catch { /* audit is best effort */ }
    logger.info?.(`[intel] crash brain v${out.version} approved by an admin`);
    res.json({ approved: out });
  }));
  a.post('/crash-brain/rollback', wrap(async (req, res) => {
    const out = await intel.rollbackCrashBrain({ by: req.user.email || req.user.userId });
    logger.info?.('[intel] crash brain rolled back by an admin');
    res.json({ approved: out });
  }));
  a.post('/purge', wrap(async (req, res) => res.json({ purged: await intel.purgeRaw() })));
  a.post('/aggregate', wrap(async (req, res) => {
    const holds = lease ? lease.status()['intel-aggregate']?.holding : true;
    if (lease && !holds && Object.keys(lease.status()).includes('intel-aggregate')) {
      return res.status(409).json({ error: 'Aggregation runs on the other node (job lease). It runs within 5 minutes by itself.', code: 'NOT_LEASE_HOLDER' });
    }
    res.json(await intel.aggregate());
  }));
  a.get('/rider/:userId/export', wrap(async (req, res) => res.json({ rows: await intel.exportContributions(String(req.params.userId)) })));
  a.post('/rider/:userId/delete', wrap(async (req, res) => res.json(await intel.deleteContributions(String(req.params.userId)))));
  a.use(codedErrors);
  app.use('/api/admin/intel', a);

  return intel;
}

module.exports = { attachIntel, areaOf, csvOf, INFO };
