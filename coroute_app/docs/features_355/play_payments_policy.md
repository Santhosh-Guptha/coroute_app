# Google Play payments policy: the app is consumption-only (3.56)

Owner decision (Nov 10, 2026): the Play app sells nothing. **No in-app purchasing, no prices or costs, no
steering to an outside payment.** Plans are bought and managed only on the website (see
[web_payments.md](web_payments.md)). The same single build goes to Google Play and to the website APK.

The app may show neutral account status only: the plan name, what it includes, its status and end date.

## Rules for future work (read before touching plans, admin or notifications)

1. **No payment SDK** in the app: no Razorpay, Play Billing, Stripe, UPI intents or similar, and no Play
   Install Referrer. Nothing in `pubspec.yaml`, Gradle, ProGuard or the manifest.
2. **No money and no buying words** in anything a rider or a store reviewer can see (screens, snackbars,
   dialogs, notifications, push texts, Android resources, store listing): no `₹` / INR amounts, "price",
   "pricing", "per month", "/mo", "buy", "purchase", "upgrade", "renew", "payment(s)", "checkout", "coupon",
   "discount", "offer code", "plans page".
3. **No steering.** No link, button, QR code or text pointing a rider to the website to pay, not even "visit
   our website to get a plan". The only allowed line is the neutral **"Your plan is managed in your CoRoute
   account."** (no URL, not tappable).
4. **Locked features and capacity say what is so, nothing more**: "Group rides need a host with a group plan.",
   "Hosting a group ride needs a group plan.", "This ride is full.", "This is a solo ride. Others can't join
   it." No upgrade button, no navigation to a plan screen; tapping does nothing beyond closing. Use
   `PlanGateMessages` (`lib/domain/membership/plan_gate_messages.dart`). `ApiClient` already replaces the
   gateway's text for every plan / capacity refusal code (`MEMBERSHIP_EXPIRED`, `CONVOY_FULL`, `RIDE_FULL`,
   `SOLO_RIDE`, `SOLO_TRIP_ONLY`, `MEMBERSHIP_CAPACITY_EXCEEDED`, ...) and drops any server message with
   money or buying words ("This isn't available right now.").
5. **Free stays free and is said plainly**: solo riding, every safety feature, and joining someone's group ride.
   Community shows **"Solo riding and every safety feature are free."**
6. **Server checks stay.** Plans are enforced on the gateway; the app only reads `/membership/my`.
7. **Fuel money is allowed** only when it is clearly about fuel the rider buys at a pump (ride analytics:
   "Fuel price", "Fuel cost this month"), never about CoRoute.
8. **Staff admin in the app** has no payments, coupons, plan prices, revenue or marketing. One staff-only note
   row in Admin > Settings says **"Payments, coupons and marketing are managed in the web admin."** (no URL,
   no link). Admin "Change plan" for a rider stays (no prices shown).
9. **Run the scan** before every release and in review: `/opt/dartpkg/bin/dart tool/play_policy_scan.dart`
   (from the repo root; plain `dart <file>`, not `dart run`, so no pub resolution). It must print 0 hits.
   Its allowlist is for non-UI identifiers only (API field names, storage keys, the policy regex itself,
   the fuel price lines and the staff note), each with a reason. Never allowlist rider-facing text.

## 3.56 additions: access modes, push kinds, offer e-mails

10. **Access modes** ([access_modes.md](access_modes.md)): the admin can make CoRoute paid, free for
    everyone, or free up to limits. The app never learns the mode or a price.
    * It reads only capabilities: `canHostGroup`, `maxRiders`, `groupFeatures`, `reason`.
    * In free mode the app shows **no plan status at all**.
    * The only gate words are "Hosting a group ride needs a group plan.", "Hosting more group rides needs
      a group plan.", "This ride is full." and "This isn't included in this ride.", with no link and no
      button.
11. **Push kinds** ([notifications_admin.md](notifications_admin.md)): Update, Event, Safety tip,
    Community and Partner perk. Each has its own channel and opt-out.
    * A **Partner perk** is a real-world perk at a partner CoRoute curated: not a digital good, never a
      CoRoute plan, price, coupon, code or link.
    * It is off until the rider turns it on (Google Play ads policy: no third-party ads in
      notifications the rider did not ask for) and is always labelled "Partner perk".
12. **Offers, coupons and prices for CoRoute plans go only by e-mail** (the Offers e-mail campaign).
    * Only to riders who opted in on the website account page (off by default).
    * Every e-mail has an unsubscribe link and one-click headers, and a suppression list applies.
    * Never in a push, never in the app.

## What the app shows now

* **"Your plan"** screen (`lib/presentation/subscription/membership_dashboard_screen.dart`, title "Your plan"):
  the read-only `YourPlanCard` (`your_plan_card.dart`, built from the pure `PlanSummary`,
  `lib/domain/membership/plan_summary.dart`): plan name, status (Free / Active), "Ends on 12 Dec" or "Your
  Large Group plan ended on 3 Nov", what the plan includes (riders per group, talk / messages / invite code /
  regroup, every safety feature, plus the server's feature lines with any money or buying words dropped),
  and "Your plan is managed in your CoRoute account." No buttons or links in the card. The active trip lock
  and, for the owner of a group plan, the riders on it (invite / remove a rider, seats used) stay below the
  card: seat management, not buying ("All seats are taken." when full).
