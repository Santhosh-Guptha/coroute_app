'use strict';
/**
 * 3.55 unique usernames, profiles, friends and profile pictures
 * (docs/features_355/usernames_friends_profiles.md).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'socialadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const U = require('../src/usernames');
const F = require('../src/friends');
const A = require('../src/avatars');
const { rideTotals } = require('../src/social_routes');

let t;
let admin;
before(async () => {
  t = await boot();
  admin = await t.register('Social Admin', 'socialadmin@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const PNG_1x1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
/** The 1x1 PNG with a tEXt chunk (location text) inserted after IHDR. */
function pngWithText(text) {
  const ihdrEnd = 8 + 12 + 13;
  const data = Buffer.from(`Comment\0${text}`, 'latin1');
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  chunk.write('tEXt', 4, 'ascii');
  data.copy(chunk, 8);
  return Buffer.concat([PNG_1x1.slice(0, ihdrEnd), chunk, PNG_1x1.slice(ihdrEnd)]);
}
async function raw(method, path, buf, token, type = 'image/png') {
  const res = await fetch(t.base + path, { method, headers: { 'Content-Type': type, Authorization: `Bearer ${token}` }, body: buf });
  const ct = res.headers.get('content-type') || '';
  return { status: res.status, json: ct.includes('json') ? await res.json() : null, body: ct.includes('json') ? null : Buffer.from(await res.arrayBuffer()), headers: res.headers };
}
const setFlag = (id, enabled) => t.api('PUT', `/admin/features/${id}`, { enabled, reason: 'test' }, admin.token);

// ------------------------------------------------------------------ pure rules
test('validateUsername: format, reserved words, profanity, phone / e-mail patterns', () => {
  for (const ok of ['SwiftFalcon482', 'abc', 'Rider_One', 'a'.repeat(20), 'ThrottleTiger907', 'Moto_2024']) {
    assert.equal(U.validateUsername(ok).ok, true, ok);
  }
  const bad = {
    USERNAME_FORMAT: ['ab', 'a'.repeat(21), '1rider', '_rider', 'has space', 'dash-name', 'dot.name', 'mail@x', '', null, 42, 'émile'],
    USERNAME_RESERVED: ['admin', 'Admin', 'CoRoute', 'support', 'official', 'moderator', 'Real_Admin7', 'c0route', 'Supp0rtTeam', 'staff'],
    USERNAME_NOT_ALLOWED: ['fuckrider', 'Sh1tHead', 'bitch99'],
    USERNAME_CONTACT: ['r9876543210', 'call9876543', 'mygmailbox', 'rider_yahoo'],
  };
  for (const [code, list] of Object.entries(bad)) {
    for (const u of list) {
      const v = U.validateUsername(u);
      assert.equal(v.ok, false, String(u));
      assert.equal(v.code, code, `${u} -> ${v.code}`);
    }
  }
});

test('generated usernames are valid, use the curated words and 3-4 digits', () => {
  const seen = new Set();
  for (let i = 0; i < 3000; i++) {
    const c = U.generateCandidate();
    assert.match(c, /^[A-Z][a-z]+[A-Z][a-z]+\d{3,4}$/, c);
    assert.ok(c.length >= 3 && c.length <= 20, c);
    const adj = U.ADJECTIVES.find((a) => c.startsWith(a));
    assert.ok(adj, c);
    assert.ok(U.RIDE_WORDS.includes(c.slice(adj.length).replace(/\d+$/, '')), c);
    seen.add(c);
  }
  assert.ok(seen.size > 2500, 'enough variety');
  // Every word combination with any digits passes the rider rules (auto names are never refused).
  for (const a of U.ADJECTIVES) for (const w of U.RIDE_WORDS) assert.equal(U.validateUsername(`${a}${w}482`).ok, true, `${a}${w}`);
});

