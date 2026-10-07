'use strict';
process.env.NODE_ENV = 'test';
process.env.JOIN_MAX_FAILURES = '3';
process.env.JOIN_MAX_FAILURES_PER_IP = '4';
process.env.MAX_CONVOY_RIDERS = '2';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

let t, lead, convoy;
before(async () => {
  t = await boot();
  lead = await t.register('Limit Lead', 'limitlead@coroute.test');
  convoy = (await t.api('POST', '/convoys', { name: 'Limited ride' }, lead.token)).json;
  assert.ok(convoy.joinCode);
});
after(async () => { await t.gw.shutdown(); });

const join = (code, token, ip) => t.api('POST', '/convoys/join', { code }, token, { 'X-Forwarded-For': ip });
const wrongCode = () => (convoy.joinCode === '999999' ? '999998' : '999999');

test('wrong codes are limited per rider; the next try is refused even with the right code', async () => {
  const a = await t.register('Limit Guesser', 'limitguess@coroute.test');
  for (let i = 0; i < 3; i++) assert.equal((await join(wrongCode(), a.token, '198.51.100.1')).status, 404);
  const blocked = await join(convoy.joinCode, a.token, '198.51.100.1');
  assert.equal(blocked.status, 429);
  assert.equal(blocked.json.code, 'TOO_MANY_ATTEMPTS');
  assert.match(blocked.json.error, /Too many wrong codes/);
});

test('correct joins never count; the size cap applies to new riders only', async () => {
  const b = await t.register('Limit Member', 'limitmember@coroute.test');
  for (let i = 0; i < 5; i++) assert.equal((await join(convoy.joinCode, b.token, '198.51.100.2')).status, 200, 're-join ' + i);

  const c = await t.register('Limit Third', 'limitthird@coroute.test');
  const full = await join(convoy.joinCode, c.token, '198.51.100.3');
  assert.equal(full.status, 409);
  assert.equal(full.json.code, 'CONVOY_FULL');
  assert.match(full.json.error, /full \(2 riders\)/);

  // b leaves: there is room for c; then b is the newcomer and the convoy is full again.
  await t.api('POST', `/convoys/${convoy.groupId}/leave`, null, b.token);
  assert.equal((await join(convoy.joinCode, c.token, '198.51.100.3')).status, 200);
  const again = await join(convoy.joinCode, b.token, '198.51.100.2');
  assert.equal(again.status, 409);
  assert.equal(again.json.code, 'CONVOY_FULL');
});

test('wrong codes are also limited per network across accounts', async () => {
  const d = await t.register('Limit Net One', 'limitnet1@coroute.test');
  const e = await t.register('Limit Net Two', 'limitnet2@coroute.test');
  for (const u of [d, d, e, e]) assert.equal((await join(wrongCode(), u.token, '198.51.100.9')).status, 404);
  const blocked = await join(wrongCode(), e.token, '198.51.100.9');
  assert.equal(blocked.status, 429);
  // Another network is not affected.
  assert.equal((await join(wrongCode(), e.token, '198.51.100.10')).status, 404);
});
