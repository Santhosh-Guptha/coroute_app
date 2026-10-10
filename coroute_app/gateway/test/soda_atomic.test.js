const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SodaClient } = require('../src/oracle/soda');

test('atomic patch tests the observed document before replacement without retrying conflicts', async () => {
  for (const status of [200, 404, 409, 412, 422, 500]) {
    const calls = [];
    const soda = new SodaClient({ baseUrl: 'https://example.test', user: 'test', password: 'test',
      fetchImpl: async (url, options) => { calls.push({ url, options }); return new Response('', { status }); } });
    const operation = soda.compareAndReplace('jobs', 'a/b', { sequence: 1 }, { sequence: 2 });
    if (status === 500) await assert.rejects(operation);
    else assert.equal(await operation, status === 200);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, 'https://example.test/jobs/a%2Fb');
    assert.equal(calls[0].options.method, 'PATCH');
    assert.equal(calls[0].options.headers['Content-Type'], 'application/json-patch+json');
    assert.deepEqual(JSON.parse(calls[0].options.body), [
      { op: 'test', path: '', value: { sequence: 1 } }, { op: 'replace', path: '', value: { sequence: 2 } }]);
  }
});

test('patched gaxios uuid dependency supports its CommonJS v4 call', () => {
  const { createRequire } = require('node:module');
  const fromGaxios = createRequire(require.resolve('gaxios'));
  assert.match(fromGaxios('uuid').v4(), /^[0-9a-f-]{36}$/);
  assert.equal(typeof require('gaxios').request, 'function');
});
