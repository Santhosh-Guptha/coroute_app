# FEAT-03 — Emergency Siren Acoustic Frequency Detector
## Comprehensive Test Plan & Verification Specification

**Document Version:** 1.0.0  
**Feature ID:** `FEAT-03`  
**Classification:** Acoustic DSP & Life-Safety Validation  
**Target Release:** v3.47.0+  

---

### 1. Test Strategy Overview

The testing suite for **FEAT-03** is partitioned into four distinct validation layers:
1. **Deterministic DSP Unit Tests**: Synthetic, mathematical wave generation simulating exact physical siren profiles, vehicle engine harmonics, wind noise, and horns to verify the streaming classifier without hardware dependencies.
2. **Audio Ducking & Restoration Tests**: Verification of the $-20\text{ dB}$ ($0.10$) amplitude attenuation on playback buffers, smooth release, and safety preemption.
3. **HUD & Alert Arbitration Tests**: Validation of the high-contrast `SirenHudPill`, alert deduplication, Community-tier unlocking, and directional text guards.
4. **Physical Controlled Acoustic Tests**: Controlled field procedures testing speaker distance attenuation, motorcycle mount placement, and ambient wind degradation.

---

### 2. Unit Test Matrix (`test/siren_acoustic_detector_test.dart`)

| Test ID | Test Scenario | Input Signal Characteristics | Expected Result | Pass Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **TEST-SIR-01** | **Wail Siren Pattern** | Sinusoidal FM $700\text{--}1500\text{ Hz}$, $T = 4.0\text{ s}$, $SNR = +12\text{ dB}$ | **DETECTED**: `wail` mode | State $\to$ `detected`, confidence $\ge 0.85$ |
| **TEST-SIR-02** | **Yelp Siren Pattern** | Rapid triangular FM $700\text{--}1500\text{ Hz}$, $T = 0.35\text{ s}$ | **DETECTED**: `yelp` mode | State $\to$ `detected`, confidence $\ge 0.85$ |
| **TEST-SIR-03** | **Two-Tone (Hi-Lo)** | Alternating $700\text{ Hz} \leftrightarrow 950\text{ Hz}$, dwell $0.6\text{ s}$ | **DETECTED**: `twoTone` mode | State $\to$ `detected`, confidence $\ge 0.80$ |
| **TEST-SIR-04** | **Motorcycle Engine RPM Sweep** | Linear sweep $120\text{--}420\text{ Hz}$ + 2nd/3rd harmonics | **REJECTED**: No periodic FM | State remains `inactive`, confidence $< 0.20$ |
| **TEST-SIR-05** | **Loud Exhaust Rumble** | High amplitude pink noise $60\text{--}250\text{ Hz}$, $95\text{ dB SPL}$ | **REJECTED**: Low mid-band | State remains `inactive`, confidence $< 0.10$ |
| **TEST-SIR-06** | **Wind Buffeting & Clipping**| Brownian noise $< 350\text{ Hz}$ with random clipping | **REJECTED**: High flatness | Low peak-to-average ratio ($PAR < 2.0$), no trigger |
| **TEST-SIR-07** | **Static Vehicle Horn** | Static dual-tone $440\text{ Hz} + 880\text{ Hz}$, zero modulation | **REJECTED**: Modulation absent | Frequency deviation $< 50\text{ Hz}$, no trigger |
| **TEST-SIR-08** | **Music & Speech Contamination**| Multi-harmonic speech vocal tracts + dynamic rhythm | **REJECTED**: Irregular pitch | Formant clusters reject periodic siren cycles |
| **TEST-SIR-09** | **Weak / Intermittent Siren** | Low amplitude wail ($SNR \approx +3\text{ dB}$) with gaps | **ACCUMULATION**: Confidence ramps | Requires $\ge 3$ consecutive cycles before alert |
| **TEST-SIR-10** | **Simultaneous Noise + Siren**| Wail siren mixed with $75\text{ dB}$ engine rumble | **DETECTED**: Harmonic extraction | Narrowband tracker isolates siren through noise |
| **TEST-SIR-11** | **Silence & Dynamic Noise Floor**| Pure silence $\to$ ambient city street noise | **ADAPTIVE**: Noise floor tracks | Baseline energy adapts without false triggers |
| **TEST-SIR-12** | **Buffer Overflow & Corrupt Samples**| NaN, Inf, non-aligned PCM byte arrays | **RESILIENT**: Graceful discard | Zero crashes or unhandled exceptions |
| **TEST-SIR-13** | **Confidence Hysteresis & Cooldown**| Siren stops after 5 seconds of continuous detection | **COOLDOWN**: 3.0s cooldown | Transitions `detected` $\to$ `cooldown` $\to$ `inactive` |
| **TEST-SIR-14** | **Continuous Siren Deduplication**| Siren sounds for 30 continuous seconds | **DEDUPED**: Single incident | Exactly 1 alert event and persistent HUD state |
| **TEST-SIR-15** | **Permission Denial Recovery** | Mic permission denied or revoked | **UNAVAILABLE**: Graceful state | State $\to$ `unavailable`, zero crashes |
| **TEST-SIR-16** | **Deterministic Resource Cleanup**| Detector stopped / ride ended | **CLEANUP**: Streams closed | Stream subscriptions canceled, memory released |

---

### 3. Audio Ducking Test Matrix

| Test ID | Test Scenario | Action | Expected Output | Pass Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **TEST-DUCK-01** | **-20 dB Intercom Chatter Ducking**| Siren transitions to `detected` | `IntercomService` incoming PCM scaled by $0.10$ | Measured amplitude reduction $= 20.0\text{ dB} \pm 0.5\text{ dB}$ |
| **TEST-DUCK-02** | **Smooth Volume Restoration** | Siren clears to `inactive` | Playback volume restored to original $1.0$ factor | Smooth ramp over $500\text{ ms}$, no clicks/pops |
| **TEST-DUCK-03** | **Critical Voice Override** | High-priority SOS alert spoken during siren | `VoiceService` SOS alert speaks at 100% volume | Siren ducking never attenuates emergency voice |
| **TEST-DUCK-04** | **Crash / Shutdown Safety** | Unexpected detector error or ride cancel | Audio state forcefully restored | System volume preference remains intact |

---

### 4. Cockpit HUD & Entitlement Test Matrix

| Test ID | Test Scenario | Expected Visual / Behavioral Result | Pass Criteria |
| :--- | :--- | :--- | :--- |
| **TEST-HUD-01** | **Community Tier Access** | `FeatureGates.isUnlocked(Feature.sirenAcousticDetector)` | Evaluates `true` on Community tier |
| **TEST-HUD-02** | **Direction Unverified Alert Text**| Single microphone / direction unknown | Text: `🚨 EMERGENCY SIREN DETECTED · YIELD` |
| **TEST-HUD-03** | **Direction Verified Alert Text** | Multi-sensor / rear acoustic verified | Text: `🚨 EMERGENCY SIREN DETECTED BEHIND · YIELD` |
| **TEST-HUD-04** | **Non-Obscuring Priority Stack** | Active SOS occurs simultaneously with siren | SOS alert occupies slot 1; siren occupies slot 2 |

---

### 5. Physical Controlled Testing Protocol (Summary)

Physical validation involves:
1. Calibrated outdoor speaker setup broadcasting standardized siren sweeps (SAE J1849).
2. Motorcycle stationary test at $150\text{ m}$ (direct line-of-sight).
3. Motorcycle riding test at $60\text{ km/h}$ and $80\text{ km/h}$ with helmet wind buffeting.
4. Measurement of false-positive rejection over a $30\text{--minute}$ mixed highway ride.
