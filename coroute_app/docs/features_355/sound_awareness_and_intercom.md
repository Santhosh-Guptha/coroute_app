# 3.55 Sound awareness and clean intercom voice

During a ride, the phone's own microphone listens for emergency-vehicle sirens and for horns close by. The same microphone gives the intercom a cleaned-up voice: breath, wind and engine noise are taken out before anything goes to the group.

**Purpose (owner's decision).** The real scenario is a rider who cannot hear outside sound: noise-cancelling earbuds, a helmet Bluetooth set, or music. The phone on the mount, in the tank bag or in a pocket still hears the road, even when the earbuds cancel it. CoRoute warns **that rider**; it does not tell the group (the old "Tell my group" card was removed). A siren reaches the rider through the headset even with noise cancellation on: ANC blocks outside sound, not playback.

All audio is processed on the phone. Detection audio is never recorded, stored or sent. The intercom sends voice only while the rider talks.

## Files

| Part | File |
|---|---|
| One shared ride microphone | `lib/data/services/ride_mic_hub.dart` (`RideMicHub`) |
| Siren and horn detector (pure Dart DSP) | `lib/domain/audio/sound_awareness_engine.dart` (`SoundAwarenessEngine`) |
| Voice cleanup (pure Dart DSP) | `lib/domain/audio/voice_cleanup.dart` (`VoiceCleanup`) |
| DSP building blocks | `lib/domain/audio/dsp_core.dart` (biquad, FFT, peak limiter, 2:1 decimator) |
| Alert level (isolated or not), horn mode, mic need (pure Dart) | `lib/domain/audio/sound_alert_policy.dart` (`SoundAlertPolicy`, `ListeningState`) |
| Alerts, cockpit card, ducking, audio-state polling | `lib/data/services/siren_acoustic_detector.dart` (3.55 "ride mic hub path" section) |
| "Can the rider hear outside?" (native, no mic), critical-line routing, alert tone | `android/.../TtsChannel.kt` (`listeningState`, `alertTone`, `headsetOutput`); Dart: `NativeVoiceEngine.readListeningState` / `alertTone` in `voice_service.dart` |
| Intercom on the shared mic, cleanup, playback limiter, toggles | `lib/data/services/intercom_service.dart` |
| Settings (added at the end of the class) | `lib/data/services/settings_service.dart` |
| Wiring | `lib/main.dart`, between the "3.55 sound awareness (mic agent) BEGIN" and "END" markers |
| Cockpit card detail line | `lib/presentation/rider/widgets/siren_hud_pill.dart` (one text) |
| Tests | `test/sound_alert_policy_test.dart`, `test/siren_horn_detector_355_test.dart`, `test/voice_cleanup_355_test.dart`, `test/support/audio_synth_355.dart` |

## 1. One microphone for the whole ride (RideMicHub)

Android reliably allows only one capture per app. The detector and the intercom therefore share one `record` stream: 16 kHz mono PCM16, cut into 20 ms frames (320 samples).

- **When it opens.** The mic opens only while a consumer needs it:
  - **Detection** needs it while all of these hold: a ride is active (group trip `STARTED` or an offline solo ride), siren alerts are on or horn alerts are effectively active (On, or Automatic while the rider is isolated; rider setting and admin switch), the battery is OK, there is no phone call, the permission is granted, and the app is in front or the ride foreground service is running.
  - **The intercom** needs it while push-to-talk is held or hands-free (VOX) is armed.
- **Which mic: always the phone's own for detection.** A headset mic sits inside the helmet or the ear, and Bluetooth (SCO) headset mics are noise-suppressed: they would miss sirens. Detection therefore captures explicitly from the built-in mic: `RecordConfig(device: …)` with the `InputDeviceType.builtIn` device from `listInputDevices()` (record 7; label fallback "built-in"; unknown = default device, which without SCO is the built-in mic). This also keeps a wired headset's in-line mic out of detection. Bluetooth SCO stays off while detecting, so music keeps A2DP quality. The decision is `MicPlan.forNeeds` in `ride_mic_hub.dart`:

  | Need | Mic | Android source | OS effects | Bluetooth SCO |
  |---|---|---|---|---|
  | Detection only (headset or not) | built-in | `mic` (raw) | off | off |
  | Detection + hands-free talk (VOX), headset or not | built-in | `mic` (raw) | off (software cleanup) | off |
  | Detection + push-to-talk, no headset | built-in | `mic` (raw) | off (software cleanup) | off |
  | Detection + push-to-talk **held**, with a headset | headset | `voiceCommunication` | on | on |
  | Intercom only (detection not wanted) | default / headset | `voiceCommunication` | on | on |

  OS noise suppression would erase a siren as stationary noise, so detection uses the raw source.
- **Push-to-talk with a headset.** The headset mic is used only while the button is held (the rider's voice is clearer from the helmet mic). Those frames are flagged headset + processed and the detector **skips** them, so the road noise floor is not disturbed. On release the hub re-opens on the built-in mic and detection carries on. Opening SCO takes up to about a second on some headsets, as before.
- **Hands-free (VOX) with a headset: trade-off.** Android gives one capture, and detection must hear the road, so hands-free talk uses the phone's mic too, cleaned in software (high-pass, noise suppression, breath and wind cut, voice gate). The voice is weaker than from the helmet mic when the phone is far from the rider's mouth (mount, tank bag). Riders who want the clearest voice with a helmet set use push-to-talk. With detection off (sirens off and horns not active), hands-free uses the headset mic as before.
- **Headset changes.** The input device list is re-read every 15 s (device type, label fallback). When the headset state changes, the mic re-opens with the right plan.
- **"Can the rider hear outside?" needs no mic.** It comes from the phone's audio state, read every 3 s during a ride (`TtsChannel.listeningState`: `AudioManager.getDevices(GET_DEVICES_OUTPUTS)` types + `isMusicActive` + call mode) plus the intercom playing. See section 3.
- **Phone calls.** `PhoneCallService` tells the hub (`setPhoneCallActive`). The mic is released during the call and re-opened after it. `audioInterruption: pauseResume` covers other interruptions.
- **Permission missing.** Detection never shows the system dialog in the middle of a ride. It checks only, and says once: "Siren and horn alerts need the microphone. Allow it for CoRoute in phone settings to use them." The intercom asks on the rider's tap, as before.
- **Battery.** Detection pauses at < 15 % (when not charging), with Battery saver on, or with the SOS battery reserve. The intercom keeps the mic when it needs it.
- **Data saver.** Capture stays at 16 kHz, because detection needs it. The intercom sends 8 kHz: the cleaned 16 kHz signal goes through a 31-tap low-pass and a 2:1 decimator.
- **Switch off = mic off.** The setting, the admin switch or the end of the ride releases the mic at once (`settingsChanged` → `reevaluate`).
- **Background and lock screen.**
  - The hub keeps running in the background only while the ride foreground service runs.
  - When the mic opens with the app in front, and again on every resume while it is open, the hub calls `BackgroundService.ensureMicrophoneType()`. That restarts the ride service once with the `microphone` type, so capture continues with the screen off.
  - The intercom now calls `ensureMicrophoneType()` only while the app is in front. The call stops and restarts the service, and Android 14 refuses to start a microphone service from the background, which would have killed the ride service.
- **Errors.** If the mic is taken by another app or an assistant, the hub retries after 3, 6, ... 18 s, then waits for the next resume or setting change.

## 2. Sirens and horns (SoundAwarenessEngine)

Every 20 ms, the last 512 samples (32 ms, Hann window) go through one 512-point FFT (31.25 Hz bins).

Each bin has an adaptive noise floor. It drops fast and rises about 2 dB/s, so a steady engine drone, wind roar or tyre noise becomes "floor". Only sounds that stand out of the floor are looked at.

### Sirens

**Tonal frame.** A frame is tonal when all of these hold:

- the strongest peak in 400-2000 Hz, picked by its height above the floor (not by raw power), is at least 8 dB above the floor;
- that peak (plus its 2nd and 3rd harmonics) holds at least 45 % of the floor-normalised excess energy within ±780 Hz. A gust spreads its excess over all bins and fails this;
- there is no harmonic comb around the peak, that is, no narrow partial 80-400 Hz below it that repeats at the same spacing. Speech and engines are combs over a low fundamental; a siren tone is its own lowest partial;
- the mic is not clipping.

**Classification.** Every 100 ms, the last 4 s are classified:

1. At least 1.5 s of tonal frames, at least 45 % tonal coverage (55 % for sweeps), still sounding in the last 0.5 s, and a frequency span of at least 120 Hz. A constant tone (horn, alarm, whistle) is not a siren.
2. Then the pattern:
   - **Hi-lo / two-tone:** two tight frequency clusters (frequency ratio 1.12-1.7, each ≥ 20 % of the frames, ≤ 15 % between them) with at least 2 switches. This covers EU and Indian ambulances (e.g. 960/770 Hz, 1050/700 Hz) and police hi-lo.
   - **Yelp:** a smooth sweep (≥ 85 % of the frame-to-frame steps small), span ≥ 300 Hz, reversing 2.5-11 cycles a second (yelps run at about 3.5-8 Hz).
   - **Wail:** a smooth sweep, span ≥ 350 Hz within 380-2100 Hz, at most 1.2 cycles a second (a 2-6 s wail), with a mean sweep speed of 80-3000 Hz/s.
   - **Not reported:** a steady tone with stray peaks (more than 35 % of the frames within 3 % of the median), and smooth sweeps at 1.2-2.5 cycles a second. Speech intonation looks like that; it was the only false alarm found in tuning, so it was removed.
3. Three positive evaluations in a row (300 ms) confirm a siren.

**Episodes and cool-down.**

- One alert per episode. An episode ends 8 s after the last positive evaluation.
- A new episode alerts only if 30 s have passed since the last alert.
- Within that time, a new alert comes only when the siren is clearly closer: a nearness step up and at least 6 dB louder.
- Within an episode, an "approaching" alert comes once, when the trend becomes approaching while near.

**Trend and nearness.**

- **Approaching / moving away:** the least-squares loudness slope of the tone (its excess power above the floor) over the current run, at most the last 5 s. ≥ +1 dB/s means approaching; ≤ −1 dB/s, or a ≥ 3 % Doppler drop of the hi-lo centre with a flat or falling level, means moving away.
- The trend is reported only once at least 2 s of tone spread over at least 4 s have been heard (about a whole wail cycle). Before that, it is "unknown" and is not spoken.
- **Nearness:** the median tone SNR over the last second. ≥ 24 dB is very near, ≥ 14 dB is near, anything less is far.

**Kind (a best guess).** Hi-lo is reported as ambulance-like, yelp as police-like, and a low, slow wail (centre < 850 Hz) as fire-engine-like. The kind is named only when the confidence is at least 0.85, and always as a likeness ("sounds like an ambulance"): the same patterns are used by different services in different countries.

**Direction.** One phone microphone cannot tell behind from ahead. The alerts say "close by" or "approaching", never "behind". `directionKnown` stays false, so the cockpit card never claims "BEHIND".

### Horns

**Horn frame.** Partials are narrow spectral lines at least 10 dB above the floor and within 20 dB of the strongest. Each line is credited to the fundamental that explains it as an overtone (±4 %). A frame is a horn frame when all of these hold:

- 1 or 2 significant fundamentals (each ≥ 20 % of the line energy): a car horn is a dual tone, a chord has 3 or more;
- the lowest fundamental is in 140-900 Hz (truck air horns are lower, about 180-225 Hz);
- those fundamentals hold at least 55 % of the excess energy;
- the line SNR is at least 12 dB.

**Horn event.** A run of horn frames becomes a horn event when:

- it has a sudden onset: the same lines were at least 10 dB weaker 100 ms before (the best of the last 200 ms counts);
- the pitch is steady: at least 2 lines within 3 % of the previous frame's lines;
- it lasts between 250 ms and 4 s.

**Own horn.** Clipping (3 or more samples ≥ 0.97 FS in a frame), a peak ≥ 0.97 FS or a frame RMS ≥ −6 dBFS means the bike's own horn, and the event is ignored.

**Alert.**

- **Fires on:** two close horns (≥ 16 dB line SNR) within 8 s, or one very close long horn (≥ 22 dB, ≥ 1 s).
- **Limits:** at most one horn alert per 20 s.
- **Suppressed:** never during a siren episode, never while a third or more of the last 2 s was siren-like tone (a hi-lo tone switch looks like a horn blast), and never while the rider is talking on the intercom.

## 3. What the rider hears and sees

**Listening isolated** (the rider likely cannot hear outside) = ANY of: a Bluetooth audio headset (A2DP, SCO, LE audio headset), a hearing aid, a wired / USB headset or headphones, another app's music playing (`isMusicActive`), the intercom playing a rider's voice, or a phone call. Pure rule: `SoundAlertPolicy` / `ListeningState.isolated`.

| Alert | Rider isolated | Rider not isolated (phone speaker, no music) |
|---|---|---|
| Siren close / approaching / clearly closer | **Full:** P1, music paused, the line through the headset at alert volume, strong vibration, cockpit card, heads-up when the app is not in front | **Softer:** cockpit card, strong vibration, one short tone (no speech: the rider hears the siren) |
| Siren far away | P2 "Emergency vehicle siren in the distance." (music ducked), medium vibration, card | card, medium vibration |
| Horn (Automatic / On) | "Horn close by. Check your mirrors." (P2), vibration, horn card | only with Horn alerts On: vibration, horn card |

How the spoken line reaches the rider (the rule for **all** critical lines, `TtsChannel.kt`): with a headset connected, the line uses the media "navigation guidance" usage, so it plays in the helmet / earbuds over A2DP, with the media volume raised to at least 60 % of max for the line and put back after. It does **not** use the alarm usage then, because Android may force alarm sound to the phone speaker (the rider would miss it in the helmet). With no headset, critical lines use the alarm usage (heard with media volume 0 and through Do Not Disturb).

**Real scenarios**

| Scenario | Isolated? | Rider hears | Rider sees / feels |
|---|---|---|---|
| ANC earbuds + music, ambulance close behind or ahead | yes (Bluetooth + music) | Music pauses; in the earbuds: "Emergency vehicle siren close by. Keep left and give way." | Strong triple vibration, siren card, heads-up on the lock screen |
| Helmet Bluetooth set, no music, siren approaching | yes (Bluetooth) | In the helmet: "Emergency vehicle approaching, sounds like an ambulance. Keep left and give way." (kind only when confident) | Card "… · Approaching · Close", strong vibration |
| Wired earphones, siren far away | yes (wired) | "Emergency vehicle siren in the distance." | Card "… · Far", medium vibration |
| Phone speaker, no music, siren close | no | One short tone (alarm stream) | Card, strong vibration |
| Phone speaker, music playing on the phone | yes (music) | Music pauses; the line on the speaker (alarm stream) | Card, strong vibration |
| Phone in a jacket pocket at speed, earbuds in | yes | Alert only if the phone hears the siren (see Limits: pocket at speed may miss it) | — |
| Helmet set, push-to-talk held while a siren starts | yes | Detection pauses during the press (headset mic); alert follows on release if the siren is still there | — |
| Far siren later 20 dB louder | as above | P1 (isolated): "Emergency vehicle getting closer. Keep left and give way." | Card updates to "Very close" |
| Siren passes and fades | — | nothing new | Card "Moving away", cleared 8 s after the siren stops; intercom ducking lifted |
| Same siren again within 30 s | — | nothing (cool-down) | Card shows again |
| Two horns close by, earbuds in (Automatic) | yes | "Horn close by. Check your mirrors." | Vibration, horn card (4 s) |
| Two horns close by, phone speaker, Horn alerts Automatic | no | nothing (horns off: the rider hears traffic; mic not opened for horns) | nothing |
| Two horns close by, phone speaker, Horn alerts On | no | nothing spoken | Vibration, horn card |
| Single far horn / own horn / horn while talking | — | nothing | nothing |
| Wind, engine, speech, music | — | nothing | nothing |
| Phone call | yes | detection paused, mic released | resumes after the call |
| Screen locked, ride running | — | voice alerts and vibration work (foreground service with microphone type) | heads-up; cockpit card when the screen is on again |

Every siren episode also lowers intercom playback by 20 dB while it lasts. Wording always says "close by" or "approaching", never "behind".

The give-way side comes from the setting "Give way to the" (`auto` / `left` / `right`). `auto` uses the phone's country: India, the UK and other left-hand-traffic countries mean left, other countries mean right. An unknown country means left.

## 4. Clean intercom voice (VoiceCleanup)

At 16 kHz, per frame, before encoding and sending:

1. **High-pass at 140 Hz** (2nd-order biquad) removes wind rumble and engine drone.
2. **Noise suppression.**
   - STFT of 256 points with a hop of 128, sqrt-Hann analysis and synthesis (perfect reconstruction).
   - The per-bin noise floor falls fast and rises about 2.5 dB/s. It is frozen while the rider speaks, and it starts low, so a word said the instant the mic opens is not taken for noise.
   - The gain is a Wiener gain with the decision-directed a-priori SNR, with a −15 dB floor and 3-tap smoothing across bins against musical noise.
3. **Per 20 ms block, the features are:**
   - voicing: the normalised autocorrelation of the 250-4000 Hz band, from a magnitude-compressed 1024-point spectrum, for pitch 80-300 Hz;
   - spectral flatness;
   - the share of energy in the 1-6 kHz band;
   - the share of energy below 300 Hz in the raw input;
   - clipping.
4. **Breath and wind.**
   - **Breath** is unvoiced, noise-like (flatness ≥ 0.25) and mostly 1-6 kHz, lasting at least 60 ms and starting at least 100 ms after the last voiced block. It is cut by **−20 dB**. The "s" and "t" sounds around words stay.
   - **A wind gust** is unvoiced with ≥ 60 % of its energy below 300 Hz, or clipping. It is cut by **−18 dB**.
5. **Voice gate.**
   - **Hands-free (VOX)** opens after 2 voiced blocks (40 ms) and holds 500 ms after the last one. Breath and wind alone never open it.
   - While the gate is shut, nothing is sent: the stream ends, as in the old VOX.
   - The 40 ms before the gate opened are sent first (pre-roll), so the first syllable is not cut.
   - **Push-to-talk** uses a soft gate (−12 dB when there is no voice).
6. **Level.** The AGC targets −20 dBFS speech (range −6 to +18 dB, at most 25 dB/s, following voiced blocks only). A peak limiter at −1 dBFS follows, so the output never clips.
7. **Receive side.** The existing mixing is unchanged. A light peak limiter (ceiling 0.8 FS, 6 dB/s release, no added latency) runs before playback, so one loud rider does not blast.

Added latency is **12 ms** (8 ms STFT + 4 ms block alignment).

Setting "Clean up my voice" (on by default) and admin switch `voiceCleanup`: when off, raw frames and the old loudness VOX are used.

When only the intercom uses the mic (no detection), the OS effects stay on as well (voiceCommunication source).

## 5. Measured results

All results come from synthesised signals, run with plain `dart` on the scratch copies and the same code as the tests.

The riding background is an engine drone (45 Hz harmonic series, wandering ±15 %) + low-pass wind with gusts + mic hiss, about **−26 dBFS**. Sirens are tones with odd harmonics.

### Sirens (first alert time after the siren starts; SNR is the tone over the ambient floor)

| Signal (siren level over 12 s) | Result |
|---|---|
| Wail 500-1800 Hz, 4.5 s (−39 dBFS) | detected after 2.3 s, wail, near, 17.9 dB |
| Yelp 3.5 / 5 / 8 Hz (−39 dBFS) | detected after 2.3 / 2.4 / 2.9 s, yelp (police-like) |
| Hi-lo 960/770 Hz, 0.5 s (−39 dBFS) | detected after 2.5 s, hi-lo |
| Hi-lo 1050/700 Hz, 0.7 s, India (−39 dBFS) | detected after 1.9 s, hi-lo |
| Same sirens at −45 dBFS (19 dB under the ride noise) | wail, yelp 3.5/5 and hi-lo detected after 2.4-3.7 s; yelp 8 Hz not detected |
| Same sirens at −51 dBFS (25 dB under) | not detected (limit) |
| Loud hi-lo / wail (very near, ~33 dB) | detected after 1.6-1.7 s, no horn alert |
| Approaching wail (+2.5 dB/s) | alert "approaching" (measured slope +1.8 dB/s) |
| Hi-lo moving away (−1.5 dB/s, 6 % Doppler drop) | trend "moving away" |
| Same siren again 13 s after the first ended | no second alert (cool-down) |
| Far hi-lo that becomes 20 dB louder | second alert, reason "closer" |

### Horns

| Signal | Result |
|---|---|
| Two close car horn blasts (420 + 500 Hz) | 1 alert |
| One very close horn of 1.3 s | 1 alert |
| Truck air horn 180 + 225 Hz, twice | 1 alert |
| Three double horns within 10 s | 1 alert (20 s limit) |
| Single or double far horn | no alert |
| Own horn (clipping) | 2 events flagged own, no alert |
| Horn while the rider talks / horns off | no alert |

### False alarms

There were 0 siren alerts and 0 horn alerts on:

- wind gusts with clipping;
- wind only;
- engine drone and high-rpm engine;
- male, female and child-like speech;
- music-like chords;
- a constant 1 kHz tone;
- near silence;
- six "everything at once" mixes;
- **20 minutes** of mixed negative audio (40 × 30 s: engines at 30-150 Hz, clipping wind, speech with f0 90-290 Hz, chords).

### Cost

The detector takes about 0.6-1.5 ms per second of audio on a desktop JIT for a single scenario, and about 16 ms per second over the 20-minute mix. Expect a few % of one core on a mid-range phone.

### Voice cleanup (AGC off, so each stage is measured alone)

| Segment | Hands-free | Push-to-talk |
|---|---|---|
| Voiced vowel 140 Hz / 210 Hz / running speech | −0.0 / −0.1 / −0.9 dB | same |
| Breath (−25 dBFS) / loud breath (−18 dBFS) | **−30 dB** / **−30 dB** | −20 / −20 dB |
| Wind gusts (−15 dBFS) | **−34.5 dB** | −22.5 dB |
| Gate open during voice | 98/100, 49/50, 48/50 frames | — |
| Gate open during breath / wind / hiss | **0** frames | — |
| Steady riding noise, gate off (high-pass + noise suppression only) | −24 to −25 dB, with clean speech −0.7 dB | |
| Speech in wind at about 1 dB SNR | gate open 189/200 frames, wind-only run 0/400 | |
| Speech in wind at −5.5 dB SNR | gate open 138/200 frames (heavy wind cuts some syllables) | |
| Quiet speaker (−40 dBFS) with AGC | raised by more than 10 dB | |
| Shout (−3 dBFS) | output peak ≤ 0.9 (no clipping) | |
| Added latency | 192 samples = 12 ms | |
| CPU | about 3-6 ms per second of audio (desktop JIT) | |

### Tests

| File | Covers |
|---|---|
| `test/sound_alert_policy_test.dart` | isolated / not isolated alert level, horn modes, mic need, native map parsing (pure Dart; all pass under a plain-`dart` harness) |
| `test/siren_horn_detector_355_test.dart` | 32 engine tests (pure Dart; all pass under a plain-`dart` harness) plus service tests that need the Flutter test runner: isolated vs not isolated siren alert, headset-mic frames skipped, Automatic horns follow the audio state, built-in mic pick, mic plan |
| `test/voice_cleanup_355_test.dart` | 12 DSP tests (all pass in plain `dart`) plus 3 intercom tests that need Flutter |

## 6. Limits (honest)

- **Phone in a pocket at 80 km/h.** Clothing and wind noise can bury a siren: it must stand about 10 dB above the ambient floor in its band. Detection works best with the phone on the handlebar mount or in a tank bag.
- **Helmet / earbud mics are never used for detection.** They sit inside the helmet or ear and are noise-suppressed. Detection always uses the phone's own mic; only a held push-to-talk with a headset pauses it for the press. Hands-free talk with a headset uses the phone mic (weaker voice, see section 1).
- **"Isolated" is a best guess.** A Bluetooth speaker on the bike counts as a headset (alerts are spoken, which is fine). Open-face helmets with no earphones and no music count as "can hear" even at high wind noise: the rider gets the card + vibration + tone, not speech. Turn Horn alerts On for horns in that case.
- **Call-only (HFP) helmet sets.** A headset that offers only the call profile (no A2DP media) counts as isolated, but media cannot reach it, so critical lines stay on the alarm stream (phone speaker). Nearly all current helmet sets and earbuds have A2DP.
- **Alert volume in the headset.** Critical lines raise the media volume to at least 60 % for the line. Some Bluetooth headsets with their own volume (absolute volume off) may still be quieter.
- **No direction.** One microphone cannot localise. "Approaching" means "getting louder", and "behind" is never claimed. A siren ahead coming towards the rider also reads as approaching.
- **The kind is a guess.** The same hi-lo, wail and yelp patterns are shared between ambulance, police and fire in many countries. The kind is shown only when the confidence is high, and as a likeness.
- **Very fast yelps (8 Hz) need a stronger signal** than slow ones, because of the 32 ms analysis window.
- **Horns masked by a passenger** talking right next to the phone may be missed (they fall below the "close" threshold). Horns sounding during a siren are not alerted, by design.
- **The trend is unknown at first.** The trend needs about 4 s of siren, so the first alert usually says "close by" and the cockpit card adds "Approaching" or "Moving away" later.
- **Lock-screen haptics.** `HapticFeedback` may not vibrate with the screen off on some phones, so with the app in the background the alert posts a heads-up with vibration instead (`AlarmNotifier.showSoundAwarenessAlert`).
- **Pure Dart DSP.** The DSP runs on the UI isolate. The cost is small (see above), but very old phones may show it in traces.

## 7. Settings and admin switches

**Settings** (`SettingsService`, loaded by `loadSoundSettings()` from `main()`):

| Setting | Key | Default |
|---|---|---|
| `sirenAlerts` | `siren_alerts_v1` | on |
| `hornAlerts` | `horn_alerts_mode_v1` | `null` = Automatic: only while the rider is isolated (earphones / helmet set, music, intercom, call); also On / Off |
| `voiceCleanup` | `voice_cleanup_v1` | on |
| `giveWaySide` | `give_way_side_v1` | `auto`; also `left` / `right` |

The old `siren_tell_group_v1` key is no longer read (the group card was removed).

Settings › Voice & sound has the rows:

- **Siren alerts**: "Warns you about ambulance, police and fire sirens, even when your earphones block outside sound. Listens on your phone during rides only. Nothing is recorded or sent." With **Give way to the…** under it.
- **Horn alerts** (Automatic / On / Off): "Automatic: only when earphones or music may stop you hearing traffic. Listens on your phone during rides only. Nothing is recorded or sent."
- **Clean up my voice**.

Each is hidden when its admin switch is off. The horn card clears after 4 s. The old gap (Automatic horns with Siren alerts off never opened the mic, so the headset was never seen) is fixed: isolation comes from the phone's audio state without the mic, and the mic opens for horns whenever they are effectively active.

**Admin switches** (FeatureFlagsService; unknown means on):

| Switch | Controls |
|---|---|
| `sirenDetector` | sirens |
| `hornAlert` | horns |
| `voiceCleanup` | intercom cleanup |

When both detection switches are off, the mic is not opened for detection.

## 8. Intercom public API for notification actions (agent "audio")

- `IntercomService.toggleHandsFreeTalk()` arms or disarms hands-free talk and returns the new armed state.
- `IntercomService.toggleGroupMute()` stops or resumes hearing the group (deafen) and returns the muted state.
- Existing names are unchanged (`setMicMuted`, `beginTransmission`, `endTransmission`, `startVox`, `stopVox`, `disableHandsFree`, ...).

## 9. Device checks (to do on real phones)

1. Start a ride with the app in front. The notification's service has the microphone type: check `adb shell dumpsys activity services <pkg>` for `foregroundServiceType=0x88` (location|microphone). Then lock the screen and play a siren recording near the phone. The P1 voice should come through the headset.
2. A trip started while the phone is locked: on unlock, the service gets the microphone type (resume hook). Check again with screen off.
3. Phone call during a ride: the mic is released (the Android mic indicator goes off), then comes back after the call.
4. **ANC earbuds (noise cancellation on) + music**: play a siren recording near the phone (not near the earbuds). Music pauses, the line is heard **in the earbuds only** (not on the phone speaker), at a clear volume even with a low media volume; the volume goes back after.
5. **Helmet Bluetooth set**:
   - detection: `adb shell dumpsys audio` shows the capture on the built-in mic (`AUDIO_DEVICE_IN_BUILTIN_MIC`), no SCO; music stays A2DP stereo;
   - push-to-talk held: SCO helmet mic; released: back to the built-in mic;
   - hands-free talk: the built-in mic (check the voice is understandable from a tank-bag / mount phone);
   - disconnecting the headset: the next critical line plays on the speaker on the alarm stream.
6. **Wired earphones with an in-line mic**: detection still records from the built-in mic (dumpsys audio), not the cable mic.
7. **Phone speaker, no music**: a siren close by gives a short tone + vibration + card, no speech. Start music in another app: the next siren is spoken.
8. **Horns on Automatic with Siren alerts off**: no headset, no music: the mic indicator stays off. Connect earbuds: within ~3 s the mic opens (indicator on) and two horns give "Horn close by".
9. On devices with an odd `mic` source (some apply AGC anyway), check that a siren at ~10 m from a tank-bag phone at 40-60 km/h is detected. Note pocket and mount results.
10. Hands-free talk at 60-100 km/h with a helmet mic: breathing hard and wind gusts should not open the gate, and speech should open it within about 40 ms with no cut first syllable.
11. Data saver on: listeners hear 8 kHz voice at the right speed, and detection still runs.
12. Battery below 15 % (not charging): detection pauses, and the intercom still works.
13. Turning the admin switches `sirenDetector` and `hornAlert` off, or turning both settings off, makes the Android mic indicator go off within a second when the intercom is idle.

## 10. Native / manifest notes

- No manifest change is required. The manifest already has `RECORD_AUDIO`, `FOREGROUND_SERVICE_MICROPHONE` and `foregroundServiceType="location|microphone"`.
- Kotlin (`TtsChannel.kt`, channel `coroute/tts`): `listeningState` (headset kind from `getDevices(GET_DEVICES_OUTPUTS)`: A2DP / SCO / BLE headset (API 31+) = bluetooth, hearing aid (API 28+), wired / USB (API 26+) headset; `isMusicActive`; call mode), `alertTone` (one 400 ms tone, media stream on a headset, alarm stream on the speaker), and the critical-line routing rule (headset = guidance usage + 60 % media floor, speaker = alarm usage; also used for the critical fallback tone). Not compiled here: build once.
- Recommended for `background_service.dart` (not owned by this change): start the service with `micActive: await _micGranted()` (the `micGranted` parameter of `serviceTypesFor` is currently unused by `start`). The microphone type would then be present from the first start, and the stop-and-restart in `ensureMicrophoneType()` would be needed less often. Also expose a `runningWithMic` getter.
- The `coroute/audio_watchdog` channel used by the legacy ducking call (`setSirenDucking`) has no native handler; the call is a safe no-op. Music is paused by the P1 voice alert (`pauseOthers`) instead.
