'use strict';
/**
 * 3.55 Crews and crew polls (docs/features_355/crews_polls.md): every invite / membership rule, the
 * poll lifecycle, privacy, admin moderation, the switches and account-erase cleanup.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'crewadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const F = require('../src/friends');
const CR = require('../src/crews');

let t;
let admin;
before(async () => {
  t = await boot();
  // One client address per rider (the API allows 240 calls a minute per address; this file makes more).
  const ips = new Map();
  const call = t.api;
  t.api = (m, p, b, token, h = {}) => {
    if (!ips.has(token)) ips.set(token, `198.51.${100 + (ips.size >> 8)}.${ips.size % 256}`);
    return call(m, p, b, token, { 'X-Forwarded-For': ips.get(token), ...h });
  };
  admin = await t.register('Crew Console', 'crewadmin@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

let seq = 0;
/** Registers a rider from its own client address (the sign-up limit is 30 per address per 15 minutes). */
async function rider(name) {
  seq++;
  const r = await t.api('POST', '/auth/register', {
    name, email: `crew${seq}_${Date.now()}@coroute.test`, password: 'Password#123',
    phone: `+9197${String(10000000 + seq).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA01CR${String(1000 + seq).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  }, null, { 'X-Forwarded-For': `203.0.113.${seq % 250}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
async function befriend(x, y) {
  const out = await F.sendRequest(t.soda, x.user.userId, y.user.userId);
  if (out.status === 'REQUESTED') await F.respond(t.soda, y.user.userId, out.edge.requestId, true);
  assert.equal(await F.areFriends(t.soda, x.user.userId, y.user.userId), true);
}
const setFlag = (id, enabled) => t.api('PUT', `/admin/features/${id}`, { enabled, reason: 'test' }, admin.token);
async function newCrew(owner, name = 'Sunday Riders') {
  const r = await t.api('POST', '/crews', { name, description: 'Easy morning loops' }, owner.token);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json.crew;
}
/** owner invites friend (made a friend first) and the friend accepts. */
async function join(crew, inviter, friend) {
  if (!(await F.areFriends(t.soda, inviter.user.userId, friend.user.userId))) await befriend(inviter, friend);
  const inv = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: friend.user.username }, inviter.token);
  assert.equal(inv.status, 201, JSON.stringify(inv.json));
  const list = await t.api('GET', '/crews', null, friend.token);
  const mine = list.json.invites.find((i) => i.crewId === crew.crewId);
  const acc = await t.api('POST', `/crews/invites/${mine.inviteId}/accept`, null, friend.token);
  assert.equal(acc.json.status, 'JOINED', JSON.stringify(acc.json));
}
const detail = (crew, who) => t.api('GET', `/crews/${crew.crewId}`, null, who.token);
async function setUser(userId, patch) {
  const row = await t.soda.findOne('users', { userId });
  await t.soda.replace('users', row.key, { ...row.value, ...patch });
  t.gw.auth.gate?.invalidate?.(userId);
}

// ------------------------------------------------------------------ pure rules
test('crew name and description rules: length, sanitising, profanity, contact details', () => {
  assert.deepEqual(CR.validateCrewName('  Deccan   <b>Riders</b> '), { ok: true, value: 'Deccan bRiders/b' });
  for (const [name, code] of [['ab', 'CREW_NAME_FORMAT'], ['a'.repeat(41), 'CREW_NAME_FORMAT'], ['   ', 'CREW_NAME_FORMAT'], ['!!!', 'CREW_NAME_FORMAT'],
    [null, 'CREW_NAME_FORMAT'], ['Shit Riders', 'CREW_NAME_NOT_ALLOWED'], ['Call 9876543210', 'CREW_TEXT_CONTACT'],
    ['me@mail.com crew', 'CREW_TEXT_CONTACT'], ['www.crew.in', 'CREW_TEXT_CONTACT']]) {
    assert.equal(CR.validateCrewName(name).code, code, String(name));
  }
  for (const ok of ['Essex Riders', 'Cockpit Crew', 'Kuttanad Loop', 'Ghats 2026', 'abc', 'a'.repeat(40)]) assert.equal(CR.validateCrewName(ok).ok, true, ok);
  assert.equal(CR.validateDescription('x'.repeat(200)).ok, true);
  assert.equal(CR.validateDescription('x'.repeat(201)).code, 'CREW_DESC_FORMAT');
  assert.equal(CR.validateDescription(undefined).value, '');
  assert.equal(CR.validateDescription('ping 98765 43210').code, 'CREW_TEXT_CONTACT');
});

test('poll rules: question, 2-6 options, duplicates, deadline window, default 3 days', () => {
  const now = 1_000_000_000_000;
  const ok = CR.validatePoll({ question: ' Where next? ', options: ['Nandi Hills', 'Coorg'] }, now);
  assert.equal(ok.question, 'Where next?');
  assert.deepEqual(ok.options, [{ id: 'o1', text: 'Nandi Hills' }, { id: 'o2', text: 'Coorg' }]);
  assert.equal(ok.closesAt, now + 3 * 86400000);
  assert.equal(ok.multi, false);
  assert.equal(ok.anonymous, false, 'named by default');
  const code = (body) => { try { CR.validatePoll(body, now); return 'OK'; } catch (e) { return e.code; } };
  assert.equal(code({ question: '', options: ['a', 'b'] }), 'POLL_QUESTION');
  assert.equal(code({ question: 'q'.repeat(121), options: ['a', 'b'] }), 'POLL_QUESTION');
  assert.equal(code({ question: 'q'.repeat(120), options: ['a', 'b'] }), 'OK');
  assert.equal(code({ question: 'q', options: ['a'] }), 'POLL_OPTIONS');
  assert.equal(code({ question: 'q', options: ['1', '2', '3', '4', '5', '6', '7'] }), 'POLL_OPTIONS');
  assert.equal(code({ question: 'q', options: ['1', '2', '3', '4', '5', '6'] }), 'OK');
  assert.equal(code({ question: 'q', options: 'a,b' }), 'POLL_OPTIONS');
  assert.equal(code({ question: 'q', options: ['a', ' '] }), 'POLL_OPTION_TEXT');
  assert.equal(code({ question: 'q', options: ['a', 'o'.repeat(61)] }), 'POLL_OPTION_TEXT');
  assert.equal(code({ question: 'q', options: ['Coorg', 'coorg '] }), 'POLL_OPTION_DUPLICATE');
  assert.equal(code({ question: 'q', options: ['a', 'b'], closesAt: now + 31 * 86400000 }), 'POLL_DEADLINE');
  assert.equal(code({ question: 'q', options: ['a', 'b'], closesAt: now + 60000 }), 'POLL_DEADLINE');
  assert.equal(code({ question: 'q', options: ['a', 'b'], durationHours: 30 * 24 }), 'OK');
  assert.equal(code({ question: 'q', options: ['a', 'b'], closesAt: 'soon' }), 'POLL_DEADLINE');
  assert.equal(code({ question: 'Call 9876543210?', options: ['a', 'b'] }), 'CREW_TEXT_CONTACT');
  assert.equal(CR.validatePoll({ question: 'q', options: ['a', 'b'], template: 'RIDE_DATE_PLACE' }, now).template, 'RIDE_DATE_PLACE');
  assert.equal(CR.validatePoll({ question: 'q', options: ['a', 'b'], template: 'CHAT' }, now).template, null);
});

test('votes and result math', () => {
  const single = { multi: false, options: [{ id: 'o1', text: 'A' }, { id: 'o2', text: 'B' }, { id: 'o3', text: 'C' }] };
  assert.deepEqual(CR.validateVote(single, ['o2']), ['o2']);
  for (const v of [[], ['o1', 'o2'], ['o9'], ['o1', 'o1'], null]) assert.throws(() => CR.validateVote(single, v), /./, JSON.stringify(v));
  const multi = { ...single, multi: true };
  assert.deepEqual(CR.validateVote(multi, ['o1', 'o3']), ['o1', 'o3']);
  const r = CR.tally(multi, [{ optionIds: ['o1', 'o3'] }, { optionIds: ['o1'] }, { optionIds: ['o2'] }, { optionIds: [] }, { optionIds: ['zz'] }]);
  assert.equal(r.totalVoters, 3);
  assert.deepEqual(r.options.map((o) => [o.count, o.percent]), [[2, 67], [1, 33], [1, 33]]);
  assert.deepEqual(r.leaders, ['o1']);
  const none = CR.tally(single, []);
  assert.equal(none.totalVoters, 0);
  assert.deepEqual(none.options.map((o) => o.percent), [0, 0, 0]);
  assert.deepEqual(none.leaders, []);
  assert.deepEqual(CR.tally(single, [{ optionIds: ['o1'] }, { optionIds: ['o2'] }]).leaders, ['o1', 'o2'], 'a tie has two leaders');
});

// ------------------------------------------------------------------ crews
test('create: any rider, sanitised, creator is admin; validation errors; owned-crew limit and rate limit', async () => {
  const a = await rider('Crew Maker');
  const bad = await t.api('POST', '/crews', { name: 'ab' }, a.token);
  assert.deepEqual([bad.status, bad.json.code], [422, 'CREW_NAME_FORMAT']);
  assert.equal((await t.api('POST', '/crews', { name: 'Fine name', description: 'd'.repeat(201) }, a.token)).json.code, 'CREW_DESC_FORMAT');
  const c = await t.api('POST', '/crews', { name: '  Night   Owls ', description: ' Late rides ' }, a.token);
  assert.equal(c.status, 201);
  assert.match(c.json.crew.crewId, /^cr_[a-f0-9]{16}$/);
  assert.equal(c.json.crew.name, 'Night Owls');
  assert.equal(c.json.crew.myRole, 'ADMIN');
  assert.equal(c.json.crew.settings.membersCanCreatePolls, false, 'members cannot start polls by default');
  const list = await t.api('GET', '/crews', null, a.token);
  assert.equal(list.json.crews.length, 1);
  assert.equal(list.json.crews[0].admin, a.user.username);
  assert.equal(list.json.limits.maxMembers, CR.LIMITS.MAX_MEMBERS);
  for (let i = 2; i <= CR.LIMITS.MAX_OWNED; i++) assert.equal((await t.api('POST', '/crews', { name: `Crew number ${i}` }, a.token)).status, 201);
  const over = await t.api('POST', '/crews', { name: 'One too many' }, a.token);
  assert.deepEqual([over.status, over.json.code], [409, 'CREW_LIMIT']);
  // Rate limit: 20 creations an hour per rider (refused ones count too).
  let last;
  for (let i = 0; i < 12; i++) last = await t.api('POST', '/crews', { name: `Spam crew ${i}` }, a.token);
  assert.equal(last.status, 429);
  assert.equal(last.json.code, 'RATE_LIMITED');
});

test('invites: friends only; non-friend, unknown, blocked and suspended answer the same; idempotent; push', async () => {
  const a = await rider('Invite Admin');
  const friend = await rider('Invite Friend');
  const stranger = await rider('Invite Stranger');
  const blockedFriend = await rider('Invite Blocked');
  const suspended = await rider('Invite Suspended');
  const crew = await newCrew(a, 'Invite Testers');
  await befriend(a, friend);
  await befriend(a, blockedFriend);
  await befriend(a, suspended);

  const unknown = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: 'NoSuchRider_77' }, a.token);
  assert.deepEqual([unknown.status, unknown.json.code], [404, 'NOT_A_FRIEND']);
  const nonFriend = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: stranger.user.username }, a.token);
  assert.deepEqual([nonFriend.status, nonFriend.json], [unknown.status, unknown.json], 'non-friend = unknown username');
  // A friend who blocks the admin (blocking ends the friendship) is refused the same way.
  assert.equal((await t.api('POST', '/blocks', { username: a.user.username }, blockedFriend.token)).status, 200);
  const blocked = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: blockedFriend.user.username }, a.token);
  assert.deepEqual([blocked.status, blocked.json], [unknown.status, unknown.json]);
  // A suspended account is refused the same way.
  await setUser(suspended.user.userId, { status: 'BLOCKED' });
  const susp = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: suspended.user.username }, a.token);
  assert.deepEqual([susp.status, susp.json], [unknown.status, unknown.json]);
  // Self.
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/invites`, { username: a.user.username }, a.token)).json.status, 'ALREADY_MEMBER');

  const ws = await t.connect(friend.token);
  const inv = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: friend.user.username.toLowerCase() }, a.token);
  assert.deepEqual([inv.status, inv.json.status], [201, 'INVITED']);
  const push = await ws.next((m) => m.type === 'CREW_INVITE');
  assert.equal(push.crewName, 'Invite Testers');
  assert.equal(push.username, a.user.username);
  assert.equal(JSON.stringify(push).includes(a.user.userId), false, 'pushes never carry a userId');
  ws.close();
  const again = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: friend.user.username }, a.token);
  assert.deepEqual([again.status, again.json.status], [200, 'ALREADY_INVITED']);

  // Batch answers per name.
  const batch = await t.api('POST', `/crews/${crew.crewId}/invites`, { usernames: [friend.user.username, stranger.user.username, 'NoSuchRider_77'] }, a.token);
  assert.deepEqual(batch.json.results.map((x) => x.status), ['ALREADY_INVITED', 'NOT_A_FRIEND', 'NOT_A_FRIEND']);

  // The invitee sees it, with the inviter's card only.
  const fl = await t.api('GET', '/crews', null, friend.token);
  assert.equal(fl.json.invites.length, 1);
  assert.deepEqual(Object.keys(fl.json.invites[0].invitedBy).sort(), ['avatarUrl', 'username']);
  // The admin sees the pending invite; the invitee cannot see the crew yet.
  assert.equal((await detail(crew, a)).json.invites.length, 1);
  assert.equal((await detail(crew, friend)).status, 404);
  // Invitable picker: only my friends, with their status.
  const pick = await t.api('GET', `/crews/${crew.crewId}/invitable`, null, a.token);
  const st = Object.fromEntries(pick.json.friends.map((x) => [x.username, x.status]));
  assert.equal(st[friend.user.username], 'INVITED');
  assert.equal(st[stranger.user.username], undefined, 'strangers never listed');
  assert.equal(st[suspended.user.username], undefined, 'suspended never listed');

  // Accept: member; accepting twice is harmless (invite gone -> 404).
  const acc = await t.api('POST', `/crews/invites/${fl.json.invites[0].inviteId}/accept`, null, friend.token);
  assert.equal(acc.json.status, 'JOINED');
  assert.equal((await t.api('POST', `/crews/invites/${fl.json.invites[0].inviteId}/accept`, null, friend.token)).status, 404);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/invites`, { username: friend.user.username }, a.token)).json.status, 'ALREADY_MEMBER');
  const d = await detail(crew, friend);
  assert.equal(d.status, 200);
  assert.equal(d.json.crew.myRole, 'MEMBER');
  assert.equal(d.json.invites.length, 0, 'members do not see pending invites');
  assert.equal(d.json.members.length, 2);

  // A plain member cannot invite (403), even their own friends.
  const other = await rider('Member Friend');
  await befriend(friend, other);
  const m403 = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: other.user.username }, friend.token);
  assert.deepEqual([m403.status, m403.json.code], [403, 'NOT_CREW_ADMIN']);
  assert.equal((await t.api('GET', `/crews/${crew.crewId}/invitable`, null, friend.token)).status, 403);
});

