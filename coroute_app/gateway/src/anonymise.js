'use strict';
/**
 * Account deletion for shared records.
 *
 * Records that belong to a group (convoy metadata, trip reports, the group
 * timeline, other riders' trip records) keep their shape so the other
 * members' history still works, but every trace of the deleted rider is
 * replaced: the userId by an anonymous id (the same one everywhere, so a
 * report stays consistent), the name by "Former rider", and phone, e-mail,
 * bike number and emergency contact by empty strings.
 */
const crypto = require('crypto');

const FORMER_RIDER = 'Former rider';

function newAnonId() { return `former_${crypto.randomBytes(5).toString('hex')}`; }

/** What identifies the rider in stored documents. */
function identity(user, anonId = newAnonId()) {
  const secrets = new Set();
  for (const v of [user.email, user.phone, user.emergencyContact, user.emergencyContactName]) {
    const s = String(v || '').trim();
    if (s.length >= 3) secrets.add(s);
  }
  const vehicleNo = String(user.vehicleNo || '').trim();
  if (vehicleNo.length >= 3 && vehicleNo.toUpperCase() !== 'PILLION') secrets.add(vehicleNo);
  return { userId: String(user.userId), anonId, name: String(user.name || '').trim(), secrets };
}

/**
 * Id fields and the name fields that belong to them. When the id is the rider's, the name is
 * replaced whatever it says, so a name the rider used before a rename goes too.
 */
const NAME_OF_ID = {
  userId: ['name', 'userName'],
  senderId: ['senderName'],
  suggestedBy: ['suggestedByName'],
  createdByUserId: ['createdByUserName'],
  withUserId: ['withName'],
  resolvedBy: ['resolvedByName'],
  from: ['fromName'],
};

/**
 * Returns a copy of value with the rider replaced everywhere (strings, object keys, nested).
 * `owned`: the object sits under the rider's userId as a key (members[uid], arrivals[uid]).
 */
function scrub(value, id, owned = false) {
  if (typeof value === 'string') {
    if (value === id.userId) return id.anonId;
    if (id.name && value === id.name) return FORMER_RIDER;
    if (id.secrets.has(value.trim())) return '';
    return value;
  }
  if (Array.isArray(value)) return value.map((v) => scrub(v, id));
  if (value && typeof value === 'object') {
    const names = new Set(owned ? ['name', 'userName'] : []);
    for (const [idField, nameFields] of Object.entries(NAME_OF_ID)) {
      if (value[idField] === id.userId) for (const f of nameFields) names.add(f);
    }
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      let key = k;
      if (k === id.userId) key = id.anonId;
      else if (id.name && k === id.name) key = FORMER_RIDER;
      const next = names.has(k) && typeof v === 'string' && v ? FORMER_RIDER : scrub(v, id, k === id.userId);
      // defineProperty: a key such as "__proto__" stays a plain key.
      Object.defineProperty(out, key, { value: next, enumerable: true, writable: true, configurable: true });
    }
    return out;
  }
  return value;
}

/** Convoy metadata: drops the rider's wait request, then scrubs everything else. */
function scrubConvoyMeta(meta, id) {
  const copy = { ...meta };
  if (copy.waitRequests && id.name && copy.waitRequests[id.name] !== undefined) {
    copy.waitRequests = { ...copy.waitRequests };
    delete copy.waitRequests[id.name];
  }
  return scrub(copy, id);
}

/** True when a document still mentions the rider (used to skip needless writes). */
function mentions(doc, id) {
  const json = JSON.stringify(doc);
  if (json.includes(JSON.stringify(id.userId))) return true;
  if (id.name && json.includes(JSON.stringify(id.name))) return true;
  for (const s of id.secrets) if (json.includes(JSON.stringify(s))) return true;
  return false;
}

module.exports = { FORMER_RIDER, identity, scrub, scrubConvoyMeta, mentions, newAnonId };
