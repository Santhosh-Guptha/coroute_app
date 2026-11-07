'use strict';
/**
 * Public ride and safe contact (src/public_ride.js): host-only settings, visibility within both radii,
 * coarse positions (500 m grid, compass heading, no ids or names), parked rides hidden, contact requests
 * (filter, rate limits, no PII, guests), accept / chat / location / block / suspension / report, SOS
 * interplay, and road warnings for riders coming toward the spot (2 confirmations, expiry, votes).
 * Synthetic highway along a meridian (lat 17.40 .. 17.70); each test rides on its own meridian.
 */
process.env.PUBLIC_RIDE_TICK_MS = '3600000';
process.env.ADMIN_EMAILS = 'pr.admin@coroute.test,pr.admin2@coroute.test';
const { netBoot, line, E_LAT } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { cleanText, snap, geohash, cellsFor, isGuest } = require('../src/public_ride');
const { applyPublicRidePatch, publicRideOf } = require('../src/public_ride_settings');

let h;
let laneNo = 0;
const lane = () => 30 + (laneNo++) * 0.5; // 50 km apart
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

const pr = () => h.t.gw.publicRides;
const uidOf = (u) => u.user.userId;

/** JOIN with the public ride capability; records every frame. */
async function sock(token, gid) {
  const ws = await h.t.connect(token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'JOIN', groupId: gid, caps: ['net1', 'pubride1'] });
  const snap = await ws.next((m) => m.type === 'SNAPSHOT');
  ws.snapshot = snap.convoy;
  ws.frames = [];
  ws.on('message', (d, bin) => { if (!bin) ws.frames.push(JSON.parse(d.toString())); });
  return ws;
}

async function ride(points, name, { pub = true, radiusKm = 10, showName = false, showDestRegion = false } = {}) {
  const R = await h.rideOn(points, { name });
  R.ws = await sock(R.lead.token, R.gid);
  if (pub) {
    R.ws.sendJson({ type: 'CONFIG', publicRide: { on: true, radiusKm, showName, showDestRegion } });
    await R.ws.next((m) => m.type === 'CONFIG');
  }
  return R;
}
async function member(R, tag = 'Member') {
  const u = await h.join(R, tag);
  const ws = await sock(u.token, R.gid);
  return { u, ws };
}
const tick = (dt = 0) => pr().tick(Date.now() + dt);
async function rides(ws) {
  await h.settle();
  const l = h.got(ws, 'PUBLIC_RIDES');
  return l.length ? l[l.length - 1].rides : [];
}
const rideIdOf = (R) => publicRideOf(h.t.gw.convoys.rooms.get(R.gid).meta.publicRide).id;
async function ask(ws, msg, okType) {
  ws.sendJson(msg);
  return ws.next((m) => m.type === okType || m.type === 'ERROR');
}

// ------------------------------------------------------------------ pure helpers
test('text filter: short lines pass; links, numbers, handles and bad words are refused', () => {
  assert.deepEqual(cleanText('  Need   petrol, 2 km back  '), { ok: true, text: 'Need petrol, 2 km back' });
  assert.equal(cleanText('').text, '');
  for (const bad of ['call me 98765 43210', '+91-98765-43210', 'nine eight seven six five four three', 'see www.example.com', 'https://x.io/a', 'mail me a@b.com', 'insta @rider_kid', 'you are a f*ck', 'chutiya', 'x'.repeat(81)]) {
    assert.equal(cleanText(bad).ok, false, bad);
  }
  assert.equal(cleanText('Fuel at 5 km, exit 2').ok, true);
});

test('settings model: off by default; a new opaque id each time it is turned on; radius from 5/10/25/50 only', () => {
  const off = publicRideOf(undefined);
  assert.deepEqual({ on: off.on, radiusKm: off.radiusKm, id: off.id }, { on: false, radiusKm: 10, id: '' });
  const on = applyPublicRidePatch(off, { on: true, radiusKm: 25, showName: true });
  assert.match(on.id, /^PR-[0-9A-F]{12}$/);
  assert.equal(on.radiusKm, 25);
  assert.equal(applyPublicRidePatch(on, { radiusKm: 7 }).radiusKm, 25, 'not a choice: unchanged');
  const off2 = applyPublicRidePatch(on, { on: false });
  assert.equal(off2.id, '');
  const on2 = applyPublicRidePatch(off2, { on: true });
  assert.notEqual(on2.id, on.id);
});

