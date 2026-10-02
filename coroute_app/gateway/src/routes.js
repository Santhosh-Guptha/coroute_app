'use strict';
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth, requireAdmin, AuthError } = require('./auth');
const { ConvoyError } = require('./convoys');

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

/**
 * @param {{auth: import('./auth').AuthService, convoys: import('./convoys').ConvoyManager, repo: any, soda: any, hub: any, startedAt:number}} deps
 */
function buildRouter({ auth, convoys, repo, soda, hub, startedAt }) {
  const r = express.Router();

  const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many attempts, try again later.' } });
  const apiLimiter = rateLimit({ windowMs: 60 * 1000, limit: 240, standardHeaders: 'draft-7', legacyHeaders: false });

  // ---- public ----
  r.get('/health', wrap(async (req, res) => {
    let db = 'DOWN';
    try { db = (await soda.ping()) ? 'UP' : 'DEGRADED'; } catch { db = 'DOWN'; }
    res.status(db === 'UP' ? 200 : 503).json({
      status: db === 'UP' ? 'HEALTHY' : 'DEGRADED',
      uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
      db,
      rooms: convoys.rooms.size,
      sockets: hub ? hub.wss.clients.size : 0,
      version: require('../package.json').version,
    });
  }));

  r.post('/auth/register', authLimiter, wrap(async (req, res) => res.status(201).json(await auth.register(req.body || {}))));
  r.post('/auth/login', authLimiter, wrap(async (req, res) => res.json(await auth.login(req.body || {}))));
  r.post('/auth/google', authLimiter, wrap(async (req, res) => res.json(await auth.loginWithGoogle(req.body || {}))));

  // ---- authenticated ----
  r.use(requireAuth, apiLimiter);

  r.get('/me', wrap(async (req, res) => res.json(await auth.me(req.user.userId))));
  r.patch('/me', wrap(async (req, res) => res.json(await auth.updateProfile(req.user.userId, req.body || {}))));

  // Convoys
  r.post('/convoys', wrap(async (req, res) => res.status(201).json(await convoys.createConvoy(req.user, req.body || {}))));
  r.post('/convoys/join', wrap(async (req, res) => res.json(await convoys.joinByCode(req.user, req.body?.code, req.body?.rider || {}))));
  r.get('/convoys/active', wrap(async (req, res) => {
    const meta = await repo.findActiveMembership(req.user.userId);
    if (!meta) return res.json({ convoy: null });
    res.json({ convoy: await convoys.getSnapshot(meta.groupId) });
  }));
  r.get('/convoys/:groupId', wrap(async (req, res) => {
    const { groupId } = req.params;
    if (!(await convoys.isMember(groupId, req.user.userId)) && req.user.role !== 'MASTER_ADMIN') {
      return res.status(403).json({ error: 'Not a member of this convoy.' });
    }
    res.json(await convoys.getSnapshot(groupId));
  }));
  r.post('/convoys/:groupId/leave', wrap(async (req, res) => { await convoys.leave(req.params.groupId, req.user.userId); res.json({ ok: true }); }));
  r.post('/convoys/:groupId/status', wrap(async (req, res) => {
    const room = await convoys.getRoom(req.params.groupId);
    const rider = room.riders.get(req.user.userId);
    if (!rider || (rider.role !== 'LEAD' && room.meta.createdByUserId !== req.user.userId && req.user.role !== 'MASTER_ADMIN')) {
      return res.status(403).json({ error: 'Only the convoy lead can change the trip state.' });
    }
    res.json({ tripStatus: await convoys.setTripStatus(req.params.groupId, String(req.body?.status || '')) });
  }));

  // Trips (summary records are kept forever; GPS trails are trimmed by retention)
  r.get('/trips', wrap(async (req, res) => res.json({ trips: await repo.listTripsForUser(req.user.userId) })));
  r.post('/trips', wrap(async (req, res) => {
    const t = req.body || {};
    if (!t.tripId || typeof t.tripId !== 'string') return res.status(400).json({ error: 'tripId required' });
    const trip = { ...t, userId: req.user.userId, savedAt: Date.now() };
    if (Array.isArray(trip.breadcrumbTrail) && trip.breadcrumbTrail.length > 20000) trip.breadcrumbTrail = trip.breadcrumbTrail.slice(-20000);
    await repo.saveTrip(trip);
    res.status(201).json({ ok: true });
  }));
  r.delete('/trips/:tripId', wrap(async (req, res) => res.json({ removed: await repo.deleteTrip(req.params.tripId, req.user.userId) })));

  // Admin
  r.get('/admin/fleet', requireAdmin, wrap(async (req, res) => res.json({ convoys: await convoys.fleet() })));
  r.post('/admin/broadcast', requireAdmin, wrap(async (req, res) => res.json(await convoys.adminBroadcast(req.user, req.body?.message))));
  r.get('/admin/users', requireAdmin, wrap(async (req, res) => res.json({ users: await auth.listUsers() })));
  r.patch('/admin/users/:userId/role', requireAdmin, wrap(async (req, res) => res.json(await auth.setRole(req.user, req.params.userId, String(req.body?.role || '')))));
  r.delete('/admin/convoys/:groupId', requireAdmin, wrap(async (req, res) => { await convoys.adminDissolve(req.params.groupId); res.json({ ok: true }); }));

  // Errors
  // eslint-disable-next-line no-unused-vars
  r.use((err, req, res, next) => {
    if (err instanceof AuthError || err instanceof ConvoyError) return res.status(err.status).json({ error: err.message });
    if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Malformed JSON' });
    console.error('[api]', err);
    res.status(500).json({ error: 'Internal error' });
  });

  return r;
}

module.exports = { buildRouter };
