# Prompt: finish and release CoRoute v3.55 (paste into your agent)

```
Finish and release CoRoute v3.55. Repo wise-chandrasekhar/coroute_app, branch release/v3.55.0, Flutter C:\Users\<you>\flutter.
Follow docs/DEPLOY_PROMPT_v3.55.md for details. Stop and report at any failed safety gate. Never print or commit secrets.

A. BUILD AND COMMIT
1. flutter pub get && flutter analyze && flutter test. Fix code (or tests asserting intentionally changed text).
   Only the 4 ui_audit path_provider tests may stay failing. Report the counts.
2. cd gateway && npm ci && npm test. Known timing-flaky tests: public_ride_mirror, two_node_failover, job_lease, login performance; re-run them alone.
3. Commit the working tree in logical chunks (theme/design, settings, admin charts, website, 3D map bikes + assets, plans no-downgrade,
   coupon link + install referrer, review persistence, notice dedupe, docs, tests) and push. Delete _to_delete/.

B. SERVERS (VM2 first, then VM1, per gateway/deploy/RUNBOOK.md)
1. Take an encrypted DB backup. Store it durably (Object Storage bucket or the backup volume, not /tmp) and dry-run restore it.
   Also move the old /tmp/db_predeploy_backup to durable storage and delete the /tmp copy.
2. Deploy the gateway + website. Env changes: REDIRECT_LEGACY_HOST=true (owner decision: redirect DuckDNS website pages now;
   /api, /ws, /.well-known, live/watch links are never redirected). Keep PUBLIC_ORIGIN=https://coroute.devmonks.space.
3. Check on both hosts:
   - health, /, /leaderboard, /get?coupon=TEST1, /api/public/alltime-stats, /admin/analytics/trends (admin token);
   - assetlinks identical on both hosts;
   - https://coroute.duckdns.org/ gives a 301 to the new domain, but https://coroute.duckdns.org/api/health gives 200 (NOT redirected);
   - a 3.54/3.55 app build still signs in and joins a ride via duckdns.
4. Object Storage: set REVIEW_PHOTO_STORE=par and the APK store settings per docs/features_355/platform.md. Upload a test photo and check it serves.
5. Calendar reminder for 1 week from now: if no HTTPS problems, raise HSTS on coroute.devmonks.space to max-age=31536000 in both Caddyfiles and reload.

C. SECURITY
1. Rotate the JWT secret (24–72 h grace, runbook in features_355/platform.md) and the DB password.
2. The owner regenerates the DuckDNS token; put the new one only in OCI Vault and the Caddy env on both VMs; check that certificates renew.
3. Move vm_provision_ssh.key off VM1 (keep it in Vault / the admin machine). Confirm VM1 can no longer SSH to VM2 without it.

D. OWNER ITEMS (ask, don't invent)
- SMS DLT templates whitelisting coroute.devmonks.space (confirm done).
- The 4 Firebase app values (COROUTE_FCM_*) for the build.
- Razorpay: webhook https://coroute.devmonks.space/<membership webhook path from routes>, website URL updated.
- Play Console: website and privacy URLs on the new domain; the Play App Signing SHA-256.

E. ANDROID RELEASE
1. Add the Play App Signing SHA-256 to assetlinks.json (keep the upload key fingerprint too). Deploy and check on both hosts.
2. Build: flutter build appbundle --release (no COROUTE_API; COROUTE_FCM_* via gradle properties). Bump the build number if 10019 was already uploaded.
3. Upload to Play Internal testing.

F. DEVICE GATE (2–4 Android phones: one group ride, one solo). Use the checklist in DEPLOY_PROMPT step 7. Must pass:
   - SOS hold and the crash alarm;
   - emergency texts (Play build opens the messages app);
   - lock-screen Medical ID;
   - changing the speed limit mid-ride;
   - a siren recording with earbuds, and the Siren alerts switch off → the mic dot disappears;
   - music lowering when speeding, and a call during a ride;
   - Talk/Mute from the lock screen;
   - pillion seat on 2 phones, and one "I'm OK" answer counting for both;
   - 3D bikes rotating correctly, light and dark theme;
   - a crew ride invite with the app killed → push → invitation screen;
   - friend invite link and coupon link /get?coupon= open the app on both hosts;
   - upgrade allowed, downgrade refused;
   - the domain fallback (block the new host on the phone → the app uses DuckDNS).
   Any SOS/crash/emergency failure = STOP, no Play release.

G. LOAD AND RESILIENCE
1. Failure drill: stop the live node mid-ride; the other node takes over; riders reconnect; SOS still delivered.
2. 30-minute soak with simulated riders (test/integration/live_convoy_verifier.js or the soak script). Record CPU, memory and latency;
   set the live-rider cap in config from the results.
3. Restore drill: restore the backup into a scratch DB and verify counts.

H. ROLLOUT
Internal testing OK → Production staged rollout 10% → (48 h, crash-free ≥ 99.5%, no SOS issues) → 50% → 100%.
Monitor the Play vitals, gateway logs and admin overview daily.

REPORT after each section: what passed or failed, versions, commit hashes, URLs, decisions needed.
```
