# Traction and KPIs

**Current traction: none to report.** CoRoute is pre-launch (not yet on Google Play). This document defines the KPIs we will report from launch, where each one comes from in the product, and a weekly investor-update template. Report real numbers only, and say when a number is small or partial.

---

## 1. Where the numbers come from

| Source | Who can open it | What it gives |
|---|---|---|
| **App admin console** (Flutter, master admin) › Insights / dashboard | Master admins | Overview tiles and daily trend charts (rides, km, active riders, sign-ups, SOS), plan mix, riders and groups lists, rider and group detail, feature analytics |
| **Admin analytics API** (behind the console) | Master admin token | `GET /api/admin/analytics/overview?days=1..365` · `GET /api/admin/analytics/trends?days=7|30|90&tz=330` · `GET /api/admin/analytics/riders` · `GET /api/admin/analytics/groups` |
| **Web admin** (`/admin`) › Revenue | Master admins | Net revenue per day (30 / 60 / 90 days) and per month (12 months), active paid plans at month end, coupon redemptions, revenue by plan, top coupons, monthly table (`GET /api/admin/web/revenue?days=&months=`) |
| **Web admin** › Payments | Master admins | Orders, refunds, 30-day tiles, CSV export (`GET /api/admin/payments/analytics`, `/export.csv`) |
| **Web admin** › Operators | Master admins | Applications by status and type, approved / suspended / expired counts (`GET /api/admin/operators/summary`) |
| **Website impact section** (public) | Anyone | All-time, privacy-rounded totals: riders, rides, km, riding hours, group rides, largest group, longest trip, bikes, SOS resolved, crash alerts, alerts answered, median response, road reports, this week (`GET /api/public/impact-stats`). Hidden until at least 10 are behind a number. |
| **Google Play Console** (after launch) | Owner | Installs, store listing conversion, ratings, crash-free users, user-perceived ANR rate |

Notes on the data:

- Staff accounts are excluded from rider counts and revenue; Razorpay test-mode money is reported separately. Keep it that way in every investor number.
- Admin analytics responses carry a `truncated` flag when a scan hit its cap; if it is true, say the number is a lower bound.
- Use India time (`tz=330`) for daily and monthly buckets.

---

## 2. KPI definitions

### 2.1 Acquisition

| KPI | Definition | Pull from |
|---|---|---|
| Installs | New installs in the period | Play Console |
| Store conversion | Installs ÷ store listing visitors | Play Console |
| Sign-ups | New rider accounts (staff excluded) | trends `series.signups`; overview `riders.newInPeriod` |
| Invite-led sign-ups | Sign-ups that came through a ride join link, friend link or crew / club invite | **Not instrumented yet**: add attribution before quoting |

### 2.2 Activation

| KPI | Definition | Pull from |
|---|---|---|
| First-ride activation | Share of a week's sign-ups who complete a ride within 7 days | riders list (joined date vs first trip); compute offline |
| Safety setup rate | Share of riders with an emergency contact and medical ID entered | **Not exposed as a tile yet**: add an aggregate before quoting |

### 2.3 Engagement

| KPI | Definition | Pull from |
|---|---|---|
| Weekly active riders (WAR) | Distinct riders with a completed trip in the last 7 days | impact `thisWeek.riders`; overview `riders.active7d` (last seen, a broader measure; label which one you use) |
| Monthly active riders (MAR) | Same over 30 days | trends `series.activeRiders` (distinct per day; sum distinct offline) or overview `riders.active30d` |
| Rides completed | Completed trips in the period | overview `rides.tripsInPeriod`; trends `series.rides` (group rides ended) |
| Group rides | Rides with 2+ riders that ended | overview `rides.groupsInPeriod` |
| Average group size | Riders per group ride | overview `rides.avgGroupSize` |
| Km and riding hours | Distance and moving time | overview `rides.kmInPeriod`, `rides.ridingHours`; trends `series.km` |
| Rides per active rider | Rides ÷ MAR | derived |

### 2.4 Retention

| KPI | Definition | Pull from |
|---|---|---|
| Day-30 retention | Share of a sign-up cohort with a ride in days 23–30 (or 30 ± 3) after sign-up | riders list export; compute offline |
| Host repeat rate | Share of hosts in month m who host again in m+1 | groups list by owner; compute offline |

### 2.5 Monetisation

