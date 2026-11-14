# CoRoute round 10: free offline long-range link and crash rescue beacon (build 3.55.0+10029)

Round 9 is committed as build 3.55.0+10028 (1b22be6). Round 10 is in the working tree, uncommitted, and ships as
build 3.55.0+10029 (pubspec already bumped). Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway +
website + web admin). Build 3.55.0+10028 is committed. Ship round 10 as build 3.55.0+10029: commit, test, build, the
multi-phone field tests below, Play internal testing. Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Repo C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app, branch release/v3.55.0.
- Never commit or print secrets, real IPs, OCIDs, tenancy e-mails or key paths. MESH_KEY_SECRET goes in the Vault.
- Never weaken SOS, crash detection, emergency texts from the rider's own SIM, Medical ID, ride lock, lock-screen
  cockpit, app lock. Fix code, not tests, unless a text changed on purpose. dart tool/play_policy_scan.dart -> 0 hits.
- Read first: docs/features_355/offline_long_range_link.md, docs/quality/ROUND10_MESH_NOTES.md,
  docs/features_355/rescue_beacon.md, docs/quality/ROUND10_RESCUE_NOTES.md,
  docs/release/PLAY_CONSOLE_DECLARATIONS_10027.md (section G: Nearby devices).
- Do not commit _to_delete/ or _incoming/; delete _to_delete/ after the commit.

=== 1. WHAT IS NEW ===
A) Free offline long-range group link (no hotspot, no extra hardware; starts by itself when the signal drops):
   - Bluetooth LE Long Range (Coded PHY) extended advertising + L2CAP data (Android 10+, GATT on 8-9), 1M PHY fallback
     for phones without Coded PHY; Wi-Fi/hotspot UDP path kept. Kotlin: LongRangeBle.kt, MeshBleChannel.kt.
   - Multi-hop relay with dedupe, hop limit, relay suppression, priorities SOS > alerts > positions > voice > chat;
     AES-256-GCM frames with a per-ride key from the server (MESH_KEY), replay protection.
   - Any rider with data bridges the group to the server (MESH_BRIDGE); bridged riders show connected; a bridged SOS is
     stored like any SOS, one alert whichever copy arrives first.
   - Store-and-forward: own SOS resent until anyone acknowledges; voice degrades to 15 s walkie-talkie clips across gaps.
   - Chain-keeper warns the rider at a stretching gap and the lead; status chip "Offline link: 5 riders, 2 hops";
     group panel "4 of 6 phones support long range".
   - Simulation (10 riders over 1 km): SOS to every rider 100 % (Coded PHY), positions 96 % within 10 s, clips 99 %.
     Realistic range 200-600 m per hop between bikes; this must be proven on the road (section 5).
   - A "resolved" SOS over the mesh does not close the server alert (owner decision pending on per-rider signatures).
B) Crash rescue beacon (only after the crash countdown ends with no answer, or an open SOS with no answer to
   "Still able to respond?"):
   - escalating 2-4 kHz siren on the alarm stream at max volume, then duty cycle (10 s every 30 s, every 60 s after
     15 min), silent at the 10 % SOS battery reserve; DND total silence -> alarms only, restored afterwards;
   - near-ultrasonic locator code (17.8-19.0 kHz and 14.4-15.6 kHz, capped at -13 dBFS) + BLE locator advertisement
     (own service UUID) + vibration + SOS torch/screen flash at night (never above 3 flashes/s, never face-down);
   - stops: rider "I'm OK", SOS resolved, or a bystander's 3 s hold "Stop siren: help is here" (logged; SOS stays open,
     silent locator keeps running);
   - responders: "Find Ravi" finder screen (compass + distance, offline mini map, ride/walk there, BLE and sound
     hotter/colder meters, "Listen" prompt, "Ping the phone"); listens only during an open SOS, on-device, nothing
     recorded; the ride mic switches to 48 kHz only while the finder listens;
   - gateway: rescueId on every SOS alert (helpers get it after accepting), RESCUE_PING (group members/accepted helpers,
     rate-limited).
   - Lab: locator 30-50 m in a quiet forest (15-20 m with an engine idling nearby), siren audible to ~100 m, 0 false
     riders in 25 min of forest/engine/wind noise.
C) Pre-ride phone check: new "Nearby devices" item (Android 12+, warning only, never blocks a ride) so the mesh and the
   rescue beacon have Bluetooth permission BEFORE a crash; one shared helper (lib/core/permissions/nearby_permission.dart).
D) Manifest: BLUETOOTH_SCAN (neverForLocation), BLUETOOTH_ADVERTISE, BLUETOOTH_CONNECT; BLUETOOTH/BLUETOOTH_ADMIN
   (maxSdkVersion 30); uses-feature bluetooth_le required=false. No CAMERA (torch needs none).

