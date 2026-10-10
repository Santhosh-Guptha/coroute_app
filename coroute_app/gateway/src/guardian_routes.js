'use strict';
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth } = require('./auth');
const { GuardianError } = require('./guardians');
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch(next);

/** Separate observer endpoints: guest sessions are never accepted by rider auth. */
function guardianRouter({ service, gate, origin, push = null }) {
  const r = express.Router();
  r.use((req, res, next) => {
    res.set('Cache-Control', 'no-store').set('Referrer-Policy', 'no-referrer')
      .set('X-Robots-Tag', 'noindex, nofollow');
    next();
  });
  const limit = (max) => rateLimit({ windowMs: 60000, limit: max, standardHeaders: 'draft-7', legacyHeaders: false });
  const credentialOf = (req) => {
    const id = req.params.id;
    if (!/^[a-f0-9]{24}$/.test(id)) throw new GuardianError();
    const prefix = `guardian_${id}=`;
    return String(req.headers.cookie || '').split(';').map((v) => v.trim()).find((v) => v.startsWith(prefix))?.slice(prefix.length);
  };
  const setSession = (res, result) => {
    const id = crypto.createHash('sha256').update(result.credential).digest('hex').slice(0, 24);
    res.cookie(`guardian_${id}`, result.credential, { secure: true, httpOnly: true,
      sameSite: 'strict', path: `/api/guardian/sessions/${id}`, expires: new Date(result.expiresAt) });
    res.status(201).json({ sessionId: id, expiresAt: result.expiresAt });
  };
  r.get('/capabilities', limit(30), (req, res) => res.json({ push: !!push, publicKey: push?.publicKey || null }));
  r.post('/ticket', limit(10), wrap(async (req, res) => {
    if (req.get('origin') !== origin) throw new GuardianError('Origin not allowed.', 403);
    const view = await service.snapshot(req.body?.ticket);
    setSession(res, { credential: req.body.ticket, expiresAt: view.expiresAt });
  }));
  r.post('/sessions/:id/subscription', limit(10), wrap(async (req, res) => {
    if (!push) throw new GuardianError('Browser alerts are unavailable.', 503);
    if (req.get('origin') !== origin) throw new GuardianError('Origin not allowed.', 403);
    res.status(201).json(await push.subscribe(credentialOf(req), req.body?.subscription, req.body?.preferences));
  }));
  r.delete('/sessions/:id/subscription/:subscriptionId', limit(10), wrap(async (req, res) => {
    if (!push) throw new GuardianError('Browser alerts are unavailable.', 503);
    if (req.get('origin') !== origin) throw new GuardianError('Origin not allowed.', 403);
    await push.unsubscribe(credentialOf(req), req.params.subscriptionId);
    res.json({ removed: true });
  }));
  const pinLimit = rateLimit({ windowMs: 60000, limit: 10, keyGenerator: (req) => crypto.createHash('sha256').update(String(req.body?.token || '').slice(0, 128)).digest('hex'), standardHeaders: 'draft-7', legacyHeaders: false });
  r.post('/session', limit(10), pinLimit, wrap(async (req, res) => {
    if (req.get('origin') !== origin) throw new GuardianError('Origin not allowed.', 403);
    const result = await service.exchange(req.body?.token, req.body?.pin);
    setSession(res, result);
  }));
  r.get('/sessions/:id/snapshot', limit(60), wrap(async (req, res) => {
    const snapshot = await service.snapshot(credentialOf(req));
    res.json(snapshot);
  }));
  r.use(requireAuth(gate), limit(20));
  r.get('/consent/:groupId', wrap(async (req, res) => res.json(await service.getConsent(req.user.userId, req.params.groupId))));
  r.patch('/consent/:groupId', wrap(async (req, res) => res.json(await service.setConsent(req.user.userId, req.params.groupId, req.body?.allowed))));
  r.post('/links', wrap(async (req, res) => {
    const { groupId, ...input } = req.body || {};
    if (typeof groupId !== 'string' || groupId.length > 100) throw new GuardianError('Choose a ride.', 400);
    const { token, ...result } = await service.create(req.user.userId, groupId, input);
    res.status(201).json({ ...result, url: `${origin}/watch#token=${token}` });
  }));
  r.get('/links/:groupId', wrap(async (req, res) => res.json({ links: await service.list(req.user.userId, req.params.groupId) })));
  r.patch('/links/:grantId', wrap(async (req, res) => res.json(await service.pause(req.user.userId, req.params.grantId, req.body?.paused))));
  r.delete('/links/:grantId', wrap(async (req, res) => res.json(await service.revoke(req.user.userId, req.params.grantId))));
  r.use((err, req, res, next) => {
    if (err instanceof GuardianError) return res.status(err.status).json({ error: err.message, ...(err.code ? { code: err.code } : {}) });
    next(err);
  });
  return r;
}
module.exports = { guardianRouter };
