'use strict';
/**
 * 3.56 admin push campaigns (src/push_campaigns.js, docs/features_355/notifications_admin.md):
 * validation, the Play-policy guard (same terms as tool/play_policy_scan.dart), targeting, scheduling
 * with the claim lease, the per-rider daily cap, the "News and updates" opt-out, image validation
 * (type, size, metadata stripped, public https URL) and the FCM data message (image, target).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'newsadmin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
delete process.env.FCM_SERVICE_ACCOUNT_JSON;
delete process.env.FCM_SERVICE_ACCOUNT_FILE;

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { PushCampaigns, createImageStore } = require('../src/push_campaigns');
const { APP_SCAN_TERMS, forbiddenTermIn } = require('../src/policy_terms');
const P = require('../src/push');

const sent = [];
const transport = async (message) => { sent.push(message); return { status: 200, body: { name: 'projects/x/messages/1' } }; };
const tok = (n) => `newstoken_${String(n).padStart(4, '0')}_${'y'.repeat(40)}`;
const imageDir = fs.mkdtempSync(path.join(os.tmpdir(), 'coroute-push-img-'));

let t, admin, riderA, riderB;
let seq = 0;
async function rider(name) {
  seq++;
  const r = await t.api('POST', '/auth/register', {
    name, email: `news${seq}_${Date.now()}@coroute.test`, password: 'Password#123',
    phone: `+9195${String(10000000 + seq).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA03NW${String(1000 + seq).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  }, null, { 'X-Forwarded-For': `203.0.113.${(seq % 250) + 1}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
const api = (m, p, b, token) => t.api(m, p, b, token, { 'X-Forwarded-For': `198.51.100.${(token || '').length % 200}` });

before(async () => {
  t = await boot({ pushTransport: transport, pushImageStore: createImageStore({ dir: imageDir }) });
  // The bootstrap admin (BOOTSTRAP_ADMIN_EMAILS).
  const r = await t.api('POST', '/auth/register', {
    name: 'News Admin', email: 'newsadmin@coroute.test', password: 'Password#123', phone: '+919811100001', vehicleType: 'Motorcycle',
    vehicleNo: 'KA03AD0001', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  }, null, { 'X-Forwarded-For': '203.0.113.251' });
  admin = r.json;
  riderA = await rider('Asha Rider');
  riderB = await rider('Bala Rider');
  for (const [u, n] of [[admin, 1], [riderA, 2], [riderB, 3]]) {
    assert.equal((await api('POST', '/me/push-tokens', { token: tok(n), platform: 'android', appVersion: '3.56.0' }, u.token)).status, 200);
  }
});
after(async () => { await t.gw.shutdown(); fs.rmSync(imageDir, { recursive: true, force: true }); });

// ------------------------------------------------------------ policy terms
test('the server guard covers every term of the app scan (tool/play_policy_scan.dart)', () => {
  const dart = fs.readFileSync(path.join(__dirname, '..', '..', 'tool', 'play_policy_scan.dart'), 'utf8');
  const m = /forbiddenTerms = RegExp\(\s*r'\(([^']+)\)'/.exec(dart);
  assert.ok(m, 'the scan regex is found');
  for (const term of m[1].split('|')) assert.ok(APP_SCAN_TERMS.includes(term), `server list has ${term}`);
  for (const s of ['Get 20% off today', 'Use coupon RIDE10', 'New price drop', 'Upgrade now', 'Buy a plan', 'Only ₹99', 'Renew your plan', 'Big sale this week', 'Special offer for you', 'See coroute.example/plans', 'Pay with UPI']) {
    assert.ok(forbiddenTermIn(s), `refused: ${s}`);
  }
  for (const s of ['New: ride replays are here', 'Crews can now run polls', 'Stay safe on the highway this weekend']) assert.equal(forbiddenTermIn(s), null, s);
});

// ------------------------------------------------------------ validation through the API
test('admin only; title / body limits, Play-policy guard, links and personal data refused', async () => {
  const good = { title: 'Crew polls are here', body: 'Ask your crew where to ride next.', target: 'crews', audience: { kind: 'all' } };
  assert.equal((await api('POST', '/admin/push/campaigns', good, riderA.token)).status, 403);
  let r = await api('POST', '/admin/push/campaigns', { ...good, title: 'x'.repeat(66) }, admin.token);
  assert.equal(r.status, 400); assert.equal(r.json.code, 'TITLE_TOO_LONG');
  r = await api('POST', '/admin/push/campaigns', { ...good, body: 'y'.repeat(241) }, admin.token);
  assert.equal(r.status, 400); assert.equal(r.json.code, 'BODY_TOO_LONG');
  r = await api('POST', '/admin/push/campaigns', { ...good, body: 'Use coupon RIDE20 for a discount' }, admin.token);
  assert.equal(r.status, 422); assert.equal(r.json.code, 'PLAY_POLICY');
  assert.match(r.json.error, /website board or in an e-mail/);
  r = await api('POST', '/admin/push/test', { ...good, title: 'Upgrade to Large Group' }, admin.token);
  assert.equal(r.status, 422, 'the test send is guarded too');
  r = await api('POST', '/admin/push/campaigns', { ...good, body: 'Read more at https://coroute.example/blog' }, admin.token);
  assert.equal(r.status, 422); assert.equal(r.json.code, 'NO_LINKS');
  r = await api('POST', '/admin/push/campaigns', { ...good, body: 'Call us on +91 98765 43210' }, admin.token);
  assert.equal(r.status, 422); assert.equal(r.json.code, 'PERSONAL_DATA');
  r = await api('POST', '/admin/push/campaigns', { ...good, target: 'plans' }, admin.token);
  assert.equal(r.status, 400); assert.equal(r.json.code, 'BAD_TARGET');
  r = await api('POST', '/admin/push/campaigns', { ...good, audience: { kind: 'active', days: 0 } }, admin.token);
  assert.equal(r.status, 400);
  r = await api('POST', '/admin/push/campaigns', { ...good, sendAt: Date.now() - 3600000 }, admin.token);
  assert.equal(r.status, 400); assert.equal(r.json.code, 'BAD_TIME');
  const cfg = await api('GET', '/admin/push/config', null, admin.token);
  assert.deepEqual(cfg.json.targets, ['home', 'friends', 'crews', 'rides', 'settings']);
  assert.equal(cfg.json.limits.title, 65);
});

// ------------------------------------------------------------ images
function pngWithText() {
  const crc = () => Buffer.alloc(4);
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); return Buffer.concat([len, Buffer.from(type, 'ascii'), data, crc()]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(2, 0); ihdr.writeUInt32BE(2, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), chunk('IHDR', ihdr), chunk('tEXt', Buffer.from('GPS\0 12.97,77.59 secret place')), chunk('IDAT', Buffer.alloc(10)), chunk('IEND', Buffer.alloc(0))]);
}
const upload = (buf, type = 'image/png', token = admin.token) => fetch(`${t.base}/admin/push/images`, {
  method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': type, 'X-Forwarded-For': '198.51.100.9' }, body: buf,
}).then(async (res) => ({ status: res.status, json: await res.json().catch(() => ({})) }));

test('images: JPEG / PNG / WebP only, 1 MB at most, metadata removed, public https URL', async () => {
  const r = await upload(pngWithText());
  assert.equal(r.status, 201, JSON.stringify(r.json));
  assert.match(r.json.image.url, /^https:\/\/coroute\.example\/media\/push\/pi_[a-f0-9]{24}\.png$/);
  assert.ok(P.IMAGE_URL_RE.test(r.json.image.url));
  const file = r.json.image.url.split('/').pop();
  const res = await fetch(`${t.origin}/media/push/${file}`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'image/png');
  assert.match(res.headers.get('cache-control'), /public/);
  const body = Buffer.from(await res.arrayBuffer());
  assert.ok(!body.includes(Buffer.from('secret place')), 'PNG text chunk (location) stripped');
  assert.equal((await upload(Buffer.from('GIF89a' + 'x'.repeat(50)), 'image/gif')).status, 415);
  const big = Buffer.concat([pngWithText(), Buffer.alloc(1024 * 1024 + 10)]);
  assert.equal((await upload(big)).status, 413);
  assert.equal((await upload(pngWithText(), 'image/png', riderA.token)).status, 403, 'riders cannot upload');
  assert.equal((await fetch(`${t.origin}/media/push/pi_${'0'.repeat(24)}.png`)).status, 404);
  assert.equal((await fetch(`${t.origin}/media/push/../../src/app.js`)).status, 404);
  t.imageId = r.json.image.imageId;
});

// ------------------------------------------------------------ test send, FCM message, history
test('test send reaches only the admin, carries title, body (240), image and target; history counts it', async () => {
  sent.length = 0;
  const body = `${'Ride safe this weekend. '.repeat(10)}`.slice(0, 240);
  const r = await api('POST', '/admin/push/test', { title: 'Weekend ride tips', body, target: 'rides', imageId: t.imageId }, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.result.sent, 1);
  assert.equal(sent.length, 1);
  const m = sent[0].message;
  assert.equal(m.token, tok(1));
  assert.equal(m.data.type, 'NEWS');
  assert.equal(m.data.title, 'Weekend ride tips');
  assert.equal(m.data.body, body.trim(), 'body up to 240 characters is not clipped');
  assert.equal(m.data.target, 'rides');
  assert.match(m.data.imageUrl, /^https:\/\/coroute\.example\/media\/push\//);
  assert.ok(!('notification' in m), 'data-only message');
  const h = await api('GET', '/admin/push/campaigns', null, admin.token);
  const row = h.json.campaigns.find((c) => c.test);
  assert.equal(row.status, 'SENT');
  assert.equal(row.stats.sent, 1);
});

test('send now to usernames: only those riders; opted-out riders are skipped', async () => {
  const meB = await api('GET', '/me', null, riderB.token);
  const meA = await api('GET', '/me', null, riderA.token);
  const nameA = (meA.json.user || meA.json).username; const nameB = (meB.json.user || meB.json).username;
  assert.ok(nameA && nameB, 'riders have usernames');
  assert.equal((await api('PUT', '/me/push-prefs', { news: false }, riderB.token)).status, 200);
  assert.equal((await api('GET', '/me/push-prefs', null, riderB.token)).json.news, false);
  assert.equal((await api('PUT', '/me/push-prefs', { news: 'no' }, riderB.token)).status, 400);
  const cnt = await api('POST', '/admin/push/audience-count', { audience: { kind: 'users', usernames: [nameA, nameB] } }, admin.token);
  assert.deepEqual(cnt.json, { riders: 1, optedOut: 1 });
  sent.length = 0;
  const r = await api('POST', '/admin/push/campaigns', { title: 'Hello riders', body: 'New ride replays are in the app.', target: 'home', audience: { kind: 'users', usernames: [nameA, nameB] } }, admin.token);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  await t.gw.notifications.campaigns.tick();
  const c = (await api('GET', `/admin/push/campaigns/${r.json.campaign.campaignId}`, null, admin.token)).json.campaign;
  assert.equal(c.status, 'SENT');
  assert.equal(c.stats.targeted, 2);
  assert.equal(c.stats.reached, 1);
  assert.equal(c.stats.optedOut, 1);
  assert.deepEqual(sent.map((m) => m.message.token), [tok(2)]);
  await api('PUT', '/me/push-prefs', { news: true }, riderB.token);
});

test('a scheduled campaign can be cancelled before it starts', async () => {
  const r = await api('POST', '/admin/push/campaigns', { title: 'Later', body: 'Later message.', audience: { kind: 'all' }, sendAt: Date.now() + 3600000 }, admin.token);
  assert.equal(r.json.campaign.status, 'SCHEDULED');
  const c = await api('POST', `/admin/push/campaigns/${r.json.campaign.campaignId}/cancel`, null, admin.token);
  assert.equal(c.json.campaign.status, 'CANCELLED');
  assert.equal((await api('POST', `/admin/push/campaigns/${r.json.campaign.campaignId}/cancel`, null, admin.token)).status, 409);
});

// ------------------------------------------------------------ unit: targeting, scheduling, cap, lease
async function unitSetup({ now }) {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  const users = { u1: { lastLoginAt: now - 2 * 86400000 }, u2: { lastLoginAt: now - 40 * 86400000 }, u3: { lastActiveAt: now - 3600000 }, u4: { lastLoginAt: now } };
  for (const [userId, f] of Object.entries(users)) await soda.insert('users', { userId, email: `${userId}@x.test`, ...f });
  await soda.ensureCollection('push_tokens');
  for (const uid of Object.keys(users)) await soda.insert('push_tokens', { userId: uid, token: `tok_${uid}_${'z'.repeat(30)}`, platform: 'android' });
  await soda.insert('memberships', { ownerUserId: 'u1', category: 'group_small', status: 'ACTIVE', validUntil: now + 86400000 });
  await soda.insert('memberships', { ownerUserId: 'u3', category: 'group_large', status: 'ACTIVE', validUntil: now + 86400000 });
  await soda.insert('memberships', { ownerUserId: 'u2', category: 'group_large', status: 'ACTIVE', validUntil: now - 1 }); // ended
  const calls = [];
  const push = { enabled: true, async notifyUsers(ids, msg) { calls.push({ ids, msg }); return { sent: 1, failed: 0, skipped: 0 }; } };
  const clock = { t: now };
  const sleeps = [];
  const svc = new PushCampaigns({ soda, repo, push, origin: 'https://coroute.example', clock: () => clock.t, sleep: async (ms) => { sleeps.push(ms); }, batchSize: 2, ratePerSec: 1, dailyCap: 2, logger: { info() {}, warn() {} } });
  return { soda, repo, svc, calls, clock, sleeps };
}

test('targeting: all, active in N days, plan type', async () => {
  const now = Date.UTC(2026, 10, 10, 6, 0);
  const { svc } = await unitSetup({ now });
  const ids = async (a) => (await svc.resolveAudience(await svc.validateAudience(a))).sort();
  assert.deepEqual(await ids({ kind: 'all' }), ['u1', 'u2', 'u3', 'u4']);
  assert.deepEqual(await ids({ kind: 'active', days: 7 }), ['u1', 'u3', 'u4']);
  assert.deepEqual(await ids({ kind: 'active', days: 60 }), ['u1', 'u2', 'u3', 'u4']);
  assert.deepEqual(await ids({ kind: 'plan', plans: ['group_large'] }), ['u3']);
  assert.deepEqual(await ids({ kind: 'plan', plans: ['community'] }), ['u2', 'u4'], 'an ended plan counts as community');
  await assert.rejects(svc.validateAudience({ kind: 'plan', plans: ['gold'] }), /plan types/);
});

test('scheduling: not before sendAt; batches respect the rate; resumes after a crashed worker', async () => {
  const now = Date.UTC(2026, 10, 10, 6, 0);
  const { svc, calls, clock, sleeps, soda } = await unitSetup({ now });
  const c = await svc.create({ title: 'Morning ride', body: 'Good morning riders.', audience: { kind: 'all' }, sendAt: now + 3600000 });
  assert.equal(await svc.tick(), 0, 'not due yet');
  assert.equal(calls.length, 0);
  clock.t = now + 3600000;
  assert.equal(await svc.tick(), 1);
  const done = await svc.get(c.campaignId);
  assert.equal(done.status, 'SENT');
  assert.equal(done.stats.reached, 4);
  assert.equal(calls.length, 4);
  assert.equal(calls[0].msg.type, 'NEWS');
  assert.equal(calls[0].msg.target, 'home');
  assert.deepEqual(sleeps, [2000], '2 tokens per batch at 1/s: one wait between the two batches');
  // A worker that died mid-campaign: its lease ends, another worker continues from the cursor.
  const c2 = await svc.create({ title: 'Second', body: 'Second message.', audience: { kind: 'all' } });
  const row = await soda.findOne('push_campaigns', { campaignId: c2.campaignId });
  await soda.replace('push_campaigns', row.key, { ...row.value, status: 'SENDING', worker: 'dead', leaseUntil: clock.t - 1, recipients: ['u1', 'u2', 'u3', 'u4'], cursor: 2, stats: { ...row.value.stats, targeted: 4, reached: 2, sent: 2 } });
  calls.length = 0;
  await svc.tick();
  assert.deepEqual(calls.map((x) => x.ids[0]), ['u3', 'u4'], 'resumed at the cursor');
  assert.equal((await svc.get(c2.campaignId)).stats.reached, 4);
});

test('frequency cap: at most 2 campaign pushes per rider per India day; opt-out respected', async () => {
  const now = Date.UTC(2026, 10, 10, 6, 0);
  const { svc, calls, clock } = await unitSetup({ now });
  await svc.setNews('u4', false);
  let last;
  for (let i = 0; i < 3; i++) { last = await svc.create({ title: `News ${i}`, body: 'Body.', audience: { kind: 'all' } }); await svc.tick(); }
  const per = (uid) => calls.filter((x) => x.ids[0] === uid).length;
  assert.equal(per('u1'), 2);
  assert.equal(per('u4'), 0, 'opted out');
  const third = await svc.get(last.campaignId);
  assert.equal(third.stats.capped, 3, 'third campaign: three riders capped');
  assert.equal(third.stats.optedOut, 1);
  clock.t = now + 86400000; // next India day
  await svc.create({ title: 'Next day', body: 'Body.', audience: { kind: 'all' } });
  await svc.tick();
  assert.equal(per('u1'), 3);
});

test('a campaign fails clearly when push is not configured', async () => {
  const now = Date.now();
  const { svc } = await unitSetup({ now });
  svc.push = { enabled: false, notifyUsers: async () => ({ sent: 0, failed: 0, skipped: 1, disabled: 'unconfigured' }) };
  const c = await svc.create({ title: 'X', body: 'Y.', audience: { kind: 'all' } });
  await svc.tick();
  const d = await svc.get(c.campaignId);
  assert.equal(d.status, 'FAILED');
  assert.match(d.error, /FCM_SERVICE_ACCOUNT_JSON/);
  await sleep(1);
});

test('buildMessage keeps only a well-formed https image of /media/push and a known target', () => {
  const ok = P.buildMessage('t', { type: 'NEWS', title: 'a', body: 'b', imageUrl: `https://coroute.example/media/push/pi_${'a'.repeat(24)}.jpg`, target: 'friends' });
  assert.equal(ok.message.data.target, 'friends');
  assert.ok(ok.message.data.imageUrl);
  const bad = P.buildMessage('t', { type: 'NEWS', title: 'a', body: 'b', imageUrl: 'http://evil.example/x.jpg', target: 'plans' });
  assert.equal(bad.message.data.imageUrl, undefined);
  assert.equal(bad.message.data.target, undefined);
});