test('coarse position: a fixed 500 m grid; geohash cells cover the radius', () => {
  const a = snap(17.45012, 78.00011), b = snap(17.45101, 78.00102);
  assert.deepEqual(a, b, 'both inside one cell');
  const c = snap(17.4537, 78.0);
  assert.notDeepEqual(a, c);
  const lat = 17.45, lng = 78.0;
  assert.ok(Math.abs(a.lat - 17.45012) * 111320 <= 260);
  const cells = cellsFor(lat, lng, 50000);
  assert.ok(cells.has(geohash(lat + 0.44, lng, 4)) && cells.has(geohash(lat, lng - 0.46, 4)));
  assert.ok(cells.size < 80);
  assert.equal(isGuest({ email: 'guest_1_2@guest.coroute.local' }), true);
  assert.equal(isGuest({ email: 'rider@coroute.test' }), false);
});

// ------------------------------------------------------------------ settings and visibility
test('Public ride is off by default; only the host turns it on; the ride sees its settings, never its id', async () => {
  const lng = lane();
  const A = await ride(line(lng, 17.40, 17.70), 'Hill Gang', { pub: false });
  assert.deepEqual(A.ws.snapshot.publicRide, { on: false, radiusKm: 10, showName: false, showDestRegion: false });
  const M = await member(A);
  const err = await ask(M.ws, { type: 'CONFIG', publicRide: { on: true } }, 'CONFIG');
  assert.equal(err.type, 'ERROR');
  assert.equal(err.code, 403);
  A.ws.sendJson({ type: 'CONFIG', publicRide: { on: true, radiusKm: 25 } });
  const cfg = await M.ws.next((m) => m.type === 'CONFIG');
  assert.deepEqual(cfg.publicRide, { on: true, radiusKm: 25, showName: false, showDestRegion: false });
  assert.ok(!JSON.stringify(cfg).includes(rideIdOf(A)));
  assert.match(rideIdOf(A), /^PR-[0-9A-F]{12}$/);
  await h.endRide(A);
});

test('visibility: within BOTH radii only; "Show public rides near me" uses its own radius; private rides never appear', async () => {
  const lng = lane();
  const A = await ride(line(lng, 17.40, 17.70), 'North', { radiusKm: 5 });
  const B = await ride(line(lng, 17.70, 17.40), 'South', { radiusKm: 50 });
  const P = await ride(line(lng, 17.40, 17.70), 'Private', { pub: false });
  h.place(A.gid, A.lead, 17.45, lng, 0, 60);
  h.place(B.gid, B.lead, 17.522, lng, 180, 60); // 8 km
  h.place(P.gid, P.lead, 17.47, lng, 0, 60);
  tick();
  assert.deepEqual(await rides(A.ws), [], 'A: 8 km > its 5 km');
  assert.deepEqual(await rides(B.ws), [], "B: 8 km > A's 5 km");
  A.ws.sendJson({ type: 'CONFIG', publicRide: { radiusKm: 10 } });
  await A.ws.next((m) => m.type === 'CONFIG');
  tick();
  const seenByA = await rides(A.ws);
  assert.equal(seenByA.length, 1);
  assert.deepEqual({ ...seenByA[0], lat: 0, lng: 0 }, { rideId: rideIdOf(B), label: 'Rider', riders: 1, distanceKm: 8, lat: 0, lng: 0, heading: 'S' });
  const seenByB = await rides(B.ws);
  assert.equal(seenByB.length, 1);
  assert.equal(seenByB[0].heading, 'N');
  assert.equal(seenByB[0].rideId, rideIdOf(A));
  // The private ride's rider watches with "Show public rides near me".
  P.ws.sendJson({ type: 'PR_PREFS', showNearby: true, radiusKm: 10, roadWarnings: false });
  await P.ws.next((m) => m.type === 'PR_PREFS_OK');
  tick();
  assert.deepEqual((await rides(P.ws)).map((r) => r.rideId), [rideIdOf(A), rideIdOf(B)]);
  P.ws.sendJson({ type: 'PR_PREFS', showNearby: true, radiusKm: 5 });
  await P.ws.next((m) => m.type === 'PR_PREFS_OK');
  tick();
  assert.deepEqual((await rides(P.ws)).map((r) => r.rideId), [rideIdOf(A)]);
  for (const ws of [A.ws, B.ws]) for (const f of h.got(ws, 'PUBLIC_RIDES')) assert.ok(!JSON.stringify(f).includes(P.gid));
  // Turned off: gone at the next list.
  B.ws.sendJson({ type: 'CONFIG', publicRide: { on: false } });
  await B.ws.next((m) => m.type === 'CONFIG');
  tick();
  assert.deepEqual(await rides(A.ws), []);
  for (const R of [A, B, P]) await h.endRide(R);
});

