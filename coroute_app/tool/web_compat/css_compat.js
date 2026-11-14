#!/usr/bin/env node
'use strict';
/**
 * Website CSS fallbacks for older phone browsers (v3.58, docs/quality/WEBSITE_DEVICE_COMPAT_v3.58.md).
 *
 * The site is written for current browsers. Old engines (iOS Safari 12-15, Chrome < 90 in old Android WebViews,
 * Samsung Internet < 15, Firefox < 90) drop a whole declaration or rule they do not understand, which can collapse a
 * layout. This tool adds fallbacks IN PLACE, next to the original, and is safe to run again (it first removes what it
 * added before):
 *
 *  - clamp() / min() / max()      -> a plain value before the declaration (first bound; the fluid arg for min())
 *  - svh / dvh / lvh, cqi / cqw   -> vh / vw before the declaration
 *  - color-mix()                  -> the first colour before the declaration
 *  - inset, inset-inline/-block   -> top / right / bottom / left before it
 *  - margin/padding-inline/-block -> physical sides before it
 *  - backdrop-filter              -> -webkit-backdrop-filter added (Safari < 18)
 *  - custom properties using any of the above -> an @supports not (...) block with the plain value
 *  - selector lists mixing :has() / :focus-visible / :is() / :where() / :not(a, b) with plain selectors -> split, so
 *    an old browser drops only the selector it does not know, not the whole rule
 *  - flex `gap` -> `.no-flexgap` margin rules (theme-init.js adds the class when flex gap is unsupported: Safari < 14.1)
 *
 * Run:   cd tool/web_compat && npm install && node css_compat.js          (rewrites gateway/public CSS + inline styles)
 *        node css_compat.js --check                                          (exit 1 if a file would change)
 */
const fs = require('fs');
const path = require('path');
const postcss = require('postcss');

const PUB = path.join(__dirname, '..', '..', 'gateway', 'public');
const CHECK = process.argv.includes('--check');
const MARK = 'compat';
const GEN = 'compat:generated';

// ---------- value helpers ----------
function splitArgs(s) { // top-level comma split
  const out = []; let depth = 0, cur = '';
  for (const ch of s) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; } else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}
