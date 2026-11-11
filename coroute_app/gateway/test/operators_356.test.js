'use strict';
/**
 * 3.56 operator / club console (docs/features_355/operators.md): apply -> admin approval with limits and
 * features -> console access; roster, co-organiser, rides-per-month, riders-per-ride and concurrent-ride
 * limits; suspension; privacy of contacts outside an SOS; audit entries; public sign-up page capacity and
 * approval; club crews in the app's crew invite list; members leave; switch off; expiry.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'opsadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const OP = require('../src/operators');
const { operatorCapacity } = require('../src/entitlements');

let t;
let admin;
const pushes = [];
let seq = 0;

before(async () => {
  t = await boot();
  const ips = new Map();
  const call = t.api;
  t.api = (m, p, b, token, hd = {}) => {
    if (!ips.has(token)) ips.set(token, `198.51.${100 + (ips.size >> 8)}.${ips.size % 256}`);
    return call(m, p, b, token, { 'X-Forwarded-For': ips.get(token), ...hd });
  };
  admin = await t.register('Ops Console Admin', 'opsadmin@coroute.test');
  t.gw.hub.push = { notifyUsers: async (ids, opts) => { pushes.push({ ids, opts }); return { sent: ids.length }; }, onSocketEvent: async () => null };
});
after(async () => { await t.gw.shutdown(); });

async function rider(name) {
  seq++;
  const r = await t.api('POST', '/auth/register', {
    name, email: `ops${seq}_${Date.now()}@coroute.test`, password: 'Password#123',
    phone: `+9197${String(10000000 + seq).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA03OP${String(1000 + seq).slice(-4)}`,
    emergencyContact: '+919000000042', emergencyContactName: 'Family Contact',
  }, null, { 'X-Forwarded-For': `203.0.115.${seq % 250}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
const APP = { type: 'TOUR_OPERATOR', name: 'Deccan Moto Tours', city: 'Hyderabad', email: 'hello@deccanmoto.example', phone: '+91 98480 12345', website: 'deccanmoto.example', expectedRiders: 40, description: 'Weekend tours to Srisailam and Araku with a support van.' };
const auditOf = async (action) => (await t.api('GET', `/admin/audit?action=${action}&limit=200`, null, admin.token)).json.entries;

let owner; let a; let b; let c; let d; let e; let opId; let crewId;
let ride1; let ride2; let gid1;

test('apply: validation, pending status, one application, admin notified and audited', async () => {
  owner = await rider('Ravi Owner');
  const bad = await t.api('POST', '/operators/apply', { type: 'X', name: 'a', email: 'nope', phone: '1', description: 'call 9848012345 now please' }, owner.token);
  assert.equal(bad.status, 422);
  assert.equal(bad.json.code, 'INVALID_APPLICATION');
  for (const f of ['type', 'name', 'city', 'email', 'phone', 'expectedRiders', 'description']) assert.ok(bad.json.fields[f], f);
  assert.equal((await t.api('POST', '/operators/apply', APP, null)).status, 401);
  const ok = await t.api('POST', '/operators/apply', APP, owner.token);
  assert.equal(ok.status, 201, JSON.stringify(ok.json));
  assert.equal(ok.json.application.status, 'PENDING');
  assert.equal(ok.json.application.website, 'https://deccanmoto.example/');
  opId = ok.json.application.operatorId;
  assert.equal((await t.api('POST', '/operators/apply', APP, owner.token)).status, 409);
  const mine = await t.api('GET', '/operators/application', null, owner.token);
  assert.equal(mine.json.application.contact.email, 'hello@deccanmoto.example');
  // Web admin badge source + audit.
  assert.equal((await t.api('GET', '/admin/operators/summary', null, admin.token)).json.pending, 1);
  assert.equal((await t.api('GET', '/admin/operators/summary', null, owner.token)).status, 403);
  assert.equal((await t.api('GET', '/admin/operators', null, owner.token)).status, 403);
  assert.ok((await auditOf('operator.applied')).some((x) => x.target === opId));
  // No console before approval.
  const me = await t.api('GET', '/operator/me', null, owner.token);
  assert.deepEqual(me.json.operators, []);
  assert.equal(me.json.application.status, 'PENDING');
  assert.equal((await t.api('GET', `/operator/${opId}`, null, owner.token)).status, 404);
});

test('admin: list, detail with private contact, approve with limits and features (audited)', async () => {
  const list = await t.api('GET', '/admin/operators?status=PENDING', null, admin.token);
  assert.equal(list.status, 200);
  assert.equal(list.json.counts.PENDING, 1);
  assert.equal(list.json.operators[0].operatorId, opId);
  const det = await t.api('GET', `/admin/operators/${opId}`, null, admin.token);
  assert.equal(det.json.operator.contact.phone, '+91 98480 12345');
  assert.equal(det.json.template.limits.maxMembers, OP.DEFAULT_TEMPLATES.TOUR_OPERATOR.limits.maxMembers);
  const appr = await t.api('POST', `/admin/operators/${opId}/approve`, {
    limits: { maxMembers: 3, maxConcurrentRides: 1, maxRidesPerMonth: 2, maxRidersPerRide: 3, coOrganisers: 1 },
    features: { multiGroupDashboard: true, rosterEmergency: true, attendance: true, rideCalendar: true, broadcast: true, exportReports: false },
    validityDays: 90,
  }, admin.token);
  assert.equal(appr.status, 200, JSON.stringify(appr.json));
  assert.equal(appr.json.operator.status, 'APPROVED');
  assert.deepEqual(appr.json.operator.limits, { maxMembers: 3, maxConcurrentRides: 1, maxRidesPerMonth: 2, maxRidersPerRide: 3, coOrganisers: 1 });
  assert.equal((await t.api('POST', `/admin/operators/${opId}/approve`, {}, admin.token)).status, 409);
  const au = (await auditOf('operator.approve')).find((x) => x.target === opId);
  assert.ok(au && au.details.limits.maxMembers === 3 && au.details.features.exportReports === false);
  // Console opens; the business contact is shown to the owner only.
  const me = await t.api('GET', '/operator/me', null, owner.token);
  assert.equal(me.json.operators[0].role, 'OWNER');
  const con = await t.api('GET', `/operator/${opId}`, null, owner.token);
  assert.equal(con.status, 200);
  assert.equal(con.json.operator.limits.maxRidersPerRide, 3);
  assert.ok(con.json.operator.inviteLink.includes('/clubs/join/'));
  crewId = con.json.operator.crewId;
  assert.ok(crewId);
  // A stranger has no access (same 404 as an unknown operator).
  const stranger = await rider('Sam Stranger');
  assert.equal((await t.api('GET', `/operator/${opId}`, null, stranger.token)).status, 404);
});

test('roster: invites by username without friendship, limit counts pending invites, accept in the app or on the web', async () => {
  a = await rider('Anil Member');
  b = await rider('Bina Member');
  c = await rider('Chetan Rider');
  const inv = await t.api('POST', `/operator/${opId}/roster/invites`, { usernames: [a.user.username, b.user.username, 'NoSuchRider999'] }, owner.token);
  assert.equal(inv.status, 201, JSON.stringify(inv.json));
  assert.deepEqual(inv.json.results.map((x) => x.status), ['INVITED', 'INVITED', 'NOT_FOUND']);
  // Owner + 2 waiting = 3 = maxMembers.
  const full = await t.api('POST', `/operator/${opId}/roster/invites`, { usernames: [c.user.username] }, owner.token);
  assert.equal(full.status, 409);
  assert.equal(full.json.code, 'ROSTER_FULL');
  // The invite shows in the app's crew invites (People hub > Requests) and in /clubs.
  const crews = await t.api('GET', '/crews', null, a.token);
  const ci = crews.json.invites.find((x) => x.crewId === crewId);
  assert.ok(ci, 'club invite in the crew list');
  const clubs = await t.api('GET', '/clubs', null, b.token);
  assert.equal(clubs.json.invites[0].requestType, 'OPERATOR_INVITE');
  assert.ok(pushes.some((p) => p.opts.type === 'CREW_INVITE' && p.opts.data.kind === 'OPERATOR_INVITE'));
  // A accepts in the app (crew route: no friendship needed for a club), B on the website.
  assert.equal((await t.api('POST', `/crews/invites/${ci.inviteId}/accept`, null, a.token)).json.status, 'JOINED');
  assert.equal((await t.api('POST', `/clubs/invites/${clubs.json.invites[0].inviteId}/accept`, null, b.token)).json.status, 'JOINED');
  const ros = await t.api('GET', `/operator/${opId}/roster`, null, owner.token);
  assert.equal(ros.json.members.length, 3);
  // Privacy: no phone, e-mail or emergency contact in the roster.
  const raw = JSON.stringify(ros.json);
  assert.ok(!/phone|email|emergency|\+91/i.test(raw), raw);
  // The club crew is managed in the console: the owner cannot delete or rename it in the app.
  assert.equal((await t.api('DELETE', `/crews/${crewId}`, null, owner.token)).json.code, 'CLUB_MANAGED');
  assert.equal((await t.api('GET', `/crews/${crewId}`, null, a.token)).json.crew.club.operatorId, opId);
});

test('co-organisers: limited count, console access, owner-only management', async () => {
  const add = await t.api('POST', `/operator/${opId}/co-organisers`, { username: a.user.username }, owner.token);
  assert.equal(add.status, 201, JSON.stringify(add.json));
  const second = await t.api('POST', `/operator/${opId}/co-organisers`, { username: b.user.username }, owner.token);
  assert.equal(second.status, 409);
  assert.equal(second.json.code, 'CO_ORGANISER_LIMIT');
  assert.equal((await t.api('POST', `/operator/${opId}/co-organisers`, { username: c.user.username }, owner.token)).json.code, 'NOT_A_MEMBER');
  const me = await t.api('GET', '/operator/me', null, a.token);
  assert.equal(me.json.operators[0].role, 'CO_ORGANISER');
  assert.equal((await t.api('GET', `/operator/${opId}/roster`, null, a.token)).status, 200);
  assert.equal((await t.api('POST', `/operator/${opId}/co-organisers`, { username: b.user.username }, a.token)).json.code, 'OWNER_ONLY');
  assert.ok((await auditOf('operator.co_organiser_add')).some((x) => x.target === opId));
});

test('rides: riders-per-ride and rides-per-month limits; start uses operator capacity; concurrent limit', async () => {
  const tooMany = await t.api('POST', `/operator/${opId}/rides`, { title: 'Srisailam Run', startsAt: Date.now() + 3600000, maxRiders: 4 }, owner.token);
  assert.equal(tooMany.status, 422);
  assert.equal(tooMany.json.code, 'RIDERS_PER_RIDE_LIMIT');
  const notRoster = await t.api('POST', `/operator/${opId}/rides`, { title: 'Srisailam Run', maxRiders: 3, leadUsername: c.user.username }, owner.token);
  assert.equal(notRoster.json.code, 'NOT_A_MEMBER');
  const r1 = await t.api('POST', `/operator/${opId}/rides`, { title: 'Srisailam Run', startsAt: Date.now() + 60000, meetName: 'Tank Bund', destinationName: 'Srisailam', maxRiders: 3, sweeperUsername: b.user.username }, a.token);
  assert.equal(r1.status, 201, JSON.stringify(r1.json));
  ride1 = r1.json.ride;
  assert.equal(ride1.lead.username, a.user.username); // the co-organiser who created it leads
  const r2 = await t.api('POST', `/operator/${opId}/rides`, { title: 'Araku Valley Weekend', startsAt: Date.now() + 2 * 3600000, meetName: 'Vizag beach road', maxRiders: 3, publicSignup: true, requireApproval: true }, owner.token);
  assert.equal(r2.status, 201, JSON.stringify(r2.json));
  ride2 = r2.json.ride;
  assert.ok(ride2.publicUrl.includes(`/rides/${ride2.slug}`));
  const r3 = await t.api('POST', `/operator/${opId}/rides`, { title: 'Third Ride', startsAt: Date.now() + 3 * 3600000, maxRiders: 2 }, owner.token);
  assert.equal(r3.status, 409);
  assert.equal(r3.json.code, 'RIDES_PER_MONTH_LIMIT');
  // A cancelled ride frees its month slot.
  // Start ride 1: a normal convoy, trip owner = the lead (a Community rider), 3 seats from the operator limits.
  const st = await t.api('POST', `/operator/${opId}/rides/${ride1.rideId}/start`, null, owner.token);
  assert.equal(st.status, 200, JSON.stringify(st.json));
  assert.equal(st.json.capacity, 3);
  gid1 = st.json.groupId;
  const snap = await t.gw.convoys.getSnapshot(gid1);
  assert.equal(snap.capacity, 3);
  assert.equal(snap.capacityPlan, 'operator');
  assert.equal(snap.soloRide, false);
  assert.equal(snap.createdByUserId, a.user.userId);
  assert.equal(await operatorCapacity(t.gw.repo, gid1), 3);
  // Concurrent rides: 1.
  const st2 = await t.api('POST', `/operator/${opId}/rides/${ride2.rideId}/start`, null, owner.token);
  assert.equal(st2.status, 409);
  assert.equal(st2.json.code, 'CONCURRENT_RIDES_LIMIT');
  // A personal ride is not an operator ride.
  const own = await t.api('POST', '/convoys', { name: 'Solo spin' }, c.token);
  assert.equal(own.status, 201, JSON.stringify(own.json));
  assert.equal(await operatorCapacity(t.gw.repo, own.json.groupId), null);
  await t.api('POST', `/convoys/${own.json.groupId}/status`, { status: 'ENDED' }, c.token);
});

test('publish: ride invites to the roster, seats from the operator limit, sweeper role on join', async () => {
  const pub = await t.api('POST', `/operator/${opId}/rides/${ride1.rideId}/publish`, {}, owner.token);
  assert.equal(pub.status, 201, JSON.stringify(pub.json));
  // a leads (already in), owner and b get invites; 3 seats - 1 rider = 2.
  assert.equal(pub.json.invited, 2);
  const mineB = await t.api('GET', '/me/ride-invites', null, b.token);
  assert.equal(mineB.json.invites.length, 1);
  const acc = await t.api('POST', `/ride-invites/${mineB.json.invites[0].inviteId}/accept`, {}, b.token);
  assert.equal(acc.status, 200, JSON.stringify(acc.json));
  await new Promise((r) => setTimeout(r, 50));
  const room = t.gw.convoys.rooms.get(gid1);
  assert.equal(room.riders.get(b.user.userId).role, 'SWEEPER');
  const mineO = await t.api('GET', '/me/ride-invites', null, owner.token);
  assert.equal((await t.api('POST', `/ride-invites/${mineO.json.invites[0].inviteId}/accept`, {}, owner.token)).status, 200);
  // Full at 3: a stranger with the join code is refused.
  d = await rider('Divya Outsider');
  const join = await t.api('POST', '/convoys/join', { code: room.meta.joinCode }, d.token);
  assert.equal(join.status, 409, JSON.stringify(join.json));
  assert.ok(/full/i.test(join.json.error || ''), JSON.stringify(join.json));
});

test('live dashboard: positions and roles without contacts; emergency contact only during an open SOS (audited)', async () => {
  const room = t.gw.convoys.rooms.get(gid1);
  t.gw.convoys.patchRider(room, b.user.userId, { lat: 17.385, lng: 78.4867, speedKmh: 42 });
  const live = await t.api('GET', `/operator/${opId}/live`, null, owner.token);
  assert.equal(live.status, 200);
  assert.equal(live.json.rides.length, 1);
  assert.equal(live.json.sos, false);
  const raw = JSON.stringify(live.json);
  assert.ok(!/phone|email|emergencyContact|medical|\+91/i.test(raw), raw);
  const sweeper = live.json.rides[0].riders.find((x) => x.username === b.user.username);
  assert.equal(sweeper.role, 'SWEEPER');
  assert.equal(sweeper.lat, 17.385);
  // No SOS: refused.
  const none = await t.api('GET', `/operator/${opId}/rides/${ride1.rideId}/sos/al_none`, null, owner.token);
  assert.equal(none.status, 403);
  assert.equal(none.json.code, 'NO_ACTIVE_SOS');
  // b raises an SOS.
  const out = await t.gw.convoys.raiseSos(gid1, { userId: b.user.userId, name: b.user.name }, { lat: 17.39, lng: 78.49, alertType: 'SOS', clientId: 'ops-sos-1' });
  const alertId = out.alert.alertId;
  const live2 = await t.api('GET', `/operator/${opId}/live`, null, owner.token);
  assert.equal(live2.json.sos, true);
  assert.equal(live2.json.rides[0].alerts[0].rider.username, b.user.username);
  const con = await t.api('GET', `/operator/${opId}/rides/${ride1.rideId}/sos/${alertId}`, null, a.token);
  assert.equal(con.status, 200, JSON.stringify(con.json));
  assert.equal(con.json.emergencyContact.phone, '+919000000042');
  const au = (await auditOf('operator.sos_contacts_viewed')).find((x) => x.details.alertId === alertId);
  assert.ok(au && au.byUserId === a.user.userId);
  // Resolved: refused again.
  await t.gw.convoys.resolveSos(gid1, { userId: b.user.userId, name: b.user.name }, alertId, 'RESOLVED');
  assert.equal((await t.api('GET', `/operator/${opId}/rides/${ride1.rideId}/sos/${alertId}`, null, owner.token)).json.code, 'NO_ACTIVE_SOS');
  // A plan without the feature: refused even during an SOS.
  await t.api('PUT', `/admin/operators/${opId}/limits`, { features: { rosterEmergency: false } }, admin.token);
  assert.equal((await t.api('GET', `/operator/${opId}/rides/${ride1.rideId}/sos/${alertId}`, null, owner.token)).json.code, 'NOT_IN_PLAN');
  await t.api('PUT', `/admin/operators/${opId}/limits`, { features: { rosterEmergency: true } }, admin.token);
});

test('broadcast: Play guard, contact guard, push "Community update" to the roster', async () => {
  const bad = await t.api('POST', `/operator/${opId}/broadcasts`, { title: 'Big sale', body: 'Tour price 50% off this week' }, owner.token);
  assert.equal(bad.status, 422);
  assert.equal(bad.json.code, 'PLAY_POLICY');
  const phone = await t.api('POST', `/operator/${opId}/broadcasts`, { title: 'Call me', body: 'Ring 98480 12345 for details' }, owner.token);
  assert.equal(phone.json.code, 'CONTACT_IN_TEXT');
  pushes.length = 0;
  const ok = await t.api('POST', `/operator/${opId}/broadcasts`, { title: 'Sunday ride', body: 'Meet at 6 am at Tank Bund. Rain gear recommended.' }, owner.token);
  assert.equal(ok.status, 201, JSON.stringify(ok.json));
  assert.equal(ok.json.broadcast.recipients, 2);
  const p = pushes.find((x) => x.opts.type === 'NEWS');
  assert.ok(p && p.opts.data.kind === 'community_update' && p.ids.length === 2);
  const seen = await t.api('GET', '/clubs', null, b.token);
  assert.equal(seen.json.clubs[0].broadcasts[0].title, 'Sunday ride');
});

test('attendance and reports; CSV only with the export feature, no locations', async () => {
  const end = await t.api('POST', `/operator/${opId}/rides/${ride1.rideId}/end`, null, owner.token);
  assert.equal(end.status, 200, JSON.stringify(end.json));
  const att = await t.api('GET', `/operator/${opId}/rides/${ride1.rideId}/attendance`, null, owner.token);
  assert.equal(att.status, 200, JSON.stringify(att.json));
  assert.equal(att.json.attendance.joined, 3);
  assert.equal(att.json.attendance.incidents.length, 1);
  assert.ok(!/lat|lng|phone/i.test(JSON.stringify(att.json)));
  const rep = await t.api('GET', `/operator/${opId}/reports`, null, owner.token);
  assert.equal(rep.json.totals.rides, 1);
  assert.equal(rep.json.canExport, false);
  assert.equal((await t.api('GET', `/operator/${opId}/reports.csv`, null, owner.token)).json.code, 'NOT_IN_PLAN');
  await t.api('PUT', `/admin/operators/${opId}/limits`, { features: { exportReports: true } }, admin.token);
  const res = await fetch(`${t.base}/operator/${opId}/reports.csv`, { headers: { Authorization: `Bearer ${owner.token}` } });
  assert.equal(res.status, 200);
  const csv = await res.text();
  assert.ok(csv.includes('ride,ride_date_ist,status,username'));
  assert.ok(csv.includes(b.user.username));
  assert.ok(!/17\.3|78\.4|\+91/.test(csv));
  assert.ok((await auditOf('operator.report_export')).some((x) => x.target === opId));
});

test('public sign-up page: capacity and approval; join code only for approved riders of a live ride', async () => {
  const page = await fetch(`${t.origin}/rides/${ride2.slug}`);
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.ok(html.includes('Araku Valley Weekend') && html.includes('Deccan Moto Tours'));
  assert.ok(!/<script>/.test(html));
  assert.equal((await fetch(`${t.origin}/rides/unknown-ride-abcdef`)).status, 404);
  const pub = await t.api('GET', `/public/rides/${ride2.slug}`, null, null);
  assert.equal(pub.json.ride.seatsLeft, 2);
  assert.ok(!/userId|phone|email/.test(JSON.stringify(pub.json)));
  e = await rider('Esha Signup');
  assert.equal((await t.api('POST', `/rides/${ride2.slug}/signup`, null, null)).status, 401);
  assert.equal((await t.api('POST', `/rides/${ride2.slug}/signup`, null, c.token)).json.status, 'PENDING');
  assert.equal((await t.api('POST', `/rides/${ride2.slug}/signup`, null, d.token)).json.status, 'PENDING');
  assert.equal((await t.api('POST', `/rides/${ride2.slug}/signup`, null, e.token)).json.status, 'PENDING');
  const list = await t.api('GET', `/operator/${opId}/rides/${ride2.rideId}/signups`, null, owner.token);
  assert.equal(list.json.signups.length, 3);
  assert.ok(!/phone|email/.test(JSON.stringify(list.json)));
  assert.equal((await t.api('POST', `/operator/${opId}/rides/${ride2.rideId}/signups/${c.user.username}`, { approve: true }, owner.token)).status, 200);
  assert.equal((await t.api('POST', `/operator/${opId}/rides/${ride2.rideId}/signups/${d.user.username}`, { approve: true }, owner.token)).status, 200);
  const full = await t.api('POST', `/operator/${opId}/rides/${ride2.rideId}/signups/${e.user.username}`, { approve: true }, owner.token);
  assert.equal(full.status, 409);
  assert.equal(full.json.code, 'RIDE_FULL');
  assert.equal((await t.api('GET', `/public/rides/${ride2.slug}`, null, null)).json.ride.seatsLeft, 0);
  const f = await rider('Farah Late');
  assert.equal((await t.api('POST', `/rides/${ride2.slug}/signup`, null, f.token)).json.code, 'RIDE_FULL');
  assert.ok((await auditOf('operator.signup_decision')).some((x) => x.target === opId));
  // Before the ride: no join code.
  assert.equal((await t.api('GET', `/rides/${ride2.slug}/me`, null, c.token)).json.join, null);
  const st = await t.api('POST', `/operator/${opId}/rides/${ride2.rideId}/start`, null, owner.token);
  assert.equal(st.status, 200, JSON.stringify(st.json));
  const meC = await t.api('GET', `/rides/${ride2.slug}/me`, null, c.token);
  assert.equal(meC.json.status, 'APPROVED');
  assert.match(meC.json.join.code, /^\d{6}$/);
  assert.equal((await t.api('GET', `/rides/${ride2.slug}/me`, null, e.token)).json.join, null);
});

test('suspend blocks the console (reason required), reinstate restores it; live rides keep running', async () => {
  assert.equal((await t.api('POST', `/admin/operators/${opId}/suspend`, {}, admin.token)).json.code, 'REASON_REQUIRED');
  const s = await t.api('POST', `/admin/operators/${opId}/suspend`, { reason: 'Complaint under review' }, admin.token);
  assert.equal(s.status, 200, JSON.stringify(s.json));
  const blocked = await t.api('GET', `/operator/${opId}/rides`, null, owner.token);
  assert.equal(blocked.status, 403);
  assert.equal(blocked.json.code, 'OPERATOR_SUSPENDED');
  assert.equal(blocked.json.reason, 'Complaint under review');
  assert.equal((await t.api('GET', `/operator/${opId}`, null, a.token)).json.code, 'OPERATOR_SUSPENDED');
  // The live ride of the suspended operator is not cut.
  const ride = await OP.getRide(t.soda, ride2.rideId);
  assert.ok(await t.gw.convoys.isMember(ride.groupId, owner.user.userId));
  assert.equal((await t.api('POST', `/admin/operators/${opId}/reinstate`, {}, admin.token)).status, 200);
  assert.equal((await t.api('GET', `/operator/${opId}/rides`, null, owner.token)).status, 200);
  const acts = (await auditOf('operator')).filter((x) => x.target === opId).map((x) => x.action);
  for (const x of ['operator.applied', 'operator.approve', 'operator.limits', 'operator.suspend', 'operator.reinstate', 'operator.ride_start', 'operator.broadcast']) assert.ok(acts.includes(x), x);
});

test('members leave any time; the owner cannot; the invite link joins within the roster limit', async () => {
  assert.equal((await t.api('POST', `/clubs/${opId}/leave`, null, owner.token)).json.code, 'CLUB_MANAGED');
  const left = await t.api('POST', `/clubs/${opId}/leave`, null, b.token);
  assert.equal(left.status, 200);
  const ros = await t.api('GET', `/operator/${opId}/roster`, null, owner.token);
  assert.equal(ros.json.members.length, 2);
  const code = ros.json.inviteLink.split('/').pop();
  assert.equal((await t.api('GET', `/public/clubs/${code}`, null, null)).json.club.name, 'Deccan Moto Tours');
  assert.equal((await t.api('POST', '/clubs/join', { code }, c.token)).json.status, 'JOINED');
  const over = await t.api('POST', '/clubs/join', { code }, d.token);
  assert.equal(over.json.code, 'ROSTER_FULL');
  // Co-organiser leaving gives the seat back.
  assert.equal((await t.api('POST', `/clubs/${opId}/leave`, null, a.token)).status, 200);
  assert.equal((await t.api('GET', `/operator/${opId}`, null, a.token)).status, 404);
  assert.deepEqual((await OP.getOperator(t.soda, opId)).coOrganisers, []);
});

test('expired: read only; reject flow with reason and re-apply', async () => {
  const op = await OP.getOperator(t.soda, opId);
  await OP.saveOperator(t.soda, { ...op, validUntil: Date.now() - 1000 });
  assert.equal((await t.api('GET', `/operator/${opId}/rides`, null, owner.token)).status, 200);
  const w = await t.api('POST', `/operator/${opId}/broadcasts`, { title: 'Hello', body: 'Hello riders' }, owner.token);
  assert.equal(w.json.code, 'OPERATOR_EXPIRED');
  assert.equal((await t.api('GET', '/admin/operators?status=EXPIRED', null, admin.token)).json.operators[0].operatorId, opId);
  await t.api('PUT', `/admin/operators/${opId}/limits`, { validityDays: 30 }, admin.token);
  assert.equal((await t.api('GET', `/operator/${opId}`, null, owner.token)).json.operator.status, 'APPROVED');

  const club = await rider('Kiran Club');
  const ap = await t.api('POST', '/operators/apply', { ...APP, type: 'RIDING_CLUB', name: 'Kakatiya Riders', website: '' }, club.token);
  assert.equal(ap.status, 201, JSON.stringify(ap.json));
  const id2 = ap.json.application.operatorId;
  assert.equal((await t.api('POST', `/admin/operators/${id2}/reject`, {}, admin.token)).json.code, 'REASON_REQUIRED');
  const rj = await t.api('POST', `/admin/operators/${id2}/reject`, { reason: 'Please add a website' }, admin.token);
  assert.equal(rj.json.operator.status, 'REJECTED');
  assert.equal((await t.api('GET', '/operators/application', null, club.token)).json.application.reason, 'Please add a website');
  const again = await t.api('POST', '/operators/apply', { ...APP, type: 'RIDING_CLUB', name: 'Kakatiya Riders', website: 'kakatiya.example' }, club.token);
  assert.equal(again.status, 201);
  assert.equal(again.json.application.operatorId, id2);
  // Templates: admin edits the club default.
  const tpl = await t.api('PUT', '/admin/operators/templates', { templates: { RIDING_CLUB: { limits: { maxMembers: 75 } } } }, admin.token);
  assert.equal(tpl.json.templates.RIDING_CLUB.limits.maxMembers, 75);
  const appr = await t.api('POST', `/admin/operators/${id2}/approve`, {}, admin.token);
  assert.equal(appr.json.operator.limits.maxMembers, 75);
  assert.equal(appr.json.operator.features.exportReports, false);
});

test('feature switch off: applications, console and pages closed; admin review still works', async () => {
  const off = await t.api('PUT', '/admin/features/operators', { enabled: false, reason: 'test' }, admin.token);
  assert.equal(off.status, 200, JSON.stringify(off.json));
  assert.equal((await t.api('GET', '/operators/application', null, owner.token)).json.code, 'FEATURE_OFF');
  assert.equal((await t.api('GET', `/operator/${opId}`, null, owner.token)).json.code, 'FEATURE_OFF');
  assert.equal((await fetch(`${t.origin}/operators/apply`)).status, 404);
  assert.equal((await t.api('GET', '/admin/operators', null, admin.token)).status, 200);
  await t.api('PUT', '/admin/features/operators', { enabled: true, reason: 'test' }, admin.token);
  assert.equal((await fetch(`${t.origin}/operators/apply`)).status, 200);
});

test('pages: console and website pages carry strict headers', async () => {
  const con = await fetch(`${t.origin}/operator`);
  assert.equal(con.status, 200);
  assert.match(con.headers.get('content-security-policy'), /script-src 'self';/);
  assert.match(con.headers.get('x-robots-tag'), /noindex/);
  const html = await con.text();
  assert.ok(!/<script>|style="/.test(html));
  assert.equal((await fetch(`${t.origin}/operator/nope.js`)).status, 404);
  const ap = await fetch(`${t.origin}/operators/apply`);
  assert.doesNotMatch(ap.headers.get('content-security-policy'), /unsafe-inline'[^;]*script|script-src[^;]*unsafe-inline/);
  assert.equal((await fetch(`${t.origin}/clubs/join/abc`)).status, 404);
  const j = await fetch(`${t.origin}/clubs/join/ABCDEFGHJK`, { redirect: 'manual' });
  assert.equal(j.status, 302);
});

test('account erase removes the operator, its rides and club', async () => {
  const before = await OP.getOperator(t.soda, opId);
  assert.ok(before);
  await t.gw.repo.deleteUserCascade(await t.gw.repo.findUserById(owner.user.userId), {});
  assert.equal(await OP.getOperator(t.soda, opId), null);
  assert.equal((await OP.ridesOf(t.soda, opId)).length, 0);
});
