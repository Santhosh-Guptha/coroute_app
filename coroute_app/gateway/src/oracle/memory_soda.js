'use strict';
/**
 * In-memory implementation of the SodaClient surface.
 * Used by the test-suite and by `npm run dev` when ORACLE_SODA_URL=memory,
 * so the gateway can be exercised with no database at all.
 */
const { SodaClient } = require('./soda');
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
  async compareAndReplace(collection, key, expected, replacement) {
    if (!isDeepStrictEqual(this._coll(collection).get(key), expected)) return false;
    this._coll(collection).set(key, structuredClone(replacement)); return true;
  }
  async insert(collection, doc) {
    for (const fields of this.indexes.get(collection)?.values() || []) {
      if (fields.some(f => doc[f] === undefined || doc[f] === null)) continue;
      if ([...this._coll(collection).values()].some(other => fields.every(f => other[f] === doc[f]))) {
        throw Object.assign(new Error('unique constraint'), { status: 409 });
      }
    }
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
