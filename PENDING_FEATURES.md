# CoRoute - Next-Generation Safety Features Pending Backlog

> **Document Status**: Active Implementation Queue  
> **Target Release Line**: v3.47.0+  
> **Master Architecture**: Defense-in-Depth Rider Safety Matrix  
> **Rule**: Features are implemented individually in sequential, fully verified phases.

---

## Feature Implementation Pipeline Index

| ID | Feature Name | Tier Entitlement | Primary Domain | Status |
| :--- | :--- | :---: | :--- | :---: |
| **FEAT-01** | **BLE Handlebar Wireless SOS & Intercom PTT Remote** | Community (Free) | Hardware / BLE GATT | `[ ] PENDING` |
| **FEAT-02** | **Collective Pothole & Road Hazard AI Telemetry Mesh** | Road Captain / Pro | Kinematics / AI Mesh | `[ ] PENDING` |
| **FEAT-03** | **Emergency Siren Acoustic Frequency Detector** | Community (Free) | Audio DSP / TFLite | `[ ] PENDING` |
| **FEAT-04** | **Smartwatch Biometric Trauma & Pulse Verification** | Pro / Captain | WearOS / HealthKit | `[ ] PENDING` |
| **FEAT-05** | **Low-Altitude Satellite SOS Gateway Relay** | Tour Operator / Pro | Iridium / Native Sat | `[ ] PENDING` |
| **FEAT-06** | **Smart Airbag Vest Peripheral Bluetooth Bridge** | Community (Free) | BLE Wearable GATT | `[ ] PENDING` |
| **FEAT-07** | **Helmet Bluetooth Intercom Voice Safety Hotwords** | Community (Free) | Offline STT / DSP | `[ ] PENDING` |
| **FEAT-08** | **Server-Side Emergency SMS & WhatsApp Web Gateway** | Community (Free) | Cloud / Twilio API | `[ ] PENDING` |
| **FEAT-09** | **Dead Reckoning & Tunnel IMU Motion Estimation** | Community (Free) | Sensor Fusion / GIS | `[ ] PENDING` |
| **FEAT-10** | **Peer-to-Peer Bluetooth Offline Convoy Mesh** | Road Captain | Local P2P Network | `[ ] PENDING` |

---

## Detailed Specifications & Technical Implementation Plans

### FEAT-01: BLE Handlebar Wireless SOS & Intercom PTT Remote
- **Priority**: High (Immediate Ergonomic Safety)
- **Tier**: **Community (Free)** — Core life safety.
- **Problem Statement**:
  When cornering, riding at high speeds, or navigating treacherous off-road terrain with thick riding gloves, taking a hand off the handlebars to touch a phone touchscreen is extremely dangerous and often impossible.
- **Technical Architecture**:
  1. **BLE Scanner & Peripheral Manager**:
     - Service: `lib/data/services/ble_remote_service.dart`.
     - Supports standard Bluetooth HID and GATT profiles (Flic 2, BlueCadence, Sena RC4, and generic $5 BLE camera shutter / media remotes).
  2. **Input Mapping**:
     - **Single Press**: Toggle PTT Intercom Speak (Voice start / Voice end).
     - **Double Press**: Instant Quick Marker / Tactical Signal ("Hazard ahead").
     - **Triple Press or 3-Second Hold**: Trigger Emergency SOS alarm countdown without touching phone.
  3. **Cockpit Integration**:
     - Adds a paired status indicator in `live_cockpit_map_screen.dart` (`[ 🔘 Remote Paired ]`).
- **Acceptance Criteria**:
  - Remote triggers SOS even when the phone display is locked or app is in the background.
  - Sub-100ms latency on PTT voice transmission.
  - Zero interference with Bluetooth helmet audio headset.

---

### FEAT-02: Collective Pothole & Road Hazard AI Telemetry Mesh
- **Priority**: High (Group Crash Prevention)
- **Tier**: **Road Captain (Broadcast) / Pro & Community (Receive)**.
- **Problem Statement**:
  Lead riders hit severe hazards (deep unmarked potholes, gravel washouts, oil slicks, bridge joint ridges) at speed. While the lead may recover, trailing riders in the pack often crash without warning.
- **Technical Architecture**:
  1. **Kinematic Pattern Detector**:
     - Evaluates high-frequency accelerometer z-axis peaks ($> 1.8\text{ g}$ vertical shock) combined with a momentary gyroscope yaw flick ($\Delta \theta > 25^\circ/\text{s}$) without a corresponding brake stop.
  2. **Automated Anomaly Tagging**:
     - Tags WGS84 coordinate of the defect with road speed and severity score.
     - Rate-limits to 1 hazard pin per $100\text{ m}$ to prevent road vibration noise.
  3. **Gateway Mesh Broadcast**:
     - Server pushes high-priority `ROAD_HAZARD` frame to all downstream bikes traveling on the same route.
  4. **Cockpit HUD Audio Cues**:
     - Synthesizes spatial voice alert into following riders' helmets $300\text{ m}$ before the coordinate: *"Caution: severe road hazard 300 meters ahead"*.