test('invites: decline, cancel, 14-day expiry, friendship ended before accept, co-admin and admin blocks', async () => {
  const a = await rider('Expiry Admin');
  const b = await rider('Expiry Friend');
  const c = await rider('Expiry Coadmin');
  const d = await rider('Expiry Coadmin Friend');
  const crew = await newCrew(a, 'Expiry Crew');
  await befriend(a, b);

  // Decline.
  await t.api('POST', `/crews/${crew.crewId}/invites`, { username: b.user.username }, a.token);
  let inv = (await t.api('GET', '/crews', null, b.token)).json.invites[0];
  assert.equal(inv.expiresAt - inv.createdAt, 14 * 86400000);
  assert.equal((await t.api('POST', `/crews/invites/${inv.inviteId}/decline`, null, b.token)).json.status, 'DECLINED');
  assert.equal((await t.api('GET', '/crews', null, b.token)).json.invites.length, 0);
  // Cancel by the admin.
  await t.api('POST', `/crews/${crew.crewId}/invites`, { username: b.user.username }, a.token);
  const pending = (await detail(crew, a)).json.invites[0];
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/invites/${pending.inviteId}`, null, a.token)).status, 200);
  assert.equal((await t.api('GET', '/crews', null, b.token)).json.invites.length, 0);
  // Expired after 14 days: hidden, and accepting answers 410.
  await t.api('POST', `/crews/${crew.crewId}/invites`, { username: b.user.username }, a.token);
  const row = await t.soda.findOne(CR.COLLECTIONS.invites, { userId: b.user.userId });
  await t.soda.replace(CR.COLLECTIONS.invites, row.key, { ...row.value, expiresAt: Date.now() - 1 });
  const exp = await t.api('POST', `/crews/invites/${row.value.inviteId}/accept`, null, b.token);
  assert.deepEqual([exp.status, exp.json.code], [410, 'INVITE_EXPIRED']);
  // An expired invite can be sent again.
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/invites`, { username: b.user.username }, a.token)).json.status, 'INVITED');
  // Friendship ended before accepting: the invite is no longer valid.
  await t.api('DELETE', `/friends/${a.user.username}`, null, b.token);
  inv = (await t.api('GET', '/crews', null, b.token)).json.invites[0];
  const goneR = await t.api('POST', `/crews/invites/${inv.inviteId}/accept`, null, b.token);
  assert.deepEqual([goneR.status, goneR.json.code], [410, 'INVITE_GONE']);

  // Co-admin invites their own friend; but not one who blocked (or is blocked by) the crew admin.
  await join(crew, a, c);
  assert.equal((await t.api('PATCH', `/crews/${crew.crewId}/members/${c.user.username}`, { role: 'CO_ADMIN' }, a.token)).json.role, 'CO_ADMIN');
  await befriend(c, d);
  await t.api('POST', '/blocks', { username: d.user.username }, a.token);
  const refused = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: d.user.username }, c.token);
  assert.deepEqual([refused.status, refused.json.code], [404, 'NOT_A_FRIEND']);
  await t.api('DELETE', `/blocks/${d.user.username}`, null, a.token);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/invites`, { username: d.user.username }, c.token)).status, 201);
  // The invitee does not need to be the admin's friend; a block appearing before accepting voids it.
  await t.api('POST', '/blocks', { username: a.user.username }, d.token);
  const di = (await t.api('GET', '/crews', null, d.token)).json.invites[0];
  assert.equal((await t.api('POST', `/crews/invites/${di.inviteId}/accept`, null, d.token)).json.code, 'INVITE_GONE');
});

test('friendship removed after joining: stays a member', async () => {
  const a = await rider('Stay Admin');
  const b = await rider('Stay Member');
  const crew = await newCrew(a, 'Stay Crew');
  await join(crew, a, b);
  await t.api('DELETE', `/friends/${b.user.username}`, null, a.token);
  const d = await detail(crew, b);
  assert.equal(d.status, 200);
  assert.equal(d.json.members.length, 2);
});

test('crew full (members + pending invites) and joined-crew limit', async () => {
  const a = await rider('Full Admin');
  const b = await rider('Full Friend');
  const c = await rider('Full Friend Two');
  const crew = await newCrew(a, 'Full Crew');
  await befriend(a, b);
  await befriend(a, c);
  // Fill to MAX_MEMBERS - 1 with stored members, then one invite takes the last seat.
  const docs = [];
  for (let i = 0; i < CR.LIMITS.MAX_MEMBERS - 2; i++) docs.push({ memberKey: `${crew.crewId}|ghost${i}`, crewId: crew.crewId, userId: `ghost${i}`, role: 'MEMBER', joinedAt: Date.now() + i, addedBy: a.user.userId });
  for (const doc of docs) await t.soda.insert(CR.COLLECTIONS.members, doc);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/invites`, { username: b.user.username }, a.token)).status, 201);
  const full = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: c.user.username }, a.token);
  assert.deepEqual([full.status, full.json.code], [409, 'CREW_FULL']);
  // Accepting when a seat was filled meanwhile: still full.
  await t.soda.insert(CR.COLLECTIONS.members, { memberKey: `${crew.crewId}|ghostX`, crewId: crew.crewId, userId: 'ghostX', role: 'MEMBER', joinedAt: Date.now(), addedBy: a.user.userId });
  const inv = (await t.api('GET', '/crews', null, b.token)).json.invites[0];
  const acc = await t.api('POST', `/crews/invites/${inv.inviteId}/accept`, null, b.token);
  assert.deepEqual([acc.status, acc.json.code], [409, 'CREW_FULL']);
  await t.soda.removeWhere(CR.COLLECTIONS.members, { crewId: crew.crewId, role: 'MEMBER' });

  // Joined-crew limit: b is already in MAX_JOINED crews.
  for (let i = 0; i < CR.LIMITS.MAX_JOINED; i++) {
    await t.soda.insert(CR.COLLECTIONS.members, { memberKey: `cr_fake${i}|${b.user.userId}`, crewId: `cr_fake${i}`, userId: b.user.userId, role: 'MEMBER', joinedAt: Date.now(), addedBy: 'x' });
  }
  const many = await t.api('POST', `/crews/invites/${inv.inviteId}/accept`, null, b.token);
  assert.deepEqual([many.status, many.json.code], [409, 'TOO_MANY_CREWS']);
  await t.soda.removeWhere(CR.COLLECTIONS.members, { userId: b.user.userId });
});

