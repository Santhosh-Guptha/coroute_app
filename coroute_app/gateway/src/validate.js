'use strict';
/**
 * Input validation for everything a client writes that is stored and shown to
 * others: profile fields, trip records and website page-view paths.
 *
 * Profile rules apply only to values being written (registration, and fields a
 * rider changes in their profile). Existing stored values are never re-checked,
 * so nobody is locked out by a rule that is newer than their account.
 */
const config = require('./config');

class ValidationError extends Error {
  constructor(message, fields = {}, status = 422, code = 'INVALID_INPUT') {
    super(message); this.name = 'ValidationError'; this.status = status; this.fields = fields; this.code = code;
  }
}

// Control characters, plus invisible and text-direction characters that let one name pose as
// another. Zero-width joiner and non-joiner (U+200C, U+200D) stay allowed: Indian scripts use them.
const CONTROL = /[\u0000-\u001F\u007F-\u009F\u2028\u2029\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]/;
const PHONE = /^\+?[0-9 ]{7,16}$/;
const VEHICLE_NO = /^[A-Z0-9 -]+$/;

/** Phone as stored: trimmed, common separators ( - . ( ) ) removed, spaces collapsed. */
function cleanPhone(v) {
  return String(v ?? '').trim().replace(/[-.()]/g, ' ').replace(/\s+/g, ' ').trim();
}

const RULES = {
  name(v) {
    const s = String(v ?? '').trim().replace(/\s+/g, ' ');
    if (s.length < 2 || s.length > 40) return [null, 'Use 2 to 40 characters for your callsign.'];
    if (CONTROL.test(s)) return [null, 'Your callsign has characters that are not allowed.'];
    if (s.includes('@')) return [null, 'Your callsign cannot contain @.'];
    return [s];
  },
  email(v) {
    const s = String(v ?? '').trim().toLowerCase();
    if (s.length > 120 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s)) return [null, 'Enter a valid e-mail address.'];
    return [s];
  },
  phone(v) {
    const s = cleanPhone(v);
    if (!PHONE.test(s)) return [null, 'Enter a valid phone number (7 to 16 digits, may start with +).'];
    return [s];
  },
  emergencyContact(v) {
    const s = cleanPhone(v);
    if (!PHONE.test(s)) return [null, 'Enter a valid phone number for your emergency contact.'];
    return [s];
  },
  emergencyContactName(v) {
    const s = String(v ?? '').trim().replace(/\s+/g, ' ');
    if (s.length < 2 || s.length > 40 || CONTROL.test(s)) return [null, 'Use 2 to 40 characters for the emergency contact name.'];
    return [s];
  },
  vehicleType(v) {
    const s = String(v ?? '').trim();
    if (s.length > 30 || CONTROL.test(s)) return [null, 'Use at most 30 characters for the vehicle type.'];
    return [s];
  },
  vehicleNo(v) {
    const s = String(v ?? '').trim().toUpperCase().replace(/\s+/g, ' ');
    if (s === '' || s === 'PILLION') return [s];
    if (s.length > 16 || !VEHICLE_NO.test(s)) return [null, 'Use letters, numbers, spaces or - for the bike number (at most 16).'];
    return [s];
  },
  // Optional medical info (3.14): shown to responders only while the rider's SOS is open (no consent switch).
  bloodGroup(v) {
    const s = String(v ?? '').trim().toUpperCase().replace(/\s+/g, '');
    if (s !== '' && !BLOOD_GROUPS.has(s)) return [null, 'Pick a blood group from the list.'];
    return [s];
  },
  allergies(v) {
    const s = String(v ?? '').trim().replace(/ +/g, ' ');
    if (s.length > config.medicalAllergiesMax || CONTROL.test(s)) return [null, `Use at most ${config.medicalAllergiesMax} characters for allergies, on one line.`];
    return [s];
  },
  medicalNotes(v) {
    const s = String(v ?? '').trim().replace(/ +/g, ' ');
    if (s.length > config.medicalNotesMax || CONTROL.test(s)) return [null, `Use at most ${config.medicalNotesMax} characters for medical notes, on one line.`];
    return [s];
  },
};

const BLOOD_GROUPS = new Set(['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']);