test('what is shown: snapped centre, compass heading, "Group of N" or the ride name (only if clean); no ids, names or numbers', async () => {
  const lng = lane();
  const G = await ride(line(lng, 17.40, 17.70), 'Hill Gang', { showName: false, showDestRegion: true });
  const m = await member(G, 'Second');
  const W = await ride(line(lng, 17.40, 17.70), 'Watcher', { pub: true });
  const base = snap(17.4502, lng + 0.0001); // a cell centre
  h.place(G.gid, G.lead, base.lat - 0.0002, base.lng - 0.0002, 0, 60);
  h.place(G.gid, m.u, base.lat + 0.0002, base.lng + 0.0002, 10, 60);
  h.place(W.gid, W.lead, 17.43, lng, 0, 60);
  tick();
  const [g] = await rides(W.ws);
  assert.equal(g.label, 'Group of 2');
  assert.equal(g.riders, 2);
  assert.equal(g.heading, 'N');
  assert.equal(g.destRegion, 'End');
  assert.deepEqual({ lat: g.lat, lng: g.lng }, base);
  // Riders move about 50 m inside the same cell: nothing new is sent (the list did not change).
  const before = h.got(W.ws, 'PUBLIC_RIDES').length;
  h.place(G.gid, G.lead, base.lat + 0.0003, base.lng - 0.0001, 0, 60);
  h.place(G.gid, m.u, base.lat + 0.0005, base.lng + 0.0003, 0, 60);
  tick();
  await h.settle();
  assert.equal(h.got(W.ws, 'PUBLIC_RIDES').length, before);
  const raw = JSON.stringify(h.got(W.ws, 'PUBLIC_RIDES'));
  for (const secret of [G.gid, uidOf(G.lead), uidOf(m.u), G.lead.user.name, m.u.user.name, G.c.joinCode, G.lead.user.email]) {
    assert.ok(!raw.includes(secret), `leaked ${secret}`);
  }
  for (const u of [G.lead, m.u]) if (u.user.phone) assert.ok(!raw.includes(u.user.phone.slice(-7)), 'no phone numbers');
  // The host shows the ride name; a name carrying a phone number is never shown.
  G.ws.sendJson({ type: 'CONFIG', publicRide: { showName: true } });
  await G.ws.next((x) => x.type === 'CONFIG');
  tick();
  assert.equal((await rides(W.ws))[0].label, 'Hill Gang');
  h.t.gw.convoys.rooms.get(G.gid).meta.name = 'Call 9876543210';
  tick();
  assert.equal((await rides(W.ws))[0].label, 'Group of 2');
  for (const R of [G, W]) await h.endRide(R);
});

test('a ride parked for more than 10 minutes is hidden, and shows again when it moves', async () => {
  const lng = lane();
  const A = await ride(line(lng, 17.40, 17.70), 'Parked');
  const W = await ride(line(lng, 17.40, 17.70), 'Watcher');
  h.place(A.gid, A.lead, 17.45, lng, 0, 0);
  h.place(W.gid, W.lead, 17.43, lng, 0, 60);
  tick();
  assert.equal((await rides(W.ws)).length, 1);
  const t11 = 11 * 60000;
  for (const [R, u] of [[A, A.lead], [W, W.lead]]) h.t.gw.convoys.rooms.get(R.gid).riders.get(uidOf(u)).lastSeenEpochMs = Date.now() + t11;
  tick(t11);
  assert.deepEqual(await rides(W.ws), []);
  h.place(A.gid, A.lead, 17.46, lng, 0, 40);
  h.place(W.gid, W.lead, 17.43, lng, 0, 60);
  tick();
  assert.equal((await rides(W.ws)).length, 1);
  for (const R of [A, W]) await h.endRide(R);
});

// ------------------------------------------------------------------ safe contact
async function pairNear(lng, opts = {}) {
  const A = await ride(line(lng, 17.40, 17.70), opts.aName || 'Host Ride', opts.a || {});
  const B = await ride(line(lng, 17.70, 17.40), opts.bName || 'Asker Ride', opts.b || {});
  h.place(A.gid, A.lead, 17.45, lng, 0, 60);
  h.place(B.gid, B.lead, 17.48, lng, 180, 60);
  tick();
  await h.settle();
  return { A, B };
}

