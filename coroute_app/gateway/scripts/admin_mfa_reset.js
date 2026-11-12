'use strict';
/**
 * 3.57 BREAK-GLASS: clears 2-step verification of ONE administrator who lost their phone and recovery codes.
 * Runbook: gateway/deploy/RUNBOOK.md "Admin 2-step break-glass". Run on a gateway VM as the service user, with the
 * production environment loaded (/etc/coroute/gateway.env + /run/coroute/secrets.env):
 *
 *   node scripts/admin_mfa_reset.js <admin e-mail> "<ticket / reason>"
 *
 * What it does: turns 2-step off for that account, ends every session of the account, and writes an audit row
 * (AUTH / MFA_BREAK_GLASS). The admin's next web admin sign-in asks them to enrol again (ADMIN_MFA_ENFORCE=web).
 * It never prints secrets. Two people should be present (four-eyes) and the reason must name the ticket.
 */
const { createSoda } = require('../src/app');
const { Repo } = require('../src/oracle/repo');
const { encryptingSoda, fieldCryptoFromConfig } = require('../src/field_crypto');
const { SessionStore } = require('../src/sessions');
const config = require('../src/config');

(async () => {
  const [email, reason] = process.argv.slice(2);
  if (!email || !reason || reason.length < 6) {
    console.error('usage: node scripts/admin_mfa_reset.js <admin e-mail> "<ticket / reason>"');
    process.exit(2);
  }
  const soda = encryptingSoda(createSoda(), fieldCryptoFromConfig(config, console), { lazy: false });
  const repo = new Repo(soda);
  const user = await repo.findUserByEmail(email);
  if (!user) { console.error('No account with that e-mail.'); process.exit(1); }
  if (user.role !== 'MASTER_ADMIN') { console.error('That account is not an administrator; nothing changed.'); process.exit(1); }
  await repo.updateUser(user.key, { mfaEnabled: false, mfaSecret: '', mfaPendingSecret: '', mfaRecovery: [], mfaLastStep: -1, mfaResetAt: Date.now(), mfaResetReason: String(reason).slice(0, 200), tokensValidAfter: Date.now() });
  const n = await new SessionStore({ soda }).revokeAllForUser(user.userId, 'MFA_BREAK_GLASS', { by: 'break-glass' });
  await soda.insert('safety_audit', { auditId: `AUD-BG-${Date.now()}`, at: Date.now(), kind: 'AUTH', subjectId: user.userId, detail: 'MFA_BREAK_GLASS' });
  console.log(`2-step verification cleared for ${user.userId}; ${n} session(s) ended. The admin enrols again at the next web admin sign-in.`);
})().catch((e) => { console.error(e.message); process.exit(1); });