/** Fields that may be empty when written (everything else must pass its rule). */
const MAY_BE_EMPTY = new Set(['vehicleType', 'vehicleNo', 'bloodGroup', 'allergies', 'medicalNotes']);
/** On/off fields: must be a real boolean. 3.15: the nearby-rider assistance switches. */
const SWITCHES = ['smsOptOut', 'assistHelp', 'assistAsk', 'responderMedical'];

/**
 * Validates the given profile fields. Only keys present in `input` (and not
 * undefined) are checked and returned. Throws ValidationError with per-field
 * messages. `optionalEmpty` lists fields that may be sent empty (stored as '').
 */
function profileFields(input, { optionalEmpty = [] } = {}) {
  const out = {};
  const errors = {};
  const emptyOk = new Set([...MAY_BE_EMPTY, ...optionalEmpty]);
  for (const key of SWITCHES) {
    if (!input || input[key] === undefined || input[key] === null) continue;
    if (typeof input[key] !== 'boolean') errors[key] = 'This field must be on or off.'; else out[key] = input[key];
  }
  for (const [key, rule] of Object.entries(RULES)) {
    if (!input || input[key] === undefined || input[key] === null) continue;
    // Text (or a number for phone fields from older builds); never objects, arrays or booleans.
    if (typeof input[key] !== 'string' && typeof input[key] !== 'number') { errors[key] = 'This field must be text.'; continue; }
    const raw = String(input[key]).trim();
    if (raw === '' && emptyOk.has(key)) { out[key] = ''; continue; }
    const [value, error] = rule(input[key]);
    if (error) errors[key] = error; else out[key] = value;
  }
  if (Object.keys(errors).length) throw new ValidationError(Object.values(errors)[0], errors);
  return out;
}

// ---------------------------------------------------------------- bike summary (3.55)
/** The active bike's summary a rider's app sends for engine-care and fuel analysis (owner + admin only). */
// 3.56 (bike details once): also the confirmed bike type and the fuel type, so a reinstalled app
// (or a second phone) gets the whole bike back and is not asked for the details again.
const BIKE_KEYS = ['bikeModel', 'bikeCc', 'bikeColour', 'bikeTankL', 'bikeMileageKmL', 'bikeCooling', 'bikeType', 'bikeFuel'];
const BIKE_COOLING = new Set(['unknown', 'air', 'oil', 'liquid']);
/** Bike type ids (app BikeType, rider record vehicleKind); '' = not confirmed yet. */
const BIKE_TYPES = new Set(['commuter', 'scooter', 'sport', 'cruiser', 'adventure', 'offroad', 'electric', 'retro']);
const BIKE_FUELS = new Set(['petrol', 'diesel', 'cng', 'ev']);

/**
 * Validates the optional bike summary. Only keys present (not undefined) are checked and
 * returned. null, '' or 0 clears a value (stored as '' / 0 / 'unknown'). Throws ValidationError.
 */
function bikeFields(input) {
  const out = {};
  const errors = {};
  if (!input || typeof input !== 'object') return out;
  const text = (key, max, label) => {
    const v = input[key];
    if (v === undefined) return;
    if (v === null) { out[key] = ''; return; }
    if (typeof v !== 'string') { errors[key] = 'This field must be text.'; return; }
    const s = v.trim().replace(/ +/g, ' ');
    if (s.length > max || CONTROL.test(s)) { errors[key] = `Use at most ${max} characters for the ${label}, on one line.`; return; }
    out[key] = s;
  };
  const number = (key, min, max, message, { int = false } = {}) => {
    const v = input[key];
    if (v === undefined) return;
    if (v === null || v === 0 || v === '') { out[key] = 0; return; }
    const n = typeof v === 'number' ? v : (typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN);
    if (!Number.isFinite(n) || n < min || n > max || (int && !Number.isInteger(n))) { errors[key] = message; return; }
    out[key] = int ? n : Math.round(n * 10) / 10;
  };
  text('bikeModel', 60, 'bike model');
  text('bikeColour', 30, 'bike colour');
  number('bikeCc', 50, 2500, 'Engine size must be a whole number from 50 to 2500 cc.', { int: true });
  number('bikeTankL', 2, 40, 'Tank size must be from 2 to 40.');
  // From 2: an electric bike's mileage is km per kWh (2 to 60); petrol bikes are 5 to 120 in the app.
  number('bikeMileageKmL', 2, 120, 'Mileage must be from 2 to 120 km per unit.');
  const choice = (key, allowed, message) => {
    const v = input[key];
    if (v === undefined) return;
    if (v === null || v === '') { out[key] = ''; return; }
    if (typeof v !== 'string' || !allowed.has(v)) { errors[key] = message; return; }
    out[key] = v;
  };
  choice('bikeType', BIKE_TYPES, 'Pick a bike type from the list.');
  choice('bikeFuel', BIKE_FUELS, 'Pick a fuel type from the list.');
  if (input.bikeCooling !== undefined) {
    const c = input.bikeCooling === null ? 'unknown' : input.bikeCooling;
    if (typeof c !== 'string' || !BIKE_COOLING.has(c)) errors.bikeCooling = 'Pick a cooling type from the list.'; else out.bikeCooling = c;
  }
  if (Object.keys(errors).length) throw new ValidationError(Object.values(errors)[0], errors);
  return out;
}

