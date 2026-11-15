'use strict';
/**
 * v3.62 safety gaps closed:
 *  1. a group member's SOS is pushed (GROUP_SOS) to riders of the ride with no live socket, never held back by the
 *     per-rider throttle or the admin push switch, without position or medical data; its close replaces it;
 *  2. a profile slower than 1.5 s still adds its Medical ID to the open alert (same ALERT again);
 *  3. the HTTP SOS is never refused by the old 12-a-minute limit.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.SOS_MEDICAL_LATE_MS = '4000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });

let n = 0;
const register = async (name) => {
  n++;
  return JSON.parse(JSON.stringify(await gw.auth.register({
    name, email: `sospush${n}@coroute.test`, password: 'Password#123', phone: `+9198766${String(10000 + n).slice(-5)}`,
    vehicleType: 'Motorcycle', vehicleNo: `TS12AB${String(1000 + n).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })));
};

async function ride(names) {
  const users = [];
  for (const nm of names) users.push(await register(nm));
  const c = (await t.api('POST', '/convoys', { name: 'Sunday ride' }, users[0].token)).json;
  for (const u of users.slice(1)) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
  return { c, users };
}

function fakePush() {
  const calls = [];
  const real = gw.convoys.push;
  gw.convoys.push = { notifyUsers: async (ids, opts) => { calls.push({ ids, opts }); return { sent: ids.length }; } };
  return { calls, restore: () => { gw.convoys.push = real; } };
}

test('SOS is pushed to riders without a live socket; the close replaces it; no position or medical data', async () => {
  const { c, users } = await ride(['Anu Rao', 'Ravi K', 'Meera S']);
  const p = fakePush();
  try {
    const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'push-1', lat: 17.4, lng: 78.4 }, users[1].token);
    assert.equal(r.status, 201);
    await sleep(50);
    const sos = p.calls.find((x) => x.opts.type === 'GROUP_SOS');
    assert.ok(sos, 'GROUP_SOS pushed');
    assert.deepEqual(sos.ids.sort(), [users[0].user.userId, users[2].user.userId].sort(), 'everyone in the ride but the rider in trouble');
    assert.equal(sos.opts.skipConnected, true, 'riders on a socket already have the ALERT');
    assert.equal(sos.opts.urgent, true);
    assert.equal(sos.opts.title, 'SOS: Ravi needs help');
    assert.match(sos.opts.body, /Sunday ride/);
    assert.deepEqual(Object.keys(sos.opts.data).sort(), ['alertId', 'groupId']);
    assert.equal(sos.opts.collapseKey, `sos_${r.json.alertId}`);
    // A resend is the same SOS: no second push.
    await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'push-1', lat: 17.4, lng: 78.4 }, users[1].token);
    assert.equal(p.calls.filter((x) => x.opts.type === 'GROUP_SOS').length, 1);
    await gw.convoys.resolveSos(c.groupId, users[1].user, r.json.alertId);
    await sleep(50);
    const closed = p.calls.find((x) => x.opts.type === 'GROUP_SOS_RESOLVED');
    assert.ok(closed, 'close pushed');
    assert.equal(closed.opts.collapseKey, `sos_${r.json.alertId}`, 'replaces the SOS notification');
  } finally { p.restore(); }
});

test('push service: SOS skips the per-rider throttle and the admin push switch; other types do not', async () => {
  const { PushService } = require('../src/push');
  const sent = [];
  const svc = new PushService({ soda: null, transport: { send: async (m) => { sent.push(m); return { ok: true, status: 200 }; } }, perUserLimit: 1, flagsOf: () => ({ isOn: () => false }), logger: { warn() {}, info() {} } });
  svc.tokensOf = async () => [{ token: 'tok' }];
  svc._sendOne = async (m) => { sent.push(m); return 'sent'; };
  const off = await svc.notifyUsers(['u1'], { type: 'CHAT_MESSAGE', title: 'x', body: 'y' });
  assert.equal(off.disabled, 'switch');
  const a = await svc.notifyUsers(['u1'], { type: 'GROUP_SOS', title: 'SOS', body: 'b', data: { groupId: 'g', alertId: 'a', lat: '17' }, urgent: true });
  const b = await svc.notifyUsers(['u1'], { type: 'GROUP_SOS', title: 'SOS', body: 'b', urgent: true });
  assert.equal(a.sent + b.sent, 2, 'both sent past a 1-per-window throttle with push switched off');
  assert.equal(sent[0].message.data.lat, undefined, 'no position in a push');
  assert.equal(sent[0].message.android.priority, 'HIGH');
  // urgent only counts for the safety types.
  const c = await svc.notifyUsers(['u1'], { type: 'CHAT_MESSAGE', title: 'x', body: 'y', urgent: true });
  assert.equal(c.disabled, 'switch');
});

test('slow profile: the SOS goes out without Medical ID, then the same ALERT comes again with it', async () => {
  const { c, users } = await ride(['Kiran M', 'Lata P']);
  const repo = gw.convoys.repo;
  const realFind = repo.findUserById.bind(repo);
  const events = [];
  const onEvent = (gid, payload) => { if (gid === c.groupId && payload.type === 'ALERT') events.push(payload); };
  gw.convoys.on('event', onEvent);
  repo.findUserById = async (id) => {
    const u = await realFind(id);
    if (id !== users[0].user.userId) return u;
    await sleep(2200);
    return { ...u, bloodGroup: 'O+', allergies: 'Penicillin' };
  };
  try {
    const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'med-1', lat: 17.4, lng: 78.4 }, users[0].token);
    assert.equal(r.status, 201);
    const room = gw.convoys.rooms.get(c.groupId);
    assert.equal(room.alerts.get(r.json.alertId).medical, undefined, 'sent without waiting for the profile');
    await sleep(1200);
    const a = room.alerts.get(r.json.alertId);
    assert.deepEqual(a.medical, { bloodGroup: 'O+', allergies: 'Penicillin' });
    const late = events.filter((e) => e.alert.alertId === r.json.alertId && e.alert.medical);
    assert.equal(late.length, 1, 'one ALERT update with the Medical ID');
    assert.equal(late[0].alert.medical.bloodGroup, 'O+');
  } finally {
    repo.findUserById = realFind;
    gw.convoys.off('event', onEvent);
  }
});

test('slow profile after the SOS was closed: nothing is added', async () => {
  const { c, users } = await ride(['Om T']);
  const repo = gw.convoys.repo;
  const realFind = repo.findUserById.bind(repo);
  repo.findUserById = async (id) => { const u = await realFind(id); await sleep(2000); return { ...u, bloodGroup: 'B+' }; };
  try {
    const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'med-2', lat: 17.4, lng: 78.4 }, users[0].token);
    await gw.convoys.resolveSos(c.groupId, users[0].user, r.json.alertId);
    await sleep(1000);
    const a = gw.convoys.rooms.get(c.groupId).alerts.get(r.json.alertId);
    assert.ok(!a || !a.medical, 'no medical info on a closed alert');
  } finally { repo.findUserById = realFind; }
});

test('HTTP SOS: a 13th and 20th SOS in one minute still get through', async () => {
  const { c, users } = await ride(['Raju B']);
  for (let i = 0; i < 20; i++) {
    const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: `many-${i}`, lat: 17.4, lng: 78.4 }, users[0].token);
    assert.ok(r.status === 200 || r.status === 201, `SOS ${i + 1}: ${r.status}`);
  }
});
