'use strict';
process.env.NODE_ENV = 'test';

// The real SODA REST API returns at most 1000 documents per query. Analytics,
// the admin users list and the payments ledger must page past that, and say
// when a scan cap was reached instead of showing a partial count as complete.
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { scan, publicUsage, median } = require('../src/admin_analytics');

/** MemorySoda with the REST page cap of the real service. */
class CappedSoda extends MemorySoda {
  async query(collection, filter, opts = {}) {
    return super.query(collection, filter, { ...opts, limit: Math.min(Math.max(opts.limit || 100, 1), 1000) });
  }
}

test('pages past the 1000-document SODA cap', async () => {
  const soda = new CappedSoda();
  const repo = new Repo(soda);
  for (let i = 0; i < 1500; i++) {
    await soda.insert('users', { userId: `usr_${i}`, email: `r${i}@x.test`, name: `R${i}`, createdAt: i });
    await soda.insert('trips', { tripId: `T-${i}`, userId: `usr_${i}`, totalDistanceKm: 2, endTimeEpochMs: i });
  }
  for (let i = 0; i < 1200; i++) await repo.saveRazorpayOrder({ orderId: `o_${i}`, userId: `usr_${i}`, status: 'PAID', amountInPaise: 100 });

  assert.equal((await repo.listUsers(5000)).length, 1500);
  assert.equal((await repo.listUsers(5000))[0].userId, 'usr_1499'); // newest first across pages
  assert.equal((await repo.listRazorpayOrders({}, 20000)).length, 1200);

  const all = await scan(soda, 'users');
  assert.equal(all.rows.length, 1500);
  assert.equal(all.truncated, false);
  const capped = await scan(soda, 'users', {}, { cap: 1200 });
  assert.equal(capped.rows.length, 1200);
  assert.equal(capped.truncated, true);

  const s = await publicUsage(repo);
  assert.equal(s.riders, 1500);
  assert.equal(s.ridesCompleted, 1500);
  assert.equal(s.kmRidden, 3000);
});

test('median of response times', () => {
  assert.equal(median([]), null);
  assert.equal(median([30]), 30);
  assert.equal(median([90, 10, 30]), 30);
  assert.equal(median([10, 20, 30, 40]), 25);
});
