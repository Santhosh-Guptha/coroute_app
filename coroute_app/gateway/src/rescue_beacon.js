'use strict';
/**
 * Round 10 rescue beacon (docs/features_355/rescue_beacon.md).
 *
 * 1. The rescue id: 16 bits that a down rider's phone sends in its near-ultrasonic locator packets
 *    and BLE advertisement, so a responder's phone knows WHICH rider it hears. Derived from the
 *    SOS clientId (else the alertId) exactly like the app (lib/domain/rescue/rescue_id.dart):
 *    FNV-1a 32 over the UTF-8 bytes, folded to 16 bits (xor of the halves), 0 -> 1, sent as 4
 *    lower-case hex digits. Stored on the alert as `rescueId` (publicAlert passes it to the group)
 *    and given to accepted nearby responders in ASSIST_UPDATE. Not a secret, not personal data.
 *
 * 2. RESCUE_PING {alertId} (group member) or {incidentId} (accepted nearby responder): "play a loud
 *    burst now" relayed ONLY to the victim's own sockets. Authorised: a member of the alert's room
 *    (not the victim), or an active responder of the nearby incident. The alert must be open.
 *    Low rate: one per sender per alert every 20 s, and per alert at most one every 5 s and 6 a
 *    minute (whoever sends). The victim's phone rate-limits again (and goes quiet on low battery).
 */
// convoys.js requires this module (rescueIdFor), so ConvoyError is looked up lazily (no require cycle at load).
function convoyError(message, status, reason) {
  const { ConvoyError } = require('./convoys');
  return new ConvoyError(message, status, reason);
}

const RESCUE_ID = /^[0-9a-f]{4}$/;
const ACTIVE_RESPONDER = new Set(['ACCEPTED', 'EN_ROUTE', 'ARRIVING', 'ARRIVED']);
const PING_GAP_SENDER_MS = 20000;
const PING_GAP_ALERT_MS = 5000;
const PING_MAX_PER_MIN = 6;

/** The rescue id ('0001'..'ffff') for an SOS key; '' for an empty key. */
function rescueIdFromKey(key) {
  const s = key === undefined || key === null ? '' : String(key);
  if (!s) return '';
  let h = 0x811c9dc5;
  for (const b of Buffer.from(s, 'utf8')) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  let folded = ((h >>> 16) ^ (h & 0xffff)) & 0xffff;
  if (folded === 0) folded = 1;
  return folded.toString(16).padStart(4, '0');
}

/** The rescue id of a new alert: the phone's own value when well-formed, else from clientId, else alertId. */
function rescueIdFor({ msgRescueId, clientId, alertId }) {
  const given = typeof msgRescueId === 'string' ? msgRescueId.toLowerCase() : '';
  if (RESCUE_ID.test(given) && given !== '0000') return given;
  return rescueIdFromKey(clientId) || rescueIdFromKey(alertId);
}

function firstName(name) {
  const n = String(name || '').trim();
  if (!n) return '';
  const i = n.indexOf(' ');
  return i > 0 ? n.slice(0, i) : n;
}

class RescuePings {
  constructor(convoys, { network = null, now = Date.now } = {}) {
    this.convoys = convoys;
    this.network = network;
    this.now = now;
    this.bySender = new Map(); // `${alertId}|${uid}` -> last ms
    this.byAlert = new Map(); // alertId -> [ms...]
  }

  _sweep(t) {
    if (this.bySender.size > 2000) for (const [k, at] of this.bySender) if (t - at > 60000) this.bySender.delete(k);
    if (this.byAlert.size > 2000) for (const [k, list] of this.byAlert) if (!list.some((x) => t - x < 60000)) this.byAlert.delete(k);
  }

  /** Who is pinged: { gid, uid, alertId } after the checks. Throws ConvoyError otherwise. */
  async _target(groupId, user, msg) {
    const alertId = typeof msg.alertId === 'string' && msg.alertId.length <= 80 ? msg.alertId : '';
    const incidentId = typeof msg.incidentId === 'string' && msg.incidentId.length <= 40 ? msg.incidentId : '';
    if (alertId) {
      const room = await this.convoys.getRoom(groupId);
      if (!room.riders.has(user.userId)) throw convoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
      const a = room.alerts.get(alertId);
      if (!a || a.resolved) throw convoyError('This emergency is closed.', 404, 'ALERT_CLOSED');
      if (a.userId === user.userId) throw convoyError('This is your own SOS.', 403, 'OWN_ALERT');
      return { gid: groupId, uid: a.userId, alertId };
    }
    if (incidentId && this.network && this.network.incidents) {
      const inc = this.network.incidents.get(incidentId);
      const R = inc && inc.responders && inc.responders.get(user.userId);
      if (!inc || !R || !ACTIVE_RESPONDER.has(R.status)) throw convoyError('Only a rider who is helping can ping this phone.', 403, 'NOT_RESPONDER');
      const p = inc.primary || {};
      const room = this.convoys.rooms.get(p.gid);
      const a = room && room.alerts.get(p.alertId);
      if (!a || a.resolved) throw convoyError('This emergency is closed.', 404, 'INCIDENT_CLOSED');
      return { gid: p.gid, uid: a.userId, alertId: p.alertId };
    }
    throw convoyError('Which emergency? Send alertId or incidentId.', 400, 'BAD_PING');
  }

  /** RESCUE_PING. Returns { sent, throttled?, retryInS? }. */
  async ping(groupId, user, msg = {}) {
    const target = await this._target(groupId, user, msg || {});
    const t = this.now();
    this._sweep(t);
    const sk = `${target.alertId}|${user.userId}`;
    const last = this.bySender.get(sk);
    if (last !== undefined && t - last < PING_GAP_SENDER_MS) return { sent: false, throttled: true, retryInS: Math.ceil((PING_GAP_SENDER_MS - (t - last)) / 1000) };
    const list = (this.byAlert.get(target.alertId) || []).filter((x) => t - x < 60000);
    if (list.length >= PING_MAX_PER_MIN || (list.length && t - list[list.length - 1] < PING_GAP_ALERT_MS)) {
      return { sent: false, throttled: true, retryInS: Math.ceil(PING_GAP_ALERT_MS / 1000) };
    }
    list.push(t);
    this.byAlert.set(target.alertId, list);
    this.bySender.set(sk, t);
    this.convoys.emit('userMessage', target.gid, target.uid, {
      type: 'RESCUE_PING', alertId: target.alertId, fromName: firstName(user.name), at: t,
    });
    return { sent: true };
  }
}

module.exports = { rescueIdFromKey, rescueIdFor, RescuePings, RESCUE_ID, PING_GAP_SENDER_MS, PING_GAP_ALERT_MS, PING_MAX_PER_MIN };