test('contact: Say hi reaches the host as PR_REQUEST with a label only; filter, rate limits and quick replies', async () => {
  const lng = lane();
  const { A, B } = await pairNear(lng);
  const bad = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HI', quick: 'HI', text: 'call 98765 43210' }, 'PR_SENT');
  assert.equal(bad.type, 'ERROR'); assert.equal(bad.reason, 'TEXT_NOT_ALLOWED');
  const unknown = await ask(B.ws, { type: 'PR_CONTACT', rideId: 'PR-000000000000', kind: 'HI', quick: 'HI' }, 'PR_SENT');
  assert.equal(unknown.reason, 'RIDE_GONE');
  const sent = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HELP', quick: 'FUEL', text: 'Out of petrol near the bridge' }, 'PR_SENT');
  assert.equal(sent.type, 'PR_SENT');
  assert.match(sent.requestId, /^PRQ-[0-9A-F]{12}$/);
  const req = await A.ws.next((m) => m.type === 'PR_REQUEST');
  assert.equal(req.kind, 'HELP');
  assert.equal(req.quickText, 'Need fuel');
  assert.equal(req.text, 'Out of petrol near the bridge');
  assert.equal(req.from.label, 'Rider');
  assert.equal(req.from.rideId, rideIdOf(B), 'the asker is a public ride too: its marker');
  assert.equal(req.distanceKm, 3);
  const raw = JSON.stringify(req);
  for (const s of [B.gid, uidOf(B.lead), B.lead.user.name, B.lead.user.email, B.lead.user.phone || '+91']) assert.ok(!raw.includes(s), `leaked ${s}`);
  // One open request per ride; then the per-ride gap.
  const again = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HI', quick: 'HI' }, 'PR_SENT');
  assert.equal(again.code, 429);
  // The host replies with a quick line.
  const ok = await ask(A.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'QUICK', quick: 'ON_MY_WAY' }, 'PR_REPLY_OK');
  assert.equal(ok.type, 'PR_REPLY_OK');
  const msg = await B.ws.next((m) => m.type === 'PR_MESSAGE');
  assert.equal(msg.ref, sent.requestId); assert.equal(msg.quickText, 'On my way');
  // The asker cannot answer as the host.
  const notMine = await ask(B.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'ACCEPT' }, 'PR_REPLY_OK');
  assert.equal(notMine.reason, 'REQUEST_CLOSED');
  // Ignore: the asker only learns the request closed.
  await ask(A.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'IGNORE' }, 'PR_REPLY_OK');
  const closed = await B.ws.next((m) => m.type === 'PR_UPDATE');
  assert.deepEqual({ ...closed, ts: 0 }, { type: 'PR_UPDATE', requestId: sent.requestId, state: 'CLOSED', ts: 0 });
  // 4 per 10 minutes per rider (any rides).
  await h.settle(1000);
  for (let i = 0; i < 4; i++) {
    pr().rate.delete(`c2:${uidOf(B.lead)}:${rideIdOf(A)}`);
    for (const q of pr().requests.values()) if (q.fromId === uidOf(B.lead)) q.state = 'CLOSED';
    const r = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HI', quick: 'RIDE_SAFE' }, 'PR_SENT');
    assert.equal(r.type, i < 3 ? 'PR_SENT' : 'ERROR', `contact ${i + 2}`);
    if (i === 3) assert.equal(r.reason, 'RATE');
  }
  for (const R of [A, B]) await h.endRide(R);
});

