'use strict';
/**
 * 3.56 bike details once: the profile keeps the whole bike (model, confirmed type, fuel, cc,
 * colour, tank, mileage incl. electric km/kWh), so a reinstalled app or a second phone restores
 * the garage bike instead of asking for the details again. A partial save never wipes the rest.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { bikeFields } = require('../src/validate');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

const pick = (u) => ({
  bikeModel: u.bikeModel, bikeCc: u.bikeCc, bikeColour: u.bikeColour, bikeTankL: u.bikeTankL,
  bikeMileageKmL: u.bikeMileageKmL, bikeCooling: u.bikeCooling, bikeType: u.bikeType, bikeFuel: u.bikeFuel,
});

test('bikeFields: bike type and fuel are checked against the lists; empty clears', () => {
  assert.deepEqual(bikeFields({ bikeType: 'retro', bikeFuel: 'petrol' }), { bikeType: 'retro', bikeFuel: 'petrol' });
  assert.deepEqual(bikeFields({ bikeType: '', bikeFuel: null }), { bikeType: '', bikeFuel: '' });
  for (const b of [{ bikeType: 'tractor' }, { bikeType: 3 }, { bikeFuel: 'steam' }, { bikeFuel: true }]) {
    assert.throws(() => bikeFields(b), (e) => e.name === 'ValidationError', JSON.stringify(b));
  }
});

test('the whole bike round-trips through /me and survives partial and older-app saves', async () => {
  const u = await t.register('Once Rider', 'oncerider@coroute.test');
  assert.equal(u.user.bikeType, '', 'new rider: no type yet');
  assert.equal(u.user.bikeFuel, '');
  const patch = (body) => t.api('PATCH', '/me', body, u.token);
  const me = async () => { const r = await t.api('GET', '/me', null, u.token); return r.json.user || r.json; };

  const full = { bikeModel: 'Royal Enfield Classic 350', bikeCc: 349, bikeColour: 'Red', bikeTankL: 13, bikeMileageKmL: 35, bikeCooling: 'oil', bikeType: 'retro', bikeFuel: 'petrol' };
  const ok = await patch(full);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.deepEqual(pick(ok.json), full);
  assert.deepEqual(pick(await me()), full, 'GET /me returns every field (what a new install restores)');

  // Only what changed is sent by the app: the rest stays.
  assert.equal((await patch({ bikeColour: 'Black' })).status, 200);
  assert.deepEqual(pick(await me()), { ...full, bikeColour: 'Black' });
  // An older app's profile save (no bike keys) keeps the bike.
  assert.equal((await patch({ vehicleType: 'Cruiser' })).status, 200);
  assert.deepEqual(pick(await me()), { ...full, bikeColour: 'Black' });

  // Electric: mileage in km/kWh (below the petrol minimum), no engine size or tank.
  const ev = { bikeModel: 'Ather 450X', bikeCc: 0, bikeColour: 'White', bikeTankL: 0, bikeMileageKmL: 22, bikeCooling: 'unknown', bikeType: 'electric', bikeFuel: 'ev' };
  assert.equal((await patch(ev)).status, 200);
  assert.deepEqual(pick(await me()), ev);
  assert.equal((await patch({ bikeMileageKmL: 3 })).status, 200, '3 km/kWh is a valid electric mileage');
  assert.equal((await me()).bikeMileageKmL, 3);

  // A bad type is refused and nothing is written.
  const bad = await patch({ bikeType: 'spaceship', bikeColour: 'Green' });
  assert.equal(bad.status, 422);
  assert.equal((await me()).bikeColour, 'White');
});
