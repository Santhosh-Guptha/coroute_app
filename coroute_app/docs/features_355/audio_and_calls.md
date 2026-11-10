# 3.55 Audio output, other apps' sound, speed, phone calls, lock screen

What the rider hears and sees while riding with a helmet Bluetooth set or the phone speaker, music
playing in another app, the phone in a tank bag / pocket / mount and the screen locked.

Code: `lib/data/services/audio_priority_manager.dart` (rules, header comment), `voice_service.dart`,
`speed_audio_service.dart`, `phone_call_service.dart`, `alarm_notifier.dart`, `alert_service.dart`,
`ride_notification_service.dart`; pure logic in `lib/domain/safety/speed_audio_policy.dart` and
`lib/domain/voice/call_alert_queue.dart`; native in `TtsChannel.kt`, `MediaVolumeGuard.kt` (new),
`PhoneCallChannel.kt`, `RideNotification.kt`.

## Priorities

| Level | Examples | Other apps' music | Stream / usage | Notes |
|---|---|---|---|---|
| P0 emergency | SOS, crash countdown, rider down, post-call safety replay | **paused** (AUDIOFOCUS_GAIN_TRANSIENT) | headset: navigation guidance (A2DP); speaker: ALARM | preempts any lower line at once; never muted by settings |
| P1 safety confirmation | Are you OK?, break confirmation, overspeed **40 %+ over the limit**, siren close by (rider isolated) | **paused** | headset: navigation guidance (A2DP); speaker: ALARM | preempts P2-P5 at once; never muted by settings |
| P2 hazard | pothole, animal, accident ahead | ducked (paused with "Pause music during alerts") | navigation guidance | earcon first; preempts P4 / P5 |
| P3 navigation | turn, re-route | ducked / paused (toggle) | navigation guidance | dropped during a call |
| P4 group | fell behind, regroup, convoy split | ducked / paused (toggle) | navigation guidance | |
| P5 info | fuel, weather, overspeed under 40 % | ducked / paused (toggle) | navigation guidance | |

* **3.55 latency** (details and timings: `alert_latency.md`, "Speech output"): the speech engine is warmed
  up at ride start (bound, offline low-latency voice, earcon written) and kept for the whole ride (it
  used to start on the first alert, and during offline solo rides it was released after every convoy
  update); the 16 siren lines and the lead phrases "Slow down." / "Over limit." / "Please slow down."
  are pre-synthesised clips that start at once; P0-P2 lines that are not clips start with a 0.16 s
  earcon while the words are synthesised; a line preempts what is being said when everything queued
  is of lower priority (P0 / P1 over any lower, others over two levels lower); cut lines are said
  again after it unless stale; equal priorities queue.
* Focus is requested (with a listener) right before each line and released 0.7 s after the native
  speech queue is empty (a burst of lines is one duck; no pumping). Every focus result is in the
  audio diagnostics (`focus duck line granted music=true`).
* **Why music sometimes did not get quieter during a line:** Android 8+ ducks other apps by itself
  for AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK with `setWillPauseWhenDucked(false)` and the navigation
  guidance usage, which is what CoRoute requests, so Spotify / YouTube Music duck. Apps that play
  speech content (podcasts, audiobooks) or target old Android versions are not auto-ducked and may
  keep playing at full volume: "Pause music during alerts" pauses them instead (critical lines always
  pause). Lowering the media volume is not an option for ordinary lines, because the line itself
  plays on the media volume (helmet / earbuds over A2DP).
* Another app taking permanent focus during a critical line: the line keeps playing and CoRoute asks for
  focus again after 0.3 s (the other app pauses / ducks).
* Bluetooth: speech goes over A2DP like map directions; SCO is never forced for speech. A headset that
  connects or drops mid-ride simply takes the next line.
