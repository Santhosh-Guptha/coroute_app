'use strict';
/**
 * Post-trip rider reviews ("community stories").
 *
 * Rules (enforced here and in the routes that use this module):
 *  - Only a rider who took part in a trip that has ENDED may review it (their own
 *    trip record with an end time, or a member of an ENDED convoy).
 *  - One review per rider per trip: the id is derived from (tripId, userId), so a
 *    second submission updates the first instead of creating a duplicate.
 *  - Every new or edited review is PENDING_REVIEW and is never public until an
 *    admin APPROVES it. Approval needs the rider's publication consent.
 *  - The public view never carries the rider's name, email, phone, ids or
 *    coordinates; photos are public only when the rider consented AND an admin
 *    selected them.
 */
const crypto = require('crypto');
const { toDay } = require('./public_privacy');

const STATUS = Object.freeze({
  PENDING: 'PENDING_REVIEW',
  APPROVED: 'APPROVED',
  REJECTED: 'REJECTED',
  CHANGES_REQUESTED: 'CHANGES_REQUESTED',
  WITHDRAWN: 'WITHDRAWN',
});

/** Admin actions and the status each one leads to (null: status unchanged). */
const ADMIN_ACTIONS = Object.freeze({
  APPROVE: STATUS.APPROVED,
  REJECT: STATUS.REJECTED,
  REQUEST_CHANGES: STATUS.CHANGES_REQUESTED,
  REQUEST_CLARIFICATION: STATUS.CHANGES_REQUESTED, // older admin builds
  WITHDRAW: STATUS.WITHDRAWN,
  EDIT: null,
});

const LIMITS = Object.freeze({
  writtenFeedback: 1500,
  safetyExperience: 1000,
  suggestions: 1000,
  formattedText: 1000,
  adminNotes: 1000,
  reason: 500,
  photos: 5,
  photoUrl: 500,
  place: 60,
  tripName: 80,
  chips: 10,
});

const TRIP_ID = /^[A-Za-z0-9_-]{4,80}$/;
const PHOTO_EXT = /\.(jpe?g|png|webp)$/i;
/** Uploaded photo ids (see review_photos.js); stored in `photos` next to older https links. */
const UPLOAD_ID = /^rp_[a-f0-9]{24}$/;
const isUploadId = (v) => typeof v === 'string' && UPLOAD_ID.test(v);

/**
 * Website card templates. The admin app and the website share these ids (keep
 * lib/presentation/admin/admin_reviews_screen.dart and public/assets/site.js in step).
 * minPhotos/maxPhotos: how many selected photos the card shows.
 */
const TEMPLATES = Object.freeze([
  Object.freeze({ id: 'photo-left', label: 'Photo beside story', minPhotos: 1, maxPhotos: 1 }),
  Object.freeze({ id: 'photo-top', label: 'Photo above story', minPhotos: 1, maxPhotos: 1 }),
  Object.freeze({ id: 'quote-card', label: 'Quote card (no photo)', minPhotos: 0, maxPhotos: 0 }),
  Object.freeze({ id: 'gallery', label: 'Photo gallery', minPhotos: 2, maxPhotos: 3 }),
]);
const TEMPLATE_IDS = TEMPLATES.map((t) => t.id);
/** Layout names used by earlier admin builds, and the template each one now means. */
const LEGACY_LAYOUTS = Object.freeze({
  'text-left-pic-right': 'photo-left',
  'pic-left-text-right': 'photo-left',
  'pic-top-text-bottom': 'photo-top',
  'multi-pic-grid': 'gallery',
  'text-only': 'quote-card',
});
const templateOf = (id) => TEMPLATES.find((t) => t.id === id) || null;
const canonicalTemplate = (v) => (TEMPLATE_IDS.includes(v) ? v : (LEGACY_LAYOUTS[v] || null));

/**
 * The template a story is shown with, given how many photos it may show. A template that needs
 * more photos than there are falls back to one that fits; no choice picks by photo count.
 */
