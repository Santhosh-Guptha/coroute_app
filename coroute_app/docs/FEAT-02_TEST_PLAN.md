# FEAT-02 — Collective Pothole & Road Hazard AI Telemetry Mesh
## Comprehensive Test Plan & Verification Matrix

> **Author**: Senior Mobile Systems Architect & Flutter/Gateway QA Team  
> **Status**: Approved for Verification  
> **Target Release**: v3.47.0+  
> **Date**: October 2026  

---

### 1. Test Architecture & Methodology

The test plan for FEAT-02 covers five distinct verification tiers:
1. **Unit Testing (Kinematic Filter & Classifiers)**: High-frequency synthetic and labelled sensor playback simulating potholes, railway crossings, lane changes, cornering, speed bumps, and rough roads.
2. **Spatial Deduplication & Anomaly Aggregation Testing**: Verification of the 100m road-segment bucket, multi-rider corroboration counting, and confidence scoring.
3. **Gateway Mesh Protocol & Entitlement Testing**: WebSocket client-server testing enforcing Road Captain publishing restrictions, Pro/Community receive rules, and carriageway direction filtering.
4. **End-to-End Timing Verification (5-Second SLA at 80 km/h)**: Sub-second clock and distance simulation verifying that at $80\text{ km/h}$ ($22.22\text{ m/s}$), trailing riders receive the alert with $\ge 5.0\text{ seconds}$ lead time before reaching the defect.
5. **Cockpit HUD & Audio Speech Verification**: Helmet TTS announcement generation (*"Caution: severe road hazard 300 meters ahead"*), deduplicated speech queue, priority ducking, and visual HUD state.

---

### 2. Test Case Specifications & Requirements Traceability Matrix