test('allocation is collision-safe (unique index on the lowercase key) and idempotent per rider', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  // A rand that always produces the same candidate: the second rider must get a different name.
  const fixed = () => 0;
  const first = await U.allocateUsername(repo, 'usr_one', { rand: fixed });
  let second;
  try { second = await U.allocateUsername(repo, 'usr_two', { rand: fixed }); } catch (e) { second = e; }
  assert.ok(typeof second === 'string', 'falls back to a longer random suffix');
  assert.notEqual(second.toLowerCase(), first.toLowerCase());
  // Case-insensitive uniqueness: the same name with other capitals is taken.
  const avail = await U.usernameAvailability(repo, first.toUpperCase(), 'usr_two');
  assert.equal(avail.available, false);
  assert.equal(avail.code, 'USERNAME_TAKEN');
  assert.equal((await U.usernameAvailability(repo, first.toUpperCase(), 'usr_one')).available, true, 'my own name');

  // Many riders in parallel: all different.
  const created = [];
  for (let i = 0; i < 40; i++) created.push(await repo.createUser({ userId: `usr_p${i}`, name: `Parallel ${i}`, email: `p${i}@x.test`, createdAt: 1 }));
  const named = await Promise.all(created.map((u) => U.ensureUsername(repo, u)));
  const keys = named.map((u) => u.usernameKey);
  assert.equal(new Set(keys).size, 40);
  // Calling again (and concurrently for the same rider) never changes the name.
  const again = await Promise.all([U.ensureUsername(repo, created[0]), U.ensureUsername(repo, created[0])]);
  assert.equal(again[0].username, named[0].username);
  assert.equal(again[1].username, named[0].username);
  const map = await U.usernamesFor(repo, ['usr_p1', 'usr_p2', 'usr_missing']);
  assert.equal(map.get('usr_p1'), named[1].username);
  assert.equal(map.has('usr_missing'), false);
});

test('backfill gives every older account a username and is idempotent', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  for (let i = 0; i < 25; i++) await repo.createUser({ userId: `usr_old${i}`, name: `Old Rider ${i}`, email: `old${i}@x.test`, createdAt: i });
  const quiet = { info() {}, warn() {} };
  const one = await U.backfillUsernames(repo, { logger: quiet });
  assert.equal(one.allocated, 25);
  const users = await repo.listUsers(100);
  assert.ok(users.every((u) => U.USERNAME_RE.test(u.username) && u.usernameKey === u.username.toLowerCase() && u.publicLeaderboard === true));
  assert.equal(new Set(users.map((u) => u.usernameKey)).size, 25);
  // Generated from the word lists only (never from the real name).
  assert.ok(users.every((u) => /^[A-Z][a-z]+[A-Z][a-z]+\d{3,4}$/.test(u.username)));
  const before = users.map((u) => `${u.userId}:${u.username}`).sort();
  const two = await U.backfillUsernames(repo, { logger: quiet });
  assert.equal(two.allocated, 0);
  assert.deepEqual((await repo.listUsers(100)).map((u) => `${u.userId}:${u.username}`).sort(), before);
});

test('rideTotals: one ride per group (server trip wins), hours, longest, largest group', () => {
  const s = rideTotals([
    { groupId: 'GRP-1', source: 'device', totalDistanceKm: 90, movingMs: 3600000, riderCount: 4 },
    { groupId: 'GRP-1', source: 'server', totalDistanceKm: 100, movingMs: 2 * 3600000, riderCount: 5 },
    { source: 'device', totalDistanceKm: 20.25, startTimeEpochMs: 0, endTimeEpochMs: 1800000 },
    { groupId: 'GRP-2', source: 'server', totalDistanceKm: 1e9, movingMs: 1e12, riderCount: 3 },
  ]);
  assert.deepEqual(s, { trips: 3, totalKm: 5120.3, ridingHours: 50.5, longestTripKm: 5000, largestGroup: 5 });
});

