# CoRoute Multilingual Voice Assistant: Command Catalog & Intent Specifications

> **Document ID**: `DOC-VA-03`  
> **Milestone**: Milestone 5 — Private Intercom Handshake, Audio Management & Direct Voice SOS (Phases 1–4 Verified)  
> **Target Domains**: Messaging, Navigation, Voice Settings, Group Alerts, Intercom, Safety  
> **Status**: APPROVED & VERIFIED (Phases 1–4 Automated Test Coverage)  

---

## 1. Intent Taxonomy & Domain Overview

The Voice Assistant command space is organized into 6 functional domains spanning 14 discrete intents:

| Domain | Intent Identifier | Description | Risk Tier | Offline Support |
| :--- | :--- | :--- | :---: | :---: |
| **Settings** | `SET_VOICE_VOLUME` | Adjust assistant / TTS output volume | Tier 1 (Low) | Yes |
| **Settings** | `SWITCH_LANGUAGE` | Switch preferred speech language | Tier 1 (Low) | Yes |
| **Navigation** | `QUERY_TRIP_STATUS` | Query current speed, remaining distance, ETA | Tier 1 (Low) | Yes |
| **Navigation** | `REPEAT_DIRECTIONS` | Re-read last turn-by-turn guidance prompt | Tier 1 (Low) | Yes |
| **Navigation** | `FIND_ESSENTIALS` | Locate nearest fuel, hospital, puncture repair | Tier 2 (Med) | Partial (GIS Cache) |
| **Navigation** | `PROPOSE_STOP` | Propose regroup or fuel stop on route | Tier 3 (High) | Yes (Mesh) |
| **Messaging** | `SEND_MESSAGE` | Send private or directed message to rider | Tier 2 (Med) | Yes (Outbox) |
| **Messaging** | `BROADCAST_ALERT` | Send tactical alert to all convoy riders | Tier 3 (High) | Yes (Outbox) |
| **Convoy** | `QUERY_CONVOY_STATUS`| Query riders behind, lead/sweeper distance | Tier 1 (Low) | Yes (Live/Ghost) |
| **Convoy** | `REQUEST_REGROUP` | Ask convoy lead/group to slow down or halt | Tier 2 (Med) | Yes (Outbox) |
| **Intercom** | `REQUEST_INTERCOM` | Initiate 1:1 private intercom call with rider | Tier 2 (Med) | Partial (Mesh/Web) |
| **Intercom** | `DISCONNECT_INTERCOM`| Terminate private intercom session | Tier 1 (Low) | Yes |
| **Intercom** | `MUTE_MICROPHONE` | Mute or unmute local microphone | Tier 1 (Low) | Yes |
| **Safety** | `TRIGGER_SOS` | Dispatch emergency distress beacon | Tier 4 (Critical)| Yes (Mesh/SMS) |
| **Safety** | `CANCEL_SOS` | Cancel active crash countdown or alarm | Tier 4 (Critical)| Yes |

---

## 2. Intent Specifications & Slot Schemas

### 1. `SET_VOICE_VOLUME`
- **Slots**:
  - `delta` (float, e.g., `+0.2`, `-0.2`)
  - `level` (int, `0` to `100`, optional)
  - `action` (enum: `increase`, `decrease`, `max`, `mute`)
- **Sample Utterances**:
  - *“Voice volume konjam kammi pannu”* (Tamil)
  - *“Awaaz badhao”* (Hindi)
  - *“Volume reduce chey”* (Telugu)
  - *“Set volume to eighty percent”* (English)
- **Response**: *“Volume set to {level}%.”*

### 2. `QUERY_TRIP_STATUS`
- **Slots**:
  - `metric` (enum: `speed`, `distance_covered`, `distance_remaining`, `eta`, `next_stop`, `all`)
- **Sample Utterances**:
  - *“Speed kiti ahe?”* (Marathi)
  - *“Aau kete dur achhi destination?”* (Odia)
  - *“Agla stop kithe hai?”* (Punjabi)
  - *“What is our ETA?”* (English)
- **Response**: *“Speed is {speed} km/h. Next stop is {next_stop} in {distance} km.”*

### 3. `FIND_ESSENTIALS`
- **Slots**:
  - `category` (enum: `FUEL`, `PUNCTURE`, `HOSPITAL`, `FOOD`, `ATM`)
  - `max_distance_km` (double, optional, default: `10.0`)
- **Sample Utterances**:
  - *“Next petrol bunk find maadi”* (Kannada)
  - *“Find a petrol pump within five kilometres”* (English)
  - *“Petrol pump kitna dur hai?”* (Hindi)
- **Response**: *“Found Indian Oil fuel station 3.8 km ahead on your route.”*

### 4. `SEND_MESSAGE`
- **Slots**:
  - `recipient_name` (string, e.g., `"Rohit"`)
  - `message_body` (string, e.g., `"Toll gate pe ruko"`)
- **Sample Utterances**:
  - *“Rohit ki message send chey: Five minutes lo reach avtha”* (Telugu)
  - *“Rohit ko message bhejo: Main piche reh gaya”* (Hindi)
  - *“Send message to Vikram: Waiting at junction”* (English)
- **Verbal Confirmation Flow**:
  - Assistant: *“Send message to Rohit Sharma: 'Waiting at junction'. Confirm?”*
  - Rider: *“Yes”* / *“Send”* -> Transmitted.
  - Rider: *“Cancel”* / *“No”* -> Discarded.

### 5. `BROADCAST_ALERT`
- **Slots**:
  - `alert_type` (enum: `HAZARD`, `STOP`, `SLOW_DOWN`, `ROAD_BLOCK`, `CUSTOM`)
  - `message_body` (string)
- **Sample Utterances**:
  - *“Sab riders ko alert bhejo: Road par oil spill hai”* (Hindi)
  - *“Group alert pathao: Road block ahe”* (Bengali)
  - *“Broadcast alert: Pothole on left lane”* (English)
- **Confirmation**: Required before group broadcast.

### 6. `REQUEST_INTERCOM`
- **Slots**:
  - `target_rider` (string)
- **Sample Utterances**:
  - *“Rohit-inu private intercom request ayakkuka”* (Malayalam)
  - *“Rohit tho private intercom connect chey”* (Telugu)
  - *“Connect private intercom to Ananya”* (English)
- **Handshake Protocol**: Transmits consent request to target rider. Target must verbally accept or press PTT within 30 seconds before voice stream connects.

### 7. `TRIGGER_SOS` / `CANCEL_SOS`
- **Slots**: None (Immediate execution).
- **Sample Utterances**:
  - *“CoRoute emergency”*, *“CoRoute SOS”*, *“Mayday”*, *“Crash SOS”*
  - *“CoRoute I'm OK”*, *“Cancel SOS”*, *“False alarm”*, *“Silence siren”*
- **Safety Gate**: Zero conversational delay. Delegates directly to `SafetyService.alarmSendNow()` or `SafetyService.alarmImOk()`.
