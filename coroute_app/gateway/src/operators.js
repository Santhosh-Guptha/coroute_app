'use strict';
/**
 * 3.56 Operator / club console (docs/features_355/operators.md): storage, limits and rules.
 * HTTP, pages, pushes and the admin API live in operator_routes.js.
 *
 * Flow:
 *   1. A signed-in rider applies (type, organisation, city, private business contact, link, expected
 *      riders, description): status PENDING. One application per rider (a rejected one can be re-sent).
 *   2. A master admin approves (limits + features + validity, defaults from the per-type template),
 *      rejects with a reason, suspends or reinstates. Every decision is audited (admin audit log).
 *   3. On approval the operator gets a CLUB CREW (crews.js document with `club: {operatorId, ...}`):
 *      the roster IS that crew, so members see the invite in the app's existing crew invite list
 *      (People hub > Requests), accept there or on the website, and leave it like any crew. Ride
 *      invites to the roster reuse crew ride invites (ride_invites, crewId = the club crew).
 *   4. Operator rides: scheduled in the console, started as a normal convoy whose trip owner is the
 *      lead; the seats come from the operator limits (`operatorCapacity`), never the personal plan.
 *
 * Collections (created on first use): operators, operator_rides, operator_broadcasts and one config
 * document (operators_config, k='templates').
 *
 * Privacy: the business contact (e-mail / phone) is seen only by the applicant and master admins.
 * Operators never see members' phone, e-mail or medical info, except a rider's emergency contact
 * (and medical ID) while that rider has an OPEN SOS in an operator ride (audited each time).
 */
const crypto = require('crypto');
const config = require('./config');
const CR = require('./crews');

const C = Object.freeze({ operators: 'operators', rides: 'operator_rides', broadcasts: 'operator_broadcasts', config: 'operators_config' });
const DAY = 86400000;
const IST = 330 * 60000;

const TYPES = Object.freeze({
  TOUR_OPERATOR: 'Tour operator',
  RIDING_CLUB: 'Riding club',
  RENTAL_FLEET: 'Rental fleet',
  CORPORATE_FLEET: 'Corporate fleet',
});
const STATUS = Object.freeze({ PENDING: 'PENDING', APPROVED: 'APPROVED', REJECTED: 'REJECTED', SUSPENDED: 'SUSPENDED' });
const RIDE_STATUS = Object.freeze({ SCHEDULED: 'SCHEDULED', LIVE: 'LIVE', ENDED: 'ENDED', CANCELLED: 'CANCELLED' });

/** Feature checkboxes an admin grants per operator (co-organisers is a number in `limits`). */
const FEATURES = Object.freeze({
  multiGroupDashboard: 'Multi-group live dashboard',
  rosterEmergency: 'Roster & emergency contacts during an SOS',
  attendance: 'Attendance',
  rideCalendar: 'Ride calendar & public sign-ups',
  broadcast: 'Broadcast messages to the roster',
  exportReports: 'Export reports (CSV)',
});

/** Bounds of every limit (the admin form shows them). Riders per ride never exceed MAX_CONVOY_RIDERS. */
function limitBounds() {
  return {
    maxMembers: [1, 1000],
    maxConcurrentRides: [1, 20],
    maxRidesPerMonth: [1, 500],
    maxRidersPerRide: [2, Math.max(2, Number(config.maxConvoyRiders) || 50)],
    coOrganisers: [0, 10],
    validityDays: [1, 1095],
  };
}

const T = (maxMembers, maxConcurrentRides, maxRidesPerMonth, maxRidersPerRide, coOrganisers, features, validityDays = 365) => ({
  limits: { maxMembers, maxConcurrentRides, maxRidesPerMonth, maxRidersPerRide, coOrganisers }, features, validityDays,
});
const ALL = { multiGroupDashboard: true, rosterEmergency: true, attendance: true, rideCalendar: true, broadcast: true, exportReports: true };
/** Built-in defaults per type (an admin can change them: GET/PUT /admin/operators/templates). */
const DEFAULT_TEMPLATES = Object.freeze({
  TOUR_OPERATOR: T(200, 3, 30, 30, 3, { ...ALL }),
  RIDING_CLUB: T(150, 2, 12, 40, 3, { ...ALL, exportReports: false }),
  RENTAL_FLEET: T(100, 5, 60, 12, 2, { ...ALL, rideCalendar: false }),
  CORPORATE_FLEET: T(300, 5, 40, 25, 5, { ...ALL, rideCalendar: false }),
});

class OperatorError extends Error {
  constructor(message, code, status = 400, extra = {}) { super(message); this.name = 'OperatorError'; this.code = code; this.status = status; Object.assign(this, extra); }
}
const bad = (message, code = 'BAD_REQUEST', status = 422, extra) => { throw new OperatorError(message, code, status, extra); };

