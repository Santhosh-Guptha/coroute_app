'use strict';
process.env.NODE_ENV = 'test';
process.env.REPORT_DELAY_MS = '0';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const gm = require('../src/geo_math');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

/** Every stored document (all collections) as JSON strings. */
function everything() {
  const out = [];
  for (const [name, coll] of t.soda.collections) for (const doc of coll.values()) out.push([name, JSON.stringify(doc)]);
  return out;
}

function chunk(seq, startTs, n, lat0) {
  const pts = Array.from({ length: n }, (_, i) => ({ lat: lat0 + i * 0.001, lng: 78.4, ts: startTs + i * 5000 }));
  return { seq, startTs, enc: gm.encodePolyline(pts), t: pts.map((p) => p.ts - startTs), v: pts.map(() => 40), acc: pts.map(() => 5) };
}

test('deleting an account leaves no trace of the rider in any collection; the others keep their history', async () => {
  const A = await t.register('Erase Lead', 'eraselead@coroute.test');
  const B = await t.register('Erase Gone', 'erasegone@coroute.test', {
    phone: '+919812345678', vehicleNo: 'KA05ZZ9999', emergencyContact: '+919898989898', emergencyContactName: 'Gone Family',
  });
  const c = (await t.api('POST', '/convoys', { name: 'Erase ride', start: { lat: 17.3, lng: 78.4, name: 'Start' }, destination: 'End', destLat: 17.5, destLng: 78.4 }, A.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, B.token)).status, 200);
  const wa = await t.joinRoom(A.token, c.groupId);
  const wb = await t.joinRoom(B.token, c.groupId);

  // B leaves traces everywhere: chat, wait card, SOS, a suggested stop, an arrival, telemetry, a track.
  const startTs = Date.now() - 60000;
  wb.sendJson({ type: 'TELEMETRY', lat: 17.31, lng: 78.4, speedKmh: 30 });
  wb.sendJson({ type: 'CHAT', text: 'Hello from B' });
  await wa.next((m) => m.type === 'MESSAGE' && m.message.text === 'Hello from B');
  wb.sendJson({ type: 'WAIT' });
  await wa.next((m) => m.type === 'MESSAGE' && m.message.cardType === 'WAIT_2MIN');
  wb.sendJson({ type: 'SOS', lat: 17.31, lng: 78.4, clientId: 'erase-1' });
  const sos = await wa.next((m) => m.type === 'ALERT');
  wa.sendJson({ type: 'SOS_RESOLVE', alertId: sos.alert.alertId });
  await wb.next((m) => m.type === 'ALERT_RESOLVED');
  wb.sendJson({ type: 'STOP_SUGGEST', name: 'Tea', lat: 17.4, lng: 78.4 });
  await wa.next((m) => m.type === 'STOPS');
  wa.sendJson({ type: 'CORIDER', ridingWithUserId: B.user.userId });
  await wb.next((m) => m.type === 'RIDER_UPDATE' && m.rider.ridingWithUserId === B.user.userId);
  const up = await t.api('POST', `/convoys/${c.groupId}/tracks`, { chunks: [chunk(0, startTs, 6, 17.3)] }, B.token);
  assert.deepEqual(up.json.acked, [0]);
  await t.api('POST', `/convoys/${c.groupId}/tracks`, { chunks: [chunk(0, startTs, 6, 17.3)] }, A.token);
  wa.sendJson({ type: 'CORIDER', ridingWithUserId: '' });
  await sleep(50);

  // The trip ends; the report is built with both riders.
  wa.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await wb.next((m) => m.type === 'TRIP_STATUS' && m.tripStatus === 'ENDED');
  await sleep(50);
  await t.gw.timeline.idle();
  const before = await t.gw.repo.getConvoyMeta(c.groupId);
  assert.ok(before.report, 'report built');
  assert.ok(everything().some(([, j]) => j.includes(B.user.userId)), 'B is stored before the delete');
  wa.close(); wb.close();

  const del = await t.api('DELETE', '/me', null, B.token);
  assert.equal(del.status, 200);
  await t.gw.timeline.idle();
  await sleep(50);

  const needles = [B.user.userId, 'Erase Gone', 'erasegone@coroute.test', '+919812345678', 'KA05ZZ9999', '+919898989898', 'Gone Family'];
  const leaks = [];
  for (const [coll, json] of everything()) for (const n of needles) if (json.includes(n)) leaks.push(`${coll}: ${n}`);
  assert.deepEqual(leaks, [], 'no trace of the deleted rider');

  const meta = await t.gw.repo.getConvoyMeta(c.groupId);
  const former = Object.values(meta.members).find((m) => m.userId !== A.user.userId);
  assert.equal(former.name, 'Former rider');
  assert.equal(former.vehicleNo, '');
  assert.ok(meta.report.members.some((m) => m.name === 'Former rider'));
  assert.equal(meta.memberSummary.length, 2);

  // The lead's own history still works.
  const trips = (await t.api('GET', '/trips', null, A.token)).json.trips;
  const mine = trips.find((x) => x.groupId === c.groupId);
  assert.ok(mine);
  const report = await t.api('GET', `/trips/${mine.tripId}/report`, null, A.token);
  assert.equal(report.status, 200);
  assert.ok(report.json.report);
  assert.equal((await t.api('GET', `/convoys/${c.groupId}/summary`, null, A.token)).status, 200);
});

