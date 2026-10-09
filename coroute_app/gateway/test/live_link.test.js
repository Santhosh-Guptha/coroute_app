'use strict';
/**
 * 3.16 live emergency links: who may create and revoke one, one valid link per alert, at most 3 per alert,
 * the token shape, the public JSON view (first name and position only), 410 after revoke / resolve /
 * expiry, 404 for malformed tokens, headers, audit rows without the token, the /e/<token> page and the
 * public limiter.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'liveadmin@coroute.test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 9, 9, 6, 0, 0);
let now = T0;
let t, gw, admin;
before(async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  t = await boot(); gw = t.gw;
  admin = await t.register('Live Admin', 'liveadmin@coroute.test');
  assert.equal(admin.user.role, 'MASTER_ADMIN');
});
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
/** A ride with a lead, the SOS owner (Kiran Rao) and a pack rider; the owner raises an SOS. */
async function emergency() {
  n++;
  const lead = await t.register(`Live Lead ${n}`, `livelead${n}@coroute.test`);
  const owner = await t.register(`Kiran Rao ${n}`, `liveowner${n}@coroute.test`);
  const pack = await t.register(`Pack ${n}`, `livepack${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Live ${n}` }, lead.token)).json;
  for (const u of [owner, pack]) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wo = await t.joinRoom(owner.token, c.groupId);
  wo.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH_OR_EMERGENCY', clientId: `live-${n}` });
  const alert = (await wl.next((m) => m.type === 'ALERT')).alert;
  return { lead, owner, pack, c, gid: c.groupId, alert, wl, wo, close: () => { wl.close(); wo.close(); } };
}
const link = (E, tok) => t.api('POST', `/convoys/${E.gid}/alerts/${E.alert.alertId}/live-link`, {}, tok);
const unlink = (E, tok) => t.api('DELETE', `/convoys/${E.gid}/alerts/${E.alert.alertId}/live-link`, undefined, tok);
const view = (token) => fetch(`${t.origin}/api/public/live/${token}`);
async function auditRows() { await gw.audit.flush(); return gw.repo.listAudit({ limit: 500 }); }

/** Every string value anywhere in an object. */
function strings(o, out = []) {
  if (typeof o === 'string') out.push(o);
  else if (o && typeof o === 'object') for (const v of Object.values(o)) strings(v, out);
  return out;
}