const hex = (n) => crypto.randomBytes(n).toString('hex');
const withKey = (r) => (r ? { ...r.value, key: r.key } : null);
const stripKey = ({ key, ...v }) => v; // eslint-disable-line no-unused-vars
const OP_RE = /^op_[a-f0-9]{16}$/;
const RIDE_RE = /^or_[a-f0-9]{16}$/;
const SLUG_RE = /^[a-z0-9-]{3,60}-[a-f0-9]{6}$/;
const CODE_RE = /^[A-Za-z0-9]{10}$/;
const isOperatorId = (v) => typeof v === 'string' && OP_RE.test(v);
const isRideId = (v) => typeof v === 'string' && RIDE_RE.test(v);
const isSlug = (v) => typeof v === 'string' && SLUG_RE.test(v);
const isInviteCode = (v) => typeof v === 'string' && CODE_RE.test(v);

const ensured = new WeakSet();
async function ensureStore(soda) {
  if (ensured.has(soda)) return;
  for (const c of Object.values(C)) await soda.ensureCollection(c);
  const idx = (coll, name, fields, unique = false) => soda.ensureIndex(coll, { name, unique, fields: fields.map((path) => ({ path })) });
  await idx(C.operators, 'operators_id_ux', ['operatorId'], true);
  await idx(C.operators, 'operators_owner_ux', ['ownerId'], true);
  await idx(C.operators, 'operators_status_ix', ['status']);
  await idx(C.operators, 'operators_code_ix', ['inviteCode']);
  await idx(C.rides, 'operator_rides_id_ux', ['rideId'], true);
  await idx(C.rides, 'operator_rides_slug_ux', ['slug'], true);
  await idx(C.rides, 'operator_rides_op_ix', ['operatorId']);
  await idx(C.rides, 'operator_rides_group_ix', ['groupId']);
  await idx(C.broadcasts, 'operator_broadcasts_op_ix', ['operatorId']);
  await idx(C.config, 'operators_config_ux', ['k'], true);
  ensured.add(soda);
}

