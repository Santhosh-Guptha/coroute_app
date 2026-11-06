'use strict';
/** Room snapshots: one document per room for the live rider state (repo.saveRoomSnapshot / loadRoomSnapshot). */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo, COLLECTIONS } = require('../src/oracle/repo');
const { identity } = require('../src/anonymise');

async function setup() {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  return { soda, repo };
}
const rider = (userId, extra = {}) => ({ userId, name: `Rider ${userId}`, role: 'MEMBER', lat: 17.1, lng: 78.4, speed: 40, lastSeenEpochMs: 1000, ...extra });

test('migrate creates room_snapshots with a unique groupId index', async () => {
  const { soda } = await setup();
  assert.ok((await soda.listCollections()).includes('room_snapshots'));
  assert.equal(COLLECTIONS.roomSnapshots, 'room_snapshots');
  assert.deepEqual(soda.indexes.get('room_snapshots').get('room_snapshots_group_ux'), ['groupId']);
});

test('save + load round trip: one document per room, rewritten in place', async () => {
  const { soda, repo } = await setup();
  assert.equal(await repo.loadRoomSnapshot('G1'), null);
  await repo.saveRoomSnapshot('G1', { riders: [rider('u1'), rider('u2', { key: 'K-stale' })], positionsAt: 5000 });
  let snap = await repo.loadRoomSnapshot('G1');
  assert.equal(snap.positionsAt, 5000);
  assert.deepEqual(snap.riders.map((r) => r.userId), ['u1', 'u2']);
  assert.equal(snap.riders[1].key, undefined, 'SODA keys are never stored');
  assert.equal(snap.riders[0].groupId, 'G1');
  // A Map (room.riders) works too; the second save replaces the first.
  await repo.saveRoomSnapshot('G1', { riders: new Map([['u1', rider('u1', { lat: 17.5, lastSeenEpochMs: 2000 })]]), positionsAt: 6000 });
  snap = await repo.loadRoomSnapshot('G1');
  assert.equal(snap.positionsAt, 6000);
  assert.deepEqual(snap.riders.map((r) => [r.userId, r.lat]), [['u1', 17.5]]);
  assert.equal(soda.collections.get('room_snapshots').size, 1);
  // Another room has its own document.
  await repo.saveRoomSnapshot('G2', { riders: [rider('u9')] });
  assert.equal(soda.collections.get('room_snapshots').size, 2);
});

test('concurrent saves of one room are written in call order (the last state wins), no duplicate documents', async () => {
  const { soda, repo } = await setup();
  const saves = [];
  for (let i = 0; i < 20; i++) saves.push(repo.saveRoomSnapshot('G1', { riders: [rider('u1', { lat: 17 + i / 100 })], positionsAt: i }));
  await Promise.all(saves);
  const snap = await repo.loadRoomSnapshot('G1');
  assert.equal(snap.positionsAt, 19);
  assert.equal(snap.riders[0].lat, 17.19);
  assert.equal(soda.collections.get('room_snapshots').size, 1);
});

test('a snapshot removed behind the cached key is written again (no lost flush)', async () => {
  const { soda, repo } = await setup();
  await repo.saveRoomSnapshot('G1', { riders: [rider('u1')] });
  await soda.removeWhere('room_snapshots', { groupId: 'G1' }); // e.g. retention
  await repo.saveRoomSnapshot('G1', { riders: [rider('u1', { lat: 18 })] });
  assert.equal((await repo.loadRoomSnapshot('G1')).riders[0].lat, 18);
});

test('listRiders overlays the newer snapshot state on the per-rider documents', async () => {
  const { repo } = await setup();
  await repo.upsertRider('G1', rider('u1', { role: 'LEAD', lat: 17.0, lastSeenEpochMs: 1000 }));
  await repo.upsertRider('G1', rider('u2', { lat: 17.0 }));
  await new Promise((r) => setTimeout(r, 5));
  await repo.saveRoomSnapshot('G1', { riders: [rider('u1', { role: 'LEAD', lat: 17.3, lastSeenEpochMs: 9000 }), rider('u3', { lat: 17.9 })] });
  const list = await repo.listRiders('G1');
  const by = Object.fromEntries(list.map((r) => [r.userId, r]));
  assert.equal(by.u1.lat, 17.3, 'live position from the snapshot');
  assert.equal(by.u1.lastSeenEpochMs, 9000);
  assert.equal(by.u1.role, 'LEAD');
  assert.ok(by.u1.key, 'the convoy_riders key is kept');
  assert.equal(by.u1.savedAt, undefined, 'internal write stamp is not returned');
  assert.equal(by.u2.lat, 17.0, 'rider missing from the snapshot keeps its document');
  assert.equal(by.u3.lat, 17.9, 'snapshot-only rider is included');
  // A per-rider write after the snapshot (e.g. a role change) wins over the older snapshot.
  await new Promise((r) => setTimeout(r, 5));
  await repo.upsertRider('G1', rider('u1', { role: 'MEMBER', lat: 17.4, lastSeenEpochMs: 9500 }));
  const again = Object.fromEntries((await repo.listRiders('G1')).map((r) => [r.userId, r]));
  assert.equal(again.u1.role, 'MEMBER');
  assert.equal(again.u1.lat, 17.4);
});

test('removeRider also drops the rider from the snapshot (not restored at the next room load)', async () => {
  const { repo } = await setup();
  await repo.upsertRider('G1', rider('u1'));
  await repo.upsertRider('G1', rider('u2'));
  await repo.saveRoomSnapshot('G1', { riders: [rider('u1'), rider('u2')] });
  await repo.removeRider('G1', 'u2');
  assert.deepEqual((await repo.loadRoomSnapshot('G1')).riders.map((r) => r.userId), ['u1']);
  assert.deepEqual((await repo.listRiders('G1')).map((r) => r.userId), ['u1']);
});

test('deleteConvoyCascade removes the snapshot; deleteUserCascade drops and scrubs the rider', async () => {
  const { soda, repo } = await setup();
  await repo.createConvoyMeta({ groupId: 'G1', name: 'Ride', tripStatus: 'STARTED', createdByUserId: 'u1', members: { u1: { userId: 'u1', name: 'Asha' }, u2: { userId: 'u2', name: 'Bala' } } });
  await repo.createUser({ userId: 'u2', name: 'Bala', email: 'bala@x.test' });
  await repo.upsertRider('G1', rider('u1', { name: 'Asha' }));
  await repo.upsertRider('G1', rider('u2', { name: 'Bala' }));
  await repo.saveRoomSnapshot('G1', { riders: [rider('u1', { name: 'Asha', ridingWithUserId: 'u2' }), rider('u2', { name: 'Bala' })] });
  const user = await repo.findUserById('u2');
  await repo.deleteUserCascade(user, { id: identity(user) });
  const snap = await repo.loadRoomSnapshot('G1');
  assert.deepEqual(snap.riders.map((r) => r.userId), ['u1']);
  assert.ok(!JSON.stringify(snap).includes('"u2"'), 'no trace of the deleted rider');
  await repo.deleteConvoyCascade('G1');
  assert.equal(await repo.loadRoomSnapshot('G1'), null);
  assert.equal(soda.collections.get('room_snapshots').size, 0);
});
