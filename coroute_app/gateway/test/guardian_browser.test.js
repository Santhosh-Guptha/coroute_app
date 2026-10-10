 'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const read = (name) => fs.readFileSync(path.join(__dirname, '../public', name), 'utf8');
const flush = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };
function page(fetchImpl) {
  const elements = new Map(), handlers = {}, timers = new Map(), stored = new Map(); let seq = 0;
  function element(id) {
    if (!elements.has(id)) elements.set(id, { textContent: '', hidden: true, value: '', dataset: {}, children: [],
      replaceChildren() { this.children = []; }, append(v) { this.children.push(v); },
      removeAttribute(k) { delete this[k]; }, addEventListener(k, fn) { handlers[id + ':' + k] = fn; } });
    return elements.get(id);
  }
  const document = { hidden: false, getElementById: element, querySelector: element, createElement: (id) => element(id + ++seq),
    addEventListener: (k, fn) => { handlers[k] = fn; } };
  const window = { addEventListener: (k, fn) => { handlers[k] = fn; } };
  let stripped = false;
  vm.runInNewContext(read('assets/guardian.js'), { document, window, navigator: {},
    location: { hash: '#token=' + 'A'.repeat(32) }, history: { replaceState() { stripped = true; } },
    localStorage: { getItem: k => stored.get(k), setItem: (k, v) => stored.set(k, v), removeItem: k => stored.delete(k) },
    fetch: fetchImpl, URLSearchParams, AbortController, Date, Uint8Array,
    setTimeout: (fn, delay) => { timers.set(++seq, { fn, delay }); return seq; }, clearTimeout: id => timers.delete(id) });
  return { element, handlers, document, timers, stripped: () => stripped };
}
const response = (body, status = 200) => ({ ok: status === 200, status, json: async () => body });
const view = { name: '<script>private</script>', status: 'RIDING', serverTime: 1000, expiresAt: 61000,
  position: { lat: 17, lng: 78 }, timeline: [] };

test('observer page strips capability and clears private DOM when hidden or revoked', async () => {
  let revoked = false;
  const p = page(async url => response(url.endsWith('/session') ? { sessionId: 'x' } : url.endsWith('/capabilities') ? { push: false } : revoked ? {} : view,
    revoked && url.endsWith('/snapshot') ? 410 : 200));
  await flush(); assert.equal(p.stripped(), true);
  assert.match(p.element('ride-title').textContent, /<script>/, 'untrusted name remains plain text');
  p.document.hidden = true; p.handlers.visibilitychange(); assert.equal(p.element('location').hidden, true);
  revoked = true; p.document.hidden = false; p.handlers.visibilitychange(); await flush();
  assert.equal(p.element('ride-title').textContent, 'Personal ride');
  assert.match(p.element('connection').textContent, /Access ended/);
  assert.equal(p.timers.size, 0);
});

test('late response after pagehide cannot restore private location', async () => {
  let resolve;
  const p = page(async url => url.endsWith('/session') ? response({ sessionId: 'x' }) :
    url.endsWith('/capabilities') ? response({ push: false }) : new Promise(r => { resolve = r; }));
  await flush(); p.handlers.pagehide(); resolve(response(view)); await flush();
  assert.equal(p.element('location').hidden, true);
  assert.equal(p.element('ride-title').textContent, 'Personal ride');
  assert.equal(p.timers.size, 0);
});

test('PIN denial waits for user input and offline failures use bounded retry', async () => {
  const pin = page(async () => response({ code: 'GUARDIAN_PIN_REQUIRED' }, 401)); await flush();
  assert.equal(pin.element('pin-box').hidden, false); assert.equal(pin.timers.size, 0);
  const offline = page(async () => { throw new Error('offline'); }); await flush();
  assert.match(offline.element('connection').textContent, /unavailable/);
  assert.deepEqual([...offline.timers.values()].map(t => t.delay), [30000]);
});

test('service worker rejects malformed payloads and external click destinations', async () => {
  const handlers = {}, shown = [], opened = [];
  vm.runInNewContext(read('_watch-sw.js'), { self: { addEventListener: (k, fn) => { handlers[k] = fn; },
    registration: { showNotification: async (title, data) => shown.push({ title, data }) },
    clients: { openWindow: async url => opened.push(url) } } });
  for (const payload of [null, 1, 'bad']) handlers.push({ data: { json: () => payload }, waitUntil() {} });
  assert.equal(shown.length, 0);
  let waiting;
  handlers.push({ data: { json: () => ({ title: 'SECRET', url: 'https://evil.example', tag: 'test' }) }, waitUntil(p) { waiting = p; } });
  await waiting; assert.equal(shown[0].title, 'CoRoute trip update'); assert.equal(shown[0].data.data.url, '/watch');
  handlers.notificationclick({ notification: { close() {}, data: { url: 'https://evil.example' } }, waitUntil(p) { waiting = p; } });
  await waiting; assert.deepEqual(opened, ['/watch']);
});
