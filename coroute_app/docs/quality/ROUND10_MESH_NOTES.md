# Round 10: offline long-range group link (Bluetooth LE Coded PHY mesh) - notes

Build: 3.55.0+10028 (unchanged). Design and rider-facing behaviour: docs/features_355/offline_long_range_link.md.
A parallel agent built the crash rescue beacon in the same tree (docs/features_355/rescue_beacon.md). Lanes were kept;
the shared files got marked edits only (section 3).

## 1. Status: verified vs written-but-not-compiled

| Part | State |
|---|---|
| Pure Dart domain (crypto, frames, router, store-and-forward, voice policy / floor / clips / ADPCM, chain-keeper, mode switch, capability report, link planner, node engine, simulator) | **Verified**: `dart analyze lib test` clean; 9 new pure test files, all passing with tool/pure_dart_test (section 5). AES-GCM matches the NIST vectors. |
| Gateway bridge (src/mesh_bridge.js + ws.js / ws_limits.js / convoys.js hooks) | **Verified**: test/mesh_bridge_r10.test.js (6 tests), including frames **sealed by the Dart code** opened in Node. Full `npm test`: section 5. |
| Data layer (OfflineLinkService, BLE transport, platform channel, bridge client, voice link) and the UI chip / panel line | **Analyzed, not run**: needs Flutter and a device. The decisions inside it are the tested pure pieces. |
| Kotlin (LongRangeBle.kt, MeshBleChannel.kt, the MainActivity registration) | **Written, not compiled**: there is no Android SDK here. Written for compileSdk 37 / minSdk 24. Every API above 24 is behind `Build.VERSION.SDK_INT` (26: Coded PHY / extended advertising / scan PHY / connectGatt with PHY; 29: L2CAP CoC; 33: the new GATT write / notify / descriptor calls). Missing hardware, adapter off and missing permissions all return "not available", never throw. **One APK build is needed (QA M0).** |
| Intercom over the mesh | **Analyzed, not run.** The intercom change is a routing switch; the Opus / RNNoise path is unchanged. Needs devices (M6, M7). |

## 2. Files

New, in my lane:
- `lib/domain/mesh/crypto/aes_gcm.dart`: AES-128/192/256 + GCM, pure Dart.
- `lib/domain/mesh/mesh_frame.dart`: sealed v2 frame, short ids, keyring, replay guard.
- `lib/domain/mesh/mesh_messages.dart`: SOS, SOS ack, alert, position (pos2 scales), voice, clip NACK, chat, hello,
  beacon.
- `lib/domain/mesh/mesh_router.dart`: flooding, dedup, TTL, suppression, priority scheduler and budgets.
- `lib/domain/mesh/mesh_neighbors.dart`: neighbour table, RSSI trend, rider fixes and hops.
- `lib/domain/mesh/mesh_store_forward.dart`: bounded store-and-forward, SOS retry until acknowledged, epidemic offers.
- `lib/domain/mesh/mesh_voice.dart`: live / clip policy, floor, clip recorder and assembler.
- `lib/domain/mesh/mesh_adpcm.dart`: IMA ADPCM fallback codec.
- `lib/domain/mesh/mesh_chain_keeper.dart`: break prediction, convoy order, rate limits.
- `lib/domain/mesh/offline_link_mode.dart`: automatic switching, duty plans, the capability report, the chip text.
- `lib/domain/mesh/mesh_link_planner.dart`: who opens which link.
- `lib/domain/mesh/mesh_node.dart`: one rider's engine (router + store + table + clips + acks).
- `lib/domain/mesh/mesh_sim.dart`: the multi-rider simulator (QA harness, not used at runtime).
- `lib/domain/mesh/mesh_voice_gate.dart`: the interface the intercom talks to.
- `lib/domain/mesh/mesh_transport.dart`: `MeshIncomingPacket` gained optional `rssi` / `via` (backwards compatible).
- `lib/data/services/offline_link/offline_link_service.dart`: the orchestrator; implements MeshVoiceGate.
- `lib/data/services/offline_link/mesh_ble_platform.dart`: the `coroute/mesh_ble` channel.
- `lib/data/services/offline_link/ble_long_range_transport.dart`: the BLE transport + the combined BLE/UDP transport.
- `lib/data/services/offline_link/mesh_bridge_client.dart`: bridge uplink queue and downlink planner.
- `lib/data/services/offline_link/mesh_voice_link.dart`: intercom ↔ mesh voice, floor and clip playback.
- `lib/presentation/offline_link/offline_link_widgets.dart`: the status chip and the panel line.
- `android/app/src/main/kotlin/space/devmonks/coroute_app/LongRangeBle.kt` and `MeshBleChannel.kt`.
- `gateway/src/mesh_bridge.js`.
- Tests:
  - `test/mesh_crypto_test.dart`
  - `test/mesh_frame_test.dart`
  - `test/mesh_router_test.dart`
  - `test/mesh_store_forward_test.dart`
  - `test/mesh_voice_test.dart`
  - `test/mesh_chain_keeper_test.dart`
  - `test/mesh_mode_test.dart`
  - `test/mesh_bridge_link_test.dart`
  - `test/mesh_simulation_test.dart`
  - `gateway/test/mesh_bridge_r10.test.js`