test('owner and lead may create; pack and admin may not; closed alert 404; one valid link per alert; revoke then again; max 3', async () => {
  const E = await emergency();
  assert.equal((await link(E, E.pack.token)).status, 403);
  assert.equal((await link(E, E.pack.token)).json.code, 'NOT_ALLOWED');
  assert.equal((await link(E, admin.token)).status, 403, 'an admin is not a member');
  const made = await link(E, E.owner.token);
  assert.equal(made.status, 200, JSON.stringify(made.json));
  assert.match(made.json.token, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(made.json.url, `${t.origin}/e/${made.json.token}`);
  assert.equal(made.json.expiresAt, now + 30 * 60000);
  assert.match(made.headers.get('cache-control'), /no-store/);
  // The room sees only the times, never the hash or the token.
  const up = await E.wl.next((m) => m.type === 'EMERGENCY_UPDATE' || m.type === 'ALERT', 500).catch(() => null);
  const snap = (await t.api('GET', `/convoys/${E.gid}`, undefined, E.lead.token)).json;
  const a = snap.activeAlerts.find((x) => x.alertId === E.alert.alertId);
  assert.deepEqual(a.liveLink, { expiresAt: made.json.expiresAt, revokedAt: 0 });
  assert.ok(!JSON.stringify(snap).includes(made.json.token));
  assert.ok(!JSON.stringify(snap).includes('hash'));
  if (up) assert.ok(!JSON.stringify(up).includes(made.json.token));
  // A second create while the first lives: 409 with its expiry.
  const again = await link(E, E.lead.token);
  assert.equal(again.status, 409);
  assert.equal(again.json.code, 'LINK_ACTIVE');
  assert.equal(again.json.expiresAt, made.json.expiresAt);
  // Revoke (lead may), then a new one may be made; the old token is dead.
  assert.equal((await unlink(E, E.pack.token)).status, 403);
  assert.equal((await unlink(E, E.lead.token)).status, 200);
  assert.equal((await view(made.json.token)).status, 410);
  const second = await link(E, E.lead.token);
  assert.equal(second.status, 200);
  assert.notEqual(second.json.token, made.json.token);
  assert.equal((await view(second.json.token)).status, 200);
  assert.equal((await unlink(E, E.owner.token)).status, 200);
  const third = await link(E, E.owner.token);
  assert.equal(third.status, 200);
  assert.equal((await unlink(E, E.owner.token)).status, 200);
  const fourth = await link(E, E.owner.token);
  assert.equal(fourth.status, 429, 'at most 3 per alert');
  assert.equal(fourth.json.code, 'LINK_LIMIT');
  // The stored alert keeps only the hash and the times.
  const stored = (await gw.repo.listAlerts(E.gid)).find((x) => x.alertId === E.alert.alertId);
  assert.equal(stored.liveLink.hash.length, 64);
  assert.ok(stored.liveLink.revokedAt > 0);
  assert.equal(stored.liveLinkCount, 3);
  // Closed alert: 404.
  assert.equal((await t.api('POST', `/convoys/${E.gid}/alerts/SOS-nope/live-link`, {}, E.lead.token)).status, 404);
  E.wo.sendJson({ type: 'SOS_RESOLVE', alertId: E.alert.alertId });
  await E.wl.next((m) => m.type === 'ALERT_RESOLVED');
  assert.equal((await link(E, E.lead.token)).status, 404);
  E.close();
});

test('public view: first name and the rider\'s current position only; 410 after resolve and after expiry; 404 for bad tokens; headers; audit', async () => {
  const E = await emergency();
  const made = await link(E, E.owner.token);
  assert.equal(made.status, 200);
  const r = await view(made.json.token);
  assert.equal(r.status, 200);
  assert.match(r.headers.get('cache-control'), /no-store/);
  assert.match(r.headers.get('x-robots-tag'), /noindex/);
  const j = await r.json();
  assert.deepEqual(Object.keys(j).sort(), ['active', 'at', 'expiresAt', 'firstName', 'lat', 'lng']);
  assert.equal(j.firstName, 'Kiran');
  assert.equal(j.lat, 17.385);
  assert.equal(j.lng, 78.4867);
  assert.equal(j.active, true);
  assert.equal(j.expiresAt, made.json.expiresAt);
  for (const s of strings(j)) {
    assert.ok(!s.includes(E.owner.user.userId) && !s.includes(E.gid) && !s.includes('+9198765') && !s.includes('Rao') && !s.includes('@'), `leaked: ${s}`);
  }
  // The rider moves: the view follows the room position, 5 decimals.
  advance(10000);
  const room = gw.convoys.rooms.get(E.gid);
  gw.convoys.patchRider(room, E.owner.user.userId, { lat: 17.3912345, lng: 78.4901234, speedKmh: 0 }, { emit: false });
  const j2 = await (await view(made.json.token)).json();
  assert.equal(j2.lat, 17.39123);
  assert.equal(j2.lng, 78.49012);
  assert.equal(j2.at, now);
  // Malformed tokens are 404 (never 410: nothing is learnt about real links).
  for (const bad of ['short', 'A'.repeat(31), 'A'.repeat(33), `${'A'.repeat(31)}!`, '%2e%2e', 'A'.repeat(32).replace('A', '.')]) {
    assert.ok([404, 401].includes((await fetch(`${t.origin}/api/public/live/${bad}`)).status), bad); // ".." resolves to the authenticated API: 401
  }
  assert.equal((await view('B'.repeat(32))).status, 410, 'well formed but unknown');
  // Resolved: 410, and the link is revoked on the alert.
  E.wo.sendJson({ type: 'SOS_RESOLVE', alertId: E.alert.alertId });
  await E.wl.next((m) => m.type === 'ALERT_RESOLVED');
  assert.equal((await view(made.json.token)).status, 410);
  assert.ok(room.alerts.get(E.alert.alertId).liveLink.revokedAt > 0);
  E.close();

  // Expiry by the clock.
  const F = await emergency();
  const m2 = await link(F, F.owner.token);
  assert.equal((await view(m2.json.token)).status, 200);
  advance(29 * 60000);
  assert.equal((await view(m2.json.token)).status, 200, 'still valid at 29 minutes');
  advance(2 * 60000);
  assert.equal((await view(m2.json.token)).status, 410, 'expired at 31 minutes');
  assert.equal((await fetch(`${t.origin}/e/${m2.json.token}`)).status, 410);
  // Audit: CREATE / REVOKE / VIEW / EXPIRE rows with ids, never the token.
  const rows = (await auditRows()).filter((x) => x.kind === 'LIVE_LINK');
  const details = new Set(rows.map((x) => x.detail));
  for (const d of ['CREATE', 'REVOKE', 'VIEW', 'EXPIRE']) assert.ok(details.has(d), `audit ${d}`);
  const created = rows.find((x) => x.detail === 'CREATE' && x.alertId === F.alert.alertId);
  assert.equal(created.actorId, F.owner.user.userId);
  assert.equal(created.groupId, F.gid);
  const all = JSON.stringify(rows);
  for (const tok of [made.json.token, m2.json.token]) assert.ok(!all.includes(tok));
  assert.ok(!/17\.3|78\.4/.test(all), 'no coordinates in the audit');
  const views = rows.filter((x) => x.detail === 'VIEW' && x.alertId === E.alert.alertId);
  assert.equal(views.length, 1, 'views audited once per link per 5 minutes');
  F.close();
});

test('/e/<token> page: 200 with the first name while live, the expired page when dead, 404 for bad tokens; public limiter', async () => {
  const E = await emergency();
  const made = await link(E, E.owner.token);
  const page = await fetch(made.json.url);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);
  assert.match(page.headers.get('cache-control'), /no-store/);
  assert.match(page.headers.get('referrer-policy'), /no-referrer/);
  assert.match(page.headers.get('x-robots-tag'), /noindex/);
  const html = await page.text();
  assert.ok(html.includes('Kiran') && !html.includes('Kiran Rao'), 'first name only');
  assert.ok(html.includes('17.38500') && html.includes('78.48670'));
  assert.ok(html.includes('tel:112'));
  assert.ok(!/__[A-Z_]+__/.test(html) && !html.includes('<!--#include'));
  assert.ok(!html.includes(E.gid) && !html.includes(E.owner.user.userId));
  assert.equal((await fetch(`${t.origin}/e/not-a-token`)).status, 404);
  await unlink(E, E.owner.token);
  const dead = await fetch(made.json.url);
  assert.equal(dead.status, 410);
  assert.ok((await dead.text()).includes('This link has expired'));
  // Public limiter: 60 a minute per network for the JSON view.
  let last = 0;
  for (let i = 0; i < 70; i++) last = (await view(made.json.token)).status;
  assert.equal(last, 429);
  E.close();
  await sleep(10);
});