// ---------------------------------------------------------------- trips
const TRIP_ID = /^[A-Za-z0-9_-]{4,80}$/;
const TRIP_TEXT = { groupId: 40, tripName: 120, startLocationName: 120, destinationName: 120, createdByUserName: 40 };
const TRIP_NUM = ['startTimeEpochMs', 'endTimeEpochMs', 'totalDistanceKm', 'topSpeedKmh', 'avgSpeedKmh', 'riderCount', 'stopCount', 'movingMs', 'restMs'];

const CLIENT_STATS = ['v', 'distanceM', 'recordedDistanceM', 'gapDistanceM', 'movingMs', 'restMs', 'gapMs', 'maxKmh', 'avgMovingKmh', 'stops', 'longestStopMs', 'firstFixAt', 'lastFixAt', 'points', 'pieces'];

function finite(v) { const n = Number(v); return Number.isFinite(n) ? n : 0; }

/** Keeps at most `max` points, evenly spread over the trail (first and last kept). */
function downsample(list, max) {
  if (list.length <= max) return list;
  if (max < 2) return list.slice(-max);
  const out = [];
  const step = (list.length - 1) / (max - 1);
  let prev = -1;
  for (let i = 0; i < max; i++) {
    const idx = Math.round(i * step);
    let p = list[idx];
    // A signal gap between the previous kept point and this one stays a gap (trip trails).
    if (p && p.gap !== true) for (let j = prev + 1; j < idx; j++) if (list[j] && list[j].gap === true) { p = { ...p, gap: true }; break; }
    out.push(p);
    prev = idx;
  }
  return out;
}

