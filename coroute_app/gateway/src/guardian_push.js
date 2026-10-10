'use strict';
const crypto = require('crypto');
const { GuardianError } = require('./guardians');
const digest = (v) => crypto.createHash('sha256').update(JSON.stringify(v)).digest('hex');
const HOSTS = new Set(['fcm.googleapis.com', 'updates.push.services.mozilla.com', 'web.push.apple.com']);

function subscriptionOf(input) {
  if (!input || typeof input.endpoint !== 'string' || input.endpoint.length > 2048) throw new GuardianError('Invalid push subscription.', 400);
  let u;
  try { u = new URL(input.endpoint); } catch { throw new GuardianError('Invalid push subscription.', 400); }
  if (u.protocol !== 'https:' || !HOSTS.has(u.hostname) || u.port || u.username || u.password || u.hash ||
      !/^[A-Za-z0-9_-]{87}$/.test(input.keys?.p256dh || '') || !/^[A-Za-z0-9_-]{22}$/.test(input.keys?.auth || '')) {
    throw new GuardianError('This push provider or subscription is not supported.', 400);
  }
  return { endpoint: u.href, keys: { p256dh: input.keys.p256dh, auth: input.keys.auth } };
}

// Deliberately excludes names, coordinates, counts and routine movement.
function stateOf(view) {
  const incidents = view.alerts || (view.riders || []).flatMap((r) => r.alerts || []);
  return { tripStatus: view.tripStatus, emergency: view.emergency,
    incidents: incidents.map((a) => [a.type, a.reportedAt, a.status || null]).sort() };
}

/** Durable current-state delivery; failures never run on the rider SOS path. */
class GuardianPush {
  constructor({ repo, service, send, publicKey, clock = Date.now }) {
    this.repo = repo; this.service = service; this.send = send; this.publicKey = publicKey;
    this.clock = clock; this.running = false; this.stopped = false; this.offset = 0;
  }
  start() {
    this.timer = setInterval(() => this.tick().catch(() => {}), 15000);
    this.timer.unref?.();
  }
  stop() { this.stopped = true; clearInterval(this.timer); }

  async subscribe(credential, input, preferences = {}) {
    if (!preferences || typeof preferences !== 'object' || Array.isArray(preferences) || Object.keys(preferences).some((k) => !['emergencies', 'trip'].includes(k) || typeof preferences[k] !== 'boolean')) throw new GuardianError('Invalid notification preferences.', 400);
    const grant = await this.service.sessionGrant(credential);
    const subscription = subscriptionOf(input);
    const view = await this.service.viewGrant(grant.grantId);
    const subscriptionId = digest([grant.grantId, subscription.endpoint]);
    if (await this.repo.guardianRevoked(subscriptionId)) throw new GuardianError('Alerts were disabled for this link on this browser. Use a new link to enable again.', 409);
    const allowed = { emergencies: preferences.emergencies !== false, trip: preferences.trip !== false };
    await this.repo.saveGuardianSubscription({ subscriptionId, grantId: grant.grantId,
      subscription, preferences: allowed, expiresAt: view.expiresAt, state: stateOf(view), sequence: 0, version: crypto.randomUUID() });
    return { subscriptionId, expiresAt: view.expiresAt };
  }

  async unsubscribe(credential, subscriptionId) {
    const grant = await this.service.sessionGrant(credential);
    const sub = await this.repo.getGuardianSubscription(subscriptionId);
    if (sub && sub.grantId !== grant.grantId) throw new GuardianError('Not found.', 404);
    if (sub) await this.repo.revokeGuardianGrant({ grantId: subscriptionId, revokedAt: this.clock(), expiresAt: sub.expiresAt });
    await this.repo.removeGuardianSubscription(subscriptionId);
  }

