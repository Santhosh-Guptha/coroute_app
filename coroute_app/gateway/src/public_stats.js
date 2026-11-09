'use strict';
/**
 * 3.55b: the website's ALL-TIME community totals, computed by one node and shared by every node.
 *
 * communityTotals (admin_analytics.js) reads users, trips, ended rides and alerts in full. That is far too
 * much for a public request, so:
 *   - one node (job lease 'public-stats', every REFRESH_MS) computes the totals and stores them in ONE
 *     document (subscription_config k='public_stats_alltime'; aggregate numbers only, no ids or names);
 *   - every node answers the website from that document, kept in memory for MEMORY_MS;
 *   - when the document is missing or older than STALE_MS (first boot, tests, the job stopped), the first
 *     request computes it once (single flight per node) and stores it for everyone.
 * The stored numbers are exact; what leaves the server is always made coarse in public_privacy.js.
 */
const { COLLECTIONS: C } = require('./oracle/repo');

const DOC_KEY = 'public_stats_alltime';
const REFRESH_MS = 5 * 60 * 1000;
const MEMORY_MS = 60 * 1000;
const STALE_MS = 15 * 60 * 1000;

class PublicStatsStore {
  /**
   * @param {{repo: object, compute?: (repo: object, now: number) => Promise<object>, clock?: () => number,
   *          memoryMs?: number, staleMs?: number, refreshMs?: number, logger?: object}} opts
   */
  constructor({ repo, compute, clock = Date.now, memoryMs = MEMORY_MS, staleMs = STALE_MS, refreshMs = REFRESH_MS, logger = console } = {}) {
    this.repo = repo;
    this.compute = compute || ((r, now) => require('./admin_analytics').communityTotals(r, now));
    this.clock = clock;
    this.memoryMs = memoryMs; this.staleMs = staleMs; this.refreshMs = refreshMs;
    this.log = logger;
    this.mem = null; // { totals, computedAt, readAt }
    this.inflight = null;
    this.computeCount = 0;
  }

  get soda() { return this.repo.soda; }

  /** Computes the totals now and stores them for every node. */
  async refresh() {
    const now = this.clock();
    this.computeCount += 1;
    const totals = await this.compute(this.repo, now);
    try {
      await this.soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, { k: DOC_KEY, totals, computedAt: now });
    } catch (e) {
      this.log.warn?.(`[public-stats] store failed: ${e.message}`);
    }
    this.mem = { totals, computedAt: now, readAt: this.clock() };
    return totals;
  }

  /** The newest totals (from memory, the shared document, or computed once when none is fresh). */
  async get() {
    const now = this.clock();
    if (this.mem && now - this.mem.readAt < this.memoryMs && now - this.mem.computedAt < this.staleMs) return this.mem.totals;
    if (!this.inflight) {
      this.inflight = (async () => {
        const doc = await this.soda.findOne(C.subscriptionConfig, { k: DOC_KEY }).catch(() => null);
        const v = doc && doc.value;
        const at = Number(v && v.computedAt);
        if (v && v.totals && Number.isFinite(at) && now - at < this.staleMs) {
          this.mem = { totals: v.totals, computedAt: at, readAt: now };
          return v.totals;
        }
        return this.refresh();
      })().finally(() => { this.inflight = null; });
    }
    return this.inflight;
  }

  /** Drops the memory copy (an admin change); the next read goes to the shared document. */
  clear() { this.mem = null; }

  /** Registers the refresh on the job lease (one node at a time). */
  start(lease) {
    if (!lease || typeof lease.run !== 'function') return null;
    return lease.run('public-stats', this.refreshMs, () => this.refresh(), { firstDelayMs: 20000 });
  }
}

module.exports = { PublicStatsStore, DOC_KEY, REFRESH_MS, MEMORY_MS, STALE_MS };
