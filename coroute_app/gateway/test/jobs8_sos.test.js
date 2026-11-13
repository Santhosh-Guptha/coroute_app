'use strict';
/**
 * Round 8: SOS / alert delivery never depends on the job queue. With JOBS_QUEUE=on, the worker stopped and even the
 * queue's database calls failing, an SOS over the socket and over the HTTP lane reaches the group at once, and nothing
 * SOS-related is enqueued. The SOS SMS retry job and the guardian push keep their direct lease jobs.
 */
process.env.NODE_ENV = 'test';
process.env.JOBS_QUEUE = 'on';
process.env.JOBS_POLL_MIN_MS = '15';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { netBoot, sleep } = require('./_net_helpers');
const { LEASE_ROUTES, NEVER_ROUTED } = require('../src/jobs/producers');

let h, ride, member, leadWs, memberWs, jobs;
const enqueued = [];
before(async () => {
  h = await netBoot({ pushTransport: async () => ({ status: 200, body: {} }) });
  jobs = h.t.gw.app.locals.jobs;
  assert.equal(jobs.enabled, true);
  const orig = jobs.queue.enqueue.bind(jobs.queue);
  jobs.queue.enqueue = (type, ...rest) => { enqueued.push(type); return orig(type, ...rest); };
  jobs.start();
  jobs.worker.pause(); // a stopped worker
  ride = await h.rideOn(null, { name: 'Jobs SOS' });
  member = await h.join(ride, 'Jsos');
  leadWs = await h.net1(ride.lead.token, ride.gid);
  memberWs = await h.net1(member.token, ride.gid);
});
after(async () => { for (const ws of [leadWs, memberWs]) try { ws.close(); } catch { /* closed */ } await jobs.stop({ drainMs: 0 }); await h.t.gw.shutdown(); });

const alertsOf = (ws, cid) => ws.frames.filter((m) => m.type === 'ALERT' && m.alert && m.alert.clientId === cid && !m.duplicate);

test('socket SOS reaches the group with the worker stopped; nothing is enqueued for it', async () => {
  enqueued.length = 0;
  const t0 = Date.now();
  const alert = await h.sos(memberWs, 17.41, 78.51);
  await sleep(40);
  assert.equal(alertsOf(leadWs, alert.clientId).length, 1);
  assert.ok(Date.now() - t0 < 1500, `${Date.now() - t0} ms`);
  assert.deepEqual(enqueued, [], 'the SOS path enqueued nothing');
});

test('HTTP SOS lane and socket SOS work while every queue write fails', async () => {
  const orig = jobs.queue.soda;
  const broken = new Proxy(orig, { get(target, prop) { if (['insert', 'query', 'compareAndReplace', 'findOne'].includes(prop)) return async () => { throw Object.assign(new Error('DB down'), { status: 503 }); }; return Reflect.get(target, prop); } });
  jobs.queue.soda = broken;
  try {
    const cid = 'jobs-http-sos-1';
    const r = await h.t.api('POST', `/convoys/${ride.gid}/sos`, { clientId: cid, lat: 17.4, lng: 78.5, alertType: 'EMERGENCY', source: 'MANUAL' }, member.token);
    assert.equal(r.status, 201, JSON.stringify(r.json));
    await sleep(40);
    assert.equal(alertsOf(leadWs, cid).length, 1);
    const alert = await h.sos(leadWs, 17.42, 78.52);
    await sleep(40);
    assert.equal(alertsOf(memberWs, alert.clientId).length, 1);
  } finally { jobs.queue.soda = orig; }
});

test('SOS SMS retries, guardian push and live-room jobs are never routed through the queue; push carries no SOS type', () => {
  for (const n of NEVER_ROUTED) assert.equal(LEASE_ROUTES[n], undefined, n);
  assert.ok(Object.values(LEASE_ROUTES).every((r) => !/sos|alert|guardian/i.test(r.type)));
  const { SOCKET_EVENTS } = require('../src/push');
  assert.ok(Object.keys(SOCKET_EVENTS).every((k) => !/SOS|ALERT|CRASH|EMERGENCY/.test(k)), 'FCM push is not the SOS path');
  // The emergency gateway (SOS SMS) has no reference to the job queue.
  const eg = h.t.gw.emergencyGateway;
  assert.equal(eg.jobs, undefined);
  assert.ok(!/jobs\//.test(require('fs').readFileSync(require.resolve('../src/emergency_sms_gateway'), 'utf8')));
  assert.ok(!/jobs\//.test(require('fs').readFileSync(require.resolve('../src/sos_sms'), 'utf8')));
});
