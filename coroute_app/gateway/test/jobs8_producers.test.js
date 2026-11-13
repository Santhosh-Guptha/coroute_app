'use strict';
/**
 * Round 8: the migrated producers enqueue instead of working inline (JOBS_QUEUE=on), and the job handler produces the
 * same result as the inline path: welcome + ride summary e-mails (route picture), receipts, push fan-out, road cell
 * fetches, avatar clean-up, security e-mails (sealed, priority 0, inline fallback when no worker takes them), leased
 * batch ticks, the in-process worker plan per gateway role, and the admin API.
 */
process.env.NODE_ENV = 'test';
process.env.JOBS_QUEUE = 'on';
process.env.JOBS_POLL_MIN_MS = '15';
process.env.JOBS_POLL_MAX_MS = '60';
process.env.JOBS_SECURITY_FALLBACK_MS = '400';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'jobs.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.SUPPORT_EMAIL = 'help@coroute.example';
process.env.PAYMENTS_ENABLED = 'true';
process.env.TRIP_MEMORY_DELAY_MIN = '0';
process.env.ROAD_CELLS_OVERPASS_URL = 'http://overpass.test/api/interpreter';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { Jobs, RegisterOnlyLease } = require('../src/jobs');
const { LEASE_ROUTES, NEVER_ROUTED } = require('../src/jobs/producers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { buildMessage } = require('../src/push');
const A = require('../src/avatars');

const quiet = { info() {}, warn() {}, error() {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mails = [];
const mailTransport = { async sendMail(m) { mails.push(m); return { messageId: `<j${mails.length}@test>` }; } };
const fcm = [];
const pushTransport = async (msg) => { fcm.push(msg); return { status: 200, body: {} }; };
const overpass = { calls: 0 };
const geoFetch = async (url) => {
  if (String(url).startsWith('http://overpass.test')) { overpass.calls++; return { ok: true, status: 200, json: async () => ({ elements: [] }) }; }
  throw new Error(`unexpected fetch ${url}`);
};

let t, jobs, admin;
const Q = 'job_queue';
const queued = async (type) => (await t.gw.soda.query(Q, { type }, { limit: 100 })).map((r) => r.value);
async function until(fn, ms = 3000) { const t0 = Date.now(); for (;;) { const v = await fn(); if (v) return v; if (Date.now() - t0 > ms) return v; await sleep(10); } }

function seg(marker, body) { const h = Buffer.alloc(4); h[0] = 0xFF; h[1] = marker; h.writeUInt16BE(body.length + 2, 2); return Buffer.concat([h, body]); }
function jpeg({ w = 512, h = 512 } = {}) {
  const sof = Buffer.from([8, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  return Buffer.concat([Buffer.from([0xFF, 0xD8]), seg(0xE0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'binary')),
    seg(0xDB, Buffer.alloc(65, 1)), seg(0xC0, sof), seg(0xC4, Buffer.alloc(30, 2)), seg(0xDA, Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0])),
    Buffer.alloc(200, 0x55), Buffer.from([0xFF, 0xD9])]);
}

before(async () => {
  t = await boot({ mailTransport, pushTransport, geoFetch });
  jobs = t.gw.app.locals.jobs;
  assert.equal(jobs.enabled, true);
  admin = await t.register('Jobs Admin', 'jobs.admin@coroute.test');
  // The worker is started and paused per test, so each test sees what was enqueued before anything runs.
  jobs.start();
  jobs.worker.pause();
});
after(async () => { await jobs.stop({ drainMs: 0 }); await t.gw.shutdown(); });

const work = async () => { jobs.worker.resume(); await sleep(30); await until(async () => !(await t.gw.soda.query(Q, { state: { $in: ['queued', 'running'] }, runAt: { $lte: Date.now() } }, { limit: 1 })).length); await jobs.worker.idle(); jobs.worker.pause(); };

test('welcome e-mail: the sign-up enqueues one email.lifecycle job; the worker sends exactly what the inline path builds', async () => {
  await work();
  mails.length = 0;
  const r = await t.register('Asha Jobs', 'asha.jobs@coroute.test');
  await t.gw.notifications.lifecycle.idle();
  const [job] = await queued('email.lifecycle').then((rows) => rows.filter((d) => d.key === `mail:welcome:${r.user.userId}`));
  assert.ok(job, 'a job was enqueued');
  assert.deepEqual(job.payload, { key: `welcome:${r.user.userId}` }, 'the payload is the mail_log key: no address, no text');
  assert.equal(mails.length, 0, 'nothing sent on the request path');
  await work();
  const sent = mails.filter((m) => m.to === 'asha.jobs@coroute.test');
  assert.equal(sent.length, 1);
  const user = await t.gw.repo.findUserById(r.user.userId);
  const inline = await t.gw.notifications.lifecycle.buildWelcome(user);
  assert.equal(sent[0].subject, inline.subject);
  assert.equal(sent[0].text, inline.text);
  assert.deepEqual(sent[0].headers, inline.headers);
  const [log] = (await t.gw.soda.query('mail_log', { key: `welcome:${r.user.userId}` }, { limit: 2 })).map((x) => x.value);
  assert.equal(log.status, 'SENT');
  // Re-running the job (at-least-once delivery) never sends twice: the mail_log claim decides.
  assert.deepEqual(await t.gw.notifications.lifecycle.process(`welcome:${r.user.userId}`), { skipped: 'ALREADY_SENT' });
});

test('ride summary e-mail: enqueued per rider; the worker renders the route picture (route_png) and sends it', async () => {
  mails.length = 0;
  const r = await t.register('Ravi Rides', 'ravi.jobs@coroute.test');
  await work();
  mails.length = 0;
  const end = Date.now() - 60000; const start = end - 75 * 60000;
  const pts = [];
  for (let i = 0; i <= 246; i++) pts.push({ lat: +(12.9 + i * 0.00063).toFixed(5), lng: +(77.5 + i * 0.00063).toFixed(5), speedKmh: 40, heading: 0, timestamp: 1 });
  const tripDoc = { tripId: `TRIP-J1-${r.user.userId}`, source: 'server', groupId: 'GRP-JOBS1', userId: r.user.userId, tripName: 'Jobs ride', startTimeEpochMs: start,
    endTimeEpochMs: end, totalDistanceKm: 24.6, topSpeedKmh: 90, avgSpeedKmh: 40, riderCount: 1, stopCount: 1, movingMs: 65 * 60000, restMs: 600000, breadcrumbTrail: pts, savedAt: Date.now() };
  await t.gw.repo.saveTrip(tripDoc);
  const meta = { groupId: 'GRP-JOBS1', name: 'Jobs ride', members: { [r.user.userId]: { userId: r.user.userId, name: 'Ravi Rides' } }, createdAtEpochMs: start, endedAtEpochMs: end };
  await t.gw.repo.saveConvoyMeta(meta);
  t.gw.notifications.lifecycle.onTripFinished({ meta, perMember: [{ userId: r.user.userId, name: 'Ravi Rides', tripDoc }] });
  await t.gw.notifications.lifecycle.idle();
  assert.ok((await queued('email.lifecycle')).some((d) => d.key === `mail:trip_memory:GRP-JOBS1:${r.user.userId}` && d.state === 'queued'));
  assert.equal(mails.length, 0);
  await work();
  const m = mails.find((x) => x.to === 'ravi.jobs@coroute.test');
  assert.ok(m, 'sent by the worker');
  const inline = await t.gw.notifications.lifecycle.buildTripMemory(await t.gw.repo.findUserById(r.user.userId), tripDoc, meta);
  assert.equal(m.subject, inline.subject);
  assert.equal(m.text, inline.text);
  assert.equal((m.attachments || []).length, (inline.attachments || []).length);
  if (inline.attachments && inline.attachments.length) assert.ok(Buffer.compare(m.attachments[0].content, inline.attachments[0].content) === 0, 'the same route picture');
});

test('receipt e-mail: a paid order enqueues email.receipt (order id only); the worker sends it once', async () => {
  const rider = await t.register('Pay Rider', 'pay.jobs@coroute.test');
  await work();
  mails.length = 0;
  const orderId = 'order_JOBS000001';
  await t.gw.repo.saveRazorpayOrder({ orderId, internalOrderId: 'CR-J1', userId: rider.user.userId, category: 'group_small', amountInPaise: 49900, originalPrice: 599,
    currency: 'INR', status: 'CREATED', mode: 'test', channel: 'web', createdAt: Date.now(),
    quote: { planName: 'Small Group', seats: 6, billingDays: 30, breakdown: [{ label: 'Small Group (30 days)', amountInr: 499 }, { label: 'To pay now', amountInr: 499 }] } });
  await t.gw.repo.updateRazorpayOrder(orderId, { status: 'PAID', paymentId: 'pay_JOBS1', paidAt: Date.now() });
  await t.gw.notifications.purchaseEmail.idle();
  const [job] = (await queued('email.receipt')).filter((d) => d.key === `mail:receipt:${orderId}`);
  assert.deepEqual(job.payload, { orderId });
  assert.equal(mails.length, 0);
  await work();
  const sent = mails.filter((m) => m.to === 'pay.jobs@coroute.test');
  assert.equal(sent.length, 1);
  assert.equal(sent[0].subject, 'Your CoRoute receipt: Small Group');
  assert.ok(sent[0].text.includes('pay_JOBS1'));
  // A second PAID write (webhook retry) adds no second job while the first is fresh, and mail_log keeps it to one mail.
  await t.gw.repo.updateRazorpayOrder(orderId, { status: 'PAID' });
  await t.gw.notifications.purchaseEmail.idle();
  await work();
  assert.equal(mails.filter((m) => m.to === 'pay.jobs@coroute.test').length, 1);
});

test('push fan-out: notifyUsers enqueues push.fanout (ids + text, no socket check on the worker); the worker sends the same FCM message', async () => {
  const a = await t.register('Push Rider', 'push.jobs@coroute.test');
  const token = `fcm_${'a'.repeat(40)}`;
  assert.equal((await t.api('POST', '/me/push-tokens', { token, platform: 'android' }, a.token)).status, 200);
  fcm.length = 0;
  const opts = { type: 'RIDE_INVITE', title: 'Ride invitation', body: 'SwiftFalcon482 invited you to a ride', data: { inviteId: 'ri_1', eventId: 'RIDE_INVITE:ri_1' }, priority: 'high', ttlSec: 1800 };
  const out = await t.gw.push.notifyUsers([a.user.userId], opts);
  assert.deepEqual(out, { sent: 0, skipped: 0, failed: 0, queued: 1 });
  const [job] = await queued('push.fanout');
  assert.equal(job.priority, 1, 'high priority pushes first');
  assert.equal(job.key, 'push:RIDE_INVITE:ri_1:0');
  assert.deepEqual(job.payload.userIds, [a.user.userId]);
  assert.equal(fcm.length, 0);
  // The same event again (a retry by the caller) is one job.
  await t.gw.push.notifyUsers([a.user.userId], opts);
  assert.equal((await queued('push.fanout')).length, 1);
  await work();
  assert.equal(fcm.length, 1);
  assert.deepEqual(fcm[0], buildMessage(token, { ...opts, type: 'RIDE_INVITE' }));
  // Inside a job (a campaign tick on the worker) notifyUsers sends directly.
  const { runInJob } = require('../src/jobs/context');
  const direct = await runInJob({ jobId: 'j_x', type: 'push.campaigns_tick' }, () => t.gw.push.notifyUsers([a.user.userId], { ...opts, data: { inviteId: 'ri_2' } }));
  assert.equal(direct.sent, 1);
});

test('road cells: a missing cell answers 202 at once and enqueues roads.fetch; the worker fetches under its budget', async () => {
  const r = await t.register('Road Rider', 'road.jobs@coroute.test');
  const cell = 'tdr1y0';
  overpass.calls = 0;
  const first = await t.api('GET', `/geo/roads?cell=${cell}`, null, r.token);
  assert.equal(first.status, 202);
  assert.equal(first.json.pending, true);
  assert.equal(overpass.calls, 0, 'no upstream call on the request');
  await t.api('GET', `/geo/roads?cell=${cell}`, null, r.token);
  const rows = (await queued('roads.fetch')).filter((d) => d.key === `roads:${cell}`);
  assert.equal(rows.length, 1, 'one job per cell');
  await work();
  assert.equal(overpass.calls, 1);
  const second = await t.api('GET', `/geo/roads?cell=${cell}`, null, r.token);
  assert.equal(second.status, 200, 'the stored cell is served from the database');
});

test('avatars: the EXIF clean-up stays on the request; removing the replaced picture is a photo.delete job', async () => {
  const r = await t.register('Photo Rider', 'photo.jobs@coroute.test');
  const up = async () => {
    const res = await fetch(`${t.base}/me/avatar`, { method: 'POST', headers: { 'Content-Type': 'image/jpeg', Authorization: `Bearer ${r.token}` }, body: jpeg() });
    const j = await res.json();
    return { ...j, avatarId: String(j.avatarUrl || '').split('/').pop() };
  };
  const one = await up();
  assert.match(one.avatarId, /^av_/);
  const two = await up();
  assert.notEqual(two.avatarId, one.avatarId);
  const docs = async () => (await t.gw.soda.query(A.COLL, { userId: r.user.userId }, { limit: 10 })).map((x) => x.value.avatarId).sort();
  assert.deepEqual(await docs(), [one.avatarId, two.avatarId].sort(), 'the old picture is still there until the job runs');
  const job = (await queued('photo.delete')).find((d) => d.payload && d.payload.avatarIds && d.payload.avatarIds.includes(one.avatarId));
  assert.ok(job);
  await work();
  assert.deepEqual(await docs(), [two.avatarId]);
});

test('security e-mail: priority 0, sealed (no address / link in the row); a stopped worker never blocks it (inline fallback)', async () => {
  const r = await t.register('Sec Rider', 'sec.jobs@coroute.test');
  await work();
  mails.length = 0;
  const before = jobs.counters.fallbackInline;
  const res = await t.api('POST', '/auth/password/forgot', { email: 'sec.jobs@coroute.test' });
  assert.equal(res.status, 202);
  const row = await until(async () => (await queued('email.security'))[0]);
  assert.ok(row, 'enqueued');
  assert.equal(row.priority, 0);
  const raw = JSON.stringify(row);
  assert.ok(!raw.includes('sec.jobs@coroute.test') && !raw.includes('/reset'), 'sealed');
  assert.equal(mails.length, 0);
  // The worker stays paused (stopped): after JOBS_SECURITY_FALLBACK_MS the gateway sends it itself.
  const got = await until(() => mails.find((m) => m.to === 'sec.jobs@coroute.test'), 3000);
  assert.ok(got, 'sent inline after the fallback time');
  assert.equal(got.subject, 'Reset your CoRoute password');
  assert.equal(jobs.counters.fallbackInline, before + 1);
  await until(async () => !(await queued('email.security')).length);
  assert.equal((await queued('email.security')).length, 0, 'the row is gone');
  await sleep(100);
  await work();
  assert.equal(mails.filter((m) => m.to === 'sec.jobs@coroute.test').length, 1, 'never sent twice');
  void r;
});

test('security e-mail: with a running worker the worker sends it (well before the fallback) and the gateway does not', async () => {
  mails.length = 0;
  jobs.worker.resume();
  const before = { inline: jobs.counters.fallbackInline, worker: jobs.counters.fallbackTakenByWorker };
  const t0 = Date.now();
  await t.api('POST', '/auth/password/forgot', { email: 'sec.jobs@coroute.test' });
  const got = await until(() => mails.find((m) => m.to === 'sec.jobs@coroute.test'), 3000);
  assert.ok(got && Date.now() - t0 < 350, `sent by the worker in ${Date.now() - t0} ms`);
  await sleep(500);
  assert.equal(mails.filter((m) => m.to === 'sec.jobs@coroute.test').length, 1);
  assert.equal(jobs.counters.fallbackInline, before.inline);
  assert.equal(jobs.counters.fallbackTakenByWorker, before.worker + 1);
  await jobs.worker.idle();
  jobs.worker.pause();
});

test('security e-mail: the queue being down sends at once (enqueue failure)', async () => {
  mails.length = 0;
  const orig = jobs.queue.enqueue;
  jobs.queue.enqueue = async () => { throw Object.assign(new Error('SODA busy'), { status: 503 }); };
  try {
    const t0 = Date.now();
    await t.api('POST', '/auth/password/forgot', { email: 'sec.jobs@coroute.test' });
    const got = await until(() => mails.find((m) => m.to === 'sec.jobs@coroute.test'), 2000);
    assert.ok(got && Date.now() - t0 < 300);
  } finally { jobs.queue.enqueue = orig; }
});

test('leased batch ticks: the lease keeps the schedule and enqueues the work; the handler is the original function', async () => {
  assert.equal(t.gw.lease.__jobsRouted, true);
  for (const n of NEVER_ROUTED) assert.equal(LEASE_ROUTES[n], undefined, `${n} is never routed through the queue`);
  const soda = new MemorySoda();
  const runs = [];
  const fakeLease = { run(name, ms, fn) { runs.push({ name, fn }); return { stop() {} }; } };
  const j = new Jobs({ soda, logger: quiet, options: { queue: true } });
  j.routeLease(fakeLease, LEASE_ROUTES);
  let nightly = 0; let sms = 0;
  fakeLease.run('business-nightly', 86400000, async ({ signal, name }) => { assert.ok(signal); assert.equal(name, 'business-nightly'); nightly++; });
  fakeLease.run('sos-sms', 15000, async () => { sms++; });
  await runs[1].fn({});
  assert.equal(sms, 1, 'sos-sms runs directly');
  await runs[0].fn({});
  await runs[0].fn({});
  assert.equal(nightly, 0, 'the lease only enqueued');
  const rows = (await soda.query(Q, {}, { limit: 10 })).map((x) => x.value);
  assert.deepEqual(rows.map((d) => [d.type, d.key, d.state]), [['batch.business_nightly', 'lease:business-nightly', 'queued']], 'one pending run, never a backlog');
  j.start();
  await until(() => nightly === 1);
  assert.equal(nightly, 1);
  await j.stop({ drainMs: 0 });
  // Queue off: the lease runs the work itself, exactly as before round 8.
  const off = new Jobs({ soda: new MemorySoda(), logger: quiet, options: { queue: false } });
  const runs2 = [];
  const lease2 = { run(name, ms, fn) { runs2.push(fn); } };
  off.routeLease(lease2, LEASE_ROUTES);
  let ran = 0;
  lease2.run('intel-daily', 1000, async () => { ran++; });
  await runs2[0]({});
  assert.equal(ran, 1);
  // The separate worker process records leases without scheduling them, and still gets the handlers.
  const rol = new RegisterOnlyLease();
  const w = new Jobs({ soda: new MemorySoda(), lease: rol, logger: quiet });
  w.routeLease(rol, LEASE_ROUTES);
  rol.run('backup-full', 3600000, async () => {});
  assert.equal(w.mode, 'separate'); assert.equal(w.enabled, true);
  assert.ok(w.registry.has('batch.backup_full'));
  assert.deepEqual(rol.names, ['backup-full']);
});

test('in-process worker plan: web/all work jobs; a live node yields to any other worker and never works with JOBS_SEPARATE_WORKER=on', async () => {
  const mk = (role, options = {}) => new Jobs({ soda: new MemorySoda(), logger: quiet, role, options: { queue: true, ...options } });
  assert.equal(mk('all').plan(), 'run');
  assert.equal(mk('web').plan(), 'run');
  assert.equal(mk('live').plan(), 'yield');
  assert.equal(mk('live', { separateWorker: true }).plan(), 'off');
  assert.equal(mk('live', { separateWorker: true, inprocess: 'on' }).plan(), 'off', 'never on a live node when a separate worker exists');
  assert.equal(mk('standby').plan(), 'off');
  assert.equal(mk('web', { inprocess: 'off' }).plan(), 'off');
  assert.equal(mk('web', { queue: false }).plan(), 'off');
  // Yield: a live node works jobs only while no other worker heartbeats.
  const soda = new MemorySoda();
  const live = new Jobs({ soda, logger: quiet, role: 'live', options: { queue: true, pollMinMs: 20, pollMaxMs: 40 } });
  live.register('email.x1', async () => {});
  live.start();
  await live._heartbeat();
  assert.equal(live.worker.paused, false, 'alone: works');
  const web = new Jobs({ soda, logger: quiet, role: 'web', options: { queue: true, pollMinMs: 20, pollMaxMs: 40 } });
  web.register('email.x1', async () => {});
  web.start();
  await web._heartbeat();
  await live._heartbeat();
  assert.equal(live.worker.paused, true, 'another worker is up: the live node stops working jobs');
  await web.stop({ drainMs: 0 });
  await live._heartbeat();
  assert.equal(live.worker.paused, false, 'the other worker left: the live node helps again');
  await live.stop({ drainMs: 0 });
});

test('admin API: depth per type, oldest age, workers, alert flags; dead letters retry / discard; MASTER_ADMIN only', async () => {
  const rider = await t.register('Plain Rider', 'plain.jobs@coroute.test');
  assert.equal((await t.api('GET', '/admin/jobs')).status, 401);
  assert.equal((await t.api('GET', '/admin/jobs', null, rider.token)).status, 403);
  await jobs.enqueue('email.receipt', { orderId: 'order_NONE' }, { key: 'admin-test-1' });
  jobs.queue._summary = null;
  const s = await t.api('GET', '/admin/jobs', null, admin.token);
  assert.equal(s.status, 200);
  assert.equal(s.json.enabled, true);
  assert.ok(s.json.types['email.receipt'].queued >= 1);
  assert.ok(Array.isArray(s.json.workers));
  assert.equal(typeof s.json.oldestDueAgeS, 'number');
  assert.deepEqual(Object.keys(s.json.thresholds).sort(), ['dead', 'oldestS']);
  // A dead letter: claim and fail permanently.
  const [j] = await jobs.queue.claim('admin-test', { families: ['email'], limit: 5, accept: (d) => d.key === 'admin-test-1' });
  const { PermanentError } = require('../src/jobs/errors');
  assert.equal(await jobs.queue.fail(j, new PermanentError('bad')), 'dead');
  const dead = await t.api('GET', '/admin/jobs/dead', null, admin.token);
  const item = dead.json.items.find((d) => d.key === 'admin-test-1');
  assert.ok(item);
  assert.equal((await t.api('POST', '/admin/jobs/dead/nonsense/retry', {}, admin.token)).status, 404);
  const retry = await t.api('POST', `/admin/jobs/dead/${item.jobId}/retry`, {}, admin.token);
  assert.deepEqual(retry.json, { ok: true, outcome: 'retried' });
  const [j2] = await jobs.queue.claim('admin-test', { families: ['email'], limit: 5, accept: (d) => d.key === 'admin-test-1' });
  await jobs.queue.fail(j2, new PermanentError('bad again'));
  assert.equal((await t.api('DELETE', `/admin/jobs/dead/${item.jobId}`, null, admin.token)).json.ok, true);
  assert.equal((await t.api('GET', '/admin/jobs/dead', null, admin.token)).json.items.filter((d) => d.key === 'admin-test-1').length, 0);
  // Metrics: the gateway's /metrics carries the job rows.
  const metrics = await (await fetch(`${t.origin}/metrics`)).text();
  assert.match(metrics, /coroute_jobs_enabled\{mode="gateway"\} 1/);
  assert.match(metrics, /coroute_jobs_enqueued_total\{type="email.lifecycle"\} \d+/);
});
