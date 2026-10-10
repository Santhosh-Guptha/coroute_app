'use strict';
process.env.NODE_ENV = 'test';
process.env.GUARDIAN_ENABLED = 'true';
process.env.PUBLIC_ORIGIN = 'https://guardian.example';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
test('guest cookie access is scoped, revocable and never rider authentication', async () => {
  const t = await boot();
  try {
    const rider = await t.register('Guardian Rider', 'guardian@test.example');
    const ride = await t.api('POST', '/convoys', { name: 'Private ride' }, rider.token);
    const created = await t.api('POST', '/guardian/links', { groupId: ride.json.groupId, subject: 'PERSONAL', level: 'LIVE', acknowledged: true }, rider.token);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    const token = new URL(created.json.url).hash.slice('#token='.length);
    assert.equal((await t.api('POST', '/guardian/session', { token }, null, { Origin: 'https://evil.example' })).status, 403);
    const session = await t.api('POST', '/guardian/session', { token }, null, { Origin: 'https://guardian.example' });
    assert.equal(session.status, 201);
    const cookie = session.headers.get('set-cookie');
    assert.match(cookie, /HttpOnly/); assert.match(cookie, /Secure/); assert.match(cookie, /SameSite=Strict/);
    const path = `/guardian/sessions/${session.json.sessionId}/snapshot`;
    const headers = { Cookie: cookie.split(';')[0] };
    const view = await t.api('GET', path, null, null, headers);
    assert.equal(view.status, 200); assert.equal(view.json.scope, 'PERSONAL');
    assert.equal(view.headers.get('cache-control'), 'no-store');
    assert.equal((await t.api('GET', path)).status, 410);
    assert.equal((await t.api('GET', '/me', null, token)).status, 401);
    assert.equal((await t.api('POST', '/convoys', { name: 'Not allowed' }, null, headers)).status, 401);
    const page = await fetch(`${t.origin}/watch`); assert.equal(page.status, 200);
    assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
    assert.equal(page.headers.get('cache-control'), 'no-store');
    assert.ok(!(await page.text()).includes('Private ride'));
    assert.equal((await fetch(`${t.origin}/watch.html`)).status, 404);
    await t.api('DELETE', `/guardian/links/${created.json.grantId}`, null, rider.token);
    assert.equal((await t.api('GET', path, null, null, headers)).status, 410);
  } finally { await t.gw.shutdown(); }
});


test('PIN and pause are enforced over HTTP and guest access cannot manage a link', async () => {
  const t = await boot();
  try {
    const rider = await t.register('PIN Rider', 'pin-guardian@test.example');
    const ride = await t.api('POST', '/convoys', { name: 'PIN ride' }, rider.token);
    const created = await t.api('POST', '/guardian/links', { groupId: ride.json.groupId,
      level: 'LIVE', acknowledged: true, pin: '739152' }, rider.token);
    assert.equal(created.status, 201);
    const token = new URL(created.json.url).hash.slice('#token='.length);
    const origin = { Origin: 'https://guardian.example' };
    const denied = await t.api('POST', '/guardian/session', { token }, null, origin);
    assert.equal(denied.status, 401); assert.equal(denied.json.code, 'GUARDIAN_PIN_REQUIRED');
    assert.equal(denied.headers.get('set-cookie'), null);
    const session = await t.api('POST', '/guardian/session', { token, pin: '739152' }, null, origin);
    assert.equal(session.status, 201);
    const headers = { Cookie: session.headers.get('set-cookie').split(';')[0] };
    const path = `/guardian/sessions/${session.json.sessionId}/snapshot`;
    const management = `/guardian/links/${created.json.grantId}`;
    assert.equal((await t.api('PATCH', management, { paused: true }, null, headers)).status, 401);
    assert.equal((await t.api('PATCH', management, { paused: 'yes' }, rider.token)).status, 400);
    assert.equal((await t.api('PATCH', management, { paused: true }, rider.token)).status, 200);
    assert.equal((await t.api('GET', path, null, null, headers)).status, 423);
    await t.api('PATCH', management, { paused: false }, rider.token);
    assert.equal((await t.api('GET', path, null, null, headers)).status, 200);
    const capabilities = await t.api('GET', '/guardian/capabilities');
    assert.equal(capabilities.json.push, false);
    assert.equal((await t.api('POST', `/guardian/sessions/${session.json.sessionId}/subscription`, {}, null, { ...headers, ...origin })).status, 503);
    await t.api('DELETE', management, null, rider.token);
    assert.equal((await t.api('GET', path, null, null, headers)).status, 410);
  } finally { await t.gw.shutdown(); }
});