| KPI | Definition | Pull from |
|---|---|---|
| Paying hosts | Riders who own an active paid plan | web admin › Revenue `activePaidPlans`; overview `riders.paying` |
| Host-to-paid conversion | Paying hosts ÷ riders who hosted a group ride in the period | derived |
| Rider-to-paid conversion | Paying ÷ all riders | overview `riders.conversionPct` |
| Net revenue | Paid orders minus refunds, live mode only, staff excluded | web admin › Revenue `daily[].netInr`, `monthly[].netInr` |
| ARPU (paying host) | Net plan revenue ÷ paying hosts | derived |
| Coupon share | Orders with a coupon ÷ paid orders; coupon discount ₹ | Revenue `couponRedemptions`, `couponDiscountInr` |
| Active operators | Approved, not suspended or expired | web admin › Operators summary |
| Plan mix | Riders by plan (Community / Small Group / Large Group) | trends `plans` |

### 2.6 Safety quality (what makes CoRoute credible)

| KPI | Definition | Pull from |
|---|---|---|
| SOS raised | SOS and crash alerts in the period | overview `safety.sosInPeriod`; trends `series.sos` |
| SOS resolved | Alerts closed as real and resolved | overview `safety.resolved`; impact `safety.sosResolved` |
| False alarms | Alerts closed as false alarms | overview `safety.falseAlarms` |
| Crash false-alarm rate | Crash countdowns cancelled with "I'm OK" ÷ crash countdowns | **App-side; not in the overview yet**: add an aggregate before quoting |
| Alerts answered by riders | Alerts with at least one responder | impact `safety.alertsAnswered`; overview `safety.answered` |
| Median first response | Seconds from alert to the first responder | overview `safety.medianResponseSec` |
| Median time to resolve | Seconds from alert to resolution | overview `safety.medianResolveSec` |
| Road reports live | Saved road hazards not yet expired | impact `safety.roadReports` |

Always report safety numbers with care: never imply an outcome ("lives saved") that the data does not show.

### 2.7 Reliability

| KPI | Definition | Pull from |
|---|---|---|
| Crash-free users | Play vitals | Play Console (target ≥ 99.5 %) |
| User-perceived ANR rate | Play vitals | Play Console (target < 0.3 %; Play limit 0.47 %) |
| Battery per riding hour | Measured per `docs/BATTERY.md` | device tests |
| Uptime | `/api/health/live` availability | load-balancer health / monitoring **[OWNER TO SET UP]** |

---

## 3. North-star and guardrails (proposal)

- **North star:** weekly group rides completed (each one exposes several riders to CoRoute and is where hosts pay).
- **Guardrails:** crash false-alarm rate, overspeed minutes per 100 km must not rise (gamification must never push speed), crash-free users, battery per riding hour.

---

## 4. Weekly investor update template

Copy, fill, send. Leave a line out rather than estimate it.

```
Subject: CoRoute weekly update, week of <DD Mon YYYY>

1. Headline (one sentence)
   <The most important thing that happened this week.>

2. Numbers (this week · last week · change)          Source
   Installs                    <n> · <n> · <±%>       Play Console
   Sign-ups                    <n> · <n> · <±%>       Admin analytics (trends)
   Weekly active riders        <n> · <n> · <±%>       Website impact / overview (say which)
   Rides completed             <n> · <n> · <±%>       Admin analytics
   Group rides · avg size      <n> · <x.x>            Admin analytics
   Paying hosts                <n> · <n>              Web admin › Revenue
   Net revenue (₹, live)       <n> · <n>              Web admin › Revenue
   Active operators            <n>                    Web admin › Operators
   SOS raised · resolved · false alarms  <n> · <n> · <n>   Admin analytics
   Median first response (s)   <n>                    Admin analytics
   Crash-free users · ANR      <x.x %> · <x.xx %>     Play Console
   (Mark any number with "truncated" or "partial" when the source says so.)

3. Product shipped
   - <release / feature, with its status: in testing, staged %, 100 %>

4. Customers and partners
   - <clubs, operators, dealers spoken to; pilots started; only named with their consent>

5. What we learned
   - <one or two insights from riders, data or tests>

6. Next week's top 3
   1. <...>
   2. <...>
   3. <...>

7. Asks
   - <introductions, hires, advice>

8. Risks / blockers
   - <Play review, device issues, compliance, runway>
```

## 5. Pre-launch update template (until there are users)

```
Subject: CoRoute pre-launch update, <DD Mon YYYY>

Launch gates                    Status (not started / in progress / done)
  v3.55 device gate (native build + phone tests)   <status>
  Production deploy (two VMs, drill, soak test)     <status, measured live-rider cap>
  Google Play listing and closed testing            <status, testers>
  Firebase / push live                              <status>
  Legal review (terms, privacy, DPDP)               <status>
  iOS                                               <status>
Clubs / operators in conversation: <n, named only with consent>
Spend this period: <₹> · Runway: <months>
Next 2 weeks: <...>
Asks: <...>
```
