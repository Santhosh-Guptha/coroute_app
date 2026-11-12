'use strict';
/**
 * 3.57 security: central route permission table (src/route_policy.js). Fails when a route has no declared policy,
 * when a declared-public route no longer exists, or when a route does not enforce what it declares:
 *   auth / admin / operator -> anonymous gets 401
 *   admin                   -> a signed-in rider gets 403
 *   operator                -> a rider who is not that operator's owner / co-organiser gets 403 or 404
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { walkRoutes, policyOf, PUBLIC, OTHER } = require('../src/route_policy');

let env; let routes; let rider;
before(async () => {
  env = await boot();
  routes = walkRoutes(env.gw.app);
  rider = await env.register('Policy Rider', 'policy.rider@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

const urlOf = (path) => path.split(',')[0].replace(/:[A-Za-z_]+(\([^)]*\))?\??/g, 'x1234').replace(/\*$/, 'x');
async function hit(method, path, token) {
  const m = method === '_ALL' ? 'GET' : method;
  const res = await fetch(env.origin + urlOf(path), {
    method: m, redirect: 'manual',
    headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': `10.88.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}`, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: ['GET', 'HEAD'].includes(m) ? undefined : '{}',
  });
  await res.arrayBuffer().catch(() => null);
  return res.status;
}

test('every route has a declared access policy', () => {
  assert.ok(routes.length > 300, `walked ${routes.length} routes`);
  const missing = routes.filter((k) => !policyOf(k));
  assert.deepEqual(missing, [], 'add these routes to src/route_policy.js');
});

test('declared public routes exist (no stale entries)', () => {
  const set = new Set(routes);
  const stale = [...Object.keys(PUBLIC), ...Object.keys(OTHER)].filter((k) => !set.has(k));
  assert.deepEqual(stale, []);
});

test('auth / admin / operator routes refuse anonymous callers (401)', async () => {
  const bad = [];
  for (const k of routes) {
    const p = policyOf(k);
    if (!['auth', 'admin', 'operator'].includes(p)) continue;
    const [method, path] = [k.slice(0, k.indexOf(' ')), k.slice(k.indexOf(' ') + 1)];
    const st = await hit(method, path, null);
    if (st !== 401) bad.push(`${k} -> ${st}`);
  }
  assert.deepEqual(bad, [], 'these routes answer anonymous callers: declare them public or protect them');
});

test('admin routes refuse a signed-in rider (403); operator routes refuse a stranger (403/404)', async () => {
  const bad = [];
  for (const k of routes) {
    const p = policyOf(k);
    if (p !== 'admin' && p !== 'operator') continue;
    const [method, path] = [k.slice(0, k.indexOf(' ')), k.slice(k.indexOf(' ') + 1)];
    const st = await hit(method, path, rider.token);
    if (p === 'admin' ? st !== 403 : ![403, 404].includes(st)) bad.push(`${k} -> ${st}`);
  }
  assert.deepEqual(bad, []);
  // The rider's account is untouched by all of that.
  assert.equal((await env.api('GET', '/me', null, rider.token)).status, 200);
});
