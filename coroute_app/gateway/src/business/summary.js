'use strict';
/**
 * Round 6: the weekly owner summary e-mail (docs/intelligence/BUSINESS_ANALYTICS.md).
 *
 * Every Monday at 09:00 India time, in plain language, to the MASTER_ADMIN addresses (accounts with that role and
 * BOOTSTRAP_ADMIN_EMAILS): riders active and new, rides, SOS and crash alerts with how they ended, revenue, the size
 * of the at-risk list and server health. Sent through the gateway's mailer; the words (subject, heading, intro,
 * footer) are the editable template `owner_weekly_summary` (Settings > Templates); the switch is in Settings.
 * Runs under the job lease; the week is claimed with a compare-and-replace, so it is sent once across both nodes.
 * The e-mail holds counts only: no rider names, no addresses, no positions.
 */
const { validEmail } = require('../mailer');
const { weekOf, weekStart } = require('./brain');

const DAY = 86400000;
const IST = 330 * 60000;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const istDate = (ms, year = false) => { const d = new Date(ms + IST); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}${year ? ` ${d.getUTCFullYear()}` : ''}`; };
const inr = (n) => `₹${Math.round(Number(n) || 0).toLocaleString('en-IN')}`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

/** True from Monday 09:00 IST until the end of that Monday. */
function isSummaryTime(now) {
  const d = new Date(now + IST);
  return d.getUTCDay() === 1 && d.getUTCHours() >= 9;
}

class WeeklySummary {
  constructor({ brain, soda, repo, mailer, templates, servers = null, config = {}, logger = console, clock = Date.now } = {}) {
    this.brain = brain; this.soda = soda; this.repo = repo; this.mailer = mailer; this.templates = templates; this.servers = servers;
    this.config = config; this.log = logger; this.clock = clock;
  }

  async settings() {
    const s = (await this.brain.getAgg('settings')) || {};
    return { weeklySummary: s.weeklySummary !== false, updatedAt: s.updatedAt || 0, updatedBy: s.updatedBy || null };
  }

  async setSettings(body, { by = 'admin' } = {}) {
    const b = body && typeof body === 'object' ? body : {};
    if (typeof b.weeklySummary !== 'boolean') throw Object.assign(new Error('weeklySummary must be true or false.'), { status: 400, code: 'BAD_SETTINGS' });
    await this.brain.putAgg('settings', { weeklySummary: b.weeklySummary, updatedBy: String(by).slice(0, 120) });
    return this.settings();
  }

  /** The administrators' addresses: MASTER_ADMIN accounts (verified, active) and BOOTSTRAP_ADMIN_EMAILS. */
  async recipients() {
    const out = new Set();
    for (const e of this.config.adminEmails || []) if (validEmail(e)) out.add(String(e).trim().toLowerCase());
    const rows = await this.soda.query('users', { role: 'MASTER_ADMIN' }, { limit: 50 }).catch(() => []);
    for (const r of rows) {
      const u = r.value;
      if (u && !u.deletedAt && u.emailVerified !== false && (!u.status || u.status === 'ACTIVE') && validEmail(u.email)) out.add(u.email.trim().toLowerCase());
    }
    return [...out].slice(0, 20);
  }

  /** SOS and crash alerts of the last 7 days and how they ended (counts only). */
  async alerts(now) {
    const out = { sos: 0, crash: 0, resolved: 0, falseAlarm: 0, cancelled: 0, open: 0 };
    for (let offset = 0; offset < 5000; offset += 200) {
      const rows = await this.soda.query('alerts', { timestamp: { $gte: now - 7 * DAY } }, { limit: 200, offset }).catch(() => []);
      for (const r of rows) {
        const a = r.value;
        if (!a) continue;
        if (a.auto === true) out.crash++; else out.sos++;
        const st = String(a.status || (a.resolved ? 'RESOLVED' : 'OPEN'));
        if (st === 'FALSE_ALARM') out.falseAlarm++; else if (st === 'CANCELLED') out.cancelled++; else if (a.resolved || st === 'RESOLVED' || st === 'EXPIRED') out.resolved++; else out.open++;
      }
      if (rows.length < 200) break;
    }
    return out;
  }

  /** The numbers and the plain-language lines of this week's e-mail. */
  async compose(now = this.clock()) {
    const [week, revenue, churn, state, al] = await Promise.all([this.brain.getAgg('week'), this.brain.getAgg('revenue'), this.brain.getAgg('churn'), this.brain.getAgg('state'), this.alerts(now)]);
    const health = this.servers ? await this.servers.snapshot().catch(() => null) : null;
    const w = weekOf(now) - 1;
    const range = `${istDate(weekStart(w))} to ${istDate(weekStart(w + 1) - 1, true)}`;
    const wk = week || {};
    const last7 = (revenue && revenue.last7) || { netInr: 0, orders: 0, refundsInr: 0 };
    const renew = (revenue && revenue.renewals) || { in7: 0 };
    const atRisk = churn && Array.isArray(churn.atRisk) ? churn.atRisk.length : 0;
    const lines = [];
    if (!week) lines.push('The business numbers have not been computed yet (they are refreshed every night).');
    else {
      lines.push(`${plural(wk.activeRiders7 || 0, 'rider', 'riders')} opened the app in the last 7 days, out of ${wk.totalRiders || 0}. ${plural(wk.newRiders7 || 0, 'new rider', 'new riders')} signed up.`);
      lines.push(`${plural(wk.ridersRode7 || 0, 'rider', 'riders')} rode, on ${plural(wk.rideDays7 || 0, 'ride day', 'ride days')} in total.`);
    }
    const alerts = al.sos + al.crash;
    lines.push(alerts === 0 ? 'No SOS or crash alert was raised.'
      : `${plural(al.sos, 'SOS alert', 'SOS alerts')} and ${plural(al.crash, 'crash alert', 'crash alerts')}: ${al.resolved} closed as handled, ${al.falseAlarm} false ${al.falseAlarm === 1 ? 'alarm' : 'alarms'}, ${al.cancelled} cancelled${al.open ? `, ${al.open} still open` : ''}.`);
    lines.push(`Revenue: ${inr(last7.netInr)} net from ${plural(last7.orders || 0, 'paid order', 'paid orders')}${last7.refundsInr ? ` (after ${inr(last7.refundsInr)} refunded)` : ''}. ${plural(renew.in7 || 0, 'plan ends', 'plans end')} in the next 7 days.`);
    lines.push(atRisk ? `${plural(atRisk, 'rider is', 'riders are')} on the at-risk list this week. You can send them a win-back e-mail from the Business pages.` : 'No rider is on the at-risk list this week.');
    if (health) {
      const word = { ok: 'healthy', warn: 'need a look', bad: 'need attention now' }[health.status] || 'unknown';
      const notes = health.nodes.flatMap((n) => (n.reachable === false ? [n.error] : n.notes)).concat(health.backup && health.backup.note ? [health.backup.note] : []).filter(Boolean).slice(0, 3);
      lines.push(`Servers: ${word}.${notes.length ? ` ${notes.join(' ')}` : ''}`);
    }
    if (state && state.lastRunAt) lines.push(`Numbers as of ${istDate(state.lastRunAt)}.`);
    const origin = String(this.config.publicOrigin || this.config.linkOrigin || '').replace(/\/+$/, '');
    const vars = { week: range, activeRiders: String(wk.activeRiders7 || 0), newRiders: String(wk.newRiders7 || 0), revenue: inr(last7.netInr), atRisk: String(atRisk), adminUrl: `${origin}/admin#/business` };
    return { vars, lines, range, alerts: al };
  }

  async render(now = this.clock()) {
    const c = await this.compose(now);
    const t = await this.templates.render('owner_weekly_summary', c.vars);
    const text = [t.heading, '', t.intro, '', ...c.lines.map((l) => `- ${l}`), '', t.footer, ''].join('\n');
    const html = `<!doctype html><html><body style="margin:0;padding:24px;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#111827;line-height:1.55">`
      + `<div style="max-width:560px;margin:0 auto"><h1 style="font-size:20px;margin:0 0 12px">${esc(t.heading)}</h1><p style="margin:0 0 12px">${esc(t.intro)}</p>`
      + `<ul style="padding-left:20px;margin:0 0 16px">${c.lines.map((l) => `<li style="margin:0 0 8px">${esc(l)}</li>`).join('')}</ul>`
      + `<p style="margin:0;color:#6b7280;font-size:13px">${esc(t.footer)}</p></div></body></html>`;
    return { subject: t.subject, text, html, lines: c.lines, vars: c.vars };
  }

  /** Sends now to `to` (a list) or the administrators. Returns { sent, failed, recipients }. */
  async send({ to = null, now = this.clock() } = {}) {
    const list = to || await this.recipients();
    const m = await this.render(now);
    let sent = 0; let failed = 0;
    for (const addr of list) {
      const r = await this.mailer.send({ to: addr, subject: m.subject, text: m.text, html: m.html, headers: { 'X-Auto-Response-Suppress': 'All' } });
      if (r.sent) sent++; else failed++;
    }
    return { sent, failed, recipients: list.length };
  }

  /** Leased hourly: sends once per week, on Monday from 09:00 IST, when the switch is on and e-mail is configured. */
  async tick(now = this.clock()) {
    if (!this.brain.enabled || !isSummaryTime(now)) return { skipped: 'NOT_TIME' };
    if (!this.mailer || !this.mailer.enabled) return { skipped: 'MAIL_OFF' };
    if (!(await this.settings()).weeklySummary) return { skipped: 'SWITCHED_OFF' };
    const week = weekOf(now);
    await this.brain.ensureStore();
    let row = await this.soda.findOne('business_agg', { k: 'summary-state' });
    if (!row) {
      await this.soda.insert('business_agg', { k: 'summary-state', week: 0, sentAt: 0 }).catch(() => {});
      row = await this.soda.findOne('business_agg', { k: 'summary-state' });
    }
    if (!row || Number(row.value.week) >= week) return { skipped: 'ALREADY_SENT' };
    // Claim the week first: a second node (or a retry) never sends it again.
    if (!(await this.soda.compareAndReplace('business_agg', row.key, row.value, { ...row.value, week, sentAt: now, result: null }))) return { skipped: 'TAKEN' };
    const out = await this.send({ now }).catch((e) => ({ sent: 0, failed: 0, recipients: 0, error: String(e.message).slice(0, 80) }));
    const cur = await this.soda.findOne('business_agg', { k: 'summary-state' });
    if (cur) await this.soda.replace('business_agg', cur.key, { ...cur.value, result: out }).catch(() => {});
    this.log.info?.(`[business] weekly summary: ${out.sent} sent, ${out.failed} failed`);
    return out;
  }
}

module.exports = { WeeklySummary, isSummaryTime };
