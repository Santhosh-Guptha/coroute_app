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
  // Optional medical info (3.14): shown to the ride group only while the rider's SOS is open.
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
/** On/off fields: must be a real boolean. */
const SWITCHES = ['smsOptOut'];

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

// ---------------------------------------------------------------- trips
const TRIP_ID = /^[A-Za-z0-9_-]{4,80}$/;
const TRIP_TEXT = { groupId: 40, tripName: 120, startLocationName: 120, destinationName: 120, createdByUserName: 40 };
const TRIP_NUM = ['startTimeEpochMs', 'endTimeEpochMs', 'totalDistanceKm', 'topSpeedKmh', 'avgSpeedKmh', 'riderCount', 'stopCount', 'movingMs', 'restMs'];

function finite(v) { const n = Number(v); return Number.isFinite(n) ? n : 0; }

/** Keeps at most `max` points, evenly spread over the trail (first and last kept). */
function downsample(list, max) {
  if (list.length <= max) return list;
  if (max < 2) return list.slice(-max);
  const out = [];
  const step = (list.length - 1) / (max - 1);
  for (let i = 0; i < max; i++) out.push(list[Math.round(i * step)]);
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
  }));
  return out;
}

// ---------------------------------------------------------- page views
const SITE_PATHS = new Set(['/', '/privacy', '/terms', '/join']);

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

module.exports = { ValidationError, profileFields, tripRecord, sitePath, cleanPhone, downsample, validPhone, clientIdOf, BLOOD_GROUPS };
