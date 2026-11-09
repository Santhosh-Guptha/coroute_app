'use strict';
/**
 * 3.55 Crews: persistent rider crews with polls (docs/features_355/crews_polls.md).
 *
 * A crew is a standing circle of riding friends, separate from a live ride ("group" in the app means
 * the people in a live ride, see docs/UX_NAMING_GUIDE_v3.55.md). Crews have no chat at all: the only
 * thing members can post is a vote in a poll.
 *
 * Storage and rules only; the HTTP layer (views, privacy, pushes, rate limits) lives in crew_routes.js.
 *
 * Collections (own helpers, created on first use):
 *   crews          { crewId, name, description, adminId, settings:{membersCanCreatePolls}, memberCount, createdAt, updatedAt }
 *   crew_members   { memberKey "<crewId>|<userId>", crewId, userId, role: ADMIN|CO_ADMIN|MEMBER, joinedAt, addedBy }
 *   crew_invites   { inviteId, inviteKey "<crewId>|<userId>", crewId, userId, invitedBy, createdAt, expiresAt }
 *   crew_polls     { pollId, crewId, createdBy, question, options:[{id,text}], multi, anonymous, template,
 *                    status: OPEN|CLOSED, createdAt, closesAt, closedAt, closedBy }
 *   crew_votes     { voteKey "<pollId>|<userId>", pollId, crewId, userId, optionIds:[], at, erased? }
 *
 * Rules:
 *   - Any signed-in rider can create a crew (limit MAX_OWNED as admin). The creator is the admin.
 *   - Only the admin and co-admins (up to MAX_CO_ADMINS) can invite, and only riders who are mutual
 *     friends of the person inviting and not blocked either way (also not blocked with the admin).
 *     The friend gets an invitation to accept or decline; it expires after 14 days.
 *   - Friendship is checked when inviting and again when accepting. A member whose friendship with
 *     the inviter ends later stays a member (the admin can remove them).
 *   - The admin can hand the crew to another member. An admin who leaves without choosing hands it
 *     to the oldest co-admin, else the oldest member; the last member leaving deletes the crew.
 */
const crypto = require('crypto');
const F = require('./friends');

const DAY = 86400000;
const C = Object.freeze({ crews: 'crews', members: 'crew_members', invites: 'crew_invites', polls: 'crew_polls', votes: 'crew_votes' });
const LIMITS = Object.freeze({
  NAME_MIN: 3,
  NAME_MAX: 40,
  DESC_MAX: 200,
  MAX_OWNED: 10, // crews one rider can be admin of
  MAX_JOINED: 30, // crews one rider can be a member of (any role)
  MAX_MEMBERS: 100, // members per crew (pending invites count towards it while inviting)
  MAX_CO_ADMINS: 3,
  INVITE_TTL_MS: 14 * DAY,
  INVITE_BATCH: 20,
  POLL_QUESTION_MAX: 120,
  POLL_OPTIONS_MIN: 2,
  POLL_OPTIONS_MAX: 6,
  POLL_OPTION_MAX: 60,
  POLL_DEFAULT_MS: 3 * DAY,
  POLL_MIN_MS: 10 * 60000,
  POLL_MAX_MS: 30 * DAY,
  POLL_KEEP_CLOSED: 50,
  MAX_OPEN_POLLS: 10,
});
const ROLES = Object.freeze({ ADMIN: 'ADMIN', CO_ADMIN: 'CO_ADMIN', MEMBER: 'MEMBER' });
const POLL_TEMPLATES = Object.freeze(['RIDE_DATE_PLACE']);
const CREW_RE = /^cr_[a-f0-9]{16}$/;
const INVITE_RE = /^ci_[a-f0-9]{16}$/;
const POLL_RE = /^po_[a-f0-9]{16}$/;

class CrewError extends Error {
  constructor(message, code, status = 400) { super(message); this.name = 'CrewError'; this.code = code; this.status = status; }
}

