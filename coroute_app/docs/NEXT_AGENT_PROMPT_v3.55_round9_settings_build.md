# CoRoute round 9: fewer settings, speed-limit fix, Play build health (build 3.55.0+10028)

Rounds 7-8 are committed as build 3.55.0+10027 (commits up to 9a5346a). Round 9 is in the working tree, uncommitted,
and ships as build 3.55.0+10028 (pubspec already bumped). Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Build 3.55.0+10027 is committed. Ship round 9 as build 3.55.0+10028: commit, test, build,
release-build device test, Play internal testing, console declarations. Report after each section. STOP at any failed
safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths.
- Never weaken SOS, crash detection, emergency texts, Medical ID, ride lock, lock-screen cockpit, app lock.
- dart tool/play_policy_scan.dart must print 0 hits. Fix code, not tests, unless a text changed on purpose.
- Read first: docs/quality/ROUND9_SETTINGS_NOTES.md, docs/release/ROUND9_BUILD_NOTES.md,
  docs/release/R8_KEEP_RULES_v3.57.md, docs/release/PLAY_CONSOLE_DECLARATIONS_10027.md (applies to 10028 too),
  docs/release/PLAY_BUILD_HEALTH_PLAN_v3.57.md.
- Do not commit _to_delete/ or _incoming/; delete _to_delete/ after the commit.

=== 1. WHAT IS NEW ===
A) Speed limit changed mid-ride now applies at once (owner bug report):
   - voice no longer drops the new warning (per-limit key, 5 s window) and says the limit
     ("Over limit. 72 km/h, limit 60."): lib/domain/safety/overspeed_voice.dart, VoiceService.speakOverspeed;
   - a limit change refreshes the lock-screen notification, the Android 16 live update ("Limit N") and Ride AOD at once;
   - an offline solo ride uses the Settings limit;
   - the stricter of the rider's own and the lead's group limit still wins; Settings shows which one applies.
   No gateway change (group limit path verified).
B) Settings 35 -> 18 choices: safety warnings always on (curves, speed limit display, overspeed, hazard, rough road,
   twisty, long-ride/night nudges); fixed smart values (overspeed margin +10 %/min 5 km/h, idle = Ride AOD, screen on
   only while moving, noise reduction Strong, wind mode automatic, break reminder 2 h); voice alerts and battery saver in
   the ride screen quick settings; "Advanced" section (lock-screen cockpit switch, fuel, navigation app, quick replies,
   permissions, features guide); "Mute this ride" button on nudge cards. One-time migration writes removed toggles back
   to ON and deletes retired keys; never touches consent ("Help make roads safer" stays off by default).
C) Play build health:
   - R8: whole-package keep rules removed (our package, io.flutter, dexterous, gson, foreground task, record, gms.auth,
     credentials); Log.v/Log.d stripped. HIGHEST RISK of a release-only crash: see section 4.
   - androidResources.localeFilters = en, hi, te, ta, kn, ml, mr (85 -> 7 localizations).
   - Manifest: tools:node="remove" for AD_ID, READ_PHONE_STATE, READ/WRITE_EXTERNAL_STORAGE, CAMERA ("Take a new photo"
     uses the camera app, no permission).
   - libcoroute_voice.so built for arm64-v8a, armeabi-v7a, x86_64 with 16 KB pages; tool/check_16kb_alignment.sh.
   - Minimum Android is 7.0 (API 24): website, JSON-LD and docs updated.

=== 2. COMMIT ===
git status; nothing secret. Commits: "fix(app): speed limit changes apply mid-ride", "feat(app): fewer settings, safe
defaults on", "build(android): narrow R8 keep rules, locale filters, permission removals, 16 KB native checks",
"fix(website): minimum Android 7.0", "docs(v3.57): round 9 notes, Play declarations", "chore(release): 3.55.0+10028".
Push.

=== 3. TEST AND BUILD ===
1. cd gateway && npm ci && npm test -> expect 1434 passing (flaky alone-reruns: public_ride_mirror, two_node_failover,
   job_lease, login performance, email_marketing_357).
