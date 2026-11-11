# CoRoute support playbook (internal)

For the CoRoute support team. Not for riders. App 3.55, November 2026.

Rider-facing references to link in replies: *Quick start*, *User guide*, *Safety guide*, *FAQ*, *Troubleshooting*, *Privacy summary*, *Community guidelines* (all in `docs/handbook/users/`).

**Ground rules**

- Safety first. Anything that could mean a rider was not alerted, or was alerted wrongly, is **P0**.
- Never ask a rider for their password, OTP or sign-in token. Never ask for medical info.
- Never tell a rider to buy something in the app (the app sells nothing). For group hosting, say only: "Group hosting is managed in your CoRoute account on the website." Never quote prices, offers or coupons in app-related replies, push or in-app messages. Offers go only by opt-in e-mail from the web admin.
- Do not promise dates for fixes. Say what we know and when we will update them.
- Staff cannot see medical info or hear voice. Do not imply we can.
- Refer to riders by username in internal notes; keep phone numbers and e-mails out of tickets where possible.

---

## 1. Where requests come in

| Channel | What arrives | Where staff see it |
|---|---|---|
| **In-app Send feedback** (Profile › Help) | Category *Report a problem* (`bug`), *Suggest a safety feature* (`idea`), *Other* (`other`); message; optional attached diagnostics log; "You may reply by e-mail" flag | Web admin › **Engagement › Feedback inbox**; attached logs under **System › Diagnostics** |
| **Post-ride safety prompt** | Diagnostics log after an SOS, crash alarm or false-alarm cancel (reason `safety_prompt`) | Web admin › System › Diagnostics |
| **E-mail** (contact address on the website) | Account, deletion, data requests, website plan questions | Support mailbox [OWNER TO FILL: address and owner] |
| **Website account deletion page** | Riders who cannot sign in | [OWNER TO FILL: where these requests land] |
| **Play Store reviews** | Public reviews | Play Console [OWNER TO FILL: who replies] |
| **Public ride / chat reports** | Reported messages and riders | Web admin › Public ride reports (`/admin/public-ride/reports`) |

## 2. Workflow

1. **Triage** within the response target (section 3). Set severity and a category tag: `safety`, `crash-false-alarm`, `sos`, `alerts-audio`, `siren`, `intercom`, `battery-background`, `permissions`, `group-ride`, `social`, `maps-search`, `account`, `deletion`, `data-request`, `web-plan`, `refund`, `moderation`, `idea`.
2. **Check known issues** (section 9) and the canned replies (section 6).
3. **Gather facts**: username, phone model and Android version, app build (in the diagnostics header), date/time and roughly where, what they saw and heard, ride code if any.
4. **Get the log**: if none attached, either reply with canned reply C01, or in the web admin use **Riders › rider › Ask for logs** (the rider gets "CoRoute support asked for your app log" and must tap Send; requests expire after 7 days). Logs are kept 30 days on the server and only 7 days on the phone: ask quickly.
5. **Analyse** (section 7).
6. **Resolve or escalate** (section 8).
7. **Reply** in plain language, short sentences, no internal terms (no "socket", "FCM", "gateway", "telemetry"). Close with what the rider should do next.
8. **Close** with tags and, for P0/P1, a one-line root cause.

## 3. Severity levels

| Level | Meaning | Examples | First response | Escalate |
|---|---|---|---|---|
| **P0: safety** | A rider may not have been alerted, or alerts went to the wrong people, or private safety data leaked | SOS not delivered; crash countdown did not appear after a real crash; group not alerted; SOS texts not sent; false SOS reaching contacts repeatedly; medical info shown to someone who should not see it; guardian link showing someone else | **Within 1 hour, any day** [OWNER TO FILL: on-call rota] | At once to engineering on-call |
| **P1: major** | A core feature broken for a rider or group, no safety impact proven | Ride stops in background on a phone model; intercom dead for a whole group; cannot sign in; cannot join rides; account deletion failed | Same business day | Engineering within 1 business day |
| **P2: normal** | Feature misbehaves, workaround exists | Late or repeated ordinary alerts; music not lowered; siren missed in a pocket; map search errors; friend request missing | 2 business days | If 3+ similar reports in a week |
| **P3: low** | Questions, wording, ideas | "How do I…", suggestions, translation errors | 5 business days | Product backlog |

