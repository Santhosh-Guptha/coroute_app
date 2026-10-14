# CoRoute Pending Safety Features Roadmap

**Created:** October 14, 2026  
**Status:** Backlog / Prioritized Future Roadmap  
**Context:** Preserved for implementation following the Cockpit UX Simplification initiative.

---

## 1. Server-Side Gateway Emergency SMS / WhatsApp Relay (Zero-SIM / No-Airtime Fallback)
- **Current State:** The emergency SMS fallback relies strictly on client-side Android `SmsManager`. If the rider's phone has no SMS airtime balance, is a data-only SIM, or is an iOS device, SMS cannot be sent.
- **Planned Implementation:** Implement server-side emergency dispatch on the Oracle Cloud Gateway (via Twilio, AWS SNS, or Infobip REST API). When a rider triggers an SOS over mobile data, the gateway automatically dispatches SMS/WhatsApp alerts with live GPS tracking links to all registered emergency contacts.

---

## 2. Peer-to-Peer Offline Mesh Telemetry (Cellular Dead Zones)
- **Current State:** In deep valleys, national parks, and mountain passes with zero cellular signal, convoy members cannot see teammates' live distances or emergency status.
- **Planned Implementation:** Implement direct device-to-device Bluetooth Low Energy (BLE) or Wi-Fi Direct Nearby Connections mesh protocol (100–300m range) to sync relative distance, leader/sweeper markers, and SOS distress beacons between nearby bikes without internet.

---

## 3. Physical Bluetooth Wearable & Smart Airbag Vest Integration
- **Current State:** The software hook `SafetyService.externalImpact(source: ExternalImpactSource.wearable, g: ...)` is fully built and tested via the 7-tap developer trigger, but no physical Bluetooth peripheral bridge exists.
- **Planned Implementation:** Add Bluetooth Low Energy (BLE) peripheral scanning and GATT listener service for smart motorcycle airbag vests (e.g. Helite, In&motion, Alpinestars Tech-Air) and WearOS / Apple Watch fall-detection sensors.

---

## 4. Hands-Free Helmet Bluetooth Intercom Voice Safety Hotwords
- **Current State:** When riding at highway speeds with thick riding gloves, dismissing a check-in, setting a fuel stop, or sending an SOS requires looking at and touching the screen.
- **Planned Implementation:** Integrate hands-free speech recognition through helmet communicators (Cardo / Sena) listening for quick voice hotwords: *"CoRoute I'm OK"*, *"CoRoute SOS"*, *"CoRoute Fuel"*, *"CoRoute Regroup"*.

---

## 5. Dead Reckoning & Tunnel IMU Motion Estimation (Zero-GPS Handling)
- **Current State:** Inside long tunnels or under heavy mountain rock cover where GPS signal is completely lost, speed drops to 0 km/h, which can trigger false "Rider Stopped" alerts after 2 minutes.
- **Planned Implementation:** Use the phone's Accelerometer & Gyroscope (IMU) to calculate dead reckoning / vehicular movement, maintaining estimated position and suppressing false stop alarms until GPS lock is reacquired.

---

## 6. Sub-Convoy Split & Re-group Clustering (Multi-Squad Safety)
- **Current State:** A convoy is treated as a single pack with one Lead and one Sweeper. If a 12-bike group gets split by traffic lights or a highway fork into two groups, the second group receives distance separation alarms.
- **Planned Implementation:** Dynamic sub-convoy clustering (DBSCAN distance algorithm) that automatically detects a split, promotes a temporary sub-lead for Squad Bravo, and coordinates safety status for both halves until regrouping.

---

## 7. Lock-Screen First Responder ICE Card Shortcut
- **Current State:** `IceMedicalCard` exists inside the app and within open SOS incident sheets.
- **Planned Implementation:** Add an Android Lock-Screen Notification / Quick Settings tile shortcut allowing first responders or bystanders to open the rider's Emergency Medical Card (Blood Group, Allergies, ICE Contacts) instantly without unlocking the phone.