/** A trip record from a phone, reduced to the known fields with types and sizes enforced. */
function tripRecord(t, { maxPoints = config.tripMaxTrailPoints } = {}) {
  if (!t || typeof t !== 'object') throw new ValidationError('Trip data is missing.', {}, 400);
  const tripId = typeof t.tripId === 'string' ? t.tripId : '';
  if (!TRIP_ID.test(tripId)) throw new ValidationError('tripId required', { tripId: 'Use 4 to 80 letters, numbers, - or _.' }, 400);
  const out = { tripId };
  for (const [k, max] of Object.entries(TRIP_TEXT)) {
    if (t[k] !== undefined && t[k] !== null) out[k] = String(t[k]).replace(/[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g, ' ').slice(0, max);
  }
  for (const k of TRIP_NUM) if (t[k] !== undefined && t[k] !== null) out[k] = finite(t[k]);
  const trail = Array.isArray(t.breadcrumbTrail) ? t.breadcrumbTrail : [];
  out.breadcrumbTrail = downsample(
    trail.filter((p) => p && typeof p === 'object' && Number.isFinite(Number(p.lat)) && Number.isFinite(Number(p.lng))),
    maxPoints,
  ).map((p) => ({
    lat: Math.max(-90, Math.min(90, Number(p.lat))),
    lng: Math.max(-180, Math.min(180, Number(p.lng))),
    speedKmh: Math.max(0, Math.min(300, finite(p.speedKmh))),
    heading: ((finite(p.heading) % 360) + 360) % 360,
    timestamp: finite(p.timestamp),
    // The first point after a signal gap: maps cut the line there.
    ...(p.gap === true ? { gap: true } : {}),
  }));
  // Numbers the phone computed from its own recorded track (the server uses them when it has no track).
  if (t.clientStats && typeof t.clientStats === 'object' && !Array.isArray(t.clientStats)) {
    const cs = {};
    for (const k of CLIENT_STATS) {
      const v = Number(t.clientStats[k]);
      if (Number.isFinite(v) && v >= 0) cs[k] = v;
    }
    if (Object.keys(cs).length) out.clientStats = cs;
  }
  return out;
}

// ---------------------------------------------------------- page views
const SITE_PATHS = new Set(['/', '/features', '/safety', '/how-it-works', '/about', '/get', '/privacy', '/terms', '/join']);

/** The site page a beacon path belongs to, or null for anything else (not stored). */
function sitePath(raw) {
  let p = String(raw || '/').split(/[?#]/)[0].slice(0, 200).toLowerCase();
  if (!p.startsWith('/')) return null;
  p = p.replace(/\/index\.html$/, '/').replace(/\.html$/, '');
  if (p.length > 1) p = p.replace(/\/+$/, '');
  if (p.startsWith('/join/')) p = '/join';
  return SITE_PATHS.has(p) ? p : null;
}

/** A phone number as stored, if it is a usable number (used for the SMS roster), else ''. */
function validPhone(v) {
  const s = cleanPhone(v);
  return PHONE.test(s) ? s : '';
}

/**
 * Optional clientId on socket messages (outbox dedupe): 1 to 64 of A-Z a-z 0-9 _ . : -
 * Anything else is treated as absent (old behaviour).
 */
const CLIENT_ID = /^[A-Za-z0-9_.:-]{1,64}$/;
function clientIdOf(v) { return typeof v === 'string' && CLIENT_ID.test(v) ? v : ''; }

/** Roles the lead may give a rider (3.16 ROLE_SET; 3.55 adds LEAD: the riding lead, the owner keeps the owner's rights). */
// 3.55: LEAD too (the riding lead at the front; the ride's owner keeps the owner's rights).
const ROLES_SETTABLE = new Set(['LEAD', 'SWEEPER', 'PACK']);
/** A settable role as sent, or '' for anything else. */
function roleOf(v) { return typeof v === 'string' && ROLES_SETTABLE.has(v) ? v : ''; }

/** Live emergency link token (3.16): exactly 32 of A-Z a-z 0-9 _ - (24 random bytes, base64url). */
// 32 characters (alert / share links) or 22 (3.56: the SOS SMS links, which must fit a 30-character DLT variable).
const LIVE_TOKEN = /^(?:[A-Za-z0-9_-]{22}|[A-Za-z0-9_-]{32})$/;
function liveTokenOf(v) { return typeof v === 'string' && LIVE_TOKEN.test(v) ? v : ''; }

/**
 * Weather points (3.16): 1 to 5 of { lat, lng, at? }. Returns the clean list or throws ValidationError 422.
 * `at` (epoch seconds) defaults to now and is clamped to [now - 1 h, now + 48 h].
 */
function weatherPoints(input, nowS = Math.floor(Date.now() / 1000)) {
  if (!Array.isArray(input) || input.length < 1 || input.length > 5) throw new ValidationError('Send 1 to 5 points.', { points: 'Send 1 to 5 points.' });
  const out = [];
  for (const p of input) {
    if (!p || typeof p !== 'object' || Array.isArray(p)) throw new ValidationError('Each point needs lat and lng.', { points: 'Each point needs lat and lng.' });
    const num = (v) => (v === null || v === undefined || v === '' || typeof v === 'boolean' ? NaN : Number(v));
    const lat = num(p.lat), lng = num(p.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) {
      throw new ValidationError('Each point needs lat and lng.', { points: 'Each point needs lat and lng.' });
    }
    let at = p.at === undefined || p.at === null ? nowS : num(p.at);
    if (!Number.isFinite(at)) throw new ValidationError('Point time must be a number (epoch seconds).', { points: 'Point time must be a number (epoch seconds).' });
    if (at > 1e11) at = Math.round(at / 1000); // milliseconds sent by mistake
    at = Math.round(Math.max(nowS - 3600, Math.min(nowS + 48 * 3600, at)));
    out.push({ lat, lng, at });
  }
  return out;
}

module.exports = {
  ValidationError, SWITCHES, profileFields, tripRecord, sitePath, cleanPhone, downsample, validPhone, clientIdOf, BLOOD_GROUPS,
  ROLES_SETTABLE, roleOf, liveTokenOf, weatherPoints, bikeFields, BIKE_KEYS,
};
