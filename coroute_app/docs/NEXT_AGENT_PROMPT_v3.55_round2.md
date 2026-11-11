# CoRoute v3.55 round 2: next prompt for the release agent

Build 3.55.0+10023 (up to commit f01cb7e: handbook, legal pages, minimal profile/settings, access modes, operators, ride chat, navigate, website overhaul) is already deployed. This prompt covers only what came after it. Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway on two OCI VMs + website + web admin). Build 3.55.0+10023 is deployed. Ship the next increment: commit, test, build, deploy, verify, and continue the Play Store work. Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0, Flutter C:\Users\santhosh\flutter. Full background: PROJECT_CONTEXT.md, docs/MASTER_AGENT_PROMPT_v3.55.md (sections 4-8 still apply for deploy and Play), docs/handbook/README.md.
- Never commit or print secrets (CLUSTER_CREDENTIALS.md, .env, key.properties, keystores, FCM JSON, SMTP passwords). Secrets live in OCI Vault and /etc/coroute/*.env.
- The app must show no prices/payments/coupons: dart tool/play_policy_scan.dart must print 0 hits.
- Never weaken SOS, crash detection, emergency texts or the lock-screen Medical ID.

=== 1. WHAT IS NEW (uncommitted in the working tree; ~93 files) ===
A) Emergency texts from the rider's own SIM (no SMS provider; owner decision):
   - AndroidManifest: SEND_SMS + <uses-feature android.hardware.telephony required="false"> + EmergencyTextReceiver. No READ_SMS / RECEIVE_SMS / READ_PHONE_STATE.
   - New EmergencyTexts.kt (native queue + receiver), SmsChannel.kt (enqueue / cancelTexts / textStatuses), MainActivity.kt wiring.
   - Dart: lib/domain/safety/emergency_texts.dart (rules), sms_sender.dart, pending_sos.dart (texted-SOS record), safety_service.dart (send / cancel / "safe now" / test text), convoy_service.dart onMySosClosed, main.dart.
   - UI: emergency_texts_disclosure.dart (shown after saving a contact, from permissions, from Safety health), Safety health "Emergency texts" status + "Send a test text", wording on contact form / SOS screen / solo card / always-on list.
   - Behaviour: automatic texts (no tap) on SOS (10 s cancel window for a manual SOS), crash countdown end, rider-down and check-in escalations; up to 5 contacts; retries 30 s / 2 / 5 / 10 min and 3 s after network returns; queue survives app kill and reboot; "safe now" once after resolve; 30 texts per 24 h cap; denied permission → prefilled messages-app fallback.
   - SMS_PROVIDER stays off (server SMS code kept, unused).
B) Lifecycle e-mails (docs/features_355/lifecycle_emails.md): welcome e-mail once per new account (password + Google; steps, /guide link, group-rides block → /plans or "free right now", optional welcome coupon), ride summary e-mail after rides ≥ 2 km and ≥ 10 min (no speeds, route PNG with first/last 300 m cut, /trip/<id> owner-only page), e-mail preferences (Account & receipts always; Ride summaries + Tips on; Offers opt-in) on /account#emails and signed one-click unsubscribe, new pages /guide and /trip/<id>, templates "Welcome e-mail" and "Ride summary e-mail" in web admin › Templates. Files: gateway/src/lifecycle_emails.js, route_png.js, templates.js, public/guide.html, public/trip.html, public/assets/trip.js.
C) E-mail studio (docs/features_355/email_marketing.md): web admin › Notifications › E-mail studio — 8 starter templates, block editor (header image, text, coupon, price, button, image, divider, fixed footer), variables, audiences (opted-in riders only for marketing), unique single-use coupon codes per recipient, send now / schedule / automation rules (win-back, plan ending), weekly cap 2 + quiet hours 21:00-09:00 IST, click tracking via /r/<token> (no open pixels; can be switched off), reports. Files: gateway/src/email_marketing.js, public/admin/email_studio.js/.css, plus small edits in repo.js, mailer.js, offer_emails.js, notifications.js, notify.js, offers.js, admin.js, admin index.html/admin.css.
D) Docs/website wording: privacy.html + privacy-and-security.html (texts sent from the rider's own number; e-mails we send; click tracking), docs/features_355/sos_sms.md, docs/handbook/compliance/play_store_compliance.md (§3a SMS permission declaration text + second video script), user handbook lines, MASTER_AGENT_PROMPT_v3.55.md (items l, m, n).

=== 2. COMMIT ===
1. git status; check no secrets are staged. Commit in chunks: "feat(v3.55): emergency texts from the rider's SIM", "feat(v3.55): welcome and ride summary e-mails", "feat(v3.55): e-mail studio", "docs(v3.55): SMS, e-mail and privacy updates". Delete coroute_app/_to_delete/. Push.

=== 3. TEST AND BUILD ===
1. cd gateway && npm ci && npm test → expect ~1133 passing (flaky alone-reruns: public_ride_mirror, two_node_failover, job_lease, login performance).
2. flutter pub get && flutter analyze && flutter test (new: test/emergency_texts_357_test.dart, test/emergency_texts_safety_357_test.dart). Fix code, not tests, unless text changed on purpose.
3. dart tool/play_policy_scan.dart → 0 hits.
4. Bump pubspec.yaml to 3.55.0+10024.
5. flutter build appbundle --release and flutter build apk --release --split-per-abi (no COROUTE_API; COROUTE_FCM_* gradle properties). FIRST compile of EmergencyTexts.kt and the changed SmsChannel.kt/MainActivity.kt — fix compile errors carefully, never by removing emergency texts.

=== 4. DEPLOY GATEWAY + WEBSITE (VM2 then VM1) ===
1. Encrypted DB backup to durable storage; dry-run restore.
2. Env on both VMs (secrets from Vault):
   - SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, MAIL_FROM, MAIL_REPLY_TO — confirm set (owner says configured).
   - MAIL_POSTAL_ADDRESS=<owner's postal address> — REQUIRED; real marketing campaigns and automation rules are refused without it (ask the owner).
   - SUPPORT_EMAIL / SECURITY_CONTACT — confirm set (role addresses).
   - Optional: TRIP_MEMORY_DELAY_MIN (default 10), LIFECYCLE_EMAIL_RATE (default 5), OFFER_EMAIL_RATE.
   - SMS_PROVIDER=off (unchanged).
3. Deploy VM2, restart, check; then VM1. Check on both hosts: /api/health, /guide, /trip/<id> (signed-in owner only; others refused), /account#emails, /r/<token> redirect from a test campaign, /admin › Notifications › E-mail studio loads, /privacy shows the e-mail and SMS sections.
4. Sending domain: verify SPF, DKIM and DMARC for the MAIL_FROM domain (send a test to Gmail and Outlook; check "mailed-by/signed-by" and that it lands in Inbox, not Spam). Report the results.

=== 5. E-MAIL QA ===
1. Register a new account (password) and one with a new Google account → one welcome e-mail each; group-rides block matches the current access mode; Tips off → block omitted.
2. Finish a real or simulated ride ≥ 2 km / 10 min → ride summary e-mail ~10 min later, once; route image has no start/end 300 m; "View trip report" opens /trip/<id> for the owner only.
3. Unsubscribe links: open → confirm page; confirming turns off only that category; /account#emails reflects it; Account & receipts can't be turned off.
4. E-mail studio: Templates › Festive offer › Use → add a coupon block (active coupon), price block, button → preview desktop/mobile, light/dark → Send test to me. Then a small real campaign to an internal test audience with "unique codes" on → redeem one code on /plans (Razorpay test mode) → report shows sent, click, redemption. A second redemption of the same code is refused.
5. Automation rule: create "win-back 30 days inactive" against a test account; confirm it sends once and respects the weekly cap and quiet hours.
6. Receipt/refund e-mails still arrive (Razorpay test purchase + refund from /admin).

=== 6. DEVICE SAFETY GATE FOR EMERGENCY TEXTS (2 phones: rider + contact) ===
Record phone model, Android version, result. Any failure = STOP (no Play release).
1. Fresh install: add an emergency contact → disclosure screen → grant SMS → Safety health shows "Emergency texts: ready" → "Send a test text" arrives on the contact phone.
2. SOS hold with the screen LOCKED, app in background → after ~10 s the contact receives the SMS (name, "needs help", time, live link, lat/lng); SOS screen shows sent → delivered.
3. Crash alarm countdown to 0 without "I'm OK", screen locked → SMS "may have crashed" arrives with no tap.
4. Cancel a manual SOS within 10 s → no SMS. Resolve after the SMS → "safe now" arrives once.
5. Airplane mode on → raise SOS → wait 1 min → airplane off → SMS goes out by itself; repeat after force-closing the app.
6. Dual-SIM phone: text goes from the default SMS SIM.
7. Deny the SMS permission → prefilled messages-app fallback opens; Safety health says texts need a tap.
8. Diagnostics log shows only last-3-digit numbers.
9. A tablet without a SIM can still install the build (Play internal testing).
Also re-run the core safety checks from MASTER_AGENT_PROMPT section 6 A (SOS, crash false alarms, Medical ID).

=== 7. GOOGLE PLAY ===
1. Upload 3.55.0+10024 to Internal testing → install on the test phones → repeat section 6 on the Play-installed build.
2. Policy › App content › Sensitive permissions › SMS and Call Log: Permissions Declaration Form for SEND_SMS:
   - Core functionality: "Physical safety / emergency alerts"; CoRoute is not the default SMS app.
   - Use the justification text in docs/handbook/compliance/play_store_compliance.md §3a.
   - Video (YouTube unlisted, 30-90 s): set an emergency contact → disclosure → grant permission → raise an SOS with the screen locked → the SMS arriving on a second phone → "safe now". Script in the same doc.
3. Data safety: add "SMS: sent from the user's device to the user's chosen emergency contacts; not collected by CoRoute".
4. Update the privacy policy link check (the policy now explains SMS and e-mails).
5. Continue the remaining Play steps from MASTER_AGENT_PROMPT section 8 (closed testing with 12+ testers for 14 days, apply for production, staged rollout) if not finished. Release notes: docs/handbook/users/release_notes_v3.55_users.md (add one line: "Emergency texts now go out automatically from your phone after an SOS or crash alarm.").
6. Update the website APKs + SHA256SUMS and the gateway latest build to 10024 (never raise MIN_APP_BUILD).

=== 8. LAUNCH RISK TO RAISE WITH THE OWNER (do not change without a decision) ===
The app loads map tiles directly from tile.openstreetmap.org and the gateway routes through the public OSRM demo (router.project-osrm.org, GEO_ROUTE_URL default). Both have usage policies that forbid heavy/production use (and OSM forbids bulk tile downloads used by offline route maps). Before public launch the owner must choose:
   A) Google Maps SDK for the online map + a licensed/self-hosted OSM tile source for offline route maps, or
   B) one licensed/self-hosted OSM tile provider for everything;
   and routing on a self-hosted Valhalla (has motorcycle routing) or OSRM on a small extra VM (set GEO_ROUTE_URL to it).
Report the current tile/routing request volume from the logs to size this.

=== 9. OWNER ITEMS TO ASK FOR ===
MAIL_POSTAL_ADDRESS; confirmation that SMTP domain DNS (SPF/DKIM/DMARC) can be edited; Play Console access for the SMS declaration; grievance officer and refund timelines (if still [OWNER TO FILL]); map/routing decision (section 8).

=== 10. REPORT ===
Commit hashes, build number, checksums, deploy times, test counts, e-mail QA results (with inbox/spam placement), device table for section 6, Play Console status (SMS declaration submitted?), open issues, decisions needed.
```