Any report that a rider was hurt or in danger and CoRoute behaved unexpectedly is **P0** until proven otherwise, even if the rider says it is not urgent.

## 4. P0 procedure

1. Acknowledge within the target. Use reply C02 (P0 acknowledgment). If the rider may still be in danger, tell them to call **112**.
2. Ask for (or request) the diagnostics log of that phone, and if possible of the receiving phones (group members, helper).
3. In the web admin, check the ride: open SOS alerts, who was asked to help, delivery, the SMS log (Notifications › SMS: masked numbers, SENT / DELIVERED / FAILED / CAPPED).
4. Post in the engineering P0 channel [OWNER TO FILL] with: username, build, phone model, time (IST), ride code, alert id, what failed, log id(s).
5. Update the rider at least daily until closed.
6. After closing: write a short incident note (what happened, why, fix, follow-up). Check whether the store listing or help docs need a correction.

## 5. Account deletion and data requests

| Request | How | Timeline |
|---|---|---|
| **Delete account (rider can sign in)** | Point them to **Profile › Account › Delete account**. It is immediate: profile, trips, routes, timeline entries, safety log rows, false-alarm count, chat messages, SOS alerts, voice log entries, push tokens, diagnostics logs, crew memberships. Shared rides keep the ride with "Former rider". | Immediate |
| **Delete account (cannot sign in)** | Verify the request comes from the registered e-mail address. Delete via web admin [OWNER TO FILL: exact admin path and who may do it]. Confirm to the rider by e-mail. | Privacy policy says within **30 days**. Internal target: [OWNER TO FILL] |
| **Copy of my data** | Verify identity (registered e-mail). Export [OWNER TO FILL: export method/tool]. Send securely. Never include other riders' data. | [OWNER TO FILL] (DPDP: respond without undue delay) |
| **Correct my data** | Most fields the rider can edit (My profile, Edit details, My bikes). Otherwise correct in admin and note it. | [OWNER TO FILL] |
| **Delete one trip / review / photo** | Rider can delete trips and withdraw reviews in the app. Photos: admin moderation. | Immediate / [OWNER TO FILL] |
| **Diagnostics log deletion** | Rider: Clear logs on the phone. Server: admin can delete a single log; all are deleted with the account; otherwise expire after 30 days. | Immediate |
| **Law enforcement / legal request** | Do not answer directly. Forward to [OWNER TO FILL: legal contact]. | — |

Website plans and receipts belong to the account: deleting the account does not issue a refund. Mention this before deleting if the rider has an active plan.

## 6. Canned replies (top 30)

Adapt names and details. Keep the safety lines. `{username}` = rider's username.

**C01 Ask for diagnostics**
> Thanks for telling us. To see what happened on your phone, please send us your app log: open CoRoute › Profile › Help › Send feedback, choose "Report a problem", write "{ticket}" in the message, turn on "Attach diagnostics log" and tap Send. The log has no messages, names, phone numbers or exact places. Your phone keeps it for 7 days, so please send it soon.

**C02 P0 acknowledgment**
> Thank you for reporting this. We treat anything to do with alerts and SOS as our top priority and our engineers are looking at it now. If you or anyone is in danger, please call 112. We will update you within {hours} hours.

**C03 False crash alarm**
> Sorry about the false alarm. The most common cause is a phone that is loose in a pocket or bag. A firm handlebar mount helps most. Always tap "I'm OK" when you are fine: CoRoute learns from it for your bike. If you ride on, the alarm cancels itself. Could you send us the log of that ride (reply C01 steps) so we can check the cause?

**C04 Why can't I turn crash detection off**
> Crash detection, SOS and emergency texts are always on for every rider, because a crash with detection off reaches nobody. If it is bothering you with false alarms, let us help fix the cause: (C03 tips).

**C05 SOS sent by mistake**
> No problem. Close it with "False alarm" on the SOS screen and tell your group. SOS needs a full 3-second hold, so if this happened without a hold, please send us your log (C01).

**C06 SOS texts not sent**
> On phones from Google Play, CoRoute cannot send texts by itself. When there is no internet it opens your messages app with the text and all numbers filled in, and you or someone with you taps Send. You can also tap "Text the group now" on the SOS screen. Please check your emergency contact number in Profile › Emergency contact & Medical ID. If the text still did not open, please send us your log (C01).

