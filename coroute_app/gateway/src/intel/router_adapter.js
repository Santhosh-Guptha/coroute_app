'use strict';
/**
 * Router adapter (feature 13): GEO_ROUTE_URL may point to OSRM (default, ROUTER_KIND=osrm) or to Valhalla with
 * costing=motorcycle (ROUTER_KIND=valhalla, owner-gated, needs the A1: gateway/deploy/valhalla/README.md).
 * Both answers are normalised to the same internal shape GeoProxy already returns:
 *   { distanceM, durationS, line: [{lat,lng}], legs: [{distanceM, durationS}], steps: [{name, ref, distanceM, durationS}] }
 * Valhalla and OSRM are free software (MIT / BSD-2); the map data is OpenStreetMap (ODbL): attribution is shown.
 */

/** Valhalla's encoded shape: polyline with 6 decimals. */
function decodePolyline6(str, maxPoints = 100000) {
  const out = [];
  let i = 0, lat = 0, lng = 0;
  const s = String(str || '');
  while (i < s.length && out.length < maxPoints) {
    let b, shift = 0, result = 0;
    do { b = s.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20 && i < s.length);
    lat += (result & 1) ? ~(result >> 1) : (result >> 1);
    shift = 0; result = 0;
    do { b = s.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20 && i < s.length);
    lng += (result & 1) ? ~(result >> 1) : (result >> 1);
    out.push({ lat: lat / 1e6, lng: lng / 1e6 });
  }
  return out;
}

/** The upstream request for waypoints [{lat,lng}] (rounded by the caller) and an optional start bearing. */
function buildRequest(kind, base, wp, { bearing = null } = {}) {
  if (kind === 'valhalla') {
    const locations = wp.map((p, i) => ({ lat: p.lat, lon: p.lng, type: i === 0 || i === wp.length - 1 ? 'break' : 'through',
      ...(i === 0 && bearing !== null ? { heading: bearing, heading_tolerance: 60 } : {}) }));
    const json = { locations, costing: 'motorcycle', costing_options: { motorcycle: { use_highways: 0.6, use_trails: 0 } },
      directions_options: { units: 'kilometers', language: 'en-US' } };
    return { url: `${base}/route?json=${encodeURIComponent(JSON.stringify(json))}`, kind };
  }
  const coords = wp.map((p) => `${p.lng},${p.lat}`).join(';');
  let url = `${base}/route/v1/driving/${coords}?overview=full&geometries=geojson&steps=true`;
  if (bearing !== null) url += `&bearings=${[`${bearing},60`, ...wp.slice(1).map(() => '')].join(';')}`;
  return { url, kind };
}

/** Error code of an upstream answer ('NoRoute' etc.), or null when it is a route. */
function errorCode(kind, j) {
  if (!j || typeof j !== 'object') return 'Invalid';
  if (kind === 'valhalla') {
    if (j.trip && Array.isArray(j.trip.legs)) return null;
    // Valhalla: 442 "No path could be found", 171 "No suitable edges near location"
    const c = Number(j.error_code);
    if (c === 442 || c === 443) return 'NoRoute';
    if (c === 171 || c === 170) return 'NoSegment';
    return j.error_code ? `Valhalla${c}` : 'Invalid';
  }
  if (typeof j.code === 'string' && j.code !== 'Ok') return j.code;
  return Array.isArray(j.routes) && j.routes.length ? null : 'NoRoute';
}

/** Normalises one answer; null when it carries no route. */
function normalise(kind, j) {
  if (errorCode(kind, j)) return null;
  if (kind === 'valhalla') {
    const legs = j.trip.legs;
    const line = [];
    const steps = [];
    for (const leg of legs) {
      const pts = decodePolyline6(leg.shape);
      if (line.length && pts.length) pts.shift();
      line.push(...pts);
      for (const m of (leg.maneuvers || [])) {
        const name = Array.isArray(m.street_names) ? String(m.street_names[0] || '').trim() : '';
        const d = Math.round((Number(m.length) || 0) * 1000);
        if (name || d > 0) steps.push({ name, ref: '', distanceM: d, durationS: Math.round(Number(m.time) || 0) });
      }
    }
    const sum = j.trip.summary || {};
    return {
      distanceM: Math.round((Number(sum.length) || 0) * 1000), durationS: Math.round(Number(sum.time) || 0), line,
      legs: legs.map((l) => ({ distanceM: Math.round((Number(l.summary?.length) || 0) * 1000), durationS: Math.round(Number(l.summary?.time) || 0) })),
      steps, router: 'valhalla',
    };
  }
  const r = j.routes[0];
  const steps = [];
  for (const leg of (r.legs || [])) {
    for (const s of (leg.steps || [])) {
      const name = (s.name || '').trim();
      const ref = (s.ref || '').trim();
      const d = Math.round(s.distance || 0);
      if (name || ref || d > 0) steps.push({ name, ref, distanceM: d, durationS: Math.round(s.duration || 0) });
    }
  }
  return {
    distanceM: Math.round(r.distance || 0), durationS: Math.round(r.duration || 0),
    line: (r.geometry?.coordinates || []).map(([x, y]) => ({ lat: y, lng: x })),
    legs: (r.legs || []).map((l) => ({ distanceM: Math.round(l.distance || 0), durationS: Math.round(l.duration || 0) })),
    steps, router: 'osrm',
  };
}

const ATTRIBUTION = {
  osrm: 'Routes: OSRM, map data © OpenStreetMap contributors (ODbL)',
  valhalla: 'Routes: Valhalla, map data © OpenStreetMap contributors (ODbL)',
};

module.exports = { buildRequest, normalise, errorCode, decodePolyline6, ATTRIBUTION };
