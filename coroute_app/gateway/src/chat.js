'use strict';
/**
 * v3.60 chat (docs/features_355/communities_chat_v360.md, section Chat). Text only: no photos, videos, voice
 * notes or files, ever. Every message is deleted 90 days after it was sent.
 *
 *   - Friend chat (kind 'dm'): two riders who are friends and have not blocked each other. Ending the friendship
 *     or a block closes the chat for new messages (history stays until it expires or the account is deleted).
 *   - Community chat (kind 'crew'): the members of a community of up to `chatMembersMax` members (the community
 *     admin's plan limit, default 50). A bigger community has no chat (members still have polls and rides).
 *
 * Collections (created on first use):
 *   chats          { chatId, kind, members:[a,b] + a, b (dm, sorted; a/b are the indexed lookups), crewId (crew), createdAt, lastAt, lastPreview, lastBy }
 *   chat_messages  { messageId, chatId, senderId, text, clientId, at, expiresAt }
 *   chat_reads     { readKey "<chatId>|<userId>", chatId, userId, lastReadAt }
 *
 * Realtime: CHAT_MESSAGE over the socket to the other members, and a push, EXCEPT while the receiver is on a ride
 * (an active trip): a rider is never distracted by chat while riding. Ride alerts are separate: they are never
 * counted as messages (the app keeps two badges, Alerts and Messages).
 *
 * registerChatRoutes({ r, repo, hub, wrap, flagsOf }) once on the authenticated router.
 * Switches: `friendChat`, `communityChat` (feature_flags.js) and the same ids per plan (plans.js).
 */
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const F = require('./friends');
const U = require('./usernames');
const A = require('./avatars');
const CR = require('./crews');
const PL = require('./plans');
const { firstNameOf } = require('./social_routes');
const { stampEvent } = require('./push');

const DAY = 86400000;
const C = Object.freeze({ chats: 'chats', messages: 'chat_messages', reads: 'chat_reads' });
const LIMITS = Object.freeze({ TEXT_MAX: 1000, KEEP_MS: 90 * DAY, PAGE: 50, LIST_MAX: 200, PREVIEW: 80 });
const CHAT_RE = /^(dm_[a-f0-9]{24}|cc_[a-f0-9]{16})$/;
const MSG_RE = /^cm_[a-f0-9]{16}$/;
const RIDING = ['PLANNING', 'STARTED', 'PAUSED', 'ACTIVE'];

class ChatError extends Error {
  constructor(message, code, status = 400) { super(message); this.code = code; this.status = status; }
}

let migrated = new WeakSet();
async function ensureChatStore(soda) {
  if (migrated.has(soda)) return;
  for (const c of Object.values(C)) await soda.ensureCollection(c);
  const idx = (coll, name, fields, unique = false) => soda.ensureIndex(coll, { name, unique, fields: fields.map((path) => ({ path })) });
  await idx(C.chats, 'chats_id_ux', ['chatId'], true);
  await idx(C.chats, 'chats_a_ix', ['a']);
  await idx(C.chats, 'chats_b_ix', ['b']);
  await idx(C.chats, 'chats_crew_ix', ['crewId']);
  await idx(C.messages, 'chat_msgs_id_ux', ['messageId'], true);
  await idx(C.messages, 'chat_msgs_chat_ix', ['chatId', 'at']);
  await idx(C.messages, 'chat_msgs_sender_ix', ['senderId']);
  await idx(C.messages, 'chat_msgs_exp_ix', ['expiresAt']);
  await idx(C.reads, 'chat_reads_ux', ['readKey'], true);
  await idx(C.reads, 'chat_reads_user_ix', ['userId']);
  migrated.add(soda);
}

const withKey = (r) => (r ? { ...r.value, key: r.key } : null);
const dmIdOf = (a, b) => `dm_${crypto.createHash('sha256').update([a, b].sort().join('|')).digest('hex').slice(0, 24)}`;
const crewChatIdOf = (crewId) => `cc_${String(crewId).slice(3)}`;
const crewIdOfChat = (chatId) => `cr_${chatId.slice(3)}`;

