'use strict';
/**
 * 3.55 unique public usernames (docs/features_355/usernames_friends_profiles.md).
 *
 * Every account has `username` (shown publicly: friends, leaderboards on the website) and
 * `usernameKey` (its lowercase form). Uniqueness is case-insensitive and enforced by a reservation
 * document per name in the `usernames` collection (unique index on usernameKey): a name belongs to
 * whoever inserted its reservation first, so two nodes can never hand out the same name.
 *
 *  - Allocated automatically, never from the rider's real name: <Adjective><RideWord><3-4 digits>
 *    ("SwiftFalcon482") from the curated word lists below. New accounts get one at registration,
 *    older accounts lazily on sign-in / GET /me and through the idempotent backfill job.
 *  - The rider may pick their own once per 30 days (USERNAME_CHANGE_DAYS); a change of capitals only
 *    is always allowed. Rules: 3-20 of A-Z a-z 0-9 _, starts with a letter, no reserved words
 *    (admin, coroute, support, official ...), no profanity (also with digits for letters), nothing
 *    that looks like a phone number (7+ digits) or an e-mail address / provider.
 *  - `publicLeaderboard` (user doc, default true): the rider can hide their username from the
 *    website leaderboards (read by the scoring module).
 *
 * Exports used by other modules: usernamesFor(repo, userIds) -> Map userId -> username, and
 * ensureUsername(repo, user) -> user with username.
 */
const crypto = require('crypto');

const COLL = 'usernames';
const USERNAME_CHANGE_DAYS = 30;
const CHANGE_MS = USERNAME_CHANGE_DAYS * 86400000;
const USERNAME_RE = /^[A-Za-z][A-Za-z0-9_]{2,19}$/;

// Curated, inoffensive word lists (each word short enough that word+word+4 digits fits in 20).
const ADJECTIVES = Object.freeze([
  'Swift', 'Steady', 'Bold', 'Brave', 'Calm', 'Clever', 'Bright', 'Rapid', 'Silent', 'Smooth',
  'Lucky', 'Noble', 'Sunny', 'Misty', 'Rocky', 'Dusty', 'Golden', 'Silver', 'Amber', 'Azure',
  'Crimson', 'Indigo', 'Jade', 'Coral', 'Frosty', 'Stormy', 'Breezy', 'Cosmic', 'Lunar', 'Solar',
  'Wild', 'Free', 'Keen', 'Mighty', 'Nimble', 'Quick', 'Sharp', 'Zesty', 'Epic', 'Happy',
  'Jolly', 'Merry', 'Plucky', 'Proud', 'Royal', 'Sturdy', 'Trusty', 'Wise', 'Zippy', 'Daring',
]);
const RIDE_WORDS = Object.freeze([
  'Falcon', 'Tiger', 'Throttle', 'Piston', 'Torque', 'Comet', 'Nomad', 'Atlas', 'Gear', 'Clutch',
  'Rider', 'Roamer', 'Ranger', 'Drifter', 'Cruiser', 'Voyager', 'Pilot', 'Racer', 'Tracker', 'Scout',
  'Eagle', 'Hawk', 'Panther', 'Wolf', 'Cheetah', 'Stallion', 'Mustang', 'Bison', 'Lynx', 'Puma',
  'Rocket', 'Thunder', 'Breeze', 'Summit', 'Canyon', 'Ridge', 'Trail', 'Highway', 'Horizon', 'Compass',
  'Spoke', 'Sprocket', 'Chrome', 'Ignition', 'Turbo', 'Kickstand', 'Saddle', 'Visor', 'Lantern', 'Meteor',
]);

