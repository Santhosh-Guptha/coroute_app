'use strict';
/**
 * 3.55 friends (docs/features_355/usernames_friends_profiles.md): the friend graph, personal invite
 * codes and blocks. Storage only; the HTTP rules live in social_routes.js.
 *
 * Collections (own helpers, created on first use):
 *   friend_edges   one per pair of riders       unique: pairKey ("<a>|<b>", ids sorted), requestId
 *                  { requestId, pairKey, a, b, from, to, status: PENDING|ACCEPTED, shadow?, createdAt, respondedAt }
 *   user_blocks    one per blocker -> blocked   unique: blockKey ("<blocker>|<blocked>")
 *   invite_codes   one per rider                unique: code, userId
 *
 * Mutual approval: a request is PENDING until the other rider accepts (ACCEPTED) or declines (the
 * edge is removed). A request to a rider who sent me one is an acceptance. No user enumeration: a
 * request to a rider who blocked me is stored as a `shadow` edge the requester sees as "pending"
 * forever and the target never sees, so it looks exactly like an unanswered request; a request to an
 * unknown username answers the same way (social_routes.js).
 */
const crypto = require('crypto');

const C = Object.freeze({ edges: 'friend_edges', blocks: 'user_blocks', invites: 'invite_codes' });
const MAX_FRIENDS = 500;
const MAX_PENDING_OUT = 50;
const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const INVITE_RE = /^[A-HJ-NP-Z2-9]{8}$/;
const REQUEST_RE = /^fr_[a-f0-9]{20}$/;

class FriendError extends Error {
  constructor(message, code, status = 400) { super(message); this.name = 'FriendError'; this.code = code; this.status = status; }
}

let migrated = new WeakSet();
async function ensureFriendStore(soda) {
  if (migrated.has(soda)) return;
  for (const c of Object.values(C)) await soda.ensureCollection(c);
  const idx = (coll, name, fields, unique = false) => soda.ensureIndex(coll, { name, unique, fields: fields.map((path) => ({ path })) });
  await idx(C.edges, 'friend_edges_pair_ux', ['pairKey'], true);
  await idx(C.edges, 'friend_edges_req_ux', ['requestId'], true);
  await idx(C.edges, 'friend_edges_a_ix', ['a']);
  await idx(C.edges, 'friend_edges_b_ix', ['b']);
  await idx(C.blocks, 'user_blocks_ux', ['blockKey'], true);
  await idx(C.blocks, 'user_blocks_blocker_ix', ['blocker']);
  await idx(C.blocks, 'user_blocks_blocked_ix', ['blocked']);
  await idx(C.invites, 'invite_codes_code_ux', ['code'], true);
  await idx(C.invites, 'invite_codes_user_ux', ['userId'], true);
  migrated.add(soda);
}