let migrated = new WeakSet();
async function ensureCrewStore(soda) {
  if (migrated.has(soda)) return;
  for (const c of Object.values(C)) await soda.ensureCollection(c);
  const idx = (coll, name, fields, unique = false) => soda.ensureIndex(coll, { name, unique, fields: fields.map((path) => ({ path })) });
  await idx(C.crews, 'crews_id_ux', ['crewId'], true);
  await idx(C.crews, 'crews_admin_ix', ['adminId']);
  await idx(C.members, 'crew_members_ux', ['memberKey'], true);
  await idx(C.members, 'crew_members_crew_ix', ['crewId']);
  await idx(C.members, 'crew_members_user_ix', ['userId']);
  await idx(C.invites, 'crew_invites_id_ux', ['inviteId'], true);
  await idx(C.invites, 'crew_invites_key_ux', ['inviteKey'], true);
  await idx(C.invites, 'crew_invites_user_ix', ['userId']);
  await idx(C.invites, 'crew_invites_crew_ix', ['crewId']);
  await idx(C.invites, 'crew_invites_by_ix', ['invitedBy']);
  await idx(C.polls, 'crew_polls_id_ux', ['pollId'], true);
  await idx(C.polls, 'crew_polls_crew_ix', ['crewId']);
  await idx(C.votes, 'crew_votes_ux', ['voteKey'], true);
  await idx(C.votes, 'crew_votes_poll_ix', ['pollId']);
  await idx(C.votes, 'crew_votes_user_ix', ['userId']);
  await idx(C.votes, 'crew_votes_crew_ix', ['crewId']);
  migrated.add(soda);
}

const hex = (n) => crypto.randomBytes(n).toString('hex');
const isCrewId = (v) => typeof v === 'string' && CREW_RE.test(v);
const isInviteId = (v) => typeof v === 'string' && INVITE_RE.test(v);
const isPollId = (v) => typeof v === 'string' && POLL_RE.test(v);
const isConflict = (e) => e && (e.status === 409 || /unique|ORA-00001|duplicate/i.test(String(e.message || '')));
const canManage = (m) => !!m && (m.role === ROLES.ADMIN || m.role === ROLES.CO_ADMIN);
const withKey = (r) => (r ? { ...r.value, key: r.key } : null);
const stripKey = ({ key, ...v }) => v; // eslint-disable-line no-unused-vars

// ------------------------------------------------------------------ text rules
/** Trim, drop control / bidi / zero-width characters and angle brackets, collapse whitespace. */
function cleanText(raw) {
  if (typeof raw !== 'string') return '';
  return raw.normalize('NFC')
    .replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g, ' ')
    .replace(/[<>]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}
const charLen = (s) => [...s].length;
const PROFANITY = (() => { try { return require('./usernames').PROFANITY; } catch { return []; } })();
/** Phone numbers, e-mail addresses and links (no contact details in crew text). */
function looksLikeContact(s) {
  const digits = s.replace(/[\s().-]/g, '');
  return /\d{7,}/.test(digits) || /[^\s@]+@[^\s@]+\.[a-z]{2,}/i.test(s) || /(https?:\/\/|www\.)/i.test(s);
}
/** Never innocent inside a longer word: refused anywhere. */
const STRONG = Object.freeze(['fuck', 'shit', 'bitch', 'cunt', 'whore', 'slut', 'asshole', 'nigg', 'porn',
  'chutiya', 'chutia', 'bhenchod', 'behenchod', 'madarchod', 'bsdk', 'gandu']);
/**
 * Profanity check for crew names, descriptions and polls: STRONG words anywhere, the rest of the
 * username list as whole words (so "Sussex", "Cockpit" or "Kuttanad" are fine).
 */
function hasProfanity(s) {
  const k = s.toLowerCase().replace(/[^a-z0-9]/g, '');
  if (STRONG.some((w) => k.includes(w))) return true;
  const words = s.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  return words.some((w) => PROFANITY.some((p) => w === p || w === `${p}s`));
}

/** { ok, value } or { ok:false, code, message } for a crew name. */
function validateCrewName(raw) {
  const v = cleanText(raw);
  const n = charLen(v);
  if (n < LIMITS.NAME_MIN || n > LIMITS.NAME_MAX || !/[\p{L}\p{N}]/u.test(v)) {
    return { ok: false, code: 'CREW_NAME_FORMAT', message: `A crew name has ${LIMITS.NAME_MIN} to ${LIMITS.NAME_MAX} characters.` };
  }
  if (hasProfanity(v)) return { ok: false, code: 'CREW_NAME_NOT_ALLOWED', message: 'Please choose a different name.' };
  if (looksLikeContact(v)) return { ok: false, code: 'CREW_TEXT_CONTACT', message: 'Crew names cannot have phone numbers, e-mail addresses or links.' };
  return { ok: true, value: v };
}

