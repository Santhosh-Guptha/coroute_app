'use strict';
/**
 * 3.55 friends: the exact answers the app reads (lib/domain/social/friends_models.dart).
 * Owner bug "a friend request is not appearing anywhere in the app": this pins the shapes and field
 * names end to end (send by username and by invite code, the target's GET /friends `incoming`, the
 * sender's `outgoing`, the FRIEND_REQUEST / FRIEND_ACCEPTED socket pushes) and checks them against
 * the fixture the Dart test parses (test/fixtures/friends_355_gateway.json), so neither side can
 * drift from the other.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { boot } = require('./_helpers');

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'test', 'fixtures', 'friends_355_gateway.json'), 'utf8'));

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

const typeOf = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);
/** Keys and value types, recursively (arrays by their first element). `nullable` keys may be null or string. */
function shapeOf(v, nullable = new Set(['avatarUrl'])) {
  if (Array.isArray(v)) return v.length ? [shapeOf(v[0], nullable)] : [];
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v).sort()) out[k] = nullable.has(k) ? 'string|null' : shapeOf(v[k], nullable);
    return out;
  }
  return typeOf(v);
}

test('a request by username (any case, with "@") and by invite code reaches the target everywhere the app looks', async () => {
  const a = await t.register('Contract Sender', 'contract.sender@coroute.test');
  const b = await t.register('Contract Target', 'contract.target@coroute.test');
  const c = await t.register('Contract Coder', 'contract.coder@coroute.test');
  const bWs = await t.connect(b.token);
  const aWs = await t.connect(a.token);

  // Sender: 202 with the request as it will appear under "Sent".
  const sent = await t.api('POST', '/friends/requests', { username: `@${b.user.username.toLowerCase()}` }, a.token);
  assert.equal(sent.status, 202, JSON.stringify(sent.json));
  assert.equal(sent.json.status, 'REQUESTED');
  assert.match(sent.json.request.requestId, /^fr_[a-f0-9]{20}$/);
  assert.equal(sent.json.request.username, b.user.username);
  assert.deepEqual(shapeOf(sent.json), shapeOf(FIXTURE.sendByUsername.body));

  // Target: the socket push names the sender by username, with the request id and an eventId.
  const push = await bWs.next((m) => m.type === 'FRIEND_REQUEST');
  assert.equal(push.requestId, sent.json.request.requestId);
  assert.equal(push.username, a.user.username);
  assert.equal(push.eventId, `FRIEND_REQUEST:${push.requestId}`);
  assert.deepEqual(shapeOf(push), shapeOf(FIXTURE.socketFriendRequest));
  assert.ok(!JSON.stringify(push).includes(a.user.userId), 'no userId in the push');

  // By invite code (lower case is fine).
  const code = (await t.api('GET', '/friends/invite', null, b.token)).json.inviteCode;
  const byCode = await t.api('POST', '/friends/requests', { inviteCode: code.toLowerCase() }, c.token);
  assert.equal(byCode.status, 202);
  assert.deepEqual(shapeOf(byCode.json), shapeOf(FIXTURE.sendByInviteCode.body));
  const push2 = await bWs.next((m) => m.type === 'FRIEND_REQUEST');
  assert.equal(push2.username, c.user.username);
  assert.equal(push2.via, 'invite');

  // Target's GET /friends: top-level `incoming` (not nested), one row per request, newest first.
  const bList = (await t.api('GET', '/friends', null, b.token)).json;
  assert.deepEqual(Object.keys(bList).sort(), ['blocked', 'friends', 'incoming', 'inviteCode', 'inviteLink', 'ok', 'outgoing', 'shareText']);
  assert.deepEqual(bList.incoming.map((r) => r.username), [c.user.username, a.user.username]);
  assert.deepEqual(bList.incoming.map((r) => r.requestId), [byCode.json.request.requestId, sent.json.request.requestId]);
  assert.deepEqual(shapeOf(bList), shapeOf(FIXTURE.targetFriends));
  assert.ok(!JSON.stringify(bList).includes(a.user.userId) && !JSON.stringify(bList).includes(c.user.userId));

  // Sender's GET /friends: the same request under `outgoing` (what the app shows under "Sent").
  const aList = (await t.api('GET', '/friends', null, a.token)).json;
  assert.deepEqual(aList.outgoing, [sent.json.request]);
  assert.deepEqual(shapeOf(aList), shapeOf(FIXTURE.senderFriends));

  // Accept: the sender hears FRIEND_ACCEPTED and sees a friend row the app parses.
  const acc = await t.api('POST', `/friends/requests/${sent.json.request.requestId}/accept`, null, b.token);
  assert.equal(acc.json.status, 'FRIENDS');
  const accepted = await aWs.next((m) => m.type === 'FRIEND_ACCEPTED');
  assert.equal(accepted.username, b.user.username);
  assert.deepEqual(shapeOf(accepted), shapeOf(FIXTURE.socketFriendAccepted));
  const after = (await t.api('GET', '/friends', null, a.token)).json;
  assert.deepEqual(shapeOf(after), shapeOf(FIXTURE.senderAfterAccept));
  assert.equal(after.friends[0].username, b.user.username);
  aWs.close(); bWs.close();
});

