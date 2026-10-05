'use strict';
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw;
after(async () => gw && gw.shutdown());

test('the app build of each active rider is recorded so the minimum build can be raised safely', async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  const reg = async (n) => (await gw.auth.register({ name: n, email: `${n.toLowerCase()}@coroute.test`, password: 'Password#123', phone: '9999999999' })).user.userId;
  const a = await reg('Arun'), b = await reg('Bindu'), c = await reg('Chitra'), d = await reg('Dev');
  const now = Date.now();
  await gw.auth.me(a, { appBuild: 66, now });
  await gw.auth.me(b, { appBuild: 65, now });
  await gw.auth.me(c, { now }); // an older app sends no build
  await gw.auth.me(d, { appBuild: 66, now: now - 40 * 86400000 }); // not active in the last 30 days
  await gw.auth.me(a, { appBuild: 'x', now }); // junk is ignored, the build stays

  const r = await gw.auth.appBuilds({ days: 30, now, minBuild: 60, latestBuild: 66 });
  assert.equal(r.total, 3);
  assert.equal(r.older, 1);
  assert.deepEqual(r.builds, [{ build: 66, users: 1 }, { build: 65, users: 1 }]);
  assert.equal(r.onLatest, 1);
  assert.deepEqual(r.lockout, [{ build: 66, wouldLockOut: 2 }, { build: 65, wouldLockOut: 1 }]);
  assert.equal((await gw.repo.findUserById(a)).appBuild, 66);
});