* **Critical lines and headsets (3.55 rule, TtsChannel.kt, decided per line):** with a headset connected
  (Bluetooth A2DP / SCO / LE audio, hearing aid, wired / USB) a critical line uses the navigation-guidance
  usage, so it plays in the helmet / earbuds like media (noise cancellation does not block playback), and
  the media volume is raised to at least 60 % of max for the line, then put back (unless the rider changed
  it). The ALARM usage is not used then, because Android may play alarms on the phone speaker as well.
  With no headset, critical lines use ALARM (heard with media volume 0 and through DND). The critical
  fallback tone follows the same rule.
* Same line again: the existing per-priority dedupe windows (cooldown) apply; stale queued lines expire (TTL).
* No speech engine / engine error: tone + vibration for P0–P2 (alarm stream for critical) and, for
  P0 / P1, a sounding heads-up on the new **Critical ride alerts** channel.

## Real scenarios

| Scenario | What the rider hears / sees |
|---|---|
| Music playing, hazard ahead | Music gets quiet, "Pothole ahead" at full speech volume, music comes back ~0.7 s after |
| Music playing on the speaker, crash countdown / SOS / siren close | Music **pauses**, line on the alarm stream (heard even with media volume 0, and through DND when alarms are allowed), music resumes after |
| ANC earbuds + music, siren close / SOS | Music **pauses**, the line in the earbuds (media speech, at least 60 % volume), not on the phone speaker; volume and music come back after |
| Helmet Bluetooth set, no music, critical line | In the helmet (media speech over A2DP), not on the speaker |
| Wired earphones, critical line | In the earphones (media speech) |
| Phone speaker, no music, siren close | Short tone + vibration + cockpit card (no speech: the rider hears the siren; see sound_awareness_and_intercom.md) |
| Phone in a pocket, earbuds in | Alerts are heard in the earbuds; a siren is detected only if the pocketed phone hears it (may miss at speed) |
| "Pause music during alerts" on, any line | Music pauses for every line, resumes after the last one |
| Media volume 0 | Ordinary lines silent (rider's choice); critical lines still heard (speaker: alarm stream; headset: media raised to 60 % for the line) |
| Do Not Disturb on | Critical lines heard (alarm usage); SOS and Critical channels use the alarm sound and `bypassDnd` (honoured when the rider gives CoRoute DND access) |
| 10 % over the limit for 4 s (the strictest of the group, my own and the **road / zone** limit) | Music to 60 % of the rider's volume; overspeed warning plays at the rider's full volume |
| 25 % over | Music to 30 % |
| 40 %+ over | Music paused; "Slow down. 95 km/h, limit 65." as a critical line (alarm stream) |
| Back 3 km/h under the limit for 5 s | Music resumes and the volume ramps back up (one step every 0.25 s) |
| Rider changes the volume / presses play while lowered | CoRoute stops touching the volume for the rest of that episode and never "restores" over it |
| Over the limit while CoRoute is speaking (the overspeed line itself) | The lowered volume is applied when the line ends (3.55 fix: it used to be skipped, and the next check took it for the rider's own change and stopped lowering for the episode) |
| Headset reports back a neighbouring volume step (Bluetooth absolute volume rounding) | Taken as the value set, not as the rider's change |
| Fixed-volume device, `setStreamVolume` refused (DND policy, OEM) or ignored (some absolute-volume headsets), or media volume at 2 steps or less | **Fallback: audio focus.** A silent transient "may duck" focus is held while over the limit (Android ducks other apps), the pause step holds a transient focus (music pauses); released at the end of the episode. Music always gets quieter |
| Ride ends / SOS / crash alarm / setting or admin switch off / no fix for 15 s | Volume restored at once |
| App killed while lowered | Restored at the next start (only if the volume is still the one CoRoute set) |
| Helmet set connects while lowered | The new route is lowered from its own volume; the speaker's saved volume is restored when that route comes back |
| Intercom voice arrives while music is lowered | Intercom kept at the rider's original volume, music ducked under it (SpeedAudioService, if `intercom` is passed) |
| Phone rings | Ordinary lines held (not spoken over the ringtone); critical: full line on the alarm stream, buzz, heads-up |
| On a call | Ordinary lines held, navigation dropped; critical: short tone + very short phrase **in the call audio** (caller does not hear it), buzz, heads-up notification; group chat paused (IntercomService, existing) |
| Call ends | "Safety alert during your call: …" (critical, full) then "While you were on the call: 2 road warnings, Asha fell behind." Lines older than 60 s dropped (critical kept 5 min), latest per kind |
| Screen locked, critical alert | Voice plays; another rider's SOS shows full-screen over the lock screen (UrgentAlertActivity), or heads-up when Android 14+ denies full-screen intents (`canUseFullScreenIntent`) |
| Screen locked, ride notification | Speed (rounded to 5), limit, next warning ahead, intercom state (Talking / Receiving Asha / Group voice muted / Hands-free on / Voice paused (call)); buttons SOS, Talk on/off, Mute/Unmute, Leave, all usable without unlocking (broadcasts) |
| Alert notification while the voice speaks it | Notification posted silently (no double sound); if the voice cannot speak it (muted, no engine, phone call) the notification sounds |

## Settings and admin switches

* **Lower music when speeding** (Settings > Voice & sound, default on): `SettingsService.lowerMusicWhenSpeeding`.
  Hidden when the admin switch `speedAudio` is off.
  **3.55 root cause of "volume control on music not working":** (1) only the group / personal limit
  was used, both 0 by default, while most riders are warned by Road care's road / school / hospital
  limit: the music was never lowered. Now the strictest of all three is used (Road care's limit with
  the admin switch `speedLimits`), and offline solo rides count as rides. (2) The overspeed line
  plays exactly when the episode starts; a lowering that arrived while it played was skipped and then
  read as the rider's own change (episode over). (3) Volume changes that a device ignores had no
  fallback. Every step is in the audio diagnostics (`speed music apply 60% route=bt idx 10->6`,
  `volume set ok`, `volume ignored ... -> focus fallback`, `duck focus granted`, `restore`).
* **Pause music during alerts** (existing): ordinary lines pause instead of duck. Critical lines always pause.
* Admin `speedAudio` (unknown = on): off restores the music and stops lowering.
* Admin `callAwareAlerts` (unknown = on): off gives the 3.54 behaviour (lines spoken during calls, P0
  queued for a post-call replay).

## Notification channels

| Channel | Use | Sound | Lock screen |
|---|---|---|---|
| `coroute_convoy` (plugin, existing) | ride status, ongoing | silent | public (no private data) |
| `coroute_critical_alerts` (new) | critical line during a call / when speech failed | alarm, vibration, bypassDnd | public (names only) |
| `coroute_sos_v2` (replaces `coroute_sos`) | another rider's SOS | **alarm** usage, insistent, bypassDnd | public (names only) |
| `coroute_alerts`, `coroute_hazard` (existing) | group alerts, accident warnings | silent when spoken, else default | public |
| `coroute_crash` (existing) | own crash alarm | alarm, full-screen | public |

Intercom has no notification of its own: its state is on the ride notification. Chat messages are
not part of this work (keep them private on the lock screen where they are posted).

## For the lead to wire (main.dart is not mine)

1. `SpeedAudioService` (lazy: false, wired in main.dart), see its class comment:
   `SpeedAudioService(ctx.read<ConvoyService>(), ctx.read<SettingsService>(), safety: ctx.read<SafetyService>(), intercom: ctx.read<IntercomService>())`, dispose on teardown.
2. `RideNotificationService(..., intercom: ctx.read<IntercomService>())` for the state line and the
   Talk on/off + Mute toggles (without it the notification is as before; Talk opens the app).
3. Nothing else: call-aware alerts work through the existing `voice.attachPhoneCallService`, the
   critical notifier is set by `AlarmNotifier` when it initialises.
4. Optional: `RideNotificationChannel.canFullScreen()` for the phone check (Android 14+ full-screen
   permission).
5. Agent "mic" (done): siren lines are P1 / P2 through `priorityManager.submit` only when the rider is
   isolated (headset / music / intercom / call), else a short tone (`NativeVoiceEngine.alertTone`) (horn
   alerts were removed in 3.55). Other services can use `voice.priorityManager.announce(AudioPriority.p0CriticalEmergency, text, key: ...)`
   (or the existing `VoiceService.speakEmergency / speakHazard`). If the intercom ever sets
   MODE_IN_COMMUNICATION, call `PhoneCallService.setOwnCommunicationMode(true/false)`.
   Not changed (not mine): after a call the intercom does not re-arm hands-free by itself.

## Audio diagnostics (device tests)

`AudioDiagLog` (`lib/domain/audio/audio_diag_log.dart`) keeps the last 300 audio lines of the ride
in memory and prints them (`adb logcat -s CoRouteAudio flutter`): alert queued / preempting / to the
engine with its wait, speech start delay (clip or not), decision-to-audio time, focus results, music
volume changes and fallbacks, engine warm-up and clip count. No spoken text, names or places (a key
that is the text itself is logged as "(text)").

## Tests

* `test/speed_audio_policy_test.dart`, `test/call_alert_queue_test.dart` (pure logic; also sanity-run
  with plain Dart).
* `test/audio_and_calls_355_test.dart` (ducking vs pause flags, far-overspeed, announce, in-call
  phrase + heads-up + after-call summary, ringing, fallback, status line, setting).
* Updated to the new behaviour: `phone_call_and_fuel_safety_test.dart`, `audio_priority_and_fatigue_test.dart`
  (ordinary lines are no longer spoken during a call; a switch-off test keeps the old behaviour).

## Needs a device check

* TTS with `USAGE_VOICE_COMMUNICATION` during a cellular call: heard in the earpiece / helmet call link and
  not sent to the caller (expected on stock Android; some OEMs may drop it, the tone + buzz + heads-up remain).
* `ToneGenerator` on `STREAM_VOICE_CALL` during a call (some phones refuse; caught).
* Critical lines with a Bluetooth helmet set / ANC earbuds: heard in the headset only (media speech), not on
  the speaker; the 60 % media floor is applied and restored (some headsets with their own volume may differ).
  With no headset: alarm stream on the speaker as before.
* Call detection without READ_PHONE_STATE: Android 12+ uses audio-mode changes; older phones poll the mode
  every 1.5 s. Some phones never set MODE_RINGTONE while ringing (then ringing is seen only when the call connects).
* Music apps honour transient focus loss (pause) and resume when CoRoute gives it back (Spotify, YouTube Music, JioSaavn).
* `setStreamVolume` on Bluetooth absolute-volume devices and the per-route volume handling; the
  diagnostics show `volume set ok` or `volume ignored ... -> focus fallback` (then music must duck
  by focus). Check on a fixed-volume device (some Android TV / car head units) that the duck focus is
  used.
* Ride over a road / school-zone limit with no group or personal limit set: music lowers after 4 s
  at 10 % over, pauses at 40 % over, comes back 5 s after slowing down.
* Speech latency: `speech start ... +NNms (clip)` for a siren line under ~150 ms; `decision->audio`
  under 500 ms for P0 / P1; the earcon heard at once for a hazard line. First alert of a ride: no
  extra delay (engine warmed at ride start: `engine warm ok=true`).
* Offline voice: `tts voice offline picked` or `tts voice default offline` in the log; with only a
  network voice installed for the language, `no offline voice` (expect slower lines).
* Talk on from the lock screen on Android 14 (microphone foreground-service type started from a
  notification action).
* Full-screen intent denied on Android 14+: heads-up shows instead.
* DND access: the critical channels bypass DND only after the rider allows CoRoute in Settings > Do Not Disturb access.
* Kotlin was not compiled here (no Android SDK): build once.
