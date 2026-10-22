# FEAT-03 — Emergency Siren Acoustic Frequency Detector
## Detailed Technical Implementation Plan

**Document Version:** 1.0.0  
**Feature ID:** `FEAT-03`  
**Classification:** Acoustic DSP & Life-Safety Implementation  
**Target Release:** v3.47.0+  

---

### 1. Modules & Architecture Deliverables

```
coroute_app/
├── lib/
│   ├── core/
│   │   └── config/
│   │       └── feature_gates.dart                 [Add Feature.sirenAcousticDetector (Community Free)]
│   ├── data/
│   │   └── services/
│   │       ├── siren_acoustic_detector.dart       [NEW: Streaming DSP classifier & audio ducking coordinator]
│   │       └── intercom_service.dart              [Update: Add setSirenDucking(-20 dB / 0.10 factor)]
│   └── presentation/
│       └── rider/
│           ├── widgets/
│           │   └── siren_hud_pill.dart            [NEW: High-contrast pulsating emergency HUD pill]
│           └── live_cockpit_map_screen.dart       [Update: Integrate siren alert slot into cockpit map]
└── test/
    └── siren_acoustic_detector_test.dart          [NEW: 16 DSP unit tests, ducking tests, HUD tests]
```

---

### 2. Implementation Tasks Breakdown

#### Task 1: Subscription Gating & Feature Catalog (`TASK-SIREN-01`)
- **Target File**: `coroute_app/lib/core/config/feature_gates.dart`.
- **Changes**:
  1. Add `Feature.sirenAcousticDetector` to `enum Feature`.
  2. In `isUnlocked(Feature feature, [SubscriptionTier? tier])`:
     ```dart
     case Feature.roadHazardReceive:
     case Feature.sirenAcousticDetector:
       return true; // Available to all tiers including Community
     ```

#### Task 2: Streaming DSP Siren Classifier Engine (`TASK-SIREN-02`)
- **Target File**: `coroute_app/lib/data/services/siren_acoustic_detector.dart`.
- **Classes**:
  - `enum SirenPatternType { wail, yelp, twoTone, unknown }`
  - `enum SirenDetectorState { inactive, candidate, detected, cooldown, unavailable }`
  - `class SirenDetectionEvent`:
    - `DateTime timestamp`
    - `double confidence` ($0.0\text{--}1.0$)
    - `SirenPatternType pattern`
    - `double dominantFrequencyHz`
    - `bool directionKnown`
    - `bool approachingFromBehind`
  - `class SirenClassifierEngine`:
    - Pure Dart, zero native dependencies, deterministic for unit testing.
    - Processes $16\text{ kHz}$ 16-bit mono PCM chunks in 512-sample ($32\text{ ms}$) analysis windows.
    - Windowing: Hanning window to suppress boundary artifacts.
    - Bandpass analysis: Discrete Goertzel / FFT filter bank covering $600\text{--}1600\text{ Hz}$ in $25\text{ Hz}$ intervals.
    - Peak Tracking: Estimates dominant instantaneous frequency $f_{peak}$ in the band.
    - Spectral Prominence: Peak-to-Average Ratio ($PAR$) and noise-floor estimation to reject wideband wind noise ($PAR < 2.0$).
    - Modulation History: Maintains sliding $3.5\text{-second}$ history of peak frequencies:
      - **Wail**: Frequency deviation $\Delta f \ge 400\text{ Hz}$, period $3.0\text{--}6.0\text{ s}$.
      - **Yelp**: Frequency deviation $\Delta f \ge 400\text{ Hz}$, period $0.15\text{--}0.5\text{ s}$.
      - **Two-Tone**: Alternating plates in $[650, 780]\text{ Hz}$ and $[880, 1020]\text{ Hz}$.
    - False-Positive Gating:
      - Rejects monotonic vehicle horns ($\Delta f < 50\text{ Hz}$).
      - Rejects engine acceleration ramps (monotonic increase without periodic reversal).
      - Rejects low-frequency rumble (exhaust noise below $300\text{ Hz}$).
    - State Machine & Hysteresis:
      - Transition from `candidate` to `detected` requires consecutive confidence $\ge 0.65$.
      - Cooldown buffer: Once `detected`, remains active for $3.0\text{ seconds}$ after signal ceases before reverting to `inactive`.