test('accept opens a 30 minute chat: quick lines, own live location, contact only when shared; block closes it and hides both', async () => {
  const lng = lane();
  const { A, B } = await pairNear(lng);
  const sent = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HELP', quick: 'PUNCTURE' }, 'PR_SENT');
  await A.ws.next((m) => m.type === 'PR_REQUEST');
  const acc = await ask(A.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'ACCEPT' }, 'PR_REPLY_OK');
  const chB = await B.ws.next((m) => m.type === 'PR_CHANNEL');
  const chA = await A.ws.next((m) => m.type === 'PR_CHANNEL');
  assert.equal(chB.channelId, acc.channelId); assert.equal(chB.state, 'OPEN');
  assert.ok(Math.abs(chB.expiresAt - Date.now() - 30 * 60000) < 5000);
  assert.equal(chA.with.label, 'Rider');
  const up = await B.ws.next((m) => m.type === 'PR_UPDATE');
  assert.equal(up.state, 'ACCEPTED');
  await ask(B.ws, { type: 'PR_SAY', channelId: acc.channelId, quick: 'WAIT_THERE', text: 'At the blue dhaba' }, 'PR_SAY_OK');
  const said = await A.ws.next((m) => m.type === 'PR_MESSAGE');
  assert.equal(said.text, 'At the blue dhaba');
  const fast = await ask(B.ws, { type: 'PR_SAY', channelId: acc.channelId, quick: 'THANKS' }, 'PR_SAY_OK');
  assert.equal(fast.code, 429, 'one line per 3 s');
  // Live location: only the sharer's own, only after they turn it on.
  assert.equal(h.got(A.ws, 'PR_LOCATION').length, 0);
  await ask(B.ws, { type: 'PR_SHARE_LOC', channelId: acc.channelId, on: true }, 'PR_SHARE_LOC_OK');
  const loc = await A.ws.next((m) => m.type === 'PR_LOCATION');
  assert.equal(loc.lat, 17.48);
  await ask(B.ws, { type: 'PR_SHARE_LOC', channelId: acc.channelId, on: false }, 'PR_SHARE_LOC_OK');
  assert.equal((await A.ws.next((m) => m.type === 'PR_LOCATION')).off, true);
  // Contact details only when the host chooses to share them.
  assert.equal(h.got(B.ws, 'PR_CONTACT_SHARED').length, 0);
  await ask(A.ws, { type: 'PR_SHARE_CONTACT', channelId: acc.channelId }, 'PR_SHARE_CONTACT_OK');
  const shared = await B.ws.next((m) => m.type === 'PR_CONTACT_SHARED');
  assert.ok(shared.phone.length >= 7);
  assert.equal(shared.name, A.lead.user.name.split(' ')[0]);
  // Block: the chat closes for both; neither sees the other's ride; a new request is silently dropped.
  await ask(A.ws, { type: 'PR_BLOCK', ref: acc.channelId }, 'PR_BLOCK_OK');
  assert.equal((await B.ws.next((m) => m.type === 'PR_CHANNEL' && m.state === 'CLOSED')).channelId, acc.channelId);
  tick();
  assert.deepEqual(await rides(B.ws), []);
  assert.deepEqual(await rides(A.ws), []);
  assert.ok(pr().blocked(uidOf(A.lead), uidOf(B.lead)));
  const stored = await h.t.soda.query('public_ride', { k: 'block', blocker: uidOf(A.lead) });
  assert.equal(stored.length, 1);
  assert.ok(stored[0].value.until - Date.now() > 29 * 86400000);
  for (const R of [A, B]) await h.endRide(R);
});

test('blocked by 3 different riders: public ride paused for 7 days (no list, no contact, no warnings); a blocked sender is silently dropped', async () => {
  const lng = lane();
  const { A, B } = await pairNear(lng);
  const bad = uidOf(B.lead);
  // A blocks B through a request: B's next request is "sent" but never reaches A.
  pr().block(uidOf(A.lead), bad);
  const C = await ride(line(lng, 17.40, 17.70), 'Third');
  h.place(C.gid, C.lead, 17.47, lng, 0, 60);
  tick();
  const ids = (await rides(B.ws)).map((r) => r.rideId);
  assert.ok(!ids.includes(rideIdOf(A)) && ids.includes(rideIdOf(C)));
  pr().block('usr_other_1', bad);
  assert.equal(pr().suspendedUntil(bad), 0);
  pr().block('usr_other_2', bad);
  assert.ok(pr().suspendedUntil(bad) - Date.now() > 6.9 * 86400000);
  tick();
  assert.deepEqual(await rides(B.ws), []);
  const r = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(C), kind: 'HI', quick: 'HI' }, 'PR_SENT');
  assert.equal(r.reason, 'SUSPENDED');
  const w = await ask(B.ws, { type: 'ROAD_WARN', kind: 'POLICE' }, 'ROAD_WARN_SENT');
  assert.equal(w.reason, 'SUSPENDED');
  // B's own ride is hidden from others too.
  assert.ok(!(await rides(C.ws)).some((x) => x.rideId === rideIdOf(B)));
  pr().suspend(bad, 0);
  for (const R of [A, B, C]) await h.endRide(R);
});