- **Acceptance Criteria**:
  - False positive rejection on routine railway tracks and intentional lane changes.
  - Trailing riders receive spatial warning with minimum 5 seconds reaction time at $80\text{ km/h}$.

---

### FEAT-03: Emergency Siren Acoustic Frequency Detector
- **Priority**: Medium-High (Auditory Situational Awareness)
- **Tier**: **Community (Free)**.
- **Problem Statement**:
  Riders wearing custom earplugs, noise-isolating helmet pads, and listening to convoy intercom or music cannot hear sirens of ambulances, fire trucks, or police vehicles approaching from behind until they are dangerously close.
- **Technical Architecture**:
  1. **Low-Power Audio Classifier**:
     - Service: `lib/data/services/siren_acoustic_detector.dart`.
     - Micro-buffer audio input sampling at $16\text{ kHz}$ from phone or helmet ambient mic.
     - Detects characteristic siren harmonics: $700\text{ Hz} - 1500\text{ Hz}$ frequency modulation (wail, yelp, two-tone hi-lo).
  2. **Ducking & HUD Visual Override**:
     - Automatically ducks intercom and music audio by $-20\text{ dB}$.
     - Displays pulsating emergency pill on map: `[ 🚨 EMERGENCY SIREN DETECTED BEHIND · YIELD ]`.
- **Acceptance Criteria**:
  - Distinguishes sirens from motorcycle engine noise, wind buffeting, and loud exhaust pipes.
  - Detects approaching siren at a minimum distance of $150\text{ m}$.

---

### FEAT-04: Smartwatch Biometric Trauma & Pulse Verification
- **Priority**: High (Post-Crash Trauma Escalation)
- **Tier**: **Pro Rider / Road Captain**.
- **Problem Statement**:
  In severe motorcycle crashes, riders are frequently thrown into deep ravines or brush where they cannot be seen, suffering internal hemorrhage or traumatic cardiac arrest while unable to speak.
- **Technical Architecture**:
  1. **Health Bridge Listener**:
     - Service: `lib/data/services/biometric_safety_bridge.dart`.
     - Connects via Apple HealthKit (iOS) and Google Health Connect / WearOS companion.
  2. **Cardiac Anomaly Protocol**:
     - Tracks real-time heart rate (BPM) during the 15-second crash countdown.
     - **Tachycardia / Extreme Stress Spike**: $\text{BPM} > 160$ post-impact.
     - **Trauma / Cardiac Arrest**: Abrupt cessation of pulse or drop to $0$ BPM.
  3. **Escalated Dispatch**:
     - Upgrades SOS dispatch to **"Critical Trauma Level 1 (Severe Trauma / Cardiac Alert)"**.
     - Automatically attaches 5-minute pre-crash heart rate graph and blood group directly to paramedic emergency payload.
- **Acceptance Criteria**:
  - Continuous low-battery consumption ($< 2\%$ battery per 4-hour ride).
  - Clean fallback when watch is not worn or disconnects during impact.

---

### FEAT-05: Low-Altitude Satellite SOS Gateway Relay
- **Priority**: High (Extreme Wilderness Resilience)
- **Tier**: **Tour Operator / Pro Rider**.
- **Problem Statement**:
  In high-altitude adventure routes (e.g., Ladakh, Spiti Valley, Alaskan Highway, Australian Outback), cellular coverage (including 2G GSM) drops to zero for hundreds of kilometers.
- **Technical Architecture**:
  1. **Satellite Protocol Transceiver**:
     - Service: `lib/data/services/satellite_sos_service.dart`.
     - Direct BLE / USB bridge to Garmin inReach, ZOLEO, or Bivy Stick satellite communicators.
     - Integration with Android 15 `SatelliteManager` and iOS 18 Emergency Satellite APIs.
  2. **Compressed 16-Byte Distress Payload**:
     - Compact binary representation: Lat (4B), Lng (4B), Altitude (2B), Timestamp (4B), Severity & Blood Group (2B).
     - Dispatches via Iridium or Globalstar satellite constellations directly to CoRoute Emergency Gateway.
- **Acceptance Criteria**:
  - Automatically activates when terrestrial cell network reports 0 bars for $> 60\text{ seconds}$ during an emergency.
  - Emergency packet successfully transmits with clear sky view in $< 90\text{ seconds}$.

---

### FEAT-06: Smart Airbag Vest Peripheral Bluetooth Bridge
- **Priority**: Medium (Hardware Integration)
- **Tier**: **Community (Free)**.
- **Problem Statement**:
  Electronic motorcycle airbag vests (In&motion, Alpinestars Tech-Air, Helite e-Turtle) deploy pyrotechnically in $20\text{ to }40\text{ ms}$ upon sensing a high-side or low-side crash, but the rider's phone may be mounted on handlebars without registering immediate impact.
- **Technical Architecture**:
  1. **GATT Peripheral Listener**:
     - Connects to airbag vest deployment status service UUID.
  2. **Instant External Impact Escalation**:
     - On receipt of deployment flag, immediately invokes:
       `SafetyService.externalImpact(source: ExternalImpactSource.wearable, g: 6.0)`.
     - Bypasses phone motion filter and triggers emergency countdown instantly.