function validateDescription(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: '' };
  if (typeof raw !== 'string') return { ok: false, code: 'CREW_DESC_FORMAT', message: 'The description must be text.' };
  const v = cleanText(raw);
  if (charLen(v) > LIMITS.DESC_MAX) return { ok: false, code: 'CREW_DESC_FORMAT', message: `The description has up to ${LIMITS.DESC_MAX} characters.` };
  if (v && hasProfanity(v)) return { ok: false, code: 'CREW_DESC_NOT_ALLOWED', message: 'Please change the description.' };
  if (v && looksLikeContact(v)) return { ok: false, code: 'CREW_TEXT_CONTACT', message: 'The description cannot have phone numbers, e-mail addresses or links.' };
  return { ok: true, value: v };
}

const bad = (v) => { throw new CrewError(v.message, v.code, 422); };

/**
 * Checks a new poll. Input: { question, options:[string], multi?, anonymous?, closesAt? (epoch ms)
 * or durationHours?, template? }. Returns the clean poll fields or throws CrewError (422).
 */
function validatePoll(body, now = Date.now()) {
  const b = body && typeof body === 'object' ? body : {};
  const question = cleanText(b.question);
  if (!question || charLen(question) > LIMITS.POLL_QUESTION_MAX) {
    bad({ code: 'POLL_QUESTION', message: `Ask a question of up to ${LIMITS.POLL_QUESTION_MAX} characters.` });
  }
  if (!Array.isArray(b.options) || b.options.length < LIMITS.POLL_OPTIONS_MIN || b.options.length > LIMITS.POLL_OPTIONS_MAX) {
    bad({ code: 'POLL_OPTIONS', message: `A poll has ${LIMITS.POLL_OPTIONS_MIN} to ${LIMITS.POLL_OPTIONS_MAX} options.` });
  }
  const seen = new Set();
  const options = b.options.map((raw, i) => {
    const text = cleanText(typeof raw === 'string' ? raw : (raw && typeof raw.text === 'string' ? raw.text : ''));
    if (!text || charLen(text) > LIMITS.POLL_OPTION_MAX) {
      bad({ code: 'POLL_OPTION_TEXT', message: `Each option has 1 to ${LIMITS.POLL_OPTION_MAX} characters.` });
    }
    const k = text.toLowerCase();
    if (seen.has(k)) bad({ code: 'POLL_OPTION_DUPLICATE', message: 'Two options are the same.' });
    seen.add(k);
    return { id: `o${i + 1}`, text };
  });
  for (const s of [question, ...options.map((o) => o.text)]) {
    if (hasProfanity(s)) bad({ code: 'POLL_NOT_ALLOWED', message: 'Please change the wording.' });
    if (looksLikeContact(s)) bad({ code: 'CREW_TEXT_CONTACT', message: 'Polls cannot have phone numbers, e-mail addresses or links.' });
  }
  let closesAt = now + LIMITS.POLL_DEFAULT_MS;
  if (b.closesAt !== undefined && b.closesAt !== null) {
    closesAt = Number(b.closesAt);
  } else if (b.durationHours !== undefined && b.durationHours !== null) {
    closesAt = now + Number(b.durationHours) * 3600000;
  }
  if (!Number.isFinite(closesAt) || closesAt < now + LIMITS.POLL_MIN_MS || closesAt > now + LIMITS.POLL_MAX_MS) {
    bad({ code: 'POLL_DEADLINE', message: 'The poll can close between 10 minutes and 30 days from now.' });
  }
  const template = POLL_TEMPLATES.includes(b.template) ? b.template : null;
  return { question, options, multi: b.multi === true, anonymous: b.anonymous === true, closesAt: Math.round(closesAt), template };
}

/** Checks a vote against a poll: one option for single choice, 1..n distinct options for multiple. */
function validateVote(poll, optionIds) {
  if (!Array.isArray(optionIds) || optionIds.length === 0) throw new CrewError('Pick an option.', 'VOTE_INVALID', 422);
  const ids = [...new Set(optionIds.map(String))];
  if (ids.length !== optionIds.length) throw new CrewError('Pick each option once.', 'VOTE_INVALID', 422);
  const valid = new Set(poll.options.map((o) => o.id));
  if (ids.some((id) => !valid.has(id))) throw new CrewError('That option is not in this poll.', 'VOTE_INVALID', 422);
  if (!poll.multi && ids.length !== 1) throw new CrewError('This poll takes one answer.', 'VOTE_INVALID', 422);
  return ids;
}

