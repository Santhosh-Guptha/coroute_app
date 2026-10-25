# FEAT-05: CoRoute Low-Connectivity SOS & Satellite Relay — Field Validation Checklist

> **Feature ID**: FEAT-05  
> **Target Release Line**: v3.47.0+  
> **Validation Target**: Wilderness & Mountain Corridor Zero-Connectivity Readiness  

---

## 1. Pre-Ride Checklist (Before Entering Dead Zone)

| # | Inspection Item | Verification Step | Pass Criteria | Sign-off |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Emergency Contact Configured** | Open CoRoute Profile $\to$ Safety Settings $\to$ ICE Contacts. | At least one valid mobile number with country code (e.g., `+91 ...`) saved. | [ ] |
| 2 | **Medical Info Consent** | Check Profile $\to$ Medical Info. Confirm blood group (e.g., `O+`) is entered. | Blood group selected; user consented to share during emergency. | [ ] |
| 3 | **Offline Map Packs Downloaded** | Open Trip Planner $\to$ Offline Maps Manager. Download corridor tile pack (e.g., *Manali to Leh*). | Vector tiles verified and available offline. | [ ] |
| 4 | **Battery Level & Power Bank** | Verify phone battery is $>80\%$; connect to handlebar 12V USB / power bank. | Phone actively charging or full battery. | [ ] |
| 5 | **Subscription Verification** | Ensure Pro Rider or Tour Operator subscription is active if automated satellite relay is needed. | Feature unlocked in Settings $\to$ Subscription. | [ ] |

---

## 2. Simulated Dead-Zone Field Drill (Airplane Mode Test)

| # | Test Step | Execution Method | Expected Result | Pass Criteria |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Simulate Dead Zone** | Enable **Airplane Mode**, then re-enable **GPS / Location Services**. | Cellular data disconnected; 0 bars; GPS lock maintained. | [ ] |
| 2 | **Trigger Manual SOS** | Long-press handlebar remote SOS button for 2.5s OR hold on-screen SOS for 3s. | SOS countdown initiates; visual and audible alarm sounds. | [ ] |
| 3 | **Inspect Emergency Sheet** | Allow countdown to complete without cancellation. | Sheet displays: `Status: Handoff Required` or `Queued in Buffer`. | [ ] |
| 4 | **Verify India 112 ERSS Text** | Inspect generated emergency dispatch text message. | Text contains: Rider SOS header, exact Lat/Lng coordinates, Google Maps URL, UTC timestamp, Trauma level, and Blood Group. | [ ] |
| 5 | **Simulate Reconnect** | Disable **Airplane Mode**; restore 4G/5G connection. | `SatelliteSosService` auto-flushes queued event; status transitions to `Accepted by Provider`. | [ ] |

---

## 3. Crash Detection & Countdown Expiry Drill (Staged Test)

| # | Test Step | Execution Method | Expected Result | Pass Criteria |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Crash Trigger** | Trigger test crash in staged low-connectivity simulation. | 15-second high-contrast countdown screen appears. Bystander siren sounds. | [ ] |
| 2 | **Biometric Vitals Binding** | Observe trauma level on countdown HUD (if smartwatch worn). | Pulse verified; trauma level (e.g., `Stable Vitals` or `Elevated Stress`) attached to SOS payload. | [ ] |
| 3 | **Auto-Dispatch on Expiry** | Allow 15-second countdown to expire without touching "I'm OK". | Dispatch initiates automatically. 16-byte binary packet encoded and stored to persistent disk queue. | [ ] |
| 4 | **Cancellation Test** | Tap "Cancel SOS" on active emergency banner. | Service marks event `Cancelled`; disables retry timers; notifies convoy mesh. | [ ] |

---

## 4. Verification Sign-off

- **Lead Safety Auditor**: ____________________________________
- **Date Verified**: ____________________________________
- **Field Location / Corridor**: ____________________________________
- **Result**: [ ] PASS  [ ] FAIL
