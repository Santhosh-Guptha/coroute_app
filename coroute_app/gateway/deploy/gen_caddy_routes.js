#!/usr/bin/env node
'use strict';
/**
 * Generates the LIVE route matcher of deploy/caddy/Caddyfile.vm1 from deploy/route_split.md.
 *
 *   node deploy/gen_caddy_routes.js           rewrite the GENERATED block in Caddyfile.vm1 (and print it)
 *   node deploy/gen_caddy_routes.js --print   print the matcher only
 *   node deploy/gen_caddy_routes.js --check   every route defined in src/ must match a LIVE or WEB row (exit 1 if not)
 *   node deploy/gen_caddy_routes.js --list    every route defined in src/ with its class
 *
 * Row syntax (markdown table): | LIVE|WEB | METHODS (comma list or *) | /path/:param/* | source | why |
 * `:param` matches one path segment, a trailing `/*` the path itself and everything below it.
 * The Caddy matcher is case-insensitive and accepts a trailing slash (Express does both). GET implies HEAD.
 * Regexes use only [.] style classes: no backslashes or braces, so CEL and Caddy placeholders leave them alone.
 */
const fs = require('fs');
const path = require('path');

const DEPLOY = __dirname;
const SRC = path.join(DEPLOY, '..', 'src');
const SPLIT = path.join(DEPLOY, 'route_split.md');
const CADDY_VM1 = path.join(DEPLOY, 'caddy', 'Caddyfile.vm1');
const BEGIN = '# BEGIN GENERATED LIVE ROUTES';
const END = '# END GENERATED LIVE ROUTES';
const METHODS = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];

function parseRows(md = fs.readFileSync(SPLIT, 'utf8')) {
  const rows = [];
  for (const line of md.split('\n')) {
    const m = line.match(/^\|\s*(LIVE|WEB)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$/);
    if (!m) continue;
    const methods = m[2] === '*' ? ['*'] : m[2].split(',').map((s) => s.trim().toUpperCase());
    for (const x of methods) if (x !== '*' && !METHODS.includes(x)) throw new Error(`route_split.md: unknown method ${x} in: ${line}`);
    const p = m[3].replace(/`/g, '');
    if (!p.startsWith('/') || /[\s{}`\\]/.test(p)) throw new Error(`route_split.md: bad path ${p}`);
    rows.push({ cls: m[1], methods, path: p, source: m[4], why: m[5] });
  }
  if (!rows.some((r) => r.cls === 'LIVE')) throw new Error('route_split.md: no LIVE rows found');
  return rows;
}

/** Path pattern -> regex body (no anchors), backslash-free. */
function regexBody(p) {
  let tail = '';
  if (p.endsWith('/*')) { tail = '(?:/.*)?'; p = p.slice(0, -2); }
  const out = p.split('/').map((seg) => {
    if (seg.startsWith(':')) return '[^/]+';
    if (/[+?^$()|[\]]/.test(seg)) throw new Error(`route_split.md: unsupported character in path segment ${seg}`);
    return seg.replace(/\./g, '[.]').replace(/\*/g, '.*');
  }).join('/');
  return (out || '') + tail;
}

function methodKey(methods) {
  if (methods.includes('*')) return '*';
  const set = new Set(methods);
  if (set.has('GET')) set.add('HEAD');
  return [...set].sort((a, b) => METHODS.indexOf(a) - METHODS.indexOf(b)).join(',');
}

/** The Caddy named matcher for every LIVE row. */
function liveMatcher(rows) {
  const groups = new Map();
  for (const r of rows.filter((x) => x.cls === 'LIVE')) {
    const k = methodKey(r.methods);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(regexBody(r.path));
  }
  const parts = [];
  const keys = [...groups.keys()].sort((a, b) => (a === '*' ? -1 : b === '*' ? 1 : a.localeCompare(b)));
  for (const k of keys) {
    const re = `path_regexp('(?i)^(?:${groups.get(k).join('|')})/?$')`;
    parts.push(k === '*' ? re : `(method(${k.split(',').map((x) => `'${x}'`).join(', ')}) && ${re})`);
  }
  for (const p of parts) if (p.includes('`')) throw new Error('backtick in matcher');
  return [
    `${BEGIN} (deploy/gen_caddy_routes.js from deploy/route_split.md; do not edit by hand)`,
    `@live expression \`${parts.join(' || ')}\``,
    END,
  ];
}

