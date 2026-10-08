'use strict';
/**
 * Safety audit trail (3.15): one small row per safety network or discovery action (raise, status,
 * notify, answer, hazard, false-alert report, resolve, expire, discovery notify, wave).
 *
 * Rows hold ids, kinds, counts and short codes only: never coordinates, names or free text.
 * Writes are fire and forget through a write-behind queue: batched every 2 s, at most 200 rows
 * waiting (the oldest are dropped with a warning), and the one-shot timer runs only while rows wait,
 * so an alert is never slowed by the database.
 */
const crypto = require('crypto');

const KINDS = new Set(['RAISE', 'STATUS', 'NOTIFY', 'ANSWER', 'HAZARD', 'REPORT_FALSE', 'RESOLVE', 'EXPIRE', 'DISCOVERY_NOTIFY', 'WAVE', 'RESET']);
const ID = /^[A-Za-z0-9_.:-]{1,80}$/;

/** A row reduced to the allowed fields, with types and sizes enforced. */
function cleanRow(row, at) {
  const out = { auditId: `AUD-${crypto.randomBytes(6).toString('hex').toUpperCase()}`, at: Number.isFinite(row.at) ? row.at : at, kind: KINDS.has(row.kind) ? row.kind : 'STATUS' };
  for (const k of ['incidentId', 'alertId', 'groupId', 'actorId', 'subjectId']) {
    if (typeof row[k] === 'string' && ID.test(row[k])) out[k] = row[k];
  }
  if (Number.isFinite(row.count)) out.count = Math.round(row.count);
  // Codes only: upper case words, digits, _ : , = and spaces. Anything else is dropped.
  out.detail = String(row.detail || '').toUpperCase().replace(/[^A-Z0-9_:,= ]/g, '').slice(0, 120);
  return out;
}

class SafetyAudit {
  constructor({ repo, logger = console, clock = Date.now, batchMs = 2000, maxQueued = 200 } = {}) {
    this.repo = repo; this.log = logger; this.clock = clock; this.batchMs = batchMs; this.maxQueued = maxQueued;
    this.queue = [];
    this.timer = null;
    this.flushing = null;
  }

  /** Queues one row (never throws, never awaits the database). */
  add(row) {
    if (!row || typeof row !== 'object') return;
    this.queue.push(cleanRow(row, this.clock()));
    if (this.queue.length > this.maxQueued) {
      const drop = this.queue.length - this.maxQueued;
      this.queue.splice(0, drop);
      this.log.warn('[audit] queue full, dropped', drop);
    }
    if (!this.timer) {
      this.timer = setTimeout(() => { this.timer = null; this.flush().catch(() => {}); }, this.batchMs);
      if (this.timer.unref) this.timer.unref();
    }
  }

  /** Writes everything queued now (tests, shutdown). */
  async flush() {
    if (this.flushing) await this.flushing;
    if (!this.queue.length) return 0;
    const rows = this.queue.splice(0, this.queue.length);
    this.flushing = (async () => {
      for (const r of rows) {
        try { await this.repo.addAudit(r); } catch (e) { this.log.warn('[audit] write failed', e.message); }
      }
    })();
    try { await this.flushing; } finally { this.flushing = null; }
    return rows.length;
  }

  /** Account deletion: rows about this user that are still waiting are dropped (stored ones go in the cascade). */
  forget(userId) {
    this.queue = this.queue.filter((r) => r.actorId !== userId && r.subjectId !== userId);
  }

  stop() { clearTimeout(this.timer); this.timer = null; }
}

module.exports = { SafetyAudit, cleanRow, AUDIT_KINDS: KINDS };
