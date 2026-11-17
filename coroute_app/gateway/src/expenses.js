'use strict';
/**
 * v3.63 trip planning lite: expense split per ride (docs/features_355/trip_planning_lite_v363.md).
 *
 * Plain records riders keep for themselves: what was spent, who paid, who shares it, and the shortest "who owes whom"
 * list. CoRoute never moves money, sells or charges anything here (no payment link, no checkout).
 *
 * Who: every rider of the ride (current or earlier member of the convoy). During the ride and for 30 days after its
 * last activity the riders can read, add and settle; after that the records are kept read-only until 90 days, then
 * removed (hourly sweep). A rider edits or deletes only what they added.
 *
 * Collection `ride_expenses` (created on first use):
 *   { kind: 'expense', id, groupId, by, what, amount (paise), paidBy, shares: { userId: paise }, createdAt, updatedAt }
 *   { kind: 'settle',  id, groupId, by, from, to, amount (paise), createdAt }
 *   { kind: 'meta',    groupId, members: { userId: firstName }, rideName, lastLiveAt }
 *
 * REST (authenticated, members only):
 *   GET    /api/convoys/:groupId/expenses                    list + balances + settle-up suggestions
 *   POST   /api/convoys/:groupId/expenses                    { what, amount, paidBy?, split: { mode: 'equal', among: [ids] } | { mode: 'custom', shares: { id: amount } } }
 *   PUT    /api/convoys/:groupId/expenses/:id                same body, creator only
 *   DELETE /api/convoys/:groupId/expenses/:id                creator only
 *   POST   /api/convoys/:groupId/expenses/settle             { from, to, amount }  "paid back" record
 *   DELETE /api/convoys/:groupId/expenses/settle/:id         creator only (undo)
 * Realtime: EXPENSES_CHANGED { version } to the room (the app reloads the list).
 * Amounts in the API are rupees with up to 2 decimals; stored as whole paise.
 */
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');

const DAY = 86400000;
const COLL = 'ride_expenses';
const LIMITS = Object.freeze({ WHAT_MAX: 60, MAX_PAISE: 100000000, PER_RIDE: 300, OPEN_MS: 30 * DAY, KEEP_MS: 90 * DAY });
const ID_RE = /^ex_[a-f0-9]{16}$/;
const UID_RE = /^[A-Za-z0-9_:.-]{1,80}$/;

class ExpenseError extends Error {
  constructor(message, status = 400, code = 'INVALID') { super(message); this.status = status; this.code = code; }
}

/** Rupees (number or "12.50") -> whole paise, or null. */
function toPaise(v) {
  const n = typeof v === 'string' && /^\s*\d+(\.\d{1,2})?\s*$/.test(v) ? Number(v) : (typeof v === 'number' ? v : NaN);
  if (!Number.isFinite(n) || n <= 0) return null;
  const p = Math.round(n * 100);
  if (Math.abs(p - n * 100) > 0.001 || p < 1 || p > LIMITS.MAX_PAISE) return null;
  return p;
}
const toRupees = (p) => Math.round(Number(p) || 0) / 100;

/** Equal shares of `amount` paise among `ids` (the first ones carry the leftover paise, so the sum is exact). */
function equalShares(amount, ids) {
  const out = {};
  const n = ids.length;
  const base = Math.floor(amount / n);
  let rest = amount - base * n;
  for (const id of ids) { out[id] = base + (rest > 0 ? 1 : 0); if (rest > 0) rest--; }
  return out;
}

/**
 * Net balance per rider in paise (positive = is owed, negative = owes) from expenses and settlements.
 * A settlement "from paid to" moves `amount` from the payer's debt.
 */
function balancesOf(rows) {
  const bal = {};
  const add = (id, v) => { bal[id] = (bal[id] || 0) + v; };
  for (const r of rows) {
    if (r.kind === 'expense') {
      add(r.paidBy, r.amount);
      for (const [id, s] of Object.entries(r.shares || {})) add(id, -s);
    } else if (r.kind === 'settle') {
      add(r.from, r.amount);
      add(r.to, -r.amount);
    }
  }
  for (const k of Object.keys(bal)) if (bal[k] === 0) delete bal[k];
  return bal;
}