/** True while votes are taken. */
const pollOpen = (poll, now = Date.now()) => poll.status === 'OPEN' && poll.closesAt > now;

/**
 * Results: { totalVoters, options:[{id, text, count, percent}], leaders:[id] }. percent is of the
 * voters (multiple choice can add up to more than 100), rounded to whole numbers.
 */
function tally(poll, votes) {
  const counts = new Map(poll.options.map((o) => [o.id, 0]));
  let voters = 0;
  for (const v of votes || []) {
    const ids = Array.isArray(v.optionIds) ? v.optionIds.filter((id) => counts.has(id)) : [];
    if (!ids.length) continue;
    voters++;
    for (const id of new Set(ids)) counts.set(id, counts.get(id) + 1);
  }
  const max = Math.max(0, ...counts.values());
  return {
    totalVoters: voters,
    options: poll.options.map((o) => ({ id: o.id, text: o.text, count: counts.get(o.id), percent: voters ? Math.round((counts.get(o.id) / voters) * 100) : 0 })),
    leaders: max > 0 ? poll.options.filter((o) => counts.get(o.id) === max).map((o) => o.id) : [],
  };
}

// ------------------------------------------------------------------ crews
async function getCrew(soda, crewId) {
  if (!isCrewId(crewId)) return null;
  await ensureCrewStore(soda);
  return withKey(await soda.findOne(C.crews, { crewId }));
}

async function memberOf(soda, crewId, userId) {
  if (!crewId || !userId) return null;
  await ensureCrewStore(soda);
  return withKey(await soda.findOne(C.members, { memberKey: `${crewId}|${userId}` }));
}

/** Members, oldest first. */
async function membersOf(soda, crewId) {
  await ensureCrewStore(soda);
  const rows = (await soda.query(C.members, { crewId }, { limit: LIMITS.MAX_MEMBERS + 50 })).map(withKey);
  return rows.sort((a, b) => a.joinedAt - b.joinedAt || (a.userId < b.userId ? -1 : 1));
}

async function membershipsOf(soda, userId) {
  await ensureCrewStore(soda);
  return (await soda.query(C.members, { userId }, { limit: 500 })).map(withKey);
}

async function liveInvitesOf(soda, crewId, now = Date.now()) {
  await ensureCrewStore(soda);
  const rows = (await soda.query(C.invites, { crewId }, { limit: 500 })).map(withKey);
  const live = [];
  for (const r of rows) {
    if (r.expiresAt <= now) await soda.remove(C.invites, r.key); else live.push(r);
  }
  return live;
}

async function syncCount(soda, crew) {
  const fresh = await getCrew(soda, crew.crewId);
  if (!fresh) return null;
  const n = (await membersOf(soda, crew.crewId)).length;
  const next = { ...stripKey(fresh), memberCount: n, updatedAt: Date.now() };
  await soda.replace(C.crews, fresh.key, next);
  return { ...next, key: fresh.key };
}

async function createCrew(soda, adminId, { name, description } = {}, now = Date.now()) {
  await ensureCrewStore(soda);
  const n = validateCrewName(name);
  if (!n.ok) bad(n);
  const d = validateDescription(description);
  if (!d.ok) bad(d);
  const owned = await soda.query(C.crews, { adminId }, { limit: LIMITS.MAX_OWNED + 1 });
  if (owned.length >= LIMITS.MAX_OWNED) throw new CrewError(`You can run up to ${LIMITS.MAX_OWNED} crews.`, 'CREW_LIMIT', 409);
  const joined = await membershipsOf(soda, adminId);
  if (joined.length >= LIMITS.MAX_JOINED) throw new CrewError(`You can be in up to ${LIMITS.MAX_JOINED} crews.`, 'TOO_MANY_CREWS', 409);
  const crew = {
    crewId: `cr_${hex(8)}`, name: n.value, description: d.value, adminId,
    settings: { membersCanCreatePolls: false }, memberCount: 1, createdAt: now, updatedAt: now,
  };
  crew.key = await soda.insert(C.crews, stripKey(crew));
  await soda.insert(C.members, { memberKey: `${crew.crewId}|${adminId}`, crewId: crew.crewId, userId: adminId, role: ROLES.ADMIN, joinedAt: now, addedBy: adminId });
  return crew;
}

