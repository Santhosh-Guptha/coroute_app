'use strict';
/**
 * In-memory implementation of the SodaClient surface.
 * Used by the test-suite and by `npm run dev` when ORACLE_SODA_URL=memory,
 * so the gateway can be exercised with no database at all.
 */
const { SodaClient } = require('./soda');

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
  }
  _coll(name) {
    if (!this.collections.has(name)) this.collections.set(name, new Map());
    return this.collections.get(name);
  }
  async ping() { return true; }
  async listCollections() { return [...this.collections.keys()]; }
  async ensureCollection(name) { this._coll(name); }
  async ensureIndex() { /* no-op */ }
  async insert(collection, doc) {
    const key = `K${++this.seq}`;
    this._coll(collection).set(key, structuredClone(doc));
    return key;
  }
  async replace(collection, key, doc) {
    if (!this._coll(collection).has(key)) throw Object.assign(new Error('not found'), { status: 404 });
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
}

module.exports = { MemorySoda, matches };
