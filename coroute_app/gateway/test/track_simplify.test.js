'use strict';
/** Old-track simplification by the retention job (TRACK_DETAIL_DAYS) and its readers. */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { Retention } = require('../src/retention');
const { TrackStore, analyseTrack, toGpx, toWire, simplifyTrack, encodeChunkBody } = require('../src/tracks');
const gm = require('../src/geo_math');

const DAY = 86400000;
const T0 = Date.UTC(2026, 8, 1, 4, 0, 0);
const quiet = { info() {}, warn() {}, error() {} };

/** A 40 km/h ride north with a bend, a 5 minute stop and GPS jitter, one fix per second. */
function ride(start = T0, lng0 = 78.4) {
  const pts = [];
  let lat = 17.0, lng = lng0, t = start;
  const step = 40 / 3.6 / 111195; // degrees per second
  for (let i = 0; i < 1200; i++) { lat += step; pts.push({ ts: t, lat, lng: lng + (i % 2 ? 1e-6 : 0), v: 40, acc: 5 }); t += 1000; }
  for (let i = 0; i < 300; i++) { pts.push({ ts: t, lat: lat + (i % 3) * 1e-5, lng, v: 0, acc: 5 }); t += 1000; } // stop
  for (let i = 0; i < 1200; i++) { lng += step; pts.push({ ts: t, lat, lng, v: 40, acc: 5 }); t += 1000; }
  return pts.map((p) => ({ ...p, lat: +p.lat.toFixed(5), lng: +p.lng.toFixed(5) }));
}
async function storeChunks(repo, groupId, userId, pts, size = 120, seq0 = 0) {
  for (let i = 0, seq = seq0; i < pts.length; i += size, seq++) {
    await repo.insertTrackChunk({ groupId, userId, seq, ...encodeChunkBody(pts.slice(i, i + size)), createdAt: pts[i].ts });
  }
}
async function setup() {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  const retention = new Retention({ repo, soda, convoys: { autoEndStaleConvoys: async () => 0 }, logger: quiet });
  return { soda, repo, retention, tracks: new TrackStore(repo), chunks: () => [...soda.collections.get('track_chunks').values()] };
}

test('simplifyTrack keeps first/last, stays within tolerance and keeps a point every minute', () => {
  const pts = ride();
  const s = simplifyTrack(pts, { toleranceM: 5, maxGapMs: 60000 });
  assert.ok(s.length < pts.length / 10, `${s.length} of ${pts.length}`);
  assert.deepEqual(s[0], pts[0]);
  assert.deepEqual(s[s.length - 1], pts[pts.length - 1]);
  for (let i = 1; i < s.length; i++) assert.ok(s[i].ts - s[i - 1].ts <= 60000);
  let worst = 0;
  for (const p of pts) {
    let best = Infinity;
    for (let i = 1; i < s.length; i++) best = Math.min(best, gm.pointToSegment(p, s[i - 1], s[i]).dist);
    worst = Math.max(worst, best);
  }
  assert.ok(worst <= 6, `max deviation ${worst.toFixed(1)} m`);
});