/** Admin edits: name, description, membersCanCreatePolls. */
async function updateCrew(soda, crew, patch = {}) {
  const next = { ...stripKey(crew), settings: { ...(crew.settings || {}) }, updatedAt: Date.now() };
  if (patch.name !== undefined) { const n = validateCrewName(patch.name); if (!n.ok) bad(n); next.name = n.value; }
  if (patch.description !== undefined) { const d = validateDescription(patch.description); if (!d.ok) bad(d); next.description = d.value; }
  if (patch.membersCanCreatePolls !== undefined) {
    if (typeof patch.membersCanCreatePolls !== 'boolean') throw new CrewError('membersCanCreatePolls must be on or off.', 'BAD_REQUEST', 400);
    next.settings.membersCanCreatePolls = patch.membersCanCreatePolls;
  }
  await soda.replace(C.crews, crew.key, next);
  return { ...next, key: crew.key };
}

async function deleteCrew(soda, crewId) {
  await ensureCrewStore(soda);
  await soda.removeWhere(C.votes, { crewId });
  await soda.removeWhere(C.polls, { crewId });
  await soda.removeWhere(C.invites, { crewId });
  await soda.removeWhere(C.members, { crewId });
  await soda.removeWhere(C.crews, { crewId });
}

// ------------------------------------------------------------------ invites
/**
 * `inviter` (a manager of `crew`) invites `targetId`. Returns { status } with status
 * INVITED | ALREADY_INVITED | ALREADY_MEMBER | REFUSED. REFUSED covers "not a friend", blocked either
 * way (with the inviter or the admin) and unknown riders alike (the caller answers them the same).
 * Throws CrewError CREW_FULL when members + pending invites reach MAX_MEMBERS.
 */
async function inviteToCrew(soda, crew, inviter, targetId, now = Date.now()) {
  await ensureCrewStore(soda);
  if (!targetId) return { status: 'REFUSED' };
  if (await memberOf(soda, crew.crewId, targetId)) return { status: 'ALREADY_MEMBER' };
  if (!(await F.areFriends(soda, inviter.userId, targetId))) return { status: 'REFUSED' };
  if (await F.blockedEither(soda, inviter.userId, targetId)) return { status: 'REFUSED' };
  if (crew.adminId !== inviter.userId && await F.blockedEither(soda, crew.adminId, targetId)) return { status: 'REFUSED' };
  const inviteKey = `${crew.crewId}|${targetId}`;
  const existing = withKey(await soda.findOne(C.invites, { inviteKey }));
  if (existing) {
    if (existing.expiresAt > now) return { status: 'ALREADY_INVITED', invite: existing };
    await soda.remove(C.invites, existing.key);
  }
  const members = (await membersOf(soda, crew.crewId)).length;
  const pending = (await liveInvitesOf(soda, crew.crewId, now)).length;
  if (members + pending >= LIMITS.MAX_MEMBERS) {
    throw new CrewError(`A crew has up to ${LIMITS.MAX_MEMBERS} riders, counting invites waiting for an answer.`, 'CREW_FULL', 409);
  }
  const invite = { inviteId: `ci_${hex(8)}`, inviteKey, crewId: crew.crewId, userId: targetId, invitedBy: inviter.userId, createdAt: now, expiresAt: now + LIMITS.INVITE_TTL_MS };
  try {
    invite.key = await soda.insert(C.invites, invite);
  } catch (e) {
    if (!isConflict(e)) throw e;
    return { status: 'ALREADY_INVITED' };
  }
  return { status: 'INVITED', invite };
}

/** Live (not expired) invites addressed to `userId`; expired ones are dropped. */
async function invitesFor(soda, userId, now = Date.now()) {
  await ensureCrewStore(soda);
  const rows = (await soda.query(C.invites, { userId }, { limit: 500 })).map(withKey);
  const live = [];
  for (const r of rows) {
    if (r.expiresAt <= now) await soda.remove(C.invites, r.key); else live.push(r);
  }
  return live;
}

/**
 * The invitee answers. Returns { status: 'JOINED' | 'DECLINED', crew } or null when there is no such
 * invite for this rider. Throws INVITE_EXPIRED (410), INVITE_GONE (410: the inviter is no longer a
 * friend or member, or someone is blocked), CREW_FULL (409), TOO_MANY_CREWS (409).
 */