test('guest mode is retired: no guest session can reach public rides', async () => {
  const g = await h.t.api('POST', '/auth/guest', { name: 'Visitor' });
  assert.equal(g.status, 410, JSON.stringify(g.json));
  assert.equal(g.json.code, 'GUEST_RETIRED');
  // The server-side rule stays for any record an older gateway left behind.
  assert.equal(isGuest({ provider: 'guest' }), true);
  assert.equal(isGuest({ provider: 'password', email: 'a@b.c' }), false);
});

test('report: stored with the conversation for admin review (admins only); contacts are logged', async () => {
  const lng = lane();
  const { A, B } = await pairNear(lng);
  const sent = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HI', quick: 'WHERE_TO', text: 'Heading to the lake?' }, 'PR_SENT');
  await A.ws.next((m) => m.type === 'PR_REQUEST');
  const rep = await ask(A.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'REPORT', reason: 'SPAM', text: 'Keeps asking', block: true }, 'PR_REPLY_OK');
  assert.equal(rep.type, 'PR_REPLY_OK');
  await h.settle(50);
  const admin = await h.rider('Admin', { email: 'pr.admin@coroute.test' });
  const list = await h.t.api('GET', '/admin/public-ride/reports', null, admin.token);
  assert.equal(list.status, 200, JSON.stringify(list.json));
  const r = list.json.reports.find((x) => x.ref === sent.requestId);
  assert.ok(r, 'report stored');
  assert.equal(r.reporterId, uidOf(A.lead)); assert.equal(r.reportedId, uidOf(B.lead));
  assert.equal(r.reason, 'SPAM');
  assert.deepEqual(r.transcript.map((x) => [x.from, x.quick, x.text]), [['REPORTED', 'WHERE_TO', 'Heading to the lake?']]);
  assert.ok(pr().blocked(uidOf(A.lead), uidOf(B.lead)));
  const log = await h.t.api('GET', `/admin/public-ride/log?userId=${uidOf(B.lead)}`, null, admin.token);
  assert.ok(log.json.log.some((x) => x.ref === sent.requestId && x.kind === 'HI'));
  const nope = await h.t.api('GET', '/admin/public-ride/reports', null, B.lead.token);
  assert.equal(nope.status, 403);
  for (const R of [A, B]) await h.endRide(R);
});

test('report review (admin console): names, warn on the record, suspend, dismiss', async () => {
  const lng = lane();
  const { A, B } = await pairNear(lng);
  const sent = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(A), kind: 'HI', quick: 'HI', text: '' }, 'PR_SENT');
  await A.ws.next((m) => m.type === 'PR_REQUEST');
  await ask(A.ws, { type: 'PR_REPLY', requestId: sent.requestId, action: 'REPORT', reason: 'ABUSE', text: 'Rude' }, 'PR_REPLY_OK');
  await h.settle(50);
  const admin = await h.rider('Admin2', { email: 'pr.admin2@coroute.test' });
  const list = await h.t.api('GET', '/admin/public-ride/reports?status=OPEN', null, admin.token);
  const r = list.json.reports.find((x) => x.ref === sent.requestId);
  assert.ok(r, 'open report listed');
  assert.equal(typeof r.reportedName, 'string'); assert.equal(typeof r.reporterName, 'string');
  assert.equal(r.reportedSuspendedUntil, 0);
  // Unknown action: refused, nothing changes.
  const bad = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'BAN' }, admin.token);
  assert.equal(bad.status, 400);
  // Warn: actioned, and a WARNED entry on the reported rider's record.
  const warn = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'ACTIONED', action: 'WARN' }, admin.token);
  assert.equal(warn.status, 200, JSON.stringify(warn.json));
  await h.settle(50);
  const log = await h.t.api('GET', `/admin/public-ride/log?userId=${uidOf(B.lead)}`, null, admin.token);
  assert.ok(log.json.log.some((x) => x.kind === 'WARNED' && x.ref === r.reportId), 'warning on the record');
  // Suspend 7 days: the list shows it.
  const susp = await h.t.api('POST', `/admin/public-ride/users/${uidOf(B.lead)}/suspension`, { days: 7 }, admin.token);
  assert.equal(susp.status, 200);
  assert.ok(susp.json.suspendedUntil > Date.now() + 6 * 86400000);
  const all = await h.t.api('GET', '/admin/public-ride/reports', null, admin.token);
  const after = all.json.reports.find((x) => x.reportId === r.reportId);
  assert.equal(after.status, 'ACTIONED'); assert.equal(after.action, 'WARN');
  assert.ok(after.reportedSuspendedUntil > Date.now());
  // Dismiss: reviewed; no longer in the open list. Lift the suspension again.
  const dis = await h.t.api('PATCH', `/admin/public-ride/reports/${r.reportId}`, { status: 'REVIEWED', action: 'DISMISS' }, admin.token);
  assert.equal(dis.status, 200);
  const open = await h.t.api('GET', '/admin/public-ride/reports?status=OPEN', null, admin.token);
  assert.ok(!open.json.reports.some((x) => x.reportId === r.reportId));
  await h.t.api('POST', `/admin/public-ride/users/${uidOf(B.lead)}/suspension`, { days: 0 }, admin.token);
  assert.equal(pr().suspendedUntil(uidOf(B.lead)), 0);
  for (const R of [A, B]) await h.endRide(R);
});

