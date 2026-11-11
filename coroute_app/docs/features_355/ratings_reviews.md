# Ratings & reviews (3.55)

Owner request: "Put an option to rate our application, and review trips and places he went and
stayed, with configurable templates."

Four parts, one set of admin templates:

1. **Rate CoRoute**: Google Play's own in-app review card (Play In-App Review API), asked rarely and
   at calm moments, plus a permanent "Rate CoRoute" row in Profile › Help (only there since Nov 11).
2. **Trip review**: after the ride, a calm card "How was the ride?" with 1-5 stars, quick chips and
   an optional short note (280).
3. **Places he went and stayed**: the places the rider stopped at long enough (the existing dwell
   prompts) in the same sheet, with stars, chips of that category and an optional photo.
4. **Templates (web admin, Engagement)**: prompt texts (en / hi / te), chip lists, rating-ask rules,
   the feedback inbox and review statistics.

## Google Play review policy (how it is kept)

- **No gating.** The app never asks "Do you like CoRoute?" before the Play card, and the rider's trip
  rating, chips or note are not an input to the ask (`RatingAskScheduler` has no rating field). Every
  rider who meets the timing rules gets the same Play card. The old 3.54 prompt that showed only
  after a 4-5 star trip rating ("Enjoying safer rides?" sheet, `ReviewPromptPolicy`) was removed.
- **No incentive.** Nothing is offered for a rating. "Send feedback" is a separate row, never a branch
  of a "happy / unhappy" question.
- **Templates stay neutral.** The gateway refuses (422) any template text or chip label with prices,
  payments, plans, coupons, discounts, offers, free trials, rewards, gifts, prizes, points, "rate us to
  get...", "5 stars for...", or gating wording ("Enjoying it? Rate us", "Not happy? Tell us instead"),
  in English, Hindi and Telugu (`policyProblem` in `gateway/src/engagement.js`). The app drops such a
  text again on its side (`EngagementConfig.policyProblem`) and shows the default.
- Google decides whether the card really shows (quota) and never tells the app whether or how the
  rider rated.

## Rate CoRoute

| Rule (admin default) | Where |
|---|---|
| After the Nth completed ride without SOS / crash alarm (3rd) | `ratingPrompt.afterRides` (1-50) |
| Not within N days of the last ask (30) | `ratingPrompt.cooldownDays` (14-365) |
| At most N asks a year (3) | `ratingPrompt.maxPerYear` (1-3, hard cap 3) |
| On / off | `ratingPrompt.enabled`, plus the `reviewPrompt` feature switch |
| Never during a ride, never within 20 s of its end | app |
| Only once the after-ride wrap-up / summary was closed, or at the next app open while a finished clean ride waits (3 days) | app |
| Never after a problem: a ride with SOS / crash alarm, any SOS or crash error in the session log, a problem in the last 7 days, or an error-heavy session (5+ error log entries) | app |
| Never in the first 2 days after install; "Don't ask again" from 3.54 still respected | app |

The ask is counted before the card opens. The rows in Profile › Help ("Rate CoRoute", "Send feedback"; removed from Settings on Nov 11)
are always there and do not count: they open Google's card and fall back to the
Play listing (`market://details?id=...`, then `https://play.google.com/...`) when the card could not
run or closed within 0.7 s (quota: Google showed nothing).

Android: `android/app/src/main/kotlin/space/devmonks/coroute_app/InAppReviewChannel.kt`
(MethodChannel `coroute/in_app_review`, method `requestReview` -> `{ok, error?}`:
`requestReviewFlow` then `launchReviewFlow`), registered in `MainActivity.kt`; Gradle
`implementation("com.google.android.play:review:2.0.2")` (no review-ktx). iOS: the rows open the
configured App Store page; no automatic ask.

## After-ride wrap-up (trip + places)

`lib/presentation/engagement/ride_wrapup_sheet.dart`, order from `RideWrapUpFlow.build`
(`lib/domain/engagement/ride_wrapup_flow.dart`):

1. "How was the ride?" when trip reviews are on, the gateway says the rider may review this ride
   and there is no review yet. Stars, trip chips, a note (280). "Add photos or a story" opens the
   full trip review sheet (consents, up to 5 photos, website story).
2. Up to 2 places (`reviews.maxPlaces`), longest stay first, never more than 3 cards in all: stars,
   the chips of the place's category group, optional note, optional photo (shown to others after an
   admin check, as before).

One swipeable sheet; every card has "Skip", the sheet has "Skip all"; closing it is "Skip all".
Opened 1.5 s after the cockpit closes (ride ended or left), at the next app open for stored place
questions, and from the trip report. Once per ride (the existing `review_prompted_<id>` flags).

Trip report: a skipped ride shows a "How was the ride?" card with "Rate" / "Not now" for
`reviews.reportDays` (7) days after the ride; "Not now" hides it on that report for good.