async function respondInvite(soda, userId, inviteId, yes, now = Date.now()) {
  if (!isInviteId(inviteId)) return null;
  await ensureCrewStore(soda);
  const inv = withKey(await soda.findOne(C.invites, { inviteId }));
  if (!inv || inv.userId !== userId) return null;
  if (inv.expiresAt <= now) {
    await soda.remove(C.invites, inv.key);
    throw new CrewError('This invite has expired. Ask for a new one.', 'INVITE_EXPIRED', 410);
  }
  if (!yes) {
    await soda.remove(C.invites, inv.key);
    return { status: 'DECLINED' };
  }
  const crew = await getCrew(soda, inv.crewId);
  if (!crew) { await soda.remove(C.invites, inv.key); return null; }
  if (await memberOf(soda, crew.crewId, userId)) {
    await soda.remove(C.invites, inv.key);
    return { status: 'JOINED', crew };
  }
  const inviter = await memberOf(soda, crew.crewId, inv.invitedBy);
  const stillOk = inviter
    && await F.areFriends(soda, userId, inv.invitedBy)
    && !(await F.blockedEither(soda, userId, inv.invitedBy))
    && !(await F.blockedEither(soda, userId, crew.adminId));
  if (!stillOk) {
    await soda.remove(C.invites, inv.key);
    throw new CrewError('This invite is no longer valid.', 'INVITE_GONE', 410);
  }
  if ((await membersOf(soda, crew.crewId)).length >= LIMITS.MAX_MEMBERS) {
    throw new CrewError(`This crew is full (${LIMITS.MAX_MEMBERS} riders).`, 'CREW_FULL', 409);
  }
  if ((await membershipsOf(soda, userId)).length >= LIMITS.MAX_JOINED) {
    throw new CrewError(`You can be in up to ${LIMITS.MAX_JOINED} crews. Leave one first.`, 'TOO_MANY_CREWS', 409);
  }
  try {
    await soda.insert(C.members, { memberKey: `${crew.crewId}|${userId}`, crewId: crew.crewId, userId, role: ROLES.MEMBER, joinedAt: now, addedBy: inv.invitedBy });
  } catch (e) { if (!isConflict(e)) throw e; }
  await soda.remove(C.invites, inv.key);
  return { status: 'JOINED', crew: await syncCount(soda, crew) };
}

/** A manager takes back a pending invite. True when removed. */
async function cancelInvite(soda, crewId, inviteId) {
  if (!isInviteId(inviteId)) return false;
  await ensureCrewStore(soda);
  const inv = withKey(await soda.findOne(C.invites, { inviteId }));
  if (!inv || inv.crewId !== crewId) return false;
  await soda.remove(C.invites, inv.key);
  return true;
}

// ------------------------------------------------------------------ roles and leaving
async function setRole(soda, member, role) {
  const next = { ...stripKey(member), role };
  await soda.replace(C.members, member.key, next);
  return { ...next, key: member.key };
}

/** Admin promotes a member to co-admin or back. Throws CO_ADMIN_LIMIT, NOT_ALLOWED. */
async function changeRole(soda, crew, target, role) {
  if (![ROLES.CO_ADMIN, ROLES.MEMBER].includes(role)) throw new CrewError('Role must be CO_ADMIN or MEMBER.', 'BAD_REQUEST', 400);
  if (target.role === ROLES.ADMIN) throw new CrewError('Hand the crew to someone else first.', 'NOT_ALLOWED', 409);
  if (target.role === role) return target;
  if (role === ROLES.CO_ADMIN) {
    const co = (await membersOf(soda, crew.crewId)).filter((m) => m.role === ROLES.CO_ADMIN).length;
    if (co >= LIMITS.MAX_CO_ADMINS) throw new CrewError(`A crew has up to ${LIMITS.MAX_CO_ADMINS} co-admins.`, 'CO_ADMIN_LIMIT', 409);
  }
  return setRole(soda, target, role);
}

/** Makes `newAdmin` (a member) the admin; the old admin (if still a member) becomes co-admin when a slot is free, else member. */
async function transferAdmin(soda, crew, newAdmin) {
  const members = await membersOf(soda, crew.crewId);
  const old = members.find((m) => m.role === ROLES.ADMIN && m.userId !== newAdmin.userId);
  await setRole(soda, newAdmin, ROLES.ADMIN);
  if (old) {
    const co = members.filter((m) => m.role === ROLES.CO_ADMIN && m.userId !== newAdmin.userId).length;
    await setRole(soda, old, co < LIMITS.MAX_CO_ADMINS ? ROLES.CO_ADMIN : ROLES.MEMBER);
  }
  const fresh = await getCrew(soda, crew.crewId);
  const next = { ...stripKey(fresh), adminId: newAdmin.userId, updatedAt: Date.now() };
  await soda.replace(C.crews, fresh.key, next);
  return { ...next, key: fresh.key };
}