#### Task 3: Siren Acoustic Detector & Ducking Coordinator (`TASK-SIREN-03`)
- **Target File**: `coroute_app/lib/data/services/siren_acoustic_detector.dart`.
- **Class**: `class SirenAcousticDetector extends ChangeNotifier`:
  - Manages `AudioRecorder` stream at $16\text{ kHz}$ mono PCM16.
  - Exposes:
    - `ValueNotifier<SirenDetectorState> stateNotifier`
    - `ValueNotifier<SirenDetectionEvent?> activeSirenNotifier`
    - `ValueNotifier<bool> isAudioDuckedNotifier`
  - Audio Ducking Integration:
    - Connects with `IntercomService` to duck chatter by $-20\text{ dB}$ (factor $0.10$).
    - Connects with system audio channel to request `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` on Android.
    - Smooth release on siren resolution without altering rider's volume settings.
  - Safe lifecycle management:
    - Bounded internal memory buffers (circular queues, max 256 kB RAM).
    - Releases mic deterministically on `stop()` or `dispose()`.

#### Task 4: Audio Ducking in IntercomService (`TASK-SIREN-04`)
- **Target File**: `coroute_app/lib/data/services/intercom_service.dart`.
- **Changes**:
  - Add `setSirenDucking(bool ducked)` method.
  - When true, clamps incoming playback audio using `attenuatePcm16(chunk, 0.10)` ($-20\text{ dB}$).
  - Smooth restoration when ducking is disengaged.

#### Task 5: Cockpit Map HUD Emergency Pill (`TASK-SIREN-05`)
- **Target File**: `coroute_app/lib/presentation/rider/widgets/siren_hud_pill.dart`.
- **UI Design**:
  - High-visibility amber/red pulsating emergency badge matching `AppTheme` styling.
  - Restrained, rider-friendly single-pulse glow.
  - Displays:
    - If `approachingFromBehind == true`: `🚨 EMERGENCY SIREN DETECTED BEHIND · YIELD`
    - Otherwise: `🚨 EMERGENCY SIREN DETECTED · YIELD`
  - Accessible semantics label for screen readers.

#### Task 6: Live Cockpit Map Screen Integration (`TASK-SIREN-06`)
- **Target File**: `coroute_app/lib/presentation/rider/live_cockpit_map_screen.dart`.
- **Changes**:
  - In `_slots()`, evaluate `SirenAcousticDetector.activeSirenNotifier`.
  - When siren is detected, insert `SirenHudPill` at `AlertPriority.hazard` (ranking below active SOS, but above standard route info and social notices).

#### Task 7: Unit & Integration Test Suite (`TASK-SIREN-07`)
- **Target File**: `coroute_app/test/siren_acoustic_detector_test.dart`.
- **Coverage**:
  - 16 deterministic DSP tests with synthetic waveforms.
  - Ducking -20 dB attenuation and restoration tests.
  - HUD pill display and directional text guard tests.
  - Lifecycle, permission denial, and resource cleanup tests.

---

### 3. Verification Commands & Acceptance Criteria

```bash
# 1. Run Siren Acoustic Detector test suite
cd coroute_app; flutter test test/siren_acoustic_detector_test.dart

# 2. Run existing emergency and timing regression tests
cd coroute_app; flutter test test/emergency_guidance_test.dart test/road_hazard_mesh_timing_test.dart

# 3. Verify static analysis
cd coroute_app; dart analyze lib

# 4. Run gateway regression tests
node --test coroute_app/gateway/test/road_hazard_gateway.test.js
npm test --prefix coroute_app/gateway
```
