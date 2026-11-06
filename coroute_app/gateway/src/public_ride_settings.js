'use strict';
/**
 * "Public ride" settings of one ride (room meta `publicRide`), kept free of other modules so
 * convoys.js and public_ride.js can both use it. Off unless the host turns it on.
 *
 *   { on, radiusKm (5 | 10 | 25 | 50), showName, showDestRegion, id, since }
 *
 * `id` is an opaque handle other riders see instead of the group id; it changes every time the
 * ride is made public again, so an old id never leads back to the ride.
 */
const crypto = require('crypto');

const RADII_KM = [5, 10, 25, 50];
const DEFAULT_RADIUS_KM = 10;

function radiusOf(v, def = DEFAULT_RADIUS_KM) {
  const n = Number(v);
  return RADII_KM.includes(n) ? n : def;
}

/** Settings as stored: always a complete object (off by default). */
function publicRideOf(stored) {
  const s = stored && typeof stored === 'object' ? stored : {};
  return {
    on: s.on === true,
    radiusKm: radiusOf(s.radiusKm),
    showName: s.showName === true,
    showDestRegion: s.showDestRegion === true,
    id: typeof s.id === 'string' && /^PR-[0-9A-F]{12}$/.test(s.id) ? s.id : '',
    since: Number(s.since) || 0,
  };
}

/** A host's CONFIG patch applied to the stored settings (wrong types are ignored). */
function applyPublicRidePatch(stored, patch, at = Date.now()) {
  const cur = publicRideOf(stored);
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) return cur;
  const next = { ...cur };
  if (typeof patch.on === 'boolean') next.on = patch.on;
  if (patch.radiusKm !== undefined) next.radiusKm = radiusOf(patch.radiusKm, cur.radiusKm);
  if (typeof patch.showName === 'boolean') next.showName = patch.showName;
  if (typeof patch.showDestRegion === 'boolean') next.showDestRegion = patch.showDestRegion;
  if (next.on && !cur.on) { next.id = `PR-${crypto.randomBytes(6).toString('hex').toUpperCase()}`; next.since = at; }
  if (!next.on) { next.id = ''; next.since = 0; }
  return next;
}

/** What the ride's own members see (CONFIG / SNAPSHOT): never the opaque id. */
function publicRideView(stored) {
  const s = publicRideOf(stored);
  return { on: s.on, radiusKm: s.radiusKm, showName: s.showName, showDestRegion: s.showDestRegion };
}

module.exports = { RADII_KM, DEFAULT_RADIUS_KM, radiusOf, publicRideOf, applyPublicRidePatch, publicRideView };