function findCall(v, name, from = 0) { // returns {start, open, end} of name( ... ) at word boundary
  const re = new RegExp(`(^|[^a-zA-Z0-9_-])(${name})\\(`, 'g');
  re.lastIndex = from;
  const m = re.exec(v);
  if (!m) return null;
  const start = m.index + m[1].length, open = start + name.length;
  let depth = 0;
  for (let i = open; i < v.length; i++) {
    if (v[i] === '(') depth++;
    else if (v[i] === ')') { depth--; if (depth === 0) return { start, open, end: i }; }
  }
  return null;
}
const isMath = (a) => /\s[-+*/]\s/.test(a);
const wrap = (a) => (isMath(a) && !/^calc\(/.test(a) ? `calc(${a})` : a);
const fluid = (a) => /%|vw|vh|vmin|vmax/.test(a);

function pick(name, args) {
  if (name === 'clamp') return args[0];
  if (name === 'min') return args.find(fluid) || args[0];
  if (name === 'max') return args.find((a) => !fluid(a)) || args[0];
  if (name === 'color-mix') { // color-mix(in srgb, A 50%, B) -> A
    const first = args[1] || '';
    return first.replace(/\s+\d+(\.\d+)?%$/, '').trim();
  }
  return args[0];
}
function replaceCalls(v, names) {
  let changed = true, guard = 0;
  while (changed && guard++ < 50) {
    changed = false;
    for (const name of names) {
      const c = findCall(v, name);
      if (!c) continue;
      const inner = v.slice(c.open + 1, c.end);
      const args = splitArgs(inner).map((a) => replaceCalls(a, names));
      const chosen = pick(name, args);
      // inside calc() an expression needs no extra calc wrapper
      const before = v.slice(0, c.start);
      const insideCalc = /calc\([^)]*$/.test(before);
      v = before + (insideCalc ? `(${chosen})` : wrap(chosen)) + v.slice(c.end + 1);
      changed = true;
    }
  }
  return v;
}
const MATH = ['clamp', 'min', 'max'];
function needs(v) {
  return {
    math: MATH.some((n) => findCall(v, n)),
    vunits: /\d(s|d|l)v(h|w|min|max)\b/.test(v),
    cq: /\dcq(i|w|h|b)\b/.test(v),
    mix: !!findCall(v, 'color-mix'),
  };
}
function fallbackValue(v) {
  let out = v;
  out = out.replace(/(\d)(s|d|l)v(h|w|min|max)\b/g, '$1v$3');
  out = out.replace(/(\d)cq(i|w)\b/g, '$1vw').replace(/(\d)cq(h|b)\b/g, '$1vh');
  out = replaceCalls(out, ['color-mix']);
  out = replaceCalls(out, MATH);
  return out === v ? null : out;
}

// ---------- logical properties ----------
function logical(prop, value) {
  const parts = postcss.list.space(value);
  const two = (a, b) => [a, b === undefined ? a : b];
  const m = /^(margin|padding)-(inline|block)(-start|-end)?$/.exec(prop);
  if (m) {
    const [base, axis, side] = [m[1], m[2], m[3]];
    const sides = axis === 'inline' ? ['left', 'right'] : ['top', 'bottom'];
    if (side) return [[`${base}-${side === '-start' ? sides[0] : sides[1]}`, value]];
    const [a, b] = two(parts[0], parts[1]);
    return [[`${base}-${sides[0]}`, a], [`${base}-${sides[1]}`, b]];
  }
  if (prop === 'inset') {
    const [t, r = t, b = t, l = r] = parts;
    return [['top', t], ['right', r], ['bottom', b], ['left', l]];
  }
  const i = /^inset-(inline|block)(-start|-end)?$/.exec(prop);
  if (i) {
    const sides = i[1] === 'inline' ? ['left', 'right'] : ['top', 'bottom'];
    if (i[2]) return [[i[2] === '-start' ? sides[0] : sides[1], value]];
    const [a, b] = two(parts[0], parts[1]);
    return [[sides[0], a], [sides[1], b]];
  }
  return null;
}

// ---------- selectors ----------
const RISKY_SEL = /:has\(|:focus-visible|:is\(|:where\(|::backdrop|:not\([^)]*,/;

function insideSupports(node) {
  for (let p = node.parent; p; p = p.parent) if (p.type === 'atrule' && /^supports$/i.test(p.name)) return true;
  return false;
}
function insideKeyframes(node) {
  for (let p = node.parent; p; p = p.parent) if (p.type === 'atrule' && /keyframes$/i.test(p.name)) return true;
  return false;
}

const plugin = () => ({
  postcssPlugin: 'coroute-compat',
  Once(root) {
    // 1. remove what an earlier run added
    root.walkComments((c) => {
      if (c.text === MARK) { const n = c.next(); if (n && n.type === 'decl') n.remove(); c.remove(); }
    });
    root.walk((n) => {
      if ((n.type === 'rule' || n.type === 'atrule') && n.first && n.first.type === 'comment' && n.first.text === GEN) n.remove();
    });

    // 2. split risky selector lists
    root.walkRules((rule) => {
      if (insideKeyframes(rule) || !rule.selectors || rule.selectors.length < 2) return;
      const risky = rule.selectors.filter((s) => RISKY_SEL.test(s));
      if (!risky.length || risky.length === rule.selectors.length && risky.length === 1) return;
      const safe = rule.selectors.filter((s) => !RISKY_SEL.test(s));
      let after = rule;
      for (const s of risky) {
        const clone = rule.clone({ selector: s });
        after.after(clone); after = clone;
      }
      if (safe.length) rule.selectors = safe; else rule.remove();
    });

    // 3. declarations
    const customFallbacks = []; // [rule, prop, value, condition]
    root.walkDecls((d) => {
      if (insideSupports(d) || insideKeyframes(d)) return;
      const v = d.value;
      if (d.prop.startsWith('--')) {
        const n = needs(v);
        if (!(n.math || n.vunits || n.mix || n.cq)) return;
        const fb = fallbackValue(v);
        if (!fb) return;
        const cond = [n.math && 'not (width: clamp(1px, 1px, 1px))', n.vunits && 'not (height: 1svh)', n.mix && 'not (color: color-mix(in srgb, red 50%, blue))', n.cq && 'not (width: 1cqi)'].filter(Boolean).join(' or ');
        if (d.parent.type === 'rule') customFallbacks.push([d.parent, d.prop, fb, cond, d.important]);
        return;
      }
      const add = (prop, value) => {
        const prev = d.prev();
        const fb = postcss.decl({ prop, value, important: d.important });
        fb.raws.before = d.raws.before;
        fb.raws.between = d.raws.between;
        const c = postcss.comment({ text: MARK });
        c.raws.before = d.raws.before;
        d.before(c); d.before(fb);
        void prev;
      };
      // backdrop-filter prefix
      if (d.prop === 'backdrop-filter') {
        const has = d.parent.nodes.some((n) => n.type === 'decl' && n.prop === '-webkit-backdrop-filter');
        if (!has) add('-webkit-backdrop-filter', d.value);
      }
      const phys = logical(d.prop, v);
      if (phys) {
        const exists = d.parent.nodes.some((n) => n.type === 'decl' && phys.some(([p]) => p === n.prop));
        if (!exists) for (const [p, val] of phys) add(p, fallbackValue(val) || val);
        return;
      }
      const fb = fallbackValue(v);
      if (fb && !/(^|[^a-z-])(clamp|min|max|color-mix)\(|\d(s|d|l)vh/.test(fb)) add(d.prop, fb);
    });
    // one @supports block per rule and condition
    const groups = new Map();
    for (const [rule, prop, value, cond, important] of customFallbacks) {
      if (!groups.has(rule)) groups.set(rule, new Map());
      const g = groups.get(rule);
      if (!g.has(cond)) g.set(cond, []);
      g.get(cond).push([prop, value, important]);
    }
    for (const [rule, byCond] of groups) {
      let after = rule;
      for (const [cond, decls] of byCond) {
        const at = postcss.atRule({ name: 'supports', params: cond });
        at.append(postcss.comment({ text: GEN }));
        const r = postcss.rule({ selector: rule.selector });
        for (const [prop, value, important] of decls) r.append(postcss.decl({ prop, value, important }));
        at.append(r);
        after.after(at); after = at;
      }
    }

    // 4. flex gap fallback
    root.walkRules((rule) => {
      if (insideSupports(rule) || insideKeyframes(rule)) return;
      if (rule.first && rule.first.type === 'comment' && rule.first.text === GEN) return;
      let display = null, gap = null, rowGap = null, colGap = null, dir = 'row', wrapMode = false;
      rule.walkDecls((d) => {
        if (d.parent !== rule) return;
        if (d.prop === 'display') display = d.value.trim();
        if (d.prop === 'gap') { const p = postcss.list.space(d.value); rowGap = p[0]; colGap = p[1] || p[0]; gap = d.value; }
        if (d.prop === 'row-gap') rowGap = d.value;
        if (d.prop === 'column-gap') colGap = d.value;
        if (d.prop === 'flex-direction') dir = d.value.trim();
        if (d.prop === 'flex-wrap' && /wrap/.test(d.value) && !/nowrap/.test(d.value)) wrapMode = true;
        if (d.prop === 'flex-flow') { if (/column/.test(d.value)) dir = 'column'; if (/(^|\s)wrap/.test(d.value)) wrapMode = true; }
      });
      if (!display || !/^(inline-)?flex$/.test(display) || !(gap || rowGap || colGap)) return;
      if (/reverse/.test(dir)) return;
      const sels = rule.selectors.filter((s) => !/::|^(html|:root)\b/.test(s));
      if (!sels.length) return;
      const fix = (v) => fallbackValue(v) || v;
      const decls = [];
      let childSel;
      if (/column/.test(dir)) { if (rowGap) decls.push(['margin-top', fix(rowGap)]); childSel = ' > * + *'; }
      else if (wrapMode) { if (colGap) decls.push(['margin-right', fix(colGap)]); if (rowGap) decls.push(['margin-bottom', fix(rowGap)]); childSel = ' > *'; }
      else { if (colGap) decls.push(['margin-left', fix(colGap)]); childSel = ' > * + *'; }
      if (!decls.length || decls.some(([, v]) => /var\(|^0$/.test(v) && false)) return;
      const r = postcss.rule({ selector: sels.map((s) => `.no-flexgap ${s}${childSel}`).join(', ') });
      r.append(postcss.comment({ text: GEN }));
      for (const [p, v] of decls) r.append(postcss.decl({ prop: p, value: v }));
      rule.after(r);
    });
  },
});
plugin.postcss = true;

// ---------- files ----------
function listFiles() {
  const out = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) { if (!['fonts', 'screens', 'story'].includes(e.name)) walk(full); continue; }
      if (/leaflet\.css$/.test(e.name)) continue; // vendored
      if (/\.css$/.test(e.name) || /\.html$/.test(e.name)) out.push(full);
    }
  };
  walk(PUB);
  return out;
}

async function processCss(css, from) {
  const res = await postcss([plugin]).process(css, { from });
  return res.css;
}

(async () => {
  let changed = 0;
  for (const f of listFiles()) {
    const src = fs.readFileSync(f, 'utf8');
    let out;
    if (f.endsWith('.html')) {
      const parts = []; let last = 0;
      const re = /(<style[^>]*>)([\s\S]*?)(<\/style>)/g; let m;
      while ((m = re.exec(src))) {
        parts.push(src.slice(last, m.index + m[1].length));
        parts.push(await processCss(m[2], f));
        last = m.index + m[1].length + m[2].length;
      }
      parts.push(src.slice(last));
      out = parts.join('');
    } else out = await processCss(src, f);
    if (out !== src) {
      changed++;
      if (CHECK) console.log('would change', path.relative(PUB, f));
      else { fs.writeFileSync(f, out); console.log('updated', path.relative(PUB, f)); }
    }
  }
  if (CHECK && changed) process.exit(1);
  console.log(CHECK ? 'compat check: up to date' : `compat: ${changed} file(s) updated`);
})();