/** Text: control / bidi characters out, whitespace kept tidy, 1..1000 characters. */
function cleanMessage(raw) {
  if (typeof raw !== 'string') throw new ChatError('Write a message.', 'EMPTY');
  const v = raw.normalize('NFC')
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g, '')
    .replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  if (!v) throw new ChatError('Write a message.', 'EMPTY');
  if ([...v].length > LIMITS.TEXT_MAX) throw new ChatError(`A message has up to ${LIMITS.TEXT_MAX} characters.`, 'TOO_LONG', 422);
  return v;
}
const previewOf = (text) => { const one = text.replace(/\s+/g, ' '); return [...one].length > LIMITS.PREVIEW ? `${[...one].slice(0, LIMITS.PREVIEW - 1).join('')}…` : one; };

async function getChat(soda, chatId) {
  if (!CHAT_RE.test(String(chatId || ''))) return null;
  await ensureChatStore(soda);
  return withKey(await soda.findOne(C.chats, { chatId }));
}

async function ensureDm(soda, a, b, now = Date.now()) {
  await ensureChatStore(soda);
  const chatId = dmIdOf(a, b);
  const found = await getChat(soda, chatId);
  if (found) return found;
  const [x, y] = [a, b].sort();
  const doc = { chatId, kind: 'dm', members: [x, y], a: x, b: y, createdAt: now, lastAt: 0, lastPreview: '', lastBy: null };
  try { doc.key = await soda.insert(C.chats, doc); } catch { return getChat(soda, chatId); }
  return doc;
}

async function ensureCrewChat(soda, crewId, now = Date.now()) {
  await ensureChatStore(soda);
  const chatId = crewChatIdOf(crewId);
  const found = await getChat(soda, chatId);
  if (found) return found;
  const doc = { chatId, kind: 'crew', crewId, createdAt: now, lastAt: 0, lastPreview: '', lastBy: null };
  try { doc.key = await soda.insert(C.chats, doc); } catch { return getChat(soda, chatId); }
  return doc;
}

/** Deletes messages older than 90 days (all chats). Returns how many. */
async function sweepExpired(soda, now = Date.now()) {
  await ensureChatStore(soda);
  let n = 0;
  for (;;) {
    const rows = await soda.query(C.messages, { expiresAt: { $lt: now } }, { limit: 500 });
    if (!rows.length) break;
    for (const r of rows) { await soda.remove(C.messages, r.key); n++; }
    if (rows.length < 500) break;
  }
  return n;
}

async function messagesOf(soda, chatId, { before = 0, limit = LIMITS.PAGE, now = Date.now() } = {}) {
  await ensureChatStore(soda);
  const filter = { chatId, expiresAt: { $gte: now } };
  if (before > 0) filter.at = { $lt: before };
  const rows = await soda.query(C.messages, filter, { limit: Math.max(1, Math.min(LIMITS.PAGE, limit)), orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }] });
  return rows.map(withKey).reverse();
}

async function readOf(soda, chatId, userId) {
  return withKey(await soda.findOne(C.reads, { readKey: `${chatId}|${userId}` }));
}
async function markRead(soda, chatId, userId, at = Date.now()) {
  await ensureChatStore(soda);
  const prev = await readOf(soda, chatId, userId);
  const doc = { readKey: `${chatId}|${userId}`, chatId, userId, lastReadAt: Math.max(at, prev ? prev.lastReadAt : 0) };
  if (prev) await soda.replace(C.reads, prev.key, doc); else await soda.insert(C.reads, doc);
  return doc;
}
async function unreadIn(soda, chatId, userId, now = Date.now()) {
  const r = await readOf(soda, chatId, userId);
  const since = r ? r.lastReadAt : 0;
  const rows = await soda.query(C.messages, { chatId, at: { $gt: since }, expiresAt: { $gte: now } }, { limit: 100 });
  return rows.filter((x) => x.value.senderId !== userId).length;
}