function resolveTemplate(chosen, photoCount) {
  const n = Math.max(0, Number(photoCount) || 0);
  const t = canonicalTemplate(chosen);
  if (t) {
    const def = templateOf(t);
    if (n >= def.minPhotos) return t;
    if (t === 'gallery' && n >= 1) return 'photo-top';
    return 'quote-card';
  }
  return n >= 2 ? 'gallery' : n === 1 ? 'photo-left' : 'quote-card';
}

const EMAIL_RE = /[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}/i;
const PHONE_RE = /\+?\d[\d\s().-]{7,}\d/g;
/**
 * 'email' | 'phone' | null: contact details a public excerpt must not carry. A phone is any run
 * of 10 or more digits (spaces, dots, dashes and brackets allowed between them).
 */
function contactInfoIn(text) {
  const s = String(text || '');
  if (EMAIL_RE.test(s)) return 'email';
  const runs = s.match(PHONE_RE) || [];
  if (runs.some((r) => r.replace(/\D/g, '').length >= 10)) return 'phone';
  return null;
}

class ReviewError extends Error {
  constructor(status, message, code, fields) {
    super(message);
    this.status = status;
    this.code = code;
    if (fields) this.fields = fields;
  }
}

/** Plain text only: tags removed, control characters dropped, whitespace tidied. */
function plainText(v) {
  if (v === undefined || v === null) return '';
  return String(v)
    .replace(/<[^>]*>/g, ' ')
    .replace(/[<>]/g, '')
    .replace(/[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u2028\u2029]/g, ' ')
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .split('\n').map((l) => l.trim()).join('\n')
    .trim();
}

