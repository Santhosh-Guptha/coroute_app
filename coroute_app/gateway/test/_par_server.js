'use strict';
/**
 * A fake OCI Object Storage bucket PAR for tests (not a test file itself):
 *   PUT/GET/HEAD/DELETE  /p/<token>/n/ns/b/bucket/o/<encoded name>
 *   GET                  /p/<token>/n/ns/b/bucket/o/?prefix=&start=&limit=&fields=   (object listing)
 * Options: allowDelete (else 405), allowList (else 404), pageSize, failNext (that many 503 answers).
 */
const http = require('http');

async function startParServer({ allowDelete = true, allowList = true, pageSize = 1000, token = 'tok3n' } = {}) {
  const objects = new Map(); // name -> { body, type, at }
  const log = [];
  const state = { allowDelete, allowList, pageSize, failNext: 0, dropNext: 0 };
  const base = `/p/${token}/n/ns/b/bucket/o/`;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const url = new URL(req.url, 'http://x');
      log.push({ method: req.method, path: url.pathname, query: url.search });
      if (state.dropNext > 0) { state.dropNext--; req.socket.destroy(); return; }
      if (state.failNext > 0) { state.failNext--; res.writeHead(503); return res.end('busy'); }
      if (!url.pathname.startsWith(base)) { res.writeHead(404); return res.end(); }
      const rest = url.pathname.slice(base.length);
      if (rest === '') {
        if (req.method !== 'GET' || !state.allowList) { res.writeHead(404); return res.end('{"code":"NotAuthorizedOrNotFound"}'); }
        const prefix = url.searchParams.get('prefix') || '';
        const start = url.searchParams.get('start') || '';
        const limit = Math.min(Number(url.searchParams.get('limit')) || 1000, state.pageSize);
        const names = [...objects.keys()].filter((n) => n.startsWith(prefix) && n >= start).sort();
        const page = names.slice(0, limit);
        const body = { objects: page.map((n) => ({ name: n, size: objects.get(n).body.length, timeCreated: objects.get(n).at })) };
        if (names.length > limit) body.nextStartWith = names[limit];
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(body));
      }
      const name = decodeURIComponent(rest);
      const o = objects.get(name);
      switch (req.method) {
        case 'PUT':
          objects.set(name, { body: Buffer.concat(chunks), type: req.headers['content-type'], at: new Date().toISOString() });
          res.writeHead(200, { ETag: `"${objects.size}"` }); return res.end();
        case 'GET':
          if (!o) { res.writeHead(404); return res.end(); }
          res.writeHead(200, { 'Content-Type': o.type || 'application/octet-stream', 'Content-Length': o.body.length }); return res.end(o.body);
        case 'HEAD':
          if (!o) { res.writeHead(404); return res.end(); }
          res.writeHead(200, { 'Content-Length': o.body.length }); return res.end();
        case 'DELETE':
          if (!state.allowDelete) { res.writeHead(405); return res.end(); }
          if (!o) { res.writeHead(404); return res.end(); }
          objects.delete(name); res.writeHead(204); return res.end();
        default:
          res.writeHead(405); return res.end();
      }
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}${base}`;
  return { url, objects, log, state, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}

module.exports = { startParServer };
