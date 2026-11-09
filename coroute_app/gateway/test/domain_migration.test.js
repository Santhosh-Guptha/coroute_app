'use strict';
// Domain move coroute.duckdns.org -> coroute.devmonks.space (src/domains.js, docs/DOMAIN_MIGRATION_devmonks.md).
process.env.NODE_ENV = 'test';
process.env.PUBLIC_ORIGIN = 'https://coroute.devmonks.space';
process.env.REDIRECT_LEGACY_HOST = 'true';
process.env.CORS_ORIGINS = 'https://partner.example';
delete process.env.LEGACY_ORIGINS; // default: https://coroute.duckdns.org
const http = require('node:http');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const D = require('../src/domains');
const config = require('../src/config');
const { inviteLinkOf } = require('../src/social_routes');
const { EmergencySmsGateway } = require('../src/emergency_sms_gateway');

const NEW = 'https://coroute.devmonks.space';
const OLD_HOST = 'coroute.duckdns.org';
const NEW_HOST = 'coroute.devmonks.space';

let gw, port;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  port = gw.server.address().port;
});
after(async () => { await gw.shutdown(); });

/** Raw request with a chosen Host header (fetch cannot set Host). */
function req(method, path, host, headers = {}, body = null) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port, method, path, headers: { host, ...headers } }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}

test('config: PUBLIC_ORIGIN is the link origin; duckdns stays a legacy origin', () => {
  assert.equal(config.publicOrigin, NEW);
  assert.equal(config.linkOrigin, NEW);
  assert.deepEqual(config.legacyOrigins, ['https://coroute.duckdns.org']);
  assert.deepEqual(D.siteOriginsOf(config), [NEW, 'https://coroute.duckdns.org']);
  assert.ok(config.providerUserAgent.includes(`+${NEW};`));
  // Without PUBLIC_ORIGIN links fall back to the host that is live today.
  assert.equal(D.linkOriginOf({ publicOrigin: '' }), 'https://coroute.duckdns.org');
  assert.equal(D.normaliseOrigin('https://Coroute.DevMonks.Space:443/'), NEW);
  assert.equal(D.normaliseOrigin('javascript:alert(1)'), '');
});

test('generated links use PUBLIC_ORIGIN: friend invites, SMS live links, meta links', async () => {
  assert.equal(inviteLinkOf('5TLBM452'), `${NEW}/join/friend/5TLBM452`);
  const sms = new EmergencySmsGateway({ config: { publicOrigin: config.publicOrigin, liveLinkMin: 30 } });
  assert.ok(sms.generateTrackingUrl({ lat: 12.9, lng: 77.5 }).startsWith(`${NEW}/e/`));
  const smsFallback = new EmergencySmsGateway({ config: { liveLinkMin: 30 } });
  assert.ok(smsFallback.generateTrackingUrl({ lat: 12.9, lng: 77.5 }).startsWith('https://coroute.duckdns.org/e/'), 'never an unowned domain');
  // Asked on the OLD host (an installed 3.54 app), the links still point at the canonical origin.
  const meta = await req('GET', '/api/meta', OLD_HOST);
  assert.equal(meta.status, 200);
  const m = JSON.parse(meta.body);
  assert.equal(m.downloadUrl, `${NEW}/download`);
  assert.equal(m.privacyUrl, `${NEW}/privacy`);
});

test('website canonical, sitemap and robots use PUBLIC_ORIGIN', async () => {
  const home = await req('GET', '/', NEW_HOST);
  assert.equal(home.status, 200);
  assert.ok(home.body.includes(`<link rel="canonical" href="${NEW}/">`));
  assert.ok(!home.body.includes('duckdns'));
  const sm = await req('GET', '/sitemap.xml', NEW_HOST);
  assert.ok(sm.body.includes(`<loc>${NEW}/privacy</loc>`));
  const robots = await req('GET', '/robots.txt', NEW_HOST);
  assert.ok(robots.body.includes(`Sitemap: ${NEW}/sitemap.xml`));
});

test('both hosts are served; the old host keeps the whole API (GET and POST)', async () => {
  for (const host of [NEW_HOST, OLD_HOST]) {
    const h = await req('GET', '/api/health', host);
    assert.equal(h.status, 200, `health on ${host}`);
    const post = await req('POST', '/api/auth/login', host, { 'content-type': 'application/json' }, JSON.stringify({ email: 'x@y.z', password: 'nope-nope' }));
    assert.notEqual(post.status, 301, `POST on ${host} is never redirected`);
    assert.notEqual(post.status, 308);
    assert.equal(post.headers.location, undefined);
  }
});

test('CORS accepts both site origins (plus CORS_ORIGINS) and nothing else', async () => {
  for (const origin of [NEW, 'https://coroute.duckdns.org', 'https://partner.example']) {
    const r = await req('OPTIONS', '/api/health', NEW_HOST, { origin, 'access-control-request-method': 'GET' });
    assert.equal(r.headers['access-control-allow-origin'], origin, origin);
  }
  const evil = await req('OPTIONS', '/api/health', NEW_HOST, { origin: 'https://evil.example', 'access-control-request-method': 'GET' });
  assert.equal(evil.headers['access-control-allow-origin'], undefined);
});

