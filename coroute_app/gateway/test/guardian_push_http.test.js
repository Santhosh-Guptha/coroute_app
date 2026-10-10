 'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { GuardianService } = require('../src/guardians');
const { GuardianPush } = require('../src/guardian_push');
const { guardianRouter } = require('../src/guardian_routes');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');

test('enabled push HTTP endpoints enforce origin, session and subscription ownership', async () => {
  const soda = new MemorySoda(), repo = new Repo(soda); await repo.migrate();
  const now = Date.now();
  await soda.insert('users', { userId: 'me', status: 'ACTIVE' });
  const meta = await repo.createConvoyMeta({ groupId: 'g', tripStatus: 'STARTED', members: { me: { joinedAt: now - 1000, role: 'LEAD' } } });
  const service = new GuardianService({ repo, convoys: { getRoom: async () => ({ meta, riders: new Map(), alerts: new Map() }) } });
  const push = new GuardianPush({ repo, service, publicKey: 'test-public-key', send: async () => { throw new Error('must not send'); } });
  const app = express(); app.use(express.json());
  app.use('/api/guardian', guardianRouter({ service, push, origin: 'https://guardian.example', gate: {} }));
  const server = app.listen(0, '127.0.0.1'); await new Promise(r => server.once('listening', r));
  const base = `http://127.0.0.1:${server.address().port}/api/guardian`;
  const call = async (path, method = 'GET', body, headers = {}) => {
    const res = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: res.status, headers: res.headers, body: await res.json() };
  };
  try {
    const grant = await service.create('me', 'g', { level: 'LIVE', acknowledged: true });
    const session = await call('/session', 'POST', { token: grant.token }, { Origin: 'https://guardian.example' });
    const id = session.body.sessionId;
    const headers = { Origin: 'https://guardian.example', Cookie: session.headers.get('set-cookie').split(';')[0] };
    const path = `/sessions/${id}/subscription`;
    const data = { subscription: { endpoint: 'https://fcm.googleapis.com/test', keys: { p256dh: 'A'.repeat(87), auth: 'B'.repeat(22) } } };
    assert.equal((await call('/capabilities')).body.push, true);
    assert.equal((await call(path, 'POST', data, { ...headers, Origin: 'https://evil.example' })).status, 403);
    assert.equal((await call(path, 'POST', data, { Origin: headers.Origin })).status, 410);
    assert.equal((await call(path, 'POST', { ...data, preferences: { trip: 'yes' } }, headers)).status, 400);
    const subscribed = await call(path, 'POST', data, headers); assert.equal(subscribed.status, 201);
    const other = await service.create('me', 'g', { level: 'LIVE', acknowledged: true });
    const otherSession = await call('/session', 'POST', { token: other.token }, { Origin: headers.Origin });
    assert.equal((await call(`/sessions/${otherSession.body.sessionId}/subscription/${subscribed.body.subscriptionId}`, 'DELETE', undefined,
      { ...headers, Cookie: otherSession.headers.get('set-cookie').split(';')[0] })).status, 404);
    assert.equal((await call(path + '/' + subscribed.body.subscriptionId, 'DELETE', undefined, headers)).status, 200);
    assert.equal((await call(path, 'POST', data, headers)).status, 409);
  } finally { await new Promise(r => server.close(r)); }
});
