'use strict';
/**
 * 3.55 bike summary in the profile (engine care and fuel analysis): validated server side,
 * returned to the owner, shown in the admin rider detail, never in public/admin list views.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'bikeadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { bikeFields } = require('../src/validate');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('bikeFields validates types, ranges and control characters', () => {
  assert.deepEqual(bikeFields({}), {});
  assert.deepEqual(bikeFields({ bikeModel: '  Classic   350 ', bikeCc: 349, bikeColour: 'Gunmetal Grey', bikeTankL: 13, bikeMileageKmL: 35.25, bikeCooling: 'oil' }),
    { bikeModel: 'Classic 350', bikeCc: 349, bikeColour: 'Gunmetal Grey', bikeTankL: 13, bikeMileageKmL: 35.3, bikeCooling: 'oil' });
  // Clearing.
  assert.deepEqual(bikeFields({ bikeModel: null, bikeCc: 0, bikeColour: '', bikeTankL: null, bikeMileageKmL: 0, bikeCooling: null }),
    { bikeModel: '', bikeCc: 0, bikeColour: '', bikeTankL: 0, bikeMileageKmL: 0, bikeCooling: 'unknown' });
  const bad = [
    { bikeModel: 'm'.repeat(61) }, { bikeModel: 'line\nbreak' }, { bikeModel: 5 }, { bikeModel: { a: 1 } },
    { bikeColour: 'c'.repeat(31) }, { bikeColour: 'red‮' },
    { bikeCc: 49 }, { bikeCc: 2501 }, { bikeCc: 349.5 }, { bikeCc: 'big' }, { bikeCc: true }, { bikeCc: -100 },
    { bikeTankL: 1.5 }, { bikeTankL: 41 }, { bikeTankL: Infinity },
    { bikeMileageKmL: 1.5 }, { bikeMileageKmL: 121 },
    { bikeCooling: 'water' }, { bikeCooling: 1 },
  ];
  for (const b of bad) {
    assert.throws(() => bikeFields(b), (e) => e.name === 'ValidationError' && Object.keys(e.fields).length === 1, JSON.stringify(b));
  }
  // Limits are inclusive.
  assert.deepEqual(bikeFields({ bikeCc: 50, bikeTankL: 2, bikeMileageKmL: 120 }), { bikeCc: 50, bikeTankL: 2, bikeMileageKmL: 120 });
  assert.deepEqual(bikeFields({ bikeMileageKmL: 2 }), { bikeMileageKmL: 2 }, 'electric km/kWh');
  assert.deepEqual(bikeFields({ bikeCc: 2500, bikeTankL: 40, bikeMileageKmL: 5 }), { bikeCc: 2500, bikeTankL: 40, bikeMileageKmL: 5 });
});

test('PATCH /me stores the bike summary for the owner; admin detail shows it; lists do not', async () => {
  const u = await t.register('Bike Owner', 'bikeowner@coroute.test');
  const admin = await t.register('Bike Admin', 'bikeadmin@coroute.test');
  assert.equal(u.user.bikeModel, '', 'empty summary for a new rider');
  assert.equal(u.user.bikeCc, 0);
  assert.equal(u.user.bikeCooling, 'unknown');
  const patch = (body) => t.api('PATCH', '/me', body, u.token);

  const ok = await patch({ bikeModel: 'Himalayan 450', bikeCc: 452, bikeColour: 'Kaza Brown', bikeTankL: 17, bikeMileageKmL: 28, bikeCooling: 'liquid' });
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.deepEqual([ok.json.bikeModel, ok.json.bikeCc, ok.json.bikeColour, ok.json.bikeTankL, ok.json.bikeMileageKmL, ok.json.bikeCooling],
    ['Himalayan 450', 452, 'Kaza Brown', 17, 28, 'liquid']);

  // A bad value is refused and nothing is written.
  const bad = await patch({ bikeCc: 5000, name: 'Bike Owner Two' });
  assert.equal(bad.status, 422);
  assert.ok(bad.json.fields.bikeCc);
  const me = await t.api('GET', '/me', null, u.token);
  const mine = me.json.user || me.json;
  assert.equal(mine.bikeCc, 452);
  assert.equal(mine.name, 'Bike Owner');

  // An older app's save (no bike keys) keeps the summary.
  const older = await patch({ vehicleType: 'Adventure' });
  assert.equal(older.status, 200);
  assert.equal(older.json.bikeModel, 'Himalayan 450');

  // Admin: rider detail has a bike block; the user list (publicUser) has none of it.
  const detail = await t.api('GET', `/admin/analytics/riders/${u.user.userId}`, null, admin.token);
  assert.equal(detail.status, 200, JSON.stringify(detail.json));
  assert.deepEqual(detail.json.rider.bike, { model: 'Himalayan 450', cc: 452, colour: 'Kaza Brown', tankL: 17, mileageKmL: 28, cooling: 'liquid' });
  const list = await t.api('GET', '/admin/users', null, admin.token);
  if (list.status === 200) {
    const rows = list.json.users || list.json;
    const row = (Array.isArray(rows) ? rows : []).find((r) => r.userId === u.user.userId);
    if (row) assert.equal(row.bikeModel, undefined, 'admin lists keep riders minimal');
  }

  // Clearing.
  const cleared = await patch({ bikeModel: '', bikeCc: 0, bikeColour: null, bikeTankL: 0, bikeMileageKmL: null, bikeCooling: 'unknown' });
  assert.equal(cleared.status, 200);
  assert.deepEqual([cleared.json.bikeModel, cleared.json.bikeCc, cleared.json.bikeColour, cleared.json.bikeTankL, cleared.json.bikeMileageKmL, cleared.json.bikeCooling],
    ['', 0, '', 0, 0, 'unknown']);
  const after = await t.api('GET', `/admin/analytics/riders/${u.user.userId}`, null, admin.token);
  assert.equal(after.json.rider.bike, null);
});