2. flutter pub get && flutter analyze && flutter test (new: test/round9_speed_limit_live_pure_test.dart,
   test/round9_settings_live_test.dart; updated: settings_minimal_355, network_settings_ui, voice_hud_notification,
   settings_lock_cockpit_migration, voice_service, audio_and_calls_355). dart tool/play_policy_scan.dart -> 0 hits.
3. flutter build appbundle --release and flutter build apk --release --split-per-abi. Gradle must accept the new
   settings (AGP 9: androidResources.localeFilters; CMake ABI filter).
4. tool/check_16kb_alignment.sh <aab and each apk> -> passes for arm64-v8a, armeabi-v7a and x86_64, and
   libcoroute_voice.so is present for all three.
5. Review the merged manifest (command in ROUND9_BUILD_NOTES.md): none of AD_ID, READ_PHONE_STATE, storage, CAMERA;
   write the final permission list into the report.

=== 4. RELEASE-BUILD DEVICE TEST (R8 safety gate) ===
Install the RELEASE build (not debug) on two phones (one Android 14+, one Android 8-10). Run all 14 items in
docs/release/R8_KEEP_RULES_v3.57.md: crash alarm full-screen over the lock screen, notification actions (I'm OK, SOS,
Talk, Mute) from the lock screen, ride foreground service start/stop and after reboot, intercom with noise reduction,
Google sign-in, emergency texts queue, quick settings tile, app lock, lock-screen cockpit, Android 16 live update,
plan reminders after reboot, profile picture "Take a new photo", push notifications.
ANY crash or missing behaviour: get the stack trace, decode it with build/app/outputs/mapping/release/mapping.txt, add
the narrowest keep rule, rebuild, retest. If not fixable quickly: restore the old rules listed in
R8_KEEP_RULES_v3.57.md for 10028 and report (the R8 change then moves to 10029).

=== 5. DEVICE QA (report each with phone model + Android version) ===
- Speed limit S1-S14 (ROUND9_SETTINGS_NOTES.md): change your own limit mid-ride -> next warning uses it and the voice
  says it; lead changes the group limit mid-ride -> a member phone and an old 10027 phone follow within ~2 s; the
  lock-screen cockpit, Ride AOD and Android 16 live update show the new limit; offline solo ride uses the Settings limit.
- Settings: an existing user who had turned warnings off sees them on after the update; "Help make roads safer" keeps
  its value; settings screen on a 320x568 phone and at the largest font; "Mute this ride" works and resets next ride.
- SAFETY GATE (any failure = STOP): SOS with the screen locked, crash countdown with no tap, cancel window,
  "safe now", emergency texts in airplane mode then back online, SOS during group voice.

=== 6. GOOGLE PLAY ===
1. Upload 3.55.0+10028 to Internal testing; upload the R8 mapping file and native debug symbols.
2. App bundle explorer should show: DEX optimization above Medium/46 %, 7 localizations, the permission count from
   the merged manifest, API 24+, target 36, "Supports 16 KB". Report the numbers.
3. Policy > App content: submit or update the declarations in PLAY_CONSOLE_DECLARATIONS_10027.md (background location,
   foreground service location + microphone with videos, SMS, full-screen intent for the crash alarm, battery
   optimization justification) and the Data safety answers (location, audio, photos, device IDs, app activity).
4. Store listing: minimum Android 7.0; release notes: "Speed limit changes now apply instantly during a ride",
   "Simpler settings: safety warnings are always on", "Clearer group voice with noise reduction" (if not already in
   10027's notes).
5. Update the website APKs + SHA256SUMS and LATEST_APP_BUILD=10028 on both VMs (never raise MIN_APP_BUILD).

=== 7. OWNER DECISIONS ===
- Own speed limit able to raise the warning above the lead's group limit (default now: stricter wins).
- Voice alerts and battery saver only in the ride screen quick settings, or back in Settings.
- Lock-screen cockpit: keep the switch under Advanced (default on) or make it always on.

=== 8. REPORT ===
Commit hashes, build number, checksums, test counts (gateway, flutter test, analyze, policy scan), 16 KB check output,
final permission list, release-build device test table (R8), speed-limit and settings QA results, console numbers
(DEX %, localizations, permissions, 16 KB), declarations submitted, open issues, decisions needed.
```
