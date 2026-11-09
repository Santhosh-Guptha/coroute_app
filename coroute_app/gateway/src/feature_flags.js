'use strict';
/**
 * 3.55 admin feature switches ("kill switches").
 *
 * The master admin can switch a feature off for EVERY rider at once (a feature that misbehaves in the
 * field is stopped without an app release) and back on again. This is a different thing from
 * ./feature_policy (the settings a ride's lead picks for one ride) and from ./entitlements (what a
 * plan includes): a switch here only ever takes a feature away for everyone, temporarily.
 *
 * Rules:
 *  - The catalog below is the only list of switchable features; an unknown id cannot be stored.
 *  - Core safety (SOS, crash detection, emergency texts, medical ID) is `locked`: always on, can never
 *    be stored off, and the apps never gate it.
 *  - Unknown / missing state means `defaultOn`. A database outage never switches anything off: the
 *    last known state stays (and before the first read, the defaults apply).
 *  - State is one document in subscription_config (k='feature_flags') shared by both gateway VMs:
 *    each node re-reads it at least every 30 s, and a change on one node pokes the other at once over
 *    the live mirror (extension 'ff', which only triggers a re-read: the peer's payload is never
 *    trusted as state).
 *  - Lookups (isOn) are a cached map read, never a DB read, so enforcement costs nothing per message.
 */
const { EventEmitter } = require('events');
const { COLLECTIONS: C } = require('./oracle/repo');

const DOC_KEY = 'feature_flags';
const HISTORY_MAX = 50;
const REASON_MAX = 200;
const FEATURE_OFF = 'FEATURE_OFF';
const FEATURE_OFF_MESSAGE = 'This feature is turned off for now.';
const GROUPS = Object.freeze(['Safety', 'Riding', 'Group', 'Places', 'Community', 'Platform']);