**C07 Ride stops / app closes in background**
> Your phone is closing CoRoute to save battery. Please open CoRoute › Profile › Settings › Safety health and tap the battery button, then follow the steps for your phone brand in our Troubleshooting guide (section 2). On {brand}: {steps}. This keeps crash detection running during long rides.

**C08 Location "Allow all the time"**
> Please open your phone Settings › Apps › CoRoute › Permissions › Location and choose "Allow all the time", with precise location on. CoRoute uses location only during rides, but it needs this so your group and crash detection keep working with the screen off.

**C09 Notifications not arriving**
> Please check Settings › Apps › CoRoute › Notifications are on, including "Friends" and "Ride invites", and in CoRoute check Settings › Push notifications is on. Safety health in CoRoute Settings has a button that opens the right page.

**C10 Alerts late**
> Thanks. Late alerts usually come from the phone limiting CoRoute in the background or an old text-to-speech engine. Please (1) allow unrestricted battery (C07), (2) update "Speech Services by Google" from Play, then try again. If it happens again, note which alert and when, and send the log (C01).

**C11 Headset audio on phone speaker**
> Please connect the headset before the ride, allow "Nearby devices" for CoRoute, and in your phone's Bluetooth settings make sure "Media audio" is on for the headset. Some helmet sets connect for calls only; then emergency lines play on the phone speaker.

**C12 Intercom not heard**
> Please check the microphone permission for CoRoute, that you are not muted (the ride notification shows "Group voice muted"), and that you have mobile data. During a phone call, group talk pauses and comes back after. If it still fails with good signal, please send logs from both phones (C01).

**C13 Siren not detected**
> Siren alerts work during rides only, and best with the phone in a mount or tank bag: in a pocket at speed, wind can hide the siren. Music on the phone's own speaker pauses detection, and it pauses below 15 % battery. The alert comes about 3 seconds after the siren starts. If it missed a clear siren with the phone mounted, please send the log (C01) with the time.

**C14 Siren false alert**
> Thanks for telling us. Could you send the log (C01) with the time and what made the sound? It helps us tune detection. You can turn Siren alerts off in Settings if needed.

**C15 Music not lowered when speeding**
> "Lower music when speeding" is under Settings › More settings. It uses the strictest of the group, your own and the road's limit. If you change the volume yourself, CoRoute stops adjusting it for that stretch. If it never works, please send the log (C01).

**C16 Speed lower than speedometer**
> CoRoute shows your true GPS speed. Bike speedometers are allowed by law to read higher than the true speed (never lower), so a few km/h difference is normal. Warnings use the true speed.

**C17 Cannot host a group ride (neutral)**
> You can join any group ride for free and ride solo with every safety feature. Group hosting is managed in your CoRoute account on the website.

**C18 Ride is full**
> The ride has reached its rider limit. The trip owner can tell you more.

**C19 Complete your bike keeps showing**
> CoRoute needs your bike's make and model, type and colour (plus engine, tank and mileage for a fuel bike) so your group sees your bike on the map. If you ride on someone else's bike, choose "I'm riding pillion (no bike)" when you join.

**C20 Friend request missing**
> Please check the username is exact (your friend can read it in Profile › My profile) and look under People › Requests. Blocks either way stop requests. If it still does not appear, please send the log (C01).

**C21 Change username**
> Open Profile, tap the top box (My profile) and change your username. You can do this once every 30 days; changing only capital letters is always allowed.

**C22 Map search not working**
> Please check your connection and tap Retry. If India has no match, tap "Search everywhere". You can also paste a Google Maps link into the search box, or share a place from Google Maps to CoRoute.

**C23 Offline maps question**
> There is nothing to download: CoRoute saves the map along your route automatically when the ride starts (on Wi-Fi, unless data saver is on) and keeps it 7 days after the trip.

**C24 Battery use**
> The screen stays on during rides so you always see alerts, so a bike charger helps on long rides. Battery saver turns on at 20 % and never reduces SOS or crash detection.

