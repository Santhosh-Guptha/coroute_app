'use strict';
/**
 * Play payments policy (docs/features_355/play_payments_policy.md): the plan notices that reach the
 * consumption-only app (SUBSCRIPTION_* push texts) are neutral account status only: no price, no
 * "renew / upgrade / buy / pay", no pointer to a website. notifyPlanChange() sends the socket message
 * the app re-reads its plan on, and the neutral push. Pure: no server, no network.
 */
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../src/push');

const TYPES = ['SUBSCRIPTION_ACTIVATED', 'SUBSCRIPTION_EXPIRING', 'SUBSCRIPTION_EXPIRED', 'SUBSCRIPTION_REVOKED'];
const DEC_12 = Date.UTC(2026, 11, 12, 6, 0, 0);

test('every plan notice is neutral and names the plan or the end date', () => {
  for (const type of TYPES) {
    for (const p of [{ plan: 'group_small' }, { tier: 'roadCaptain' }, { planName: 'Large Group (7–12)' }, {}]) {
      const m = P.SOCKET_EVENTS[type]({ type, validUntil: DEC_12, ...p });
      assert.ok(m.title && m.body, `${type} has a title and a body`);
      assert.ok(!P.PLAN_TEXT_FORBIDDEN.test(`${m.title} ${m.body}`), `${type}: "${m.body}" is neutral`);
      assert.ok(!/https?:|www\.|\.com|\.space|\.org/i.test(m.body), 'no link');
      assert.deepEqual(Object.keys(m.data), [], 'no ids or amounts in the data');
    }
  }
  assert.equal(P.planNotice({ type: 'SUBSCRIPTION_ACTIVATED', plan: 'group_small' }).body, 'Your Small Group plan is active.');
  assert.equal(P.planNotice({ type: 'SUBSCRIPTION_ACTIVATED', planName: 'Large Group (7–12)' }).body, 'Your Large Group plan is active.');
  assert.equal(P.planNotice({ type: 'SUBSCRIPTION_EXPIRING', validUntil: DEC_12 }).body, 'Your plan ends on 12 Dec.');
  assert.match(P.planNotice({ type: 'SUBSCRIPTION_EXPIRED' }).body, /Solo riding and every safety feature stay free\./);
  // A server plan name with money words is never echoed.
  assert.equal(P.planNotice({ type: 'SUBSCRIPTION_ACTIVATED', planName: 'Promo ₹49 plan' }).body, 'Your plan is active.');
});

test('notifyPlanChange sends the socket message and the neutral push, never throws', async () => {
  const socket = [];
  const pushed = [];
  const push = { notifyUsers: async (ids, n) => { pushed.push({ ids, n }); return { sent: 1 }; } };
  push.onSocketEvent = P.PushService.prototype.onSocketEvent.bind(Object.assign(push, { _onPeer: () => false }));
  const hub = { sendToUser: (uid, payload) => { socket.push({ uid, payload }); return 1; }, push };
  P.notifyPlanChange({ hub }, 'u_1', { type: 'SUBSCRIPTION_EXPIRING', tier: 'proRider', validUntil: DEC_12 });
  await new Promise((r) => setImmediate(r));
  assert.equal(socket.length, 1);
  assert.equal(socket[0].payload.type, 'SUBSCRIPTION_EXPIRING');
  assert.match(socket[0].payload.eventId, /^SUBSCRIPTION_EXPIRING:/);
  assert.equal(pushed.length, 1);
  assert.equal(pushed[0].n.body, 'Your plan ends on 12 Dec.');
  assert.equal(pushed[0].n.data.eventId, socket[0].payload.eventId, 'one notice per event in the app');

  // Through the convoy emitter when no hub is given; other types and missing users are ignored.
  const emitted = [];
  P.notifyPlanChange({ convoys: { emit: (...a) => emitted.push(a) } }, 'u_2', { type: 'SUBSCRIPTION_EXPIRED' });
  assert.equal(emitted.length, 1);
  assert.equal(emitted[0][0], 'userMessage');
  P.notifyPlanChange({ hub }, 'u_3', { type: 'FRIEND_REQUEST' });
  P.notifyPlanChange({ hub }, '', { type: 'SUBSCRIPTION_EXPIRED' });
  assert.equal(socket.length, 1);
  assert.doesNotThrow(() => P.notifyPlanChange({ hub: { sendToUser: () => { throw new Error('x'); } } }, 'u_4', { type: 'SUBSCRIPTION_REVOKED' }));
});

test('the web purchase activation notice (web_shop.js) is neutral too', async () => {
  let shop;
  try { shop = require('../src/web_shop'); } catch { return; } // owned by the website work; skip when absent
  if (typeof shop.notifyPlanActivated !== 'function') return;
  const pushed = [];
  const hub = { sendToUser: () => 1, push: { notifyUsers: async (ids, n) => { pushed.push(n); return {}; } } };
  shop.notifyPlanActivated({ hub, userId: 'u_9', membership: { category: 'group_small', categoryName: 'Small Group (2–6)', validUntil: DEC_12 }, order: { orderId: 'o_1' }, source: 'web' });
  await new Promise((r) => setImmediate(r));
  for (const n of pushed) assert.ok(!P.PLAN_TEXT_FORBIDDEN.test(`${n.title} ${n.body}`), `"${n.title}: ${n.body}" is neutral`);
});