// ------------------------------------------------------------------ text
/** Control / bidi / zero-width characters and angle brackets out, whitespace collapsed, capped. */
function clean(raw, max) {
  if (typeof raw !== 'string') return '';
  return raw.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁯﻿]/g, ' ')
    .replace(/[<>]/g, '').replace(/\s+/g, ' ').trim().slice(0, max);
}
const EMAIL_RE = /^[^\s@<>()",;:]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,24}$/;
const PHONE_RE = /^\+?[0-9][0-9 -]{6,18}[0-9]$/;
const CONTACT_IN_TEXT = /([^\s@]+@[^\s@]+\.[a-z]{2,}|(?:\d[\s-]?){7,})/i;

/** https / http link to a website or social page, or ''. */
function cleanLink(raw) {
  const s = clean(raw, 200);
  if (!s) return '';
  let u;
  try { u = new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`); } catch { return null; }
  if (!['http:', 'https:'].includes(u.protocol) || !/\.[a-z]{2,}$/i.test(u.hostname) || u.username || u.password) return null;
  return u.toString().slice(0, 200);
}

/** The application body -> clean fields, or throws OperatorError with `fields`. */
function validateApplication(b = {}) {
  const fields = {};
  const type = String(b.type || '').trim().toUpperCase();
  if (!TYPES[type]) fields.type = 'Pick tour operator, riding club, rental fleet or corporate fleet.';
  const name = clean(b.name, 80);
  if (name.length < 3 || !/[\p{L}\p{N}]/u.test(name)) fields.name = 'Organisation name: 3 to 80 characters.';
  const city = clean(b.city, 60);
  if (city.length < 2) fields.city = 'Enter the city you run rides from.';
  const email = clean(b.email, 254).toLowerCase();
  if (!EMAIL_RE.test(email)) fields.email = 'Enter a business e-mail address.';
  const phone = clean(b.phone, 20);
  if (!PHONE_RE.test(phone)) fields.phone = 'Enter a business phone number.';
  const website = cleanLink(b.website);
  if (website === null) fields.website = 'Enter a website or social page link (https://...).';
  const expected = Math.floor(Number(b.expectedRiders));
  if (!Number.isFinite(expected) || expected < 1 || expected > 100000) fields.expectedRiders = 'Expected riders: a number from 1.';
  const description = clean(b.description, 500);
  if (description.length < 10) fields.description = 'Tell us in a sentence or two what rides you run (10 to 500 characters).';
  else if (CONTACT_IN_TEXT.test(description)) fields.description = 'Keep phone numbers and e-mail addresses in the contact fields.';
  if (Object.keys(fields).length) bad('Please check the highlighted fields.', 'INVALID_APPLICATION', 422, { fields });
  return { type, name, city, contact: { email, phone }, website: website || '', expectedRiders: expected, description };
}

// ------------------------------------------------------------------ templates and limits
function clampInt(v, [lo, hi], def) {
  const n = Math.floor(Number(v));
  if (!Number.isFinite(n)) return def;
  return Math.max(lo, Math.min(hi, n));
}
/** Limits from input, each clamped to its bounds; missing values from `base`. */
function cleanLimits(input = {}, base = {}) {
  const b = limitBounds();
  const out = {};
  for (const k of ['maxMembers', 'maxConcurrentRides', 'maxRidesPerMonth', 'maxRidersPerRide', 'coOrganisers']) {
    out[k] = clampInt(input[k] ?? base[k], b[k], b[k][0]);
  }
  return out;
}
function cleanFeatures(input = {}, base = {}) {
  const out = {};
  for (const k of Object.keys(FEATURES)) out[k] = typeof input[k] === 'boolean' ? input[k] : !!base[k];
  return out;
}
function cleanTemplate(input = {}, base = {}) {
  return {
    limits: cleanLimits(input.limits || {}, (base && base.limits) || {}),
    features: cleanFeatures(input.features || {}, (base && base.features) || {}),
    validityDays: clampInt(input.validityDays ?? (base && base.validityDays), limitBounds().validityDays, 365),
  };
}

async function getTemplates(soda) {
  await ensureStore(soda);
  const row = await soda.findOne(C.config, { k: 'templates' });
  const stored = (row && row.value.templates) || {};
  const out = {};
  for (const t of Object.keys(TYPES)) out[t] = cleanTemplate(stored[t] || {}, DEFAULT_TEMPLATES[t]);
  return { templates: out, updatedAt: row ? row.value.updatedAt || 0 : 0, updatedBy: row ? row.value.updatedBy || null : null };
}
async function saveTemplates(soda, input, by) {
  const cur = (await getTemplates(soda)).templates;
  const next = {};
  for (const t of Object.keys(TYPES)) next[t] = cleanTemplate((input && input[t]) || {}, cur[t]);
  await soda.upsertBy(C.config, { k: 'templates' }, { k: 'templates', templates: next, updatedAt: Date.now(), updatedBy: by || null });
  return next;
}

// ------------------------------------------------------------------ operators
async function getOperator(soda, operatorId) {
  if (!isOperatorId(operatorId)) return null;
  await ensureStore(soda);
  return withKey(await soda.findOne(C.operators, { operatorId }));
}
async function operatorOfOwner(soda, ownerId) {
  if (!ownerId) return null;
  await ensureStore(soda);
  return withKey(await soda.findOne(C.operators, { ownerId }));
}
async function operatorByInviteCode(soda, code) {
  if (!isInviteCode(code)) return null;
  await ensureStore(soda);
  const op = withKey(await soda.findOne(C.operators, { inviteCode: code }));
  return op && op.inviteLinkOn !== false ? op : null;
}
async function operatorOfCrew(soda, crewId) {
  await ensureStore(soda);
  return withKey(await soda.findOne(C.operators, { crewId }));
}
async function saveOperator(soda, op) {
  const next = { ...stripKey(op), updatedAt: Date.now() };
  await soda.replace(C.operators, op.key, next);
  return { ...next, key: op.key };
}
async function listOperators(soda, { status = '', type = '', q = '', limit = 500 } = {}) {
  await ensureStore(soda);
  const filter = {};
  if (status && STATUS[status]) filter.status = status;
  if (type && TYPES[type]) filter.type = type;
  let rows = (await soda.query(C.operators, filter, { limit: 5000 })).map(withKey);
  const s = String(q || '').trim().toLowerCase();
  if (s) rows = rows.filter((o) => `${o.name} ${o.city} ${o.contact && o.contact.email}`.toLowerCase().includes(s));
  return rows.sort((a, b) => b.createdAt - a.createdAt).slice(0, limit);
}

/** Effective status now: an APPROVED operator past its validity reads EXPIRED. */
function effectiveStatus(op, now = Date.now()) {
  if (!op) return null;
  if (op.status === STATUS.APPROVED && Number(op.validUntil) > 0 && Number(op.validUntil) <= now) return 'EXPIRED';
  return op.status;
}

/** A rider applies (or re-applies after a rejection). */
async function apply(soda, userId, body, now = Date.now()) {
  await ensureStore(soda);
  const v = validateApplication(body);
  const existing = await operatorOfOwner(soda, userId);
  if (existing && existing.status !== STATUS.REJECTED) {
    bad(existing.status === STATUS.PENDING ? 'Your application is waiting for review.' : 'You already run an operator account.', 'ALREADY_APPLIED', 409);
  }
  const doc = {
    operatorId: existing ? existing.operatorId : `op_${hex(8)}`, ownerId: userId, ...v,
    status: STATUS.PENDING, reason: '', limits: null, features: null, validFrom: 0, validUntil: 0,
    crewId: existing ? existing.crewId || null : null, coOrganisers: [], inviteCode: null, inviteLinkOn: false,
    createdAt: now, updatedAt: now, decidedAt: 0, decidedBy: null,
    history: [...((existing && existing.history) || []), { at: now, action: existing ? 'REAPPLIED' : 'APPLIED' }].slice(-50),
  };
  if (existing) {
    await soda.replace(C.operators, existing.key, doc);
    return { ...doc, key: existing.key };
  }
  doc.key = await soda.insert(C.operators, doc);
  return doc;
}

/** Crew name (3-40 characters) from an organisation name. */
function crewNameOf(name) {
  let n = clean(name, 40);
  if (n.length < 3) n = `${n} Club`.trim();
  const v = CR.validateCrewName(n);
  return v.ok ? v.value : 'CoRoute Club';
}

/**
 * The club crew of an approved operator (created once, owner as crew ADMIN). Written directly (not
 * through createCrew): an operator's club does not count against the owner's personal crew limits.
 */
async function ensureClubCrew(soda, op, now = Date.now()) {
  await CR.ensureCrewStore(soda);
  const club = { operatorId: op.operatorId, type: op.type, maxMembers: (op.limits && op.limits.maxMembers) || 100 };
  if (op.crewId) {
    const crew = await CR.getCrew(soda, op.crewId);
    if (crew) {
      await soda.replace(CR.COLLECTIONS.crews, crew.key, { ...stripKey(crew), club, updatedAt: now });
      if (!(await CR.memberOf(soda, crew.crewId, op.ownerId))) {
        await soda.insert(CR.COLLECTIONS.members, { memberKey: `${crew.crewId}|${op.ownerId}`, crewId: crew.crewId, userId: op.ownerId, role: CR.ROLES.ADMIN, joinedAt: now, addedBy: op.ownerId }).catch(() => {});
      }
      return crew.crewId;
    }
  }
  const crewId = `cr_${hex(8)}`;
  await soda.insert(CR.COLLECTIONS.crews, {
    crewId, name: crewNameOf(op.name), description: clean(`${TYPES[op.type]} in ${op.city}. Run in the CoRoute operator console.`, 200),
    adminId: op.ownerId, settings: { membersCanCreatePolls: false }, memberCount: 1, club, createdAt: now, updatedAt: now,
  });
  await soda.insert(CR.COLLECTIONS.members, { memberKey: `${crewId}|${op.ownerId}`, crewId, userId: op.ownerId, role: CR.ROLES.ADMIN, joinedAt: now, addedBy: op.ownerId });
  return crewId;
}

/** Admin decisions. Returns the saved operator. */
async function decide(soda, op, action, { by, reason = '', limits, features, validUntil, validityDays, now = Date.now() } = {}) {
  const why = clean(reason, 300);
  const st = op.status;
  const entry = { at: now, action, by: by || null, reason: why };
  let next = { ...op };
  if (action === 'APPROVE') {
    if (![STATUS.PENDING, STATUS.REJECTED].includes(st)) bad('Only a waiting application can be approved.', 'BAD_STATE', 409);
    const tpl = (await getTemplates(soda)).templates[op.type] || DEFAULT_TEMPLATES[op.type];
    next.limits = cleanLimits(limits || {}, tpl.limits);
    next.features = cleanFeatures(features || {}, tpl.features);
    next.validFrom = now;
    next.validUntil = validUntilOf({ validUntil, validityDays }, tpl.validityDays, now);
    next.status = STATUS.APPROVED;
    next.inviteCode = next.inviteCode || randomCode();
    next.inviteLinkOn = true;
    next.crewId = await ensureClubCrew(soda, next, now);
    entry.limits = next.limits; entry.features = next.features; entry.validUntil = next.validUntil;
  } else if (action === 'REJECT') {
    if (st !== STATUS.PENDING) bad('Only a waiting application can be rejected.', 'BAD_STATE', 409);
    if (why.length < 3) bad('Give a reason (the applicant sees it).', 'REASON_REQUIRED', 422);
    next.status = STATUS.REJECTED;
  } else if (action === 'SUSPEND') {
    if (st !== STATUS.APPROVED) bad('Only an approved operator can be suspended.', 'BAD_STATE', 409);
    if (why.length < 3) bad('Give a reason (the operator sees it).', 'REASON_REQUIRED', 422);
    next.status = STATUS.SUSPENDED;
  } else if (action === 'REINSTATE') {
    if (st !== STATUS.SUSPENDED) bad('Only a suspended operator can be reinstated.', 'BAD_STATE', 409);
    next.status = STATUS.APPROVED;
  } else if (action === 'LIMITS') {
    if (![STATUS.APPROVED, STATUS.SUSPENDED].includes(st)) bad('Limits apply to approved operators.', 'BAD_STATE', 409);
    next.limits = cleanLimits(limits || {}, op.limits || {});
    next.features = cleanFeatures(features || {}, op.features || {});
    if (validUntil !== undefined || validityDays !== undefined) next.validUntil = validUntilOf({ validUntil, validityDays }, 365, now);
    next.crewId = await ensureClubCrew(soda, next, now);
    // Fewer co-organisers allowed than there are: the newest go back to members.
    const co = Array.isArray(next.coOrganisers) ? next.coOrganisers : [];
    if (co.length > next.limits.coOrganisers) {
      const keep = co.slice(0, next.limits.coOrganisers);
      for (const uid of co.slice(next.limits.coOrganisers)) await setCrewRole(soda, next.crewId, uid, CR.ROLES.MEMBER);
      next.coOrganisers = keep;
    }
    entry.limits = next.limits; entry.features = next.features; entry.validUntil = next.validUntil;
  } else {
    bad('Unknown action.', 'BAD_ACTION', 400);
  }
  next.reason = ['REJECT', 'SUSPEND'].includes(action) ? why : (action === 'LIMITS' ? next.reason : '');
  next.decidedAt = now; next.decidedBy = by || null;
  next.history = [...(op.history || []), entry].slice(-50);
  return saveOperator(soda, next);
}

function validUntilOf({ validUntil, validityDays } = {}, defDays, now) {
  const t = Number(validUntil);
  if (Number.isFinite(t) && t > now) return Math.min(t, now + limitBounds().validityDays[1] * DAY);
  const d = clampInt(validityDays ?? defDays, limitBounds().validityDays, 365);
  return now + d * DAY;
}
function randomCode() {
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  let s = '';
  for (let i = 0; i < 10; i++) s += abc[crypto.randomInt(abc.length)];
  return s;
}

// ------------------------------------------------------------------ roles and roster
/** 'OWNER' | 'CO_ORGANISER' | null for a user and an operator. */
function roleIn(op, userId) {
  if (!op || !userId) return null;
  if (op.ownerId === userId) return 'OWNER';
  if (Array.isArray(op.coOrganisers) && op.coOrganisers.includes(userId)) return 'CO_ORGANISER';
  return null;
}
/** Operators a user can open in the console (any status except PENDING / REJECTED). */
async function operatorsFor(soda, userId) {
  await ensureStore(soda);
  const own = await operatorOfOwner(soda, userId);
  // Co-organiser seats: filtered here (array matching differs between SODA and the memory store).
  const co = (await soda.query(C.operators, {}, { limit: 5000 })).map(withKey).filter((o) => Array.isArray(o.coOrganisers) && o.coOrganisers.includes(userId));
  const all = [own, ...co].filter(Boolean).filter((o, i, a) => a.findIndex((x) => x.operatorId === o.operatorId) === i);
  return all.filter((o) => [STATUS.APPROVED, STATUS.SUSPENDED].includes(o.status));
}

async function setCrewRole(soda, crewId, userId, role) {
  const m = await CR.memberOf(soda, crewId, userId);
  if (m && m.role !== CR.ROLES.ADMIN) await CR.setRole(soda, m, role);
}

/** Roster members (crew members) and pending invites. */
async function roster(soda, op, now = Date.now()) {
  if (!op.crewId) return { members: [], invites: [] };
  const members = await CR.membersOf(soda, op.crewId);
  const invites = await CR.liveInvitesOf(soda, op.crewId, now);
  return { members, invites };
}

/**
 * Invites `targetId` to the club crew. Operator invites need no friendship (the rider still has to
 * accept). Members + pending invites stay within maxMembers. Returns { status, invite? }.
 */
async function inviteToRoster(soda, op, inviterId, targetId, now = Date.now()) {
  const crew = await CR.getCrew(soda, op.crewId);
  if (!crew) bad('The club roster is not set up yet.', 'NO_ROSTER', 409);
  if (await CR.memberOf(soda, crew.crewId, targetId)) return { status: 'ALREADY_MEMBER' };
  const inviteKey = `${crew.crewId}|${targetId}`;
  const existing = withKey(await soda.findOne(CR.COLLECTIONS.invites, { inviteKey }));
  if (existing) {
    if (existing.expiresAt > now) return { status: 'ALREADY_INVITED', invite: existing };
    await soda.remove(CR.COLLECTIONS.invites, existing.key);
  }
  const { members, invites } = await roster(soda, op, now);
  if (members.length + invites.length >= op.limits.maxMembers) {
    bad(`Your roster is full (${op.limits.maxMembers} riders, counting invites waiting for an answer).`, 'ROSTER_FULL', 409, { limit: op.limits.maxMembers });
  }
  const invite = { inviteId: `ci_${hex(8)}`, inviteKey, crewId: crew.crewId, userId: targetId, invitedBy: inviterId, createdAt: now, expiresAt: now + CR.LIMITS.INVITE_TTL_MS, club: op.operatorId };
  try { await soda.insert(CR.COLLECTIONS.invites, invite); } catch (e) {
    if (e && e.status === 409) return { status: 'ALREADY_INVITED' };
    throw e;
  }
  return { status: 'INVITED', invite };
}

/** Joins through the club's invite link (the rider chose to). */
async function joinByLink(soda, op, userId, now = Date.now()) {
  const crew = await CR.getCrew(soda, op.crewId);
  if (!crew) bad('This club link no longer works.', 'LINK_GONE', 410);
  if (await CR.memberOf(soda, crew.crewId, userId)) return { status: 'ALREADY_MEMBER', crew };
  const { members, invites } = await roster(soda, op, now);
  const mine = invites.find((i) => i.userId === userId);
  if (members.length + invites.length - (mine ? 1 : 0) >= op.limits.maxMembers) bad('This club is full.', 'ROSTER_FULL', 409);
  if ((await CR.membershipsOf(soda, userId)).length >= CR.LIMITS.MAX_JOINED) {
    bad(`You can be in up to ${CR.LIMITS.MAX_JOINED} crews and clubs. Leave one first.`, 'TOO_MANY_CREWS', 409);
  }
  await soda.insert(CR.COLLECTIONS.members, { memberKey: `${crew.crewId}|${userId}`, crewId: crew.crewId, userId, role: CR.ROLES.MEMBER, joinedAt: now, addedBy: op.ownerId, via: 'link' }).catch((e) => { if (!(e && e.status === 409)) throw e; });
  if (mine) await soda.remove(CR.COLLECTIONS.invites, mine.key).catch(() => {});
  await CR.syncCount(soda, crew);
  return { status: 'JOINED', crew };
}

// ------------------------------------------------------------------ rides
function istMonth(ms) { return new Date(ms + IST).toISOString().slice(0, 7); }
function slugOf(title) {
  const base = String(title || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 50) || 'ride';
  return `${base.length < 3 ? `${base}-ride` : base}-${hex(3)}`;
}

async function getRide(soda, rideId) {
  if (!isRideId(rideId)) return null;
  await ensureStore(soda);
  return withKey(await soda.findOne(C.rides, { rideId }));
}
async function rideBySlug(soda, slug) {
  if (!isSlug(slug)) return null;
  await ensureStore(soda);
  return withKey(await soda.findOne(C.rides, { slug }));
}
async function rideOfGroup(soda, groupId) {
  if (!groupId) return null;
  await ensureStore(soda);
  return withKey(await soda.findOne(C.rides, { groupId }));
}
async function ridesOf(soda, operatorId) {
  await ensureStore(soda);
  return (await soda.query(C.rides, { operatorId }, { limit: 5000 })).map(withKey).sort((a, b) => (b.startsAt || 0) - (a.startsAt || 0));
}
async function saveRide(soda, ride) {
  const next = { ...stripKey(ride), updatedAt: Date.now() };
  await soda.replace(C.rides, ride.key, next);
  return { ...next, key: ride.key };
}

/** Rides counted against the month of `at` (cancelled ones do not count). */
async function ridesInMonth(soda, operatorId, at) {
  const m = istMonth(at);
  return (await ridesOf(soda, operatorId)).filter((r) => r.month === m && r.status !== RIDE_STATUS.CANCELLED).length;
}

/** Clean ride fields from the console (create or edit). */
function validateRide(b = {}, op, { now = Date.now(), partial = false } = {}) {
  const fields = {};
  const out = {};
  if (!partial || b.title !== undefined) {
    out.title = clean(b.title, 80);
    if (out.title.length < 3) fields.title = 'Ride name: 3 to 80 characters.';
  }
  if (!partial || b.startsAt !== undefined) {
    const t = Number(b.startsAt);
    if (!Number.isFinite(t) || t < now - 6 * 3600000 || t > now + 366 * DAY) fields.startsAt = 'Pick a start date and time within the next year.';
    else out.startsAt = Math.floor(t);
  }
  for (const [k, max] of [['meetName', 120], ['destinationName', 120], ['notes', 500]]) {
    if (!partial || b[k] !== undefined) out[k] = clean(b[k], max);
  }
  if (out.notes && CONTACT_IN_TEXT.test(out.notes)) fields.notes = 'Keep phone numbers and e-mail addresses out of the public notes.';
  if (!partial || b.maxRiders !== undefined) {
    const lim = op.limits.maxRidersPerRide;
    const n = Math.floor(Number(b.maxRiders ?? lim));
    if (!Number.isFinite(n) || n < 2) fields.maxRiders = 'At least 2 riders.';
    else if (n > lim) fields.maxRiders = `Your plan allows up to ${lim} riders per ride.`;
    else out.maxRiders = n;
  }
  if (b.publicSignup !== undefined) out.publicSignup = b.publicSignup === true;
  if (b.requireApproval !== undefined) out.requireApproval = b.requireApproval !== false;
  if (out.publicSignup && !op.features.rideCalendar) fields.publicSignup = 'Public sign-up pages are not part of your plan.';
  if (Object.keys(fields).length) {
    const code = fields.maxRiders && /plan allows/.test(fields.maxRiders) ? 'RIDERS_PER_RIDE_LIMIT' : 'INVALID_RIDE';
    bad(Object.values(fields)[0], code, 422, { fields });
  }
  return out;
}

async function createRide(soda, op, by, fields, now = Date.now()) {
  const used = await ridesInMonth(soda, op.operatorId, fields.startsAt);
  if (used >= op.limits.maxRidesPerMonth) {
    bad(`Your plan allows ${op.limits.maxRidesPerMonth} rides a month; ${istMonth(fields.startsAt)} is full.`, 'RIDES_PER_MONTH_LIMIT', 409, { limit: op.limits.maxRidesPerMonth });
  }
  const ride = {
    rideId: `or_${hex(8)}`, operatorId: op.operatorId, slug: slugOf(fields.title),
    title: fields.title, startsAt: fields.startsAt, month: istMonth(fields.startsAt),
    meetName: fields.meetName || '', destinationName: fields.destinationName || '', notes: fields.notes || '',
    maxRiders: fields.maxRiders, leadUserId: fields.leadUserId || by, sweeperUserId: fields.sweeperUserId || null,
    publicSignup: !!fields.publicSignup, requireApproval: fields.requireApproval !== false, signups: [],
    status: RIDE_STATUS.SCHEDULED, groupId: null, createdBy: by, createdAt: now, updatedAt: now,
    startedAt: 0, endedAt: 0, publishedAt: 0, invited: 0,
  };
  ride.key = await soda.insert(C.rides, ride);
  return ride;
}

/** Live operator rides whose convoy is still running (`isActive(groupId)` decides). */
async function liveRides(soda, operatorId, isActive) {
  const out = [];
  for (const r of await ridesOf(soda, operatorId)) {
    if (r.status !== RIDE_STATUS.LIVE) continue;
    if (await isActive(r.groupId)) out.push(r);
  }
  return out;
}

/** Public sign-up counts. */
function signupCounts(ride) {
  const s = Array.isArray(ride.signups) ? ride.signups : [];
  return {
    approved: s.filter((x) => x.status === 'APPROVED').length,
    pending: s.filter((x) => x.status === 'PENDING').length,
  };
}

/**
 * A rider signs up on the public page. Seats = maxRiders minus the lead, approved sign-ups and,
 * with approval off, every sign-up. Returns the stored sign-up.
 */
async function signUp(soda, ride, userId, now = Date.now()) {
  if (!ride.publicSignup) bad('This ride has no public sign-up.', 'SIGNUP_CLOSED', 404);
  if (![RIDE_STATUS.SCHEDULED, RIDE_STATUS.LIVE].includes(ride.status)) bad('Sign-up for this ride is closed.', 'SIGNUP_CLOSED', 409);
  const list = Array.isArray(ride.signups) ? [...ride.signups] : [];
  const i = list.findIndex((s) => s.userId === userId);
  if (i >= 0 && ['PENDING', 'APPROVED'].includes(list[i].status)) return { ride, signup: list[i], already: true };
  if (i >= 0 && list[i].status === 'REJECTED') bad('The organiser did not approve your sign-up for this ride.', 'SIGNUP_REJECTED', 403);
  const { approved, pending } = signupCounts(ride);
  const seats = Math.max(0, ride.maxRiders - 1 - approved - (ride.requireApproval ? 0 : pending));
  if (seats <= 0) bad('This ride is full.', 'RIDE_FULL', 409);
  // Waiting list capped at 3x the seats so a page cannot be flooded.
  if (ride.requireApproval && pending >= Math.max(10, ride.maxRiders * 3)) bad('This ride has too many sign-ups waiting. Try again later.', 'SIGNUPS_FULL', 409);
  const signup = { userId, status: ride.requireApproval ? 'PENDING' : 'APPROVED', at: now, decidedAt: ride.requireApproval ? 0 : now };
  if (i >= 0) list[i] = signup; else list.push(signup);
  const saved = await saveRide(soda, { ...ride, signups: list });
  return { ride: saved, signup };
}

async function decideSignup(soda, ride, userId, approve, now = Date.now()) {
  const list = Array.isArray(ride.signups) ? [...ride.signups] : [];
  const i = list.findIndex((s) => s.userId === userId);
  if (i < 0 || !['PENDING', 'APPROVED'].includes(list[i].status)) bad('No such sign-up.', 'NOT_FOUND', 404);
  if (approve && list[i].status !== 'APPROVED') {
    const { approved } = signupCounts(ride);
    if (approved >= ride.maxRiders - 1) bad(`This ride is full (${ride.maxRiders} riders with the lead).`, 'RIDE_FULL', 409);
  }
  list[i] = { ...list[i], status: approve ? 'APPROVED' : 'REJECTED', decidedAt: now };
  return saveRide(soda, { ...ride, signups: list });
}

async function cancelSignup(soda, ride, userId, now = Date.now()) {
  const list = Array.isArray(ride.signups) ? [...ride.signups] : [];
  const i = list.findIndex((s) => s.userId === userId);
  if (i < 0 || list[i].status === 'REJECTED') return ride;
  list[i] = { ...list[i], status: 'CANCELLED', decidedAt: now };
  return saveRide(soda, { ...ride, signups: list });
}

// ------------------------------------------------------------------ capacity hook
/**
 * Seats of an operator ride (for entitlements / convoys): the ride's maxRiders, never above the
 * operator's riders-per-ride limit nor MAX_CONVOY_RIDERS. null when `groupId` is not an operator
 * ride of an approved (or suspended: a ride already under way is never cut) operator.
 * Personal plans are not consulted for operator rides.
 */
async function operatorCapacity(repo, groupId) {
  const soda = repo && (repo.soda || repo);
  if (!soda || !groupId) return null;
  const ride = await rideOfGroup(soda, groupId).catch(() => null);
  if (!ride) return null;
  const op = await getOperator(soda, ride.operatorId).catch(() => null);
  if (!op || !op.limits) return null;
  const ceiling = Math.max(1, Number(config.maxConvoyRiders) || 1);
  return Math.max(2, Math.min(ride.maxRiders || op.limits.maxRidersPerRide, op.limits.maxRidersPerRide, ceiling));
}

// ------------------------------------------------------------------ broadcasts
const BROADCAST_LIMITS = Object.freeze({ TITLE_MAX: 60, BODY_MAX: 300, PER_DAY: 5 });
async function broadcastsOf(soda, operatorId, limit = 50) {
  await ensureStore(soda);
  return (await soda.query(C.broadcasts, { operatorId }, { limit: 1000 })).map(withKey).sort((a, b) => b.at - a.at).slice(0, limit);
}
async function addBroadcast(soda, doc) {
  await ensureStore(soda);
  return soda.insert(C.broadcasts, doc);
}

// ------------------------------------------------------------------ account erase
/**
 * The rider's application / operator (rides and broadcasts of their own operator go with it; the
 * club crew is deleted by crews.forgetCrewUser as the admin leaves), co-organiser seats, sign-ups.
 */
async function forgetOperatorUser(soda, userId) {
  await ensureStore(soda);
  const own = await operatorOfOwner(soda, userId);
  if (own) {
    await soda.removeWhere(C.rides, { operatorId: own.operatorId });
    await soda.removeWhere(C.broadcasts, { operatorId: own.operatorId });
    if (own.crewId) await CR.deleteCrew(soda, own.crewId).catch(() => {});
    await soda.remove(C.operators, own.key);
  }
  for (const row of await soda.query(C.operators, {}, { limit: 5000 })) {
    const op = withKey(row);
    if (!Array.isArray(op.coOrganisers) || !op.coOrganisers.includes(userId)) continue;
    await saveOperator(soda, { ...op, coOrganisers: op.coOrganisers.filter((x) => x !== userId) });
  }
  for (const row of await soda.query(C.rides, {}, { limit: 20000 })) {
    const r = withKey(row);
    const touched = (r.signups || []).some((s) => s.userId === userId) || r.leadUserId === userId || r.sweeperUserId === userId;
    if (!touched) continue;
    await saveRide(soda, {
      ...r, signups: (r.signups || []).filter((s) => s.userId !== userId),
      leadUserId: r.leadUserId === userId ? r.createdBy : r.leadUserId, sweeperUserId: r.sweeperUserId === userId ? null : r.sweeperUserId,
    });
  }
}

module.exports = {
  C, COLLECTIONS: C, TYPES, STATUS, RIDE_STATUS, FEATURES, DEFAULT_TEMPLATES, BROADCAST_LIMITS, OperatorError,
  ensureStore, clean, cleanLink, validateApplication, limitBounds, cleanLimits, cleanFeatures, cleanTemplate,
  getTemplates, saveTemplates, getOperator, operatorOfOwner, operatorByInviteCode, operatorOfCrew, saveOperator,
  listOperators, effectiveStatus, apply, decide, ensureClubCrew, roleIn, operatorsFor, setCrewRole, roster,
  inviteToRoster, joinByLink, istMonth, slugOf, getRide, rideBySlug, rideOfGroup, ridesOf, saveRide, ridesInMonth,
  validateRide, createRide, liveRides, signupCounts, signUp, decideSignup, cancelSignup, operatorCapacity,
  broadcastsOf, addBroadcast, forgetOperatorUser, randomCode, isOperatorId, isRideId, isSlug, isInviteCode, CONTACT_IN_TEXT,
};
