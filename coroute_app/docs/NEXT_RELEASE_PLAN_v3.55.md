# CoRoute Next Release Plan (v3.55)

Nov 7, 2026 · @Haswanth

## Summary

v3.55 makes CoRoute the safest app a rider can carry, using only the phone and our own data, while keeping solo riding free and the servers light. It has three themes:

- **Phone-only safety:** new protection that works with no extra hardware and mostly without signal.
- **Safer groups and community:** features that help riders look after each other, inside a group and on the open road.
- **Steady growth:** plan clarity, honest reviews and a stronger two-VM platform.

Every new feature runs its logic on the phone; the gateway only relays, stores and fans out alerts. Nothing depends on outside products or paid services.

## Baseline: what v3.54 already delivers

v3.55 builds on a release that is code-complete but not yet proven on real roads and real OCI.

| Area | In v3.54 |
| --- | --- |
| Safety | Crash detection (also at slow-traffic speed), SOS with durable delivery and SMS fallback, guardians live link, Medical ID on the lock screen by default, offline solo ride, pre-ride phone check |
| Riding | Smooth course-up map, speed-adaptive precise GPS, auto re-routing, labelled places (food, hospitals, mechanics, police, fuel by type), on-phone fuel range and warnings |
| Groups | Live group map, push-to-talk, regroup, lead/sweep, public ride with safe contact, oncoming-rider road warnings |
| Plans | Community free (solo), Small Group 2–6, Large Group 7–12, prorated upgrades, coupons fixed |
| Insight | Personal ride analytics on the phone, Play Store review prompt, suggest-a-feature |
| Platform | Two-VM failover with live ride mirror, encrypted backups, Vault secrets, batched DB writes, privacy-rounded public stats, new 3D website |

Still open from v3.54: run `flutter test` and a Gradle build, the OCI deploy and failure drills, the soak test to set the live-rider cap, and real-device checks listed in the release checklist.

## New phone-only safety features (every rider, Community included)

Twelve features use only the phone's GPS, motion sensors, clock, battery and the rider's own history; all are free on every plan.

| Feature | What the rider gets | How the phone does it | Without signal |
| --- | --- | --- | --- |
| Sharp-bend warning | "Sharp bend in 300 m, slow to 35" | Curvature from the cached route line plus current speed | Yes |
| Smart speed limits | Warning when over the road's limit, stricter near schools and hospitals | OSM maxspeed tags and zones from the cached places corridor | Yes (cached) |
| Fatigue score | Break prompts that adapt to the rider, not a fixed timer | Ride time, time of day, micro-stops, steering wobble from the gyroscope | Yes |
| Rider-down check | "Are you OK?" when the bike falls while stopped or at walking pace | Tip-over pattern plus no movement for 60 s | Yes (SMS fallback) |
| Crash detection that learns | Fewer false alarms over time | Each "I'm OK" tunes thresholds for that bike and mount on the phone | Yes |
| Phone-mount check | Tells the rider if crash detection is weak in a pocket or tank bag | Vibration and orientation pattern while riding | Yes |
| Solo check-in timer | Contact is texted if the rider does not arrive or answer by ETA + margin | Local timer, ETA from the route | Yes (SMS) |
| No-signal ahead | Last position and ETA sent to guardians before a dead zone | Coverage log from the rider's own past rides on that road | Prepares before |
| SOS battery reserve | Below 10%, the phone keeps power for SOS and sends the last location | Stops the map and heavy work, slows GPS | Yes |
| High-altitude care | Acclimatisation reminders above 3,000 m and on fast climbs | GPS altitude and climb rate | Yes |
| Night riding care | Earlier break prompts and brighter alerts after sunset | Sunset time computed on the phone | Yes |
| Ride safety report | Private summary: hard brakes, over-limit minutes, night km, breaks | Sensor and GPS events from the ride, kept on the phone | Yes |

## Group and community safety features

Nine features help riders look after each other; the first six need a group plan, the last three work for everyone.

