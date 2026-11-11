'use strict';
/**
 * Website pages without a build step. Every page in public/ is read once at startup:
 *   <!--#include header-->, <!--#include footer-->  -> public/partials/<name>.html
 *   <body data-page="x">                             -> aria-current="page" on links with data-nav="x"
 *   /assets/<file>[?v=...]                            -> /assets/<file>?v=<hash of that file> (cache busting, every
 *                                                        reference: stylesheets, scripts, sprites, images, inline url())
 *   __ASSET_V__                                       -> short hash over every file under public/assets
 *   __APP_VERSION__                                   -> package.json version, "3.15.0" shown as "3.15"
 *   <!--support-email-->..<!--/support-email-->       -> kept (with __SUPPORT_EMAIL__ filled in) when SUPPORT_EMAIL
 *                                                        is a valid address; <!--no-support-email-->..<!--/no-support-email-->
 *                                                        kept otherwise (the legal pages then point to the contact form);
 *                                                        the same with security-email / __SECURITY_EMAIL__ (SECURITY_CONTACT)
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
  '/leaderboard': 'leaderboard.html', // 3.55b public leaderboards (usernames only)
  '/updates': 'updates.html', // 3.56 marketing board: updates, offers, safety tips, events (src/board.js)
  '/about': 'about.html',
  '/guide': 'guide.html', // 3.57 quick start guide (from docs/handbook/users/quick_start.md; linked from the welcome e-mail)
  '/get': 'get.html',
  '/checkout': 'checkout.html', // payment page for an order made in an older app build (not listed in the sitemap)
  // 3.56 rider shop (src/web_shop.js: strict CSP, no-store): /plans, /account, /signin, /receipt.
  ...require('./web_shop').SHOP_PAGES,
  '/privacy': 'privacy.html',
  '/privacy-and-security': 'privacy-and-security.html', // 3.56 plain-language data protection page
  '/terms': 'terms.html',
  '/delete-account': 'delete-account.html',
  '/refunds': 'refund_policy.html', // refund & cancellation policy (website purchases)
  '/security': 'security.html', // responsible disclosure (linked from /.well-known/security.txt)
};
/** Pages rendered by other handlers (not routes of their own). 3.16: the live emergency link pages (/e/<token>). */
const SPECIAL_PAGES = ['404.html', 'join.html', 'join_friend.html', 'live.html', 'live_expired.html', 'watch.html',
  // 3.56 operator / club console pages, rendered by src/operator_routes.js
  'operators_apply.html', 'clubs.html', 'ride_public.html',
  // 3.57 /trip/<tripId> (the ride summary e-mail's link; the owner's own ride), rendered by app.js
  'trip.html'];
