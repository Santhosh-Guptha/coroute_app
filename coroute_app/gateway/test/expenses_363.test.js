'use strict';
/**
 * v3.63 trip planning lite: expense split per ride (src/expenses.js). Records only, members only, exact paise,
 * shortest settle-up list, creator-only edit / delete, double-tap safe, 30 days open after the ride, account erase.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const X = require('../src/expenses');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });
let n = 0;
const reg = async (name) => { n++; return t.register(name, `exp${n}@coroute.test`); };

test('pure: paise, equal shares, balances, settle-up', () => {
  assert.equal(X.toPaise('12.50'), 1250);
  assert.equal(X.toPaise(0.1), 10);
  assert.equal(X.toPaise('1.234'), null);
  assert.equal(X.toPaise(-1), null);
  assert.equal(X.toPaise(0), null);
  const s = X.equalShares(1000, ['a', 'b', 'c']);
  assert.deepEqual(s, { a: 334, b: 333, c: 333 });
  const rows = [
    { kind: 'expense', paidBy: 'a', amount: 3000, shares: { a: 1000, b: 1000, c: 1000 } },
    { kind: 'expense', paidBy: 'b', amount: 600, shares: { a: 200, b: 200, c: 200 } },
  ];
  const bal = X.balancesOf(rows);
  assert.deepEqual(bal, { a: 1800, b: -600, c: -1200 });
  const plan = X.settleUp(bal);
  assert.deepEqual(plan, [{ from: 'c', to: 'a', amount: 1200 }, { from: 'b', to: 'a', amount: 600 }]);
  const after = X.balancesOf([...rows, { kind: 'settle', from: 'c', to: 'a', amount: 1200 }, { kind: 'settle', from: 'b', to: 'a', amount: 600 }]);
  assert.deepEqual(after, {}, 'all settled');
});

test('API: members add, split, settle; strangers refused; creator-only edits; double tap safe', async () => {
  const a = await reg('Anu Rao'); const b = await reg('Ravi K'); const c = await reg('Meera S'); const x = await reg('Stranger Z');
  const ride = (await t.api('POST', '/convoys', { name: 'Coorg weekend' }, a.token)).json;
  for (const u of [b, c]) assert.equal((await t.api('POST', '/convoys/join', { code: ride.joinCode }, u.token)).status, 200);
  const base = `/convoys/${ride.groupId}/expenses`;
  const ws = await t.joinRoom(b.token, ride.groupId);

  assert.equal((await t.api('GET', base, null, x.token)).status, 403, 'not a rider of this ride');
  const e1 = await t.api('POST', base, { what: 'Fuel', amount: 30, split: { mode: 'equal', among: [a.user.userId, b.user.userId, c.user.userId] } }, a.token);
  assert.equal(e1.status, 200, JSON.stringify(e1.json));
  await ws.next((m) => m.type === 'EXPENSES_CHANGED');
  const again = await t.api('POST', base, { what: 'Fuel', amount: 30, split: { mode: 'equal', among: [a.user.userId, b.user.userId, c.user.userId] } }, a.token);
  assert.equal(again.json.duplicate, true, 'a double tap adds it once');
  const bad = await t.api('POST', base, { what: 'Food', amount: 10, split: { mode: 'custom', shares: { [a.user.userId]: 3, [b.user.userId]: 3 } } }, b.token);
  assert.equal(bad.json.code, 'SPLIT_SUM');
  const e2 = await t.api('POST', base, { what: 'Food', amount: 6, paidBy: b.user.userId, split: { mode: 'custom', shares: { [a.user.userId]: 2, [b.user.userId]: 2, [c.user.userId]: 2 } } }, b.token);
  assert.equal(e2.status, 200);
  assert.equal((await t.api('POST', base, { what: 'Toll', amount: 5, paidBy: x.user.userId }, a.token)).json.code, 'BAD_PAYER');

  let list = (await t.api('GET', base, null, c.token)).json;
  assert.equal(list.expenses.length, 2);
  assert.equal(list.totalSpent, 36);
  const bal = Object.fromEntries(list.balances.map((v) => [v.name, v.amount]));
  assert.deepEqual(bal, { Anu: 18, Ravi: -6, Meera: -12 });
  assert.equal(list.settleUp.length, 2);
  assert.equal(list.settleUp[0].fromName, 'Meera');

  assert.equal((await t.api('PUT', `${base}/${e1.json.id}`, { what: 'Fuel', amount: 33 }, b.token)).status, 403, 'only the creator edits');
  assert.equal((await t.api('DELETE', `${base}/${e1.json.id}`, null, b.token)).status, 403, 'only the creator deletes');
  assert.equal((await t.api('POST', `${base}/settle`, { from: c.user.userId, to: a.user.userId, amount: 12 }, b.token)).status, 403, 'only the two riders involved');
  const st = await t.api('POST', `${base}/settle`, { from: c.user.userId, to: a.user.userId, amount: 12 }, c.token);
  assert.equal(st.status, 200);
  list = (await t.api('GET', base, null, a.token)).json;
  assert.deepEqual(list.settleUp.map((s) => [s.fromName, s.toName, s.amount]), [['Ravi', 'Anu', 6]]);
  assert.equal((await t.api('DELETE', `${base}/settle/${st.json.id}`, null, c.token)).status, 200, 'undo own settlement');
  ws.close();
});

test('after the ride: open for 30 days for its riders, then read-only, removed after 90 days', async () => {
  const a = await reg('Kiran M');
  const ride = (await t.api('POST', '/convoys', { name: 'Solo test' }, a.token)).json;
  const svc = new X.ExpenseService({ soda: gw.repo.soda, convoys: gw.convoys });
  await svc.add(ride.groupId, a.user.userId, { what: 'Snacks', amount: 4 });
  // The ride is gone from memory: the meta answers.
  const gone = new X.ExpenseService({ soda: gw.repo.soda, convoys: { getRoom: async () => null, rooms: new Map() } });
  assert.equal((await gone.list(ride.groupId, a.user.userId)).canEdit, true);
  const meta = await gw.repo.soda.findOne(X.COLL, { groupId: ride.groupId, kind: 'meta' });
  await gw.repo.soda.replace(X.COLL, meta.key, { ...meta.value, lastLiveAt: Date.now() - 31 * 86400000 });
  assert.equal((await gone.list(ride.groupId, a.user.userId)).canEdit, false);
  await assert.rejects(gone.add(ride.groupId, a.user.userId, { what: 'Late', amount: 1 }), (e) => e.code === 'CLOSED');
  await gw.repo.soda.replace(X.COLL, meta.key, { ...meta.value, lastLiveAt: Date.now() - 91 * 86400000 });
  await gone.sweep();
  assert.equal((await gw.repo.soda.query(X.COLL, { groupId: ride.groupId })).length, 0);
});

test('account erase: own records removed, name replaced in other rides', async () => {
  const a = await reg('Erase Me'); const b = await reg('Stay Here');
  const ride = (await t.api('POST', '/convoys', { name: 'Erase ride' }, b.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: ride.joinCode }, a.token)).status, 200);
  await t.api('POST', `/convoys/${ride.groupId}/expenses`, { what: 'Tea', amount: 2 }, a.token);
  await t.api('GET', `/convoys/${ride.groupId}/expenses`, null, b.token);
  const svc = new X.ExpenseService({ soda: gw.repo.soda, convoys: gw.convoys });
  await svc.forgetUser(a.user.userId);
  const rows = await gw.repo.soda.query(X.COLL, { groupId: ride.groupId });
  assert.equal(rows.filter((r) => r.value.by === a.user.userId).length, 0);
  const meta = rows.find((r) => r.value.kind === 'meta');
  assert.equal(meta.value.members[a.user.userId], 'Deleted rider');
});

test('weather at stops: MET wind speed is carried as km/h (v3.63)', () => {
  const { cellOf } = require('../src/weather_met');
  const t0 = '2026-11-17T06:00:00Z';
  const cell = cellOf({ properties: { timeseries: [{ time: t0, data: { instant: { details: { air_temperature: 27.4, wind_speed: 4.2 } }, next_1_hours: { summary: { symbol_code: 'cloudy' }, details: { precipitation_amount: 0 } } } }] } });
  assert.equal(cell.winds[0], 15, '4.2 m/s = 15 km/h');
  assert.equal(cell.temps[0], 27.4);
});
