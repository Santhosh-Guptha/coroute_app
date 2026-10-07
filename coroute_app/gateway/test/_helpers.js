'use strict';
/**
 * Shared helpers for the newer test files: boot a full gateway on MemorySoda,
 * call the REST API, register riders with a complete safety profile, and open
 * WebSockets that collect what they receive. Not a test file itself
 * (`npm test` runs test/*.test.js only).
 *
 * Set process.env (NODE_ENV=test and any overrides) BEFORE requiring this file.
 */
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

const quiet = { info() {}, warn() {}, error() {} };

async function boot(opts = {}) {
  const soda = opts.soda || new MemorySoda();
  const gw = await createApp({ soda, logger: quiet, ...opts });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  const origin = `http://127.0.0.1:${port}`;
  const base = `${origin}/api`;
  const wsBase = `ws://127.0.0.1:${port}/ws`;

  async function api(method, path, body, token, headers = {}) {
    const res = await fetch(base + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
      body: body === undefined || body === null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
    });
    const json = await res.json().catch(() => ({}));
    return { status: res.status, json, headers: res.headers };
  }

  let phoneSeq = 0;
  /** Registers a rider with every mandatory safety field filled in. */
  async function register(name, email, extra = {}) {
    phoneSeq++;
    const r = await api('POST', '/auth/register', {
      name, email, password: 'Password#123',
      phone: `+9198765${String(10000 + phoneSeq).slice(-5)}`,
      vehicleType: 'Motorcycle', vehicleNo: `TS09AB${String(1000 + phoneSeq).slice(-4)}`,
      emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
      ...extra,
    });
    assert.equal(r.status, 201, JSON.stringify(r.json));
    return r.json;
  }

  function connect(token) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`${wsBase}?token=${token}`);
      ws.inbox = [];
      ws.waiters = [];
      ws.closeCode = null;
      ws.on('message', (data, isBinary) => {
        const item = isBinary ? { binary: Buffer.from(data) } : JSON.parse(data.toString());
        const w = ws.waiters.findIndex((wt) => wt.pred(item));
        if (w >= 0) ws.waiters.splice(w, 1)[0].resolve(item); else ws.inbox.push(item);
      });
      ws.closed = new Promise((res) => ws.on('close', (code) => { ws.closeCode = code; res(code); }));
      ws.next = (pred, timeout = 1500) => new Promise((res, rej) => {
        const i = ws.inbox.findIndex(pred);
        if (i >= 0) return res(ws.inbox.splice(i, 1)[0]);
        const t = setTimeout(() => rej(new Error('timeout waiting for message')), timeout);
        ws.waiters.push({ pred, resolve: (v) => { clearTimeout(t); res(v); } });
      });
      ws.sendJson = (o) => ws.send(JSON.stringify(o));
      ws.once('open', () => resolve(ws));
      ws.once('error', (e) => { if (ws.readyState !== WebSocket.OPEN) reject(e); });
    });
  }

  /** Connects and joins a convoy room; resolves after the SNAPSHOT. */
  async function joinRoom(token, groupId) {
    const ws = await connect(token);
    ws.sendJson({ type: 'JOIN', groupId });
    const snap = await ws.next((m) => m.type === 'SNAPSHOT');
    ws.snapshot = snap.convoy;
    return ws;
  }

  return { gw, soda, origin, base, wsBase, api, register, connect, joinRoom };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

module.exports = { boot, sleep, quiet };