/** A photo reference we are willing to store: https or site-relative, an image extension, no tricks. */
function photoRef(v) {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  if (!s || s.length > LIMITS.photoUrl || /[\s"'<>\\]/.test(s)) return null;
  let path;
  if (s.startsWith('/') && !s.startsWith('//')) {
    if (s.includes('..')) return null;
    path = s.split(/[?#]/)[0];
  } else {
    let u;
    try { u = new URL(s); } catch { return null; }
    if (u.protocol !== 'https:' || u.username || u.password) return null;
    path = u.pathname;
  }
  return PHOTO_EXT.test(path) ? s : null;
}

function stableReviewId(tripId, userId) {
  const h = crypto.createHash('sha256').update(`${tripId}\u0000${userId}`).digest('hex').slice(0, 20).toUpperCase();
  return `FB-${h}`;
}

/**
 * Validates a rider's submission. Returns the clean fields or throws ReviewError(422).
 * Over-long text is refused (the app caps input), never silently cut.
 */
function validateSubmission(body) {
  const b = body && typeof body === 'object' ? body : {};
  const fields = {};
  const rating = b.rating;
  if (typeof rating !== 'number' || !Number.isInteger(rating) || rating < 1 || rating > 5) fields.rating = 'Choose a rating from 1 to 5 stars.';

  const text = (k, alias) => plainText(b[k] !== undefined ? b[k] : (alias ? b[alias] : ''));
  const writtenFeedback = text('writtenFeedback', 'feedback');
  const safetyExperience = text('safetyExperience');
  const suggestions = text('suggestions');
  if (writtenFeedback.length > LIMITS.writtenFeedback) fields.writtenFeedback = `Please keep it under ${LIMITS.writtenFeedback} characters.`;
  if (safetyExperience.length > LIMITS.safetyExperience) fields.safetyExperience = `Please keep it under ${LIMITS.safetyExperience} characters.`;
  if (suggestions.length > LIMITS.suggestions) fields.suggestions = `Please keep it under ${LIMITS.suggestions} characters.`;

  let rawPhotos = Array.isArray(b.photos) ? b.photos : (b.photoUrl ? [b.photoUrl] : []);
  rawPhotos = rawPhotos.filter((p) => p !== null && p !== undefined && p !== '');
  const photos = [];
  // Ids of photos uploaded earlier that the rider keeps (the route checks they are really theirs).
  const keepUploads = [];
  if (rawPhotos.length > LIMITS.photos) fields.photos = `Add up to ${LIMITS.photos} photos.`;
  else {
    for (const p of rawPhotos) {
      if (isUploadId(p)) { if (!keepUploads.includes(p)) keepUploads.push(p); continue; }
      const ok = photoRef(p);
      if (!ok) { fields.photos = 'Photos must be JPEG, PNG or WebP images on a secure (https) link.'; break; }
      if (!photos.includes(ok)) photos.push(ok);
    }
  }
  if (Object.keys(fields).length) throw new ReviewError(422, 'Please correct the highlighted fields.', 'INVALID_REVIEW', fields);

  // 3.55 quick chips ("Great route", "Good pace"...; ids from the engagement config, src/engagement.js).
  const chips = [];
  if (Array.isArray(b.chips)) {
    for (const x of b.chips) {
      const id = typeof x === 'string' ? x.trim() : '';
      if (/^[a-z][a-z0-9_]{0,31}$/.test(id) && !chips.includes(id)) chips.push(id);
      if (chips.length >= LIMITS.chips) break;
    }
  }
  const consentTripDetails = b.consentTripDetails === true;
  const photoTick = b.consentPhoto === true || b.consentPhotos === true;
  // Publication consent: explicit when sent; older builds only sent the trip-details consent.
  const consentPublish = b.consentPublish !== undefined ? b.consentPublish === true : (consentTripDetails || (photoTick && photos.length > 0));
  // The photo box reads "CoRoute may publish this photo and story": it only counts with publication consent.
  // Photos the rider did not agree to show are not kept at all (uploads included).
  const consentPhoto = photoTick && consentPublish;
  return {
    rating, writtenFeedback, safetyExperience, suggestions, chips,
    photos: consentPhoto ? photos : [], keepUploads: consentPhoto ? keepUploads : [],
    consentPublish, consentTripDetails, consentPhoto,
  };
}

const tripEnded = (t, now) => {
  const end = Number(t.endTimeEpochMs) || 0;
  const start = Number(t.startTimeEpochMs) || 0;
  return end > 0 && end <= now + 5 * 60000 && !(start > 0 && end < start);
};

const ACTIVE_STATUSES = ['PLANNING', 'STARTED', 'PAUSED'];

/** The rider's member record on a convoy (live map, or the durable summary kept at the end), or null. */
function memberOf(meta, userId) {
  if (!meta || !userId) return null;
  const m = meta.members && meta.members[userId];
  if (m) return m;
  const list = Array.isArray(meta.memberSummary) ? meta.memberSummary : [];
  return list.find((x) => x && x.userId === userId) || null;
}

/** Has this member's part of the ride finished? The whole convoy ended, or they left it (and did not rejoin). */
function memberFinished(meta, m) {
  if (meta.tripStatus === 'ENDED') return true;
  if (!ACTIVE_STATUSES.includes(meta.tripStatus)) return false;
  const left = Number(m.leftAt) || 0;
  return left > 0 && left >= (Number(m.joinedAt) || 0);
}

/**
 * Every id one rider's review of one ride may be stored under. The app opens the review from the
 * convoy (groupId, right after the ride) and from trip history (the rider's trip record
 * `TRIP-<convoy>-<userId>`); both name the same ride, so both must find the same review.
 */
function relatedReviewIds(tripId, userId) {
  const id = String(tripId || '');
  const out = [id];
  if (!TRIP_ID.test(id) || !userId) return out;
  if (id.startsWith('GRP-')) {
    const rec = `TRIP-${id.slice(4)}-${userId}`;
    if (TRIP_ID.test(rec)) out.push(rec);
  } else {
    const suffix = `-${userId}`;
    if (id.startsWith('TRIP-') && id.endsWith(suffix) && id.length > 5 + suffix.length) {
      out.push(`GRP-${id.slice(5, id.length - suffix.length)}`);
    }
  }
  return out;
}

const NOT_PARTICIPANT = () => new ReviewError(403, 'Only riders who took part in this trip can review it.', 'NOT_PARTICIPANT');
const NOT_COMPLETED = () => new ReviewError(409, 'You can review this trip once it has ended.', 'TRIP_NOT_COMPLETED');

/**
 * May [userId] review [tripId]? Resolves to { trip, reviewTripId, reviewIds } (a snapshot of
 * public-safe trip facts, the id a new review is stored under, every id an earlier review of the
 * same ride may carry) or throws ReviewError: 400 bad id, 404 unknown trip, 403 not a participant,
 * 409 not finished.
 * [tripId] is the rider's trip record id, or a convoy groupId the rider was a member of. A trip
 * record that names a convoy is checked against that convoy's member list (a phone-made record
 * alone never proves the rider was there).
 */
async function checkEligibility({ repo }, tripId, userId, now = Date.now()) {
  if (!TRIP_ID.test(String(tripId || ''))) throw new ReviewError(400, 'Unknown trip.', 'BAD_TRIP_ID');
  const metaOf = async (gid) => (gid && typeof repo.getConvoyMeta === 'function' ? repo.getConvoyMeta(gid).catch(() => null) : null);
  const trip = await repo.getTrip(tripId).catch(() => null);
  if (trip) {
    if (trip.userId !== userId) throw NOT_PARTICIPANT();
    if (!tripEnded(trip, now)) throw NOT_COMPLETED();
    let reviewTripId = tripId;
    if (trip.groupId) {
      const meta = await metaOf(trip.groupId);
      if (meta) {
        const m = memberOf(meta, userId);
        if (!m) throw NOT_PARTICIPANT();
        // Still riding in that convoy (it is active and they have not left): not finished yet.
        if (!memberFinished(meta, m)) throw NOT_COMPLETED();
        reviewTripId = meta.groupId || trip.groupId;
      } else if (trip.source !== 'server') {
        // A phone's record naming a convoy the server has no trace of cannot be verified.
        throw NOT_PARTICIPANT();
      }
    }
    return { trip: snapshotOfTrip(trip), reviewTripId, reviewIds: [...new Set([reviewTripId, ...relatedReviewIds(tripId, userId)])] };
  }
  const meta = await metaOf(tripId);
  if (!meta) throw new ReviewError(404, 'Trip not found.', 'TRIP_NOT_FOUND');
  const member = memberOf(meta, userId);
  if (!member) throw NOT_PARTICIPANT();
  if (!memberFinished(meta, member)) throw NOT_COMPLETED();
  // The rider's own trip record (built by the server from their track) has their real distance.
  const recordId = relatedReviewIds(tripId, userId)[1];
  const record = recordId ? await repo.getTrip(recordId).catch(() => null) : null;
  const own = record && record.userId === userId ? record : null;
  const mine = meta.report && Array.isArray(meta.report.members) ? meta.report.members.find((m) => m.userId === userId) : null;
  const memberEnd = meta.tripStatus === 'ENDED' ? 0 : (Number(member.leftAt) || 0);
  return {
    trip: snapshotOfTrip({
      tripName: meta.name,
      totalDistanceKm: own && Number(own.totalDistanceKm) > 0 ? own.totalDistanceKm
        : (mine && mine.distanceM ? mine.distanceM / 1000 : (meta.report?.group?.distanceM || 0) / 1000),
      startLocationName: meta.startLocationName || meta.start?.name || '',
      destinationName: meta.destinationName || '',
      startTimeEpochMs: meta.startedAt || meta.createdAtEpochMs || 0,
      // The convoy stores its end as endedAtEpochMs; updatedAt moves with every later save.
      endTimeEpochMs: memberEnd || meta.endedAtEpochMs || meta.endedAt || meta.updatedAt || 0,
    }),
    reviewTripId: meta.groupId || tripId,
    reviewIds: [...new Set([meta.groupId || tripId, ...relatedReviewIds(tripId, userId)])],
  };
}

/** The rider's newest review stored under any of [ids], or null. */
async function findOwnReview(repo, ids, userId) {
  let best = null;
  for (const id of [...new Set(ids)]) {
    const r = await repo.findTripFeedbackFor(id, userId);
    if (r && (!best || (r.updatedAt || r.submittedAt || 0) > (best.updatedAt || best.submittedAt || 0))) best = r;
  }
  return best;
}

/** Public-safe facts about a trip, captured when the review is written (names only, never coordinates). */
function snapshotOfTrip(t) {
  const km = Number(t.totalDistanceKm || (t.distanceM ? t.distanceM / 1000 : 0)) || 0;
  const start = Number(t.startTimeEpochMs) || 0;
  const end = Number(t.endTimeEpochMs) || 0;
  const days = start > 0 && end > start ? Math.max(1, Math.ceil((end - start) / 86400000)) : 1;
  const place = (s) => plainText(s).slice(0, LIMITS.place);
  return {
    tripName: plainText(t.tripName).slice(0, LIMITS.tripName) || 'Motorcycle ride',
    distanceKm: Math.max(0, Math.round(km)),
    routeFrom: place(t.startLocationName),
    routeTo: place(t.destinationName),
    durationDays: days,
    tripEndedAt: end || null,
  };
}

/** The rider's own view of their review (status and the admin's reason, no audit trail). */
function riderView(doc) {
  if (!doc) return null;
  return {
    feedbackId: doc.feedbackId,
    tripId: doc.tripId,
    tripName: doc.tripName,
    rating: doc.rating,
    writtenFeedback: doc.writtenFeedback || '',
    safetyExperience: doc.safetyExperience || '',
    suggestions: doc.suggestions || '',
    chips: Array.isArray(doc.chips) ? doc.chips : [],
    photos: doc.photos || [],
    photoUrl: ((doc.photos || []).find((p) => !isUploadId(p))) || null,
    // Uploaded photos, viewable by the rider through GET /api/trips/:tripId/feedback/photos/:photoId.
    uploadedPhotos: uploadsOf(doc).map((u) => ({ id: u.id, mime: u.mime, width: u.width || null, height: u.height || null, url: `/trips/${encodeURIComponent(doc.tripId)}/feedback/photos/${u.id}` })),
    consentPublish: doc.consentPublish === true,
    consentTripDetails: doc.consentTripDetails === true,
    consentPhoto: doc.consentPhoto === true,
    status: doc.status,
    statusReason: doc.statusReason || '',
    submittedAt: doc.submittedAt,
    updatedAt: doc.updatedAt || doc.submittedAt,
    approvedAt: doc.approvedAt || null,
  };
}

/** Upload metadata kept with a review (only entries whose id is still in `photos`). */
function uploadsOf(doc) {
  const own = Array.isArray(doc && doc.photos) ? doc.photos : [];
  return (Array.isArray(doc && doc.uploads) ? doc.uploads : []).filter((u) => u && isUploadId(u.id) && own.includes(u.id));
}

/** Public address of a photo: uploads go through the checked media route, links stay as they are. */
function publicPhotoSrc(doc, p) {
  return isUploadId(p) ? `/api/public/review-photos/${encodeURIComponent(doc.feedbackId)}/${p}` : p;
}

/** May this stored review be shown publicly at all? */
function isPublic(doc) {
  return !!doc && doc.status === STATUS.APPROVED && publishConsent(doc);
}

/** Older records have no explicit publication consent: the trip-details consent stood for it. */
function publishConsent(doc) {
  if (doc.consentPublish !== undefined) return doc.consentPublish === true;
  return doc.consentTripDetails === true || doc.consentPhoto === true;
}

/** Photos that may be public: admin-selected, among the rider's own, with photo consent. */
function publicPhotos(doc) {
  if (doc.consentPhoto !== true) return [];
  const own = Array.isArray(doc.photos) ? doc.photos : [];
  const sel = Array.isArray(doc.selectedPhotos) ? doc.selectedPhotos : [];
  return sel.filter((p) => own.includes(p)).slice(0, LIMITS.photos);
}

/** The public story: no names, emails, phones, ids or coordinates. */
function publicStory(doc, idx, cfg = {}) {
  const prefix = plainText(cfg.labelPrefix || 'Rider').slice(0, 30) || 'Rider';
  const label = cfg.showAnonymousLabels === false ? 'CoRoute Rider' : `${prefix} #${idx + 1}`;
  const details = doc.consentTripDetails === true && doc.showTripDetails !== false;
  const selected = publicPhotos(doc);
  const template = resolveTemplate(doc.template || doc.templateLayout || doc.layout, selected.length);
  const shown = selected.slice(0, templateOf(template).maxPhotos);
  const photos = shown.map((p) => publicPhotoSrc(doc, p));
  const uploads = uploadsOf(doc);
  const photoSizes = shown.map((p) => {
    const u = uploads.find((x) => x.id === p);
    return u && u.width && u.height ? { width: u.width, height: u.height } : null;
  });
  const layout = doc.templateLayout || doc.layout || template;
  const text = plainText(doc.formattedText || doc.writtenFeedback || '');
  return {
    feedbackId: doc.feedbackId,
    tripName: details ? (doc.tripName || 'Motorcycle ride') : 'A CoRoute ride',
    rating: doc.rating,
    formattedText: text,
    writtenFeedback: text, // the public excerpt: the rider's raw text is only public through it
    photos,
    photoSizes,
    selectedPhotos: photos, // older website builds
    template,
    distanceKm: details && doc.distanceKm > 0 ? doc.distanceKm : null,
    routeFrom: details ? (doc.routeFrom || null) : null,
    routeTo: details ? (doc.routeTo || null) : null,
    durationDays: details ? (doc.durationDays || null) : null,
    riderLabel: label,
    anonymousRiderLabel: label,
    templateLayout: layout,
    layout,
    // Dates to the day only: the website shows month and year, and a finer time could point at one ride.
    approvedAt: toDay(doc.approvedAt),
    submittedAt: toDay(doc.submittedAt),
  };
}

/** Approved, consented stories, newest approval first, plus a summary. */
async function communityStories(repo, limit = 10) {
  const n = Math.min(50, Math.max(1, Number.parseInt(limit, 10) || 10));
  const [rows, cfg] = await Promise.all([
    repo.listApprovedStories(Math.min(200, n * 4)).catch(() => []),
    typeof repo.getCommunityStatsConfig === 'function' ? repo.getCommunityStatsConfig().catch(() => ({})) : {},
  ]);
  const approved = rows.filter(isPublic)
    .sort((a, b) => (b.approvedAt || b.submittedAt || 0) - (a.approvedAt || a.submittedAt || 0))
    .slice(0, n);
  const stories = approved.map((d, i) => publicStory(d, i, cfg || {}));
  const rated = stories.filter((s) => Number.isFinite(s.rating));
  const averageRating = rated.length ? Math.round((rated.reduce((a, s) => a + s.rating, 0) / rated.length) * 10) / 10 : null;
  return { ok: true, stories, summary: { count: stories.length, averageRating } };
}

/** Admin moderation input, validated. Throws ReviewError(400/422). */
function validateModeration(body) {
  const b = body && typeof body === 'object' ? body : {};
  const action = String(b.action || '').toUpperCase();
  if (!Object.prototype.hasOwnProperty.call(ADMIN_ACTIONS, action)) {
    throw new ReviewError(400, `Valid action required: ${Object.keys(ADMIN_ACTIONS).join(', ')}`, 'BAD_ACTION');
  }
  const fields = {};
  const reason = plainText(b.reason !== undefined ? b.reason : (action === 'REJECT' || action.startsWith('REQUEST_') ? (b.adminNotes || b.notes) : ''));
  const adminNotes = plainText(b.adminNotes !== undefined ? b.adminNotes : b.notes);
  if ((action === 'REJECT' || action === 'REQUEST_CHANGES' || action === 'REQUEST_CLARIFICATION') && !reason) {
    fields.reason = 'Tell the rider why.';
  }
  if (reason.length > LIMITS.reason) fields.reason = `Please keep it under ${LIMITS.reason} characters.`;
  if (adminNotes.length > LIMITS.adminNotes) fields.adminNotes = `Please keep it under ${LIMITS.adminNotes} characters.`;
  let formattedText;
  if (b.formattedText !== undefined && b.formattedText !== null) {
    formattedText = plainText(b.formattedText);
    if (formattedText.length > LIMITS.formattedText) fields.formattedText = `Please keep the excerpt under ${LIMITS.formattedText} characters.`;
  }
  let selectedPhotos;
  if (Array.isArray(b.selectedPhotos)) {
    if (b.selectedPhotos.length > LIMITS.photos) fields.selectedPhotos = `Select up to ${LIMITS.photos} photos.`;
    else selectedPhotos = b.selectedPhotos.filter((p) => typeof p === 'string');
  }
  // `template` (one of TEMPLATES) or, from older admin builds, `templateLayout` (a legacy layout name).
  let templateLayout;
  let template;
  const rawTemplate = b.template !== undefined && b.template !== null && b.template !== '' ? b.template : b.templateLayout;
  if (rawTemplate !== undefined && rawTemplate !== null && rawTemplate !== '') {
    templateLayout = String(rawTemplate);
    template = canonicalTemplate(templateLayout) || undefined;
    if (!template) fields[b.template !== undefined ? 'template' : 'templateLayout'] = `Use one of: ${TEMPLATE_IDS.join(', ')}.`;
  }
  if (formattedText) {
    const found = contactInfoIn(formattedText);
    if (found) fields.formattedText = found === 'email' ? 'Remove the e-mail address from the public excerpt.' : 'Remove the phone number from the public excerpt.';
  }
  const showTripDetails = typeof b.showTripDetails === 'boolean' ? b.showTripDetails : undefined;
  if (Object.keys(fields).length) throw new ReviewError(422, 'Please correct the highlighted fields.', 'INVALID_MODERATION', fields);
  return { action, nextStatus: ADMIN_ACTIONS[action], reason, adminNotes, formattedText, selectedPhotos, template, templateLayout, showTripDetails };
}

/** Admin list item: everything an admin needs, plus whether it can go public. */
function adminView(doc) {
  const { key, ...rest } = doc;
  const uploads = uploadsOf(doc);
  const selected = Array.isArray(doc.selectedPhotos) ? doc.selectedPhotos : [];
  const pub = publicPhotos(doc);
  return {
    ...rest,
    consentPublish: publishConsent(doc),
    canPublish: publishConsent(doc),
    publicPhotos: pub,
    template: resolveTemplate(doc.template || doc.templateLayout, pub.length),
    templateChosen: canonicalTemplate(doc.template) || null,
    // Every photo the rider attached, with an admin-only address for uploads (relative to /api).
    photoItems: (Array.isArray(doc.photos) ? doc.photos : []).map((p) => {
      const u = uploads.find((x) => x.id === p);
      return {
        id: p,
        uploaded: !!u,
        url: u ? `/admin/reviews/${encodeURIComponent(doc.feedbackId)}/photos/${p}` : p,
        width: (u && u.width) || null,
        height: (u && u.height) || null,
        selected: selected.includes(p),
      };
    }),
    excerptContact: contactInfoIn(doc.formattedText || doc.writtenFeedback || ''),
  };
}

module.exports = {
  STATUS, ADMIN_ACTIONS, LIMITS, ReviewError,
  TEMPLATES, TEMPLATE_IDS, LEGACY_LAYOUTS, canonicalTemplate, resolveTemplate, templateOf, contactInfoIn, isUploadId, uploadsOf, publicPhotoSrc,
  plainText, photoRef, stableReviewId, validateSubmission, checkEligibility, snapshotOfTrip, relatedReviewIds, findOwnReview, memberOf, memberFinished,
  riderView, isPublic, publishConsent, publicPhotos, publicStory, communityStories, validateModeration, adminView,
};