/** The shortest-ish "who pays whom" list: largest debtor pays largest creditor, repeated (at most n - 1 transfers). */
function settleUp(bal) {
  const cred = Object.entries(bal).filter(([, v]) => v > 0).map(([id, v]) => ({ id, v })).sort((a, b) => b.v - a.v || (a.id < b.id ? -1 : 1));
  const debt = Object.entries(bal).filter(([, v]) => v < 0).map(([id, v]) => ({ id, v: -v })).sort((a, b) => b.v - a.v || (a.id < b.id ? -1 : 1));
  const out = [];
  let i = 0, j = 0;
  while (i < debt.length && j < cred.length) {
    const amt = Math.min(debt[i].v, cred[j].v);
    if (amt > 0) out.push({ from: debt[i].id, to: cred[j].id, amount: amt });
    debt[i].v -= amt; cred[j].v -= amt;
    if (debt[i].v === 0) i++;
    if (cred[j].v === 0) j++;
  }
  return out;
}

class ExpenseService {
  constructor({ soda, convoys, logger = console, clock = Date.now }) {
    Object.assign(this, { soda, convoys, log: logger, clock });
    this.ready = null;
  }

  async ensure() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(COLL);
        await this.soda.ensureIndex(COLL, { name: `${COLL}_group_ix`, fields: [{ path: 'groupId' }] }).catch(() => {});
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  async _meta(groupId) {
    const r = await this.soda.findOne(COLL, { groupId, kind: 'meta' });
    return r ? { ...r.value, key: r.key } : null;
  }