const pairOf = (x, y) => (x < y ? [x, y] : [y, x]);
const pairKeyOf = (x, y) => pairOf(x, y).join('|');
const newRequestId = () => `fr_${crypto.randomBytes(10).toString('hex')}`;
const isRequestId = (v) => typeof v === 'string' && REQUEST_RE.test(v);
const isInviteCode = (v) => typeof v === 'string' && INVITE_RE.test(v);
const normaliseInvite = (v) => String(v || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
const isConflict = (e) => e && (e.status === 409 || /unique|ORA-00001|duplicate/i.test(String(e.message || '')));

function newInviteCode() {
  let s = '';
  for (let i = 0; i < 8; i++) s += INVITE_ALPHABET[crypto.randomInt(INVITE_ALPHABET.length)];
  return s;
}

// ---------------------------------------------------------------- invite codes
/** The rider's personal invite code (created on first use, stable afterwards). */
async function inviteCodeOf(soda, userId) {
  await ensureFriendStore(soda);
  const r = await soda.findOne(C.invites, { userId });
  if (r) return r.value.code;
  for (let i = 0; i < 20; i++) {
    const code = newInviteCode();
    try {
      await soda.insert(C.invites, { code, userId, at: Date.now() });
      return code;
    } catch (e) {
      if (!isConflict(e)) throw e;
      const mine = await soda.findOne(C.invites, { userId });
      if (mine) return mine.value.code; // a parallel call created it
    }
  }
  throw new FriendError('No invite code could be created. Try again.', 'INVITE_UNAVAILABLE', 503);
}

/** userId owning an invite code, or null. */
async function userIdByInviteCode(soda, raw) {
  const code = normaliseInvite(raw);
  if (!isInviteCode(code)) return null;
  await ensureFriendStore(soda);
  const r = await soda.findOne(C.invites, { code });
  return r ? r.value.userId : null;
}

// ---------------------------------------------------------------- blocks
async function hasBlocked(soda, blocker, blocked) {
  if (!blocker || !blocked) return false;
  await ensureFriendStore(soda);
  return !!(await soda.findOne(C.blocks, { blockKey: `${blocker}|${blocked}` }));
}
/** True when either rider blocked the other. */
async function blockedEither(soda, x, y) {
  return (await hasBlocked(soda, x, y)) || (await hasBlocked(soda, y, x));
}

async function edgeBetween(soda, x, y) {
  await ensureFriendStore(soda);
  const r = await soda.findOne(C.edges, { pairKey: pairKeyOf(x, y) });
  return r ? { ...r.value, key: r.key } : null;
}

/** 'FRIENDS' | 'PENDING_OUT' | 'PENDING_IN' | 'NONE' as `me` sees it (shadow requests to me are NONE). */
async function relationOf(soda, me, other) {
  if (!me || !other || me === other) return 'NONE';
  const e = await edgeBetween(soda, me, other);
  if (!e) return 'NONE';
  if (e.status === 'ACCEPTED') return 'FRIENDS';
  if (e.from === me) return 'PENDING_OUT';
  return e.shadow ? 'NONE' : 'PENDING_IN';
}
const areFriends = async (soda, x, y) => (await relationOf(soda, x, y)) === 'FRIENDS';

async function edgesOf(soda, userId) {
  await ensureFriendStore(soda);
  const [as, bs] = await Promise.all([
    soda.query(C.edges, { a: userId }, { limit: 2000 }),
    soda.query(C.edges, { b: userId }, { limit: 2000 }),
  ]);
  return [...as, ...bs].map((r) => ({ ...r.value, key: r.key }));
}

/**
 * fromId asks toId. Returns { status: 'REQUESTED' | 'FRIENDS' | 'ALREADY_FRIENDS', edge }.
 * Throws FriendError for SELF, YOU_BLOCKED, TOO_MANY_PENDING, TOO_MANY_FRIENDS.
 */
async function sendRequest(soda, fromId, toId, { now = Date.now(), via = 'username' } = {}) {
  if (fromId === toId) throw new FriendError('That is you.', 'SELF', 400);
  await ensureFriendStore(soda);
  if (await hasBlocked(soda, fromId, toId)) throw new FriendError('You blocked this rider. Unblock them first.', 'YOU_BLOCKED', 409);
  const existing = await edgeBetween(soda, fromId, toId);
  if (existing) {
    if (existing.status === 'ACCEPTED') return { status: 'ALREADY_FRIENDS', edge: existing };
    if (existing.from === fromId) return { status: 'REQUESTED', edge: existing };
    if (!existing.shadow) return { status: 'FRIENDS', edge: await accept(soda, fromId, existing, now) };
    // They asked while I had blocked them, and I have since unblocked: start over as a normal request.
    await soda.remove(C.edges, existing.key);
  }
  const blockedByTarget = await hasBlocked(soda, toId, fromId);
  if (!blockedByTarget) {
    const mine = await edgesOf(soda, fromId);
    if (mine.filter((e) => e.status === 'PENDING' && e.from === fromId).length >= MAX_PENDING_OUT) {
      throw new FriendError('You have too many requests waiting. Wait for answers or cancel some.', 'TOO_MANY_PENDING', 429);
    }
    if (mine.filter((e) => e.status === 'ACCEPTED').length >= MAX_FRIENDS) {
      throw new FriendError(`You can have up to ${MAX_FRIENDS} friends.`, 'TOO_MANY_FRIENDS', 409);
    }
  }
  const [a, b] = pairOf(fromId, toId);
  const edge = {
    requestId: newRequestId(), pairKey: `${a}|${b}`, a, b, from: fromId, to: toId, status: 'PENDING', via,
    ...(blockedByTarget ? { shadow: true } : {}), createdAt: now, respondedAt: 0,
  };
  try {
    edge.key = await soda.insert(C.edges, edge);
  } catch (e) {
    if (!isConflict(e)) throw e;
    const again = await edgeBetween(soda, fromId, toId); // a parallel request between the same two riders
    return { status: again && again.status === 'ACCEPTED' ? 'ALREADY_FRIENDS' : 'REQUESTED', edge: again };
  }
  return { status: 'REQUESTED', edge, created: true };
}

async function accept(soda, me, edge, now = Date.now()) {
  const { key, ...value } = edge;
  const next = { ...value, status: 'ACCEPTED', respondedAt: now };
  await soda.replace(C.edges, key, next);
  return { ...next, key };
}

/** The edge of a request addressed to `me` (never a shadow one), or null. */
async function incomingRequest(soda, me, requestId) {
  if (!isRequestId(requestId)) return null;
  await ensureFriendStore(soda);
  const r = await soda.findOne(C.edges, { requestId });
  const e = r ? { ...r.value, key: r.key } : null;
  return e && e.to === me && e.status === 'PENDING' && !e.shadow ? e : null;
}

/** Accept (true) or decline (false) a request to `me`. Returns the edge or null when unknown. */
async function respond(soda, me, requestId, yes, { now = Date.now() } = {}) {
  const e = await incomingRequest(soda, me, requestId);
  if (!e) return null;
  if (yes) return accept(soda, me, e, now);
  await soda.remove(C.edges, e.key);
  return { ...e, status: 'DECLINED' };
}

/** The sender takes back an outgoing request. True when removed. */
async function cancelRequest(soda, me, requestId) {
  if (!isRequestId(requestId)) return false;
  await ensureFriendStore(soda);
  const r = await soda.findOne(C.edges, { requestId });
  if (!r || r.value.from !== me || r.value.status !== 'PENDING') return false;
  await soda.remove(C.edges, r.key);
  return true;
}

/** Ends a friendship (either side). True when there was one. */
async function removeFriend(soda, me, other) {
  const e = await edgeBetween(soda, me, other);
  if (!e || e.status !== 'ACCEPTED') return false;
  await soda.remove(C.edges, e.key);
  return true;
}

/**
 * me blocks other: any friendship and my own request end; a request THEY sent me becomes a shadow
 * (they keep seeing "pending", I never see it).
 */
async function block(soda, me, other, { now = Date.now() } = {}) {
  if (me === other) throw new FriendError('That is you.', 'SELF', 400);
  await ensureFriendStore(soda);
  const e = await edgeBetween(soda, me, other);
  if (e) {
    if (e.status === 'PENDING' && e.from === other) {
      const { key, ...value } = e;
      await soda.replace(C.edges, key, { ...value, shadow: true });
    } else {
      await soda.remove(C.edges, e.key);
    }
  }
  try {
    await soda.insert(C.blocks, { blockKey: `${me}|${other}`, blocker: me, blocked: other, at: now });
  } catch (err) { if (!isConflict(err)) throw err; }
  return true;
}

/** Lifts my block; shadow requests from them to me are dropped (as if declined). */
async function unblock(soda, me, other) {
  await ensureFriendStore(soda);
  const n = await soda.removeWhere(C.blocks, { blockKey: `${me}|${other}` });
  const e = await edgeBetween(soda, me, other);
  if (e && e.shadow && e.from === other && !(await hasBlocked(soda, other, me))) await soda.remove(C.edges, e.key);
  return n > 0;
}

async function blockedBy(soda, me) {
  await ensureFriendStore(soda);
  return (await soda.query(C.blocks, { blocker: me }, { limit: 2000 })).map((r) => r.value);
}

/** { friends, incoming, outgoing } edges for `me` (shadow requests to me are left out). */
async function listFor(soda, me) {
  const edges = await edgesOf(soda, me);
  return {
    friends: edges.filter((e) => e.status === 'ACCEPTED'),
    incoming: edges.filter((e) => e.status === 'PENDING' && e.to === me && !e.shadow),
    outgoing: edges.filter((e) => e.status === 'PENDING' && e.from === me),
  };
}

/** Erased account: every edge, block and invite code that names it. */
async function forgetFriends(soda, userId) {
  await ensureFriendStore(soda);
  await soda.removeWhere(C.edges, { a: userId });
  await soda.removeWhere(C.edges, { b: userId });
  await soda.removeWhere(C.blocks, { blocker: userId });
  await soda.removeWhere(C.blocks, { blocked: userId });
  await soda.removeWhere(C.invites, { userId });
}

module.exports = {
  COLLECTIONS: C, MAX_FRIENDS, MAX_PENDING_OUT, FriendError, ensureFriendStore,
  inviteCodeOf, userIdByInviteCode, isInviteCode, normaliseInvite, isRequestId,
  hasBlocked, blockedEither, relationOf, areFriends, sendRequest, respond, cancelRequest, removeFriend,
  block, unblock, blockedBy, listFor, forgetFriends, pairKeyOf,
  _resetForTests: () => { migrated = new WeakSet(); },
};