// ------------------------------------------------------------------ HTTP
test('every account gets a username: at registration, lazily on sign-in and GET /me', async () => {
  const a = await t.register('Arjun Kumar', 'arjun@coroute.test');
  assert.match(a.user.username, U.USERNAME_RE);
  assert.ok(!/arjun|kumar/i.test(a.user.username), 'never from the real name');
  assert.equal(a.user.publicLeaderboard, true);
  // An account from before usernames (no field): sign-in allocates one.
  const repo = t.gw.repo;
  const legacy = await repo.findUserByEmail('arjun@coroute.test');
  await t.soda.replace('users', legacy.key, (({ key, username, usernameKey, ...rest }) => rest)(legacy));
  await U.forgetUsernames(repo, legacy.userId);
  const login = await t.api('POST', '/auth/login', { identifier: 'arjun@coroute.test', password: 'Password#123' });
  assert.equal(login.status, 200);
  assert.match(login.json.user.username, U.USERNAME_RE);
  const me = await t.api('GET', '/me', null, a.token);
  assert.equal(me.json.username, login.json.user.username, 'stable afterwards');
  // Admin user list shows the username (searchable by the console).
  const list = await t.api('GET', '/admin/users', null, admin.token);
  const row = list.json.users.find((u) => u.userId === a.user.userId);
  assert.equal(row.username, me.json.username);
  // Rider analytics list: shown and searchable by username; the detail shows it too.
  const found = await t.api('GET', `/admin/analytics/riders?q=${me.json.username.toLowerCase()}`, null, admin.token);
  assert.equal(found.status, 200);
  assert.deepEqual(found.json.riders.map((x) => x.username), [me.json.username]);
  const detail = await t.api('GET', `/admin/users/${a.user.userId}/details`, null, admin.token);
  assert.equal(detail.json.user.username, me.json.username);
});

test('username change: validation, availability, uniqueness, once per 30 days', async () => {
  const a = await t.register('Chooser One', 'chooser1@coroute.test');
  const b = await t.register('Chooser Two', 'chooser2@coroute.test');
  const check = (u, tok = a.token) => t.api('GET', `/users/username-available?u=${encodeURIComponent(u)}`, null, tok);
  assert.equal((await check('admin')).json.available, false);
  assert.equal((await check('admin')).json.code, 'USERNAME_RESERVED');
  assert.equal((await check('x')).json.code, 'USERNAME_FORMAT');
  assert.equal((await check(b.user.username)).json.code, 'USERNAME_TAKEN');
  assert.equal((await check(b.user.username.toLowerCase())).json.available, false, 'case-insensitive');
  assert.equal((await check('MountainGoat_7')).json.available, true);

  const change = (u, tok = a.token) => t.api('PATCH', '/me/username', { username: u }, tok);
  for (const [u, status, code] of [['admin', 422, 'USERNAME_RESERVED'], ['9876543210x', 422, 'USERNAME_FORMAT'], ['ride9876543210', 422, 'USERNAME_CONTACT'],
    ['fuckthis', 422, 'USERNAME_NOT_ALLOWED'], [b.user.username.toUpperCase(), 409, 'USERNAME_TAKEN']]) {
    const r = await change(u);
    assert.equal(r.status, status, `${u}: ${JSON.stringify(r.json)}`);
    assert.equal(r.json.code, code);
  }
  const old = a.user.username;
  const ok = await change('MountainGoat_7');
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(ok.json.username, 'MountainGoat_7');
  assert.ok(ok.json.nextUsernameChangeAt > Date.now() + 29 * 86400000);
  assert.equal((await check('mountaingoat_7', b.token)).json.available, false);
  assert.equal((await check(old, b.token)).json.available, true, 'the old name is free again');
  // Capitals only: always allowed, no new cooldown.
  const caps = await change('mountainGOAT_7');
  assert.equal(caps.status, 200);
  assert.equal(caps.json.username, 'mountainGOAT_7');
  // A real change within 30 days: refused with the date it becomes possible.
  const again = await change('ValleyGoat_8');
  assert.equal(again.status, 429);
  assert.equal(again.json.code, 'USERNAME_COOLDOWN');
  assert.ok(again.json.nextChangeAt > Date.now());
  // After 30 days it works.
  const doc = await t.gw.repo.findUserById(a.user.userId);
  await t.gw.repo.updateUser(doc.key, { usernameChangedAt: Date.now() - 31 * 86400000 });
  assert.equal((await change('ValleyGoat_8')).status, 200);
  // Privacy toggle for the website leaderboards.
  assert.equal((await t.api('PATCH', '/me/privacy', { publicLeaderboard: 'no' }, a.token)).status, 400);
  assert.equal((await t.api('PATCH', '/me/privacy', { publicLeaderboard: false }, a.token)).json.publicLeaderboard, false);
  assert.equal((await t.api('GET', '/me', null, a.token)).json.publicLeaderboard, false);
  assert.equal((await t.gw.repo.findUserById(a.user.userId)).publicLeaderboard, false);
});

