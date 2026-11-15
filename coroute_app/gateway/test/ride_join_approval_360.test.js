'use strict';
/**
 * v3.60: join codes are letters and digits (no look-alikes) and a rider joining by code waits for the host (or the
 * ride head) to let them in. Approved riders and riders invited from a community join directly.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const config = require('../src/config');
const { boot } = require('./_helpers');

let t;
before(async () => { config.rideJoinApproval = true; t = await boot(); });
after(async () => { config.rideJoinApproval = false; await t.gw.shutdown(); });

test('join by code waits for the host; approve lets the rider in, decline refuses for a while', async () => {
  const host = await t.register('Host Rider', 'host.approval@coroute.test');
  const asker = await t.register('Asker Rider', 'asker.approval@coroute.test');
  const other = await t.register('Other Rider', 'other.approval@coroute.test');
  const created = await t.api('POST', '/convoys', { name: 'Sunday loop', rider: { lat: 12.97, lng: 77.59 } }, host.token);
  assert.equal(created.status, 201, JSON.stringify(created.json));
  const { groupId, joinCode } = created.json;
  assert.match(joinCode, /^[A-HJKMNP-Z2-9]{6}$/);
  assert.ok(/[A-Z]/.test(joinCode) && /\d/.test(joinCode), 'letters and digits');

  const hostWs = await t.joinRoom(host.token, groupId);
  const askerWs = await t.connect(asker.token);

  const p = await t.api('POST', '/convoys/join', { code: joinCode.toLowerCase() }, asker.token);
  assert.deepEqual([p.status, p.json.status, p.json.groupId], [202, 'PENDING', groupId]);
  assert.equal(p.json.riders, undefined, 'no ride details before approval');
  const ev = await hostWs.next((m) => m.type === 'JOIN_REQUEST');
  assert.equal(ev.userId, asker.user.userId);
  assert.equal(ev.name, 'Asker');
  const snap = await t.api('GET', `/convoys/${groupId}`, null, host.token);
  assert.equal(snap.json.pendingMembers[asker.user.userId], 'Asker');
  assert.equal((await t.api('GET', `/convoys/${groupId}`, null, asker.token)).status, 403, 'not a member yet');

  // Asking again keeps one request; only the host / head can decide.
  assert.equal((await t.api('POST', '/convoys/join', { code: joinCode }, asker.token)).status, 202);
  assert.equal((await t.api('POST', `/convoys/${groupId}/join-requests/${asker.user.userId}`, { approve: true }, other.token)).status, 403);

  const ok = await t.api('POST', `/convoys/${groupId}/join-requests/${asker.user.userId}`, { approve: true }, host.token);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  await askerWs.next((m) => m.type === 'JOIN_APPROVED' && m.groupId === groupId);
  const joined = await t.api('POST', '/convoys/join', { code: joinCode }, asker.token);
  assert.equal(joined.status, 200);
  assert.ok(joined.json.riders[asker.user.userId], 'in the ride');
  assert.deepEqual(joined.json.pendingMembers, {});

  // Decline.
  const otherWs = await t.connect(other.token);
  assert.equal((await t.api('POST', '/convoys/join', { code: joinCode }, other.token)).status, 202);
  const no = await t.api('POST', `/convoys/${groupId}/join-requests/${other.user.userId}`, { approve: false }, host.token);
  assert.equal(no.json.approved, false);
  await otherWs.next((m) => m.type === 'JOIN_DECLINED');
  const again = await t.api('POST', '/convoys/join', { code: joinCode }, other.token);
  assert.deepEqual([again.status, again.json.code], [403, 'JOIN_DECLINED']);
  assert.equal((await t.api('POST', `/convoys/${groupId}/join-requests/${other.user.userId}`, { approve: true }, host.token)).status, 404, 'no longer waiting');
  hostWs.close(); askerWs.close(); otherWs.close();
});

test('meet first: the ride gathers at the start; only the host starts it from there or moves the meeting point', async () => {
  const host = await t.register('Gather Host', 'gather.host@coroute.test');
  const other = await t.register('Gather Other', 'gather.other@coroute.test');
  const start = { lat: 12.9716, lng: 77.5946, name: 'Hebbal flyover' };
  const created = await t.api('POST', '/convoys', { name: 'Meet first', start, gathering: true, rider: { lat: 12.9, lng: 77.5 } }, host.token);
  assert.equal(created.status, 201, JSON.stringify(created.json));
  assert.deepEqual(created.json.gathering, { ...start, startedAt: 0 });
  const plain = await t.api('POST', '/convoys', { name: 'No gather', rider: { lat: 12.9, lng: 77.5 } }, other.token);
  assert.equal(plain.json.gathering, null);
  const gid = created.json.groupId;
  assert.equal((await t.api('POST', `/convoys/${gid}/gathering`, { start: true }, other.token)).status, 403);
  const moved = await t.api('POST', `/convoys/${gid}/gathering`, { meetingPoint: { lat: 13.0, lng: 77.6, name: 'Yelahanka' } }, host.token);
  assert.equal(moved.json.gathering.name, 'Yelahanka');
  const go = await t.api('POST', `/convoys/${gid}/gathering`, { start: true }, host.token);
  assert.ok(go.json.gathering.startedAt > 0);
  assert.equal((await t.api('POST', `/convoys/${gid}/gathering`, { start: true }, host.token)).json.code, 'ALREADY_STARTED');
  const snap = await t.api('GET', `/convoys/${gid}`, null, host.token);
  assert.ok(snap.json.gathering.startedAt > 0);
});