const f = (id, group, label, description, extra = {}) => Object.freeze({ id, group, label, description, defaultOn: true, locked: false, ...extra });
/** Every switchable feature. Order = order in the admin console (grouped by `group`). */
const CATALOG = Object.freeze([
  // ---- Safety: the first four are locked (always on) ----
  f('sos', 'Safety', 'SOS', 'One-tap SOS to the group and emergency contacts.', { locked: true }),
  f('crashDetection', 'Safety', 'Crash detection', 'Detects a likely crash and starts the alarm countdown.', { locked: true }),
  f('emergencySms', 'Safety', 'Emergency texts', 'Texts to emergency contacts during an SOS or crash.', { locked: true }),
  f('medicalId', 'Safety', 'Medical ID', 'Medical details on the lock screen and in an SOS.', { locked: true }),
  f('assistNetwork', 'Safety', 'Nearby rider help', 'Asks riders of other groups close to an emergency to help.'),
  f('guardianLink', 'Safety', 'Ride Guardian', 'Family can follow a ride through a private web link.'),
  // 3.55 solo and guardian safety (docs/features_355/solo_guardian.md)
  f('soloCheckIn', 'Safety', 'Solo check-in timer', 'Texts the emergency contact when a solo rider is overdue at the destination and does not answer.'),
  f('noSignalAhead', 'Safety', 'No-signal ahead', 'Tells the group and guardians before a stretch that had no signal on the rider\'s earlier rides.'),
  f('arrivalMessage', 'Safety', 'Arrival message', 'Guardians get "Arrived safely" once at the end of the ride, then the link stops tracking.'),
  f('publicRiderHelp', 'Safety', 'Help from public riders', 'An SOS also asks riders of nearby public rides who agreed to help.'),
  f('sirenDetector', 'Safety', 'Siren detector', 'Listens for ambulance, police and fire engine sirens, lowers the audio and tells the rider.'),
  f('hornAlert', 'Safety', 'Horn close by alert', 'Tells the rider when a vehicle honks close by (on the phone, nothing is recorded).'),
  // 3.55 phone-only sensor safety (free on every plan, no signal needed; logic on the phone).
  f('fatigueScore', 'Safety', 'Fatigue score', 'Break reminders that adapt to ride time, time of day, short stops and steering wobble.'),
  f('riderDown', 'Safety', 'Rider-down check', '"Bike down?" alarm when the bike falls at a stop and nothing moves for a minute.'),
  f('crashLearning', 'Safety', 'Crash detection that learns', 'Each "I\'m OK" tunes low-speed fall and slide thresholds for that bike. Hard impacts always alarm.'),
  f('mountCheck', 'Safety', 'Phone-mount check', 'Tells the rider once per ride when the phone is not in a handlebar mount.'),
  f('sosBatteryReserve', 'Safety', 'SOS battery reserve', 'Below 10% battery in a ride, pauses extras and sends the last location once.'),
  f('safetyReport', 'Safety', 'Ride safety report', 'Private safety summary after the ride, kept on the phone.'),
  // 3.55 road context (phone-only, every plan)
  f('bendWarning', 'Safety', 'Sharp-bend warning', 'Warns before a sharp bend on the route line when riding too fast for it.'),
  f('speedLimits', 'Safety', 'Smart speed limits', 'Warns when over the road\'s limit, stricter near schools and hospitals.'),
  f('altitudeCare', 'Safety', 'High-altitude care', 'Acclimatisation reminders above 3,000 m and on fast climbs.'),
  f('nightCare', 'Safety', 'Night riding care', 'Earlier break prompts and stronger alerts after sunset.'),
  // ---- Riding ----
  f('roadHazards', 'Riding', 'Live road warnings', 'Potholes and speed breakers reported by the lead, warned to the riders behind.'),
  f('roadHistory', 'Riding', 'Saved road reports', 'Road reports from earlier rides, shown on later rides of the same road.'),
  f('offRouteGroupPrompt', 'Riding', 'Off-route group prompt', 'Asks the group what to do when a rider leaves the planned route.'),
  f('fuelAutoRoute', 'Riding', 'Fuel auto-route', 'One tap to route to the nearest fuel when fuel runs low.'),
  f('weather', 'Riding', 'Weather on the route', 'Rain and dark warnings along the planned route.'),
  f('bleRemote', 'Riding', 'Handlebar remote', 'Bluetooth handlebar buttons for talk and signals (the on-screen SOS always works).'),
  f('engineCare', 'Riding', 'Engine care', 'Service reminders and engine care tips in the garage.'),
  f('rideAnalytics', 'Riding', 'Ride analytics', 'Personal ride numbers and charts after a ride.'),
  f('riskyStretch', 'Riding', 'Risky-stretch heads-up', 'Warns of stretches where many riders brake hard (anonymous, 10 riders or more).'),
  f('speedAudio', 'Riding', 'Lower music when speeding', 'Lowers music and other audio while the rider is over the speed limit.'),
  f('callAwareAlerts', 'Riding', 'Calls: hold ride voice, let critical alerts through', 'During a phone call ride announcements wait; crash, SOS and other critical alerts still play.'),
  // ---- Group ----
  f('rideRoles', 'Group', 'Riding roles', 'Lead, middle and sweeper roles, swaps and role prompts.'),
  f('autoRoles', 'Group', 'Automatic roles', 'Roles follow the riders\' order along the route.'),
  f('intercom', 'Group', 'Group talk', 'Push-to-talk voice with the group.'),
  f('groupFuel', 'Group', 'Group fuel stop', 'Shares fuel range so the group stops before anyone runs dry.'),
  f('publicRide', 'Group', 'Public ride', 'Shows the ride to nearby riders, safe contact and shared road warnings.'),
  f('discovery', 'Group', 'Nearby groups', 'Tells a group when another CoRoute group rides close by.'),
  f('voiceCleanup', 'Group', 'Intercom voice cleanup: noise, wind and breath', 'Removes engine noise, wind and breathing from group talk before it is sent.'),
  f('riderVehicleLive', 'Group', 'Live bike change', 'Changing the active garage bike in a ride updates the colour and model the group sees at once.'),
  f('vehicleSwap', 'Group', 'Bike swap', 'Two riders swap bikes mid-ride and the app follows.'),
  f('pillionSeat', 'Group', 'Pillion seat', 'A pillion confirms whose bike they sit on; the group sees one bike with two people.'),
  // 3.55 group safety (logic on the phones; the gateway relays and stores)
  f('missingRiderCheck', 'Group', 'Missing-rider check', 'Asks a rider who stopped while the group moved on if they are OK, then tells the lead.'),
  f('stretchAlert', 'Group', 'Group stretch alert', 'Tells the lead when the group spreads out more than the set distance.'),
  f('regroupSuggest', 'Group', 'Smart regroup point', 'Suggests a fuel, food or rest stop ahead where the group can gather.'),
  f('groupBreak', 'Group', 'Group break planner', 'Suggests one group break when several riders need rest (levels only).'),
  f('buddyPairs', 'Group', 'Buddy pairs', 'In large groups each rider watches one buddy, with a one-tap check.'),
  f('rollCall', 'Group', 'Start and arrival roll call', 'Who has joined at the start and who has arrived at the end, in the ride sheet.'),
  // ---- Places ----
  f('essentials', 'Places', 'Stops on the way', 'Fuel, food and rest stops along the route.'),
  f('mapPlaces', 'Places', 'Map places', 'Places layer on the ride map.'),
  f('placeReviews', 'Places', 'Place reviews', 'Rider reviews and photos of places.'),
  f('heritagePlaces', 'Places', 'Heritage places', 'Heritage and sightseeing places near the route.'),
  // ---- Community ----
  f('reviewPrompt', 'Community', 'Ride review prompt', 'Asks riders to review the ride after it ends.'),
  f('communityStatsWebsite', 'Community', 'Website community numbers', 'Rider, ride and kilometre totals on the public website.'),
  // 3.55 friends and profile pictures (docs/features_355/usernames_friends_profiles.md). Usernames are core (no switch).
  f('friends', 'Community', 'Friends', 'Add riders as friends by username or invite link and see friends\' ride totals.'),
  f('profilePhotos', 'Community', 'Profile photos', 'Riders can add a profile picture shown on their profile, to friends and to their ride group.'),
  // 3.55 crews (docs/features_355/crews_polls.md): standing circles of friends; polls only, no chat.
  f('crews', 'Community', 'Crews', 'Riders create crews and invite their friends. Off: crews and crew invites are hidden.'),
  f('crewPolls', 'Community', 'Crew polls', 'Crew admins (and members, if allowed) ask the crew a question with fixed options. No chat.'),
  f('crewRides', 'Community', 'Start a ride with this crew', 'The host of a ride invites chosen crew members; they accept or decline. Off: no crew ride invites.'),
  // 3.55 rider score (docs/features_355/rider_score.md)
  f('riderScore', 'Community', 'Rider score', 'A private 0-100 score of safe riding (speed discipline, smoothness, safety habits, regular riding) with tips.'),
  f('leaderboard', 'Community', 'Public leaderboard', 'Top riders by score, distance, hours and rides, by username only. Off: the lists are empty.'),
  // ---- Platform ----
  f('offlineMesh', 'Platform', 'No-internet link', 'Phone-to-phone link for positions when there is no network.'),
  f('adminWarnings', 'Platform', 'Moderator warnings', 'Delivers a moderator\'s warning on a public-ride report to the rider as an in-app notice.'),
  // 3.55 admin-only tool (docs/features_355/marketing_studio.md): off answers 403 FEATURE_OFF on /admin/marketing/*.
  f('marketingStudio', 'Platform', 'Marketing studio', 'Admin image creator for coupon and special-offer posts (admin console only).'),
  // 3.55 push notifications (docs/features_355/push_notifications.md): off = the gateway sends no FCM pushes.
  f('pushNotifications', 'Platform', 'Push notifications', 'Friend requests, crew invites, polls and ride invites reach the phone when the app is closed.'),
]);
const BY_ID = new Map(CATALOG.map((e) => [e.id, e]));
const ID_RE = /^[A-Za-z][A-Za-z0-9]{1,39}$/;

