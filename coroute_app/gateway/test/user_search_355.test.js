'use strict';
/**
 * 3.55 People hub (docs/features_355/usernames_friends_profiles.md, "People hub"):
 *   GET /users/search?q=      username prefix search (privacy-safe)
 *   GET /friends/suggestions  "People you rode with"
 *   PATCH /me/privacy {discoverable}
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'searchadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { searchKeyOf } = require('../src/social_routes');

let t;
let admin;
let shortQ; // reused by later tests (registration is limited to 30 per 15 minutes per address)
before(async () => {
  t = await boot();
  admin = await t.register('Search Admin', 'searchadmin@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const setFlag = (id, enabled) => t.api('PUT', `/admin/features/${id}`, { enabled, reason: 'test' }, admin.token);
const rename = (r, username) => t.api('PATCH', '/me/username', { username }, r.token);
const search = (r, q) => t.api('GET', `/users/search?q=${encodeURIComponent(q)}`, null, r.token);
const names = (res) => (res.json.results || []).map((x) => x.username);

/** Registers a rider with a chosen username. */
async function rider(name, email, username) {
  const r = await t.register(name, email);
  const res = await rename(r, username);
  assert.equal(res.status, 200, JSON.stringify(res.json));
  return r;
}

test('searchKeyOf: 2-20 username characters, "@" and capitals ignored, e-mails / phones never match', () => {
  assert.equal(searchKeyOf('Sw'), 'sw');
  assert.equal(searchKeyOf('  @SwiftFal '), 'swiftfal');
  assert.equal(searchKeyOf('@@ab'), 'ab');
  for (const bad of ['', 'a', '@a', ' s ', 'mail@example.com', '+919876543210', 'two words', 'a'.repeat(21), null, undefined, 'dash-x']) {
    assert.equal(searchKeyOf(bad), null, String(bad));
  }
});

test('prefix search: case-insensitive, with @, max 10, only username + picture + relation', async () => {
  const me = await rider('Seeker Main', 'seeker@coroute.test', 'SeekerMain');
  const created = [];
  for (let i = 0; i < 11; i++) created.push(await rider(`Zeta Rider ${i}`, `zeta${i}@coroute.test`, `ZetaRider${String(i).padStart(2, '0')}`));

  const res = await search(me, 'zetar');
  assert.equal(res.status, 200);
  assert.equal(res.json.results.length, 10, 'at most 10 results');
  assert.equal(res.headers.get('cache-control'), 'private, no-store');
  for (const row of res.json.results) {
    assert.deepEqual(Object.keys(row).sort(), ['avatarUrl', 'relation', 'username']);
    assert.equal(row.relation, 'NONE');
    assert.match(row.username, /^ZetaRider\d\d$/);
  }
  // "@", capitals and spaces give the same answer.
  assert.deepEqual(names(await search(me, '  @ZETAR ')), names(res));
  // The exact username comes first.
  const exact = await search(me, 'ZetaRider10');
  assert.deepEqual(names(exact), ['ZetaRider10']);
  // Never myself.
  assert.deepEqual(names(await search(me, 'seekerm')), []);
  // Nothing about the account leaks, even when the query looks like it.
  const body = JSON.stringify(res.json);
  for (const leak of ['@coroute.test', '+91', 'userId', 'phone', 'email', 'Zeta Rider']) assert.ok(!body.includes(leak), leak);
});

test('search: min 2 characters, e-mail / phone queries refused, needs sign-in, switch off', async () => {
  const me = shortQ = await rider('Short Query', 'shortq@coroute.test', 'ShortQuery');
  for (const q of ['', 'a', '@b']) {
    const r = await search(me, q);
    assert.equal(r.status, 400, q);
    assert.equal(r.json.code, 'QUERY_TOO_SHORT');
  }
  // Searching by an e-mail or a phone number never finds anyone.
  assert.equal((await search(me, 'shortq@coroute.test')).status, 400);
  assert.equal((await search(me, '+919876510001')).status, 400);
  assert.equal((await t.api('GET', '/users/search?q=zeta')).status, 401);
  await setFlag('friends', false);
  try {
    assert.equal((await search(me, 'zeta')).status, 403);
  } finally {
    await setFlag('friends', true);
  }
});