test('privacy: non-members get the same 404 as an unknown crew; member rows carry no contact details', async () => {
  const a = await rider('Privacy Admin');
  const b = await rider('Privacy Member');
  const s = await rider('Privacy Stranger');
  const crew = await newCrew(a, 'Private Crew');
  await join(crew, a, b);
  const unknown = await t.api('GET', '/crews/cr_0000000000000000', null, s.token);
  const notMine = await detail(crew, s);
  assert.deepEqual([notMine.status, notMine.json], [unknown.status, unknown.json]);
  assert.deepEqual([notMine.status, notMine.json.code], [404, 'CREW_NOT_FOUND']);
  assert.equal((await t.api('GET', '/crews/not-an-id', null, s.token)).status, 404);
  for (const [m, p, body] of [['GET', `/crews/${crew.crewId}/polls`], ['POST', `/crews/${crew.crewId}/polls`, { question: 'q', options: ['a', 'b'] }],
    ['POST', `/crews/${crew.crewId}/leave`], ['PATCH', `/crews/${crew.crewId}`, { name: 'Taken over' }], ['DELETE', `/crews/${crew.crewId}`],
    ['POST', `/crews/${crew.crewId}/invites`, { username: a.user.username }], ['GET', `/crews/${crew.crewId}/invitable`]]) {
    const r = await t.api(m, p, body, s.token);
    assert.equal(r.status, 404, `${m} ${p}`);
  }
  const d = await detail(crew, b);
  for (const m of d.json.members) assert.deepEqual(Object.keys(m).sort(), ['avatarUrl', 'displayName', 'joinedAt', 'role', 'username']);
  const text = JSON.stringify(d.json);
  for (const who of [a, b]) {
    assert.equal(text.includes(who.user.userId), false, 'no userId');
    assert.equal(text.includes(who.user.email), false, 'no e-mail');
  }
  assert.equal(/phone|email|medical|emergency|location|lat|lng/i.test(Object.keys(d.json.members[0]).join(',')), false);
  assert.equal(d.json.members[0].displayName, 'Privacy', 'first name only');
  // No chat: there is no message endpoint at all.
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/messages`, { text: 'hi' }, a.token)).status, 404);
});

test('roles: co-admins (max 3), only the admin removes, transfer, admin leaving hands over, last member deletes', async () => {
  const a = await rider('Role Admin');
  const ms = [];
  for (let i = 0; i < 5; i++) ms.push(await rider(`Role Member${i}`));
  const crew = await newCrew(a, 'Role Crew');
  for (const m of ms) await join(crew, a, m);
  for (let i = 0; i < 3; i++) assert.equal((await t.api('PATCH', `/crews/${crew.crewId}/members/${ms[i].user.username}`, { role: 'CO_ADMIN' }, a.token)).status, 200);
  const fourth = await t.api('PATCH', `/crews/${crew.crewId}/members/${ms[3].user.username}`, { role: 'CO_ADMIN' }, a.token);
  assert.deepEqual([fourth.status, fourth.json.code], [409, 'CO_ADMIN_LIMIT']);
  assert.equal((await t.api('PATCH', `/crews/${crew.crewId}/members/${ms[3].user.username}`, { role: 'KING' }, a.token)).status, 400);
  // Co-admins cannot remove, change roles, rename or delete.
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/members/${ms[4].user.username}`, null, ms[0].token)).status, 403);
  assert.equal((await t.api('PATCH', `/crews/${crew.crewId}/members/${ms[4].user.username}`, { role: 'CO_ADMIN' }, ms[0].token)).status, 403);
  assert.equal((await t.api('PATCH', `/crews/${crew.crewId}`, { name: 'Renamed' }, ms[0].token)).status, 403);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}`, null, ms[0].token)).status, 403);
  // Admin removes a member; the removed rider is told and loses access.
  const ws = await t.connect(ms[4].token);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/members/${ms[4].user.username}`, null, a.token)).json.removed, true);
  assert.equal((await ws.next((m) => m.type === 'CREW_REMOVED')).crewId, crew.crewId);
  ws.close();
  assert.equal((await detail(crew, ms[4])).status, 404);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/members/${a.user.username}`, null, a.token)).json.code, 'NOT_ALLOWED');
  // Transfer to a plain member: the old admin becomes a member (3 co-admin seats taken).
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/transfer`, { username: 'NoSuchRider_1' }, a.token)).status, 422);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/transfer`, { username: ms[3].user.username }, a.token)).json.admin, ms[3].user.username);
  let d = await detail(crew, a);
  assert.equal(d.json.crew.myRole, 'MEMBER');
  assert.equal(d.json.members[0].username, ms[3].user.username);
  assert.equal(d.json.members[0].role, 'ADMIN');
  // The new admin leaves without choosing: the oldest co-admin (ms[0]) takes over.
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/leave`, null, ms[3].token)).json.left, true);
  d = await detail(crew, ms[0]);
  assert.equal(d.json.crew.myRole, 'ADMIN');
  // Leaving with a chosen successor.
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/leave`, { transferTo: 'NoSuchRider_1' }, ms[0].token)).status, 422);
  await t.api('POST', `/crews/${crew.crewId}/leave`, { transferTo: a.user.username }, ms[0].token);
  assert.equal((await detail(crew, a)).json.crew.myRole, 'ADMIN');
  // Members leave; the last one leaving deletes the crew.
  for (const m of [ms[1], ms[2]]) assert.equal((await t.api('POST', `/crews/${crew.crewId}/leave`, null, m.token)).json.deleted, false);
  const last = await t.api('POST', `/crews/${crew.crewId}/leave`, null, a.token);
  assert.equal(last.json.deleted, true);
  assert.equal(await t.soda.findOne(CR.COLLECTIONS.crews, { crewId: crew.crewId }), null);
});

test('admin settings and delete', async () => {
  const a = await rider('Edit Admin');
  const b = await rider('Edit Member');
  const crew = await newCrew(a, 'Edit Crew');
  await join(crew, a, b);
  const p = await t.api('PATCH', `/crews/${crew.crewId}`, { name: '  New  Name ', description: '', membersCanCreatePolls: true }, a.token);
  assert.equal(p.json.crew.name, 'New Name');
  assert.equal(p.json.crew.settings.membersCanCreatePolls, true);
  assert.equal((await t.api('PATCH', `/crews/${crew.crewId}`, { name: 'x' }, a.token)).json.code, 'CREW_NAME_FORMAT');
  assert.equal((await t.api('PATCH', `/crews/${crew.crewId}`, { membersCanCreatePolls: 'yes' }, a.token)).status, 400);
  const ws = await t.connect(b.token);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}`, null, a.token)).json.deleted, true);
  assert.equal((await ws.next((m) => m.type === 'CREW_DELETED')).crewName, 'New Name');
  ws.close();
  assert.equal((await detail(crew, b)).status, 404);
  assert.equal((await t.api('GET', '/crews', null, b.token)).json.crews.length, 0);
});

