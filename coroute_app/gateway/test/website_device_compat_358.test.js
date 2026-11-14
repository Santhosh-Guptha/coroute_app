'use strict';
/**
 * v3.58 website device compatibility guards (docs/quality/WEBSITE_DEVICE_COMPAT_v3.58.md).
 * Static checks that keep the fixes for older phones and narrow screens from regressing. The CSS fallbacks themselves
 * are written by tool/web_compat/css_compat.js; these tests fail when new CSS was added without running it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const PUB = path.join(__dirname, '..', 'public');
function walk(dir, re, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { if (!['fonts', 'screens', 'story'].includes(e.name)) walk(full, re, out); } else if (re.test(e.name)) out.push(full);
  }
  return out;
}
const rel = (f) => path.relative(PUB, f);
const cssFiles = walk(PUB, /\.css$/).filter((f) => !/leaflet\.css$/.test(f));
const htmlFiles = walk(PUB, /\.html$/);
function cssOf(f) {
  const s = fs.readFileSync(f, 'utf8');
  return f.endsWith('.html') ? [...s.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join('\n') : s;
}
// Declarations "prop: value" with the text before them in the same block, outside @supports blocks.
function decls(css) {
  const out = [];
  const noSupports = css.replace(/@supports[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, '');
  const re = /([{;]\s*(?:\/\*[^*]*\*\/\s*)?)([-a-z]+)\s*:\s*([^;{}]+)/g;
  let m;
  while ((m = re.exec(noSupports))) out.push({ prop: m[2], value: m[3].trim(), before: noSupports.slice(Math.max(0, m.index - 400), m.index + m[1].length) });
  return out;
}

test('every inset / clamp / svh declaration has the plain fallback before it (run tool/web_compat)', () => {
  const missing = [];
  for (const f of [...cssFiles, ...htmlFiles]) {
    for (const d of decls(cssOf(f))) {
      if (d.prop.startsWith('--') || /-(inline|block)/.test(d.prop)) continue; // logical props get physical sides
      if (d.prop === 'inset' && !/\btop\s*:[^;]*;\s*(\/\*\s*compat\s*\*\/\s*)?right\s*:[^;]*;\s*(\/\*\s*compat\s*\*\/\s*)?bottom\s*:[^;]*;\s*(\/\*\s*compat\s*\*\/\s*)?left\s*:[^;]*;\s*$/.test(d.before)) missing.push(`${rel(f)}: inset: ${d.value}`);
      if (/(^|[^a-z-])clamp\(/.test(d.value) || /\d(s|d|l)vh\b/.test(d.value)) {
        const esc = d.prop.replace(/[-]/g, '\\-');
        if (!new RegExp(`(^|[;{\\s/])${esc}\\s*:[^;]*;\\s*$`).test(d.before)) missing.push(`${rel(f)}: ${d.prop}: ${d.value.slice(0, 60)}`);
      }
    }
  }
  assert.deepEqual(missing.slice(0, 20), [], 'cd tool/web_compat && npm install && node css_compat.js');
});

test('backdrop-filter always has the -webkit- prefix (Safari < 18)', () => {
  for (const f of cssFiles) {
    const css = cssOf(f);
    const n = (css.match(/(^|[^-])backdrop-filter\s*:/g) || []).length;
    const w = (css.match(/-webkit-backdrop-filter\s*:/g) || []).length;
    assert.ok(w >= n, `${rel(f)}: ${n} backdrop-filter, ${w} prefixed`);
  }
});

test('focus rings: no bare ":focus { outline: none }" (Safari < 15.4 would show no ring at all)', () => {
  for (const f of cssFiles) {
    assert.ok(!/(^|[}\s]):focus\s*\{\s*outline\s*:\s*(none|0)/.test(cssOf(f)), `${rel(f)} hides focus for keyboard users`);
  }
});

test('site.js: matchMedia listeners work on Safari < 14 (addListener fallback) and the header fits narrow screens', () => {
  const js = fs.readFileSync(path.join(PUB, 'assets', 'site.js'), 'utf8');
  assert.ok(!/mq\([^)]*\)\.addEventListener\(/.test(js), 'use onMQ(), not MediaQueryList.addEventListener directly');
  assert.match(js, /addListener\(fn\)/);
  assert.match(js, /function fitHeader\(/);
  const css = fs.readFileSync(path.join(PUB, 'assets', 'site.css'), 'utf8');
  assert.match(css, /\.hdr-tight .site-header .theme-toggle-btn \{ display: none; \}/);
  assert.match(css, /\.hdr-tighter .site-header .site-header__cta \{ display: none; \}/);
  assert.match(css, /\.site-footer__nav \{ display: grid; grid-template-columns: repeat\(2, minmax\(0, 1fr\)\)/);
});

test('public scripts stay ES2019 (no optional chaining or ??: iOS 12-13.3 would drop the whole file)', () => {
  const files = [...walk(path.join(PUB, 'assets'), /\.js$/), path.join(PUB, '_watch-sw.js')];
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')
      .replace(/'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`/g, '""');
    assert.ok(!/\?\.[a-zA-Z_$[(]/.test(src), `${rel(f)}: optional chaining`);
    assert.ok(!/[^?]\?\?[^?]/.test(src.replace(/\/[^/\n]+\/[gimsuy]*/g, '')), `${rel(f)}: nullish coalescing`);
  }
});

test('flex gap fallback: theme-init.js marks browsers without flex gap', () => {
  const js = fs.readFileSync(path.join(PUB, 'assets', 'theme-init.js'), 'utf8');
  assert.match(js, /no-flexgap/);
  const site = fs.readFileSync(path.join(PUB, 'assets', 'site.css'), 'utf8');
  assert.match(site, /\.no-flexgap /);
});

test('pages that need JavaScript say so when it is off', () => {
  for (const p of ['account', 'signin', 'clubs', 'trip', 'receipt', 'checkout', 'updates', 'leaderboard', 'live', 'delete-account']) {
    assert.match(fs.readFileSync(path.join(PUB, `${p}.html`), 'utf8'), /<noscript><div class="noscript-note/, p);
  }
});