const SENSITIVE = /phone|email|emergency|blood|allerg|medical|guardian|subscription|plan|payment|^lat|^lng|location|home|userId|vehicle|^role|^name$/i;
function assertNoSensitive(obj, user) {
  const json = JSON.stringify(obj);
  for (const k of Object.keys(obj.profile || {})) assert.ok(!SENSITIVE.test(k), `field ${k}`);
  for (const k of Object.keys(obj.profile?.stats || {})) assert.ok(!SENSITIVE.test(k), `stat ${k}`);
  for (const v of [user.email, user.phone, user.emergencyContact, user.emergencyContactName, user.userId, user.name].filter(Boolean)) {
    assert.ok(!json.includes(v), `leaks ${v}`);
  }
}

test('friend request lifecycle, profile privacy and notifications', async () => {
  const a = await t.register('Priya Raman', 'priya@coroute.test');
  const b = await t.register('Kiran Das', 'kiran@coroute.test');
  await t.api('PATCH', '/me', { bloodGroup: 'O+', allergies: 'Penicillin', medicalNotes: 'Asthma' }, b.token);
  const bWs = await t.connect(b.token);
  const aWs = await t.connect(a.token);

  // Non-friend view: username + picture only.
  const stranger = await t.api('GET', `/users/${b.user.username}/profile`, null, a.token);
  assert.equal(stranger.status, 200);
  assert.deepEqual(Object.keys(stranger.json.profile).sort(), ['avatarUrl', 'relation', 'username']);
  assert.equal(stranger.json.profile.relation, 'NONE');
  assertNoSensitive(stranger.json, b.user);

  const sent = await t.api('POST', '/friends/requests', { username: b.user.username.toLowerCase() }, a.token);
  assert.equal(sent.status, 202);
  assert.equal(sent.json.status, 'REQUESTED');
  // The sender's own view of the request (shown under "Sent" at once): the target's card only.
  assert.deepEqual(Object.keys(sent.json.request).sort(), ['at', 'avatarUrl', 'requestId', 'username']);
  assert.equal(sent.json.request.username, b.user.username);
  const push = await bWs.next((m) => m.type === 'FRIEND_REQUEST');
  assert.equal(push.username, a.user.username);
  assert.ok(!JSON.stringify(push).includes(a.user.userId), 'no userId in the notification');
  // Repeating the request is idempotent (no duplicate edge).
  assert.equal((await t.api('POST', '/friends/requests', { username: b.user.username }, a.token)).status, 202);

  const bList = await t.api('GET', '/friends', null, b.token);
  assert.equal(bList.json.incoming.length, 1);
  assert.equal(bList.json.incoming[0].username, a.user.username);
  assert.ok(!JSON.stringify(bList.json).includes(a.user.userId));
  const aList = await t.api('GET', '/friends', null, a.token);
  assert.equal(aList.json.outgoing.length, 1);
  assert.equal((await t.api('GET', `/users/${b.user.username}/profile`, null, a.token)).json.profile.relation, 'PENDING_OUT');

  // Only the addressee can accept.
  const rid = bList.json.incoming[0].requestId;
  assert.equal((await t.api('POST', `/friends/requests/${rid}/accept`, null, a.token)).status, 404);
  const acc = await t.api('POST', `/friends/requests/${rid}/accept`, null, b.token);
  assert.equal(acc.status, 200);
  assert.equal(acc.json.status, 'FRIENDS');
  const accepted = await aWs.next((m) => m.type === 'FRIEND_ACCEPTED');
  assert.equal(accepted.username, b.user.username);

  // Friend view: first name + totals, still nothing sensitive.
  const friend = await t.api('GET', `/users/${b.user.username}/profile`, null, a.token);
  assert.equal(friend.json.profile.relation, 'FRIENDS');
  assert.equal(friend.json.profile.displayName, 'Kiran');
  assert.deepEqual(Object.keys(friend.json.profile.stats).sort(), ['level', 'ridingHours', 'score', 'totalKm', 'trips']);
  assertNoSensitive(friend.json, { ...b.user, name: 'Kiran Das' });
  assert.ok(!JSON.stringify(friend.json).includes('Penicillin') && !JSON.stringify(friend.json).includes('O+'));
  const fl = await t.api('GET', '/friends', null, a.token);
  assert.equal(fl.json.friends.length, 1);
  assert.deepEqual(Object.keys(fl.json.friends[0]).sort(), ['avatarUrl', 'displayName', 'since', 'totalKm', 'trips', 'username']);
  assert.equal((await t.api('POST', '/friends/requests', { username: b.user.username }, a.token)).json.status, 'ALREADY_FRIENDS');

  // Remove, then a mutual request becomes a friendship at once; decline and cancel.
  assert.equal((await t.api('DELETE', `/friends/${a.user.username}`, null, b.token)).json.removed, true);
  assert.equal((await t.api('GET', '/friends', null, a.token)).json.friends.length, 0);
  await t.api('POST', '/friends/requests', { username: a.user.username }, b.token);
  const mutual = await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  assert.equal(mutual.json.status, 'FRIENDS');
  await t.api('DELETE', `/friends/${b.user.username}`, null, a.token);
  await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  const inc = (await t.api('GET', '/friends', null, b.token)).json.incoming[0];
  assert.equal((await t.api('POST', `/friends/requests/${inc.requestId}/decline`, null, b.token)).json.status, 'DECLINED');
  assert.equal((await t.api('GET', '/friends', null, a.token)).json.outgoing.length, 0);
  await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  const out = (await t.api('GET', '/friends', null, a.token)).json.outgoing[0];
  assert.equal((await t.api('DELETE', `/friends/requests/${out.requestId}`, null, a.token)).status, 200);
  assert.equal((await t.api('GET', '/friends', null, b.token)).json.incoming.length, 0);
  assert.equal((await t.api('POST', '/friends/requests', { username: a.user.username }, a.token)).json.code, 'SELF');
  aWs.close(); bWs.close();
});

