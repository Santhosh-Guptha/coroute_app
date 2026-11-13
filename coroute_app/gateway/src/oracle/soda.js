'use strict';
/**
 * Minimal, dependency-free client for Oracle Autonomous Database's
 * SODA for REST API (served by ORDS).
 *
 * Every document store call in the gateway goes through this class so the
 * credentials live in exactly one place (environment variables) and never
 * ship inside the mobile app.
 */
class SodaError extends Error {
  constructor(message, status, body) {
    super(message);
    this.name = 'SodaError';
    this.status = status;
    this.body = body;
  }
}

/**
 * Round 6: document revision for compare-and-replace (`casRev`).
 *
 * compareAndReplace sends a JSON Patch whose precondition tests each top-level SCALAR of the observed document
 * (Oracle includes `_id` in a whole-document `test`, so that form can never match). Scalars alone miss three kinds
 * of concurrent change: a change inside a nested object / array (coupon holds, refunds), a top-level key that was
 * ADDED (lease `wantedBy`, session `revokedAt`), and a plain replace that touches no scalar. So every document of
 * the collections below carries one scalar that changes on EVERY write: `casRev`, a unique token.
 *
 *  - insert / insertMany / replace (and upsertBy through them) stamp a fresh casRev on documents of CAS_COLLECTIONS
 *    (on the caller's object too, so a cached copy still matches the stored one);
 *  - compareAndReplace tests `/casRev` together with the scalars and writes a fresh one;
 *  - documents written before this release get one from the leased 'cas-rev-seed' job (seedRev: a JSON Patch `add`,
 *    which never loses an update). Until then they are compared by their scalars only, as before.
 *
 * Other collections behave exactly as before (no stamping, the same emitted patch).
 */
const REV_FIELD = 'casRev';
/** Every collection some caller compare-and-replaces (src/job_lease.js, sessions.js, repo.js coupons / orders ...). */
const CAS_COLLECTIONS = Object.freeze([
  'leases', 'auth_sessions', 'coupons', 'subscription_config', 'guardian_subscriptions', 'guardian_jobs',
  'mail_log', 'email_studio_templates', 'email_studio_campaigns', 'email_studio_rules', 'offer_email_campaigns',
  'push_campaigns', 'rider_scores', 'hosted_ride_counts', 'business_agg',
]);
let revSeq = 0;
/** A token no other write of this or any other node produces: time, a process-wide counter and 6 random bytes. */
function newRev() {
  revSeq = (revSeq + 1) % 1679616;
  return `${Date.now().toString(36)}.${revSeq.toString(36)}.${require('crypto').randomBytes(6).toString('hex')}`;
}
const isScalar = (v) => typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean' || v === null;
/** The `test` operations of a compare-and-replace: one per top-level scalar of the observed document (never `_id`). */
function casTests(expected) {
  const tests = [];
  if (expected && typeof expected === 'object' && !Array.isArray(expected)) {
    for (const [k, v] of Object.entries(expected)) {
      if (k !== '_id' && isScalar(v)) tests.push({ op: 'test', path: `/${String(k).replace(/~/g, '~0').replace(/\//g, '~1')}`, value: v });
    }
  } else {
    tests.push({ op: 'test', path: '', value: expected });
  }
  return tests;
}
/** True when a stored document passes those tests (MemorySoda uses it, so tests see what the database would do). */
function casTestsPass(stored, tests) {
  if (stored === undefined || stored === null) return false;
  for (const t of tests) {
    if (t.path === '') { if (!require('node:util').isDeepStrictEqual(stored, t.value)) return false; continue; }
    const k = t.path.slice(1).replace(/~1/g, '/').replace(/~0/g, '~');
    if (!Object.prototype.hasOwnProperty.call(stored, k) || stored[k] !== t.value) return false; // a missing path fails a JSON Patch test
  }
  return true;
}
const isPlainDoc = (d) => !!d && typeof d === 'object' && !Array.isArray(d);