/** My friend chats (a and b are queried separately: SODA filters on scalars). */
async function dmsOf(soda, userId, limit = LIMITS.LIST_MAX) {
  await ensureChatStore(soda);
  const rows = [...await soda.query(C.chats, { a: userId }, { limit }), ...await soda.query(C.chats, { b: userId }, { limit })];
  const seen = new Set();
  return rows.map(withKey).filter((c) => c.kind === 'dm' && !seen.has(c.chatId) && seen.add(c.chatId));
}

/** Account erase: my messages, my friend chats and read marks. */
async function forgetChatUser(soda, userId) {
  await ensureChatStore(soda);
  await soda.removeWhere(C.messages, { senderId: userId });
  await soda.removeWhere(C.reads, { userId });
  for (const c of await dmsOf(soda, userId, 5000)) {
    await soda.removeWhere(C.messages, { chatId: c.chatId });
    await soda.removeWhere(C.reads, { chatId: c.chatId });
    await soda.remove(C.chats, c.key);
  }
}

async function deleteCrewChat(soda, crewId) {
  await ensureChatStore(soda);
  const chatId = crewChatIdOf(crewId);
  await soda.removeWhere(C.messages, { chatId });
  await soda.removeWhere(C.reads, { chatId });
  await soda.removeWhere(C.chats, { chatId });
}

