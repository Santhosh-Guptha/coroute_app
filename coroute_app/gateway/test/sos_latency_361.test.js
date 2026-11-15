'use strict';
/**
 * v3.61 SOS latency: a slow or failing database never holds back an SOS. The duplicate check waits at most
 * SOS_LOOKUP_WAIT_MS (a failing one counts as "not found"), the store at most SOS_STORE_WAIT_MS; the alert goes out
 * as unsaved and is marked saved when the late write lands (one stored row).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.SOS_LOOKUP_WAIT_MS = '300';
process.env.SOS_STORE_WAIT_MS = '300';

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
    name, email: `soslat${n}@coroute.test`, password: 'Password#123', phone: `+9198755${String(10000 + n).slice(-5)}`,
    vehicleType: 'Motorcycle', vehicleNo: `TS11AB${String(1000 + n).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })));
};

test('slow store and failing duplicate check: the SOS still goes out fast, then is saved once', async () => {
  const lead = await register('Lead Lat');
  const c = (await t.api('POST', '/convoys', { name: 'Latency ride' }, lead.token)).json;
  const repo = gw.convoys.repo;
  const realAdd = repo.addAlert.bind(repo);
  const realFind = repo.findAlertByClientId.bind(repo);
  let added = 0;
  repo.findAlertByClientId = async () => { throw new Error('db down'); };
  repo.addAlert = async (gid, a) => { await sleep(900); added++; return realAdd(gid, a); };
  try {
    const t0 = Date.now();
    const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'lat-1', lat: 17.4, lng: 78.4 }, lead.token);
    const ms = Date.now() - t0;
    assert.equal(r.status, 201);
    assert.equal(r.json.persisted, false, 'sent before the slow write finished');
    assert.ok(ms < 850, `answered in ${ms} ms (store takes 900 ms)`);
    const room = gw.convoys.rooms.get(c.groupId);
    assert.ok(room.alerts.has(r.json.alertId));
    // A resend while the first write still runs waits for it (no second row).
    repo.findAlertByClientId = realFind;
    const again = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'lat-1', lat: 17.4, lng: 78.4 }, lead.token);
    assert.equal(again.json.duplicate, true);
    assert.equal(again.json.alertId, r.json.alertId);
    await sleep(1000);
    assert.equal(added, 1, 'stored exactly once');
    assert.ok(!(room.unsaved && room.unsaved.has(r.json.alertId)), 'marked saved after the late write');
    const rows = (await repo.listAlerts(c.groupId, { includeResolved: true })).filter((a) => a.clientId === 'lat-1');
    assert.equal(rows.length, 1);
  } finally {
    repo.addAlert = realAdd;
    repo.findAlertByClientId = realFind;
  }
});