  async tick() {
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      const now = this.clock(), views = new Map();
      const viewFor = (grantId) => {
        if (!views.has(grantId)) views.set(grantId, this.service.viewGrant(grantId));
        return views.get(grantId);
      };
      const subs = await this.repo.listGuardianSubscriptions(now, this.offset);
      this.offset = subs.length < 100 ? 0 : this.offset + subs.length;
      for (const sub of subs) {
        try {
          if (await this.repo.guardianRevoked(sub.subscriptionId)) { await this.repo.removeGuardianSubscription(sub.subscriptionId); continue; }
          const view = await viewFor(sub.grantId), state = stateOf(view);
          const incidentChanged = digest(state.incidents) !== digest(sub.state.incidents) || state.emergency !== sub.state.emergency;
          const tripChanged = state.tripStatus !== sub.state.tripStatus;
          if ((incidentChanged && sub.preferences.emergencies) || (tripChanged && sub.preferences.trip && view.level !== 'EMERGENCY_ONLY')) {
            // Queue before advancing the cursor: a crash cannot silently lose a change.
            await this.repo.enqueueGuardianJob({ jobId: digest([sub.subscriptionId, sub.version, (sub.sequence || 0) + 1, state]),
              subscriptionId: sub.subscriptionId, grantId: sub.grantId, subscriptionVersion: sub.version, state: 'PENDING',
              target: state, attempts: 0, nextAttemptAt: now, expiresAt: now + 10 * 60000 });
          }
          if (digest(state) !== digest(sub.state)) await this.repo.saveGuardianSubscription({ ...sub, state, sequence: (sub.sequence || 0) + 1 });
        } catch (e) {
          if (e instanceof GuardianError && e.code !== 'GUARDIAN_PAUSED') await this.repo.removeGuardianSubscription(sub.subscriptionId);
          // A temporary database failure retains the subscription and cursor.
        }
      }
      for (const job of await this.repo.listGuardianJobs(now)) {
        if (this.stopped) break;
        try {
          const sub = await this.repo.getGuardianSubscription(job.subscriptionId);
          if (!sub || sub.version !== job.subscriptionVersion || await this.repo.guardianRevoked(job.subscriptionId) || now >= job.expiresAt || now >= sub.expiresAt) { job.state = 'CANCELLED'; }
          else {
            // Fresh authorization immediately before send; no permission cache across jobs.
            const view = await this.service.viewGrant(job.grantId);
            if (digest(stateOf(view)) !== digest(job.target)) job.state = 'CANCELLED';
            else {
              const ticket = await this.service.ticket(job.grantId);
              const latest = await this.repo.getGuardianSubscription(job.subscriptionId);
              if (this.stopped || !latest || latest.version !== sub.version || await this.repo.guardianRevoked(job.subscriptionId)) {
                job.state = 'CANCELLED'; await this.repo.saveGuardianJob(job); continue;
              }
              await this.send(sub.subscription, JSON.stringify({ title: 'CoRoute trip update',
                body: 'Open Ride Guardian for the latest shared update.', tag: job.jobId,
                url: `/watch#ticket=${ticket.credential}` }), {
                TTL: 300, urgency: job.target.emergency ? 'high' : 'normal', topic: job.jobId.slice(0, 32), timeout: 8000 });
              job.state = 'SENT';
            }
          }
        } catch (e) {
          if (e.code === 'GUARDIAN_PAUSED') job.state = 'CANCELLED';
          else if (e instanceof GuardianError || e.statusCode === 404 || e.statusCode === 410) {
            job.state = 'CANCELLED'; await this.repo.removeGuardianSubscription(job.subscriptionId);
          } else {
            job.attempts++;
            job.nextAttemptAt = now + Math.min(300000, 15000 * 2 ** job.attempts);
            if (job.attempts >= 5) job.state = 'FAILED';
          }
        }
        await this.repo.saveGuardianJob(job);
      }
    } finally { this.running = false; }
  }
}
module.exports = { GuardianPush, subscriptionOf, stateOf };