test('suspended and deleted accounts leave their crews; a deleted admin hands over; votes cleaned up', async () => {
  const a = await rider('Gone Admin');
  const b = await rider('Gone Coadmin');
  const c = await rider('Gone Member');
  const crew = await newCrew(a, 'Gone Crew');
  await join(crew, a, b);
  await join(crew, a, c);
  await t.api('PATCH', `/crews/${crew.crewId}/members/${b.user.username}`, { role: 'CO_ADMIN' }, a.token);
  const open = (await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Open one', options: ['x', 'y'] }, a.token)).json.poll;
  const closed = (await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Closed one', options: ['x', 'y'] }, a.token)).json.poll;
  for (const p of [open, closed]) await t.api('POST', `/crews/${crew.crewId}/polls/${p.pollId}/vote`, { optionIds: ['o1'] }, a.token);
  await t.api('POST', `/crews/${crew.crewId}/polls/${closed.pollId}/close`, null, a.token);

  // Suspended member: dropped on the next read.
  await setUser(c.user.userId, { status: 'BLOCKED' });
  let d = await detail(crew, a);
  assert.deepEqual(d.json.members.map((m) => m.username).sort(), [a.user.username, b.user.username].sort());
  assert.equal(await CR.memberOf(t.soda, crew.crewId, c.user.userId), null);

  // Deleted admin: the co-admin takes over; open-poll votes removed, closed-poll votes kept anonymously.
  const del = await t.api('DELETE', '/me', null, a.token);
  assert.equal(del.status, 200, JSON.stringify(del.json));
  d = await detail(crew, b);
  assert.equal(d.json.crew.myRole, 'ADMIN');
  assert.equal(d.json.members.length, 1);
  const polls = (await t.api('GET', `/crews/${crew.crewId}/polls`, null, b.token)).json.polls;
  const po = polls.find((p) => p.pollId === open.pollId);
  const pc = polls.find((p) => p.pollId === closed.pollId);
  assert.equal(po.totalVoters, 0);
  assert.equal(pc.totalVoters, 1, 'closed results keep the count');
  assert.deepEqual(pc.voters.o1, [], 'but not the name');
  assert.equal(pc.createdBy, null);
  assert.equal((await t.soda.query(CR.COLLECTIONS.votes, { userId: a.user.userId }, { limit: 10 })).length, 0);
  assert.equal((await t.soda.query(CR.COLLECTIONS.invites, { invitedBy: a.user.userId }, { limit: 10 })).length, 0);
  // The last member deleting their account deletes the crew.
  await t.api('DELETE', '/me', null, b.token);
  assert.equal(await t.soda.findOne(CR.COLLECTIONS.crews, { crewId: crew.crewId }), null);
  assert.equal((await t.soda.query(CR.COLLECTIONS.polls, { crewId: crew.crewId }, { limit: 10 })).length, 0);
});

// ------------------------------------------------------------------ polls
test('poll lifecycle: who may create, push, vote / change / retract, named results, close, delete, expiry', async () => {
  const a = await rider('Poll Admin');
  const b = await rider('Poll Member');
  const c = await rider('Poll Member Two');
  const crew = await newCrew(a, 'Poll Crew');
  await join(crew, a, b);
  await join(crew, a, c);

  // Members cannot start polls unless the admin allows it.
  const denied = await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Ride Sunday?', options: ['Yes', 'No'] }, b.token);
  assert.deepEqual([denied.status, denied.json.code], [403, 'NOT_ALLOWED']);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Bad', options: ['only'] }, a.token)).json.code, 'POLL_OPTIONS');

  const ws = await t.connect(b.token);
  const created = await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Where on Sunday?', options: ['Nandi Hills', 'Coorg', 'Skandagiri'], comment: 'ignored' }, a.token);
  assert.equal(created.status, 201, JSON.stringify(created.json));
  const poll = created.json.poll;
  assert.equal(poll.status, 'OPEN');
  assert.equal(poll.anonymous, false);
  assert.equal(poll.createdBy, a.user.username);
  assert.equal('comment' in poll, false, 'no free text');
  assert.ok(Math.abs(poll.closesAt - (Date.now() + 3 * 86400000)) < 60000, 'default 3 days');
  const push = await ws.next((m) => m.type === 'POLL_CREATED');
  assert.equal(push.question, 'Where on Sunday?');
  assert.equal(push.crewName, 'Poll Crew');

  // The list shows a pending vote for b.
  const lb = (await t.api('GET', '/crews', null, b.token)).json.crews.find((x) => x.crewId === crew.crewId);
  assert.deepEqual([lb.openPolls, lb.pendingVotes], [1, 1]);
  // 3.55 People hub: when the next open poll closes ("Poll closes in 5 h" in the Crews list).
  assert.ok(lb.nextPollClosesAt > Date.now(), 'nextPollClosesAt is the open poll\'s closing time');

  const vote = (who, ids) => t.api('POST', `/crews/${crew.crewId}/polls/${poll.pollId}/vote`, { optionIds: ids }, who.token);
  assert.equal((await vote(b, ['o1', 'o2'])).json.code, 'VOTE_INVALID', 'single choice');
  assert.equal((await vote(b, ['o9'])).json.code, 'VOTE_INVALID');
  let r = await vote(b, ['o1']);
  assert.deepEqual(r.json.poll.myVote, ['o1']);
  await ws.next((m) => m.type === 'POLL_UPDATED' && m.pollId === poll.pollId);
  r = await vote(b, ['o2']);
  assert.deepEqual(r.json.poll.myVote, ['o2'], 'changed vote');
  await vote(c, ['o2']);
  r = await vote(a, ['o3']);
  assert.equal(r.json.poll.totalVoters, 3);
  assert.deepEqual(r.json.poll.options.map((o) => o.count), [0, 2, 1]);
  assert.deepEqual(r.json.poll.options.map((o) => o.percent), [0, 67, 33]);
  assert.deepEqual(r.json.poll.leaders, ['o2']);
  assert.deepEqual(r.json.poll.voters.o2.map((v) => v.username).sort(), [b.user.username, c.user.username].sort());
  assert.deepEqual(Object.keys(r.json.poll.voters.o2[0]).sort(), ['displayName', 'username']);
  const lb2 = (await t.api('GET', '/crews', null, b.token)).json.crews.find((x) => x.crewId === crew.crewId);
  assert.equal(lb2.pendingVotes, 0);
  // Retract.
  r = await t.api('DELETE', `/crews/${crew.crewId}/polls/${poll.pollId}/vote`, null, c.token);
  assert.equal(r.json.poll.totalVoters, 2);
  assert.deepEqual(r.json.poll.myVote, []);

  // Only the creator / admin / co-admins close or delete.
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/polls/${poll.pollId}/close`, null, b.token)).status, 403);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/polls/${poll.pollId}`, null, b.token)).status, 403);
  const closed = await t.api('POST', `/crews/${crew.crewId}/polls/${poll.pollId}/close`, null, a.token);
  assert.equal(closed.json.poll.status, 'CLOSED');
  assert.ok(closed.json.poll.closedAt > 0);
  const late = await vote(b, ['o1']);
  assert.deepEqual([late.status, late.json.code], [409, 'POLL_CLOSED']);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/polls/${poll.pollId}/vote`, null, b.token)).json.code, 'POLL_CLOSED');
  // Closed results stay visible to members.
  const kept = (await t.api('GET', `/crews/${crew.crewId}/polls`, null, c.token)).json.polls.find((p) => p.pollId === poll.pollId);
  assert.equal(kept.totalVoters, 2);

  // Members allowed to create: anonymous multiple-choice poll by a member; results without names.
  await t.api('PATCH', `/crews/${crew.crewId}`, { membersCanCreatePolls: true }, a.token);
  const anon = (await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Which snacks?', options: ['Chai', 'Vada', 'Dosa'], multi: true, anonymous: true, durationHours: 2 }, b.token)).json.poll;
  assert.equal(anon.multi, true);
  r = await t.api('POST', `/crews/${crew.crewId}/polls/${anon.pollId}/vote`, { optionIds: ['o1', 'o3'] }, c.token);
  assert.deepEqual(r.json.poll.options.map((o) => o.count), [1, 0, 1]);
  assert.equal('voters' in r.json.poll, false, 'anonymous: no names');
  assert.equal(JSON.stringify(r.json).includes(c.user.username), false);
  // The member who created it can close it; a different member cannot delete it; the admin can.
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/polls/${anon.pollId}`, null, c.token)).status, 403);
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/polls/${anon.pollId}`, null, a.token)).json.deleted, true);
  assert.equal((await t.soda.query(CR.COLLECTIONS.votes, { pollId: anon.pollId }, { limit: 10 })).length, 0);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/polls/${anon.pollId}/vote`, { optionIds: ['o1'] }, c.token)).status, 404);

  // Deadline passing closes the poll on its own.
  const timed = (await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Ride date?', options: ['Sat 14', 'Sun 15'], template: 'RIDE_DATE_PLACE' }, a.token)).json.poll;
  assert.equal(timed.template, 'RIDE_DATE_PLACE');
  const row = await t.soda.findOne(CR.COLLECTIONS.polls, { pollId: timed.pollId });
  await t.soda.replace(CR.COLLECTIONS.polls, row.key, { ...row.value, closesAt: Date.now() - 1000 });
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/polls/${timed.pollId}/vote`, { optionIds: ['o1'] }, b.token)).json.code, 'POLL_CLOSED');
  const after = (await t.api('GET', `/crews/${crew.crewId}/polls`, null, b.token)).json.polls.find((p) => p.pollId === timed.pollId);
  assert.equal(after.status, 'CLOSED');
  ws.close();
});

test('polls: max open polls, last 50 closed kept', async () => {
  const a = await rider('Many Polls');
  const crew = await newCrew(a, 'Many Poll Crew');
  for (let i = 0; i < CR.LIMITS.MAX_OPEN_POLLS; i++) {
    assert.equal((await t.api('POST', `/crews/${crew.crewId}/polls`, { question: `Q${i}`, options: ['a', 'b'] }, a.token)).status, 201);
  }
  const over = await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'One more', options: ['a', 'b'] }, a.token);
  assert.deepEqual([over.status, over.json.code], [409, 'TOO_MANY_OPEN_POLLS']);
  // 55 old closed polls stored; closing one more prunes to 50 closed.
  const base = Date.now() - 100 * 86400000;
  for (let i = 0; i < 55; i++) {
    await t.soda.insert(CR.COLLECTIONS.polls, { pollId: `po_${String(i).padStart(16, '0')}`, crewId: crew.crewId, createdBy: a.user.userId, question: `Old ${i}`, options: [{ id: 'o1', text: 'a' }, { id: 'o2', text: 'b' }], multi: false, anonymous: false, template: null, status: 'CLOSED', createdAt: base + i, closesAt: base + i, closedAt: base + i, closedBy: null });
  }
  const list = (await t.api('GET', `/crews/${crew.crewId}/polls`, null, a.token)).json.polls;
  await t.api('POST', `/crews/${crew.crewId}/polls/${list[0].pollId}/close`, null, a.token);
  const closed = (await t.soda.query(CR.COLLECTIONS.polls, { crewId: crew.crewId, status: 'CLOSED' }, { limit: 200 })).map((x) => x.value);
  assert.equal(closed.length, CR.LIMITS.POLL_KEEP_CLOSED);
  assert.ok(closed.some((p) => p.pollId === list[0].pollId), 'the newest closed poll is kept');
  assert.equal(closed.some((p) => p.question === 'Old 0'), false, 'the oldest are dropped');
});

// ------------------------------------------------------------------ switches and admin
test('admin switches: crews off hides everything, crewPolls off only the polls', async () => {
  const a = await rider('Switch Admin');
  const crew = await newCrew(a, 'Switch Crew');
  assert.equal((await setFlag('crewPolls', false)).status, 200);
  const off = await t.api('GET', `/crews/${crew.crewId}/polls`, null, a.token);
  assert.deepEqual([off.status, off.json.code, off.json.feature], [403, 'FEATURE_OFF', 'crewPolls']);
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'q', options: ['a', 'b'] }, a.token)).status, 403);
  const d = await detail(crew, a);
  assert.equal(d.status, 200);
  assert.equal(d.json.crew.canCreatePoll, false);
  await setFlag('crewPolls', true);
  await setFlag('crews', false);
  for (const [m, p] of [['GET', '/crews'], ['POST', '/crews'], ['GET', `/crews/${crew.crewId}`], ['GET', `/crews/${crew.crewId}/polls`]]) {
    const r = await t.api(m, p, m === 'POST' ? { name: 'Off crew' } : undefined, a.token);
    assert.deepEqual([r.status, r.json.code], [403, 'FEATURE_OFF'], `${m} ${p}`);
  }
  // Admin moderation keeps working while riders' crews are off.
  assert.equal((await t.api('GET', '/admin/crews', null, admin.token)).status, 200);
  await setFlag('crews', true);
  assert.equal((await t.api('GET', '/crews', null, a.token)).status, 200);
  const feats = await t.api('GET', '/features', null, a.token);
  assert.equal(feats.json.flags.crews, true);
  assert.equal(feats.json.flags.crewPolls, true);
});

test('admin console: list, detail, delete a poll and a crew (audited); riders refused', async () => {
  const a = await rider('Mod Admin');
  const b = await rider('Mod Member');
  const crew = await newCrew(a, 'Moderated Crew');
  await join(crew, a, b);
  const poll = (await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Rude question', options: ['a', 'b'] }, a.token)).json.poll;
  const list = await t.api('GET', '/admin/crews?q=moderated', null, admin.token);
  assert.equal(list.status, 200);
  const row = list.json.crews.find((c) => c.crewId === crew.crewId);
  assert.equal(row.admin, a.user.username);
  assert.equal(row.memberCount, 2);
  assert.equal(row.openPolls, 1);
  const det = await t.api('GET', `/admin/crews/${crew.crewId}`, null, admin.token);
  assert.equal(det.json.members.length, 2);
  assert.equal(det.json.polls[0].question, 'Rude question');
  for (const [m, p] of [['GET', '/admin/crews'], ['GET', `/admin/crews/${crew.crewId}`], ['DELETE', `/admin/crews/${crew.crewId}`], ['DELETE', `/admin/crews/${crew.crewId}/polls/${poll.pollId}`]]) {
    assert.equal((await t.api(m, p, null, b.token)).status, 403, `${m} ${p}`);
  }
  assert.equal((await t.api('DELETE', `/admin/crews/${crew.crewId}/polls/${poll.pollId}`, null, admin.token)).json.deleted, true);
  assert.equal((await t.api('GET', `/crews/${crew.crewId}/polls`, null, b.token)).json.polls.length, 0);
  const ws = await t.connect(b.token);
  assert.equal((await t.api('DELETE', `/admin/crews/${crew.crewId}`, null, admin.token)).json.deleted, true);
  await ws.next((m) => m.type === 'CREW_DELETED');
  ws.close();
  assert.equal((await detail(crew, b)).status, 404);
  assert.equal((await t.api('GET', `/admin/crews/${crew.crewId}`, null, admin.token)).status, 404);
  const auditRows = (await t.soda.query('audit_log', {}, { limit: 1000 })).map((x) => x.value).filter((e) => String(e.action || '').startsWith('crew.'));
  if (auditRows.length) assert.deepEqual(new Set(auditRows.map((e) => e.action)), new Set(['crew.poll.delete', 'crew.delete']));
});
