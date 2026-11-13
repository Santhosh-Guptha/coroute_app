'use strict';
/**
 * Round 8 voice relay (src/voice_relay.js), in-process mode: group-only routing, codec negotiation and the PCM
 * fallback rule, lowest priority under backpressure (an SOS overtakes voice), per-speaker caps, talk-time
 * fairness, metrics. Process mode: test/voice_relay_process_r8.test.js.
 */
process.env.NODE_ENV = 'test';
process.env.VOICE_CAPS_GRACE_MS = '150';
process.env.VOICE_FAIR_HOLD_MS = '400';
process.env.VOICE_MAX_BYTES_PER_SEC = '20000';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { WebSocket } = require('ws');
const { boot, sleep } = require('./_helpers');
const { VoiceRelay, encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END, VOICE_DROP_BYTES } = require('../src/voice_relay');
const { FEATURES } = require('../src/ws');

let env;
before(async () => { env = await boot(); });
after(async () => { await env.gw.shutdown(); });

let seq = 0;
async function group(n, name = 'Voice') {
  const users = [];
  for (let i = 0; i < n; i++) users.push(await env.register(`${name} ${i}`, `voice-r8-${++seq}@coroute.test`));
  const c = (await env.api('POST', '/convoys', { name: `${name} ride` }, users[0].token)).json;
  for (const u of users.slice(1)) await env.api('POST', '/convoys/join', { code: c.joinCode }, u.token);
  return { users, groupId: c.groupId };
}
const frames = (ws, kind) => ws.inbox.filter((m) => m.binary && m.binary[0] === kind).map((m) => decodeVoice(m.binary));
const serverSocketOf = (gid, userId) => [...env.gw.hub.rooms.get(gid)].find((c) => c.user.userId === userId);

test('HELLO advertises voice2; VOICE_CAPS from every rider -> VOICE_CODEC opus1', async () => {
  assert.ok(FEATURES.includes('voice2'));
  const { users, groupId } = await group(2, 'Caps');
  const [a, b] = await Promise.all(users.map((u) => env.joinRoom(u.token, groupId)));
  a.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16'] });
  const ca = await a.next((m) => m.type === 'VOICE_CODEC');
  assert.equal(ca.codec, 'opus1');
  assert.equal(ca.groupId, groupId);
  assert.equal(ca.voice, undefined, 'in-process mode: no separate voice socket');
  b.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16', 'bogus'] });
  assert.equal((await b.next((m) => m.type === 'VOICE_CODEC')).codec, 'opus1');
  a.close(); b.close();
});

test('an old build in the group: VOICE_CODEC pcm16 to everyone, an Opus START is refused, PCM still flows to all', async () => {
  const { users, groupId } = await group(3, 'Mixed');
  const [a, b, old] = await Promise.all(users.map((u) => env.joinRoom(u.token, groupId)));
  a.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16'] });
  b.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16'] });
  // Within the grace time the silent socket is "maybe new": opus1.
  assert.equal((await a.next((m) => m.type === 'VOICE_CODEC')).codec, 'opus1');
  await b.next((m) => m.type === 'VOICE_CODEC');
  await sleep(250); // the old build never announces caps
  a.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'opus1' }));
  const switched = await a.next((m) => m.type === 'VOICE_CODEC' && m.codec === 'pcm16');
  assert.equal(switched.reason, 'old_listener');
  assert.equal((await b.next((m) => m.type === 'VOICE_CODEC')).codec, 'pcm16', 'everyone with caps hears about the change');
  await a.next((m) => m.type === 'VOICE_CODEC' && m.refused === true);
  await sleep(50);
  assert.equal(frames(old, VOICE_START).length, 0, 'the refused Opus stream never started');
  assert.equal(old.inbox.filter((m) => m.type === 'VOICE_CODEC').length, 0, 'an old build is never sent VOICE_CODEC');
  // The app restarts in PCM: everybody hears it, the old build included.
  a.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'pcm16' }));
  a.send(encodeVoice(VOICE_FRAME, { seq: 0 }, Buffer.alloc(1280, 3)));
  const f = decodeVoice((await old.next((m) => m.binary && m.binary[0] === VOICE_FRAME)).binary);
  assert.equal(f.payload.length, 1280);
  await b.next((m) => m.binary && m.binary[0] === VOICE_FRAME);
  a.send(encodeVoice(VOICE_END, {}));
  await old.next((m) => m.binary && m.binary[0] === VOICE_END);
  // The old build leaves: the group goes back to Opus.
  old.close();
  const back = await a.next((m) => m.type === 'VOICE_CODEC' && m.codec === 'opus1');
  assert.equal(back.reason, 'all_opus');
  a.close(); b.close();
});

