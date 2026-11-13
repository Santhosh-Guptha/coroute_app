'use strict';
/**
 * Round 8 voice relay process (VOICE_RELAY_MODE=process). Forked by src/voice_relay.js (VoiceRelay) with an IPC
 * channel; never started on its own. Serves the WebSocket path /voice on VOICE_RELAY_HOST:VOICE_RELAY_PORT
 * (default 127.0.0.1:3010; Caddy routes /voice here, deploy/caddy/voice_relay.caddy) and GET /voice/health.
 * Holds only voice sockets: no database, no rooms, no SOS. Every floor / membership decision is asked of the
 * gateway over IPC (VoiceEdge), so a voice storm here can never slow the live node's safety traffic.
 */
const http = require('http');
const config = require('./config');
const { VoiceEdge } = require('./voice_relay');

if (!process.send) {
  console.error('voice_relay_server.js is started by the gateway (VOICE_RELAY_MODE=process), not directly.');
  process.exit(2);
}

const envInt = (k, d) => { const n = parseInt(process.env[k] || '', 10); return Number.isFinite(n) && n >= 0 ? n : d; };
const port = envInt('VOICE_RELAY_PORT', 3010);
const host = process.env.VOICE_RELAY_HOST || '127.0.0.1';
const quiet = { info() {}, warn() {}, error() {} };

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && (req.url === '/voice/health' || req.url === '/health')) {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ ok: true, sockets: edge.socks.size, streams: edge.streams.size }));
    return;
  }
  res.writeHead(404);
  res.end();
});
const edge = new VoiceEdge({ server, secret: config.jwtSecret, logger: quiet, link: { send: (m) => { try { process.send(m); } catch { /* parent gone */ } } } });
process.on('message', (m) => { try { edge.onLink(m); } catch { /* one bad message never kills the relay */ } });
process.on('disconnect', () => process.exit(0));
server.listen(port, host, () => { try { process.send({ t: 'ready', port: server.address().port }); } catch { /* parent gone */ } });