- Docs: `docs/features_355/offline_long_range_link.md` and this file.

## 3. Edits to shared / other files (all marked "Round 10 offline link")

| File | Edit |
|---|---|
| `lib/data/services/intercom_service.dart` | `offlineVoice` (MeshVoiceGate), `deliverOfflineVoice()`. A talk starts when the socket **or** the offline link can carry it. `_txOffline` keeps a talk on the path it started on. Codec and Opus bitrate (8-12 kbit/s) come from the gate. Unchanged when `offlineVoice` is null. |
| `lib/main.dart` | One `ChangeNotifierProvider<OfflineLinkService>` (lazy: false) after the intercom provider. It wires the intercom, the WarningScheduler gate (`safety.roadCare.mayAdviseFallingBehind`) and VoiceService. |
| `android/app/src/main/AndroidManifest.xml` | **No new entries.** The rescue-beacon agent had already declared BLUETOOTH_SCAN (neverForLocation), BLUETOOTH_ADVERTISE, legacy BLUETOOTH / BLUETOOTH_ADMIN (maxSdk 30) and bluetooth_le (not required). A marked comment says the offline link uses the same entries. |
| `android/.../MainActivity.kt` | Registers `coroute/mesh_ble` + `coroute/mesh_ble_events` and disposes them in `cleanUpFlutterEngine`. Not in the shared-file list, but there is no other way to register a channel; same pattern as the rescue channel. |
| `lib/presentation/rider/live_cockpit_map_screen.dart` | `const OfflineLinkChip(...)` under the permission banner and `const OfflineLinkCapabilityLine()` under the group roster. One import. |
| `gateway/src/ws.js` | Require, `MESH_CAP` in FEATURES, `meshBridge` on the hub, cases `MESH_HELLO` / `MESH_BRIDGE`, close and room-ended clean-up. |
| `gateway/src/ws_limits.js` | `MESH_BRIDGE` is a safety type (it can carry an SOS; the module does its own limits); `MESH_HELLO` max 512 bytes. |
| `gateway/src/convoys.js` | `patchRider(..., {trusted})` accepts `viaBridge` (any direct patch clears it); `publicRider` exposes `viaBridge` while it is under 30 s old. |
| `gateway/test/net_compat.test.js` | The exact HELLO feature list now ends with `mesh1`. |
| `gateway/deploy/.env.example` | `MESH_KEY_SECRET`, `MESH_BRIDGE_PER_SEC`. |
| `docs/release/PLAY_CONSOLE_DECLARATIONS_10027.md` | Appended section G. |

**Routes:** no HTTP route was added (everything is on the existing `/ws` socket), so `deploy/route_split.md` and the
route policy do not change. **Env vars:** `MESH_KEY_SECRET` (default: derived from JWT_SECRET; must be the same on
both nodes of a two-node deployment) and `MESH_BRIDGE_PER_SEC` (40) are both in `.env.example`.

**Not changed:** convoy_service.dart (mesh positions and SOS go in through the existing public
`applyMeshTelemetry`; own position, pending SOS and alerts are read through public getters), rider_model.dart,
realtime_service.dart (capabilities and the key travel in `MESH_HELLO` after SNAPSHOT, not in JOIN caps), the 3.55
hotspot mesh (`P2pMeshService` keeps running unchanged on UDP 42424; the new link uses 42425).

## 4. Permissions

- Android 12+: **Nearby devices**: `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`.
  They are asked once, the first time a group ride starts with Bluetooth LE available (remembered in
  `offline_link_bt_asked_v1`). If they are denied, the link runs on the UDP / hotspot path only and the SOS paths are
  untouched.
- Android 11 and older: legacy `BLUETOOTH` / `BLUETOOTH_ADMIN` (install time) and the location permission the app
  already has (needed for BLE scans there, and location services on).