  /**
   * Can `userId` use the expenses of `groupId`? { members, write } or throws 403 / 404.
   * Live ride: the convoy's members (now or earlier in it). After it: the members kept in the meta for 30 days.
   */
  async access(groupId, userId) {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(String(groupId || ''))) throw new ExpenseError('Ride not found.', 404, 'NOT_FOUND');
    await this.ensure();
    const t = this.clock();
    const room = this.convoys ? await this.convoys.getRoom(groupId, { required: false }).catch(() => null) : null;
    if (room && room.meta && (room.meta.members?.[userId] || (room.riders && room.riders.has(userId)))) {
      const members = {};
      for (const m of Object.values(room.meta.members || {})) if (m && m.userId) members[m.userId] = firstName(m.name);
      if (room.riders) for (const [id, r] of room.riders) if (!members[id]) members[id] = firstName(r && r.name);
      const meta = await this._meta(groupId);
      const doc = { kind: 'meta', groupId, members: { ...(meta ? meta.members : {}), ...members }, rideName: String(room.meta.name || '').slice(0, 60), lastLiveAt: t };
      // At most one write a minute per ride for the "last live" time and the member list.
      if (!meta || t - (meta.lastLiveAt || 0) > 60000 || Object.keys(doc.members).length !== Object.keys(meta.members || {}).length) {
        if (meta) await this.soda.replace(COLL, meta.key, doc).catch(() => {}); else await this.soda.insert(COLL, doc).catch(() => {});
      }
      return { members: doc.members, write: true, live: true, rideName: doc.rideName };
    }
    const meta = await this._meta(groupId);
    if (!meta || !meta.members || !Object.hasOwn(meta.members, userId)) throw new ExpenseError('Only riders of this ride can see its expenses.', 403, 'NOT_MEMBER');
    const age = t - (Number(meta.lastLiveAt) || 0);
    if (age > LIMITS.KEEP_MS) throw new ExpenseError('Ride not found.', 404, 'NOT_FOUND');
    return { members: meta.members, write: age <= LIMITS.OPEN_MS, live: false, rideName: meta.rideName || '' };
  }

  async _rows(groupId) {
    // At most PER_RIDE records per ride (+ its meta): one query.
    const found = await this.soda.query(COLL, { groupId }, { limit: LIMITS.PER_RIDE + 10 });
    return found.filter((r) => r.value && r.value.kind !== 'meta').map((r) => ({ ...r.value, key: r.key }));
  }

  async list(groupId, userId) {
    const acc = await this.access(groupId, userId);
    const rows = await this._rows(groupId);
    rows.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
    const bal = balancesOf(rows);
    const nameOf = (id) => acc.members[id] || 'Rider';
    const total = rows.filter((r) => r.kind === 'expense').reduce((s, r) => s + r.amount, 0);
    return {
      groupId, rideName: acc.rideName, canEdit: acc.write, me: userId,
      members: Object.entries(acc.members).map(([id, name]) => ({ userId: id, name })),
      totalSpent: toRupees(total),
      expenses: rows.filter((r) => r.kind === 'expense').map((r) => ({
        id: r.id, what: r.what, amount: toRupees(r.amount), paidBy: r.paidBy, paidByName: nameOf(r.paidBy), by: r.by, mine: r.by === userId,
        shares: Object.entries(r.shares || {}).map(([id, s]) => ({ userId: id, name: nameOf(id), amount: toRupees(s) })), createdAt: r.createdAt,
      })),
      settlements: rows.filter((r) => r.kind === 'settle').map((r) => ({ id: r.id, from: r.from, fromName: nameOf(r.from), to: r.to, toName: nameOf(r.to), amount: toRupees(r.amount), mine: r.by === userId, createdAt: r.createdAt })),
      balances: Object.entries(bal).map(([id, v]) => ({ userId: id, name: nameOf(id), amount: toRupees(v) })),
      settleUp: settleUp(bal).map((s) => ({ from: s.from, fromName: nameOf(s.from), to: s.to, toName: nameOf(s.to), amount: toRupees(s.amount) })),
    };
  }

  /** Validates an expense body against the members; returns { what, amount, paidBy, shares }. */
  _clean(body, members, userId) {
    const b = body && typeof body === 'object' ? body : {};
    const what = String(b.what == null ? '' : b.what).replace(/[\u0000-\u001f\u007f<>]/g, '').trim().slice(0, LIMITS.WHAT_MAX);
    if (!what) throw new ExpenseError('Say what it was for (fuel, food, toll...).', 400, 'WHAT_REQUIRED');
    const amount = toPaise(b.amount);
    if (!amount) throw new ExpenseError('Enter an amount above 0 (up to 2 decimals).', 400, 'BAD_AMOUNT');
    const isMember = (id) => typeof id === 'string' && UID_RE.test(id) && Object.hasOwn(members, id);
    const paidBy = b.paidBy == null || b.paidBy === '' ? userId : String(b.paidBy);
    if (!isMember(paidBy)) throw new ExpenseError('The rider who paid must be on this ride.', 400, 'BAD_PAYER');
    const split = b.split && typeof b.split === 'object' ? b.split : { mode: 'equal', among: Object.keys(members) };
    let shares;
    if (split.mode === 'custom') {
      const raw = split.shares && typeof split.shares === 'object' && !Array.isArray(split.shares) ? split.shares : null;
      if (!raw || !Object.keys(raw).length) throw new ExpenseError('Give each share.', 400, 'BAD_SPLIT');
      shares = {};
      for (const [id, v] of Object.entries(raw)) {
        if (!isMember(id)) throw new ExpenseError('Every share must be a rider on this ride.', 400, 'BAD_SPLIT');
        const p = v === 0 || v === '0' ? 0 : toPaise(v);
        if (p === null) throw new ExpenseError('Shares must be amounts of 0 or more (up to 2 decimals).', 400, 'BAD_SPLIT');
        if (p > 0) shares[id] = p;
      }
      const sum = Object.values(shares).reduce((s, x) => s + x, 0);
      if (sum !== amount) throw new ExpenseError(`The shares add up to ${toRupees(sum)}, not ${toRupees(amount)}.`, 400, 'SPLIT_SUM');
    } else {
      const among = Array.isArray(split.among) ? [...new Set(split.among.map(String))] : [];
      if (!among.length || among.length > 100 || !among.every(isMember)) throw new ExpenseError('Choose who shares it (riders on this ride).', 400, 'BAD_SPLIT');
      shares = equalShares(amount, among.sort());
    }
    return { what, amount, paidBy, shares };
  }

  _changed(groupId) {
    try { if (this.convoys && typeof this.convoys._emit === 'function' && this.convoys.rooms.has(groupId)) this.convoys._emit(groupId, 'EXPENSES_CHANGED', { version: this.clock() }); } catch { /* best effort */ }
  }

  async add(groupId, userId, body) {
    const acc = await this.access(groupId, userId);
    if (!acc.write) throw new ExpenseError('This ride\'s expenses are closed (30 days after the ride).', 409, 'CLOSED');
    const v = this._clean(body, acc.members, userId);
    const rows = await this._rows(groupId);
    if (rows.length >= LIMITS.PER_RIDE) throw new ExpenseError('This ride has the most expense records allowed.', 409, 'TOO_MANY');
    // A double tap sends the same expense twice within seconds: answered with the first one.
    const t = this.clock();
    const dup = rows.find((r) => r.kind === 'expense' && r.by === userId && r.what === v.what && r.amount === v.amount && t - (r.createdAt || 0) < 10000);
    if (dup) return { id: dup.id, duplicate: true };
    const id = `ex_${crypto.randomBytes(8).toString('hex')}`;
    await this.soda.insert(COLL, { kind: 'expense', id, groupId, by: userId, ...v, createdAt: t, updatedAt: t });
    this._changed(groupId);
    return { id };
  }

  async _own(groupId, userId, id, kind) {
    if (!ID_RE.test(String(id || ''))) throw new ExpenseError('Not found.', 404, 'NOT_FOUND');
    const r = await this.soda.findOne(COLL, { groupId, id: String(id) });
    if (!r || r.value.kind !== kind) throw new ExpenseError('Not found.', 404, 'NOT_FOUND');
    if (r.value.by !== userId) throw new ExpenseError('Only the rider who added it can change it.', 403, 'NOT_OWNER');
    return r;
  }

  async edit(groupId, userId, id, body) {
    const acc = await this.access(groupId, userId);
    if (!acc.write) throw new ExpenseError('This ride\'s expenses are closed (30 days after the ride).', 409, 'CLOSED');
    const r = await this._own(groupId, userId, id, 'expense');
    const v = this._clean(body, acc.members, userId);
    await this.soda.replace(COLL, r.key, { ...r.value, ...v, updatedAt: this.clock() });
    this._changed(groupId);
    return { id };
  }

  async remove(groupId, userId, id, kind = 'expense') {
    const acc = await this.access(groupId, userId);
    if (!acc.write) throw new ExpenseError('This ride\'s expenses are closed (30 days after the ride).', 409, 'CLOSED');
    const r = await this._own(groupId, userId, id, kind);
    await this.soda.remove(COLL, r.key);
    this._changed(groupId);
    return { removed: true };
  }

  async settle(groupId, userId, body) {
    const acc = await this.access(groupId, userId);
    if (!acc.write) throw new ExpenseError('This ride\'s expenses are closed (30 days after the ride).', 409, 'CLOSED');
    const b = body && typeof body === 'object' ? body : {};
    const from = String(b.from || ''), to = String(b.to || '');
    if (!Object.hasOwn(acc.members, from) || !Object.hasOwn(acc.members, to) || from === to) throw new ExpenseError('Choose two riders of this ride.', 400, 'BAD_SETTLE');
    // Only the two riders involved record that one paid the other back.
    if (userId !== from && userId !== to) throw new ExpenseError('Only the two riders involved can mark this as paid back.', 403, 'NOT_INVOLVED');
    const amount = toPaise(b.amount);
    if (!amount) throw new ExpenseError('Enter an amount above 0.', 400, 'BAD_AMOUNT');
    const t = this.clock();
    const rows = await this._rows(groupId);
    const dup = rows.find((r) => r.kind === 'settle' && r.by === userId && r.from === from && r.to === to && r.amount === amount && t - (r.createdAt || 0) < 10000);
    if (dup) return { id: dup.id, duplicate: true };
    const id = `ex_${crypto.randomBytes(8).toString('hex')}`;
    await this.soda.insert(COLL, { kind: 'settle', id, groupId, by: userId, from, to, amount, createdAt: t });
    this._changed(groupId);
    return { id };
  }

  /** Removes rides whose last activity is older than 90 days. */
  async sweep() {
    await this.ensure();
    const cutoff = this.clock() - LIMITS.KEEP_MS;
    const old = await this.soda.query(COLL, { kind: 'meta', lastLiveAt: { $lt: cutoff } }, { limit: 200 });
    let removed = 0;
    for (const m of old) removed += Number(await this.soda.removeWhere(COLL, { groupId: m.value.groupId }).catch(() => 0)) || 0;
    return removed;
  }

  /** Account erase: the rider's own records go; their name in other rides' lists becomes "Deleted rider". */
  async forgetUser(userId) {
    await this.ensure();
    await this.soda.removeWhere(COLL, { by: userId }).catch(() => {});
    const metas = await this.soda.query(COLL, { kind: 'meta' }, { limit: 2000 }).catch(() => []);
    for (const m of metas) {
      if (m.value && m.value.members && Object.hasOwn(m.value.members, userId)) {
        await this.soda.replace(COLL, m.key, { ...m.value, members: { ...m.value.members, [userId]: 'Deleted rider' } }).catch(() => {});
      }
    }
  }
}

