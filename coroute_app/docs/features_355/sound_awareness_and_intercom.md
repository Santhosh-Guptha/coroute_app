# 3.55 Sound awareness and clean intercom voice

During a ride, the phone's own microphone listens for emergency-vehicle sirens (ambulance, police, fire engine). Horn alerts were removed (owner's decision, 3.55). The same microphone gives the intercom a cleaned-up voice: breath, wind and engine noise are taken out before anything goes to the group.

**Purpose (owner's decision).** The real scenario is a rider who cannot hear outside sound: noise-cancelling earbuds, a helmet Bluetooth set, or music. The phone on the mount, in the tank bag or in a pocket still hears the road, even when the earbuds cancel it. CoRoute warns **that rider**; it does not tell the group (the old "Tell my group" card was removed). A siren reaches the rider through the headset even with noise cancellation on: ANC blocks outside sound, not playback.

All audio is processed on the phone. Detection audio is never recorded, stored or sent. The intercom sends voice only while the rider talks.

## Files

| Part | File |
|---|---|
| One shared ride microphone | `lib/data/services/ride_mic_hub.dart` (`RideMicHub`) |
| Siren detector (pure Dart DSP) | `lib/domain/audio/sound_awareness_engine.dart` (`SoundAwarenessEngine`) |
| Voice cleanup (pure Dart DSP) | `lib/domain/audio/voice_cleanup.dart` (`VoiceCleanup`) |
| DSP building blocks | `lib/domain/audio/dsp_core.dart` (biquad, FFT, peak limiter, 2:1 decimator) |
| Alert level (isolated or not), own sound on the speaker (pure Dart) | `lib/domain/audio/sound_alert_policy.dart` (`SoundAlertPolicy`, `ListeningState`) |
| Alerts and spoken lines, cockpit card, ducking, audio-state polling | `lib/data/services/siren_acoustic_detector.dart` (3.55 "ride mic hub path" section) |
| "Can the rider hear outside?" (native, no mic), critical-line routing, alert tone | `android/.../TtsChannel.kt` (`listeningState`, `alertTone`, `headsetOutput`); Dart: `NativeVoiceEngine.readListeningState` / `alertTone` in `voice_service.dart` |
| Intercom on the shared mic, cleanup, playback limiter, toggles | `lib/data/services/intercom_service.dart` |
| Settings (added at the end of the class) | `lib/data/services/settings_service.dart` |
| Wiring | `lib/main.dart`, between the "3.55 sound awareness (mic agent) BEGIN" and "END" markers |
| Cockpit card | `lib/presentation/rider/widgets/siren_hud_pill.dart` (title from `SirenDetectionEvent.alertText`) |
| Tests | `test/sound_alert_policy_test.dart`, `test/siren_detector_355_test.dart`, `test/voice_cleanup_355_test.dart`, `test/support/audio_synth_355.dart` |

## 1. One microphone for the whole ride (RideMicHub)

Android reliably allows only one capture per app. The detector and the intercom therefore share one `record` stream: 16 kHz mono PCM16, cut into 20 ms frames (320 samples).

- **When it opens.** The mic opens only while a consumer needs it:
  - **Detection** needs it while all of these hold: a ride is active (group trip `STARTED` or an offline solo ride), siren alerts are on (rider setting and admin switch `sirenDetector`), the battery is OK, there is no phone call, the permission is granted, and the app is in front or the ride foreground service is running.
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
- **Hands-free (VOX) with a headset: trade-off.** Android gives one capture, and detection must hear the road, so hands-free talk uses the phone's mic too, cleaned in software (high-pass, noise suppression, breath and wind cut, voice gate). The voice is weaker than from the helmet mic when the phone is far from the rider's mouth (mount, tank bag). Riders who want the clearest voice with a helmet set use push-to-talk. With detection off (siren alerts off), hands-free uses the headset mic as before.
- **Headset changes.** The input device list is re-read every 15 s (device type, label fallback). When the headset state changes, the mic re-opens with the right plan.
- **"Can the rider hear outside?" needs no mic.** It comes from the phone's audio state, read every second during a ride (`TtsChannel.listeningState`: `AudioManager.getDevices(GET_DEVICES_OUTPUTS)` types + `isMusicActive` + call mode + CoRoute speaking) plus the intercom playing. See section 3.
- **Phone calls.** `PhoneCallService` tells the hub (`setPhoneCallActive`). The mic is released during the call and re-opened after it. `audioInterruption: pauseResume` covers other interruptions.
- **Permission missing.** Detection never shows the system dialog in the middle of a ride. It checks only, and says once: "Siren alerts need the microphone. Allow it for CoRoute in phone settings to use them." The intercom asks on the rider's tap, as before.
- **Battery.** Detection pauses at < 15 % (when not charging), with Battery saver on, or with the SOS battery reserve. The intercom keeps the mic when it needs it.
- **Data saver.** Capture stays at 16 kHz, because detection needs it. The intercom sends 8 kHz: the cleaned 16 kHz signal goes through a 31-tap low-pass and a 2:1 decimator.
- **Switch off = mic off.** The setting, the admin switch or the end of the ride releases the mic at once (`settingsChanged` → `reevaluate`).
- **Background and lock screen.**
  - The hub keeps running in the background only while the ride foreground service runs.
  - When the mic opens with the app in front, and again on every resume while it is open, the hub calls `BackgroundService.ensureMicrophoneType()`. That restarts the ride service once with the `microphone` type, so capture continues with the screen off.
  - The intercom now calls `ensureMicrophoneType()` only while the app is in front. The call stops and restarts the service, and Android 14 refuses to start a microphone service from the background, which would have killed the ride service.
- **Errors.** If the mic is taken by another app or an assistant, the hub retries after 3, 6, ... 18 s, then waits for the next resume or setting change.

## 2. Sirens (SoundAwarenessEngine)

Every 20 ms, the last 512 samples (32 ms, Hann window) go through one 512-point FFT (31.25 Hz bins).

Each bin has an adaptive noise floor. It drops fast and rises about 2 dB/s, so a steady engine drone, wind roar, rain or tyre noise becomes "floor". Only sounds that stand out of the floor are looked at.

**Tonal frame.** A frame is tonal when all of these hold:

- the peak in 380-2100 Hz that stands highest above its floor is at least 8 dB above it. When it is the 2nd or 3rd harmonic of a stronger partial (wind makes the floor low-pitched, so a harmonic can stand out more), the fundamental is followed;
- that peak holds at least 45 % of the floor-normalised excess energy within ±780 Hz (a second siren's peak counts too). A gust or rain spreads its excess over all bins and fails this;
- there is no harmonic comb around the peak (speech and engines are combs over a low fundamental; a siren tone is its own lowest partial);
- the mic is not clipping.

With two tonal peaks (two sirens), the one that continues the previous frame's track is followed. Frames where broadband sound covers the band (a gust, rain, clipping: half the band ≥ 6 dB over its floor) are **masked**: they neither break nor extend a run.

**Continuous for a few seconds.** A siren is only considered once its tone has run **continuously for 2.5 s**, with no gap longer than **0.4 s** (masked frames do not count as a gap, up to 1.2 s in a row; an isolated tonal frame, a noise blip, neither starts nor bridges a run). Short chirps, a horn honk, a "whoop", a reversing beeper (0.5 s gaps) or a notification sound never get that far.

**Pattern.** Every 100 ms the current run (at most the last 4 s) is classified:

- **Hi-lo / two-tone:** two tight frequency clusters (ratio 1.1-1.7, ≤ 18 % of the frames between them) alternating at a **regular dwell** (robust spread of the tone lengths ≤ 30 %, dwell 0.12-1.6 s), each tone **sustained** (a struck or plucked note, as in a chime or ringtone, decays > 6 dB within the tone). A tune of 3 or more steady notes (musical truck horn, ringtone, temple loudspeaker) is rejected outright.
- **Yelp:** a smooth triangular sweep, span ≥ 300 Hz, reversing 2.5-12 cycles a second, with regular half cycles (below 5 cycles/s) and steady turning points (spread ≤ 10-12 %). Singing and melisma wander and fail.
- **Wail:** a smooth sweep, span ≥ 350 Hz within 360-2200 Hz, at most 1.2 cycles a second, sweep speed 80-3000 Hz/s, each half cycle ≥ 0.8 s and mostly one-way (≥ 75 % of the steps in the sweep's direction). Also a mechanical siren's slow spin-up.
- **Not reported:** a constant tone (span < 8 % of the pitch: horn, alarm, whistle, beeper), held notes, and smooth sweeps at 1.2-2.5 cycles a second (speech intonation).

Three positive evaluations in a row (300 ms) confirm. **Typical alert: 2.8-3.1 s after the siren starts.**

**Kind (ambulance / police / fire), said only when confident.** From the pattern mix of the whole episode (last 20 s):

| Evidence | Kind | Confidence |
|---|---|---|
| hi-lo, ratio 1.18-1.6, dwell 0.33-1.1 s (India 1050/700 or 960/770 Hz, EU two-tone) | ambulance | 0.72-0.9 (more evaluations, regular dwell) |
| hi-lo and wail switching | ambulance (typical in India) | 0.85 |
| yelp (3-12 cycles/s) | police | 0.78-0.88 |
| wail and yelp switching ("wail-yelp") | police | 0.9 |
| hi-lo and yelp switching, or a very fast hi-lo (dwell < 0.33 s) | police | 0.72-0.82 |
| slow, low wail (centre < 850 Hz, sweep < 700 Hz/s: mechanical) | fire engine | 0.78-0.88 |
| electronic wail alone, narrow two-tone (ratio < 1.18, e.g. the French police "pin-pon"), anything else | none: "Emergency vehicle" | 0 |

A weak siren (tone < 12 dB over the floor) loses 0.06. The kind is said at ≥ 0.8; until then the line says "Emergency vehicle" and the cockpit card updates when the kind becomes clear (for example a wail that switches to yelp becomes "POLICE SIREN").

**Episodes and cool-down.**

- One alert per episode. An episode ends 8 s after the last positive evaluation.
- A new episode alerts only if 30 s have passed since the last alert.
- Within that time, a new alert comes only when the siren is clearly closer: a nearness step up and at least 6 dB louder.
- Within an episode, an "approaching" alert comes when the trend becomes approaching while near, at most once per 30 s. A siren that stays at the same distance (stuck behind an ambulance in traffic) is not repeated.

**Trend and nearness.**

- **Approaching / moving away:** the least-squares loudness slope of the tone over the current run, at most the last 5 s. ≥ +1 dB/s means approaching; ≤ −1 dB/s, or a ≥ 3 % Doppler drop of the hi-lo / yelp pitch between the two halves of the window with a flat or falling level, means moving away (it passed). Doppler is not used for a wail (its own sweep would look like it).
- The trend is reported only once at least 2 s of tone spread over at least 4 s have been heard. Before that, it is "unknown" and is not spoken.
- **Nearness:** the median tone SNR over the last second. ≥ 24 dB is very near, ≥ 14 dB is near, anything less is far.

**Direction.** One phone microphone cannot tell behind from ahead. The alerts say "close by" or "approaching", never "behind". `directionKnown` stays false.

**The phone's own sound.** While the phone plays sound on its own loudspeaker (another app's music, the intercom without a headset, CoRoute's own spoken line; from `listeningState` every second and, for our own speech, at once from the Dart side), the engine treats the frames as silent (`SoundAwarenessEngine.suppress`) and leaves its noise floor alone, so the phone never alerts on itself. With earbuds or a helmet set the sound goes to the ears, and the phone mic keeps listening to the road. A ringing phone releases the mic anyway (phone call).

## 3. What the rider hears and sees

**Listening isolated** (the rider likely cannot hear outside) = ANY of: a Bluetooth audio headset (A2DP, SCO, LE audio headset), a hearing aid, a wired / USB headset or headphones, another app's music playing (`isMusicActive`), the intercom playing a rider's voice, or a phone call. Pure rule: `SoundAlertPolicy` / `ListeningState.isolated`.

| Alert | Rider isolated | Rider not isolated (phone speaker, no music) |
|---|---|---|
| Siren close / approaching / clearly closer | **Full:** P1, music paused, the line through the headset at alert volume, strong vibration, cockpit card, heads-up when the app is not in front | **Softer:** cockpit card, strong vibration, one short tone (no speech: the rider hears the siren) |
| Siren far away | P2 "Emergency vehicle siren in the distance." (music ducked), medium vibration, card | card, medium vibration |

**The spoken line names the kind only when the engine is confident** (`SirenAcousticDetector.sirenAlertText`): "Ambulance siren close by. Keep left and give way.", "Police approaching. Keep left and give way.", "Fire engine getting closer. Keep left and give way.", "Ambulance siren in the distance."; otherwise "Emergency vehicle siren close by. ..." The cockpit card title follows ("AMBULANCE SIREN · GIVE WAY", else "EMERGENCY VEHICLE SIREN · GIVE WAY"). All 16 lines for the rider's give-way side are pre-synthesised at ride start, so the alert starts at once (alert_latency.md, "Speech output").

How the spoken line reaches the rider (the rule for **all** critical lines, `TtsChannel.kt`): with a headset connected, the line uses the media "navigation guidance" usage, so it plays in the helmet / earbuds over A2DP, with the media volume raised to at least 60 % of max for the line and put back after. It does **not** use the alarm usage then, because Android may force alarm sound to the phone speaker (the rider would miss it in the helmet). With no headset, critical lines use the alarm usage (heard with media volume 0 and through Do Not Disturb).

**Real scenarios**

| Scenario | Isolated? | Rider hears | Rider sees / feels |
|---|---|---|---|
| ANC earbuds + music, ambulance (hi-lo) close behind or ahead | yes (Bluetooth + music) | Music pauses; in the earbuds, about 3 s after the siren started: "Ambulance siren close by. Keep left and give way." | Strong triple vibration, "AMBULANCE SIREN" card, heads-up on the lock screen |
| Helmet Bluetooth set, no music, police yelp approaching | yes (Bluetooth) | In the helmet: "Police approaching. Keep left and give way." (kind only when confident, else "Emergency vehicle approaching ...") | Card "… · Approaching · Close", strong vibration |
| Electronic wail (used by all services) | as above | "Emergency vehicle siren close by. ..." (no kind: a wail alone does not tell) | Card; becomes "POLICE SIREN" if it switches to yelp, "AMBULANCE SIREN" if it switches to hi-lo |
| Slow, low mechanical wail | as above | "Fire engine siren close by. ..." (once confident) | Card "FIRE ENGINE SIREN" |
| A 1-2 s "whoop" or chirp, a horn honk, a musical truck horn, a reversing beeper, a ringtone, temple music | — | nothing (not continuous / not a siren pattern) | nothing |
| Music playing on the phone's own speaker | — | the phone ignores what its own speaker plays (detection paused while it plays) | — |
| Stuck behind an ambulance for a minute at the same distance | — | one alert only; again only if it gets clearly closer or starts approaching (at most once per 30 s) | Card stays while it sounds |
| Two sirens at once | — | one episode, usually the generic line (the track switches between them; detection can take longer) | Card |
| Tunnel / underpass (echo), rain | — | detected as usual (echo and rain tested) | — |
| Wired earphones, siren far away | yes (wired) | "Emergency vehicle siren in the distance." | Card "… · Far", medium vibration |
| Phone speaker, no music, siren close | no | One short tone (alarm stream) | Card, strong vibration |
| Phone speaker, music playing on the phone | yes (music) | Music pauses; the line on the speaker (alarm stream) | Card, strong vibration |
| Phone in a jacket pocket at speed, earbuds in | yes | Alert only if the phone hears the siren (see Limits: pocket at speed may miss it) | — |
| Helmet set, push-to-talk held while a siren starts | yes | Detection pauses during the press (headset mic); alert follows on release if the siren is still there | — |
| Far siren later 20 dB louder | as above | P1 (isolated): "Emergency vehicle getting closer. Keep left and give way." | Card updates to "Very close" |
| Siren passes and fades | — | nothing new | Card "Moving away", cleared 8 s after the siren stops; intercom ducking lifted |
| Same siren again within 30 s | — | nothing (cool-down) | Card shows again |
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

### Sirens (3.55 continuous-siren engine; first alert after the siren starts)

Siren level about −39 dBFS (13 dB under the ride noise) unless noted. "Kind" is what is said by the end of the episode ("!" = confident, said; "?" = not said).

| Signal | Alert after | Pattern | Kind |
|---|---|---|---|
| Ambulance hi-lo 960/770 Hz, 0.5 s | 2.8 s | hi-lo | ambulance ! (0.81 at the alert) |
| Ambulance hi-lo 1050/700 Hz, 0.7 s (India) | 2.8 s | hi-lo | ambulance ! |
| Two-tone 410/550 Hz, 0.6 s (DE-style) | 2.9 s | hi-lo | ambulance ! |
| Hi-lo / wail switching (India ambulance) | 2.8 s | hi-lo, then wail | ambulance ! |
| Narrow two-tone 435/488 Hz (FR police) | 3.0 s | hi-lo | none (generic) |
| Police yelp 3.5 / 5 / 8 Hz | 3.7 / 3.1 / 3.1 s | yelp | police ! (8 Hz: said once confident) |
| Wail-yelp switching | 2.9 s | wail, then yelp | generic at the alert, police ! on the card |
| Mechanical fire siren (380-1050 Hz, 9 s cycle) | 3.1 s | wail | fire engine ! |
| Electronic wail 500-1800 Hz, 4.5 s | 3.1 s | wail | none (generic, by design) |
| Hi-lo / wail in a tunnel (5 echoes, 31-270 ms) | 2.8 / 3.1 s | as dry | as dry |
| Hi-lo in rain | 2.8 s | hi-lo | ambulance ! |
| Hi-lo in clipping wind at 100 km/h (−26 dBFS siren) | 2.9 s | hi-lo | ambulance ! |
| Quiet hi-lo / wail (−45 dBFS, 19 dB under the ride noise) | 5.1 / 3.8 s | hi-lo / wail | weak: generic |
| Two sirens at once (hi-lo + wail) | 8.6 s | wail | generic |
| Very fast "phaser" 11 Hz | not detected (limit) | | |

Trend and episodes:

| Signal | Result |
|---|---|
| Approaching wail (+2.5 dB/s) / hi-lo (+3 dB/s) | alert, then trend approaching (+2.1 / +2.7 dB/s) |
| Hi-lo leaving (−1.5 dB/s, 6 % Doppler drop) / yelp leaving (5 % drop) | trend moving away |
| Hi-lo passing (rising 3 dB/s, pitch −6 % at the pass, then fading) | one alert; approaching, then moving away |
| Stuck behind an ambulance for 60 s at the same level | 1 alert |
| A 60 s siren that starts approaching after 35 s | 2-3 alerts: the first, then "approaching" / "getting closer" after 35 s |
| Same siren again 13 s after the first ended | no second alert (cool-down) |
| Far hi-lo that becomes 20 dB louder | second alert, reason "closer" |
| Phone playing on its own speaker during the whole siren | no alert; when it stops, the 2.5 s run starts after it |

### No false alarms

0 siren alerts (4 seeds each) on:

- **short sounds:** a 1 s yelp chirp, a 1.5 s hi-lo, a 2 s wail, two 1 s chirps 2 s apart;
- **horns:** car horns honking (with a 1.2 s blast), one 3 s car horn, a truck air horn (180 / 225 Hz), a **musical truck pressure horn** playing a tune (4 s and 8 s, random tunes from a scale, notes 0.15-0.5 s);
- **reversing beepers** (1.1 kHz 0.5 / 0.5 s, 2.7 kHz 0.25 / 0.25 s), a **ringtone** (struck notes, a tune) and a decaying **"ding-dong" chime**;
- **rain**, **temple / loudspeaker music** (harmonium drone + a singer gliding between notes with vibrato), music from a nearby car (chords);
- wind gusts with clipping at 100 km/h, wind only, engine drone and high-rpm engine;
- male, female and child-like speech; a constant 1 kHz tone; near silence; six "everything at once" mixes;
- **20 minutes** of mixed negative audio (40 × 30 s: engines, clipping wind, speech, plus musical horns, beepers, ringtones, temple music, rain with honking, chords).

A real police "whoop" in short bursts with gaps under 0.4 s (or gaps hidden by a gust) counts as continuous and alerts after 2.5 s of it: that is wanted.

### Cost

The detector takes about 0.9 ms per second of audio on a desktop JIT (20-minute mix). Expect a few % of one core on a mid-range phone.

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
| `test/sound_alert_policy_test.dart` | isolated / not isolated alert level, own sound on the speaker, native map parsing (pure Dart; 6 tests, all pass under a plain-`dart` harness) |
| `test/siren_detector_355_test.dart` (was `siren_horn_detector_355_test.dart`) | 52 engine tests (pure Dart; all pass under a plain-`dart` harness): 17 siren kinds / conditions with kind and delay checks, 4 short-sound cases, 22 false-alarm cases, own-speaker suppression, 8 trend / episode cases; plus service tests that need the Flutter test runner: isolated vs not isolated, own music on the speaker ignored, headset-mic frames skipped, setting off, alert texts (every line is pre-synthesised), built-in mic pick, mic plan |
| `test/voice_cleanup_355_test.dart` | 12 DSP tests (all pass in plain `dart`) plus 3 intercom tests that need Flutter |

## 6. Limits (honest)

- **Phone in a pocket at 80 km/h.** Clothing and wind noise can bury a siren: it must stand about 10 dB above the ambient floor in its band. Detection works best with the phone on the handlebar mount or in a tank bag.
- **Helmet / earbud mics are never used for detection.** They sit inside the helmet or ear and are noise-suppressed. Detection always uses the phone's own mic; only a held push-to-talk with a headset pauses it for the press. Hands-free talk with a headset uses the phone mic (weaker voice, see section 1).
- **"Isolated" is a best guess.** A Bluetooth speaker on the bike counts as a headset (alerts are spoken, which is fine). Open-face helmets with no earphones and no music count as "can hear" even at high wind noise: the rider gets the card + vibration + tone, not speech. 
- **Call-only (HFP) helmet sets.** A headset that offers only the call profile (no A2DP media) counts as isolated, but media cannot reach it, so critical lines stay on the alarm stream (phone speaker). Nearly all current helmet sets and earbuds have A2DP.
- **Alert volume in the headset.** Critical lines raise the media volume to at least 60 % for the line. Some Bluetooth headsets with their own volume (absolute volume off) may still be quieter.
- **No direction.** One microphone cannot localise. "Approaching" means "getting louder", and "behind" is never claimed. A siren ahead coming towards the rider also reads as approaching.
- **The kind is a best guess.** The same hi-lo, wail and yelp patterns are shared between ambulance, police and fire in many countries (Indian police also use hi-lo; all services use the electronic wail). The kind is said only when the pattern mix makes it likely (see section 2); an electronic wail alone, a narrow two-tone or a weak siren stays "Emergency vehicle".
- **Detection takes about 3 s** by design (2.5 s of continuous siren + confirmation), so short chirps and horns do not alert.
- **Music on the phone's own speaker pauses detection** while it plays (the mic would hear the phone). With earbuds or a helmet set this does not apply.
- **Very fast yelps:** 8 Hz is detected; an 11 Hz "phaser" is not (the 32 ms analysis window smears it).
- **Two sirens at once** are one episode, detected later (several seconds) and usually without the kind.
- **The trend is unknown at first.** The trend needs about 4 s of siren, so the first alert usually says "close by" and the cockpit card adds "Approaching" or "Moving away" later (an approaching siren re-alerts once).
- **Lock-screen haptics.** `HapticFeedback` may not vibrate with the screen off on some phones, so with the app in the background the alert posts a heads-up with vibration instead (`AlarmNotifier.showSoundAwarenessAlert`).
- **Pure Dart DSP.** The DSP runs on the UI isolate. The cost is small (see above), but very old phones may show it in traces.

## 7. Settings and admin switches

**Settings** (`SettingsService`, loaded by `loadSoundSettings()` from `main()`):

| Setting | Key | Default |
|---|---|---|
| `sirenAlerts` | `siren_alerts_v1` | on |
| `voiceCleanup` | `voice_cleanup_v1` | on |
| `giveWaySide` | `give_way_side_v1` | `auto`; also `left` / `right` |

The old `siren_tell_group_v1` key is no longer read (the group card was removed). The removed horn setting's stored value (`horn_alerts_mode_v1`) is deleted by `loadSoundSettings()`.

Settings › Voice & sound has the rows:

- **Siren alerts**: "Warns you about ambulance, police and fire sirens, even when your earphones block outside sound. Listens on your phone during rides only. Nothing is recorded or sent." With **Give way to the…** under it.
- **Clean up my voice**.

Each is hidden when its admin switch is off. Horn alerts (setting, cockpit horn card, admin switch `hornAlert`, detector) were removed in 3.55.

**Admin switches** (FeatureFlagsService; unknown means on):

| Switch | Controls |
|---|---|
| `sirenDetector` | sirens |
| `voiceCleanup` | intercom cleanup |

When `sirenDetector` is off (or Siren alerts is off), the mic is not opened for detection.

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
8. **Siren kinds**: play recordings of an Indian ambulance (hi-lo), a police yelp / wail-yelp and a fire engine near a mount / tank-bag phone at 40-60 km/h: the line names the kind (or says "Emergency vehicle"), about 3 s after the siren starts. A truck's musical horn, a reversing beeper and a ringtone from another phone must not alert. Play music on the phone speaker with a siren outside: no alert while the music plays.
9. On devices with an odd `mic` source (some apply AGC anyway), check that a siren at ~10 m from a tank-bag phone at 40-60 km/h is detected. Note pocket and mount results.
10. Hands-free talk at 60-100 km/h with a helmet mic: breathing hard and wind gusts should not open the gate, and speech should open it within about 40 ms with no cut first syllable.
11. Data saver on: listeners hear 8 kHz voice at the right speed, and detection still runs.
12. Battery below 15 % (not charging): detection pauses, and the intercom still works.
13. Turning the admin switch `sirenDetector` off, or Siren alerts off, makes the Android mic indicator go off within a second when the intercom is idle.

## 10. Native / manifest notes

- No manifest change is required. The manifest already has `RECORD_AUDIO`, `FOREGROUND_SERVICE_MICROPHONE` and `foregroundServiceType="location|microphone"`.
- 3.55 owner-report round (`TtsChannel.kt`): `listeningState` also returns `ownSpeech` (CoRoute is speaking; the detector ignores the mic then when there is no headset); speech start / done events and diagnostics go back to Dart on the same channel (`MainActivity` sets `tts.events`); siren lines are pre-synthesised clips (`prepare`). Not compiled here: build once.
- Kotlin (`TtsChannel.kt`, channel `coroute/tts`): `listeningState` (headset kind from `getDevices(GET_DEVICES_OUTPUTS)`: A2DP / SCO / BLE headset (API 31+) = bluetooth, hearing aid (API 28+), wired / USB (API 26+) headset; `isMusicActive`; call mode), `alertTone` (one 400 ms tone, media stream on a headset, alarm stream on the speaker), and the critical-line routing rule (headset = guidance usage + 60 % media floor, speaker = alarm usage; also used for the critical fallback tone). Not compiled here: build once.
- Recommended for `background_service.dart` (not owned by this change): start the service with `micActive: await _micGranted()` (the `micGranted` parameter of `serviceTypesFor` is currently unused by `start`). The microphone type would then be present from the first start, and the stop-and-restart in `ensureMicrophoneType()` would be needed less often. Also expose a `runningWithMic` getter.
- The `coroute/audio_watchdog` channel used by the legacy ducking call (`setSirenDucking`) has no native handler; the call is a safe no-op. Music is paused by the P1 voice alert (`pauseOthers`) instead.
