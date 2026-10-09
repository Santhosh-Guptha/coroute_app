'use strict';
/**
 * Website pages without a build step. Every page in public/ is read once at startup:
 *   <!--#include header-->, <!--#include footer-->  -> public/partials/<name>.html
 *   <body data-page="x">                             -> aria-current="page" on links with data-nav="x"
 *   /assets/<file>[?v=...]                            -> /assets/<file>?v=<hash of that file> (cache busting, every
 *                                                        reference: stylesheets, scripts, sprites, images, inline url())
 *   __ASSET_V__                                       -> short hash over every file under public/assets
 *   __APP_VERSION__                                   -> package.json version, "3.15.0" shown as "3.15"
 * Per request only the cheap placeholders (__ORIGIN__, __MAX_RIDERS__, __CODE__) are replaced.
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/** Public route -> page file. Each one is rendered through the shared shell. */
const SITE_PAGES = {
  '/': 'index.html',
  '/features': 'features.html',
  '/safety': 'safety.html',
  '/how-it-works': 'how-it-works.html',
  '/about': 'about.html',
  '/get': 'get.html',
  '/privacy': 'privacy.html',
  '/terms': 'terms.html',
};
/** Pages rendered by other handlers (not routes of their own). 3.16: the live emergency link pages (/e/<token>). */
const SPECIAL_PAGES = ['404.html', 'join.html', 'live.html', 'live_expired.html'];
/** Special pages a deployment may still lack (the server then answers with a built-in plain page). */
const OPTIONAL_PAGES = new Set(['live.html', 'live_expired.html']);
/** Sitemap entries: path and priority. */
const SITEMAP = [['/', '1.0'], ['/features', '0.8'], ['/safety', '0.8'], ['/how-it-works', '0.7'], ['/get', '0.8'], ['/about', '0.5'], ['/privacy', '0.3'], ['/terms', '0.3']];

const INCLUDE = /<!--#include ([a-z0-9-]+)-->/g;
/** An /assets/ file reference in a page (attribute, inline style or url()), with an optional old ?v= query. */
const ASSET_REF = /\/assets\/([A-Za-z0-9_\-./]+\.[a-z0-9]+)(?:\?v=[A-Za-z0-9_.]*)?/g;

function loadSite(publicDir) {
  const read = (f) => fs.readFileSync(path.join(publicDir, f), 'utf8');
  const partials = {};
  for (const f of fs.readdirSync(path.join(publicDir, 'partials'))) {
    if (f.endsWith('.html')) partials[f.slice(0, -5)] = read(path.join('partials', f));
  }
  // Cache busting: static files are served with a 7 day max-age, so every /assets reference in a page carries
  // the hash of the file it points to. Editing any asset changes its URL; nothing is bumped by hand.
  const assetsDir = path.join(publicDir, 'assets');
  const fileHashes = new Map();
  const allHash = crypto.createHash('sha256');
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) { walk(full); continue; }
      const buf = fs.readFileSync(full);
      const rel = path.relative(assetsDir, full).split(path.sep).join('/');
      fileHashes.set(rel, crypto.createHash('sha256').update(buf).digest('hex').slice(0, 10));
      allHash.update(rel).update(buf);
    }
  };
  walk(assetsDir);
  const assetVersion = allHash.digest('hex').slice(0, 10);
  const versionAssets = (html, file) => html.replace(ASSET_REF, (m, rel) => {
    const h = fileHashes.get(rel);
    if (!h) throw new Error(`${file}: reference to missing asset /assets/${rel}`);
    return `/assets/${rel}?v=${h}`;
  });
  const pkgVersion = require('../package.json').version;
  const appVersion = pkgVersion.replace(/\.0$/, '');

  const cache = new Map();
  for (const file of [...new Set([...Object.values(SITE_PAGES), ...SPECIAL_PAGES])]) {
    if (OPTIONAL_PAGES.has(file) && !fs.existsSync(path.join(publicDir, file))) continue;
    let html = read(file).replace(INCLUDE, (m, name) => {
      if (!(name in partials)) throw new Error(`${file}: unknown include "${name}"`);
      return partials[name];
    });
    const page = (html.match(/<body\b[^>]*\bdata-page="([a-z0-9-]+)"/) || [])[1];
    if (page) html = html.replaceAll(`data-nav="${page}"`, `data-nav="${page}" aria-current="page"`);
    html = html.replaceAll('__ASSET_V__', assetVersion).replaceAll('__APP_VERSION__', appVersion);
    cache.set(file, versionAssets(html, file));
  }

  return {
    assetVersion,
    appVersion,
    /** Short content hash of one file under public/assets (path relative to assets/). */
    assetHash: (rel) => fileHashes.get(rel),
    /** True when the page file exists and was loaded. */
    has: (file) => cache.has(file),
    /** The page with the per-request placeholders filled in. */
    render(file, vars = {}) {
      let html = cache.get(file);
      if (html === undefined) throw new Error(`unknown page ${file}`);
      for (const [k, v] of Object.entries(vars)) html = html.replaceAll(k, v);
      return html;
    },
  };
}

/** True for paths that must never be served as static files (partials, templates, raw page sources). */
function isHiddenPath(rawPath) {
  let p;
  try { p = decodeURIComponent(rawPath); } catch { return true; }
  p = p.toLowerCase();
  return p.startsWith('/partials/') || p === '/partials' || /\/_[^/]*$/.test(p) || p.endsWith('.html');
}

module.exports = { loadSite, isHiddenPath, SITE_PAGES, SITEMAP };
