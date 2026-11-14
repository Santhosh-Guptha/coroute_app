'use strict';
/**
 * Runs the homepage's rider-stories block from public/assets/site.js against a
 * small fake DOM: template layouts, safe text and honest empty states. (v3.58: the home "CoRoute in numbers"
 * block was removed with the duplicate home sections; the impact block shows the community totals.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const JS = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'site.js'), 'utf8');
const between = (a, b) => {
  const i = JS.indexOf(a);
  const j = JS.indexOf(b, i + 1);
  assert.ok(i >= 0 && j > i, `site.js block ${a}`);
  return JS.slice(i, j);
};
const REVIEWS = between('/* ---------- Rider reviews', '/* ---------- Theme toggle');

class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.attrs = {};
    this.listeners = {};
    this.parent = null;
    this.className = '';
    this.hidden = false;
    this._text = '';
    const self = this;
    this.classList = {
      add(c) { if (!self.classList.contains(c)) self.className = `${self.className} ${c}`.trim(); },
      remove(c) { self.className = self.className.split(/\s+/).filter((x) => x && x !== c).join(' '); },
      contains(c) { return self.className.split(/\s+/).includes(c); },
      toggle(c) { if (self.classList.contains(c)) { self.classList.remove(c); return false; } self.classList.add(c); return true; },
    };
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = []; this._text = String(v); }
  appendChild(c) { c.parent = this; this.children.push(c); return c; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
  all(pred, out = []) { for (const c of this.children) { if (pred(c)) out.push(c); c.all(pred, out); } return out; }
  byClass(c) { return this.all((e) => e.classList.contains(c)); }
  byTag(t) { return this.all((e) => e.tagName === t.toUpperCase()); }
}

function makeDoc(ids) {
  const byId = {};
  for (const id of ids) { byId[id] = new El('div'); byId[id].attrs.id = id; }
  return {
    byId,
    createElement: (t) => new El(t),
    createElementNS: (ns, t) => new El(t),
    getElementById: (id) => byId[id] || null,
    querySelector: () => null,
  };
}
const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
const response = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

async function runReviews(routes) {
  const doc = makeDoc(['community-stories-container', 'reviews-summary']);
  doc.byId['community-stories-container'].setAttribute('data-limit', '6');
  const calls = [];
  const fetch = async (url) => {
    calls.push(url);
    const key = Object.keys(routes).find((k) => url.startsWith(k));
    if (!key) return response(404, { error: 'Not found' });
    const v = routes[key];
    if (v instanceof Error) throw v;
    return response(200, v);
  };
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  // eslint-disable-next-line no-new-func
  new Function('doc', 'win', 'clamp', 'hasIO', 'fetch', REVIEWS)(doc, { fetch }, clamp, false, fetch);
  await flush();
  return { box: doc.byId['community-stories-container'], summary: doc.byId['reviews-summary'], calls };
}

const story = (extra) => ({
  feedbackId: 'FB-ABCDEF123456', tripName: 'Coorg loop', rating: 5, formattedText: 'We stayed together all the way.',
  riderLabel: 'Rider #1', approvedAt: Date.UTC(2026, 9, 1), photos: [], ...extra,
});
const P = (n) => `/api/public/review-photos/FB-ABCDEF123456/rp_${String(n).repeat(24)}`;

test('rider stories render with the template the admin chose', async () => {
  const stories = [
    story({ feedbackId: 'FB-LEFT00000001', template: 'photo-left', photos: [P(1)], photoSizes: [{ width: 1600, height: 1200 }] }),
    story({ feedbackId: 'FB-TOP000000001', template: 'photo-top', photos: [P(2)] }),
    story({ feedbackId: 'FB-QUOTE0000001', template: 'quote-card', photos: [P(3)] }),
    story({ feedbackId: 'FB-GALL00000001', template: 'gallery', photos: [P(4), P(5), P(6)] }),
    story({ feedbackId: 'FB-GALL00000002', template: 'gallery', photos: [P(7)] }),
    story({ feedbackId: 'FB-LEGACY000001', templateLayout: 'multi-pic-grid', photos: [P(8), P(9)] }),
  ];
  const { box, summary, calls } = await runReviews({ '/api/public/community-stories': { ok: true, stories, summary: { count: 6, averageRating: 5 } } });
  assert.equal(calls.length, 1);
  assert.equal(box.getAttribute('data-state'), 'loaded');
  const cards = box.byTag('article');
  assert.deepEqual(cards.map((c) => c.getAttribute('data-template')), ['photo-left', 'photo-top', 'quote-card', 'gallery', 'photo-top', 'gallery']);
  const imgs = (c) => c.byTag('img');
  assert.equal(imgs(cards[0]).length, 1);
  assert.equal(cards[0].byClass('rv-card__media').length, 1);
  assert.equal(imgs(cards[0])[0].width, 1600);
  assert.equal(imgs(cards[0])[0].loading, 'lazy');
  assert.match(imgs(cards[0])[0].alt, /^Group photo from Coorg loop, shared by Rider #1$/);
  assert.equal(imgs(cards[1]).length, 1);
  assert.equal(imgs(cards[2]).length, 0, 'quote card shows no photo');
  assert.equal(imgs(cards[3]).length, 3);
  assert.equal(cards[3].byClass('rv-card__gallery').length, 1);
  assert.equal(imgs(cards[4]).length, 1, 'a one-photo gallery falls back to photo-top');
  assert.equal(imgs(cards[5]).length, 2);
  assert.equal(summary.textContent, 'Average 5.0 out of 5 from 6 approved stories.');
});

test('rider text stays text; unsafe photo links are dropped', async () => {
  const evil = story({
    template: 'photo-top',
    formattedText: '<img src=x onerror=alert(1)> great ride',
    tripName: '<script>alert(1)</script>',
    photos: ['javascript:alert(1)', '//evil.example/x.jpg', 'http://plain.example/x.jpg'],
  });
  const { box } = await runReviews({ '/api/public/community-stories': { ok: true, stories: [evil] } });
  const card = box.byTag('article')[0];
  assert.equal(card.byTag('img').length, 0);
  assert.equal(card.byTag('script').length, 0);
  assert.equal(card.getAttribute('data-template'), 'quote-card');
  assert.ok(card.textContent.includes('<img src=x onerror=alert(1)> great ride'));
});

test('no stories: honest empty state; failures: error state with retry', async () => {
  const empty = await runReviews({ '/api/public/community-stories': { ok: true, stories: [], summary: { count: 0, averageRating: null } } });
  assert.equal(empty.box.getAttribute('data-state'), 'empty');
  assert.ok(empty.box.textContent.includes('No published stories yet.'));
  assert.equal(empty.summary.hidden, true);
  const seeded = await runReviews({ '/api/public/community-stories': { ok: true, stories: [story({ feedbackId: 'FB-SEED-1' })] } });
  assert.equal(seeded.box.getAttribute('data-state'), 'empty', 'placeholder ids never render');
  const broken = await runReviews({ '/api/public/community-stories': new Error('down'), '/community-stories': new Error('down') });
  assert.equal(broken.box.getAttribute('data-state'), 'error');
  assert.ok(broken.box.textContent.includes('could not load'));
  assert.deepEqual(broken.calls, ['/api/public/community-stories?limit=6', '/community-stories']);
});

