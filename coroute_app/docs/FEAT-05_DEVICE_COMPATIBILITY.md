# FEAT-05: CoRoute Low-Connectivity SOS & Satellite Relay — Device Compatibility Guide

> **Feature ID**: FEAT-05  
> **Target Release Line**: v3.47.0+  
> **Last Updated**: October 23, 2026  

---

## 1. Overview

This document specifies the supported operating systems, hardware capabilities, and communication pathways for CoRoute's emergency distress system across connected, cellular-only, low-connectivity, and complete dead-zone environments.

---

## 2. Platform & Hardware Matrix

| Hardware / OS Category | Supported Devices | Minimum OS Version | Connectivity Channels | CoRoute Emergency Behavior |
| :--- | :--- | :--- | :--- | :--- |
| **Standard Android Smartphone** | Samsung Galaxy, Google Pixel, Xiaomi, OnePlus, Realme, Vivo | Android 6.0+ (API 23+) | 2G/3G/4G/5G Cellular, Wi-Fi | Online Gateway when connected. Falls back to ERSS 112 dialer and SMS handoff with human-readable coordinates, Google Maps link, and trauma status. Offline events queued to disk. |
| **Android 15+ NTN Satellite Phones** | Google Pixel 9 series, upcoming Android 15/16 NTN hardware | Android 15 (API 35+) | 3GPP Rel-17 NTN Satellite, Cellular | Automatic fallback detection in dead zones. Triggers system emergency satellite assistant handoff. Bounded offline queue persists until signal is re-established. |
| **Apple iPhone (Cellular Only)** | iPhone 6s through iPhone 13 | iOS 12.0+ | 2G/3G/4G/5G Cellular, Wi-Fi | Online Gateway when connected. In dead zones, triggers native emergency dialer (`tel:112`) and formats emergency SMS text. Events persist to disk queue. |
| **Apple iPhone (Satellite Hardware)** | iPhone 14, 15, 16 series | iOS 16.1+ | Globalstar L-Band Satellite, Cellular | In cellular dead zones, CoRoute detects connectivity loss and guides rider to the native iOS Emergency SOS via Satellite UI. Background disk queue persists until connectivity returns. |
| **India BSNL Skylo NTN Devices** | BSNL Satellite IoT Terminals | Device Firmware 2.0+ | Inmarsat / GSAT GEO Satellite | Fully authorized under DoT/WPC India license. Sends 16-byte compact binary packets through BSNL Dehradun Satellite Gateway. |
| **Garmin inReach (Consumer)** | inReach Mini 2, inReach Messenger | Garmin OS / Explore App | Iridium LEO Satellite | Direct control via proprietary BLE requires Garmin Enterprise Partner contract. CoRoute provides app handoff and formatted SMS text. |
| **ZOLEO Communicator** | ZOLEO Satellite Communicator | ZOLEO App | Iridium LEO Satellite | Closed proprietary BLE. CoRoute provides deep-link handoff and formatted emergency message. |

---

## 3. Indian Regulatory & Geographic Deployment Rules

### 1. Department of Telecommunications (DoT) & WPC Law
- Under the **Indian Wireless Telegraphy Act (1933)** and **Indian Telegraph Act (1885)**, foreign satellite transceivers (e.g. Thuraya, Iridium handhelds imported without DoT permits) are strictly illegal in India.
- Unlicensed satellite equipment operated in sensitive border zones (e.g., Ladakh, Jammu & Kashmir, Sikkim, Arunachal Pradesh) will be confiscated by Indian security forces and can incur criminal prosecution.
- **CoRoute Compliance**: CoRoute does not operate or require unauthorized satellite uplinks. In India, it routes through licensed cellular infrastructure (ERSS 112) or authorized BSNL Skylo channels.

### 2. Emergency Response Support System (ERSS 112)
- All mobile handsets in India are legally mandated to support single-key emergency dialing to **112**.
- 112 calls route with emergency priority across any available tower (even if the user's home operator has no signal and even if no SIM card is inserted).
- ERSS 112 operators require human-readable text (latitude, longitude, landmark, severity, blood group) rather than binary hex streams. CoRoute automatically structures this text.

---

## 4. Battery Optimization in Zero-Connectivity Zones

When riding outside cellular coverage:
1. **Radio Search Suppression**: Continuous network searching drains phone batteries rapidly. CoRoute's `SatelliteSosService` uses exponential backoff (1s, 2s, 4s... max 5 attempts) and then pauses until network state transitions occur, preventing continuous battery drain.
2. **Offline Disk Persistence**: Emergency events are safely serialized to flash storage (`SharedPreferences`) so they survive device shutdown or battery depletion.
3. **Emergency Screen Mode**: When the crash alarm triggers in low-battery conditions, high-contrast, black-background UI minimizes OLED power consumption.