test('search: relationship chip, blocks hide both ways, discoverable off = exact username only', async () => {
  const me = await rider('Chip Viewer', 'chipviewer@coroute.test', 'ChipViewer');
  const friend = await rider('Kilo Friend', 'kilofriend@coroute.test', 'KiloFriend');
  const asked = await rider('Kilo Asked', 'kiloasked@coroute.test', 'KiloAsked');
  const asker = await rider('Kilo Asker', 'kiloasker@coroute.test', 'KiloAsker');
  const blocker = await rider('Kilo Blocker', 'kiloblocker@coroute.test', 'KiloBlocker');
  const blockedByMe = await rider('Kilo Blocked', 'kiloblocked@coroute.test', 'KiloBlocked');
  const hidden = await rider('Kilo Hidden', 'kilohidden@coroute.test', 'KiloHidden');

  // friend: request + accept
  const fr = await t.api('POST', '/friends/requests', { username: 'KiloFriend' }, me.token);
  await t.api('POST', `/friends/requests/${fr.json.request.requestId}/accept`, null, friend.token);
  await t.api('POST', '/friends/requests', { username: 'KiloAsked' }, me.token);
  await t.api('POST', '/friends/requests', { username: 'ChipViewer' }, asker.token);
  await t.api('POST', '/blocks', { username: 'ChipViewer' }, blocker.token);
  await t.api('POST', '/blocks', { username: 'KiloBlocked' }, me.token);
  const off = await t.api('PATCH', '/me/privacy', { discoverable: false }, hidden.token);
  assert.equal(off.status, 200);
  assert.equal(off.json.discoverable, false);
  assert.equal(off.json.publicLeaderboard, true, 'the other switch is untouched');
  assert.equal((await t.api('GET', '/me/profile', null, hidden.token)).json.profile.discoverable, false);
  assert.equal((await t.api('PATCH', '/me/privacy', { discoverable: 'no' }, hidden.token)).status, 400);

  const res = await search(me, 'kilo');
  const rel = Object.fromEntries(res.json.results.map((x) => [x.username, x.relation]));
  assert.deepEqual(rel, { KiloFriend: 'FRIENDS', KiloAsked: 'PENDING_OUT', KiloAsker: 'PENDING_IN' });
  // Hidden from me: KiloBlocker (blocked me), KiloBlocked (I blocked), KiloHidden (not discoverable).
  assert.deepEqual(names(await search(me, 'KiloHidden')), ['KiloHidden'], 'exact username still finds them');
  assert.deepEqual(names(await search(me, 'kiloblocker')), [], 'a block is never revealed');
  assert.deepEqual(names(await search(me, 'kiloblocked')), []);
  // The blocker cannot find me either way round.
  assert.deepEqual(names(await search(blocker, 'chipview')), []);
  void asked; void blockedByMe;
});

test('search is limited to 30 a minute per rider', async () => {
  const me = shortQ;
  let limited = null;
  for (let i = 0; i < 32; i++) {
    const r = await search(me, `xq${i}`);
    if (r.status === 429) { limited = r; break; }
  }
  assert.ok(limited, 'the 31st search is refused');
  assert.equal(limited.json.code, 'RATE_LIMITED');
});

test('People you rode with: co-riders of my recent rides, not friends, opt-out and blocks respected', async () => {
  const me = await rider('Ride Self', 'rideself@coroute.test', 'RideSelf');
  const often = await rider('Ride Often', 'rideoften@coroute.test', 'RideOften');
  const once = await rider('Ride Once', 'rideonce@coroute.test', 'RideOnce');
  const pal = await rider('Ride Pal', 'ridepal@coroute.test', 'RidePal');
  const shy = await rider('Ride Shy', 'rideshy@coroute.test', 'RideShy');
  const rude = await rider('Ride Rude', 'riderude@coroute.test', 'RideRude');
  const old = await rider('Ride Old', 'rideold@coroute.test', 'RideOld');
  const stranger = shortQ;

  const now = Date.now();
  const repo = t.gw.repo;
  let n = 0;
  const trip = (r, groupId, end) => repo.saveTrip({
    tripId: `trip_s${++n}`, userId: r.user.userId, groupId, startTimeEpochMs: end - 3600000, endTimeEpochMs: end, totalDistanceKm: 20, riderCount: 3,
  });
  // Ride A (yesterday): me, often, once, pal, shy, rude. Ride B: me, often. Old ride (a year ago): me, old.
  for (const r of [me, often, once, pal, shy, rude]) await trip(r, 'GRP-SUGG-A', now - 86400000);
  for (const r of [me, often]) await trip(r, 'GRP-SUGG-B', now - 2 * 86400000);
  for (const r of [me, old]) await trip(r, 'GRP-SUGG-OLD', now - 365 * 86400000);
  await trip(stranger, 'GRP-SUGG-OTHER', now - 86400000);

  const fr = await t.api('POST', '/friends/requests', { username: 'RidePal' }, me.token);
  await t.api('POST', `/friends/requests/${fr.json.request.requestId}/accept`, null, pal.token);
  await t.api('PATCH', '/me/privacy', { discoverable: false }, shy.token);
  await t.api('POST', '/blocks', { username: 'RideSelf' }, rude.token);
  await t.api('POST', '/friends/requests', { username: 'RideOnce' }, me.token);

  const res = await t.api('GET', '/friends/suggestions', null, me.token);
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.deepEqual(res.json.suggestions.map((s) => s.username), ['RideOften', 'RideOnce'], 'most rides first; friends, opted-out, blockers, old rides and strangers left out');
  assert.equal(res.json.suggestions[0].rides, 2);
  assert.equal(res.json.suggestions[0].relation, 'NONE');
  assert.equal(res.json.suggestions[1].relation, 'PENDING_OUT');
  for (const s of res.json.suggestions) assert.deepEqual(Object.keys(s).sort(), ['avatarUrl', 'relation', 'rides', 'username']);
  // A rider with no rides gets an empty list.
  assert.deepEqual((await t.api('GET', '/friends/suggestions', null, stranger.token)).json.suggestions, []);
  void once; void old;
});