test('Opus to Opus listeners with a compact frame header; group-only (another ride hears nothing)', async () => {
  const g1 = await group(3, 'OpusA');
  const g2 = await group(1, 'OpusB');
  const [a, b, c] = await Promise.all(g1.users.map((u) => env.joinRoom(u.token, g1.groupId)));
  const x = await env.joinRoom(g2.users[0].token, g2.groupId);
  for (const w of [a, b, c, x]) w.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16'] });
  await Promise.all([a, b, c, x].map((w) => w.next((m) => m.type === 'VOICE_CODEC')));
  const opus = Buffer.from([0, 3, 1, 2, 3, 0, 2, 9, 9]); // two length-prefixed packets
  a.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'opus1' }));
  const st = decodeVoice((await b.next((m) => m.binary && m.binary[0] === VOICE_START)).binary);
  assert.equal(st.header.codec, 'opus1');
  assert.equal(st.header.from, g1.users[0].user.userId);
  a.send(encodeVoice(VOICE_FRAME, { seq: 7 }, opus));
  const fr = decodeVoice((await c.next((m) => m.binary && m.binary[0] === VOICE_FRAME)).binary);
  assert.deepEqual(Object.keys(fr.header).sort(), ['codec', 'from', 'seq', 'streamId']);
  assert.equal(fr.header.seq, 7);
  assert.equal(fr.header.streamId, st.header.streamId);
  assert.deepEqual([...fr.payload], [...opus]);
  a.send(encodeVoice(VOICE_END, {}));
  await b.next((m) => m.binary && m.binary[0] === VOICE_END);
  await sleep(50);
  assert.equal(x.inbox.filter((m) => m.binary).length, 0, 'never across rides');
  assert.equal(frames(a, VOICE_FRAME).length, 0, 'never back to the speaker');
  for (const w of [a, b, c, x]) w.close();
});

test('lowest priority: a listener with a backlog gets no voice, and its queued SOS still arrives first', async () => {
  const { users, groupId } = await group(3, 'Backpressure');
  const [talker, slow, other] = await Promise.all(users.map((u) => env.joinRoom(u.token, groupId)));
  const srv = serverSocketOf(groupId, users[1].user.userId);
  let fake = 200 * 1024; // over WS_OUT_SOFT_BYTES: JSON gets queued, voice gets dropped
  Object.defineProperty(srv, 'bufferedAmount', { get: () => fake, configurable: true });
  const before = env.gw.hub.stats.voiceDropped;
  talker.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'pcm16' }));
  for (let i = 0; i < 5; i++) talker.send(encodeVoice(VOICE_FRAME, { seq: i }, Buffer.alloc(1280, 1)));
  await other.next((m) => m.binary && m.binary[0] === VOICE_FRAME);
  // SOS while the slow socket is backlogged: queued in the safety lane.
  other.sendJson({ type: 'SOS', clientId: 'sos-r8-1', lat: 17.4, lng: 78.4, source: 'manual' });
  // Poll instead of a fixed sleep: under a full parallel test run the gateway can need longer than 150 ms.
  for (const until = Date.now() + 3000; Date.now() < until && !(srv.outq && env.gw.hub.stats.voiceDropped >= before + 5);) await sleep(25);
  assert.ok(srv.outq, 'the SOS is queued for the slow socket');
  assert.ok(env.gw.hub.stats.voiceDropped >= before + 5, 'voice frames dropped, not queued');
  talker.send(encodeVoice(VOICE_FRAME, { seq: 9 }, Buffer.alloc(1280, 1))); // still dropped: queue not empty
  fake = 0; // the link recovers: the queue drains
  const alert = await slow.next((m) => m.type === 'ALERT', 3000);
  assert.ok(alert);
  const firstVoiceIdx = slow.inbox.findIndex((m) => m.binary && m.binary[0] === VOICE_FRAME);
  assert.equal(firstVoiceIdx, -1, 'no voice frame was delivered ahead of (or instead of) the SOS');
  talker.send(encodeVoice(VOICE_END, {}));
  delete srv.bufferedAmount;
  for (const w of [talker, slow, other]) w.close();
});