| Test ID | Module Under Test | Requirement / Scenario | Preconditions & Input Data | Expected Output / Assertion |
| :--- | :--- | :--- | :--- | :--- |
| **TEST-KIN-01** | `RoadHazardDetector` | Severe Pothole Detection | Vehicle speed $60\text{ km/h}$, vertical shock peak $2.3\text{ g}$, gyro yaw rate $38^\circ/\text{s}$ at $\Delta t = +80\text{ ms}$. | Detection triggered: `classification = POTHOLE`, `severity = HIGH`, `confidence \ge 0.85`. |
| **TEST-KIN-02** | `RoadHazardDetector` | Railway Crossing False-Positive Rejection | Vehicle speed $50\text{ km/h}$, dual vertical shocks ($2.1\text{ g}$ then $2.0\text{ g}$ at $120\text{ ms}$), yaw rate $< 8^\circ/\text{s}$, heading unchanged. | **Rejected**: Identified as transverse joint/railway crossing; no hazard broadcast. |
| **TEST-KIN-03** | `RoadHazardDetector` | Intentional Lane Change Rejection | Vehicle speed $80\text{ km/h}$, gyro yaw rate $32^\circ/\text{s}$, smooth roll angle change, vertical shock peak $< 0.3\text{ g}$. | **Rejected**: Identified as intentional lane change; no hazard broadcast. |
| **TEST-KIN-04** | `RoadHazardDetector` | Cornering & Sustained Lean Rejection | Vehicle speed $65\text{ km/h}$, sustained roll $28^\circ$, continuous yaw rate $18^\circ/\text{s}$, vertical dynamic shock $< 0.2\text{ g}$. | **Rejected**: Identified as cornering; no hazard broadcast. |
| **TEST-KIN-05** | `RoadHazardDetector` | Speed Breaker / Bump Discrimination | Vehicle speed slowing from $45\text{ km/h}$ to $25\text{ km/h}$, vertical shock $1.4\text{ g}$, yaw rate $< 10^\circ/\text{s}$. | **Rejected**: Filtered as speed breaker; no severe hazard broadcast. |
| **TEST-KIN-06** | `RoadHazardDetector` | Rough / Gravel Road Baseline Noise Rejection | Continuous high-frequency vibration ($\sigma_g = 0.45\text{ g}$), multiple small peaks ($1.1\text{ g} - 1.4\text{ g}$), no isolated shock $> 1.8\text{ g}$. | **Rejected**: High noise floor detected; individual bumps suppressed. |
| **TEST-KIN-07** | `RoadHazardDetector` | Phone Handling / Tap Rejection | Vehicle stationary ($v = 0\text{ km/h}$), hand tap shock $2.5\text{ g}$, yaw flick $40^\circ/\text{s}$. | **Rejected**: Speed $< 15\text{ km/h}$; stationary phone handling guard active. |
| **TEST-KIN-08** | `RoadHazardDetector` | Hard Braking to Stop Guard | Hard braking ($a_x = -0.8\text{ g}$) followed by stop ($v \le 5\text{ km/h}$ within $4\text{ s}$). | **Rejected**: Braking stop detected; handed off to crash/stop detector. |
| **TEST-KIN-09** | `RoadHazardDetector` | Device Orientation Invariance | Phone mounted in landscape tilted $45^\circ$. Vertical shock $2.2\text{ g}$ applied along world Earth-vertical. | Gravity vector filter correctly identifies Earth-vertical; shock $> 1.8\text{ g}$ accurately detected. |
| **TEST-KIN-10** | `RoadHazardDetector` | Wheelbase Double-Peak Cooldown | Front wheel hits hole ($2.1\text{ g}$), rear wheel hits hole $140\text{ ms}$ later ($1.9\text{ g}$). | Cooldown window collapses both hits into a single hazard observation with peak $2.1\text{ g}$. |
| **TEST-AGG-01** | `RoadHazardAggregator` | 100-Meter Spatial Deduplication | Two hazard observations reported $40\text{ m}$ apart along same road segment. | Only 1 hazard pin generated; second observation increments corroboration count. |
| **TEST-AGG-02** | `RoadHazardAggregator` | Multi-Rider Corroboration | Rider A reports pothole at $(12.9716, 77.5946)$. Rider B reports pothole $20\text{ m}$ away $2\text{ minutes}$ later. | Hazard pin maintained, `corroborations = 2`, `confidence` escalated from $0.70$ to $0.90$. |
| **TEST-AGG-03** | `RoadHazardAggregator` | Distinct Hazards Separation | Hazard 1 at km $10.000$, Hazard 2 at km $10.150$ ($150\text{ m}$ separation). | Both hazard pins preserved independently ($> 100\text{ m}$ apart). |
| **TEST-GW-01** | Gateway `ws.js` | Road Captain Broadcast Entitlement | Publisher connected with role `LEAD` / tier `roadCaptain` sends `ROAD_HAZARD`. | Frame accepted, validated, and broadcast to convoy room. |
| **TEST-GW-02** | Gateway `ws.js` | Community Publisher Rejection | Publisher connected with tier `community` (not Lead) attempts `ROAD_HAZARD`. | Rejected with HTTP 403 / Error `ENTITLEMENT_REQUIRED`. |
| **TEST-GW-03** | Gateway `ws.js` | Pro & Community Receive Entitlement | Trailing rider on `community` tier connected to room where Road Captain broadcasts hazard. | Rider successfully receives `ROAD_HAZARD` frame. |
| **TEST-GW-04** | Gateway `ws.js` | Downstream Route & Heading Filtering | Rider upstream $400\text{ m}$ heading $90^\circ$ vs Rider on opposite carriageway heading $270^\circ$. | Upstream rider receives hazard; opposite carriageway rider is excluded. |
| **TEST-GW-05** | Gateway `ws.js` | Passed Rider Exclusion | Rider positioned $50\text{ m}$ *past* the hazard ($d_{ahead} = -50\text{ m}$). | Rider is excluded from broadcast. |
| **TEST-TIM-01** | End-to-End Timing | 5-Second Reaction Time at 80 km/h | Trailing rider at $80\text{ km/h}$ ($22.22\text{ m/s}$). Hazard triggered at $300\text{ m}$ ahead on route. | End-to-end latency $\le 3.5\text{ s}$ ($78\text{ m}$). Alert finishes playing at $> 220\text{ m}$, providing $> 9.5\text{ s}$ reaction time ($\gg 5.0\text{ s}$). |
| **TEST-TIM-02** | End-to-End Timing | High Speed Scenario (100 km/h) | Trailing rider at $100\text{ km/h}$ ($27.78\text{ m/s}$). Hazard triggered at $300\text{ m}$ ahead on route. | Alert finishes playing at $\sim 200\text{ m}$, providing $7.2\text{ s}$ reaction time ($\ge 5.0\text{ s}$). |
| **TEST-HUD-01** | `LiveCockpitMapScreen` | Visual Hazard Pill Display | Ingest `ROAD_HAZARD` at $300\text{ m}$ ahead. | Amber/orange tactical HUD pill displayed: `[ ⚠️ SEVERE ROAD HAZARD 300M AHEAD ]`. Tap centers map. |
| **TEST-AUD-01** | `VoiceService` | Helmet Audio Speech Output | Trigger alert at $300\text{ m}$ ahead. | Exact phrase spoken: *"Caution: severe road hazard 300 meters ahead"*. |
| **TEST-AUD-02** | `VoiceService` | Audio Deduplication & Ducking | Multiple GPS updates within $300\text{ m} - 250\text{ m}$. | Alert speaks exactly once; background intercom audio is ducked during speech. |