function registerChatRoutes({ r, repo, hub = null, wrap, flagsOf = () => null }) {
  const soda = repo.soda;
  const plans = PL.forRepo(repo);
  const perUser = (req) => req.user?.userId || req.ip;
  const limiter = (windowMs, limit, message) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: perUser, message: { error: message, code: 'RATE_LIMITED' } });
  const readLimiter = limiter(60 * 1000, 240, 'Too many requests. Wait a minute.');
  const sendLimiter = limiter(60 * 1000, 30, 'You are sending messages too fast. Wait a moment.');
  const isOn = (id) => { const fl = flagsOf(); return !fl || fl.isOn(id); };
  const noStore = (res) => res.set('Cache-Control', 'no-store');
  const fail = (res, e) => {
    if (e instanceof ChatError || e instanceof CR.CrewError) return res.status(e.status).json({ error: e.message, code: e.code });
    throw e;
  };

  // Account erase and community deletion clean up the chat.
  if (!repo.__chatCascade) {
    repo.__chatCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await forgetChatUser(soda, user.userId).catch(() => {});
      return out;
    };
  }
  // 90-day retention: hourly sweep (reads also never return expired messages).
  if (!soda.__chatSweep) {
    soda.__chatSweep = setInterval(() => { sweepExpired(soda).catch(() => {}); }, 3600000);
    soda.__chatSweep.unref?.();
  }

  const usersByIds = async (ids) => {
    const map = new Map();
    const list = [...new Set(ids.filter(Boolean))];
    for (let i = 0; i < list.length; i += 100) {
      const rows = await soda.query('users', { userId: { $in: list.slice(i, i + 100) } }, { limit: 100 });
      for (const row of rows) {
        const u = { ...row.value, key: row.key };
        map.set(u.userId, u.username ? u : await U.ensureUsername(repo, u).catch(() => u));
      }
    }
    return map;
  };
  const avatarOf = (u) => (isOn('profilePhotos') ? A.avatarUrlOf(u && u.avatarId) : null);
  const cardOf = (u) => ({ username: (u && u.username) || '', displayName: firstNameOf(u && u.name), avatarUrl: avatarOf(u) });

  /** The chat size limit of a community: its admin's plan (default 50). */
  const crewChatAllowed = async (crew) => {
    if (!isOn('communityChat')) return { ok: false, reason: 'OFF' };
    const eff = await plans.effectiveFor(crew.adminId);
    if (!eff.features.communityChat) return { ok: false, reason: 'PLAN' };
    if ((crew.memberCount || 0) > eff.limits.chatMembersMax) return { ok: false, reason: 'TOO_BIG', max: eff.limits.chatMembersMax };
    return { ok: true, max: eff.limits.chatMembersMax };
  };

  /**
   * Access to a chat for `uid`: { chat, kind, others:[userIds], crew?, canSend, closedReason? } or null (= 404).
   */
  const access = async (chatId, uid) => {
    if (!CHAT_RE.test(String(chatId || ''))) return null;
    if (chatId.startsWith('dm_')) {
      const chat = await getChat(soda, chatId);
      if (!chat || !chat.members.includes(uid)) return null;
      const other = chat.members.find((m) => m !== uid) || uid;
      let closedReason = null;
      if (!isOn('friendChat')) closedReason = 'OFF';
      else if (!(await F.areFriends(soda, uid, other))) closedReason = 'NOT_FRIENDS';
      else if (await F.blockedEither(soda, uid, other)) closedReason = 'BLOCKED';
      return { chat, kind: 'dm', others: [other], canSend: !closedReason, closedReason };
    }
    const crewId = crewIdOfChat(chatId);
    const crew = await CR.getCrew(soda, crewId);
    if (!crew || !(await CR.memberOf(soda, crewId, uid))) return null;
    const allowed = await crewChatAllowed(crew);
    const chat = await ensureCrewChat(soda, crewId);
    const members = (await CR.membersOf(soda, crewId)).map((m) => m.userId);
    return { chat, kind: 'crew', crew, others: members.filter((m) => m !== uid), canSend: allowed.ok, closedReason: allowed.ok ? null : allowed.reason, max: allowed.max };
  };

  const messageView = (m, users, uid) => ({
    messageId: m.messageId, chatId: m.chatId, text: m.text, at: m.at, expiresAt: m.expiresAt, clientId: m.clientId || null,
    mine: m.senderId === uid, from: users.get(m.senderId) ? cardOf(users.get(m.senderId)) : { username: '', displayName: 'Former rider', avatarUrl: null },
  });

  const riding = async (userId) => {
    const t = await repo.getActiveTrip(userId).catch(() => null);
    return !!(t && RIDING.includes(String(t.status || 'ACTIVE').toUpperCase()));
  };

  // ---- list ----
  r.get('/chats', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const now = Date.now();
    await ensureChatStore(soda);
    const out = [];
    // Friend chats with at least one message.
    const dms = (await dmsOf(soda, uid)).filter((c) => c.lastAt > now - LIMITS.KEEP_MS);
    const users = await usersByIds(dms.flatMap((c) => c.members));
    for (const c of dms) {
      const other = users.get(c.members.find((m) => m !== uid));
      if (!other || other.status === 'BLOCKED') continue;
      out.push({ chatId: c.chatId, kind: 'dm', title: other.username || 'Rider', subtitle: firstNameOf(other.name), avatarUrl: avatarOf(other),
        lastAt: c.lastAt, lastPreview: c.lastPreview, lastMine: c.lastBy === uid, unread: await unreadIn(soda, c.chatId, uid, now) });
    }
    // Community chats of my communities that have chat.
    for (const m of await CR.membershipsOf(soda, uid)) {
      const crew = await CR.getCrew(soda, m.crewId);
      if (!crew) continue;
      const allowed = await crewChatAllowed(crew);
      if (!allowed.ok) continue;
      const chat = await getChat(soda, crewChatIdOf(crew.crewId));
      const fresh = chat && chat.lastAt > now - LIMITS.KEEP_MS;
      out.push({ chatId: crewChatIdOf(crew.crewId), kind: 'crew', crewId: crew.crewId, title: crew.name, subtitle: `${crew.memberCount || 0} members`,
        avatarUrl: crew.photoId ? A.avatarUrlOf(crew.photoId) : null, lastAt: fresh ? chat.lastAt : 0, lastPreview: fresh ? chat.lastPreview : '',
        lastMine: fresh && chat.lastBy === uid, unread: fresh ? await unreadIn(soda, chat.chatId, uid, now) : 0 });
    }
    out.sort((a, b) => b.lastAt - a.lastAt || a.title.localeCompare(b.title));
    noStore(res).json({ ok: true, chats: out, unread: out.reduce((n, c) => n + c.unread, 0), keepDays: 90 });
  }));

  r.get('/chats/unread', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const now = Date.now();
    await ensureChatStore(soda);
    let n = 0;
    const dms = (await dmsOf(soda, uid)).filter((c) => c.lastAt > now - LIMITS.KEEP_MS);
    for (const c of dms) n += await unreadIn(soda, c.chatId, uid, now);
    for (const m of await CR.membershipsOf(soda, uid)) {
      const chat = await getChat(soda, crewChatIdOf(m.crewId));
      if (chat && chat.lastAt > now - LIMITS.KEEP_MS) n += await unreadIn(soda, chat.chatId, uid, now);
    }
    noStore(res).json({ ok: true, messages: n });
  }));

  // ---- open a friend chat ----
  r.post('/chats/dm', readLimiter, wrap(async (req, res) => {
    if (!isOn('friendChat')) return res.status(403).json({ error: 'This feature is turned off for now.', code: 'FEATURE_OFF', feature: 'friendChat' });
    const uid = req.user.userId;
    const other = await U.findUserByUsername(repo, String(req.body?.username || '')).catch(() => null);
    const notFriend = { error: 'You can chat with your friends.', code: 'NOT_A_FRIEND' };
    if (!other || other.userId === uid || other.status === 'BLOCKED') return res.status(404).json(notFriend);
    if (!(await F.areFriends(soda, uid, other.userId)) || await F.blockedEither(soda, uid, other.userId)) return res.status(404).json(notFriend);
    if (!(await plans.featureFor(uid, 'friendChat'))) return res.status(403).json(PL.PLAN_OFF('Chat with friends'));
    const chat = await ensureDm(soda, uid, other.userId);
    noStore(res).json({ ok: true, chat: { chatId: chat.chatId, kind: 'dm', title: other.username, subtitle: firstNameOf(other.name), avatarUrl: avatarOf(other) } });
  }));

  // ---- messages ----
  r.get('/chats/:chatId/messages', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const a = await access(String(req.params.chatId), uid);
    if (!a) return noStore(res).status(404).json({ error: 'Chat not found.', code: 'CHAT_NOT_FOUND' });
    const before = Number(req.query.before) || 0;
    const list = await messagesOf(soda, a.chat.chatId, { before, limit: Number(req.query.limit) || LIMITS.PAGE });
    const users = await usersByIds(list.map((m) => m.senderId));
    const meta = { chatId: a.chat.chatId, kind: a.kind, canSend: a.canSend, closedReason: a.closedReason, keepDays: 90 };
    if (a.kind === 'crew') Object.assign(meta, { crewId: a.crew.crewId, title: a.crew.name, memberCount: a.crew.memberCount || 0, chatMembersMax: a.max || null });
    else {
      const ou = (await usersByIds(a.others)).get(a.others[0]);
      Object.assign(meta, { title: ou ? ou.username : 'Rider', username: ou ? ou.username : '' });
    }
    noStore(res).json({ ok: true, chat: meta, messages: list.map((m) => messageView(m, users, uid)), more: list.length >= LIMITS.PAGE });
  }));

  r.post('/chats/:chatId/messages', sendLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const a = await access(String(req.params.chatId), uid);
    if (!a) return res.status(404).json({ error: 'Chat not found.', code: 'CHAT_NOT_FOUND' });
    if (!a.canSend) {
      const why = { OFF: 'Chat is turned off for now.', NOT_FRIENDS: 'You can chat with your friends only.', BLOCKED: 'You cannot message this rider.', PLAN: 'Chat is not included in this plan.', TOO_BIG: `Community chat is for communities of up to ${a.max} members.` };
      return res.status(403).json({ error: why[a.closedReason] || 'You cannot send messages here.', code: `CHAT_${a.closedReason || 'CLOSED'}` });
    }
    if (a.kind === 'dm' && !(await plans.featureFor(uid, 'friendChat'))) return res.status(403).json(PL.PLAN_OFF('Chat with friends'));
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    // Text only: any attachment field is refused outright.
    if (['image', 'images', 'photo', 'video', 'file', 'attachment', 'attachments', 'media', 'audio'].some((k) => b[k] !== undefined)) {
      return res.status(415).json({ error: 'Chat is text only.', code: 'TEXT_ONLY' });
    }
    let text;
    try { text = cleanMessage(b.text); } catch (e) { return fail(res, e); }
    const clientId = typeof b.clientId === 'string' && /^[A-Za-z0-9_-]{6,40}$/.test(b.clientId) ? b.clientId : null;
    const now = Date.now();
    if (clientId) {
      const dup = (await soda.query(C.messages, { chatId: a.chat.chatId, senderId: uid, clientId }, { limit: 1 })).map(withKey)[0];
      if (dup) {
        const users = await usersByIds([uid]);
        return res.json({ ok: true, message: messageView(dup, users, uid), duplicate: true });
      }
    }
    const msg = { messageId: `cm_${crypto.randomBytes(8).toString('hex')}`, chatId: a.chat.chatId, senderId: uid, text, clientId, at: now, expiresAt: now + LIMITS.KEEP_MS };
    await soda.insert(C.messages, msg);
    const chat = await getChat(soda, a.chat.chatId);
    if (chat) { const { key, ...v } = chat; await soda.replace(C.chats, key, { ...v, lastAt: now, lastPreview: previewOf(text), lastBy: uid }); }
    await markRead(soda, a.chat.chatId, uid, now);
    const users = await usersByIds([uid]);
    const sender = users.get(uid);
    const view = messageView(msg, users, uid);
    res.status(201).json({ ok: true, message: view });
    // Fan-out after answering: socket to everyone, push only to riders who are not on a ride.
    for (const other of a.others) {
      const payload = stampEvent({ type: 'CHAT_MESSAGE', chatId: a.chat.chatId, messageId: msg.messageId, kind: a.kind,
        username: sender ? sender.username : '', crewName: a.kind === 'crew' ? a.crew.name : undefined, preview: previewOf(text),
        message: { ...view, mine: false } });
      let delivered = 0;
      try { if (hub) delivered = hub.sendToUser(other, payload) || 0; } catch { /* best effort */ }
      riding(other).then((onRide) => {
        if (onRide || !hub || !hub.push) return;
        hub.push.onSocketEvent(other, payload, { delivered }).catch(() => {});
      }).catch(() => {});
    }
  }));

  r.post('/chats/:chatId/read', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const a = await access(String(req.params.chatId), uid);
    if (!a) return res.status(404).json({ error: 'Chat not found.', code: 'CHAT_NOT_FOUND' });
    const at = Math.min(Date.now(), Number(req.body?.at) || Date.now());
    await markRead(soda, a.chat.chatId, uid, at);
    res.json({ ok: true });
  }));

  r.delete('/chats/:chatId/messages/:messageId', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const a = await access(String(req.params.chatId), uid);
    const id = String(req.params.messageId || '');
    if (!a || !MSG_RE.test(id)) return res.status(404).json({ error: 'Message not found.', code: 'NOT_FOUND' });
    const m = withKey(await soda.findOne(C.messages, { messageId: id }));
    if (!m || m.chatId !== a.chat.chatId) return res.status(404).json({ error: 'Message not found.', code: 'NOT_FOUND' });
    let may = m.senderId === uid;
    if (!may && a.kind === 'crew') may = CR.canManage(await CR.memberOf(soda, a.crew.crewId, uid));
    if (!may) return res.status(403).json({ error: 'You can delete your own messages.', code: 'NOT_ALLOWED' });
    await soda.remove(C.messages, m.key);
    for (const other of a.others) { try { if (hub) hub.sendToUser(other, { type: 'CHAT_DELETED', chatId: a.chat.chatId, messageId: id }); } catch { /* best effort */ } }
    res.json({ ok: true, deleted: true });
  }));
}

module.exports = {
  COLLECTIONS: C, LIMITS, ChatError, ensureChatStore, dmIdOf, crewChatIdOf, cleanMessage, previewOf, ensureDm, ensureCrewChat,
  dmsOf, messagesOf, markRead, unreadIn, sweepExpired, forgetChatUser, deleteCrewChat, registerChatRoutes,
  _resetForTests: () => { migrated = new WeakSet(); },
};