function firstName(n) { return String(n || 'Rider').trim().split(/\s+/)[0].slice(0, 30) || 'Rider'; }

function registerExpenseRoutes({ r, repo, convoys, wrap }) {
  const svc = new ExpenseService({ soda: repo.soda, convoys });
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 40, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `exp:${req.user ? req.user.userId : req.ip}`, message: { error: 'Too many changes. Wait a moment.', code: 'RATE_LIMITED' } });
  const run = (fn) => wrap(async (req, res) => {
    try { res.set('Cache-Control', 'no-store').json(await fn(req)); } catch (e) {
      if (e instanceof ExpenseError) return res.status(e.status).json({ error: e.message, code: e.code });
      throw e;
    }
  });
  const gid = (req) => String(req.params.groupId || '');
  r.get('/convoys/:groupId/expenses', run((req) => svc.list(gid(req), req.user.userId)));
  r.post('/convoys/:groupId/expenses/settle', limiter, run((req) => svc.settle(gid(req), req.user.userId, req.body)));
  r.delete('/convoys/:groupId/expenses/settle/:id', limiter, run((req) => svc.remove(gid(req), req.user.userId, req.params.id, 'settle')));
  r.post('/convoys/:groupId/expenses', limiter, run((req) => svc.add(gid(req), req.user.userId, req.body)));
  r.put('/convoys/:groupId/expenses/:id', limiter, run((req) => svc.edit(gid(req), req.user.userId, req.params.id, req.body)));
  r.delete('/convoys/:groupId/expenses/:id', limiter, run((req) => svc.remove(gid(req), req.user.userId, req.params.id, 'expense')));
  if (!repo.__expenseCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__expenseCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await svc.forgetUser(user.userId).catch(() => {});
      return out;
    };
  }
  if (!repo.soda.__expenseSweep) {
    repo.soda.__expenseSweep = setInterval(() => { svc.sweep().catch(() => {}); }, 3600000);
    repo.soda.__expenseSweep.unref?.();
  }
  return svc;
}

module.exports = { ExpenseService, ExpenseError, registerExpenseRoutes, toPaise, equalShares, balancesOf, settleUp, COLL, LIMITS };
