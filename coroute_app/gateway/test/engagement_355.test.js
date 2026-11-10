'use strict';
/**
 * 3.55 ratings & reviews engagement (src/engagement.js, docs/features_355/ratings_reviews.md):
 * config validation (incl. the Play policy guard against prices, coupons, incentives and gating
 * wording), versioned save / restore, the app config endpoint, in-app feedback (sanitised, rate
 * limited, admin inbox), review chips on trip and place reviews, and the admin stats.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'engadmin@coroute.test';
const test = require('node:test');
const assert = require('node:assert/strict');
const E = require('../src/engagement');
const { boot } = require('./_helpers');

const clone = (v) => JSON.parse(JSON.stringify(v));

// ------------------------------------------------------------------ pure: validation & guard
test('defaults pass their own validation and keep the owner rules', () => {
  const c = E.validateConfig(clone(E.DEFAULT_CONFIG));
  assert.equal(c.ratingPrompt.afterRides, 3);
  assert.equal(c.ratingPrompt.cooldownDays, 30);
  assert.equal(c.ratingPrompt.maxPerYear, 3);
  assert.equal(c.reviews.reportDays, 7);
  assert.deepEqual(c.tripChips.map((x) => x.id), ['great_route', 'good_pace', 'too_fast', 'long_breaks', 'bad_roads', 'safe_group']);
  for (const g of E.CHIP_GROUPS) assert.ok(c.placeChips[g].length > 0, g);
  assert.deepEqual(c.placeChips.stay.map((x) => x.id), ['clean', 'bike_parking', 'safe', 'good_value']);
  for (const k of Object.keys(E.TEXT_KEYS)) for (const l of E.LANGS) assert.ok(c.texts[k][l], `${k}.${l}`);
});

test('policy guard: prices, coupons, rewards, incentives and gating are refused (en/hi/te)', () => {
  const bad = {
    'Rate us to get a free month': 'OFFER',
    'Only ₹99 for Pro': 'MONEY',
    'Rs 50 off your plan': 'MONEY',
    'Use coupon RIDE10': 'OFFER',
    '20% off today': 'OFFER',
    'Win a helmet!': 'REWARD',
    'Earn points for every review': 'REWARD',
    'Review us and get a badge': 'REWARD',
    'Give 5 stars for a gift': 'REWARD',
    'Rate us to unlock themes': 'REWARD',
    'Enjoying CoRoute? Rate us on Google Play': 'GATING',
    'Love the app? Leave a review': 'GATING',
    'Not happy? Send us feedback instead': 'GATING',
    'मुफ़्त सदस्यता पाएं': 'MONEY',
    'कूपन पाएं': 'OFFER',
    'ఉచిత బహుమతి': 'OFFER',
  };
  for (const [text, code] of Object.entries(bad)) assert.equal(E.policyProblem(text), code, text);
  for (const ok of ['How was the ride?', 'Great view', 'Good value', 'Places you stopped at', 'Rate CoRoute', 'Share your opinion on Google Play', 'Bike parking', 'Viewpoints on the way']) {
    assert.equal(E.policyProblem(ok), null, ok);
  }
});

test('validateConfig: field errors for bad text, chips and numbers; unknown keys dropped', () => {
  const c = clone(E.DEFAULT_CONFIG);
  c.texts.tripTitle = { en: 'Rate us to win a prize', hi: 'ठीक', te: '' };
  c.texts.placesTitle = { hi: 'सिर्फ़ हिंदी' };
  c.tripChips = [{ id: 'Great Route', label: { en: 'x' } }, { id: 'ok', label: { en: 'Fine' } }, { id: 'ok', label: { en: 'Dup' } }, { id: 'cash', label: { en: 'Cashback inside' } }];
  c.placeChips.stay = new Array(11).fill(0).map((_, i) => ({ id: `c${i}`, label: { en: `C${i}` } }));
  c.ratingPrompt = { enabled: true, afterRides: 0, cooldownDays: 3, maxPerYear: 12 };
  c.reviews = { maxPlaces: 3, reportDays: 30 };
  c.evil = '<script>';
  let err;
  try { E.validateConfig(c); } catch (e) { err = e; }
  assert.ok(err instanceof E.EngagementError);
  assert.equal(err.status, 422);
  const f = err.fields;
  assert.match(f['texts.tripTitle.en'], /Google Play/);
  assert.match(f['texts.placesTitle.en'], /English/);
  assert.match(f['tripChips[0].id'], /lower-case/);
  assert.match(f['tripChips[2].id'], /twice/);
  assert.match(f['tripChips[3].label.en'], /Google Play/);
  assert.match(f['placeChips.stay'], /Up to 10/);
  for (const k of ['ratingPrompt.afterRides', 'ratingPrompt.cooldownDays', 'ratingPrompt.maxPerYear', 'reviews.maxPlaces', 'reviews.reportDays']) assert.ok(f[k], k);

  // HTML is stripped, hi/te optional, missing parts keep the defaults.
  const ok = E.validateConfig({ texts: { tripTitle: { en: '<b>How was it?</b>' } }, ratingPrompt: { enabled: false } });
  assert.deepEqual(ok.texts.tripTitle, { en: 'How was it?' });
  assert.equal(ok.ratingPrompt.enabled, false);
  assert.equal(ok.ratingPrompt.afterRides, 3);
  assert.equal(ok.evil, undefined);
});

test('chip ids from riders: shape, dedupe, cap; feedback validation', () => {
  assert.deepEqual(E.cleanChipIds(['great_route', 'great_route', 'BAD', '<x>', 42, 'safe_group']), ['great_route', 'safe_group']);
  assert.equal(E.cleanChipIds(new Array(30).fill(0).map((_, i) => `c${i}`)).length, 10);
  assert.deepEqual(E.cleanChipIds('nope'), []);
  assert.throws(() => E.validateFeedback({ message: 'hi' }), (e) => !!e.fields.message);
  assert.throws(() => E.validateFeedback({ message: 'x'.repeat(1001) }), (e) => !!e.fields.message);
  assert.throws(() => E.validateFeedback({ message: 'Valid message here', topic: 'spam' }), (e) => !!e.fields.topic);
  const v = E.validateFeedback({ message: '  <b>Map froze</b> on the ghat road ', topic: 'BUG', appVersion: '3.55.0', platform: 'android', contactOk: true });
  assert.equal(v.message, 'Map froze on the ghat road');
  assert.equal(v.topic, 'bug');
  assert.equal(v.platform, 'android');
});

test('computeStats: averages, distribution, chip frequency, place ratings by category', () => {
  const now = Date.UTC(2026, 10, 10);
  const day = 86400000;
  const trips = [
    { rating: 5, chips: ['great_route', 'safe_group'], submittedAt: now - day, writtenFeedback: 'Lovely' },
    { rating: 4, chips: ['great_route'], submittedAt: now - 2 * day },
    { rating: 2, chips: ['too_fast', 'unknown_x'], submittedAt: now - 3 * day },
    { rating: 1, submittedAt: now - 200 * day }, // outside 90 days
    { rating: 3, submittedAt: now - day, status: 'WITHDRAWN' },
  ];
  const places = [
    { category: 'stay', rating: 5, chips: ['clean', 'bike_parking'], createdAt: now - day },
    { category: 'stay', rating: 3, chips: ['clean'], createdAt: now - day },
    { category: 'food', rating: 4, chips: ['tasty'], createdAt: now - day },
    { category: 'ev', rating: 2, chips: ['quick'], createdAt: now - day },
  ];
  const s = E.computeStats({ trips, places, feedback: [{ status: 'OPEN' }, { status: 'HANDLED' }], days: 90, now });
  assert.equal(s.trip.count, 3);
  assert.equal(s.trip.avg, 3.7);
  assert.deepEqual(s.trip.distribution, [0, 1, 0, 1, 1]);
  assert.deepEqual(s.trip.chips[0], { id: 'great_route', label: 'Great route', count: 2 });
  assert.ok(s.trip.chips.find((c) => c.id === 'unknown_x' && c.label === 'unknown_x'));
  assert.equal(s.trip.withNote, 1);
  assert.equal(s.trip.weekly.length, 13);
  assert.equal(s.places.count, 4);
  assert.deepEqual(s.places.categories[0], { category: 'stay', group: 'stay', count: 2, avg: 4 });
  assert.deepEqual(s.places.chips.stay[0], { id: 'clean', label: 'Clean', count: 2 });
  assert.deepEqual(s.places.chips.fuel[0], { id: 'quick', label: 'Quick', count: 1 }, 'ev counts under the fuel group');
  assert.deepEqual(s.feedback, { total: 2, open: 1 });
});

// ------------------------------------------------------------------ HTTP
test('HTTP: app config, admin save/version/restore, feedback inbox, chips on reviews, stats', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const admin = await env.register('Eng Admin', 'engadmin@coroute.test');
  const rider = await env.register('Ravi Rider', 'eng.rider@coroute.test');
  const other = await env.register('Other Rider', 'eng.other@coroute.test');

  // App config: auth required; defaults at version 0; ETag / 304.
  assert.equal((await env.api('GET', '/app/engagement-config')).status, 401);
  const c0 = await env.api('GET', '/app/engagement-config', null, rider.token);
  assert.equal(c0.status, 200);
  assert.equal(c0.json.version, 0);
  assert.equal(c0.json.config.ratingPrompt.afterRides, 3);
  assert.equal(c0.json.history, undefined, 'no admin history for riders');
  assert.match(c0.headers.get('cache-control'), /private/);
  const etag = c0.headers.get('etag');
  const c304 = await env.api('GET', '/app/engagement-config', null, rider.token, { 'If-None-Match': etag });
  assert.equal(c304.status, 304);

  // Admin endpoints refuse riders.
  assert.equal((await env.api('GET', '/admin/engagement/config', null, rider.token)).status, 403);
  assert.equal((await env.api('PUT', '/admin/engagement/config', { config: {} }, rider.token)).status, 403);
  assert.equal((await env.api('GET', '/admin/engagement/stats', null, rider.token)).status, 403);
  assert.equal((await env.api('GET', '/admin/engagement/feedback', null, rider.token)).status, 403);

  const a0 = await env.api('GET', '/admin/engagement/config', null, admin.token);
  assert.equal(a0.status, 200);
  assert.ok(a0.json.defaults && a0.json.languages.includes('te'));

  // Incentive text refused; nothing saved.
  const cfg = clone(a0.json.config);
  cfg.texts.rateSubtitle = { en: 'Rate us 5 stars to get a free month' };
  const refused = await env.api('PUT', '/admin/engagement/config', { config: cfg, baseVersion: 0 }, admin.token);
  assert.equal(refused.status, 422);
  assert.ok(refused.json.fields['texts.rateSubtitle.en']);

  cfg.texts.rateSubtitle = { en: 'Tell other riders what you think', hi: 'अपनी राय बताएं' };
  cfg.ratingPrompt.afterRides = 5;
  cfg.tripChips.push({ id: 'scenic', label: { en: 'Scenic' } });
  const saved = await env.api('PUT', '/admin/engagement/config', { config: cfg, baseVersion: 0, note: 'More rides first' }, admin.token);
  assert.equal(saved.status, 200, JSON.stringify(saved.json));
  assert.equal(saved.json.version, 1);

  // A stale base version is a conflict.
  const stale = await env.api('PUT', '/admin/engagement/config', { config: cfg, baseVersion: 0 }, admin.token);
  assert.equal(stale.status, 409);
  assert.equal(stale.json.code, 'VERSION_CONFLICT');

  cfg.ratingPrompt.enabled = false;
  const v2 = await env.api('PUT', '/admin/engagement/config', { config: cfg, baseVersion: 1 }, admin.token);
  assert.equal(v2.json.version, 2);
  const restored = await env.api('POST', '/admin/engagement/config/restore', { version: 1 }, admin.token);
  assert.equal(restored.status, 200);
  assert.equal(restored.json.version, 3);
  assert.equal(restored.json.config.ratingPrompt.enabled, true);
  const hist = await env.api('GET', '/admin/engagement/config', null, admin.token);
  assert.deepEqual(hist.json.history.map((h) => h.version), [3, 2, 1]);

  // Riders get the new version (fresh cache on the node that saved it).
  const c3 = await env.api('GET', '/app/engagement-config', null, rider.token);
  assert.equal(c3.json.version, 3);
  assert.equal(c3.json.config.ratingPrompt.afterRides, 5);
  assert.ok(c3.json.config.tripChips.some((c) => c.id === 'scenic'));

  // Feedback: sanitised, deduped, rate limited, admin inbox with search and handled.
  assert.equal((await env.api('POST', '/me/feedback', { message: 'Hello there' })).status, 401);
  const bad = await env.api('POST', '/me/feedback', { message: 'no' }, rider.token);
  assert.equal(bad.status, 422);
  const f1 = await env.api('POST', '/me/feedback', { message: '<img src=x onerror=alert(1)>Voice drops near tunnels', topic: 'bug', appVersion: '3.55.0+10020', contactOk: false }, rider.token);
  assert.equal(f1.status, 201, JSON.stringify(f1.json));
  const dup = await env.api('POST', '/me/feedback', { message: 'Voice drops near tunnels', topic: 'bug' }, rider.token);
  assert.equal(dup.status, 200);
  assert.equal(dup.json.duplicate, true);
  await env.api('POST', '/me/feedback', { message: 'Please add a dark map', topic: 'idea', contactOk: true }, other.token);

  const inbox = await env.api('GET', '/admin/engagement/feedback', null, admin.token);
  assert.equal(inbox.status, 200);
  assert.equal(inbox.json.items.length, 2);
  const mine = inbox.json.items.find((x) => x.topic === 'bug');
  assert.equal(mine.message, 'Voice drops near tunnels');
  assert.equal(mine.email, '', 'no e-mail without contactOk');
  assert.equal(mine.userName, 'Ravi');
  assert.equal(inbox.json.items.find((x) => x.topic === 'idea').email, 'eng.other@coroute.test');
  const search = await env.api('GET', '/admin/engagement/feedback?q=tunnel', null, admin.token);
  assert.equal(search.json.items.length, 1);
  const h = await env.api('PUT', `/admin/engagement/feedback/${mine.feedbackId}`, { handled: true, note: 'Fixed in 3.56' }, admin.token);
  assert.equal(h.status, 200);
  assert.equal(h.json.item.status, 'HANDLED');
  const open = await env.api('GET', '/admin/engagement/feedback?status=OPEN', null, admin.token);
  assert.equal(open.json.items.length, 1);
  assert.deepEqual(open.json.counts, { total: 2, open: 1, handled: 1 });
  assert.equal((await env.api('PUT', '/admin/engagement/feedback/af_nope', { handled: true }, admin.token)).status, 404);

  // Rate limit: 5 per hour per rider.
  let limited = null;
  for (let i = 0; i < 6 && !limited; i++) {
    const r = await env.api('POST', '/me/feedback', { message: `Another idea number ${i} for the team` }, other.token);
    if (r.status === 429) limited = r;
  }
  assert.ok(limited, 'the 6th feedback in an hour is refused');

  // Chips on a trip review (stored, private: rider view, admin view; never public without consent).
  const now = Date.now();
  await env.gw.repo.saveTrip({ tripId: 'TRIP-ENG-1', userId: rider.user.userId, tripName: 'Coast run', startTimeEpochMs: now - 7200000, endTimeEpochMs: now - 600000, totalDistanceKm: 120, source: 'server' });
  const tr = await env.api('POST', '/trips/TRIP-ENG-1/feedback', { rating: 5, writtenFeedback: 'Smooth ride', chips: ['great_route', 'safe_group', 'BAD ID', 'great_route'] }, rider.token);
  assert.ok([200, 201].includes(tr.status), JSON.stringify(tr.json));
  assert.deepEqual(tr.json.feedback.chips, ['great_route', 'safe_group']);
  assert.equal(tr.json.feedback.consentPublish, false, 'quick review is private by default');
  const stories = await env.api('GET', '/community-stories');
  assert.ok(!(stories.json.stories || []).some((s) => /Smooth ride/.test(s.formattedText || '')), 'never public without consent and approval');

  // Chips on a place review.
  const pr = await env.api('POST', '/places/reviews', { placeId: 'osm:node:42', placeName: 'Hill Inn', category: 'stay', lat: 17.4, lng: 78.5, rating: 4, chips: ['clean', 'bike_parking', 'clean', 'Nope!'] }, rider.token);
  assert.equal(pr.status, 201, JSON.stringify(pr.json));
  assert.deepEqual(pr.json.review.chips, ['clean', 'bike_parking']);

  const stats = await env.api('GET', '/admin/engagement/stats?days=30', null, admin.token);
  assert.equal(stats.status, 200);
  assert.equal(stats.json.trip.count, 1);
  assert.equal(stats.json.trip.avg, 5);
  assert.deepEqual(stats.json.trip.chips.map((c) => c.id), ['great_route', 'safe_group']);
  assert.equal(stats.json.places.categories[0].category, 'stay');
  assert.equal(stats.json.places.chips.stay[0].label, 'Bike parking');
  assert.ok(stats.json.feedback.total >= 2);

  // Account erase removes the rider's feedback.
  await env.gw.repo.deleteUserCascade(await env.gw.repo.findUserById(other.user.userId));
  const after = await env.api('GET', '/admin/engagement/feedback', null, admin.token);
  assert.ok(!after.json.items.some((x) => x.userName === 'Other'));
});