---

### 3. Kinematic Test Datasets (Synthetic & Labelled)

#### Dataset A: Pothole Strike (Labelled Real-World Ground Truth)
- Vehicle: KTM 390 Adventure, Handlebar Ram-Mount (tilted $35^\circ$).
- Speed: $72\text{ km/h}$.
- Trace:
  - $t = 0.00\text{ s}$: $a_v = 0.02\text{ g}$, $\omega_{yaw} = 1.2^\circ/\text{s}$ (Smooth tarmac).
  - $t = 0.10\text{ s}$: $a_v = 0.40\text{ g}$, $\omega_{yaw} = 3.5^\circ/\text{s}$ (Entry edge).
  - $t = 0.12\text{ s}$: $a_v = 2.45\text{ g}$, $\omega_{yaw} = 34.8^\circ/\text{s}$ (Impact shock + handlebar deflection).
  - $t = 0.24\text{ s}$: $a_v = 1.95\text{ g}$, $\omega_{yaw} = 12.1^\circ/\text{s}$ (Rear wheel impact).
  - $t = 0.50\text{ s}$: $a_v = 0.15\text{ g}$, $\omega_{yaw} = 2.0^\circ/\text{s}$, speed $68\text{ km/h}$ (Recovery, continued riding).
- Ground Truth: **POSITIVE (POTHOLE)**.

#### Dataset B: Railway Track Crossing (Labelled Ground Truth)
- Vehicle: Royal Enfield Himalayan, Tank-bag mount.
- Speed: $55\text{ km/h}$.
- Trace:
  - $t = 0.00\text{ s}$: $a_v = 0.05\text{ g}$, $\omega_{yaw} = 0.5^\circ/\text{s}$.
  - $t = 0.08\text{ s}$: $a_v = 2.10\text{ g}$, $\omega_{yaw} = 4.2^\circ/\text{s}$ (Front wheel hits rail perpendicular).
  - $t = 0.18\text{ s}$: $a_v = 1.98\text{ g}$, $\omega_{yaw} = 3.8^\circ/\text{s}$ (Rear wheel hits rail).
  - $t = 0.30\text{ s}$: $a_v = 0.08\text{ g}$, $\omega_{yaw} = 0.8^\circ/\text{s}$, heading unchanged.
- Ground Truth: **FALSE POSITIVE (TRANSVERSE_JOINT)**.

#### Dataset C: Aggressive Lane Change (Labelled Ground Truth)
- Vehicle: Kawasaki Versys 650, Handlebar mount.
- Speed: $85\text{ km/h}$.
- Trace:
  - $t = 0.00\text{ s}$ to $t = 0.80\text{ s}$: Roll changes smoothly from $0^\circ$ to $18^\circ$ and back to $0^\circ$.
  - Yaw rate peaks at $32.4^\circ/\text{s}$.
  - Vertical dynamic shock: $|a_v| \le 0.28\text{ g}$.
- Ground Truth: **FALSE POSITIVE (LANE_CHANGE)**.
