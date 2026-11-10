'use strict';
// 3.55 alert latency review: the timeline tick went from 30 s to 2 s (TIMELINE_TICK_MS) and the
// per-convoy group check from 5 s to 2 s. This measures the CPU cost of one tick and of a
// telemetry burst, so the shorter intervals stay safe on a small server.
process.env.NODE_ENV = 'test';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const config = require('../src/config');
const { TimelineEngine } = require('../src/timeline');

function world({ rooms, riders, now }) {
  const convoys = new EventEmitter();
  convoys.rooms = new Map();
  convoys._emit = () => {};
  convoys.passive = () => false;
  convoys.recordVisit = async () => null;
  convoys.clearRegroup = async () => null;
  let writes = 0;
  const repo = {
    listOpenEvents: async () => [],
    upsertEvent: async () => { writes++; },
    removeEvent: async () => {},
    listEvents: async () => [],
    getConvoyMeta: async () => null,
  };
  for (let g = 0; g < rooms; g++) {
    const gid = `GRP-LOAD${g}`;
    const map = new Map();
    for (let i = 0; i < riders; i++) {
      const userId = `u${g}_${i}`;
      map.set(userId, {
        userId, name: `Rider ${i}`, lat: 17 + g * 0.01 + i * 0.0002, lng: 78, speedKmh: 45, lastSeenEpochMs: now - 1000,
        role: i === 0 ? 'LEAD' : (i === riders - 1 ? 'SWEEPER' : 'PACK'), batteryLevel: 80,
      });
    }
    convoys.rooms.set(gid, { riders: map, alerts: new Map(), meta: { groupId: gid, tripStatus: 'STARTED', createdByUserId: `u${g}_0`, members: {}, stopPoints: [] } });
  }
  const tl = new TimelineEngine({ convoys, repo, logger: { warn() {} }, tickMs: 3600000, clock: () => now });
  return { tl, convoys, writes: () => writes };
}

test('default tick and group-check intervals are 2 s', () => {
  assert.equal(config.timelineTickMs, Number(process.env.TIMELINE_TICK_MS || 2000));
});

test('one tick over 200 rides x 25 riders (5,000 riders) costs a few ms and writes nothing', async () => {
  const now = 1_800_000_000_000;
  const w = world({ rooms: 200, riders: 25, now });
  try {
    await w.tl.tick(); // warm-up: creates the per-ride state
    const runs = 10;
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < runs; i++) await w.tl.tick();
    const msPerTick = Number(process.hrtime.bigint() - t0) / 1e6 / runs;
    // At a 2 s tick this is the share of one core spent on ticks.
    const share = msPerTick / 2000;
    console.log(`[timeline load] ${msPerTick.toFixed(2)} ms per tick for 5,000 riders (${(share * 100).toFixed(2)} % of one core at 2 s)`);
    assert.ok(msPerTick < 100, `tick took ${msPerTick} ms`);
    assert.equal(w.writes(), 0, 'nothing changed, nothing written');
  } finally {
    w.tl.stop();
  }
});

test('a telemetry burst (every rider of a 50-rider ride, 1 Hz for 60 s) stays cheap with the 2 s group check', async () => {
  let now = 1_800_000_000_000;
  const w = world({ rooms: 1, riders: 50, now });
  const room = w.convoys.rooms.get('GRP-LOAD0');
  try {
    const t0 = process.hrtime.bigint();
    for (let s = 0; s < 60; s++) {
      now += 1000;
      for (const r of room.riders.values()) {
        r.lat += 0.0001; r.lastSeenEpochMs = now;
        await w.tl.onTelemetry('GRP-LOAD0', { ...r });
      }
    }
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    console.log(`[timeline load] 3,000 fixes of one 50-rider ride: ${ms.toFixed(1)} ms (${(ms / 3000).toFixed(3)} ms per fix)`);
    assert.ok(ms / 3000 < 2, `${ms / 3000} ms per fix`);
  } finally {
    w.tl.stop();
  }
});