/** Effective map {id: bool} for every catalog feature from a stored {id: bool} (anything else ignored). */
function effectiveFlags(stored) {
  const out = {};
  for (const e of CATALOG) {
    const v = stored && Object.hasOwn(stored, e.id) ? stored[e.id] : undefined;
    out[e.id] = e.locked ? true : (typeof v === 'boolean' ? v : e.defaultOn);
  }
  return out;
}

/** Only catalog ids with boolean values, never a locked feature stored off. */
function cleanStored(stored) {
  const out = {};
  if (!stored || typeof stored !== 'object' || Array.isArray(stored)) return out;
  for (const [id, v] of Object.entries(stored)) {
    const e = BY_ID.get(id);
    if (!e || typeof v !== 'boolean') continue;
    if (e.locked) continue;
    out[id] = v;
  }
  return out;
}

class FeatureFlagError extends Error {
  constructor(message, status = 400, code = 'BAD_FEATURE') { super(message); this.statusCode = status; this.code = code; }
}

class FeatureFlags extends EventEmitter {
  /**
   * @param {{repo?: any, soda?: any, logger?: any, refreshMs?: number, clock?: () => number}} opts
   */
  constructor({ repo = null, soda = null, logger = console, refreshMs = 30000, clock = Date.now } = {}) {
    super();
    this.soda = soda || repo?.soda || null;
    this.log = logger;
    this.refreshMs = Math.max(1000, Math.min(refreshMs, 30000));
    this.clock = clock;
    this.stored = {};
    this.flags = effectiveFlags({});
    this.updatedAt = 0;
    this.updatedBy = null;
    this.history = [];
    this.timer = null;
    this.mirror = null; // set by Mirror.register('ff', this)
    this._refreshing = null;
  }

