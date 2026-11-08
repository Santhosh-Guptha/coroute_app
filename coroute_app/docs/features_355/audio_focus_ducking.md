# 3.55 Audio Focus, Music Ducking & Voice Alert Overtake Enhancement

Area: Audio safety, Voice guidance, Helmet intercoms, OS media priority.
Release: v3.55.0 (Build 10019)
Status: Code-complete, Kotlin verified, Dart analyzed (0 issues), 100% test pass.

---

## 1. Problem Statement
When riding with external audio active (such as Spotify, YouTube Music, or Podcasts playing through helmet Bluetooth headsets like Sena/Cardo or earbuds), CoRoute's spoken alerts were frequently inaudible or drowned out. Specifically, when exceeding the speed limit or encountering road hazards, the spoken warning played at very low volume without ducking or stopping external music.

---

## 2. Technical Root Cause
1. **Audio Focus Never Requested for Warnings:** In `TtsChannel.kt`, `requestFocus()` was guarded by `if (isEmergency)`. Since non-emergency alerts (speed overlimit, sharp bend cues, potholes, road hazards, navigation, fatigue warnings) set `isEmergency = false`, no audio focus was requested from Android. Spotify continued playing at 100% volume without receiving a ducking signal.
2. **Missing TTS Volume Gain:** The Android `TextToSpeech` call passed an empty bundle without `KEY_PARAM_VOLUME = 1.0f`.
3. **No Rider Control for Music Pausing:** Some riders prefer music to duck (lower volume to 15–20%), while others prefer music to pause completely during an alert and resume automatically after. There was no user-configurable preference.

---

## 3. Enhancement Architecture

### A. Android Native Audio Focus (`TtsChannel.kt`)
- **Proper Audio Attributes:**
  - Standard warnings: `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`, `CONTENT_TYPE_SPEECH`.
  - Life-safety emergencies: `USAGE_ALARM`, `CONTENT_TYPE_SONIFICATION`.
- **Dynamic Focus Request:**
  - Always requests audio focus before speaking.
  - Standard mode: `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` with `setWillPauseWhenDucked(true)`. Ducks Spotify down to ~15% volume and restores it to 100% upon completion.
  - Pause mode: `AUDIOFOCUS_GAIN_TRANSIENT`. Forces Spotify to pause during speech and resume immediately on completion.
- **Watchdog Timer:** A 25-second timer safely abandons audio focus if TTS callbacks are delayed or dropped by the OS.
- **Maximum Gain:** Injected `bundle.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)`.

### B. iOS Audio Session (`AppDelegate.swift`)
- Configured `AVAudioSessionCategoryPlayback` with `duckOthers`.
- Dynamic switching: ducks audio for warnings; pauses/interrupts audio for emergencies or when `pauseOthers` is enabled.

### C. Cockpit Settings & Flutter Service Pipeline
- Added `keyPauseOtherAudio` preference in `NetworkConstants`.
- Added `pauseOtherAudio` toggle in `SettingsService` (persisted in SharedPreferences).
- Added UI toggle in `SettingsScreen` under "Voice & sound":
  - **"Pause music during alerts"**:
    - OFF (Default): Lowers music/Spotify volume (ducking) so alerts are loud and prominent.
    - ON: Pauses music/Spotify completely during alerts, then resumes.
- P0 Critical Emergency alerts (SOS, crash detection) always pause external music unconditionally.
- Wired through `AudioPriorityManager` and `VoiceService`.

---

## 4. Test Evidence
- `flutter analyze coroute_app`: 0 issues found.
- `gradlew compileDebugKotlin`: BUILD SUCCESSFUL.
- `flutter test`:
  - `test/voice_service_test.dart` (23 passing tests covering ducking, pause mode, and emergency overrides).
  - `test/audio_priority_and_fatigue_test.dart`
  - `test/alert_persistence_test.dart`
  - `test/intercom_network_resilience_test.dart`
  - `test/intercom_resilience_and_fallback_test.dart`
  - `test/phone_call_and_fuel_safety_test.dart`
  - `test/voice_hud_notification_test.dart`
  - `test/ios_platform_integration_test.dart`