Chip groups: stay; food; fuel (fuel and EV charging); viewpoint (viewpoints and heritage); other
(everything else). Same table in `chipGroupOf` (gateway) and `EngagementConfig.groupOf` (app).

### Privacy

- The quick trip review is sent with no publication consent (`consentPublish: false`): its stars,
  chips and note are visible to the rider and to admins only, and can never appear on the website
  (stories need consent AND admin approval, unchanged).
- Place reviews: as before (first name only, photos after an admin check); chips are shown with the
  review.
- In-app feedback stores the first name and user id; the e-mail only when the rider turned on "You
  may reply by e-mail". It is erased with the account.

## Endpoints (under /api)

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/app/engagement-config` | rider | `{ok, version, config}`; ETag `"eng-<version>"`, 304, `private, max-age=300`; 30 s node cache. The app keeps a copy and refreshes it at most every 6 hours. |
| POST | `/me/feedback` | rider | `{message (5-1000), topic: general/bug/idea/ride/places/other, appVersion?, platform?, contactOk?}`; plain text only; 5 per hour, 20 per day per rider; the same text within 10 min is kept once (200, `duplicate: true`). |
| POST | `/trips/:tripId/feedback` | rider | existing; now also `chips: [id]` (up to 10, id shape `^[a-z][a-z0-9_]{0,31}$`). |
| POST | `/places/reviews` | rider | existing; now also `chips: [id]`. |
| GET | `/admin/engagement/config` | admin | config, defaults, languages, text keys, ranges, last 10 versions. |
| PUT | `/admin/engagement/config` | admin | `{config, baseVersion, note?}`; 422 with `fields` (path -> message), 409 `VERSION_CONFLICT`; audited. |
| POST | `/admin/engagement/config/restore` | admin | `{version, baseVersion?}`: saves that version again as a new one. |
| GET | `/admin/engagement/feedback` | admin | `?status=OPEN|HANDLED&q=&limit=`; `{items, counts}`. |
| PUT | `/admin/engagement/feedback/:id` | admin | `{handled: bool, note?}`. |
| GET | `/admin/engagement/stats` | admin | `?days=7..365`: trip average, 1-5 distribution, weekly counts, chip frequency; place ratings by category, chip frequency per group; open feedback. |

Storage: config in `subscription_config` (`k = 'engagement_config'`, `version`, `history` of 10 with
full snapshots); feedback in the new collection `engagement_feedback`.

## Web admin: Engagement

`gateway/public/admin/engagement.js` (nav "Engagement"): tabs Templates (texts per language with
English fallback, chip editors per review type and place group, live preview), Rating prompt (rules
and after-ride switches), Feedback inbox (search, open / handled), Review stats (tiles, bar and line
charts, place table). One Save bar with the live version; Versions table with Restore.

## Files

- Gateway: `src/engagement.js` (+ one line in `src/app.js`), chips in `src/trip_reviews.js` and
  `src/road_and_places.js`; web admin `public/admin/engagement.js`, nav + script in `index.html`,
  a few `eng-*` rules in `admin.css`.
- App: `lib/domain/engagement/{engagement_config,rating_ask_scheduler,ride_wrapup_flow}.dart`,
  `lib/data/services/engagement_service.dart`, `lib/presentation/engagement/{ride_wrapup_sheet,rate_and_feedback}.dart`,
  `lib/presentation/review/app_review_prompt.dart` (rewritten), hooks in the cockpit ride end, the
  trip report, the home screen (app open), Settings and Profile; provider in `main.dart`; `chips` in
  `PlaceReviewService.submit`.
- Android: `InAppReviewChannel.kt`, `MainActivity.kt`, `build.gradle.kts`.
- Tests: `gateway/test/engagement_355.test.js`, `test/engagement_355_test.dart`.

## Device checks

1. Install from an internal-testing track (the Play card only shows for Play-installed builds; use
   internal app sharing / FakeReviewManager for repeat tests). Profile › Help › Rate CoRoute: Google's card
   (or the Play listing when the quota hides it).
2. Finish 3 clean rides: after the third ride's wrap-up is closed (or at the next app open) Google's
   card may show; a 4th ride within 30 days shows nothing.
3. Ride with an SOS test or a crash alarm: no ask after that ride or for 7 days.
4. End a ride with a 20+ minute stop at a hotel and a dhaba: one sheet, trip card then the two
   places, chips per category, "Skip" / "Skip all" work; Hindi / Telugu text when the safety language
   is set.
5. Skip the wrap-up, open the trip report: "How was the ride?" card with Rate / Not now; gone after
   7 days or "Not now".
6. Profile › Help › Send feedback (pick Report a problem / Suggest a safety feature / Other; optionally attach the diagnostics log): message appears in web admin Engagement > Feedback inbox with topic bug / idea / other; an attached log appears under Diagnostics.
7. Web admin: save a text with "Rate us to get a free month": refused with the field highlighted.
