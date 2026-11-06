'use strict';
/**
 * Staff accounts: the people who run CoRoute (admins, and anyone listed in STAFF_EMAILS).
 *
 * Staff are real accounts and can ride, pay and join groups like anyone else, but they are
 * not riders for the numbers: every rider / member / paying / conversion count in the admin
 * console and on the public website leaves them out, so an admin testing the app never
 * inflates the community figures. Rides a staff account took part in still count as rides;
 * they carry `hasStaff: true` so a test ride can be told apart.
 *
 * Guests are a separate category (see isGuestAccount) and keep their own handling.
 *
 * A user is staff when ANY of these holds:
 *   - its role is an admin role (MASTER_ADMIN, ADMIN, or any role naming ADMIN / STAFF);
 *   - its email is in BOOTSTRAP_ADMIN_EMAILS (config.adminEmails, the master admin seed list);
 *   - its email is in the optional STAFF_EMAILS list (config.staffEmails).
 * The lists are read at call time, so a changed config applies without a restart of this module.
 */
// config is read lazily: scripts that load the data layer alone need no full gateway environment.
const cfg = () => require('./config');

/** Roles that are staff by themselves (used for database queries; isStaffRole also matches *ADMIN*). */
const STAFF_ROLES = ['MASTER_ADMIN', 'ADMIN', 'SUPER_ADMIN', 'SUPPORT_ADMIN', 'STAFF'];

function isStaffRole(role) {
  const r = String(role || '').trim().toUpperCase();
  return !!r && (STAFF_ROLES.includes(r) || r.includes('ADMIN'));
}

/** Lowercased staff email addresses (bootstrap admins + STAFF_EMAILS). */
function staffEmails() {
  const out = new Set();
  const config = cfg();
  for (const e of [...(config.adminEmails || []), ...(config.staffEmails || [])]) {
    const v = String(e || '').trim().toLowerCase();
    if (v) out.add(v);
  }
  return out;
}

/** True for an admin or staff account. Null / missing users are never staff. */
function isStaffAccount(user, emails = null) {
  if (!user || typeof user !== 'object') return false;
  if (isStaffRole(user.role)) return true;
  const email = String(user.email || '').trim().toLowerCase();
  return !!email && (emails || staffEmails()).has(email);
}

/** Guest sessions (unchanged rule: provider 'guest' or a placeholder guest address). */
function isGuestAccount(u) {
  return !!u && (u.provider === 'guest' || String(u.email || '').endsWith('@guest.coroute.local'));
}

/** userIds of the staff accounts among `users`. */
function staffIdsOf(users) {
  const emails = staffEmails();
  const ids = new Set();
  for (const u of users || []) if (u && u.userId && isStaffAccount(u, emails)) ids.add(u.userId);
  return ids;
}

/** True when any member id of a convoy document (or a list of ids) is staff. */
function hasStaffMember(memberIds, staffIds) {
  if (!staffIds || !staffIds.size) return false;
  for (const id of memberIds || []) if (staffIds.has(id)) return true;
  return false;
}

module.exports = { STAFF_ROLES, isStaffRole, isStaffAccount, isGuestAccount, staffEmails, staffIdsOf, hasStaffMember };
