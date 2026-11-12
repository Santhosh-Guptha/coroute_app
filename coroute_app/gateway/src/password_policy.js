'use strict';
/**
 * 3.57 security: password rules for every new password (register, change, reset, admin temporary passwords
 * are generated, not checked). NIST SP 800-63B style:
 *   - at least 8 characters, at most 200 (never a maximum below 64)
 *   - not on the bundled list of common / breached passwords (and not a trivial variant: case, trailing
 *     digits or "!" removed), not "coroute"-based, not the e-mail, its local part or the callsign
 *   - not one repeated character or a straight keyboard / number run
 * No composition rules (they make passwords weaker in practice). Messages are short and specific.
 */

// The most common passwords of 8+ characters from public breach corpora (shorter ones fail the length rule).
const COMMON = new Set(`
password password1 password12 password123 password1234 passw0rd p@ssw0rd p@ssword pa55word passwort
12345678 123456789 1234567890 0123456789 987654321 9876543210 11111111 111111111 00000000 12341234 123123123
1q2w3e4r 1q2w3e4r5t 1qaz2wsx qwertyui qwertyuiop qwerty123 qwerty1234 asdfghjk asdfghjkl zxcvbnm1 zxcvbnmm
iloveyou iloveyou1 sunshine princess football baseball welcome1 welcome123 letmein1 letmein123 monkey123
dragon123 master123 superman batman123 trustno1 starwars whatever abcd1234 abc12345 abcdefgh abcdefg1
admin123 admin1234 administrator root1234 changeme changeme1 default1 secret123 test1234 testtest
qazwsxedc michael1 jennifer computer internet samsung1 google123 facebook linkedin1 mustang1 shadow12
charlie1 jordan23 hunter12 freedom1 ashley12 bailey12 access14 flower12 cheese12 killer12 summer12
india123 india@123 bharat123 hindustan krishna1 ganesh123 jaimatadi omnamahshivaya sairam123 hanuman1
motorcycle motorbike bullet350 royalenfield himalayan classic350 harley123 ducati123 yamaha123 pulsar220
rider123 biker123 ride1234 coroute coroute1 coroute123 coroute@123 corouteapp
`.trim().split(/\s+/));

const RUNS = ['abcdefghijklmnopqrstuvwxyz', '01234567890', 'qwertyuiop', 'asdfghjkl', 'zxcvbnm'];

class PasswordPolicyError extends Error {
  constructor(message) { super(message); this.name = 'PasswordPolicyError'; this.status = 422; this.code = 'WEAK_PASSWORD'; }
}

/** The problem with `password`, or null when it is acceptable. */
function passwordProblem(password, { email = '', name = '' } = {}) {
  if (typeof password !== 'string' || password.length < 8) return 'Use at least 8 characters.';
  if (password.length > 200) return 'Use at most 200 characters.';
  const lower = password.toLowerCase();
  // Trivial variants: "Password1", "password123!", "Sunshine!" read as the listed word.
  const stripped = lower.replace(/!+$/, '').replace(/\d+$/, '').replace(/[!@.]+$/, '');
  if (COMMON.has(lower) || COMMON.has(stripped) || (stripped.length >= 4 && COMMON.has(`${stripped}123`))) return 'This password is too common. Choose something harder to guess.';
  if (/^coroute/.test(stripped)) return 'Do not use "CoRoute" as your password.';
  if (/^(.)\1+$/.test(password)) return 'Do not use one repeated character.';
  for (const run of RUNS) {
    if (run.includes(lower) || run.split('').reverse().join('').includes(lower)) return 'Do not use a straight run of keys or numbers.';
  }
  const e = String(email || '').trim().toLowerCase();
  const local = e.split('@')[0];
  if (e && (lower === e || (local.length >= 4 && (lower === local || stripped === local)))) return 'Do not use your e-mail address as your password.';
  const n = String(name || '').trim().toLowerCase().replace(/\s+/g, '');
  if (n.length >= 4 && (lower.replace(/\s+/g, '') === n || stripped === n)) return 'Do not use your callsign as your password.';
  return null;
}

/** Throws PasswordPolicyError (422, WEAK_PASSWORD) when the password is not acceptable. */
function assertPasswordOk(password, ctx = {}) {
  const p = passwordProblem(password, ctx);
  if (p) throw new PasswordPolicyError(p);
}

module.exports = { passwordProblem, assertPasswordOk, PasswordPolicyError, COMMON };