**C25 Delete account**
> You can delete your account in CoRoute › Profile › Account › Delete account. It is removed at once and cannot be undone. If you cannot sign in, reply from your registered e-mail address and we will delete it for you within 30 days.

**C26 Data copy request**
> We have received your request for a copy of your data. To protect your account, we will send it only to your registered e-mail address. You will hear from us within {timeline}.

**C27 Privacy: who sees my location / medical info**
> Your location is shared only with the group you ride with, during the ride, and with guardians at the level you choose. Medical info goes only to your group, guardians and a rider who accepted to help, and only while your SOS or crash alert is open. Our staff cannot see it. Full details: Profile › Help › Privacy & terms.

**C28 Nearby riders help always on**
> Help from nearby riders can bring help sooner, so it is part of the safety features for everyone. Before anyone accepts they see only the emergency point and distance; your phone number is never shared. You can always choose "Can't Assist" when asked.

**C29 Report about another rider (moderation)**
> Thank you for reporting this. We will review it under our community guidelines. You can block the rider from People › the rider › Block; they are not told. If you feel unsafe, please call 112.

**C30 Website plan / payment question**
> Thanks. Plans and receipts are in your CoRoute account on the website (Account page, View receipt). We have passed your question to the team that handles website payments and will reply within {timeline}.

## 7. Reading a diagnostics log

**Where:** web admin › System › **Diagnostics** (filter by username, build, reason, 24 h / 7 / 30 days), or Riders › rider › **App logs**. Every view and download is audited.

1. Open the log. Start with **Problems** (warnings and errors), then the category of the issue:

| Issue | Category | Look for |
|---|---|---|
| Late alert | `audio` | `P2 ... decision->audio 2400ms`; queue wait (`to engine: waited`) vs engine start (`speech start +Nms`); `speed.overspeed_warn.fixAgeMs` for stale GPS |
| Music not lowered | `audio`, `speed` | `native focus ...`, `speed music lower/restore ...`, `volume ignored ... -> focus fallback` |
| False SOS / crash alarm | `crash`, `location` | `crash.impact_candidate` numbers, `crash.alarm_open` (scenario, confidence), then `alarm_ride_on` / `alarm_cancel` / `alarm_send`; `location.gps_summary` around it |
| SOS delivery | `sos` | raise, queued, resends, ack time, SMS fallback |
| Siren | `siren` | `siren.detected` (seconds heard, confidence, kind), `siren.alert`; ask the rider to turn on Detailed logs for `candidate_rejected` reasons |
| Connection drops | `realtime` | socket drops by close code, connect failures, reconnect time |
| Friend request missing | `social`, `push` | `social.friend_event`, `social.friends_loaded`, `push.received` |
| Background kills | lifecycle, battery, permissions | gaps in GPS summaries, app restarts, permission states |

2. **Download** the bundle and run the summary tool from the repo root (plain Node, no dependencies):

```
node tool/diag/analyze_logs.js coroute-diag-dl_xxx.jsonl.gz            # text report
node tool/diag/analyze_logs.js coroute-diag-dl_xxx.jsonl.gz --json     # machine-readable
node tool/diag/analyze_logs.js coroute-diag-dl_xxx.jsonl.gz --ride G-ABC123   # one ride
```

It prints builds and app starts, entries by level and category, top errors, alert latency per priority (p50 / p90 / max), overspeed decisions, crash candidates and why they were dropped, alarms, cancels and sends, SOS delivery, socket drops, GPS rate / accuracy / gaps, API errors, siren detections, intercom, push and friend events, native crashes and stalls, and the rides in the bundle.

3. Note the request id (server errors carry one) and the build. Server-side logs: see `docs/features_355/diagnostics_logs.md#server-logs` (engineering only).
4. Logs never contain names, messages, phone numbers or exact places; locations are rounded to about 100 m. Do not paste log contents into public channels anyway.

## 8. When to escalate to engineering

Escalate (with username, build, phone model, Android version, time IST, ride code, log id, summary output) when:

- any **P0** (immediately);
- a P1 that the troubleshooting steps did not fix;
- the same P2 from **3 or more riders in a week**, or on one phone brand;
- the analyser shows errors, native crashes or stalls;
- a crash alarm fired with no plausible impact in the log, or did not fire after a confirmed crash;
- texts show FAILED or CAPPED in the SMS log;
- a privacy concern (data shown to the wrong person);
- wording in the app is wrong, offensive or mistranslated (to product).