- `neverForLocation` is honest here. The scan only reads CoRoute's own mesh beacons, and RSSI feeds link quality and
  the chain-keeper, never a position. Positions come from GPS, as before. Android filters some beacon formats
  (iBeacon / Eddystone) from scans with this flag; our service data is not affected.
- No new foreground service type. Radios run inside the existing ride service (type `location`; `microphone` while the
  intercom is on). BLE needs no FGS type of its own. **Watch on Android 14+ devices (M10).**
- Play Console: section G of PLAY_CONSOLE_DECLARATIONS_10027.md.

### Privacy wording (for the lead: privacy policy / store listing / in-app permission text)

> **Nearby devices (Bluetooth), Android 12 and newer.** During a group ride, CoRoute uses Bluetooth to keep riders
> connected when there is no mobile signal: phones pass positions, SOS alerts and push-to-talk voice to each other,
> rider to rider, and a phone that still has signal passes them on to the CoRoute server. Everything sent this way is
> encrypted for your ride only. CoRoute does not use Bluetooth to find your location, and it is off when you are not in
> a group ride.

Short permission rationale (in-app, before the system dialog if the lead wants one):
"Let your group stay connected without signal: CoRoute passes positions, SOS and voice phone to phone over Bluetooth
during group rides."

## 5. Tests and simulation

Pure Dart (`DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh <file>`):

| File | Tests | What |
|---|---|---|
| mesh_crypto_test | 5 | FIPS-197 AES-128/192/256; NIST GCM cases 2, 14, 16; tampering of ciphertext / tag / AAD / nonce / key |
| mesh_frame_test | 7 | short ids (same as the gateway); seal / open; outsiders cannot read or inject; relay header rewrite and TTL cap; replay: duplicate / stale / future / eviction low-water; every message codec; beacon MAC and minute binding |
| mesh_router_test | 7 | flood along a line with hop counts; TTL; dense-group suppression (≤ 4 relays among 12) and SOS never suppressed (11 relays); progress suppression; **voice flood never delays an SOS**, positions keep flowing, late live voice dropped, voice within its share; latest-only positions; neighbour RSSI trend |
| mesh_store_forward_test | 6 | expiry per class; latest-only; **own SOS retry 2/6/14/29/59 s until acknowledged**; epidemic offers and re-offer on rejoin; bounded storage never evicts SOS; SOS across a 30 s gap delivered and acknowledged |
| mesh_voice_test | 9 | live at 12 / 8 kbit/s, clip on no path / slow / lossy / floor busy, ADPCM rules; floor: Lead cut-in, fair share, stale, collisions; 15 s clip cap, chunking, out-of-order reassembly; missing-chunk requests and partial clips; ADPCM SNR > 15 dB |
| mesh_chain_keeper_test | 5 | time to break (RSSI / gap); convoy order; the rider in front of the gap warned and the lead note; no warning without a trend / not my link / during an emergency; rate limits |
| mesh_mode_test | 6 | off / standby / bridge / offline, the 8 s / 3 s / 10 s hysteresis; duty plans; "4 of 6 phones support long range"; chip text |
| mesh_bridge_link_test | 4 | link planner (lower id connects, fallback, budget, Coded only when both); bridge uplink filter; downlink choice |
| mesh_simulation_test | 2 | 10 riders, 1 km, random gaps (below) |