class SodaClient {
  /**
   * @param {{baseUrl:string,user:string,password:string,timeoutMs?:number,fetchImpl?:Function}} opts
   */
  constructor(opts) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, '');
    this.authHeader = 'Basic ' + Buffer.from(`${opts.user}:${opts.password}`).toString('base64');
    this.timeoutMs = opts.timeoutMs || 6000;
    this.fetch = opts.fetchImpl || globalThis.fetch;
    // v3.56 connection budget: at most maxInFlight requests to ORDS at a time from this node (the Always Free
    // database has a small session pool shared by every node); the rest wait in a FIFO queue (bounded, and never
    // longer than timeoutMs). Safety-critical collections (SOS alerts, sessions = sign-in / refresh, job leases)
    // never wait: they bypass the budget. 0 = unlimited (the old behaviour).
    const envInt = (k, d) => { const n = parseInt(process.env[k] || '', 10); return Number.isFinite(n) && n >= 0 ? n : d; };
    this.maxInFlight = opts.maxInFlight ?? envInt('ORACLE_MAX_INFLIGHT', 16);
    this.maxQueue = opts.maxQueue ?? envInt('ORACLE_MAX_QUEUE', 2000);
    this.priority = new Set(opts.priorityCollections || String(process.env.ORACLE_PRIORITY_COLLECTIONS || 'alerts,auth_sessions,leases').split(',').map((x) => x.trim()).filter(Boolean));
    this.inFlight = 0;
    this.waiting = [];
    this.stats = { requests: 0, queued: 0, rejected: 0, maxQueue: 0, bypass: 0 };
    // Round 6: collections whose documents carry a casRev (see REV_FIELD above).
    this.revCollections = new Set(opts.revCollections || CAS_COLLECTIONS);
  }

  /** True when documents of this collection carry a revision token for compare-and-replace. */
  hasRev(collection) { return this.revCollections.has(collection); }

  /** A new document keeps a casRev it already carries (a restored backup stays byte-identical), else gets one. */
  _stampNew(collection, doc) {
    if (isPlainDoc(doc) && doc[REV_FIELD] !== undefined) return doc;
    return this._stamp(collection, doc);
  }

  /** Stamps a fresh casRev on a document that is about to be written (the caller's object: its copy stays in step). */
  _stamp(collection, doc) {
    if (this.revCollections.has(collection) && isPlainDoc(doc) && !Object.isFrozen(doc)) doc[REV_FIELD] = newRev();
    return doc;
  }

  /** Database calls waiting for a slot now (load shedding reads it). */
  queueLength() { return this.waiting.length; }

  _collectionOf(path) {
    const seg = String(path || '').split('?')[0].split('/')[1] || '';
    try { return decodeURIComponent(seg); } catch { return seg; }
  }

  /** Resolves to a release function once a slot is free (or at once for priority collections / no budget). */
  _acquire(path) {
    this.stats.requests++;
    if (!this.maxInFlight || !path || this.priority.has(this._collectionOf(path))) {
      if (this.maxInFlight) this.stats.bypass++;
      return Promise.resolve(() => {});
    }
    const grant = () => { this.inFlight++; let done = false; return () => { if (done) return; done = true; this.inFlight--; this._next(); }; };
    if (this.inFlight < this.maxInFlight && !this.waiting.length) return Promise.resolve(grant());
    if (this.waiting.length >= this.maxQueue) {
      this.stats.rejected++;
      return Promise.reject(new SodaError('SODA busy: too many database calls queued', 503, null));
    }
    this.stats.queued++;
    return new Promise((resolve, reject) => {
      const w = { resolve: () => resolve(grant()), timer: null };
      w.timer = setTimeout(() => {
        const i = this.waiting.indexOf(w);
        if (i >= 0) this.waiting.splice(i, 1);
        this.stats.rejected++;
        reject(new SodaError('SODA busy: timed out waiting for a database slot', 503, null));
      }, this.timeoutMs);
      if (w.timer.unref) w.timer.unref();
      this.waiting.push(w);
      if (this.waiting.length > this.stats.maxQueue) this.stats.maxQueue = this.waiting.length;
    });
  }

  _next() {
    while (this.inFlight < this.maxInFlight && this.waiting.length) {
      const w = this.waiting.shift();
      clearTimeout(w.timer);
      w.resolve();
    }
  }

  async _request(method, path, body, opts = {}) {
    const release = await this._acquire(path);
    try { return await this._requestNow(method, path, body, opts); } finally { release(); }
  }

  async _requestNow(method, path, body, { retries = 2, contentType = 'application/json' } = {}) {
    const url = `${this.baseUrl}${path}`;
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        const res = await this.fetch(url, {
          method,
          headers: {
            Authorization: this.authHeader,
            Accept: 'application/json',
            ...(body !== undefined ? { 'Content-Type': contentType } : {}),
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        const text = await res.text();
        let json = null;
        if (text) {
          try { json = JSON.parse(text); } catch { json = { raw: text }; }
        }
        const retryable = (res.status >= 500 || res.status === 429);
        if (retryable && attempt < retries) {
          lastErr = new SodaError(`SODA ${method} ${path} -> ${res.status}`, res.status, json);
          const backoffMs = Math.min(1000, 100 * Math.pow(2, attempt) + Math.floor(Math.random() * 50));
          await new Promise((r) => setTimeout(r, backoffMs));
          continue;
        }
        if (!res.ok) throw new SodaError(`SODA ${method} ${path} -> ${res.status}`, res.status, json);
        return json;
      } catch (err) {
        lastErr = err;
        const transient = err.name === 'TimeoutError' || err.name === 'AbortError' || err.code === 'ECONNRESET' || err.code === 'UND_ERR_SOCKET';
        if (!transient || attempt >= retries) throw err;
        const backoffMs = Math.min(1000, 100 * Math.pow(2, attempt) + Math.floor(Math.random() * 50));
        await new Promise((r) => setTimeout(r, backoffMs));
      }
    }
    throw lastErr;
  }

  /** Health probe: lists collections. */
  async ping() {
    const r = await this._request('GET', '', undefined, { retries: 0 });
    return Array.isArray(r?.items);
  }

  async listCollections() {
    const r = await this._request('GET', '');
    return (r?.items || []).map((c) => c.name);
  }

  /** Idempotent: creates the collection if missing. */
  async ensureCollection(name) {
    try {
      await this._request('PUT', `/${encodeURIComponent(name)}`);
    } catch (err) {
      // ORDS answers 200/201 when created, 200 when it already exists; anything else is real.
      if (!(err instanceof SodaError && err.status === 409)) throw err;
    }
  }

  /**
   * Creates an index. Idempotent (ignores "already exists").
   * @param {string} collection
   * @param {{name:string, unique?:boolean, fields:Array<{path:string,datatype?:string,order?:'asc'|'desc'}>}} spec
   */
  async ensureIndex(collection, spec) {
    try {
      await this._request('POST', `/${encodeURIComponent(collection)}?action=index`, spec);
    } catch (err) {
      const msg = JSON.stringify(err.body || '').toLowerCase();
      if (err instanceof SodaError && (err.status === 400 || err.status === 409) && /exist|ora-00955|ora-01408/.test(msg)) return;
      throw err;
    }
  }

  /** Inserts a document; returns the SODA key. */
  async insert(collection, doc) {
    this._stampNew(collection, doc);
    const r = await this._request('POST', `/${encodeURIComponent(collection)}`, doc, { retries: 0 });
    const item = r?.items?.[0];
    if (!item?.id) throw new SodaError('SODA insert returned no key', 500, r);
    return item.id;
  }

  /**
   * Bulk insert (SODA REST `?action=insert` with a JSON array): one round trip for many documents.
   * Returns the keys in input order. Never retried here: an ambiguous bulk write is resolved by the
   * caller (e.g. TrackStore re-checks which documents exist before inserting one by one).
   */
  async insertMany(collection, docs) {
    if (!Array.isArray(docs) || docs.length === 0) return [];
    for (const d of docs) this._stampNew(collection, d);
    const r = await this._request('POST', `/${encodeURIComponent(collection)}?action=insert`, docs, { retries: 0 });
    const items = r?.items || [];
    if (items.length !== docs.length || items.some((it) => !it?.id)) throw new SodaError('SODA bulk insert returned an unexpected key list', 500, r);
    return items.map((it) => it.id);
  }

  /**
   * Every document of a collection, page by page, as an async iterator of [{key, value}] pages (backups).
   * Keyset paging on the key (`fromID`, the listing is ordered by key), so documents inserted or deleted
   * meanwhile never make it skip others. If the server ignores `fromID`, it falls back to offset paging
   * (duplicates are dropped by key).
   */
  async *scan(collection, { pageSize = 500 } = {}) {
    const limit = Math.min(Math.max(pageSize, 2), 1000);
    const coll = `/${encodeURIComponent(collection)}`;
    const seen = new Set();
    let keyset = true;
    let lastKey = null;
    let offset = 0;
    for (let guard = 0; guard < 1e6; guard++) {
      const path = keyset && lastKey
        ? `${coll}?fromID=${encodeURIComponent(lastKey)}&limit=${limit + 1}&fields=all`
        : `${coll}?limit=${limit}&offset=${offset}&fields=all`;
      const r = await this._request('GET', path);
      const items = (r?.items || []).filter((it) => it && it.id);
      if (keyset && lastKey && items.length && items[0].id !== lastKey) {
        keyset = false; // fromID not honoured: continue by offset from where we are
        offset = seen.size;
        continue;
      }
      const page = [];
      for (const it of items) {
        if (seen.has(it.id)) continue;
        seen.add(it.id);
        page.push({ key: it.id, value: it.value });
      }
      if (page.length) yield page;
      const more = r?.hasMore === true || (r?.hasMore === undefined && items.length >= (keyset && lastKey ? limit + 1 : limit));
      if (!page.length || !more) return;
      lastKey = page[page.length - 1].key;
      offset += items.length;
    }
  }

  /** Replaces the document stored under key. */
  async replace(collection, key, doc) {
    this._stamp(collection, doc); // a plain replace is seen by every compare-and-replace that read the old document
    await this._request('PUT', `/${encodeURIComponent(collection)}/${encodeURIComponent(key)}`, doc, { retries: 0 });
    return key;
  }

  /**
   * The JSON Patch of one compare-and-replace: `test` for every top-level scalar of the observed document (casRev
   * among them when the document has one), then the whole-document replacement. In a CAS collection the replacement
   * gets a fresh casRev (set on the caller's object too, so the next compare-and-replace from it matches).
   */
  _casPatch(collection, expected, replacement) {
    const patch = casTests(expected);
    if (!patch.length) throw new SodaError('compareAndReplace needs at least one top-level scalar in the observed document', 500, null);
    if (isPlainDoc(replacement)) {
      if (this.revCollections.has(collection) && !Object.isFrozen(replacement)) replacement[REV_FIELD] = newRev();
      else if (!this.revCollections.has(collection) && isPlainDoc(expected) && expected[REV_FIELD] !== undefined && replacement[REV_FIELD] === expected[REV_FIELD]) {
        // A document that carries a casRev outside the listed collections keeps the guarantee.
        if (!Object.isFrozen(replacement)) replacement[REV_FIELD] = newRev();
      }
    }
    const clean = isPlainDoc(replacement) ? { ...replacement } : replacement;
    if (clean && clean._id) delete clean._id;
    patch.push({ op: 'replace', path: '', value: clean });
    return patch;
  }

  /**
   * Atomic JSON Patch test + replacement (Oracle SODA 18c+). Never retry an ambiguous write.
   * Resolves to true when the stored document still was the observed one and is now the replacement; false on a
   * conflict (the caller re-reads). See REV_FIELD at the top of this file for what "still the observed one" means.
   */
  async compareAndReplace(collection, key, expected, replacement) {
    if (this.revCollections.has(collection) && isPlainDoc(expected) && expected[REV_FIELD] === undefined) {
      return this._casWithoutRev(collection, key, expected, replacement);
    }
    return this._casApply(collection, key, this._casPatch(collection, expected, replacement));
  }

  /** Sends one compare-and-replace patch: true = applied, false = the precondition failed or the document is gone. */
  async _casApply(collection, key, patch) {
    try {
      await this._request('PATCH', `/${encodeURIComponent(collection)}/${encodeURIComponent(key)}`,
        patch,
        { retries: 0, contentType: 'application/json-patch+json' });
      return true;
    } catch (e) {
      if (e instanceof SodaError && [400, 404, 409, 412, 422].includes(e.status)) return false;
      throw e;
    }
  }

  /**
   * Compare-and-replace of a CAS-collection document that has no casRev yet (written before round 6, and not yet
   * reached by the 'cas-rev-seed' job). Its scalars alone cannot prove that nothing changed, so:
   *   1. read it: it must still have no casRev and equal the observed document in full;
   *   2. give it a casRev (JSON Patch `add`: changes nothing else);
   *   3. read it again: it must equal the observed document plus exactly that casRev;
   *   4. compare-and-replace on that casRev.
   * Any other write between 3 and 4 changes or removes the casRev, so step 4 fails. Three extra calls, once per
   * old document.
   */
  async _casWithoutRev(collection, key, expected, replacement) {
    const { isDeepStrictEqual } = require('node:util');
    const norm = (d) => { const o = JSON.parse(JSON.stringify(d)); if (isPlainDoc(o)) delete o._id; return o; };
    const want = norm(expected);
    const before = await this.get(collection, key);
    if (!isPlainDoc(before) || before[REV_FIELD] !== undefined || !isDeepStrictEqual(norm(before), want)) return false;
    const rev = await this.seedRev(collection, key);
    if (!rev) return false;
    const seeded = await this.get(collection, key);
    if (!isPlainDoc(seeded) || !isDeepStrictEqual(norm(seeded), { ...want, [REV_FIELD]: rev })) return false;
    return this._casApply(collection, key, this._casPatch(collection, { ...expected, [REV_FIELD]: rev }, replacement));
  }

  /**
   * Gives a document written before round 6 its first casRev: a JSON Patch `add` of that one member. It changes
   * nothing else, so it can never lose an update; a compare-and-replace in flight simply fails once and re-reads.
   * Resolves to the new token, or null when the document is gone.
   */
  async seedRev(collection, key) {
    const rev = newRev();
    try {
      await this._request('PATCH', `/${encodeURIComponent(collection)}/${encodeURIComponent(key)}`,
        [{ op: 'add', path: `/${REV_FIELD}`, value: rev }],
        { retries: 0, contentType: 'application/json-patch+json' });
      return rev;
    } catch (e) {
      if (e instanceof SodaError && [400, 404, 409, 412, 422].includes(e.status)) return null;
      throw e;
    }
  }

  /** Returns the raw document under key or null. */
  async get(collection, key) {
    try {
      return await this._request('GET', `/${encodeURIComponent(collection)}/${encodeURIComponent(key)}`);
    } catch (err) {
      if (err instanceof SodaError && err.status === 404) return null;
      throw err;
    }
  }

  async remove(collection, key) {
    try {
      await this._request('DELETE', `/${encodeURIComponent(collection)}/${encodeURIComponent(key)}`, undefined, { retries: 0 });
      return true;
    } catch (err) {
      if (err instanceof SodaError && err.status === 404) return false;
      throw err;
    }
  }

  /**
   * Query-by-example. Returns [{key, value}].
   * @param {string} collection
   * @param {object} filter QBE filter (e.g. {groupId:'GRP-1', timestamp:{$gt: 123}})
   * @param {{orderBy?:Array<{path:string,datatype?:string,order?:'asc'|'desc'}>, limit?:number, offset?:number, fields?:'id'}} opts
   */
  async query(collection, filter, opts = {}) {
    const limit = Math.min(Math.max(opts.limit || 100, 1), 1000);
    const offset = Math.max(opts.offset || 0, 0);
    const qbe = opts.orderBy
      ? { $query: filter, $orderby: opts.orderBy.map((o) => ({ datatype: 'string', order: 'asc', ...o })) }
      : filter;
    // fields=id returns keys only (for counting without loading documents).
    const fields = opts.fields === 'id' ? '&fields=id' : '';
    const r = await this._request(
      'POST',
      `/${encodeURIComponent(collection)}?action=query&limit=${limit}&offset=${offset}${fields}`,
      qbe,
    );
    return (r?.items || []).map((it) => ({ key: it.id, value: it.value }));
  }

  /** Convenience: first match or null. */
  async findOne(collection, filter, opts = {}) {
    const rows = await this.query(collection, filter, { ...opts, limit: 1 });
    return rows[0] || null;
  }

  /** Upsert keyed by a unique business field (e.g. {groupId}). */
  async upsertBy(collection, filter, doc) {
    const existing = await this.findOne(collection, filter);
    if (existing) {
      await this.replace(collection, existing.key, doc);
      return existing.key;
    }
    return this.insert(collection, doc);
  }

  /** Deletes every document matching filter (batched with concurrency limit). Returns count. */
  async removeWhere(collection, filter, batch = 100) {
    let total = 0;
    const concurrency = 6;
    for (;;) {
      const rows = await this.query(collection, filter, { limit: batch });
      if (rows.length === 0) break;
      for (let i = 0; i < rows.length; i += concurrency) {
        const chunk = rows.slice(i, i + concurrency);
        await Promise.all(chunk.map((r) => this.remove(collection, r.key)));
      }
      total += rows.length;
      if (rows.length < batch) break;
    }
    return total;
  }
}