const RESERVED = Object.freeze([
  'admin', 'administrator', 'coroute', 'support', 'official', 'moderator', 'mod', 'staff', 'system',
  'root', 'help', 'helpdesk', 'security', 'team', 'service', 'null', 'undefined', 'api', 'owner',
  'devmonks', 'police', 'emergency', 'ambulance', 'sos', 'guardian', 'verified', 'billing', 'payment',
  'razorpay', 'anonymous', 'everyone', 'nobody', 'test', 'webmaster', 'info', 'noreply', 'contact',
]);
// Names that must not appear anywhere in the name (checked after undoing digit-for-letter swaps).
const RESERVED_ANYWHERE = Object.freeze(['admin', 'coroute', 'support', 'official', 'moderator', 'devmonks', 'staff']);
// A deliberately short list of slurs / sexual / abusive words (substring match on a normalised form).
const PROFANITY = Object.freeze([
  'fuck', 'fuk', 'shit', 'bitch', 'cunt', 'dick', 'cock', 'pussy', 'whore', 'slut', 'bastard', 'asshole',
  'nigg', 'fag', 'retard', 'rape', 'porn', 'sex', 'nazi', 'hitler', 'penis', 'vagina', 'boob', 'tits',
  'chutiya', 'chutia', 'bhenchod', 'behenchod', 'madarchod', 'bsdk', 'gandu', 'randi', 'harami', 'kutta',
  'lund', 'loda', 'lauda', 'chod', 'jihad', 'terror', 'suicide',
]);
const EMAILISH = Object.freeze(['gmail', 'yahoo', 'hotmail', 'outlook', 'icloud', 'protonmail', 'rediff', 'mailcom', 'dotcom']);

class UsernameError extends Error {
  constructor(message, code, status = 422, extra = {}) {
    super(message);
    this.name = 'UsernameError';
    this.code = code;
    this.status = status;
    Object.assign(this, extra);
  }
}

const keyOf = (u) => String(u || '').toLowerCase();
const normalise = (s) => keyOf(s).replace(/_/g, '')
  .replace(/0/g, 'o').replace(/1/g, 'i').replace(/3/g, 'e').replace(/4/g, 'a')
  .replace(/5/g, 's').replace(/7/g, 't').replace(/8/g, 'b').replace(/9/g, 'g');

/**
 * Rider-chosen username check (pure). Returns { ok: true, username } or { ok: false, code, message }.
 * Codes: USERNAME_FORMAT, USERNAME_RESERVED, USERNAME_NOT_ALLOWED, USERNAME_CONTACT.
 */
function validateUsername(raw) {
  const u = typeof raw === 'string' ? raw.trim() : '';
  if (!USERNAME_RE.test(u)) {
    return { ok: false, code: 'USERNAME_FORMAT', message: 'Use 3 to 20 letters, numbers or _, starting with a letter.' };
  }
  const k = keyOf(u);
  const n = normalise(u);
  if (RESERVED.includes(k) || RESERVED.includes(k.replace(/_/g, '')) || RESERVED_ANYWHERE.some((w) => n.includes(w))) {
    return { ok: false, code: 'USERNAME_RESERVED', message: 'That username is reserved. Choose another one.' };
  }
  if (PROFANITY.some((w) => n.includes(w) || k.includes(w))) {
    return { ok: false, code: 'USERNAME_NOT_ALLOWED', message: 'That username is not allowed. Choose another one.' };
  }
  if (/\d{7,}/.test(u.replace(/_/g, '')) || (u.match(/\d/g) || []).length > 8 || EMAILISH.some((w) => k.replace(/_/g, '').includes(w))) {
    return { ok: false, code: 'USERNAME_CONTACT', message: 'A username cannot look like a phone number or an e-mail address.' };
  }
  return { ok: true, username: u };
}

/** A random generated candidate: <Adjective><RideWord><3-4 digits>, always valid. */
function generateCandidate(rand = crypto.randomInt) {
  const a = ADJECTIVES[rand(ADJECTIVES.length)];
  const w = RIDE_WORDS[rand(RIDE_WORDS.length)];
  const digits = rand(2) === 0 ? String(100 + rand(900)) : String(1000 + rand(9000));
  return `${a}${w}${digits}`.slice(0, 20);
}

let migrated = new WeakSet();
/** Creates the reservation collection + indexes once per soda instance. */
async function ensureUsernameStore(soda) {
  if (migrated.has(soda)) return;
  await soda.ensureCollection(COLL);
  await soda.ensureIndex(COLL, { name: 'usernames_key_ux', unique: true, fields: [{ path: 'usernameKey' }] });
  await soda.ensureIndex(COLL, { name: 'usernames_user_ix', unique: false, fields: [{ path: 'userId' }] });
  migrated.add(soda);
}

