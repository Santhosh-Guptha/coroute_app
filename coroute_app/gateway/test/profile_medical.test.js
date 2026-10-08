'use strict';
/**
 * 3.14 optional medical info and the emergency-text opt-out in the profile: validation, returned
 * only to the owner, never in admin lists, and never cleared by an older app's profile save.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'medadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('medical fields and smsOptOut are validated', async () => {
  const u = await t.register('Med Valid', 'medvalid@coroute.test');
  assert.equal(u.user.bloodGroup, '', 'registration returns the owner view');
  assert.equal(u.user.smsOptOut, false);
  const patch = (body) => t.api('PATCH', '/me', body, u.token);

  const ok = await patch({ bloodGroup: 'ab-', allergies: '  Penicillin,  peanuts ', medicalNotes: 'Diabetic. Sugar in the tank bag.', smsOptOut: true });
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(ok.json.bloodGroup, 'AB-');
  assert.equal(ok.json.allergies, 'Penicillin, peanuts');
  assert.equal(ok.json.medicalNotes, 'Diabetic. Sugar in the tank bag.');
  assert.equal(ok.json.smsOptOut, true);

  const bad = [
    [{ bloodGroup: 'Z+' }, 'bloodGroup'],
    [{ bloodGroup: 'O' }, 'bloodGroup'],
    [{ allergies: 'a'.repeat(121) }, 'allergies'],
    [{ medicalNotes: 'n'.repeat(201) }, 'medicalNotes'],
    [{ medicalNotes: 'line one\nline two' }, 'medicalNotes'],
    [{ allergies: 'bell\u0007' }, 'allergies'],
    [{ allergies: 'hidden‮text' }, 'allergies'],
    [{ allergies: { x: 1 } }, 'allergies'],
    [{ medicalNotes: ['a'] }, 'medicalNotes'],
    [{ smsOptOut: 'yes' }, 'smsOptOut'],
    [{ smsOptOut: 1 }, 'smsOptOut'],
  ];
  for (const [body, field] of bad) {
    const r = await patch(body);
    assert.equal(r.status, 422, `${JSON.stringify(body)} -> ${r.status}`);
    assert.ok(r.json.fields && r.json.fields[field], JSON.stringify(r.json));
  }
  assert.equal((await patch({ smsOptOut: 'yes' })).json.error, 'This field must be on or off.');
  assert.equal((await patch({ allergies: 'a'.repeat(120), medicalNotes: 'n'.repeat(200) })).status, 200, 'limits are inclusive');

  // Empty clears; the blood group may be blank.
  const cleared = await patch({ bloodGroup: '', allergies: '', medicalNotes: '', smsOptOut: false });
  assert.equal(cleared.status, 200);
  assert.deepEqual([cleared.json.bloodGroup, cleared.json.allergies, cleared.json.medicalNotes, cleared.json.smsOptOut], ['', '', '', false]);
});

test('GET /me, login and PATCH return the medical info to the owner; admin lists and details do not', async () => {
  const u = await t.register('Med Owner', 'medowner@coroute.test');
  const admin = await t.register('Med Admin', 'medadmin@coroute.test');
  await t.api('PATCH', '/me', { bloodGroup: 'B+', allergies: 'Sulfa drugs', medicalNotes: 'Pacemaker', smsOptOut: true }, u.token);

  const me = await t.api('GET', '/me', null, u.token);
  assert.equal(me.status, 200);
  assert.equal(me.json.bloodGroup, 'B+');
  assert.equal(me.json.allergies, 'Sulfa drugs');
  assert.equal(me.json.medicalNotes, 'Pacemaker');
  assert.equal(me.json.smsOptOut, true);
  const login = await t.api('POST', '/auth/login', { identifier: 'medowner@coroute.test', password: 'Password#123' });
  assert.equal(login.json.user.allergies, 'Sulfa drugs');

  const list = await t.api('GET', '/admin/users', null, admin.token);
  assert.equal(list.status, 200);
  const details = await t.api('GET', `/admin/users/${u.user.userId}/details`, null, admin.token);
  assert.equal(details.status, 200);
  for (const res of [list, details]) {
    const text = JSON.stringify(res.json);
    assert.ok(!text.includes('Sulfa drugs') && !text.includes('Pacemaker'), 'no medical info for admins');
    assert.ok(!text.includes('bloodGroup') && !text.includes('smsOptOut'));
  }
  // Admin's own /me is the owner view of the admin, not of anyone else.
  const adminMe = await t.api('GET', '/me', null, admin.token);
  assert.ok(!JSON.stringify(adminMe.json).includes('Sulfa'));
});

test('a profile save from an older app (old keys only) keeps the medical info and the opt-out', async () => {
  const u = await t.register('Med Old', 'medold@coroute.test');
  await t.api('PATCH', '/me', { bloodGroup: 'O-', allergies: 'Latex', smsOptOut: true }, u.token);
  const old = await t.api('PATCH', '/me', {
    name: 'Med Old', phone: '+919876512345', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB0001',
    emergencyContact: '+919000000002', emergencyContactName: 'New Contact',
  }, u.token);
  assert.equal(old.status, 200, JSON.stringify(old.json));
  assert.equal(old.json.bloodGroup, 'O-');
  assert.equal(old.json.allergies, 'Latex');
  assert.equal(old.json.smsOptOut, true);
  // null means "not sent" as well.
  const nulls = await t.api('PATCH', '/me', { bloodGroup: null, allergies: null, medicalNotes: null, smsOptOut: null }, u.token);
  assert.equal(nulls.status, 200);
  assert.equal(nulls.json.allergies, 'Latex');
  const stored = await t.gw.repo.findUserById(u.user.userId);
  assert.equal(stored.bloodGroup, 'O-');
  assert.equal(stored.smsOptOut, true);
});