test('REDIRECT_LEGACY_HOST: website pages on the old host -> 301 to the new origin, query kept', async () => {
  const r = await req('GET', '/features?ref=sms', OLD_HOST);
  assert.equal(r.status, 301);
  assert.equal(r.headers.location, `${NEW}/features?ref=sms`);
  const root = await req('HEAD', '/', `${OLD_HOST}:443`);
  assert.equal(root.status, 301);
  assert.equal(root.headers.location, `${NEW}/`);
  // The new host and unknown hosts are served, never redirected.
  assert.equal((await req('GET', '/features', NEW_HOST)).status, 200);
  assert.equal((await req('GET', '/features', '127.0.0.1')).status, 200);
});

test('legacy redirect never touches /api, /ws, /.well-known, live links, guardian page or POSTs', async () => {
  for (const p of ['/api/health', '/api/meta', '/api', '/.well-known/assetlinks.json', '/status']) {
    const r = await req('GET', p, OLD_HOST);
    assert.notEqual(r.status, 301, p);
    assert.equal(r.headers.location, undefined, p);
  }
  for (const p of ['/e/abcdefghijklmnopqrstuvwxyz012345', '/watch', '/uploads/x.jpg']) {
    assert.notEqual((await req('GET', p, OLD_HOST)).status, 301, p);
  }
  // WebSocket upgrade on the old host is handled by the socket server (auth), never by a redirect.
  const ws = await new Promise((resolve) => {
    const r = http.request({ host: '127.0.0.1', port, path: '/ws', headers: { host: OLD_HOST, connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==' } });
    const done = (v) => { clearTimeout(t); r.destroy(); resolve(v); };
    const t = setTimeout(() => done({ status: 0, headers: {} }), 3000);
    r.on('response', (res) => { res.resume(); done({ status: res.statusCode, headers: res.headers }); });
    r.on('upgrade', (res, socket) => { socket.destroy(); done({ status: res.statusCode, headers: res.headers }); });
    r.on('error', () => done({ status: 0, headers: {} }));
    r.end();
  });
  assert.notEqual(ws.status, 301);
  assert.equal(ws.headers.location, undefined);
  // Pure rules.
  const cfg = { publicOrigin: NEW, legacyOrigins: ['https://coroute.duckdns.org'], redirectLegacyHost: true };
  const at = (method, path) => D.legacyRedirectTarget(cfg, { method, host: OLD_HOST, path, url: path });
  for (const p of ['/api/auth/login', '/api', '/ws', '/ws/x', '/.well-known/assetlinks.json', '/e/tok', '/watch', '/watch-sw.js']) {
    assert.equal(at('GET', p), null, p);
  }
  assert.equal(at('POST', '/features'), null);
  assert.equal(at('GET', '/join/ABC123'), `${NEW}/join/ABC123`);
  assert.equal(D.legacyRedirectTarget({ ...cfg, redirectLegacyHost: false }, { method: 'GET', host: OLD_HOST, path: '/', url: '/' }), null, 'flag off');
  assert.equal(D.legacyRedirectTarget({ ...cfg, publicOrigin: '' }, { method: 'GET', host: OLD_HOST, path: '/', url: '/' }), null, 'no target');
  assert.equal(D.legacyRedirectTarget({ ...cfg, publicOrigin: 'http://coroute.devmonks.space' }, { method: 'GET', host: OLD_HOST, path: '/', url: '/' }), null, 'never to http');
});

test('assetlinks.json is identical on both hosts (App Links verify each host directly)', async () => {
  const a = await req('GET', '/.well-known/assetlinks.json', NEW_HOST);
  const b = await req('GET', '/.well-known/assetlinks.json', OLD_HOST);
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.match(a.headers['content-type'], /application\/json/);
  assert.equal(a.body, b.body);
  const j = JSON.parse(a.body);
  assert.equal(j[0].target.package_name, 'space.devmonks.coroute_app');
  assert.ok(j[0].relation.includes('delegate_permission/common.handle_all_urls'));
});

test('invite pages on the new host render (App Link fallback page)', async () => {
  const r = await req('GET', '/join/ABC123', NEW_HOST);
  assert.equal(r.status, 200);
  assert.ok(r.body.includes('ABC123'));
  const f = await req('GET', '/join/friend/5TLBM452', NEW_HOST);
  assert.equal(f.status, 200);
});

test('guardian watch pages open on either host pass the Origin check; others are refused', async () => {
  const express = require('express');
  const { guardianRouter } = require('../src/guardian_routes');
  const service = { snapshot: async () => ({ expiresAt: Date.now() + 60000 }), convoys: null };
  const app = express();
  app.use(express.json());
  app.use('/api/guardian', guardianRouter({ service, gate: null, origin: NEW, allowedOrigins: D.siteOriginsOf(config) }));
  const srv = app.listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  try {
    const post = (origin) => fetch(`http://127.0.0.1:${srv.address().port}/api/guardian/ticket`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify({ ticket: 't'.repeat(40) }) });
    assert.equal((await post(NEW)).status, 201);
    assert.equal((await post('https://coroute.duckdns.org')).status, 201);
    assert.equal((await post('https://evil.example')).status, 403);
  } finally { srv.close(); }
});
