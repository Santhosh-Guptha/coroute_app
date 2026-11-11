'use strict';
/**
 * 3.55 ride chat: CHAT quick cards keep their card type, the 5 a second chat limit, and CHAT_REPORT
 * (a group ride chat message reported to the CoRoute team, stored with the public ride reports;
 * the transcript has only the reported rider's and the reporter's lines).
 */
process.env.PUBLIC_RIDE_TICK_MS = '3600000';
process.env.ADMIN_EMAILS = 'chat.admin@coroute.test';
const { netBoot } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

const uidOf = (u) => u.user.userId;

async function chatRide() {
  const R = await h.rideOn(null, { name: 'Chat' });
  const member = await h.join(R, 'Chatter');
  const third = await h.join(R, 'Third');
  const lead = await h.net1(R.lead.token, R.gid);
  const ws = await h.net1(member.token, R.gid);
  const ws3 = await h.net1(third.token, R.gid);
  return { R, member, third, lead, ws, ws3 };
}

test('quick card keeps its card type; CHAT_REPORT stores a report with the two riders\' lines only', async () => {
  const { R, member, third, lead, ws, ws3 } = await chatRide();
  ws.sendJson({ type: 'CHAT', text: 'Fuel stop', isQuickCard: true, cardType: 'FUEL', clientId: 'c-1' });
  const q = await lead.next((m) => m.type === 'MESSAGE' && m.message.text === 'Fuel stop');
  assert.equal(q.message.isQuickCard, true);
  assert.equal(q.message.cardType, 'FUEL');
  ws3.sendJson({ type: 'CHAT', text: 'Someone else talking', clientId: 'c-3' });
  await lead.next((m) => m.type === 'MESSAGE' && m.message.text === 'Someone else talking');
  lead.sendJson({ type: 'CHAT', text: 'ok noted', clientId: 'c-2' });
  await ws.next((m) => m.type === 'MESSAGE' && m.message.text === 'ok noted');
  ws.sendJson({ type: 'CHAT', text: 'rude words here', clientId: 'c-4' });
  const bad = await lead.next((m) => m.type === 'MESSAGE' && m.message.text === 'rude words here');

  lead.sendJson({ type: 'CHAT_REPORT', messageId: bad.message.messageId, reason: 'ABUSE' });
  const ok = await lead.next((m) => m.type === 'CHAT_REPORT_OK');
  assert.equal(ok.messageId, bad.message.messageId);
  assert.match(ok.reportId, /^RPT-/);
  await h.settle(50);
  // The reported rider is never told.
  assert.equal(h.got(ws, 'CHAT_REPORT_OK').length, 0);

  const admin = await h.rider('Admin', { email: 'chat.admin@coroute.test' });
  const list = await h.t.api('GET', '/admin/public-ride/reports', null, admin.token);
  assert.equal(list.status, 200, JSON.stringify(list.json));
  const r = list.json.reports.find((x) => x.reportId === ok.reportId);
  assert.ok(r, 'report stored');
  assert.equal(r.reporterId, uidOf(R.lead));
  assert.equal(r.reportedId, uidOf(member));
  assert.equal(r.reason, 'ABUSE');
  assert.equal(r.ref, `CHAT:${R.gid}:${bad.message.messageId}`);
  assert.deepEqual(r.transcript.map((x) => [x.from, x.text]), [
    ['REPORTED', 'Fuel stop'],
    ['REPORTER', 'ok noted'],
    ['REPORTED', 'rude words here'],
  ]);
  assert.ok(!r.transcript.some((x) => x.text === 'Someone else talking'), 'other riders are not in the transcript');
  void third;
  await h.endRide(R);
});

test('CHAT_REPORT: unknown message and my own message are refused', async () => {
  const { R, lead } = await chatRide();
  lead.sendJson({ type: 'CHAT_REPORT', messageId: 'MSG-nope' });
  const e1 = await lead.next((m) => m.type === 'ERROR');
  assert.equal(e1.code, 404);
  lead.sendJson({ type: 'CHAT', text: 'my own line', clientId: 'own-1' });
  const mine = await lead.next((m) => m.type === 'MESSAGE' && m.message.text === 'my own line');
  lead.sendJson({ type: 'CHAT_REPORT', messageId: mine.message.messageId });
  const e2 = await lead.next((m) => m.type === 'ERROR' && m !== e1);
  assert.equal(e2.code, 400);
  await h.endRide(R);
});

test('chat is rate limited (more than 5 a second: "Slow down")', async () => {
  const { R, ws } = await chatRide();
  for (let i = 0; i < 8; i++) ws.sendJson({ type: 'CHAT', text: `burst ${i}`, clientId: `b-${i}` });
  const e = await ws.next((m) => m.type === 'ERROR' && m.code === 429);
  assert.equal(e.message, 'Slow down.');
  await h.endRide(R);
});
