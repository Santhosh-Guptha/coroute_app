'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runStagingKeepalive, COLLECTION } = require('../scripts/staging_keepalive');
const { MemorySoda } = require('../src/oracle/memory_soda');

test('staging_keepalive: inserts document and prunes expired records in memory', async () => {
  const memorySoda = new MemorySoda();
  const log = {
    info() {},
    warn() {},
    error() {},
  };

  const day = 24 * 60 * 60 * 1000;
  const now = Date.now();

  // Pre-populate an old entry (40 days old) and a recent entry (5 days old)
  await memorySoda.ensureCollection(COLLECTION);
  await memorySoda.insert(COLLECTION, { heartbeat: true, timestamp: now - 40 * day });
  await memorySoda.insert(COLLECTION, { heartbeat: true, timestamp: now - 5 * day });

  const preQuery = await memorySoda.query(COLLECTION, {});
  assert.equal(preQuery.length, 2);

  const res = await runStagingKeepalive({
    sodaClient: memorySoda,
    nowMs: now,
    log,
  });

  assert.equal(res.ok, true);
  assert.ok(res.key);
  assert.equal(res.pruned, 1); // 40-day-old entry was pruned

  const postQuery = await memorySoda.query(COLLECTION, {});
  assert.equal(postQuery.length, 2); // 5-day-old + newly inserted entry
});

test('staging_keepalive: fails when no password provided and not memory', async () => {
  await assert.rejects(
    async () => {
      await runStagingKeepalive({
        env: { STAGING_ORACLE_PASSWORD: '', ORACLE_PASSWORD: '', STAGING_ORACLE_SODA_URL: 'https://example.com' },
        log: { info() {}, warn() {}, error() {} },
      });
    },
    /STAGING_ORACLE_PASSWORD or ORACLE_PASSWORD must be set/
  );
});

test('staging_keepalive: dry-run ping succeeds with MemorySoda', async () => {
  const memorySoda = new MemorySoda();
  const res = await runStagingKeepalive({
    sodaClient: memorySoda,
    dryRun: true,
    log: { info() {}, warn() {}, error() {} },
  });

  assert.equal(res.ok, true);
  assert.equal(res.dryRun, true);
});