test('lowest priority (unit): voice only below VOICE_DROP_BYTES and with no queued backlog', () => {
  assert.equal(VoiceRelay.voiceMaySend({ outq: null, bufferedAmount: 0 }), true);
  assert.equal(VoiceRelay.voiceMaySend({ outq: null, bufferedAmount: VOICE_DROP_BYTES + 1 }), false);
  assert.equal(VoiceRelay.voiceMaySend({ outq: [[], [], new Map()], bufferedAmount: 0 }), false);
  assert.ok(VOICE_DROP_BYTES < 128 * 1024, 'under the queueing threshold for safety messages');
});

// A fake hub for the unit tests below.
function fakeHub() {
  const hub = {
    rooms: new Map(), voice: new Map(), stats: {}, sent: [], errors: [], roomSent: [], mirror: null,
    convoys: { rooms: new Map(), featureFlags: null, isLead: (room, u) => u.userId === 'lead' },
    repo: { logged: [], logVoiceSession(e) { this.logged.push(e); } },
    send(ws, obj) { hub.sent.push({ to: ws.user.userId, ...obj }); },
    sendError(ws, code, message, reason) { hub.errors.push({ to: ws.user.userId, code, message, reason }); },
    roomSend(gid, obj) { hub.roomSent.push(obj); },
  };
  return hub;
}
function sock(hub, uid, gid = 'G') {
  const s = { user: { userId: uid, name: uid, role: 'RIDER' }, groupId: gid, readyState: WebSocket.OPEN, bufferedAmount: 0, outq: null, got: [],
    send(b) { s.got.push(decodeVoice(b)); } };
  if (!hub.rooms.has(gid)) hub.rooms.set(gid, new Set());
  if (!hub.convoys.rooms.has(gid)) hub.convoys.rooms.set(gid, { riders: new Map(), meta: {} });
  hub.rooms.get(gid).add(s);
  return s;
}

test('caps: frame size, frames per second and bytes per second per speaker', () => {
  const hub = fakeHub();
  const relay = new VoiceRelay(hub, { mode: 'inprocess' });
  const a = sock(hub, 'a'); const b = sock(hub, 'b');
  relay.onBinary(a, encodeVoice(VOICE_START, { sampleRate: 16000 }));
  relay.onBinary(a, encodeVoice(VOICE_FRAME, { seq: 0 }, Buffer.alloc(17000))); // > VOICE_MAX_FRAME_BYTES
  for (let i = 1; i <= 30; i++) relay.onBinary(a, encodeVoice(VOICE_FRAME, { seq: i }, Buffer.alloc(1280)));
  const got = b.got.filter((p) => p.kind === VOICE_FRAME).length;
  assert.equal(got, Math.floor(20000 / 1280), 'VOICE_MAX_BYTES_PER_SEC=20000 lets 15 PCM frames through this second');
  assert.ok(hub.stats.voiceCapped >= 30 - got + 1);
  assert.equal(b.got[0].kind, VOICE_START);
});