| Feature | What riders get | How it works | Plan |
| --- | --- | --- | --- |
| Missing-rider check | If one rider stops or goes silent while the group moves, their phone asks "OK?", then the lead is told | Each phone watches its own movement; the server only relays the alert | Group |
| Group stretch alert | Lead hears "Group spread 4 km, slow down" | Phones already know ahead/behind; threshold set by the lead | Group |
| Smart regroup point | Suggests a safe stop ahead (fuel, dhaba, wide shoulder) when the group spreads | Lead's phone picks from the cached places corridor | Group |
| Group break planner | One group break when several riders need rest | Each phone shares only its fatigue level, not raw data | Group |
| Buddy pairs | In large groups, each rider is paired to watch one buddy | Assigned at ride start; buddy gets a one-tap check | Large Group |
| Start and arrival roll call | Everyone ticked in at start, ticked arrived at the end; guardians told automatically | Ride state already on the phones | Group |
| Risky-stretch heads-up | "Many hard brakes reported on this stretch" | Anonymous, rounded hard-brake clusters shared only after k ≥ 10 riders | All |
| Help from public riders | SOS can ask nearby public-ride riders to help, with consent | Builds on the public ride and safety network already shipped | All |
| Arrival message | Guardians get "Arrived safely" with no tracking afterwards | Sent once at ride end, link expires | All |

Privacy rule for all of these: phones share levels and events, never raw sensor data; anything shared beyond the group is rounded and needs at least 10 riders behind it.

## Platform and reliability

The platform goal is to run safely on the two free micro VMs, prove it with drills, and keep every new feature's logic on the phone.

| Work item | Why | Impact |
| --- | --- | --- |
| Run the two-VM failure drills and the 30-minute soak test | Turns estimates into a measured live-rider cap | Confident capacity (estimate 200–700 live riders) |
| Wire or retire the offline crash-incident queue | It is the only offline store for crash incidents and is not connected today | No lost crash record when offline |
| Retire voice-command and siren services that receive no audio | They load at start-up but do nothing | Less battery and memory |
| Move review photos and APKs to Object Storage | VM disks hold no user data | VM loss loses nothing |
| Hourly and nightly encrypted backups, monthly restore test into DB 2 | Proves recovery | Data safe from a database disaster |
| Admin "Change plan" API on the new plans | It still accepts only old tier names | Admins can fix plans cleanly |
| Deliver admin warnings to riders | "Warn" on a public-ride report is only recorded today | Fair moderation |
| Rotate the leaked JWT secret and DB password | Old values are in git history | Closes the leak |
| Own domain with a regular DNS provider | Removes the DuckDNS dependency | Fewer single points of failure |

## Plans, growth and feedback

Growth comes from trust: solo safety stays free forever, groups pay for what groups need, and riders tell other riders.

- **Community stays free:** every new safety feature in this plan ships to Community. Group plans add only group coordination (talk, messages, group map, group alerts, buddy pairs).
- **Clear upgrade moments:** suggest a group plan when a Community rider joins or invites friends, never by locking safety.
- **Play Store launch:** publish on Google Play, then set `PLAY_STORE_URL` so the website and the in-app prompt link to it. The prompt only appears after a good ride (≥ 20 km, no SOS, rated 4–5 or third ride), at most once per 120 days.
- **Stories and ideas:** moderated rider stories on the website; the "Suggest a safety feature" form feeds this roadmap. Review the top ideas each month.
- **iPhone:** finish TestFlight, then set `APP_STORE_URL` so iPhone download buttons appear.

Success metrics to track in the admin console (rounded, staff excluded): weekly riders, rides completed, Community-to-group conversion, crash false-alarm rate, SOS acknowledged within 2 minutes, Play Store rating.

## Phasing and timeline

Nothing new ships until v3.54 passes its drills; then each phase is two 2-week sprints and must clear its gate.

&#91;embedded content: v3.55 phases · 4 phases, 3 gates, 2-week sprints\]

Safety features that work without signal go first; analytics-heavy and community features follow once beta riders confirm false alarms are rare. Sprint lengths are a proposal; set dates once Phase 0 finishes.

## Risks and open decisions

The biggest risk is shipping more features before v3.54 is proven on real phones and real OCI.

**Risks**

- v3.54 Dart tests, Gradle build and Kotlin native code have not run yet; real-device testing may find regressions.
- Micro VM CPU may be throttled; the soak test sets the safe live-rider cap.
- OpenStreetMap data in India is patchy (fuel types, speed limits, hospital tags); features must degrade gracefully.
- Sensor-based features (fatigue, rider-down, learning crash detection) need careful tuning to avoid false alarms that train riders to ignore alerts.
- Play Store review of background location and full-screen alerts may require changes.

**Decisions for the owner**

- [ ] Keep "Share medical info with a responder" consent switches (recommended for privacy) or remove them
- [ ] Should a rider with no plan be able to join a public ride on the road (convoy join), or only contact it?
- [ ] Deliver admin "warnings" to riders in the app, or keep them internal
- [ ] Credit beyond the new plan's price becomes extra days (current) or is capped
- [ ] Guests barred from road warnings (current) or allowed
- [ ] Buy an own domain now or after launch