* **Home status chip**: the plan name only ("Community", "Small Group", "Large Group", a legacy plan's name).
* **Account**: one "Your plan" row (plan name, riders, end date). The payment history row is gone.
* **Features guide**: "Your plan" entry, neutral text.
* **Notifications**: `SUBSCRIPTION_*` push texts are neutral (gateway `push.js` `planNotice`):
  "Your Small Group plan is active.", "Your plan ends on 12 Dec.", "Your plan has ended. Solo riding and every
  safety feature stay free.", "Your plan has changed. Solo riding and every safety feature stay free."
  E-mail / SMS (outside the app) are not built in `push.js` and were not changed.

## A website purchase unlocks the app at once

1. The website activation (`gateway/src/web_shop.js` `notifyPlanActivated`, owned by the website work) sends
   `SUBSCRIPTION_ACTIVATED` to the rider's sockets (and a neutral push when no socket got it).
2. The app's socket handler (`ConvoyService`, `SUBSCRIPTION_ACTIVATED / EXPIRING / EXPIRED / REVOKED`, also
   outside a ride: the socket opens at sign-in) calls `onPlanChanged` -> `MembershipService.fetchMyMembership()`.
3. A push of type `SUBSCRIPTION_*` routes to the "Your plan" screen and re-reads the plan (tapped or in the
   foreground, `push_router_host.dart`). The screen also re-reads on open and on pull-to-refresh.
4. `MembershipService` notifies listeners; the "Your plan" card, the home chip and the hosting checks update.
   Covered by `test/your_plan_card_test.dart` ("a plan activated in the account shows at once").

`coroute://subscription` still only re-reads the plan (no other action).

The legacy-tier sweeper (`subscription_lifecycle.js`) now hands its 7/3/1-day `SUBSCRIPTION_EXPIRING` to the
same neutral push (`app.js`, `notify`). `push.notifyPlanChange()` is available to send socket + neutral push
for any other `SUBSCRIPTION_*` event.

## What was removed (3.56)

App (Flutter):
* `razorpay_flutter` (and its only dependency `eventify`) from `pubspec.yaml` / `pubspec.lock`.
* `lib/presentation/subscription/membership_payment_screen.dart`, `payment_success_screen.dart`,
  `payment_history_screen.dart`.
* `MembershipService`: `createOrder`, `verifyPayment`, `fetchPaymentHistory`, `fetchQuote`, `validateCoupon`,
  `activateFreeMembership`, `purchaseMembership`, `groupFromPrice`, the coupon refusal messages and helpers,
  and the admin catalog / payments / refund / revenue methods. Kept: `fetchMyMembership`, `fetchCatalog`
  (plan names and features only), cache, invite / respond / remove rider.
* Models: `MembershipCategory.priceRupees`, `UserMembership.priceRupees / orderId / paymentId / offerApplied`,
  `MembershipCatalog.introductoryOffers / keyId / mode`, `MembershipPaymentItem`, `PlanQuote`, `QuoteLine`.
  `paymentsEnabled` is read from the server JSON as `plansEnforced` (plans on / off; hides plan UI when off).
* Coupon-into-app path: `lib/domain/marketing/pending_coupon.dart`, `lib/data/services/pending_coupon_store.dart`,
  the `/get?coupon=` and `coroute://get` handling in `main.dart`.
* `lib/domain/membership/plan_change_rules.dart` (only used by the buying UI; the gateway keeps the rule).
* The "Membership Activated Successfully" banner of the trip review sheet (payment journey only).
* Admin console: `admin_payments_tabs.dart`, `admin_promotions_tabs.dart`, `admin_plans_pricing_screen.dart`,
  `admin_payment_analytics_tab.dart`, `lib/presentation/admin/marketing/**`, `lib/domain/marketing/**`, the
  pricing and payment gateway (Razorpay keys) tabs of `admin_config_tabs.dart` (the audit log stays), the
  "Plans & payments" section (Payments, Marketing pages), the Revenue and money rows of the overview and of
  a rider's details (the plan count chart stays, "Paying riders" reads "On a group plan"), and the money
  helpers of `admin_payments_logic.dart` / `admin_payments_widgets.dart`.
* Copy: feature catalog plan entries, username reserved word `razorpay`, convoy join error text.

Android:
* Manifest: App Links intent filter for `/get` and the `coroute://get` filter; the `upi` `<queries>` entry.
* `InstallReferrerChannel.kt`, its `MainActivity` registration, the `com.android.installreferrer` Gradle
  dependency and ProGuard rule; the Razorpay ProGuard rules.

Store: `store/LISTING.md` no longer says "There is no subscription"; it says solo riding, every safety feature
and joining a group ride are free (no price, no buying words).

Tests removed with the code: `coupon_link_and_plan_change_355_test`, `coupon_refusal_messages_test`,
`marketing_template_355_test`, `payment_history_reconciliation_test`, `trip_creation_payment_journey_test`,
`admin_pricing_validation_test`, `generate_journey_screenshots_test`, `membership_ui_states_test` (replaced by
`your_plan_card_test`), the payments parts of `admin_coupon_and_trip_view_test`, `plans_v2_test` (quote),
`trip_creation_membership_gate_test` (order dedupe, upgrade / renewal UI), `ui_audit_batch4/5` (payment and
admin payments screenshots). Added: `test/your_plan_card_test.dart` (card has no buttons and no price text,
neutral gate messages, instant update), gateway `test/play_policy_push_355.test.js`.

## Left for the website and web admin

* Plans, prices, coupons, checkout, receipts and payment history: website (`web_payments.md`).
* Payments list, refunds, revenue, plan pricing, coupons, payment gateway keys, Marketing studio: web admin.
* The website's activation push text (`web_shop.js`) is neutral today ("Small Group is active. Thank you for
  riding with CoRoute."); `gateway/test/play_policy_push_355.test.js` fails if it ever gains money or buying
  words. It may reuse `push.planNotice()` for the same wording as the other plan notices.