test('blocking: no requests, no profile, no picture; a block is never revealed', async () => {
  const a = await t.register('Block Asker', 'blockasker@coroute.test');
  const b = await t.register('Block Target', 'blocktarget@coroute.test');
  assert.equal((await raw('POST', '/me/avatar', PNG_1x1, b.token)).status, 201);
  const bAvatar = (await t.api('GET', '/me/profile', null, b.token)).json.profile.avatarUrl;
  assert.match(bAvatar, /^\/api\/avatars\/av_[a-f0-9]{24}$/);
  assert.equal((await raw('GET', bAvatar.replace('/api', ''), null, a.token)).status, 200, 'visible before the block');

  // a asked first; b blocks a: the pending request turns into a shadow (a still sees it pending).
  await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  assert.equal((await t.api('POST', '/blocks', { username: a.user.username }, b.token)).json.blocked, true);
  assert.equal((await t.api('GET', '/friends', null, b.token)).json.incoming.length, 0, 'b never sees it');
  assert.equal((await t.api('GET', '/friends', null, a.token)).json.outgoing.length, 1, 'a cannot tell');
  assert.deepEqual((await t.api('GET', '/friends', null, b.token)).json.blocked.map((x) => x.username), [a.user.username]);

  // A request to the rider who blocked me looks exactly like an unanswered one (same shape).
  const toBlocked = await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  const c = await t.register('Block Bystander', 'blockbystander@coroute.test');
  const toNormal = await t.api('POST', '/friends/requests', { username: c.user.username }, a.token);
  assert.equal(toBlocked.status, 202);
  assert.equal(toBlocked.status, toNormal.status);
  assert.deepEqual(Object.keys(toBlocked.json).sort(), Object.keys(toNormal.json).sort(), 'a block is not revealed');
  assert.deepEqual(Object.keys(toBlocked.json.request).sort(), Object.keys(toNormal.json.request).sort());
  // An unknown username or code says so (a typo is never reported as sent).
  const toUnknown = await t.api('POST', '/friends/requests', { username: 'NoSuchRider_42' }, a.token);
  assert.deepEqual([toUnknown.status, toUnknown.json.code], [404, 'NOT_FOUND']);
  const badCode = await t.api('POST', '/friends/requests', { inviteCode: 'ZZZZZZZZ' }, a.token);
  assert.deepEqual([badCode.status, badCode.json.code], [404, 'NOT_FOUND']);

  const pBlocked = await t.api('GET', `/users/${b.user.username}/profile`, null, a.token);
  const pUnknown = await t.api('GET', '/users/NoSuchRider_42/profile', null, a.token);
  assert.deepEqual([pBlocked.status, pBlocked.json], [pUnknown.status, pUnknown.json]);
  assert.equal((await raw('GET', bAvatar.replace('/api', ''), null, a.token)).status, 404, 'no picture for a blocked rider');
  // b sees a as BLOCKED and cannot send a request without unblocking.
  assert.equal((await t.api('GET', `/users/${a.user.username}/profile`, null, b.token)).json.profile.relation, 'BLOCKED');
  assert.equal((await t.api('POST', '/friends/requests', { username: a.user.username }, b.token)).json.code, 'YOU_BLOCKED');
  // Unblock: the shadow request is dropped, things work again.
  assert.equal((await t.api('DELETE', `/blocks/${a.user.username}`, null, b.token)).json.unblocked, true);
  assert.deepEqual((await t.api('GET', '/friends', null, a.token)).json.outgoing.map((x) => x.username), [c.user.username]);
  assert.equal((await t.api('GET', `/users/${b.user.username}/profile`, null, a.token)).status, 200);
  // Blocking an unknown username answers like a real one.
  assert.deepEqual((await t.api('POST', '/blocks', { username: 'NoSuchRider_42' }, a.token)).json, { ok: true, blocked: true });
});

