'use strict';
/**
 * In-memory implementation of the SodaClient surface.
 * Used by the test-suite and by `npm run dev` when ORACLE_SODA_URL=memory,
 * so the gateway can be exercised with no database at all.
 */
const { SodaClient, REV_FIELD, newRev, casTestsPass } = require('./soda');
const { isDeepStrictEqual } = require('node:util');

function matches(doc, filter) {
  for (const [path, cond] of Object.entries(filter)) {
    const val = path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), doc);
    if (cond !== null && typeof cond === 'object' && !Array.isArray(cond)) {
      for (const [op, arg] of Object.entries(cond)) {
        switch (op) {
          case '$in': if (!arg.includes(val)) return false; break;
          case '$gt': if (!(val > arg)) return false; break;
          case '$gte': if (!(val >= arg)) return false; break;
          case '$lt': if (!(val < arg)) return false; break;
          case '$lte': if (!(val <= arg)) return false; break;
          case '$ne': if (val === arg) return false; break;
          case '$exists': if ((val !== undefined) !== !!arg) return false; break;
          default: throw new Error(`memory_soda: unsupported operator ${op}`);
        }
      }
    } else if (val !== cond) {
      return false;
    }
  }
  return true;
}

class MemorySoda extends SodaClient {
  constructor() {
    super({ baseUrl: 'http://memory', user: 'x', password: 'x' });
    this.collections = new Map();
    this.seq = 0;
    this.indexes = new Map();
  }
  _coll(name) {
    if (!this.collections.has(name)) this.collections.set(name, new Map());
    return this.collections.get(name);
  }
  async ping() { return true; }
  async listCollections() { return [...this.collections.keys()]; }
  async ensureCollection(name) { this._coll(name); }
  async ensureIndex(collection, spec) {
    if (!spec.unique) return;
    const indexes = this.indexes.get(collection) || new Map();
    indexes.set(spec.name, spec.fields.map(f => f.path)); this.indexes.set(collection, indexes);
  }
  /**
   * The same precondition the database applies (round 6): the JSON Patch built by SodaClient._casPatch, i.e. a test
   * of every top-level scalar of the observed document (casRev among them), NOT a deep comparison. A race that the
   * real patch would miss is therefore missed here too, and a test can show it. compareAndReplace itself (and its
   * path for documents without a casRev) is SodaClient's.
   */
  async _casApply(collection, key, patch) {
    const stored = this._coll(collection).get(key);
    if (!casTestsPass(stored, patch.filter((op) => op.op === 'test'))) return false;
    this._coll(collection).set(key, structuredClone(patch[patch.length - 1].value)); return true;
  }
  async seedRev(collection, key) {
    const stored = this._coll(collection).get(key);
    if (!stored) return null;
    stored[REV_FIELD] = newRev();
    return stored[REV_FIELD];
  }
  async insert(collection, doc) {
    for (const fields of this.indexes.get(collection)?.values() || []) {
      if (fields.some(f => doc[f] === undefined || doc[f] === null)) continue;
      if ([...this._coll(collection).values()].some(other => fields.every(f => other[f] === doc[f]))) {
        throw Object.assign(new Error('unique constraint'), { status: 409 });
      }
    }
    const key = `K${++this.seq}`;
    this._stampNew(collection, doc);
    this._coll(collection).set(key, structuredClone(doc));
    return key;
  }
  /** All or nothing, like one SODA bulk insert in a single transaction. */
  async insertMany(collection, docs) {
    if (!Array.isArray(docs) || docs.length === 0) return [];
    const fieldsList = [...(this.indexes.get(collection)?.values() || [])];
    const existing = [...this._coll(collection).values()];
    for (let i = 0; i < docs.length; i++) {
      const doc = docs[i];
      for (const fields of fieldsList) {
        if (fields.some(f => doc[f] === undefined || doc[f] === null)) continue;
        const clash = (other) => fields.every(f => other[f] === doc[f]);
        if (existing.some(clash) || docs.slice(0, i).some(clash)) throw Object.assign(new Error('unique constraint'), { status: 409 });
      }
    }
    const keys = [];
    for (const doc of docs) {
      const key = `K${++this.seq}`;
      this._stampNew(collection, doc);
      this._coll(collection).set(key, structuredClone(doc));
      keys.push(key);
    }
    return keys;
  }
  async *scan(collection, { pageSize = 500 } = {}) {
    const all = [...this._coll(collection).entries()];
    for (let i = 0; i < all.length; i += pageSize) {
      yield all.slice(i, i + pageSize).map(([key, value]) => ({ key, value: structuredClone(value) }));
    }
  }
  async replace(collection, key, doc) {
    if (!this._coll(collection).has(key)) throw Object.assign(new Error('not found'), { status: 404 });
    this._stamp(collection, doc);
    this._coll(collection).set(key, structuredClone(doc));
    return key;
  }
  async get(collection, key) {
    const d = this._coll(collection).get(key);
    return d ? structuredClone(d) : null;
  }
  async remove(collection, key) { return this._coll(collection).delete(key); }
  async query(collection, filter, opts = {}) {
    const limit = opts.limit || 100;
    const offset = opts.offset || 0;
    let rows = [...this._coll(collection).entries()]
      .filter(([, v]) => matches(v, filter))
      .map(([key, value]) => ({ key, value: structuredClone(value) }));
    if (opts.orderBy) {
      rows.sort((a, b) => {
        for (const o of opts.orderBy) {
          const av = a.value[o.path]; const bv = b.value[o.path];
          if (av === bv) continue;
          const cmp = av > bv ? 1 : -1;
          return o.order === 'desc' ? -cmp : cmp;
        }
        return 0;
      });
    }
    return rows.slice(offset, offset + limit);
  }
  async findOne(collection, filter, opts = {}) {
    const rows = await this.query(collection, filter, { ...opts, limit: 1 });
    return rows[0] || null;
  }
  async upsertBy(collection, filter, doc) {
    const existing = await this.findOne(collection, filter);
    if (existing) {
      await this.replace(collection, existing.key, doc);
      return existing.key;
    }
    return this.insert(collection, doc);
  }
  async removeWhere(collection, filter, batch = 200) {
    let total = 0;
    for (;;) {
      const rows = await this.query(collection, filter, { limit: batch });
      if (rows.length === 0) break;
      for (const r of rows) this.remove(collection, r.key);
      total += rows.length;
      if (rows.length < batch) break;
    }
    return total;
  }
}

module.exports = { MemorySoda, matches };
