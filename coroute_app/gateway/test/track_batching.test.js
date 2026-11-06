'use strict';
/**
 * Batched track writes: many chunks -> one bulk insert, every caller answered only after its chunk is
 * stored, idempotent on (groupId, userId, seq), and a failed write is an error (the phone keeps the chunk).
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { TrackStore, validateChunk } = require('../src/tracks');
const gm = require('../src/geo_math');

const T0 = Date.UTC(2026, 9, 5, 4, 0, 0);
function chunk(seq, n = 5) {
  const pts = [];
  for (let i = 0; i < n; i++) pts.push({ lat: 17 + (seq * n + i) / 10000, lng: 78.4 });
  const startTs = T0 + seq * 60000;
  return validateChunk({ seq, startTs, enc: gm.encodePolyline(pts), t: pts.map((_, i) => i * 1000), v: pts.map(() => 40), acc: pts.map(() => 5) }, { nowMs: T0 + 86400000 });
}
async function setup(opts = {}) {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  const calls = { bulk: 0, single: 0, bulkSizes: [] };
  const bulk = repo.insertTrackChunks.bind(repo);
  repo.insertTrackChunks = async (docs) => { calls.bulk++; calls.bulkSizes.push(docs.length); return bulk(docs); };
  const single = repo.insertTrackChunk.bind(repo);
  repo.insertTrackChunk = async (doc) => { calls.single++; return single(doc); };
  const store = new TrackStore(repo, { flushMs: 30, maxBatch: 50, ...opts });
  const count = () => soda.collections.get('track_chunks').size;
  return { soda, repo, store, calls, count };
}

test('concurrent saves are written with one bulk insert and each resolves after the write', async () => {
  const { store, calls, count } = await setup();
  const results = await Promise.all(Array.from({ length: 30 }, (_, i) => store.save('G1', `u${i % 3}`, chunk(i))));
  assert.equal(calls.bulk, 1);
  assert.equal(calls.single, 0);
  assert.equal(count(), 30, 'every chunk is in the database when its promise resolves');
  assert.deepEqual(results.map((r) => r.seq), Array.from({ length: 30 }, (_, i) => i));
  assert.ok(results.every((r) => r.duplicate === false));
});

test('a full batch (maxBatch) is flushed at once without waiting for the timer', async () => {
  const { store, calls, count } = await setup({ flushMs: 60000, maxBatch: 10 });
  const started = Date.now();
  await Promise.all(Array.from({ length: 25 }, (_, i) => store.save('G1', 'u1', chunk(i)).catch((e) => e)).slice(0, 20));
  assert.ok(Date.now() - started < 5000);
  assert.deepEqual(calls.bulkSizes.slice(0, 2), [10, 10]);
  await store.flush(); // the remaining 5
  assert.equal(count(), 25);
});

test('duplicates: a resent stored chunk and the same chunk twice in one batch are stored once', async () => {
  const { store, count } = await setup();
  assert.equal((await store.save('G1', 'u1', chunk(1))).duplicate, false);
  assert.equal((await store.save('G1', 'u1', chunk(1))).duplicate, true, 'already in the database');
  const [a, b, c] = await Promise.all([store.save('G1', 'u1', chunk(2)), store.save('G1', 'u1', chunk(2)), store.save('G1', 'u2', chunk(2))]);
  assert.equal(a.duplicate, false);
  assert.equal(b.duplicate, true, 'same chunk while the first copy is being written');
  assert.equal(c.duplicate, false, 'same seq of another rider is another chunk');
  assert.equal(count(), 3);
});

test('a concurrent writer storing the same chunk: bulk insert conflicts, one-by-one fallback keeps the rest', async () => {
  const { soda, store, calls, count } = await setup();
  // Another gateway node inserts seq 3 between our existence check and our bulk insert.
  const realQuery = soda.query.bind(soda);
  let raced = false;
  soda.query = async (coll, filter, opts) => {
    const rows = await realQuery(coll, filter, opts);
    if (!raced && coll === 'track_chunks' && filter.seq && filter.seq.$in) {
      raced = true;
      await soda.insert('track_chunks', { groupId: 'G1', userId: 'u1', seq: 3, startTs: 1, endTs: 2, enc: '', t: [], v: [], acc: [] });
    }
    return rows;
  };
  const res = await Promise.all([2, 3, 4].map((s) => store.save('G1', 'u1', chunk(s))));
  assert.equal(calls.bulk, 1);
  assert.equal(calls.single, 3, 'fallback inserts one by one');
  assert.deepEqual(res.map((r) => r.duplicate), [false, true, false]);
  assert.equal(count(), 3);
  assert.equal(store.stats.fallbacks, 1);
});

test('a failed write rejects every caller of that batch; nothing is acknowledged; a retry stores it', async () => {
  const { repo, store, count } = await setup();
  const bulk = repo.insertTrackChunks;
  const single = repo.insertTrackChunk;
  repo.insertTrackChunks = async () => { throw Object.assign(new Error('ORDS 503'), { status: 503 }); };
  repo.insertTrackChunk = async () => { throw Object.assign(new Error('ORDS 503'), { status: 503 }); };
  const settled = await Promise.allSettled([1, 2, 3].map((s) => store.save('G1', 'u1', chunk(s))));
  assert.ok(settled.every((s) => s.status === 'rejected' && /503/.test(s.reason.message)));
  assert.equal(count(), 0);
  repo.insertTrackChunks = bulk;
  repo.insertTrackChunk = single;
  const again = await Promise.all([1, 2, 3].map((s) => store.save('G1', 'u1', chunk(s))));
  assert.ok(again.every((r) => r.duplicate === false));
  assert.equal(count(), 3);
});

test('existence check failing also rejects (no ACK without a durable write)', async () => {
  const { repo, store, count } = await setup();
  repo.existingTrackSeqs = async () => { throw new Error('timeout'); };
  await assert.rejects(store.save('G1', 'u1', chunk(1)), /timeout/);
  assert.equal(count(), 0);
});

test('HTTP: POST /convoys/:id/tracks answers after the batched write, and 5xx when it fails', async (t) => {
  const { boot } = require('./_helpers');
  const h = await boot();
  t.after(async () => { await h.gw.shutdown().catch(() => {}); });
  const A = await h.register('Asha Lead', 'asha.batch@coroute.test');
  const created = await h.api('POST', '/convoys', { name: 'Batch ride' }, A.token);
  assert.equal(created.status, 201);
  const gid = created.json.groupId;
  const now = Date.now();
  const raw = (seq) => {
    const pts = [{ lat: 17 + seq / 1000, lng: 78.4 }, { lat: 17.0005 + seq / 1000, lng: 78.4 }];
    return { seq, startTs: now - 60000 + seq * 1000, enc: gm.encodePolyline(pts), t: [0, 500], v: [30, 31], acc: [5, 5] };
  };
  const chunks = Array.from({ length: 20 }, (_, i) => raw(i));
  const up = await h.api('POST', `/convoys/${gid}/tracks`, { chunks }, A.token);
  assert.equal(up.status, 200, JSON.stringify(up.json));
  assert.deepEqual(up.json.acked, chunks.map((c) => c.seq));
  assert.equal(h.soda.collections.get('track_chunks').size, 20, 'stored before the answer');
  // Database down: the request fails, the phone keeps the chunks.
  const bulk = h.gw.repo.insertTrackChunks;
  const single = h.gw.repo.insertTrackChunk;
  h.gw.repo.insertTrackChunks = async () => { throw new Error('db down'); };
  h.gw.repo.insertTrackChunk = async () => { throw new Error('db down'); };
  const fail = await h.api('POST', `/convoys/${gid}/tracks`, { chunks: [raw(30), raw(31)] }, A.token);
  assert.ok(fail.status >= 500, `status ${fail.status}`);
  assert.equal(fail.json.acked, undefined);
  h.gw.repo.insertTrackChunks = bulk;
  h.gw.repo.insertTrackChunk = single;
  const retry = await h.api('POST', `/convoys/${gid}/tracks`, { chunks: [raw(30), raw(31), raw(0)] }, A.token);
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.json.acked, [30, 31, 0]);
  assert.equal(h.soda.collections.get('track_chunks').size, 22);
});