Do **not** escalate: battery/background issues fixed by the brand steps, permission issues, questions answered by the FAQ.

## 9. Refunds for website purchases

The app sells nothing; every purchase is made on the website and handled in the **web admin**.

1. Find the order: web admin › **Payments** (search by order, payment or user id; status; date range). The detail shows the rider's current plan.
2. Check the request against the refund policy published on the website [OWNER TO FILL: refund policy rules, time window, partial vs full].
3. Issue it in **Payments › order › Refund** (full or partial, with a reason; confirmation required). Razorpay processes it; the webhook records `refund.processed`.
4. After a refund, the order is never activated again. If the plan should end, use admin **Change plan** [OWNER TO FILL: whether a refund ends the plan automatically or by hand].
5. Reply to the rider with the amount and the expected time for the money to return [OWNER TO FILL: typical bank timeline].
6. Never discuss refunds, prices or coupons in the app or in push messages. E-mail only.

Plans do not renew on their own, so there is nothing to cancel.

## 10. Moderation

| Content | Where | Action |
|---|---|---|
| Reported chat messages, public ride reports | Public ride reports | Dismiss, or **Warn** (message ≤ 280 characters appears on the rider's Home screen), or suspend |
| Crews and polls | Admin › Crews | Delete crew / poll (members are told; audited) |
| Profile pictures | Admin › rider | Remove picture (audited) |
| Place reviews and photos | Admin › Place reviews | Approve / hide; photos appear only after approval |
| Trip reviews and group photos | Engagement | Approve for the website, label "Rider #" |
| Usernames | Admin › rider | Reserved and offensive names are already refused; rename on report |

Follow the consequence ladder in the *Community guidelines*: remove content, warn, limit, suspend, report to police where required. Suspended accounts keep no access; safety features keep working for active accounts.

## 11. Known documentation mismatches (fixed 11 Nov 2026)

The public texts below were updated on 11 Nov 2026 to match the current app. Support can now quote
the website pages.

| Where | Was | Now (fixed) |
|---|---|---|
| `gateway/public/privacy.html` summary, "Crash detection", "Your choices" | Crash detection, nearby help and emergency texts could be switched off | Always on; the rider still chooses voice alerts, siren alerts, leaderboards, news pushes, offer e-mails, fuel sharing |
| `privacy.html` "Medical ID on the lock screen" | Off until turned on | Always on during an open alert |
| `privacy.html` "Emergency texts when there is no internet" | Off until switched on; sent automatically | Always on; on Play builds the messages app opens with the text ready; server SMS (MSG91/Twilio) when enabled |
| `privacy.html` "Spoken alerts and the ride notification" | Lock screen view could be switched off | Ride on lock screen is always shown during a ride |
| `privacy.html` "App diagnostics log" | Settings > More > Diagnostics | Profile > Help > Send feedback (Attach diagnostics log / View diagnostics), or the after-ride prompt |
| `privacy.html`, `privacy-and-security.html`, `delete-account.html` | "Account & security, Delete my account"; 30 days vs 24-48 h | Profile > Account > **Delete account** (at once); web request within 48 hours; backups expire within 30 days |
| `privacy.html` crash section | Above 25 km/h | From about 12 km/h |
| `terms.html` summary, §2, §3 | Trip Head = on-road lead; plans in the app; "unless you turn this off" | Trip owner = creator; Trip head = settings only; Lead = riding role; plans on the website, upgrade-only while active, may be free (access modes); refunds per `/refunds`; operators; "call 112" |
| `privacy.html`, `terms.html`, `delete-account.html` | Personal contact e-mail | The address in `SUPPORT_EMAIL` (role address), else the home page contact form |
| `store/LISTING.md` (old draft) | 15 s countdown, "you switch this on" for texts, "No Bluetooth" | Still old: use `store/out/play_assets/listing_text.md`; it still says texts are switched on by the rider and should be updated |

New pages support can link: `/refunds` (refund and cancellation policy: website purchases only, plans
do not renew, a full refund ends the plan, a partial refund keeps it) and `/security` (responsible
disclosure, with `/.well-known/security.txt`).