const isConflict = (e) => e && (e.status === 409 || /unique|ORA-00001|duplicate/i.test(String(e.message || '')));

/** Inserts a reservation for `username`; true when it is now ours, false when someone has it. */
async function reserve(soda, username, userId, now = Date.now()) {
  await ensureUsernameStore(soda);
  const usernameKey = keyOf(username);
  const existing = await soda.findOne(COLL, { usernameKey });
  if (existing) return existing.value.userId === userId;
  try {
    await soda.insert(COLL, { usernameKey, username, userId, at: now });
    return true;
  } catch (e) {
    if (!isConflict(e)) throw e;
    const after = await soda.findOne(COLL, { usernameKey });
    return !!after && after.value.userId === userId;
  }
}

async function release(soda, usernameKey, userId) {
  if (!usernameKey) return;
  await ensureUsernameStore(soda);
  await soda.removeWhere(COLL, { usernameKey, userId });
}

/** A fresh generated username reserved for `userId` (retries on collisions). */
async function allocateUsername(repo, userId, { rand, now = Date.now() } = {}) {
  for (let i = 0; i < 40; i++) {
    let candidate = generateCandidate(rand);
    if (i >= 20) candidate = `${candidate.replace(/\d+$/, '')}${10000 + crypto.randomInt(90000)}`.slice(0, 20);
    if (!validateUsername(candidate).ok) continue;
    if (await reserve(repo.soda, candidate, userId, now)) return candidate;
  }
  throw new UsernameError('No username could be allocated. Try again.', 'USERNAME_ALLOCATION', 503);
}

const inflight = new Map(); // userId -> Promise<user> (one allocation per rider per node)

/**
 * The user with a username: allocates and stores one when missing (idempotent; concurrent calls for
 * the same rider share one allocation). Accepts any user document; never throws for a missing key.
 */
async function ensureUsername(repo, user, { now = Date.now() } = {}) {
  if (!user || !user.userId) return user;
  if (user.username && user.usernameKey) return user;
  if (inflight.has(user.userId)) return inflight.get(user.userId);
  const job = (async () => {
    const fresh = user.key ? user : await repo.findUserById(user.userId);
    if (!fresh) return user;
    if (fresh.username && fresh.usernameKey) return { ...user, username: fresh.username, usernameKey: fresh.usernameKey };
    await ensureUsernameStore(repo.soda);
    // A reservation left by an earlier attempt (crash between reserve and save) is reused.
    const prior = await repo.soda.findOne(COLL, { userId: fresh.userId });
    const username = prior ? prior.value.username : await allocateUsername(repo, fresh.userId, { now });
    const patch = { username, usernameKey: keyOf(username), usernameSetAt: now };
    if (typeof fresh.publicLeaderboard !== 'boolean') patch.publicLeaderboard = true;
    await repo.updateUser(fresh.key, patch);
    return { ...user, ...patch };
  })();
  inflight.set(user.userId, job);
  try { return await job; } finally { inflight.delete(user.userId); }
}

/**
 * Rider-initiated change. Throws UsernameError: 422 validation, 409 USERNAME_TAKEN,
 * 429 USERNAME_COOLDOWN (with nextChangeAt). Returns the patched fields.
 */
async function changeUsername(repo, user, desired, { now = Date.now() } = {}) {
  const v = validateUsername(desired);
  if (!v.ok) throw new UsernameError(v.message, v.code, 422);
  const username = v.username;
  const key = keyOf(username);
  const current = user.username ? user : await ensureUsername(repo, user, { now });
  if (current.username === username) return { username, usernameKey: key, usernameChangedAt: Number(current.usernameChangedAt) || 0 };
  const caseOnly = key === current.usernameKey;
  const last = Number(current.usernameChangedAt) || 0;
  if (!caseOnly && last && now - last < CHANGE_MS) {
    throw new UsernameError(`You can change your username once every ${USERNAME_CHANGE_DAYS} days.`, 'USERNAME_COOLDOWN', 429, { nextChangeAt: last + CHANGE_MS });
  }
  if (caseOnly) {
    await repo.soda.findOne(COLL, { usernameKey: key }).then(async (r) => {
      if (r && r.value.userId === user.userId) await repo.soda.replace(COLL, r.key, { ...r.value, username });
    });
    await repo.updateUser(current.key, { username });
    return { username, usernameKey: key, usernameChangedAt: last };
  }
  if (!(await reserve(repo.soda, username, user.userId, now))) {
    throw new UsernameError('That username is taken. Choose another one.', 'USERNAME_TAKEN', 409);
  }
  const patch = { username, usernameKey: key, usernameChangedAt: now, usernameSetAt: now };
  await repo.updateUser(current.key, patch);
  await release(repo.soda, current.usernameKey, user.userId).catch(() => {});
  return patch;
}