// ------------------------------------------------------------------ SOS interplay
test('SOS: a ride with an open SOS takes no requests and leaves the map; public-ride riders are still asked to help', async () => {
  const lng = lane();
  const V = await ride(line(lng, 17.40, 17.70), 'Victim');
  const B = await ride(line(lng, 17.40, 17.70), 'Public Helper');
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  h.place(B.gid, B.lead, 17.473, lng, 0, 60);
  tick();
  assert.ok((await rides(B.ws)).some((r) => r.rideId === rideIdOf(V)));
  await h.sos(V.ws, E_LAT, lng);
  const reqHelp = await B.ws.next((m) => m.type === 'ASSIST_REQUEST', 3000);
  assert.match(reqHelp.incidentId, /^NET-/);
  const busy = await ask(B.ws, { type: 'PR_CONTACT', rideId: rideIdOf(V), kind: 'HELP', quick: 'FIRST_AID' }, 'PR_SENT');
  assert.equal(busy.reason, 'BUSY');
  tick();
  assert.ok(!(await rides(B.ws)).some((r) => r.rideId === rideIdOf(V)));
  // The rider in SOS is told to use SOS, not public ride.
  const own = await ask(V.ws, { type: 'PR_CONTACT', rideId: rideIdOf(B), kind: 'HELP', quick: 'FIRST_AID' }, 'PR_SENT');
  assert.ok(['SOS_OPEN', 'RIDE_GONE'].includes(own.reason), own.reason);
  // Nothing of public ride ever went to the SOS lane.
  for (const R of [V, B]) await h.endRide(R);
});

// ------------------------------------------------------------------ road warnings
async function road(lng) {
  const R = await ride(line(lng, 17.70, 17.40), 'Reporter'); // southbound
  const C = await ride(line(lng, 17.40, 17.70), 'Close'); // northbound, 3 km before
  const A = await ride(line(lng, 17.40, 17.70), 'Far'); // northbound, 11 km before
  const D = await ride(line(lng, 17.70, 17.40), 'Away'); // southbound, already past (behind)
  const E = await ride(line(lng, 17.40, 17.70), 'Off', { pub: false }); // northbound, road warnings off
  h.place(R.gid, R.lead, 17.55, lng, 180, 50);
  h.place(C.gid, C.lead, 17.523, lng, 0, 60);
  h.place(A.gid, A.lead, 17.45, lng, 0, 60);
  h.place(D.gid, D.lead, 17.45, lng, 180, 60);
  h.place(E.gid, E.lead, 17.53, lng, 0, 60);
  return { R, C, A, D, E, all: [R, C, A, D, E] };
}