/** Special pages a deployment may still lack (the server then answers with a built-in plain page). */
const OPTIONAL_PAGES = new Set(['live.html', 'live_expired.html', 'join_friend.html']); // 3.55: friend invite page (social_routes.js)
/** Sitemap entries: path and priority. */
const SITEMAP = [['/', '1.0'], ['/features', '0.8'], ['/safety', '0.8'], ['/how-it-works', '0.7'], ['/leaderboard', '0.6'], ['/updates', '0.6'], ['/get', '0.8'], ['/plans', '0.8'], ['/about', '0.5'], ['/guide', '0.6'], ['/privacy-and-security', '0.6'], ['/privacy', '0.3'], ['/terms', '0.3'], ['/refunds', '0.3'], ['/security', '0.2'], ['/delete-account', '0.3']];

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

  // iPhone download blocks: <!--ios-->..<!--/ios--> shown only when an App Store / TestFlight / IPA link is
  // configured; <!--no-ios-->..<!--/no-ios--> shown otherwise (read once at startup).
  // Google Play blocks: <!--play-->..<!--/play--> (with __PLAY_STORE_URL__ inside) only when PLAY_STORE_URL is an
  // https link; <!--no-play-->..<!--/no-play--> otherwise.
  const cfg = require('./config');
  const iosAvailable = Boolean(cfg.appStoreUrl || cfg.iosTestFlightUrl || cfg.iosIpaUrl);
  const playStoreUrl = cfg.playStoreUrl;
  const cache = new Map();
  for (const file of [...new Set([...Object.values(SITE_PAGES), ...SPECIAL_PAGES])]) {
    if (OPTIONAL_PAGES.has(file) && !fs.existsSync(path.join(publicDir, file))) continue;
    let html = read(file).replace(INCLUDE, (m, name) => {
      if (!(name in partials)) throw new Error(`${file}: unknown include "${name}"`);
      return partials[name];
    });
    const page = (html.match(/<body\b[^>]*\bdata-page="([a-z0-9-]+)"/) || [])[1];
    if (page) html = html.replaceAll(`data-nav="${page}"`, `data-nav="${page}" aria-current="page"`);
    html = applyPlatformBlocks(html, iosAvailable, playStoreUrl);
    html = applySupportEmail(html, cfg.supportEmail, cfg.securityContact);
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

/** A Play Store link fit for an href: https only, no quotes or angle brackets; '' otherwise. */
function safePlayUrl(url) {
  const s = String(url || '').trim();
  return /^https:\/\/[^\s"'<>]+$/i.test(s) ? s.replace(/&(?!amp;)/g, '&amp;') : '';
}

/**
 * Keeps or strips the platform blocks of a page:
 *   <!--ios-->..<!--/ios--> / <!--no-ios-->..<!--/no-ios-->     by iosAvailable;
 *   <!--play-->..<!--/play--> / <!--no-play-->..<!--/no-play--> by a valid https playStoreUrl, which fills
 *   __PLAY_STORE_URL__ (only ever inside play blocks).
 */
function applyPlatformBlocks(html, iosAvailable, playStoreUrl = '') {
  const play = safePlayUrl(playStoreUrl);
  return html
    .replace(/<!--ios-->([\s\S]*?)<!--\/ios-->/g, (m, inner) => (iosAvailable ? inner : ''))
    .replace(/<!--no-ios-->([\s\S]*?)<!--\/no-ios-->/g, (m, inner) => (iosAvailable ? '' : inner))
    .replace(/<!--play-->([\s\S]*?)<!--\/play-->/g, (m, inner) => (play ? inner.replaceAll('__PLAY_STORE_URL__', play) : ''))
    .replace(/<!--no-play-->([\s\S]*?)<!--\/no-play-->/g, (m, inner) => (play ? '' : inner));
}

/** An e-mail address fit for a page and a mailto: link (plain address, no spaces, quotes or angle brackets); '' otherwise. */
function safeEmail(email) {
  const s = String(email || '').trim();
  return /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$/.test(s) ? s : '';
}

/**
 * Keeps or strips the support e-mail blocks of a page: <!--support-email-->..<!--/support-email--> (with
 * __SUPPORT_EMAIL__ inside) when SUPPORT_EMAIL is a valid address, <!--no-support-email-->..<!--/no-support-email-->
 * otherwise. __SUPPORT_EMAIL__ only ever appears inside support-email blocks.
 */
function applySupportEmail(html, email, securityEmail = email) {
  const blocks = (src, name, token, addr) => {
    const e = safeEmail(addr);
    return src
      .replace(new RegExp(`<!--${name}-->([\\s\\S]*?)<!--\\/${name}-->`, 'g'), (m, inner) => (e ? inner.replaceAll(token, e) : ''))
      .replace(new RegExp(`<!--no-${name}-->([\\s\\S]*?)<!--\\/no-${name}-->`, 'g'), (m, inner) => (e ? '' : inner));
  };
  return blocks(blocks(html, 'support-email', '__SUPPORT_EMAIL__', email), 'security-email', '__SECURITY_EMAIL__', securityEmail);
}

/**
 * The Content-Security-Policy of the public marketing and legal pages (SITE_PAGES other than the shop pages,
 * which set their own): no inline script (the theme line is /assets/theme-init.js), nothing from other sites
 * except https images (approved story photos may be hosted elsewhere), framing denied.
 */
const MARKETING_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: https:",
  "font-src 'self'",
  "connect-src 'self'",
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  "manifest-src 'self'",
].join('; ');

/** True for paths that must never be served as static files (partials, templates, raw page sources). */
function isHiddenPath(rawPath) {
  let p;
  try { p = decodeURIComponent(rawPath); } catch { return true; }
  p = p.toLowerCase();
  return p.startsWith('/partials/') || p === '/partials' || /\/_[^/]*$/.test(p) || p.endsWith('.html');
}

module.exports = { loadSite, isHiddenPath, applyPlatformBlocks, applySupportEmail, safeEmail, safePlayUrl, SITE_PAGES, SITEMAP, MARKETING_CSP };
