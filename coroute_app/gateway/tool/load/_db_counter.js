'use strict';
/**
 * Counts SODA calls per method and collection (load tests: find the hottest DB calls).
 * countingSoda(soda) -> { soda (a Proxy with the same API), top(n), total(), reset() }.
 */
const COUNTED = new Set(['ping', 'listCollections', 'ensureCollection', 'ensureIndex', 'compareAndReplace', 'insert', 'insertMany',
  'replace', 'get', 'remove', 'query', 'findOne', 'upsertBy', 'removeWhere']);

function countingSoda(inner) {
  let counts = new Map();
  const soda = new Proxy(inner, {
    get(target, prop, recv) {
      const v = Reflect.get(target, prop, recv);
      if (typeof v !== 'function' || !COUNTED.has(prop)) return v;
      return function counted(...args) {
        const k = `${prop} ${typeof args[0] === 'string' ? args[0] : ''}`.trim();
        counts.set(k, (counts.get(k) || 0) + 1);
        return v.apply(target, args);
      };
    },
  });
  return {
    soda,
    reset() { counts = new Map(); },
    total() { let n = 0; for (const c of counts.values()) n += c; return n; },
    top(n = 10) { return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, c]) => ({ call: k, count: c })); },
  };
}

module.exports = { countingSoda };