  static catalog() { return CATALOG; }

  /** True unless the admin switched `id` off. Unknown ids and locked features are always on. */
  isOn(id) {
    const e = BY_ID.get(id);
    if (!e || e.locked) return true;
    return this.flags[id] !== false;
  }

  anyOff() { return CATALOG.some((e) => this.flags[e.id] === false); }

  /** What riders get (GET /api/features, the FEATURE_FLAGS push). */
  snapshot() { return { flags: { ...this.flags }, updatedAt: this.updatedAt }; }

  /** Applies a stored document; emits 'change' with the snapshot when the effective state moved. */
  _apply(doc) {
    const stored = cleanStored(doc?.flags);
    const next = effectiveFlags(stored);
    const at = Number(doc?.updatedAt) || 0;
    const changed = CATALOG.some((e) => next[e.id] !== this.flags[e.id]);
    this.stored = stored;
    this.flags = next;
    this.history = Array.isArray(doc?.history) ? doc.history.slice(-HISTORY_MAX) : [];
    this.updatedBy = doc?.updatedBy || null;
    const newer = at !== this.updatedAt;
    this.updatedAt = at;
    if (changed || newer) this.emit('change', this.snapshot(), { changed });
    return changed;
  }

  async _read() {
    if (!this.soda) return null;
    const r = await this.soda.findOne(C.subscriptionConfig, { k: DOC_KEY });
    return r ? r.value : null;
  }

  /** Re-reads the document. On a read error the last known state stays (never switches features off). */
  refresh() {
    if (this._refreshing) return this._refreshing;
    this._refreshing = (async () => {
      try {
        const doc = await this._read();
        if (doc) this._apply(doc);
        else if (this.updatedAt) this._apply({ flags: {}, updatedAt: 0 }); // document removed: defaults
      } catch (e) {
        this.log.warn?.(`[features] refresh failed, keeping last known state: ${e.message}`);
      } finally {
        this._refreshing = null;
      }
    })();
    return this._refreshing;
  }

  start() {
    if (this.timer) return this;
    this.timer = setInterval(() => { this.refresh(); }, this.refreshMs);
    if (this.timer.unref) this.timer.unref();
    return this;
  }

  stop() { if (this.timer) clearInterval(this.timer); this.timer = null; }

  /**
   * Admin switch. Validated here (never trust the client): a catalog id, a boolean, a locked feature
   * is never switched off, and a reason (1..200 chars) is required to switch a feature off.
   * Read-modify-write on the freshest document so a change made on the other node is kept.
   */
  async set(id, enabled, { by = 'admin', byUserId = null, reason = '' } = {}) {
    if (typeof id !== 'string' || !ID_RE.test(id) || !BY_ID.has(id)) throw new FeatureFlagError('Unknown feature.', 400, 'UNKNOWN_FEATURE');
    const e = BY_ID.get(id);
    if (typeof enabled !== 'boolean') throw new FeatureFlagError('enabled must be true or false.', 400, 'BAD_FEATURE');
    if (e.locked) throw new FeatureFlagError(`${e.label} is a core safety feature and is always on.`, 400, 'FEATURE_LOCKED');
    const why = typeof reason === 'string' ? reason.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim() : '';
    if (why.length > REASON_MAX) throw new FeatureFlagError(`Reason must be at most ${REASON_MAX} characters.`, 400, 'BAD_REASON');
    if (!enabled && !why) throw new FeatureFlagError('Say why the feature is being turned off.', 400, 'REASON_REQUIRED');
    if (!this.soda) throw new FeatureFlagError('Feature switches are not available.', 503, 'UNAVAILABLE');

    const doc = (await this._read()) || {};
    const stored = cleanStored(doc.flags);
    const previous = effectiveFlags(stored)[id];
    stored[id] = enabled;
    const at = Math.max(this.clock(), (Number(doc.updatedAt) || 0) + 1);
    const history = Array.isArray(doc.history) ? doc.history.slice(-(HISTORY_MAX - 1)) : [];
    history.push({ id, enabled, previous, by: String(by).slice(0, 120), reason: why, at });
    const next = { k: DOC_KEY, flags: stored, updatedAt: at, updatedBy: String(by).slice(0, 120), updatedByUserId: byUserId, history };
    await this.soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, next);
    this._apply(next);
    // The other gateway re-reads the document now instead of within 30 s.
    try { if (this.mirror) this.mirror.ext('ff', { op: 'REFRESH', at }); } catch { /* the 30 s re-read still converges */ }
    return { entry: history[history.length - 1], previous };
  }

  /** The admin view: catalog + state + the last changes (newest first). */
  adminView() {
    const lastBy = new Map();
    for (const h of this.history) if (h && typeof h.id === 'string') lastBy.set(h.id, h);
    return {
      ok: true,
      groups: GROUPS,
      updatedAt: this.updatedAt,
      updatedBy: this.updatedBy,
      features: CATALOG.map((e) => ({
        id: e.id, label: e.label, description: e.description, group: e.group,
        defaultOn: e.defaultOn, locked: e.locked, enabled: this.isOn(e.id),
        lastChange: lastBy.get(e.id) || null,
      })),
      history: [...this.history].reverse(),
    };
  }

  // ---- mirror extension 'ff': a poke only, the database is the truth ----
  exportState() { return { at: this.updatedAt }; }
  importState() { this.refresh(); }
  applyRemote() { this.refresh(); }
}

