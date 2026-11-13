# Rescue beacon (round 10, app build 3.55.0+10028, not released)

The owner asked for a stronger SOS siren when a rider really crashed and does not answer, plus a
high-frequency sound that other riders' phones can detect, so they can find the rider, for example
in a forest.

Short version: after an **unanswered** crash countdown (or an unanswered "Still able to respond?"
during an open SOS), the down rider's phone sounds a loud, escalating siren. It also sends a quiet
near-ultrasonic locator code, a Bluetooth locator signal and, in the dark, an SOS light. Group
riders and accepted nearby helpers get a **"Find Ravi"** screen. It combines GPS, Bluetooth and the
locator sound into one plain guide, and has a **"Ping the phone"** button.

It **only adds** behaviour. Crash detection, the 30 s countdown, "I'm OK", SOS, the emergency texts
and the Medical ID are unchanged. The beacon never starts without an open SOS and never starts
before the countdown ends.

## 1. When it runs (victim phone)

| Start | How |
|---|---|
| Crash countdown ran out with no answer | SafetyService sends the SOS as `CRASH_AUTO` (`alarm.sent && alarm.isUnresponsive`). The beacon starts at once. |
| SOS raised by the rider (hold SOS, "Need Help", notification) and the rider goes quiet | 3 min after the SOS: **"Still able to respond?"** (screen over the lock screen, heads-up notification). With no tap on "I can respond" within 60 s, the beacon starts. One check per SOS. |
| By hand | "Lost or trapped? Start the rescue siren" on the rider's own open SOS. |

The pure start rules are in `RescueStartGate` and `SosResponseCheck`
(`lib/domain/rescue/rescue_beacon_plan.dart`, tests in `test/rescue_beacon_plan_test.dart`). The service
(`lib/data/services/rescue_beacon_service.dart`) runs a 500 ms timer only while this rider has an open
SOS. A normal ride costs nothing.

### Schedule

| Time since start | Siren | Locator sound | BLE |
|---|---|---|---|
| 0 to 2 min, **escalating** | continuous in 10 s chunks; level 0.40 → 0.52 → 0.65 → 0.78 of full scale, sweep 1.2 s → 0.3 s | mixed in, every 2 s | balanced (250 ms) |
| 2 to 15 min | 10 s every **30 s** | every 2 s, also in the gaps | balanced |
| after 15 min | 10 s every **60 s** | every 2 s | low power (1 s) after 30 min |
| battery reserve (SOS battery reserve on, or < 10 % and not charging) | **off**; a responder ping plays a 5 s burst, at most 1 a minute | off | low power |
| ≤ 4 % | off; pings at most 1 every 3 min | off | low power |

The alarm stream is set to max while the beacon plays and restored afterwards. The phone vibrates
(SOS pattern, alarm attributes) at the start of each siren window. The screen wakes over the lock
screen during siren windows in the first 15 minutes, never when the phone is face-down or in a pocket.
A partial wake lock with a 2 min timeout is renewed every minute while the beacon runs.

### Stops

