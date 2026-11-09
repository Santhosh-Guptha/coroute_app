'use strict';
/**
 * 3.55 platform: "Warn" on a public-ride report reaches the rider.
 * Unit tests of src/admin_warnings.js and one end-to-end run through the admin report review.
 */
process.env.PUBLIC_RIDE_TICK_MS = '3600000';
process.env.ADMIN_EMAILS = 'pr.warnadmin@coroute.test';
const { netBoot, line } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { AdminWarnings, cleanMessage, validateWarnMessage, MESSAGE_MAX, MAX_PENDING, DEFAULT_MESSAGE } = require('../src/admin_warnings');
const { publicRideOf } = require('../src/public_ride_settings');

// ------------------------------------------------------------------ unit
function fakes({ on = true } = {}) {
  const users = new Map([['usr_b', { key: 'k1', userId: 'usr_b' }]]);
  const repo = {
    findUserById: async (id) => (users.has(id) ? { ...users.get(id) } : null),
    updateUser: async (key, patch) => { for (const [id, u] of users) if (u.key === key) users.set(id, { ...u, ...patch }); },
  };
  const sent = [];
  const hub = { sendToUser: (uid, payload) => { sent.push([uid, payload]); return 1; } };
  const rows = [];
  const audit = { add: (r) => rows.push(r) };
  const flags = { on };
  const w = new AdminWarnings({ repo, hub, audit, flagsOf: () => ({ isOn: (id) => id !== 'adminWarnings' || flags.on }), clock: () => 1700000000000 });
  return { w, users, sent, rows, flags };
}

test('plain text: control characters and angle brackets removed, spaces collapsed, length capped', () => {
  assert.equal(cleanMessage('  Be\u0000 kind\n\n to <b>riders</b>  '), 'Be kind to briders/b');
  assert.equal(cleanMessage(42), '');
  const long = cleanMessage('x'.repeat(MESSAGE_MAX + 50));
  assert.equal(long.length, MESSAGE_MAX);
  assert.ok(long.endsWith('…'));
});

test('typed Warn text: required, trimmed, sanitized, at most 280 characters (refused, never cut)', () => {
  assert.deepEqual(validateWarnMessage('  Keep\u0000 it  <i>polite</i>  '), { ok: true, message: 'Keep it ipolite/i' });
  for (const bad of [undefined, null, 42, '', '   ', '\u0000\u200B', '<>']) {
    const v = validateWarnMessage(bad);
    assert.equal(v.ok, false, JSON.stringify(bad)); assert.equal(v.code, 'WARN_MESSAGE_REQUIRED');
  }
  assert.equal(validateWarnMessage('x'.repeat(MESSAGE_MAX)).ok, true, 'limit inclusive');
  assert.equal(validateWarnMessage(`  ${'x'.repeat(MESSAGE_MAX)}  `).ok, true, 'trimmed before counting');
  const long = validateWarnMessage('x'.repeat(MESSAGE_MAX + 1));
  assert.equal(long.ok, false); assert.equal(long.code, 'WARN_MESSAGE_TOO_LONG');
  assert.equal(validateWarnMessage(DEFAULT_MESSAGE).ok, true, 'the default line fits (quick option)');
});

test('warn: stored on the user until acknowledged, pushed at once, audited without the text', async () => {
  const { w, users, sent, rows } = fakes();
  const r = await w.warn('usr_b', 'Please keep messages about the ride.', { byUserId: 'usr_admin', ref: 'PRR-1' });
  assert.equal(r.ok, true); assert.equal(r.delivered, true);
  assert.match(r.warning.id, /^AW-[0-9A-F]{12}$/);
  assert.deepEqual(sent, [['usr_b', { type: 'ADMIN_WARNING', id: r.warning.id, message: 'Please keep messages about the ride.', at: 1700000000000 }]]);
  assert.equal(users.get('usr_b').pendingWarnings.length, 1);
  assert.equal(users.get('usr_b').pendingWarnings[0].ref, 'PRR-1');
  assert.deepEqual(await w.list('usr_b'), [{ id: r.warning.id, message: 'Please keep messages about the ride.', at: 1700000000000 }]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].kind, 'ADMIN_WARNING'); assert.equal(rows[0].detail, 'SENT');
  assert.ok(!JSON.stringify(rows).includes('Please keep'), 'audit never holds the text');
  // Acknowledge: gone; a second ack or a bad id is refused.
  assert.equal(await w.ack('usr_b', r.warning.id), true);
  assert.deepEqual(await w.list('usr_b'), []);
  assert.equal(await w.ack('usr_b', r.warning.id), false);
  assert.equal(await w.ack('usr_b', '../x'), false);
  assert.equal(rows[1].detail, 'ACK');
});

test('warn: empty message uses the default line; at most MAX_PENDING kept; unknown user refused', async () => {
  const { w, users } = fakes();
  const first = await w.warn('usr_b', '   ');
  assert.equal(first.warning.message, DEFAULT_MESSAGE);
  for (let i = 0; i < MAX_PENDING + 2; i++) await w.warn('usr_b', `Note ${i}`);
  assert.equal(users.get('usr_b').pendingWarnings.length, MAX_PENDING);
  assert.equal(users.get('usr_b').pendingWarnings.at(-1).message, `Note ${MAX_PENDING + 1}`);
  assert.deepEqual(await w.warn('usr_x', 'hi'), { ok: false, reason: 'NO_USER' });
});

