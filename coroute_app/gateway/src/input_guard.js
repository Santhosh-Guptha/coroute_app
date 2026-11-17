'use strict';
/**
 * v3.62 security: request input hardening (defence in depth for the database query filters).
 *
 * The database speaks a Mongo-like query language: a filter value that is an object such as {"$ne": null} is an
 * operator, not a value. Most routes check the type of what they put into a filter, but one missed `String()` would let
 * a client widen a lookup ("operator injection"). And a JSON key "__proto__" / "constructor" / "prototype" merged into
 * an object can poison it ("prototype pollution").
 *
 *  - Query strings use the simple parser (app.set('query parser', 'simple')): `?email[$ne]=x` stays the literal key
 *    "email[$ne]"; a value is always a string (or an array of strings for a repeated key), never an object.
 *  - JSON bodies (HTTP) and socket messages go through `sanitize`: keys that start with "$" and the three prototype
 *    keys are removed at every depth. No client of ours sends such keys.
 *
 * Never throws; never touches raw webhook bodies (Buffers).
 */
const FORBIDDEN = new Set(['__proto__', 'constructor', 'prototype']);
const MAX_DEPTH = 32;

function sanitize(v, depth = 0) {
  if (v === null || typeof v !== 'object' || Buffer.isBuffer(v)) return v;
  if (depth > MAX_DEPTH) return Array.isArray(v) ? [] : {};
  if (Array.isArray(v)) {
    for (let i = 0; i < v.length; i++) v[i] = sanitize(v[i], depth + 1);
    return v;
  }
  for (const k of Object.keys(v)) {
    if (k.charCodeAt(0) === 36 /* $ */ || FORBIDDEN.has(k)) { delete v[k]; continue; }
    v[k] = sanitize(v[k], depth + 1);
  }
  return v;
}

/** Express middleware: cleans req.body (parsed JSON only). */
function bodyGuard() {
  return (req, res, next) => {
    if (req.body && typeof req.body === 'object' && !Buffer.isBuffer(req.body)) {
      try { sanitize(req.body); } catch { req.body = {}; }
    }
    next();
  };
}

module.exports = { sanitize, bodyGuard, FORBIDDEN };