test('a rider deleted by an admin while a convoy is live is removed from that convoy in memory too', async () => {
  const A = await t.register('Live Lead', 'livelead@coroute.test');
  const B = await t.register('Live Gone', 'livegone@coroute.test');
  const admin = await t.register('Erase Admin', 'eraseadmin@coroute.test');
  await t.gw.auth.setRole({ userId: 'system' }, admin.user.userId, 'MASTER_ADMIN');
  const c = (await t.api('POST', '/convoys', { name: 'Live ride' }, A.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, B.token);
  const wb = await t.joinRoom(B.token, c.groupId);
  wb.sendJson({ type: 'WAIT' });
  await wb.next((m) => m.type === 'MESSAGE');

  assert.equal((await t.api('DELETE', `/admin/users/${B.user.userId}`, null, admin.token)).status, 200);
  assert.equal(await wb.closed, 4401);
  const room = t.gw.convoys.rooms.get(c.groupId);
  assert.ok(room, 'the convoy is still live');
  assert.ok(!JSON.stringify(room.meta).includes('Live Gone'));
  assert.ok(!JSON.stringify(room.messages).includes('Live Gone'));
  // A later save writes nothing back.
  await t.gw.convoys.flushAll();
  for (const [coll, json] of everything()) assert.ok(!json.includes(B.user.userId) && !json.includes('Live Gone'), coll);
});

test('retention removes SOS coordinates after the track retention period', async () => {
  const A = await t.register('Old Sos', 'oldsos@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Old SOS ride' }, A.token)).json;
  const ws = await t.joinRoom(A.token, c.groupId);
  ws.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, clientId: 'old-1' });
  await ws.next((m) => m.type === 'ALERT');
  ws.close();
  const stats = await t.gw.retention.runOnce(Date.now() + 91 * 86400000);
  assert.ok(stats.alertsStripped >= 1);
  const [alert] = await t.gw.repo.listAlerts(c.groupId, { includeResolved: true });
  assert.equal(alert.lat, null);
  assert.equal(alert.lng, null);
  assert.equal(alert.userId, A.user.userId, 'who and when are kept');
});

test('deleting an account removes its review photo files, every guardian grant (past 100) and its SOS live links', async () => {
  const fs = require('fs');
  const config = require('../src/config');
  const { createPhotoStore } = require('../src/review_photos');
  const repo = t.gw.repo;
  const lead = await t.register('Link Lead', 'linklead@coroute.test');
  const G = await t.register('Grant Gone', 'grantgone@coroute.test');
  const uid = G.user.userId;

  // Two reviews with uploaded photo files on disk (one review also keyed by email only).
  const store = createPhotoStore(config.reviewPhotoDir);
  const metas = [];
  for (let i = 0; i < 3; i++) metas.push(await store.save({ mime: 'image/png', ext: 'png', data: Buffer.from(`png-${i}`) }));
  await repo.addTripFeedback({ tripId: 'trip_photo_1', userId: uid, rating: 5, photos: [metas[0].id, metas[1].id], uploads: [metas[0], metas[1]] });
  await repo.addTripFeedback({ tripId: 'trip_photo_2', email: G.user.email, rating: 4, photos: [metas[2].id], uploads: [metas[2]] });
  // Someone else's photo stays.
  const keep = await store.save({ mime: 'image/png', ext: 'png', data: Buffer.from('keep') });
  await repo.addTripFeedback({ tripId: 'trip_photo_3', userId: lead.user.userId, rating: 5, photos: [keep.id], uploads: [keep] });
  for (const m of [...metas, keep]) assert.ok(fs.existsSync(store.fileOf(m)));

  // 150 guardian grants, each with a session (more than one page of 100).
  for (let i = 0; i < 150; i++) {
    await repo.createGuardianGrant({ grantId: `grant_${i}`, tokenHash: `tok_${i}`, creatorId: uid, groupId: 'g1', createdAt: Date.now() });
    await repo.createGuardianSession({ sessionHash: `sess_${i}`, grantId: `grant_${i}` });
  }

  // An SOS with a public live link, and a standalone SMS-gateway link.
  const c = (await t.api('POST', '/convoys', { name: 'Link ride' }, lead.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, G.token)).status, 200);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wg = await t.joinRoom(G.token, c.groupId);
  wg.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH_OR_EMERGENCY', clientId: 'erase-link-1' });
  const alert = (await wl.next((m) => m.type === 'ALERT')).alert;
  const made = await t.api('POST', `/convoys/${c.groupId}/alerts/${alert.alertId}/live-link`, {}, G.token);
  assert.equal(made.status, 200, JSON.stringify(made.json));
  const view = (tok) => fetch(`${t.origin}/api/public/live/${tok}`).then((r) => r.status);
  assert.equal(await view(made.json.token), 200);
  const smsUrl = t.gw.convoys.emergencyGateway.generateTrackingUrl({ tripId: c.groupId, riderId: uid, riderName: 'Grant Gone', lat: 17.38, lng: 78.48 });
  const smsToken = smsUrl.split('/e/')[1];
  assert.equal(await view(smsToken), 200);

  assert.equal((await t.api('DELETE', '/me', null, G.token)).status, 200);
  await wg.closed;
  wl.close();

  for (const m of metas) assert.ok(!fs.existsSync(store.fileOf(m)), `photo ${m.id} deleted`);
  assert.ok(fs.existsSync(store.fileOf(keep)), 'another rider\'s photo stays');
  assert.equal((await repo.soda.query('guardian_grants', {}, { limit: 1000 })).filter((r) => r.value.creatorId === uid).length, 0);
  assert.equal((await t.api('GET', '/public/live/' + made.json.token)).status, 410);
  assert.equal(await view(smsToken), 410);
  assert.ok(![...t.gw.convoys.liveLinks.values()].some((ref) => ref.alertId === alert.alertId), 'live link index entry gone');
  for (const [coll, json] of everything()) assert.ok(!json.includes(uid), `${coll} still mentions the rider`);
});