Gateway: `node --test test/mesh_bridge_r10.test.js` passes 6/6:
- Dart-sealed vectors open in Node;
- MESH_HELLO → key + caps map;
- bridged position with viaBridge / presence ONLINE / replay refused / direct wins;
- presence falls back to NO_SIGNAL;
- bridged SOS stored once whichever copy first (two bridges + the rider's own socket), and a mesh "resolved" never
  closes it;
- outsiders / proxied / non-members / garbage / stale refused; switch off → SOS only.

Full `npm test`:
- **First run** (before the net_compat update): 1448 tests, 1446 pass.
  - `net_compat` "HELLO keeps the 3.14 features first" asserts the exact feature list, which now ends with `mesh1`.
    Updated.
  - `public_ride_mirror` "two nodes ... replicate" hit a PR_UPDATE timeout under load. It passes on its own.
- **Final run**: 1448 tests, **1447 pass**, 1 fail.
  - `two_node_failover` "hand-back: a restarted live node is 503 syncing ..." got 200 instead of 503: a timing race
    under full-suite load, in code this round does not touch.
  - It passes on its own: `node --test test/two_node_failover.test.js` 12/12.
- The 14 tests above the 1434 baseline are mine (6) plus the rescue-beacon agent's.

### Simulation (lib/domain/mesh/mesh_sim.dart: the real MeshNodeEngine over a simulated radio)

Model:
- 10 riders spread over 1 km at about 60 km/h.
- Path loss calibrated to a ~390 m median Coded PHY range (~150 m on 1M), 4 dB shadowing, logistic reception around
  the sensitivity.
- Per-phone airtime: 6 KB/s Coded, 25 KB/s 1M. 10 % loss on overlapping receptions.
- Gap events: a rider stops 15-45 s, then catches up at +6 m/s.

Traffic:
- positions every 2 s;
- HELLO every 1 s;
- 4 SOS per 10 min from random riders;
- 4 walkie-talkie clips of 10 s (Opus 12 kbit/s);
- one 20 s live talk from the lead.

| Scenario (seeds × 10 min) | SOS delivered to every other rider | SOS origin acknowledged | Positions within 10 s | Clips complete | Live voice within 450 ms | Max hops | Busiest phone airtime |
|---|---|---|---|---|---|---|---|
| **Coded PHY**, 0.15 gaps/min/rider (5) | **100 %** (180/180), p50 60 ms, p95 110 ms | 100 %, p50 120 ms | 95.9 %, p50 70 ms, p95 180 ms | 99.4 %, p50 6.1 s, p95 15.2 s after the clip ends | 92.5 %, p50 120 ms, p95 250 ms | 4 | 19 % |
| Coded PHY, **harsh**: 0.6 gaps/min + 20 % collisions (3) | **100 %** (108/108), p50 60 ms, p95 20 s (store-and-forward across gaps) | 100 %, p50 150 ms | 76.2 % | 90.7 %, p50 16 s | 60.3 % | 4 | 23 % |
| **1M PHY only** (no Coded PHY phones) (3) | 97.2 %, p95 80 s | 100 % | 50.2 % | 74.1 % | 35.6 % | 4 | 7 % |

What it says:
- With Coded PHY phones a 1 km group is a working 4-hop chain: SOS always arrives, usually in about 0.1 s.
- Positions keep the map live. Clips arrive in seconds.
- Live voice is usable most of the time, which is exactly why clips exist.
- Across real gaps the SOS waits and arrives when the chain heals: store-and-forward is doing the work.
- Without Coded PHY the same group falls apart (1M range is ~150 m). Mixed groups sit in between. This is why the
  group panel shows the long-range count.

Honest limits of the model:
- broadcast-only (the phones use ≤ 4 links each: fewer collisions, but connection set-up costs seconds);
- a straight road with no terrain;
- no interference from other 2.4 GHz users;
- no phone-to-phone antenna differences.
The device checks below are the real test.

## 6. Device QA (needs real phones; M0 first)

- **M0. Build.** `flutter build apk` / appbundle. Fix any Kotlin compile issue in LongRangeBle.kt / MeshBleChannel.kt
  (written without an SDK). Install on all test phones.
- **M1. Flight-mode ride, 1 km.** 4-6 phones, flight mode on with Bluetooth on, on bikes over about 1 km of open
  road, 20 min. Expected:
  - the chip shows "Offline link: N riders, H hops" within about 15 s of losing the server;
  - every phone sees every other rider on the map (hop count shown);
  - log the per-hop distances where links held.
- **M2. Mixed phones.** At least one phone without Coded PHY (check `caps` in the diagnostics log, or the panel line
  "x of y phones support long range"). Expected:
  - the non-Coded phone links on 1M to its neighbours;
  - the Coded phones still find it (legacy set);
  - the panel count is right.
- **M3. Bridge rider.** One rider with signal, the others in flight mode. Expected:
  - that phone shows "Offline link: bridging N riders";
  - a rider at home (web / guardian / another online phone) sees the offline riders move with fresh positions;
  - the admin fleet shows them ONLINE (via bridge);
  - when the bridge rider turns flight mode on, they go NO_SIGNAL about 30 s later.
- **M4. Gaps and rejoin.** One rider stops for 2 min (out of range), then catches up. Expected:
  - the chain-keeper warns the rider in front ("ease off a little") and the lead ("stretched behind …") before the
    break, at most once per gap per 2 minutes;
  - after the rejoin the stopped rider gets the latest positions and any SOS / clip it missed.
- **M5. SOS across 3 hops.** The last rider raises an SOS (test contact), with the chain lead ↔ 2 ↔ 3 ↔ 4 spread so the
  ends cannot hear each other. Expected:
  - the SOS alarm on every phone within about 2 s;
  - the origin stops resending after the first acknowledgement (diagnostics);
  - with one bridge phone online, the server stores ONE alert (also when the origin regains signal and its own SOS
    arrives);
  - the rider's own SIM SMS goes out exactly as before (it must never wait for the mesh).
- **M6. Live voice over the mesh.** Push-to-talk between neighbours and over 2 hops. Expected:
  - clear speech (RNNoise still on);
  - at most one speaker;
  - the Lead cuts in;
  - latency under about 0.5 s on 2 hops.
- **M7. Walkie-talkie clips.**
  - Talk with nobody in range, then come into range: "Voice message from …" plays on the others.
  - A talk while someone else holds the floor becomes a clip and plays after.
  - A 15 s cap.
- **M8. Automatic switching.** Ride through a real dead zone with flight mode off. Expected:
  - the link turns offline within about 8 s of losing the socket and back to standby about 10 s after the socket
    returns;
  - no flapping at the coverage edge;
  - positions, SOS and voice carry on across the switch.
- **M9. Battery per hour.** Each mode (standby, bridge, offline moving, offline stopped), 1 h each, on 3 phone models.
  Compare with section 4 of the feature doc (paper: offline about 15-40 mA extra).
- **M10. Background / screen off.** Screen off and phone locked for the whole of M1 on Android 12, 14 and 15 devices.
  Expected:
  - scans keep reporting (filtered scans);
  - links survive;
  - no foreground-service type complaint on Android 14+.
- **M11. Rescue beacon together.** During an SOS the rescue beacon (other agent) also advertises. Check that the phone
  runs both sets: mesh coded + mesh legacy + rescue legacy + rescue extended is up to 4 advertising sets. On a chip
  with fewer slots, the mesh logs `adv_* error 2` (TOO_MANY_ADVERTISERS); the rescue beacon must keep running. If this
  happens on real phones, drop the mesh legacy set during a rescue.
- **M12. Permissions.** A fresh install on Android 12+: the Nearby devices dialog appears once at the first group-ride
  start. Denied: no crash, the link runs on Wi-Fi / hotspot only, and the SOS still works. Android 9 / 11: no dialog
  (location already granted).

## 7. Integration point for the rescue beacon (no dependency created)

The rescue beacon advertises its own 5-byte id under its own UUID (`6f1d0c2a-...`). The two are independent (separate
advertising sets, separate scans). Possible next steps, if wanted:
- the mesh scanner adds a second hardware filter for the rescue UUID and reports rescue sightings (id, RSSI, the
  sighting rider's GPS fix) as a mesh `alert` (a new code, `MeshAlertCode` 4), so a rescuer far away learns which
  rider is already near the victim, over several hops;
- the mesh SOS frame already carries the victim's SOS and position across the chain (that part is done).
Nothing in the rescue code calls the mesh, and nothing in the mesh calls the rescue code.

## 8. Website / handbook claim text (for the lead; I did not edit public pages)

Today the pages say: "Group phones on a shared hotspot pass the SOS along, phone to phone, until one gets through".
This stays true (the 3.55 hotspot mesh is unchanged). Suggested new text once M1, M3 and M5 pass on real phones:

- **Home / safety page, "No network at all":**
  "No network at all? Group phones pass the SOS along by Bluetooth, rider to rider, until one of them has signal, and
  that phone gets it to us. With long-range Bluetooth phones, a group spread over about a kilometre stays connected.
  It works over a shared hotspot too."
- **Features list item:** "Offline group link: positions, SOS and push-to-talk rider to rider over long-range
  Bluetooth when there is no signal. Any rider with signal connects the whole group. Free, no extra hardware."
- **Honesty footnote (keep it next to the claim):** "Range depends on the phones: long-range Bluetooth (Bluetooth 5
  Coded PHY) typically reaches 200-600 m between bikes, more on open roads, and needs a phone that supports it. The
  app shows how many phones in your group do. Your phone's own SMS to your emergency contacts stays the first SOS
  path."
- **Investor one-pager / memo, "SOS that works without signal":** replace "(3) a phone-to-phone mesh relays SOS
  between riders on a shared hotspot" with "(3) a phone-to-phone mesh relays SOS, positions and voice between riders
  over long-range Bluetooth or a shared hotspot, and any rider with signal bridges it to the server". Keep "device
  check pending" until M1-M5 pass.

Do **not** claim "1 km" per phone, "works with every phone", or a guaranteed delivery time.