- **Acceptance Criteria**:
  - Zero false triggers on vest battery low or firmware update.
  - Latency from vest deployment to app alarm $< 150\text{ ms}$.

---

### FEAT-07: Hands-Free Helmet Bluetooth Intercom Voice Safety Hotwords
- **Priority**: Medium (Hands-Free Cockpit Operation)
- **Tier**: **Community (Free)**.
- **Problem Statement**:
  Riders in heavy traffic or rain cannot safely operate touchscreen controls to acknowledge solo check-ins, report fuel stops, or call SOS.
- **Technical Architecture**:
  1. **On-Device Offline Speech Keyword Spotter**:
     - Uses compact TensorFlow Lite / Picovoice keyword spotting model running purely on CPU.
  2. **Recognized Safety Hotwords**:
     - *"CoRoute I'm OK"* $\rightarrow$ Cancels active crash countdown / check-in.
     - *"CoRoute Emergency SOS"* $\rightarrow$ Triggers immediate emergency alert.
     - *"CoRoute Regroup Ahead"* $\rightarrow$ Broadcasts meeting point to convoy.
     - *"CoRoute Low Fuel"* $\rightarrow$ Flags rider as low fuel on group bead wire.
- **Acceptance Criteria**:
  - 100% offline operation without active internet connection.
  - $> 95\%$ accuracy with helmet microphone wind noise at $60\text{ km/h}$.

---

### FEAT-08: Server-Side Emergency SMS & WhatsApp Web Gateway
- **Priority**: High (Cross-Platform SMS Reliability)
- **Tier**: **Community (Free)**.
- **Problem Statement**:
  Client-side Android `SmsManager` fails if the rider's phone is a data-only SIM card, has exhausted prepaid balance, or is an iOS device where background SMS dispatch is restricted by Apple security sandboxes.
- **Technical Architecture**:
  1. **Gateway Dispatch Microservice**:
     - File: `coroute_app/gateway/src/services/emergency_sms_gateway.js`.
     - Integrates Twilio / AWS SNS / Infobip REST API on OCI Cluster.
  2. **Automated Redundancy Switch**:
     - When client SOS arrives over WebSocket or HTTP, the gateway dispatches server-side SMS and WhatsApp messages to all registered emergency contacts containing live tracking URLs.
- **Acceptance Criteria**:
  - Guaranteed SMS delivery within 10 seconds of gateway receipt.
  - Zero credentials leaked to client app.

---

### FEAT-09: Dead Reckoning & Tunnel IMU Motion Estimation
- **Priority**: Medium (Zero-GPS Handling)
- **Tier**: **Community (Free)**.
- **Problem Statement**:
  Inside long highway tunnels (e.g., 5–10 km alpine tunnels) or steep mountain gorges, GPS drops completely. The app shows $0\text{ km/h}$, causing false "Rider Stopped" warnings.
- **Technical Architecture**:
  1. **IMU Sensor Fusion Filter**:
     - Evaluates accelerometer forward vector and wheel rotational vibration frequency.
  2. **Position Projection**:
     - Projects position forward along the active route corridor at last known speed until GPS re-acquires.
     - Suppresses stopped/separated alerts while inside detected tunnel envelopes.
- **Acceptance Criteria**:
  - Position error $< 50\text{ m}$ per kilometer traveled in GPS blackouts.
  - Smooth GPS re-acquisition without teleportation jumps.

---

### FEAT-10: Peer-to-Peer Bluetooth Offline Convoy Mesh
- **Priority**: High (Deep Wilderness Convoy Sync)
- **Tier**: **Road Captain / Pro Rider**.
- **Problem Statement**:
  When an entire convoy rides through an internet-dead mountain pass, the cloud gateway is unreachable. Riders cannot see teammate distances or emergency status.
- **Technical Architecture**:
  1. **Nearby Connections / BLE Mesh Engine**:
     - Service: `lib/data/services/p2p_mesh_service.dart`.
     - Establishes a hop-by-hop mesh network ($100\text{ to }250\text{ m}$ per hop) between bikes.
  2. **Mesh Frame Exchange**:
     - Synchronizes rider relative order, battery level, sweeper status, and distress flags.
- **Acceptance Criteria**:
  - 10-bike chain maintains mesh connectivity over a $1.5\text{ km}$ convoy string.
  - Local peer-to-peer distress alerts sound instantly across all mesh nodes.

---

## Next Action & Starting Order

We will execute this backlog **one feature at a time**, beginning with:
1. **FEAT-01: BLE Handlebar Wireless SOS & Intercom PTT Remote** (Hardware integration, zero-look rider safety).
2. **FEAT-02: Collective Pothole & Road Hazard AI Telemetry Mesh** (Autonomous pack protection).
3. **FEAT-03: Emergency Siren Acoustic Frequency Detector** (Audio situational awareness).
4. ...and sequentially through the remaining roadmap.