test('friend requests are limited to 20 a day', async () => {
  const a = await t.register('Busy Sender', 'busysender@coroute.test');
  let last;
  for (let i = 0; i < 21; i++) last = await t.api('POST', '/friends/requests', { username: `Nobody_${i}x` }, a.token);
  assert.equal(last.status, 429);
});

test('invite code: register with it -> request to the inviter; join page and app link', async () => {
  const inviter = await t.register('Invite Host', 'invitehost@coroute.test');
  const inv = await t.api('GET', '/friends/invite', null, inviter.token);
  assert.match(inv.json.inviteCode, /^[A-HJ-NP-Z2-9]{8}$/);
  assert.ok(inv.json.inviteLink.endsWith(`/join/friend/${inv.json.inviteCode}`));
  assert.ok(inv.json.shareText.includes(inviter.user.username) && !inv.json.shareText.includes('Invite Host'));
  assert.equal((await t.api('GET', '/friends/invite', null, inviter.token)).json.inviteCode, inv.json.inviteCode, 'stable');
  const ws = await t.connect(inviter.token);
  const newbie = await t.register('New Comer', 'newcomer@coroute.test', { inviteCode: inv.json.inviteCode.toLowerCase() });
  const push = await ws.next((m) => m.type === 'FRIEND_REQUEST');
  assert.equal(push.username, newbie.user.username);
  assert.equal(push.via, 'invite');
  const list = await t.api('GET', '/friends', null, inviter.token);
  assert.deepEqual(list.json.incoming.map((x) => x.username), [newbie.user.username]);
  // Adding by code from inside the app works too (another rider).
  const other = await t.register('Code Adder', 'codeadder@coroute.test');
  assert.equal((await t.api('POST', '/friends/requests', { inviteCode: inv.json.inviteCode }, other.token)).status, 202);
  assert.equal((await t.api('GET', '/friends', null, inviter.token)).json.incoming.length, 2);
  // The public page never names the inviter.
  const page = await fetch(`${t.origin}/join/friend/${inv.json.inviteCode}`);
  const html = await page.text();
  assert.equal(page.status, 200);
  assert.ok(html.includes(`coroute://join/friend/${inv.json.inviteCode}`));
  assert.ok(!html.includes(inviter.user.username) && !html.includes('Invite Host'));
  // 3.55: rendered with the website design (shared header / footer, site.css), placeholders filled.
  assert.ok(html.includes('/assets/site.css') && html.includes('class="site-main"') && html.includes('data-page="join-friend"'));
  assert.ok(!html.includes('__CODE__') && !html.includes('__ORIGIN__') && !html.includes('<!--#include'));
  assert.equal((await fetch(`${t.origin}/join/friend/bad!`, { redirect: 'manual' })).status, 302);
  ws.close();
});

