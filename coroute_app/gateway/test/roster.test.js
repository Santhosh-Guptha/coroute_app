'use strict';
/**
 * 3.14 emergency SMS roster: other riders' numbers (no names, no emergency contacts of others),
 * opt-outs and the caller excluded, own emergency contact included; members of a live ride only.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'rosteradmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

const roster = (gid, token) => t.api('GET', `/convoys/${gid}/emergency-roster`, null, token);

test('a rider gets the other riders\' numbers only, without opt-outs, names or their emergency contacts', async () => {
  const lead = await t.register('Roster Lead', 'rlead@coroute.test', { phone: '+91 98765 00001', emergencyContact: '+91 90000 11111', emergencyContactName: 'Lead Mother' });
  const asha = await t.register('Roster Asha', 'rasha@coroute.test', { phone: '+91 98765 00002', emergencyContact: '+91 90000 22222', emergencyContactName: 'Asha Brother' });
  const bala = await t.register('Roster Bala', 'rbala@coroute.test', { phone: '+91 98765 00003' });
  const twin = await t.register('Roster Twin', 'rtwin@coroute.test', { phone: '+91 98765 00001' }); // shares the lead's number
  const outsider = await t.register('Roster Outsider', 'routsider@coroute.test');
  const admin = await t.register('Roster Admin', 'rosteradmin@coroute.test');
  assert.equal((await t.api('PATCH', '/me', { smsOptOut: true }, bala.token)).json.smsOptOut, true);

  const c = (await t.api('POST', '/convoys', { name: 'Roster ride' }, lead.token)).json;
  for (const u of [asha, bala, twin]) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);

  const res = await roster(c.groupId, asha.token);
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const body = res.json;
  assert.equal(body.groupId, c.groupId);
  assert.equal(body.cap, 10);
  assert.ok(body.validUntil - body.generatedAt === 12 * 3600000);
  assert.deepEqual(body.members, [{ userId: lead.user.userId, role: 'LEAD', phone: '+91 98765 00001' }], 'lead only: Bala opted out, the twin number is a duplicate, Asha is the caller');
  assert.deepEqual(body.emergencyContact, { name: 'Asha Brother', phone: '+91 90000 22222' });
  const text = JSON.stringify(body);
  for (const secret of ['Roster Lead', 'Lead Mother', '+91 90000 11111', '+91 98765 00003', '+91 98765 00002', 'vehicle', 'name":"Roster']) {
    assert.ok(!text.includes(secret), `roster must not contain ${secret}`);
  }

  // The lead sees Asha (and not the twin's number, which is the lead's own).
  const forLead = (await roster(c.groupId, lead.token)).json;
  assert.deepEqual(forLead.members.map((m) => m.userId), [asha.user.userId]);
  assert.equal(forLead.emergencyContact.name, 'Lead Mother');

  // Not a member, or an admin: 403 with NOT_MEMBER.
  const no = await roster(c.groupId, outsider.token);
  assert.equal(no.status, 403);
  assert.equal(no.json.code, 'NOT_MEMBER');
  assert.equal(no.headers.get('cache-control'), 'no-store');
  assert.equal((await roster(c.groupId, admin.token)).status, 403);
  assert.equal((await roster('GRP-NOPE', asha.token)).status, 403);
  assert.equal((await roster('x'.repeat(200), asha.token)).status, 403);
  assert.equal((await t.api('GET', `/convoys/${c.groupId}/emergency-roster`)).status, 401);

  // Opt-out changes mid-ride: the room hears ROSTER_CHANGED and the next roster includes Bala.
  const wa = await t.joinRoom(asha.token, c.groupId);
  const wb = await t.joinRoom(bala.token, c.groupId);
  assert.equal((await t.api('PATCH', '/me', { smsOptOut: false }, bala.token)).status, 200);
  await wa.next((m) => m.type === 'ROSTER_CHANGED');
  assert.ok((await roster(c.groupId, asha.token)).json.members.some((m) => m.userId === bala.user.userId && m.phone === '+91 98765 00003'));
  // An unrelated profile change sends nothing.
  wa.inbox.length = 0;
  assert.equal((await t.api('PATCH', '/me', { vehicleType: 'Scooter' }, bala.token)).status, 200);
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(wa.inbox.filter((m) => m.type === 'ROSTER_CHANGED').length, 0);
  // A new phone number reaches the ride too.
  assert.equal((await t.api('PATCH', '/me', { phone: '+91 98765 00009' }, bala.token)).status, 200);
  await wa.next((m) => m.type === 'ROSTER_CHANGED');
  const after = (await roster(c.groupId, lead.token)).json; // lead: 3rd call of 6
  assert.ok(after.members.some((m) => m.phone === '+91 98765 00009'));
  assert.ok(!JSON.stringify(after).includes('+91 98765 00003'));
  // The opt-out is never sent to other riders.
  const snap = (await t.api('GET', `/convoys/${c.groupId}`, null, lead.token)).json;
  assert.ok(!JSON.stringify(snap).includes('smsOptOut'));
  wa.close(); wb.close();

  // Paused ride still works; planning and ended rides answer 409.
  await t.api('POST', `/convoys/${c.groupId}/status`, { status: 'PAUSED' }, lead.token);
  assert.equal((await roster(c.groupId, twin.token)).status, 200);
  await t.api('POST', `/convoys/${c.groupId}/status`, { status: 'PLANNING' }, lead.token);
  const planning = await roster(c.groupId, twin.token);
  assert.equal(planning.status, 409);
  assert.equal(planning.json.code, 'RIDE_NOT_ACTIVE');
  await t.api('POST', `/convoys/${c.groupId}/status`, { status: 'ENDED' }, lead.token);
  const ended = await roster(c.groupId, twin.token);
  assert.equal(ended.status, 409);
  assert.equal(ended.json.code, 'RIDE_NOT_ACTIVE');
  assert.equal(t.gw.convoys.rooms.has(c.groupId), false, 'an ended convoy is not loaded back into memory');
  assert.equal((await roster(c.groupId, outsider.token)).status, 403);
});

test('the roster is limited to 6 calls per rider per minute', async () => {
  const lead = await t.register('Limit Lead', 'limitlead@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Limit ride' }, lead.token)).json;
  for (let i = 0; i < 6; i++) assert.equal((await roster(c.groupId, lead.token)).status, 200, `call ${i + 1}`);
  const seventh = await roster(c.groupId, lead.token);
  assert.equal(seventh.status, 429);
  assert.equal(seventh.headers.get('cache-control'), 'no-store');
});
