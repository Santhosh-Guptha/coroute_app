'use strict';
/**
 * Round 4 security e-mails (docs/features_355/sessions_and_security.md §9): ride sign-in code, "signed in during a
 * ride" notice, sign-up verification, "someone tried to create an account with your e-mail", account deletion
 * confirmation (builds before 10025) and the e-mail 2-step code.
 *
 * Every message is plain text plus a small HTML part (one table, inline styles, no images, no remote content) so it
 * reads the same in Gmail, Outlook and phone mail apps. Every variable is HTML-escaped; links are only ever built
 * from PUBLIC_ORIGIN and a token generated here. Sent through the SMTP mailer (src/mailer.js) as transactional mail
 * (header X-CoRoute-Mail: security): never suppressed by marketing preferences, never logged with the address.
 */

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const oneLine = (s, max = 80) => String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, max);

/**
 * Template definitions. `lines(v)` returns paragraphs; an entry { code } is shown big, { link, label } as a button.
 * Variables are fixed per template (tests render every one).
 */
const TEMPLATES = Object.freeze({
  ride_signin_code: {
    subject: () => 'Ride sign-in code',
    lines: (v) => [
      `Hi ${v.name},`,
      `Someone (hopefully you) is trying to sign in on ${v.device} while you're on a ride on ${v.otherDevice}.`,
      { code: v.code },
      `Code: ${v.code}. It works once, for ${v.minutes} minutes. Entering it signs the other phone out; the ride and any open SOS stay with your group.`,
      "If this wasn't you, change your password.",
    ],
  },
  ride_signin_notice: {
    subject: () => 'Signed in during a ride',
    lines: (v) => [
      `Hi ${v.name},`,
      `Your CoRoute account was signed in on ${v.device} with an e-mail code at ${v.at}, while ${v.otherDevice} was on a ride. ${v.otherDevice} was signed out and your group saw "${v.name} switched phones". Any open SOS stays open.`,
      'If this was not you, change your password now and choose "Sign out of all devices".',
      { link: v.securityUrl, label: 'Review where you are signed in' },
    ],
  },
  register_verify: {
    subject: () => 'Confirm your e-mail to finish creating your CoRoute account',
    lines: (v) => [
      `Hi ${v.name},`,
      `Confirm this address to finish creating your CoRoute account. The link works once, for ${v.hours} hours.`,
      { link: v.link, label: 'Confirm my e-mail' },
      `Or open: ${v.link}`,
      'If you did not sign up, ignore this e-mail: nothing is created and the details are removed after 7 days.',
    ],
  },
  register_exists: {
    subject: () => 'Someone tried to create a CoRoute account with your e-mail',
    lines: (v) => [
      `Hi ${v.name},`,
      'Someone tried to create an account with your e-mail; if it was you, sign in or reset your password.',
      { link: v.signinUrl, label: 'Sign in' },
      `Forgot your password? Use "Forgot password?" on ${v.signinUrl}.`,
      'If it was not you, you can ignore this e-mail. Your account has not changed.',
    ],
  },
  delete_confirm: {
    subject: () => 'Confirm deleting your CoRoute account',
    lines: (v) => [
      `Hi ${v.name},`,
      `Your CoRoute app asked to delete your account and everything in it. To confirm, open this link within ${v.minutes} minutes. It works once.`,
      { link: v.link, label: 'Delete my account' },
      `Or open: ${v.link}`,
      'If you did not ask for this, ignore this e-mail and change your password: your account stays as it is.',
    ],
  },
  mfa_email_code: {
    subject: () => 'Your CoRoute sign-in code',
    lines: (v) => [
      `Hi ${v.name},`,
      `Your 2-step verification code for ${v.where}:`,
      { code: v.code },
      `It works once, for ${v.minutes} minutes. CoRoute never asks for this code by phone or chat.`,
      'If you are not signing in, change your password.',
    ],
  },
});

/** Renders a template: { subject, text, html }. Unknown ids throw (a programming error). */
function render(id, vars = {}, { origin = '' } = {}) {
  const t = TEMPLATES[id];
  if (!t) throw new Error(`unknown security e-mail ${id}`);
  const v = {};
  for (const [k, val] of Object.entries(vars)) v[k] = k === 'link' || k.endsWith('Url') ? String(val || '') : oneLine(val);
  if (!v.name) v.name = 'rider';
  const items = t.lines(v);
  const subject = oneLine(t.subject(v), 150);
  const footer = origin ? `${origin}/security` : '';
  const text = [
    ...items.map((it) => (typeof it === 'string' ? it : it.code ? `    ${it.code}` : `${it.label}: ${it.link}`)),
    '', '— CoRoute', footer,
  ].join('\n\n').replace(/\n{3,}/g, '\n\n');
  const p = (s) => `<p style="margin:0 0 14px 0;font-size:15px;line-height:1.5;color:#1b1f24">${esc(s)}</p>`;
  const body = items.map((it) => {
    if (typeof it === 'string') return p(it);
    if (it.code) return `<p style="margin:6px 0 18px 0;font-size:30px;letter-spacing:6px;font-weight:700;font-family:Consolas,Menlo,monospace;color:#1b1f24">${esc(it.code)}</p>`;
    return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 18px 0"><tr><td style="background:#d94f00;border-radius:6px">`
      + `<a href="${esc(it.link)}" style="display:inline-block;padding:12px 20px;color:#ffffff;font-weight:700;font-size:15px;text-decoration:none">${esc(it.label)}</a></td></tr></table>`;
  }).join('');
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + `<title>${esc(subject)}</title></head><body style="margin:0;padding:0;background:#f3f4f6">`
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6"><tr><td align="center" style="padding:24px 12px">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:8px"><tr><td style="padding:24px 24px 8px 24px;font-family:Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
    + `<p style="margin:0 0 18px 0;font-size:13px;font-weight:700;letter-spacing:1px;color:#d94f00">COROUTE</p>${body}`
    + `<p style="margin:18px 0 16px 0;font-size:12px;color:#5b6470">This is a security message about your CoRoute account.${footer ? ` <a href="${esc(footer)}" style="color:#5b6470">${esc(footer)}</a>` : ''}</p>`
    + '</td></tr></table></td></tr></table></body></html>';
  return { subject, text, html };
}

module.exports = { TEMPLATES, render, esc };
