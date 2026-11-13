'use strict';
/**
 * Round 8 voice relay, VOICE_RELAY_MODE=process: the gateway forks src/voice_relay_server.js, apps with caps get a
 * ticket in VOICE_CODEC and talk on /voice; the floor and membership stay with the gateway (IPC); old builds on
 * /ws still hear and are heard; a rider who leaves the ride loses the voice socket; shutdown stops the process.
 */
process.env.NODE_ENV = 'test';
process.env.VOICE_RELAY_MODE = 'process';
process.env.VOICE_RELAY_PORT = '0';
process.env.VOICE_CAPS_GRACE_MS = '100';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { boot, sleep } = require('./_helpers');
const { encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END } = require('../src/voice_relay');

let env; let relay;
before(async () => {
  env = await boot();
  relay = env.gw.hub.voiceRelay;
  for (let i = 0; i < 100 && !(relay.edge && relay.edge.ready); i++) await sleep(50);
});
after(async () => { await env.gw.shutdown(); });

function voiceSocket(port, ticket) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/voice`, ['coroute.voice.v1', `coroute.voice.t.${ticket}`]);
    ws.inbox = []; ws.waiters = [];
    ws.on('message', (data, isBinary) => {
      const item = isBinary ? decodeVoice(Buffer.from(data)) : JSON.parse(data.toString());
      const w = ws.waiters.findIndex((x) => x.pred(item));
      if (w >= 0) ws.waiters.splice(w, 1)[0].resolve(item); else ws.inbox.push(item);
    });
    ws.next = (pred, timeout = 4000) => new Promise((res, rej) => {
      const i = ws.inbox.findIndex(pred);
      if (i >= 0) return res(ws.inbox.splice(i, 1)[0]);
      const t = setTimeout(() => rej(new Error(`timeout: ${pred}`)), timeout);
      ws.waiters.push({ pred, resolve: (v) => { clearTimeout(t); res(v); } });
    });
    ws.closed = new Promise((res) => ws.on('close', (code) => res(code)));
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

test('process mode boots: the voice process is up, /voice/health answers', async () => {
  assert.equal(relay.mode, 'process');
  assert.ok(relay.edge && relay.edge.ready, 'voice process ready');
  assert.ok(relay.edge.port > 0);
  const h = await (await fetch(`http://127.0.0.1:${relay.edge.port}/voice/health`)).json();
  assert.equal(h.ok, true);
});

test('new apps talk on /voice, an old build on /ws hears them and is heard; the floor is shared; leaving revokes', async () => {
  const users = [];
  for (const n of ['PA', 'PB', 'PC']) users.push(await env.register(`Proc ${n}`, `voice-proc-${n.toLowerCase()}@coroute.test`));
  const c = (await env.api('POST', '/convoys', { name: 'Proc ride' }, users[0].token)).json;
  for (const u of users.slice(1)) await env.api('POST', '/convoys/join', { code: c.joinCode }, u.token);
  const [a, b, old] = await Promise.all(users.map((u) => env.joinRoom(u.token, c.groupId)));
  a.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16'] });
  b.sendJson({ type: 'VOICE_CAPS', codecs: ['opus1', 'pcm16'] });
  const ca = await a.next((m) => m.type === 'VOICE_CODEC');
  const cb = await b.next((m) => m.type === 'VOICE_CODEC');
  assert.equal(ca.voice.path, '/voice');
  assert.ok(ca.voice.ticket && cb.voice.ticket);

  // A forged ticket is refused.
  const bad = await voiceSocket(relay.edge.port, ca.voice.ticket.replace(/.$/, (ch) => (ch === 'A' ? 'B' : 'A')));
  assert.equal(await bad.closed, 4401);

  const va = await voiceSocket(relay.edge.port, ca.voice.ticket);
  const vb = await voiceSocket(relay.edge.port, cb.voice.ticket);
  await va.next((m) => m.type === 'VOICE_READY');
  await vb.next((m) => m.type === 'VOICE_READY');
  await sleep(150); // the old build's caps grace runs out: the group needs PCM

  // A talks on /voice (PCM: an old build listens).
  va.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'pcm16' }));
  va.send(encodeVoice(VOICE_FRAME, { seq: 0 }, Buffer.alloc(1280, 5)));
  const sb = await vb.next((m) => m.kind === VOICE_START);
  assert.equal(sb.header.from, users[0].user.userId);
  const fb = await vb.next((m) => m.kind === VOICE_FRAME);
  assert.equal(fb.payload.length, 1280);
  const fo = decodeVoice((await old.next((m) => m.binary && m.binary[0] === VOICE_FRAME)).binary);
  assert.equal(fo.header.streamId, sb.header.streamId, 'the old build on /ws hears the same stream');
  await a.next((m) => m.type === 'MIC_STATUS' && m.isSpeaking === true);

  // The floor is the gateway's: the old build gets VOICE_BUSY while A talks on /voice.
  old.send(encodeVoice(VOICE_START, { sampleRate: 16000 }));
  const busy = await old.next((m) => m.type === 'VOICE_BUSY');
  assert.equal(busy.speaker, users[0].user.name);
  va.send(encodeVoice(VOICE_END, {}));
  await vb.next((m) => m.kind === VOICE_END);
  await old.next((m) => m.binary && m.binary[0] === VOICE_END);
  await sleep(50);
  assert.equal(a.inbox.filter((m) => m.binary).length, 0, 'never back to the speaker');
  assert.equal(b.inbox.filter((m) => m.binary).length, 0, 'no double audio on the /ws socket of a /voice listener');

  // The old build talks on /ws: A and B hear it on /voice.
  old.send(encodeVoice(VOICE_START, { sampleRate: 8000, codec: 'pcm16' }));
  old.send(encodeVoice(VOICE_FRAME, { seq: 0 }, Buffer.alloc(640, 2)));
  const s2 = await va.next((m) => m.kind === VOICE_START);
  assert.equal(s2.header.sampleRate, 8000);
  await vb.next((m) => m.kind === VOICE_FRAME);
  old.send(encodeVoice(VOICE_END, {}));
  await va.next((m) => m.kind === VOICE_END);

  // Leaving the ride closes the voice socket.
  a.sendJson({ type: 'LEAVE' });
  assert.equal(await va.closed, 4403);
  vb.close(); a.close(); b.close(); old.close();
});

test('shutdown stops the voice process', async () => {
  const child = relay.edge.child;
  const exited = new Promise((r) => child.once('exit', r));
  relay.close();
  await exited;
  assert.ok(child.exitCode !== null || child.signalCode !== null);
});