test('an unknown username or code says so instead of a silent "sent"; a block still looks like a pending request', async () => {
  const a = await t.register('Typo Sender', 'typo.sender@coroute.test');
  const b = await t.register('Typo Blocker', 'typo.blocker@coroute.test');
  const unknown = await t.api('POST', '/friends/requests', { username: 'NoSuchRider_42' }, a.token);
  assert.equal(unknown.status, 404);
  assert.deepEqual(unknown.json, FIXTURE.sendUnknown.body);
  const badCode = await t.api('POST', '/friends/requests', { inviteCode: 'ZZZZZZZZ' }, a.token);
  assert.equal(badCode.status, 404);
  assert.equal(badCode.json.code, 'NOT_FOUND');
  assert.equal((await t.api('GET', '/friends', null, a.token)).json.outgoing.length, 0);

  // b blocked a: a's request is a shadow. a sees it under "Sent" like any unanswered request;
  // b never sees it, and gets no push.
  await t.api('POST', '/blocks', { username: a.user.username }, b.token);
  const bWs = await t.connect(b.token);
  const toBlocker = await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  assert.equal(toBlocker.status, 202);
  assert.deepEqual(shapeOf(toBlocker.json), shapeOf(FIXTURE.sendByUsername.body));
  assert.deepEqual((await t.api('GET', '/friends', null, a.token)).json.outgoing.map((r) => r.username), [b.user.username]);
  assert.equal((await t.api('GET', '/friends', null, b.token)).json.incoming.length, 0);
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(bWs.inbox.filter((m) => m.type === 'FRIEND_REQUEST').length, 0, 'no push for a shadow request');

  // Unblocked: a fresh request from a reaches b normally (the block never hides later requests).
  await t.api('DELETE', `/blocks/${a.user.username}`, null, b.token);
  const again = await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  assert.equal(again.status, 202);
  const push = await bWs.next((m) => m.type === 'FRIEND_REQUEST');
  assert.equal(push.username, a.user.username);
  assert.deepEqual((await t.api('GET', '/friends', null, b.token)).json.incoming.map((r) => r.username), [a.user.username]);
  bWs.close();
});

test('the sender can cancel from "Sent"; the target then sees nothing', async () => {
  const a = await t.register('Cancel Sender', 'cancel.sender@coroute.test');
  const b = await t.register('Cancel Target', 'cancel.target@coroute.test');
  const sent = await t.api('POST', '/friends/requests', { username: b.user.username.toUpperCase() }, a.token);
  assert.equal(sent.status, 202);
  assert.equal((await t.api('DELETE', `/friends/requests/${sent.json.request.requestId}`, null, a.token)).status, 200);
  assert.equal((await t.api('GET', '/friends', null, a.token)).json.outgoing.length, 0);
  assert.equal((await t.api('GET', '/friends', null, b.token)).json.incoming.length, 0);
});

test('the friends switch is on by default', async () => {
  const a = await t.register('Switch Reader', 'switch.reader@coroute.test');
  const f = await t.api('GET', '/features', null, a.token);
  assert.equal(f.status, 200);
  assert.notEqual(f.json.flags.friends, false);
});
