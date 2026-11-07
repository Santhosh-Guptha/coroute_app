'use strict';
/**
 * OCI Object Storage through a Pre-Authenticated Request (PAR) — no OCI SDK, no API keys on the VM.
 *
 *   createParStore('https://objectstorage.<region>.oraclecloud.com/p/<token>/n/<ns>/b/<bucket>/o/')
 *     .put(name, buffer, contentType)   PUT  <base><encodeURIComponent(name)>
 *     .get(name)       -> Buffer | null GET  (404 and tombstones -> null)
 *     .exists(name)    -> boolean       HEAD
 *     .del(name)       -> { deleted, tombstoned }
 *     .list(prefix)    -> [{ name, size, timeCreated }]  GET <base>?prefix=..&fields=name,size,timeCreated
 *
 * The PAR must be a BUCKET-level PAR ("Permit object reads and writes"; enable "object listing" for
 * list()). The PAR URL is a bearer secret: it is never logged, never put into an error message and
 * never sent to a client (photos and backups are always streamed through the gateway).
 *
 * Deleting: OCI PARs do not always permit DELETE (403/405 depending on the access type). Then del()
 * OVERWRITES the object with a small tombstone marker, so the original bytes (e.g. a review photo of
 * a deleted account) are gone, and get()/list() treat the object as deleted. Keep object versioning
 * OFF on this bucket (a versioned bucket would keep the overwritten bytes as a previous version), and
 * set a lifecycle rule to physically purge old objects (see backup_jobs.js for the backup prefix).
 *
 * Transient failures (network errors, timeouts, 429, 5xx) are retried with exponential backoff.
 */

const TOMBSTONE = Buffer.from('COROUTE-TOMBSTONE-v1\n', 'utf8');
const TOMBSTONE_TYPE = 'application/x-coroute-tombstone';

class ObjectStoreError extends Error {
  constructor(message, status = 0, code = 'OBJECT_STORE') {
    super(message);
    this.name = 'ObjectStoreError';
    this.status = status;
    this.code = code;
  }
}

const isTombstone = (buf) => Buffer.isBuffer(buf) && buf.length === TOMBSTONE.length && buf.equals(TOMBSTONE);

function validBaseUrl(u) {
  try {
    const x = new URL(String(u).replace('.oraclecloudapps.com', '.oraclecloud.com'));
    return (x.protocol === 'https:' || x.protocol === 'http:') && /\/o\/?$/.test(x.pathname);
  } catch { return false; }
}

/**
 * @param {string} parBaseUrl bucket PAR ending in /o/
 * @param {{fetchImpl?:Function, retries?:number, timeoutMs?:number, backoffMs?:number}} [opts]
 */
