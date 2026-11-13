'use strict';
/**
 * Round 6 clean-up (c): deploy/.env.example is the documentation of every environment variable the gateway reads.
 * This test FAILS when a variable read anywhere in src/ is missing from it, when the template holds a real-looking
 * value (it must contain placeholders only), or when .gitignore would ignore the template again.
 * LIVE_RIDER_CAP (clean-up e): config only, default unset (0 = off), documented.
 */
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'src');
const EXAMPLE = path.join(ROOT, 'deploy', '.env.example');

/** Not configuration: set by the platform / test runner, or not an environment variable at all. */
const NOT_CONFIG = new Set(['NODE_ENV', 'NODE_TEST_CONTEXT', 'MSG', 'PATH', 'HOME', 'TZ']);

function jsFiles(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) out.push(...jsFiles(path.join(dir, e.name)));
    else if (e.name.endsWith('.js')) out.push(path.join(dir, e.name));
  }
  return out;
}

/** Every environment variable name read in src/ (direct reads, env objects passed around, and the small helpers). */
function envVarsRead() {
  const names = new Map();
  const add = (n, f) => { if (!NOT_CONFIG.has(n)) { if (!names.has(n)) names.set(n, path.relative(ROOT, f)); } };
  const patterns = [
    /process\.env\.([A-Z][A-Z0-9_]+)/g,
    /process\.env\[\s*['"]([A-Z][A-Z0-9_]+)['"]\s*\]/g,
    /\benv\.([A-Z][A-Z0-9_]{2,})\b/g,
    /\benv\[\s*['"]([A-Z][A-Z0-9_]+)['"]\s*\]/g,
    /\b(?:required|int|list|oneOf|envInt|num|bool|flt|str)\(\s*(?:env\s*,\s*)?['"]([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+|PORT|HOST)['"]/g,
    /\bsetting\(\s*'[A-Za-z]+'\s*,\s*'([A-Z][A-Z0-9_]+)'/g,
  ];
  for (const f of jsFiles(SRC)) {
    const text = fs.readFileSync(f, 'utf8');
    for (const re of patterns) for (const m of text.matchAll(re)) add(m[1], f);
  }
  return names;
}

function documented() {
  const set = new Set();
  for (const line of fs.readFileSync(EXAMPLE, 'utf8').split('\n')) {
    const m = line.match(/^\s*#?\s*(?:\[Vault\]\s*)?([A-Z][A-Z0-9_]+)=/);
    if (m) set.add(m[1]);
  }
  return set;
}

test('.env.example documents every environment variable read in src/', () => {
  const read = envVarsRead();
  assert.ok(read.size > 250, `found ${read.size} variables in src/`);
  const have = documented();
  const missing = [...read.entries()].filter(([n]) => !have.has(n)).map(([n, f]) => `${n} (${f})`).sort();
  assert.deepEqual(missing, [], 'add these to gateway/deploy/.env.example (commented, with a one-line explanation)');
});

test('.env.example holds placeholders only (no real addresses, OCIDs, e-mail addresses, keys or key paths)', () => {
  const text = fs.readFileSync(EXAMPLE, 'utf8');
  const bad = [];
  text.split('\n').forEach((line, i) => {
    const at = `line ${i + 1}: ${line.slice(0, 80)}`;
    if (/ocid1\.[a-z]+\.oc1\.[a-z0-9-]*\.[a-z0-9]{20,}/.test(line)) bad.push(`OCID ${at}`);
    for (const m of line.matchAll(/\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g)) {
      const [a, b] = [Number(m[1]), Number(m[2])];
      const reserved = a === 10 || a === 127 || a === 0 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31)
        || (a === 192 && b === 0) || (a === 198 && b === 51) || (a === 203 && b === 0) || a === 169 || a >= 224
        || ['1.1.1.1', '8.8.8.8', '1.2.3.4'].includes(m[0]);
      if (!reserved) bad.push(`public IPv4 ${at}`);
    }
    for (const m of line.matchAll(/[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[a-z]{2,})/g)) {
      if (!/(^|\.)example(\.[a-z]+)?$|\.example$|^your-|<|^coroute\.(example|test)$/.test(m[1]) && !/your|example|<|\$/.test(m[0])) bad.push(`e-mail ${at}`);
    }
    if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(line)) bad.push(`private key ${at}`);
    if (/(\/home\/[a-z][a-z0-9_-]*\/\.ssh|C:\\Users\\[A-Za-z]|~\/\.ssh\/[A-Za-z0-9_.-]+\.key)/.test(line)) bad.push(`key path ${at}`);
    // Secret-looking assignments: an uncommented SECRET / PASSWORD / TOKEN / KEY with a long literal that is not a placeholder.
    const kv = line.match(/^\s*#?\s*([A-Z][A-Z0-9_]*(?:SECRET|PASSWORD|TOKEN|_KEY|_PASS))=(\S+)/);
    if (kv && kv[2].length >= 16 && !/[<>$]|\.\.\.|your|example|change|random|xxxx/i.test(kv[2])) bad.push(`secret-looking value ${at}`);
  });
  assert.deepEqual(bad, []);
});

test('.gitignore keeps the template tracked and the filled copies ignored', () => {
  const gi = fs.readFileSync(path.join(ROOT, '..', '.gitignore'), 'utf8').split('\n').map((l) => l.trim());
  assert.ok(gi.includes('*.env*'), 'the catch-all secret rule stays');
  const idx = (s) => gi.indexOf(s);
  assert.ok(idx('!gateway/deploy/.env.example') > idx('*.env*'), '.env.example is un-ignored after the *.env* rule');
  assert.ok(gi.includes('gateway/.env'), 'the real env file stays ignored');
  assert.ok(gi.some((l) => /inventory\.local\.env$/.test(l)), 'the filled inventory stays ignored');
});

test('LIVE_RIDER_CAP is config only: unset = off, read as an integer, documented (commented) in .env.example', () => {
  const load = (v) => {
    const prev = process.env.LIVE_RIDER_CAP;
    if (v === undefined) delete process.env.LIVE_RIDER_CAP; else process.env.LIVE_RIDER_CAP = v;
    delete require.cache[require.resolve('../src/config')];
    try { return require('../src/config').liveRiderCap; } finally {
      if (prev === undefined) delete process.env.LIVE_RIDER_CAP; else process.env.LIVE_RIDER_CAP = prev;
      delete require.cache[require.resolve('../src/config')];
    }
  };
  assert.equal(load(undefined), 0, 'default: no cap');
  assert.equal(load('2500'), 2500);
  assert.throws(() => load('many'), /LIVE_RIDER_CAP must be an integer/);
  const line = fs.readFileSync(EXAMPLE, 'utf8').split('\n').find((l) => /LIVE_RIDER_CAP=/.test(l));
  assert.ok(line && /^\s*#/.test(line), 'documented as a commented suggestion (default unset)');
  assert.match(fs.readFileSync(EXAMPLE, 'utf8'), /LIVE_RIDER_CAP[\s\S]{0,400}2500/, 'the owner-facing suggestion for a micro VM is written down');
});
