# FEAT-01 — Field & Physical Hardware Validation Checklist
## BLE Handlebar Wireless SOS & Intercom PTT Remote

> **Feature ID**: FEAT-01  
> **Testing Environment**: Physical Motorcycle Handlebars, Bluetooth HID Remotes, Heavy Riding Gloves  
> **Evaluator**: Safety Systems & Hardware Interop Engineering  

---

## 1. Hardware Pairing & Coexistence Verification

- [ ] **Physical Pairing & System Registration**:
  - [ ] Remote (e.g. AB Shutter 3 / Sena RC4) pairs cleanly under Android Settings $\to$ Connected Devices / Bluetooth.
  - [ ] Remote registers as an Input Device (HID keyboard / gamepad).
  - [ ] Remote connects within $\le 2.0\text{ seconds}$ upon handlebar power-on.
- [ ] **Helmet Bluetooth Headset Coexistence**:
  - [ ] Connect Cardo Packtalk Edge or Sena 50S via Bluetooth Classic audio (HFP/A2DP).
  - [ ] Verify two-way intercom audio operates without clicks, crackles, or packet drops when remote buttons are pressed.
  - [ ] Verify phone media playback does not glitch or pause when remote events trigger.

---

## 2. Ergonomic Glove Operation & Gesture Timing

- [ ] **Single Press (PTT Voice Toggle)**:
  - [ ] Press remote button once wearing thick leather winter gloves while riding at $60\text{--}80\text{ km/h}$.
  - [ ] Intercom begins transmitting within $< 100\text{ ms}$.
  - [ ] Haptic buzz confirms action to handlebar mount.
  - [ ] Pressing again cleanly stops voice transmission.
- [ ] **Double Press (Hazard Ahead Signal)**:
  - [ ] Double-tap remote button rapidly within $400\text{ ms}$.
  - [ ] Cockpit immediately synthesizes *"Caution: Hazard on road."* through helmet speakers.
  - [ ] Trailing convoy riders receive tactical packet and audio cue.
- [ ] **Triple Press & 2.5s Hold (Emergency SOS)**:
  - [ ] Deliberately click button 3 times in quick succession.
  - [ ] Emergency SOS full-screen alarm immediately triggers countdown without touching phone.
  - [ ] Hold button continuously for $\ge 2.5\text{ seconds}$.
  - [ ] Emergency SOS full-screen alarm immediately triggers countdown.

---

## 3. Cockpit HUD & Visual Verification

- [ ] **Cockpit Status Pill**:
  - [ ] When remote is paired, cockpit displays `[ 🔘 REMOTE PAIRED · 95% ]`.
  - [ ] When remote disconnects or powers down, pill displays `[ 🔘 REMOTE DISCONNECTED ]`.
  - [ ] Tapping pill provides tactile feedback and opens diagnostics.
