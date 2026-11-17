'use strict';
/**
 * v3.62 own intelligence database (src/oracle/intel_store.js): routing by switch state, writes mirrored while
 * copying, the resumable copy, key translation after the switch, `_mk` never returned, and a full gateway with a
 * second store (consent lands there, account erase purges there, health reports both stores).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const IS = require('../src/oracle/intel_store');

function setup() {
  const main = new MemorySoda(), intel = new MemorySoda();
  let t = 1_000_000;
  const clock = () => t;
  const state = new IS.IntelDbState({ main, clock, ttlMs: 1 });
  const routed = IS.routedSoda(main, intel, { state, collections: new Set(['intel_raw', 'intel_consent']) });
  return { main, intel, state, routed, clock, tick: (ms) => { t += ms; } };
}

test('main mode: everything stays in the main store (no behaviour change)', async () => {
  const e = setup();
  await e.state.refresh();
  const k = await e.routed.insert('intel_raw', { a: 1 });
  await e.routed.insert('users', { u: 1 });
  assert.equal((await e.main.query('intel_raw', {})).length, 1);
  assert.equal((await e.intel.query('intel_raw', {})).length, 0);
  assert.equal((await e.routed.get('intel_raw', k)).a, 1);
});

test('dual mode mirrors every write; the copy finishes, switches, translates old keys and hides _mk', async () => {
  const e = setup();
  const old = [];
  for (let i = 0; i < 7; i++) old.push(await e.main.insert('intel_raw', { i, t: i }));
  await e.main.insert('intel_consent', { userId: 'u1', on: true });
  await e.main.insert('users', { u: 'never copied' });
  const mig = new IS.IntelDbMigration({ main: e.main, intel: e.intel, state: e.state, collections: new Set(['intel_raw', 'intel_consent']), clock: e.clock, batch: 3, settleMs: 100 });
  assert.equal((await mig.step()).mode, 'dual');
  // While copying: writes go to both stores, reads stay on main.
  const live = await e.routed.insert('intel_raw', { i: 99, t: 99 });
  await e.routed.replace('intel_raw', old[0], { i: 0, t: 0, changed: true });
  await e.routed.remove('intel_raw', old[1]);
  await e.routed.removeWhere('intel_raw', { i: 2 });
  assert.equal((await e.intel.findOne('intel_raw', { _mk: live })).value.i, 99, 'mirrored insert');
  assert.equal((await mig.step()).waiting, true, 'waits until both nodes mirror');
  e.tick(200);
  let r;
  for (let n = 0; n < 20; n++) { r = await mig.step(); if (r.done) break; }
  assert.equal(r.mode, 'intel');
  const rows = await e.intel.query('intel_raw', {}, { limit: 100 });
  assert.equal(rows.length, 6, '7 - 2 removed + 1 live');
  assert.equal(new Set(rows.map((x) => x.value._mk)).size, 6, 'no duplicates');
  assert.equal((await e.intel.findOne('intel_raw', { _mk: old[0] })).value.changed, true);
  assert.equal((await e.intel.query('users', {})).length, 0, 'other collections never copied');
  // Intel mode: reads from the intel store, _mk hidden, a main key from before the switch still works.
  await e.state.refresh();
  const got = await e.routed.get('intel_raw', old[3]);
  assert.equal(got.i, 3);
  assert.equal(got._mk, undefined);
  await e.routed.replace('intel_raw', old[3], { i: 3, t: 3, after: true });
  assert.equal((await e.intel.findOne('intel_raw', { _mk: old[3] })).value.after, true, 'translated key');
  const q = await e.routed.query('intel_raw', { i: 3 });
  assert.equal(q[0].value._mk, undefined);
  const nk = await e.routed.insert('intel_raw', { i: 100 });
  assert.equal((await e.main.query('intel_raw', { i: 100 })).length, 0, 'new writes only in the intel store');
  assert.equal((await e.routed.get('intel_raw', nk)).i, 100);
  assert.equal((await mig.step()).done, true, 'later runs do nothing');
});

test('full gateway with its own intelligence database: consent there, erase purges there, health reports it', async () => {
  const { boot } = require('./_helpers');
  const intelSoda = new MemorySoda();
  const t = await boot({ intelSoda });
  try {
    assert.ok(t.gw.intelDb, 'second store wired');
    await t.gw.intelDb.state.set({ mode: 'intel', doneAt: Date.now() });
    const u = await t.register('Intel Db', 'inteldb@coroute.test');
    const r = await t.api('PUT', '/intel/consent', { on: true }, u.token);
    assert.equal(r.status, 200);
    assert.equal((await intelSoda.query('intel_consent', { userId: u.user.userId })).length, 1, 'stored in the intel database');
    assert.equal((await t.gw.intelDb.main.query('intel_consent', { userId: u.user.userId })).length, 0, 'not in the main database');
    assert.equal((await t.api('GET', '/intel/consent', null, u.token)).json.on, true);
    const h = await t.api('GET', '/health');
    assert.equal(h.json.intel.database.separate, true);
    assert.equal(h.json.intel.database.mode, 'intel');
    assert.equal(h.json.intel.database.intelDb, 'UP');
    await t.gw.repo.deleteUserCascade(await t.gw.repo.findUserById(u.user.userId), {});
    assert.equal((await intelSoda.query('intel_consent', { userId: u.user.userId })).length, 0, 'account erase purges the intel database');
  } finally { await t.gw.shutdown(); }
});
