'use strict';
/**
 * Round 6 clean-up (b): the LIVE (vm1) / WEB (vm2) route split is complete and strict.
 *  - every route the booted gateway serves is classified in deploy/route_split.md (the same walk as the route
 *    permission table, src/route_policy.js; test/route_policy_357.test.js checks the access policy of the same list);
 *  - the generated Caddy matcher in deploy/caddy/Caddyfile.vm1 is current;
 *  - routes that read or change in-memory ride state are LIVE, account / shop / batch routes are WEB;
 *  - deploy/release.sh fails on an unclassified route.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { boot } = require('./_helpers');
const { walkRoutes, policyOf } = require('../src/route_policy');
const gen = require('../deploy/gen_caddy_routes');

let env; let routes; let rows;
before(async () => {
  env = await boot();
  rows = gen.parseRows();
  routes = [];
  for (const k of walkRoutes(env.gw.app)) {
    const method = k.slice(0, k.indexOf(' '));
    for (const p of k.slice(k.indexOf(' ') + 1).split(',')) routes.push({ key: k, method: method === '_ALL' ? '*' : method, path: p.length > 1 ? p.replace(/\/$/, '') : p });
  }
});
after(async () => { await env.gw.shutdown(); });

const clsOf = (method, p) => gen.classify(rows, method, p).cls;

test('every served route is classified LIVE or WEB (no route falls through to vm2 unnoticed)', () => {
  assert.ok(routes.length > 500, `walked ${routes.length} routes`);
  const missing = gen.classifyAll(rows, routes).filter((r) => !r.cls).map((r) => `${r.method} ${r.path}`);
  assert.deepEqual(missing, [], 'add these to gateway/deploy/route_split.md, then run node deploy/gen_caddy_routes.js');
});

test('the same route list has an access policy for every route (route_policy stays in sync with the split)', () => {
  assert.deepEqual(routes.filter((r) => !policyOf(r.key)).map((r) => r.key), []);
});

test('the generated LIVE matcher in Caddyfile.vm1 is current, and the file holds no real private address', () => {
  assert.equal(gen.caddyInSync(rows), true, 'run node deploy/gen_caddy_routes.js');
  for (const f of ['Caddyfile.vm1', 'Caddyfile.vm2']) {
    const text = fs.readFileSync(path.join(__dirname, '..', 'deploy', 'caddy', f), 'utf8');
    const ips = [...text.matchAll(/\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g)].map((m) => m[0]).filter((ip) => !['127.0.0.1', '1.1.1.1', '8.8.8.8', '0.0.0.0'].includes(ip));
    assert.deepEqual(ips, [], `${f}: addresses belong in deploy/inventory.local.env`);
  }
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'deploy', 'caddy', 'Caddyfile.vm1'), 'utf8'), /reverse_proxy VM2_PRIVATE_IP:3000 127\.0\.0\.1:3000/);
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'deploy', 'setup_node.sh'), 'utf8'), /s\/VM2_PRIVATE_IP\/\$PEER_IP\/g/);
});

test('realtime routes are LIVE (vm1): rooms, sockets, SOS, live links, operator console, crew ride invites', () => {
  const live = [
    ['GET', '/ws'], ['POST', '/api/convoys'], ['POST', '/api/convoys/join'], ['GET', '/api/convoys/GRP1'],
    ['POST', '/api/v1/sos/dispatch-external'], ['GET', '/e/abcdef'], ['GET', '/api/public/live/abcdef'], ['PATCH', '/api/me'], ['DELETE', '/api/me'],
    ['POST', '/api/operator/op1/rides/r1/start'], ['POST', '/api/operator/op1/rides/r1/end'], ['GET', '/api/operator/op1/live'], ['GET', '/api/operator/me'],
    ['POST', '/api/crews/c1/ride-invites'], ['POST', '/api/ride-invites/i1/accept'], ['GET', '/api/me/ride-invites'],
    ['GET', '/api/admin/fleet'], ['GET', '/api/admin/emergencies'], ['POST', '/api/admin/public-ride/users/u1/suspension'],
    ['GET', '/api/admin/riders/u1'], ['POST', '/api/admin/riders/u1/ride-lock/end'], ['GET', '/api/admin/intel/overview'],
    ['GET', '/api/guardian/view'], ['GET', '/api/health/live'],
  ];
  for (const [m, p] of live) assert.equal(clsOf(m, p), 'LIVE', `${m} ${p}`);
});

test('account, social, shop, e-mail tools, admin batch pages and Business analytics are WEB (vm2)', () => {
  const web = [
    ['POST', '/api/auth/login'], ['GET', '/api/me'], ['GET', '/api/me/sessions'], ['POST', '/api/me/mfa/setup'],
    ['GET', '/api/friends'], ['POST', '/api/friends/requests'], ['GET', '/api/crews'], ['POST', '/api/crews/c1/polls/p1/vote'],
    ['GET', '/api/users/search'], ['POST', '/api/me/avatar'], ['GET', '/api/convoys/GRP1/usernames'], ['GET', '/api/convoys/GRP1/timeline'],
    ['POST', '/api/rides/slug/signup'], ['POST', '/api/clubs/join'], ['POST', '/api/operators/apply'],
    ['POST', '/api/intel/events'], ['GET', '/api/intel/hazards'], ['POST', '/api/sms/receipts/twilio/tok'],
    ['POST', '/api/membership/webhook'], ['POST', '/api/subscription/webhook'], ['POST', '/email/unsubscribe'],
    ['GET', '/api/admin/riders'], ['POST', '/api/admin/riders/u1/email'], ['POST', '/api/admin/email-studio/campaigns'],
    ['GET', '/api/admin/business/overview'], ['GET', '/api/admin/business/servers'], ['GET', '/api/admin/web/revenue'],
    ['GET', '/plans'], ['GET', '/admin'], ['GET', '/assets/site.css'],
  ];
  for (const [m, p] of web) assert.equal(clsOf(m, p), 'WEB', `${m} ${p}`);
  // The website catch-all never classifies an API path.
  assert.equal(clsOf('GET', '/api/not-a-route'), null);
  assert.equal(clsOf('POST', '/api/brand/new'), null);
});

test('a route that loads or reads a live room in its handler is never classified WEB', () => {
  // Source check for the modules that own in-memory ride state: a handler line that touches rooms must sit in a LIVE path.
  const liveOnly = [/^\/api\/operator\//, /^\/api\/(crews\/[^/]+\/)?ride-invites/, /^\/api\/me\/ride-invites$/];
  for (const r of routes) {
    if (!liveOnly.some((re) => re.test(r.path.replace(/:[A-Za-z_]+/g, 'x1')))) continue;
    assert.equal(clsOf(r.method === '*' ? 'GET' : r.method, r.path.replace(/:[A-Za-z_]+/g, 'x1')), 'LIVE', `${r.method} ${r.path}`);
  }
});

test('release.sh is strict: an unclassified route stops the release (only --skip-route-check skips, and says so)', () => {
  const sh = fs.readFileSync(path.join(__dirname, '..', 'deploy', 'release.sh'), 'utf8');
  assert.match(sh, /gen_caddy_routes\.js --check/);
  assert.match(sh, /route split check failed[^\n]*\n\s*\[ "\$DRY" = 1 \] && note "[^"]*" \|\| exit 1/);
  assert.match(sh, /--skip-route-check\) SKIP_ROUTES=1/);
  assert.doesNotMatch(sh, /they go to vm2 as WEB in Caddy/);
  // The checker itself reports an unclassified route.
  const without = rows.filter((r) => !(r.cls === 'WEB' && r.path === '/api/friends/*'));
  const out = gen.classifyAll(without, [{ method: 'GET', path: '/api/friends/suggestions' }]);
  assert.equal(out[0].cls, null);
});
