'use strict';
/**
 * v3.62 own database for the road & safety intelligence (docs/intelligence/INTEL_DATABASE.md).
 *
 * INTEL_SODA_URL (+ INTEL_ORACLE_USER / INTEL_ORACLE_PASSWORD, same style as ORACLE_SODA_URL / ORACLE_USER /
 * ORACLE_PASSWORD) points the intelligence collections (INTEL_COLLECTIONS) at a second SODA store. Not set: nothing
 * here runs and every collection stays in the main database exactly as before.
 *
 * Set: `routedSoda(main, intel)` is put under the field-encryption layer, so every module (intel engine, consent,
 * business brain, road risk, account erase and export cascades, backups) keeps calling one `soda` and the call for an
 * intelligence collection goes to the right store. Which store answers depends on the switch state, a document in
 * the MAIN database (`intel_db_state`, k = 'state'), read at most every STATE_TTL_MS by each node:
 *
 *   main    (default, also before any migration) reads and writes go to the main database (no data is split).
 *   dual    the copy is running: reads from main; every write is applied to main AND mirrored to the intel store
 *           (a mirrored document carries `_mk` = its main key), so nothing written while copying is lost.
 *   intel   the copy is done: reads and writes go to the intel store. A key from the main store (read just before the
 *           switch) is translated through `_mk`. `_mk` is never returned to callers.
 *
 * Migration (INTEL_DB_MIGRATE=1, job lease 'intel-db-migrate', one node, every minute, resumable):
 *   1. state main -> dual, then wait 2 x STATE_TTL_MS so both nodes mirror writes;
 *   2. copy every intelligence collection in batches (INTEL_DB_MIGRATE_BATCH documents per run), skipping documents
 *      already in the intel store (`_mk`); passes repeat until one full pass copies nothing;
 *   3. state dual -> intel. The main copies stay (the owner removes them later; nothing is deleted here).
 */

const STATE_COLL = 'intel_db_state';
const STATE_TTL_MS = 30000;
const TRANSLATE_MS = 10 * 60000;
const DEFAULT_COLLECTIONS = Object.freeze(['intel_raw', 'intel_cells', 'intel_meta', 'intel_crash_train', 'intel_consent', 'intel_insights',
  'business_agg', 'business_riders', 'business_obs', 'road_risk']);
const MODES = new Set(['main', 'dual', 'intel']);
const READS = new Set(['get', 'query', 'findOne', 'scan']);
const BOTH = new Set(['ensureCollection', 'ensureIndex']);

function intelCollections(env = process.env) {
  const raw = String(env.INTEL_DB_COLLECTIONS || '').split(',').map((s) => s.trim()).filter((s) => /^[a-z][a-z0-9_]{1,62}$/.test(s));
  return new Set(raw.length ? raw : DEFAULT_COLLECTIONS);
}

const strip = (row) => {
  if (!row || !row.value || row.value._mk === undefined) return row;
  const { _mk, ...rest } = row.value; void _mk;
  return { ...row, value: rest };
};
const stripDoc = (d) => { if (!d || d._mk === undefined) return d; const { _mk, ...rest } = d; void _mk; return rest; };

/** Reads and caches the switch state from the main store. */
class IntelDbState {
  constructor({ main, clock = Date.now, ttlMs = STATE_TTL_MS, logger = console }) {
    Object.assign(this, { main, clock, ttlMs, log: logger });
    this.value = { mode: 'main' };
    this.at = 0;
    this.loading = null;
  }

  /** Synchronous: the last known mode (refreshes in the background when stale). */
  mode() {
    if (this.clock() - this.at > this.ttlMs && !this.loading) this.refresh().catch(() => {});
    return this.value.mode;
  }

  async refresh() {
    if (this.loading) return this.loading;
    this.loading = (async () => {
      try {
        const r = await this.main.findOne(STATE_COLL, { k: 'state' });
        const v = r && r.value ? r.value : { mode: 'main' };
        this.value = { ...v, mode: MODES.has(v.mode) ? v.mode : 'main' };
        this.at = this.clock();
      } catch (e) { this.log.warn?.(`[intel-db] state read failed: ${e.message}`); }
      return this.value;
    })().finally(() => { this.loading = null; });
    return this.loading;
  }

  async set(patch) {
    const next = { ...this.value, ...patch, k: 'state', updatedAt: this.clock() };
    await this.main.ensureCollection(STATE_COLL).catch(() => {});
    await this.main.upsertBy(STATE_COLL, { k: 'state' }, next);
    this.value = { ...next, mode: MODES.has(next.mode) ? next.mode : 'main' };
    this.at = this.clock();
    return this.value;
  }
}

/**
 * A soda that sends intelligence collections to `intel` according to `state.mode()`. Everything else, and every
 * collection when the mode is 'main', goes to `main` unchanged.
 */
