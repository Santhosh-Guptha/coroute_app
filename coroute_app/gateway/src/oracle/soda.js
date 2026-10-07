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

class SodaClient {
  /**
   * @param {{baseUrl:string,user:string,password:string,timeoutMs?:number,fetchImpl?:Function}} opts
   */
  constructor(opts) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, '');
    this.authHeader = 'Basic ' + Buffer.from(`${opts.user}:${opts.password}`).toString('base64');
    this.timeoutMs = opts.timeoutMs || 6000;
    this.fetch = opts.fetchImpl || globalThis.fetch;
  }

  async _request(method, path, body, { retries = 1 } = {}) {
    const url = `${this.baseUrl}${path}`;
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        const res = await this.fetch(url, {
          method,
          headers: {
            Authorization: this.authHeader,
            Accept: 'application/json',
            ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        const text = await res.text();
        let json = null;
        if (text) {
          try { json = JSON.parse(text); } catch { json = { raw: text }; }
        }
        if (res.status >= 500 && attempt < retries) {
          lastErr = new SodaError(`SODA ${method} ${path} -> ${res.status}`, res.status, json);
          continue;
        }
        if (!res.ok) throw new SodaError(`SODA ${method} ${path} -> ${res.status}`, res.status, json);
        return json;
      } catch (err) {
        lastErr = err;
        const transient = err.name === 'TimeoutError' || err.name === 'AbortError' || err.code === 'ECONNRESET' || err.code === 'UND_ERR_SOCKET';
        if (!transient || attempt >= retries) throw err;
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
    const r = await this._request('POST', `/${encodeURIComponent(collection)}`, doc, { retries: 0 });
    const item = r?.items?.[0];
    if (!item?.id) throw new SodaError('SODA insert returned no key', 500, r);
    return item.id;
  }

  /** Replaces the document stored under key. */
  async replace(collection, key, doc) {
    await this._request('PUT', `/${encodeURIComponent(collection)}/${encodeURIComponent(key)}`, doc, { retries: 0 });
    return key;
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

  /** Deletes every document matching filter (batched). Returns count. */
  async removeWhere(collection, filter, batch = 200) {
    let total = 0;
    for (;;) {
      const rows = await this.query(collection, filter, { limit: batch });
      if (rows.length === 0) break;
      await Promise.all(rows.map((r) => this.remove(collection, r.key)));
      total += rows.length;
      if (rows.length < batch) break;
    }
    return total;
  }
}

module.exports = { SodaClient, SodaError };
