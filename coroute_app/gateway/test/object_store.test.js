'use strict';
/** Object store through a Pre-Authenticated Request (fake PAR server). */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createParStore, ObjectStoreError, TOMBSTONE } = require('../src/object_store');
const { startParServer } = require('./_par_server');

test('put / get / exists / del round trip; names are URL-encoded', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const store = createParStore(par.url, { backoffMs: 5 });
  const data = Buffer.from([0, 1, 2, 255, 10, 13]);
  await store.put('coroute/2026/11/06/09-critical.json.gz.enc', data, 'application/octet-stream');
  assert.ok(par.log.some((l) => l.path.endsWith('/o/coroute%2F2026%2F11%2F06%2F09-critical.json.gz.enc')));
  assert.deepEqual(await store.get('coroute/2026/11/06/09-critical.json.gz.enc'), data);
  assert.equal(par.objects.get('coroute/2026/11/06/09-critical.json.gz.enc').type, 'application/octet-stream');
  assert.equal(await store.exists('coroute/2026/11/06/09-critical.json.gz.enc'), true);
  assert.equal(await store.get('missing'), null);
  assert.equal(await store.exists('missing'), false);
  assert.deepEqual(await store.del('coroute/2026/11/06/09-critical.json.gz.enc'), { deleted: true, tombstoned: false });
  assert.equal(await store.get('coroute/2026/11/06/09-critical.json.gz.enc'), null);
  assert.deepEqual(await store.del('never-there'), { deleted: true, tombstoned: false });
});

test('a PAR without DELETE: the object is overwritten with a tombstone and reads as deleted', async (t) => {
  const par = await startParServer({ allowDelete: false });
  t.after(() => par.close());
  const store = createParStore(par.url, { backoffMs: 5 });
  await store.put('photo.jpg', Buffer.from('secret pixels'), 'image/jpeg');
  assert.deepEqual(await store.del('photo.jpg'), { deleted: true, tombstoned: true });
  assert.ok(par.objects.get('photo.jpg').body.equals(TOMBSTONE), 'the original bytes are gone');
  assert.equal(await store.get('photo.jpg'), null);
  assert.equal(await store.exists('photo.jpg'), false);
  assert.deepEqual((await store.list('')).map((o) => o.name), [], 'tombstones are not listed');
  assert.equal((await store.list('', { raw: true })).length, 1);
  // Writing it again revives it.
  await store.put('photo.jpg', Buffer.from('new'), 'image/jpeg');
  assert.equal((await store.get('photo.jpg')).toString(), 'new');
});

test('list pages through every object under a prefix; unsupported listing is a clear error', async (t) => {
  const par = await startParServer({ pageSize: 3 });
  t.after(() => par.close());
  const store = createParStore(par.url, { backoffMs: 5 });
  for (let i = 0; i < 10; i++) await store.put(`a/${String(i).padStart(2, '0')}`, Buffer.from(String(i)));
  await store.put('b/other', Buffer.from('x'));
  const listed = await store.list('a/');
  assert.deepEqual(listed.map((o) => o.name), Array.from({ length: 10 }, (_, i) => `a/${String(i).padStart(2, '0')}`));
  assert.equal(listed[0].size, 1);
  assert.ok(par.log.filter((l) => l.query.includes('prefix=a%2F')).length >= 4, 'paged');
  par.state.allowList = false;
  await assert.rejects(store.list('a/'), (e) => e instanceof ObjectStoreError && e.code === 'LIST_UNSUPPORTED');
});

test('5xx and dropped connections are retried with backoff; 4xx is not; errors never contain the PAR token', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const store = createParStore(par.url, { backoffMs: 5, retries: 3 });
  par.state.failNext = 2;
  await store.put('x', Buffer.from('1'));
  assert.equal((await store.get('x')).toString(), '1');
  par.state.dropNext = 1;
  assert.equal((await store.get('x')).toString(), '1');
  par.state.failNext = 10;
  const err = await store.get('x').catch((e) => e);
  assert.ok(err instanceof ObjectStoreError);
  assert.equal(err.status, 503);
  assert.ok(!err.message.includes('tok3n') && !err.message.includes('127.0.0.1'), err.message);
  par.state.failNext = 0;
  const bad = createParStore(par.url.replace('tok3n', 'wrong'), { backoffMs: 5 });
  const e2 = await bad.put('y', Buffer.from('1')).catch((e) => e);
  assert.equal(e2.status, 404);
  assert.ok(!e2.message.includes('wrong'));
});

test('the base URL must be a bucket PAR ending in /o/', () => {
  assert.throws(() => createParStore(''), /PAR URL/);
  assert.throws(() => createParStore('https://objectstorage.ap-hyderabad-1.oraclecloud.com/p/t/n/ns/b/bkt'), /PAR URL/);
  assert.doesNotThrow(() => createParStore('https://objectstorage.ap-hyderabad-1.oraclecloud.com/p/t/n/ns/b/bkt/o/'));
  assert.doesNotThrow(() => createParStore('https://objectstorage.ap-hyderabad-1.oraclecloud.com/p/t/n/ns/b/bkt/o'));
});
