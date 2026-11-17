'use strict';
/**
 * v3.62b intelligence database: collections added after the switch (INTEL_DB_PROFILE=extended) are copied safely
 * (pending -> both written -> copied -> migrated) and a migrated collection keeps answering from the intel store
 * even if later removed from the list; safety collections can never be moved.
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const IS = require('../src/oracle/intel_store');

test('profile and never-move list', () => {
  const ext = IS.intelCollections({ INTEL_DB_PROFILE: 'extended' });
  assert.ok(ext.has('pageviews') && ext.has('track_chunks') && ext.has('intel_raw'));
  assert.ok(!IS.intelCollections({}).has('pageviews'), 'default profile unchanged');
  const forced = IS.intelCollections({ INTEL_DB_COLLECTIONS: 'intel_raw,alerts,users,auth_sessions,geo_cache,pageviews' });
  assert.deepEqual([...forced].sort(), ['intel_raw', 'pageviews'], 'safety collections are never moved');
});

test('a collection added after the switch: mirrored, copied, then served from the intel store', async () => {
  const main = new MemorySoda(), intel = new MemorySoda();
  let t = 1_000_000; const clock = () => t;
  const state = new IS.IntelDbState({ main, clock, ttlMs: 1 });
  await state.set({ mode: 'intel', doneAt: t, migrated: ['intel_raw'] });
  const cols = new Set(['intel_raw', 'pageviews']);
  const routed = IS.routedSoda(main, intel, { state, collections: cols });
  for (let i = 0; i < 5; i++) await main.insert('pageviews', { i });
  // Before the copy: pageviews answer from main.
  assert.equal((await routed.query('pageviews', {})).length, 5);
  const mig = new IS.IntelDbMigration({ main, intel, state, collections: cols, clock, batch: 2, settleMs: 100 });
  const r1 = await mig.step();
  assert.deepEqual(r1.adding, ['pageviews']);
  await state.refresh();
  const live = await routed.insert('pageviews', { i: 99 });
  assert.ok(await intel.findOne('pageviews', { _mk: live }), 'mirrored while pending');
  assert.equal((await routed.query('pageviews', {})).length, 6, 'reads still from main while pending');
  t += 200;
  let r; for (let n = 0; n < 20; n++) { r = await mig.step(); if (r.done) break; }
  assert.deepEqual(r.added, ['pageviews']);
  await state.refresh();
  assert.equal(IS.storeFor('pageviews', 'intel', state.value, cols), 'intel');
  assert.equal((await routed.query('pageviews', {}, { limit: 50 })).length, 6, 'served from the intel store');
  assert.equal((await intel.query('pageviews', {}, { limit: 50 })).length, 6);
  // Removed from the list later: still answered from the intel store (data never "disappears").
  const routed2 = IS.routedSoda(main, intel, { state, collections: new Set(['intel_raw']) });
  await main.insert('pageviews', { stray: true });
  assert.equal((await routed2.query('pageviews', {}, { limit: 50 })).length, 6);
});

test('state from before v3.62b (no migrated list) keeps working', () => {
  const cols = new Set(['intel_raw']);
  assert.equal(IS.storeFor('intel_raw', 'intel', { mode: 'intel' }, cols), 'intel');
  assert.equal(IS.storeFor('users', 'intel', { mode: 'intel' }, cols), 'main');
  assert.equal(IS.storeFor('intel_raw', 'dual', { mode: 'dual' }, cols), 'dual');
  assert.equal(IS.storeFor('intel_raw', 'main', { mode: 'main' }, cols), 'main');
});