function routedSoda(main, intel, { state, collections = intelCollections(), logger = console, stats = { mirrored: 0, mirrorErrors: 0, translated: 0 } } = {}) {
  const isIntel = (c) => typeof c === 'string' && collections.has(c);
  const mirrorErr = (op, c, e) => { stats.mirrorErrors++; logger.warn?.(`[intel-db] mirror ${op} ${c} failed: ${e && e.message}`); };

  async function intelKeyOf(c, key) {
    const r = await intel.findOne(c, { _mk: key });
    if (r) stats.translated++;
    return r ? r.key : null;
  }
  async function mirrorReplace(c, mainKey, doc) {
    const ik = await intelKeyOf(c, mainKey);
    if (ik) await intel.replace(c, ik, { ...stripDoc(doc), _mk: mainKey });
    else await intel.insert(c, { ...stripDoc(doc), _mk: mainKey });
    stats.mirrored++;
  }
  /** In intel mode: the intel key for `key` (itself, or a main key translated through _mk). */
  async function resolve(c, key) {
    // Main keys can only still be held by callers shortly after the switch (a read just before it): translate for
    // 10 minutes after doneAt, through `_mk` first (a native intel key could look the same as a main key).
    const doneAt = Number(state.value && state.value.doneAt) || 0;
    if (doneAt && state.clock() - doneAt > TRANSLATE_MS) return key;
    return (await intelKeyOf(c, key)) || key;
  }

  const dual = {
    async insert(c, doc) {
      const k = await main.insert(c, doc);
      await intel.insert(c, { ...stripDoc(doc), _mk: k }).then(() => { stats.mirrored++; }, (e) => mirrorErr('insert', c, e));
      return k;
    },
    async insertMany(c, docs) {
      const keys = await main.insertMany(c, docs);
      if (Array.isArray(keys) && keys.length) {
        await intel.insertMany(c, docs.map((d, i) => ({ ...stripDoc(d), _mk: keys[i] }))).then(() => { stats.mirrored += keys.length; }, (e) => mirrorErr('insertMany', c, e));
      }
      return keys;
    },
    async replace(c, key, doc) {
      const out = await main.replace(c, key, doc);
      await mirrorReplace(c, key, doc).catch((e) => mirrorErr('replace', c, e));
      return out;
    },
    async compareAndReplace(c, key, expected, replacement) {
      const ok = await main.compareAndReplace(c, key, expected, replacement);
      if (ok) await mirrorReplace(c, key, replacement).catch((e) => mirrorErr('cas', c, e));
      return ok;
    },
    async upsertBy(c, filter, doc) {
      const k = await main.upsertBy(c, filter, doc);
      await mirrorReplace(c, k, doc).catch((e) => mirrorErr('upsert', c, e));
      return k;
    },
    async remove(c, key) {
      const out = await main.remove(c, key);
      await intel.removeWhere(c, { _mk: key }).catch((e) => mirrorErr('remove', c, e));
      return out;
    },
    async removeWhere(c, filter, batch) {
      const n = await main.removeWhere(c, filter, batch);
      await intel.removeWhere(c, filter, batch).catch((e) => mirrorErr('removeWhere', c, e));
      return n;
    },
    async seedRev(c, key) { return main.seedRev(c, key); },
  };

  const intelMode = {
    async get(c, key) { return stripDoc(await intel.get(c, await resolve(c, key))); },
    async query(c, f, o) { return (await intel.query(c, f, o)).map(strip); },
    async findOne(c, f, o) { return strip(await intel.findOne(c, f, o)); },
    async *scan(c, o) { for await (const page of intel.scan(c, o)) yield page.map(strip); },
    // A translated document keeps its `_mk` (the main key may still be used once more within the window).
    async replace(c, key, doc) { const k = await resolve(c, key); return intel.replace(c, k, k !== key ? { ...stripDoc(doc), _mk: key } : stripDoc(doc)); },
    async compareAndReplace(c, key, expected, replacement) { const k = await resolve(c, key); return intel.compareAndReplace(c, k, expected, k !== key ? { ...stripDoc(replacement), _mk: key } : stripDoc(replacement)); },
    async remove(c, key) { return intel.remove(c, await resolve(c, key)); },
    async seedRev(c, key) { return intel.seedRev(c, await resolve(c, key)); },
  };

  return new Proxy(main, {
    get(target, prop, recv) {
      const v = Reflect.get(target, prop, recv);
      if (prop === '__intelRouted') return true;
      if (prop === 'intelStore') return intel;
      if (prop === 'intelState') return state;
      if (prop === 'intelStats') return stats;
      if (prop === 'hasRev') return (c) => (isIntel(c) && typeof intel.hasRev === 'function' ? intel.hasRev(c) : typeof target.hasRev === 'function' ? target.hasRev(c) : false);
      if (typeof v !== 'function') return v;
      return function routed(c, ...rest) {
        if (!isIntel(c)) return v.call(target, c, ...rest);
        if (BOTH.has(prop)) {
          const a = v.call(target, c, ...rest);
          const b = typeof intel[prop] === 'function' ? intel[prop](c, ...rest) : null;
          return Promise.all([a, b]).then((x) => x[0]);
        }
        const mode = state.mode();
        if (mode === 'intel') {
          if (intelMode[prop]) return intelMode[prop](c, ...rest);
          return typeof intel[prop] === 'function' ? intel[prop](c, ...rest) : v.call(target, c, ...rest);
        }
        if (mode === 'dual' && !READS.has(prop) && dual[prop]) return dual[prop](c, ...rest);
        return v.call(target, c, ...rest);
      };
    },
  });
}

