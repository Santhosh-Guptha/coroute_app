'use strict';
/**
 * v3.60 communities (public / private, join requests, picture, hosted rides with interest answers), chat (friends,
 * communities up to the plan limit, text only, 90 days, no push while riding) and admin features / limits by plan.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'commadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const F = require('../src/friends');
const CH = require('../src/chat');
const PL = require('../src/plans');
const { boot } = require('./_helpers');

let t; let admin; let seq = 0;
before(async () => {
  t = await boot();
  admin = await t.register('Comm Admin', 'commadmin@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

async function rider(name) {
  seq++;
  return t.register(name, `comm${seq}_${Date.now()}@coroute.test`);
}
async function befriend(x, y) {
  const out = await F.sendRequest(t.soda, x.user.userId, y.user.userId);
  if (out.status === 'REQUESTED') await F.respond(t.soda, y.user.userId, out.edge.requestId, true);
}
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('public community: anyone sees members and rides and joins at once; private: request, approve / decline', async () => {
  const owner = await rider('Owner Public');
  const walker = await rider('Walk In');
  const pub = await t.api('POST', '/crews', { name: 'Open Road Club', description: 'Anyone welcome', visibility: 'public' }, owner.token);
  assert.equal(pub.status, 201, JSON.stringify(pub.json));
  assert.equal(pub.json.crew.visibility, 'public');
  const priv = await t.api('POST', '/crews', { name: 'Quiet Loops', description: 'Invite and approve' }, owner.token);
  assert.equal(priv.json.crew.visibility, 'private', 'private by default');

  const found = await t.api('GET', '/communities/discover?q=road', null, walker.token);
  assert.equal(found.status, 200);
  assert.ok(found.json.communities.some((c) => c.crewId === pub.json.crew.crewId && c.status === 'NONE'));

  const view = await t.api('GET', `/communities/${pub.json.crew.crewId}`, null, walker.token);
  assert.equal(view.status, 200);
  assert.equal(view.json.members.length, 1, 'public: members visible to non-members');
  const pview = await t.api('GET', `/communities/${priv.json.crew.crewId}`, null, walker.token);
  assert.equal(pview.json.members, undefined, 'private: summary only');

  const j = await t.api('POST', `/communities/${pub.json.crew.crewId}/join`, null, walker.token);
  assert.deepEqual([j.status, j.json.status], [200, 'MEMBER']);
  assert.equal((await t.api('GET', `/crews/${pub.json.crew.crewId}`, null, walker.token)).status, 200);

  const rq = await t.api('POST', `/communities/${priv.json.crew.crewId}/join`, null, walker.token);
  assert.deepEqual([rq.status, rq.json.status], [202, 'REQUESTED']);
  const list = await t.api('GET', `/crews/${priv.json.crew.crewId}/requests`, null, owner.token);
  assert.equal(list.json.requests.length, 1);
  assert.equal(list.json.requests[0].username, walker.user.username);
  assert.equal((await t.api('GET', `/crews/${priv.json.crew.crewId}/requests`, null, walker.token)).status, 404, 'non-member');
  const ap = await t.api('POST', `/crews/${priv.json.crew.crewId}/requests/${walker.user.username}/approve`, null, owner.token);
  assert.deepEqual([ap.status, ap.json.status], [200, 'APPROVED']);
  assert.equal((await t.api('GET', `/crews/${priv.json.crew.crewId}`, null, walker.token)).status, 200, 'member now');

  // Admin removes a member; a second request is declined.
  assert.equal((await t.api('DELETE', `/crews/${priv.json.crew.crewId}/members/${walker.user.username}`, null, owner.token)).status, 200);
  await t.api('POST', `/communities/${priv.json.crew.crewId}/join`, null, walker.token);
  const de = await t.api('POST', `/crews/${priv.json.crew.crewId}/requests/${walker.user.username}/decline`, null, owner.token);
  assert.equal(de.json.status, 'DECLINED');
  assert.equal((await t.api('GET', `/crews/${priv.json.crew.crewId}`, null, walker.token)).status, 404);

  // Switch to public.
  const sw = await t.api('PATCH', `/crews/${priv.json.crew.crewId}`, { visibility: 'public' }, owner.token);
  assert.equal(sw.json.crew.visibility, 'public');
  assert.equal((await t.api('PATCH', `/crews/${priv.json.crew.crewId}`, { visibility: 'secret' }, owner.token)).status, 400);
});

test('community picture: managers upload and remove; shown on the community', async () => {
  const owner = await rider('Owner Photo');
  const crew = (await t.api('POST', '/crews', { name: 'Photo Riders', visibility: 'public' }, owner.token)).json.crew;
  const res = await fetch(`${t.base}/crews/${crew.crewId}/photo`, { method: 'POST', headers: { Authorization: `Bearer ${owner.token}`, 'Content-Type': 'image/png' }, body: PNG });
  const up = { status: res.status, json: await res.json() };
  assert.equal(up.status, 201, JSON.stringify(up.json));
  assert.match(up.json.photoUrl, /\/api\/avatars\/av_/);
  const v = await t.api('GET', `/communities/${crew.crewId}`, null, owner.token);
  assert.equal(v.json.community.photoUrl, up.json.photoUrl);
  const img = await fetch(`${t.base}${up.json.photoUrl.replace(/^\/api/, '')}`, { headers: { Authorization: `Bearer ${owner.token}` } });
  assert.equal(img.status, 200);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/photo`, null, owner.token)).json.photoUrl, null);
});

test('hosted rides: managers plan, members answer interested / not, host edits and cancels', async () => {
  const owner = await rider('Ride Host');
  const mate = await rider('Ride Mate');
  const crew = (await t.api('POST', '/crews', { name: 'Weekend Hosts', visibility: 'public' }, owner.token)).json.crew;
  await t.api('POST', `/communities/${crew.crewId}/join`, null, mate.token);
  const startAt = Date.now() + 2 * 86400000;
  const bad = await t.api('POST', `/crews/${crew.crewId}/rides`, { title: 'x', meetName: 'Hebbal', startAt: Date.now() }, owner.token);
  assert.equal(bad.json.code, 'RIDE_TIME');
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/rides`, { title: 'Nandi sunrise', meetName: 'Hebbal flyover', startAt }, mate.token)).status, 403, 'members cannot host');
  const mk = await t.api('POST', `/crews/${crew.crewId}/rides`, { title: 'Nandi sunrise', meetName: 'Hebbal flyover', destName: 'Nandi Hills', startAt, notes: 'Full tank' }, owner.token);
  assert.equal(mk.status, 201, JSON.stringify(mk.json));
  assert.equal(mk.json.ride.interestedCount, 1, 'the host is interested');
  const rid = mk.json.ride.rideId;
  const ans = await t.api('POST', `/crews/${crew.crewId}/rides/${rid}/answer`, { answer: 'INTERESTED' }, mate.token);
  assert.deepEqual([ans.json.myAnswer, ans.json.interestedCount], ['INTERESTED', 2]);
  const no = await t.api('POST', `/crews/${crew.crewId}/rides/${rid}/answer`, { answer: 'NOT_INTERESTED' }, mate.token);
  assert.equal(no.json.interestedCount, 1);
  const list = await t.api('GET', `/crews/${crew.crewId}/rides`, null, mate.token);
  assert.equal(list.json.rides[0].myAnswer, 'NOT_INTERESTED');
  assert.equal(list.json.rides[0].notInterestedCount, 1);
  const ed = await t.api('PATCH', `/crews/${crew.crewId}/rides/${rid}`, { title: 'Nandi sunrise loop' }, owner.token);
  assert.equal(ed.json.ride.title, 'Nandi sunrise loop');
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/rides/${rid}`, null, owner.token)).json.status, 'CANCELLED');
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/rides/${rid}/answer`, { answer: 'INTERESTED' }, mate.token)).json.code, 'RIDE_CANCELLED');
  // Flag off hides rides.
  assert.equal((await t.api('PUT', '/admin/features/communityRides', { enabled: false, reason: 't' }, admin.token)).status, 200);
  assert.equal((await t.api('GET', `/crews/${crew.crewId}/rides`, null, mate.token)).status, 403);
  await t.api('PUT', '/admin/features/communityRides', { enabled: true }, admin.token);
});

test('friend chat: friends only, text only, unread counts, read marks, delete own message', async () => {
  const a = await rider('Chat Anu');
  const b = await rider('Chat Bala');
  const stranger = await rider('Chat Stranger');
  assert.equal((await t.api('POST', '/chats/dm', { username: b.user.username }, a.token)).status, 404, 'not friends yet');
  await befriend(a, b);
  const dm = await t.api('POST', '/chats/dm', { username: b.user.username }, a.token);
  assert.equal(dm.status, 200);
  const id = dm.json.chat.chatId;
  const wsB = await t.connect(b.token);
  await sleep(50);
  assert.equal((await t.api('POST', `/chats/${id}/messages`, { text: 'hi', image: 'x' }, a.token)).status, 415, 'text only');
  assert.equal((await t.api('POST', `/chats/${id}/messages`, { text: '   ' }, a.token)).json.code, 'EMPTY');
  const sent = await t.api('POST', `/chats/${id}/messages`, { text: 'Ride on Sunday?', clientId: 'cli_000001' }, a.token);
  assert.equal(sent.status, 201, JSON.stringify(sent.json));
  assert.ok(sent.json.message.expiresAt - sent.json.message.at === 90 * 86400000, 'kept 90 days');
  const again = await t.api('POST', `/chats/${id}/messages`, { text: 'Ride on Sunday?', clientId: 'cli_000001' }, a.token);
  assert.equal(again.json.duplicate, true, 'resend with the same clientId is not doubled');
  const live = await wsB.next((m) => m.type === 'CHAT_MESSAGE');
  assert.equal(live.message.text, 'Ride on Sunday?');
  wsB.close();
  assert.equal((await t.api('GET', `/chats/${id}/messages`, null, stranger.token)).status, 404);
  const ub = await t.api('GET', '/chats/unread', null, b.token);
  assert.equal(ub.json.messages, 1);
  const lb = await t.api('GET', '/chats', null, b.token);
  assert.equal(lb.json.chats.find((c) => c.chatId === id).unread, 1);
  await t.api('POST', `/chats/${id}/read`, null, b.token);
  assert.equal((await t.api('GET', '/chats/unread', null, b.token)).json.messages, 0);
  const msgs = await t.api('GET', `/chats/${id}/messages`, null, b.token);
  assert.equal(msgs.json.messages.length, 1);
  assert.equal((await t.api('DELETE', `/chats/${id}/messages/${sent.json.message.messageId}`, null, b.token)).status, 403, 'not mine');
  assert.equal((await t.api('DELETE', `/chats/${id}/messages/${sent.json.message.messageId}`, null, a.token)).status, 200);
  // Unfriend: chat closed for new messages.
  assert.equal((await t.api('DELETE', `/friends/${b.user.username}`, null, a.token)).status, 200);
  const closed = await t.api('POST', `/chats/${id}/messages`, { text: 'still there?' }, a.token);
  assert.equal(closed.json.code, 'CHAT_NOT_FRIENDS');
});

test('chat: 90-day sweep, no push while the receiver is riding, account deletion removes my chats', async () => {
  const a = await rider('Sweep A');
  const b = await rider('Sweep B');
  await befriend(a, b);
  const id = (await t.api('POST', '/chats/dm', { username: b.user.username }, a.token)).json.chat.chatId;
  await t.api('POST', `/chats/${id}/messages`, { text: 'old one' }, a.token);
  const rows = await t.soda.query(CH.COLLECTIONS.messages, { chatId: id }, { limit: 10 });
  await t.soda.replace(CH.COLLECTIONS.messages, rows[0].key, { ...rows[0].value, at: Date.now() - 91 * 86400000, expiresAt: Date.now() - 86400000 });
  assert.equal((await t.api('GET', `/chats/${id}/messages`, null, b.token)).json.messages.length, 0, 'expired is never shown');
  assert.equal(await CH.sweepExpired(t.soda), 1);

  // Riding: no push (socket only).
  const pushed = [];
  const orig = t.gw.push && t.gw.push.onSocketEvent;
  if (t.gw.push) t.gw.push.onSocketEvent = async (uid, p) => { pushed.push([uid, p.type]); return null; };
  await t.gw.repo.setActiveTrip(b.user.userId, { groupId: 'g_ride_test', role: 'PARTICIPANT', status: 'STARTED' });
  await t.api('POST', `/chats/${id}/messages`, { text: 'are you riding?' }, a.token);
  await sleep(100);
  assert.equal(pushed.filter(([u]) => u === b.user.userId).length, 0, 'no push during a ride');
  await t.gw.repo.clearActiveTrip?.(b.user.userId).catch?.(() => {});
  await t.soda.removeWhere('active_trips', { userId: b.user.userId }).catch(() => {});
  await t.api('POST', `/chats/${id}/messages`, { text: 'back home?' }, a.token);
  await sleep(100);
  if (t.gw.push) assert.equal(pushed.filter(([u, ty]) => u === b.user.userId && ty === 'CHAT_MESSAGE').length, 1, 'pushed when not riding');
  if (orig) t.gw.push.onSocketEvent = orig;

  await t.gw.repo.deleteUserCascade(await t.gw.repo.findUserById(a.user.userId));
  assert.equal((await t.soda.query(CH.COLLECTIONS.messages, { senderId: a.user.userId }, { limit: 10 })).length, 0);
  assert.equal((await CH.dmsOf(t.soda, b.user.userId)).length, 0);
});

test('community chat: members only; off above the plan limit; plan matrix gates features and limits', async () => {
  const owner = await rider('Chat Owner');
  const m1 = await rider('Chat Member');
  const crew = (await t.api('POST', '/crews', { name: 'Talky Riders', visibility: 'public' }, owner.token)).json.crew;
  await t.api('POST', `/communities/${crew.crewId}/join`, null, m1.token);
  const list = await t.api('GET', '/chats', null, m1.token);
  const cc = list.json.chats.find((c) => c.kind === 'crew' && c.crewId === crew.crewId);
  assert.ok(cc, 'community chat listed');
  const s = await t.api('POST', `/chats/${cc.chatId}/messages`, { text: 'Hello all' }, m1.token);
  assert.equal(s.status, 201);
  const outsider = await rider('Chat Outsider');
  assert.equal((await t.api('GET', `/chats/${cc.chatId}/messages`, null, outsider.token)).status, 404);

  // Admin: plan matrix (tests run with payments off = Large Group plan).
  const cfg = await t.api('GET', '/admin/plan-features', null, admin.token);
  assert.equal(cfg.status, 200);
  assert.ok(cfg.json.features.every((f) => !['sos', 'crashDetection', 'medicalId'].includes(f.id)), 'safety never behind a plan');
  assert.equal((await t.api('GET', '/admin/plan-features', null, m1.token)).status, 403);
  assert.equal((await t.api('PUT', '/admin/plan-features', { plans: { group_large: { limits: { chatMembersMax: 1 } } } }, admin.token)).status, 400, 'below min');
  const put = await t.api('PUT', '/admin/plan-features', { plans: { group_large: { features: { communityChat: true, createCommunity: false }, limits: { chatMembersMax: 2 } } } }, admin.token);
  assert.equal(put.status, 200, JSON.stringify(put.json));
  const me = await t.api('GET', '/me/plan-features', null, m1.token);
  assert.equal(me.json.planId, 'group_large');
  assert.equal(me.json.features.createCommunity, false);
  assert.equal((await t.api('POST', '/crews', { name: 'Blocked by plan' }, m1.token)).json.code, 'PLAN_FEATURE');
  // A third member: community above the chat limit (2) -> chat closed.
  const m2 = await rider('Chat Third');
  await t.api('POST', `/communities/${crew.crewId}/join`, null, m2.token);
  const closed = await t.api('POST', `/chats/${cc.chatId}/messages`, { text: 'still here' }, m1.token);
  assert.equal(closed.json.code, 'CHAT_TOO_BIG');
  // Back to defaults.
  await t.api('PUT', '/admin/plan-features', { plans: {} }, admin.token);
  assert.equal(PL.cleanConfig(null).plans.community.limits.chatMembersMax, 50);
});

test('account deletion clears community requests and ride answers', async () => {
  const owner = await rider('Del Owner');
  const x = await rider('Del Rider');
  const crew = (await t.api('POST', '/crews', { name: 'Gone Soon' }, owner.token)).json.crew;
  await t.api('POST', `/communities/${crew.crewId}/join`, null, x.token);
  await t.gw.repo.deleteUserCascade(await t.gw.repo.findUserById(x.user.userId));
  assert.equal((await t.soda.query('crew_requests', { userId: x.user.userId }, { limit: 5 })).length, 0);
});

test('friend profile: rides we were on together (friends only)', async () => {
  const a = await rider('Together A');
  const b = await rider('Together B');
  const trip = (u, g, name) => t.gw.repo.saveTrip({ tripId: `TRIP-${g}-${u.user.userId}`, source: 'server', groupId: g, userId: u.user.userId, tripName: name, startLocationName: 'Hebbal', destinationName: 'Nandi Hills', endTimeEpochMs: Date.now(), totalDistanceKm: 61.2, riderCount: 4 });
  await trip(a, 'GRP-T1', 'Sunrise'); await trip(b, 'GRP-T1', 'Sunrise');
  await trip(a, 'GRP-T2', 'Solo a');
  assert.equal((await t.api('GET', `/users/${b.user.username}/rides-together`, null, a.token)).status, 403, 'not friends');
  await befriend(a, b);
  const r = await t.api('GET', `/users/${b.user.username}/rides-together`, null, a.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.count, 1);
  assert.deepEqual([r.json.rides[0].name, r.json.rides[0].to, r.json.rides[0].myKm], ['Sunrise', 'Nandi Hills', 61.2]);
  assert.equal(JSON.stringify(r.json).includes(b.user.userId), false, 'no user ids');
});

test('plans default (owner, 15 Nov): plan features off on Community (free), on for the group plans; safety never listed', () => {
  const d = PL.cleanConfig(null).plans;
  for (const f of PL.FEATURES) {
    assert.equal(d.community.features[f.id], false, f.id);
    assert.equal(d.group_small.features[f.id], true, f.id);
    assert.equal(d.group_large.features[f.id], true, f.id);
  }
  assert.equal(PL.planIdFromPlan({ category: 'community', seats: 1 }), 'community');
});