/** Who takes over when the admin goes: the oldest co-admin, else the oldest member (or null). */
function successorOf(members, leavingId) {
  const rest = members.filter((m) => m.userId !== leavingId);
  return rest.find((m) => m.role === ROLES.CO_ADMIN) || rest[0] || null;
}

/**
 * `userId` leaves (or is dropped from) the crew. An admin hands over to `transferTo` (a member's
 * userId) or the successor; the last member leaving deletes the crew.
 * Returns { left, deleted, newAdminId }.
 */
async function leaveCrew(soda, crew, userId, { transferTo = null } = {}) {
  const members = await membersOf(soda, crew.crewId);
  const me = members.find((m) => m.userId === userId);
  if (!me) return { left: false, deleted: false, newAdminId: null };
  let newAdminId = null;
  if (me.role === ROLES.ADMIN) {
    if (members.length === 1) {
      await deleteCrew(soda, crew.crewId);
      return { left: true, deleted: true, newAdminId: null };
    }
    let next = null;
    if (transferTo) {
      next = members.find((m) => m.userId === transferTo && m.userId !== userId);
      if (!next) throw new CrewError('Pick a member of this crew.', 'NOT_A_MEMBER', 422);
    } else {
      next = successorOf(members, userId);
    }
    await soda.remove(C.members, me.key);
    await transferAdmin(soda, crew, next);
    newAdminId = next.userId;
  } else {
    await soda.remove(C.members, me.key);
  }
  await syncCount(soda, crew);
  return { left: true, deleted: false, newAdminId };
}

// ------------------------------------------------------------------ polls
async function getPoll(soda, crewId, pollId) {
  if (!isPollId(pollId)) return null;
  await ensureCrewStore(soda);
  const p = withKey(await soda.findOne(C.polls, { pollId }));
  return p && p.crewId === crewId ? p : null;
}

async function settlePoll(soda, poll, now = Date.now()) {
  if (poll.status === 'OPEN' && poll.closesAt <= now) {
    const next = { ...stripKey(poll), status: 'CLOSED', closedAt: poll.closesAt, closedBy: null };
    await soda.replace(C.polls, poll.key, next);
    return { ...next, key: poll.key, justClosed: true };
  }
  return poll;
}

/** Keeps the newest POLL_KEEP_CLOSED closed polls of a crew. */
async function pruneClosed(soda, crewId) {
  const closed = (await soda.query(C.polls, { crewId, status: 'CLOSED' }, { limit: 1000 })).map(withKey)
    .sort((a, b) => (b.closedAt || 0) - (a.closedAt || 0));
  for (const p of closed.slice(LIMITS.POLL_KEEP_CLOSED)) {
    await soda.removeWhere(C.votes, { pollId: p.pollId });
    await soda.remove(C.polls, p.key);
  }
}

/** Polls of a crew, newest first (expired ones are closed on the way). */
async function pollsOf(soda, crewId, now = Date.now()) {
  await ensureCrewStore(soda);
  const rows = (await soda.query(C.polls, { crewId }, { limit: 1000 })).map(withKey);
  let closedAny = false;
  const out = [];
  for (const r of rows) {
    const p = await settlePoll(soda, r, now);
    if (p.justClosed) closedAny = true;
    out.push(p);
  }
  if (closedAny) await pruneClosed(soda, crewId);
  const live = closedAny ? (await soda.query(C.polls, { crewId }, { limit: 1000 })).map(withKey) : out;
  return live.sort((a, b) => b.createdAt - a.createdAt);
}

const canCreatePoll = (crew, member) => canManage(member) || (!!member && !!(crew.settings && crew.settings.membersCanCreatePolls));

async function createPoll(soda, crew, member, body, now = Date.now()) {
  if (!canCreatePoll(crew, member)) throw new CrewError('Only the crew admin and co-admins can start polls in this crew.', 'NOT_ALLOWED', 403);
  const clean = validatePoll(body, now);
  const open = (await pollsOf(soda, crew.crewId, now)).filter((p) => pollOpen(p, now)).length;
  if (open >= LIMITS.MAX_OPEN_POLLS) throw new CrewError(`A crew can have up to ${LIMITS.MAX_OPEN_POLLS} open polls. Close one first.`, 'TOO_MANY_OPEN_POLLS', 409);
  const poll = { pollId: `po_${hex(8)}`, crewId: crew.crewId, createdBy: member.userId, ...clean, status: 'OPEN', createdAt: now, closedAt: 0, closedBy: null };
  poll.key = await soda.insert(C.polls, stripKey(poll));
  return poll;
}