/**
 * Leased job body: gives every document of the CAS collections that has no casRev yet its first one, in small
 * batches (`max` documents per run; the next run continues). Runs on the raw client (stored documents as they are).
 */
async function seedMissingRevs(soda, { collections = CAS_COLLECTIONS, batch = 100, max = 2000, signal = null, logger = null } = {}) {
  let seeded = 0;
  for (const c of collections) {
    for (let guard = 0; guard < 1000 && seeded < max; guard++) {
      if (signal && signal.aborted) return seeded;
      let rows;
      try { rows = await soda.query(c, { [REV_FIELD]: { $exists: false } }, { limit: Math.min(batch, max - seeded), fields: 'id' }); } catch (e) {
        if (logger && logger.warn) logger.warn(`[cas-rev] ${c}: ${String(e.message).slice(0, 120)}`);
        break;
      }
      if (!rows.length) break;
      let ok = 0;
      for (const r of rows) { if (await soda.seedRev(c, r.key).catch(() => null)) ok++; }
      seeded += ok;
      if (!ok || rows.length < Math.min(batch, max - seeded + ok)) break;
    }
  }
  return seeded;
}

module.exports = { SodaClient, SodaError, REV_FIELD, CAS_COLLECTIONS, newRev, casTests, casTestsPass, seedMissingRevs };