test('profile pictures: type by magic bytes, size, metadata removed, admin moderation, switch', async () => {
  const a = await t.register('Photo Rider', 'photorider@coroute.test');
  const notImage = await raw('POST', '/me/avatar', Buffer.from('GIF89a this is not allowed at all'), a.token, 'image/png');
  assert.equal(notImage.status, 415);
  assert.equal(notImage.json.code, 'UNSUPPORTED_PHOTO');
  assert.equal((await raw('POST', '/me/avatar', Buffer.alloc(2 * 1024 * 1024 + 10, 1), a.token)).status, 413);
  assert.equal((await t.api('POST', '/me/avatar', { data: 'x' }, a.token)).status, 415);
  assert.throws(() => A.prepareAvatar(Buffer.alloc(0)), (e) => e.status === 400);

  const up = await raw('POST', '/me/avatar', pngWithText('Lat 12.97 Lng 77.59 home'), a.token, 'application/octet-stream');
  assert.equal(up.status, 201, JSON.stringify(up.json));
  const got = await raw('GET', up.json.avatarUrl.replace('/api', ''), null, a.token);
  assert.equal(got.status, 200);
  assert.equal(got.headers.get('content-type'), 'image/png');
  assert.ok(!got.body.toString('latin1').includes('Lat 12.97'), 'text metadata removed');
  assert.equal(got.body.slice(0, 8).toString('hex'), PNG_1x1.slice(0, 8).toString('hex'));
  // Shown in /me and the admin list; a new upload replaces the old one (old URL gone).
  assert.equal((await t.api('GET', '/me', null, a.token)).json.avatarUrl, up.json.avatarUrl);
  const up2 = await raw('POST', '/me/avatar', PNG_1x1, a.token);
  assert.notEqual(up2.json.avatarUrl, up.json.avatarUrl);
  assert.equal((await raw('GET', up.json.avatarUrl.replace('/api', ''), null, a.token)).status, 404);
  assert.equal((await t.soda.query(A.COLL, { userId: a.user.userId }, { limit: 10 })).length, 1);
  assert.equal((await raw('GET', '/avatars/av_nothere', null, a.token)).status, 404);

  // Admin removes it (moderation).
  const del = await t.api('DELETE', `/admin/users/${a.user.userId}/avatar`, null, admin.token);
  assert.equal(del.json.removed, true);
  assert.equal((await t.api('GET', '/me', null, a.token)).json.avatarUrl, null);
  assert.equal((await t.api('DELETE', `/admin/users/${a.user.userId}/avatar`, null, a.token)).status, 403, 'admins only');

  // Switch off: no uploads, no pictures served.
  const up3 = await raw('POST', '/me/avatar', PNG_1x1, a.token);
  assert.equal((await setFlag('profilePhotos', false)).status, 200);
  assert.equal((await raw('POST', '/me/avatar', PNG_1x1, a.token)).status, 403);
  assert.equal((await raw('GET', up3.json.avatarUrl.replace('/api', ''), null, a.token)).status, 403);
  assert.equal((await t.api('GET', '/me/profile', null, a.token)).json.profile.avatarUrl, null);
  await setFlag('profilePhotos', true);
});