// ------------------------------------------------------------------ enforcement helpers
/** PR_* / road warning messages that start something new (closing, blocking and reporting stay allowed). */
const PR_NEW = new Set(['PR_CONTACT', 'PR_REPLY', 'PR_SAY', 'PR_SHARE_LOC', 'PR_SHARE_CONTACT', 'ROAD_WARN', 'ROAD_WARN_VOTE']);
const WS_FEATURE = Object.freeze({
  ROAD_HAZARD: ['roadHazards'],
  ROLE_SWAP: ['rideRoles'],
  SWAP_REQUEST: ['vehicleSwap'],
  SWAP_ANSWER: ['vehicleSwap'],
  BUDDY_ASSIGN: ['buddyPairs'],
  BUDDY_PING: ['buddyPairs'],
  WAVE: ['discovery'],
  SIGNAL_AHEAD: ['noSignalAhead'],
  RIDER_VEHICLE: ['riderVehicleLive'],
  PILLION_SEAT: ['pillionSeat'],
});
/**
 * Feature ids a socket message needs ([] = none). Turning something OFF is always allowed (automatic
 * roles off, public ride visibility off), and nothing on the SOS / safety lanes is ever listed.
 */
function wsFeaturesFor(msg) {
  const type = msg && typeof msg.type === 'string' ? msg.type : '';
  if (WS_FEATURE[type]) return WS_FEATURE[type];
  if (type === 'ROLE_SET') return String(msg.role || '').toUpperCase() === 'LEAD' ? ['rideRoles'] : [];
  if (type === 'ROLE_AUTO') return msg.on === true ? ['rideRoles', 'autoRoles'] : [];
  if (PR_NEW.has(type)) return ['publicRide'];
  if (type === 'PR_PREFS') return msg.showNearby === true || msg.roadWarnings === true ? ['publicRide'] : [];
  return [];
}

/** The first feature in `ids` that is switched off, or null. */
function firstOff(flags, ids) {
  if (!flags || !ids || !ids.length) return null;
  for (const id of ids) if (!flags.isOn(id)) return id;
  return null;
}

const offBody = (id) => ({ error: FEATURE_OFF_MESSAGE, code: FEATURE_OFF, feature: id });

/** Express guard: 403 FEATURE_OFF while `id` is switched off. `flagsOf` is read per request (no DB). */
function requireFeature(flagsOf, id) {
  return (req, res, next) => {
    const flags = typeof flagsOf === 'function' ? flagsOf() : flagsOf;
    if (flags && !flags.isOn(id)) return res.status(403).set('Cache-Control', 'no-store').json(offBody(id));
    return next();
  };
}

// ------------------------------------------------------------------ routes
/**
 * Public (before authentication): the website's community numbers answer "not shown" while
 * communityStatsWebsite is off, in the same shape as the admin's "hide numbers" setting, so the
 * website simply hides the section.
 */