/** { available, code?, message? } for GET /users/username-available (the rider's own name counts as available). */
async function usernameAvailability(repo, raw, forUserId = null) {
  const v = validateUsername(raw);
  if (!v.ok) return { available: false, code: v.code, message: v.message };
  await ensureUsernameStore(repo.soda);
  const r = await repo.soda.findOne(COLL, { usernameKey: keyOf(v.username) });
  if (!r || (forUserId && r.value.userId === forUserId)) return { available: true, username: v.username };
  return { available: false, code: 'USERNAME_TAKEN', message: 'That username is taken.' };
}

/** The user document with this username (any capitals), or null. */
async function findUserByUsername(repo, raw) {
  const k = keyOf(typeof raw === 'string' ? raw.trim() : '');
  if (!USERNAME_RE.test(k)) return null;
  await ensureUsernameStore(repo.soda);
  const r = await repo.soda.findOne(COLL, { usernameKey: k });
  if (!r) return null;
  const u = await repo.findUserById(r.value.userId);
  return u && u.usernameKey === k ? u : null;
}

/**
 * Map userId -> username for the given ids (unknown / deleted ids are left out). Riders without a
 * username yet get one allocated now (so leaderboards never show a blank).
 */
async function usernamesFor(repo, userIds) {
  const ids = [...new Set((userIds || []).filter((x) => typeof x === 'string' && x))];
  const out = new Map();
  for (let i = 0; i < ids.length; i += 100) {
    const chunk = ids.slice(i, i + 100);
    const rows = await repo.soda.query('users', { userId: { $in: chunk } }, { limit: chunk.length });
    for (const r of rows) {
      let u = { ...r.value, key: r.key };
      if (!u.username) u = await ensureUsername(repo, u).catch(() => u);
      if (u.username) out.set(u.userId, u.username);
    }
  }
  return out;
}

/** Gives every account without a username one. Idempotent; returns { scanned, allocated }. */
async function backfillUsernames(repo, { logger = console, max = 100000 } = {}) {
  let scanned = 0;
  let allocated = 0;
  let failed = 0;
  for (;;) {
    const rows = await repo.soda.query('users', { usernameKey: { $exists: false } }, { limit: 200 });
    if (!rows.length) break;
    let progressed = 0;
    for (const r of rows) {
      scanned++;
      try {
        const u = await ensureUsername(repo, { ...r.value, key: r.key });
        if (u && u.username) { allocated++; progressed++; }
      } catch (e) {
        failed++;
        logger.warn?.(`[usernames] backfill of one account failed: ${e.message}`);
      }
    }
    if (!progressed || scanned >= max) break;
  }
  if (allocated) logger.info?.(`[usernames] backfill gave ${allocated} account(s) a username`);
  return { scanned, allocated, failed };
}

/** Removes the reservations of an erased account (the name becomes free again). */
async function forgetUsernames(repo, userId) {
  await ensureUsernameStore(repo.soda);
  await repo.soda.removeWhere(COLL, { userId });
}

module.exports = {
  COLL, USERNAME_CHANGE_DAYS, CHANGE_MS, USERNAME_RE, ADJECTIVES, RIDE_WORDS, RESERVED, PROFANITY,
  UsernameError, validateUsername, generateCandidate, allocateUsername, ensureUsername, changeUsername,
  usernameAvailability, findUserByUsername, usernamesFor, backfillUsernames, forgetUsernames, ensureUsernameStore,
  _resetForTests: () => { migrated = new WeakSet(); inflight.clear(); },
};