async function votesOf(soda, pollId) {
  await ensureCrewStore(soda);
  return (await soda.query(C.votes, { pollId }, { limit: LIMITS.MAX_MEMBERS * 3 })).map(withKey);
}

/** Casts or changes `userId`'s vote. Throws POLL_CLOSED (409) or VOTE_INVALID (422). */
async function castVote(soda, poll, userId, optionIds, now = Date.now()) {
  const p = await settlePoll(soda, poll, now);
  if (!pollOpen(p, now)) throw new CrewError('This poll is closed.', 'POLL_CLOSED', 409);
  const ids = validateVote(p, optionIds);
  const voteKey = `${p.pollId}|${userId}`;
  const doc = { voteKey, pollId: p.pollId, crewId: p.crewId, userId, optionIds: ids, at: now };
  await soda.upsertBy(C.votes, { voteKey }, doc);
  return doc;
}

async function retractVote(soda, poll, userId, now = Date.now()) {
  const p = await settlePoll(soda, poll, now);
  if (!pollOpen(p, now)) throw new CrewError('This poll is closed.', 'POLL_CLOSED', 409);
  return (await soda.removeWhere(C.votes, { voteKey: `${p.pollId}|${userId}` })) > 0;
}

const canModeratePoll = (poll, member) => !!member && (poll.createdBy === member.userId || canManage(member));

async function closePoll(soda, poll, byId, now = Date.now()) {
  const p = await settlePoll(soda, poll, now);
  if (p.status === 'CLOSED') return p;
  const next = { ...stripKey(p), status: 'CLOSED', closedAt: now, closedBy: byId };
  await soda.replace(C.polls, p.key, next);
  await pruneClosed(soda, p.crewId);
  return { ...next, key: p.key };
}

async function deletePoll(soda, poll) {
  await soda.removeWhere(C.votes, { pollId: poll.pollId });
  await soda.remove(C.polls, poll.key);
}

// ------------------------------------------------------------------ account erase
/**
 * Erased account: crews it runs are handed to the successor (or deleted when it was alone), its
 * memberships and invites (sent and received) go, votes in open polls are removed and votes in
 * closed polls are kept as anonymous counts. Polls it created stay, with no creator.
 */
async function forgetCrewUser(soda, userId) {
  await ensureCrewStore(soda);
  for (const m of await membershipsOf(soda, userId)) {
    const crew = await getCrew(soda, m.crewId);
    if (!crew) { await soda.remove(C.members, m.key); continue; }
    await leaveCrew(soda, crew, userId);
  }
  await soda.removeWhere(C.invites, { userId });
  await soda.removeWhere(C.invites, { invitedBy: userId });
  const votes = (await soda.query(C.votes, { userId }, { limit: 5000 })).map(withKey);
  for (const v of votes) {
    const p = withKey(await soda.findOne(C.polls, { pollId: v.pollId }));
    if (!p || pollOpen(p)) { await soda.remove(C.votes, v.key); continue; }
    const anon = `erased_${hex(8)}`;
    await soda.replace(C.votes, v.key, { ...stripKey(v), userId: anon, voteKey: `${v.pollId}|${anon}`, erased: true });
  }
  const polls = (await soda.query(C.polls, { createdBy: userId }, { limit: 5000 })).map(withKey);
  for (const p of polls) await soda.replace(C.polls, p.key, { ...stripKey(p), createdBy: null });
}

module.exports = {
  COLLECTIONS: C, LIMITS, ROLES, POLL_TEMPLATES, CrewError, ensureCrewStore,
  isCrewId, isInviteId, isPollId, canManage, canCreatePoll, canModeratePoll,
  cleanText, validateCrewName, validateDescription, validatePoll, validateVote, pollOpen, tally,
  getCrew, memberOf, membersOf, membershipsOf, liveInvitesOf, createCrew, updateCrew, deleteCrew,
  inviteToCrew, invitesFor, respondInvite, cancelInvite, changeRole, transferAdmin, successorOf, leaveCrew,
  getPoll, pollsOf, createPoll, votesOf, castVote, retractVote, closePoll, deletePoll, forgetCrewUser,
  _resetForTests: () => { migrated = new WeakSet(); },
};