function writeCaddy(rows) {
  const lines = liveMatcher(rows);
  const src = fs.readFileSync(CADDY_VM1, 'utf8');
  const a = src.indexOf(BEGIN);
  const b = src.indexOf(END);
  if (a < 0 || b < a) throw new Error(`${CADDY_VM1}: markers "${BEGIN}" / "${END}" not found`);
  const lineStart = src.lastIndexOf('\n', a) + 1;
  const indent = src.slice(lineStart, a);
  const next = src.slice(0, lineStart) + lines.map((l) => indent + l).join('\n') + src.slice(b + END.length);
  fs.writeFileSync(CADDY_VM1, next);
  return lines;
}

/** Routes defined in src/: [{ method, path, file, line }]. Literal paths only (the site page loop is WEB). */
function srcRoutes() {
  const prefixFor = (f) => (f === 'app.js' ? '' : f === 'guardian_routes.js' ? '/api/guardian' : '/api');
  const out = [];
  for (const f of fs.readdirSync(SRC).filter((x) => x.endsWith('.js'))) {
    const lines = fs.readFileSync(path.join(SRC, f), 'utf8').split('\n');
    lines.forEach((l, i) => {
      const m = l.match(/\b(?:r|app|router)\.(get|post|put|patch|delete|all)\(\s*(\[[^\]]*\]|'[^']*')/);
      if (!m) return;
      const paths = m[2].startsWith('[') ? [...m[2].matchAll(/'([^']*)'/g)].map((x) => x[1]) : [m[2].slice(1, -1)];
      for (const p of paths) out.push({ method: m[1].toUpperCase(), path: prefixFor(f) + p, file: f, line: i + 1 });
    });
  }
  out.push({ method: 'GET', path: '/ws', file: 'ws.js', line: 0 });
  return out;
}

function classify(rows, method, p) {
  const sample = p.replace(/:[A-Za-z_]+/g, 'x1');
  const hit = (r) => {
    if (r.path === '/*' && sample.startsWith('/api')) return false; // the website catch-all never covers the API
    const okMethod = r.methods.includes('*') || r.methods.includes(method) || (method === 'HEAD' && r.methods.includes('GET'));
    return okMethod && new RegExp(`^(?:${regexBody(r.path)})/?$`, 'i').test(sample);
  };
  const live = rows.find((r) => r.cls === 'LIVE' && hit(r));
  if (live) return { cls: 'LIVE', row: live };
  const web = rows.find((r) => r.cls === 'WEB' && hit(r));
  return web ? { cls: 'WEB', row: web } : { cls: null };
}

function main(argv) {
  const rows = parseRows();
  if (argv.includes('--check') || argv.includes('--list')) {
    let missing = 0;
    for (const r of srcRoutes()) {
      const c = classify(rows, r.method, r.path);
      if (!c.cls) missing++;
      if (argv.includes('--list') || !c.cls) console.log(`${(c.cls || 'UNCLASSIFIED').padEnd(12)} ${r.method.padEnd(6)} ${r.path}  (${r.file}:${r.line})`);
    }
    if (missing) {
      console.error(`\n${missing} route(s) are in neither list: add them to deploy/route_split.md (LIVE if they touch rooms, sockets or live links), then rerun without --check.`);
      process.exit(1);
    }
    if (argv.includes('--check')) console.log('route_split.md covers every route in src/.');
    return;
  }
  const lines = argv.includes('--print') ? liveMatcher(rows) : writeCaddy(rows);
  console.log(lines.join('\n'));
}

if (require.main === module) main(process.argv.slice(2));
module.exports = { parseRows, liveMatcher, regexBody, classify, srcRoutes };
