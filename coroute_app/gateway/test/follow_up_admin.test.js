'use strict';
/**
 * 3.16: CHECK_IN with context FOLLOW_UP (an instant FOLLOW_UP entry, nothing else touched), the admin
 * "call the emergency contact" endpoint (name and phone for an open alert, audited without the number,
 * limited), and the SOS timeline entry carrying source / reportedByName for REPORT_DOWN.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'fuadmin@coroute.test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t, gw, admin;
before(async () => {
  t = await boot(); gw = t.gw;
  admin = await t.register('FU Admin', 'fuadmin@coroute.test');
  assert.equal(admin.user.role, 'MASTER_ADMIN');
});
after(async () => { await gw.shutdown(); });

let n = 0;
async function ride() {
  n++;
  const lead = await t.register(`FU Lead ${n}`, `fulead${n}@coroute.test`);
  const rider = await t.register(`Kiran Rider ${n}`, `furider${n}@coroute.test`, { emergencyContact: '+91 90000 00077', emergencyContactName: 'Amma' });
  const c = (await t.api('POST', '/convoys', { name: `FU ${n}` }, lead.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token)).status, 200);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wr = await t.joinRoom(rider.token, c.groupId);
  return { lead, rider, c, gid: c.groupId, wl, wr, end: () => t.api('POST', `/convoys/${c.groupId}/status`, { status: 'ENDED' }, lead.token) };
}
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);

test('CHECK_IN FOLLOW_UP OK: one FOLLOW_UP instant, INCIDENT / NO_REPLY untouched; NO_REPLY with FOLLOW_UP is 400', async () => {
  const R = await ride();
  // An open NO_REPLY for the rider must survive a follow-up.
  R.wr.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', awayM: 1200, clientId: 'nr-1' });
  await R.wr.next((m) => m.type === 'ACK' && m.clientId === 'nr-1');
  await gw.timeline.idle();
  assert.equal((await events(R.gid, 'NO_REPLY')).filter((e) => e.open).length, 1);
  R.wr.sendJson({ type: 'CHECK_IN', result: 'OK', context: 'FOLLOW_UP', lat: 17.4, lng: 78.5, clientId: 'fu-1' });
  const ack = await R.wr.next((m) => m.type === 'ACK' && m.clientId === 'fu-1');
  assert.equal(ack.duplicate, false);
  const fu = await R.wl.next((m) => m.type === 'TIMELINE' && m.event.type === 'FOLLOW_UP');
  assert.equal(fu.event.userId, R.rider.user.userId);
  assert.deepEqual(fu.event.data, { result: 'OK' });
  assert.equal(fu.event.open, false);
  assert.equal(fu.event.lat, 17.4);
  await gw.timeline.idle();
  assert.equal((await events(R.gid, 'FOLLOW_UP')).length, 1);
  assert.equal((await events(R.gid, 'NO_REPLY')).filter((e) => e.open).length, 1, 'the no-reply entry is not closed by a follow-up');
  assert.equal((await events(R.gid, 'CHECK_IN')).length, 0, 'no CHECK_IN entry either');
  R.wr.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', context: 'FOLLOW_UP', clientId: 'fu-2' });
  const err = await R.wr.next((m) => m.type === 'ERROR' && m.clientId === 'fu-2');
  assert.equal(err.code, 400);
  assert.equal(err.reason, 'BAD_RESULT');
  // An unknown context is ignored: an ordinary OK closes the no-reply entry (direct call: the socket's
  // alarm budget of 3 CHECK_IN per 10 s is spent).
  await gw.timeline.checkIn(R.gid, R.rider.user, { result: 'OK', context: 'SOMETHING' });
  await gw.timeline.idle();
  assert.equal((await events(R.gid, 'NO_REPLY')).filter((e) => e.open).length, 0);
  await R.end();
  R.wl.close(); R.wr.close();
});

test('admin contact: name and phone for an open alert; 404 when closed, missing or no contact; audit without digits; 11th call 429', async () => {
  const R = await ride();
  R.wr.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH', clientId: 'sos-c' });
  const alert = (await R.wl.next((m) => m.type === 'ALERT')).alert;
  const path = `/admin/emergencies/${R.gid}/${alert.alertId}/contact`;
  assert.equal((await t.api('POST', path, {}, R.lead.token)).status, 403, 'admins only');
  const r = await t.api('POST', path, {}, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.deepEqual(r.json, { name: 'Amma', phone: '+91 90000 00077', riderName: R.rider.user.name });
  assert.match(r.headers.get('cache-control'), /no-store/);
  await gw.audit.flush();
  const rows = (await gw.repo.listAudit({ limit: 500 })).filter((x) => x.kind === 'ADMIN_CONTACT');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].actorId, admin.user.userId);
  assert.equal(rows[0].subjectId, R.rider.user.userId);
  assert.equal(rows[0].alertId, alert.alertId);
  assert.equal(rows[0].groupId, R.gid);
  assert.equal(rows[0].detail, 'CALL');
  assert.ok(rows[0].at > 0);
  assert.ok(!/[0-9]/.test(rows[0].detail) && !JSON.stringify(rows[0]).includes('90000'), 'never the number');
  // Visible in /admin/safety.
  const safety = (await t.api('GET', '/admin/safety', undefined, admin.token)).json;
  assert.ok(safety.audit.some((x) => x.kind === 'ADMIN_CONTACT'));
  // Unknown alert / group: 404.
  assert.equal((await t.api('POST', `/admin/emergencies/${R.gid}/SOS-nope/contact`, {}, admin.token)).status, 404);
  assert.equal((await t.api('POST', `/admin/emergencies/GRP-NOPE/${alert.alertId}/contact`, {}, admin.token)).status, 404);
  // No contact on file: 404 NO_CONTACT.
  const u = await gw.repo.findUserById(R.rider.user.userId);
  await gw.repo.updateUser(u.key, { emergencyContact: '', emergencyContactName: '' });
  const none = await t.api('POST', path, {}, admin.token);
  assert.equal(none.status, 404);
  assert.equal(none.json.code, 'NO_CONTACT');
  await gw.repo.updateUser(u.key, { emergencyContact: u.emergencyContact, emergencyContactName: u.emergencyContactName });
  // Closed alert: 404.
  R.wr.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alertId });
  await R.wl.next((m) => m.type === 'ALERT_RESOLVED');
  assert.equal((await t.api('POST', path, {}, admin.token)).json.code, 'ALERT_CLOSED');
  // 10 a minute per admin.
  let last;
  for (let i = 0; i < 8; i++) last = await t.api('POST', path, {}, admin.token);
  assert.equal(last.status, 429);
  assert.equal(last.json.code, 'RATE_LIMITED');
  await R.end();
  R.wl.close(); R.wr.close();
});

test('SOS timeline data carries source and reportedByName for REPORT_DOWN; MANUAL for a plain SOS', async () => {
  const R = await ride();
  const room = gw.convoys.rooms.get(R.gid);
  gw.convoys.patchRider(room, R.lead.user.userId, { lat: 17.385, lng: 78.4867, speedKmh: 0 }, { emit: false });
  R.wl.sendJson({ type: 'REPORT_DOWN', lat: 17.386, lng: 78.487, subjectUserId: R.rider.user.userId, clientId: 'rd-1' });
  const a = await R.wr.next((m) => m.type === 'ALERT');
  await gw.timeline.idle();
  const sos = (await events(R.gid, 'SOS')).find((e) => e.data.alertId === a.alert.alertId);
  assert.equal(sos.userId, R.rider.user.userId);
  assert.equal(sos.data.source, 'MEMBER_REPORT');
  assert.equal(sos.data.reportedBy, R.lead.user.userId);
  assert.equal(sos.data.reportedByName, R.lead.user.name);
  R.wr.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'MEDICAL', clientId: 'sos-m' });
  const b = await R.wl.next((m) => m.type === 'ALERT' && m.alert.alertId !== a.alert.alertId);
  await gw.timeline.idle();
  const plain = (await events(R.gid, 'SOS')).find((e) => e.data.alertId === b.alert.alertId);
  assert.equal(plain.data.source, 'MANUAL');
  assert.equal(plain.data.reportedBy, undefined);
  await R.end();
  R.wl.close(); R.wr.close();
  await sleep(10);
});