function createParStore(parBaseUrl, opts = {}) {
  const sanitized = String(parBaseUrl || '').replace('.oraclecloudapps.com', '.oraclecloud.com');
  if (!sanitized || !validBaseUrl(sanitized)) {
    throw new ObjectStoreError('Object store: the PAR URL must be a bucket PAR ending in /o/.', 0, 'BAD_PAR_URL');
  }
  const base = sanitized.replace(/\/?$/, '/');
  const fetchImpl = opts.fetchImpl || globalThis.fetch;
  const retries = opts.retries ?? 3;
  const timeoutMs = opts.timeoutMs ?? 30000;
  const backoffMs = opts.backoffMs ?? 200;

  const checkName = (name) => {
    if (typeof name !== 'string' || !name || name.length > 1024 || name.includes('\0')) throw new ObjectStoreError('Object store: invalid object name.', 0, 'BAD_NAME');
    return name;
  };
  const urlOf = (name) => base + encodeURIComponent(checkName(name));

  /** fetch with retries; `what` names the operation for errors (never the URL: it holds the PAR token). */
  async function call(method, url, { body, headers = {}, what }) {
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        const res = await fetchImpl(url, { method, headers, body, signal: AbortSignal.timeout(timeoutMs) });
        if ((res.status >= 500 || res.status === 429) && attempt < retries) {
          await res.arrayBuffer().catch(() => {});
          lastErr = new ObjectStoreError(`Object store ${what} failed (${res.status}).`, res.status);
        } else {
          return res;
        }
      } catch (err) {
        lastErr = new ObjectStoreError(`Object store ${what} failed (${err.name === 'TimeoutError' ? 'timeout' : 'network'}).`, 0, 'NETWORK');
        if (attempt >= retries) throw lastErr;
      }
      const wait = Math.min(5000, backoffMs * 2 ** attempt) + Math.floor(Math.random() * backoffMs);
      await new Promise((r) => setTimeout(r, wait));
    }
    throw lastErr;
  }
  const fail = async (res, what) => {
    await res.arrayBuffer().catch(() => {});
    return new ObjectStoreError(`Object store ${what} failed (${res.status}).`, res.status);
  };

  const store = {
    kind: 'par',
    async put(name, data, contentType = 'application/octet-stream') {
      const body = Buffer.isBuffer(data) ? data : Buffer.from(data);
      const res = await call('PUT', urlOf(name), { body, headers: { 'Content-Type': contentType }, what: `put ${name}` });
      if (!res.ok) throw await fail(res, `put ${name}`);
      await res.arrayBuffer().catch(() => {});
      return { name, bytes: body.length, etag: res.headers.get('etag') || null };
    },
    async get(name) {
      const res = await call('GET', urlOf(name), { what: `get ${name}` });
      if (res.status === 404) { await res.arrayBuffer().catch(() => {}); return null; }
      if (!res.ok) throw await fail(res, `get ${name}`);
      const buf = Buffer.from(await res.arrayBuffer());
      return isTombstone(buf) ? null : buf;
    },
    async exists(name) {
      const res = await call('HEAD', urlOf(name), { what: `head ${name}` });
      await res.arrayBuffer().catch(() => {});
      if (res.status === 404) return false;
      if (!res.ok) throw new ObjectStoreError(`Object store head ${name} failed (${res.status}).`, res.status);
      return Number(res.headers.get('content-length')) !== TOMBSTONE.length || (await store.get(name)) !== null;
    },
    /** Deletes, or (when the PAR does not allow DELETE) overwrites the object with a tombstone. */
    async del(name) {
      const res = await call('DELETE', urlOf(name), { what: `delete ${name}` });
      await res.arrayBuffer().catch(() => {});
      if (res.ok || res.status === 404) return { deleted: true, tombstoned: false };
      if (res.status === 403 || res.status === 405 || res.status === 401) {
        await store.put(name, TOMBSTONE, TOMBSTONE_TYPE);
        return { deleted: true, tombstoned: true };
      }
      throw new ObjectStoreError(`Object store delete ${name} failed (${res.status}).`, res.status);
    },
    /**
     * Every object whose name starts with prefix (tombstones left out). Needs a PAR with object listing.
     * `raw: true` skips the tombstone check (no extra reads); tombstones then show with size TOMBSTONE.length.
     */
    async list(prefix = '', { raw = false } = {}) {
      const out = [];
      let start = null;
      for (let page = 0; page < 10000; page++) {
        const q = new URLSearchParams({ prefix, fields: 'name,size,timeCreated', limit: '1000' });
        if (start) q.set('start', start);
        const res = await call('GET', `${base}?${q}`, { what: 'list' });
        if (res.status === 401 || res.status === 403 || res.status === 404 || res.status === 405) {
          await res.arrayBuffer().catch(() => {});
          throw new ObjectStoreError('Object store: this PAR does not allow listing objects.', res.status, 'LIST_UNSUPPORTED');
        }
        if (!res.ok) throw await fail(res, 'list');
        const body = await res.json().catch(() => null);
        if (!body || !Array.isArray(body.objects)) throw new ObjectStoreError('Object store list returned an unexpected answer.', res.status);
        for (const o of body.objects) {
          if (!o || typeof o.name !== 'string') continue;
          const size = Number.isFinite(o.size) ? o.size : null;
          if (!raw && size === TOMBSTONE.length && (await store.get(o.name)) === null) continue;
          out.push({ name: o.name, size, timeCreated: o.timeCreated || null });
        }
        if (!body.nextStartWith) break;
        start = body.nextStartWith;
      }
      return out;
    },
  };
  return store;
}

/** Same API kept in memory (tests, local development). */
function createMemoryStore() {
  const objects = new Map();
  return {
    kind: 'memory',
    objects,
    async put(name, data, contentType = 'application/octet-stream') {
      const body = Buffer.from(data);
      objects.set(name, { body, contentType, timeCreated: new Date().toISOString() });
      return { name, bytes: body.length, etag: null };
    },
    async get(name) { const o = objects.get(name); return o ? Buffer.from(o.body) : null; },
    async exists(name) { return objects.has(name); },
    async del(name) { objects.delete(name); return { deleted: true, tombstoned: false }; },
    async list(prefix = '') {
      return [...objects.entries()].filter(([n]) => n.startsWith(prefix)).sort(([a], [b]) => (a < b ? -1 : 1))
        .map(([name, o]) => ({ name, size: o.body.length, timeCreated: o.timeCreated }));
    },
  };
}

module.exports = { createParStore, createMemoryStore, ObjectStoreError, TOMBSTONE, isTombstone };