=== 2. COMMIT ===
"feat(mesh): free offline long-range link (BLE Coded PHY, relay, bridge, store-and-forward, chain-keeper)",
"feat(rescue): crash rescue beacon (escalating siren, ultrasonic + BLE locator, strobe, finder)",
"feat(app): Nearby devices in the pre-ride phone check", "feat(gateway): mesh bridge, rescueId, RESCUE_PING",
"docs(v3.57): round 10 notes", "chore(release): 3.55.0+10029". Push.

=== 3. TEST AND BUILD ===
1. cd gateway && npm ci && npm test -> expect 1448 passing (flaky alone-reruns: public_ride_mirror, two_node_failover,
   job_lease, login performance, email_marketing_357).
2. flutter pub get && flutter analyze && flutter test (new: test/mesh_*, test/rescue_*,
   test/services/nearby_devices_check_test.dart, the updated pre_ride_phone_check_test.dart, and the rescue victim
   service test that was only run with a stub). dart tool/play_policy_scan.dart -> 0 hits.
3. tool/rescue_lab/run.sh -> the lab tables match docs/features_355/rescue_beacon.md.
4. Release build (appbundle + split APKs). FIRST compile of LongRangeBle.kt, MeshBleChannel.kt, RescueBeaconChannel.kt
   and the MainActivity registrations. tool/check_16kb_alignment.sh passes. Merged manifest: list the Bluetooth
   permissions in the report.
5. Release-build R8 check: the new Kotlin classes are reached through MethodChannels (no reflection), but run the
   features on the RELEASE build; any crash -> narrowest keep rule from the mapping file.

=== 4. ENV ===
MESH_KEY_SECRET (Vault, 32+ random bytes, same on both nodes; without it the per-ride key is derived from JWT_SECRET
with a warning), MESH_BRIDGE_PER_SEC (default fine). Both in deploy/.env.example. Deploy gateway first (release.sh
staging -> vm2 -> vm1), then the APK. Old apps ignore the new messages.

=== 5. FIELD TESTS (real roads/forest; report phone models + Android versions, distances, results) ===
Mesh M0-M12 (ROUND10_MESH_NOTES.md), most important:
 - M1: 4-6 phones spread over ~1 km on a road, ALL in flight mode with Bluetooth on: positions and SOS reach everyone;
   record per-hop distances that worked.
 - M2: mixed phones with and without Coded PHY. M3: one rider with mobile data bridges the rest to the server
   (check the web live map shows everyone).
 - M4: create a gap and close it: chain-keeper warning, store-and-forward delivery on rejoin.
 - M5: SOS across 3 hops in flight mode, plus the rider's own-SIM SMS still sent.
 - M6/M7: live voice over 1-2 hops; clips across a gap. M8: automatic switching in a real dead zone and back.
 - M9: battery per hour in offline mode. M10: screen off on Android 14+. M12: permission flow.
Rescue R1-R14 (ROUND10_RESCUE_NOTES.md), most important:
 - forest or park with 2-3 phones: victim phone in a pocket, under a jacket, face-down; measure detection distance for
   siren (by ear), locator sound and BLE; walk in with the finder and confirm the guidance gets you there;
 - silent/DND override and volume restore; battery per hour of beacon (target <= 8 %); bystander stop; night strobe
   rate; an old phone whose speaker rolls off at high frequency; siren detector and intercom while the finder is open.
SAFETY GATE (any failure = STOP): normal crash countdown, "I'm OK", cancel window and SOS behave exactly as in 10028;
the beacon never starts during a normal ride or before the countdown ends; emergency SMS from the rider's own SIM is
sent in every offline test.

=== 6. GOOGLE PLAY ===
1. Internal testing 3.55.0+10029; upload the mapping file and native debug symbols.
2. Data safety / permissions: Nearby devices (Bluetooth scan/advertise/connect) used to connect group riders' phones
   offline and to locate a crashed rider; no location derived from Bluetooth (neverForLocation); microphone use for
   the rescue finder processed on the phone, not recorded (section G of PLAY_CONSOLE_DECLARATIONS_10027.md).
3. Release notes: "Stay connected with your group with no signal: phones link to each other automatically",
   "After a crash with no response, your phone sounds a siren and helps your riders find you".
4. Website and handbook wording from the notes (do NOT claim 1 km per phone; say "the group's phones pass messages
   along, a few hundred metres per hop").
5. LATEST_APP_BUILD=10029 on both VMs; website APKs + SHA256SUMS.

=== 7. OWNER DECISIONS ===
- Per-rider signatures for mesh frames (would let "I'm safe" over the mesh close the alert and stop forged frames
  from other riders of the same ride).
- Website/handbook claim wording for the offline link and the rescue beacon.

=== 8. REPORT ===
Commit hashes, build number, checksums, test counts, Kotlin compile result, field test tables (distances per hop,
delivery, battery), rescue detection distances, safety gate results, Play status, open issues, decisions.
```