test('road warning: oncoming riders within 5 km get it at once; 20 km after a 2nd rider confirms; never riders past it or with warnings off', async () => {
  const lng = lane();
  const { R, C, A, D, E, all } = await road(lng);
  const s = await ask(R.ws, { type: 'ROAD_WARN', kind: 'ACCIDENT' }, 'ROAD_WARN_SENT');
  assert.equal(s.type, 'ROAD_WARN_SENT'); assert.equal(s.merged, false);
  const wc = await C.ws.next((m) => m.type === 'ROAD_WARNING');
  assert.equal(wc.kind, 'ACCIDENT'); assert.equal(wc.label, 'Accident');
  assert.equal(wc.by, 'ONCOMING'); assert.equal(wc.confirmed, false); assert.equal(wc.aheadKm, 3);
  assert.ok(Math.abs(wc.expiresAt - Date.now() - 60 * 60000) < 5000);
  const raw = JSON.stringify(wc);
  for (const x of [uidOf(R.lead), R.gid, R.lead.user.name]) assert.ok(!raw.includes(x));
  await h.settle();
  for (const X of [A, D, E, R]) assert.equal(h.got(X.ws, 'ROAD_WARNING').length, 0);
  // E turns road warnings on: gets it at the next tick.
  E.ws.sendJson({ type: 'PR_PREFS', showNearby: false, roadWarnings: true });
  await E.ws.next((m) => m.type === 'PR_PREFS_OK');
  tick();
  assert.equal((await E.ws.next((m) => m.type === 'ROAD_WARNING')).aheadKm, 2);
  // A second southbound rider reports the same thing 300 m on: confirmed, now 20 km.
  const R2 = await ride(line(lng, 17.70, 17.40), 'Reporter Two');
  h.place(R2.gid, R2.lead, 17.547, lng, 180, 50);
  const s2 = await ask(R2.ws, { type: 'ROAD_WARN', kind: 'ACCIDENT' }, 'ROAD_WARN_SENT');
  assert.equal(s2.merged, true); assert.equal(s2.confirmations, 2); assert.equal(s2.warnId, s.warnId);
  const wa = await A.ws.next((m) => m.type === 'ROAD_WARNING');
  assert.equal(wa.confirmed, true); assert.equal(wa.aheadKm, 11);
  assert.equal((await C.ws.next((m) => m.type === 'ROAD_WARNING')).confirmed, true, 'upgrade');
  await h.settle();
  assert.equal(h.got(D.ws, 'ROAD_WARNING').length, 0, 'already past it');
  // Expiry (60 min for an accident): cleared for everyone who got it.
  tick(61 * 60000);
  for (const X of [A, C, E]) assert.equal((await X.ws.next((m) => m.type === 'ROAD_WARNING_CLEAR')).warnId, s.warnId);
  assert.equal(pr().warnings.size, 0);
  for (const X of [...all, R2]) await h.endRide(X);
});

test('road warning abuse limits: 3 per 10 minutes; 2 "not there" votes clear it; voters must have received it', async () => {
  const lng = lane();
  const { R, C, E, all } = await road(lng);
  E.ws.sendJson({ type: 'PR_PREFS', roadWarnings: true });
  await E.ws.next((m) => m.type === 'PR_PREFS_OK');
  const w1 = await ask(R.ws, { type: 'ROAD_WARN', kind: 'POLICE' }, 'ROAD_WARN_SENT');
  await C.ws.next((m) => m.type === 'ROAD_WARNING');
  await E.ws.next((m) => m.type === 'ROAD_WARNING');
  // A rider who never got it cannot vote.
  const D2 = await ride(line(lng, 17.70, 17.40), 'Stranger');
  h.place(D2.gid, D2.lead, 17.30, lng, 180, 60);
  const nv = await ask(D2.ws, { type: 'ROAD_WARN_VOTE', warnId: w1.warnId, still: false }, 'ROAD_WARN_VOTE_OK');
  assert.equal(nv.reason, 'WARN_GONE');
  const v1 = await ask(C.ws, { type: 'ROAD_WARN_VOTE', warnId: w1.warnId, still: false }, 'ROAD_WARN_VOTE_OK');
  assert.equal(v1.cleared, false);
  const v2 = await ask(E.ws, { type: 'ROAD_WARN_VOTE', warnId: w1.warnId, still: false }, 'ROAD_WARN_VOTE_OK');
  assert.equal(v2.cleared, true);
  await C.ws.next((m) => m.type === 'ROAD_WARNING_CLEAR');
  // Rate limit: 3 new warnings per 10 minutes (the cleared one counts).
  assert.equal((await ask(R.ws, { type: 'ROAD_WARN', kind: 'ANIMALS' }, 'ROAD_WARN_SENT')).type, 'ROAD_WARN_SENT');
  assert.equal((await ask(R.ws, { type: 'ROAD_WARN', kind: 'WEATHER' }, 'ROAD_WARN_SENT')).type, 'ROAD_WARN_SENT');
  const fourth = await ask(R.ws, { type: 'ROAD_WARN', kind: 'FUEL_CLOSED' }, 'ROAD_WARN_SENT');
  assert.equal(fourth.code, 429);
  const badKind = await ask(R.ws, { type: 'ROAD_WARN', kind: 'ALIENS' }, 'ROAD_WARN_SENT');
  assert.equal(badKind.reason, 'BAD_KIND');
  for (const X of [...all, D2]) await h.endRide(X);
});
