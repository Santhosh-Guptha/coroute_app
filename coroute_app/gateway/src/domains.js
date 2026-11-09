'use strict';
/**
 * Public origin and legacy hosts (domain move coroute.duckdns.org -> coroute.devmonks.space,
 * docs/DOMAIN_MIGRATION_devmonks.md).
 *
 * - PUBLIC_ORIGIN is the one canonical origin used for every generated link (invites, live links,
 *   guardian links, checkout, sitemap, canonical tags). Empty: FALLBACK_ORIGIN for links built
 *   without a request, the request's own host for pages.
 * - LEGACY_ORIGINS (default https://coroute.duckdns.org) stay fully served: installed apps have the
 *   old host built in. Both hosts are accepted for CORS and guardian Origin checks.
 * - REDIRECT_LEGACY_HOST=true sends website pages (GET/HEAD) on a legacy host to PUBLIC_ORIGIN with a
 *   301. Never /api, /ws, /.well-known (App Links verification does not follow redirects), live
 *   emergency links, the guardian page or uploads: old apps and links keep working on the old host.
 */

const FALLBACK_ORIGIN = 'https://coroute.duckdns.org';

/** "https://Host:443/" -> "https://host"; anything that is not an http(s) origin -> ''. */
function normaliseOrigin(value) {
  const s = String(value || '').trim();
  if (!s) return '';
  try {
    const u = new URL(s);
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return '';
    return u.origin.toLowerCase();
  } catch {
    return '';
  }
}

/** Host name of an origin or Host header, lower case, without port. */
function hostOf(value) {
  const s = String(value || '').trim().toLowerCase();
  if (!s) return '';
  if (s.includes('://')) { try { return new URL(s).hostname; } catch { return ''; } }
  return s.replace(/:\d+$/, '');
}

/** Every origin this site answers on: the public one first, then the legacy ones (no duplicates). */
function siteOriginsOf(cfg) {
  const all = [normaliseOrigin(cfg.publicOrigin), ...(cfg.legacyOrigins || []).map(normaliseOrigin)].filter(Boolean);
  return [...new Set(all)];
}

/** Origin for links made outside a request (friend invites, SMS live links, provider User-Agent). */
function linkOriginOf(cfg) {
  return normaliseOrigin(cfg.publicOrigin) || FALLBACK_ORIGIN;
}

// Paths that are never redirected from a legacy host (prefix match; '/ws' also exact).
const NO_REDIRECT_PREFIXES = Object.freeze(['/api/', '/ws/', '/.well-known/', '/e/', '/watch', '/uploads/', '/status']);

function isRedirectablePath(path) {
  const p = String(path || '/');
  if (p === '/api' || p === '/ws') return false;
  return !NO_REDIRECT_PREFIXES.some((pre) => p.startsWith(pre));
}

/**
 * Where a request on a legacy host should be sent, or null to serve it here.
 * @param {{publicOrigin:string, legacyOrigins:string[], redirectLegacyHost:boolean}} cfg
 * @param {{method:string, host:string, path:string, url:string}} req  url = path + query
 */
function legacyRedirectTarget(cfg, req) {
  if (!cfg.redirectLegacyHost) return null;
  const target = normaliseOrigin(cfg.publicOrigin);
  if (!target || !target.startsWith('https://')) return null;
  if (req.method !== 'GET' && req.method !== 'HEAD') return null;
  const host = hostOf(req.host);
  if (!host || host === hostOf(target)) return null;
  const legacyHosts = (cfg.legacyOrigins || []).map(hostOf).filter(Boolean);
  if (!legacyHosts.includes(host)) return null;
  if (!isRedirectablePath(req.path)) return null;
  const url = String(req.url || '/');
  return `${target}${url.startsWith('/') ? url : `/${url}`}`;
}

/** Express middleware for REDIRECT_LEGACY_HOST (no-op when the flag is off). */
function legacyHostRedirect(cfg) {
  return (req, res, next) => {
    const to = legacyRedirectTarget(cfg, { method: req.method, host: req.get('host'), path: req.path, url: req.originalUrl });
    if (!to) return next();
    res.set('Cache-Control', 'public, max-age=3600').redirect(301, to);
  };
}

module.exports = {
  FALLBACK_ORIGIN, normaliseOrigin, hostOf, siteOriginsOf, linkOriginOf,
  isRedirectablePath, legacyRedirectTarget, legacyHostRedirect,
};