test('fairness: after VOICE_FAIR_HOLD_MS the floor goes to the next rider who presses talk; the Lead is exempt', async () => {
  const hub = fakeHub();
  const relay = new VoiceRelay(hub, { mode: 'inprocess' });
  const a = sock(hub, 'a'); const b = sock(hub, 'b'); const lead = sock(hub, 'lead');
  relay.onBinary(a, encodeVoice(VOICE_START, {}));
  relay.onBinary(b, encodeVoice(VOICE_START, {}));
  assert.equal(hub.sent.at(-1).type, 'VOICE_BUSY', 'a fresh hold is respected');
  for (let i = 0; i < 9; i++) { await sleep(50); relay.onBinary(a, encodeVoice(VOICE_FRAME, { seq: i }, Buffer.alloc(100))); }
  relay.onBinary(b, encodeVoice(VOICE_START, {}));
  assert.equal(hub.stats.voiceFairShare, 1);
  assert.equal(relay.floorOf('G').from, 'b');
  const ends = lead.got.filter((p) => p.kind === VOICE_END);
  assert.equal(ends.at(-1).header.reason, 'fair-share');
  // The Lead holding the floor is not cut.
  relay.onBinary(b, encodeVoice(VOICE_END, {}));
  relay.onBinary(lead, encodeVoice(VOICE_START, {}));
  for (let i = 0; i < 9; i++) { await sleep(50); relay.onBinary(lead, encodeVoice(VOICE_FRAME, { seq: i }, Buffer.alloc(100))); }
  relay.onBinary(a, encodeVoice(VOICE_START, {}));
  assert.equal(hub.sent.at(-1).type, 'VOICE_BUSY');
  assert.equal(relay.floorOf('G').from, 'lead');
});

test('metrics: voice counters in hub.stats and on /metrics; speakers gauge follows live streams', async () => {
  const hub = fakeHub();
  const relay = new VoiceRelay(hub, { mode: 'inprocess' });
  const a = sock(hub, 'a'); sock(hub, 'b'); sock(hub, 'c');
  relay.onBinary(a, encodeVoice(VOICE_START, {}));
  assert.equal(relay.metrics().speakers, 1);
  relay.onBinary(a, encodeVoice(VOICE_FRAME, { seq: 1 }, Buffer.alloc(640)));
  const m = relay.metrics();
  assert.equal(m.framesIn, 1);
  assert.equal(m.framesOut, 2);
  assert.ok(m.bytesOut > 1280 && m.bytesIn > 640);
  relay.onBinary(a, encodeVoice(VOICE_END, {}));
  assert.equal(relay.metrics().speakers, 0);
  assert.equal(hub.repo.logged.length, 1, 'a session log line (who / when / how long), never audio');
  assert.equal(Object.keys(hub.repo.logged[0]).includes('payload'), false);
  const res = await fetch(`${env.origin}/metrics`);
  const text = await res.text();
  assert.match(text, /kind="voiceBytesIn"/);
  assert.match(text, /kind="voiceDropped"/);
});

test('1:1 and lead channel unchanged: a private stream reaches only its target', () => {
  const hub = fakeHub();
  const relay = new VoiceRelay(hub, { mode: 'inprocess' });
  const a = sock(hub, 'a'); const b = sock(hub, 'b'); const c = sock(hub, 'c');
  relay.onBinary(a, encodeVoice(VOICE_START, { to: 'b' }));
  relay.onBinary(a, encodeVoice(VOICE_FRAME, { to: 'b', seq: 1 }, Buffer.alloc(320)));
  assert.equal(b.got.length, 2);
  assert.equal(c.got.length, 0);
  relay.onBinary(a, encodeVoice(VOICE_START, { to: 'nobody' }));
  assert.equal(hub.errors.at(-1).code, 404);
  relay.onBinary(c, encodeVoice(VOICE_START, { channel: 'LEAD_ONLY' }));
  assert.equal(hub.errors.at(-1).code, 403);
});
