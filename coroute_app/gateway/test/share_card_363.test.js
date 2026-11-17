'use strict';
/**
 * v3.63 rich invite cards (src/invite_cards.js): /join/<CODE> and /join/friend/<CODE> carry Open Graph + Twitter tags
 * so WhatsApp / Telegram / iMessage show a card. A valid ride code shows only the host's first name, the ride name,
 * the destination, the day and the rider count; an unknown code gets the generic card; nothing else leaks.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const IC = require('../src/invite_cards');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });

const og = (html, prop) => {
  const m = new RegExp(`<meta (?:property|name)="${prop}" content="([^"]*)">`).exec(html);
  return m ? m[1] : null;
};

test('valid ride code: host first name, ride, destination, rider count; no private details', async () => {
  const host = await t.register('Anusha Reddy Kolli', 'og.host@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Sunday breakfast', destination: 'Nandi Hills', startPoint: '12 Secret Lane, my home', destLat: 13.37, destLng: 77.68 }, host.token)).json;
  const res = await fetch(`${t.origin}/join/${c.joinCode}`);
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.equal(og(html, 'og:title'), 'Join Anusha&#39;s ride: Nandi Hills');
  const d = og(html, 'og:description');
  assert.match(d, /Sunday breakfast/);
  assert.match(d, /1 rider so far/);
  assert.match(og(html, 'og:image'), /\/assets\/og\/ride\.png\?v=/);
  assert.equal(og(html, 'twitter:card'), 'summary_large_image');
  for (const secret of ['Secret Lane', 'Reddy', 'Kolli', '13.37', '77.68', 'og.host@']) assert.ok(!html.includes(secret), `leaks ${secret}`);
  assert.match(res.headers.get('cache-control') || '', /private/);
  assert.equal(res.headers.get('x-robots-tag'), 'noindex');
});

test('unknown code: generic card; friend invite: generic, never whose code', async () => {
  const html = await (await fetch(`${t.origin}/join/ZZZZ99`)).text();
  assert.equal(og(html, 'og:title'), 'Join a group ride on CoRoute');
  const u = await t.register('Friend Owner', 'og.friend@coroute.test');
  const me = (await t.api('GET', '/me/profile', null, u.token)).json;
  const code = me && (me.inviteCode || (me.profile && me.profile.inviteCode));
  assert.ok(code, 'friend invite code');
  {
    const fh = await (await fetch(`${t.origin}/join/friend/${code}`)).text();
    assert.equal(og(fh, 'og:title'), 'You have a riding friend invite on CoRoute');
    assert.ok(!fh.includes('Friend Owner'));
    assert.match(og(fh, 'og:image'), /\/assets\/og\/friend\.png\?v=/);
  }
});

test('escaping and length: a hostile ride name cannot break out of the tag', () => {
  const m = IC.inviteMeta('ride', { host: 'Ravi', ride: '"><script>alert(1)</script>', destination: '', startsAt: 0, riders: 0 }, 'https://x.example', '/join/AB12CD');
  const tags = IC.ogTags(m);
  assert.ok(!tags.includes('<script>'));
  assert.ok(tags.includes('&lt;script&gt;'));
  assert.ok(IC.clean('a'.repeat(300), 90).length <= 90);
  assert.equal(IC.firstName('  Meera   Nair '), 'Meera');
  assert.match(IC.whenText(Date.UTC(2026, 10, 22, 1, 0)), /^Sun 22 Nov, 6:30 am$/);
});

test('trip report counts the road hazards logged on the ride (the ride card shows it)', () => {
  const { buildTripReport } = require('../src/report');
  const t0 = Date.now() - 3600000;
  const meta = { name: 'R', createdAtEpochMs: t0, endedAtEpochMs: t0 + 3000000, members: { u1: { userId: 'u1', name: 'A', joinedAt: t0 } }, stopPoints: [] };
  const events = [
    { type: 'ROAD_HAZARD', userId: 'u1', startedAt: t0 + 1000 },
    { type: 'ROAD_HAZARD', userId: 'u1', startedAt: t0 + 2000 },
    { type: 'STOPPED', userId: 'u1', startedAt: t0 + 3000 },
  ];
  const { report } = buildTripReport({ meta, tracksByUser: new Map(), events });
  assert.equal(report.group.hazards, 2);
});