test('switch adminWarnings off: nothing delivered, the rider list reads empty', async () => {
  const { w, sent, flags } = fakes({ on: false });
  assert.deepEqual(await w.warn('usr_b', 'hi'), { ok: false, reason: 'FEATURE_OFF' });
  assert.equal(sent.length, 0);
  flags.on = true;
  await w.warn('usr_b', 'hi');
  flags.on = false;
  assert.deepEqual(await w.list('usr_b'), []);
});

// ------------------------------------------------------------------ end to end
let h;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

async function sock(token, gid) {
  const ws = await h.t.connect(token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'JOIN', groupId: gid, caps: ['net1', 'pubride1'] });
  await ws.next((m) => m.type === 'SNAPSHOT');
  return ws;
}
async function ride(points, name) {
  const R = await h.rideOn(points, { name });
  R.ws = await sock(R.lead.token, R.gid);
  R.ws.sendJson({ type: 'CONFIG', publicRide: { on: true, radiusKm: 10 } });
  await R.ws.next((m) => m.type === 'CONFIG');
  return R;
}
async function ask(ws, msg, okType) {
  ws.sendJson(msg);
  return ws.next((m) => m.type === okType || m.type === 'ERROR');
}

test('admin WARN on a report: the reported rider gets ADMIN_WARNING now, sees it in /me/warnings until acknowledged', async () => {
  const lng = 70.5;
  const A = await ride(line(lng, 17.40, 17.70), 'Warn Host');
  const B = await ride(line(lng, 17.70, 17.40), 'Warn Asker');
  h.place(A.gid, A.lead, 17.45, lng, 0, 60);
  h.place(B.gid, B.lead, 17.48, lng, 180, 60);
  h.t.gw.publicRides.tick(Date.now());
  await h.settle();
  const rideId = publicRideOf(h.t.gw.convoys.rooms.get(A.gid).meta.publicRide).id;
  const sent = await ask(B.ws, { type: 'PR_CONTACT', rideId, kind: 'HI', quick: 'HI', text: '' }, 'PR_SENT');
  assert.equal(sent.type, 'PR_SENT', JSON.stringify(sent));
  await A.ws.next((m) => m.type === 'PR_REQUEST');
  await ask(A.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'REPORT', reason: 'ABUSE', text: 'Rude' }, 'PR_REPLY_OK');
  await h.settle(50);

  const admin = await h.rider('WarnAdmin', { email: 'pr.warnadmin@coroute.test' });
  const list = await h.t.api('GET', '/admin/public-ride/reports?status=OPEN', null, admin.token);
  const r = list.json.reports.find((x) => x.ref === sent.requestId);
  assert.ok(r, 'report listed');

  // A rider can never warn (admin router).
  const nope = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'WARN', message: 'x' }, A.lead.token);
  assert.equal(nope.status, 403);

  // The typed text is validated: empty or over 280 characters is refused and nothing is sent.
  let early = 0;
  const count = (d, bin) => { if (!bin && JSON.parse(d.toString()).type === 'ADMIN_WARNING') early++; };
  B.ws.on('message', count);
  const empty = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'WARN', message: '   ' }, admin.token);
  assert.equal(empty.status, 400); assert.equal(empty.json.code, 'WARN_MESSAGE_REQUIRED');
  const tooLong = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'WARN', message: 'y'.repeat(281) }, admin.token);
  assert.equal(tooLong.status, 400); assert.equal(tooLong.json.code, 'WARN_MESSAGE_TOO_LONG');
  const notText = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'WARN', message: { x: 1 } }, admin.token);
  assert.equal(notText.status, 400);
  await h.settle(30);
  B.ws.off('message', count);
  assert.equal(early, 0, 'refused: nothing delivered');
  assert.equal((await h.t.api('GET', '/admin/public-ride/reports?status=OPEN', null, admin.token)).json.reports.some((x) => x.reportId === r.reportId), true, 'still open');

  const push = B.ws.next((m) => m.type === 'ADMIN_WARNING');
  const warn = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'WARN', message: '  Please keep\u0000 contact polite.  ' }, admin.token);
  assert.equal(warn.status, 200, JSON.stringify(warn.json));
  const msg = await push;
  assert.equal(msg.message, 'Please keep contact polite.');
  assert.match(msg.id, /^AW-[0-9A-F]{12}$/);

  const all = await h.t.api('GET', '/admin/public-ride/reports', null, admin.token);
  assert.equal(all.json.reports.find((x) => x.reportId === r.reportId).warnMessage, 'Please keep contact polite.', 'admin record keeps the text sent');

  const mine = await h.t.api('GET', '/me/warnings', null, B.lead.token);
  assert.equal(mine.status, 200);
  assert.deepEqual(mine.json.warnings.map((x) => x.id), [msg.id]);
  assert.equal(mine.json.warnings[0].ref, undefined, 'the report id stays with the admin record');
  // The other rider has none; one rider cannot acknowledge another's warning.
  assert.deepEqual((await h.t.api('GET', '/me/warnings', null, A.lead.token)).json.warnings, []);
  assert.equal((await h.t.api('POST', `/me/warnings/${msg.id}/ack`, {}, A.lead.token)).status, 404);

  const ack = await h.t.api('POST', `/me/warnings/${msg.id}/ack`, {}, B.lead.token);
  assert.equal(ack.status, 200);
  assert.deepEqual((await h.t.api('GET', '/me/warnings', null, B.lead.token)).json.warnings, []);

  // The contact log records the warning as delivered.
  const log = await h.t.api('GET', `/admin/public-ride/log?userId=${B.lead.user.userId}`, null, admin.token);
  assert.ok(log.json.log.some((x) => x.kind === 'WARNED' && x.ref === r.reportId && x.delivered === true));
  for (const R of [A, B]) await h.endRide(R);
});