/** The one-shot, resumable copy from the main store to the intel store (job lease 'intel-db-migrate'). */
class IntelDbMigration {
  constructor({ main, intel, state, collections = intelCollections(), logger = console, clock = Date.now, batch = 500, settleMs = 2 * STATE_TTL_MS + 5000 }) {
    Object.assign(this, { main, intel, state, collections: [...collections], log: logger, clock, batch, settleMs });
  }

  async ensureIntelIndexes() {
    for (const c of this.collections) {
      await this.intel.ensureCollection(c).catch(() => {});
      await this.intel.ensureIndex(c, { name: `${c}_mk_ix`, fields: [{ path: '_mk' }] }).catch(() => {});
    }
  }

  /** One run. Returns { mode, copied, done }. */
  async step({ signal } = {}) {
    const s = await this.state.refresh();
    if (s.mode === 'intel') return { mode: 'intel', copied: 0, done: true };
    if (s.mode === 'main') {
      await this.ensureIntelIndexes();
      await this.state.set({ mode: 'dual', dualSince: this.clock(), progress: { i: 0, offset: 0, passCopied: 0, pass: 1 }, copiedTotal: 0 });
      this.log.info?.('[intel-db] mirroring writes to the intelligence database; the copy starts after both nodes switch');
      return { mode: 'dual', copied: 0, done: false };
    }
    if (this.clock() - (Number(s.dualSince) || 0) < this.settleMs) return { mode: 'dual', copied: 0, done: false, waiting: true };
    const p = { i: 0, offset: 0, passCopied: 0, pass: 1, ...(s.progress || {}) };
    let budget = this.batch, copied = 0;
    while (budget > 0 && !signal?.aborted) {
      if (p.i >= this.collections.length) {
        if (p.passCopied === 0) {
          await this.state.set({ mode: 'intel', doneAt: this.clock(), progress: p, copiedTotal: (s.copiedTotal || 0) + copied });
          this.log.info?.(`[intel-db] copy complete after ${p.pass} pass(es): reads and writes now use the intelligence database`);
          return { mode: 'intel', copied, done: true };
        }
        Object.assign(p, { i: 0, offset: 0, passCopied: 0, pass: p.pass + 1 });
        if (p.pass > 20) break; // never loop forever; the next run continues
        continue;
      }
      const c = this.collections[p.i];
      const page = Math.min(budget, 200);
      const rows = await this.main.query(c, {}, { limit: page, offset: p.offset }).catch(() => []);
      for (const r of rows) {
        const have = await this.intel.findOne(c, { _mk: r.key }).catch(() => null);
        if (have) continue;
        try { await this.intel.insert(c, { ...stripDoc(r.value), _mk: r.key }); copied++; p.passCopied++; } catch (e) {
          if (!(e && e.status === 409)) this.log.warn?.(`[intel-db] copy ${c} failed: ${e.message}`);
        }
      }
      budget -= Math.max(1, rows.length);
      if (rows.length < page) { p.i++; p.offset = 0; } else p.offset += rows.length;
    }
    await this.state.set({ progress: p, copiedTotal: (s.copiedTotal || 0) + copied });
    return { mode: 'dual', copied, done: false };
  }
}

/** Health of both stores for /api/health and the admin page. `intelDb`: { state, intel, routed } or null. */
async function intelDbHealth(intelDb) {
  if (!intelDb) return { separate: false, mode: 'main' };
  let intelUp = false;
  try { intelUp = !!(await intelDb.intel.ping()); } catch { intelUp = false; }
  const v = intelDb.state.value || {};
  return { separate: true, mode: intelDb.state.mode(), intelDb: intelUp ? 'UP' : 'DOWN', progress: v.progress || null, copiedTotal: v.copiedTotal || 0,
    dualSince: v.dualSince || 0, doneAt: v.doneAt || 0, mirrorErrors: intelDb.routed ? intelDb.routed.intelStats.mirrorErrors : 0,
    collections: intelDb.collections ? [...intelDb.collections] : [] };
}

module.exports = { routedSoda, IntelDbState, IntelDbMigration, intelDbHealth, intelCollections, DEFAULT_COLLECTIONS, STATE_COLL, STATE_TTL_MS };