| Who | How | Effect |
|---|---|---|
| Rider | "I'm the rider and I'm OK: stop the siren", or the existing "I'M CONSCIOUS · SILENCE SIREN" button on the crash screen (existing rule) | everything stops; the SOS stays as it is (the rider resolves it as usual) |
| Resolver | the SOS is resolved anywhere (rider's "I am safe", group, admin) | everything stops |
| Bystander | **3 s hold** on "Stop siren: help is here" | siren, light and vibration stop; the SOS **stays open**; the inaudible locator and BLE keep running so the group can still find the spot; logged (diagnostics log `rescue_stop {by: bystander}` and the beacon screen's log) |
| Anyone touching the screen | a touch | all sound pauses for 15 s (ear safety when someone reads the Medical ID or calls 112 next to the phone) |

## 2. The sound

Generator: `RescueSynth` (`lib/domain/rescue/rescue_acoustics.dart`). The same code feeds the phone and
the lab.

- **Siren:** a triangle sweep 2 to 4 kHz, sine plus 25 % third harmonic (6 to 12 kHz). Small speakers
  are loudest and the ear most sensitive in this range. Level differences between the ears make it
  easy to locate. There is no clipping, so nothing lands above 12 kHz.
- **Locator packet:** 4-FSK, 16 symbols of 40 ms tone plus 10 ms gap (800 ms), with 4 ms raised-cosine
  edges (no audible clicks). Sync `[3,0,2,1]` uses all four tones, so a steady insect or whistle can
  never match. Then 24 bits: the rescue id (16 bits) and a CRC-8.
  - high band: 17.8 / 18.2 / 18.6 / 19.0 kHz
  - low band: 14.4 / 14.8 / 15.2 / 15.6 kHz
  - One packet every 2 s per band. With both bands: high at 0 s, low at 1 s.
- **Band choice:** a speaker self-test 20 s into a ride, at most once every 30 days, and only when the
  ride mic is already open for siren alerts. The phone plays 250 ms of each band at locator level on
  the media stream and listens at 48 kHz (`SpeakerSelfTest`, `RescueSpeakerCheck`).
  - both heard: **both** (the lab shows the low band carries farther)
  - only one heard: that band
  - nothing measurable: both
  - The result is logged as `rescue_speaker_test`.

### Rescue id

16 bits from the SOS clientId (else alertId): FNV-1a 32 over the UTF-8 bytes, folded, 0 → 1. The
phone (`RescueId`, also offline) and the gateway (`rescueIdFromKey`) compute the same value. Shared
test vectors: `client-123` → `c78e`. The gateway stores it as `rescueId` on the alert. Group riders
also derive it from the clientId they already receive. Nearby helpers get it in `ASSIST_UPDATE` only
after they accept.

## 3. The detector (responder phones)

`RescueBeaconDetector` (`lib/domain/rescue/rescue_beacon_detector.dart`):

- Every 5 ms it runs Goertzel filters at the 4 tones and 5 reference frequencies per band
  (about 0.5 % of one core).
- After each step it tests whether a whole packet just ended. The sync symbols must each have the
  expected tone strongest by 3 dB and above the local noise floor. Then it reads the data and checks
  the CRC.
- With a known target id it also tests the whole 16-symbol pattern ("matched" mode, a little more
  sensitive).
- `RescueBeaconTracker` needs **2 packets with the same id within 12 s** before it says "heard".
- Other ids are listed as "another rescue beacon nearby" unless the rider turns on **Help anyone**.

**Microphone:** the ride mic hub records at 16 kHz, which cannot hold 17 to 20 kHz. While a rescue
listener is attached, the same single capture opens at **48 kHz** (raw built-in mic). The siren
detector and the intercom keep getting their usual 16 kHz frames through a 63-tap low-pass decimator
(`lib/domain/rescue/decimator.dart`, > 50 dB alias rejection; `ride_mic_hub.dart`, marked block).
Push-to-talk on a headset pauses the rescue listener while the button is held.

**When it listens:** (`RescueListenGate`)

- only while another rider's SOS is open in my group, or I accepted to help a nearby rider;
- **and** either the finder screen is open, or I am within 1 km of the victim's last position
  (2 km when offline).

Never otherwise. With the finder closed and a beacon heard, the phone shows one heads-up:
"Ravi is close: open CoRoute and tap Find Ravi".

## 4. BLE locator

`RescueBeaconChannel.kt`:

- Service data under CoRoute's rescue UUID `6f1d0c2a-5b8e-4c37-9a41-2e7c5d0b9f13`, 5 bytes: magic, version,
  id, flags (siren / reserve / bystander-stopped). No name, no position. This is independent of any
  other CoRoute BLE use (the offline mesh).
- **Legacy** advertising (every phone can scan it), balanced or low power, TX high, non-connectable.
- **Extended** advertising on Android 8+ when the chip supports it, on **LE Coded PHY** when supported
  (`isLeExtendedAdvertisingSupported`, `isLeCodedPhySupported`, `isMultipleAdvertisementSupported`).
- Rescuers scan for that UUID only (`setLegacy(false)` and `PHY_LE_ALL_SUPPORTED` on Android 8+, so
  they also hear the Coded set). RSSI is smoothed: median of 5, then an exponential average.

## 5. Light

- Camera torch via `CameraManager.setTorchMode` (API 23+). It needs **no CAMERA permission**, and
  CAMERA stays removed. With no torch, or the camera busy, the whole app shows a white **screen
  flash** (`RescueStrobeOverlay`, on top of every screen).
- Pattern: SOS Morse, unit 250 ms (dots at 2 flashes/s). **Never more than 3 flashes in any second.**
  The Dart side checks this (`RescueStrobe.validate`, tested) and the Kotlin side checks it again
  (any on+off cycle < 334 ms is refused).
- It flashes only during siren windows, only when it is dark (light sensor < 40 lux, or after sunset
  when there is no light sensor), and only when the phone is not covered or face-down (proximity,
  accelerometer).

## 6. Finder screen ("Find Ravi")

Opened from the "Find Ravi" button on another rider's open SOS (incident sheet) or on an accepted
nearby-rider request (assist sheet). The route name `safety/rescue_finder` is allowed over the
locked cockpit.

- One big status line. Examples:
  - "Very close: within about 20 m. Look and listen. Call out to Ravi."
  - "Close: within about 50 m. Walk slowly and watch the meter rise."
  - "In Bluetooth range (roughly 30 to 100 m)."
  - "About 120 m by GPS. Listen for the siren."
  - "1.8 km away. Follow the arrow or the route."
- A hotter / colder line, plus a compass arrow and distance to the last GPS fix (with its age and
  accuracy).
- A mini map from the offline tile cache.
- **Ride there** (in-app emergency navigation) and **Walk there** (map app, walking).
- A Bluetooth meter and a locator-sound meter, each with a trend chip.
- **"Listen: Ravi's siren should be audible now"** when close.
- **Ping Ravi's phone**: at most one press every 20 s.
- The honest note: *"Sound and Bluetooth tell you how close you are, not which way. Walk 10 to 20
  steps in one direction and watch the meter..."*
- Keeps the screen on (wakelock_plus) and has glove-sized controls (64 to 72 dp).

## 7. Server

- `gateway/src/rescue_beacon.js`:
  - `rescueIdFor` is used by `_raiseSos` (stored as `alert.rescueId`).
  - `publicAlert` adds `rescueId`, derived for older stored alerts.
  - `ASSIST_UPDATE.rescueId` goes to accepted responders.
- `RESCUE_PING {alertId}` (group member, not the victim) or `{incidentId}` (active nearby responder):
  - relayed only to the victim's sockets as `RESCUE_PING {alertId, fromName, at}`;
  - the sender gets `RESCUE_PING_RESULT {sent | throttled, retryInS}`;
  - limits: 1 per sender per alert per 20 s; per alert ≥ 5 s apart and ≤ 6 a minute;
  - errors: `OWN_ALERT`, `ALERT_CLOSED`, `INCIDENT_CLOSED`, `NOT_RESPONDER`, `BAD_PING`.
  - A signed-out ("safety-only") victim socket still receives pings for its own alert.
- No database change: `rescueId` is one more field on the alert document.
- **Offline victim:** a ping cannot reach the phone through the server. Integration point for the
  offline mesh: `RescueFinderService.meshPing` (sender) and
  `RescueBeaconService.instance?.onPingForRescueId(id)` (receiver).

## 8. Honest range (to be verified on devices, see ROUND10 notes R1 to R4)

| Signal | Expected | Lab model (open phone, quiet forest → noisy) |
|---|---|---|
| Audible siren | tens of m to ~100 m+ in a quiet forest | ~33 dB SPL at 100 m in forest vs ~28 dB ambient: just audible at 100 m, clear at 50 m; pocket −8 dB |
| Near-ultrasonic locator | ~10 to 40 m | high band 15 to 30 m, low band 20 to 50 m; pocket 5 to 25 m |
| BLE | ~30 to 100 m | not modelled (RF); body and foliage take 10 to 20 dB |

GPS and the route cover the long range. Siren, sound and BLE are for the **last metres**.

## 9. Battery

Estimates, to be measured (R9):

- **Siren:** the speaker at full power is about 0.5 to 1.5 W while sounding. 10 s per 30 s ≈ 0.3 W;
  10 s per 60 s ≈ 0.15 W.
- **Locator packets:** about 0.1 W while the amplifier runs.
- **BLE advertising:** 1 to 10 mW.
- **Torch** (dark only, in siren windows): about 0.3 W average.
- **Screen wake:** first 15 min only.
- **Rough total:** 3 to 8 % of a 4,500 mAh battery per hour in the duty phase. The first 2 minutes
  cost more.
- At the SOS battery reserve (10 %) everything audible stops, so the SMS / SOS keep the battery.

## 10. Safety

- **Volume.** A phone siren at max is about 80 to 90 dB SPL at 1 m, and much more at ear distance. So
  any touch on the screen pauses the sound for 15 s, the siren starts at 0.40 of full scale and
  escalates over 2 minutes, and it runs on a duty cycle after that.
- **Near-ultrasonic.** The locator peak is −13 dBFS, always ≤ 0.28 of the siren peak.
  - In the lab model that is about 61 dB SPL at 1 m in the high band and ~66 dB in the low band. That
    is under the ~75 dB per 1/3-octave guidance often cited for 16 to 20 kHz airborne sound for the
    public (e.g. the IRPA/INIRC interim guideline) at normal distances. It is never continuous:
    0.8 s every 2 s per band, 40 ms tones, no clicks.
  - It stops in the battery reserve and pauses when someone touches the phone.
  - **Pets** (dogs, cats hear it): the level is like a quiet conversation at 1 m and is only played
    during an emergency.
  - The low band (14 to 16 kHz) is audible to many people as a faint chirp. That is acceptable next
    to a loud siren, and even helps.
- **Flashing:** ≤ 3 flashes/s, checked in Dart and in Kotlin; never when covered.

## 11. Privacy

- The microphone runs at 48 kHz **only on responders' phones, only during an open SOS** (finder
  open, or within 1 km of the victim).
- Audio is processed in memory on the phone by a few narrow filters around 14 to 20 kHz.
  **Nothing is recorded, stored or sent.**
- BLE: only CoRoute rescue advertisements are kept, as an id and a signal strength.
- The rescue id is a 16-bit number. It is not personal and not a secret, and is sent to nearby
  helpers only after they accept.
- The victim's phone advertises no name or position.