function registerFeatureFlagPublicGuards({ r, flagsOf }) {
  const off = () => { const fl = flagsOf(); return !!fl && !fl.isOn('communityStatsWebsite'); };
  // One route per path (string paths keep the router introspectable by the admin-guard test).
  const usageOff = (req, res, next) => (off()
    ? res.set('Cache-Control', 'public, max-age=60').json({ ok: true, enabled: false, stats: null, code: FEATURE_OFF })
    : next());
  const communityOff = (req, res, next) => (off()
    ? res.set('Cache-Control', 'public, max-age=60').json({ enabled: false, message: FEATURE_OFF_MESSAGE, code: FEATURE_OFF })
    : next());
  for (const p of ['/public/usage-stats', '/usage-stats', '/public/impact-stats', '/impact-stats', '/public/alltime-stats', '/alltime-stats']) r.get(p, usageOff);
  for (const p of ['/public/community-stats', '/community-stats']) r.get(p, communityOff);
}

/**
 * Authenticated routes (registered after requireAuth): the riders' read, the admin console and the
 * guards in front of the REST features the server serves. Must be registered BEFORE the routes it
 * guards (road_and_places, geo).
 */
function registerFeatureFlagRoutes({ r, flagsOf, repo, wrap, requireAdmin }) {
  const rateLimit = require('express-rate-limit');
  const readLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many requests.' } });
  const writeLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many changes. Wait a minute.' } });

  // Riders: the effective switches. Short cache: the socket push is the fast path.
  r.get('/features', readLimiter, (req, res) => {
    const fl = flagsOf();
    const snap = fl ? fl.snapshot() : { flags: effectiveFlags({}), updatedAt: 0 };
    res.set('Cache-Control', 'private, max-age=30').json({ ok: true, ...snap });
  });

  r.get('/admin/features', requireAdmin, wrap(async (req, res) => {
    const fl = flagsOf();
    if (!fl) return res.status(503).json({ error: 'Feature switches are not available.' });
    await fl.refresh(); // the admin sees the database state, also a change made on the other node
    res.set('Cache-Control', 'no-store').json(fl.adminView());
  }));

  r.put('/admin/features/:id', requireAdmin, writeLimiter, wrap(async (req, res) => {
    const fl = flagsOf();
    if (!fl) return res.status(503).json({ error: 'Feature switches are not available.' });
    const body = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
    if (body.reason !== undefined && typeof body.reason !== 'string') return res.status(400).json({ error: 'Reason must be text.', code: 'BAD_REASON' });
    let result;
    try {
      result = await fl.set(String(req.params.id || ''), body.enabled, {
        by: req.user?.email || req.user?.userId || 'admin', byUserId: req.user?.userId || null, reason: body.reason || '',
      });
    } catch (e) {
      if (e instanceof FeatureFlagError) return res.status(e.statusCode).json({ error: e.message, code: e.code });
      throw e;
    }
    // Audited like every admin write (subscription_config k='audit', shown in Settings > Audit log).
    if (repo && typeof repo.addAuditEntry === 'function') {
      try {
        await repo.addAuditEntry({ at: Date.now(), by: req.user?.email || req.user?.userId || 'admin', byUserId: req.user?.userId || null,
          action: body.enabled ? 'feature.on' : 'feature.off', target: result.entry.id,
          details: { enabled: body.enabled, previous: result.previous, reason: result.entry.reason } });
      } catch { /* never in the way */ }
    }
    res.set('Cache-Control', 'no-store').json({ ok: true, feature: fl.adminView().features.find((x) => x.id === result.entry.id), ...fl.snapshot() });
  }));

  // ---- server-side enforcement of REST features (admin moderation under /admin stays available) ----
  r.use('/road-hazards/near', requireFeature(flagsOf, 'roadHistory'));
  r.use('/places', requireFeature(flagsOf, 'placeReviews'));
  r.use('/geo/essentials', requireFeature(flagsOf, 'essentials'));
  r.use('/geo/weather', requireFeature(flagsOf, 'weather'));
  r.use('/geo/poi-cells', requireFeature(flagsOf, 'mapPlaces'));
}

module.exports = {
  CATALOG, GROUPS, FEATURE_OFF, FEATURE_OFF_MESSAGE, REASON_MAX, DOC_KEY,
  FeatureFlags, FeatureFlagError, effectiveFlags, cleanStored, wsFeaturesFor, firstOff, requireFeature,
  registerFeatureFlagPublicGuards, registerFeatureFlagRoutes,
};