test('retention merges old chunks per rider into one simplified document, then deletes the originals', async () => {
  const { soda, repo, retention, tracks, chunks } = await setup();
  const pts = ride();
  await storeChunks(repo, 'G1', 'u1', pts);
  await storeChunks(repo, 'G1', 'u2', ride(T0, 78.5));
  const fresh = ride(T0 + 20 * DAY);
  await storeChunks(repo, 'G2', 'u1', fresh); // recent ride: kept in full detail
  const before = analyseTrack((await tracks.load('G1', { userId: 'u1' })).get('u1'));
  const originalCount = chunks().length;

  const now = T0 + 20 * DAY;
  const stats = await retention.runOnce(now, { autoEnd: false });
  assert.equal(stats.tracksSimplified, 2);
  assert.equal(stats.trackChunksMerged, 2 * Math.ceil(pts.length / 120));
  const g1 = chunks().filter((c) => c.groupId === 'G1');
  assert.equal(g1.length, 2, 'one document per rider');
  for (const c of g1) { assert.equal(c.simplified, true); assert.ok(c.seq < 0); }
  assert.equal(chunks().filter((c) => c.groupId === 'G2').length, Math.ceil(fresh.length / 120), 'recent chunks untouched');
  assert.ok(chunks().length < originalCount);

  // Readers: load / replay / GPX / trip report work on the simplified document.
  const loaded = (await tracks.load('G1', { userId: 'u1' })).get('u1');
  assert.equal(loaded[0].ts, pts[0].ts);
  assert.equal(loaded[loaded.length - 1].ts, pts[pts.length - 1].ts);
  assert.ok(loaded.length < pts.length / 10);
  const after = analyseTrack(loaded);
  assert.ok(Math.abs(after.distanceM - before.distanceM) / before.distanceM < 0.02, `${after.distanceM} vs ${before.distanceM}`);
  assert.equal(after.stops.length, before.stops.length, 'the stop is still found');
  assert.equal(after.gaps.length, 0, 'a stop is not mistaken for a signal gap');
  assert.ok(Math.abs(after.spanMs - before.spanMs) < 1000);
  const gpx = toGpx({ name: 'Ride', tracks: [{ name: 'u1', points: loaded }] });
  assert.equal((gpx.match(/<trkpt /g) || []).length, loaded.length);
  assert.equal(toWire(loaded).length, loaded.length);
  // A time window inside the ride still works.
  const mid = (await tracks.load('G1', { userId: 'u1', from: pts[600].ts, to: pts[1800].ts })).get('u1');
  assert.ok(mid.length > 0 && mid.every((p) => p.ts >= pts[600].ts && p.ts <= pts[1800].ts));

  // Idempotent: nothing left to merge.
  const again = await retention.simplifyOldTracks(now + 1);
  assert.equal(again.tracksSimplified, 0);
  assert.equal(soda.collections.get('track_chunks').size, chunks().length);
});

test('crash between write and delete: the next run merges everything again without duplicate points', async () => {
  const { soda, repo, retention, tracks, chunks } = await setup();
  await storeChunks(repo, 'G1', 'u1', ride());
  const realRemove = soda.remove.bind(soda);
  let removes = 0;
  soda.remove = async (coll, key) => { if (coll === 'track_chunks' && ++removes > 5) throw new Error('crash'); return realRemove(coll, key); };
  await retention.simplifyOldTracks(T0 + 20 * DAY);
  soda.remove = realRemove;
  assert.ok(chunks().some((c) => c.simplified) && chunks().some((c) => !c.simplified), 'half done');
  await retention.simplifyOldTracks(T0 + 20 * DAY + 3600000);
  const left = chunks();
  assert.equal(left.length, 1);
  assert.equal(left[0].simplified, true);
  const loaded = (await tracks.load('G1')).get('u1');
  const ts = loaded.map((p) => p.ts);
  assert.equal(new Set(ts).size, ts.length);
  // A late chunk older than the detail window is merged with the existing simplified document.
  await storeChunks(repo, 'G1', 'u1', ride(T0 + 3600000 * 2), 120, 1000);
  const r = await retention.simplifyOldTracks(T0 + 20 * DAY + 7200000);
  assert.equal(r.tracksSimplified, 1);
  assert.equal(chunks().length, 1);
});

test('TRACK_RETENTION_DAYS still applies; TRACK_DETAIL_DAYS=0 disables simplification', async () => {
  const { repo, retention, chunks } = await setup();
  await storeChunks(repo, 'G1', 'u1', ride());
  const old = await retention.runOnce(T0 + 100 * DAY, { autoEnd: false }); // beyond the 90 day default
  assert.ok(old.trackChunksRemoved > 0);
  assert.equal(chunks().length, 0);
  await storeChunks(repo, 'G1', 'u1', ride());
  const config = require('../src/config');
  const had = Object.prototype.hasOwnProperty.call(config, 'trackDetailDays');
  const prev = config.trackDetailDays;
  config.trackDetailDays = 0;
  try {
    const r = await retention.simplifyOldTracks(T0 + 20 * DAY);
    assert.equal(r.tracksSimplified, 0);
    assert.ok(chunks().every((c) => !c.simplified));
  } finally { if (had) config.trackDetailDays = prev; else delete config.trackDetailDays; }
});
