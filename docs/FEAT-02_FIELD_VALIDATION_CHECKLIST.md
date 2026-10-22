# FEAT-02 — Field Validation & Closed-Course Testing Checklist
## CoRoute Collective Pothole & Road Hazard AI Telemetry Mesh

**Document Version:** 1.0.0  
**Target Release:** v3.46.0  
**Feature ID:** `FEAT-02`  
**Classification:** High-Risk Dynamic Kinematic Field Procedure  

---

### 1. Mandatory Safety & Closed-Course Protocol

> [!CAUTION]
> **CLOSED-COURSE SAFETY REQUIREMENT**  
> Dynamic hazard detection and reaction-time testing must **NEVER** be conducted on open public roads or in mixed live traffic. Testing must strictly occur on a controlled, closed-course test track or an abandoned paved airstrip with dedicated safety marshals and paramedic standby.

1. **Rider Equipment & PPE:**
   - ECE 22.06 / DOT certified full-face helmet with integrated Bluetooth communicator (Sena 50S, Cardo Packtalk Edge, or equivalent).
   - CE Level 2 armored riding jacket, pants, gloves, and riding boots.
2. **Speed Compliance & Marshalling:**
   - Test speeds are strictly limited to designated target runs (60 km/h, 80 km/h, 100 km/h).
   - Course must have clear run-off zones with no oncoming vehicular traffic.
   - A chase vehicle or trackside observer equipped with synchronized high-speed video timing equipment must record all test runs.

---

### 2. Vehicle & Phone Mount Rigidity Setup

Prior to conducting kinematic sensor tests, verify the physical smartphone installation:

- [ ] **Mount Rigidity Check:** Secure device in a high-grade mechanical mount with vibration dampener (Quad Lock with Vibration Dampener, RAM Mount, or SP Connect).
- [ ] **Loose Mount Detection Test:** Deliberately induce mount wobble while stationary. Verify detector suppresses artificial vibration spikes due to speed-gating ($< 20\text{ km/h}$).
- [ ] **Orientation Calibration Verification:**
  - Mount device in primary riding orientation (Portrait, Landscape 90°, or Landscape 270°).
  - Perform a steady 5-second roll-out at 30–40 km/h on smooth pavement.
  - Verify `RoadHazardDetector` converges low-pass static gravity vector $\vec{g}_{est}$ within $\pm 0.3\text{ m/s}^2$ of Earth vertical ($9.80665\text{ m/s}^2$) and computes valid device rotation matrix.
  - Verify shock spike gating prevents sudden impacts ($|\vec{a}| > 14\text{ m/s}^2$ or $< 6\text{ m/s}^2$) from pulling $\vec{g}_{est}$ off vertical.

---

### 3. Kinematic Detector Field Scenarios

| Test ID | Track Feature / Maneuver | Test Speed | Expected Detector Behavior | Pass/Fail Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **FLD-KIN-01** | **Calibrated Severe Pothole** (depth $\ge 4.5\text{ cm}$, sharp drop) | 60 & 80 km/h | Dynamic shock $> 1.8\text{ g}$, gyro yaw $> 25^\circ/\text{s}$, no hard braking | **DETECT**: Event emitted with `pothole` classification, confidence $\ge 0.80$ |
| **FLD-KIN-02** | **Railway Level Crossing** (Dual transverse tracks) | 60 & 80 km/h | Two high vertical jolts ($> 2.0\text{ g}$), minimal yaw deflection ($< 15^\circ/\text{s}$) | **REJECT**: No hazard emitted; transverse shock filter active |
| **FLD-KIN-03** | **Bridge Expansion Joint** (Rubber/metal transverse seam) | 80 km/h | Sharp vertical impulse ($1.9\text{ g}$), straight vehicle trajectory | **REJECT**: Suppressed by low angular rate ($< 25^\circ/\text{s}$) |
| **FLD-KIN-04** | **Speed Breaker / Asphalt Hump** | 30 & 50 km/h | Gradual rise/fall, speed reduction before impact | **REJECT**: Deceleration braking profile + lack of sharp shock spike |
| **FLD-KIN-05** | **Intentional Highway Lane Change** | 80 & 100 km/h | Sustained yaw flick ($30\text{--}45^\circ/\text{s}$), smooth pavement | **REJECT**: Suppressed due to near-zero dynamic shock ($< 0.4\text{ g}$) |
| **FLD-KIN-06** | **High-Vibration Corrugated Gravel Road** | 50 km/h | High continuous background vibration ($\sigma_g \approx 0.65\text{ g}$) | **REJECT**: Background noise adapted into dynamic variance buffer |
| **FLD-KIN-07** | **Severe Pothole on Gravel Road** | 50 km/h | Sharp shock punching through gravel floor ($> 3\sigma_g$ and $> 1.8\text{ g}$) + yaw | **DETECT**: Successfully triggers despite high ambient road vibration |
| **FLD-KIN-08** | **Wheelbase Re-strike Cooldown** | 60 & 80 km/h | Front wheel impacts pothole, followed by rear wheel 80–120ms later | **COLLAPSE**: Single observation emitted; rear impact absorbed by 750ms cooldown |
| **FLD-KIN-09** | **Stationary / Low-Speed Handling** | 0–15 km/h | Rider taps mount, enters phone passcode, or drops bike on stand | **REJECT**: Speed gate ($< 20\text{ km/h}$) completely suppresses detection |