test('friends switch off: friend routes answer FEATURE_OFF; blocks still work', async () => {
  const a = await t.register('Switch Rider', 'switchrider@coroute.test');
  assert.equal((await setFlag('friends', false)).status, 200);
  const r = await t.api('GET', '/friends', null, a.token);
  assert.equal(r.status, 403);
  assert.equal(r.json.code, 'FEATURE_OFF');
  assert.equal((await t.api('POST', '/friends/requests', { username: 'Someone_1' }, a.token)).status, 403);
  assert.equal((await t.api('GET', '/blocks', null, a.token)).status, 200);
  await setFlag('friends', true);
  assert.equal((await t.api('GET', '/friends', null, a.token)).status, 200);
});

test('GET /me/stats from stored trips; ride group usernames; account erase removes social data', async () => {
  const a = await t.register('Stats Rider', 'statsrider@coroute.test');
  const b = await t.register('Stats Friend', 'statsfriend@coroute.test');
  const now = Date.now();
  for (const [i, km] of [[1, 120.5], [2, 30]]) {
    const r = await t.api('POST', '/trips', { tripId: `TRIP-stat-${i}`, totalDistanceKm: km, movingMs: 3600000 * i, riderCount: i + 2, startTimeEpochMs: now - 7200000, endTimeEpochMs: now }, a.token);
    assert.equal(r.status, 201, JSON.stringify(r.json));
  }
  const s = await t.api('GET', '/me/stats?fresh=1', null, a.token);
  assert.equal(s.status, 200);
  assert.deepEqual({ ...s.json.stats, memberSince: 0 }, { trips: 2, totalKm: 150.5, ridingHours: 3, longestTripKm: 120.5, largestGroup: 4, memberSince: 0 });
  assert.ok(s.json.stats.memberSince > 0);

  // Ride group: members see each other's username and picture by userId; others do not.
  const c = await t.api('POST', '/convoys', { name: 'Social Ride' }, a.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  const gid = c.json.groupId || c.json.convoy?.groupId;
  const names = await t.api('GET', `/convoys/${gid}/usernames`, null, a.token);
  assert.equal(names.status, 200);
  assert.equal(names.json.riders[a.user.userId].username, a.user.username);
  assert.equal((await t.api('GET', `/convoys/${gid}/usernames`, null, b.token)).status, 403);

  // Erase: username freed, friend edges / blocks / invite codes / pictures gone.
  await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  await t.api('POST', '/blocks', { username: b.user.username }, a.token);
  await F.inviteCodeOf(t.soda, a.user.userId);
  await raw('POST', '/me/avatar', PNG_1x1, a.token);
  await t.api('POST', `/convoys/${gid}/leave`, null, a.token);
  const del = await t.api('DELETE', '/me', { currentPassword: 'Password#123' }, a.token);
  assert.equal(del.status, 200, JSON.stringify(del.json));
  const left = async (coll, filter) => (await t.soda.query(coll, filter, { limit: 10 })).length;
  assert.equal(await left(U.COLL, { userId: a.user.userId }), 0);
  assert.equal(await left(F.COLLECTIONS.edges, { a: a.user.userId }) + await left(F.COLLECTIONS.edges, { b: a.user.userId }), 0);
  assert.equal(await left(F.COLLECTIONS.blocks, { blocker: a.user.userId }), 0);
  assert.equal(await left(F.COLLECTIONS.invites, { userId: a.user.userId }), 0);
  assert.equal(await left(A.COLL, { userId: a.user.userId }), 0);
  assert.equal((await t.api('GET', `/users/username-available?u=${a.user.username}`, null, b.token)).json.available, true);
  assert.equal((await t.api('GET', '/friends', null, b.token)).json.incoming.length, 0);
});

test('admin: social summary and backfill endpoint', async () => {
  const a = await t.register('Admin Seen', 'adminseen@coroute.test');
  const s = await t.api('GET', `/admin/users/${a.user.userId}/social`, null, admin.token);
  assert.equal(s.json.username, a.user.username);
  assert.equal((await t.api('GET', `/admin/users/${a.user.userId}/social`, null, a.token)).status, 403);
  const bf = await t.api('POST', '/admin/usernames/backfill', null, admin.token);
  assert.equal(bf.status, 200);
  assert.equal(bf.json.allocated, 0);
});