---

### 4. Mesh Aggregation & Multi-Rider Corroboration

Conduct with Lead Rider (Road Captain account) and Trailing Rider (Pro / Community account):

- [ ] **Lead Rider Entitlement:** Verify Lead Rider app has active `Road Captain` or `Tour Operator` plan. Verify gateway accepts `ROAD_HAZARD` frame and returns acknowledgment.
- [ ] **Unauthorized Publisher Rejection:** Downgrade Lead account to `Free / Community`. Verify gateway returns structured error `{ type: 'ERROR', code: 403, reason: 'ENTITLEMENT_REQUIRED' }` and no mesh broadcast is generated.
- [ ] **100-Meter Spatial Deduplication:**
  - Lead rider hits test defect at Marker 0m. Gateway allocates `pin_001`.
  - Chase rider hits same defect 30 seconds later. Gateway recognizes proximity ($< 100\text{ m}$) and matching heading ($\pm 60^\circ$).
  - Verify Gateway corroboration count increments to 2, confidence increases by +0.15, and no duplicate pin is created.
- [ ] **Opposite Carriageway Isolation:**
  - On dual-carriageway divided test strip, have a rider drive in opposite direction (heading diff $180^\circ$) past the defect coordinates.
  - Verify trailing opposite riders do **NOT** receive hazard warning for oncoming lanes.
- [ ] **Boundary Separation (99m vs 101m):**
  - Defect A at 0m, Defect B at 99m: verify single aggregated hazard cluster.
  - Defect A at 0m, Defect C at 102m: verify two distinct hazard pins.

---

### 5. 5-Second Reaction Time & Spoken Alert Timing Verification

- [ ] **Trailing Rider Spacing Setup:** Trailing rider follows Lead Rider at 500m distance at steady 80 km/h ($22.22\text{ m/s}$).
- [ ] **Broadcast & Route Match:** When trailing rider reaches 300m remaining corridor distance:
  - Gateway WebSocket delivers `ROAD_HAZARD` payload.
  - Receiver triggers `EmergencyGuidance` spoken alert.
- [ ] **Exact Spoken Phrasing:** Verify helmet headset speaks:  
  `"Caution: severe road hazard 300 meters ahead"`.
- [ ] **Physical Reaction Window Stopwatch Measurement:**
  - Start stopwatch when TTS completes speech playback (`"300 meters ahead"` ends).
  - Stop stopwatch when motorcycle front tire reaches the physical hazard marker.
  - **Acceptance Criterion:** Elapsed time must be $\ge 5.0\text{ seconds}$.  
    *(Observed baseline at 80 km/h: 300m trigger yields $\sim 11.3\text{ seconds}$ remaining reaction time).*
- [ ] **High-Speed Stress Test (100 km/h / 27.78 m/s):**
  - Repeat test at 100 km/h.
  - **Acceptance Criterion:** Elapsed time must be $\ge 5.0\text{ seconds}$.  
    *(Observed baseline at 100 km/h: 300m trigger yields $\sim 8.6\text{ seconds}$ remaining reaction time).*

---

### 6. Helmet Bluetooth Audio & Visual HUD Integration

- [ ] **Bluetooth Communicator SCO Routing:**
  - Connect Sena / Cardo headset over Bluetooth.
  - Ensure alert routes cleanly to helmet speakers with ducking of intercom/music.
- [ ] **Realistic Spatial Audio Limitation Check:**
  - Verify that dual-mono helmet audio is received loud and clear ($85\text{ dB(A)}$).
  - Verify rider UI displays directional HUD pill (`RoadHazardHudPill`) with relative bearing arrow and distance countdown.
  - Note: Bluetooth HFP/SCO does not support binaural 3D spatial HRTF panning; audio is dual-mono with visual directional assist.
- [ ] **Non-Repeating Speech Suppression:**
  - Maintain 80 km/h approach. Ensure warning is spoken **once** at the 300m threshold and does not repeatedly loop or chatter.
- [ ] **Emergency SOS Preemption:**
  - Trigger simulated `CRASH_AUTO` convoy emergency simultaneously with a road hazard approach.
  - Verify emergency SOS guidance immediately preempts road hazard warning.

---

### 7. Sign-off & Completion

| Role | Name | Signature / Timestamp | Result |
| :--- | :--- | :--- | :--- |
| **Lead Test Rider** | | | PASS / FAIL |
| **Safety Marshal** | | | PASS / FAIL |
| **QA / Audio Lead** | | | PASS / FAIL |
